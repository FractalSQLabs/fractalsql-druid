-- demo/demo-vertical-agentic-ops-devops.sql
--
-- FractalSQL for Apache Druid -- industry vertical: autonomous incident
-- triage and self-healing. A deployment bot is stuck in an infinite
-- retry loop (its state toggles between two values every cycle) and
-- its latency is drifting; a fleet health monitor has to catch the
-- loop from the raw state stream, route the incident to the right
-- capability, and stop the change before it reaches a known-bad state.
--
--   1. The incident telemetry: 96 cycles from the stuck bot, three
--      from a healthy one.
--   2. fractal_agent_detect_loop: the period-2 state toggle.
--   3. fractal_agent_route_task: the nearest capability.
--   4. fractal_agent_outlier_intercept: the proposed state matches a
--      known-bad one.
--   5. fractal_agent_anomaly_triage: the drifting latency metric.
--   6. fractal_agent_search_agent and fractal_agent_rag_agent: the
--      root-cause synthesis over the incident corpus.
--   7. A closing fractal_reason() writes the triage.
--
-- Prerequisites: the extension is loaded on the Druid cluster. The
-- agents' rationales and the closing triage need a reasoning provider
-- (docs/reasoning-setup.md); every other step runs with no model.
--
-- Run:
--   python3 demo/run_demo.py --file demo/demo-vertical-agentic-ops-devops.sql
--
-- ===========================================================================
-- Notes on how this runs on Druid
-- ===========================================================================
--
--   * The three tables are @fixture directives: Druid has no DDL, no
--     VALUES and no recursive CTE, so a set of rows has no SQL form.
--     The timestamps are fixed values rather than relative to now, and the fixture's timestamp column becomes the row's
--     __time -- which is also how the triage agent orders the series.
--   * The state_hash toggle is one-hot encoded into 2-dimensional
--     directions (12345 -> [1,0], 67890 -> [0,1]) because fractal_state_fingerprint is
--     direction-based: a raw scalar cast to a 1-dimensional vector
--     would collapse to its sign, and every same-signed sequence would
--     false-positive as "looping". The one-hot state log is carried in
--     a fixture row, because the agent reads a table.
--   * The loop verdict is the fingerprint stream itself: a state whose
--     fingerprint repeats is a loop, and the repetition count gives
--     the period. The core's own Brent detector is not used -- on Druid it never returns.
--   * The agents are service calls: an agent reads a table and reasons
--     about it, and a Druid SQL function can do neither.
--   * The incident text is embedded by the extension's own embed tier
--     rather than by the vectorizer. The vectorizer's registry is per
--     node on Druid, not a TEMP object per connection, so a kit that
--     registered one would leave it watching its table for every
--     later run on the shared node; the tier itself is exercised in
--     demo-vectorizer.sql. The embeddings land in a datasource of
--     their own, because the search agents read a table.
--
-- Notes:
--   * Fully deterministic fixtures (no random()).

-- ---------------------------------------------------------------------------
-- 0. Sanity check: extension loaded?
-- ---------------------------------------------------------------------------
SELECT fractal_edition(), fractal_version();

