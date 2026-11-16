-- demo/demo-vertical-heavy-industry-predictive-maintenance.sql
--
-- FractalSQL for Apache Druid -- industry vertical: heavy machinery and
-- fleet predictive maintenance. Commercial marine vessels,
-- construction and mining equipment, industrial powertrains, hull and
-- structural sensor networks. An AGENTIC kit: two installed agents are
-- chained, shown hand-composed first and then as the shipped one-call
-- agents.
--
--   1. fractal_agent_anomaly_triage -- the drift exponent of one
--      asset's vibration series, flagging a shift into a new
--      (pre-failure) regime.
--   2. fractal_agent_patient_deterioration_triage -- baseline-vs-current
--      trajectory drift against the asset's intake baseline, with a
--      same-class cohort search (an asset plays the patient).
--   3. A closing fractal_reason() produces a maintenance-window
--      recommendation.
--
-- Prerequisites: the extension is loaded on the Druid cluster. The
-- hand-composed sections need no model; the shipped agents and the
-- closing recommendation need a reasoning provider
-- (docs/reasoning-setup.md).
--
-- Run:
--   python3 demo/run_demo.py --file demo/demo-vertical-heavy-industry-predictive-maintenance.sql
--
-- ===========================================================================
-- Notes on how this runs on Druid
-- ===========================================================================
--
--   * The telemetry is a fixture: Druid has no DDL, no row-source
--     literal and no recursive CTE, and a set of rows has no SQL form
--     there. The rows are computed ahead of time and carried in the fixture.
--   * The state vector is a column of that fixture rather than a value
--     built inside the insert, and the two end-state vectors the agent
--     needs are computed into a datasource, because an agent reads its
--     arguments out of tables.
--   * The drift report and the two agents are called the way this host
--     calls them: the drift is a SQL function over the aggregate, and
--     the agents are service calls, because an agent reads a table and
--     reasons about it and a Druid SQL function can do neither.
--   * The closing narrative is a fractal_reason() call over a JSON
--     context the kit assembles from its own result rows.
--
-- Notes:
--   * Fully deterministic fixtures (no random()).
--   * The state vector is [vib_rms_z, kurtosis_z, bearing_temp_z,
--     order1_amp_z] in CSV TEXT.
--   * The drift window is 32 points, so each asset has 96 readings. The
--     failure signature is an ACCELERATING vibration ramp (a growing
--     bearing defect), not a level shift.
--   * The trajectory search's doc_id is the reading row's own id, so
--     the result joins straight back to the telemetry.

-- ---------------------------------------------------------------------------
-- 0. Sanity check: extension loaded?
-- ---------------------------------------------------------------------------
SELECT fractal_edition(), fractal_version();

