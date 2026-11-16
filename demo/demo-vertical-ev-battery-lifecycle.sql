-- demo/demo-vertical-ev-battery-lifecycle.sql
--
-- FractalSQL for Apache Druid -- industry vertical: EV battery
-- lifecycle. Three vehicles x 96 readings: state of health, pack
-- temperature and mean cell voltage. EV-203 fades and heats from
-- reading 65; the other two are healthy.
--
--   1. The telemetry: three vehicles x 96 readings.
--   2. The baseline-to-current trajectory search for EV-203.
--   3. fractal_agent_patient_deterioration_triage: the pack's triage.
--   4. The temperature-regime drift per vehicle.
--   5. Reasoning: one maintenance and safety recommendation over both
--      signals.
--
-- Prerequisites: the extension is loaded on the Druid cluster. The
-- narrative and the agents' rationales need a reasoning provider
-- (docs/reasoning-setup.md); every other step runs with no model.
--
-- Run:
--   python3 demo/run_demo.py --file demo/demo-vertical-ev-battery-lifecycle.sql
--
-- ===========================================================================
-- Notes on how this runs on Druid
-- ===========================================================================
--
--   * The telemetry is an MSQ write: Druid has no DDL, no VALUES and no
--     recursive CTE, so the reading index comes from an UNNESTed array.
--   * The cohort and the two end-state vectors are computed into
--     datasources the agents and the searches read from: an agent's
--     arguments are values, and these are computed.
--   * The searches and the compositions are service calls.
--
-- Notes:
--   * Fully deterministic fixtures (no random()).

-- ---------------------------------------------------------------------------
-- 0. Sanity check: extension loaded?
-- ---------------------------------------------------------------------------
SELECT fractal_edition(), fractal_version();

-- ---------------------------------------------------------------------------
-- 1. The telemetry: three vehicles x 96 readings.
--
-- The state vector is [state of health, temperature over 35C, voltage
-- over 3.70V, health fade].
-- ---------------------------------------------------------------------------
REPLACE INTO ebl_telemetry OVERWRITE ALL
SELECT "id", "vin", "model_year", "seq", "soh", "temp_c", "volt",
       CAST(s."soh" AS VARCHAR) || ','
       || CAST((s."temp_c" - 35.0) / 10.0 AS VARCHAR) || ','
       || CAST((s."volt" - 3.70) / 0.10 AS VARCHAR) || ','
       || CAST((0.99 - s."soh") / s."seq" AS VARCHAR) AS "state"
FROM (
    SELECT v."n" * 96 + r."g" AS "id",
           v."vin" AS "vin",
           v."my" AS "model_year",
           r."g" AS "seq",
           v."n" AS "n",
           0.99 - 0.0004 * r."g"
               - CASE WHEN v."vin" = 'EV-203' AND r."g" > 64 THEN 0.004 * (r."g" - 64) ELSE 0 END AS "soh",
           31.0 + MOD(r."g", 8) * 0.6
               + CASE WHEN v."vin" = 'EV-203' AND r."g" > 64
                      THEN 0.02 * (r."g" - 64) * (r."g" - 64) ELSE 0 END AS "temp_c",
           3.72 - MOD(r."g", 5) * 0.004
               - CASE WHEN v."vin" = 'EV-203' AND r."g" > 64 THEN 0.09 ELSE 0 END AS "volt"
    FROM (
        -- The three vehicles. An explicit array rather than a UNION:
        -- Druid's MSQ write only unions over regular tables, and the
        -- fleet's ordinal and model year fall out of the tail number.
        SELECT CASE t."vin"
                   WHEN 'EV-101' THEN 1
                   WHEN 'EV-102' THEN 2
                   ELSE 3
               END AS "n",
               t."vin" AS "vin",
               CASE t."vin"
                   WHEN 'EV-203' THEN 2023
                   ELSE 2024
               END AS "my"
        FROM UNNEST(ARRAY['EV-101', 'EV-102', 'EV-203']) AS t(vin)
    ) v
    CROSS JOIN (
        SELECT g AS "g" FROM UNNEST(ARRAY[
            1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16, 17, 18, 19, 20,
            21, 22, 23, 24, 25, 26, 27, 28, 29, 30, 31, 32, 33, 34, 35, 36, 37, 38,
            39, 40, 41, 42, 43, 44, 45, 46, 47, 48, 49, 50, 51, 52, 53, 54, 55, 56,
            57, 58, 59, 60, 61, 62, 63, 64, 65, 66, 67, 68, 69, 70, 71, 72, 73, 74,
            75, 76, 77, 78, 79, 80, 81, 82, 83, 84, 85, 86, 87, 88, 89, 90, 91, 92,
            93, 94, 95, 96]) AS t(g)
    ) r
) s
PARTITIONED BY ALL;

-- The state vector: [state of health, temperature over 35C, voltage
-- over 3.70V, health fade].
REPLACE INTO ebl_state OVERWRITE ALL
SELECT "id", "vin", "seq", "state"
FROM (
    SELECT s."id" AS "id", s."vin" AS "vin", s."seq" AS "seq",
           CAST(s."soh" AS VARCHAR) || ','
           || CAST((s."temp_c" - 35.0) / 10.0 AS VARCHAR) || ','
           || CAST((s."volt" - 3.70) / 0.10 AS VARCHAR) || ','
           || CAST((0.99 - s."soh") / s."seq" AS VARCHAR) AS "state"
    FROM "ebl_telemetry" s
) v
PARTITIONED BY ALL;

