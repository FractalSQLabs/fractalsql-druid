-- demo/demo-fractal-index.sql
--
-- Runnable walkthrough of the native IVF index: build an index over a
-- datasource's vector column, search it, compare it with the exact scan,
-- show the stale/delta case, and drop it.
--
-- Prerequisites: the extension is loaded on the Druid cluster. The core
-- in use must carry the IVF maths; when it does not, every index
-- operation says so and the kit's headline check reports it.
--
-- Run:
--   python3 demo/run_demo.py --file demo/demo-fractal-index.sql
--
-- ===========================================================================
-- Notes on how this runs on Druid
-- ===========================================================================
--
--   * Druid has no DDL and no DML. A Druid SQL query is read-only, and a
--     value reaches a datasource through an MSQ INSERT task. So the
--     index's CELLS live in a COMPANION DATASOURCE, written with an MSQ
--     INSERT -- the same precedent the vectorizer's companion datasource
--     sets (docs/vectorizer-setup.md).
--   * Druid has no cheap fetch by id: filtering on a BIGINT id scans
--     segments. So the vector a candidate needs in order to be VERIFIED
--     is stored inside the index, as an FP16 copy, next to the codes.
--     The distances the indexed search returns are therefore exact to
--     FP16 precision, not FP32 -- the exact scan (search/telemetry) is
--     the float32 reference, and the kit compares them.
--   * The index's operations read a datasource and (for a build) write
--     one, which a Druid SQL function cannot do: they are service
--     operations (POST /fractalsql/index), reached here with @call.
--   * The indexed search does NOT apply the Diversify repulsion layer.
--
-- Safe to re-run: the fixture is written with OVERWRITE ALL, and the
-- index is dropped at the end.

-- ---------------------------------------------------------------------------
-- 0. Sanity check: extension loaded?
-- ---------------------------------------------------------------------------
SELECT fractal_edition(), fractal_version();

-- ---------------------------------------------------------------------------
-- 1. The rows to index.
--
-- Twenty-four rows, eight dimensions, on a circle around the origin with
-- a little jitter: an IVF index has cells to find, and the neighbours of
-- a query are the rows near it.
-- ---------------------------------------------------------------------------
-- @fixture fi_docs {"rows": [
--   {"id": 1,  "embedding": "0.600,0.800,0.000,0.000,0.000,0.000,0.000,0.000"},
--   {"id": 2,  "embedding": "0.598,0.801,0.002,-0.001,0.000,0.000,0.000,0.000"},
--   {"id": 3,  "embedding": "0.601,0.799,-0.001,0.002,0.000,0.000,0.000,0.000"},
--   {"id": 4,  "embedding": "0.400,0.916,0.000,0.000,0.000,0.000,0.000,0.000"},
--   {"id": 5,  "embedding": "0.200,0.980,0.000,0.000,0.000,0.000,0.000,0.000"},
--   {"id": 6,  "embedding": "0.000,1.000,0.000,0.000,0.000,0.000,0.000,0.000"},
--   {"id": 7,  "embedding": "-0.200,0.980,0.000,0.000,0.000,0.000,0.000,0.000"},
--   {"id": 8,  "embedding": "-0.400,0.916,0.000,0.000,0.000,0.000,0.000,0.000"},
--   {"id": 9,  "embedding": "-0.600,0.800,0.000,0.000,0.000,0.000,0.000,0.000"},
--   {"id": 10, "embedding": "-0.800,0.600,0.000,0.000,0.000,0.000,0.000,0.000"},
--   {"id": 11, "embedding": "-0.980,0.200,0.000,0.000,0.000,0.000,0.000,0.000"},
--   {"id": 12, "embedding": "-1.000,0.000,0.000,0.000,0.000,0.000,0.000,0.000"},
--   {"id": 13, "embedding": "-0.980,-0.200,0.000,0.000,0.000,0.000,0.000,0.000"},
--   {"id": 14, "embedding": "-0.800,-0.600,0.000,0.000,0.000,0.000,0.000,0.000"},
--   {"id": 15, "embedding": "-0.600,-0.800,0.000,0.000,0.000,0.000,0.000,0.000"},
--   {"id": 16, "embedding": "-0.400,-0.916,0.000,0.000,0.000,0.000,0.000,0.000"},
--   {"id": 17, "embedding": "-0.200,-0.980,0.000,0.000,0.000,0.000,0.000,0.000"},
--   {"id": 18, "embedding": "0.000,-1.000,0.000,0.000,0.000,0.000,0.000,0.000"},
--   {"id": 19, "embedding": "0.200,-0.980,0.000,0.000,0.000,0.000,0.000,0.000"},
--   {"id": 20, "embedding": "0.400,-0.916,0.000,0.000,0.000,0.000,0.000,0.000"},
--   {"id": 21, "embedding": "0.800,0.600,0.000,0.000,0.000,0.000,0.000,0.000"},
--   {"id": 22, "embedding": "0.980,0.200,0.000,0.000,0.000,0.000,0.000,0.000"},
--   {"id": 23, "embedding": "0.600,0.800,0.000,0.000,0.000,0.000,0.000,0.000"},
--   {"id": 24, "embedding": "0.590,0.810,0.000,0.000,0.000,0.000,0.000,0.000"}
-- ]};

