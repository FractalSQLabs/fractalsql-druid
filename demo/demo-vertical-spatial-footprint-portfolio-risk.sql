-- demo/demo-vertical-spatial-footprint-portfolio-risk.sql
--
-- FractalSQL for Apache Druid -- industry vertical: spatial footprint
-- analysis -- box-counting dimension and portfolio risk optimization.
-- Three districts' parcel footprints (a dense grid, a single arterial
-- strip and a two-corridor district) measured with
-- fractal_dimension_boxcount: the lower the dimension the more linear
-- the frontage and the more a valuation depends on a few corridors.
-- Six asset classes x 64 months of index values feed
-- fractal_dimension_dfa and fractal_optimize_portfolio (pick 3 classes
-- for the renewal push; the accelerating one is flagged), and Scout
-- (fractal_search_explore) selects six deliberately different
-- comparable parcels so the reviewer sees the spread of the market,
-- not six near-twins.
--
--   1. fractal_dimension_boxcount: the spatial footprint of each
--      district's parcels.
--   2. fractal_dimension_dfa + fractal_optimize_portfolio: 3-of-6 asset
--      classes, risk = variance x DFA exponent.
--   3. fractal_search_explore (Scout): six diverse comparable parcels.
--   4. A closing fractal_reason() writes the reviewer's note.
--
-- Prerequisites: the extension is loaded on the Druid cluster. The
-- agents' rationales and the closing narrative need a reasoning
-- provider (docs/reasoning-setup.md); every other step runs with no
-- model.
--
-- Run:
--   python3 demo/run_demo.py --file demo/demo-vertical-spatial-footprint-portfolio-risk.sql
--
-- ===========================================================================
-- Notes on how this runs on Druid
-- ===========================================================================
--
--   * The parcels and the index series are MSQ writes: Druid has no DDL
--     and no recursive CTE, so the 200-point and 64-month axes are
--     explicit arrays crossed with the districts and the classes.
--   * The parcel cloud is folded into one vector per district with
--     ARRAY_AGG: Druid has no group_concat. The dimension then reads
--     the cloud straight out of that table -- a 200-point cloud is too
--     big to come back through a scalar subquery.
--   * The profile is one write with a GROUP BY: Druid has no window
--     functions, so the class's rank (pid) is a CASE.
--   * The optimizer's inputs are the two strings it takes: the
--     expected returns, and the covariance matrix flattened row-major.
--     The covariance is written out as its own 36-row table, so the
--     flattening is the row order and not the join's.
--   * The optimizer takes three arguments on Druid; it has no seed.
--   * The comparables are an @fixture directive: Druid has no DDL and
--     no VALUES.
--   * Scout over the whole comparables table is a @call service call
--     (search/explore): it is a corpus search, not a Druid aggregate.
--     The picks are matched back to their rows by their id, not by
--     their coordinates: the service returns the id of every row the
--     population chose.
--
-- Notes:
--   * Fully deterministic fixtures (no random()).
--   * Parcel vector = [foot traffic, zoning intensity, transit access,
--     macro sensitivity].
--   * The index series for class 'class-d' accelerates from month 41.

-- ---------------------------------------------------------------------------
-- 0. Sanity check: extension loaded?
-- ---------------------------------------------------------------------------
SELECT fractal_edition(), fractal_version();

-- ---------------------------------------------------------------------------
-- 1. Parcel footprints: three districts.
-- ---------------------------------------------------------------------------
REPLACE INTO sfp_parcels OVERWRITE ALL
SELECT e."ent" AS "ent", g."pt" AS "pt",
       (MOD(g."pt" * 37, 100)) / 100.0 AS "x",
       CASE e."ent"
            WHEN 'dense-grid' THEN (MOD(g."pt" * 61, 100)) / 100.0
            WHEN 'linear-strip' THEN (MOD(g."pt" * 37, 100)) / 330.0
                                    + 0.002 * MOD(g."pt", 5)
            ELSE CASE WHEN MOD(g."pt", 2) = 0
                      THEN (MOD(g."pt" * 37, 100)) / 400.0
                      ELSE 0.8 + (MOD(g."pt" * 37, 100)) / 500.0
                 END
       END AS "y"
