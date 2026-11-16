-- demo/demo-vertical-medtech-clinical.sql
--
-- FractalSQL for Apache Druid -- industry vertical: medtech clinical.
-- Forty synthetic patients with demographics and current vitals. A
-- sepsis-watch cohort (age > 65 AND condition = sepsis) is searched
-- with fractal_hybrid_clinical_search, one patient's drift from their
-- admission baseline is found with fractal_search_trajectory, and the
-- domain geometry primitives -- the vessel tree, the cortical mesh and
-- the corneal nerve plexus -- close the kit.
--
--   1. The patients: demographics + current vitals.
--   2. fractal_hybrid_clinical_search: the cohort-restricted search.
--   3. fractal_search_trajectory: a patient's drift from their
--      admission baseline.
--   4. fractal_vascular_network: the vessel tree.
--   5. fractal_cortical_folding: a reference mesh.
--   6. fractal_nerve_plexus_metric: the corneal nerve plexus.
--
-- Prerequisites: the extension is loaded on the Druid cluster. The
-- deterioration triage's rationale needs a reasoning provider
-- (docs/reasoning-setup.md); every other step runs with no model.
--
-- Run:
--   python3 demo/run_demo.py --file demo/demo-vertical-medtech-clinical.sql
--
-- ===========================================================================
-- Notes on how this runs on Druid
-- ===========================================================================
--
--   * The patients are a fixture: Druid has no DDL, no VALUES and no
--     recursive CTE, and random values are the deterministic sin-hash the other kits use.
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
-- 1. Forty synthetic patients: demographics + current vitals.
--
-- The vitals vector is [heart rate, blood pressure, temperature,
-- oxygen saturation, white-cell count].
-- ---------------------------------------------------------------------------
-- @fixture vmc_patients {"rows": [
--   {"id": 1, "age": 77, "condition": "routine", "vitals": "0.8109,0.0167,0.0881,0.0775,0.5976"},
--   {"id": 2, "age": 59, "condition": "routine", "vitals": "0.0167,0.0881,0.0775,0.5976,0.2415"},
--   {"id": 3, "age": 70, "condition": "sepsis", "vitals": "0.0881,0.0775,0.5976,0.2415,0.3881"},
--   {"id": 4, "age": 81, "condition": "routine", "vitals": "0.0775,0.5976,0.2415,0.3881,0.3282"},
--   {"id": 5, "age": 54, "condition": "post-op", "vitals": "0.5976,0.2415,0.3881,0.3282,0.3679"},
--   {"id": 6, "age": 37, "condition": "post-op", "vitals": "0.2415,0.3881,0.3282,0.3679,0.5074"},
--   {"id": 7, "age": 43, "condition": "sepsis", "vitals": "0.3881,0.3282,0.3679,0.5074,0.1733"},
--   {"id": 8, "age": 33, "condition": "sepsis", "vitals": "0.3282,0.3679,0.5074,0.1733,0.0289"},
--   {"id": 9, "age": 33, "condition": "sepsis", "vitals": "0.3679,0.5074,0.1733,0.0289,0.1903"},
--   {"id": 10, "age": 27, "condition": "routine", "vitals": "0.5074,0.1733,0.0289,0.1903,0.5949"},
--   {"id": 11, "age": 70, "condition": "sepsis", "vitals": "0.1733,0.0289,0.1903,0.5949,0.1541"},
--   {"id": 12, "age": 23, "condition": "sepsis", "vitals": "0.0289,0.1903,0.5949,0.1541,0.6928"},
--   {"id": 13, "age": 27, "condition": "sepsis", "vitals": "0.1903,0.5949,0.1541,0.6928,0.1842"},
--   {"id": 14, "age": 27, "condition": "routine", "vitals": "0.5949,0.1541,0.6928,0.1842,0.0442"},
--   {"id": 15, "age": 62, "condition": "post-op", "vitals": "0.1541,0.6928,0.1842,0.0442,0.7339"},
--   {"id": 16, "age": 38, "condition": "post-op", "vitals": "0.6928,0.1842,0.0442,0.7339,0.4315"},
--   {"id": 17, "age": 48, "condition": "post-op", "vitals": "0.1842,0.0442,0.7339,0.4315,0.0895"},
--   {"id": 18, "age": 44, "condition": "post-op", "vitals": "0.0442,0.7339,0.4315,0.0895,0.2774"},
--   {"id": 19, "age": 47, "condition": "routine", "vitals": "0.7339,0.4315,0.0895,0.2774,0.0941"},
--   {"id": 20, "age": 56, "condition": "sepsis", "vitals": "0.4315,0.0895,0.2774,0.0941,0.3764"},
--   {"id": 21, "age": 33, "condition": "sepsis", "vitals": "0.0895,0.2774,0.0941,0.3764,0.4848"},
--   {"id": 22, "age": 23, "condition": "sepsis", "vitals": "0.2774,0.0941,0.3764,0.4848,0.3580"},
--   {"id": 23, "age": 34, "condition": "routine", "vitals": "0.0941,0.3764,0.4848,0.3580,0.4441"},
--   {"id": 24, "age": 62, "condition": "sepsis", "vitals": "0.3764,0.4848,0.3580,0.4441,0.9280"},
--   {"id": 25, "age": 32, "condition": "routine", "vitals": "0.4848,0.3580,0.4441,0.9280,0.8154"},
--   {"id": 26, "age": 69, "condition": "sepsis", "vitals": "0.3580,0.4441,0.9280,0.8154,0.1415"},
--   {"id": 27, "age": 70, "condition": "sepsis", "vitals": "0.4441,0.9280,0.8154,0.1415,0.5297"},
--   {"id": 28, "age": 25, "condition": "routine", "vitals": "0.9280,0.8154,0.1415,0.5297,0.7374"},
--   {"id": 29, "age": 71, "condition": "routine", "vitals": "0.8154,0.1415,0.5297,0.7374,0.7809"},
--   {"id": 30, "age": 51, "condition": "sepsis", "vitals": "0.1415,0.5297,0.7374,0.7809,0.7511"},
--   {"id": 31, "age": 28, "condition": "post-op", "vitals": "0.5297,0.7374,0.7809,0.7511,0.9279"},
--   {"id": 32, "age": 40, "condition": "sepsis", "vitals": "0.7374,0.7809,0.7511,0.9279,0.1462"},
--   {"id": 33, "age": 28, "condition": "post-op", "vitals": "0.7809,0.7511,0.9279,0.1462,0.0558"},
--   {"id": 34, "age": 47, "condition": "routine", "vitals": "0.7511,0.9279,0.1462,0.0558,0.4899"},
--   {"id": 35, "age": 54, "condition": "post-op", "vitals": "0.9279,0.1462,0.0558,0.4899,0.2641"},
--   {"id": 36, "age": 46, "condition": "routine", "vitals": "0.1462,0.0558,0.4899,0.2641,0.9330"},
--   {"id": 37, "age": 52, "condition": "routine", "vitals": "0.0558,0.4899,0.2641,0.9330,0.0789"},
--   {"id": 38, "age": 85, "condition": "routine", "vitals": "0.4899,0.2641,0.9330,0.0789,0.1655"},
--   {"id": 39, "age": 77, "condition": "sepsis", "vitals": "0.2641,0.9330,0.0789,0.1655,0.4976"},
--   {"id": 40, "age": 31, "condition": "routine", "vitals": "0.9330,0.0789,0.1655,0.4976,0.8932"}
-- ]};

