-- demo/demo-vertical-agentic-customer-support.sql
--
-- FractalSQL for Apache Druid -- industry vertical: agentic customer
-- support. One customer (cust-abc) drifts across four sessions from
-- onboarding toward churn; a playbook of past churn-recovery cases
-- says what worked for others; and a catalogue of retention offers is
-- the menu the agent picks from.
--
--   1. The session telemetry: four states on a churn drift.
--   2. fractal_agent_trajectory_predict: where the drift is heading.
--   3. The hybrid cohort recall over the playbook (the shipped
--      agent, fractal_agent_recall_hybrid, and the search it wraps).
--   4. Scout over the session states: a spread, not a cluster.
--   5. fractal_agent_recommend_diverse: a spread of retention offers.
--   6. A closing fractal_reason() writes the retention brief.
--
-- Prerequisites: the extension is loaded on the Druid cluster. The
-- agents' rationales and the closing narrative need a reasoning
-- provider (docs/reasoning-setup.md); every other step runs with no
-- model.
--
-- Run:
--   python3 demo/run_demo.py --file demo/demo-vertical-agentic-customer-support.sql
--
-- ===========================================================================
-- Notes on how this runs on Druid
-- ===========================================================================
--
--   * The three tables are @fixture directives: Druid has no DDL and no
--     VALUES, so a set of rows has no SQL form. The "last interaction" column is a fixed date rather than relative to now, so the run is reproducible.
--   * The searches and the agents are service calls. An agent reads a
--     table and reasons about it, so the call names
--     the table and the columns, and its result lands in a datasource
--     the later SQL can join against.
--   * fractal_agent_trajectory_predict's baseline_id has no Druid
--     counterpart: the agent derives the velocity from the two
--     most recent states of the session stream and carries the
--     baseline id through as the decision's subject. The predicted
--     state is therefore the projection of the drift, not a replay of
--     a baseline.
--   * The session-global fractal_diversify_enable() is not available: on
--     Druid the diversify flag is a node-level setting, not a
--     per-session one, so a kit that flipped it would change every
--     other query on the shared node. The Scout step below carries the
--     diversification in its own parameters instead.
--
-- Notes:
--   * Fully deterministic fixtures (no random()).

-- ---------------------------------------------------------------------------
-- 0. Sanity check: extension loaded?
-- ---------------------------------------------------------------------------
SELECT fractal_edition(), fractal_version();

-- ---------------------------------------------------------------------------
-- 1. The customer session telemetry: four states on a churn drift.
--
-- The state vector is the customer's three-feature state; the sentiment
-- falls and the first feature climbs as the customer drifts.
-- ---------------------------------------------------------------------------
-- @fixture acs_sessions {"rows": [
--   {"session_id": 100, "customer_id": "cust-abc", "state_vector": "0.1,0.1,0.1", "sentiment_score": 0.8, "last_interaction": "2026-10-12"},
--   {"session_id": 101, "customer_id": "cust-abc", "state_vector": "0.3,0.15,0.1", "sentiment_score": 0.6, "last_interaction": "2026-10-22"},
--   {"session_id": 102, "customer_id": "cust-abc", "state_vector": "0.6,0.2,0.1", "sentiment_score": 0.4, "last_interaction": "2026-11-01"},
--   {"session_id": 103, "customer_id": "cust-abc", "state_vector": "0.8,0.2,0.1", "sentiment_score": 0.2, "last_interaction": "2026-11-11"}
-- ]};

SELECT "session_id", "customer_id", "state_vector", "sentiment_score", "last_interaction"
FROM "acs_sessions";

-- ---------------------------------------------------------------------------
-- 2. fractal_agent_trajectory_predict: where the drift is heading.
--
-- The agent reads the session stream, takes the velocity between the
-- two most recent states, and projects it forward.
-- ---------------------------------------------------------------------------
-- @call agent/trajectory_predict {"table": "acs_sessions", "col": "state_vector",
--                                 "id": "100", "steps": 5} AS acs_forecast;

SELECT "id", "current", "velocity", "predicted", "steps" FROM "acs_forecast";

-- ---------------------------------------------------------------------------
-- 3. The hybrid cohort recall over the playbook.
--
-- The playbook holds what worked (or did not) for other customers whose
-- state, at the point of intervention, looked like this one. The cohort
-- is the playbook itself, and the query is this customer's current
-- drifting state.
--
-- First the search the agent wraps: a cohort-restricted nearest-rows
-- search over the playbook.
-- ---------------------------------------------------------------------------
-- @fixture acs_playbook {"rows": [
--   {"case_id": 1, "customer_id": "cust-def", "state_vector": "0.75,0.22,0.12", "resolution": "Escalated to a retention specialist with a loyalty discount; saved"},
--   {"case_id": 2, "customer_id": "cust-ghi", "state_vector": "0.30,0.10,0.05", "resolution": "Proactive check-in call resolved early-stage frustration"},
--   {"case_id": 3, "customer_id": "cust-jkl", "state_vector": "0.82,0.18,0.09", "resolution": "Offered a downgrade path instead of cancellation; saved"},
--   {"case_id": 4, "customer_id": "cust-mno", "state_vector": "0.05,0.05,0.05", "resolution": "No intervention needed, healthy customer"}
-- ]};

