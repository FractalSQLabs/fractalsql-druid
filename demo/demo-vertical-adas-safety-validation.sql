-- demo/demo-vertical-adas-safety-validation.sql
--
-- FractalSQL for Apache Druid -- industry vertical: ADAS safety
-- validation. A history of known-bad maneuvers and a set of proposed
-- ones: each proposal is screened against the history, and the
-- routing deviation from the fleet baseline is the second signal. The
-- closing verdict reads both.
--
--   1. Known-bad history + proposed maneuvers.
--   2. The screen: the nearest known-bad scenario per proposal.
--   3. fractal_agent_outlier_intercept: the same screen, as an agent.
--   4. The routing deviation from the fleet baseline.
--   5. Reasoning: one go / no-go verdict over both signals.
--
-- Prerequisites: the extension is loaded on the Druid cluster. The
-- narrative and the agent's rationale need a reasoning provider
-- (docs/reasoning-setup.md); every other step runs with no model.
--
-- Run:
--   python3 demo/run_demo.py --file demo/demo-vertical-adas-safety-validation.sql
--
-- ===========================================================================
-- Notes on how this runs on Druid
-- ===========================================================================
--
--   * The fixtures are @fixture directives and one MSQ write: Druid has
--     no DDL, no VALUES and no recursive CTE.
--   * The screens and the searches are service calls: an agent reads a
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
-- 1. Known-bad history + proposed maneuvers.
-- ---------------------------------------------------------------------------
-- @fixture asv_known_bad {"rows": [
--   {"id": 1, "scenario": "hard brake at highway speed", "state": "0.90,0.10,0.95,0.10"},
--   {"id": 2, "scenario": "evasive swerve", "state": "0.50,0.90,0.20,0.95"},
--   {"id": 3, "scenario": "late brake approaching a stop", "state": "0.40,0.05,0.90,0.05"},
--   {"id": 4, "scenario": "lane drift under load", "state": "0.70,0.60,0.05,0.30"}
-- ]};

-- @fixture asv_proposed {"rows": [
--   {"id": 1, "label": "P1 firm brake, high speed", "state": "0.88,0.12,0.90,0.15"},
--   {"id": 2, "label": "P2 steady cruise", "state": "0.55,0.02,0.02,0.01"},
--   {"id": 3, "label": "P3 gentle lane change", "state": "0.45,0.35,0.05,0.30"}
-- ]};

-- ---------------------------------------------------------------------------
-- 2. The screen: the nearest known-bad scenario per proposal.
--
-- confidence = 1/(1+distance); a proposal is intercepted when it sits
-- within 0.15 of a known-bad scenario.
-- ---------------------------------------------------------------------------
-- @call agent/outlier_screen {"proposed_table": "asv_proposed", "state_column": "state",
--                            "id_column": "id", "label_column": "label",
--                            "history_table": "asv_known_bad", "emb_column": "state",
--                            "threshold": 0.15, "metric": "cosine"} AS asv_screen;

SELECT p."label" AS "label", k."scenario" AS "nearest_bad",
       ROUND(s."distance", 4) AS "distance",
       (s."distance" < 0.15) AS "intercepted"
FROM "asv_screen" s, "asv_proposed" p, "asv_known_bad" k
WHERE s."id" = p."id" AND s."doc_id" = k."id";

-- ---------------------------------------------------------------------------
-- 3. fractal_agent_outlier_intercept: the same screen, as an agent.
--
-- The same check under exact Euclidean distance (magnitude counts).
-- ---------------------------------------------------------------------------
-- @call agent/outlier_screen {"proposed_table": "asv_proposed", "state_column": "state",
--                            "id_column": "id", "label_column": "label",
--                            "history_table": "asv_known_bad", "emb_column": "state",
--                            "threshold": 0.15, "metric": "cosine"} AS asv_verdict;

-- @call agent/outlier_screen {"proposed_table": "asv_proposed", "state_column": "state",
--                            "id_column": "id", "label_column": "label",
--                            "history_table": "asv_known_bad", "emb_column": "state",
--                            "threshold": 0.3, "metric": "l2"} AS asv_screen_l2;

SELECT p."label" AS "label", s."intercepted" AS "intercepted_l2"
FROM "asv_screen_l2" s, "asv_proposed" p
WHERE s."id" = p."id";

-- ---------------------------------------------------------------------------
-- 4. The routing deviation from the fleet baseline.
--
-- Forty fleet vehicles on three lane/speed bands; vehicle V-17's
-- routing vector (lateral offset, heading, speed) is compared against
-- the fleet baseline.
-- ---------------------------------------------------------------------------
REPLACE INTO asv_routes OVERWRITE ALL
SELECT "id", "vehicle", "route"
FROM (
    SELECT g AS "id",
           'V-' || CAST(g AS VARCHAR) AS "vehicle",
           CAST(0.10 * MOD(g, 3) + 0.01 * MOD(g, 7) AS VARCHAR) || ','
           || CAST(0.05 * MOD(g, 4) AS VARCHAR) || ','
           || CAST(0.60 + 0.05 * MOD(g, 3) + 0.004 * MOD(g, 5) AS VARCHAR) AS "route"
    FROM UNNEST(ARRAY[
        1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16, 17, 18, 19, 20,
        21, 22, 23, 24, 25, 26, 27, 28, 29, 30, 31, 32, 33, 34, 35, 36, 37, 38, 39, 40]) AS t(g)
) s
PARTITIONED BY ALL;

-- @call search/trajectory {"table": "asv_routes", "column": "route", "id_column": "id",
--                         "baseline": "0.100,0.050,0.650",
--                         "current": "0.900,0.800,0.200",
--                         "k": 3} AS asv_traj;

SELECT v."vehicle" AS "vehicle", ROUND(r."distance", 4) AS "distance"
FROM "asv_traj" r, "asv_routes" v
WHERE r."doc_id" = v."id";

-- ---------------------------------------------------------------------------
-- 5. Reasoning: one go / no-go verdict over both signals.
-- ---------------------------------------------------------------------------
SELECT fractal_reason(
    'one-line go/no-go safety verdict for this proposed ADAS maneuver',
    '{"intercept":"' || (SELECT ARRAY_TO_STRING(ARRAY_AGG(CAST("intercepted" AS VARCHAR), 8192), ',')
                         FROM "asv_screen" WHERE "id" = 1)
     || '","routing_deviation":"' || (SELECT ARRAY_TO_STRING(ARRAY_AGG(CAST("distance" AS VARCHAR), 8192), ',')
                                    FROM "asv_traj")
     || '"}') AS "narrative";

-- ---------------------------------------------------------------------------
-- The headline.
--
-- The kit passes when all three proposals were screened and the screen
-- caught the two aggressive maneuvers -- the firm brake and the lane
-- change -- while letting the steady cruise through. That split IS the
-- finding.
-- ---------------------------------------------------------------------------
SELECT CASE
           WHEN (SELECT COUNT(*) FROM "asv_proposed") = 3
            AND (SELECT COUNT(*) FROM "asv_screen" s, "asv_proposed" p
                 WHERE s."id" = p."id" AND s."distance" < 0.15) = 2
            THEN 'HEADLINE kit=adas-safety-validation ok'
            ELSE 'HEADLINE kit=adas-safety-validation FAILED'
       END AS "headline";
