<p align="center">
  <img src="../FractalSQLforDruid.jpg" alt="FractalSQL for Apache Druid" width="720">
</p>

# Enterprise Tier — CISO Decision Audit & Quantized Ternary Ledger (QTL)

QTL is a tamper-evident audit ledger for agent and optimizer decisions. The
mechanism is described in full below.

The core FractalSQL extension (Discovery, Cognition, and Agency) works fine
on its own; none of it needs anything described on this page. This tier
exists for regulated environments that need to prove what an agent decided,
not just claim it: every optimizer call and agent decision can write a
tamper-evident record a CISO or auditor can verify, rather than a log line
they simply have to trust.

## Delivery

The ledger/audit core symbols are **enterprise-gated** in the core: they are
absent from the community sovereign archive on every platform, and
the vendor header marks them "absent from a community-compiled object". A
static link against the community archive therefore cannot resolve them at
all.

On Druid the tier is the **separately licensed FractalSQL Enterprise core**,
installed by whoever holds the licence and loaded at run time. It is *not*
part of the extension JAR and *not* part of the community drop: the
extension's native payload links only the community archive, and the
enterprise library is `dlopen`'d on first use, by `fractalsqld` (see the
[FractalSQL Daemon](fractalsql-daemon.md#provider-keys) page for its config keys).

```ini
# fractalsqld.conf, on the host that runs the daemon (beside the broker).
enterprise_lib = /opt/fractalsql/enterprise/libfractalsql-enterprise-sovereign-c.so
enterprise_ledger_path = /var/lib/fractalsql/fractalsql_ledger.dat
enterprise_ledger_key =
enterprise_require_signature = true
```

The library and the chain live with the daemon: each `fractalsqld` loads its own copy of the library and keeps its own ledger. The extension in every
Druid process that uses that daemon reaches them through it, so on a single host (the default `docker compose up`) the whole host shares one chain, and
on a cluster with a daemon per host there is **one chain per host**. See [Where the chain lives](#where-the-chain-lives) and
[Auditing a cluster](#auditing-a-cluster-a-ledger-per-host).

These are **operator settings**. A request's query context is caller-supplied,
so it cannot re-point the licensed library, name the chain's path or change
the ledger's key — the daemon refuses all four on a session's config overlay.

Without the library, every ledger-management call reports a clean
`fractalsql: enterprise tier not loaded` error. The tier is **dormant**, not
broken: the rest of the extension carries on, and the chain's own verification
still answers (see below).

### Enabling it

Put the library and its detached signature side by side where the `fractalsql`
service user can read them, and name the library in `fractalsqld.conf` with an
**absolute** path (the daemon refuses a relative one at start). The packages
keep the reasoning plugin in `/usr/lib/fractalsql-druid/fractalsqld/`, so
`/usr/lib/fractalsql-druid/fractalsqld/enterprise/` is the natural place; the
Docker image uses `/opt/fractalsql/enterprise/`, built in from
`include/<platform>/` when the pair was dropped there (see
[Docker demo](docker-demo.md#the-enterprise-tier-opt-in)).

```ini
# /etc/fractalsql/fractalsqld.conf
enterprise_lib = /usr/lib/fractalsql-druid/fractalsqld/enterprise/libfractalsql-enterprise-sovereign-c.so
```

Then apply it with `fsqlctl reload`. There is no rebuild of the extension and no
Druid restart: the library is `dlopen`'d on the next ledger call. The tier's own
status says whether it loaded:

```bash
curl -s -X POST -H 'Content-Type: application/json' \
  -d '{"action":"status"}' http://localhost:8082/fractalsql/ledger
# {"loaded": true, "library": "/usr/lib/fractalsql-druid/fractalsqld/enterprise/libfractalsql-enterprise-sovereign-c.so",
#  "ledger_path": "/var/lib/fractalsql/fractalsql_ledger.dat", "edition": "Community", "destructive_locked": false}
```

On a Community install (no library configured), every gated call answers with:

```
fractalsql: enterprise tier not loaded (fractal_ledger_flush). the QTL ledger and the CISO audit are
FractalSQL Enterprise features. Install the enterprise core library where fractalsqld runs and set
enterprise_lib in its configuration, or contact your vendor for FractalSQL Enterprise.
```

**Removing the library re-dormants the surface, with a restart.** Once a library
has loaded, its path is locked (the loaded image is the trust anchor), so deleting
or changing `enterprise_lib` and running `fsqlctl reload` is refused: the reload
fails and the running configuration stays. Restart `fractalsqld` and the gated
calls return to the *enterprise tier not loaded* error, with no recompile. The
extension and every community primitive keep working unchanged, the chain file
stays where it is, and `fractal_ledger_verify` still verifies it.

**The library must match the core the extension links.** The enterprise
core's ledger functions read the *same* `fsql_ctx` the extension's community
archive created: the context is made by the community build and handed to the
enterprise build's functions, so the two builds must agree on the context's
layout. The loader compares their `fsql_abi_version()` and refuses a library from
a different ABI line. That check catches an ABI break; it does not by itself
catch two builds from the same ABI line that differ in other ways, so the stronger
requirement is **the same core commit**: use an enterprise library built from the
commit the community archive was (`include/VERSION` names it).

### Detached signature verification (mandatory by default)

The eight-symbol link-proof check only proves a file has the right function
*names*. A tampered file with the same names sails through it untouched, so a
valid detached Ed25519 signature — a sibling `<path>.sig` file, exactly 64
raw bytes — is verified over the library's **exact bytes** against a fixed
FractalSQLabs public key before the library is loaded.

* An **invalid** signature (present but wrong) is **always refused**,
  whatever the settings say: unambiguous tamper evidence, unlike a merely
  absent file.
* A **missing** signature is refused too, unless the operator opts out with
  `enterprise_require_signature = false` **in `fractalsqld.conf`** (or
  `FRACTALSQL_ENTERPRISE_REQUIRE_SIGNATURE=0` in the daemon's environment).
  It is the operator's setting, not a session's: the daemon refuses to let a
  query's session change it.
* The **verified bytes** are what get loaded, through a private temporary
  copy — not the path, which a writer with access to the directory could
  swap between the check and the load. The bytes are re-verified after the
  load for the same reason.
* The library path is **locked** once a library has loaded: the loaded image
  is the trust anchor. Re-pointing it needs a node restart.

New enterprise releases only need a fresh signature from the same long-lived
key; the extension never needs rebuilding, which preserves the drop-in
design a hash pin would have broken.

The verification runs in `fractalsqld`, using OpenSSL's Ed25519, so the
Druid extension links no crypto library.

## The chain

The ledger is a genuine **append-only hash chain**, not a snapshot. Every
record links to its predecessor:

```
entry_hash = SHA256(prev_hash || payload || mac)
```

A rewritten record breaks the chain; a deleted record leaves the same visible
break. This holds **even without a MAC key**: `entry_hash` covers the
payload unconditionally, so a byte-flip anywhere in history is structurally
detectable, not just cryptographically.

Three files are involved:

| File | What it is |
| --- | --- |
| `<ledger>` | the chain — the authoritative store |
| `<ledger>.head` | the per-kind row counters, **outside** the chain, with its own MAC, written atomically via temp-file + rename |
| `<ledger>.csv` | a plain-text mirror of the records: a read surface, not a second source of truth |

The head file is what makes a **truncated tail visible**. The chain alone
cannot show that records were removed from its end — there is nothing after
the last record to notice its absence — but the head still says how many
records there were, and the head's own MAC says the head was not edited
either. The head is written outside the chain precisely so that whoever can
write to the chain cannot quietly rewrite the head with it.

`enterprise_ledger_key` turns on the **HMAC-SHA256
envelope**: each payload is additionally tagged, authenticating it against
forgery by anyone who does not hold the key. With no key configured, the
chain's structural integrity is still checked — only the MAC layer is
skipped. A key-configured load of a record written *without* the key is
refused rather than silently trusted.

## The functions

| Function | Purpose |
| --- | --- |
| `fractal_ledger_flush()` | Seal the core's truth + shadow ledgers into a QTL blob and append it to the chain. Returns the number of entries sealed. |
| `fractal_ledger_load()` | Rehydrate the core's ledgers from the chain's latest record (the tip is verified first, O(1)). |
| `fractal_ledger_compact()` | Compact the core's in-memory QTL representation. Returns the chain's record count. |
| `fractal_ledger_reset_soft()` | Clear the Shadow ledger; keep the Truth ledger and the epoch. Returns how many shadows went. |
| `fractal_ledger_reset_hard()` | Clear both ledgers and restart the epoch. Returns how many entries went. |
| `fractal_ledger_truth_count()` | Truth-side entry count. |
| `fractal_ledger_shadow_count()` | Shadow-side entry count. |
| `fractal_ledger_verify()` | Walk the ENTIRE chain and return a JSON audit report: `{"ok":true,"rows_verified":N}` or `{"ok":false,"first_failure_id":ID,"reason":"..."}`. |
| `fractal_audit_unpack('')` | Decode the chain's latest QTL blob into the CISO event log: one `{"epoch","doc_id","signal"}` object per entry. |
| `fractal_audit_log(type, payload)` | Append one general decision-audit record to the second chain (kind 2). |
| `fractal_lock_destructive()` | Latch the destructive operations, one way. |

**`fractal_ledger_verify` is not gated.** It reads the node's own chain
file, not the core's, so it answers on a Community deployment too: a CISO can
audit the chain whether or not the licence is installed. It is the one
enterprise function that always works.

**`fractal_audit_unpack` is decoded by the enterprise core.** The empty
argument means "the last thing the ledger sealed" — the chain's most recent
QTL blob is read and handed to the core's own unpacker. A caller that has
the blob can pass it instead.

**`fractal_audit_log`** writes to the kind=2 chain: a second, independent
append-only chain alongside kind=1's QTL blobs, with the same hash-chain and
CSV-mirror guarantees. The payload is stored verbatim as text, inside a `{"type":...,"entry":...}` wrapper.

**Locking the destructive operations.** `fractal_ledger_flush()`,
`fractal_ledger_compact()`, `fractal_ledger_reset_soft()`,
`fractal_ledger_reset_hard()` and `fractal_audit_log()` refuse once
`fractal_lock_destructive()` has been called. The latch is **one-way**: it
holds for the life of the node, and nothing in SQL clears it, so SQL that
runs later — including SQL a reasoning agent generated — cannot undo it. A
node restart does.

The latch is node-level rather than per-connection, because a Druid node has
no connection. A read-only deployment therefore sets it at startup instead of
running a statement:

```properties
druid.fractalsql.ledger.read_only=true
```

which latches the node as it starts, so the refusal does not depend on
anybody remembering to run a statement.

### Destructive operations are off by default

`FRACTAL_LEDGER_COMPACT`, `FRACTAL_LEDGER_RESET_SOFT` and `FRACTAL_LEDGER_RESET_HARD` destroy ledger records, so they refuse unless an
operator turns them on:

```properties
druid.fractalsql.ledger.allow_destructive=true
```

Without it a node nobody configured cannot have its audit chain destroyed by a query. Every attempt, allowed or refused, is written to the
node's log. `FRACTAL_LEDGER_FLUSH` (sealing the ledgers into the chain) is routine and is not affected. The read-only latch above still
wins: a latched node refuses even with the switch on. Who may run SQL at all is Druid's own authorisation to decide; restrict the
statement with Druid's authoriser wherever you enable this.

This default changed: earlier builds allowed these operations unless the node was latched.

## The multimodal portfolio

`fractal_optimize_portfolio_multimodal(mu, cov, k)` runs several independent
restarts and returns up to `n_restarts` structurally distinct portfolios
instead of one: candidates within `quality_frac` of the best Sharpe found,
no two sharing more than `overlap_threshold` of their assets. Same entropy
engine as the single-best version.

`fractal_optimize_portfolio_multimodal_pareto(mu, cov, k)` is the
Pareto-front sibling: the same independent searches, but each scored by
decomposed **return/risk** instead of scalar Sharpe and reduced to a genuine
non-dominated Pareto front (NSGA-II crowding-distance truncation past
`max_front`).

`fractal_optimize_portfolio_multimodal_ex(mu, cov, k, obl, diffusion)` is
the sibling carrying the OBL / Lévy-flight knobs: `use_obl` (Opposition-Based
Learning — evaluate each SFS trial candidate's bound-reflected opposite and
keep whichever fits better) and `diffusion_mode` (a heavy-tailed
Mantegna-algorithm step that can help escape local optima on highly
multimodal problems).

All three are **enterprise-gated**: their core symbols ship only in the
licensed enterprise core, so they report that the tier is not loaded without
one. They are *optional* symbols in that library, so an enterprise build
without them still loads for the ledger surface — and these three then say
so, distinctly, rather than reporting a missing tier.

The trailing arguments take the documented defaults: eight restarts,
an overlap threshold of 0.15, a quality fraction of 0.90, and a Pareto front
of eight points.

## Where the chain lives

The ledger is a file on the host that runs `fractalsqld`, one per daemon. Druid itself cannot hold it: its
segments are immutable and it has no synchronous per-row write. Protect the file, its backups and its
volume as you would the data it describes. The ledger key and the enterprise library stay with the daemon,
outside the analytical tier's backups and deep storage.

How many chains you have follows from where the daemons run (see
[Druid integration](druid-integration.md#25-where-the-daemon-runs)):

| Layout | Ledgers | Audit it with |
| --- | --- | --- |
| **Single host** (`docker compose up`) | One chain, shared by every Druid process on the host | `fractal_ledger_verify`, plus `fractalsql-ledger-collect` for an off-host copy |
| **Multi-host** (`--profile multihost`; in production, a daemon on each host) | One chain per host, never merged | Collect every host's chain into one audit store and check it ([below](#auditing-a-cluster-a-ledger-per-host)) |

A call is recorded by the daemon behind the broker that served it, so a ledger call made as SQL through the
router lands in whichever broker's chain handled the query. The cluster's complete record is the set of
per-host chains.

## External anchoring (closing the truncation gap)

The chain shows that nothing in the middle was altered or removed, but not that the end was not cut off.
The head file covers most of that. Publishing the head hash outside the node covers the rest.

With `FSQL_LEDGER_ANCHOR_LOG=stderr` (or `syslog`), the daemon writes one JSON line per append:

```json
{"event":"ledger_head","kind":1,"rows":17,"hash":"<hex of the newest entry hash>"}
```

A chain with its tail deleted no longer matches the last line published. Send the log to a collector that
the node cannot rewrite, and keep it as long as your audit window.

## Data at rest

The chain and its head file are created owner-only (`0600`) in a `0700` directory. The head is a separate
file with its own MAC, so deleting the tail of the chain is detectable.

An audit entry carries what the agents were asked and what they produced: the question, the generated SQL
with its literals, the analysis and the rows read. That text can hold customer data. `FSQL_AUDIT_REDACT`
sets what the chain keeps:

| `FSQL_AUDIT_REDACT` | What is stored |
| --- | --- |
| `none` (default) | The text as it is. |
| `hash` | `sha256:<hex> len=<bytes>`: equal texts stay comparable, the text itself is not kept. |
| `truncate` | The first 64 characters. |

Redaction applies to nested fields too. Identifiers, counts, statuses and the attribution block are stored
unchanged. It does not encrypt anything: use volume encryption and file permissions for the file itself.
The MAC key is the `enterprise_ledger_key` you already set. The anchor log publishes only a hash of the
head, never the key or entry contents.

## Auditing a cluster: a ledger per host

Each `fractalsqld` keeps its own ledger (the chain, its `.head` file and its `.csv` mirror) at
`enterprise_ledger_path`. Chains are not merged, because merging would break the tamper-evidence of each.
Each one is verified where it lives, and a copy is kept off the host with two tools shipped in the bundle,
the `.deb` and the `.rpm`.

**1. Collect, on every daemon host.** Run `fractalsql-ledger-collect` as the daemon's user, on a schedule:

```bash
fractalsql-ledger-collect --dest /mnt/audit-store
# stored /mnt/audit-store/druid-broker-1/20261113T220135Z  (kind1 rows: 1, kind2 rows: 17)
```

Each run has the daemon verify both chains, copies the ledger, head and mirror, and retries if the chain
changed during the copy. It then writes a `MANIFEST.json` and `SHA256SUMS` and files the snapshot under
`<dest>/<host>/<UTC time>/`. It never overwrites a snapshot and never writes to the ledger. The host name
defaults to the hostname (`--host-id`), and the socket, key file and ledger path come from
`/etc/fractalsql/fractalsqld.conf` (`--conf` to change that).

Exit status is `0` for a verified snapshot, `3` when a chain does not verify, and `1` for an error. A chain
that fails verification is still copied, since the copy is the evidence. Alert on `3`:

```
*/15 * * * *  fractalsql  fractalsql-ledger-collect --dest /mnt/audit-store
```

**2. Check, anywhere.** `fractalsql-ledger-check` re-checks a store or one snapshot, with no daemon and no
key:

```bash
fractalsql-ledger-check /mnt/audit-store
# ok    druid-broker-1/20261113T220135Z  18 record(s): kind 1: 1, kind 2: 17
# ok    druid-broker-2/20261113T220133Z  7 record(s): kind 2: 7
```

For each snapshot it checks that the files match `SHA256SUMS`, that the daemon reported both chains
verified, that every record's hash links to the previous one, that the head's row counts match the chain,
and that the CSV mirror agrees. Across a host's snapshots it checks that the history only grew: each chain
must begin, byte for byte, with the one before it.

**What this proves.** Record MACs need the ledger key, which stays on the host, so the daemon checks them
there and the manifest records its verdict. The offline check proves structure, linkage, completeness
against the head and growth between snapshots. Someone who can rewrite both a chain and its head could
fool one snapshot, but not an earlier one, which would no longer match. So keep the audit store out of the
hosts' reach: give hosts write-only access (object-lock or WORM storage, or a separate account). Snapshots
are full copies, so keep each host's oldest and prune the rest deliberately.

A host that stops delivering snapshots leaves a gap in the store's timestamps. The checker does not alert
on a missing snapshot, so watch the collect job's exit status.

---

For enterprise editions, licensing, and support, contact
**enterprise@fractalsqlabs.com**.
