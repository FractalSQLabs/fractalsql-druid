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

## `fractal_search`
**Sniper Mode Convergence**

Converges to the single best point minimizing cosine distance to a query over the unit box $[-1, 1]^d$. It is a precision tool for finding the absolute global minimum.

### Signature
```sql
fractal_search(
    vector  ARRAY-or-TEXT,   -- stored vector (an ARRAY column, or CSV/JSON text)
    query   ARRAY-or-TEXT    -- the target vector to converge toward
) RETURNS REAL
```

### Arguments
| Argument | Type | Default | Range | Description |
| --- | --- | --- | --- | --- |
| `vector` | ARRAY / TEXT | (Required) | — | The stored vector to score. |
| `query` | ARRAY / TEXT | (Required) | — | The target vector to converge toward. |

*Druid difference:* the `iterations` / `population_size` / `diffusion_factor` tuning arguments are fixed at their SFS defaults here (`fractal_search` is a per-row scalar run once per distinct query per scan). Use `fractal_search_debug(query, ...)` when you need the tunable form.

`iterations` x `population_size` x `diffusion_factor` x the vector length must not exceed 2,147,483,648 (about a minute of work) in one call; each limit is checked on its own and then their product, and a larger search is refused.

### Query-Vector Dimension Limit
The query vector may carry up to **16,384 dimensions**: the shared core library's `FSQL_MAX_DIM`, and the limit that fires (`exceeds FSQL_MAX_DIM`). A query beyond that is rejected.

`fractal_search_debug` and `fractal_search_explore` take the same query and share the same limit.

---

## `fractal_search_debug`
**Sniper Mode with Trajectory Trace**

Same convergence as `fractal_search`, but returns a detailed trace of the process, with the full tuning arguments intact.

### Signature
```sql
fractal_search_debug(
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

Takes effect on the next `fractal_search` call.

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
