-- demo/demo-vertical-agentic-recall-recommendation.sql
--
-- FractalSQL for Apache Druid -- industry vertical: recall and
-- recommendation. Thirty offers in four kinds and thirty past sessions in
-- three groups. Scout picks six *different* offers to test, the similar
-- past sessions are recalled, and the model is asked a plain-English
-- question about the list.
--
--   1. The offers.
--   2. Scout (diversity-first): six different offers.
--   3. The past sessions + the recall.
--   4. fractal_sql_agent: a question in plain English.
--   5. Reasoning: the follow-up message brief.
--
-- Prerequisites: the extension is loaded on the Druid cluster. The
-- narrative and the agents' rationales need a reasoning provider
-- (docs/reasoning-setup.md); every other step runs with no model.
--
-- Run:
--   python3 demo/run_demo.py --file demo/demo-vertical-agentic-recall-recommendation.sql
--
-- ===========================================================================
-- Notes on how this runs on Druid
-- ===========================================================================
--
--   * The fixtures are @fixture directives: Druid has no DDL and no
--     VALUES, so a set of rows has no SQL form.
--   * The Scout search and the agents are service calls: an agent reads
--     a table and reasons about it, and a Druid SQL function can do
--     neither.
--
-- Notes:
--   * Fully deterministic fixtures (no random()).

-- ---------------------------------------------------------------------------
-- 0. Sanity check: extension loaded?
-- ---------------------------------------------------------------------------
SELECT fractal_edition(), fractal_version();

