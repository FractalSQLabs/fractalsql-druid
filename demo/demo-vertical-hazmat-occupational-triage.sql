-- demo/demo-vertical-hazmat-occupational-triage.sql
--
-- FractalSQL for Apache Druid -- industry vertical: occupational
-- exposure monitoring. Hazardous-materials response, chemical and nuclear
-- plant crews, wearable-sensor workforce safety. A DOMAIN kit built on
-- one installed agent, fractal_agent_patient_deterioration_triage,
-- reused verbatim: its contract (cohort vector search plus
-- baseline-vs-current trajectory drift) is domain-neutral, so the kit
-- only supplies exposure columns in place of clinical vitals and a
-- worker's pre-shift baseline in place of an admission baseline.
--
--   1. Thirty-six synthetic workers across three work zones and two
--      shifts. The reactor-bay night shift is the contaminated cohort.
--   2. The cohort-restricted search: the reactor-bay night-shift crew.
--   3. The pre-shift baseline vs. current exposure trajectory.
--   4. fractal_agent_patient_deterioration_triage: the exposure triage.
--   5. Reasoning: the countermeasure-dispatch recommendation.
--
-- Prerequisites: the extension is loaded on the Druid cluster. The
-- agent's rationale and the closing recommendation need a reasoning
-- provider (docs/reasoning-setup.md); every other step runs with no
-- model.
--
-- Run:
--   python3 demo/run_demo.py --file demo/demo-vertical-hazmat-occupational-triage.sql
--
-- ===========================================================================
-- Notes on how this runs on Druid
-- ===========================================================================
--
--   * The workers are a fixture: Druid has no DDL and no row-source
--     literal, and a set of rows has no SQL form there. The rows are computed ahead of time and carried in the fixture.
--   * The cohort is computed into a datasource the search reads it from:
--     a two-predicate cohort (same work zone AND same shift) is what a
--     single filter pair cannot express.
--   * The searches and the composition are service calls: an agent
--     reads a table and reasons about it, and a Druid SQL function can
--     do neither.
--   * The closing narrative is a fractal_reason() call over a JSON
--     context the kit assembles from its own result rows.
--
-- Notes:
--   * Fully deterministic fixtures (no random()).
--   * The exposure vector is [dose_rate_z, body_temp_z, air_quality_z,
--     heart_rate_z] in CSV TEXT.
--   * The trajectory search's doc_id is the worker's own id, so the
--     result joins straight back to the workers.

-- ---------------------------------------------------------------------------
-- 0. Sanity check: extension loaded?
-- ---------------------------------------------------------------------------
SELECT fractal_edition(), fractal_version();