-- ---------------------------------------------------------------------------
-- 1. The incident telemetry.
--
-- bot-deploy-01 is a deployment bot stuck in an infinite retry loop:
-- the state_hash toggles 12345 <-> 67890 every cycle (a clean period-2
-- sequence). The latency_ms series is a genuinely drifting (non-
-- degenerate) signal -- a baseline of about 50ms for the first 64
-- cycles, then a +30ms step-up over the most recent 32 (the loop
-- degrading the latency).
-- ---------------------------------------------------------------------------
-- @fixture aod_incident_logs {"rows": [
--   {"id": 1, "agent_id": "bot-deploy-01", "state_hash": 12345, "latency_ms": 51.3, "body": "bot-deploy-01 retrying authentication: identity service refused connection (attempt 1)", "ts": "2026-11-11T16:00:01Z", "payload": "{\"event\": \"retry_auth\"}"},
--   {"id": 2, "agent_id": "bot-deploy-01", "state_hash": 67890, "latency_ms": 52.6, "body": "bot-deploy-01 health check completed: all subsystems nominal (cycle 2)", "ts": "2026-11-11T16:00:02Z", "payload": "{\"event\": \"check_health\"}"},
--   {"id": 3, "agent_id": "bot-deploy-01", "state_hash": 12345, "latency_ms": 53.9, "body": "bot-deploy-01 retrying authentication: identity service refused connection (attempt 3)", "ts": "2026-11-11T16:00:03Z", "payload": "{\"event\": \"retry_auth\"}"},
--   {"id": 4, "agent_id": "bot-deploy-01", "state_hash": 67890, "latency_ms": 55.2, "body": "bot-deploy-01 health check completed: all subsystems nominal (cycle 4)", "ts": "2026-11-11T16:00:04Z", "payload": "{\"event\": \"check_health\"}"},
--   {"id": 5, "agent_id": "bot-deploy-01", "state_hash": 12345, "latency_ms": 56.5, "body": "bot-deploy-01 retrying authentication: identity service refused connection (attempt 5)", "ts": "2026-11-11T16:00:05Z", "payload": "{\"event\": \"retry_auth\"}"},
--   {"id": 6, "agent_id": "bot-deploy-01", "state_hash": 67890, "latency_ms": 57.8, "body": "bot-deploy-01 health check completed: all subsystems nominal (cycle 6)", "ts": "2026-11-11T16:00:06Z", "payload": "{\"event\": \"check_health\"}"},
--   {"id": 7, "agent_id": "bot-deploy-01", "state_hash": 12345, "latency_ms": 59.1, "body": "bot-deploy-01 retrying authentication: identity service refused connection (attempt 7)", "ts": "2026-11-11T16:00:07Z", "payload": "{\"event\": \"retry_auth\"}"},
--   {"id": 8, "agent_id": "bot-deploy-01", "state_hash": 67890, "latency_ms": 50.0, "body": "bot-deploy-01 health check completed: all subsystems nominal (cycle 8)", "ts": "2026-11-11T16:00:08Z", "payload": "{\"event\": \"check_health\"}"},
--   {"id": 9, "agent_id": "bot-deploy-01", "state_hash": 12345, "latency_ms": 51.3, "body": "bot-deploy-01 retrying authentication: identity service refused connection (attempt 9)", "ts": "2026-11-11T16:00:09Z", "payload": "{\"event\": \"retry_auth\"}"},
--   {"id": 10, "agent_id": "bot-deploy-01", "state_hash": 67890, "latency_ms": 52.6, "body": "bot-deploy-01 health check completed: all subsystems nominal (cycle 10)", "ts": "2026-11-11T16:00:10Z", "payload": "{\"event\": \"check_health\"}"},
--   {"id": 11, "agent_id": "bot-deploy-01", "state_hash": 12345, "latency_ms": 53.9, "body": "bot-deploy-01 retrying authentication: identity service refused connection (attempt 11)", "ts": "2026-11-11T16:00:11Z", "payload": "{\"event\": \"retry_auth\"}"},
--   {"id": 12, "agent_id": "bot-deploy-01", "state_hash": 67890, "latency_ms": 55.2, "body": "bot-deploy-01 health check completed: all subsystems nominal (cycle 12)", "ts": "2026-11-11T16:00:12Z", "payload": "{\"event\": \"check_health\"}"},
--   {"id": 13, "agent_id": "bot-deploy-01", "state_hash": 12345, "latency_ms": 56.5, "body": "bot-deploy-01 retrying authentication: identity service refused connection (attempt 13)", "ts": "2026-11-11T16:00:13Z", "payload": "{\"event\": \"retry_auth\"}"},
--   {"id": 14, "agent_id": "bot-deploy-01", "state_hash": 67890, "latency_ms": 57.8, "body": "bot-deploy-01 health check completed: all subsystems nominal (cycle 14)", "ts": "2026-11-11T16:00:14Z", "payload": "{\"event\": \"check_health\"}"},
--   {"id": 15, "agent_id": "bot-deploy-01", "state_hash": 12345, "latency_ms": 59.1, "body": "bot-deploy-01 retrying authentication: identity service refused connection (attempt 15)", "ts": "2026-11-11T16:00:15Z", "payload": "{\"event\": \"retry_auth\"}"},
--   {"id": 16, "agent_id": "bot-deploy-01", "state_hash": 67890, "latency_ms": 50.0, "body": "bot-deploy-01 health check completed: all subsystems nominal (cycle 16)", "ts": "2026-11-11T16:00:16Z", "payload": "{\"event\": \"check_health\"}"},
--   {"id": 17, "agent_id": "bot-deploy-01", "state_hash": 12345, "latency_ms": 51.3, "body": "bot-deploy-01 retrying authentication: identity service refused connection (attempt 17)", "ts": "2026-11-11T16:00:17Z", "payload": "{\"event\": \"retry_auth\"}"},
--   {"id": 18, "agent_id": "bot-deploy-01", "state_hash": 67890, "latency_ms": 52.6, "body": "bot-deploy-01 health check completed: all subsystems nominal (cycle 18)", "ts": "2026-11-11T16:00:18Z", "payload": "{\"event\": \"check_health\"}"},
--   {"id": 19, "agent_id": "bot-deploy-01", "state_hash": 12345, "latency_ms": 53.9, "body": "bot-deploy-01 retrying authentication: identity service refused connection (attempt 19)", "ts": "2026-11-11T16:00:19Z", "payload": "{\"event\": \"retry_auth\"}"},
--   {"id": 20, "agent_id": "bot-deploy-01", "state_hash": 67890, "latency_ms": 55.2, "body": "bot-deploy-01 health check completed: all subsystems nominal (cycle 20)", "ts": "2026-11-11T16:00:20Z", "payload": "{\"event\": \"check_health\"}"},
--   {"id": 21, "agent_id": "bot-deploy-01", "state_hash": 12345, "latency_ms": 56.5, "body": "bot-deploy-01 retrying authentication: identity service refused connection (attempt 21)", "ts": "2026-11-11T16:00:21Z", "payload": "{\"event\": \"retry_auth\"}"},
--   {"id": 22, "agent_id": "bot-deploy-01", "state_hash": 67890, "latency_ms": 57.8, "body": "bot-deploy-01 health check completed: all subsystems nominal (cycle 22)", "ts": "2026-11-11T16:00:22Z", "payload": "{\"event\": \"check_health\"}"},
--   {"id": 23, "agent_id": "bot-deploy-01", "state_hash": 12345, "latency_ms": 59.1, "body": "bot-deploy-01 retrying authentication: identity service refused connection (attempt 23)", "ts": "2026-11-11T16:00:23Z", "payload": "{\"event\": \"retry_auth\"}"},
--   {"id": 24, "agent_id": "bot-deploy-01", "state_hash": 67890, "latency_ms": 50.0, "body": "bot-deploy-01 health check completed: all subsystems nominal (cycle 24)", "ts": "2026-11-11T16:00:24Z", "payload": "{\"event\": \"check_health\"}"},
--   {"id": 25, "agent_id": "bot-deploy-01", "state_hash": 12345, "latency_ms": 51.3, "body": "bot-deploy-01 retrying authentication: identity service refused connection (attempt 25)", "ts": "2026-11-11T16:00:25Z", "payload": "{\"event\": \"retry_auth\"}"},
--   {"id": 26, "agent_id": "bot-deploy-01", "state_hash": 67890, "latency_ms": 52.6, "body": "bot-deploy-01 health check completed: all subsystems nominal (cycle 26)", "ts": "2026-11-11T16:00:26Z", "payload": "{\"event\": \"check_health\"}"},
--   {"id": 27, "agent_id": "bot-deploy-01", "state_hash": 12345, "latency_ms": 53.9, "body": "bot-deploy-01 retrying authentication: identity service refused connection (attempt 27)", "ts": "2026-11-11T16:00:27Z", "payload": "{\"event\": \"retry_auth\"}"},
--   {"id": 28, "agent_id": "bot-deploy-01", "state_hash": 67890, "latency_ms": 55.2, "body": "bot-deploy-01 health check completed: all subsystems nominal (cycle 28)", "ts": "2026-11-11T16:00:28Z", "payload": "{\"event\": \"check_health\"}"},
--   {"id": 29, "agent_id": "bot-deploy-01", "state_hash": 12345, "latency_ms": 56.5, "body": "bot-deploy-01 retrying authentication: identity service refused connection (attempt 29)", "ts": "2026-11-11T16:00:29Z", "payload": "{\"event\": \"retry_auth\"}"},
--   {"id": 30, "agent_id": "bot-deploy-01", "state_hash": 67890, "latency_ms": 57.8, "body": "bot-deploy-01 health check completed: all subsystems nominal (cycle 30)", "ts": "2026-11-11T16:00:30Z", "payload": "{\"event\": \"check_health\"}"},
--   {"id": 31, "agent_id": "bot-deploy-01", "state_hash": 12345, "latency_ms": 59.1, "body": "bot-deploy-01 retrying authentication: identity service refused connection (attempt 31)", "ts": "2026-11-11T16:00:31Z", "payload": "{\"event\": \"retry_auth\"}"},
--   {"id": 32, "agent_id": "bot-deploy-01", "state_hash": 67890, "latency_ms": 50.0, "body": "bot-deploy-01 health check completed: all subsystems nominal (cycle 32)", "ts": "2026-11-11T16:00:32Z", "payload": "{\"event\": \"check_health\"}"},
--   {"id": 33, "agent_id": "bot-deploy-01", "state_hash": 12345, "latency_ms": 51.3, "body": "bot-deploy-01 retrying authentication: identity service refused connection (attempt 33)", "ts": "2026-11-11T16:00:33Z", "payload": "{\"event\": \"retry_auth\"}"},
--   {"id": 34, "agent_id": "bot-deploy-01", "state_hash": 67890, "latency_ms": 52.6, "body": "bot-deploy-01 health check completed: all subsystems nominal (cycle 34)", "ts": "2026-11-11T16:00:34Z", "payload": "{\"event\": \"check_health\"}"},
--   {"id": 35, "agent_id": "bot-deploy-01", "state_hash": 12345, "latency_ms": 53.9, "body": "bot-deploy-01 retrying authentication: identity service refused connection (attempt 35)", "ts": "2026-11-11T16:00:35Z", "payload": "{\"event\": \"retry_auth\"}"},
--   {"id": 36, "agent_id": "bot-deploy-01", "state_hash": 67890, "latency_ms": 55.2, "body": "bot-deploy-01 health check completed: all subsystems nominal (cycle 36)", "ts": "2026-11-11T16:00:36Z", "payload": "{\"event\": \"check_health\"}"},
--   {"id": 37, "agent_id": "bot-deploy-01", "state_hash": 12345, "latency_ms": 56.5, "body": "bot-deploy-01 retrying authentication: identity service refused connection (attempt 37)", "ts": "2026-11-11T16:00:37Z", "payload": "{\"event\": \"retry_auth\"}"},
--   {"id": 38, "agent_id": "bot-deploy-01", "state_hash": 67890, "latency_ms": 57.8, "body": "bot-deploy-01 health check completed: all subsystems nominal (cycle 38)", "ts": "2026-11-11T16:00:38Z", "payload": "{\"event\": \"check_health\"}"},
--   {"id": 39, "agent_id": "bot-deploy-01", "state_hash": 12345, "latency_ms": 59.1, "body": "bot-deploy-01 retrying authentication: identity service refused connection (attempt 39)", "ts": "2026-11-11T16:00:39Z", "payload": "{\"event\": \"retry_auth\"}"},
--   {"id": 40, "agent_id": "bot-deploy-01", "state_hash": 67890, "latency_ms": 50.0, "body": "bot-deploy-01 health check completed: all subsystems nominal (cycle 40)", "ts": "2026-11-11T16:00:40Z", "payload": "{\"event\": \"check_health\"}"},
--   {"id": 41, "agent_id": "bot-deploy-01", "state_hash": 12345, "latency_ms": 51.3, "body": "bot-deploy-01 retrying authentication: identity service refused connection (attempt 41)", "ts": "2026-11-11T16:00:41Z", "payload": "{\"event\": \"retry_auth\"}"},
--   {"id": 42, "agent_id": "bot-deploy-01", "state_hash": 67890, "latency_ms": 52.6, "body": "bot-deploy-01 health check completed: all subsystems nominal (cycle 42)", "ts": "2026-11-11T16:00:42Z", "payload": "{\"event\": \"check_health\"}"},
--   {"id": 43, "agent_id": "bot-deploy-01", "state_hash": 12345, "latency_ms": 53.9, "body": "bot-deploy-01 retrying authentication: identity service refused connection (attempt 43)", "ts": "2026-11-11T16:00:43Z", "payload": "{\"event\": \"retry_auth\"}"},
--   {"id": 44, "agent_id": "bot-deploy-01", "state_hash": 67890, "latency_ms": 55.2, "body": "bot-deploy-01 health check completed: all subsystems nominal (cycle 44)", "ts": "2026-11-11T16:00:44Z", "payload": "{\"event\": \"check_health\"}"},
--   {"id": 45, "agent_id": "bot-deploy-01", "state_hash": 12345, "latency_ms": 56.5, "body": "bot-deploy-01 retrying authentication: identity service refused connection (attempt 45)", "ts": "2026-11-11T16:00:45Z", "payload": "{\"event\": \"retry_auth\"}"},
--   {"id": 46, "agent_id": "bot-deploy-01", "state_hash": 67890, "latency_ms": 57.8, "body": "bot-deploy-01 health check completed: all subsystems nominal (cycle 46)", "ts": "2026-11-11T16:00:46Z", "payload": "{\"event\": \"check_health\"}"},
--   {"id": 47, "agent_id": "bot-deploy-01", "state_hash": 12345, "latency_ms": 59.1, "body": "bot-deploy-01 retrying authentication: identity service refused connection (attempt 47)", "ts": "2026-11-11T16:00:47Z", "payload": "{\"event\": \"retry_auth\"}"},
--   {"id": 48, "agent_id": "bot-deploy-01", "state_hash": 67890, "latency_ms": 50.0, "body": "bot-deploy-01 health check completed: all subsystems nominal (cycle 48)", "ts": "2026-11-11T16:00:48Z", "payload": "{\"event\": \"check_health\"}"},
--   {"id": 49, "agent_id": "bot-deploy-01", "state_hash": 12345, "latency_ms": 51.3, "body": "bot-deploy-01 retrying authentication: identity service refused connection (attempt 49)", "ts": "2026-11-11T16:00:49Z", "payload": "{\"event\": \"retry_auth\"}"},
--   {"id": 50, "agent_id": "bot-deploy-01", "state_hash": 67890, "latency_ms": 52.6, "body": "bot-deploy-01 health check completed: all subsystems nominal (cycle 50)", "ts": "2026-11-11T16:00:50Z", "payload": "{\"event\": \"check_health\"}"},
--   {"id": 51, "agent_id": "bot-deploy-01", "state_hash": 12345, "latency_ms": 53.9, "body": "bot-deploy-01 retrying authentication: identity service refused connection (attempt 51)", "ts": "2026-11-11T16:00:51Z", "payload": "{\"event\": \"retry_auth\"}"},
--   {"id": 52, "agent_id": "bot-deploy-01", "state_hash": 67890, "latency_ms": 55.2, "body": "bot-deploy-01 health check completed: all subsystems nominal (cycle 52)", "ts": "2026-11-11T16:00:52Z", "payload": "{\"event\": \"check_health\"}"},
--   {"id": 53, "agent_id": "bot-deploy-01", "state_hash": 12345, "latency_ms": 56.5, "body": "bot-deploy-01 retrying authentication: identity service refused connection (attempt 53)", "ts": "2026-11-11T16:00:53Z", "payload": "{\"event\": \"retry_auth\"}"},
--   {"id": 54, "agent_id": "bot-deploy-01", "state_hash": 67890, "latency_ms": 57.8, "body": "bot-deploy-01 health check completed: all subsystems nominal (cycle 54)", "ts": "2026-11-11T16:00:54Z", "payload": "{\"event\": \"check_health\"}"},
--   {"id": 55, "agent_id": "bot-deploy-01", "state_hash": 12345, "latency_ms": 59.1, "body": "bot-deploy-01 retrying authentication: identity service refused connection (attempt 55)", "ts": "2026-11-11T16:00:55Z", "payload": "{\"event\": \"retry_auth\"}"},
--   {"id": 56, "agent_id": "bot-deploy-01", "state_hash": 67890, "latency_ms": 50.0, "body": "bot-deploy-01 health check completed: all subsystems nominal (cycle 56)", "ts": "2026-11-11T16:00:56Z", "payload": "{\"event\": \"check_health\"}"},
--   {"id": 57, "agent_id": "bot-deploy-01", "state_hash": 12345, "latency_ms": 51.3, "body": "bot-deploy-01 retrying authentication: identity service refused connection (attempt 57)", "ts": "2026-11-11T16:00:57Z", "payload": "{\"event\": \"retry_auth\"}"},
--   {"id": 58, "agent_id": "bot-deploy-01", "state_hash": 67890, "latency_ms": 52.6, "body": "bot-deploy-01 health check completed: all subsystems nominal (cycle 58)", "ts": "2026-11-11T16:00:58Z", "payload": "{\"event\": \"check_health\"}"},
--   {"id": 59, "agent_id": "bot-deploy-01", "state_hash": 12345, "latency_ms": 53.9, "body": "bot-deploy-01 retrying authentication: identity service refused connection (attempt 59)", "ts": "2026-11-11T16:00:59Z", "payload": "{\"event\": \"retry_auth\"}"},
--   {"id": 60, "agent_id": "bot-deploy-01", "state_hash": 67890, "latency_ms": 55.2, "body": "bot-deploy-01 health check completed: all subsystems nominal (cycle 60)", "ts": "2026-11-11T16:01:00Z", "payload": "{\"event\": \"check_health\"}"},
--   {"id": 61, "agent_id": "bot-deploy-01", "state_hash": 12345, "latency_ms": 56.5, "body": "bot-deploy-01 retrying authentication: identity service refused connection (attempt 61)", "ts": "2026-11-11T16:01:01Z", "payload": "{\"event\": \"retry_auth\"}"},
--   {"id": 62, "agent_id": "bot-deploy-01", "state_hash": 67890, "latency_ms": 57.8, "body": "bot-deploy-01 health check completed: all subsystems nominal (cycle 62)", "ts": "2026-11-11T16:01:02Z", "payload": "{\"event\": \"check_health\"}"},
--   {"id": 63, "agent_id": "bot-deploy-01", "state_hash": 12345, "latency_ms": 59.1, "body": "bot-deploy-01 retrying authentication: identity service refused connection (attempt 63)", "ts": "2026-11-11T16:01:03Z", "payload": "{\"event\": \"retry_auth\"}"},
--   {"id": 64, "agent_id": "bot-deploy-01", "state_hash": 67890, "latency_ms": 50.0, "body": "bot-deploy-01 health check completed: all subsystems nominal (cycle 64)", "ts": "2026-11-11T16:01:04Z", "payload": "{\"event\": \"check_health\"}"},
--   {"id": 65, "agent_id": "bot-deploy-01", "state_hash": 12345, "latency_ms": 81.3, "body": "bot-deploy-01 retrying authentication: identity service refused connection (attempt 65)", "ts": "2026-11-11T16:01:05Z", "payload": "{\"event\": \"retry_auth\"}"},
--   {"id": 66, "agent_id": "bot-deploy-01", "state_hash": 67890, "latency_ms": 82.6, "body": "bot-deploy-01 health check completed: all subsystems nominal (cycle 66)", "ts": "2026-11-11T16:01:06Z", "payload": "{\"event\": \"check_health\"}"},
--   {"id": 67, "agent_id": "bot-deploy-01", "state_hash": 12345, "latency_ms": 83.9, "body": "bot-deploy-01 retrying authentication: identity service refused connection (attempt 67)", "ts": "2026-11-11T16:01:07Z", "payload": "{\"event\": \"retry_auth\"}"},
--   {"id": 68, "agent_id": "bot-deploy-01", "state_hash": 67890, "latency_ms": 85.2, "body": "bot-deploy-01 health check completed: all subsystems nominal (cycle 68)", "ts": "2026-11-11T16:01:08Z", "payload": "{\"event\": \"check_health\"}"},
--   {"id": 69, "agent_id": "bot-deploy-01", "state_hash": 12345, "latency_ms": 86.5, "body": "bot-deploy-01 retrying authentication: identity service refused connection (attempt 69)", "ts": "2026-11-11T16:01:09Z", "payload": "{\"event\": \"retry_auth\"}"},
--   {"id": 70, "agent_id": "bot-deploy-01", "state_hash": 67890, "latency_ms": 87.8, "body": "bot-deploy-01 health check completed: all subsystems nominal (cycle 70)", "ts": "2026-11-11T16:01:10Z", "payload": "{\"event\": \"check_health\"}"},
--   {"id": 71, "agent_id": "bot-deploy-01", "state_hash": 12345, "latency_ms": 89.1, "body": "bot-deploy-01 retrying authentication: identity service refused connection (attempt 71)", "ts": "2026-11-11T16:01:11Z", "payload": "{\"event\": \"retry_auth\"}"},
--   {"id": 72, "agent_id": "bot-deploy-01", "state_hash": 67890, "latency_ms": 80.0, "body": "bot-deploy-01 health check completed: all subsystems nominal (cycle 72)", "ts": "2026-11-11T16:01:12Z", "payload": "{\"event\": \"check_health\"}"},
--   {"id": 73, "agent_id": "bot-deploy-01", "state_hash": 12345, "latency_ms": 81.3, "body": "bot-deploy-01 retrying authentication: identity service refused connection (attempt 73)", "ts": "2026-11-11T16:01:13Z", "payload": "{\"event\": \"retry_auth\"}"},
--   {"id": 74, "agent_id": "bot-deploy-01", "state_hash": 67890, "latency_ms": 82.6, "body": "bot-deploy-01 health check completed: all subsystems nominal (cycle 74)", "ts": "2026-11-11T16:01:14Z", "payload": "{\"event\": \"check_health\"}"},
--   {"id": 75, "agent_id": "bot-deploy-01", "state_hash": 12345, "latency_ms": 83.9, "body": "bot-deploy-01 retrying authentication: identity service refused connection (attempt 75)", "ts": "2026-11-11T16:01:15Z", "payload": "{\"event\": \"retry_auth\"}"},
--   {"id": 76, "agent_id": "bot-deploy-01", "state_hash": 67890, "latency_ms": 85.2, "body": "bot-deploy-01 health check completed: all subsystems nominal (cycle 76)", "ts": "2026-11-11T16:01:16Z", "payload": "{\"event\": \"check_health\"}"},
--   {"id": 77, "agent_id": "bot-deploy-01", "state_hash": 12345, "latency_ms": 86.5, "body": "bot-deploy-01 retrying authentication: identity service refused connection (attempt 77)", "ts": "2026-11-11T16:01:17Z", "payload": "{\"event\": \"retry_auth\"}"},
--   {"id": 78, "agent_id": "bot-deploy-01", "state_hash": 67890, "latency_ms": 87.8, "body": "bot-deploy-01 health check completed: all subsystems nominal (cycle 78)", "ts": "2026-11-11T16:01:18Z", "payload": "{\"event\": \"check_health\"}"},
--   {"id": 79, "agent_id": "bot-deploy-01", "state_hash": 12345, "latency_ms": 89.1, "body": "bot-deploy-01 retrying authentication: identity service refused connection (attempt 79)", "ts": "2026-11-11T16:01:19Z", "payload": "{\"event\": \"retry_auth\"}"},
--   {"id": 80, "agent_id": "bot-deploy-01", "state_hash": 67890, "latency_ms": 80.0, "body": "bot-deploy-01 health check completed: all subsystems nominal (cycle 80)", "ts": "2026-11-11T16:01:20Z", "payload": "{\"event\": \"check_health\"}"},
--   {"id": 81, "agent_id": "bot-deploy-01", "state_hash": 12345, "latency_ms": 81.3, "body": "bot-deploy-01 retrying authentication: identity service refused connection (attempt 81)", "ts": "2026-11-11T16:01:21Z", "payload": "{\"event\": \"retry_auth\"}"},
--   {"id": 82, "agent_id": "bot-deploy-01", "state_hash": 67890, "latency_ms": 82.6, "body": "bot-deploy-01 health check completed: all subsystems nominal (cycle 82)", "ts": "2026-11-11T16:01:22Z", "payload": "{\"event\": \"check_health\"}"},
--   {"id": 83, "agent_id": "bot-deploy-01", "state_hash": 12345, "latency_ms": 83.9, "body": "bot-deploy-01 retrying authentication: identity service refused connection (attempt 83)", "ts": "2026-11-11T16:01:23Z", "payload": "{\"event\": \"retry_auth\"}"},
--   {"id": 84, "agent_id": "bot-deploy-01", "state_hash": 67890, "latency_ms": 85.2, "body": "bot-deploy-01 health check completed: all subsystems nominal (cycle 84)", "ts": "2026-11-11T16:01:24Z", "payload": "{\"event\": \"check_health\"}"},
--   {"id": 85, "agent_id": "bot-deploy-01", "state_hash": 12345, "latency_ms": 86.5, "body": "bot-deploy-01 retrying authentication: identity service refused connection (attempt 85)", "ts": "2026-11-11T16:01:25Z", "payload": "{\"event\": \"retry_auth\"}"},
--   {"id": 86, "agent_id": "bot-deploy-01", "state_hash": 67890, "latency_ms": 87.8, "body": "bot-deploy-01 health check completed: all subsystems nominal (cycle 86)", "ts": "2026-11-11T16:01:26Z", "payload": "{\"event\": \"check_health\"}"},
--   {"id": 87, "agent_id": "bot-deploy-01", "state_hash": 12345, "latency_ms": 89.1, "body": "bot-deploy-01 retrying authentication: identity service refused connection (attempt 87)", "ts": "2026-11-11T16:01:27Z", "payload": "{\"event\": \"retry_auth\"}"},
--   {"id": 88, "agent_id": "bot-deploy-01", "state_hash": 67890, "latency_ms": 80.0, "body": "bot-deploy-01 health check completed: all subsystems nominal (cycle 88)", "ts": "2026-11-11T16:01:28Z", "payload": "{\"event\": \"check_health\"}"},
--   {"id": 89, "agent_id": "bot-deploy-01", "state_hash": 12345, "latency_ms": 81.3, "body": "bot-deploy-01 retrying authentication: identity service refused connection (attempt 89)", "ts": "2026-11-11T16:01:29Z", "payload": "{\"event\": \"retry_auth\"}"},
--   {"id": 90, "agent_id": "bot-deploy-01", "state_hash": 67890, "latency_ms": 82.6, "body": "bot-deploy-01 health check completed: all subsystems nominal (cycle 90)", "ts": "2026-11-11T16:01:30Z", "payload": "{\"event\": \"check_health\"}"},
--   {"id": 91, "agent_id": "bot-deploy-01", "state_hash": 12345, "latency_ms": 83.9, "body": "bot-deploy-01 retrying authentication: identity service refused connection (attempt 91)", "ts": "2026-11-11T16:01:31Z", "payload": "{\"event\": \"retry_auth\"}"},
--   {"id": 92, "agent_id": "bot-deploy-01", "state_hash": 67890, "latency_ms": 85.2, "body": "bot-deploy-01 health check completed: all subsystems nominal (cycle 92)", "ts": "2026-11-11T16:01:32Z", "payload": "{\"event\": \"check_health\"}"},
--   {"id": 93, "agent_id": "bot-deploy-01", "state_hash": 12345, "latency_ms": 86.5, "body": "bot-deploy-01 retrying authentication: identity service refused connection (attempt 93)", "ts": "2026-11-11T16:01:33Z", "payload": "{\"event\": \"retry_auth\"}"},
--   {"id": 94, "agent_id": "bot-deploy-01", "state_hash": 67890, "latency_ms": 87.8, "body": "bot-deploy-01 health check completed: all subsystems nominal (cycle 94)", "ts": "2026-11-11T16:01:34Z", "payload": "{\"event\": \"check_health\"}"},
--   {"id": 95, "agent_id": "bot-deploy-01", "state_hash": 12345, "latency_ms": 89.1, "body": "bot-deploy-01 retrying authentication: identity service refused connection (attempt 95)", "ts": "2026-11-11T16:01:35Z", "payload": "{\"event\": \"retry_auth\"}"},
--   {"id": 96, "agent_id": "bot-deploy-01", "state_hash": 67890, "latency_ms": 80.0, "body": "bot-deploy-01 health check completed: all subsystems nominal (cycle 96)", "ts": "2026-11-11T16:01:36Z", "payload": "{\"event\": \"check_health\"}"},
--   {"id": 97, "agent_id": "bot-deploy-02", "state_hash": 11111, "latency_ms": 42.0, "body": "bot-deploy-02 deployed configuration v2.3 successfully", "ts": "2026-11-11T16:01:37Z", "payload": "{\"event\": \"init\"}"},
--   {"id": 98, "agent_id": "bot-deploy-02", "state_hash": 22222, "latency_ms": 45.0, "body": "bot-deploy-02 applied rolling update to worker pool", "ts": "2026-11-11T16:01:38Z", "payload": "{\"event\": \"config\"}"},
--   {"id": 99, "agent_id": "bot-deploy-02", "state_hash": 33333, "latency_ms": 48.0, "body": "bot-deploy-02 deployment finalized, rollout green", "ts": "2026-11-11T16:01:39Z", "payload": "{\"event\": \"deploy\"}"}
-- ]};