-- ---------------------------------------------------------------------------
-- 2. The cohort-restricted search: the sepsis-watch cohort.
-- ---------------------------------------------------------------------------
REPLACE INTO vmc_cohort OVERWRITE ALL
SELECT ARRAY_TO_STRING(ARRAY_AGG(CAST("id" AS VARCHAR), 8192), ',') AS "ids"
FROM "vmc_patients"
WHERE "age" > 65 AND "condition" = 'sepsis'
PARTITIONED BY ALL;

-- @call search/hybrid {"table": "vmc_patients", "column": "vitals", "id_column": "id",
--                     "query": "1,-1,1,1,0.5", "k": 5,
--                     "docIdsTable": "vmc_cohort", "docIdsColumn": "ids"} AS vmc_hybrid;

SELECT p."id" AS "patient_id", p."condition" AS "condition",
       ROUND(r."distance", 4) AS "distance"
FROM "vmc_hybrid" r, "vmc_patients" p
WHERE r."doc_id" = p."id";

-- ---------------------------------------------------------------------------
-- 3. Patient drift from admission baseline.
-- ---------------------------------------------------------------------------
-- @call search/trajectory {"table": "vmc_patients", "column": "vitals", "id_column": "id",
--                         "baseline": "0.1,0.05,0.0,0.0,0.0",
--                         "current": "1.4,-1.1,0.9,0.7,1.2",
--                         "k": 5} AS vmc_traj;