-- ---------------------------------------------------------------------------
-- 1. The offers.
-- ---------------------------------------------------------------------------
-- @fixture arr_offers {"rows": [
--   {"id": 1, "label": "OFFER-01 offer-priority", "kind": "offer-priority", "c1": 0.2013, "c2": 0.8387, "c3": 0.3313, "c4": 0.3687, "vec": "0.2013,0.8387,0.3313,0.3687"},
--   {"id": 2, "label": "OFFER-02 offer-credit", "kind": "offer-credit", "c1": 0.3626, "c2": 0.2374, "c3": 0.8726, "c4": 0.5974, "vec": "0.3626,0.2374,0.8726,0.5974"},
--   {"id": 3, "label": "OFFER-03 offer-discount", "kind": "offer-discount", "c1": 0.5739, "c2": 0.6361, "c3": 0.2639, "c4": 0.2261, "vec": "0.5739,0.6361,0.2639,0.2261"},
--   {"id": 4, "label": "OFFER-04 offer-bundle", "kind": "offer-bundle", "c1": 0.9352, "c2": 0.1348, "c3": 0.2052, "c4": 0.8548, "vec": "0.9352,0.1348,0.2052,0.8548"},
--   {"id": 5, "label": "OFFER-05 offer-priority", "kind": "offer-priority", "c1": 0.1465, "c2": 0.8335, "c3": 0.2465, "c4": 0.3335, "vec": "0.1465,0.8335,0.2465,0.3335"},
--   {"id": 6, "label": "OFFER-06 offer-credit", "kind": "offer-credit", "c1": 0.3078, "c2": 0.2322, "c3": 0.9378, "c4": 0.5622, "vec": "0.3078,0.2322,0.9378,0.5622"},
--   {"id": 7, "label": "OFFER-07 offer-discount", "kind": "offer-discount", "c1": 0.6691, "c2": 0.6309, "c3": 0.1791, "c4": 0.1909, "vec": "0.6691,0.6309,0.1791,0.1909"},
--   {"id": 8, "label": "OFFER-08 offer-bundle", "kind": "offer-bundle", "c1": 0.8804, "c2": 0.1296, "c3": 0.2704, "c4": 0.8196, "vec": "0.8804,0.1296,0.2704,0.8196"},
--   {"id": 9, "label": "OFFER-09 offer-priority", "kind": "offer-priority", "c1": 0.2417, "c2": 0.8283, "c3": 0.3117, "c4": 0.4483, "vec": "0.2417,0.8283,0.3117,0.4483"},
--   {"id": 10, "label": "OFFER-10 offer-credit", "kind": "offer-credit", "c1": 0.253, "c2": 0.227, "c3": 0.853, "c4": 0.527, "vec": "0.253,0.227,0.853,0.527"},
--   {"id": 11, "label": "OFFER-11 offer-discount", "kind": "offer-discount", "c1": 0.6143, "c2": 0.6257, "c3": 0.2443, "c4": 0.1557, "vec": "0.6143,0.6257,0.2443,0.1557"},
--   {"id": 12, "label": "OFFER-12 offer-bundle", "kind": "offer-bundle", "c1": 0.9756, "c2": 0.1244, "c3": 0.1856, "c4": 0.7844, "vec": "0.9756,0.1244,0.1856,0.7844"},
--   {"id": 13, "label": "OFFER-13 offer-priority", "kind": "offer-priority", "c1": 0.1869, "c2": 0.8231, "c3": 0.3769, "c4": 0.4131, "vec": "0.1869,0.8231,0.3769,0.4131"},
--   {"id": 14, "label": "OFFER-14 offer-credit", "kind": "offer-credit", "c1": 0.3482, "c2": 0.2218, "c3": 0.9182, "c4": 0.6418, "vec": "0.3482,0.2218,0.9182,0.6418"},
--   {"id": 15, "label": "OFFER-15 offer-discount", "kind": "offer-discount", "c1": 0.5595, "c2": 0.6205, "c3": 0.1595, "c4": 0.1205, "vec": "0.5595,0.6205,0.1595,0.1205"},
--   {"id": 16, "label": "OFFER-16 offer-bundle", "kind": "offer-bundle", "c1": 0.9208, "c2": 0.1192, "c3": 0.2508, "c4": 0.7492, "vec": "0.9208,0.1192,0.2508,0.7492"},
--   {"id": 17, "label": "OFFER-17 offer-priority", "kind": "offer-priority", "c1": 0.2821, "c2": 0.8179, "c3": 0.2921, "c4": 0.3779, "vec": "0.2821,0.8179,0.2921,0.3779"},
--   {"id": 18, "label": "OFFER-18 offer-credit", "kind": "offer-credit", "c1": 0.2934, "c2": 0.2166, "c3": 0.9834, "c4": 0.6066, "vec": "0.2934,0.2166,0.9834,0.6066"},
--   {"id": 19, "label": "OFFER-19 offer-discount", "kind": "offer-discount", "c1": 0.6547, "c2": 0.6153, "c3": 0.2247, "c4": 0.2353, "vec": "0.6547,0.6153,0.2247,0.2353"},
--   {"id": 20, "label": "OFFER-20 offer-bundle", "kind": "offer-bundle", "c1": 0.866, "c2": 0.114, "c3": 0.166, "c4": 0.714, "vec": "0.866,0.114,0.166,0.714"},
--   {"id": 21, "label": "OFFER-21 offer-priority", "kind": "offer-priority", "c1": 0.2273, "c2": 0.8127, "c3": 0.3573, "c4": 0.3427, "vec": "0.2273,0.8127,0.3573,0.3427"},
--   {"id": 22, "label": "OFFER-22 offer-credit", "kind": "offer-credit", "c1": 0.3886, "c2": 0.2114, "c3": 0.8986, "c4": 0.5714, "vec": "0.3886,0.2114,0.8986,0.5714"},
--   {"id": 23, "label": "OFFER-23 offer-discount", "kind": "offer-discount", "c1": 0.5999, "c2": 0.6101, "c3": 0.2899, "c4": 0.2001, "vec": "0.5999,0.6101,0.2899,0.2001"},
--   {"id": 24, "label": "OFFER-24 offer-bundle", "kind": "offer-bundle", "c1": 0.9612, "c2": 0.1088, "c3": 0.2312, "c4": 0.8288, "vec": "0.9612,0.1088,0.2312,0.8288"}
-- ]};

SELECT "kind", COUNT(*) AS "n" FROM "arr_offers"
GROUP BY "kind" ORDER BY "kind";

-- ---------------------------------------------------------------------------
-- 2. Scout (diversity-first): six different offers.
--
-- The service matches the population back to the rows it came from, so
-- the picks are queryable.
-- ---------------------------------------------------------------------------
-- @call search/explore {"datasource": "arr_offers", "vectorColumn": "vec",
--                      "idColumn": "id", "query": "[0.6,0.4,0.6,0.5]",
--                      "k": 6, "params": "{\"population_size\": 6, \"iterations\": 8}"} AS arr_picks;