-- The two end states, and the cohort the triage looks within.
REPLACE INTO ebl_v203 OVERWRITE ALL
SELECT "baseline", "current"
FROM (
    SELECT (SELECT "state" FROM "ebl_state" WHERE "vin" = 'EV-203' AND "seq" = 1) AS "baseline",
           (SELECT "state" FROM "ebl_state" WHERE "vin" = 'EV-203' AND "seq" = 96) AS "current"
) v
PARTITIONED BY ALL;

REPLACE INTO ebl_cohort OVERWRITE ALL
SELECT ARRAY_TO_STRING(ARRAY_AGG(CAST("id" AS VARCHAR), 8192), ',') AS "ids"
FROM "ebl_telemetry" WHERE "model_year" = 2023
PARTITIONED BY ALL;

SELECT "vin", COUNT(*) AS "readings", ROUND(MIN("soh"), 3) AS "min_soh",
       ROUND(MAX("temp_c"), 1) AS "max_temp_c"
FROM "ebl_telemetry" GROUP BY "vin" ORDER BY "vin";

-- ---------------------------------------------------------------------------
-- 2. The baseline-to-current trajectory search for EV-203.
-- ---------------------------------------------------------------------------
-- @call search/trajectory {"table": "ebl_state", "column": "state", "id_column": "id",
--                         "baseline_table": "ebl_v203", "baseline_column": "baseline",
--                         "current_table": "ebl_v203", "current_column": "current",
--                         "k": 5} AS ebl_traj;

SELECT t."vin" AS "vin", t."seq" AS "seq", ROUND(r."distance", 4) AS "distance"
FROM "ebl_traj" r, "ebl_state" t
WHERE r."doc_id" = t."id";

-- ---------------------------------------------------------------------------
-- 3. fractal_agent_patient_deterioration_triage: the pack's triage.
-- ---------------------------------------------------------------------------
-- @call agent/patient_deterioration_triage {"patient_table": "ebl_state",
--                                           "vec_col": "state",
--                                           "id_column": "id",
--                                           "query_vec_table": "ebl_v203",
--                                           "query_vec_column": "current",
--                                           "baseline_vec_table": "ebl_v203",
--                                           "baseline_vec_column": "baseline",
--                                           "current_vec_table": "ebl_v203",
--                                           "current_vec_column": "current",
--                                           "cohort_doc_ids_table": "ebl_cohort",
--                                           "cohort_doc_ids_column": "ids",
--                                           "k": 5};

-- ---------------------------------------------------------------------------
-- 4. The temperature-regime drift per vehicle.
-- ---------------------------------------------------------------------------
REPLACE INTO ebl_drift OVERWRITE ALL
SELECT "vin",
       fractal_dimension_drift(
           ARRAY_TO_STRING(ARRAY_AGG(CAST("temp_c" AS VARCHAR), 16384), ','), 32) AS "dj"
FROM "ebl_telemetry"
GROUP BY "vin"
PARTITIONED BY ALL;

SELECT "vin",
       ROUND(fractal_json_value("dj", '$.drift'), 4) AS "drift",
       ROUND(fractal_json_value("dj", '$.recent_alpha'), 4) AS "recent_alpha",
       ROUND(fractal_json_value("dj", '$.baseline_alpha'), 4) AS "baseline_alpha"
FROM "ebl_drift" GROUP BY "vin", "dj" ORDER BY "vin";

-- The shipped agent: the same composition, one call.
-- @call agent/anomaly_triage {"log_table": "ebl_telemetry", "metric_col": "temp_c",
--                            "time_col": "seq", "filter_col": "vin",
--                            "filter_val": "EV-203", "baseline_window": 32};

-- ---------------------------------------------------------------------------
-- 5. Reasoning: one maintenance and safety recommendation over both
-- signals.
-- ---------------------------------------------------------------------------
SELECT fractal_reason(
    'one-line maintenance and safety recommendation for an EV pack showing '
    || 'both an accelerating state-of-health fade and a thermal regime shift',
    '{"soh_trajectory":"' || (SELECT ARRAY_TO_STRING(ARRAY_AGG(CAST("distance" AS VARCHAR), 8192), ',')
                                  FROM "ebl_traj")
     || '","thermal_drift":"' || (SELECT ARRAY_TO_STRING(ARRAY_AGG(CAST("dj" AS VARCHAR), 8192), ',')
                                  FROM "ebl_drift" WHERE "vin" = 'EV-203')
     || '"}') AS "narrative";

-- ---------------------------------------------------------------------------
-- The headline.
--
-- The kit passes when the telemetry is the size it claims to be and
-- EV-203 really is the problem: its state of health fades further than
-- the other two packs' and it runs hotter.
-- ---------------------------------------------------------------------------
SELECT CASE
           WHEN (SELECT COUNT(*) FROM "ebl_telemetry") = 288
            AND (SELECT MAX("temp_c") FROM "ebl_telemetry" WHERE "vin" = 'EV-203') > 50
            AND (SELECT MIN("soh") FROM "ebl_telemetry" WHERE "vin" = 'EV-203')
                < (SELECT MIN("soh") FROM "ebl_telemetry" WHERE "vin" = 'EV-101')
            THEN 'HEADLINE kit=ev-battery-lifecycle ok'
            ELSE 'HEADLINE kit=ev-battery-lifecycle FAILED'
       END AS "headline";
