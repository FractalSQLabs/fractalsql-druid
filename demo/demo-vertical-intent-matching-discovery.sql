-- demo/demo-vertical-intent-matching-discovery.sql
--
-- FractalSQL for Apache Druid -- industry vertical: intent-matching
-- discovery. Twenty-four target entities in four intent clusters, a
-- content library, and the two discovery questions the vertical asks:
-- which entities should the agent engage (Scout: six *different*
-- entities, not six near-twins), and what content should it lead with
-- (a diverse recommendation, not the nearest one).
--
--   1. Twenty-four target entities in four intent clusters.
--   2. Scout: six different entities.
--   3. A diverse recommendation over the content library.
--   4. A closing fractal_reason() writes the engagement plan.
--
-- Prerequisites: the extension is loaded on the Druid cluster. The closing
-- fractal_reason() narrative needs a reasoning provider
-- (docs/reasoning-setup.md); every other step runs with no model.
--
-- Run:
--   python3 demo/run_demo.py --file demo/demo-vertical-intent-matching-discovery.sql
--
-- ===========================================================================
-- Notes on how this runs on Druid
-- ===========================================================================
--
--   * The fixtures are @fixture directives: Druid has no DDL and no
--     VALUES, so a set of rows has no SQL form.
--   * The Scout search and the recommender are service calls, and their
--     results land in datasources the kit can query: an agent reads a
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
-- 1. Twenty-four target entities in four intent clusters.
-- ---------------------------------------------------------------------------
-- @fixture imd_entities {"rows": [
--   {"id": 1, "label": "ENT-01", "category": "cluster-b", "c1": 0.2013, "c2": 0.8387, "c3": 0.3313, "c4": 0.3687, "vec": "0.2013,0.8387,0.3313,0.3687"},
--   {"id": 2, "label": "ENT-02", "category": "cluster-c", "c1": 0.3626, "c2": 0.2374, "c3": 0.8726, "c4": 0.5974, "vec": "0.3626,0.2374,0.8726,0.5974"},
--   {"id": 3, "label": "ENT-03", "category": "cluster-d", "c1": 0.5739, "c2": 0.6361, "c3": 0.2639, "c4": 0.2261, "vec": "0.5739,0.6361,0.2639,0.2261"},
--   {"id": 4, "label": "ENT-04", "category": "cluster-a", "c1": 0.9352, "c2": 0.1348, "c3": 0.2052, "c4": 0.8548, "vec": "0.9352,0.1348,0.2052,0.8548"},
--   {"id": 5, "label": "ENT-05", "category": "cluster-b", "c1": 0.1465, "c2": 0.8335, "c3": 0.2465, "c4": 0.3335, "vec": "0.1465,0.8335,0.2465,0.3335"},
--   {"id": 6, "label": "ENT-06", "category": "cluster-c", "c1": 0.3078, "c2": 0.2322, "c3": 0.9378, "c4": 0.5622, "vec": "0.3078,0.2322,0.9378,0.5622"},
--   {"id": 7, "label": "ENT-07", "category": "cluster-d", "c1": 0.6691, "c2": 0.6309, "c3": 0.1791, "c4": 0.1909, "vec": "0.6691,0.6309,0.1791,0.1909"},
--   {"id": 8, "label": "ENT-08", "category": "cluster-a", "c1": 0.8804, "c2": 0.1296, "c3": 0.2704, "c4": 0.8196, "vec": "0.8804,0.1296,0.2704,0.8196"},
--   {"id": 9, "label": "ENT-09", "category": "cluster-b", "c1": 0.2417, "c2": 0.8283, "c3": 0.3117, "c4": 0.4483, "vec": "0.2417,0.8283,0.3117,0.4483"},
--   {"id": 10, "label": "ENT-10", "category": "cluster-c", "c1": 0.253, "c2": 0.227, "c3": 0.853, "c4": 0.527, "vec": "0.253,0.227,0.853,0.527"},
--   {"id": 11, "label": "ENT-11", "category": "cluster-d", "c1": 0.6143, "c2": 0.6257, "c3": 0.2443, "c4": 0.1557, "vec": "0.6143,0.6257,0.2443,0.1557"},
--   {"id": 12, "label": "ENT-12", "category": "cluster-a", "c1": 0.9756, "c2": 0.1244, "c3": 0.1856, "c4": 0.7844, "vec": "0.9756,0.1244,0.1856,0.7844"},
--   {"id": 13, "label": "ENT-13", "category": "cluster-b", "c1": 0.1869, "c2": 0.8231, "c3": 0.3769, "c4": 0.4131, "vec": "0.1869,0.8231,0.3769,0.4131"},
--   {"id": 14, "label": "ENT-14", "category": "cluster-c", "c1": 0.3482, "c2": 0.2218, "c3": 0.9182, "c4": 0.6418, "vec": "0.3482,0.2218,0.9182,0.6418"},
--   {"id": 15, "label": "ENT-15", "category": "cluster-d", "c1": 0.5595, "c2": 0.6205, "c3": 0.1595, "c4": 0.1205, "vec": "0.5595,0.6205,0.1595,0.1205"},
--   {"id": 16, "label": "ENT-16", "category": "cluster-a", "c1": 0.9208, "c2": 0.1192, "c3": 0.2508, "c4": 0.7492, "vec": "0.9208,0.1192,0.2508,0.7492"},
--   {"id": 17, "label": "ENT-17", "category": "cluster-b", "c1": 0.2821, "c2": 0.8179, "c3": 0.2921, "c4": 0.3779, "vec": "0.2821,0.8179,0.2921,0.3779"},
--   {"id": 18, "label": "ENT-18", "category": "cluster-c", "c1": 0.2934, "c2": 0.2166, "c3": 0.9834, "c4": 0.6066, "vec": "0.2934,0.2166,0.9834,0.6066"},
--   {"id": 19, "label": "ENT-19", "category": "cluster-d", "c1": 0.6547, "c2": 0.6153, "c3": 0.2247, "c4": 0.2353, "vec": "0.6547,0.6153,0.2247,0.2353"},
--   {"id": 20, "label": "ENT-20", "category": "cluster-a", "c1": 0.866, "c2": 0.114, "c3": 0.166, "c4": 0.714, "vec": "0.866,0.114,0.166,0.714"},
--   {"id": 21, "label": "ENT-21", "category": "cluster-b", "c1": 0.2273, "c2": 0.8127, "c3": 0.3573, "c4": 0.3427, "vec": "0.2273,0.8127,0.3573,0.3427"},
--   {"id": 22, "label": "ENT-22", "category": "cluster-c", "c1": 0.3886, "c2": 0.2114, "c3": 0.8986, "c4": 0.5714, "vec": "0.3886,0.2114,0.8986,0.5714"},
--   {"id": 23, "label": "ENT-23", "category": "cluster-d", "c1": 0.5999, "c2": 0.6101, "c3": 0.2899, "c4": 0.2001, "vec": "0.5999,0.6101,0.2899,0.2001"},
--   {"id": 24, "label": "ENT-24", "category": "cluster-a", "c1": 0.9612, "c2": 0.1088, "c3": 0.2312, "c4": 0.8288, "vec": "0.9612,0.1088,0.2312,0.8288"}
-- ]};

