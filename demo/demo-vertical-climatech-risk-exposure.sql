-- demo/demo-vertical-climatech-risk-exposure.sql
--
-- FractalSQL for Apache Druid -- industry vertical: physical-climate
-- risk exposure. A 20 x 20 hazard grid carries a fuel-moisture deficit
-- index for the dry and the wet season. The dry-season high-hazard
-- region is large and compact; the wet-season one is smaller and
-- gappier, and the morphology says so.
--
--   1. The hazard grid: 20 x 20 cells, dry vs wet season.
--   2. The morphology of the elevated-hazard region in each season.
--   3. fractal_agent_network_coverage_alert: the dry-season exposure.
--   4. Reasoning: the risk-exposure narrative.
--
-- Prerequisites: the extension is loaded on the Druid cluster. The
-- narrative and the agent's rationale need a reasoning provider
-- (docs/reasoning-setup.md); every other step runs with no model.
--
-- Run:
--   python3 demo/run_demo.py --file demo/demo-vertical-climatech-risk-exposure.sql
--
-- ===========================================================================
-- Notes on how this runs on Druid
-- ===========================================================================
--
--   * The grid is an MSQ write: Druid has no DDL and no recursive CTE,
--     so the cell indices come from two UNNESTed arrays.
--   * The point cloud is folded into one vector with ARRAY_AGG: Druid
--     has no group_concat, and the rows keep the order they were
--     written in.
--   * The agent is a service call, and reads its cloud and its series
--     from the datasources the demo computed.
--
-- Notes:
--   * Fully deterministic fixtures (no random()).

-- ---------------------------------------------------------------------------
-- 0. Sanity check: extension loaded?
-- ---------------------------------------------------------------------------
SELECT fractal_edition(), fractal_version();

-- ---------------------------------------------------------------------------
-- 1. A 20 x 20 hazard grid, dry vs wet season.
-- ---------------------------------------------------------------------------
REPLACE INTO cre_grid OVERWRITE ALL
SELECT "r", "c", "dry_index", "wet_index"
FROM (
    SELECT r."r" AS "r", c."c" AS "c",
           (19 - r."r") / 19.0 * 0.5 + (19 - c."c") / 19.0 * 0.3
               + MOD(r."r" * 5 + c."c" * 3, 7) / 70.0 + 0.05 AS "dry_index",
           ((19 - r."r") / 19.0 * 0.5 + (19 - c."c") / 19.0 * 0.3
               + MOD(r."r" * 5 + c."c" * 3, 7) / 70.0) * 0.55 AS "wet_index"
    FROM (
        SELECT g AS "r" FROM UNNEST(ARRAY[
            0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16, 17, 18, 19]) AS t(g)
    ) r
    CROSS JOIN (
        SELECT g AS "c" FROM UNNEST(ARRAY[
            0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16, 17, 18, 19]) AS t(g)
    ) c
) g
PARTITIONED BY ALL;

SELECT SUM(CASE WHEN "dry_index" > 0.40 THEN 1 ELSE 0 END) AS "high_hazard_cells_dry",
       SUM(CASE WHEN "wet_index" > 0.25 THEN 1 ELSE 0 END) AS "elevated_cells_wet"
FROM "cre_grid";

-- ---------------------------------------------------------------------------
-- 2. The morphology of the elevated-hazard region.
--
-- The dry-season region is large and compact; the wet-season region is
-- smaller and gappier.
-- ---------------------------------------------------------------------------
REPLACE INTO cre_cloud_dry OVERWRITE ALL
SELECT ARRAY_TO_STRING(ARRAY_AGG(
           CAST("c" AS VARCHAR) || ',' || CAST("r" AS VARCHAR), 8192), ',') AS "cloud"
FROM "cre_grid" WHERE "dry_index" > 0.40
PARTITIONED BY ALL;

REPLACE INTO cre_cloud_wet OVERWRITE ALL
SELECT ARRAY_TO_STRING(ARRAY_AGG(
           CAST("c" AS VARCHAR) || ',' || CAST("r" AS VARCHAR), 8192), ',') AS "cloud"
FROM "cre_grid" WHERE "wet_index" > 0.25
PARTITIONED BY ALL;