FROM (
    SELECT g AS "pt" FROM UNNEST(ARRAY[
        1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16, 17, 18, 19, 20,
        21, 22, 23, 24, 25, 26, 27, 28, 29, 30, 31, 32, 33, 34, 35, 36, 37, 38,
        39, 40, 41, 42, 43, 44, 45, 46, 47, 48, 49, 50, 51, 52, 53, 54, 55, 56,
        57, 58, 59, 60, 61, 62, 63, 64, 65, 66, 67, 68, 69, 70, 71, 72, 73, 74,
        75, 76, 77, 78, 79, 80, 81, 82, 83, 84, 85, 86, 87, 88, 89, 90, 91, 92,
        93, 94, 95, 96, 97, 98, 99, 100, 101, 102, 103, 104, 105, 106, 107,
        108, 109, 110, 111, 112, 113, 114, 115, 116, 117, 118, 119, 120, 121,
        122, 123, 124, 125, 126, 127, 128, 129, 130, 131, 132, 133, 134, 135,
        136, 137, 138, 139, 140, 141, 142, 143, 144, 145, 146, 147, 148, 149,
        150, 151, 152, 153, 154, 155, 156, 157, 158, 159, 160, 161, 162, 163,
        164, 165, 166, 167, 168, 169, 170, 171, 172, 173, 174, 175, 176, 177,
        178, 179, 180, 181, 182, 183, 184, 185, 186, 187, 188, 189, 190, 191,
        192, 193, 194, 195, 196, 197, 198, 199, 200]) AS t(g)
) g
CROSS JOIN (
    SELECT g AS "ent" FROM UNNEST(ARRAY[
        'dense-grid', 'linear-strip', 'dual-corridor']) AS t(g)
) e
PARTITIONED BY ALL;

REPLACE INTO sfp_cloud OVERWRITE ALL
SELECT "ent",
       ARRAY_TO_STRING(ARRAY_AGG(
           CAST("x" AS VARCHAR) || ',' || CAST("y" AS VARCHAR), 16384), ',') AS "cloud"
FROM "sfp_parcels"
GROUP BY "ent"
PARTITIONED BY ALL;

REPLACE INTO sfp_dim OVERWRITE ALL
SELECT "ent", ROUND(fractal_dimension_boxcount("cloud", 2), 3) AS "dim"
FROM "sfp_cloud"
PARTITIONED BY ALL;

SELECT "ent", "dim" FROM "sfp_dim" GROUP BY "ent", "dim" ORDER BY "ent";

-- ---------------------------------------------------------------------------
-- 2. Asset classes: 6 classes x 64 months of index value.
-- ---------------------------------------------------------------------------
REPLACE INTO sfp_index OVERWRITE ALL
SELECT e."ent" AS "ent", s."seq" AS "seq",
       (CASE e."ent"
            WHEN 'class-a' THEN 120.0 WHEN 'class-b' THEN 95.0
            WHEN 'class-c' THEN 140.0 WHEN 'class-d' THEN 110.0
            WHEN 'class-e' THEN 160.0 ELSE 85.0 END)
       * (1.0 + 0.06 * (MOD(s."seq"
                           + (CASE e."ent"
                                 WHEN 'class-a' THEN 1 WHEN 'class-b' THEN 2
                                 WHEN 'class-c' THEN 3 WHEN 'class-d' THEN 4
                                 WHEN 'class-e' THEN 5 ELSE 6 END), 7)) / 7.0)
       + CASE WHEN e."ent" = 'class-d' AND s."seq" > 40
              THEN 0.45 * (s."seq" - 40) * (s."seq" - 40)
              ELSE 0.0 END AS "val"
