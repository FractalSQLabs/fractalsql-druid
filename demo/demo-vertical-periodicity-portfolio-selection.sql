-- demo/demo-vertical-periodicity-portfolio-selection.sql
--
-- FractalSQL for Apache Druid -- industry vertical: periodicity and
-- selection -- cycle-strength detection and risk-aware portfolio
-- choice. Six items x 96 days of sales velocity with a weekly demand
-- cycle of differing strength.
--
--   1. fractal_periodogram: the dominant period of each item's sales
--      velocity.
--   2. fractal_optimize_portfolio (SFS): 3-of-6 selection for the
--      scheduled action.
--   3. fractal_agent_recommend_diverse: a diverse substitute-item set.
--   4. A closing fractal_reason() writes the decision note.
--
-- Prerequisites: the extension is loaded on the Druid cluster. The
-- agents' rationales and the closing narrative need a reasoning
-- provider (docs/reasoning-setup.md); every other step runs with no
-- model.
--
-- Run:
--   python3 demo/run_demo.py --file demo/demo-vertical-periodicity-portfolio-selection.sql
--
-- ===========================================================================
-- Notes on how this runs on Druid
-- ===========================================================================
--
--   * The sales series is an MSQ write: Druid has no DDL and no
--     recursive CTE, so the 96-day axis is an explicit array crossed
--     with the six items.
--   * The profile (mean, variance, DFA exponent, dominant frequency)
--     is one write with a GROUP BY: Druid has no window functions, so
--     the item's rank (pid) is a CASE, and the series is folded into one
--     vector with ARRAY_AGG -- Druid has no group_concat.
--   * The optimizer's inputs are the two strings it takes: the
--     expected returns, and the covariance matrix flattened row-major.
--     The covariance is written out as its own 36-row table, so the
--     flattening is the row order and not the join's.
--   * The optimizer takes three arguments on Druid; it has no seed.
--   * The catalogue is an @fixture directive: Druid has no DDL and no
--     VALUES.
--   * The recommender is a @call service call: an agent reads a table
--     and reasons about it, and a Druid SQL function can do neither.
--   * fractal_agent_diverse_portfolios -- enterprise tier. The Druid
--     build carries the multimodal optimizer as
--     fractal_optimize_portfolio_multimodal, but it is gated behind the
--     licensed core, so the kit does not call it: a dormant call would
--     print an error, and this kit must run clean.
--
-- Notes:
--   * Fully deterministic fixtures (no random()).

-- ---------------------------------------------------------------------------
-- 0. Sanity check: extension loaded?
-- ---------------------------------------------------------------------------
SELECT fractal_edition(), fractal_version();

-- ---------------------------------------------------------------------------
-- 1. Six items x 96 days of sales velocity.
--
-- A weekly cycle: the phase advances with the day, and each item's
-- own strength decides how deep the cycle bites.
-- ---------------------------------------------------------------------------
REPLACE INTO pps_sales OVERWRITE ALL
SELECT e."ent" AS "ent", s."seq" AS "seq",
       (CASE e."ent"
            WHEN 'item-a' THEN 90.0 WHEN 'item-b' THEN 110.0
            WHEN 'item-c' THEN 140.0 WHEN 'item-d' THEN 120.0
            WHEN 'item-e' THEN 100.0 ELSE 160.0 END)
       * (1.0
          + (CASE e."ent"
                WHEN 'item-a' THEN 0.35 WHEN 'item-b' THEN 0.30
                WHEN 'item-c' THEN 0.02 WHEN 'item-d' THEN 0.04
                WHEN 'item-e' THEN 0.28 ELSE 0.02 END)
            * SIN(2 * 3.141592653589793 * s."seq" / 7.0)
          + 0.004 * MOD(s."seq", 5)) AS "val"
FROM (
    SELECT g AS "seq" FROM UNNEST(ARRAY[
        1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16, 17, 18, 19, 20,
        21, 22, 23, 24, 25, 26, 27, 28, 29, 30, 31, 32, 33, 34, 35, 36, 37, 38,
        39, 40, 41, 42, 43, 44, 45, 46, 47, 48, 49, 50, 51, 52, 53, 54, 55, 56,
        57, 58, 59, 60, 61, 62, 63, 64, 65, 66, 67, 68, 69, 70, 71, 72, 73, 74,
        75, 76, 77, 78, 79, 80, 81, 82, 83, 84, 85, 86, 87, 88, 89, 90, 91, 92,
        93, 94, 95, 96]) AS t(g)
) s
CROSS JOIN (
    SELECT g AS "ent" FROM UNNEST(ARRAY[
        'item-a', 'item-b', 'item-c', 'item-d', 'item-e', 'item-f']) AS t(g)
) e
PARTITIONED BY ALL;

