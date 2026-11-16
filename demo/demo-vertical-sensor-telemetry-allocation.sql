-- demo/demo-vertical-sensor-telemetry-alsite.sql
--
-- FractalSQL for Apache Druid -- industry vertical: Multi-site
-- allocation: stockout prevention and non-linear demand forecasting.
-- AGENTIC kit: Six sites x 64 days of unit demand.
-- `fractal_dimension_dfa` finds the site whose demand is accelerating
-- (a viral item or a local event) rather than merely high;
-- `fractal_optimize_portfolio` picks which 3 sites get the scheduled
-- allocation from the central hub with the risk matrix inflated by the
-- DFA exponent; the site to inspect is flagged for an expedited pick
-- instead. `fractal_agent_allocate` is the shipped one-call form of the
-- optimizer step.
--
--   1. fractal_dimension_dfa over each site's daily units: non-linear
--      vs merely high.
--   2. fractal_optimize_portfolio (SFS): 3-of-6 scheduled allocation,
--      risk = variance x DFA exponent.
--   3. fractal_agent_allocate: the same optimizer plus a reasoned
--      rationale, one call.
--   4. A closing fractal_reason() writes the service-plan rationale.
--
-- Prerequisites: the extension is loaded on the Druid cluster. The closing
-- fractal_reason() narrative and the agent's rationale need a reasoning
-- provider (docs/reasoning-setup.md); every other step runs with no model.
--
-- Run:
--   python3 demo/run_demo.py --file demo/demo-vertical-sensor-telemetry-alsite.sql
--
-- ===========================================================================
-- Notes on how this runs on Druid
-- ===========================================================================
--
--   * The fixture is an MSQ write, not CREATE TABLE + INSERT, and each
--     site's 64 days are ONE row whose days are an ARRAY column --
--     the shape the fractal_* functions read, and the shape that keeps
--     the series' order intact (a DFA exponent is order-sensitive).
--   * The optimizer's covariance matrix is a cross join of the profile
--     rows, folded into one flat vector with ARRAY_AGG: Druid has no
--     group_concat and no json_each.
--   * The agent is a service call, not a SQL function: an agent reads a
--     table and reasons about it, and a Druid SQL function can do
--     neither.
--
-- Notes:
--   * Fully deterministic fixtures (no random()).
--   * mu is mean daily units per unit of stock moved; the matrix is demand
--     variance x DFA exponent.
--   * Ends with a HEADLINE line computed from the kit's own results
--     (HEADLINE kit=<name> ok); the build_test kit gate greps for it.

-- ---------------------------------------------------------------------------
-- 0. Sanity check: extension loaded?
-- ---------------------------------------------------------------------------
SELECT fractal_edition(), fractal_version();

-- ---------------------------------------------------------------------------
-- 1. Six sites x 64 days of unit demand.
--
-- site-d accelerates from day 41 (the local event); the others are
-- steady with a weekly ripple.
-- ---------------------------------------------------------------------------
REPLACE INTO sta_demand OVERWRITE ALL
SELECT "ent", "seq", "val"
FROM (
    SELECT "ent", "seq",
           "base" * (1.0 + 0.06 * MOD("seq" + "p1", 7) / 7.0)
               + CASE WHEN "p2" > 0 AND "seq" > 40
                      THEN "p2" * ("seq" - 40) * ("seq" - 40)
                      ELSE 0 END AS "val"
    FROM (
    SELECT CASE
               WHEN g <= 64 THEN 'site-a'
               WHEN g <= 128 THEN 'site-b'
               WHEN g <= 192 THEN 'site-c'
               WHEN g <= 256 THEN 'site-d'
               WHEN g <= 320 THEN 'site-e'
               ELSE 'site-f'
           END AS "ent",
           CASE
               WHEN g <= 64 THEN 120.0
               WHEN g <= 128 THEN 95.0
               WHEN g <= 192 THEN 140.0
               WHEN g <= 256 THEN 110.0
               WHEN g <= 320 THEN 160.0
               ELSE 85.0
           END AS "base",
           CASE
               WHEN g <= 64 THEN 1
               WHEN g <= 128 THEN 2
               WHEN g <= 192 THEN 3
               WHEN g <= 256 THEN 4
               WHEN g <= 320 THEN 5
               ELSE 6
           END AS "p1",
           CASE WHEN g <= 256 AND g > 192 THEN 0.45 ELSE 0 END AS "p2",
           CASE
               WHEN g <= 64 THEN g
               WHEN g <= 128 THEN g - 64
               WHEN g <= 192 THEN g - 128
               WHEN g <= 256 THEN g - 192
               WHEN g <= 320 THEN g - 256
               ELSE g - 320
           END AS "seq"
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
        279, 280, 281, 282, 283, 284, 285, 286, 287, 288, 289, 290, 291, 292,
        293, 294, 295, 296, 297, 298, 299, 300, 301, 302, 303, 304, 305, 306,
        307, 308, 309, 310, 311, 312, 313, 314, 315, 316, 317, 318, 319, 320,
        321, 322, 323, 324, 325, 326, 327, 328, 329, 330, 331, 332, 333, 334,
        335, 336, 337, 338, 339, 340, 341, 342, 343, 344, 345, 346, 347, 348,
        349, 350, 351, 352, 353, 354, 355, 356, 357, 358, 359, 360, 361, 362,
        363, 364, 365, 366, 367, 368, 369, 370, 371, 372, 373, 374, 375, 376,
        377, 378, 379, 380, 381, 382, 383, 384]) AS t(g)
    ) s
) v
PARTITIONED BY ALL;

