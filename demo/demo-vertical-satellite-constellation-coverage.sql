-- demo/demo-vertical-satellite-constellation-coverage.sql
--
-- FractalSQL for Apache Druid -- industry vertical: space and
-- satellite communications. Constellation coverage monitoring, on two
-- installed agents:
--
--   * fractal_agent_network_coverage_alert -- the spatial morphology
--     of the constellation's footprint grid (box-counting dimension and
--     lacunarity) plus the drift of a link-quality telemetry series,
--     flagging coverage gaps and dead zones. This is the COVERAGE-GAP
--     angle only; orbital drift and collision detection are a
--     different problem and are not covered here.
--   * fractal_agent_schedule_workload -- a secondary branch that
--     models launch-manifest / payload-slot scheduling as a
--     resource-allocation problem (vector-refine + nearest-slot
--     match).
--
-- Prerequisites: the extension is loaded on the Druid cluster. The
-- agents' rationales and the closing narrative need a reasoning
-- provider (docs/reasoning-setup.md); every other step runs with no
-- model.
--
-- Run:
--   python3 demo/run_demo.py --file demo/demo-vertical-satellite-constellation-coverage.sql
--
-- ===========================================================================
-- Notes on how this runs on Druid
-- ===========================================================================
--
--   * The footprint lattice is an MSQ write: Druid has no DDL and no
--     recursive CTE, so the grid indices come from two UNNESTed arrays
--     crossed with each other. The jitter is integer arithmetic, with % written as MOD.
--   * The link-quality series is a fixture. Druid has no recursion, so the generator runs an integer LCG (seed 4242) and the 96 samples
--     arrive as rows.
--   * The point clouds are folded into one vector with ARRAY_AGG:
--     Druid has no group_concat. The morphology then reads the cloud
--     straight out of that table -- a 400-point cloud is too big to
--     come back through a scalar subquery.
--   * The corpus search over the launch slots is a @call service call
--     (search/telemetry), and the agents are @call service calls too:
--     an agent reads a table and reasons about it, and a Druid SQL
--     function can do neither.
--   * The launch slots' doc_id is the slot's id, not a rowid: Druid
--     tables have no rowid.
--
-- Notes:
--   * Fully deterministic fixtures (no random()).
--   * The footprint grid is a 20 x 20 lattice of footprint centres
--     (400 points). The morphology estimator needs a few hundred points
--     for a stable answer, which is why the grid is this size. The
--     degraded constellation loses a block of footprints (a dead
--     zone), which raises lacunarity (gappiness).
--   * The link-quality series is 96 samples with a regime change at 49:
--     a stable carrier followed by a fast oscillation as a relay
--     degrades.

-- ---------------------------------------------------------------------------
-- 0. Sanity check: extension loaded?
-- ---------------------------------------------------------------------------
SELECT fractal_edition(), fractal_version();

-- ---------------------------------------------------------------------------
-- 1. Footprint grids: a healthy 20 x 20 lattice and a degraded copy
-- missing an 8 x 8 block (rows 6-13, columns 6-13).
-- ---------------------------------------------------------------------------
REPLACE INTO scc_footprints OVERWRITE ALL
SELECT r."r" AS "r", c."c" AS "c",
       c."c" + 0.06 * (MOD(r."r" * 7 + c."c" * 13, 10) - 5) / 5.0 AS "x",
       r."r" + 0.06 * (MOD(r."r" * 11 + c."c" * 3, 10) - 5) / 5.0 AS "y"
FROM (
    SELECT g AS "r" FROM UNNEST(ARRAY[
        0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16, 17, 18, 19]) AS t(g)
) r
CROSS JOIN (
    SELECT g AS "c" FROM UNNEST(ARRAY[
        0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16, 17, 18, 19]) AS t(g)
) c
PARTITIONED BY ALL;

SELECT COUNT(*) AS "healthy_footprints",
       SUM(CASE WHEN NOT ("r" BETWEEN 6 AND 13 AND "c" BETWEEN 6 AND 13)
                THEN 1 ELSE 0 END) AS "degraded_footprints"
