<p align="center">
  <img src="../FractalSQLforDruid.jpg" alt="FractalSQL for Apache Druid" width="720">
</p>

# Druid integration: design and limits

How FractalSQL fits into Apache Druid, which parts are SQL expressions and
which are service calls, and the Druid constraints behind those choices.

---

## 1. What is in the box

| Piece | What it is | Where |
| --- | --- | --- |
| Extension JAR (Maven, Java 17 bytecode) | Registers the `fractal_*` functions and the extension's HTTP endpoints in Druid | `druid-extension/` |
| JNI shim | Links the pure-C FractalSQL core into the Druid process, one payload per platform | `druid-extension/src/main/native/` |
| `fractalsqld` | The daemon that holds the reasoning, embedding and ledger tiers and the session settings. Both a C and a JVM build exist; the JVM build is the one the packages and the container image ship. | `service/` |
| MCP server | A C++ server that exposes 108 tools over Druid's SQL API and the extension's endpoints | `mcp/` |
| Demo stack | ZooKeeper, coordinator (also the overlord), broker, historical, middle manager, router and `fractalsqld` in Docker | `docker/` |
| Demo runner | Druid's client for the demo suite, since Druid has no command-line SQL client | `demo/run_demo.py` |

The core in `include/` is linked, never edited and never rebuilt.

### 1.1 The function surface

The SQL surface is 68 functions, registered in `FractalFn.java`:

| Tier | Functions | Count |
| --- | --- | --- |
| Analytics | `fractal_dimension_*`, `fractal_change_point_detect`, `fractal_periodogram`, `fractal_spectrogram_entropy`, `fractal_morphological_complexity`, the portfolio family, the TDA and morphology functions | see [api-analytics.md](api-analytics.md) |
| Vector | `fractal_vector`, `fractal_vector_from_text`, `fractal_vector_to_json`, the distances, norms, quantizers and arithmetic | see [api-discovery.md](api-discovery.md) |
| The node itself | `fractal_edition`, `fractal_version` | 2 |
| Cognition | `fractal_reason`, `fractal_embed` | 2 |
| JSON accessors | `fractal_json_value`, `fractal_json_text` | 2 |
| Config / session | `fractal_config_set`, `fractal_config_get`, `fractal_config_reset`, `fractal_config_list`, `fractal_config_keys` | 5 |
| Enterprise (gated) | `fractal_ledger_*`, `fractal_audit_log`, the multimodal portfolio functions | see [enterprise.md](enterprise.md) |

The enterprise functions are registered on every build. On a Community
deployment the gated ones report that the tier is not loaded;
`fractal_ledger_verify` still answers, because it reads the node's own chain
file rather than the core's. The multimodal portfolio functions are gated
too: their core symbols are not in the Community archive.

A vector argument is a Druid `ARRAY` column or the core's text form; a
vector result is the text form (see 3.3).

`fractal_search_distance` sits outside that table. It scans a column as a corpus, so
it is an aggregate, not a per-row expression.

---

## 2. Where each tier lives

A function goes on the **SQL** surface only if it is pure, a per-row or
per-group computation over data Druid already has, and callable without
running another query and without an unbounded external call. Everything
else goes to the **daemon** (`fractalsqld`) or the **service** (the
extension's HTTP endpoints), and reaches users through the **MCP tools**.

| Tier | Functions | Lives in | Why not SQL |
| --- | --- | --- | --- |
| Cognition | `fractal_reason`, `fractal_embed` | **daemon** (called from SQL) | A model round trip has unbounded latency; it must not hold a Druid query thread. |
| Cognition | text-to-SQL, schema context | **service** | It has to read `INFORMATION_SCHEMA` and validate a candidate statement, and a Druid SQL function cannot issue another query. |
| Agency | the installable `fractal_agent_*` agents | **service** | Each one runs its own SQL against a caller-named table, then reasons, then emits a decision document. |
| Enterprise | `fractal_ledger_*`, `fractal_audit_*` | **daemon** | The chain's tamper-evidence is established at write time, over an append-only local file, not in an immutable columnar store. |
| Vectorizer | `fractal_vectorizer_*` | **service** | Druid has no triggers and no temporary tables; the embedding is a poll plus an MSQ write. |
| Config / session | `fractal_diversify_*`, `fractal_feedback_report`, `fractal_explain_result`, `fractal_detect_collapse` | **daemon** (per-session overlay) | Session state about a conversation. |

### 2.1 The function registry

`service/protocol/functions.def` is the single source of truth for the
callable surface. Each row carries a result kind (`STR`, `INT`, `REAL`) and a
retry class (`r` pure, `s` stateful, `e` provider round trip). The retry
class decides the surface: every `r` function is a candidate for SQL, and no
`s` or `e` function is.

The extension's registry is checked against it by `FunctionRegistryTest`, which
runs with the extension's unit tests. A few consequences:

- `fractal_vector_dims` and `fractal_vector_hamming_distance` are `BIGINT`.
- `fractal_state_fingerprint` returns the fingerprint as **hex text**. The
  Hamming distance between two states is `fractal_state_distance`.
- `fractal_optimize_portfolio_ex(mu, cov, k, obl, diffusion)` is the form with the core's own knobs (`use_obl`, the
  diffusion mode). A Druid native function has a fixed arity, so those knobs are a second function and
  `fractal_optimize_portfolio(mu, cov, k)` stays as it is.
