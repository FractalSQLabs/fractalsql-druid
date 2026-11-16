-- demo/demo-vertical-climatech-emissions-monitoring.sql
--
-- FractalSQL for Apache Druid -- industry vertical: Climate Tech --
-- industrial emissions and utility-leak detection (methane / CO2 sensor
-- networks, water-distribution pressure and flow monitoring).
--
-- DOMAIN kit built on the signal fractal_agent_anomaly_triage uses: the
-- drift exponent of a single sensor's series flags a shift into a new
-- (leak / over-emission) regime, closing with a reasoned narrative.
--
-- Run:
--   python3 demo/run_demo.py --file demo/demo-vertical-climatech-emissions-monitoring.sql
--
-- Notes:
--   * Fully deterministic fixture (no random()).
--   * Each sensor has a baseline reading; the drift window is 32 points,
--     so each sensor needs >= 48 readings.  A leak is an ACCELERATING
--     concentration ramp downstream of the source, not a level shift:
--     DFA removes a constant offset, so only a change in the series'
--     dynamics moves the exponent.
--   * The network mixes gases and a pipeline-pressure sensor (PRS-07): the
--     agent is indifferent to the physical quantity, so the same call
--     screens a water-distribution pressure series for leaks.
--
-- ===========================================================================
-- Notes on how this runs on Druid
-- ===========================================================================
--
--   * Fixtures are MSQ writes, not CREATE TABLE + INSERT.  Druid has no
--     DDL, so a fixture is an INSERT INTO ... SELECT ... PARTITIONED BY
--     ALL, which creates the datasource.
--   * One row per sensor, not one row per reading: the series lives in an
--     ARRAY column, which is what the fractal_* functions read, so the
--     array IS the column.
--   * MOD() instead of '%': the percent operator is not allowed under
--     Druid's SQL conformance level.
--   * fractal_json_value instead of json_extract: Druid's JSON_VALUE reads
--     a COMPLEX column, not a JSON string, and the fractal_* functions
--     answer with a JSON document.
--   * The .print banners are comments; the runner prints the result rows.
--
-- Safe to re-run: the fixture replaces the datasource's data.

-- ---------------------------------------------------------------------------
-- 1. Four sensors x 96 readings.  CH4-02 (methane, downstream of a
-- compressor) starts leaking at reading 65: concentration ramps up
-- quadratically.  CH4-01 and CO2-01 are steady; PRS-07 is a pipeline
-- pressure sensor, steady here.
--
-- The column is called "reading", not "value": VALUE is a reserved word
-- in Calcite, and a reserved word cannot be used as a column alias.
-- ---------------------------------------------------------------------------
-- REPLACE, not INSERT: an INSERT appends, so a re-run would leave two
-- copies of every sensor and the per-sensor subqueries would break.
-- OVERWRITE ALL replaces the datasource's data, which is what "safe to
-- re-run" means here.
REPLACE INTO cem_series OVERWRITE ALL
SELECT r.sensor,
       CASE r.sensor
           WHEN 'CH4-01' THEN 'methane_ppm'
           WHEN 'CH4-02' THEN 'methane_ppm'
           WHEN 'CO2-01' THEN 'co2_ppm'
           ELSE 'pressure_kpa'
       END AS quantity,
       CASE r.sensor
           WHEN 'CH4-01' THEN 1.9
           WHEN 'CH4-02' THEN 1.9
           WHEN 'CO2-01' THEN 412.0
           ELSE 620.0
       END AS baseline,
       ARRAY_AGG(r.reading) AS "values",
       MAX(r.reading) AS peak