FROM (
    SELECT g AS "seq" FROM UNNEST(ARRAY[
        1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16, 17, 18, 19, 20,
        21, 22, 23, 24, 25, 26, 27, 28, 29, 30, 31, 32, 33, 34, 35, 36, 37, 38,
        39, 40, 41, 42, 43, 44, 45, 46, 47, 48, 49, 50, 51, 52, 53, 54, 55, 56,
        57, 58, 59, 60, 61, 62, 63, 64]) AS t(g)
) s
CROSS JOIN (
    SELECT g AS "ent" FROM UNNEST(ARRAY[
        'class-a', 'class-b', 'class-c', 'class-d', 'class-e', 'class-f']) AS t(g)
) e
PARTITIONED BY ALL;

REPLACE INTO sfp_prof OVERWRITE ALL
SELECT CASE "ent"
           WHEN 'class-a' THEN 1 WHEN 'class-b' THEN 2 WHEN 'class-c' THEN 3
           WHEN 'class-d' THEN 4 WHEN 'class-e' THEN 5 ELSE 6 END AS "pid",
       "ent" AS "ent",
       "mean_v" AS "mean_v",
       "var_v" AS "var_v",
       "dfa_alpha" AS "dfa_alpha",
       ROUND("mean_v" / 100.0, 4) AS "mu"
FROM (
    SELECT "ent",
           AVG("val") AS "mean_v",
           AVG("val" * "val") - AVG("val") * AVG("val") AS "var_v",
           fractal_dimension_dfa(
               ARRAY_TO_STRING(ARRAY_AGG(CAST("val" AS VARCHAR), 16384), ',')) AS "dfa_alpha"
    FROM "sfp_index" GROUP BY "ent"
) p
PARTITIONED BY ALL;

SELECT "ent", ROUND("mean_v", 4) AS "mean_v", ROUND("var_v", 4) AS "var_v",
       ROUND("dfa_alpha", 3) AS "dfa_alpha"
FROM "sfp_prof"
GROUP BY "ent", "mean_v", "var_v", "dfa_alpha" ORDER BY "ent";

REPLACE INTO sfp_cov_rows OVERWRITE ALL
SELECT (a."pid" - 1) * 6 + b."pid" AS "k",
       CASE WHEN a."pid" = b."pid"
            THEN ROUND(a."var_v" * a."dfa_alpha" / 100.0, 4)
            ELSE 0.0 END AS "v"
FROM "sfp_prof" a, "sfp_prof" b
PARTITIONED BY ALL;

-- The expected returns, in class order.
REPLACE INTO sfp_mu OVERWRITE ALL
SELECT MAX(CASE WHEN "pid" = 1 THEN "mu" END) || ','
       || MAX(CASE WHEN "pid" = 2 THEN "mu" END) || ','
       || MAX(CASE WHEN "pid" = 3 THEN "mu" END) || ','
       || MAX(CASE WHEN "pid" = 4 THEN "mu" END) || ','
       || MAX(CASE WHEN "pid" = 5 THEN "mu" END) || ','
       || MAX(CASE WHEN "pid" = 6 THEN "mu" END) AS "mu"
FROM "sfp_prof"
PARTITIONED BY ALL;

REPLACE INTO sfp_opt OVERWRITE ALL
SELECT fractal_optimize_portfolio(
           (SELECT "mu" FROM "sfp_mu"),
           ARRAY_TO_STRING(ARRAY_AGG(CAST("v" AS VARCHAR), 16384), ','),
           3) AS "rj"
FROM "sfp_cov_rows"
PARTITIONED BY ALL;

SELECT ROUND(fractal_json_value("rj", '$.sharpe'), 4) AS "sharpe"
FROM "sfp_opt" GROUP BY "rj";