FROM "scc_footprints";

-- ---------------------------------------------------------------------------
-- 2. Morphology of each lattice. The dead zone shows up as higher
-- lacunarity in the degraded constellation.
-- ---------------------------------------------------------------------------
REPLACE INTO scc_cloud_healthy OVERWRITE ALL
SELECT ARRAY_TO_STRING(ARRAY_AGG(
           CAST("x" AS VARCHAR) || ',' || CAST("y" AS VARCHAR), 16384), ',') AS "cloud"
FROM "scc_footprints"
PARTITIONED BY ALL;

REPLACE INTO scc_cloud_degraded OVERWRITE ALL
SELECT ARRAY_TO_STRING(ARRAY_AGG(
           CAST("x" AS VARCHAR) || ',' || CAST("y" AS VARCHAR), 16384), ',') AS "cloud"
FROM "scc_footprints"
WHERE NOT ("r" BETWEEN 6 AND 13 AND "c" BETWEEN 6 AND 13)
PARTITIONED BY ALL;

REPLACE INTO scc_morph_healthy OVERWRITE ALL
SELECT 'healthy' AS "constellation",
       fractal_json_value(
           fractal_morphological_complexity("cloud", 2),
           '$.dimension') AS "dimension",
       fractal_json_value(
           fractal_morphological_complexity("cloud", 2),
           '$.lacunarity') AS "lacunarity"
FROM "scc_cloud_healthy"
PARTITIONED BY ALL;

REPLACE INTO scc_morph_degraded OVERWRITE ALL
SELECT 'degraded' AS "constellation",
       fractal_json_value(
           fractal_morphological_complexity("cloud", 2),
           '$.dimension') AS "dimension",
       fractal_json_value(
           fractal_morphological_complexity("cloud", 2),
           '$.lacunarity') AS "lacunarity"
FROM "scc_cloud_degraded"
PARTITIONED BY ALL;

SELECT "constellation", ROUND("dimension", 3) AS "dimension",
       ROUND("lacunarity", 3) AS "lacunarity"
FROM "scc_morph_healthy";

SELECT "constellation", ROUND("dimension", 3) AS "dimension",
       ROUND("lacunarity", 3) AS "lacunarity"
FROM "scc_morph_degraded";

