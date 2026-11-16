-- demo/demo-vertical-telecom-account-anomaly-screening.sql
--
-- FractalSQL for Apache Druid -- industry vertical: telecom account
-- anomaly screening. A history of known-anomalous change patterns, and
-- four proposed account events awaiting commit. Each event is screened
-- against the known patterns under two metrics: cosine, which flags a
-- faint event of the right shape, and exact Euclidean distance, which
-- lets it through to a lower-severity review queue.
--
--   1. Known-anomalous patterns + proposed account events.
--   2. The screen: the nearest known-anomalous pattern per event.
--   3. fractal_agent_outlier_intercept: the same screen, as an agent.
--   4. The same screen under exact Euclidean distance.
--   5. Reasoning: the justification an analyst sees next to the held
--      event.
--
-- Prerequisites: the extension is loaded on the Druid cluster. The closing
-- fractal_reason() narrative needs a reasoning provider
-- (docs/reasoning-setup.md); every other step runs with no model.
--
-- Run:
--   python3 demo/run_demo.py --file demo/demo-vertical-telecom-account-anomaly-screening.sql
--
-- ===========================================================================
-- Notes on how this runs on Druid
-- ===========================================================================
--
--   * The fixtures are @fixture directives: Druid has no DDL and no
--     VALUES, so a set of rows has no SQL form.
--   * The screen is a service call: an agent reads a table and reasons
--     about it, and a Druid SQL function can do neither. The call covers
--     the whole table of proposed events, and its result lands in a
--     datasource the kit can query.
--
-- Notes:
--   * Fully deterministic fixtures (no random()).

-- ---------------------------------------------------------------------------
-- 0. Sanity check: extension loaded?
-- ---------------------------------------------------------------------------
SELECT fractal_edition(), fractal_version();

-- ---------------------------------------------------------------------------
-- 1. Known-anomalous patterns + proposed account events.
-- ---------------------------------------------------------------------------
-- @fixture taa_known_anomalous {"rows": [
--   {"id": 1, "pattern": "SIM swap + port-out + new device", "event": "0.95,0.90,0.85,0.10,0.20"},
--   {"id": 2, "pattern": "SIM swap from a distant location", "event": "0.90,0.05,0.30,0.95,0.40"},
--   {"id": 3, "pattern": "rapid plan changes off-hours", "event": "0.05,0.05,0.10,0.10,0.95"},
--   {"id": 4, "pattern": "new device + location jump + port-out", "event": "0.10,0.80,0.90,0.85,0.30"}
-- ]};

-- @fixture taa_proposed {"rows": [
--   {"id": 1, "label": "E1 swap + port-out + new handset", "event": "0.92,0.88,0.80,0.12,0.18"},
--   {"id": 2, "label": "E2 routine plan upgrade", "event": "0.02,0.00,0.05,0.00,0.05"},
--   {"id": 3, "label": "E3 new handset, same city", "event": "0.00,0.02,0.70,0.04,0.05"},
--   {"id": 4, "label": "E4 faint SIM swap, far away", "event": "0.40,0.02,0.12,0.42,0.16"}
-- ]};

SELECT COUNT(*) AS "known_patterns" FROM "taa_known_anomalous";

-- ---------------------------------------------------------------------------
-- 2. The screen: the nearest known-anomalous pattern per event,
-- threshold 0.10 (cosine).
-- ---------------------------------------------------------------------------
-- @call agent/outlier_screen {"proposed_table": "taa_proposed", "state_column": "event",
--                            "id_column": "id", "label_column": "label",
--                            "history_table": "taa_known_anomalous", "emb_column": "event",
--                            "threshold": 0.1, "metric": "cosine"} AS taa_screen;

SELECT p."label" AS "label",
       k."pattern" AS "nearest_pattern",
       ROUND(s."distance", 4) AS "distance",
       (s."distance" < 0.10) AS "intercepted"
FROM "taa_screen" s, "taa_proposed" p, "taa_known_anomalous" k
WHERE s."id" = p."id" AND s."doc_id" = k."id";

-- ---------------------------------------------------------------------------
-- 3. The shipped agent (the reasoning provider supplies its "reason").
-- ---------------------------------------------------------------------------
-- @call agent/outlier_screen {"proposed_table": "taa_proposed", "state_column": "event",
--                            "id_column": "id", "label_column": "label",
--                            "history_table": "taa_known_anomalous", "emb_column": "event",
--                            "threshold": 0.1, "metric": "cosine"} AS taa_screen_agent;

-- ---------------------------------------------------------------------------
-- 4. When intensity should count: exact Euclidean distance. E4 is a
-- faint SIM swap with a location jump -- the same shape as a known
-- pattern but at under half the intensity -- so cosine flags it while
-- l2 lets it through to a lower-severity review queue.
-- ---------------------------------------------------------------------------
-- @call agent/outlier_screen {"proposed_table": "taa_proposed", "state_column": "event",
--                            "id_column": "id", "label_column": "label",
--                            "history_table": "taa_known_anomalous", "emb_column": "event",
--                            "threshold": 0.3, "metric": "l2"} AS taa_screen_l2;

SELECT p."label" AS "label", s."intercepted" AS "intercepted_l2"
FROM "taa_screen_l2" s, "taa_proposed" p
WHERE s."id" = p."id";

-- ---------------------------------------------------------------------------
-- 5. Reasoning: the justification an analyst sees next to the held
-- event.
-- ---------------------------------------------------------------------------
SELECT fractal_reason(
    'one-line justification for holding this account change for review',
    '{"event":"' || (SELECT ARRAY_TO_STRING(ARRAY_AGG(CAST("label" AS VARCHAR), 8192), ',')
                      FROM "taa_proposed" WHERE "id" = 1)
     || '","screen":"' || (SELECT ARRAY_TO_STRING(ARRAY_AGG(CAST("pattern" AS VARCHAR), 8192), ',')
                          FROM "taa_screen" s, "taa_known_anomalous" k
                          WHERE s."doc_id" = k."id" AND s."id" = 1)
     || '"}') AS "narrative";

-- ---------------------------------------------------------------------------
-- The headline.
--
-- The kit passes when all four events were screened against the four
-- known patterns and the cosine screen caught two of them -- the SIM
-- swap with a port-out and the faint swap from a distance.
-- ---------------------------------------------------------------------------
SELECT CASE
           WHEN (SELECT COUNT(*) FROM "taa_proposed") = 4
            AND (SELECT COUNT(*) FROM "taa_known_anomalous") = 4
            AND (SELECT COUNT(*) FROM "taa_screen" s, "taa_proposed" p
                 WHERE s."id" = p."id" AND s."distance" < 0.10) = 2
            THEN 'HEADLINE kit=telecom-account-anomaly-screening ok'
            ELSE 'HEADLINE kit=telecom-account-anomaly-screening FAILED'
       END AS "headline";