SELECT "category", COUNT(*) AS "n" FROM "imd_entities" GROUP BY "category";

-- ---------------------------------------------------------------------------
-- 2. Scout: six different entities.
-- ---------------------------------------------------------------------------
-- @call search/explore {"datasource": "imd_entities", "vectorColumn": "vec",
--                      "idColumn": "id", "query": "[0.6,0.3,0.5,0.7]",
--                      "k": 6, "params": "{\"population_size\": 6, \"iterations\": 8}"} AS imd_picks;

SELECT p."ord" AS "ord", e."id" AS "id", e."label" AS "label", e."category" AS "category"
FROM "imd_picks" p, "imd_entities" e
WHERE p."doc_id" = e."id";

-- Coverage: the intent clusters the six picks represent.
SELECT COUNT(DISTINCT e."category") AS "categories_covered_of_4"
FROM "imd_picks" p, "imd_entities" e WHERE p."doc_id" = e."id";

-- ---------------------------------------------------------------------------
-- 3. A diverse recommendation over the content library.
-- ---------------------------------------------------------------------------
-- @fixture imd_content {"rows": [
--   {"id": 1, "label": "calculator #1", "vec": "0.1513,0.8487,0.2763"},
--   {"id": 2, "label": "technical whitepaper #2", "vec": "0.3026,0.1474,0.8776"},
--   {"id": 3, "label": "integration playbook #3", "vec": "0.5789,0.5461,0.6539"},
--   {"id": 4, "label": "case study #4", "vec": "0.9302,0.1448,0.1552"},
--   {"id": 5, "label": "analyst report #5", "vec": "0.1065,0.8435,0.2065"},
--   {"id": 6, "label": "overview guide #6", "vec": "0.2578,0.1422,0.9328"},
--   {"id": 7, "label": "calculator #7", "vec": "0.6591,0.5409,0.5841"},
--   {"id": 8, "label": "technical whitepaper #8", "vec": "0.8854,0.1396,0.2104"},
--   {"id": 9, "label": "integration playbook #9", "vec": "0.1867,0.8383,0.2617"},
--   {"id": 10, "label": "case study #10", "vec": "0.213,0.137,0.863"},
--   {"id": 11, "label": "analyst report #11", "vec": "0.6143,0.5357,0.6393"},
--   {"id": 12, "label": "overview guide #12", "vec": "0.9656,0.1344,0.1406"},
--   {"id": 13, "label": "calculator #13", "vec": "0.1419,0.8331,0.3169"},
--   {"id": 14, "label": "technical whitepaper #14", "vec": "0.2932,0.1318,0.9182"},
--   {"id": 15, "label": "integration playbook #15", "vec": "0.5695,0.5305,0.5695"},
--   {"id": 16, "label": "case study #16", "vec": "0.9208,0.1292,0.1958"},
--   {"id": 17, "label": "analyst report #17", "vec": "0.2221,0.8279,0.2471"},
--   {"id": 18, "label": "overview guide #18", "vec": "0.2484,0.1266,0.9734"},
--   {"id": 19, "label": "calculator #19", "vec": "0.6497,0.5253,0.6247"},
--   {"id": 20, "label": "technical whitepaper #20", "vec": "0.876,0.124,0.126"},
--   {"id": 21, "label": "integration playbook #21", "vec": "0.1773,0.8227,0.3023"},
--   {"id": 22, "label": "case study #22", "vec": "0.3286,0.1214,0.9036"},
--   {"id": 23, "label": "analyst report #23", "vec": "0.6049,0.5201,0.6799"},
--   {"id": 24, "label": "overview guide #24", "vec": "0.9562,0.1188,0.1812"},
--   {"id": 25, "label": "calculator #25", "vec": "0.1325,0.8175,0.2325"},
--   {"id": 26, "label": "technical whitepaper #26", "vec": "0.2838,0.1162,0.9588"},
--   {"id": 27, "label": "integration playbook #27", "vec": "0.6851,0.5149,0.6101"},
--   {"id": 28, "label": "case study #28", "vec": "0.9114,0.1136,0.2364"},
--   {"id": 29, "label": "analyst report #29", "vec": "0.2127,0.8123,0.2877"},
--   {"id": 30, "label": "overview guide #30", "vec": "0.239,0.111,0.889"}
-- ]};

