-- demo/demo-vertical-document-risk-drift.sql
--
-- FractalSQL for Apache Druid -- industry vertical: document risk
-- drift. Four agreements x 96 weekly clause-risk reviews; DOC-C
-- inflates from week 65. The drift exponent compares the recent window
-- against the baseline window of the same series, and the kit reads the
-- reviewer-ready replacement language from a diverse (not merely
-- nearest) set of approved clauses.
--
--   1. Clause-risk telemetry: 4 agreements x 96 weekly reviews.
--   2. The regime drift and the DFA exponent per agreement.
--   3. fractal_agent_anomaly_triage: the drifting agreement against a
--      stable one.
--   4. Scout: six different clause variants.
--   5. Diverse approved replacement clauses.
--   6. A closing fractal_reason() writes the reviewer-ready note.
--
-- Prerequisites: the extension is loaded on the Druid cluster. The closing
-- fractal_reason() narrative and the agent's triage need a reasoning
-- provider (docs/reasoning-setup.md); every other step runs with no model.
--
-- Run:
--   python3 demo/run_demo.py --file demo/demo-vertical-document-risk-drift.sql
--
-- ===========================================================================
-- Notes on how this runs on Druid
-- ===========================================================================
--
--   * The fixtures are MSQ writes and @fixture directives: Druid has no
--     DDL, no VALUES and no recursive CTE.
--   * The series is folded into one vector per agreement with ARRAY_AGG:
--     Druid has no group_concat, and the drift exponent is
--     order-sensitive.
--   * The agents are service calls, not SQL functions: an agent reads a
--     table and reasons about it, and a Druid SQL function can do
--     neither. The Scout search and the recommender land in
--     datasources the kit can query.
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
-- 1. Clause-risk telemetry: 4 agreements x 96 weekly reviews.
-- ---------------------------------------------------------------------------
REPLACE INTO drd_risk OVERWRITE ALL
SELECT "ent", "seq", "val"
FROM (
    SELECT CASE
               WHEN g <= 96 THEN 'DOC-A'
               WHEN g <= 192 THEN 'DOC-B'
               WHEN g <= 288 THEN 'DOC-C'
               ELSE 'DOC-D'
           END AS "ent",
           CASE
               WHEN g <= 96 THEN g
               WHEN g <= 192 THEN g - 96
               WHEN g <= 288 THEN g - 192
               ELSE g - 288
           END AS "seq",
           CASE
               WHEN g <= 96 THEN 38.0
               WHEN g <= 192 THEN 52.0
               WHEN g <= 288 THEN 45.0
               ELSE 61.0
           END * (1.0 + 0.004 * MOD(CASE
               WHEN g <= 96 THEN g
               WHEN g <= 192 THEN g - 96
               WHEN g <= 288 THEN g - 192
               ELSE g - 288
           END, 8))
           + CASE WHEN g > 192 + 64 AND g <= 288
                  THEN 45.0 * 0.0024 * (g - 192 - 64) * (g - 192 - 64)
                  ELSE 0 END AS "val"
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
PARTITIONED BY ALL;

-- ---------------------------------------------------------------------------
-- 2. The regime drift and the DFA exponent per agreement.
-- ---------------------------------------------------------------------------
REPLACE INTO drd_prof OVERWRITE ALL
SELECT "ent",
       AVG("val") AS "mean_v",
       AVG("val" * "val") - AVG("val") * AVG("val") AS "var_v",
       fractal_dimension_dfa(
           ARRAY_TO_STRING(ARRAY_AGG(CAST("val" AS VARCHAR), 16384), ',')) AS "dfa_alpha",
       fractal_dimension_drift(
           ARRAY_TO_STRING(ARRAY_AGG(CAST("val" AS VARCHAR), 16384), ','), 32) AS "dj"
FROM "drd_risk"
GROUP BY "ent"
PARTITIONED BY ALL;

SELECT "ent", ROUND("mean_v", 4) AS "mean_v", ROUND("var_v", 4) AS "var_v",
       ROUND("dfa_alpha", 3) AS "dfa_alpha",
       ROUND(fractal_json_value("dj", '$.drift'), 4) AS "drift",
       ROUND(fractal_json_value("dj", '$.recent_alpha'), 4) AS "recent_alpha",
       ROUND(fractal_json_value("dj", '$.baseline_alpha'), 4) AS "baseline_alpha"
FROM "drd_prof"
GROUP BY "ent", "mean_v", "var_v", "dfa_alpha", "dj" ORDER BY "ent";

-- ---------------------------------------------------------------------------
-- 3. fractal_agent_anomaly_triage: the drifting agreement against a
-- stable one.
-- ---------------------------------------------------------------------------
-- @call agent/anomaly_triage {"log_table": "drd_risk", "metric_col": "val",
--                            "time_col": "seq", "filter_col": "ent",
--                            "filter_val": "DOC-C", "baseline_window": 32};

-- @call agent/anomaly_triage {"log_table": "drd_risk", "metric_col": "val",
--                            "time_col": "seq", "filter_col": "ent",
--                            "filter_val": "DOC-A", "baseline_window": 32};

-- ---------------------------------------------------------------------------
-- 4. Scout: six different clause variants.
-- ---------------------------------------------------------------------------
-- @fixture drd_clauses {"rows": [
--   {"id": 1, "label": "CL-01 data handling", "family": "data handling", "c1": 0.2013, "c2": 0.8387, "c3": 0.3313, "c4": 0.3687, "vec": "0.2013,0.8387,0.3313,0.3687"},
--   {"id": 2, "label": "CL-02 termination", "family": "termination", "c1": 0.3626, "c2": 0.2374, "c3": 0.8726, "c4": 0.5974, "vec": "0.3626,0.2374,0.8726,0.5974"},
--   {"id": 3, "label": "CL-03 scope limits", "family": "scope limits", "c1": 0.5739, "c2": 0.6361, "c3": 0.2639, "c4": 0.2261, "vec": "0.5739,0.6361,0.2639,0.2261"},
--   {"id": 4, "label": "CL-04 liability", "family": "liability", "c1": 0.9352, "c2": 0.1348, "c3": 0.2052, "c4": 0.8548, "vec": "0.9352,0.1348,0.2052,0.8548"},
--   {"id": 5, "label": "CL-05 data handling", "family": "data handling", "c1": 0.1465, "c2": 0.8335, "c3": 0.2465, "c4": 0.3335, "vec": "0.1465,0.8335,0.2465,0.3335"},
--   {"id": 6, "label": "CL-06 termination", "family": "termination", "c1": 0.3078, "c2": 0.2322, "c3": 0.9378, "c4": 0.5622, "vec": "0.3078,0.2322,0.9378,0.5622"},
--   {"id": 7, "label": "CL-07 scope limits", "family": "scope limits", "c1": 0.6691, "c2": 0.6309, "c3": 0.1791, "c4": 0.1909, "vec": "0.6691,0.6309,0.1791,0.1909"},
--   {"id": 8, "label": "CL-08 liability", "family": "liability", "c1": 0.8804, "c2": 0.1296, "c3": 0.2704, "c4": 0.8196, "vec": "0.8804,0.1296,0.2704,0.8196"},
--   {"id": 9, "label": "CL-09 data handling", "family": "data handling", "c1": 0.2417, "c2": 0.8283, "c3": 0.3117, "c4": 0.4483, "vec": "0.2417,0.8283,0.3117,0.4483"},
--   {"id": 10, "label": "CL-10 termination", "family": "termination", "c1": 0.253, "c2": 0.227, "c3": 0.853, "c4": 0.527, "vec": "0.253,0.227,0.853,0.527"},
--   {"id": 11, "label": "CL-11 scope limits", "family": "scope limits", "c1": 0.6143, "c2": 0.6257, "c3": 0.2443, "c4": 0.1557, "vec": "0.6143,0.6257,0.2443,0.1557"},
--   {"id": 12, "label": "CL-12 liability", "family": "liability", "c1": 0.9756, "c2": 0.1244, "c3": 0.1856, "c4": 0.7844, "vec": "0.9756,0.1244,0.1856,0.7844"},
--   {"id": 13, "label": "CL-13 data handling", "family": "data handling", "c1": 0.1869, "c2": 0.8231, "c3": 0.3769, "c4": 0.4131, "vec": "0.1869,0.8231,0.3769,0.4131"},
--   {"id": 14, "label": "CL-14 termination", "family": "termination", "c1": 0.3482, "c2": 0.2218, "c3": 0.9182, "c4": 0.6418, "vec": "0.3482,0.2218,0.9182,0.6418"},
--   {"id": 15, "label": "CL-15 scope limits", "family": "scope limits", "c1": 0.5595, "c2": 0.6205, "c3": 0.1595, "c4": 0.1205, "vec": "0.5595,0.6205,0.1595,0.1205"},
--   {"id": 16, "label": "CL-16 liability", "family": "liability", "c1": 0.9208, "c2": 0.1192, "c3": 0.2508, "c4": 0.7492, "vec": "0.9208,0.1192,0.2508,0.7492"},
--   {"id": 17, "label": "CL-17 data handling", "family": "data handling", "c1": 0.2821, "c2": 0.8179, "c3": 0.2921, "c4": 0.3779, "vec": "0.2821,0.8179,0.2921,0.3779"},
--   {"id": 18, "label": "CL-18 termination", "family": "termination", "c1": 0.2934, "c2": 0.2166, "c3": 0.9834, "c4": 0.6066, "vec": "0.2934,0.2166,0.9834,0.6066"},
--   {"id": 19, "label": "CL-19 scope limits", "family": "scope limits", "c1": 0.6547, "c2": 0.6153, "c3": 0.2247, "c4": 0.2353, "vec": "0.6547,0.6153,0.2247,0.2353"},
--   {"id": 20, "label": "CL-20 liability", "family": "liability", "c1": 0.866, "c2": 0.114, "c3": 0.166, "c4": 0.714, "vec": "0.866,0.114,0.166,0.714"},
--   {"id": 21, "label": "CL-21 data handling", "family": "data handling", "c1": 0.2273, "c2": 0.8127, "c3": 0.3573, "c4": 0.3427, "vec": "0.2273,0.8127,0.3573,0.3427"},
--   {"id": 22, "label": "CL-22 termination", "family": "termination", "c1": 0.3886, "c2": 0.2114, "c3": 0.8986, "c4": 0.5714, "vec": "0.3886,0.2114,0.8986,0.5714"},
--   {"id": 23, "label": "CL-23 scope limits", "family": "scope limits", "c1": 0.5999, "c2": 0.6101, "c3": 0.2899, "c4": 0.2001, "vec": "0.5999,0.6101,0.2899,0.2001"},
--   {"id": 24, "label": "CL-24 liability", "family": "liability", "c1": 0.9612, "c2": 0.1088, "c3": 0.2312, "c4": 0.8288, "vec": "0.9612,0.1088,0.2312,0.8288"}
-- ]};

-- @call search/explore {"datasource": "drd_clauses", "vectorColumn": "vec",
--                      "idColumn": "id", "query": "[0.5,0.6,0.4,0.5]",
--                      "k": 6, "params": "{\"population_size\": 6, \"iterations\": 8}"} AS drd_picks;

SELECT p."ord" AS "ord", c."id" AS "id", c."label" AS "label", c."family" AS "family"
FROM "drd_picks" p, "drd_clauses" c
WHERE p."doc_id" = c."id"
ORDER BY p."ord";

-- Coverage: the clause families the six picks represent.
SELECT COUNT(DISTINCT c."family") AS "families_covered_of_4"
FROM "drd_picks" p, "drd_clauses" c WHERE p."doc_id" = c."id";

-- ---------------------------------------------------------------------------
-- 5. Diverse approved replacement clauses.
-- ---------------------------------------------------------------------------
-- @fixture drd_approved {"rows": [
--   {"id": 1, "label": "APPROVED-01 data handling", "vec": "0.1513,0.8487,0.2763"},
--   {"id": 2, "label": "APPROVED-02 termination", "vec": "0.3026,0.1474,0.8776"},
--   {"id": 3, "label": "APPROVED-03 scope limits", "vec": "0.5789,0.5461,0.6539"},
--   {"id": 4, "label": "APPROVED-04 liability", "vec": "0.9302,0.1448,0.1552"},
--   {"id": 5, "label": "APPROVED-05 data handling", "vec": "0.1065,0.8435,0.2065"},
--   {"id": 6, "label": "APPROVED-06 termination", "vec": "0.2578,0.1422,0.9328"},
--   {"id": 7, "label": "APPROVED-07 scope limits", "vec": "0.6591,0.5409,0.5841"},
--   {"id": 8, "label": "APPROVED-08 liability", "vec": "0.8854,0.1396,0.2104"},
--   {"id": 9, "label": "APPROVED-09 data handling", "vec": "0.1867,0.8383,0.2617"},
--   {"id": 10, "label": "APPROVED-10 termination", "vec": "0.213,0.137,0.863"},
--   {"id": 11, "label": "APPROVED-11 scope limits", "vec": "0.6143,0.5357,0.6393"},
--   {"id": 12, "label": "APPROVED-12 liability", "vec": "0.9656,0.1344,0.1406"},
--   {"id": 13, "label": "APPROVED-13 data handling", "vec": "0.1419,0.8331,0.3169"},
--   {"id": 14, "label": "APPROVED-14 termination", "vec": "0.2932,0.1318,0.9182"},
--   {"id": 15, "label": "APPROVED-15 scope limits", "vec": "0.5695,0.5305,0.5695"},
--   {"id": 16, "label": "APPROVED-16 liability", "vec": "0.9208,0.1292,0.1958"},
--   {"id": 17, "label": "APPROVED-17 data handling", "vec": "0.2221,0.8279,0.2471"},
--   {"id": 18, "label": "APPROVED-18 termination", "vec": "0.2484,0.1266,0.9734"},
--   {"id": 19, "label": "APPROVED-19 scope limits", "vec": "0.6497,0.5253,0.6247"},
--   {"id": 20, "label": "APPROVED-20 liability", "vec": "0.876,0.124,0.126"}
-- ]};

-- @call agent/recommend_diverse {"catalog_table": "drd_approved", "emb_col": "vec",
--                                "query_vec": "0.85,0.2,0.15", "k": 4,
--                                "id_col": "id"} AS drd_rec;

SELECT r."item_id" AS "item_id", a."label" AS "label", ROUND(r."score", 4) AS "score"
FROM "drd_rec" r, "drd_approved" a WHERE r."item_id" = a."id";

-- ---------------------------------------------------------------------------
-- 6. Reasoning: the reviewer-ready note.
-- ---------------------------------------------------------------------------
SELECT fractal_reason(
    'one-line reviewer-ready note: which agreement drifted, the exposure, and the replacement language to propose',
    '{"drifting_agreement":"' || (SELECT ARRAY_TO_STRING(ARRAY_AGG(CAST("ent" AS VARCHAR), 8192), ',')
                                 FROM "drd_prof" WHERE fractal_json_value("dj", '$.drift') > 0.5 GROUP BY "ent")
     || '","replacement":"' || (SELECT ARRAY_TO_STRING(ARRAY_AGG(CAST("label" AS VARCHAR), 8192), ',')
                                FROM "drd_rec" r, "drd_approved" a WHERE r."item_id" = a."id")
     || '"}') AS "narrative";

-- ---------------------------------------------------------------------------
-- 7. The kit's own headline check.
--
-- The demo contract: a kit prints its headline and exits
-- non-zero unless the result holds. DOC-C drifted and DOC-A did not;
-- the six picks cover at least three clause families; and four
-- replacement clauses were recommended.
-- ---------------------------------------------------------------------------
SELECT CASE
           WHEN (SELECT fractal_json_value("dj", '$.drift') FROM "drd_prof" WHERE "ent" = 'DOC-C' GROUP BY "dj") > 0.5
            AND (SELECT fractal_json_value("dj", '$.drift') FROM "drd_prof" WHERE "ent" = 'DOC-A' GROUP BY "dj") < 0
            AND (SELECT COUNT(*) FROM "drd_picks" WHERE "doc_id" IS NOT NULL) = 6
            AND (SELECT COUNT(DISTINCT c."family") FROM "drd_picks" p, "drd_clauses" c WHERE p."doc_id" = c."id") >= 3
            AND (SELECT COUNT(*) FROM "drd_rec" WHERE "item_id" IS NOT NULL) = 4
            THEN 'HEADLINE kit=document-risk-drift ok'
            ELSE 'HEADLINE kit=document-risk-drift FAILED'
       END AS "headline";
