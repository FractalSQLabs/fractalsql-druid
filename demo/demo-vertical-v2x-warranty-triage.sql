-- demo/demo-vertical-v2x-warranty-triage.sql
--
-- FractalSQL for Apache Druid -- industry vertical: connected-vehicle
-- warranty triage. A DTC event arrives; the router sends it to the
-- service workflow whose capabilities are nearest, and the claims
-- history supplies the similar prior repairs.
--
--   1. fractal_agent_route_task -- matches the incoming telemetry event
--      to the nearest service workflow.
--   2. fractal_agent_recall_hybrid -- fuses a strict metadata filter
--      (a component) with fractal_hybrid_clinical_search over the
--      claims' drift vectors.
--   3. Reasoning: the dispatch recommendation plus warranty context.
--
-- Prerequisites: the extension is loaded on the Druid cluster. The agent's
-- rationale and the closing narrative need a reasoning provider
-- (docs/reasoning-setup.md); every other step runs with no model.
--
-- Run:
--   python3 demo/run_demo.py --file demo/demo-vertical-v2x-warranty-triage.sql
--
-- ===========================================================================
-- Notes on how this runs on Druid
-- ===========================================================================
--
--   * The fixtures are @fixture directives: Druid has no DDL and no
--     VALUES, so a set of rows has no SQL form.
--   * The routing and the recall are service calls: an agent reads a
--     table and reasons about it, and a Druid SQL function can do
--     neither.
--
-- Notes:
--   * Fully deterministic fixtures (no random()).

-- ---------------------------------------------------------------------------
-- 0. Sanity check: extension loaded?
-- ---------------------------------------------------------------------------
SELECT fractal_edition(), fractal_version();

-- ---------------------------------------------------------------------------
-- 1. Capability table + historical warranty claims.
-- ---------------------------------------------------------------------------
-- @fixture v2x_capabilities {"rows": [
--   {"id": 1, "workflow": "battery-thermal-service", "emb": "0.90,0.10,0.10"},
--   {"id": 2, "workflow": "powertrain-inverter-swap", "emb": "0.10,0.90,0.10"},
--   {"id": 3, "workflow": "adas-sensor-recalibration", "emb": "0.10,0.10,0.90"},
--   {"id": 4, "workflow": "software-ota-reflash", "emb": "0.50,0.50,0.50"}
-- ]};

-- @fixture v2x_claims {"rows": [
--   {"id": 1, "vin": "VIN-A01", "model_year": 2023, "component": "battery-pack", "note": "coolant pump intermittent, pack temp spike on fast charge", "drift_vec": "0.80,0.60,0.10,0.10"},
--   {"id": 2, "vin": "VIN-A02", "model_year": 2023, "component": "battery-pack", "note": "cell imbalance after winter, SoH below threshold", "drift_vec": "0.70,0.20,0.60,0.10"},
--   {"id": 3, "vin": "VIN-A03", "model_year": 2024, "component": "battery-pack", "note": "pack temp spike on fast charge, coolant valve stuck", "drift_vec": "0.82,0.58,0.12,0.08"},
--   {"id": 4, "vin": "VIN-A04", "model_year": 2024, "component": "battery-pack", "note": "contactor chatter at low state of charge", "drift_vec": "0.20,0.10,0.90,0.30"},
--   {"id": 5, "vin": "VIN-B01", "model_year": 2023, "component": "inverter", "note": "inverter overtemp derate under tow load", "drift_vec": "0.55,0.85,0.10,0.20"},
--   {"id": 6, "vin": "VIN-B02", "model_year": 2024, "component": "inverter", "note": "phase current ripple, NVH complaint", "drift_vec": "0.15,0.30,0.20,0.90"},
--   {"id": 7, "vin": "VIN-C01", "model_year": 2023, "component": "adas-sensor", "note": "forward radar misalignment after windshield replacement", "drift_vec": "0.10,0.20,0.30,0.70"},
--   {"id": 8, "vin": "VIN-C02", "model_year": 2024, "component": "adas-sensor", "note": "camera calibration drift, lane-keep disengages", "drift_vec": "0.12,0.18,0.28,0.75"}
-- ]};