SELECT 'dry season' AS "season",
       ROUND(fractal_json_value(
           fractal_morphological_complexity((SELECT "cloud" FROM "cre_cloud_dry"), 2),
           '$.dimension'), 3) AS "dimension",
       ROUND(fractal_json_value(
           fractal_morphological_complexity((SELECT "cloud" FROM "cre_cloud_dry"), 2),
           '$.lacunarity'), 3) AS "lacunarity";

SELECT 'wet season' AS "season",
       ROUND(fractal_json_value(
           fractal_morphological_complexity((SELECT "cloud" FROM "cre_cloud_wet"), 2),
           '$.dimension'), 3) AS "dimension",
       ROUND(fractal_json_value(
           fractal_morphological_complexity((SELECT "cloud" FROM "cre_cloud_wet"), 2),
           '$.lacunarity'), 3) AS "lacunarity";

-- ---------------------------------------------------------------------------
-- 3. fractal_agent_network_coverage_alert: the dry-season exposure.
--
-- The fuel-moisture drift series is 96 points: a slow oscillation for
-- the first 48, then a fast one.
-- ---------------------------------------------------------------------------
REPLACE INTO cre_drift OVERWRITE ALL
SELECT "t", "v"
FROM (
    SELECT g AS "t",
           CASE WHEN g < 49
                THEN 4.0 + 1.5 * SIN(g * 0.31)
                     + (MOD(MOD(MOD(2718 * 1103515245 + 12345, 2147483648), 65536), 1000) - 500) / 1250.0
                ELSE 4.0 + 3.0 * SIN(g * 1.4)
                     + (MOD(MOD(MOD(2718 * 1103515245 + 12345, 2147483648), 65536), 1000) - 500) / 2500.0
           END AS "v"
    FROM UNNEST(ARRAY[
        1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16, 17, 18, 19, 20,
        21, 22, 23, 24, 25, 26, 27, 28, 29, 30, 31, 32, 33, 34, 35, 36, 37, 38,
        39, 40, 41, 42, 43, 44, 45, 46, 47, 48, 49, 50, 51, 52, 53, 54, 55,
        56, 57, 58, 59, 60, 61, 62, 63, 64, 65, 66, 67, 68, 69, 70, 71, 72,
        73, 74, 75, 76, 77, 78, 79, 80, 81, 82, 83, 84, 85, 86, 87, 88, 89,
        90, 91, 92, 93, 94, 95, 96]) AS t(g)
) s
PARTITIONED BY ALL;

REPLACE INTO cre_series OVERWRITE ALL
SELECT ARRAY_TO_STRING(ARRAY_AGG(CAST("v" AS VARCHAR), 16384), ',') AS "series"
FROM "cre_drift"
PARTITIONED BY ALL;

-- @call agent/network_coverage_alert {"point_cloud_table": "cre_cloud_dry",
--                                  "point_cloud_column": "cloud",
--                                  "drift_series_table": "cre_series",
--                                  "drift_series_column": "series",
--                                  "boxcount_dim": 2, "drift_win": 48,
--                                  "drift_threshold": 0.5};

-- ---------------------------------------------------------------------------
-- 4. Reasoning: the risk-exposure narrative.
-- ---------------------------------------------------------------------------
SELECT fractal_reason(
    'one-line physical-climate-risk exposure narrative for an insured portfolio in this region',
    fractal_morphological_complexity((SELECT "cloud" FROM "cre_cloud_dry"), 2)) AS "narrative";

-- ---------------------------------------------------------------------------
-- 5. The headline.
--
-- The kit passes when the hazard map came out as the grid says it
-- should: 270 cells over the dry-season threshold and 190 over the
-- wet-season one. Those are the kit's own numbers, not the model's
-- opinion of them.
-- ---------------------------------------------------------------------------
SELECT CASE
           WHEN (SELECT SUM(CASE WHEN "dry_index" > 0.40 THEN 1 ELSE 0 END) FROM "cre_grid") = 270
            AND (SELECT SUM(CASE WHEN "wet_index" > 0.25 THEN 1 ELSE 0 END) FROM "cre_grid") = 190
            THEN 'HEADLINE kit=climatech-risk-exposure ok'
            ELSE 'HEADLINE kit=climatech-risk-exposure FAILED'
       END AS "headline";