-- The chosen entries (weight > 0; the weights are in class order).
SELECT p."ent" AS "ent", ROUND(fractal_json_value(r."rj", '$.weights[0]'), 4) AS "weight"
FROM "sfp_opt" r, "sfp_prof" p WHERE p."pid" = 1
UNION ALL
SELECT p."ent", ROUND(fractal_json_value(r."rj", '$.weights[1]'), 4)
FROM "sfp_opt" r, "sfp_prof" p WHERE p."pid" = 2
UNION ALL
SELECT p."ent", ROUND(fractal_json_value(r."rj", '$.weights[2]'), 4)
FROM "sfp_opt" r, "sfp_prof" p WHERE p."pid" = 3
UNION ALL
SELECT p."ent", ROUND(fractal_json_value(r."rj", '$.weights[3]'), 4)
FROM "sfp_opt" r, "sfp_prof" p WHERE p."pid" = 4
UNION ALL
SELECT p."ent", ROUND(fractal_json_value(r."rj", '$.weights[4]'), 4)
FROM "sfp_opt" r, "sfp_prof" p WHERE p."pid" = 5
UNION ALL
SELECT p."ent", ROUND(fractal_json_value(r."rj", '$.weights[5]'), 4)
FROM "sfp_opt" r, "sfp_prof" p WHERE p."pid" = 6;

-- The asset classes flagged for review (DFA exponent > 1.2).
SELECT "ent", ROUND("dfa_alpha", 3) AS "dfa_alpha"
FROM "sfp_prof" WHERE "dfa_alpha" > 1.2
GROUP BY "ent", "dfa_alpha" ORDER BY "dfa_alpha" DESC;