- `fractal_json_value` and `fractal_json_text` read fields out of a returned JSON document: Druid's
  own `JSON_VALUE` reads a COMPLEX column, not the JSON string these
  functions return.

The few functions with no Druid shape are listed under
[Known limits](#5-known-limits).

### 2.2 The agency tier

The composite agents are a service tier: an agent reads a table, computes an
analytic, reasons about the result and emits a decision document. A Druid SQL
function can do none of the first two, since it has no connection, so the
agents are HTTP operations on the extension:

```bash
curl -s -X POST -H 'Content-Type: application/json' \
  --data-binary '{"proposed_table":"sessions","state_column":"vec",
                  "history_table":"known","emb_column":"vec","threshold":0.1}' \
  http://localhost:8082/fractalsql/agent/outlier_screen
```

The demo suite calls them with a directive, and can materialise the result
so a later statement can query it:

```sql
-- @call agent/outlier_screen {...} AS oif_screen;
SELECT "id", "intercepted" FROM "oif_screen";
```

### 2.3 Corpus searches

The searches that read a table are service operations, for the same reason:

| Endpoint | What it does |
| --- | --- |
| `POST /fractalsql/search/explore` | Scout's diversity-first population over a corpus |
| `POST /fractalsql/search/telemetry` | The exact nearest rows |
| `POST /fractalsql/search/trajectory` | The nearest rows to a movement (current minus baseline) |
| `POST /fractalsql/search/hybrid` | The nearest rows within a cohort |
| `POST /fractalsql/search/cross-modal` | A query that blends two vectors |
| `POST /fractalsql/boxcount` | The box-counting dimension of a cloud of points |

The box counter is a service call for a second reason: as a SQL expression it
runs once per row of the group, so a few hundred points would be minutes of
core time on a data node. Here it runs once per cloud.

### 2.4 Configuration and sessions

```sql
SELECT fractal_config_set('think.level', 'deep', 'my-session');
SELECT fractal_config_get('think.level', 'my-session');
SELECT fractal_config_list('my-session');
SELECT fractal_config_reset('my-session');
SELECT fractal_config_keys();
```

- **The session id is an argument.** A Druid query has no connection to hang
  a session on, and the query context is per-request, so the caller names the
  session it is speaking for.
- **The overlay lives in `fractalsqld`**, so one overlay serves the cluster.
- **Only the tuning keys may be set.** The operator's settings (the provider
  URL, the reasoning plugin, the ledger key, the credentials) are refused,
  because the session id and the query context are both caller-supplied and a
  caller must not be able to re-point the model or read the secrets. A secret
  reads back as `<redacted>`. The allow/deny split is in `FractalSqlConfig`.

### 2.5 Where the daemon runs

The daemon's config file, its `fsqlctl` CLI and its failure behaviour are in the
[FractalSQL Daemon](fractalsql-daemon.md) page.

`fractalsqld` listens on a **Unix socket**, so it runs on the same host as the Druid processes that call
it. There is no TCP mode: the socket is limited by peer credentials, and nothing listens on the network.

**Which processes call it.** The extension is loaded into every Druid process in `loadList`, but only a
few of them reach for the daemon:

