-- demo/demo-vertical-agentic-next-action-ranking.sql
--
-- FractalSQL for Apache Druid -- industry vertical: next-action
-- ranking. Thirty candidate records with a segment, a note and a
-- candidate vector. The kit recalls the similar past candidates, picks
-- a *diverse* set of next actions from the catalogue rather than four
-- near-twins, and asks the model a plain-English status question about
-- the list.
--
--   1. The candidates: segment, note and candidate vector.
--   2. Recall: the similar past tier-1 candidates.
--   3. The next-action catalogue + the diverse recommendations.
--   4. fractal_sql_agent: a status question in plain English.
--   5. Reasoning: the ready-to-act recommendation.
--
-- Prerequisites: the extension is loaded on the Druid cluster. The
-- narrative and the agents' rationales need a reasoning provider
-- (docs/reasoning-setup.md); every other step runs with no model.
--
-- Run:
--   python3 demo/run_demo.py --file demo/demo-vertical-agentic-next-action-ranking.sql
--
-- ===========================================================================
-- Notes on how this runs on Druid
-- ===========================================================================
--
--   * The fixtures are @fixture directives: Druid has no DDL and no
--     VALUES, so a set of rows has no SQL form.
--   * The agents are service calls: an agent reads a table and reasons
--     about it, and a Druid SQL function can do neither.
--
-- Notes:
--   * Fully deterministic fixtures (no random()).

-- ---------------------------------------------------------------------------
-- 0. Sanity check: extension loaded?
-- ---------------------------------------------------------------------------
SELECT fractal_edition(), fractal_version();

-- ---------------------------------------------------------------------------
-- 1. The candidates: segment, note and candidate vector.
-- ---------------------------------------------------------------------------
-- @fixture anr_candidates {"rows": [
--   {"id": 1, "label": "CAND-001", "segment": "tier-2", "note": "attended the briefing", "vec": "0.2013,0.8387,0.3313,0.3687"},
--   {"id": 2, "label": "CAND-002", "segment": "tier-3", "note": "viewed the overview twice this week", "vec": "0.3626,0.2374,0.8726,0.5974"},
--   {"id": 3, "label": "CAND-003", "segment": "tier-1", "note": "contact changed roles", "vec": "0.5739,0.6361,0.2639,0.2261"},
--   {"id": 4, "label": "CAND-004", "segment": "tier-1", "note": "requested a trial", "vec": "0.9352,0.1348,0.2052,0.8548"},
--   {"id": 5, "label": "CAND-005", "segment": "tier-2", "note": "renewal discussion opened", "vec": "0.1465,0.8335,0.2465,0.3335"},
--   {"id": 6, "label": "CAND-006", "segment": "tier-3", "note": "requested a detailed review", "vec": "0.3078,0.2322,0.9378,0.5622"},
--   {"id": 7, "label": "CAND-007", "segment": "tier-1", "note": "attended the briefing", "vec": "0.6691,0.6309,0.1791,0.1909"},
--   {"id": 8, "label": "CAND-008", "segment": "tier-1", "note": "viewed the overview twice this week", "vec": "0.8804,0.1296,0.2704,0.8196"},
--   {"id": 9, "label": "CAND-009", "segment": "tier-2", "note": "contact changed roles", "vec": "0.2417,0.8283,0.3117,0.4483"},
--   {"id": 10, "label": "CAND-010", "segment": "tier-3", "note": "requested a trial", "vec": "0.253,0.227,0.853,0.527"},
--   {"id": 11, "label": "CAND-011", "segment": "tier-1", "note": "renewal discussion opened", "vec": "0.6143,0.6257,0.2443,0.1557"},
--   {"id": 12, "label": "CAND-012", "segment": "tier-1", "note": "requested a detailed review", "vec": "0.9756,0.1244,0.1856,0.7844"},
--   {"id": 13, "label": "CAND-013", "segment": "tier-2", "note": "attended the briefing", "vec": "0.1869,0.8231,0.3769,0.4131"},
--   {"id": 14, "label": "CAND-014", "segment": "tier-3", "note": "viewed the overview twice this week", "vec": "0.3482,0.2218,0.9182,0.6418"},
--   {"id": 15, "label": "CAND-015", "segment": "tier-1", "note": "contact changed roles", "vec": "0.5595,0.6205,0.1595,0.1205"},
--   {"id": 16, "label": "CAND-016", "segment": "tier-1", "note": "requested a trial", "vec": "0.9208,0.1192,0.2508,0.7492"},
--   {"id": 17, "label": "CAND-017", "segment": "tier-2", "note": "renewal discussion opened", "vec": "0.2821,0.8179,0.2921,0.3779"},
--   {"id": 18, "label": "CAND-018", "segment": "tier-3", "note": "requested a detailed review", "vec": "0.2934,0.2166,0.9834,0.6066"},
--   {"id": 19, "label": "CAND-019", "segment": "tier-1", "note": "attended the briefing", "vec": "0.6547,0.6153,0.2247,0.2353"},
--   {"id": 20, "label": "CAND-020", "segment": "tier-1", "note": "viewed the overview twice this week", "vec": "0.866,0.114,0.166,0.714"},
--   {"id": 21, "label": "CAND-021", "segment": "tier-2", "note": "contact changed roles", "vec": "0.2273,0.8127,0.3573,0.3427"},
--   {"id": 22, "label": "CAND-022", "segment": "tier-3", "note": "requested a trial", "vec": "0.3886,0.2114,0.8986,0.5714"},
--   {"id": 23, "label": "CAND-023", "segment": "tier-1", "note": "renewal discussion opened", "vec": "0.5999,0.6101,0.2899,0.2001"},
--   {"id": 24, "label": "CAND-024", "segment": "tier-1", "note": "requested a detailed review", "vec": "0.9612,0.1088,0.2312,0.8288"},
--   {"id": 25, "label": "CAND-025", "segment": "tier-2", "note": "attended the briefing", "vec": "0.1725,0.8075,0.2725,0.3075"},
--   {"id": 26, "label": "CAND-026", "segment": "tier-3", "note": "viewed the overview twice this week", "vec": "0.3338,0.2062,0.9638,0.5362"},
--   {"id": 27, "label": "CAND-027", "segment": "tier-1", "note": "contact changed roles", "vec": "0.6951,0.6049,0.2051,0.1649"},
--   {"id": 28, "label": "CAND-028", "segment": "tier-1", "note": "requested a trial", "vec": "0.9064,0.1036,0.2964,0.7936"},
--   {"id": 29, "label": "CAND-029", "segment": "tier-2", "note": "renewal discussion opened", "vec": "0.2677,0.8023,0.3377,0.4223"},
--   {"id": 30, "label": "CAND-030", "segment": "tier-3", "note": "requested a detailed review", "vec": "0.279,0.201,0.879,0.501"}
-- ]};