-- ---------------------------------------------------------------------------
-- 1. Thirty-six workers: zone, shift and current exposure vector.
-- ---------------------------------------------------------------------------
-- @fixture hot_workers {"rows": [
--   {"id": 1, "zone": "fuel-handling", "shift": "day", "exposure": "0.0500,-0.0600,0.0300,-0.0400"},
--   {"id": 2, "zone": "control-room", "shift": "night", "exposure": "0.1000,-0.0200,0.0600,0.0200"},
--   {"id": 3, "zone": "reactor-bay", "shift": "day", "exposure": "0.1500,0.0200,0.0900,0.0800"},
--   {"id": 4, "zone": "fuel-handling", "shift": "night", "exposure": "0.2000,0.0600,0.0000,0.1400"},
--   {"id": 5, "zone": "control-room", "shift": "day", "exposure": "0.0000,0.1000,0.0300,0.2000"},
--   {"id": 6, "zone": "reactor-bay", "shift": "night", "exposure": "0.0500,0.1400,0.0600,-0.1000"},
--   {"id": 7, "zone": "reactor-bay", "shift": "night", "exposure": "1.40,0.90,1.10,1.20"},
--   {"id": 8, "zone": "control-room", "shift": "night", "exposure": "0.1500,-0.0600,0.0000,0.0200"},
--   {"id": 9, "zone": "reactor-bay", "shift": "day", "exposure": "0.2000,-0.0200,0.0300,0.0800"},
--   {"id": 10, "zone": "fuel-handling", "shift": "night", "exposure": "0.0000,0.0200,0.0600,0.1400"},
--   {"id": 11, "zone": "control-room", "shift": "day", "exposure": "0.0500,0.0600,0.0900,0.2000"},
--   {"id": 12, "zone": "reactor-bay", "shift": "night", "exposure": "0.1000,0.1000,0.0000,-0.1000"},
--   {"id": 13, "zone": "fuel-handling", "shift": "day", "exposure": "0.1500,0.1400,0.0300,-0.0400"},
--   {"id": 14, "zone": "control-room", "shift": "night", "exposure": "0.2000,-0.1000,0.0600,0.0200"},
--   {"id": 15, "zone": "reactor-bay", "shift": "night", "exposure": "1.40,0.90,1.10,1.20"},
--   {"id": 16, "zone": "fuel-handling", "shift": "night", "exposure": "0.0500,-0.0200,0.0000,0.1400"},
--   {"id": 17, "zone": "control-room", "shift": "day", "exposure": "0.1000,0.0200,0.0300,0.2000"},
--   {"id": 18, "zone": "reactor-bay", "shift": "night", "exposure": "0.1500,0.0600,0.0600,-0.1000"},
--   {"id": 19, "zone": "fuel-handling", "shift": "day", "exposure": "0.2000,0.1000,0.0900,-0.0400"},
--   {"id": 20, "zone": "control-room", "shift": "night", "exposure": "0.0000,0.1400,0.0000,0.0200"},
--   {"id": 21, "zone": "reactor-bay", "shift": "day", "exposure": "0.0500,-0.1000,0.0300,0.0800"},
--   {"id": 22, "zone": "fuel-handling", "shift": "night", "exposure": "0.1000,-0.0600,0.0600,0.1400"},
--   {"id": 23, "zone": "control-room", "shift": "day", "exposure": "0.1500,-0.0200,0.0900,0.2000"},
--   {"id": 24, "zone": "reactor-bay", "shift": "night", "exposure": "0.2000,0.0200,0.0000,-0.1000"},
--   {"id": 25, "zone": "fuel-handling", "shift": "day", "exposure": "0.0000,0.0600,0.0300,-0.0400"},
--   {"id": 26, "zone": "control-room", "shift": "night", "exposure": "0.0500,0.1000,0.0600,0.0200"},
--   {"id": 27, "zone": "reactor-bay", "shift": "day", "exposure": "0.1000,0.1400,0.0900,0.0800"},
--   {"id": 28, "zone": "fuel-handling", "shift": "night", "exposure": "0.1500,-0.1000,0.0000,0.1400"},
--   {"id": 29, "zone": "control-room", "shift": "day", "exposure": "0.2000,-0.0600,0.0300,0.2000"},
--   {"id": 30, "zone": "reactor-bay", "shift": "night", "exposure": "0.0000,-0.0200,0.0600,-0.1000"},
--   {"id": 31, "zone": "reactor-bay", "shift": "night", "exposure": "1.40,0.90,1.10,1.20"},
--   {"id": 32, "zone": "control-room", "shift": "night", "exposure": "0.1000,0.0600,0.0000,0.0200"},
--   {"id": 33, "zone": "reactor-bay", "shift": "day", "exposure": "0.1500,0.1000,0.0300,0.0800"},
--   {"id": 34, "zone": "fuel-handling", "shift": "night", "exposure": "0.2000,0.1400,0.0600,0.1400"},
--   {"id": 35, "zone": "control-room", "shift": "day", "exposure": "0.0000,-0.1000,0.0900,0.2000"},
--   {"id": 36, "zone": "reactor-bay", "shift": "night", "exposure": "0.0500,-0.0600,0.0000,-0.1000"}
-- ]};

SELECT "zone", "shift", COUNT(*) AS "workers" FROM "hot_workers"
GROUP BY "zone", "shift" ORDER BY "zone", "shift";