-- ---------------------------------------------------------------------------
-- 3. Scout (diversity-first): six comparable parcels.
-- ---------------------------------------------------------------------------
-- @fixture sfp_comps {"rows": [
--   {"id": 1, "label": "PARCEL-01 zone-arterial", "zone": "zone-arterial", "c1": 0.2013, "c2": 0.8387, "c3": 0.3313, "c4": 0.3687, "vec": "0.2013,0.8387,0.3313,0.3687"},
--   {"id": 2, "label": "PARCEL-02 zone-outer", "zone": "zone-outer", "c1": 0.3626, "c2": 0.2374, "c3": 0.8726, "c4": 0.5974, "vec": "0.3626,0.2374,0.8726,0.5974"},
--   {"id": 3, "label": "PARCEL-03 zone-campus", "zone": "zone-campus", "c1": 0.5739, "c2": 0.6361, "c3": 0.2639, "c4": 0.2261, "vec": "0.5739,0.6361,0.2639,0.2261"},
--   {"id": 4, "label": "PARCEL-04 zone-core", "zone": "zone-core", "c1": 0.9352, "c2": 0.1348, "c3": 0.2052, "c4": 0.8548, "vec": "0.9352,0.1348,0.2052,0.8548"},
--   {"id": 5, "label": "PARCEL-05 zone-arterial", "zone": "zone-arterial", "c1": 0.1465, "c2": 0.8335, "c3": 0.2465, "c4": 0.3335, "vec": "0.1465,0.8335,0.2465,0.3335"},
--   {"id": 6, "label": "PARCEL-06 zone-outer", "zone": "zone-outer", "c1": 0.3078, "c2": 0.2322, "c3": 0.9378, "c4": 0.5622, "vec": "0.3078,0.2322,0.9378,0.5622"},
--   {"id": 7, "label": "PARCEL-07 zone-campus", "zone": "zone-campus", "c1": 0.6691, "c2": 0.6309, "c3": 0.1791, "c4": 0.1909, "vec": "0.6691,0.6309,0.1791,0.1909"},
--   {"id": 8, "label": "PARCEL-08 zone-core", "zone": "zone-core", "c1": 0.8804, "c2": 0.1296, "c3": 0.2704, "c4": 0.8196, "vec": "0.8804,0.1296,0.2704,0.8196"},
--   {"id": 9, "label": "PARCEL-09 zone-arterial", "zone": "zone-arterial", "c1": 0.2417, "c2": 0.8283, "c3": 0.3117, "c4": 0.4483, "vec": "0.2417,0.8283,0.3117,0.4483"},
--   {"id": 10, "label": "PARCEL-10 zone-outer", "zone": "zone-outer", "c1": 0.253, "c2": 0.227, "c3": 0.853, "c4": 0.527, "vec": "0.253,0.227,0.853,0.527"},
--   {"id": 11, "label": "PARCEL-11 zone-campus", "zone": "zone-campus", "c1": 0.6143, "c2": 0.6257, "c3": 0.2443, "c4": 0.1557, "vec": "0.6143,0.6257,0.2443,0.1557"},
--   {"id": 12, "label": "PARCEL-12 zone-core", "zone": "zone-core", "c1": 0.9756, "c2": 0.1244, "c3": 0.1856, "c4": 0.7844, "vec": "0.9756,0.1244,0.1856,0.7844"},
--   {"id": 13, "label": "PARCEL-13 zone-arterial", "zone": "zone-arterial", "c1": 0.1869, "c2": 0.8231, "c3": 0.3769, "c4": 0.4131, "vec": "0.1869,0.8231,0.3769,0.4131"},
--   {"id": 14, "label": "PARCEL-14 zone-outer", "zone": "zone-outer", "c1": 0.3482, "c2": 0.2218, "c3": 0.9182, "c4": 0.6418, "vec": "0.3482,0.2218,0.9182,0.6418"},
--   {"id": 15, "label": "PARCEL-15 zone-campus", "zone": "zone-campus", "c1": 0.5595, "c2": 0.6205, "c3": 0.1595, "c4": 0.1205, "vec": "0.5595,0.6205,0.1595,0.1205"},
--   {"id": 16, "label": "PARCEL-16 zone-core", "zone": "zone-core", "c1": 0.9208, "c2": 0.1192, "c3": 0.2508, "c4": 0.7492, "vec": "0.9208,0.1192,0.2508,0.7492"},
--   {"id": 17, "label": "PARCEL-17 zone-arterial", "zone": "zone-arterial", "c1": 0.2821, "c2": 0.8179, "c3": 0.2921, "c4": 0.3779, "vec": "0.2821,0.8179,0.2921,0.3779"},
--   {"id": 18, "label": "PARCEL-18 zone-outer", "zone": "zone-outer", "c1": 0.2934, "c2": 0.2166, "c3": 0.9834, "c4": 0.6066, "vec": "0.2934,0.2166,0.9834,0.6066"},
--   {"id": 19, "label": "PARCEL-19 zone-campus", "zone": "zone-campus", "c1": 0.6547, "c2": 0.6153, "c3": 0.2247, "c4": 0.2353, "vec": "0.6547,0.6153,0.2247,0.2353"},
--   {"id": 20, "label": "PARCEL-20 zone-core", "zone": "zone-core", "c1": 0.866, "c2": 0.114, "c3": 0.166, "c4": 0.714, "vec": "0.866,0.114,0.166,0.714"},
--   {"id": 21, "label": "PARCEL-21 zone-arterial", "zone": "zone-arterial", "c1": 0.2273, "c2": 0.8127, "c3": 0.3573, "c4": 0.3427, "vec": "0.2273,0.8127,0.3573,0.3427"},
--   {"id": 22, "label": "PARCEL-22 zone-outer", "zone": "zone-outer", "c1": 0.3886, "c2": 0.2114, "c3": 0.8986, "c4": 0.5714, "vec": "0.3886,0.2114,0.8986,0.5714"},
--   {"id": 23, "label": "PARCEL-23 zone-campus", "zone": "zone-campus", "c1": 0.5999, "c2": 0.6101, "c3": 0.2899, "c4": 0.2001, "vec": "0.5999,0.6101,0.2899,0.2001"},
--   {"id": 24, "label": "PARCEL-24 zone-core", "zone": "zone-core", "c1": 0.9612, "c2": 0.1088, "c3": 0.2312, "c4": 0.8288, "vec": "0.9612,0.1088,0.2312,0.8288"}
-- ]};