FROM (
    SELECT t.sensor,
           u.g AS seq,
           CASE t.sensor
               WHEN 'CH4-01' THEN 1.9
               WHEN 'CH4-02' THEN 1.9
               WHEN 'CO2-01' THEN 412.0
               ELSE 620.0
           END
           * (1.0 + 0.004 * MOD(u.g, 8))
           + CASE WHEN t.sensor = 'CH4-02' AND u.g > 64
                  THEN 0.0045 * (u.g - 64) * (u.g - 64)
                  ELSE 0.0
             END AS reading
    FROM UNNEST(ARRAY['CH4-01', 'CH4-02', 'CO2-01', 'PRS-07']) AS t(sensor)
    CROSS JOIN UNNEST(ARRAY[
        1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16,
        17, 18, 19, 20, 21, 22, 23, 24, 25, 26, 27, 28, 29, 30, 31, 32,
        33, 34, 35, 36, 37, 38, 39, 40, 41, 42, 43, 44, 45, 46, 47, 48,
        49, 50, 51, 52, 53, 54, 55, 56, 57, 58, 59, 60, 61, 62, 63, 64,
        65, 66, 67, 68, 69, 70, 71, 72, 73, 74, 75, 76, 77, 78, 79, 80,
        81, 82, 83, 84, 85, 86, 87, 88, 89, 90, 91, 92, 93, 94, 95, 96]) AS u(g)
) r
GROUP BY r.sensor
PARTITIONED BY ALL;

-- ORDER BY on a non-aggregating Druid query is restricted to __time, and
-- this datasource is not time-partitioned (the series lives in an array),
-- so the ordering is expressed as an aggregation. That is also what
-- makes the output order stable from run to run.
SELECT "sensor", "quantity", ROUND(MAX("peak"), 3) AS "peak", MAX("baseline") AS "baseline"
FROM "cem_series"
GROUP BY "sensor", "quantity"
ORDER BY "sensor";

-- ---------------------------------------------------------------------------
-- 2. Emissions-regime drift per sensor.
--
-- The drift exponent of the recent window against the baseline.  The
-- leaking sensor's ramp changes the series' dynamics, so its drift
-- moves; the steady sensors' do not.
-- ---------------------------------------------------------------------------
SELECT "sensor",
       ROUND(fractal_json_value(d, '$.drift'), 4)          AS "drift",
       ROUND(fractal_json_value(d, '$.recent_alpha'), 4)   AS "recent_alpha",
       ROUND(fractal_json_value(d, '$.baseline_alpha'), 4) AS "baseline_alpha"
FROM (
    SELECT "sensor", fractal_dimension_drift("values", 32) AS d
    FROM "cem_series"
    GROUP BY "sensor", "values"
)
ORDER BY "sensor";

-- ---------------------------------------------------------------------------
-- 3. Reasoning: the leak narrative.
--
-- This is the hand-composed part of the kit: the drift exponent says the
-- regime changed, and the model says what to do about it.
-- ---------------------------------------------------------------------------
SELECT fractal_reason(
    'one-line leak-detection narrative and recommended field response for this sensor',
    fractal_dimension_drift(
        (SELECT "values" FROM "cem_series" WHERE "sensor" = 'CH4-02'), 32)) AS "narrative";

-- ---------------------------------------------------------------------------
-- 4. The shipped agent.
--
-- The anomaly-triage agent reads a table with one row per reading, and this
-- kit keeps each sensor's series in a single ARRAY column, so it does not
-- call the agent. demo/demo-agents.sql shows the call
-- (`-- @call agent/anomaly_triage {...}`) over a table of readings; the
-- next section reads the same drift signal straight off the array.
-- ---------------------------------------------------------------------------

-- ---------------------------------------------------------------------------
-- 5. The hand-composed drift, read straight off the leaking sensor --
--    the same signal the agent would triage on.
-- ---------------------------------------------------------------------------
SELECT "sensor",
       fractal_dimension_dfa("values") AS "dfa",
       fractal_json_value(fractal_dimension_drift("values", 32), '$.drift') AS "drift"
FROM "cem_series"
GROUP BY "sensor", "values"
ORDER BY "sensor";

-- ---------------------------------------------------------------------------
-- 6. The kit's own headline check.
--
-- The demo contract: a kit prints its headline and exits
-- non-zero unless the result holds.  The leaking sensor's concentration
-- ramps quadratically from reading 65, so its peak must stand well
-- above the steady methane sensor's -- that is the signal the kit is
-- about.
-- ---------------------------------------------------------------------------
SELECT CASE
           WHEN (SELECT MAX("peak") FROM "cem_series" WHERE "sensor" = 'CH4-02')
                > 2.0 * (SELECT MAX("peak") FROM "cem_series" WHERE "sensor" = 'CH4-01')
           THEN 'HEADLINE kit=climatech-emissions-monitoring ok'
           ELSE 'HEADLINE kit=climatech-emissions-monitoring FAILED'
       END AS "headline";