| Process | Needs a daemon when |
| --- | --- |
| **Broker** | Always, if you use reasoning, embedding, text-to-SQL, the agents, the vectorizer or the enterprise tier. The SQL planner and the `/fractalsql` endpoints are here. This is where to run it. |
| **Historical** | Only if a query pushes `fractal_reason` or `fractal_embed` down to it. The analytic and vector functions run in-process and need no daemon. |
| **MiddleManager / Indexer** | Only if your own ingestion SQL calls `fractal_embed` or `fractal_reason` per row. The vectorizer does not: it embeds on the broker and submits the finished vectors in the `INSERT`. |
| **Coordinator, Overlord, Router** | No. They plan no queries. |

With no daemon on a host, the Cognition functions there return `NULL` and everything else works.

**Layouts.**

- **Single host.** One daemon, and every Druid process on the host shares its socket directory. This is
  what `docker compose up` runs.
- **Multi-host.** A daemon on each host whose Druid processes call it, normally each broker. Give every
  daemon the same provider settings in `fractalsqld.conf`; each host has its own `hmac.key`, which only
  its own Druid processes need to read. On Kubernetes, run it as a sidecar container in the broker pod and
  share `/run/fractalsql` through an `emptyDir` volume. `docker compose --profile multihost up -d` runs
  this layout with two brokers (see [Docker demo](docker-demo.md#single-host-or-multi-host)).

**State is per daemon.** The session overlay and the enterprise ledger live in the daemon. With a daemon
per host, each host has its own overlay and its own ledger chain.

**Ledgers.** A ledger is an append-only HMAC hash chain in a local file (`enterprise_ledger_path`). It is
not merged across daemons: merging would break the property that makes it tamper-evident, and Druid's
immutable segments cannot hold an append-only chain. So neither a coordinator nor a historical collects
them. A single-host stack has one chain. A cluster with a daemon per host has one chain per host, and its
audit evidence is the set of them: verify each chain on its own host and copy it to an audit store with
`fractalsql-ledger-collect`, then re-check the store anywhere with `fractalsql-ledger-check`. The
workflow is in [Enterprise Tier](enterprise.md#auditing-a-cluster-a-ledger-per-host).

---

## 3. Druid constraints that shape the design

### 3.1 Two shapes

Druid's SQL layer has no hook for a custom scalar function except a native
expression: a registered `ExprMacro` whose `Expr` evaluates per row and can be
pushed to the data nodes. So the extension has two shapes, and they are not
interchangeable:

| | Native expression | Druid aggregate |
| --- | --- | --- |
| Used for | the registered functions | `fractal_search_distance` |
| Evaluated | per row, in the projection | once per group |
| Needs a `GROUP BY` | no | yes |
| `ORDER BY` on the result | works directly | works (it is an aggregate over a grouping key) |
| Reads a column | one row's value | the whole column, as a corpus |

The aggregate is the only shape that can scan a column as a corpus.

### 3.2 Two SQL rules that shape the queries

Both are about the aggregating / non-aggregating split, and both hold on
Druid 38:

- **In an aggregating query, every projected column must be a grouping
  key.** `SELECT "id", fractal_vector_norm("emb") FROM t GROUP BY "id"` is
  rejected with "Expression 'emb' is not being grouped". The column has to
  join the grouping keys: `GROUP BY "id", "emb"`. With a unique row identity
  that is still one group per row.
- **In a non-aggregating query, `ORDER BY` is restricted to `__time`.**
  Ordering by a computed value is rejected with "requires ordering a table by
  non-time column", and a subquery does not help, since the restriction is on
  the scan.

So: rank with an aggregate (`fractal_search_distance` is the aggregate for this
reason), and compute per row with a native expression.

### 3.3 Vectors travel as text

Druid 38 cannot carry an `ARRAY` out of a native expression. Projecting one
fails inside the expression layer with

```
Cannot invoke "org.apache.druid.math.expr.ExpressionType.getType()" because "castTo" is null
```

The same failure happens when an `ARRAY`-producing expression is another
function's argument. So the vector functions use the core's text form as
their interchange format:

| Direction | Form |
| --- | --- |
| A vector argument | a Druid `ARRAY` column, or the text form: CSV (`'1.0,0.5,-0.25'`) or bracketed JSON (`'[1.0,0.5,-0.25]'`) |
| A vector result | the text form: `'[1.0,0.5,-0.25]'` |

An `ARRAY` column still works as an input, so the storage model is
unchanged; only the wire form is text. `JSON_VALUE` reads the fields back:

```sql
SELECT JSON_VALUE(fractal_vector_normalize("emb"), '$[0]') AS "first"
FROM "demo_vecs" GROUP BY "id", "emb";
```

### 3.4 The service tier

The operations that cannot be SQL functions live on the extension's own HTTP
endpoints, registered with Druid's documented Jersey binding
(`Jerseys.addResource(binder, FractalSqlResource.class)`), the same mechanism
Druid's own extensions use.

| Endpoint | What it is |
| --- | --- |
| `GET /fractalsql/health` | The extension's state: functions registered, whether a provider is configured, and the operator's configuration with credentials redacted |
| `POST /fractalsql/reason` | The provider's answer to a question: the **chat context** |
| `POST /fractalsql/review` | A candidate judged against the request that produced it: the **review context** |
| `POST /fractalsql/embed` | The provider's embedding of a text: the **embed context** |
| `GET /fractalsql/schema-context?datasource=` | A datasource's columns, read from `INFORMATION_SCHEMA` |

The reasoning tier runs through four independent contexts (chat,
text-to-SQL, review and embed), each with its own response mode. Only the
chat context's mode is the operator's to choose
(`FSQL_REASONING_HTTP_RESPONSE_MODE` in the `fractalsqld` environment: `text`
by default, `code` or `json`). The other three are fixed to what they are
for. The `/text-to-sql` endpoint and the statement-generating agents run on
the text-to-SQL context, so the answer arrives as a bare statement rather
than as prose with the statement buried in it.

The service reaches SQL by asking its own node's SQL endpoint over loopback:
Druid's `SqlEngine` is a planner factory, not a query runner, so there is no
in-process "run this query" API on the extension surface. That is a bounded
risk (the broker's worker pool needs a spare thread), and it is why the
reasoning and ledger tiers run in the daemon, not in the broker.

### 3.5 The registry is the contract

`FractalFn.java` fixes, for every function, its SQL name, the shape of its
arguments, where each argument lands in the native call, and what it returns.
The Calcite binding, the native-expression macro and the JNI dispatcher are
generated from it or checked against it, so the three cannot drift. The unit
tests assert that the registry and the native table agree on the function
ids: a mismatch there would read the wrong core function silently, which is
the worst failure mode this design has.

---

## 4. Storage and identity

- **Row identity.** Druid has no `rowid`. Searches that return rows key them
  on an ingested identity column (or `__time` plus one).
- **The vector type.** Druid has no BLOB column type, so a stored vector is
  an `ARRAY` column of numbers or the core's text form (CSV or bracketed
  JSON), and every vector argument accepts either. `fractal_vector_from_text`
  converts text into the canonical text form, so a query vector need not be
  a column.
- **Array ingestion.** A Druid `ARRAY` column of numbers needs
  `arrayIngestMode: "array"` on ingestion; the default (`"mvd"`) only carries
  `ARRAY<STRING>`.
- **The ledger.** The tamper-evident chain is a file-backed log in
  `fractalsqld`, with a head counter file and a CSV mirror. An analytical
  columnar store is the wrong home for an audit log, and the chain living in
  the daemon means each daemon keeps its own ledger (one per host in a multi-host cluster). The enterprise core, loaded
  at run time after its detached Ed25519 signature has been verified, owns
  the encoding and the truth/shadow semantics. See [enterprise.md](enterprise.md).
- **The enterprise core's drop.** The licensed library is a per-platform
  binary, supplied by whoever holds the licence and never vendored in the
  repository. It must come from the same core commit as the community archive
  (`include/VERSION`), and goes beside it in `include/<platform>/` for a build
  that should carry it, or anywhere the daemon can read it (see
  [enterprise.md](enterprise.md#enabling-it)). A Community deployment needs none
  of it: the tier is dormant, and `fractal_ledger_verify` still answers.

---

## 5. Known limits

- **Multi-row groups.** `GROUP BY "id"` (one group per row) works for the
  `fractal_search_distance` aggregate. `GROUP BY "grp"` (several rows per group)
  returns the value the group's slot was initialised to: Druid's GroupBy
  engine does not fold a group's rows for that aggregator factory, even
  though the combining factory and combiner are both provided. The native
  expressions are not affected; they are per row by construction.
- **Variadic functions.** Some functions take several arities, including the
  agents. Calcite has no variadic scalar operator, so each arity is its own
  overload.
- **Return types.** About thirty functions return a JSON document, because
  there is no array or struct type to return. They keep the JSON document (as
  `VARCHAR`); `JSON_VALUE` and `fractal_json_value` read the fields back.
- **The core's input constraints apply unchanged.** For example,
  `fractal_dimension_drift` needs a window of at least 24 samples and at
  least twice that many samples in the series, even though the header in
  `include/fractalsql_sql.h` says "window >= 16". A core error surfaces as
  `NaN` in a numeric result and as `null` in a JSON document.
- **Functions with no Druid shape.** `fractal_vector_from_float8_array` and
  `fractal_vector_to_float8_array` are not available: Druid has no float8-array
  type.
- **The feature store is a datasource.** A Druid segment is immutable, so
  `fractal_store_morphology` appends a row to the `fractalsql_feature_store`
  datasource with an MSQ write, and the newest row of a `doc_id` is its vector.
  `fractal_mine_topology_negatives` reads the datasource back and ranks it. A
  write takes as long as an MSQ task, so use it for curated examples, not for a
  stream of vectors.
- **Version lock.** The extension's SPI and SQL bridge use Druid internal
  APIs (`SqlBindings`, `SqlOperatorConversion`, `ExprMacroTable`,
  `ExpressionModule.addExprMacro`), which carry no versioning guarantee. The
  extension is built against Druid 38 and tested on Druid 37 and 38.

---

## 6. Writing a demo kit for Druid

A kit is a `.sql` file that `demo/run_demo.py` runs. The runner splits the
file into statements, submits writes as MSQ tasks and waits for them, runs
reads against the SQL endpoint, prints results tab-separated with no header,
and carries on past a failed statement (the exit status is non-zero if any
failed). The dialect differences a kit has to respect:

| Instead of | Use |
| --- | --- |
| `CREATE TABLE` + `INSERT` | `REPLACE INTO ... OVERWRITE ALL SELECT ... PARTITIONED BY ALL`, or an `@fixture` directive |
| a recursive CTE | `UNNEST(ARRAY[...]) AS t(g)`, or rows computed ahead of time |
| `random()` | a deterministic fixture (the kits use a sin-hash) |
| `%` (modulo) | `MOD(x, y)`: the percent operator is not allowed under Druid's conformance level |
| `json_extract(doc, '$.f')` | `fractal_json_value(doc, '$.f')` |
| `group_concat(x, ',')` | `STRING_AGG(x, ',')` |
| `datetime('now')` | `CURRENT_TIMESTAMP` |
| a window function | an aggregate, or a fixture whose rows carry the running value |

Two shape rules follow from the constraints above:

- A series is an `ARRAY` column in one row, not one row per reading. The
  per-row functions take it directly.
- Ordering is an aggregation. `ORDER BY` on a non-aggregating query is
  restricted to `__time`, so a kit that wants a stable order groups by the
  key and orders by the grouping key.

Every kit ends with a `HEADLINE kit=... ok` line computed from its own
results, and exits non-zero unless the result holds.

---

## 7. Platforms

Druid runs on Linux and macOS, on x86-64 and ARM64. The
extension JAR carries a native payload for each of those four platforms and
loads the one that matches the JVM:

| Platform | Payload |
| --- | --- |
| Linux x86-64 | `linux-x86_64` |
| Linux ARM64 | `linux-aarch64` |
| macOS Intel | `darwin-x86_64` |
| macOS Apple Silicon | `darwin-arm64` |

The release workflow builds and tests each payload on its own platform and
assembles them into one JAR. The cluster gates need Docker and run on Linux.

---

## 8. The demo stack

`docker/docker-compose.yml` runs the micro-quickstart topology as seven
containers (the six Druid services and `fractalsqld`), because
`apache/druid:38` is distroless: no `curl`, no `perl` and no `/usr/bin/env`,
so the image's own single-container launcher cannot run in it. The services
are started the way the image's supervise config starts them, one container
each:

```
bin/run-druid <service> conf/druid/single-server/micro-quickstart
```

Two things matter in a multi-container stack:

- `druid.host` must not be shared as `localhost`: every node would advertise
  itself as localhost and peers would dial themselves.
- `druid.zk.service.host` must be the ZooKeeper service name.

The extension JAR is mounted into the extensions directory as a directory
named after the extension, because Druid treats each `loadList` entry as a
directory and scans it for `*.jar`.