SELECT p."ord" AS "ord", o."id" AS "id", o."label" AS "label", o."kind" AS "kind"
FROM "arr_picks" p, "arr_offers" o
WHERE p."doc_id" = o."id";

-- Coverage: the offer kinds the six picks represent.
SELECT COUNT(DISTINCT o."kind") AS "kinds_covered_of_4"
FROM "arr_picks" p, "arr_offers" o WHERE p."doc_id" = o."id";

-- ---------------------------------------------------------------------------
-- 3. The past sessions + the recall.
-- ---------------------------------------------------------------------------
-- @fixture arr_sessions {"rows": [
--   {"id": 1, "label": "SESS-001", "category": "group-2", "note": "recovered with a bundle", "vec": "0.2013,0.8387,0.3313,0.3687"},
--   {"id": 2, "label": "SESS-002", "category": "group-3", "note": "ignored two follow-ups", "vec": "0.3626,0.2374,0.8726,0.5974"},
--   {"id": 3, "label": "SESS-003", "category": "group-1", "note": "recovered after a discount", "vec": "0.5739,0.6361,0.2639,0.2261"},
--   {"id": 4, "label": "SESS-004", "category": "group-1", "note": "completed offline", "vec": "0.9352,0.1348,0.2052,0.8548"},
--   {"id": 5, "label": "SESS-005", "category": "group-2", "note": "recovered with a credit", "vec": "0.1465,0.8335,0.2465,0.3335"},
--   {"id": 6, "label": "SESS-006", "category": "group-3", "note": "recovered with priority handling", "vec": "0.3078,0.2322,0.9378,0.5622"},
--   {"id": 7, "label": "SESS-007", "category": "group-1", "note": "recovered with a bundle", "vec": "0.6691,0.6309,0.1791,0.1909"},
--   {"id": 8, "label": "SESS-008", "category": "group-1", "note": "ignored two follow-ups", "vec": "0.8804,0.1296,0.2704,0.8196"},
--   {"id": 9, "label": "SESS-009", "category": "group-2", "note": "recovered after a discount", "vec": "0.2417,0.8283,0.3117,0.4483"},
--   {"id": 10, "label": "SESS-010", "category": "group-3", "note": "completed offline", "vec": "0.253,0.227,0.853,0.527"},
--   {"id": 11, "label": "SESS-011", "category": "group-1", "note": "recovered with a credit", "vec": "0.6143,0.6257,0.2443,0.1557"},
--   {"id": 12, "label": "SESS-012", "category": "group-1", "note": "recovered with priority handling", "vec": "0.9756,0.1244,0.1856,0.7844"},
--   {"id": 13, "label": "SESS-013", "category": "group-2", "note": "recovered with a bundle", "vec": "0.1869,0.8231,0.3769,0.4131"},
--   {"id": 14, "label": "SESS-014", "category": "group-3", "note": "ignored two follow-ups", "vec": "0.3482,0.2218,0.9182,0.6418"},
--   {"id": 15, "label": "SESS-015", "category": "group-1", "note": "recovered after a discount", "vec": "0.5595,0.6205,0.1595,0.1205"},
--   {"id": 16, "label": "SESS-016", "category": "group-1", "note": "completed offline", "vec": "0.9208,0.1192,0.2508,0.7492"},
--   {"id": 17, "label": "SESS-017", "category": "group-2", "note": "recovered with a credit", "vec": "0.2821,0.8179,0.2921,0.3779"},
--   {"id": 18, "label": "SESS-018", "category": "group-3", "note": "recovered with priority handling", "vec": "0.2934,0.2166,0.9834,0.6066"},
--   {"id": 19, "label": "SESS-019", "category": "group-1", "note": "recovered with a bundle", "vec": "0.6547,0.6153,0.2247,0.2353"},
--   {"id": 20, "label": "SESS-020", "category": "group-1", "note": "ignored two follow-ups", "vec": "0.866,0.114,0.166,0.714"},
--   {"id": 21, "label": "SESS-021", "category": "group-2", "note": "recovered after a discount", "vec": "0.2273,0.8127,0.3573,0.3427"},
--   {"id": 22, "label": "SESS-022", "category": "group-3", "note": "completed offline", "vec": "0.3886,0.2114,0.8986,0.5714"},
--   {"id": 23, "label": "SESS-023", "category": "group-1", "note": "recovered with a credit", "vec": "0.5999,0.6101,0.2899,0.2001"},
--   {"id": 24, "label": "SESS-024", "category": "group-1", "note": "recovered with priority handling", "vec": "0.9612,0.1088,0.2312,0.8288"},
--   {"id": 25, "label": "SESS-025", "category": "group-2", "note": "recovered with a bundle", "vec": "0.1725,0.8075,0.2725,0.3075"},
--   {"id": 26, "label": "SESS-026", "category": "group-3", "note": "ignored two follow-ups", "vec": "0.3338,0.2062,0.9638,0.5362"},
--   {"id": 27, "label": "SESS-027", "category": "group-1", "note": "recovered after a discount", "vec": "0.6951,0.6049,0.2051,0.1649"},
--   {"id": 28, "label": "SESS-028", "category": "group-1", "note": "completed offline", "vec": "0.9064,0.1036,0.2964,0.7936"},
--   {"id": 29, "label": "SESS-029", "category": "group-2", "note": "recovered with a credit", "vec": "0.2677,0.8023,0.3377,0.4223"},
--   {"id": 30, "label": "SESS-030", "category": "group-3", "note": "recovered with priority handling", "vec": "0.279,0.201,0.879,0.501"}
-- ]};