-- ---------------------------------------------------------------------------
-- 1. Asset telemetry: four assets x 96 readings.
--
-- PUMP-07 develops a bearing defect at reading 65 (accelerating
-- vibration, rising temperature); the others age gently. The class
-- column groups comparable assets.
-- ---------------------------------------------------------------------------
-- @fixture hpm_readings {"rows": [
--   {"id": 1, "asset": "PUMP-03", "class": "centrifugal", "seq": 1, "vib": 2.15, "temp_c": 58.4, "state": "-0.1500,-0.1500,-0.1600,0.0250"},
--   {"id": 2, "asset": "PUMP-03", "class": "centrifugal", "seq": 2, "vib": 2.2, "temp_c": 58.8, "state": "-0.1000,-0.1000,-0.1200,0.0500"},
--   {"id": 3, "asset": "PUMP-03", "class": "centrifugal", "seq": 3, "vib": 2.25, "temp_c": 59.2, "state": "-0.0500,-0.0500,-0.0800,0.0750"},
--   {"id": 4, "asset": "PUMP-03", "class": "centrifugal", "seq": 4, "vib": 2.3, "temp_c": 59.6, "state": "0.0000,0.0000,-0.0400,0.1000"},
--   {"id": 5, "asset": "PUMP-03", "class": "centrifugal", "seq": 5, "vib": 2.35, "temp_c": 60.0, "state": "0.0500,0.0500,0.0000,0.1250"},
--   {"id": 6, "asset": "PUMP-03", "class": "centrifugal", "seq": 6, "vib": 2.4, "temp_c": 58.0, "state": "0.1000,0.1000,-0.2000,0.1500"},
--   {"id": 7, "asset": "PUMP-03", "class": "centrifugal", "seq": 7, "vib": 2.45, "temp_c": 58.4, "state": "0.1500,0.1500,-0.1600,0.1750"},
--   {"id": 8, "asset": "PUMP-03", "class": "centrifugal", "seq": 8, "vib": 2.1, "temp_c": 58.8, "state": "-0.2000,-0.2000,-0.1200,0.0000"},
--   {"id": 9, "asset": "PUMP-03", "class": "centrifugal", "seq": 9, "vib": 2.15, "temp_c": 59.2, "state": "-0.1500,-0.1500,-0.0800,0.0250"},
--   {"id": 10, "asset": "PUMP-03", "class": "centrifugal", "seq": 10, "vib": 2.2, "temp_c": 59.6, "state": "-0.1000,-0.1000,-0.0400,0.0500"},
--   {"id": 11, "asset": "PUMP-03", "class": "centrifugal", "seq": 11, "vib": 2.25, "temp_c": 60.0, "state": "-0.0500,-0.0500,0.0000,0.0750"},
--   {"id": 12, "asset": "PUMP-03", "class": "centrifugal", "seq": 12, "vib": 2.3, "temp_c": 58.0, "state": "0.0000,0.0000,-0.2000,0.1000"},
--   {"id": 13, "asset": "PUMP-03", "class": "centrifugal", "seq": 13, "vib": 2.35, "temp_c": 58.4, "state": "0.0500,0.0500,-0.1600,0.1250"},
--   {"id": 14, "asset": "PUMP-03", "class": "centrifugal", "seq": 14, "vib": 2.4, "temp_c": 58.8, "state": "0.1000,0.1000,-0.1200,0.1500"},
--   {"id": 15, "asset": "PUMP-03", "class": "centrifugal", "seq": 15, "vib": 2.45, "temp_c": 59.2, "state": "0.1500,0.1500,-0.0800,0.1750"},
--   {"id": 16, "asset": "PUMP-03", "class": "centrifugal", "seq": 16, "vib": 2.1, "temp_c": 59.6, "state": "-0.2000,-0.2000,-0.0400,0.0000"},
--   {"id": 17, "asset": "PUMP-03", "class": "centrifugal", "seq": 17, "vib": 2.15, "temp_c": 60.0, "state": "-0.1500,-0.1500,0.0000,0.0250"},
--   {"id": 18, "asset": "PUMP-03", "class": "centrifugal", "seq": 18, "vib": 2.2, "temp_c": 58.0, "state": "-0.1000,-0.1000,-0.2000,0.0500"},
--   {"id": 19, "asset": "PUMP-03", "class": "centrifugal", "seq": 19, "vib": 2.25, "temp_c": 58.4, "state": "-0.0500,-0.0500,-0.1600,0.0750"},
--   {"id": 20, "asset": "PUMP-03", "class": "centrifugal", "seq": 20, "vib": 2.3, "temp_c": 58.8, "state": "0.0000,0.0000,-0.1200,0.1000"},
--   {"id": 21, "asset": "PUMP-03", "class": "centrifugal", "seq": 21, "vib": 2.35, "temp_c": 59.2, "state": "0.0500,0.0500,-0.0800,0.1250"},
--   {"id": 22, "asset": "PUMP-03", "class": "centrifugal", "seq": 22, "vib": 2.4, "temp_c": 59.6, "state": "0.1000,0.1000,-0.0400,0.1500"},
--   {"id": 23, "asset": "PUMP-03", "class": "centrifugal", "seq": 23, "vib": 2.45, "temp_c": 60.0, "state": "0.1500,0.1500,0.0000,0.1750"},
--   {"id": 24, "asset": "PUMP-03", "class": "centrifugal", "seq": 24, "vib": 2.1, "temp_c": 58.0, "state": "-0.2000,-0.2000,-0.2000,0.0000"},
--   {"id": 25, "asset": "PUMP-03", "class": "centrifugal", "seq": 25, "vib": 2.15, "temp_c": 58.4, "state": "-0.1500,-0.1500,-0.1600,0.0250"},
--   {"id": 26, "asset": "PUMP-03", "class": "centrifugal", "seq": 26, "vib": 2.2, "temp_c": 58.8, "state": "-0.1000,-0.1000,-0.1200,0.0500"},
--   {"id": 27, "asset": "PUMP-03", "class": "centrifugal", "seq": 27, "vib": 2.25, "temp_c": 59.2, "state": "-0.0500,-0.0500,-0.0800,0.0750"},
--   {"id": 28, "asset": "PUMP-03", "class": "centrifugal", "seq": 28, "vib": 2.3, "temp_c": 59.6, "state": "0.0000,0.0000,-0.0400,0.1000"},
--   {"id": 29, "asset": "PUMP-03", "class": "centrifugal", "seq": 29, "vib": 2.35, "temp_c": 60.0, "state": "0.0500,0.0500,0.0000,0.1250"},
--   {"id": 30, "asset": "PUMP-03", "class": "centrifugal", "seq": 30, "vib": 2.4, "temp_c": 58.0, "state": "0.1000,0.1000,-0.2000,0.1500"},
--   {"id": 31, "asset": "PUMP-03", "class": "centrifugal", "seq": 31, "vib": 2.45, "temp_c": 58.4, "state": "0.1500,0.1500,-0.1600,0.1750"},
--   {"id": 32, "asset": "PUMP-03", "class": "centrifugal", "seq": 32, "vib": 2.1, "temp_c": 58.8, "state": "-0.2000,-0.2000,-0.1200,0.0000"},
--   {"id": 33, "asset": "PUMP-03", "class": "centrifugal", "seq": 33, "vib": 2.15, "temp_c": 59.2, "state": "-0.1500,-0.1500,-0.0800,0.0250"},
--   {"id": 34, "asset": "PUMP-03", "class": "centrifugal", "seq": 34, "vib": 2.2, "temp_c": 59.6, "state": "-0.1000,-0.1000,-0.0400,0.0500"},
--   {"id": 35, "asset": "PUMP-03", "class": "centrifugal", "seq": 35, "vib": 2.25, "temp_c": 60.0, "state": "-0.0500,-0.0500,0.0000,0.0750"},
--   {"id": 36, "asset": "PUMP-03", "class": "centrifugal", "seq": 36, "vib": 2.3, "temp_c": 58.0, "state": "0.0000,0.0000,-0.2000,0.1000"},
--   {"id": 37, "asset": "PUMP-03", "class": "centrifugal", "seq": 37, "vib": 2.35, "temp_c": 58.4, "state": "0.0500,0.0500,-0.1600,0.1250"},
--   {"id": 38, "asset": "PUMP-03", "class": "centrifugal", "seq": 38, "vib": 2.4, "temp_c": 58.8, "state": "0.1000,0.1000,-0.1200,0.1500"},
--   {"id": 39, "asset": "PUMP-03", "class": "centrifugal", "seq": 39, "vib": 2.45, "temp_c": 59.2, "state": "0.1500,0.1500,-0.0800,0.1750"},
--   {"id": 40, "asset": "PUMP-03", "class": "centrifugal", "seq": 40, "vib": 2.1, "temp_c": 59.6, "state": "-0.2000,-0.2000,-0.0400,0.0000"},
--   {"id": 41, "asset": "PUMP-03", "class": "centrifugal", "seq": 41, "vib": 2.15, "temp_c": 60.0, "state": "-0.1500,-0.1500,0.0000,0.0250"},
--   {"id": 42, "asset": "PUMP-03", "class": "centrifugal", "seq": 42, "vib": 2.2, "temp_c": 58.0, "state": "-0.1000,-0.1000,-0.2000,0.0500"},
--   {"id": 43, "asset": "PUMP-03", "class": "centrifugal", "seq": 43, "vib": 2.25, "temp_c": 58.4, "state": "-0.0500,-0.0500,-0.1600,0.0750"},
--   {"id": 44, "asset": "PUMP-03", "class": "centrifugal", "seq": 44, "vib": 2.3, "temp_c": 58.8, "state": "0.0000,0.0000,-0.1200,0.1000"},
--   {"id": 45, "asset": "PUMP-03", "class": "centrifugal", "seq": 45, "vib": 2.35, "temp_c": 59.2, "state": "0.0500,0.0500,-0.0800,0.1250"},
--   {"id": 46, "asset": "PUMP-03", "class": "centrifugal", "seq": 46, "vib": 2.4, "temp_c": 59.6, "state": "0.1000,0.1000,-0.0400,0.1500"},
--   {"id": 47, "asset": "PUMP-03", "class": "centrifugal", "seq": 47, "vib": 2.45, "temp_c": 60.0, "state": "0.1500,0.1500,0.0000,0.1750"},
--   {"id": 48, "asset": "PUMP-03", "class": "centrifugal", "seq": 48, "vib": 2.1, "temp_c": 58.0, "state": "-0.2000,-0.2000,-0.2000,0.0000"},
--   {"id": 49, "asset": "PUMP-03", "class": "centrifugal", "seq": 49, "vib": 2.15, "temp_c": 58.4, "state": "-0.1500,-0.1500,-0.1600,0.0250"},
--   {"id": 50, "asset": "PUMP-03", "class": "centrifugal", "seq": 50, "vib": 2.2, "temp_c": 58.8, "state": "-0.1000,-0.1000,-0.1200,0.0500"},
--   {"id": 51, "asset": "PUMP-03", "class": "centrifugal", "seq": 51, "vib": 2.25, "temp_c": 59.2, "state": "-0.0500,-0.0500,-0.0800,0.0750"},
--   {"id": 52, "asset": "PUMP-03", "class": "centrifugal", "seq": 52, "vib": 2.3, "temp_c": 59.6, "state": "0.0000,0.0000,-0.0400,0.1000"},
--   {"id": 53, "asset": "PUMP-03", "class": "centrifugal", "seq": 53, "vib": 2.35, "temp_c": 60.0, "state": "0.0500,0.0500,0.0000,0.1250"},
--   {"id": 54, "asset": "PUMP-03", "class": "centrifugal", "seq": 54, "vib": 2.4, "temp_c": 58.0, "state": "0.1000,0.1000,-0.2000,0.1500"},
--   {"id": 55, "asset": "PUMP-03", "class": "centrifugal", "seq": 55, "vib": 2.45, "temp_c": 58.4, "state": "0.1500,0.1500,-0.1600,0.1750"},
--   {"id": 56, "asset": "PUMP-03", "class": "centrifugal", "seq": 56, "vib": 2.1, "temp_c": 58.8, "state": "-0.2000,-0.2000,-0.1200,0.0000"},
--   {"id": 57, "asset": "PUMP-03", "class": "centrifugal", "seq": 57, "vib": 2.15, "temp_c": 59.2, "state": "-0.1500,-0.1500,-0.0800,0.0250"},
--   {"id": 58, "asset": "PUMP-03", "class": "centrifugal", "seq": 58, "vib": 2.2, "temp_c": 59.6, "state": "-0.1000,-0.1000,-0.0400,0.0500"},
--   {"id": 59, "asset": "PUMP-03", "class": "centrifugal", "seq": 59, "vib": 2.25, "temp_c": 60.0, "state": "-0.0500,-0.0500,0.0000,0.0750"},
--   {"id": 60, "asset": "PUMP-03", "class": "centrifugal", "seq": 60, "vib": 2.3, "temp_c": 58.0, "state": "0.0000,0.0000,-0.2000,0.1000"},
--   {"id": 61, "asset": "PUMP-03", "class": "centrifugal", "seq": 61, "vib": 2.35, "temp_c": 58.4, "state": "0.0500,0.0500,-0.1600,0.1250"},
--   {"id": 62, "asset": "PUMP-03", "class": "centrifugal", "seq": 62, "vib": 2.4, "temp_c": 58.8, "state": "0.1000,0.1000,-0.1200,0.1500"},
--   {"id": 63, "asset": "PUMP-03", "class": "centrifugal", "seq": 63, "vib": 2.45, "temp_c": 59.2, "state": "0.1500,0.1500,-0.0800,0.1750"},
--   {"id": 64, "asset": "PUMP-03", "class": "centrifugal", "seq": 64, "vib": 2.1, "temp_c": 59.6, "state": "-0.2000,-0.2000,-0.0400,0.0000"},
--   {"id": 65, "asset": "PUMP-03", "class": "centrifugal", "seq": 65, "vib": 2.15, "temp_c": 60.0, "state": "-0.1500,-0.1500,0.0000,0.0250"},
--   {"id": 66, "asset": "PUMP-03", "class": "centrifugal", "seq": 66, "vib": 2.2, "temp_c": 58.0, "state": "-0.1000,-0.1000,-0.2000,0.0500"},
--   {"id": 67, "asset": "PUMP-03", "class": "centrifugal", "seq": 67, "vib": 2.25, "temp_c": 58.4, "state": "-0.0500,-0.0500,-0.1600,0.0750"},
--   {"id": 68, "asset": "PUMP-03", "class": "centrifugal", "seq": 68, "vib": 2.3, "temp_c": 58.8, "state": "0.0000,0.0000,-0.1200,0.1000"},
--   {"id": 69, "asset": "PUMP-03", "class": "centrifugal", "seq": 69, "vib": 2.35, "temp_c": 59.2, "state": "0.0500,0.0500,-0.0800,0.1250"},
--   {"id": 70, "asset": "PUMP-03", "class": "centrifugal", "seq": 70, "vib": 2.4, "temp_c": 59.6, "state": "0.1000,0.1000,-0.0400,0.1500"},
--   {"id": 71, "asset": "PUMP-03", "class": "centrifugal", "seq": 71, "vib": 2.45, "temp_c": 60.0, "state": "0.1500,0.1500,0.0000,0.1750"},
--   {"id": 72, "asset": "PUMP-03", "class": "centrifugal", "seq": 72, "vib": 2.1, "temp_c": 58.0, "state": "-0.2000,-0.2000,-0.2000,0.0000"},
--   {"id": 73, "asset": "PUMP-03", "class": "centrifugal", "seq": 73, "vib": 2.15, "temp_c": 58.4, "state": "-0.1500,-0.1500,-0.1600,0.0250"},
--   {"id": 74, "asset": "PUMP-03", "class": "centrifugal", "seq": 74, "vib": 2.2, "temp_c": 58.8, "state": "-0.1000,-0.1000,-0.1200,0.0500"},
--   {"id": 75, "asset": "PUMP-03", "class": "centrifugal", "seq": 75, "vib": 2.25, "temp_c": 59.2, "state": "-0.0500,-0.0500,-0.0800,0.0750"},
--   {"id": 76, "asset": "PUMP-03", "class": "centrifugal", "seq": 76, "vib": 2.3, "temp_c": 59.6, "state": "0.0000,0.0000,-0.0400,0.1000"},
--   {"id": 77, "asset": "PUMP-03", "class": "centrifugal", "seq": 77, "vib": 2.35, "temp_c": 60.0, "state": "0.0500,0.0500,0.0000,0.1250"},
--   {"id": 78, "asset": "PUMP-03", "class": "centrifugal", "seq": 78, "vib": 2.4, "temp_c": 58.0, "state": "0.1000,0.1000,-0.2000,0.1500"},
--   {"id": 79, "asset": "PUMP-03", "class": "centrifugal", "seq": 79, "vib": 2.45, "temp_c": 58.4, "state": "0.1500,0.1500,-0.1600,0.1750"},
--   {"id": 80, "asset": "PUMP-03", "class": "centrifugal", "seq": 80, "vib": 2.1, "temp_c": 58.8, "state": "-0.2000,-0.2000,-0.1200,0.0000"},
--   {"id": 81, "asset": "PUMP-03", "class": "centrifugal", "seq": 81, "vib": 2.15, "temp_c": 59.2, "state": "-0.1500,-0.1500,-0.0800,0.0250"},
--   {"id": 82, "asset": "PUMP-03", "class": "centrifugal", "seq": 82, "vib": 2.2, "temp_c": 59.6, "state": "-0.1000,-0.1000,-0.0400,0.0500"},
--   {"id": 83, "asset": "PUMP-03", "class": "centrifugal", "seq": 83, "vib": 2.25, "temp_c": 60.0, "state": "-0.0500,-0.0500,0.0000,0.0750"},
--   {"id": 84, "asset": "PUMP-03", "class": "centrifugal", "seq": 84, "vib": 2.3, "temp_c": 58.0, "state": "0.0000,0.0000,-0.2000,0.1000"},
--   {"id": 85, "asset": "PUMP-03", "class": "centrifugal", "seq": 85, "vib": 2.35, "temp_c": 58.4, "state": "0.0500,0.0500,-0.1600,0.1250"},
--   {"id": 86, "asset": "PUMP-03", "class": "centrifugal", "seq": 86, "vib": 2.4, "temp_c": 58.8, "state": "0.1000,0.1000,-0.1200,0.1500"},
--   {"id": 87, "asset": "PUMP-03", "class": "centrifugal", "seq": 87, "vib": 2.45, "temp_c": 59.2, "state": "0.1500,0.1500,-0.0800,0.1750"},
--   {"id": 88, "asset": "PUMP-03", "class": "centrifugal", "seq": 88, "vib": 2.1, "temp_c": 59.6, "state": "-0.2000,-0.2000,-0.0400,0.0000"},
--   {"id": 89, "asset": "PUMP-03", "class": "centrifugal", "seq": 89, "vib": 2.15, "temp_c": 60.0, "state": "-0.1500,-0.1500,0.0000,0.0250"},
--   {"id": 90, "asset": "PUMP-03", "class": "centrifugal", "seq": 90, "vib": 2.2, "temp_c": 58.0, "state": "-0.1000,-0.1000,-0.2000,0.0500"},
--   {"id": 91, "asset": "PUMP-03", "class": "centrifugal", "seq": 91, "vib": 2.25, "temp_c": 58.4, "state": "-0.0500,-0.0500,-0.1600,0.0750"},
--   {"id": 92, "asset": "PUMP-03", "class": "centrifugal", "seq": 92, "vib": 2.3, "temp_c": 58.8, "state": "0.0000,0.0000,-0.1200,0.1000"},
--   {"id": 93, "asset": "PUMP-03", "class": "centrifugal", "seq": 93, "vib": 2.35, "temp_c": 59.2, "state": "0.0500,0.0500,-0.0800,0.1250"},
--   {"id": 94, "asset": "PUMP-03", "class": "centrifugal", "seq": 94, "vib": 2.4, "temp_c": 59.6, "state": "0.1000,0.1000,-0.0400,0.1500"},
--   {"id": 95, "asset": "PUMP-03", "class": "centrifugal", "seq": 95, "vib": 2.45, "temp_c": 60.0, "state": "0.1500,0.1500,0.0000,0.1750"},
--   {"id": 96, "asset": "PUMP-03", "class": "centrifugal", "seq": 96, "vib": 2.1, "temp_c": 58.0, "state": "-0.2000,-0.2000,-0.2000,0.0000"},
--   {"id": 97, "asset": "PUMP-05", "class": "centrifugal", "seq": 1, "vib": 2.15, "temp_c": 58.4, "state": "-0.1500,-0.1500,-0.1600,0.0250"},
--   {"id": 98, "asset": "PUMP-05", "class": "centrifugal", "seq": 2, "vib": 2.2, "temp_c": 58.8, "state": "-0.1000,-0.1000,-0.1200,0.0500"},
--   {"id": 99, "asset": "PUMP-05", "class": "centrifugal", "seq": 3, "vib": 2.25, "temp_c": 59.2, "state": "-0.0500,-0.0500,-0.0800,0.0750"},
--   {"id": 100, "asset": "PUMP-05", "class": "centrifugal", "seq": 4, "vib": 2.3, "temp_c": 59.6, "state": "0.0000,0.0000,-0.0400,0.1000"},
--   {"id": 101, "asset": "PUMP-05", "class": "centrifugal", "seq": 5, "vib": 2.35, "temp_c": 60.0, "state": "0.0500,0.0500,0.0000,0.1250"},
--   {"id": 102, "asset": "PUMP-05", "class": "centrifugal", "seq": 6, "vib": 2.4, "temp_c": 58.0, "state": "0.1000,0.1000,-0.2000,0.1500"},
--   {"id": 103, "asset": "PUMP-05", "class": "centrifugal", "seq": 7, "vib": 2.45, "temp_c": 58.4, "state": "0.1500,0.1500,-0.1600,0.1750"},
--   {"id": 104, "asset": "PUMP-05", "class": "centrifugal", "seq": 8, "vib": 2.1, "temp_c": 58.8, "state": "-0.2000,-0.2000,-0.1200,0.0000"},
--   {"id": 105, "asset": "PUMP-05", "class": "centrifugal", "seq": 9, "vib": 2.15, "temp_c": 59.2, "state": "-0.1500,-0.1500,-0.0800,0.0250"},
--   {"id": 106, "asset": "PUMP-05", "class": "centrifugal", "seq": 10, "vib": 2.2, "temp_c": 59.6, "state": "-0.1000,-0.1000,-0.0400,0.0500"},
--   {"id": 107, "asset": "PUMP-05", "class": "centrifugal", "seq": 11, "vib": 2.25, "temp_c": 60.0, "state": "-0.0500,-0.0500,0.0000,0.0750"},
--   {"id": 108, "asset": "PUMP-05", "class": "centrifugal", "seq": 12, "vib": 2.3, "temp_c": 58.0, "state": "0.0000,0.0000,-0.2000,0.1000"},
--   {"id": 109, "asset": "PUMP-05", "class": "centrifugal", "seq": 13, "vib": 2.35, "temp_c": 58.4, "state": "0.0500,0.0500,-0.1600,0.1250"},
--   {"id": 110, "asset": "PUMP-05", "class": "centrifugal", "seq": 14, "vib": 2.4, "temp_c": 58.8, "state": "0.1000,0.1000,-0.1200,0.1500"},
--   {"id": 111, "asset": "PUMP-05", "class": "centrifugal", "seq": 15, "vib": 2.45, "temp_c": 59.2, "state": "0.1500,0.1500,-0.0800,0.1750"},
--   {"id": 112, "asset": "PUMP-05", "class": "centrifugal", "seq": 16, "vib": 2.1, "temp_c": 59.6, "state": "-0.2000,-0.2000,-0.0400,0.0000"},
--   {"id": 113, "asset": "PUMP-05", "class": "centrifugal", "seq": 17, "vib": 2.15, "temp_c": 60.0, "state": "-0.1500,-0.1500,0.0000,0.0250"},
--   {"id": 114, "asset": "PUMP-05", "class": "centrifugal", "seq": 18, "vib": 2.2, "temp_c": 58.0, "state": "-0.1000,-0.1000,-0.2000,0.0500"},
--   {"id": 115, "asset": "PUMP-05", "class": "centrifugal", "seq": 19, "vib": 2.25, "temp_c": 58.4, "state": "-0.0500,-0.0500,-0.1600,0.0750"},
--   {"id": 116, "asset": "PUMP-05", "class": "centrifugal", "seq": 20, "vib": 2.3, "temp_c": 58.8, "state": "0.0000,0.0000,-0.1200,0.1000"},
--   {"id": 117, "asset": "PUMP-05", "class": "centrifugal", "seq": 21, "vib": 2.35, "temp_c": 59.2, "state": "0.0500,0.0500,-0.0800,0.1250"},
--   {"id": 118, "asset": "PUMP-05", "class": "centrifugal", "seq": 22, "vib": 2.4, "temp_c": 59.6, "state": "0.1000,0.1000,-0.0400,0.1500"},
--   {"id": 119, "asset": "PUMP-05", "class": "centrifugal", "seq": 23, "vib": 2.45, "temp_c": 60.0, "state": "0.1500,0.1500,0.0000,0.1750"},
--   {"id": 120, "asset": "PUMP-05", "class": "centrifugal", "seq": 24, "vib": 2.1, "temp_c": 58.0, "state": "-0.2000,-0.2000,-0.2000,0.0000"},
--   {"id": 121, "asset": "PUMP-05", "class": "centrifugal", "seq": 25, "vib": 2.15, "temp_c": 58.4, "state": "-0.1500,-0.1500,-0.1600,0.0250"},
--   {"id": 122, "asset": "PUMP-05", "class": "centrifugal", "seq": 26, "vib": 2.2, "temp_c": 58.8, "state": "-0.1000,-0.1000,-0.1200,0.0500"},
--   {"id": 123, "asset": "PUMP-05", "class": "centrifugal", "seq": 27, "vib": 2.25, "temp_c": 59.2, "state": "-0.0500,-0.0500,-0.0800,0.0750"},
--   {"id": 124, "asset": "PUMP-05", "class": "centrifugal", "seq": 28, "vib": 2.3, "temp_c": 59.6, "state": "0.0000,0.0000,-0.0400,0.1000"},
--   {"id": 125, "asset": "PUMP-05", "class": "centrifugal", "seq": 29, "vib": 2.35, "temp_c": 60.0, "state": "0.0500,0.0500,0.0000,0.1250"},
--   {"id": 126, "asset": "PUMP-05", "class": "centrifugal", "seq": 30, "vib": 2.4, "temp_c": 58.0, "state": "0.1000,0.1000,-0.2000,0.1500"},
--   {"id": 127, "asset": "PUMP-05", "class": "centrifugal", "seq": 31, "vib": 2.45, "temp_c": 58.4, "state": "0.1500,0.1500,-0.1600,0.1750"},
--   {"id": 128, "asset": "PUMP-05", "class": "centrifugal", "seq": 32, "vib": 2.1, "temp_c": 58.8, "state": "-0.2000,-0.2000,-0.1200,0.0000"},
--   {"id": 129, "asset": "PUMP-05", "class": "centrifugal", "seq": 33, "vib": 2.15, "temp_c": 59.2, "state": "-0.1500,-0.1500,-0.0800,0.0250"},
--   {"id": 130, "asset": "PUMP-05", "class": "centrifugal", "seq": 34, "vib": 2.2, "temp_c": 59.6, "state": "-0.1000,-0.1000,-0.0400,0.0500"},
--   {"id": 131, "asset": "PUMP-05", "class": "centrifugal", "seq": 35, "vib": 2.25, "temp_c": 60.0, "state": "-0.0500,-0.0500,0.0000,0.0750"},
--   {"id": 132, "asset": "PUMP-05", "class": "centrifugal", "seq": 36, "vib": 2.3, "temp_c": 58.0, "state": "0.0000,0.0000,-0.2000,0.1000"},
--   {"id": 133, "asset": "PUMP-05", "class": "centrifugal", "seq": 37, "vib": 2.35, "temp_c": 58.4, "state": "0.0500,0.0500,-0.1600,0.1250"},
--   {"id": 134, "asset": "PUMP-05", "class": "centrifugal", "seq": 38, "vib": 2.4, "temp_c": 58.8, "state": "0.1000,0.1000,-0.1200,0.1500"},
--   {"id": 135, "asset": "PUMP-05", "class": "centrifugal", "seq": 39, "vib": 2.45, "temp_c": 59.2, "state": "0.1500,0.1500,-0.0800,0.1750"},
--   {"id": 136, "asset": "PUMP-05", "class": "centrifugal", "seq": 40, "vib": 2.1, "temp_c": 59.6, "state": "-0.2000,-0.2000,-0.0400,0.0000"},
--   {"id": 137, "asset": "PUMP-05", "class": "centrifugal", "seq": 41, "vib": 2.15, "temp_c": 60.0, "state": "-0.1500,-0.1500,0.0000,0.0250"},
--   {"id": 138, "asset": "PUMP-05", "class": "centrifugal", "seq": 42, "vib": 2.2, "temp_c": 58.0, "state": "-0.1000,-0.1000,-0.2000,0.0500"},
--   {"id": 139, "asset": "PUMP-05", "class": "centrifugal", "seq": 43, "vib": 2.25, "temp_c": 58.4, "state": "-0.0500,-0.0500,-0.1600,0.0750"},
--   {"id": 140, "asset": "PUMP-05", "class": "centrifugal", "seq": 44, "vib": 2.3, "temp_c": 58.8, "state": "0.0000,0.0000,-0.1200,0.1000"},
--   {"id": 141, "asset": "PUMP-05", "class": "centrifugal", "seq": 45, "vib": 2.35, "temp_c": 59.2, "state": "0.0500,0.0500,-0.0800,0.1250"},
--   {"id": 142, "asset": "PUMP-05", "class": "centrifugal", "seq": 46, "vib": 2.4, "temp_c": 59.6, "state": "0.1000,0.1000,-0.0400,0.1500"},
--   {"id": 143, "asset": "PUMP-05", "class": "centrifugal", "seq": 47, "vib": 2.45, "temp_c": 60.0, "state": "0.1500,0.1500,0.0000,0.1750"},
--   {"id": 144, "asset": "PUMP-05", "class": "centrifugal", "seq": 48, "vib": 2.1, "temp_c": 58.0, "state": "-0.2000,-0.2000,-0.2000,0.0000"},
--   {"id": 145, "asset": "PUMP-05", "class": "centrifugal", "seq": 49, "vib": 2.15, "temp_c": 58.4, "state": "-0.1500,-0.1500,-0.1600,0.0250"},
--   {"id": 146, "asset": "PUMP-05", "class": "centrifugal", "seq": 50, "vib": 2.2, "temp_c": 58.8, "state": "-0.1000,-0.1000,-0.1200,0.0500"},
--   {"id": 147, "asset": "PUMP-05", "class": "centrifugal", "seq": 51, "vib": 2.25, "temp_c": 59.2, "state": "-0.0500,-0.0500,-0.0800,0.0750"},
--   {"id": 148, "asset": "PUMP-05", "class": "centrifugal", "seq": 52, "vib": 2.3, "temp_c": 59.6, "state": "0.0000,0.0000,-0.0400,0.1000"},
--   {"id": 149, "asset": "PUMP-05", "class": "centrifugal", "seq": 53, "vib": 2.35, "temp_c": 60.0, "state": "0.0500,0.0500,0.0000,0.1250"},
--   {"id": 150, "asset": "PUMP-05", "class": "centrifugal", "seq": 54, "vib": 2.4, "temp_c": 58.0, "state": "0.1000,0.1000,-0.2000,0.1500"},
--   {"id": 151, "asset": "PUMP-05", "class": "centrifugal", "seq": 55, "vib": 2.45, "temp_c": 58.4, "state": "0.1500,0.1500,-0.1600,0.1750"},
--   {"id": 152, "asset": "PUMP-05", "class": "centrifugal", "seq": 56, "vib": 2.1, "temp_c": 58.8, "state": "-0.2000,-0.2000,-0.1200,0.0000"},
--   {"id": 153, "asset": "PUMP-05", "class": "centrifugal", "seq": 57, "vib": 2.15, "temp_c": 59.2, "state": "-0.1500,-0.1500,-0.0800,0.0250"},
--   {"id": 154, "asset": "PUMP-05", "class": "centrifugal", "seq": 58, "vib": 2.2, "temp_c": 59.6, "state": "-0.1000,-0.1000,-0.0400,0.0500"},
--   {"id": 155, "asset": "PUMP-05", "class": "centrifugal", "seq": 59, "vib": 2.25, "temp_c": 60.0, "state": "-0.0500,-0.0500,0.0000,0.0750"},
--   {"id": 156, "asset": "PUMP-05", "class": "centrifugal", "seq": 60, "vib": 2.3, "temp_c": 58.0, "state": "0.0000,0.0000,-0.2000,0.1000"},
--   {"id": 157, "asset": "PUMP-05", "class": "centrifugal", "seq": 61, "vib": 2.35, "temp_c": 58.4, "state": "0.0500,0.0500,-0.1600,0.1250"},
--   {"id": 158, "asset": "PUMP-05", "class": "centrifugal", "seq": 62, "vib": 2.4, "temp_c": 58.8, "state": "0.1000,0.1000,-0.1200,0.1500"},
--   {"id": 159, "asset": "PUMP-05", "class": "centrifugal", "seq": 63, "vib": 2.45, "temp_c": 59.2, "state": "0.1500,0.1500,-0.0800,0.1750"},
--   {"id": 160, "asset": "PUMP-05", "class": "centrifugal", "seq": 64, "vib": 2.1, "temp_c": 59.6, "state": "-0.2000,-0.2000,-0.0400,0.0000"},
--   {"id": 161, "asset": "PUMP-05", "class": "centrifugal", "seq": 65, "vib": 2.15, "temp_c": 60.0, "state": "-0.1500,-0.1500,0.0000,0.0250"},
--   {"id": 162, "asset": "PUMP-05", "class": "centrifugal", "seq": 66, "vib": 2.2, "temp_c": 58.0, "state": "-0.1000,-0.1000,-0.2000,0.0500"},
--   {"id": 163, "asset": "PUMP-05", "class": "centrifugal", "seq": 67, "vib": 2.25, "temp_c": 58.4, "state": "-0.0500,-0.0500,-0.1600,0.0750"},
--   {"id": 164, "asset": "PUMP-05", "class": "centrifugal", "seq": 68, "vib": 2.3, "temp_c": 58.8, "state": "0.0000,0.0000,-0.1200,0.1000"},
--   {"id": 165, "asset": "PUMP-05", "class": "centrifugal", "seq": 69, "vib": 2.35, "temp_c": 59.2, "state": "0.0500,0.0500,-0.0800,0.1250"},
--   {"id": 166, "asset": "PUMP-05", "class": "centrifugal", "seq": 70, "vib": 2.4, "temp_c": 59.6, "state": "0.1000,0.1000,-0.0400,0.1500"},
--   {"id": 167, "asset": "PUMP-05", "class": "centrifugal", "seq": 71, "vib": 2.45, "temp_c": 60.0, "state": "0.1500,0.1500,0.0000,0.1750"},
--   {"id": 168, "asset": "PUMP-05", "class": "centrifugal", "seq": 72, "vib": 2.1, "temp_c": 58.0, "state": "-0.2000,-0.2000,-0.2000,0.0000"},
--   {"id": 169, "asset": "PUMP-05", "class": "centrifugal", "seq": 73, "vib": 2.15, "temp_c": 58.4, "state": "-0.1500,-0.1500,-0.1600,0.0250"},
--   {"id": 170, "asset": "PUMP-05", "class": "centrifugal", "seq": 74, "vib": 2.2, "temp_c": 58.8, "state": "-0.1000,-0.1000,-0.1200,0.0500"},
--   {"id": 171, "asset": "PUMP-05", "class": "centrifugal", "seq": 75, "vib": 2.25, "temp_c": 59.2, "state": "-0.0500,-0.0500,-0.0800,0.0750"},
--   {"id": 172, "asset": "PUMP-05", "class": "centrifugal", "seq": 76, "vib": 2.3, "temp_c": 59.6, "state": "0.0000,0.0000,-0.0400,0.1000"},
--   {"id": 173, "asset": "PUMP-05", "class": "centrifugal", "seq": 77, "vib": 2.35, "temp_c": 60.0, "state": "0.0500,0.0500,0.0000,0.1250"},
--   {"id": 174, "asset": "PUMP-05", "class": "centrifugal", "seq": 78, "vib": 2.4, "temp_c": 58.0, "state": "0.1000,0.1000,-0.2000,0.1500"},
--   {"id": 175, "asset": "PUMP-05", "class": "centrifugal", "seq": 79, "vib": 2.45, "temp_c": 58.4, "state": "0.1500,0.1500,-0.1600,0.1750"},
--   {"id": 176, "asset": "PUMP-05", "class": "centrifugal", "seq": 80, "vib": 2.1, "temp_c": 58.8, "state": "-0.2000,-0.2000,-0.1200,0.0000"},
--   {"id": 177, "asset": "PUMP-05", "class": "centrifugal", "seq": 81, "vib": 2.15, "temp_c": 59.2, "state": "-0.1500,-0.1500,-0.0800,0.0250"},
--   {"id": 178, "asset": "PUMP-05", "class": "centrifugal", "seq": 82, "vib": 2.2, "temp_c": 59.6, "state": "-0.1000,-0.1000,-0.0400,0.0500"},
--   {"id": 179, "asset": "PUMP-05", "class": "centrifugal", "seq": 83, "vib": 2.25, "temp_c": 60.0, "state": "-0.0500,-0.0500,0.0000,0.0750"},
--   {"id": 180, "asset": "PUMP-05", "class": "centrifugal", "seq": 84, "vib": 2.3, "temp_c": 58.0, "state": "0.0000,0.0000,-0.2000,0.1000"},
--   {"id": 181, "asset": "PUMP-05", "class": "centrifugal", "seq": 85, "vib": 2.35, "temp_c": 58.4, "state": "0.0500,0.0500,-0.1600,0.1250"},
--   {"id": 182, "asset": "PUMP-05", "class": "centrifugal", "seq": 86, "vib": 2.4, "temp_c": 58.8, "state": "0.1000,0.1000,-0.1200,0.1500"},
--   {"id": 183, "asset": "PUMP-05", "class": "centrifugal", "seq": 87, "vib": 2.45, "temp_c": 59.2, "state": "0.1500,0.1500,-0.0800,0.1750"},
--   {"id": 184, "asset": "PUMP-05", "class": "centrifugal", "seq": 88, "vib": 2.1, "temp_c": 59.6, "state": "-0.2000,-0.2000,-0.0400,0.0000"},
--   {"id": 185, "asset": "PUMP-05", "class": "centrifugal", "seq": 89, "vib": 2.15, "temp_c": 60.0, "state": "-0.1500,-0.1500,0.0000,0.0250"},
--   {"id": 186, "asset": "PUMP-05", "class": "centrifugal", "seq": 90, "vib": 2.2, "temp_c": 58.0, "state": "-0.1000,-0.1000,-0.2000,0.0500"},
--   {"id": 187, "asset": "PUMP-05", "class": "centrifugal", "seq": 91, "vib": 2.25, "temp_c": 58.4, "state": "-0.0500,-0.0500,-0.1600,0.0750"},
--   {"id": 188, "asset": "PUMP-05", "class": "centrifugal", "seq": 92, "vib": 2.3, "temp_c": 58.8, "state": "0.0000,0.0000,-0.1200,0.1000"},
--   {"id": 189, "asset": "PUMP-05", "class": "centrifugal", "seq": 93, "vib": 2.35, "temp_c": 59.2, "state": "0.0500,0.0500,-0.0800,0.1250"},
--   {"id": 190, "asset": "PUMP-05", "class": "centrifugal", "seq": 94, "vib": 2.4, "temp_c": 59.6, "state": "0.1000,0.1000,-0.0400,0.1500"},
--   {"id": 191, "asset": "PUMP-05", "class": "centrifugal", "seq": 95, "vib": 2.45, "temp_c": 60.0, "state": "0.1500,0.1500,0.0000,0.1750"},
--   {"id": 192, "asset": "PUMP-05", "class": "centrifugal", "seq": 96, "vib": 2.1, "temp_c": 58.0, "state": "-0.2000,-0.2000,-0.2000,0.0000"},
--   {"id": 193, "asset": "PUMP-07", "class": "centrifugal", "seq": 1, "vib": 2.15, "temp_c": 58.4, "state": "-0.1500,-0.1500,-0.1600,0.0250"},
--   {"id": 194, "asset": "PUMP-07", "class": "centrifugal", "seq": 2, "vib": 2.2, "temp_c": 58.8, "state": "-0.1000,-0.1000,-0.1200,0.0500"},
--   {"id": 195, "asset": "PUMP-07", "class": "centrifugal", "seq": 3, "vib": 2.25, "temp_c": 59.2, "state": "-0.0500,-0.0500,-0.0800,0.0750"},
--   {"id": 196, "asset": "PUMP-07", "class": "centrifugal", "seq": 4, "vib": 2.3, "temp_c": 59.6, "state": "0.0000,0.0000,-0.0400,0.1000"},
--   {"id": 197, "asset": "PUMP-07", "class": "centrifugal", "seq": 5, "vib": 2.35, "temp_c": 60.0, "state": "0.0500,0.0500,0.0000,0.1250"},
--   {"id": 198, "asset": "PUMP-07", "class": "centrifugal", "seq": 6, "vib": 2.4, "temp_c": 58.0, "state": "0.1000,0.1000,-0.2000,0.1500"},
--   {"id": 199, "asset": "PUMP-07", "class": "centrifugal", "seq": 7, "vib": 2.45, "temp_c": 58.4, "state": "0.1500,0.1500,-0.1600,0.1750"},
--   {"id": 200, "asset": "PUMP-07", "class": "centrifugal", "seq": 8, "vib": 2.1, "temp_c": 58.8, "state": "-0.2000,-0.2000,-0.1200,0.0000"},
--   {"id": 201, "asset": "PUMP-07", "class": "centrifugal", "seq": 9, "vib": 2.15, "temp_c": 59.2, "state": "-0.1500,-0.1500,-0.0800,0.0250"},
--   {"id": 202, "asset": "PUMP-07", "class": "centrifugal", "seq": 10, "vib": 2.2, "temp_c": 59.6, "state": "-0.1000,-0.1000,-0.0400,0.0500"},
--   {"id": 203, "asset": "PUMP-07", "class": "centrifugal", "seq": 11, "vib": 2.25, "temp_c": 60.0, "state": "-0.0500,-0.0500,0.0000,0.0750"},
--   {"id": 204, "asset": "PUMP-07", "class": "centrifugal", "seq": 12, "vib": 2.3, "temp_c": 58.0, "state": "0.0000,0.0000,-0.2000,0.1000"},
--   {"id": 205, "asset": "PUMP-07", "class": "centrifugal", "seq": 13, "vib": 2.35, "temp_c": 58.4, "state": "0.0500,0.0500,-0.1600,0.1250"},
--   {"id": 206, "asset": "PUMP-07", "class": "centrifugal", "seq": 14, "vib": 2.4, "temp_c": 58.8, "state": "0.1000,0.1000,-0.1200,0.1500"},
--   {"id": 207, "asset": "PUMP-07", "class": "centrifugal", "seq": 15, "vib": 2.45, "temp_c": 59.2, "state": "0.1500,0.1500,-0.0800,0.1750"},
--   {"id": 208, "asset": "PUMP-07", "class": "centrifugal", "seq": 16, "vib": 2.1, "temp_c": 59.6, "state": "-0.2000,-0.2000,-0.0400,0.0000"},
--   {"id": 209, "asset": "PUMP-07", "class": "centrifugal", "seq": 17, "vib": 2.15, "temp_c": 60.0, "state": "-0.1500,-0.1500,0.0000,0.0250"},
--   {"id": 210, "asset": "PUMP-07", "class": "centrifugal", "seq": 18, "vib": 2.2, "temp_c": 58.0, "state": "-0.1000,-0.1000,-0.2000,0.0500"},
--   {"id": 211, "asset": "PUMP-07", "class": "centrifugal", "seq": 19, "vib": 2.25, "temp_c": 58.4, "state": "-0.0500,-0.0500,-0.1600,0.0750"},
--   {"id": 212, "asset": "PUMP-07", "class": "centrifugal", "seq": 20, "vib": 2.3, "temp_c": 58.8, "state": "0.0000,0.0000,-0.1200,0.1000"},
--   {"id": 213, "asset": "PUMP-07", "class": "centrifugal", "seq": 21, "vib": 2.35, "temp_c": 59.2, "state": "0.0500,0.0500,-0.0800,0.1250"},
--   {"id": 214, "asset": "PUMP-07", "class": "centrifugal", "seq": 22, "vib": 2.4, "temp_c": 59.6, "state": "0.1000,0.1000,-0.0400,0.1500"},
--   {"id": 215, "asset": "PUMP-07", "class": "centrifugal", "seq": 23, "vib": 2.45, "temp_c": 60.0, "state": "0.1500,0.1500,0.0000,0.1750"},
--   {"id": 216, "asset": "PUMP-07", "class": "centrifugal", "seq": 24, "vib": 2.1, "temp_c": 58.0, "state": "-0.2000,-0.2000,-0.2000,0.0000"},
--   {"id": 217, "asset": "PUMP-07", "class": "centrifugal", "seq": 25, "vib": 2.15, "temp_c": 58.4, "state": "-0.1500,-0.1500,-0.1600,0.0250"},
--   {"id": 218, "asset": "PUMP-07", "class": "centrifugal", "seq": 26, "vib": 2.2, "temp_c": 58.8, "state": "-0.1000,-0.1000,-0.1200,0.0500"},
--   {"id": 219, "asset": "PUMP-07", "class": "centrifugal", "seq": 27, "vib": 2.25, "temp_c": 59.2, "state": "-0.0500,-0.0500,-0.0800,0.0750"},
--   {"id": 220, "asset": "PUMP-07", "class": "centrifugal", "seq": 28, "vib": 2.3, "temp_c": 59.6, "state": "0.0000,0.0000,-0.0400,0.1000"},
--   {"id": 221, "asset": "PUMP-07", "class": "centrifugal", "seq": 29, "vib": 2.35, "temp_c": 60.0, "state": "0.0500,0.0500,0.0000,0.1250"},
--   {"id": 222, "asset": "PUMP-07", "class": "centrifugal", "seq": 30, "vib": 2.4, "temp_c": 58.0, "state": "0.1000,0.1000,-0.2000,0.1500"},
--   {"id": 223, "asset": "PUMP-07", "class": "centrifugal", "seq": 31, "vib": 2.45, "temp_c": 58.4, "state": "0.1500,0.1500,-0.1600,0.1750"},
--   {"id": 224, "asset": "PUMP-07", "class": "centrifugal", "seq": 32, "vib": 2.1, "temp_c": 58.8, "state": "-0.2000,-0.2000,-0.1200,0.0000"},
--   {"id": 225, "asset": "PUMP-07", "class": "centrifugal", "seq": 33, "vib": 2.15, "temp_c": 59.2, "state": "-0.1500,-0.1500,-0.0800,0.0250"},
--   {"id": 226, "asset": "PUMP-07", "class": "centrifugal", "seq": 34, "vib": 2.2, "temp_c": 59.6, "state": "-0.1000,-0.1000,-0.0400,0.0500"},
--   {"id": 227, "asset": "PUMP-07", "class": "centrifugal", "seq": 35, "vib": 2.25, "temp_c": 60.0, "state": "-0.0500,-0.0500,0.0000,0.0750"},
--   {"id": 228, "asset": "PUMP-07", "class": "centrifugal", "seq": 36, "vib": 2.3, "temp_c": 58.0, "state": "0.0000,0.0000,-0.2000,0.1000"},
--   {"id": 229, "asset": "PUMP-07", "class": "centrifugal", "seq": 37, "vib": 2.35, "temp_c": 58.4, "state": "0.0500,0.0500,-0.1600,0.1250"},
--   {"id": 230, "asset": "PUMP-07", "class": "centrifugal", "seq": 38, "vib": 2.4, "temp_c": 58.8, "state": "0.1000,0.1000,-0.1200,0.1500"},
--   {"id": 231, "asset": "PUMP-07", "class": "centrifugal", "seq": 39, "vib": 2.45, "temp_c": 59.2, "state": "0.1500,0.1500,-0.0800,0.1750"},
--   {"id": 232, "asset": "PUMP-07", "class": "centrifugal", "seq": 40, "vib": 2.1, "temp_c": 59.6, "state": "-0.2000,-0.2000,-0.0400,0.0000"},
--   {"id": 233, "asset": "PUMP-07", "class": "centrifugal", "seq": 41, "vib": 2.15, "temp_c": 60.0, "state": "-0.1500,-0.1500,0.0000,0.0250"},
--   {"id": 234, "asset": "PUMP-07", "class": "centrifugal", "seq": 42, "vib": 2.2, "temp_c": 58.0, "state": "-0.1000,-0.1000,-0.2000,0.0500"},
--   {"id": 235, "asset": "PUMP-07", "class": "centrifugal", "seq": 43, "vib": 2.25, "temp_c": 58.4, "state": "-0.0500,-0.0500,-0.1600,0.0750"},
--   {"id": 236, "asset": "PUMP-07", "class": "centrifugal", "seq": 44, "vib": 2.3, "temp_c": 58.8, "state": "0.0000,0.0000,-0.1200,0.1000"},
--   {"id": 237, "asset": "PUMP-07", "class": "centrifugal", "seq": 45, "vib": 2.35, "temp_c": 59.2, "state": "0.0500,0.0500,-0.0800,0.1250"},
--   {"id": 238, "asset": "PUMP-07", "class": "centrifugal", "seq": 46, "vib": 2.4, "temp_c": 59.6, "state": "0.1000,0.1000,-0.0400,0.1500"},
--   {"id": 239, "asset": "PUMP-07", "class": "centrifugal", "seq": 47, "vib": 2.45, "temp_c": 60.0, "state": "0.1500,0.1500,0.0000,0.1750"},
--   {"id": 240, "asset": "PUMP-07", "class": "centrifugal", "seq": 48, "vib": 2.1, "temp_c": 58.0, "state": "-0.2000,-0.2000,-0.2000,0.0000"},
--   {"id": 241, "asset": "PUMP-07", "class": "centrifugal", "seq": 49, "vib": 2.15, "temp_c": 58.4, "state": "-0.1500,-0.1500,-0.1600,0.0250"},
--   {"id": 242, "asset": "PUMP-07", "class": "centrifugal", "seq": 50, "vib": 2.2, "temp_c": 58.8, "state": "-0.1000,-0.1000,-0.1200,0.0500"},
--   {"id": 243, "asset": "PUMP-07", "class": "centrifugal", "seq": 51, "vib": 2.25, "temp_c": 59.2, "state": "-0.0500,-0.0500,-0.0800,0.0750"},
--   {"id": 244, "asset": "PUMP-07", "class": "centrifugal", "seq": 52, "vib": 2.3, "temp_c": 59.6, "state": "0.0000,0.0000,-0.0400,0.1000"},
--   {"id": 245, "asset": "PUMP-07", "class": "centrifugal", "seq": 53, "vib": 2.35, "temp_c": 60.0, "state": "0.0500,0.0500,0.0000,0.1250"},
--   {"id": 246, "asset": "PUMP-07", "class": "centrifugal", "seq": 54, "vib": 2.4, "temp_c": 58.0, "state": "0.1000,0.1000,-0.2000,0.1500"},
--   {"id": 247, "asset": "PUMP-07", "class": "centrifugal", "seq": 55, "vib": 2.45, "temp_c": 58.4, "state": "0.1500,0.1500,-0.1600,0.1750"},
--   {"id": 248, "asset": "PUMP-07", "class": "centrifugal", "seq": 56, "vib": 2.1, "temp_c": 58.8, "state": "-0.2000,-0.2000,-0.1200,0.0000"},
--   {"id": 249, "asset": "PUMP-07", "class": "centrifugal", "seq": 57, "vib": 2.15, "temp_c": 59.2, "state": "-0.1500,-0.1500,-0.0800,0.0250"},
--   {"id": 250, "asset": "PUMP-07", "class": "centrifugal", "seq": 58, "vib": 2.2, "temp_c": 59.6, "state": "-0.1000,-0.1000,-0.0400,0.0500"},
--   {"id": 251, "asset": "PUMP-07", "class": "centrifugal", "seq": 59, "vib": 2.25, "temp_c": 60.0, "state": "-0.0500,-0.0500,0.0000,0.0750"},
--   {"id": 252, "asset": "PUMP-07", "class": "centrifugal", "seq": 60, "vib": 2.3, "temp_c": 58.0, "state": "0.0000,0.0000,-0.2000,0.1000"},
--   {"id": 253, "asset": "PUMP-07", "class": "centrifugal", "seq": 61, "vib": 2.35, "temp_c": 58.4, "state": "0.0500,0.0500,-0.1600,0.1250"},
--   {"id": 254, "asset": "PUMP-07", "class": "centrifugal", "seq": 62, "vib": 2.4, "temp_c": 58.8, "state": "0.1000,0.1000,-0.1200,0.1500"},
--   {"id": 255, "asset": "PUMP-07", "class": "centrifugal", "seq": 63, "vib": 2.45, "temp_c": 59.2, "state": "0.1500,0.1500,-0.0800,0.1750"},
--   {"id": 256, "asset": "PUMP-07", "class": "centrifugal", "seq": 64, "vib": 2.1, "temp_c": 59.6, "state": "-0.2000,-0.2000,-0.0400,0.0000"},
--   {"id": 257, "asset": "PUMP-07", "class": "centrifugal", "seq": 65, "vib": 2.154, "temp_c": 60.35, "state": "-0.1460,-0.0700,0.0350,0.0270"},
--   {"id": 258, "asset": "PUMP-07", "class": "centrifugal", "seq": 66, "vib": 2.216, "temp_c": 58.7, "state": "-0.0840,0.0600,-0.1300,0.0580"},
--   {"id": 259, "asset": "PUMP-07", "class": "centrifugal", "seq": 67, "vib": 2.286, "temp_c": 59.45, "state": "-0.0140,0.1900,-0.0550,0.0930"},
--   {"id": 260, "asset": "PUMP-07", "class": "centrifugal", "seq": 68, "vib": 2.364, "temp_c": 60.2, "state": "0.0640,0.3200,0.0200,0.1320"},
--   {"id": 261, "asset": "PUMP-07", "class": "centrifugal", "seq": 69, "vib": 2.45, "temp_c": 60.95, "state": "0.1500,0.4500,0.0950,0.1750"},
--   {"id": 262, "asset": "PUMP-07", "class": "centrifugal", "seq": 70, "vib": 2.544, "temp_c": 61.7, "state": "0.2440,0.5800,0.1700,0.2220"},
--   {"id": 263, "asset": "PUMP-07", "class": "centrifugal", "seq": 71, "vib": 2.646, "temp_c": 62.45, "state": "0.3460,0.7100,0.2450,0.2730"},
--   {"id": 264, "asset": "PUMP-07", "class": "centrifugal", "seq": 72, "vib": 2.356, "temp_c": 60.8, "state": "0.0560,0.4400,0.0800,0.1280"},
--   {"id": 265, "asset": "PUMP-07", "class": "centrifugal", "seq": 73, "vib": 2.474, "temp_c": 61.55, "state": "0.1740,0.5700,0.1550,0.1870"},
--   {"id": 266, "asset": "PUMP-07", "class": "centrifugal", "seq": 74, "vib": 2.6, "temp_c": 62.3, "state": "0.3000,0.7000,0.2300,0.2500"},
--   {"id": 267, "asset": "PUMP-07", "class": "centrifugal", "seq": 75, "vib": 2.734, "temp_c": 63.05, "state": "0.4340,0.8300,0.3050,0.3170"},
--   {"id": 268, "asset": "PUMP-07", "class": "centrifugal", "seq": 76, "vib": 2.876, "temp_c": 63.8, "state": "0.5760,0.9600,0.3800,0.3880"},
--   {"id": 269, "asset": "PUMP-07", "class": "centrifugal", "seq": 77, "vib": 3.026, "temp_c": 64.55, "state": "0.7260,1.0900,0.4550,0.4630"},
--   {"id": 270, "asset": "PUMP-07", "class": "centrifugal", "seq": 78, "vib": 3.184, "temp_c": 62.9, "state": "0.8840,1.2200,0.2900,0.5420"},
--   {"id": 271, "asset": "PUMP-07", "class": "centrifugal", "seq": 79, "vib": 3.35, "temp_c": 63.65, "state": "1.0500,1.3500,0.3650,0.6250"},
--   {"id": 272, "asset": "PUMP-07", "class": "centrifugal", "seq": 80, "vib": 3.124, "temp_c": 64.4, "state": "0.8240,1.0800,0.4400,0.5120"},
--   {"id": 273, "asset": "PUMP-07", "class": "centrifugal", "seq": 81, "vib": 3.306, "temp_c": 65.15, "state": "1.0060,1.2100,0.5150,0.6030"},
--   {"id": 274, "asset": "PUMP-07", "class": "centrifugal", "seq": 82, "vib": 3.496, "temp_c": 65.9, "state": "1.1960,1.3400,0.5900,0.6980"},
--   {"id": 275, "asset": "PUMP-07", "class": "centrifugal", "seq": 83, "vib": 3.694, "temp_c": 66.65, "state": "1.3940,1.4700,0.6650,0.7970"},
--   {"id": 276, "asset": "PUMP-07", "class": "centrifugal", "seq": 84, "vib": 3.9, "temp_c": 65.0, "state": "1.6000,1.6000,0.5000,0.9000"},
--   {"id": 277, "asset": "PUMP-07", "class": "centrifugal", "seq": 85, "vib": 4.114, "temp_c": 65.75, "state": "1.8140,1.7300,0.5750,1.0070"},
--   {"id": 278, "asset": "PUMP-07", "class": "centrifugal", "seq": 86, "vib": 4.336, "temp_c": 66.5, "state": "2.0360,1.8600,0.6500,1.1180"},
--   {"id": 279, "asset": "PUMP-07", "class": "centrifugal", "seq": 87, "vib": 4.566, "temp_c": 67.25, "state": "2.2660,1.9900,0.7250,1.2330"},
--   {"id": 280, "asset": "PUMP-07", "class": "centrifugal", "seq": 88, "vib": 4.404, "temp_c": 68.0, "state": "2.1040,1.7200,0.8000,1.1520"},
--   {"id": 281, "asset": "PUMP-07", "class": "centrifugal", "seq": 89, "vib": 4.65, "temp_c": 68.75, "state": "2.3500,1.8500,0.8750,1.2750"},
--   {"id": 282, "asset": "PUMP-07", "class": "centrifugal", "seq": 90, "vib": 4.904, "temp_c": 67.1, "state": "2.6040,1.9800,0.7100,1.4020"},
--   {"id": 283, "asset": "PUMP-07", "class": "centrifugal", "seq": 91, "vib": 5.166, "temp_c": 67.85, "state": "2.8660,2.1100,0.7850,1.5330"},
--   {"id": 284, "asset": "PUMP-07", "class": "centrifugal", "seq": 92, "vib": 5.436, "temp_c": 68.6, "state": "3.1360,2.2400,0.8600,1.6680"},
--   {"id": 285, "asset": "PUMP-07", "class": "centrifugal", "seq": 93, "vib": 5.714, "temp_c": 69.35, "state": "3.4140,2.3700,0.9350,1.8070"},
--   {"id": 286, "asset": "PUMP-07", "class": "centrifugal", "seq": 94, "vib": 6.0, "temp_c": 70.1, "state": "3.7000,2.5000,1.0100,1.9500"},
--   {"id": 287, "asset": "PUMP-07", "class": "centrifugal", "seq": 95, "vib": 6.294, "temp_c": 70.85, "state": "3.9940,2.6300,1.0850,2.0970"},
--   {"id": 288, "asset": "PUMP-07", "class": "centrifugal", "seq": 96, "vib": 6.196, "temp_c": 69.2, "state": "3.8960,2.3600,0.9200,2.0480"},
--   {"id": 289, "asset": "DRIVE-12", "class": "gearbox", "seq": 1, "vib": 2.15, "temp_c": 58.4, "state": "-0.1500,-0.1500,-0.1600,0.0250"},
--   {"id": 290, "asset": "DRIVE-12", "class": "gearbox", "seq": 2, "vib": 2.2, "temp_c": 58.8, "state": "-0.1000,-0.1000,-0.1200,0.0500"},
--   {"id": 291, "asset": "DRIVE-12", "class": "gearbox", "seq": 3, "vib": 2.25, "temp_c": 59.2, "state": "-0.0500,-0.0500,-0.0800,0.0750"},
--   {"id": 292, "asset": "DRIVE-12", "class": "gearbox", "seq": 4, "vib": 2.3, "temp_c": 59.6, "state": "0.0000,0.0000,-0.0400,0.1000"},
--   {"id": 293, "asset": "DRIVE-12", "class": "gearbox", "seq": 5, "vib": 2.35, "temp_c": 60.0, "state": "0.0500,0.0500,0.0000,0.1250"},
--   {"id": 294, "asset": "DRIVE-12", "class": "gearbox", "seq": 6, "vib": 2.4, "temp_c": 58.0, "state": "0.1000,0.1000,-0.2000,0.1500"},
--   {"id": 295, "asset": "DRIVE-12", "class": "gearbox", "seq": 7, "vib": 2.45, "temp_c": 58.4, "state": "0.1500,0.1500,-0.1600,0.1750"},
--   {"id": 296, "asset": "DRIVE-12", "class": "gearbox", "seq": 8, "vib": 2.1, "temp_c": 58.8, "state": "-0.2000,-0.2000,-0.1200,0.0000"},
--   {"id": 297, "asset": "DRIVE-12", "class": "gearbox", "seq": 9, "vib": 2.15, "temp_c": 59.2, "state": "-0.1500,-0.1500,-0.0800,0.0250"},
--   {"id": 298, "asset": "DRIVE-12", "class": "gearbox", "seq": 10, "vib": 2.2, "temp_c": 59.6, "state": "-0.1000,-0.1000,-0.0400,0.0500"},
--   {"id": 299, "asset": "DRIVE-12", "class": "gearbox", "seq": 11, "vib": 2.25, "temp_c": 60.0, "state": "-0.0500,-0.0500,0.0000,0.0750"},
--   {"id": 300, "asset": "DRIVE-12", "class": "gearbox", "seq": 12, "vib": 2.3, "temp_c": 58.0, "state": "0.0000,0.0000,-0.2000,0.1000"},
--   {"id": 301, "asset": "DRIVE-12", "class": "gearbox", "seq": 13, "vib": 2.35, "temp_c": 58.4, "state": "0.0500,0.0500,-0.1600,0.1250"},
--   {"id": 302, "asset": "DRIVE-12", "class": "gearbox", "seq": 14, "vib": 2.4, "temp_c": 58.8, "state": "0.1000,0.1000,-0.1200,0.1500"},
--   {"id": 303, "asset": "DRIVE-12", "class": "gearbox", "seq": 15, "vib": 2.45, "temp_c": 59.2, "state": "0.1500,0.1500,-0.0800,0.1750"},
--   {"id": 304, "asset": "DRIVE-12", "class": "gearbox", "seq": 16, "vib": 2.1, "temp_c": 59.6, "state": "-0.2000,-0.2000,-0.0400,0.0000"},
--   {"id": 305, "asset": "DRIVE-12", "class": "gearbox", "seq": 17, "vib": 2.15, "temp_c": 60.0, "state": "-0.1500,-0.1500,0.0000,0.0250"},
--   {"id": 306, "asset": "DRIVE-12", "class": "gearbox", "seq": 18, "vib": 2.2, "temp_c": 58.0, "state": "-0.1000,-0.1000,-0.2000,0.0500"},
--   {"id": 307, "asset": "DRIVE-12", "class": "gearbox", "seq": 19, "vib": 2.25, "temp_c": 58.4, "state": "-0.0500,-0.0500,-0.1600,0.0750"},
--   {"id": 308, "asset": "DRIVE-12", "class": "gearbox", "seq": 20, "vib": 2.3, "temp_c": 58.8, "state": "0.0000,0.0000,-0.1200,0.1000"},
--   {"id": 309, "asset": "DRIVE-12", "class": "gearbox", "seq": 21, "vib": 2.35, "temp_c": 59.2, "state": "0.0500,0.0500,-0.0800,0.1250"},
--   {"id": 310, "asset": "DRIVE-12", "class": "gearbox", "seq": 22, "vib": 2.4, "temp_c": 59.6, "state": "0.1000,0.1000,-0.0400,0.1500"},
--   {"id": 311, "asset": "DRIVE-12", "class": "gearbox", "seq": 23, "vib": 2.45, "temp_c": 60.0, "state": "0.1500,0.1500,0.0000,0.1750"},
--   {"id": 312, "asset": "DRIVE-12", "class": "gearbox", "seq": 24, "vib": 2.1, "temp_c": 58.0, "state": "-0.2000,-0.2000,-0.2000,0.0000"},
--   {"id": 313, "asset": "DRIVE-12", "class": "gearbox", "seq": 25, "vib": 2.15, "temp_c": 58.4, "state": "-0.1500,-0.1500,-0.1600,0.0250"},
--   {"id": 314, "asset": "DRIVE-12", "class": "gearbox", "seq": 26, "vib": 2.2, "temp_c": 58.8, "state": "-0.1000,-0.1000,-0.1200,0.0500"},
--   {"id": 315, "asset": "DRIVE-12", "class": "gearbox", "seq": 27, "vib": 2.25, "temp_c": 59.2, "state": "-0.0500,-0.0500,-0.0800,0.0750"},
--   {"id": 316, "asset": "DRIVE-12", "class": "gearbox", "seq": 28, "vib": 2.3, "temp_c": 59.6, "state": "0.0000,0.0000,-0.0400,0.1000"},
--   {"id": 317, "asset": "DRIVE-12", "class": "gearbox", "seq": 29, "vib": 2.35, "temp_c": 60.0, "state": "0.0500,0.0500,0.0000,0.1250"},
--   {"id": 318, "asset": "DRIVE-12", "class": "gearbox", "seq": 30, "vib": 2.4, "temp_c": 58.0, "state": "0.1000,0.1000,-0.2000,0.1500"},
--   {"id": 319, "asset": "DRIVE-12", "class": "gearbox", "seq": 31, "vib": 2.45, "temp_c": 58.4, "state": "0.1500,0.1500,-0.1600,0.1750"},
--   {"id": 320, "asset": "DRIVE-12", "class": "gearbox", "seq": 32, "vib": 2.1, "temp_c": 58.8, "state": "-0.2000,-0.2000,-0.1200,0.0000"},
--   {"id": 321, "asset": "DRIVE-12", "class": "gearbox", "seq": 33, "vib": 2.15, "temp_c": 59.2, "state": "-0.1500,-0.1500,-0.0800,0.0250"},
--   {"id": 322, "asset": "DRIVE-12", "class": "gearbox", "seq": 34, "vib": 2.2, "temp_c": 59.6, "state": "-0.1000,-0.1000,-0.0400,0.0500"},
--   {"id": 323, "asset": "DRIVE-12", "class": "gearbox", "seq": 35, "vib": 2.25, "temp_c": 60.0, "state": "-0.0500,-0.0500,0.0000,0.0750"},
--   {"id": 324, "asset": "DRIVE-12", "class": "gearbox", "seq": 36, "vib": 2.3, "temp_c": 58.0, "state": "0.0000,0.0000,-0.2000,0.1000"},
--   {"id": 325, "asset": "DRIVE-12", "class": "gearbox", "seq": 37, "vib": 2.35, "temp_c": 58.4, "state": "0.0500,0.0500,-0.1600,0.1250"},
--   {"id": 326, "asset": "DRIVE-12", "class": "gearbox", "seq": 38, "vib": 2.4, "temp_c": 58.8, "state": "0.1000,0.1000,-0.1200,0.1500"},
--   {"id": 327, "asset": "DRIVE-12", "class": "gearbox", "seq": 39, "vib": 2.45, "temp_c": 59.2, "state": "0.1500,0.1500,-0.0800,0.1750"},
--   {"id": 328, "asset": "DRIVE-12", "class": "gearbox", "seq": 40, "vib": 2.1, "temp_c": 59.6, "state": "-0.2000,-0.2000,-0.0400,0.0000"},
--   {"id": 329, "asset": "DRIVE-12", "class": "gearbox", "seq": 41, "vib": 2.15, "temp_c": 60.0, "state": "-0.1500,-0.1500,0.0000,0.0250"},
--   {"id": 330, "asset": "DRIVE-12", "class": "gearbox", "seq": 42, "vib": 2.2, "temp_c": 58.0, "state": "-0.1000,-0.1000,-0.2000,0.0500"},
--   {"id": 331, "asset": "DRIVE-12", "class": "gearbox", "seq": 43, "vib": 2.25, "temp_c": 58.4, "state": "-0.0500,-0.0500,-0.1600,0.0750"},
--   {"id": 332, "asset": "DRIVE-12", "class": "gearbox", "seq": 44, "vib": 2.3, "temp_c": 58.8, "state": "0.0000,0.0000,-0.1200,0.1000"},
--   {"id": 333, "asset": "DRIVE-12", "class": "gearbox", "seq": 45, "vib": 2.35, "temp_c": 59.2, "state": "0.0500,0.0500,-0.0800,0.1250"},
--   {"id": 334, "asset": "DRIVE-12", "class": "gearbox", "seq": 46, "vib": 2.4, "temp_c": 59.6, "state": "0.1000,0.1000,-0.0400,0.1500"},
--   {"id": 335, "asset": "DRIVE-12", "class": "gearbox", "seq": 47, "vib": 2.45, "temp_c": 60.0, "state": "0.1500,0.1500,0.0000,0.1750"},
--   {"id": 336, "asset": "DRIVE-12", "class": "gearbox", "seq": 48, "vib": 2.1, "temp_c": 58.0, "state": "-0.2000,-0.2000,-0.2000,0.0000"},
--   {"id": 337, "asset": "DRIVE-12", "class": "gearbox", "seq": 49, "vib": 2.15, "temp_c": 58.4, "state": "-0.1500,-0.1500,-0.1600,0.0250"},
--   {"id": 338, "asset": "DRIVE-12", "class": "gearbox", "seq": 50, "vib": 2.2, "temp_c": 58.8, "state": "-0.1000,-0.1000,-0.1200,0.0500"},
--   {"id": 339, "asset": "DRIVE-12", "class": "gearbox", "seq": 51, "vib": 2.25, "temp_c": 59.2, "state": "-0.0500,-0.0500,-0.0800,0.0750"},
--   {"id": 340, "asset": "DRIVE-12", "class": "gearbox", "seq": 52, "vib": 2.3, "temp_c": 59.6, "state": "0.0000,0.0000,-0.0400,0.1000"},
--   {"id": 341, "asset": "DRIVE-12", "class": "gearbox", "seq": 53, "vib": 2.35, "temp_c": 60.0, "state": "0.0500,0.0500,0.0000,0.1250"},
--   {"id": 342, "asset": "DRIVE-12", "class": "gearbox", "seq": 54, "vib": 2.4, "temp_c": 58.0, "state": "0.1000,0.1000,-0.2000,0.1500"},
--   {"id": 343, "asset": "DRIVE-12", "class": "gearbox", "seq": 55, "vib": 2.45, "temp_c": 58.4, "state": "0.1500,0.1500,-0.1600,0.1750"},
--   {"id": 344, "asset": "DRIVE-12", "class": "gearbox", "seq": 56, "vib": 2.1, "temp_c": 58.8, "state": "-0.2000,-0.2000,-0.1200,0.0000"},
--   {"id": 345, "asset": "DRIVE-12", "class": "gearbox", "seq": 57, "vib": 2.15, "temp_c": 59.2, "state": "-0.1500,-0.1500,-0.0800,0.0250"},
--   {"id": 346, "asset": "DRIVE-12", "class": "gearbox", "seq": 58, "vib": 2.2, "temp_c": 59.6, "state": "-0.1000,-0.1000,-0.0400,0.0500"},
--   {"id": 347, "asset": "DRIVE-12", "class": "gearbox", "seq": 59, "vib": 2.25, "temp_c": 60.0, "state": "-0.0500,-0.0500,0.0000,0.0750"},
--   {"id": 348, "asset": "DRIVE-12", "class": "gearbox", "seq": 60, "vib": 2.3, "temp_c": 58.0, "state": "0.0000,0.0000,-0.2000,0.1000"},
--   {"id": 349, "asset": "DRIVE-12", "class": "gearbox", "seq": 61, "vib": 2.35, "temp_c": 58.4, "state": "0.0500,0.0500,-0.1600,0.1250"},
--   {"id": 350, "asset": "DRIVE-12", "class": "gearbox", "seq": 62, "vib": 2.4, "temp_c": 58.8, "state": "0.1000,0.1000,-0.1200,0.1500"},
--   {"id": 351, "asset": "DRIVE-12", "class": "gearbox", "seq": 63, "vib": 2.45, "temp_c": 59.2, "state": "0.1500,0.1500,-0.0800,0.1750"},
--   {"id": 352, "asset": "DRIVE-12", "class": "gearbox", "seq": 64, "vib": 2.1, "temp_c": 59.6, "state": "-0.2000,-0.2000,-0.0400,0.0000"},
--   {"id": 353, "asset": "DRIVE-12", "class": "gearbox", "seq": 65, "vib": 2.15, "temp_c": 60.0, "state": "-0.1500,-0.1500,0.0000,0.0250"},
--   {"id": 354, "asset": "DRIVE-12", "class": "gearbox", "seq": 66, "vib": 2.2, "temp_c": 58.0, "state": "-0.1000,-0.1000,-0.2000,0.0500"},
--   {"id": 355, "asset": "DRIVE-12", "class": "gearbox", "seq": 67, "vib": 2.25, "temp_c": 58.4, "state": "-0.0500,-0.0500,-0.1600,0.0750"},
--   {"id": 356, "asset": "DRIVE-12", "class": "gearbox", "seq": 68, "vib": 2.3, "temp_c": 58.8, "state": "0.0000,0.0000,-0.1200,0.1000"},
--   {"id": 357, "asset": "DRIVE-12", "class": "gearbox", "seq": 69, "vib": 2.35, "temp_c": 59.2, "state": "0.0500,0.0500,-0.0800,0.1250"},
--   {"id": 358, "asset": "DRIVE-12", "class": "gearbox", "seq": 70, "vib": 2.4, "temp_c": 59.6, "state": "0.1000,0.1000,-0.0400,0.1500"},
--   {"id": 359, "asset": "DRIVE-12", "class": "gearbox", "seq": 71, "vib": 2.45, "temp_c": 60.0, "state": "0.1500,0.1500,0.0000,0.1750"},
--   {"id": 360, "asset": "DRIVE-12", "class": "gearbox", "seq": 72, "vib": 2.1, "temp_c": 58.0, "state": "-0.2000,-0.2000,-0.2000,0.0000"},
--   {"id": 361, "asset": "DRIVE-12", "class": "gearbox", "seq": 73, "vib": 2.15, "temp_c": 58.4, "state": "-0.1500,-0.1500,-0.1600,0.0250"},
--   {"id": 362, "asset": "DRIVE-12", "class": "gearbox", "seq": 74, "vib": 2.2, "temp_c": 58.8, "state": "-0.1000,-0.1000,-0.1200,0.0500"},
--   {"id": 363, "asset": "DRIVE-12", "class": "gearbox", "seq": 75, "vib": 2.25, "temp_c": 59.2, "state": "-0.0500,-0.0500,-0.0800,0.0750"},
--   {"id": 364, "asset": "DRIVE-12", "class": "gearbox", "seq": 76, "vib": 2.3, "temp_c": 59.6, "state": "0.0000,0.0000,-0.0400,0.1000"},
--   {"id": 365, "asset": "DRIVE-12", "class": "gearbox", "seq": 77, "vib": 2.35, "temp_c": 60.0, "state": "0.0500,0.0500,0.0000,0.1250"},
--   {"id": 366, "asset": "DRIVE-12", "class": "gearbox", "seq": 78, "vib": 2.4, "temp_c": 58.0, "state": "0.1000,0.1000,-0.2000,0.1500"},
--   {"id": 367, "asset": "DRIVE-12", "class": "gearbox", "seq": 79, "vib": 2.45, "temp_c": 58.4, "state": "0.1500,0.1500,-0.1600,0.1750"},
--   {"id": 368, "asset": "DRIVE-12", "class": "gearbox", "seq": 80, "vib": 2.1, "temp_c": 58.8, "state": "-0.2000,-0.2000,-0.1200,0.0000"},
--   {"id": 369, "asset": "DRIVE-12", "class": "gearbox", "seq": 81, "vib": 2.15, "temp_c": 59.2, "state": "-0.1500,-0.1500,-0.0800,0.0250"},
--   {"id": 370, "asset": "DRIVE-12", "class": "gearbox", "seq": 82, "vib": 2.2, "temp_c": 59.6, "state": "-0.1000,-0.1000,-0.0400,0.0500"},
--   {"id": 371, "asset": "DRIVE-12", "class": "gearbox", "seq": 83, "vib": 2.25, "temp_c": 60.0, "state": "-0.0500,-0.0500,0.0000,0.0750"},
--   {"id": 372, "asset": "DRIVE-12", "class": "gearbox", "seq": 84, "vib": 2.3, "temp_c": 58.0, "state": "0.0000,0.0000,-0.2000,0.1000"},
--   {"id": 373, "asset": "DRIVE-12", "class": "gearbox", "seq": 85, "vib": 2.35, "temp_c": 58.4, "state": "0.0500,0.0500,-0.1600,0.1250"},
--   {"id": 374, "asset": "DRIVE-12", "class": "gearbox", "seq": 86, "vib": 2.4, "temp_c": 58.8, "state": "0.1000,0.1000,-0.1200,0.1500"},
--   {"id": 375, "asset": "DRIVE-12", "class": "gearbox", "seq": 87, "vib": 2.45, "temp_c": 59.2, "state": "0.1500,0.1500,-0.0800,0.1750"},
--   {"id": 376, "asset": "DRIVE-12", "class": "gearbox", "seq": 88, "vib": 2.1, "temp_c": 59.6, "state": "-0.2000,-0.2000,-0.0400,0.0000"},
--   {"id": 377, "asset": "DRIVE-12", "class": "gearbox", "seq": 89, "vib": 2.15, "temp_c": 60.0, "state": "-0.1500,-0.1500,0.0000,0.0250"},
--   {"id": 378, "asset": "DRIVE-12", "class": "gearbox", "seq": 90, "vib": 2.2, "temp_c": 58.0, "state": "-0.1000,-0.1000,-0.2000,0.0500"},
--   {"id": 379, "asset": "DRIVE-12", "class": "gearbox", "seq": 91, "vib": 2.25, "temp_c": 58.4, "state": "-0.0500,-0.0500,-0.1600,0.0750"},
--   {"id": 380, "asset": "DRIVE-12", "class": "gearbox", "seq": 92, "vib": 2.3, "temp_c": 58.8, "state": "0.0000,0.0000,-0.1200,0.1000"},
--   {"id": 381, "asset": "DRIVE-12", "class": "gearbox", "seq": 93, "vib": 2.35, "temp_c": 59.2, "state": "0.0500,0.0500,-0.0800,0.1250"},
--   {"id": 382, "asset": "DRIVE-12", "class": "gearbox", "seq": 94, "vib": 2.4, "temp_c": 59.6, "state": "0.1000,0.1000,-0.0400,0.1500"},
--   {"id": 383, "asset": "DRIVE-12", "class": "gearbox", "seq": 95, "vib": 2.45, "temp_c": 60.0, "state": "0.1500,0.1500,0.0000,0.1750"},
--   {"id": 384, "asset": "DRIVE-12", "class": "gearbox", "seq": 96, "vib": 2.1, "temp_c": 58.0, "state": "-0.2000,-0.2000,-0.2000,0.0000"}
-- ]};