SELECT "ent", COUNT(*) AS "days" FROM "sta_demand" GROUP BY "ent" ORDER BY "ent";

-- ---------------------------------------------------------------------------
-- 2. DFA exponent of each site.
--
-- The mean and the variance come from the same ARRAY the exponent does:
-- Druid cannot unnest an array into rows, so the summary statistics are
-- computed from the array's own elements.
-- ---------------------------------------------------------------------------
REPLACE INTO sta_prof OVERWRITE ALL
SELECT "ent",
       AVG("val") AS "mean_v",
       AVG("val" * "val") - AVG("val") * AVG("val") AS "var_v",
       fractal_dimension_dfa(
           ARRAY_TO_STRING(ARRAY_AGG(CAST("val" AS VARCHAR), 8192), ',')) AS "dfa_alpha"
FROM "sta_demand"
GROUP BY "ent"
PARTITIONED BY ALL;

SELECT "ent", ROUND("mean_v", 4) AS "mean_v", ROUND("var_v", 4) AS "var_v",
       ROUND("dfa_alpha", 3) AS "dfa_alpha"
FROM "sta_prof"
GROUP BY "ent", "mean_v", "var_v", "dfa_alpha" ORDER BY "ent";

-- ---------------------------------------------------------------------------
-- 3. fractal_optimize_portfolio: pick 3 sites.
--
-- mu is the mean daily units per unit of stock moved; the matrix is
-- demand variance x DFA exponent, flattened row-major.
-- ---------------------------------------------------------------------------
REPLACE INTO sta_result OVERWRITE ALL
SELECT fractal_optimize_portfolio(
           ARRAY_TO_STRING(ARRAY_AGG(CAST(ROUND(a."mean_v" / 100.0, 4) AS VARCHAR), 8192), ','),
           ARRAY_TO_STRING(ARRAY_AGG(
               CAST(ROUND(CASE WHEN a."ent" = b."ent"
                               THEN a."var_v" * a."dfa_alpha" / 100.0
                               ELSE 0 END, 4) AS VARCHAR), 8192), ','),
           3) AS "rj"
FROM "sta_prof" a, "sta_prof" b
PARTITIONED BY ALL;

SELECT fractal_json_value("rj", '$.sharpe') AS "sharpe" FROM "sta_result" GROUP BY "rj";

-- ---------------------------------------------------------------------------
-- 4. The shipped agent: the same optimizer plus a reasoned rationale.
--
-- An agent reads a table and reasons about it, so on Druid it is a
-- service call rather than a SQL function.
-- ---------------------------------------------------------------------------
-- @call agent/allocate {"table": "sta_demand", "column": "val",
--                      "cardinality": 3};

-- ---------------------------------------------------------------------------
-- 5. Reasoning: the service-plan rationale.
-- ---------------------------------------------------------------------------
SELECT fractal_reason(
    'one-line service-plan rationale: which sites get the resource this cycle and which needs an inspection',
    '{"surging_site":"' || (SELECT "ent" FROM "sta_prof" GROUP BY "ent", "dfa_alpha" ORDER BY "dfa_alpha" DESC LIMIT 1)
     || '"}') AS "narrative";

-- ---------------------------------------------------------------------------
-- 6. The kit's own headline check.
--
-- The demo contract: a kit prints its headline and exits
-- non-zero unless the result holds. One site is accelerating
-- (its DFA exponent is above 1.2) and it is the only one.
-- ---------------------------------------------------------------------------
SELECT CASE
           WHEN (SELECT "dfa_alpha" FROM "sta_prof" WHERE "ent" = 'site-d' GROUP BY "dfa_alpha") > 1.2
            AND (SELECT COUNT(*) FROM "sta_prof" WHERE "dfa_alpha" > 1.2) = 1
            THEN 'HEADLINE kit=sensor-telemetry-allocation ok'
            ELSE 'HEADLINE kit=sensor-telemetry-allocation FAILED'
       END AS "headline";