-- @call search/explore {"datasource": "sfp_comps", "vectorColumn": "vec",
--                      "idColumn": "id", "query": "0.7,0.5,0.6,0.3", "k": 6,
--                      "params": "{\"population_size\": 6, \"iterations\": 8, \"mmr_lambda\": 0.15}"} AS sfp_scout;

SELECT b."ord" AS "ord", s."id" AS "id", s."label" AS "label", s."zone" AS "zone"
FROM "sfp_scout" b, "sfp_comps" s
WHERE b."doc_id" = s."id";

-- Coverage: zones represented in the six comparables.
SELECT COUNT(DISTINCT s."zone") AS "zones_covered_of_4"
FROM "sfp_scout" b, "sfp_comps" s
WHERE b."doc_id" = s."id";

-- ---------------------------------------------------------------------------
-- 4. Reasoning: reviewer's note.
-- ---------------------------------------------------------------------------
-- The narrative's context is built in its own table: Druid's planner
-- rewrites a number inside a concatenation that is an argument of a
-- SQL function, and the reasoning call is one.
REPLACE INTO sfp_context OVERWRITE ALL
SELECT '{"most_linear_district":"'
      || (SELECT "ent" FROM "sfp_dim" WHERE "dim" = (SELECT MIN("dim") FROM "sfp_dim"))
      || '","review_class":"'
      || (SELECT "ent" FROM "sfp_prof"
          WHERE "dfa_alpha" = (SELECT MAX("dfa_alpha") FROM "sfp_prof"))
      || '","zones_covered":'
      || (SELECT COUNT(DISTINCT s."zone") FROM "sfp_scout" b, "sfp_comps" s
          WHERE b."doc_id" = s."id")
      || '}' AS "context"
PARTITIONED BY ALL;

SELECT fractal_reason(
    'one-line reviewer''s note: the corridor-dependence of the footprint and the asset class to review',
    "context") AS "narrative"
FROM "sfp_context";

-- ---------------------------------------------------------------------------
-- 5. The headline.
--
-- The kit passes when its own results hold: three
-- districts measured, the arterial strip measurably more linear than
-- the dense grid, the accelerating class-d flagged by its DFA
-- exponent, and Scout's six comparables spread over at least three
-- zones. Those are the kit's own numbers, not the model's opinion of
-- them.
-- ---------------------------------------------------------------------------
SELECT CASE
           WHEN (SELECT COUNT(*) FROM "sfp_dim") = 3
            AND (SELECT COUNT(*) FROM "sfp_prof") = 6
            AND (SELECT COUNT(*) FROM "sfp_dim" d, "sfp_dim" l
                 WHERE d."ent" = 'dense-grid' AND l."ent" = 'linear-strip'
                   AND l."dim" + 0.3 < d."dim") = 1
            AND (SELECT COUNT(*) FROM "sfp_prof"
                 WHERE "ent" = 'class-d' AND "dfa_alpha" > 1.2) = 1
            AND (SELECT COUNT(*) FROM "sfp_scout" b, "sfp_comps" s
                 WHERE b."doc_id" = s."id") = 6
            AND (SELECT COUNT(DISTINCT s."zone") FROM "sfp_scout" b, "sfp_comps" s
                 WHERE b."doc_id" = s."id") >= 3
            THEN 'HEADLINE kit=spatial-footprint-portfolio-risk ok'
            ELSE 'HEADLINE kit=spatial-footprint-portfolio-risk FAILED'
       END AS "headline";
