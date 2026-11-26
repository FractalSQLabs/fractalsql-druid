<p align="center">
  <img src="../FractalSQLforDruid.jpg" alt="FractalSQL for Apache Druid" width="720">
</p>

# Discovery API Reference

The Discovery tier provides high-precision and diverse retrieval mechanisms. Unlike traditional vector search, it treats the embedding space as a continuous optimization problem.

> **Conventions for this page.** A vector argument is a Druid `ARRAY` column of
> numbers or its text form: a CSV string (`'0.6,0.8,0.0,0.0'`) or a bracketed
> JSON array. Druid has no BLOB type. A function that returns a document
> returns it as TEXT (JSON); a Druid scalar expression cannot return a set, so
> per-row results are JSON arrays in result order. The searches that read a
> whole datasource (`telemetry`, `hybrid`, `trajectory`, `cross-modal`) are
> service operations, not SQL functions; see
> [Druid integration](druid-integration.md#23-corpus-searches). All functions
> register when Druid loads the extension: no separate install or activation step.

---

## `fractal_search_distance`
**Per-row distance (Druid)**

The aggregate form of the convergence: for each stored vector it converges toward the query over the unit box $[-1, 1]^d$ and returns the cosine distance, so it scores rows in an `ORDER BY ... LIMIT k`. It is **not** the Sniper: the Sniper is [`fractal_sfs_converge`](#fractal_sfs_converge), the table-free convergence function that is the same on every FractalSQL host. This per-row form exists on Druid because a Calcite operator cannot carry two operators with one name.

> **Renamed.** This aggregate was called `fractal_search` until the
> indexed search took that name. `fractal_search` is now the **indexed
> search** (below); there is no alias. A Calcite operator cannot carry two
> operators with one name, so the aggregate moved to `fractal_search_distance`.

### Signature
```sql
fractal_search_distance(
    vector  ARRAY-or-TEXT,   -- stored vector (an ARRAY column, or CSV/JSON text)
    query   ARRAY-or-TEXT    -- the target vector to converge toward
) RETURNS REAL
```

### Arguments
| Argument | Type | Default | Range | Description |
| --- | --- | --- | --- | --- |
| `vector` | ARRAY / TEXT | (Required) | — | The stored vector to score. |
| `query` | ARRAY / TEXT | (Required) | — | The target vector to converge toward. |

*Druid difference:* the `iterations` / `population_size` / `diffusion_factor` tuning arguments are fixed at their SFS defaults here (`fractal_search_distance` is a per-row scalar run once per distinct query per scan). Use `fractal_sfs_converge_debug(query, ...)` when you need the tunable form.

`iterations` x `population_size` x `diffusion_factor` x the vector length must not exceed 2,147,483,648 (about a minute of work) in one call; each limit is checked on its own and then their product, and a larger search is refused.

### Query-Vector Dimension Limit
The query vector may carry up to **16,384 dimensions**: the shared core library's `FSQL_MAX_DIM`, and the limit that fires (`exceeds FSQL_MAX_DIM`). A query beyond that is rejected.

`fractal_sfs_converge_debug` and `fractal_search_explore` take the same query and share the same limit.

---

## `fractal_search` (the indexed search)
**Native IVF index**

The indexed search: an inverted-file index over the datasource's vectors,
built and searched by the shared core's IVF maths. It reads the index's
cells instead of the whole datasource, and **every distance it returns is
verified** before it leaves the extension.

### Signature
```sql
fractal_search(
    table     TEXT,      -- the datasource the index covers
    column    TEXT,      -- its vector column
    query     ARRAY-or-TEXT,
    k         INTEGER DEFAULT 10,
    options   TEXT DEFAULT ''   -- JSON object; '' means the defaults
) RETURNS TEXT (JSON)
```

> **Druid difference (arity).** A Calcite operator has a fixed arity, so the
> trailing `options` argument cannot be omitted here: pass `''` for the
> defaults. The other hosts take it optionally.

> **Druid difference (where it runs).** The index's operations read a
> datasource and (for a build) write one, and a Druid SQL function cannot
> issue the queries and the MSQ writes they need. The service operation
> `POST /fractalsql/index` (`{"action":"search", ...}`) is the operation to
> use from a client; the SQL form is here so the names are the same
> everywhere a FractalSQL host computes one.

### Options (JSON keys of `options`)
| Key | Type | Default | Description |
| --- | --- | --- | --- |
| `index` | `string` | the index over (table, column) | Which index to search. |
| `nprobe` | `int` | `8` | How many cells to probe. More cells: more recall, more rows read. |
| `rerank` | `int` | `30` | The shortlist: the candidates the index returns for the verification. |
| `verify` | `int` | `1` | Verify every candidate (on by default; the index never returns an unverified distance). |

### Returns
A JSON document with:
- `candidates`: `[{"doc_id": <the row's id>, "distance": <the verified distance>}]`, at most `k` of them.
- `rows_scanned`: **the number of rows the index read.** This is the
  "index actually used" statistic: it is far below the datasource's row
  count, and a search that silently ran flat is visible here.
- `cells_probed`, `cells_missing`: the cells the search touched.
- `verified`: `1` when every returned candidate was verified.
- `precision`: `"fp16"` — see below.
- `indexed_rows`: the rows the index covers.

### The distances are exact to FP16 precision
Druid has **no cheap fetch by id**: filtering on a BIGINT id scans
segments. So the vector a candidate needs in order to be verified is stored
**inside the index**: every cell row carries the row's codes *and* an FP16
copy of its vector. The verification therefore needs no fetch at all, and
the distances are exact to **FP16** precision, not FP32. The exact
float32 distances are what `fractal_search_telemetry` returns.

### The indexed search does not apply Diversify repulsion
The Diversify layer's repulsion is a stateful, per-session filter over the
results of a *scan*; the indexed search returns the index's own verified
neighbours and does **not** apply it. Use `fractal_search_telemetry` (or
Scout, `fractal_search_explore`) when the diversity layer matters.

### When there is no index
With no index over the datasource, the search falls back to an exact scan
and says so (`indexed_rows` absent, and the fallback is reported).

---

## The index: `fractal_index_create` and friends

### Signatures
```sql
fractal_index_create(table TEXT, column TEXT, options TEXT DEFAULT '') RETURNS TEXT (JSON)
fractal_index_rebuild(name TEXT, options TEXT DEFAULT '')              RETURNS TEXT (JSON)
fractal_index_refresh(name TEXT)                                       RETURNS TEXT (JSON)
fractal_index_ensure(table TEXT, column TEXT, options TEXT DEFAULT '') RETURNS TEXT (JSON)
fractal_index_drop(name TEXT)                                          RETURNS TEXT (JSON)
fractal_index_info(name TEXT)                                          RETURNS TEXT (JSON)
fractal_index_list()                                                   RETURNS TEXT (JSON)
fractal_index_candidates(table TEXT, column TEXT, query ARRAY-or-TEXT,
                         options TEXT DEFAULT '')                      RETURNS TEXT (JSON)
```

### `fractal_index_create` options
| Key | Type | Default | Description |
| --- | --- | --- | --- |
| `name` | `string` | `<table>_<column>_index` | The index's name. |
| `id_col` | `string` | (none) | The column naming each row. When it is not numeric the row's scan position is the id (Druid has no row locator). |
| `vector_format` | `string` | `INT8` | `INT8`, `INT4`, `FP16` or `FP32`. |
| `nlist` | `int` | `0` (sqrt of the rows) | The number of cells. |
| `pca_dim` | `int` | `0` (dim/4) | The PCA basis (INT8/INT4 only). |
| `iters` | `int` | `0` (6) | The k-means iterations. |
| `sample` | `int` | `0` (50000) | The training sample size. |
| `seed` | `int` | `1` | The seed: the same corpus and the same seed give the same index. |
| `index_table` | `string` | `<name>_cells` | The companion datasource the cells are written to. |

### How the index is stored on Druid
Druid has no DDL and no DML: a Druid SQL query is read-only, and a value
reaches a datasource through an MSQ `INSERT` task. So the index's cells
live in a **companion datasource** (`<name>_cells` by default), written
with an MSQ `INSERT` -- the same precedent the vectorizer's companion
datasource sets. A cell row carries the index name, the generation, the
cell number, the row id, the row's codes (hex) and the row's FP16 vector
(hex).

Because a Druid datasource cannot be rewritten and Druid has no `DELETE`,
`fractal_index_drop` marks the index dropped: the cells stay in the
companion datasource and are ignored. Replace the datasource to reclaim
the space.

### `fractal_index_info`
The index's shape (`dim`, `format`, `nlist`, `code_bytes`), the rows it
covers, whether it is **stale** (the source datasource's row count against
the indexed one), `rows_added_since_build` (also `delta_rows`) and
`rows_deleted_since_build`, a **status** and the **advice** that goes with it:

| Status | Meaning | What to do |
| --- | --- | --- |
| `ready` | The index covers the datasource. | Nothing. |
| `stale` | Rows were added since the build, or more than 20% were deleted. | The advice says which: `fractal_index_refresh` while the added rows are up to a quarter of the index, otherwise `fractal_index_rebuild`. |
| `empty` | The datasource has no vectors. | Load rows and build again. |
| `orphaned` | The datasource or its column no longer exists. | `fractal_index_drop` removes the index. |
| `unknown` | The datasource could not be read just now. | Retry. |

A stale index still answers: the rows added after the build are scored
exactly alongside the index's candidates, and a deleted row is dropped by
the verify step.

### `fractal_index_ensure`
Leaves the index on a datasource and column fit to use, in one call: it builds the index when none exists (`created`), folds in the added rows when that is all the advice asks for (`refreshed`), rebuilds when more than a quarter of the rows were added or more than a fifth deleted (`rebuilt`), and otherwise leaves it alone (`unchanged`; a `degraded` index is rebuilt only when you pass new options). It returns `{name, action, status, generation, rows}`. The options are used only when it builds. A search never builds or changes an index. On this host it is the `ensure` action of the `/fractalsql/index` endpoint, like the other index operations.

### `fractal_index_refresh`
Folds the rows added since the build (an id above the highest the index
covers) into the index **without retraining**: each is encoded with the
index's model and appended to the companion datasource. Returns
`{name, added, rows, generation, refreshed}` (`refreshed: false` when there
is nothing to add). The cells are one row per indexed row, so the append is
the whole refresh and the generation stays. A changed vector needs
`fractal_index_rebuild`.

### `fractal_index_list`
Every registered index with its shape, `rows`, `rows_now`, `stale`,
`status` and `generation`.

### Searching only some rows (`ids`)
`fractal_search` takes `ids` in its options: a JSON array of row ids to
search among. A set of at most 4096 ids is scored exactly (just those rows);
a longer set goes through the index and is filtered, with an exact fallback
when fewer than `k` of its rows survive. An empty array returns no rows and
a non-integer is an error.

### `fractal_index_candidates`
The candidate row ids for Scout: the nearest cells in full, plus
`per_cell` representatives from every other cell, plus the rows newer than
the index.

### The core must carry the IVF maths
The IVF maths lives in the shared core library. When the core in use does
not carry it, every index operation fails with one agreed message:

```
fractalsql: this build of fractalsql-core does not carry the IVF index (rebuild the core and refresh include/<platform>)
```

The SQL surface is the same on every platform: the functions are always
registered, and they report this when the core cannot serve them.

---

## The precision contract
Every SQL-visible distance, norm and dot product in this host accumulates
in **double**, in a fixed sequential order, with no fused multiply-add and
no vectorised reduction, and is returned as a double. There is exactly ONE
cosine implementation in the repository
(`service/adapter/src/fsql_precision.h`), so every SQL-visible cosine
agrees to the last bit -- and agrees with the other FractalSQL hosts.
The canonical vector text round-trips bit-identically for float32, and
ties break on the row id.

---

## `fractal_sfs_converge`
**Sniper Mode (table-free convergence)**

The table-free **convergence** function: it runs the Stochastic Fractal Search toward the query direction and answers where it converged. It reads no table and is **not** a retrieval function (the indexed search is `fractal_search`). `fractal_sfs_converge_debug` is the same search with the full trajectory trace.

### Signature
```sql
fractal_sfs_converge(
    query            ARRAY-or-TEXT,
    iterations       INTEGER DEFAULT 30,
    population_size  INTEGER DEFAULT 50,
    diffusion_factor INTEGER DEFAULT 2
) RETURNS TEXT (JSON)   -- 1 to 4 args
```

### Return Value
Returns a JSON document (TEXT) with the following keys:
- `dim`: Vector dimensionality.
- `population_size`: Particles per generation.
- `best_point`: The final converged vector.
- `best_fit`: Final cosine distance.

---

## `fractal_sfs_converge_debug`
**Sniper Mode with Trajectory Trace**

The table-free **convergence** function with a detailed trace of the process, with the full tuning arguments intact.

> **Renamed.** This was called `fractal_search_debug`; the table-free
> convergence function was renamed because it runs SFS toward a direction and is
> **not** a retrieval function: `fractal_search` -> `fractal_sfs_converge` and
> `fractal_search_debug` -> `fractal_sfs_converge_debug`. There is no alias: the
> old name is refused with a message that names the new one.

### Signature
```sql
fractal_sfs_converge_debug(
    query            ARRAY-or-TEXT,
    iterations       INTEGER DEFAULT 30,
    population_size  INTEGER DEFAULT 50,
    diffusion_factor INTEGER DEFAULT 2
) RETURNS TEXT (JSON)   -- 1 to 4 args
```

### Return Value
Returns a JSON document (TEXT) with the following keys:
- `dim`: Vector dimensionality.
- `generations`: Total iterations run.
- `population_size`: Particles per generation.
- `best_point`: The final converged vector.
- `best_fit`: Final cosine distance.
- `best_fit_per_gen`: Array of best fits across all generations.
- `paths`: Full particle trajectories for visualization.

---

## `fractal_search_explore`
**Scout Discovery Mode**

Scans a stored corpus and returns a diverse population of results. It uses a brute-force relevance scan followed by **Maximal Marginal Relevance (MMR)** to prevent "mode collapse."

*Druid difference:* `fractal_search_explore` is an **aggregate** here, not a set-returning function: you scan your own column and the aggregate folds the whole Scout population into one JSON result. (The same search over a whole datasource is also available as the service operation `POST /fractalsql/search/explore`.)

### Signature
```sql
fractal_search_explore(
    emb     ARRAY-or-TEXT,      -- aggregate over your embedding column
    query   ARRAY-or-TEXT,
    params  TEXT DEFAULT NULL   -- JSON object of tuning parameters
) RETURNS TEXT (JSON)           -- aggregate; one row, JSON with the final SFS population
```

### Usage
```sql
SELECT fractal_search_explore(embedding, '0.6,0.8,0.0,0.0',
                       '{"population_size": 20, "iterations": 10, "walk": 0}')
FROM vectors;
```

### Options (JSON keys of `params`)
| Key | Type | Default | Range | Description |
| --- | --- | --- | --- | --- |
| `population_size` | `int` | `50` | — | Number of results to return. |
| `mmr_lambda` | `float` | `0.5` | $[0, 1]$ | Tradeoff between relevance ($1.0$) and diversity ($0.0$). Lower it when a query lands inside a dense cluster. |
| `iterations` | `int` | `15` | — | SFS generations per search. |
| `diffusion_factor` | `int` | `2` | — | SFS MDN (walk-per-particle count). |
| `walk` | `float` | `0.0` | — | Cross-particle best-pull weight; `0` (the default) removes the cross-particle best-pull, so the population spreads across distinct basins. |

---

## `fractal_search_telemetry`
**Ground-Truth Row Retrieval**

A deterministic primitive that returns the $K$ nearest real datasource rows to a query. This is the foundation for all higher-order agency functions.

On Druid this is a **service operation**: it reads a whole datasource, which a scalar SQL expression cannot do.

### Request
```
POST /fractalsql/search/telemetry
{"datasource": "docs", "vectorColumn": "emb", "idColumn": "id",
 "query": "0.6,0.8,0.0,0.0", "k": 5}
```

### Arguments
| Key | Type | Default | Description |
| --- | --- | --- | --- |
| `datasource` (alias `table`) | `string` | (Required) | The datasource containing the embeddings. |
| `vectorColumn` (alias `column`) | `string` | (Required) | The vector column: an `ARRAY` column, or CSV/JSON text. |
| `idColumn` (alias `id_column`) | `string` | — | The row-identity column. Its value is returned as `doc_id`. |
| `query` | `string` | (Required) | The target vector, as CSV or a bracketed JSON array. Alternatively `query_table` and `query_column` name a one-row datasource that holds it. |
| `k` | `int` | `5` | Number of nearest neighbors to return. |

### Returns
```json
{"n_corpus": 400, "hits": [{"doc_id": 397, "scan_pos": 396, "distance": 2.09e-06}, ...]}
```
Hits are ordered nearest first. `rows` repeats the `hits` list, so a demo `@call ... AS name` can write it into a datasource.

| Field | Description |
| --- | --- |
| `doc_id` | The row's value in the identity column named by `idColumn`: Druid has no `rowid`, so this is how a hit is resolved back to its row. Without an `idColumn`, it is the scan position. |
| `distance` | Exact cosine distance from the query (brute-force scan, not approximate). Diversify/Repulsion applies if enabled on the session. |
| `scan_pos` | The raw 0-indexed position within this call's corpus scan. Distinct from `doc_id`: it identifies a result within this call (for example the `result_handle` argument of `fractal_isolate_background`), not a datasource row. |

**Why the identity column is named by the caller.** A Druid segment has no per-row address: the columns are compressed and the rows are not addressable. A caller that needs a stable handle across calls should name a real identity column (an ingested `id`, say), which is what `doc_id` then carries. See also [api-agency.md's id-resolution note](api-agency.md#a-note-on-id-resolution).

---

## `fractal_hybrid_clinical_search`
**Cohort-Restricted Telemetry**

Wraps `fractal_search_telemetry` but restricts the search to a specific subset of rows.

### Request
```
POST /fractalsql/search/hybrid
{"datasource": "patients", "vectorColumn": "vitals", "idColumn": "id",
 "query": "0.4,0.1,0.2", "docIds": [3, 11, 26], "k": 5}
```

### Arguments
Everything `fractal_search_telemetry` takes, plus the cohort:

| Key | Type | Description |
| --- | --- | --- |
| `docIds` | `array` | The cohort: the identities the search may return, as a JSON array of values from the identity column. |
| `docIdsTable`, `docIdsColumn` | `string` | The same cohort read from a datasource, when it was computed by ordinary SQL: the named cell holds a JSON or CSV list of identities. Deliberately a list of identities rather than a raw SQL filter string, so no dynamic-SQL injection surface exists here. |

`doc_id`, `distance`, and `scan_pos` have the same semantics as `fractal_search_telemetry`, with `scan_pos` counted within this call's cohort-filtered corpus rather than the whole datasource. Errors with `doc_ids cohort matched no rows` if the cohort matches zero rows.

### Example
```
-- @call search/hybrid {"datasource": "patients", "vectorColumn": "vitals", "idColumn": "id",
--                      "query": "0.4,0.1,0.2", "docIds": [3, 11, 26], "k": 5} AS sepsis_watch;
SELECT "doc_id", "distance" FROM "sepsis_watch";
```

---

## `fractal_search_trajectory`
**Drift-Vector Search**

Searches near the delta between two states ($\Delta = V_{current} - V_{baseline}$) to find a matching trajectory in historical data.

### Request
```
POST /fractalsql/search/trajectory
{"table": "patients", "column": "vitals", "id_column": "id",
 "baseline": "0.2,0.3,0.1", "current": "0.5,0.1,0.4", "k": 5}
```

### Arguments
| Key | Type | Default | Description |
| --- | --- | --- | --- |
| `table` (alias `datasource`) | `string` | (Required) | The datasource containing the historical vectors. |
| `column` (alias `vectorColumn`) | `string` | (Required) | The vector column. |
| `id_column` (alias `idColumn`) | `string` | — | The row-identity column, returned as `doc_id`. |
| `baseline`, `current` | `string` | (Required) | The two states, as CSV or bracketed JSON. They must have the same dimension. Each may instead be read from a one-row datasource with `baseline_table`/`baseline_column` and `current_table`/`current_column`. |
| `k` | `int` | `5` | Number of nearest neighbors to return. |

Returns the same `{"n_corpus", "hits"}` document as `fractal_search_telemetry`.

---

## `fractal_cross_modal_search`
**Blended-Modality Search**

Searches with a single query blended from two modalities: $V = \alpha \cdot V_{morph} + (1 - \alpha) \cdot V_{clinical}$.

### Request
```
POST /fractalsql/search/cross-modal
{"table": "patients", "column": "vec", "id_column": "id",
 "morph": "0.6,0.8", "clinical": "-0.5,-0.4", "alpha": 0.5, "k": 3}
```

### Arguments
| Key | Type | Default | Description |
| --- | --- | --- | --- |
| `table` (alias `datasource`) | `string` | (Required) | The datasource containing the vectors. |
| `column` (alias `vectorColumn`) | `string` | (Required) | The vector column. |
| `id_column` (alias `idColumn`) | `string` | — | The row-identity column, returned as `doc_id`. |
| `morph`, `clinical` | `string` | (Required) | The two query vectors, as CSV or bracketed JSON. |
| `alpha` | `float` | `0.5` | $[0, 1]$. Weight given to the morphology vector. $(1 - \text{alpha})$ is given to the clinical vector. |
| `k` | `int` | `3` | Number of nearest neighbors to return. |

Returns the same `{"n_corpus", "hits"}` document as `fractal_search_telemetry`.

---

## Stateful Diversify & Feedback
**Persisted ledgers.** Flushing a ledger writes a QTL v2 snapshot: every entry's weight
and, for a rejected row, the repulsion shape (intensity and sigma) it was recorded with.
Loading restores that snapshot exactly -- the same rejections, with the same strength -- and
**replaces** the in-memory ledgers, so whatever the session had recorded before the load is
gone. A ledger written by an older version (which stored no weights) comes back with every
entry at weight 1.0, taking its repulsion shape from the current session's parameters.

Scout Discovery (`fractal_search_explore`) is *stateless* diversity: MMR
spreads one result set within a single call. The **Diversify/Repulsion**
layer adds *stateful* diversity **across searches**: a session records which
results the user rejected, and subsequent searches actively avoid the
neighborhoods of those rejected results ("shadows"). This is the real
differentiator over plain top-K or MMR: neither of which is stateful across
searches.

The layer is **off by default** (bit-for-bit identical to v1.0 behavior); it
must be enabled per session, and it is session-scoped. Shadows do not persist
across sessions.

### `fractal_diversify_enable()` / `fractal_diversify_disable()`
Turn the Diversify/Repulsion layer on or off for the current session.
Both return SQL `NULL` (the uniform "mutator succeeded" shape).

### `fractal_diversify_set_params(params_json)`
Tunes the repulsion layer. It takes one **JSON object**; every field is
optional: supplying only some keys keeps the core's current value for the
rest, so you only override the fields you name.

```sql
fractal_diversify_set_params(params_json TEXT)
```

| JSON key | Description |
| --- | --- |
| `window_n` | Search-context window size the repulsion layer tracks. |
| `stall_threshold` | Diversity-stall threshold below which repulsion intensifies. |
| `repulsion_sigma` | Gaussian width of each shadow's repulsion field. |
| `repulsion_weight` | Overall strength of the repulsion penalty. |
| `max_shadows_considered` | Cap on how many recorded shadows influence a search. |
| `tail_buffer_cap` | Accepted for compatibility: the value is range-checked (1-1024) and stored, but has no effect on search or the ledger. |

Takes effect on the next `fractal_search_distance` call.

### `fractal_detect_collapse()` → `REAL`
Returns the current **D_q** (diversity quotient) from the last search on this
session's context. Low values indicate the search population has collapsed
toward a single basin. Druid SQL has no NaN, so "no search has run yet or
Diversify is disabled" comes back as SQL `NULL` (the same reading is also
exposed under the core name `fractal_diversify_current_dq()`).

### `fractal_explain_result()` → TEXT (JSON)
Session-level Diversify diagnostics: `{"dq":..,"diversify_enabled":..,"overhead_p99_us":..}`.
This is a session health readout, **not** a per-candidate "this result was
penalized by shadow X" trace. The core ABI does not currently expose
shadow attribution at that granularity.

### `fractal_feedback_report(result_handle, kind, dwell_ms)` → SQL `NULL`
Reports engagement on a prior search result, feeding the shadow store when
Diversify is enabled (inert otherwise). The 2-arg (no dwell) form is also
registered.

| Argument | Type | Description |
| --- | --- | --- |
| `result_handle` | `int` | The 0-based corpus row index the result came from (matches the `scan_pos` returned by the telemetry search functions, not their `doc_id`). |
| `kind` | `text` | One of `'dwell'`, `'positive'`, `'negative'`. Anything else raises `kind must be one of ...`. |
| `dwell_ms` | `int` | Optional dwell time in ms (omitted for a bare negative report). |

`fractal_isolate_background(result_handle)` is a convenience wrapper that
reports negative engagement with no dwell time.

### The stateful loop
The canonical usage is a feedback-driven re-search loop (exercised end to end
in `demo/demo-vertical-recommendation-search.sql`):

```sql
SELECT fractal_diversify_enable();           -- 1. turn on the repulsion layer
SELECT fractal_search_explore(emb, '0.5,0.5,0.5');  -- 2. first (diverse) search
SELECT fractal_feedback_report(0, 'negative'); -- 3. reject the top result
SELECT fractal_search_explore(emb, '0.5,0.5,0.5');  -- 4. re-search the SAME query
-- 5. confirm the rejected row's neighborhood is now avoided
SELECT fractal_explain_result();             -- -> {"dq":..,"diversify_enabled":..,...}
SELECT fractal_diversify_disable();          -- 6. turn it off when done
```

## Which functions use the index

The `agent_use_index` setting (`off` by default; the key, GUC, module argument or property that carries it on each host is in the settings table in [Reasoning Setup](reasoning-setup.md)) decides whether the agents below search through a `fractal_index` when one covers the table and column. Every distance an indexed search returns is still exact, and rows added after the build are scanned exactly. This table lists what goes through the index and, for the rest, why not. The rows use the SQL names of the functions; here they are agent endpoints under `/fractalsql/agent`.

| Function or agent | Search it does | Index |
| --- | --- | --- |
| `fractal_search` | nearest rows, exact scan or index | Yes: this is the indexed search |
| `fractal_agent_route_task`, `fractal_agent_schedule_workload` | the nearest row | Yes, with `agent_use_index` |
| `fractal_agent_outlier_intercept` (cosine) | the nearest row | Yes, with `agent_use_index` (L2 scans exactly) |
| `fractal_search_agent`, `fractal_rag_agent` | the top rows for a question | Yes, with `agent_use_index`; a metadata filter restricts the indexed search to the matching rows |
| `fractal_agent_recall_hybrid` | the nearest rows within a cohort | Yes where the host has it and the cohort is a list of row ids: the cohort goes to the indexed search as its `ids` option (SQLite, PostgreSQL, DuckDB, MariaDB) |
| `fractal_hybrid_clinical_search` | the nearest rows within a cohort | No: exact scan of the cohort |
| `fractal_agent_rebalance_sibling`, `fractal_agent_detour_classify`, `fractal_agent_track_anomaly`, `fractal_agent_trajectory_predict`, `fractal_search_trajectory`, `fractal_agent_patient_deterioration_triage` | nearest row to a computed vector (current minus baseline) | No: exact scan. The index was tuned with queries taken from the rows themselves, and a computed query has not been measured against it |
| `fractal_cross_modal_search` | nearest rows to a combined vector | No: exact scan, for the same reason |
| `fractal_search_telemetry`, `fractal_agent_recommend_diverse`, `fractal_agent_feedback_audit` | exact scan with Diversify repulsion | No, by design: the repulsion needs every row's distance, and the indexed search does not apply it |
| `fractal_search_explore`, `fractal_agent_plan_explore` | population (Scout) search | No, by design: the search is exploratory, not nearest-row |
| `fractal_index_candidates` | a shortlist of ids from the index | It is the index; the shortlist is for a caller's own follow-up search |
| the other agents (allocate, anomaly triage, regime triage, loop detection, data analyst, SQL agent, and so on) | no vector search | Not applicable |