-- ---------------------------------------------------------------------------
-- 2. Recall: the similar past tier-1 candidates.
-- ---------------------------------------------------------------------------
-- @call agent/recall_hybrid {"mem_table": "anr_candidates", "vec_col": "vec",
--                            "query_vec": "0.85,0.25,0.25,0.75",
--                            "id_col": "id", "filter_col": "segment",
--                            "filter_val": "tier-1", "k": 3} AS anr_recall;

SELECT r."doc_id" AS "mem_id", c."note" AS "content"
FROM "anr_recall" r, "anr_candidates" c
WHERE r."doc_id" = c."id";

-- ---------------------------------------------------------------------------
-- 3. The next-action catalogue + the diverse recommendations.
-- ---------------------------------------------------------------------------
-- @fixture anr_actions {"rows": [
--   {"id": 1, "label": "book briefing (1)", "vec": "0.1513,0.8487,0.2763"},
--   {"id": 2, "label": "offer trial (2)", "vec": "0.3026,0.1474,0.8776"},
--   {"id": 3, "label": "share summary model (3)", "vec": "0.5789,0.5461,0.6539"},
--   {"id": 4, "label": "invite to panel (4)", "vec": "0.9302,0.1448,0.1552"},
--   {"id": 5, "label": "schedule review (5)", "vec": "0.1065,0.8435,0.2065"},
--   {"id": 6, "label": "send case summary (6)", "vec": "0.2578,0.1422,0.9328"},
--   {"id": 7, "label": "book briefing (7)", "vec": "0.6591,0.5409,0.5841"},
--   {"id": 8, "label": "offer trial (8)", "vec": "0.8854,0.1396,0.2104"},
--   {"id": 9, "label": "share summary model (9)", "vec": "0.1867,0.8383,0.2617"},
--   {"id": 10, "label": "invite to panel (10)", "vec": "0.213,0.137,0.863"},
--   {"id": 11, "label": "schedule review (11)", "vec": "0.6143,0.5357,0.6393"},
--   {"id": 12, "label": "send case summary (12)", "vec": "0.9656,0.1344,0.1406"}
-- ]};

-- @call agent/recommend_diverse {"catalog_table": "anr_actions", "emb_col": "vec",
--                                "query_vec": "0.8,0.3,0.25", "k": 4,
--                                "id_col": "id"} AS anr_rec;

SELECT r."item_id" AS "item_id", a."label" AS "label", ROUND(r."score", 4) AS "score"
FROM "anr_rec" r, "anr_actions" a
WHERE r."item_id" = a."id";

-- ---------------------------------------------------------------------------
-- 4. fractal_sql_agent: a status question in plain English.
--
-- The service generates the statement, validates it against Druid's own
-- parser, and runs it.
-- ---------------------------------------------------------------------------
-- @call agent/data_analyst {"question": "How many tier-1 candidates are in the list?",
--                           "tables": ["anr_candidates"], "max_retries": 3,
--                           "auto_execute": true};

-- ---------------------------------------------------------------------------
-- 5. Reasoning: the ready-to-act recommendation.
-- ---------------------------------------------------------------------------
SELECT fractal_reason(
    'one-line next-action recommendation for this operator, using the similar past candidates and actions',
    '{"similar_candidates":"' || (SELECT ARRAY_TO_STRING(ARRAY_AGG(CAST("doc_id" AS VARCHAR), 8192), ',')
                                  FROM "anr_recall")
     || '","candidate_action":"' || (SELECT ARRAY_TO_STRING(ARRAY_AGG(CAST("label" AS VARCHAR), 8192), ',')
                                    FROM "anr_rec" r, "anr_actions" a WHERE r."item_id" = a."id")
     || '"}') AS "narrative";

-- ---------------------------------------------------------------------------
-- 6. The kit's own headline check.
--
-- The demo contract: a kit prints its headline and exits
-- non-zero unless the result holds. Three candidates recalled, all of
-- them tier-1, and four actions recommended.
-- ---------------------------------------------------------------------------
SELECT CASE
           WHEN (SELECT COUNT(*) FROM "anr_recall") = 3
            AND (SELECT COUNT(*) FROM "anr_recall" r, "anr_candidates" l
                  WHERE l."id" = r."doc_id" AND l."segment" = 'tier-1') = 3
            AND (SELECT COUNT(*) FROM "anr_rec") = 4
            THEN 'HEADLINE kit=agentic-next-action-ranking ok'
            ELSE 'HEADLINE kit=agentic-next-action-ranking FAILED'
       END AS "headline";