SELECT COUNT(*) AS "n_incidents" FROM "aod_incident_logs";

-- The state toggle, one-hot encoded into 2-dimensional directions, as
-- the fingerprint-based loop detector needs it.
-- @fixture aod_wobble_log {"rows": [
--   {"agent_id": "bot-deploy-01", "states": "1.0,0.0,0.0,1.0,1.0,0.0,0.0,1.0,1.0,0.0,0.0,1.0,1.0,0.0,0.0,1.0,1.0,0.0,0.0,1.0,1.0,0.0,0.0,1.0,1.0,0.0,0.0,1.0,1.0,0.0,0.0,1.0,1.0,0.0,0.0,1.0,1.0,0.0,0.0,1.0,1.0,0.0,0.0,1.0,1.0,0.0,0.0,1.0,1.0,0.0,0.0,1.0,1.0,0.0,0.0,1.0,1.0,0.0,0.0,1.0,1.0,0.0,0.0,1.0,1.0,0.0,0.0,1.0,1.0,0.0,0.0,1.0,1.0,0.0,0.0,1.0,1.0,0.0,0.0,1.0,1.0,0.0,0.0,1.0,1.0,0.0,0.0,1.0,1.0,0.0,0.0,1.0,1.0,0.0,0.0,1.0,1.0,0.0,0.0,1.0,1.0,0.0,0.0,1.0,1.0,0.0,0.0,1.0,1.0,0.0,0.0,1.0,1.0,0.0,0.0,1.0,1.0,0.0,0.0,1.0,1.0,0.0,0.0,1.0,1.0,0.0,0.0,1.0,1.0,0.0,0.0,1.0,1.0,0.0,0.0,1.0,1.0,0.0,0.0,1.0,1.0,0.0,0.0,1.0,1.0,0.0,0.0,1.0,1.0,0.0,0.0,1.0,1.0,0.0,0.0,1.0,1.0,0.0,0.0,1.0,1.0,0.0,0.0,1.0,1.0,0.0,0.0,1.0,1.0,0.0,0.0,1.0,1.0,0.0,0.0,1.0,1.0,0.0,0.0,1.0,1.0,0.0,0.0,1.0,1.0,0.0,0.0,1.0,1.0,0.0,0.0,1.0"}
-- ]};

