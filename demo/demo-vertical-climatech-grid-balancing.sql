-- demo/demo-vertical-climatech-grid-balancing.sql
--
-- FractalSQL for Apache Druid -- industry vertical: climate-tech grid
-- balancing. DOMAIN + AGENTIC kit: grid-frequency telemetry for three
-- balancing areas, 96 samples each (deviation from nominal, mHz). AREA-C
-- loses damping from sample 65: its oscillation envelope grows
-- quadratically. The stability-regime drift per area decides which
-- resources the grid carries, and a dispatch set of 4 of 6 is picked
-- with `fractal_optimize_portfolio` under a ramp-rate risk matrix.
--
--   1. Grid-frequency deviation: 3 areas x 96 samples.
--   2. Step 1: frequency-stability drift per area (and the shipped
--      agent's triage of it).
--   3. Step 2: fractal_optimize_portfolio -- pick 4 of 6 resources.
--   4. A closing fractal_reason() writes the dispatch-plan rationale.
--
-- Prerequisites: the extension is loaded on the Druid cluster. The closing
-- fractal_reason() narrative and the agents' rationales need a reasoning
-- provider (docs/reasoning-setup.md); every other step runs with no model.
--
-- Run:
--   python3 demo/run_demo.py --file demo/demo-vertical-climatech-grid-balancing.sql
--
-- ===========================================================================
-- Notes on how this runs on Druid
-- ===========================================================================
--
--   * The fixtures are @fixture directives and MSQ writes: Druid has no
--     DDL, no VALUES and no recursive CTE, so the sample index comes
--     from an UNNESTed array.
--   * The risk matrix is a cross join of the resource rows, folded into
--     one flat vector with ARRAY_AGG: Druid has no group_concat and no
--     json_each.
--   * The agents are service calls, not SQL functions: an agent reads a
--     table and reasons about it, and a Druid SQL function can do
--     neither.
--
-- Notes:
--   * Fully deterministic fixtures (no random()).
--   * Ends with a HEADLINE line computed from the kit's own results
--     (HEADLINE kit=<name> ok); the build_test kit gate greps for it.

-- ---------------------------------------------------------------------------
-- 0. Sanity check: extension loaded?
-- ---------------------------------------------------------------------------
SELECT fractal_edition(), fractal_version();

-- ---------------------------------------------------------------------------
-- 1. Grid-frequency deviation: 3 areas x 96 samples.
-- ---------------------------------------------------------------------------
REPLACE INTO cgb_freq OVERWRITE ALL
SELECT "area", "sample", "dev_mhz"
FROM (
    SELECT CASE WHEN g <= 96 THEN 'AREA-A' WHEN g <= 192 THEN 'AREA-B' ELSE 'AREA-C' END AS "area",
           CASE WHEN g <= 96 THEN g WHEN g <= 192 THEN g - 96 ELSE g - 192 END AS "sample",
           4.0 + MOD(g, 8) * 0.8
               + CASE WHEN g > 192 AND g > 64 + 192
                      THEN 0.02 * (g - 192 - 64) * (g - 192 - 64)
                      ELSE 0 END AS "dev_mhz"
    FROM UNNEST(ARRAY[
        1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16,
        17, 18, 19, 20, 21, 22, 23, 24, 25, 26, 27, 28, 29, 30, 31, 32,
        33, 34, 35, 36, 37, 38, 39, 40, 41, 42, 43, 44, 45, 46, 47, 48,
        49, 50, 51, 52, 53, 54, 55, 56, 57, 58, 59, 60, 61, 62, 63, 64,
        65, 66, 67, 68, 69, 70, 71, 72, 73, 74, 75, 76, 77, 78, 79, 80,
        81, 82, 83, 84, 85, 86, 87, 88, 89, 90, 91, 92, 93, 94, 95, 96,
        97, 98, 99, 100, 101, 102, 103, 104, 105, 106, 107, 108, 109, 110,
        111, 112, 113, 114, 115, 116, 117, 118, 119, 120, 121, 122, 123, 124,
        125, 126, 127, 128, 129, 130, 131, 132, 133, 134, 135, 136, 137, 138,
        139, 140, 141, 142, 143, 144, 145, 146, 147, 148, 149, 150, 151, 152,
        153, 154, 155, 156, 157, 158, 159, 160, 161, 162, 163, 164, 165, 166,
        167, 168, 169, 170, 171, 172, 173, 174, 175, 176, 177, 178, 179, 180,
        181, 182, 183, 184, 185, 186, 187, 188, 189, 190, 191, 192, 193, 194,
        195, 196, 197, 198, 199, 200, 201, 202, 203, 204, 205, 206, 207, 208,
        209, 210, 211, 212, 213, 214, 215, 216, 217, 218, 219, 220, 221, 222,
        223, 224, 225, 226, 227, 228, 229, 230, 231, 232, 233, 234, 235, 236,
        237, 238, 239, 240, 241, 242, 243, 244, 245, 246, 247, 248, 249, 250,
        251, 252, 253, 254, 255, 256, 257, 258, 259, 260, 261, 262, 263, 264,
        265, 266, 267, 268, 269, 270, 271, 272, 273, 274, 275, 276, 277, 278,
        279, 280, 281, 282, 283, 284, 285, 286, 287, 288]) AS t(g)
) s
PARTITIONED BY ALL;

SELECT "area", COUNT(*) AS "samples", ROUND(MAX("dev_mhz"), 2) AS "peak_dev_mhz"
FROM "cgb_freq" GROUP BY "area" ORDER BY "area";

-- ---------------------------------------------------------------------------
-- 2. Step 1: frequency-stability drift per area.
--
-- The drift is computed over each area's own series, folded into one
-- vector with ARRAY_AGG.
-- ---------------------------------------------------------------------------
REPLACE INTO cgb_drift OVERWRITE ALL
SELECT "area",
       fractal_dimension_drift(
           ARRAY_TO_STRING(ARRAY_AGG(CAST("dev_mhz" AS VARCHAR), 16384), ','), 32) AS "d"
FROM "cgb_freq"
GROUP BY "area"
PARTITIONED BY ALL;

SELECT "area",
       fractal_json_value("d", '$.drift') AS "drift",
       fractal_json_value("d", '$.recent_alpha') AS "recent_alpha",
       fractal_json_value("d", '$.baseline_alpha') AS "baseline_alpha"
FROM "cgb_drift" GROUP BY "area", "d" ORDER BY "area";

-- The shipped agent: the same composition, one call.
-- @call agent/anomaly_triage {"log_table": "cgb_freq", "metric_col": "dev_mhz",
--                            "time_col": "sample", "filter_col": "area",
--                            "filter_val": "AREA-C", "baseline_window": 32};

-- ---------------------------------------------------------------------------
-- 3. Step 2: fractal_optimize_portfolio -- pick 4 of 6 resources.
--
-- The risk matrix is ramp_i * ramp_j * rho, with rho = 1 on the
-- diagonal, 0.6 between two variable renewables, 0.1 otherwise.
-- ---------------------------------------------------------------------------
-- @fixture cgb_resources {"rows": [
--   {"id": 1, "name": "solar-farm-north", "class": "variable", "value_mu": 0.090, "ramp_risk": 0.30},
--   {"id": 2, "name": "wind-park-ridge",  "class": "variable", "value_mu": 0.100, "ramp_risk": 0.35},
--   {"id": 3, "name": "battery-4h-east",  "class": "storage",  "value_mu": 0.070, "ramp_risk": 0.08},
--   {"id": 4, "name": "battery-2h-west",  "class": "storage",  "value_mu": 0.060, "ramp_risk": 0.07},
--   {"id": 5, "name": "pumped-hydro",     "class": "dispatch", "value_mu": 0.080, "ramp_risk": 0.10},
--   {"id": 6, "name": "gas-peaker",       "class": "dispatch", "value_mu": 0.110, "ramp_risk": 0.20}
-- ]};

REPLACE INTO cgb_result OVERWRITE ALL
SELECT fractal_optimize_portfolio(
           ARRAY_TO_STRING(ARRAY_AGG(CAST(a."value_mu" AS VARCHAR), 8192), ','),
           ARRAY_TO_STRING(ARRAY_AGG(
               CAST(ROUND(a."ramp_risk" * b."ramp_risk" *
                   CASE WHEN a."id" = b."id" THEN 1.0
                        WHEN a."class" = 'variable' AND b."class" = 'variable' THEN 0.6
                        ELSE 0.1 END, 6) AS VARCHAR), 8192), ','),
           4) AS "rj"
FROM "cgb_resources" a, "cgb_resources" b
PARTITIONED BY ALL;

SELECT fractal_json_value("rj", '$.sharpe') AS "sharpe" FROM "cgb_result" GROUP BY "rj";

-- The same two vectors, kept where the agent can read them: an agent's
-- arguments are values, and these two are computed.
REPLACE INTO cgb_mu OVERWRITE ALL
SELECT ARRAY_TO_STRING(ARRAY_AGG(CAST("value_mu" AS VARCHAR), 8192), ',') AS "mu"
FROM "cgb_resources"
PARTITIONED BY ALL;

REPLACE INTO cgb_cov OVERWRITE ALL
SELECT ARRAY_TO_STRING(ARRAY_AGG(
           CAST(ROUND(a."ramp_risk" * b."ramp_risk" *
               CASE WHEN a."id" = b."id" THEN 1.0
                    WHEN a."class" = 'variable' AND b."class" = 'variable' THEN 0.6
                    ELSE 0.1 END, 6) AS VARCHAR), 8192), ',') AS "cov"
FROM "cgb_resources" a, "cgb_resources" b
PARTITIONED BY ALL;

-- The shipped agent: optimizer + reasoned rationale, one call.
-- @call agent/allocate {"mu_table": "cgb_mu", "mu_column": "mu",
--                      "cov_table": "cgb_cov", "cov_column": "cov",
--                      "cardinality": 4};

-- ---------------------------------------------------------------------------
-- 4. Reasoning: the dispatch-plan rationale.
-- ---------------------------------------------------------------------------
SELECT fractal_reason(
    'one-line rationale for this grid dispatch plan given the frequency-stability drift in AREA-C',
    '{"area_c_drift":"' || (SELECT ARRAY_TO_STRING(ARRAY_AGG(CAST("d" AS VARCHAR), 16384), ',')
                            FROM "cgb_drift" WHERE "area" = 'AREA-C' GROUP BY "area")
     || '","dispatch":"' || (SELECT ARRAY_TO_STRING(ARRAY_AGG(CAST("rj" AS VARCHAR), 8192), ',')
                            FROM "cgb_result" GROUP BY "rj")
     || '"}') AS "narrative";

-- ---------------------------------------------------------------------------
-- 5. The kit's own headline check.
--
-- The demo contract: a kit prints its headline and exits
-- non-zero unless the result holds. AREA-C's drift is the worst of the
-- three, and only AREA-C's is.
-- ---------------------------------------------------------------------------
SELECT CASE
           WHEN (SELECT fractal_json_value("d", '$.drift') FROM "cgb_drift" WHERE "area" = 'AREA-C' GROUP BY "d")
                 > (SELECT fractal_json_value("d", '$.drift') FROM "cgb_drift" WHERE "area" = 'AREA-A' GROUP BY "d")
            AND (SELECT COUNT(*) FROM "cgb_drift" WHERE fractal_json_value("d", '$.drift') > 0) = 1
            THEN 'HEADLINE kit=climatech-grid-balancing ok'
            ELSE 'HEADLINE kit=climatech-grid-balancing FAILED'
       END AS "headline";