-- ---------------------------------------------------------------------------
-- 3. The link-quality series: 96 samples, a slow oscillation for the
-- first 48 and a fast one after that. Here it is a fixture, because Druid has no recursive CTE.
-- ---------------------------------------------------------------------------
-- @fixture scc_drift {"rows": [
--   {"t": 1, "v": 4.057588},
--   {"t": 2, "v": 4.969953},
--   {"t": 3, "v": 5.05683},
--   {"t": 4, "v": 5.080276},
--   {"t": 5, "v": 5.312476},
--   {"t": 6, "v": 5.089707},
--   {"t": 7, "v": 5.133077},
--   {"t": 8, "v": 4.693561},
--   {"t": 9, "v": 4.30299},
--   {"t": 10, "v": 4.366371},
--   {"t": 11, "v": 3.720606},
--   {"t": 12, "v": 3.183963},
--   {"t": 13, "v": 3.166298},
--   {"t": 14, "v": 2.960409},
--   {"t": 15, "v": 2.108518},
--   {"t": 16, "v": 2.360949},
--   {"t": 17, "v": 2.801617},
--   {"t": 18, "v": 2.972424},
--   {"t": 19, "v": 3.719701},
--   {"t": 20, "v": 3.836966},
--   {"t": 21, "v": 4.389312},
--   {"t": 22, "v": 4.368702},
--   {"t": 23, "v": 4.890962},
--   {"t": 24, "v": 5.55169},
--   {"t": 25, "v": 5.412698},
--   {"t": 26, "v": 5.68828},
--   {"t": 27, "v": 4.999886},
--   {"t": 28, "v": 5.293513},
--   {"t": 29, "v": 5.003814},
--   {"t": 30, "v": 4.568282},
--   {"t": 31, "v": 3.536553},
--   {"t": 32, "v": 3.633559},
--   {"t": 33, "v": 3.045723},
--   {"t": 34, "v": 2.555387},
--   {"t": 35, "v": 2.739866},
--   {"t": 36, "v": 2.305831},
--   {"t": 37, "v": 2.580067},
--   {"t": 38, "v": 3.119109},
--   {"t": 39, "v": 3.311365},
--   {"t": 40, "v": 3.942794},
--   {"t": 41, "v": 4.184304},
--   {"t": 42, "v": 4.289346},
--   {"t": 43, "v": 4.638921},
--   {"t": 44, "v": 5.418406},
--   {"t": 45, "v": 5.873003},
--   {"t": 46, "v": 5.468698},
--   {"t": 47, "v": 5.396872},
--   {"t": 48, "v": 4.796033},
--   {"t": 49, "v": 2.507495},
--   {"t": 50, "v": 6.486872},
--   {"t": 51, "v": 6.186121},
--   {"t": 52, "v": 2.545332},
--   {"t": 53, "v": 1.137018},
--   {"t": 54, "v": 4.65283},
--   {"t": 55, "v": 6.84096},
--   {"t": 56, "v": 4.261284},
--   {"t": 57, "v": 1.162761},
--   {"t": 58, "v": 2.507315},
--   {"t": 59, "v": 6.576242},
--   {"t": 60, "v": 6.259571},
--   {"t": 61, "v": 2.468268},
--   {"t": 62, "v": 1.382916},
--   {"t": 63, "v": 4.827713},
--   {"t": 64, "v": 7.134941},
--   {"t": 65, "v": 4.377563},
--   {"t": 66, "v": 1.195946},
--   {"t": 67, "v": 2.565505},
--   {"t": 68, "v": 6.264915},
--   {"t": 69, "v": 6.149734},
--   {"t": 70, "v": 2.155854},
--   {"t": 71, "v": 1.44033},
--   {"t": 72, "v": 4.939404},
--   {"t": 73, "v": 6.969935},
--   {"t": 74, "v": 4.097882},
--   {"t": 75, "v": 1.009994},
--   {"t": 76, "v": 2.608764},
--   {"t": 77, "v": 6.538425},
--   {"t": 78, "v": 5.859088},
--   {"t": 79, "v": 2.360186},
--   {"t": 80, "v": 1.231213},
--   {"t": 81, "v": 4.810994},
--   {"t": 82, "v": 6.961554},
--   {"t": 83, "v": 4.180755},
--   {"t": 84, "v": 1.125735},
--   {"t": 85, "v": 3.014188},
--   {"t": 86, "v": 6.707106},
--   {"t": 87, "v": 6.054916},
--   {"t": 88, "v": 2.107755},
--   {"t": 89, "v": 1.349116},
--   {"t": 90, "v": 4.965972},
--   {"t": 91, "v": 7.03501},
--   {"t": 92, "v": 4.082296},
--   {"t": 93, "v": 1.037994},
--   {"t": 94, "v": 2.914872},
--   {"t": 95, "v": 6.420097},
--   {"t": 96, "v": 5.946102}
-- ]};

REPLACE INTO scc_series OVERWRITE ALL
SELECT ARRAY_TO_STRING(ARRAY_AGG(CAST("v" AS VARCHAR), 16384), ',') AS "series"
FROM "scc_drift"
PARTITIONED BY ALL;

-- ---------------------------------------------------------------------------
-- 4. The shipped agent on the degraded constellation: morphology plus
-- link-quality drift plus a reasoned coverage alert.
-- ---------------------------------------------------------------------------
-- @call agent/network_coverage_alert {"point_cloud_table": "scc_cloud_degraded",
--                                   "point_cloud_column": "cloud",
--                                   "drift_series_table": "scc_series",
--                                   "drift_series_column": "series",
--                                   "boxcount_dim": 2, "drift_win": 48,
--                                   "drift_threshold": 0.5};