-- ---------------------------------------------------------------------------
-- 2. fractal_agent_detect_loop: the period-2 state toggle.
--
-- The state_hash sequence is a clean 12345 <-> 67890 period-2 toggle,
-- so the one-hot direction toggles cleanly too. Its DFA exponent over
-- the L2-norm trajectory is 0 (a one-hot vector's norm never
-- changes), well below the 0.9 threshold, so the DFA signal alone
-- would NOT flag it -- but the fingerprint-cycle check does.
--
-- The fingerprint stream and the repetition it shows, at the SQL level.
-- ---------------------------------------------------------------------------
-- @fixture aod_incident_states {"rows": [
--   {"cycle": 1, "state": "1.0,0.0"},
--   {"cycle": 2, "state": "0.0,1.0"},
--   {"cycle": 3, "state": "1.0,0.0"},
--   {"cycle": 4, "state": "0.0,1.0"},
--   {"cycle": 5, "state": "1.0,0.0"},
--   {"cycle": 6, "state": "0.0,1.0"},
--   {"cycle": 7, "state": "1.0,0.0"},
--   {"cycle": 8, "state": "0.0,1.0"},
--   {"cycle": 9, "state": "1.0,0.0"},
--   {"cycle": 10, "state": "0.0,1.0"},
--   {"cycle": 11, "state": "1.0,0.0"},
--   {"cycle": 12, "state": "0.0,1.0"},
--   {"cycle": 13, "state": "1.0,0.0"},
--   {"cycle": 14, "state": "0.0,1.0"},
--   {"cycle": 15, "state": "1.0,0.0"},
--   {"cycle": 16, "state": "0.0,1.0"},
--   {"cycle": 17, "state": "1.0,0.0"},
--   {"cycle": 18, "state": "0.0,1.0"},
--   {"cycle": 19, "state": "1.0,0.0"},
--   {"cycle": 20, "state": "0.0,1.0"},
--   {"cycle": 21, "state": "1.0,0.0"},
--   {"cycle": 22, "state": "0.0,1.0"},
--   {"cycle": 23, "state": "1.0,0.0"},
--   {"cycle": 24, "state": "0.0,1.0"},
--   {"cycle": 25, "state": "1.0,0.0"},
--   {"cycle": 26, "state": "0.0,1.0"},
--   {"cycle": 27, "state": "1.0,0.0"},
--   {"cycle": 28, "state": "0.0,1.0"},
--   {"cycle": 29, "state": "1.0,0.0"},
--   {"cycle": 30, "state": "0.0,1.0"},
--   {"cycle": 31, "state": "1.0,0.0"},
--   {"cycle": 32, "state": "0.0,1.0"},
--   {"cycle": 33, "state": "1.0,0.0"},
--   {"cycle": 34, "state": "0.0,1.0"},
--   {"cycle": 35, "state": "1.0,0.0"},
--   {"cycle": 36, "state": "0.0,1.0"},
--   {"cycle": 37, "state": "1.0,0.0"},
--   {"cycle": 38, "state": "0.0,1.0"},
--   {"cycle": 39, "state": "1.0,0.0"},
--   {"cycle": 40, "state": "0.0,1.0"},
--   {"cycle": 41, "state": "1.0,0.0"},
--   {"cycle": 42, "state": "0.0,1.0"},
--   {"cycle": 43, "state": "1.0,0.0"},
--   {"cycle": 44, "state": "0.0,1.0"},
--   {"cycle": 45, "state": "1.0,0.0"},
--   {"cycle": 46, "state": "0.0,1.0"},
--   {"cycle": 47, "state": "1.0,0.0"},
--   {"cycle": 48, "state": "0.0,1.0"},
--   {"cycle": 49, "state": "1.0,0.0"},
--   {"cycle": 50, "state": "0.0,1.0"},
--   {"cycle": 51, "state": "1.0,0.0"},
--   {"cycle": 52, "state": "0.0,1.0"},
--   {"cycle": 53, "state": "1.0,0.0"},
--   {"cycle": 54, "state": "0.0,1.0"},
--   {"cycle": 55, "state": "1.0,0.0"},
--   {"cycle": 56, "state": "0.0,1.0"},
--   {"cycle": 57, "state": "1.0,0.0"},
--   {"cycle": 58, "state": "0.0,1.0"},
--   {"cycle": 59, "state": "1.0,0.0"},
--   {"cycle": 60, "state": "0.0,1.0"},
--   {"cycle": 61, "state": "1.0,0.0"},
--   {"cycle": 62, "state": "0.0,1.0"},
--   {"cycle": 63, "state": "1.0,0.0"},
--   {"cycle": 64, "state": "0.0,1.0"},
--   {"cycle": 65, "state": "1.0,0.0"},
--   {"cycle": 66, "state": "0.0,1.0"},
--   {"cycle": 67, "state": "1.0,0.0"},
--   {"cycle": 68, "state": "0.0,1.0"},
--   {"cycle": 69, "state": "1.0,0.0"},
--   {"cycle": 70, "state": "0.0,1.0"},
--   {"cycle": 71, "state": "1.0,0.0"},
--   {"cycle": 72, "state": "0.0,1.0"},
--   {"cycle": 73, "state": "1.0,0.0"},
--   {"cycle": 74, "state": "0.0,1.0"},
--   {"cycle": 75, "state": "1.0,0.0"},
--   {"cycle": 76, "state": "0.0,1.0"},
--   {"cycle": 77, "state": "1.0,0.0"},
--   {"cycle": 78, "state": "0.0,1.0"},
--   {"cycle": 79, "state": "1.0,0.0"},
--   {"cycle": 80, "state": "0.0,1.0"},
--   {"cycle": 81, "state": "1.0,0.0"},
--   {"cycle": 82, "state": "0.0,1.0"},
--   {"cycle": 83, "state": "1.0,0.0"},
--   {"cycle": 84, "state": "0.0,1.0"},
--   {"cycle": 85, "state": "1.0,0.0"},
--   {"cycle": 86, "state": "0.0,1.0"},
--   {"cycle": 87, "state": "1.0,0.0"},
--   {"cycle": 88, "state": "0.0,1.0"},
--   {"cycle": 89, "state": "1.0,0.0"},
--   {"cycle": 90, "state": "0.0,1.0"},
--   {"cycle": 91, "state": "1.0,0.0"},
--   {"cycle": 92, "state": "0.0,1.0"},
--   {"cycle": 93, "state": "1.0,0.0"},
--   {"cycle": 94, "state": "0.0,1.0"},
--   {"cycle": 95, "state": "1.0,0.0"},
--   {"cycle": 96, "state": "0.0,1.0"}
-- ]};