SELECT p."id" AS "id", p."condition" AS "condition",
       ROUND(r."distance", 4) AS "distance"
FROM "vmc_traj" r, "vmc_patients" p
WHERE r."doc_id" = p."id";

-- The deterioration triage: the cohort-restricted search, the drift,
-- and a rationale.
-- @call agent/patient_deterioration_triage {"patient_table": "vmc_patients",
--                                           "vec_col": "vitals",
--                                           "id_column": "id",
--                                           "query_vec": "1,-1,1,1,0.5",
--                                           "baseline_vec": "0.1,0.05,0.0,0.0,0.0",
--                                           "current_vec": "1.4,-1.1,0.9,0.7,1.2",
--                                           "k": 5};

-- ---------------------------------------------------------------------------
-- 4. fractal_vascular_network: a branching vessel graph -- a 28-node
-- centerline chain plus two branch leaves off node 10.
-- ---------------------------------------------------------------------------
-- @fixture vmc_vessel {"rows": [
--   {"nodes": "0,0,0,1,0,0,2,0,0,3,0,0,4,0,0,5,0,0,6,0,0,7,0,0,8,0,0,9,0,0,10,0,0,11,0,0,12,0,0,13,0,0,14,0,0,15,0,0,16,0,0,17,0,0,18,0,0,19,0,0,20,0,0,21,0,0,22,0,0,23,0,0,24,0,0,25,0,0,26,0,0,27,0,0,10,1,0,10,0,1", "edges": "0,1,1,2,2,3,3,4,4,5,5,6,6,7,7,8,8,9,9,10,10,11,11,12,12,13,13,14,14,15,15,16,16,17,17,18,18,19,19,20,20,21,21,22,22,23,23,24,24,25,25,26,26,27,10,28,10,29", "arcs": "1.02,1.02,1.02,1.02,1.02,1.02,1.02,1.02,1.02,1.02,1.02,1.02,1.02,1.02,1.02,1.02,1.02,1.02,1.02,1.02,1.02,1.02,1.02,1.02,1.02,1.02,1.02,1.02"}
-- ]};

SELECT fractal_vascular_network("nodes", "edges", "arcs") FROM "vmc_vessel";

-- ---------------------------------------------------------------------------
-- 5. fractal_cortical_folding: a unit-cube surface mesh (8 vertices,
-- 12 triangular faces) -- the smooth reference case where the mesh
-- area should closely match the hull area (GI ~ 1.0).
-- ---------------------------------------------------------------------------
SELECT fractal_cortical_folding(
    '0,0,0, 1,0,0, 1,1,0, 0,1,0, 0,0,1, 1,0,1, 1,1,1, 0,1,1',
    '0,1,2, 0,2,3, 4,5,6, 4,6,7, 0,1,5, 0,5,4, 3,2,6, 3,6,7, 0,3,7, 0,7,4, 1,2,6, 1,6,5') AS "gyrification_index";