-- ---------------------------------------------------------------------------
-- 5. Secondary branch: launch-manifest scheduling. Each launch slot
-- has a capability vector [mass_margin, plane_A, plane_B, plane_C,
-- rideshare]; a replacement-satellite payload is placed on the nearest
-- slot. Vector-refine + nearest-node match, one call.
-- ---------------------------------------------------------------------------
-- @fixture scc_slots {"rows": [
--   {"id": 1, "capability": "0.9,0.8,0.0,0.0,0.1"},
--   {"id": 2, "capability": "0.5,0.0,0.9,0.1,0.4"},
--   {"id": 3, "capability": "0.3,0.0,0.1,0.9,0.9"},
--   {"id": 4, "capability": "0.6,0.1,0.8,0.1,0.2"}
-- ]};

-- The hand-composed half: the nearest slot to the replacement payload.
-- @call search/telemetry {"datasource": "scc_slots", "vectorColumn": "capability",
--                         "idColumn": "id", "query": "0.5,0.0,0.85,0.1,0.35",
--                         "k": 1} AS scc_nearest;

SELECT m."id" AS "assigned_slot",
       ROUND(1.0 / (1.0 + t."distance"), 4) AS "confidence"
FROM "scc_nearest" t, "scc_slots" m
WHERE m."id" = t."doc_id";

-- The shipped agent: same composition plus refinement, one call.
-- @call agent/schedule_workload {"task_vec": "0.5,0.0,0.85,0.1,0.35",
--                               "node_table": "scc_slots",
--                               "node_emb_col": "capability",
--                               "node_id_col": "id",
--                               "iterations": 30, "population": 50};

-- ---------------------------------------------------------------------------
-- 6. Reasoning: the combined narrative.
-- ---------------------------------------------------------------------------
-- The narrative's context is built in its own table: Druid's planner
-- rewrites a number inside a concatenation that is an argument of a
-- SQL function, and the reasoning call is one.
REPLACE INTO scc_context OVERWRITE ALL
SELECT '{"coverage":{"dimension":' || (SELECT "dimension" FROM "scc_morph_degraded")
      || ',"lacunarity":' || (SELECT "lacunarity" FROM "scc_morph_degraded")
      || '},"nearest_slot":' || (SELECT "doc_id" FROM "scc_nearest")
      || ',"degraded_footprints":' || (SELECT SUM(CASE WHEN NOT ("r" BETWEEN 6 AND 13 AND "c" BETWEEN 6 AND 13)
                                                     THEN 1 ELSE 0 END) FROM "scc_footprints")
      || '}' AS "context"
PARTITIONED BY ALL;

SELECT fractal_reason(
    'one-line summary of this constellation coverage gap and the launch slot chosen to fill it',
    "context") AS "narrative"
FROM "scc_context";

-- ---------------------------------------------------------------------------
-- 7. The headline.
--
-- The kit passes when the constellation is the one the kit drew: 400
-- healthy footprints, 336 left after the dead zone, the dead zone
-- measurably gappier than the healthy lattice, and the replacement
-- payload landed on the medium-lift slot 2. Those are the kit's own
-- numbers, not the model's opinion of them.
-- ---------------------------------------------------------------------------
SELECT CASE
           WHEN (SELECT COUNT(*) FROM "scc_footprints") = 400
            AND (SELECT SUM(CASE WHEN NOT ("r" BETWEEN 6 AND 13 AND "c" BETWEEN 6 AND 13)
                                THEN 1 ELSE 0 END) FROM "scc_footprints") = 336
            AND (SELECT COUNT(*) FROM "scc_morph_healthy" h, "scc_morph_degraded" d
                 WHERE d."lacunarity" > h."lacunarity") = 1
            AND (SELECT COUNT(*) FROM "scc_nearest") = 1
            AND (SELECT "doc_id" FROM "scc_nearest") = 2
            THEN 'HEADLINE kit=satellite-constellation-coverage ok'
            ELSE 'HEADLINE kit=satellite-constellation-coverage FAILED'
       END AS "headline";