-- @call agent/recommend_diverse {"catalog_table": "imd_content", "emb_col": "vec",
--                                "query_vec": "0.8,0.3,0.25", "k": 5,
--                                "id_col": "id"} AS imd_rec;

SELECT r."item_id" AS "item_id", c."label" AS "label", ROUND(r."score", 4) AS "score"
FROM "imd_rec" r, "imd_content" c WHERE r."item_id" = c."id";

-- ---------------------------------------------------------------------------
-- 4. Reasoning: the engagement-plan summary.
-- ---------------------------------------------------------------------------
SELECT fractal_reason(
    'one-line engagement plan: which entities to prioritize and which content to lead with',
    '{"entities_picked":"' || (SELECT ARRAY_TO_STRING(ARRAY_AGG(CAST("doc_id" AS VARCHAR), 8192), ',')
                               FROM "imd_picks" WHERE "doc_id" IS NOT NULL)
     || '","top_content":"' || (SELECT ARRAY_TO_STRING(ARRAY_AGG(CAST("label" AS VARCHAR), 8192), ',')
                                FROM "imd_rec" r, "imd_content" c WHERE r."item_id" = c."id")
     || '"}') AS "narrative";

-- ---------------------------------------------------------------------------
-- 5. The kit's own headline check.
--
-- The demo contract: a kit prints its headline and exits
-- non-zero unless the result holds. Six entities were picked, they span
-- at least three intent clusters, and five content items were
-- recommended.
-- ---------------------------------------------------------------------------
SELECT CASE
           WHEN (SELECT COUNT(*) FROM "imd_picks" WHERE "doc_id" IS NOT NULL) = 6
            AND (SELECT COUNT(DISTINCT e."category") FROM "imd_picks" p, "imd_entities" e WHERE p."doc_id" = e."id") >= 3
            AND (SELECT COUNT(*) FROM "imd_rec" WHERE "item_id" IS NOT NULL) = 5
            THEN 'HEADLINE kit=intent-matching-discovery ok'
            ELSE 'HEADLINE kit=intent-matching-discovery FAILED'
       END AS "headline";