-- ---------------------------------------------------------------------------
-- 2. Periodicity per item (fractal_periodogram) and volatility.
--
-- The series is folded into one vector per item with ARRAY_AGG: the
-- periodogram and the DFA exponent are order-sensitive.
-- ---------------------------------------------------------------------------
REPLACE INTO pps_prof OVERWRITE ALL
SELECT CASE "ent"
           WHEN 'item-a' THEN 1 WHEN 'item-b' THEN 2 WHEN 'item-c' THEN 3
           WHEN 'item-d' THEN 4 WHEN 'item-e' THEN 5 ELSE 6 END AS "pid",
       "ent" AS "ent",
       "mean_v" AS "mean_v",
       "var_v" AS "var_v",
       "dfa_alpha" AS "dfa_alpha",
       fractal_json_value("periodogram", '$.freqs[0]') AS "freq",
       ROUND("mean_v" / 100.0, 4) AS "mu"
FROM (
    SELECT "ent",
           AVG("val") AS "mean_v",
           AVG("val" * "val") - AVG("val") * AVG("val") AS "var_v",
           fractal_dimension_dfa(
               ARRAY_TO_STRING(ARRAY_AGG(CAST("val" AS VARCHAR), 16384), ',')) AS "dfa_alpha",
           fractal_periodogram(
               ARRAY_TO_STRING(ARRAY_AGG(CAST("val" AS VARCHAR), 16384), ',')) AS "periodogram"
    FROM "pps_sales" GROUP BY "ent"
) p
PARTITIONED BY ALL;

SELECT "ent", ROUND("mean_v", 4) AS "mean_v", ROUND("var_v", 4) AS "var_v",
       ROUND("dfa_alpha", 3) AS "dfa_alpha", ROUND("freq", 4) AS "top_freq",
       ROUND(1.0 / "freq", 1) AS "samples_per_cycle"
FROM "pps_prof"
GROUP BY "ent", "mean_v", "var_v", "dfa_alpha", "freq" ORDER BY "ent";

-- ---------------------------------------------------------------------------
-- 3. fractal_optimize_portfolio: pick 3 items for the scheduled action.
--
-- The optimizer takes the expected returns and a covariance matrix
-- flattened row-major. Risk is variance x DFA exponent; the matrix is
-- written out row by row, so the flattening is the row order and not
-- the join's.
-- ---------------------------------------------------------------------------
REPLACE INTO pps_cov_rows OVERWRITE ALL
SELECT (a."pid" - 1) * 6 + b."pid" AS "k",
       CASE WHEN a."pid" = b."pid"
            THEN ROUND(a."var_v" * a."dfa_alpha" / 100.0, 4)
            ELSE 0.0 END AS "v"
FROM "pps_prof" a, "pps_prof" b
PARTITIONED BY ALL;

-- The expected returns, in item order.
REPLACE INTO pps_mu OVERWRITE ALL
SELECT MAX(CASE WHEN "pid" = 1 THEN "mu" END) || ','
       || MAX(CASE WHEN "pid" = 2 THEN "mu" END) || ','
       || MAX(CASE WHEN "pid" = 3 THEN "mu" END) || ','
       || MAX(CASE WHEN "pid" = 4 THEN "mu" END) || ','
       || MAX(CASE WHEN "pid" = 5 THEN "mu" END) || ','
       || MAX(CASE WHEN "pid" = 6 THEN "mu" END) AS "mu"
FROM "pps_prof"
PARTITIONED BY ALL;

REPLACE INTO pps_opt OVERWRITE ALL
SELECT fractal_optimize_portfolio(
           (SELECT "mu" FROM "pps_mu"),
           ARRAY_TO_STRING(ARRAY_AGG(CAST("v" AS VARCHAR), 16384), ','),
           3) AS "rj"