-- The fingerprint stream, and the repetition it shows: a state that
-- repeats is a loop.
REPLACE INTO aod_fp OVERWRITE ALL
SELECT "cycle", fractal_state_fingerprint("state", 32) AS "fp"
FROM "aod_incident_states"
PARTITIONED BY ALL;

REPLACE INTO aod_repeats OVERWRITE ALL
SELECT a."cycle" AS "cycle", a."fp" AS "fp", COUNT(*) AS "n_same"
FROM "aod_fp" a, "aod_fp" b
WHERE b."fp" = a."fp"
GROUP BY a."cycle", a."fp"
PARTITIONED BY ALL;

SELECT "cycle", "fp", "n_same" FROM "aod_repeats";

-- The shipped agent: the same composition, one call.
--
-- The agent fingerprints each state the same way and streams the
-- fingerprints through the core's cycle detector.
-- ---------------------------------------------------------------------------
-- @call agent/detect_loop {"agent_id": "bot-deploy-01",
--                          "state_log_table": "aod_wobble_log",
--                          "state_log_column": "states", "dim": 2} AS aod_wobble;

SELECT "agent_id", "is_loop_detected", "cycle_length", "n_states", "dfa_exponent"
FROM "aod_wobble";

-- ---------------------------------------------------------------------------
-- 3. fractal_agent_route_task: the nearest capability.
--
-- The task's embedding is nearest the root-cause analyzer's; the
-- confidence is 1/(1+distance).
-- ---------------------------------------------------------------------------
-- @fixture aod_agent_capabilities {"rows": [
--   {"capability_name": "root-cause-analyzer", "embedding": "0.1,0.2,0.3"},
--   {"capability_name": "rollback-executor", "embedding": "0.9,0.8,0.7"}
-- ]};

