<p align="center">
  <img src="../FractalSQLforDruid.jpg" alt="FractalSQL for Apache Druid" width="720">
</p>

# FractalSQL Daemon

`fractalsqld` is the separate process that holds everything that can block on
the network, load third-party code, or hold licensed code — the
reasoning/embedding plugin, the Enterprise ledger and the session settings.
The Druid extension, loaded into your Druid processes, runs the pure functions
itself and forwards the rest to the daemon over a local Unix socket. This
page covers running the daemon and its `fsqlctl` CLI directly, and what that
two-process architecture guarantees (and doesn't) for reliability.

Normal installs (the `.deb`/`.rpm`, the release bundle's `install.sh`, or the
Docker demo) set all of this up for you — see
[`getting-started.md`](getting-started.md). The sections below are for
running it by hand, writing your own config, or scripting against it. For the
wire protocol itself, see
[`../service/protocol/SPEC.md`](../service/protocol/SPEC.md).

## Running `fractalsqld`

```
fractalsqld [-c config]
```

`-c` points at the config file (below). If omitted, it reads from
`FRACTALSQL_CONFIG` in the process environment, then falls back to
`/etc/fractalsql/fractalsqld.conf`.

`fractalsqld` runs on a Java 17 or newer runtime; the launcher that the
packages and the bundle install (`fractalsqld`) starts the JVM for you.

### Config file

One `key = value` per line, `#` for comments. `socket_path` and
`hmac_key_file` are required; everything else has a default.

| Key | Required | Default | Notes |
| --- | --- | --- | --- |
| `socket_path` | yes | — | A Unix socket path (under ~107 chars). |
| `hmac_key_file` | yes | — | Path to a file holding a hex-encoded key, shared with the extension's `druid.fractalsql.daemon_hmac_key_file`. Generate one with `openssl rand -hex 32`. |
| `log_file` | no | stderr | Where log lines go. |
| `max_connections` | no | `64` | Concurrent client connections (the extension in each Druid process, `fsqlctl`, or both). |
| `idle_timeout_secs` | no | `300` | A connection idle this long is closed. |
| `allowed_uids` | no | the daemon's own uid | Comma-separated list of uids allowed to connect (checked via `SO_PEERCRED`/`getpeereid`). Set this to the uid Druid runs as. |

### Provider keys

The remaining keys configure the reasoning, embedding, text-to-SQL and
Enterprise tiers. The config file is the **preferred** source for all of
them; a key absent from the file falls back to fractalsqld's process
environment (the `FRACTALSQL_*`/`FSQL_*` names those tiers have always
read), which is captured once at daemon startup — so a pure-environment
deployment behaves exactly as before. The `FSQLD_*` names the Docker demo
uses (`FSQLD_REASONING_URL`, `FSQLD_EMBED_MODEL`, …) are the same keys
spelled as environment variables. The legacy
`FRACTALSQL_TEXT_TO_SQL_*` names remain the text-to-sql tier's
fallback. All of them reload live with
`fsqlctl reload` (semantics below); the pushed value reaches the consumer
on that tier's *next* call.

| Key | Required | Default | Notes |
| --- | --- | --- | --- |
| `reasoning_plugin` | no | — | Path to the reasoning plugin (`.so`/`.dylib`). Must be an absolute path with no `..` segments. |
| `reasoning_url` | no | — | HTTP reasoning endpoint. |
| `reasoning_token` | no | — | Secret — Bearer token for the reasoning endpoint. |
| `reasoning_model` | no | — | Model name sent to the reasoning endpoint. |
| `reasoning_allow_plaintext` | no | off | Permit a plain-HTTP (non-TLS) reasoning endpoint. |
| `embed_url` | no | — | Embeddings HTTP endpoint. |
| `embed_model` | no | — | Model name sent to the embeddings endpoint. |
| `think` | no | `none` | THINK reasoning-effort knob for hybrid-thinker models (`none`/`off`/`low`/`medium`/`high`/…). See [reasoning-setup.md](reasoning-setup.md). |
| `think_provider` | no | `openai` | Request shape THINK uses (`openai`, `ollama`, or `anthropic`). |
| `think_native_url` | no | — | Override URL for the ollama/anthropic native shape. |
| `think_num_ctx` | no | — | Ollama-native context-window cap. Must be an integer in `1`–`10000000`. |
| `t2s_max_attempts` | no | `2` | Text-to-SQL GENERATE retry budget, clamped to `1`–`10`. |
| `t2s_allowed_statements` | no | `select` | Exactly `select` or `select_insert_update` (the latter permits writes). |
| `t2s_use_review` | no | off | Add the text-to-SQL REVIEW pass. |
| `enterprise_lib` | no | — | Path to the FractalSQL Enterprise library. Must be an absolute path with no `..` segments. |
| `enterprise_ledger_path` | no | — | Ledger file path (opens per operation, so it can be swapped live). Must be an absolute path with no `..` segments. |
| `enterprise_ledger_key` | no | — | Secret — HMAC-SHA256 ledger key (unset means structural-only validation). |
| `enterprise_require_signature` | no | on | Refuse to load an enterprise library with no detached signature file. See [enterprise.md](enterprise.md#detached-signature-verification-mandatory-by-default). |

Example (Linux):

```ini
socket_path = /run/fractalsql/fractalsqld.sock
hmac_key_file = /etc/fractalsql/hmac.key
allowed_uids = 1000
idle_timeout_secs = 300
```

Because `reasoning_token` and `enterprise_ledger_key` may sit in the file
as plaintext, the daemon's conf file is gated like `hmac_key_file`: a
world-accessible config refuses both startup and `fsqlctl reload` (the
message names "other users"). Make it private — `chmod 600` or `640` with
the daemon's group.

### Path-shaped keys are validated at load and reload

The three keys that name a file on disk -- `reasoning_plugin`,
`enterprise_lib`, `enterprise_ledger_path` -- must hold an **absolute path
with no `..` segments**. A relative path resolves differently depending on how
the daemon was started, and a `..` segment makes the path's meaning depend on
the operator's directory tree, so a value that looks harmless in one working
directory can name a different file in another.

The daemon validates the provider settings when it reads the config file, at
startup and again on every reload. A rejected value refuses the **whole**
reload -- the running configuration is left untouched -- and the daemon's log
names the key and the rule:

```
provider key reasoning_plugin: must be an absolute path with no '..' segments (got 'relative/plugin.so')
```

`fsqlctl reload` then reports `reload failed: provider settings rejected (see
the daemon log)`. The check applies to the keys actually present in the file;
a key that is absent falls back to the daemon's own environment as usual.

### Per-session configuration overrides

The config file is process-wide. Changing it means a filesystem edit plus a
reload -- the right shape for an operator, the wrong shape for a session that
wants one knob changed for its own work. Five SQL functions give a
**session** a live override of the tuning keys, layered over the
daemon-wide values:

| Function | Returns |
| --- | --- |
| `fractal_config_set(name, value, session_id)` | `'ok'`, or the refusal reason |
| `fractal_config_get(name, session_id)` | the effective value for that session, or `NULL` when the key is unknown; a secret key reports `'<redacted>'` or `'<unset>'` instead of a value |
| `fractal_config_reset(session_id)` | how many overrides were dropped |
| `fractal_config_list(session_id)` | the session's own overrides, as a JSON object |
| `fractal_config_keys()` | every known key, as a JSON array of `{name, type, session_overridable}` |

The session key is the caller's own, named as an argument: a Druid query has
no connection to hang a session on, and the query context is per-request, so
the caller names the session it is speaking for (the MCP server uses its own
session's name). A session may only override its own key.

`fractal_config_set` **returns** the refusal reason rather than raising it, so
a refusal hands the caller something it can read.

A session may change the **tuning** keys -- `reasoning_model`, `embed_model`,
`think`, `think_num_ctx`, `t2s_max_attempts`, `t2s_use_review` -- and nothing
else. A refused key is refused **by name, with the reason**, and the key is
checked before the value -- so the refusal always names the key, never the
value:

```
'reasoning_plugin' is a daemon-wide setting and cannot be changed by a session;
edit fractalsqld.conf and run `fsqlctl reload`
```

The refused keys, and why:

| Key | Why a session may not change it |
| --- | --- |
| `reasoning_plugin`, `enterprise_lib`, `enterprise_ledger_path` | which code the daemon loads -- a session that could name its own `.so` would run attacker-chosen code as the daemon |
| `reasoning_url`, `embed_url`, `think_native_url` | where the daemon's outbound traffic (and its bearer token) goes -- a session that could re-point the URL could exfiltrate the operator's token |
| `reasoning_token`, `enterprise_ledger_key` | the operator's own credentials -- a session never reads or replaces them |
| `reasoning_allow_plaintext`, `enterprise_require_signature` | transport-posture flags the operator set deliberately |
| `think_provider`, `t2s_allowed_statements` | routing and capability widening |

A secret's value is never returned: `fractal_config_get` reports
`'<redacted>'` when it is configured and `'<unset>'` when it is not.

A session may hold **several** overrides at once -- `think` and `think_num_ctx`
together, say. The overlay keeps one entry per session, so every override a
session holds reads back, `fractal_config_list` shows all of them, and
`fractal_config_reset` drops all of them: there is no way for an override to be
accepted and then be invisible, and no way for a reset to report a clean
session that still holds one.

**This surface is not a boundary.** The functions above are a full-power
SQL surface: a caller that can run `SELECT fractal_config_get(...)` reads
the effective value of every non-secret key, daemon-wide ones included, so the
overlay's refusals are there to keep one session from silently re-pointing
the shared daemon -- not to partition an untrusted caller from an untrusted
one. An agent-facing layer that wants a stricter line draws it itself; see the
MCP plugin's own configuration tools, which refuse the enterprise tier's keys
by name on the read path. Druid's own authorizer decides who may run SQL at
all.

**How the override reaches the plugin.** The model and THINK overrides are
published into the process environment the reasoning plugin reads, and the
plugin reads its own configuration ONCE -- when it is loaded -- and bakes it
into the loaded instance. So a tier republishes its settings (plus the
session's overrides) before every dispatch and compares a fingerprint of the
bridge environment against the one the live instance was loaded with; when
they differ, the tier reloads the plugin and the override takes effect on that
call. `t2s_max_attempts` and `t2s_use_review` are read by the engine on every
call, so those two take effect immediately.

**The cost of that.** Each tier holds ONE plugin instance, shared by every
session. Two sessions asking for different models make the tier reload the
instance between their calls. A session that overrides nothing pays nothing:
the fingerprint then matches the instance the tier already holds, and no
reload happens.

The extension's own config needs only the daemon's address: in each Druid
process that should reach the daemon, set these runtime properties to the same
socket and key (`daemon_timeout_ms` is optional):

```properties
druid.fractalsql.daemon_socket=/run/fractalsql/fractalsqld.sock
druid.fractalsql.daemon_hmac_key_file=/etc/fractalsql/hmac.key
druid.fractalsql.daemon_timeout_ms=300000
```

These are operator settings: a request's query context cannot change them.
Which Druid processes need a daemon at all, and how a multi-host cluster lays
them out, is in [Druid integration](druid-integration.md#25-where-the-daemon-runs).

## Running it as a service

- **Linux**: `packaging/common/fractalsqld.service` (installed by the
  `.deb`/`.rpm`). `systemctl status|restart fractalsqld`; logs via
  `journalctl -u fractalsqld`. `Restart=on-failure` is already set.
- **macOS**: the bundle's `install.sh` installs the files and writes the
  configuration but starts nothing. Run `fractalsqld -c <config>` under
  `launchd` (or any supervisor) with `KeepAlive` set, so it restarts on a
  crash.
- **Docker / Kubernetes**: the demo stack runs it as the `fractalsqld`
  service; on Kubernetes run it as a sidecar container in each broker pod and
  share `/run/fractalsql` through an `emptyDir` volume (see
  [Docker demo](docker-demo.md#single-host-or-multi-host)).

You don't need to do anything extra for the Druid side of this: the
extension reconnects to the daemon lazily on the next call, with no explicit
"reconnect" step and no Druid restart.

## `fsqlctl`

`fsqlctl` is a standalone control-plane CLI: it speaks the wire protocol
directly, with no Druid, no extension, and no core header — just the
protocol headers in `service/protocol/`.

```
fsqlctl [-s socket] [-k keyfile] COMMAND [ARGS...]
```

| Flag | Default | Env var |
| --- | --- | --- |
| `-s socket` | `/run/fractalsql/fractalsqld.sock` | `FSQLCTL_SOCKET` |
| `-k keyfile` | `/etc/fractalsql/hmac.key` | `FSQLCTL_KEY` |

`fsqlctl` ships in the release bundle and in the `.deb`/`.rpm` (`/usr/bin/fsqlctl`),
and builds from the service tree with `make -C service all`.

### Commands

- **`ping`** — checks that the daemon answers, prints the protocol version.
- **`version`** — prints the daemon's version string.
- **`check`** — checks the key file's permissions and the socket, then
  pings. The one command that doesn't need a working key file to start
  (it reports the problem instead of failing silently).
- **`call FUNCTION [ARG...]`** — runs any registered function and prints
  its result. Arguments are `s:TEXT` (string, also the default for a bare
  word), `i:N` (integer), `r:X` (real), or `NULL`:
  ```
  fsqlctl call fractal_vector_dims '[1,2,3]'
  fsqlctl call fractal_vector_norm '[3,4]'
  ```
- **`cancel HANDLE_ID`** — cooperatively cancels a call: an in-flight call
  that is running in-repo code (the text/CSV parsers and the analytic
  loops in the adapter layer) stops at its next loop boundary and reports
  an "interrupted" error, and the handle's next call fails with `ERR_BUSY`
  (the mark is one-shot — the following call runs normally). Code inside
  the vendored core archive can't be interrupted this way; those calls run
  to completion. Find a handle's id in the daemon's log or via
  `fsqlctl`'s `call` output.
- **`reload`** — tells the daemon to re-read its config file. The swap is
  all-or-nothing: an unparseable file or one that changes `socket_path` or
  `hmac_key_file` (both are read once by clients, so applying them live
  would strand every running Druid process) is refused and the running
  configuration stays in effect. The same is true of the provider keys
  (above): all 18 of them reload live, but the pushed value reaches the
  consumer on that tier's *next* call — a reload never attempts a plugin
  or library load itself, so a bad or changed `reasoning_plugin` /
  `enterprise_lib` path surfaces at that next call, with its path named in
  the daemon log. Removing a key from the file reverts that setting to the
  boot-environment fallback on the next call. Validation is loud and
  specific (a deliberate file edit is operator intent): an unknown key is
  a WARN that names the key; `t2s_max_attempts` outside `1`–`10`,
  `t2s_allowed_statements` anything but `select` or
  `select_insert_update`, `think_num_ctx` outside `1`–`10000000`, and
  empty values are each refused by name (the environment fallback, by
  contrast, stays
  silent-clamping, as before). Two deliberate exceptions: `enterprise_lib`
  cannot be changed live *while an enterprise library is already loaded* —
  the reload is refused with a message that names the currently loaded
  library; restart the daemon to change it (changes while nothing is
  loaded are fine and re-arm the load attempt). And
  `enterprise_ledger_path`/`enterprise_ledger_key` swap live — ledger file
  I/O opens and closes per operation, so the next ledger operation opens
  the new file — but continuity of ledger content across a path change is
  your responsibility, not something the daemon does for you. A lowered
  `max_connections` applies to new connections only.

### Exit codes

| Code | Meaning |
| --- | --- |
| `0` | Success |
| `1` | Failure reported by the daemon or the transport |
| `2` | Usage error |
| `3` | Authentication failure or the daemon closed the connection |
| `4` | Unknown function name (checked locally, before contacting the daemon) |

## Reliability

### The core guarantee

**A problem in `fractalsqld` never crashes or hangs a Druid process.** A
daemon crash, a hang, a plugin that misbehaves, an out-of-memory kill — all of
it surfaces to SQL as an error or a `NULL`, never a broker or historical
crash. The daemon is a separate process: the model round trip, the third-party
plugin and the licensed library all run there, so a provider that stalls holds
a daemon connection, not a Druid query thread's process. The extension is the
only FractalSQL code that runs inside the Druid process, and the functions it
runs itself (search, vector math, analytics) never depend on the daemon.

This is tested, not just asserted: `./build_test.sh --fault` kills a live
daemon in the middle of a call and confirms the client gets an error rather
than a hang, then confirms a restarted daemon serves again.

### What happens when fractalsqld is unreachable

| Situation | What you see | What to do |
| --- | --- | --- |
| Daemon down when a call starts | That call fails immediately with a clear error (`the daemon is not reachable`), or returns `NULL` for the SQL functions that report a missing daemon that way — not a hang, not a crash. Pure functions are unaffected | Start/restart `fractalsqld`; no Druid restart needed |
| Daemon restarts after being down | The next call after it's back up succeeds automatically | Nothing — the extension reconnects lazily, there's no explicit "reconnect" step |
| Daemon down briefly while a pure or stateful call is sent | The extension reconnects and retries the call itself (a transport failure is sent once more; a connection that went stale while idle is replaced first) | Nothing, as long as the daemon comes back quickly — the failure only surfaces if the attempts are exhausted |
| Daemon crashes mid-call | Pure functions are retried transparently; stateful ones are resent with an idempotency token and replayed, not re-executed; reasoning/embedding calls are not retried | See "Retry safety" below |
| No daemon on a host at all | The Cognition functions there return `NULL`; everything else works | Run one where your Druid processes need it (see [Druid integration](druid-integration.md#25-where-the-daemon-runs)) |

### Automatic retries and idempotency

The extension classifies every function into three retry tiers (defined in
`service/protocol/functions.def`) and handles transport failures itself,
with no application-visible error unless every attempt fails:

- **Pure functions (55)** — Vector, Dimension, Search, Portfolio, Topology
  and the read-only Analytics/ledger readers. Safe to just re-run: the
  extension retries across a fresh connection.
- **Stateful functions (15)** — Diversify control, sessions, config
  overrides, Feedback, the Enterprise ledger/audit mutators. Re-executing
  could double-write the ledger or corrupt state, so the extension resends
  *once* with an idempotency token and the daemon *replays* the
  already-computed result from its response cache instead of running the call
  a second time. The token is drawn fresh for each call and survives the
  reconnect (the cache is keyed by token, not by connection).
- **Expensive functions (4)** — `fractal_reason`, `fractal_embed` and the
  text-to-sql generation/review functions. Deterministic but costly:
  no automatic retry; the error surfaces and it's your call. The one
  exception is a pooled connection that went dead while idle and failed
  before the call was sent: the daemon never saw the call, so it is tried
  again on another connection.

The daemon's replay cache is process memory: **a daemon crash can still
lose an in-flight stateful call's answer**. In that case the statement
fails with an error and re-running it is a fresh execution — but a call
that *completed and was never answered* is always replayed, never
double-run.

### What happens to a call whose connection went away

A handle lives on the daemon side and is scoped to the connection that
created it: when that connection closes, the daemon frees the connection's
handles. The extension's connections are pooled and can be replaced at any
time — the daemon closes an idle connection, a transport failure drops it,
the daemon restarts.

Each call therefore opens its handle, makes the call and closes the handle on
one pooled connection, so no handle outlives the connection it was opened on.
A transport failure before the call was sent is retried on another
connection; one after it was sent follows the retry tiers above.

### What happens when a call runs too long

`fsqlctl cancel HANDLE_ID` (above) cooperatively stops a running call:
adapter-layer loops poll a cancellation flag at element/row boundaries and
unwind with an "interrupted" error, and the handle's next call is refused
with `ERR_BUSY`. This is best-effort by design — loops inside the vendored
core archive (the search swarm among them) run to completion — and Druid's
own query cancellation cannot reach the daemon. The extension's
`druid.fractalsql.daemon_timeout_ms` (default 300000) bounds how long a Druid
query thread waits for a reply.

### The embedding queue's own retry logic

The vectorizer's pull-based queue has its own retry mechanism, independent
of the above, because an automated pipeline can't just surface an error to
a human and wait:

- A row whose embedding call failed goes back to `pending` (not `failed`)
  with its `attempts` counter incremented and the error recorded. The next
  `process_queue` call claims it again.
- Permanent problems (permission errors, an unreadable source row, a failed
  write-back) fail the row immediately — these aren't retried, since
  trying again won't change the outcome.
- Each vectorizer has a retry budget (`options.max_attempts`, default 3).
  A row that exhausts it is marked `failed` for good. See
  [`vectorizer-setup.md`](vectorizer-setup.md) for the full configuration.

### Known limits

A few things are deliberately outside what the daemon can do, and it's
worth knowing where the boundaries are:

- **Cancellation stops at the vendored core.** `fsqlctl cancel` cooperatively
  interrupts calls running in the adapter layer (the text/CSV parsers and
  the per-element analytic loops), but calls already running inside the
  vendored core archive's own code (the search swarm among them) run to
  completion, and the cancel mark applies to whatever comes next.
- **Reload never loads, and two provider edges stay static.** Provider
  settings reload live (`fsqlctl reload` reads them from the config; see
  the `reload` command), but a reload never performs the plugin or
  enterprise-library load itself — a new or changed path is picked up on
  the tier's next call, with a failure named in the daemon log.
  `enterprise_lib` can't switch libraries while one is loaded (restart
  the daemon to change it), and `FSQL_REASONING_HTTP_RESPONSE_MODE` is
  environment-only. Druid queries stay up through any of this — the broker
  is untouched by a daemon restart.
- **A daemon crash mid-call can lose a stateful call's answer.** The
  idempotency cache lives in the daemon's memory. If the daemon crashes
  between executing a stateful call and sending its reply, that result is
  gone and the statement fails — it never double-runs (the token is drawn
  fresh for each call), but the caller sees the error and decides whether to
  re-run.
- **State is per daemon.** The session overlay and the enterprise ledger
  live in the daemon, so with a daemon on each host, each host has its own
  overlay and its own ledger chain. Chains are never merged; see
  [Enterprise Tier](enterprise.md#auditing-a-cluster-a-ledger-per-host).