-- @call search/hybrid {"table": "acs_playbook", "column": "state_vector",
--                      "id_column": "case_id", "query": "0.8,0.2,0.1",
--                      "docIds": [1, 2, 3, 4], "k": 5} AS acs_hybrid;

SELECT h."doc_id" AS "case_id", p."resolution" AS "resolution",
       ROUND(h."distance", 4) AS "distance"
FROM "acs_hybrid" h, "acs_playbook" p
WHERE h."doc_id" = p."case_id";

-- Then the shipped agent: the same composition, one call.
-- ---------------------------------------------------------------------------
-- @call agent/recall_hybrid {"mem_table": "acs_playbook", "vec_col": "state_vector",
--                            "query_vec": "0.8,0.2,0.1", "id_col": "case_id",
--                            "k": 5} AS acs_recall;

SELECT r."doc_id" AS "case_id", p."resolution" AS "resolution",
       ROUND(r."distance", 4) AS "distance"
FROM "acs_recall" r, "acs_playbook" p
WHERE r."doc_id" = p."case_id";

-- ---------------------------------------------------------------------------
-- 4. Scout over the session states: a spread, not a cluster.
--
-- The five particles the search returns are matched back to the session
-- states they came from, so the picks are queryable.
-- ---------------------------------------------------------------------------
-- @call search/explore {"datasource": "acs_sessions", "vectorColumn": "state_vector",
--                      "idColumn": "session_id", "query": "0.8,0.2,0.1", "k": 5,
--                      "params": "{\"population_size\": 5, \"iterations\": 8}"} AS acs_scout;

SELECT s."ord" AS "ord", e."session_id" AS "session_id", e."sentiment_score" AS "sentiment"
FROM "acs_scout" s, "acs_sessions" e
WHERE s."doc_id" = e."session_id";

-- ---------------------------------------------------------------------------
-- 5. fractal_agent_recommend_diverse: a spread of retention offers.
--
-- The nearest offers first (the plain telemetry search the agent
-- diversifies), then the agent's own diverse set.
-- ---------------------------------------------------------------------------
-- @fixture acs_catalog {"rows": [
--   {"item_id": 1, "name": "Loyalty Discount 20%", "emb": "0.80,0.20,0.10"},
--   {"item_id": 2, "name": "Free Premium Upgrade", "emb": "0.75,0.25,0.15"},
--   {"item_id": 3, "name": "Dedicated Support Line", "emb": "0.60,0.30,0.20"},
--   {"item_id": 4, "name": "Downgrade to Basic Plan", "emb": "0.40,0.10,0.05"},
--   {"item_id": 5, "name": "Early Renewal Bonus", "emb": "0.20,0.10,0.10"}
-- ]};

-- @call search/telemetry {"table": "acs_catalog", "vectorColumn": "emb",
--                         "idColumn": "item_id", "query": "0.8,0.2,0.1", "k": 5} AS acs_near;

SELECT n."doc_id" AS "item_id", c."name" AS "name",
       ROUND(1.0 - n."distance", 4) AS "score"
FROM "acs_near" n, "acs_catalog" c
WHERE n."doc_id" = c."item_id";

-- @call agent/recommend_diverse {"catalog_table": "acs_catalog", "emb_col": "emb",
--                                "query_vec": "0.8,0.2,0.1", "k": 5,
--                                "id_col": "item_id"} AS acs_rec;

SELECT r."item_id" AS "item_id", c."name" AS "name", ROUND(r."score", 4) AS "score"
FROM "acs_rec" r, "acs_catalog" c
WHERE r."item_id" = c."item_id";

-- ---------------------------------------------------------------------------
-- 6. Reasoning: the retention brief.
-- ---------------------------------------------------------------------------
SELECT fractal_reason(
    'one-line retention brief for this churning customer: the projected drift, the past case to copy, and the offer to lead with',
    '{"sessions":"' || (SELECT ARRAY_TO_STRING(ARRAY_AGG(CAST("session_id" AS VARCHAR), 8192), ',')
                            FROM "acs_sessions")
     || '","recalled_cases":"' || (SELECT ARRAY_TO_STRING(ARRAY_AGG(CAST("doc_id" AS VARCHAR), 8192), ',')
                                  FROM "acs_recall")
     || '","offers":"' || (SELECT ARRAY_TO_STRING(ARRAY_AGG(CAST("name" AS VARCHAR), 8192), ',')
                           FROM "acs_rec" r, "acs_catalog" c WHERE r."item_id" = c."item_id")
     || '"}') AS "narrative";

-- ---------------------------------------------------------------------------
-- 7. The kit's own headline check.
--
-- The demo contract: a kit prints its headline and exits
-- non-zero unless the result holds. Four sessions, a forecast over the
-- stream, the whole playbook recalled with the closest case first, and
-- all five retention offers recommended.
-- ---------------------------------------------------------------------------
SELECT CASE
           WHEN (SELECT COUNT(*) FROM "acs_sessions") = 4
            AND (SELECT COUNT(*) FROM "acs_forecast") = 1
            AND (SELECT COUNT(*) FROM "acs_recall") = 4
            AND (SELECT COUNT(*) FROM "acs_recall" WHERE "doc_id" = 3) = 1
            AND (SELECT COUNT(*) FROM "acs_rec") = 5
            THEN 'HEADLINE kit=agentic-customer-support ok'
            ELSE 'HEADLINE kit=agentic-customer-support FAILED'
       END AS "headline";