-- @call agent/route_task {"task_emb": "0.15,0.25,0.35",
--                         "cap_table": "aod_agent_capabilities",
--                         "cap_emb_col": "embedding",
--                         "cap_id_col": "capability_name", "budget": 1000} AS aod_route;

SELECT "routed_to", "confidence", "remaining_budget" FROM "aod_route";

-- ---------------------------------------------------------------------------
-- 4. fractal_agent_outlier_intercept: the proposed state matches a
-- known-bad one.
--
-- The proposed state vector matches state_id 1 exactly, so the change
-- is intercepted.
-- ---------------------------------------------------------------------------
-- @fixture aod_known_bad_states {"rows": [
--   {"state_id": 1, "description": "auth-service unreachable, retry storm", "state_vec": "0.5,0.5,0.5"},
--   {"state_id": 2, "description": "disk pressure cascading restarts", "state_vec": "0.9,0.1,0.2"}
-- ]};

-- @call agent/outlier_intercept {"state_vec": "0.5,0.5,0.5",
--                                "history_table": "aod_known_bad_states",
--                                "emb_col": "state_vec", "threshold": 0.8} AS aod_intercept;

SELECT "intercepted", "metric", "reason" FROM "aod_intercept";

-- ---------------------------------------------------------------------------
-- 5. fractal_agent_anomaly_triage: the drifting latency metric.
--
-- The latency_ms series is a non-degenerate step-up signal with a
-- 32-point recent window, so the drift succeeds -- a 16-point window
-- would be too small for the DFA on the recent window.
-- ---------------------------------------------------------------------------
-- @call agent/anomaly_triage {"log_table": "aod_incident_logs",
--                             "metric_col": "latency_ms", "time_col": "__time",
--                             "filter_col": "agent_id", "filter_val": "bot-deploy-01",
--                             "baseline_window": 32} AS aod_triage;