SELECT "asset", "class", COUNT(*) AS "readings",
       ROUND(MAX("vib"), 2) AS "max_vib_mm_s",
       ROUND(MAX("temp_c"), 1) AS "max_bearing_temp_c"
FROM "hpm_readings" GROUP BY "asset", "class" ORDER BY "asset";

-- ---------------------------------------------------------------------------
-- 2. Step 1, hand-composed: the vibration-regime drift per asset.
--
-- The healthy assets sit near zero; PUMP-07's accelerating ramp pushes
-- its recent-window exponent away from its baseline.
-- ---------------------------------------------------------------------------
REPLACE INTO hpm_drift OVERWRITE ALL
SELECT "asset",
       fractal_dimension_drift(
           ARRAY_TO_STRING(ARRAY_AGG(CAST("vib" AS VARCHAR), 16384), ','), 32) AS "dj"
FROM "hpm_readings"
GROUP BY "asset"
PARTITIONED BY ALL;

SELECT "asset",
       ROUND(fractal_json_value("dj", '$.drift'), 4) AS "drift",
       ROUND(fractal_json_value("dj", '$.recent_alpha'), 4) AS "recent_alpha",
       ROUND(fractal_json_value("dj", '$.baseline_alpha'), 4) AS "baseline_alpha"
FROM "hpm_drift" GROUP BY "asset", "dj" ORDER BY "asset";