SELECT COUNT(*) AS "rows" FROM "fi_docs";

-- ---------------------------------------------------------------------------
-- 2. Build the index.
--
-- Two passes over the rows: a sample pass that trains the model, then an
-- encode pass that assigns every row to a cell. The cells are written
-- into the companion datasource fi_docs_embedding_index_cells.
-- ---------------------------------------------------------------------------
-- @call index {"action": "create", "table": "fi_docs", "column": "embedding",
--              "options": {"name": "fi_docs_embedding_index", "id_col": "id",
--                          "vector_format": "INT8", "nlist": 8, "seed": 7}} AS index_created;

SELECT "index", "rows", "dim", "format", "nlist", "code_bytes", "id_kind", "state"
FROM "index_created";

-- The cells really are in a companion datasource.
SELECT "kind", COUNT(*) AS "cell_rows"
FROM "fi_docs_embedding_index_cells"
GROUP BY "kind";

-- ---------------------------------------------------------------------------
-- 3. The indexed search.
--
-- rows_scanned is the "index actually used" statistic: the number of rows
-- the index READ. It is far below the datasource's row count -- a search
-- that silently ran flat would show 24.
-- ---------------------------------------------------------------------------
-- @call index {"action": "search", "table": "fi_docs", "column": "embedding",
--              "query": "[0.6,0.8,0.0,0.0,0.0,0.0,0.0,0.0]", "k": 5,
--              "options": {"nprobe": 4}} AS index_search;

SELECT "rows_scanned", "cells_probed", "verified", "precision", "indexed_rows"
FROM "index_search";

-- The neighbours the index returned. The candidate list is a JSON array
-- in the result, so the extension's own JSON accessors read it.
SELECT FRACTAL_JSON_VALUE( "candidates", '$[0].doc_id' ) AS "best_doc_id",
       FRACTAL_JSON_VALUE( "candidates", '$[0].distance' ) AS "best_distance",
       FRACTAL_JSON_VALUE( "candidates", '$[1].doc_id' ) AS "second_doc_id"
FROM "index_search";

-- ---------------------------------------------------------------------------
-- 4. The exact scan, for comparison.
--
-- This is the float32 reference: every row is read and every distance is
-- computed exactly. The indexed search's distances are the same numbers
-- to FP16 precision.
-- ---------------------------------------------------------------------------
-- @call search/telemetry {"datasource": "fi_docs", "vectorColumn": "embedding",
--                         "idColumn": "id",
--                         "query": "[0.6,0.8,0.0,0.0,0.0,0.0,0.0,0.0]", "k": 5} AS exact_search;

SELECT "doc_id", "distance" FROM "exact_search";