SELECT "component", COUNT(*) AS "claims" FROM "v2x_claims" GROUP BY "component";

-- ---------------------------------------------------------------------------
-- 2. Step 1: route the incoming event.
--
-- The DTC event is a battery thermal fault -- its embedding sits
-- nearest the battery-thermal workflow.
-- ---------------------------------------------------------------------------
-- @call agent/route_task {"task_emb": "0.85,0.15,0.12",
--                        "cap_table": "v2x_capabilities", "cap_emb_col": "emb",
--                        "cap_id_col": "workflow", "budget": 1000} AS v2x_routed;

SELECT "routed_to", ROUND("confidence", 4) AS "confidence", "remaining_budget"
FROM "v2x_routed";

-- ---------------------------------------------------------------------------
-- 3. Step 2: similar 2024 battery-pack claims.
--
-- The cohort is two predicates -- model year 2024 AND battery pack --
-- which a single (filter column, filter value) pair cannot express, so
-- the caller computes it and the search reads it from a datasource.
-- ---------------------------------------------------------------------------
REPLACE INTO v2x_cohort OVERWRITE ALL
SELECT ARRAY_TO_STRING(ARRAY_AGG(CAST("id" AS VARCHAR), 8192), ',') AS "ids"
FROM "v2x_claims"
WHERE "model_year" = 2024 AND "component" = 'battery-pack'
PARTITIONED BY ALL;

-- @call search/hybrid {"table": "v2x_claims", "column": "drift_vec", "id_column": "id",
--                     "query": "0.80,0.60,0.10,0.10", "k": 3,
--                     "docIdsTable": "v2x_cohort", "docIdsColumn": "ids"} AS v2x_similar;

SELECT c."vin" AS "vin", c."model_year" AS "model_year", c."note" AS "note",
       ROUND(r."distance", 4) AS "distance"
FROM "v2x_similar" r, "v2x_claims" c
WHERE r."doc_id" = c."id";

-- ---------------------------------------------------------------------------
-- 4. Step 2, productized: fractal_agent_recall_hybrid with a strict
-- metadata filter (component = 'battery-pack'); pure retrieval, no
-- model.
-- ---------------------------------------------------------------------------
-- @call agent/recall_hybrid {"mem_table": "v2x_claims", "vec_col": "drift_vec",
--                            "query_vec": "0.80,0.60,0.10,0.10",
--                            "id_col": "id", "filter_col": "component",
--                            "filter_val": "battery-pack", "k": 3} AS v2x_recall;

SELECT r."doc_id" AS "mem_id", c."note" AS "content", ROUND(r."distance", 4) AS "distance"
FROM "v2x_recall" r, "v2x_claims" c
WHERE r."doc_id" = c."id";

-- ---------------------------------------------------------------------------
-- 5. Reasoning: the dispatch recommendation plus warranty context.
-- ---------------------------------------------------------------------------
-- @call reason {"query": "one-line dispatch recommendation plus warranty context for this connected-vehicle fault",
--               "context": "$previous"};

-- ---------------------------------------------------------------------------
-- The headline.
--
-- The kit passes when the warranty corpus is the size it claims to be
-- and the recall found the battery-pack claims it was asked for.
-- ---------------------------------------------------------------------------
SELECT CASE
           WHEN (SELECT COUNT(*) FROM "v2x_claims") = 8
            AND (SELECT COUNT(DISTINCT "component") FROM "v2x_claims") = 3
            AND (SELECT COUNT(*) FROM "v2x_recall" r, "v2x_claims" c
                 WHERE r."doc_id" = c."id" AND c."component" = 'battery-pack') = 3
            THEN 'HEADLINE kit=v2x-warranty-triage ok'
            ELSE 'HEADLINE kit=v2x-warranty-triage FAILED'
       END AS "headline";
