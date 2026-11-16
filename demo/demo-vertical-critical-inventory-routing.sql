-- demo/demo-vertical-critical-inventory-routing.sql
--
-- FractalSQL for Apache Druid -- industry vertical: critical-inventory
-- routing. AGENTIC kit: six regional depots, 64 days of consumption
-- each. D1-D3 and D5-D6 are steady (a weekly cycle on a base level);
-- D4 starts accelerating on day 41 -- the non-linear spike a plain
-- average would hide.
--
--   1. fractal_dimension_dfa over each depot's consumption: the
--      non-linear depot, not merely the busy one.
--   2. fractal_optimize_portfolio (SFS): scheduled replenishment for 3
--      of the 6 depots, with the risk matrix inflated by the DFA
--      exponent.
--   3. The shipped agent: the same optimizer plus a reasoned rationale,
--      one call.
--   4. A closing fractal_reason() writes the rebalancing rationale.
--
-- Prerequisites: the extension is loaded on the Druid cluster. The closing
-- fractal_reason() narrative and the agent's rationale need a reasoning
-- provider (docs/reasoning-setup.md); every other step runs with no model.
--
-- Run:
--   python3 demo/run_demo.py --file demo/demo-vertical-critical-inventory-routing.sql
--
-- ===========================================================================
-- Notes on how this runs on Druid
-- ===========================================================================
--
--   * The fixtures are MSQ writes, not CREATE TABLE + INSERT, and the
--     consumption is computed in the query (there is no recursive CTE).
--   * The optimizer's covariance matrix is a cross join of the profile
--     rows, folded into one flat vector with ARRAY_AGG: Druid has no
--     group_concat and no json_each.
--   * The agent is a service call, not a SQL function: an agent reads a
--     table and reasons about it, and a Druid SQL function can do
--     neither.
--
-- Notes:
--   * Fully deterministic fixtures (no random()).
--   * mu is mean daily consumption per unit moved; the matrix is demand
--     variance x DFA exponent.
--   * Ends with a HEADLINE line computed from the kit's own results
--     (HEADLINE kit=<name> ok); the build_test kit gate greps for it.

-- ---------------------------------------------------------------------------
-- 0. Sanity check: extension loaded?
-- ---------------------------------------------------------------------------
SELECT fractal_edition(), fractal_version();

-- ---------------------------------------------------------------------------
-- 1. Six regional depots, 64 days of consumption each.
-- ---------------------------------------------------------------------------
-- @fixture cir_depots {"rows": [
--   {"id": 1, "region": "north",   "base": 120},
--   {"id": 2, "region": "south",   "base": 95},
--   {"id": 3, "region": "east",    "base": 140},
--   {"id": 4, "region": "west",    "base": 110},
--   {"id": 5, "region": "central", "base": 160},
--   {"id": 6, "region": "coastal", "base": 85}
-- ]};

REPLACE INTO cir_consumption OVERWRITE ALL
SELECT p."id" AS "depot_id", p."region" AS "region", d."day",
       p."base" * (1.0 + 0.06 * MOD(d."day" + p."id", 7) / 7.0)
       + CASE WHEN p."id" = 4 AND d."day" > 40
              THEN 0.45 * (d."day" - 40) * (d."day" - 40)
              ELSE 0 END AS "units"
FROM "cir_depots" p
CROSS JOIN (
    SELECT g AS "day"
    FROM UNNEST(ARRAY[
        1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16,
        17, 18, 19, 20, 21, 22, 23, 24, 25, 26, 27, 28, 29, 30, 31, 32,
        33, 34, 35, 36, 37, 38, 39, 40, 41, 42, 43, 44, 45, 46, 47, 48,
        49, 50, 51, 52, 53, 54, 55, 56, 57, 58, 59, 60, 61, 62, 63, 64]) AS t(g)
) d
PARTITIONED BY ALL;