SELECT "threat_score", "anomaly_type", "triage_summary" FROM "aod_triage";

-- ---------------------------------------------------------------------------
-- 6. fractal_agent_search_agent and fractal_agent_rag_agent: the
-- root-cause synthesis over the incident corpus.
--
-- The corpus is the incident text, embedded by the extension's own
-- embed tier and written into a datasource of its own -- the search
-- agents read a table, and on Druid a table is what an embedding
-- becomes.
-- ---------------------------------------------------------------------------
-- @call embed {"text": "bot-deploy-01 retrying authentication: identity service refused connection (attempt 1)"} AS aod_emb_1;
-- @call embed {"text": "bot-deploy-01 health check completed: all subsystems nominal (cycle 2)"} AS aod_emb_2;
-- @call embed {"text": "bot-deploy-01 retrying authentication: identity service refused connection (attempt 3)"} AS aod_emb_3;
-- @call embed {"text": "bot-deploy-01 health check completed: all subsystems nominal (cycle 4)"} AS aod_emb_4;
-- @call embed {"text": "bot-deploy-01 retrying authentication: identity service refused connection (attempt 5)"} AS aod_emb_5;
-- @call embed {"text": "bot-deploy-01 health check completed: all subsystems nominal (cycle 6)"} AS aod_emb_6;

