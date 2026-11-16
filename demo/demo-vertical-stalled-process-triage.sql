-- demo/demo-vertical-stalled-process-triage.sql
--
-- FractalSQL for Apache Druid -- industry vertical: stalled-process
-- triage. Thirty-six items carry a segment, a stage and an item-health
-- vector. The tier-1 items in review are the stalled ones: a
-- cohort-restricted search finds them, a baseline-to-current
-- trajectory search finds how far they have moved, and the triage
-- composition folds the two together with a rationale.
--
--   1. The items: segment, stage and item-health vector.
--   2. The cohort-restricted search: the tier-1 items in review.
--   3. The baseline-to-current item-health trajectory.
--   4. fractal_agent_patient_deterioration_triage: the stalled-item
--      triage.
--   5. Reasoning: the recovery-plan recommendation.
--
-- Prerequisites: the extension is loaded on the Druid cluster. The
-- narrative and the agent's rationale need a reasoning provider
-- (docs/reasoning-setup.md); every other step runs with no model.
--
-- Run:
--   python3 demo/run_demo.py --file demo/demo-vertical-stalled-process-triage.sql
--
-- ===========================================================================
-- Notes on how this runs on Druid
-- ===========================================================================
--
--   * The items are a fixture: Druid has no DDL and no VALUES, so a set
--     of rows has no SQL form.
--   * The cohort is computed into a datasource the search reads it
--     from: a two-predicate cohort is what a single (filter column,
--     filter value) pair cannot express.
--   * The searches and the composition are service calls.
--
-- Notes:
--   * Fully deterministic fixtures (no random()).

-- ---------------------------------------------------------------------------
-- 0. Sanity check: extension loaded?
-- ---------------------------------------------------------------------------
SELECT fractal_edition(), fractal_version();

-- ---------------------------------------------------------------------------
-- 1. The items: segment, stage and item-health vector.
-- ---------------------------------------------------------------------------
-- @fixture spt_items {"rows": [
--   {"id": 1, "label": "ITEM-001", "segment": "tier-2", "stage": "intake", "vec": "0.05,-0.06,0.03,-0.04"},
--   {"id": 2, "label": "ITEM-002", "segment": "tier-3", "stage": "review", "vec": "0.1,-0.02,0.06,0.02"},
--   {"id": 3, "label": "ITEM-003", "segment": "tier-1", "stage": "intake", "vec": "0.15,0.02,0.09,0.08"},
--   {"id": 4, "label": "ITEM-004", "segment": "tier-2", "stage": "review", "vec": "0.2,0.06,0,0.14"},
--   {"id": 5, "label": "ITEM-005", "segment": "tier-3", "stage": "intake", "vec": "0,0.1,0.03,0.2"},
--   {"id": 6, "label": "ITEM-006", "segment": "tier-1", "stage": "review", "vec": "0.05,0.14,0.06,-0.1"},
--   {"id": 7, "label": "ITEM-007", "segment": "tier-1", "stage": "review", "vec": "1.4,0.9,1.1,1.2"},
--   {"id": 8, "label": "ITEM-008", "segment": "tier-3", "stage": "review", "vec": "0.15,-0.06,0,0.02"},
--   {"id": 9, "label": "ITEM-009", "segment": "tier-1", "stage": "intake", "vec": "0.2,-0.02,0.03,0.08"},
--   {"id": 10, "label": "ITEM-010", "segment": "tier-2", "stage": "review", "vec": "0,0.02,0.06,0.14"},
--   {"id": 11, "label": "ITEM-011", "segment": "tier-3", "stage": "intake", "vec": "0.05,0.06,0.09,0.2"},
--   {"id": 12, "label": "ITEM-012", "segment": "tier-1", "stage": "review", "vec": "0.1,0.1,0,-0.1"},
--   {"id": 13, "label": "ITEM-013", "segment": "tier-2", "stage": "intake", "vec": "0.15,0.14,0.03,-0.04"},
--   {"id": 14, "label": "ITEM-014", "segment": "tier-3", "stage": "review", "vec": "0.2,-0.1,0.06,0.02"},
--   {"id": 15, "label": "ITEM-015", "segment": "tier-1", "stage": "review", "vec": "1.4,0.9,1.1,1.2"},
--   {"id": 16, "label": "ITEM-016", "segment": "tier-2", "stage": "review", "vec": "0.05,-0.02,0,0.14"},
--   {"id": 17, "label": "ITEM-017", "segment": "tier-3", "stage": "intake", "vec": "0.1,0.02,0.03,0.2"},
--   {"id": 18, "label": "ITEM-018", "segment": "tier-1", "stage": "review", "vec": "0.15,0.06,0.06,-0.1"},
--   {"id": 19, "label": "ITEM-019", "segment": "tier-2", "stage": "intake", "vec": "0.2,0.1,0.09,-0.04"},
--   {"id": 20, "label": "ITEM-020", "segment": "tier-3", "stage": "review", "vec": "0,0.14,0,0.02"},
--   {"id": 21, "label": "ITEM-021", "segment": "tier-1", "stage": "intake", "vec": "0.05,-0.1,0.03,0.08"},
--   {"id": 22, "label": "ITEM-022", "segment": "tier-2", "stage": "review", "vec": "0.1,-0.06,0.06,0.14"},
--   {"id": 23, "label": "ITEM-023", "segment": "tier-3", "stage": "intake", "vec": "0.15,-0.02,0.09,0.2"},
--   {"id": 24, "label": "ITEM-024", "segment": "tier-1", "stage": "review", "vec": "0.2,0.02,0,-0.1"},
--   {"id": 25, "label": "ITEM-025", "segment": "tier-2", "stage": "intake", "vec": "0,0.06,0.03,-0.04"},
--   {"id": 26, "label": "ITEM-026", "segment": "tier-3", "stage": "review", "vec": "0.05,0.1,0.06,0.02"},
--   {"id": 27, "label": "ITEM-027", "segment": "tier-1", "stage": "intake", "vec": "0.1,0.14,0.09,0.08"},
--   {"id": 28, "label": "ITEM-028", "segment": "tier-2", "stage": "review", "vec": "0.15,-0.1,0,0.14"},
--   {"id": 29, "label": "ITEM-029", "segment": "tier-3", "stage": "intake", "vec": "0.2,-0.06,0.03,0.2"},
--   {"id": 30, "label": "ITEM-030", "segment": "tier-1", "stage": "review", "vec": "0,-0.02,0.06,-0.1"},
--   {"id": 31, "label": "ITEM-031", "segment": "tier-1", "stage": "review", "vec": "1.4,0.9,1.1,1.2"},
--   {"id": 32, "label": "ITEM-032", "segment": "tier-3", "stage": "review", "vec": "0.1,0.06,0,0.02"},
--   {"id": 33, "label": "ITEM-033", "segment": "tier-1", "stage": "intake", "vec": "0.15,0.1,0.03,0.08"},
--   {"id": 34, "label": "ITEM-034", "segment": "tier-2", "stage": "review", "vec": "0.2,0.14,0.06,0.14"},
--   {"id": 35, "label": "ITEM-035", "segment": "tier-3", "stage": "intake", "vec": "0,-0.1,0.09,0.2"},
--   {"id": 36, "label": "ITEM-036", "segment": "tier-1", "stage": "review", "vec": "0.05,-0.06,0,-0.1"}
-- ]};