-- The two agree: the indexed search's best neighbour is one of the exact scan's nearest rows (two rows sit at
-- distance 0 here), and the distances differ by at most the FP16 rounding.
SELECT COUNT(*) AS "indexed_best_is_an_exact_nearest"
FROM "exact_search" e
INNER JOIN "index_search" s ON e."doc_id" = FRACTAL_JSON_VALUE( s."candidates", '$[0].doc_id' )
WHERE e."distance" < 0.000001;

-- ---------------------------------------------------------------------------
-- 5. The candidates, for Scout.
--
-- The nearest cells in full, plus per_cell representatives from every
-- other cell, plus the rows newer than the index.
-- ---------------------------------------------------------------------------
-- @call index {"action": "candidates", "table": "fi_docs", "column": "embedding",
--              "query": "[0.6,0.8,0.0,0.0,0.0,0.0,0.0,0.0]",
--              "options": {"nprobe": 4, "per_cell": 1}} AS index_candidates;

SELECT "cells", "near", "others", "delta_rows" FROM "index_candidates";

-- ---------------------------------------------------------------------------
-- 6. The stale case.
--
-- The index covers the rows as they were when it was built. Add a row,
-- and the index is stale: it does not cover the new row yet, and
-- fractal_index_info reports the delta.
-- ---------------------------------------------------------------------------
-- @fixture fi_docs_more {"rows": [
--   {"id": 25, "embedding": "0.610,0.790,0.000,0.000,0.000,0.000,0.000,0.000"}
-- ]};

-- @call index {"action": "info", "name": "fi_docs_embedding_index"} AS index_info;

SELECT "rows", "source_rows", "stale", "delta_rows", "status", "advice" FROM "index_info";

-- The index still answers; it just does not cover the new row yet.
-- @call index {"action": "search", "table": "fi_docs", "column": "embedding",
--              "query": "[0.61,0.79,0.0,0.0,0.0,0.0,0.0,0.0]", "k": 3,
--              "options": {"nprobe": 4}} AS index_search_stale;

SELECT "rows_scanned", "indexed_rows" FROM "index_search_stale";

-- The list shows every index with its status.
-- @call index {"action": "list"} AS index_listed;

-- A refresh folds the new row in without retraining.
-- @call index {"action": "refresh", "name": "fi_docs_embedding_index"} AS index_refreshed;

SELECT "added", "rows", "refreshed" FROM "index_refreshed";

-- Search only some rows (ids): an exact scan of just those.
-- @call index {"action": "search", "table": "fi_docs", "column": "embedding",
--              "query": "[0.61,0.79,0.0,0.0,0.0,0.0,0.0,0.0]", "k": 3,
--              "options": {"ids": [1, 2, 3, 25]}} AS index_search_ids;

SELECT "rows_scanned", "used_index" FROM "index_search_ids";

-- A rebuild retrains from the rows as they are now.
-- @call index {"action": "rebuild", "name": "fi_docs_embedding_index"} AS index_rebuilt;

-- @call index {"action": "info", "name": "fi_docs_embedding_index"} AS index_info_after;

SELECT "rows", "source_rows", "stale", "delta_rows" FROM "index_info_after";

-- ---------------------------------------------------------------------------
-- 7. Drop the index.
--
-- The cells stay in the companion datasource: a Druid datasource cannot be
-- rewritten and Druid has no DELETE. Replace the datasource to reclaim
-- the space.
-- ---------------------------------------------------------------------------
-- @call index {"action": "drop", "name": "fi_docs_embedding_index"} AS index_dropped;

SELECT "index", "state", "note" FROM "index_dropped";

-- ---------------------------------------------------------------------------
-- 8. The headline check.
--
-- The index was built, it answered with verified distances, and it read
-- far fewer rows than the datasource holds.
-- ---------------------------------------------------------------------------
SELECT CASE
         WHEN s."rows_scanned" > 0
          AND s."rows_scanned" < i."source_rows"
          AND s."verified" = 1
         THEN 'HEADLINE kit=fractal-index ok'
         ELSE 'HEADLINE kit=fractal-index FAILED'
       END AS "headline"
FROM "index_search" s INNER JOIN "index_info" i ON 1 = 1;