-- @call agent/recall_hybrid {"mem_table": "arr_sessions", "vec_col": "vec",
--                            "query_vec": "0.85,0.25,0.25,0.75",
--                            "id_col": "id", "filter_col": "category",
--                            "filter_val": "group-1", "k": 3} AS arr_recall;

SELECT r."doc_id" AS "mem_id", s."note" AS "content"
FROM "arr_recall" r, "arr_sessions" s
WHERE r."doc_id" = s."id";

-- ---------------------------------------------------------------------------
-- 4. fractal_sql_agent: a question in plain English.
--
-- The service generates the statement, validates it against Druid's own
-- parser, and runs it.
-- ---------------------------------------------------------------------------
-- @call agent/data_analyst {"question": "How many abandoned group-1 sessions are there?",
--                           "tables": ["arr_sessions"], "max_retries": 3,
--                           "auto_execute": true};

-- ---------------------------------------------------------------------------
-- 5. Reasoning: the follow-up message brief.
-- ---------------------------------------------------------------------------
SELECT fractal_reason(
    'one-line follow-up message brief: which offer to lead with and what worked on similar sessions',
    '{"offers_tested":"' || (SELECT ARRAY_TO_STRING(ARRAY_AGG(CAST("doc_id" AS VARCHAR), 8192), ',')
                                FROM "arr_picks")
     || '","similar_sessions":"' || (SELECT ARRAY_TO_STRING(ARRAY_AGG(CAST("doc_id" AS VARCHAR), 8192), ',')
                                  FROM "arr_recall")
     || '"}') AS "narrative";

-- ---------------------------------------------------------------------------
-- 6. The kit's own headline check.
--
-- The demo contract: a kit prints its headline and exits
-- non-zero unless the result holds. Six offers picked across at least
-- three kinds, and three similar sessions recalled, all of them group-1.
-- ---------------------------------------------------------------------------
SELECT CASE
           WHEN (SELECT COUNT(*) FROM "arr_picks") = 6
            AND (SELECT COUNT(DISTINCT o."kind") FROM "arr_picks" p, "arr_offers" o WHERE p."doc_id" = o."id") >= 3
            AND (SELECT COUNT(*) FROM "arr_recall") = 3
            AND (SELECT COUNT(*) FROM "arr_recall" r, "arr_sessions" s
                  WHERE s."id" = r."doc_id" AND s."category" = 'group-1') = 3
            THEN 'HEADLINE kit=agentic-recall-recommendation ok'
            ELSE 'HEADLINE kit=agentic-recall-recommendation FAILED'
       END AS "headline";