-- ---------------------------------------------------------------------------
-- 6. fractal_nerve_plexus_metric: an 80-fiber zigzag skeleton.
-- ---------------------------------------------------------------------------
-- @fixture vmc_nerve {"rows": [
--   {"coords": "0.00,0.00,1.00,0.04,2.00,0.05,3.00,0.01,4.00,-0.04,5.00,-0.05,6.00,-0.01,7.00,0.03,8.00,0.05,9.00,0.02,10.00,-0.03,11.00,-0.05,12.00,-0.03,13.00,0.02,14.00,0.05,15.00,0.03,16.00,-0.01,17.00,-0.05,18.00,-0.04,19.00,0.01,20.00,0.05,21.00,0.04,22.00,-0.00,23.00,-0.04,24.00,-0.05,25.00,-0.01,26.00,0.04,27.00,0.05,28.00,0.01,29.00,-0.03,30.00,-0.05,31.00,-0.02,32.00,0.03,33.00,0.05,34.00,0.03,35.00,-0.02,36.00,-0.05,37.00,-0.03,38.00,0.01,39.00,0.05,40.00,0.04,41.00,-0.01,42.00,-0.05,43.00,-0.04,44.00,0.00,45.00,0.04,46.00,0.05,47.00,0.01,48.00,-0.04,49.00,-0.05,50.00,-0.01,51.00,0.03,52.00,0.05,53.00,0.02,54.00,-0.03,55.00,-0.05,56.00,-0.03,57.00,0.02,58.00,0.05,59.00,0.03,60.00,-0.02,61.00,-0.05,62.00,-0.04,63.00,0.01,64.00,0.05,65.00,0.04,66.00,-0.00,67.00,-0.04,68.00,-0.04,69.00,-0.01,70.00,0.04,71.00,0.05,72.00,0.01,73.00,-0.03,74.00,-0.05,75.00,-0.02,76.00,0.03,77.00,0.05,78.00,0.03,79.00,-0.02", "edges": "0,1,1,2,2,3,3,4,4,5,5,6,6,7,7,8,8,9,9,10,10,11,11,12,12,13,13,14,14,15,15,16,16,17,17,18,18,19,19,20,20,21,21,22,22,23,23,24,24,25,25,26,26,27,27,28,28,29,29,30,30,31,31,32,32,33,33,34,34,35,35,36,36,37,37,38,38,39,39,40,40,41,41,42,42,43,43,44,44,45,45,46,46,47,47,48,48,49,49,50,50,51,51,52,52,53,53,54,54,55,55,56,56,57,57,58,58,59,59,60,60,61,61,62,62,63,63,64,64,65,65,66,66,67,67,68,68,69,69,70,70,71,71,72,72,73,73,74,74,75,75,76,76,77,77,78,78,79"}
-- ]};

SELECT fractal_nerve_plexus_metric("coords", 2, "edges") FROM "vmc_nerve";

-- ---------------------------------------------------------------------------
-- The headline.
--
-- The kit passes when the cortical folding reads as a cube (a
-- gyrification index of 1) and the nerve plexus reads as the long
-- zigzag skeleton it is.
-- ---------------------------------------------------------------------------
SELECT CASE
           WHEN fractal_json_value(
                    fractal_cortical_folding(
                        '0,0,0, 1,0,0, 1,1,0, 0,1,0, 0,0,1, 1,0,1, 1,1,1, 0,1,1',
                        '0,1,2, 0,2,3, 4,5,6, 4,6,7, 0,1,5, 0,5,4, 3,2,6, 3,6,7, 0,3,7, 0,7,4, 1,2,6, 1,6,5'),
                    '$.gyrification_index') = 1.0
            AND fractal_json_value(
                    (SELECT fractal_nerve_plexus_metric("coords", 2, "edges") FROM "vmc_nerve"),
                    '$.fiber_length_density') BETWEEN 10.0 AND 10.1
            THEN 'HEADLINE kit=medtech-clinical ok'
            ELSE 'HEADLINE kit=medtech-clinical FAILED'
       END AS "headline";
