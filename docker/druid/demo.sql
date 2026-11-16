-- FractalSQL for Apache Druid -- end-to-end demo.
--
-- Run against the router's SQL endpoint:
--     POST http://localhost:8888/druid/v2/sql
--     {"query": "...", "resultFormat": "object", "header": true}
--
-- The demo_vecs datasource is ingested by scripts/ingest-demo.sh. Each
-- row has an id, a group, a timestamp, a 3-dimensional embedding and a
-- 64-sample series, both stored as Druid ARRAY columns.
--
-- The series is 64 samples long because the core's drift detector needs
-- a window of at least 24 samples and at least twice that many samples
-- in the series: FRACTAL_DIMENSION_DRIFT("series", 32) is the widest
-- window the seed data supports.
--
-- A note on shape. The fractal_* functions are native
-- expressions, so they evaluate per row. Druid's SQL has two rules to
-- work around:
--
--   * in an aggregating query, every projected column must be a
--     grouping key -- so a per-row expression over a column needs that
--     column in the GROUP BY (GROUP BY "id", "emb" below is one group
--     per row);
--   * in a non-aggregating query, ORDER BY is restricted to __time --
--     so a query that does not aggregate cannot rank by a computed
--     value.
--
-- fractal_search is the exception: it is an aggregate because it has to
-- scan the column as a corpus rather than score a single row, so it is
-- expressed as an aggregate over one group per row, "GROUP BY the row's
-- own identity".

-- =========================================================================
-- 1. Sanity: the extension is loaded and its SQL routine is registered.
-- =========================================================================
SELECT "ROUTINE_NAME", "ROUTINE_TYPE", "IS_AGGREGATOR"
FROM INFORMATION_SCHEMA.ROUTINES
WHERE "ROUTINE_NAME" = 'FRACTAL_SEARCH';

-- =========================================================================
-- 2. The FractalSQL search surface.
--
-- fractal_search(vector_column, query_text) scores a row against the
-- SFS-refined query point. The value is a cosine distance: 0.0 is an
-- exact match, larger is further away. The query vector is a VARCHAR
-- literal in the core's text form -- CSV ("1.0,0.5,-0.25") or
-- bracketed JSON ("[1.0,0.5,-0.25]").
--
-- The seed data holds emb = [1,0,0] on row "a", so the closest row
-- must come back at distance 0.
-- =========================================================================
SELECT "id", "grp", fractal_search("emb", '[1.0,0.0,0.0]') AS "dist"
FROM "demo_vecs"
GROUP BY "id", "grp"
ORDER BY "dist" ASC
LIMIT 5;

-- =========================================================================
-- 3. The same search with a different query vector, to show the
--    ranking move with the query rather than staying put.
-- =========================================================================
SELECT "id", "grp", fractal_search("emb", '[0.0,1.0,0.0]') AS "dist"
FROM "demo_vecs"
GROUP BY "id", "grp"
ORDER BY "dist" ASC
LIMIT 5;

-- =========================================================================
-- 4. A control: the same rows with no FractalSQL involved, so the
--    numbers above can be checked against plain Druid SQL.
-- =========================================================================
SELECT "id", "grp", "emb"
FROM "demo_vecs"
GROUP BY "id", "grp", "emb"
ORDER BY "id"
LIMIT 5;

-- =========================================================================
-- 5. The datasource's shape, as Druid reports it. Note that "emb" and
--    "series" are ARRAY columns -- that is the type the fractal_*
--    functions read.
-- =========================================================================
SELECT "ORDINAL_POSITION", "COLUMN_NAME", "DATA_TYPE", "IS_NULLABLE"
FROM INFORMATION_SCHEMA.COLUMNS
WHERE "TABLE_SCHEMA" = 'druid' AND "TABLE_NAME" = 'demo_vecs'
ORDER BY "ORDINAL_POSITION";

-- =========================================================================
-- 6. The extension's own SQL routine, as reported by Druid.
-- =========================================================================
SELECT "ROUTINE_NAME", "ROUTINE_TYPE", "IS_AGGREGATOR", "SIGNATURES"
FROM INFORMATION_SCHEMA.ROUTINES
WHERE "ROUTINE_SCHEMA" = 'INFORMATION_SCHEMA'
  AND "ROUTINE_NAME" = 'FRACTAL_SEARCH';

-- =========================================================================
-- 7. The vector surface.
--
-- The vector functions are native expressions: they take a vector --
-- a Druid ARRAY column, or the core's text form -- and give a number
-- or a vector back.
--
-- A vector argument may be written either way: as the ARRAY column, or
-- as the core's text form -- CSV ("1.0,0.5,-0.25") or bracketed JSON
-- ("[1.0,0.5,-0.25]"). The text form is how a query vector is written
-- when it is not in a column.
--
-- "emb" is in the GROUP BY because Druid requires every projected
-- column to be a grouping key. "id" is unique, so this is still one
-- group per row -- and it lets the result be ranked.
-- =========================================================================
SELECT "id",
       FRACTAL_VECTOR_NORM("emb") AS "norm",
       FRACTAL_VECTOR_DIMS("emb") AS "dims",
       FRACTAL_VECTOR_COSINE_DISTANCE("emb", '[1.0,0.0,0.0]') AS "dist"
FROM "demo_vecs"
GROUP BY "id", "emb"
ORDER BY "dist" ASC
LIMIT 5;

-- =========================================================================
-- 8. The vector surface again, this time producing vectors rather than
--    numbers. A vector comes back in the core's JSON text form -- the
--    same convention the reference extension used.
-- =========================================================================
SELECT "id",
       FRACTAL_VECTOR_NORMALIZE("emb") AS "unit",
       FRACTAL_VECTOR_TO_JSON("emb") AS "json"
FROM "demo_vecs"
GROUP BY "id", "emb"
ORDER BY "id"
LIMIT 3;

-- =========================================================================
-- 9. The analytic surface.
--
-- The fractal analytics read a series -- here the "series" ARRAY
-- column -- and describe its structure. Functions that answer with a
-- number give one; functions that answer with a document give JSON,
-- the same document shape the reference extension returned.
-- =========================================================================
SELECT "id",
       FRACTAL_DIMENSION_DFA("series") AS "dfa",
       FRACTAL_DIMENSION_DRIFT("series", 32) AS "drift",
       FRACTAL_CHANGE_POINT_DETECT("series", 8, 0.5) AS "change_points"
FROM "demo_vecs"
GROUP BY "id", "series"
ORDER BY "id"
LIMIT 3;

-- =========================================================================
-- 10. The registered surface, as the planner sees it: every fractal_*
--     routine the extension registered.
-- =========================================================================
SELECT "ROUTINE_NAME", "IS_AGGREGATOR"
FROM INFORMATION_SCHEMA.ROUTINES
WHERE "ROUTINE_NAME" LIKE 'FRACTAL%'
ORDER BY "ROUTINE_NAME";