SELECT "segment", "stage", COUNT(*) AS "n" FROM "spt_items"
GROUP BY "segment", "stage" ORDER BY "segment", "stage";

-- ---------------------------------------------------------------------------
-- 2. The cohort-restricted search: the tier-1 items in review.
-- ---------------------------------------------------------------------------
REPLACE INTO spt_cohort OVERWRITE ALL
SELECT ARRAY_TO_STRING(ARRAY_AGG(CAST("id" AS VARCHAR), 8192), ',') AS "ids"
FROM "spt_items" WHERE "segment" = 'tier-1' AND "stage" = 'review'
PARTITIONED BY ALL;

-- @call search/hybrid {"table": "spt_items", "column": "vec", "id_column": "id",
--                     "query": "1.4,0.9,1.1,1.2", "k": 5,
--                     "docIdsTable": "spt_cohort", "docIdsColumn": "ids"} AS spt_hybrid;

SELECT w."id" AS "id", w."label" AS "label", ROUND(r."distance", 4) AS "distance"
FROM "spt_hybrid" r, "spt_items" w
WHERE r."doc_id" = w."id";

-- ---------------------------------------------------------------------------
-- 3. The baseline-to-current item-health trajectory.
-- ---------------------------------------------------------------------------
-- @call search/trajectory {"table": "spt_items", "column": "vec", "id_column": "id",
--                         "baseline": "0.05,0,0.03,0", "current": "1.4,0.9,1.1,1.2",
--                         "k": 5} AS spt_traj;

SELECT r."doc_id" AS "id", w."label" AS "label", ROUND(r."distance", 4) AS "distance"
FROM "spt_traj" r, "spt_items" w
WHERE r."doc_id" = w."id";

-- ---------------------------------------------------------------------------
-- 4. fractal_agent_patient_deterioration_triage: the stalled-item triage.
-- ---------------------------------------------------------------------------
-- @call agent/patient_deterioration_triage {"patient_table": "spt_items",
--                                           "vec_col": "vec",
--                                           "id_column": "id",
--                                           "query_vec": "1.4,0.9,1.1,1.2",
--                                           "baseline_vec": "0.05,0,0.03,0",
--                                           "current_vec": "1.4,0.9,1.1,1.2",
--                                           "cohort_doc_ids_table": "spt_cohort",
--                                           "cohort_doc_ids_column": "ids",
--                                           "k": 5};

-- ---------------------------------------------------------------------------
-- 5. Reasoning: the recovery-plan recommendation.
-- ---------------------------------------------------------------------------
SELECT fractal_reason(
    'one-line recovery-plan recommendation for these stalled tier-1 items',
    '{"stalled_items_found":"' || (SELECT ARRAY_TO_STRING(ARRAY_AGG(CAST("doc_id" AS VARCHAR), 8192), ',')
                                    FROM "spt_traj" WHERE "distance" < 0.001)
     || '"}') AS "narrative";

-- ---------------------------------------------------------------------------
-- 6. The kit's own headline check.
--
-- The demo contract: a kit prints its headline and exits
-- non-zero unless the result holds. At least three items moved the
-- stalled way, and the nearest cohort member is one of them.
-- ---------------------------------------------------------------------------
SELECT CASE
           WHEN (SELECT COUNT(*) FROM "spt_traj" WHERE "distance" < 0.001) >= 3
            AND (SELECT COUNT(*) FROM "spt_hybrid"
                  WHERE "doc_id" IN (7, 15, 31) AND "distance" < 0.001) >= 1
            THEN 'HEADLINE kit=stalled-process-triage ok'
            ELSE 'HEADLINE kit=stalled-process-triage FAILED'
       END AS "headline";