REPLACE INTO aod_incident_embeddings OVERWRITE ALL
SELECT "embedding" FROM "aod_emb_1"
UNION ALL
SELECT "embedding" FROM "aod_emb_2"
UNION ALL
SELECT "embedding" FROM "aod_emb_3"
UNION ALL
SELECT "embedding" FROM "aod_emb_4"
UNION ALL
SELECT "embedding" FROM "aod_emb_5"
UNION ALL
SELECT "embedding" FROM "aod_emb_6"
PARTITIONED BY ALL;

-- @call agent/search_agent {"query": "Why is bot-deploy-01 looping on auth?",
--                           "table": "aod_incident_embeddings", "col": "embedding",
--                           "population_size": 10, "iterations": 5};

-- @call agent/rag_agent {"query": "What events led to the auth retry loop on bot-deploy-01?",
--                        "table": "aod_incident_embeddings", "col": "embedding"};

-- ---------------------------------------------------------------------------
-- 7. Reasoning: the triage brief.
-- ---------------------------------------------------------------------------
SELECT fractal_reason(
    'one-line triage for this anomaly-detection drift report',
    '{"threat_score":"' || (SELECT CAST("threat_score" AS VARCHAR) FROM "aod_triage")
     || '","anomaly_type":"' || (SELECT CAST("anomaly_type" AS VARCHAR) FROM "aod_triage")
     || '","loop_detected":"' || (SELECT CAST("is_loop_detected" AS VARCHAR) FROM "aod_wobble")
     || '","routed_to":"' || (SELECT CAST("routed_to" AS VARCHAR) FROM "aod_route")
     || '"}') AS "narrative";

-- ---------------------------------------------------------------------------
-- 8. The kit's own headline check.
--
-- The demo contract: a kit prints its headline and exits
-- non-zero unless the result holds. Ninety-nine incidents, the stuck
-- bot's loop detected, the incident routed to the root-cause analyzer,
-- the proposed state intercepted, and the drift triaged.
-- ---------------------------------------------------------------------------
SELECT CASE
           WHEN (SELECT COUNT(*) FROM "aod_incident_logs") = 99
            AND (SELECT COUNT(*) FROM "aod_fp") = 96
            AND (SELECT MAX("n_same") FROM "aod_repeats") = 48
            AND (SELECT "routed_to" FROM "aod_route") = 'root-cause-analyzer'
            AND (SELECT "intercepted" FROM "aod_intercept") = 'true'
            AND (SELECT COUNT(*) FROM "aod_triage") = 1
            THEN 'HEADLINE kit=agentic-ops-devops ok'
            ELSE 'HEADLINE kit=agentic-ops-devops FAILED'
       END AS "headline";