FROM "pps_cov_rows"
PARTITIONED BY ALL;

SELECT ROUND(fractal_json_value("rj", '$.sharpe'), 4) AS "sharpe"
FROM "pps_opt" GROUP BY "rj";

-- The chosen entries (weight > 0; the weights are in item order).
SELECT p."ent" AS "ent", ROUND(fractal_json_value(r."rj", '$.weights[0]'), 4) AS "weight"
FROM "pps_opt" r, "pps_prof" p WHERE p."pid" = 1
UNION ALL
SELECT p."ent", ROUND(fractal_json_value(r."rj", '$.weights[1]'), 4)
FROM "pps_opt" r, "pps_prof" p WHERE p."pid" = 2
UNION ALL
SELECT p."ent", ROUND(fractal_json_value(r."rj", '$.weights[2]'), 4)
FROM "pps_opt" r, "pps_prof" p WHERE p."pid" = 3
UNION ALL
SELECT p."ent", ROUND(fractal_json_value(r."rj", '$.weights[3]'), 4)
FROM "pps_opt" r, "pps_prof" p WHERE p."pid" = 4
UNION ALL
SELECT p."ent", ROUND(fractal_json_value(r."rj", '$.weights[4]'), 4)
FROM "pps_opt" r, "pps_prof" p WHERE p."pid" = 5
UNION ALL
SELECT p."ent", ROUND(fractal_json_value(r."rj", '$.weights[5]'), 4)
FROM "pps_opt" r, "pps_prof" p WHERE p."pid" = 6;

-- ---------------------------------------------------------------------------
-- 4. Diverse substitute-item set.
-- ---------------------------------------------------------------------------
-- @fixture pps_catalog {"rows": [
--   {"id": 1, "label": "alt-b 1", "vec": "0.1513,0.8487,0.2763"},
--   {"id": 2, "label": "alt-c 2", "vec": "0.3026,0.1474,0.8776"},
--   {"id": 3, "label": "alt-d 3", "vec": "0.5789,0.5461,0.6539"},
--   {"id": 4, "label": "alt-e 4", "vec": "0.9302,0.1448,0.1552"},
--   {"id": 5, "label": "alt-f 5", "vec": "0.1065,0.8435,0.2065"},
--   {"id": 6, "label": "alt-a 6", "vec": "0.2578,0.1422,0.9328"},
--   {"id": 7, "label": "alt-b 7", "vec": "0.6591,0.5409,0.5841"},
--   {"id": 8, "label": "alt-c 8", "vec": "0.8854,0.1396,0.2104"},
--   {"id": 9, "label": "alt-d 9", "vec": "0.1867,0.8383,0.2617"},
--   {"id": 10, "label": "alt-e 10", "vec": "0.213,0.137,0.863"},
--   {"id": 11, "label": "alt-f 11", "vec": "0.6143,0.5357,0.6393"},
--   {"id": 12, "label": "alt-a 12", "vec": "0.9656,0.1344,0.1406"},
--   {"id": 13, "label": "alt-b 13", "vec": "0.1419,0.8331,0.3169"},
--   {"id": 14, "label": "alt-c 14", "vec": "0.2932,0.1318,0.9182"},
--   {"id": 15, "label": "alt-d 15", "vec": "0.5695,0.5305,0.5695"},
--   {"id": 16, "label": "alt-e 16", "vec": "0.9208,0.1292,0.1958"},
--   {"id": 17, "label": "alt-f 17", "vec": "0.2221,0.8279,0.2471"},
--   {"id": 18, "label": "alt-a 18", "vec": "0.2484,0.1266,0.9734"},
--   {"id": 19, "label": "alt-b 19", "vec": "0.6497,0.5253,0.6247"},
--   {"id": 20, "label": "alt-c 20", "vec": "0.876,0.124,0.126"},
--   {"id": 21, "label": "alt-d 21", "vec": "0.1773,0.8227,0.3023"},
--   {"id": 22, "label": "alt-e 22", "vec": "0.3286,0.1214,0.9036"},
--   {"id": 23, "label": "alt-f 23", "vec": "0.6049,0.5201,0.6799"},
--   {"id": 24, "label": "alt-a 24", "vec": "0.9562,0.1188,0.1812"},
--   {"id": 25, "label": "alt-b 25", "vec": "0.1325,0.8175,0.2325"},
--   {"id": 26, "label": "alt-c 26", "vec": "0.2838,0.1162,0.9588"},
--   {"id": 27, "label": "alt-d 27", "vec": "0.6851,0.5149,0.6101"},
--   {"id": 28, "label": "alt-e 28", "vec": "0.9114,0.1136,0.2364"},
--   {"id": 29, "label": "alt-f 29", "vec": "0.2127,0.8123,0.2877"},
--   {"id": 30, "label": "alt-a 30", "vec": "0.239,0.111,0.889"}
-- ]};