-- ---------------------------------------------------------------------------
-- 2. Step 1: DFA exponent, mean and variance per depot.
--
-- The series is folded into one vector per depot with ARRAY_AGG: the
-- DFA exponent is order-sensitive, and ARRAY_AGG keeps the scan's
-- order.
-- ---------------------------------------------------------------------------
REPLACE INTO cir_profile OVERWRITE ALL
SELECT "depot_id",
       "region",
       AVG("units") AS "mean_units",
       AVG("units" * "units") - AVG("units") * AVG("units") AS "var_units",
       fractal_dimension_dfa(
           ARRAY_TO_STRING(ARRAY_AGG(CAST("units" AS VARCHAR), 16384), ',')) AS "dfa_alpha"
FROM (
    SELECT "depot_id", "region", "units" FROM "cir_consumption"
) x
GROUP BY "depot_id", "region"
PARTITIONED BY ALL;

SELECT "depot_id", "region", ROUND("mean_units", 2) AS "mean_units",
       ROUND("var_units", 2) AS "var_units", ROUND("dfa_alpha", 3) AS "dfa_alpha"
FROM "cir_profile"
GROUP BY "depot_id", "region", "mean_units", "var_units", "dfa_alpha"
ORDER BY "depot_id";

-- ---------------------------------------------------------------------------
-- 3. Step 2: scheduled replenishment for 3 of the 6 depots.
--
-- mu_i = mean daily consumption (need served per unit moved); the
-- matrix is a diagonal risk matrix, var_i x alpha_i, flat row-major.
-- ---------------------------------------------------------------------------
REPLACE INTO cir_result OVERWRITE ALL
SELECT fractal_optimize_portfolio(
           ARRAY_TO_STRING(ARRAY_AGG(CAST(ROUND(a."mean_units" / 100.0, 4) AS VARCHAR), 8192), ','),
           ARRAY_TO_STRING(ARRAY_AGG(
               CAST(ROUND(CASE WHEN a."depot_id" = b."depot_id"
                               THEN a."var_units" * a."dfa_alpha" / 100.0
                               ELSE 0 END, 4) AS VARCHAR), 8192), ','),
           3) AS "rj"
FROM "cir_profile" a, "cir_profile" b
PARTITIONED BY ALL;

SELECT fractal_json_value("rj", '$.sharpe') AS "sharpe" FROM "cir_result" GROUP BY "rj";

-- ---------------------------------------------------------------------------
-- 4. The shipped agent: the same optimizer plus a reasoned rationale.
-- ---------------------------------------------------------------------------
-- @call agent/allocate {"table": "cir_consumption", "column": "units",
--                      "entity_column": "depot_id", "cardinality": 3};

-- ---------------------------------------------------------------------------
-- 5. Reasoning: the rebalancing rationale.
-- ---------------------------------------------------------------------------
SELECT fractal_reason(
    'one-line rationale for this critical-inventory replenishment plan',
    '{"plan":"' || (SELECT ARRAY_TO_STRING(ARRAY_AGG(CAST("region" AS VARCHAR), 8192), ',')
                   FROM "cir_profile" WHERE "dfa_alpha" > 1.2 GROUP BY "depot_id", "region")
     || '","sharpe":"' || (SELECT ARRAY_TO_STRING(ARRAY_AGG(CAST("rj" AS VARCHAR), 8192), ',')
                          FROM "cir_result" GROUP BY "rj")
     || '"}') AS "narrative";

-- ---------------------------------------------------------------------------
-- 6. The kit's own headline check.
--
-- The demo contract: a kit prints its headline and exits
-- non-zero unless the result holds. The west depot is the accelerating
-- one, and it is the only one above the 1.2 exponent.
-- ---------------------------------------------------------------------------
SELECT CASE
           WHEN (SELECT "dfa_alpha" FROM "cir_profile" WHERE "depot_id" = 4 GROUP BY "dfa_alpha") > 1.2
            AND (SELECT COUNT(*) FROM "cir_profile" WHERE "dfa_alpha" > 1.2) = 1
            THEN 'HEADLINE kit=critical-inventory-routing ok'
            ELSE 'HEADLINE kit=critical-inventory-routing FAILED'
       END AS "headline";