-- ---------------------------------------------------------------------------
-- 2. The cohort-restricted search: the reactor-bay, night-shift crew.
--
-- The cohort is computed into a one-row datasource the search reads its
-- identities from.
-- ---------------------------------------------------------------------------
REPLACE INTO hot_cohort OVERWRITE ALL
SELECT ARRAY_TO_STRING(ARRAY_AGG(CAST("id" AS VARCHAR), 8192), ',') AS "ids"
FROM "hot_workers" WHERE "zone" = 'reactor-bay' AND "shift" = 'night'
PARTITIONED BY ALL;

-- @call search/hybrid {"table": "hot_workers", "column": "exposure", "id_column": "id",
--                     "query": "1.40,0.90,1.10,1.20", "k": 5,
--                     "docIdsTable": "hot_cohort", "docIdsColumn": "ids"} AS hot_hybrid;

SELECT w."id" AS "worker_id", w."zone" AS "zone", w."shift" AS "shift",
       ROUND(r."distance", 4) AS "distance"
FROM "hot_hybrid" r, "hot_workers" w
WHERE r."doc_id" = w."id";

-- ---------------------------------------------------------------------------
-- 3. The pre-shift baseline vs. current exposure trajectory.
-- ---------------------------------------------------------------------------
-- @call search/trajectory {"table": "hot_workers", "column": "exposure", "id_column": "id",
--                         "baseline": "0.05,0.00,0.03,0.00",
--                         "current": "1.40,0.90,1.10,1.20",
--                         "k": 5} AS hot_traj;

SELECT w."id" AS "worker_id", w."zone" AS "zone", w."shift" AS "shift",
       ROUND(r."distance", 4) AS "distance"
FROM "hot_traj" r, "hot_workers" w
WHERE r."doc_id" = w."id";

-- ---------------------------------------------------------------------------
-- 4. fractal_agent_patient_deterioration_triage: the exposure triage.
-- ---------------------------------------------------------------------------
-- @call agent/patient_deterioration_triage {"patient_table": "hot_workers",
--                                           "vec_col": "exposure",
--                                           "id_column": "id",
--                                           "query_vec": "1.40,0.90,1.10,1.20",
--                                           "baseline_vec": "0.05,0.00,0.03,0.00",
--                                           "current_vec": "1.40,0.90,1.10,1.20",
--                                           "cohort_doc_ids_table": "hot_cohort",
--                                           "cohort_doc_ids_column": "ids",
--                                           "k": 5};

-- ---------------------------------------------------------------------------
-- 5. Reasoning: the countermeasure-dispatch recommendation.
-- ---------------------------------------------------------------------------
SELECT fractal_reason(
    'one-line medical-countermeasure dispatch recommendation for this exposed work crew',
    '{"exposed_workers":"' || (SELECT ARRAY_TO_STRING(ARRAY_AGG(CAST("doc_id" AS VARCHAR), 8192), ',')
                                  FROM "hot_traj" WHERE "distance" < 0.01)
     || '","cohort":"' || (SELECT ARRAY_TO_STRING(ARRAY_AGG(CAST("id" AS VARCHAR), 8192), ',')
                             FROM "hot_workers" WHERE "zone" = 'reactor-bay' AND "shift" = 'night')
     || '"}') AS "recommendation";

-- ---------------------------------------------------------------------------
-- 6. The kit's own headline check.
--
-- The demo contract: a kit prints its headline and exits
-- non-zero unless the result holds. Thirty-six workers, a reactor-bay
-- night-shift cohort, at least one contaminated worker inside the
-- cohort-restricted search, and at least three workers the
-- baseline-to-current trajectory reads as escalated.
-- ---------------------------------------------------------------------------
SELECT CASE
           WHEN (SELECT COUNT(*) FROM "hot_workers") = 36
            AND (SELECT COUNT(*) FROM "hot_workers"
                 WHERE "zone" = 'reactor-bay' AND "shift" = 'night') = 9
            AND (SELECT COUNT(*) FROM "hot_hybrid"
                 WHERE "doc_id" IN (7, 15, 31) AND "distance" < 0.01) >= 1
            AND (SELECT COUNT(*) FROM "hot_traj" WHERE "distance" < 0.01) >= 3
            THEN 'HEADLINE kit=hazmat-occupational-triage ok'
            ELSE 'HEADLINE kit=hazmat-occupational-triage FAILED'
       END AS "headline";