-- @call agent/recommend_diverse {"catalog_table": "pps_catalog", "emb_col": "vec",
--                                "query_vec": "0.85,0.2,0.15", "k": 4,
--                                "id_col": "id"} AS pps_rec;

SELECT r."item_id" AS "item_id", c."label" AS "label", ROUND(r."score", 4) AS "score"
FROM "pps_rec" r, "pps_catalog" c
WHERE c."id" = r."item_id";

-- ---------------------------------------------------------------------------
-- 5. Reasoning: decision note.
-- ---------------------------------------------------------------------------
-- The narrative's context is built in its own table: Druid's planner
-- rewrites a number inside a concatenation that is an argument of a
-- SQL function, and the reasoning call is one.
REPLACE INTO pps_context OVERWRITE ALL
SELECT '{"most_periodic_item":"'
      || (SELECT "ent" FROM "pps_prof"
          WHERE "dfa_alpha" = (SELECT MAX("dfa_alpha") FROM "pps_prof"))
      || '","promoted_substitute":"'
      || (SELECT c."label" FROM "pps_rec" r, "pps_catalog" c
          WHERE c."id" = r."item_id" AND r."score" = (SELECT MAX("score") FROM "pps_rec"))
      || '","sharpe":' || (SELECT fractal_json_value("rj", '$.sharpe') FROM "pps_opt")
      || '}' AS "context"
PARTITIONED BY ALL;

SELECT fractal_reason(
    'one-line decision note: which items to act on, why they are periodic, and what to promote instead',
    "context") AS "narrative"
FROM "pps_context";

-- ---------------------------------------------------------------------------
-- 6. The headline.
--
-- The kit passes when its own results hold: six items
-- profiled, the strongly cyclical item-a's dominant frequency inside
-- the weekly band the series was built with, the optimizer's Sharpe
-- ratio positive, exactly three items carrying weight, and four
-- substitutes proposed. Those are the kit's own numbers, not the
-- model's opinion of them.
-- ---------------------------------------------------------------------------
SELECT CASE
           WHEN (SELECT COUNT(*) FROM "pps_prof") = 6
            AND (SELECT "freq" FROM "pps_prof" WHERE "ent" = 'item-a') > 0.13
            AND (SELECT "freq" FROM "pps_prof" WHERE "ent" = 'item-a') < 0.16
            AND (SELECT fractal_json_value("rj", '$.sharpe') FROM "pps_opt") > 0
            AND (SELECT CASE WHEN fractal_json_value("rj", '$.weights[0]') > 0 THEN 1 ELSE 0 END FROM "pps_opt")
              + (SELECT CASE WHEN fractal_json_value("rj", '$.weights[1]') > 0 THEN 1 ELSE 0 END FROM "pps_opt")
              + (SELECT CASE WHEN fractal_json_value("rj", '$.weights[2]') > 0 THEN 1 ELSE 0 END FROM "pps_opt")
              + (SELECT CASE WHEN fractal_json_value("rj", '$.weights[3]') > 0 THEN 1 ELSE 0 END FROM "pps_opt")
              + (SELECT CASE WHEN fractal_json_value("rj", '$.weights[4]') > 0 THEN 1 ELSE 0 END FROM "pps_opt")
              + (SELECT CASE WHEN fractal_json_value("rj", '$.weights[5]') > 0 THEN 1 ELSE 0 END FROM "pps_opt")
              = 3
            AND (SELECT COUNT(*) FROM "pps_rec") = 4
            THEN 'HEADLINE kit=periodicity-portfolio-selection ok'
            ELSE 'HEADLINE kit=periodicity-portfolio-selection FAILED'
       END AS "headline";