-- The shipped agent: the same composition, one call.
-- @call agent/anomaly_triage {"log_table": "hpm_readings", "metric_col": "vib",
--                            "time_col": "seq", "filter_col": "asset",
--                            "filter_val": "PUMP-07", "baseline_window": 32};

-- ---------------------------------------------------------------------------
-- 3. Step 2, hand-composed: PUMP-07's intake baseline vs. its latest
-- state. The nearest fleet readings show where in the fleet's history
-- the pump now sits.
-- ---------------------------------------------------------------------------
REPLACE INTO hpm_pump07 OVERWRITE ALL
SELECT (SELECT "state" FROM "hpm_readings" WHERE "asset" = 'PUMP-07' AND "seq" = 1) AS "baseline",
       (SELECT "state" FROM "hpm_readings" WHERE "asset" = 'PUMP-07' AND "seq" = 96) AS "current"
PARTITIONED BY ALL;

-- @call search/trajectory {"table": "hpm_readings", "column": "state", "id_column": "id",
--                         "baseline_table": "hpm_pump07", "baseline_column": "baseline",
--                         "current_table": "hpm_pump07", "current_column": "current",
--                         "k": 5} AS hpm_traj;

SELECT h."asset" AS "asset", h."seq" AS "seq", ROUND(r."distance", 4) AS "distance"
FROM "hpm_traj" r, "hpm_readings" h
WHERE r."doc_id" = h."id";

-- The cohort the triage looks within: the same-class (centrifugal)
-- assets.
REPLACE INTO hpm_cohort OVERWRITE ALL
SELECT ARRAY_TO_STRING(ARRAY_AGG(CAST("id" AS VARCHAR), 8192), ',') AS "ids"
FROM "hpm_readings" WHERE "class" = 'centrifugal'
PARTITIONED BY ALL;

-- The shipped agent: the same composition, one call.
-- @call agent/patient_deterioration_triage {"patient_table": "hpm_readings",
--                                           "vec_col": "state",
--                                           "id_column": "id",
--                                           "query_vec_table": "hpm_pump07",
--                                           "query_vec_column": "current",
--                                           "baseline_vec_table": "hpm_pump07",
--                                           "baseline_vec_column": "baseline",
--                                           "current_vec_table": "hpm_pump07",
--                                           "current_vec_column": "current",
--                                           "cohort_doc_ids_table": "hpm_cohort",
--                                           "cohort_doc_ids_column": "ids",
--                                           "k": 5};

-- ---------------------------------------------------------------------------
-- 4. Reasoning: the maintenance-window recommendation.
-- ---------------------------------------------------------------------------
SELECT fractal_reason(
    'one-line maintenance-window recommendation for a pump showing an accelerating '
    || 'vibration regime shift and drift from its intake baseline',
    '{"vibration_drift":"' || (SELECT ARRAY_TO_STRING(ARRAY_AGG(CAST("dj" AS VARCHAR), 8192), ',')
                                  FROM "hpm_drift" WHERE "asset" = 'PUMP-07')
     || '","baseline_trajectory":"' || (SELECT ARRAY_TO_STRING(ARRAY_AGG(CAST("distance" AS VARCHAR), 8192), ',')
                                         FROM "hpm_traj")
     || '"}') AS "recommendation";

-- ---------------------------------------------------------------------------
-- 5. The kit's own headline check.
--
-- The demo contract: a kit prints its headline and exits
-- non-zero unless the result holds. 384 readings over four assets, a
-- drift report that fires on PUMP-07 alone, and a trajectory search
-- that returned its five nearest fleet readings.
-- ---------------------------------------------------------------------------
SELECT CASE
           WHEN (SELECT COUNT(*) FROM "hpm_readings") = 384
            AND (SELECT COUNT(*) FROM "hpm_readings" WHERE "asset" = 'PUMP-07') = 96
            AND (SELECT COUNT(*) FROM "hpm_drift"
                 WHERE "asset" = 'PUMP-07'
                   AND ABS(fractal_json_value("dj", '$.drift')) > 0.5) = 1
            AND (SELECT COUNT(*) FROM "hpm_drift"
                 WHERE "asset" <> 'PUMP-07'
                   AND ABS(fractal_json_value("dj", '$.drift')) < 0.5) = 3
            AND (SELECT COUNT(*) FROM "hpm_traj") = 5
            THEN 'HEADLINE kit=heavy-industry-predictive-maintenance ok'
            ELSE 'HEADLINE kit=heavy-industry-predictive-maintenance FAILED'
       END AS "headline";
