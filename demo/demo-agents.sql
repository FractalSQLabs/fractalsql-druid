-- demo/demo-agents.sql
--
-- FractalSQL for Apache Druid -- the agent tier.
--
-- Every agent the extension ships, demonstrated on Druid. An agent here
-- is a SERVICE call: it reads a table, computes the analytic through the
-- same core the SQL functions call, and reasons about the result. The
-- composition shown as an inline blueprint is ordinary SQL (a corpus search is a service call too),
-- and the shipped agent is the one call that does the whole job.
--
--   1. anomaly_triage: the drift exponent over a metric series.
--   2. allocate: a cardinality-constrained allocation.
--   3. route_task: the capability nearest an incoming task.
--   4. outlier_intercept: a state screened against known-bad states.
--   5. recall_hybrid: a cohort-restricted vector recall.
--   6. recommend_diverse: a diversified top-k.
--   7. data_analyst: a natural-language question answered with SQL.
--   8. patient_deterioration_triage: a cohort's nearest patient.
--   9. schedule_workload: a refined task matched to a node.
--  10. rebalance_sibling: an allocation and the stored one it resembles.
--  11. detour_classify: a fleet detour and its GPS trace.
--  12. track_anomaly: a track deviation and its heading exponent.
--  13. network_coverage_alert: a sensor grid's morphology and drift.
--  14. The universal agents: trajectory_predict, detect_loop and
--      plan_explore -- and the outlier screen, the table-driven form
--      of the interceptor.
--
-- Prerequisites: the extension is loaded on the Druid cluster. The
-- agents' rationales need a reasoning provider (docs/reasoning-setup.md);
-- every other step runs with no model.
--
-- Run:
--   python3 demo/run_demo.py --file demo/demo-agents.sql
--
-- ===========================================================================
-- Notes on how this runs on Druid
-- ===========================================================================
--
--   * The agents are service calls, not SQL functions. An agent reads a
--     table and reasons about it, and a Druid SQL function can do
--     neither: it has no connection to issue its own query, and a query
--     thread must not be held for the length of a model round trip. So
--     each agent is `-- @call agent/<name> {...}`, and the argument
--     that would be a computed expression is passed as a table +
--     column pair (or as the text the agent reads out of a datasource).
--   * The fixtures are @fixture directives and MSQ writes: Druid has no
--     DDL, no VALUES and no recursive CTE. The metric series is a fixture, and random values are the deterministic sin-hash the other kits use.
--   * The corpus searches are service calls as well
--     (`-- @call search/telemetry`, `-- @call search/explore`): the
--     SFS converges over a whole column, which a Druid aggregate cannot
--     hold.
--   * The box count over the sensor grid is a service operation
--     (`-- @call boxcount`): it is a count over a whole cloud of points,
--     and as an expression it would run once per row.
--
-- Further agents, and how the kit carries them:
--
--   * fractal_agent_feedback_audit, fractal_agent_regime_triage and
--     the self-correcting fractal_sql_agent are agents, in sections 15, 17 and 19.
--   * fractal_agent_diverse_portfolios is an agent too, and it is enterprise-gated: its
--     core symbols are not in the community archive, so it needs the
--     licensed core. This cluster has one installed, which is why
--     section 18 runs.
--
-- Two further agents, and how this kit treats them:
--
--   * fractal_agent_outlier_screen -- the table-driven form of the
--     interceptor -- is demonstrated in section 16.
--   * fractal_agent_search_agent and fractal_agent_rag_agent embed the
--     QUESTION and then search a corpus, so the corpus has to be in the
--     embedding model's own dimension. This kit's catalogue is in three
--     dimensions, so the two agents are not demonstrated here: the
--     plan_explore agent shows the same core search over the
--     catalogue's own vectors.
--
-- Notes:
--   * Fully deterministic fixtures (no random()).
--   * Ends with a HEADLINE line computed from the kit's own results
--     (HEADLINE kit=demo-agents ok); the build_test kit gate greps for
--     it.

-- ---------------------------------------------------------------------------
-- 0. Surface check: base + agent tier.
-- ---------------------------------------------------------------------------
SELECT fractal_edition(), fractal_version();

-- ---------------------------------------------------------------------------
-- 1. A drifting metric series for one host, and a second host.
--
-- A baseline around 50 for the first 48 samples and then a +30 step-up,
-- 96 points, so the drift call's 32-point recent window has a real
-- regime change to detect. The series is carried twice: once as the
-- per-sample rows the agent reads, and once as the ordered text the SQL
-- composition reads -- Druid has no window function and no ordered
-- aggregate, so the order is carried in the fixture.
-- ---------------------------------------------------------------------------
-- @fixture ag_logs {"rows": [
--   {"id": 1, "seq": 1, "host": "host-1", "metric": 51.3},
--   {"id": 2, "seq": 2, "host": "host-1", "metric": 52.6},
--   {"id": 3, "seq": 3, "host": "host-1", "metric": 53.9},
--   {"id": 4, "seq": 4, "host": "host-1", "metric": 55.2},
--   {"id": 5, "seq": 5, "host": "host-1", "metric": 56.5},
--   {"id": 6, "seq": 6, "host": "host-1", "metric": 57.8},
--   {"id": 7, "seq": 7, "host": "host-1", "metric": 59.1},
--   {"id": 8, "seq": 8, "host": "host-1", "metric": 50.0},
--   {"id": 9, "seq": 9, "host": "host-1", "metric": 51.3},
--   {"id": 10, "seq": 10, "host": "host-1", "metric": 52.6},
--   {"id": 11, "seq": 11, "host": "host-1", "metric": 53.9},
--   {"id": 12, "seq": 12, "host": "host-1", "metric": 55.2},
--   {"id": 13, "seq": 13, "host": "host-1", "metric": 56.5},
--   {"id": 14, "seq": 14, "host": "host-1", "metric": 57.8},
--   {"id": 15, "seq": 15, "host": "host-1", "metric": 59.1},
--   {"id": 16, "seq": 16, "host": "host-1", "metric": 50.0},
--   {"id": 17, "seq": 17, "host": "host-1", "metric": 51.3},
--   {"id": 18, "seq": 18, "host": "host-1", "metric": 52.6},
--   {"id": 19, "seq": 19, "host": "host-1", "metric": 53.9},
--   {"id": 20, "seq": 20, "host": "host-1", "metric": 55.2},
--   {"id": 21, "seq": 21, "host": "host-1", "metric": 56.5},
--   {"id": 22, "seq": 22, "host": "host-1", "metric": 57.8},
--   {"id": 23, "seq": 23, "host": "host-1", "metric": 59.1},
--   {"id": 24, "seq": 24, "host": "host-1", "metric": 50.0},
--   {"id": 25, "seq": 25, "host": "host-1", "metric": 51.3},
--   {"id": 26, "seq": 26, "host": "host-1", "metric": 52.6},
--   {"id": 27, "seq": 27, "host": "host-1", "metric": 53.9},
--   {"id": 28, "seq": 28, "host": "host-1", "metric": 55.2},
--   {"id": 29, "seq": 29, "host": "host-1", "metric": 56.5},
--   {"id": 30, "seq": 30, "host": "host-1", "metric": 57.8},
--   {"id": 31, "seq": 31, "host": "host-1", "metric": 59.1},
--   {"id": 32, "seq": 32, "host": "host-1", "metric": 50.0},
--   {"id": 33, "seq": 33, "host": "host-1", "metric": 51.3},
--   {"id": 34, "seq": 34, "host": "host-1", "metric": 52.6},
--   {"id": 35, "seq": 35, "host": "host-1", "metric": 53.9},
--   {"id": 36, "seq": 36, "host": "host-1", "metric": 55.2},
--   {"id": 37, "seq": 37, "host": "host-1", "metric": 56.5},
--   {"id": 38, "seq": 38, "host": "host-1", "metric": 57.8},
--   {"id": 39, "seq": 39, "host": "host-1", "metric": 59.1},
--   {"id": 40, "seq": 40, "host": "host-1", "metric": 50.0},
--   {"id": 41, "seq": 41, "host": "host-1", "metric": 51.3},
--   {"id": 42, "seq": 42, "host": "host-1", "metric": 52.6},
--   {"id": 43, "seq": 43, "host": "host-1", "metric": 53.9},
--   {"id": 44, "seq": 44, "host": "host-1", "metric": 55.2},
--   {"id": 45, "seq": 45, "host": "host-1", "metric": 56.5},
--   {"id": 46, "seq": 46, "host": "host-1", "metric": 57.8},
--   {"id": 47, "seq": 47, "host": "host-1", "metric": 59.1},
--   {"id": 48, "seq": 48, "host": "host-1", "metric": 50.0},
--   {"id": 49, "seq": 49, "host": "host-1", "metric": 81.3},
--   {"id": 50, "seq": 50, "host": "host-1", "metric": 82.6},
--   {"id": 51, "seq": 51, "host": "host-1", "metric": 83.9},
--   {"id": 52, "seq": 52, "host": "host-1", "metric": 85.2},
--   {"id": 53, "seq": 53, "host": "host-1", "metric": 86.5},
--   {"id": 54, "seq": 54, "host": "host-1", "metric": 87.8},
--   {"id": 55, "seq": 55, "host": "host-1", "metric": 89.1},
--   {"id": 56, "seq": 56, "host": "host-1", "metric": 80.0},
--   {"id": 57, "seq": 57, "host": "host-1", "metric": 81.3},
--   {"id": 58, "seq": 58, "host": "host-1", "metric": 82.6},
--   {"id": 59, "seq": 59, "host": "host-1", "metric": 83.9},
--   {"id": 60, "seq": 60, "host": "host-1", "metric": 85.2},
--   {"id": 61, "seq": 61, "host": "host-1", "metric": 86.5},
--   {"id": 62, "seq": 62, "host": "host-1", "metric": 87.8},
--   {"id": 63, "seq": 63, "host": "host-1", "metric": 89.1},
--   {"id": 64, "seq": 64, "host": "host-1", "metric": 80.0},
--   {"id": 65, "seq": 65, "host": "host-1", "metric": 81.3},
--   {"id": 66, "seq": 66, "host": "host-1", "metric": 82.6},
--   {"id": 67, "seq": 67, "host": "host-1", "metric": 83.9},
--   {"id": 68, "seq": 68, "host": "host-1", "metric": 85.2},
--   {"id": 69, "seq": 69, "host": "host-1", "metric": 86.5},
--   {"id": 70, "seq": 70, "host": "host-1", "metric": 87.8},
--   {"id": 71, "seq": 71, "host": "host-1", "metric": 89.1},
--   {"id": 72, "seq": 72, "host": "host-1", "metric": 80.0},
--   {"id": 73, "seq": 73, "host": "host-1", "metric": 81.3},
--   {"id": 74, "seq": 74, "host": "host-1", "metric": 82.6},
--   {"id": 75, "seq": 75, "host": "host-1", "metric": 83.9},
--   {"id": 76, "seq": 76, "host": "host-1", "metric": 85.2},
--   {"id": 77, "seq": 77, "host": "host-1", "metric": 86.5},
--   {"id": 78, "seq": 78, "host": "host-1", "metric": 87.8},
--   {"id": 79, "seq": 79, "host": "host-1", "metric": 89.1},
--   {"id": 80, "seq": 80, "host": "host-1", "metric": 80.0},
--   {"id": 81, "seq": 81, "host": "host-1", "metric": 81.3},
--   {"id": 82, "seq": 82, "host": "host-1", "metric": 82.6},
--   {"id": 83, "seq": 83, "host": "host-1", "metric": 83.9},
--   {"id": 84, "seq": 84, "host": "host-1", "metric": 85.2},
--   {"id": 85, "seq": 85, "host": "host-1", "metric": 86.5},
--   {"id": 86, "seq": 86, "host": "host-1", "metric": 87.8},
--   {"id": 87, "seq": 87, "host": "host-1", "metric": 89.1},
--   {"id": 88, "seq": 88, "host": "host-1", "metric": 80.0},
--   {"id": 89, "seq": 89, "host": "host-1", "metric": 81.3},
--   {"id": 90, "seq": 90, "host": "host-1", "metric": 82.6},
--   {"id": 91, "seq": 91, "host": "host-1", "metric": 83.9},
--   {"id": 92, "seq": 92, "host": "host-1", "metric": 85.2},
--   {"id": 93, "seq": 93, "host": "host-1", "metric": 86.5},
--   {"id": 94, "seq": 94, "host": "host-1", "metric": 87.8},
--   {"id": 95, "seq": 95, "host": "host-1", "metric": 89.1},
--   {"id": 96, "seq": 96, "host": "host-1", "metric": 80.0},
--   {"id": 97, "seq": 97, "host": "host-2", "metric": 10.0},
--   {"id": 98, "seq": 98, "host": "host-2", "metric": 11.0}
-- ]};

-- @fixture ag_series {"rows": [
--   {"host": "host-1", "series": "51.3000,52.6000,53.9000,55.2000,56.5000,57.8000,59.1000,50.0000,51.3000,52.6000,53.9000,55.2000,56.5000,57.8000,59.1000,50.0000,51.3000,52.6000,53.9000,55.2000,56.5000,57.8000,59.1000,50.0000,51.3000,52.6000,53.9000,55.2000,56.5000,57.8000,59.1000,50.0000,51.3000,52.6000,53.9000,55.2000,56.5000,57.8000,59.1000,50.0000,51.3000,52.6000,53.9000,55.2000,56.5000,57.8000,59.1000,50.0000,81.3000,82.6000,83.9000,85.2000,86.5000,87.8000,89.1000,80.0000,81.3000,82.6000,83.9000,85.2000,86.5000,87.8000,89.1000,80.0000,81.3000,82.6000,83.9000,85.2000,86.5000,87.8000,89.1000,80.0000,81.3000,82.6000,83.9000,85.2000,86.5000,87.8000,89.1000,80.0000,81.3000,82.6000,83.9000,85.2000,86.5000,87.8000,89.1000,80.0000,81.3000,82.6000,83.9000,85.2000,86.5000,87.8000,89.1000,80.0000"},
--   {"host": "host-2", "series": "10.0000,11.0000"}
-- ]};

-- ---------------------------------------------------------------------------
-- 2. anomaly_triage: the drift exponent over host-1's series.
--
-- The composition: the drift document, and the three numbers read out
-- of it. threat_score is the real drift result, not a literal.
-- ---------------------------------------------------------------------------
REPLACE INTO ag_drift OVERWRITE ALL
SELECT fractal_dimension_drift("series", 32) AS "d"
FROM "ag_series" WHERE "host" = 'host-1'
PARTITIONED BY ALL;

SELECT fractal_json_value("d", '$.drift') AS "threat_score",
       fractal_json_value("d", '$.recent_alpha') AS "recent_alpha",
       fractal_json_value("d", '$.baseline_alpha') AS "baseline_alpha"
FROM "ag_drift" GROUP BY "d";

-- The shipped agent: the same composition, one call.
-- @call agent/anomaly_triage {"log_table": "ag_logs", "metric_col": "metric",
--                             "time_col": "seq", "filter_col": "host",
--                             "filter_val": "host-1", "baseline_window": 32} AS ag_triage;

SELECT "threat_score" AS "threat_score", "anomaly_type" AS "anomaly_type"
FROM "ag_triage";

-- ---------------------------------------------------------------------------
-- 3. allocate: a cardinality-constrained allocation.
--
-- Two assets, an identity covariance, cardinality 1. The optimizer's
-- own document holds the Sharpe ratio and the weights.
-- ---------------------------------------------------------------------------
-- @fixture ag_portfolio {"rows": [
--   {"mu": "0.05,0.1", "cov": "1,0,0,1"}
-- ]};

REPLACE INTO ag_opt OVERWRITE ALL
SELECT fractal_optimize_portfolio("mu", "cov", 1) AS "rj"
FROM "ag_portfolio"
PARTITIONED BY ALL;

SELECT fractal_json_value("rj", '$.sharpe') AS "sharpe",
       fractal_json_text("rj", '$.weights') AS "weights"
FROM "ag_opt" GROUP BY "rj";

-- The shipped agent: optimizer + reasoned rationale, one call.
-- @call agent/allocate {"mu_table": "ag_portfolio", "mu_column": "mu",
--                      "cov_table": "ag_portfolio", "cov_column": "cov",
--                      "cardinality": 1} AS ag_alloc_result;

SELECT "sharpe" AS "sharpe" FROM "ag_alloc_result";

-- ---------------------------------------------------------------------------
-- 4. route_task: the capability nearest the incoming task.
--
-- The composition: the corpus search (a service call -- the SFS
-- converges over a whole column) and the confidence it implies.
-- ---------------------------------------------------------------------------
-- @fixture ag_caps {"rows": [
--   {"id": 1, "capability_name": "root-cause-analyzer", "emb": "0.1,0.2,0.3"},
--   {"id": 2, "capability_name": "capacity-autoscaler", "emb": "0.9,0.8,0.7"},
--   {"id": 3, "capability_name": "incident-pager", "emb": "0.3,0.3,0.9"}
-- ]};

-- @call search/telemetry {"datasource": "ag_caps", "vectorColumn": "emb",
--                         "idColumn": "id", "query": "0.11,0.21,0.31",
--                         "k": 1} AS ag_near;

SELECT c."capability_name" AS "routed_to",
       1.0 / (1.0 + r."distance") AS "confidence"
FROM "ag_near" r, "ag_caps" c
WHERE r."doc_id" = c."id";

-- The shipped agent: the same composition, one call.
-- @call agent/route_task {"task_emb": "0.11,0.21,0.31", "cap_table": "ag_caps",
--                        "cap_emb_col": "emb", "cap_id_col": "capability_name",
--                        "budget": 1000} AS ag_route;

SELECT "routed_to" AS "routed_to", "confidence" AS "confidence",
       "remaining_budget" AS "remaining_budget"
FROM "ag_route";

-- ---------------------------------------------------------------------------
-- 5. outlier_intercept: a state screened against the known-bad states.
--
-- The composition: the nearest known-bad state under the cosine
-- distance, and the threshold comparison. The metric is named, so a
-- far probe really is far: the vectors below point in different
-- directions, and the cosine distance ignores magnitude.
--
-- The shipped agent defaults to the cosine distance. Passing
-- "metric": "l2" gives the exact Euclidean distance, where magnitude
-- does count: [0.05,0,0] sits 0.856 away from the bad state [0.9,0.1,0]
-- and is allowed under the same threshold.
-- ---------------------------------------------------------------------------
-- @fixture ag_badstates {"rows": [
--   {"id": 1, "emb": "1.0,0.0,0.0"},
--   {"id": 2, "emb": "0.9,0.1,0.0"}
-- ]};

-- The proposed actions the screen checks, one of them near a bad state
-- and one of them pointing away from every bad state.
-- @fixture ag_proposed {"rows": [
--   {"id": 1, "label": "restart-the-node", "state": "0.95,0.05,0.0"},
--   {"id": 2, "label": "scale-out", "state": "0.0,1.0,0.0"}
-- ]};

-- @call search/telemetry {"datasource": "ag_badstates", "vectorColumn": "emb",
--                         "idColumn": "id", "query": "0.95,0.05,0.0",
--                         "k": 1} AS ag_bad_near;

SELECT ("distance" < 0.5) AS "intercepted", "distance" AS "distance"
FROM "ag_bad_near";

-- The same check under exact Euclidean distance, where magnitude counts.
REPLACE INTO ag_l2 OVERWRITE ALL
SELECT MIN(fractal_vector_l2_distance("emb", '0.05,0.0,0.0')) AS "d"
FROM "ag_badstates"
PARTITIONED BY ALL;

SELECT ("d" < 0.5) AS "intercepted", "d" AS "l2_distance"
FROM "ag_l2";

-- The shipped agent: the same composition, one call. Three probes: a
-- near one (intercepted), a far one (allowed), and the near-magnitude
-- one, where the magnitude does count.
-- @call agent/outlier_intercept {"state_vec": "0.95,0.05,0.0",
--                                "history_table": "ag_badstates", "emb_col": "emb",
--                                "threshold": 0.5} AS ag_out_near;

-- @call agent/outlier_intercept {"state_vec": "0.0,1.0,0.0",
--                                "history_table": "ag_badstates", "emb_col": "emb",
--                                "threshold": 0.5} AS ag_out_far;

-- @call agent/outlier_intercept {"state_vec": "0.05,0.0,0.0",
--                                "history_table": "ag_badstates", "emb_col": "emb",
--                                "threshold": 0.5, "metric": "l2"} AS ag_out_l2;

SELECT "intercepted" AS "intercepted", "metric" AS "metric"
FROM "ag_out_near";

SELECT "intercepted" AS "intercepted", "metric" AS "metric"
FROM "ag_out_far";

SELECT "intercepted" AS "intercepted", "metric" AS "metric"
FROM "ag_out_l2";

-- ---------------------------------------------------------------------------
-- 6. recall_hybrid: a cohort-restricted vector recall.
--
-- The composition: the strict SQL filter (the cohort) collected, then
-- the recall restricted to it. mem_id is the real session_id of the
-- matching row and content is the real row text.
-- ---------------------------------------------------------------------------
-- @fixture ag_mem {"rows": [
--   {"id": 1, "session_id": 1001, "customer_id": "cust-a", "state_vector": "0.2,0.2,0.2", "content": "resolved churn via loyalty upgrade"},
--   {"id": 2, "session_id": 1002, "customer_id": "cust-a", "state_vector": "0.8,0.8,0.8", "content": "escalated billing dispute to agent"},
--   {"id": 3, "session_id": 1003, "customer_id": "cust-b", "state_vector": "0.5,0.5,0.5", "content": "refunded a duplicate charge"}
-- ]};

REPLACE INTO ag_recall_bp OVERWRITE ALL
SELECT "session_id" AS "mem_id", "content" AS "content",
       MIN(fractal_vector_cosine_similarity("state_vector", '0.18,0.22,0.2')) AS "score"
FROM "ag_mem" WHERE "customer_id" = 'cust-a'
GROUP BY "session_id", "content"
PARTITIONED BY ALL;

SELECT "mem_id" AS "mem_id", "content" AS "content", "score" AS "score"
FROM "ag_recall_bp";

-- The shipped agent: the same composition, one call.
-- @call agent/recall_hybrid {"mem_table": "ag_mem", "vec_col": "state_vector",
--                            "query_vec": "0.18,0.22,0.2", "id_col": "session_id",
--                            "filter_col": "customer_id", "filter_val": "cust-a",
--                            "k": 2} AS ag_recall;

SELECT r."doc_id" AS "mem_id", m."content" AS "content", r."distance" AS "distance"
FROM "ag_recall" r, "ag_mem" m
WHERE r."doc_id" = m."session_id";

-- ---------------------------------------------------------------------------
-- 7. recommend_diverse: a diversified top-k over a catalogue.
--
-- The composition: the plain nearest rows, scored by 1 - distance. The
-- diversify monitor is a session side effect, so it is switched on for
-- the search and switched off again at the end of the section.
-- ---------------------------------------------------------------------------
-- @fixture ag_catalog {"rows": [
--   {"id": 10, "emb": "0.1,0.0,0.0"},
--   {"id": 20, "emb": "0.0,1.0,0.0"},
--   {"id": 30, "emb": "0.0,0.0,1.0"}
-- ]};

SELECT fractal_diversify_enable();

-- @call search/telemetry {"datasource": "ag_catalog", "vectorColumn": "emb",
--                         "idColumn": "id", "query": "0.12,0.01,0.0",
--                         "k": 3} AS ag_cat_near;

SELECT c."id" AS "item_id", 1.0 - r."distance" AS "score"
FROM "ag_cat_near" r, "ag_catalog" c
WHERE r."doc_id" = c."id";

-- The shipped agent: the same composition, one call.
-- @call agent/recommend_diverse {"catalog_table": "ag_catalog", "emb_col": "emb",
--                                "query_vec": "0.12,0.01,0.0", "k": 3,
--                                "id_col": "id"} AS ag_diverse;

SELECT "item_id" AS "item_id", "score" AS "score"
FROM "ag_diverse";

SELECT fractal_diversify_disable();

-- ---------------------------------------------------------------------------
-- 8. data_analyst: a natural-language question, answered with SQL.
--
-- The generated statement is validated against Druid's own parser
-- before it runs, so the statement that executes is one Druid accepts.
-- ---------------------------------------------------------------------------
-- @fixture ag_data {"rows": [
--   {"id": 1, "category": "hardware", "amount": 1200.0},
--   {"id": 2, "category": "software", "amount": 800.5},
--   {"id": 3, "category": "hardware", "amount": 450.25}
-- ]};

-- @call agent/data_analyst {"question": "total amount spent per category in ag_data",
--                           "table_names": "[\"ag_data\"]", "max_retries": 3} AS ag_analyst;

SELECT "question" AS "question", "generated_sql" AS "generated_sql",
       "execution_status" AS "execution_status"
FROM "ag_analyst";

-- ---------------------------------------------------------------------------
-- 9. patient_deterioration_triage: the nearest patient in a cohort.
--
-- The cohort is the two-predicate one (age and condition) a single
-- filter argument cannot express, so it is computed here and handed to
-- the agent as a one-row datasource of its own.
-- ---------------------------------------------------------------------------
-- @fixture ag_patients {"rows": [
--   {"id": 1, "age": 72, "condition": "sepsis", "vitals": "0.90,-0.80,0.70,0.60"},
--   {"id": 2, "age": 64, "condition": "sepsis", "vitals": "0.10,0.10,0.10,0.10"},
--   {"id": 3, "age": 78, "condition": "pneumonia", "vitals": "0.20,0.20,0.20,0.20"},
--   {"id": 4, "age": 81, "condition": "sepsis", "vitals": "0.85,-0.75,0.65,0.55"}
-- ]};

REPLACE INTO ag_cohort OVERWRITE ALL
SELECT ARRAY_TO_STRING(ARRAY_AGG(CAST("id" AS VARCHAR), 8192), ',') AS "ids"
FROM "ag_patients" WHERE "age" > 65 AND "condition" = 'sepsis'
PARTITIONED BY ALL;

SELECT "ids" AS "cohort_ids" FROM "ag_cohort";

-- The composition: the nearest cohort member, and the drift distance:
-- how close any stored patient sits to the movement from the baseline
-- to the current state (current minus baseline, here 0.85,-0.95,0.65,0.55).
REPLACE INTO ag_pat_bp OVERWRITE ALL
SELECT MIN(fractal_vector_cosine_similarity("vitals", '0.9,-0.8,0.7,0.6')) AS "sim"
FROM "ag_patients" WHERE "age" > 65 AND "condition" = 'sepsis'
PARTITIONED BY ALL;

REPLACE INTO ag_pat_drift OVERWRITE ALL
SELECT MIN(fractal_vector_cosine_distance("vitals", '0.85,-0.95,0.65,0.55')) AS "drift_distance"
FROM "ag_patients"
PARTITIONED BY ALL;

SELECT p."sim" AS "cohort_similarity", d."drift_distance" AS "drift_distance"
FROM "ag_pat_bp" p, "ag_pat_drift" d;

-- The shipped agent: the same composition, one call.
-- @call agent/patient_deterioration_triage {"patient_table": "ag_patients",
--     "vec_col": "vitals", "id_column": "id", "query_vec": "0.9,-0.8,0.7,0.6",
--     "baseline_vec": "0.1,0.1,0.1,0.1", "current_vec": "0.95,-0.85,0.75,0.65",
--     "cohort_doc_ids_table": "ag_cohort", "cohort_doc_ids_column": "ids",
--     "k": 5} AS ag_patient;

SELECT "nearest_cohort_id" AS "nearest_cohort_id",
       "cohort_distance" AS "cohort_distance",
       "drift_distance" AS "drift_distance",
       "cohort_matches" AS "cohort_matches"
FROM "ag_patient";

-- ---------------------------------------------------------------------------
-- 10. schedule_workload: a refined task matched to a node.
--
-- The composition: the SFS refines the task vector, and the refined
-- vector is matched to the node table. The nearest node is the row with
-- the smallest distance -- carried as one number, the similarity scaled
-- up so the node's own id rides along in the fraction.
-- ---------------------------------------------------------------------------
-- @fixture ag_nodes {"rows": [
--   {"id": 1, "capability": "0.9,0.1,0.0,0.0,0.0"},
--   {"id": 2, "capability": "0.0,0.0,0.9,0.1,0.0"},
--   {"id": 3, "capability": "0.1,0.0,0.0,0.0,0.9"}
-- ]};

REPLACE INTO ag_refined OVERWRITE ALL
SELECT fractal_json_text(fractal_search_debug('0.8,0.1,0,0,0.1', 30, 50, 2), '$.best_point') AS "v"
FROM UNNEST(ARRAY[1]) AS t(x)
PARTITIONED BY ALL;

REPLACE INTO ag_nodesim OVERWRITE ALL
SELECT MIN(fractal_vector_cosine_similarity(n."capability", r."v") * 1000000.0 + n."id")
         - MIN(fractal_vector_cosine_similarity(n."capability", r."v")) * 1000000.0 AS "node_id",
       MIN(fractal_vector_cosine_similarity(n."capability", r."v")) AS "sim"
FROM "ag_nodes" n, "ag_refined" r
PARTITIONED BY ALL;

SELECT "node_id" AS "assigned_node", "sim" AS "similarity"
FROM "ag_nodesim";

-- The shipped agent: the same composition, one call.
-- @call agent/schedule_workload {"task_vec": "0.8,0.1,0,0,0.1",
--                                "node_table": "ag_nodes", "node_emb_col": "capability",
--                                "node_id_col": "id", "iterations": 30,
--                                "population": 50, "k": 5} AS ag_sched;

SELECT "assigned_node" AS "assigned_node", "confidence" AS "confidence"
FROM "ag_sched";

-- ---------------------------------------------------------------------------
-- 11. rebalance_sibling: an allocation and the stored one it resembles.
--
-- The composition: the optimizer's own Sharpe ratio and weights, then
-- the stored allocation nearest those weights.
-- ---------------------------------------------------------------------------
-- @fixture ag_alloc {"rows": [
--   {"id": 1, "alloc": "0.25,0.25,0.25,0.25"},
--   {"id": 2, "alloc": "0.40,0.30,0.20,0.10"},
--   {"id": 3, "alloc": "0.10,0.20,0.30,0.40"}
-- ]};

REPLACE INTO ag_rebal_opt OVERWRITE ALL
SELECT fractal_optimize_portfolio('0.05,0.10,0.15,0.20',
                                  '0.04,0,0,0,0,0.09,0,0,0,0,0.16,0,0,0,0,0.25', 4) AS "rj"
FROM UNNEST(ARRAY[1]) AS t(x)
PARTITIONED BY ALL;

REPLACE INTO ag_rebal_w OVERWRITE ALL
SELECT fractal_json_value("rj", '$.sharpe') AS "sharpe",
       fractal_json_text("rj", '$.weights') AS "w"
FROM "ag_rebal_opt"
PARTITIONED BY ALL;

SELECT "sharpe" AS "sharpe" FROM "ag_rebal_w";

-- The stored allocation nearest the movement from the baseline to the
-- optimized weights.
-- @call search/trajectory {"table": "ag_alloc", "column": "alloc",
--                          "id_column": "id", "baseline": "0.25,0.25,0.25,0.25",
--                          "current_table": "ag_rebal_w", "current_column": "w",
--                          "k": 1} AS ag_alloc_near;

SELECT a."id" AS "nearest_alloc_id", r."distance" AS "nearest_distance"
FROM "ag_alloc_near" r, "ag_alloc" a
WHERE r."doc_id" = a."id";

-- The shipped agent: the same composition, one call.
-- @call agent/rebalance_sibling {"mu": "0.05,0.10,0.15,0.20",
--     "cov": "0.04,0,0,0,0,0.09,0,0,0,0,0.16,0,0,0,0,0.25", "cardinality": 4,
--     "alloc_table": "ag_alloc", "alloc_emb_col": "alloc", "id_column": "id",
--     "baseline_vec": "0.25,0.25,0.25,0.25", "k": 5} AS ag_rebal;

SELECT "sharpe" AS "sharpe", "nearest_alloc_id" AS "nearest_alloc_id"
FROM "ag_rebal";

-- ---------------------------------------------------------------------------
-- 12. detour_classify: a fleet detour and the GPS trace it left.
--
-- Vehicle 1 has a deliberate detour; everyone else is a small nudge
-- away from their own baseline. The trace is a hundred-step two-
-- dimensional walk, and the box count over it is the trace's own
-- complexity.
-- ---------------------------------------------------------------------------
-- @fixture ag_vehicles {"rows": [
--   {"id": 1, "baseline": "0.9062,0.4309,1.3894,1.5919", "current": "0.2062,1.0309,1.8894,1.1919"},
--   {"id": 2, "baseline": "0.4309,1.3894,1.5919,0.5664", "current": "0.4809,1.4394,1.6419,0.6164"},
--   {"id": 3, "baseline": "1.3894,1.5919,0.5664,1.0278", "current": "1.4394,1.6419,0.6164,1.0778"},
--   {"id": 4, "baseline": "1.5919,0.5664,1.0278,0.2851", "current": "1.6419,0.6164,1.0778,0.3351"},
--   {"id": 5, "baseline": "0.5664,1.0278,0.2851,0.2288", "current": "0.6164,1.0778,0.3351,0.2788"},
--   {"id": 6, "baseline": "1.0278,0.2851,0.2288,0.6044", "current": "1.0778,0.3351,0.2788,0.6544"},
--   {"id": 7, "baseline": "0.2851,0.2288,0.6044,0.2318", "current": "0.3351,0.2788,0.6544,0.2818"},
--   {"id": 8, "baseline": "0.2288,0.6044,0.2318,1.6240", "current": "0.2788,0.6544,0.2818,1.6740"}
-- ]};

-- @fixture ag_trace {"rows": [
--   {"id": 1, "p": "-0.0643,-0.0246,-0.0889,-0.1144,-0.1787,-0.0916,-0.1559,0.0528,-0.0115,0.1790,0.1147,0.1701,0.1058,0.2505,0.1863,0.2795,0.2152,0.4098,0.3455,0.3957,0.3315,0.3104,0.2461,0.3688,0.3045,0.4576,0.3933,0.3925,0.3282,0.3967,0.3324,0.2895,0.2252,0.1738,0.1095,0.1144,0.0501,-0.0008,-0.0651,0.0928,0.0285,0.1090,0.0447,0.0804,0.0161,0.1922,0.1279,0.1846,0.1203,0.1021,0.0378,0.0449,-0.0194,-0.0526,-0.1169,-0.1516,-0.2159,-0.2770,-0.3413,-0.1837,-0.2480,-0.3287,-0.3930,-0.4523,-0.5166,-0.5790,-0.6433,-0.5498,-0.6140,-0.6273,-0.6916,-0.6609,-0.7252,-0.7124,-0.7767,-0.7521,-0.8164,-0.7499,-0.8142,-0.8479,-0.9122,-0.9892,-1.0535,-1.0821,-1.1464,-1.0537,-1.1180,-1.1574,-1.2217,-1.0996,-1.1639,-1.1944,-1.2587,-1.3311,-1.3954,-1.2609,-1.3252,-1.2815,-1.3458,-1.4046,-1.4689,-1.4714,-1.5357,-1.5932,-1.6575,-1.6303,-1.6946,-1.6349,-1.6992,-1.6775,-1.7418,-1.6942,-1.7585,-1.5658,-1.6301,-1.4712,-1.5355,-1.5788,-1.6430,-1.5698,-1.6341,-1.4986,-1.5629,-1.4144,-1.4786,-1.3390,-1.4033,-1.2106,-1.2749,-1.3168,-1.3811,-1.4500,-1.5143,-1.4531,-1.5173,-1.5238,-1.5881,-1.3939,-1.4582,-1.5202,-1.5845,-1.6206,-1.6849,-1.6213,-1.6856,-1.5033,-1.5676,-1.5502,-1.6145,-1.5285,-1.5928,-1.4634,-1.5277,-1.3299,-1.3942,-1.4175,-1.4818,-1.3751,-1.4394,-1.5110,-1.5753,-1.6515,-1.7158,-1.6517,-1.7160,-1.6647,-1.7290,-1.6744,-1.7387,-1.5495,-1.6138,-1.5790,-1.6433,-1.4305,-1.4948,-1.5001,-1.5644,-1.4213,-1.4856,-1.2791,-1.3434,-1.3971,-1.4614,-1.5468,-1.6111,-1.4774,-1.5417,-1.5356,-1.5998,-1.6228,-1.6871,-1.4925,-1.5568,-1.5616,-1.6258,-1.5817,-1.6459,-1.4873,-1.5516,-1.4050"}
-- ]};

SELECT fractal_dimension_boxcount("p", 2) AS "trace_complexity"
FROM "ag_trace";

-- The composition: the fleet row whose movement resembles the detour.
-- @call search/telemetry {"datasource": "ag_vehicles", "vectorColumn": "current",
--                         "idColumn": "id", "query": "-0.7000,0.6000,0.5000,-0.4000", "k": 5} AS ag_detour_near;

SELECT v."id" AS "id", r."distance" AS "distance"
FROM "ag_detour_near" r, "ag_vehicles" v
WHERE r."doc_id" = v."id";

-- The shipped agent: the same composition, one call.
-- @call agent/detour_classify {"vehicle_table": "ag_vehicles", "emb_col": "current",
--     "id_column": "id", "baseline_vec": "0.9062,0.4309,1.3894,1.5919", "current_vec": "0.2062,1.0309,1.8894,1.1919",
--     "gps_trace": "-0.0643,-0.0246,-0.0889,-0.1144,-0.1787,-0.0916,-0.1559,0.0528,-0.0115,0.1790,0.1147,0.1701,0.1058,0.2505,0.1863,0.2795,0.2152,0.4098,0.3455,0.3957,0.3315,0.3104,0.2461,0.3688,0.3045,0.4576,0.3933,0.3925,0.3282,0.3967,0.3324,0.2895,0.2252,0.1738,0.1095,0.1144,0.0501,-0.0008,-0.0651,0.0928,0.0285,0.1090,0.0447,0.0804,0.0161,0.1922,0.1279,0.1846,0.1203,0.1021,0.0378,0.0449,-0.0194,-0.0526,-0.1169,-0.1516,-0.2159,-0.2770,-0.3413,-0.1837,-0.2480,-0.3287,-0.3930,-0.4523,-0.5166,-0.5790,-0.6433,-0.5498,-0.6140,-0.6273,-0.6916,-0.6609,-0.7252,-0.7124,-0.7767,-0.7521,-0.8164,-0.7499,-0.8142,-0.8479,-0.9122,-0.9892,-1.0535,-1.0821,-1.1464,-1.0537,-1.1180,-1.1574,-1.2217,-1.0996,-1.1639,-1.1944,-1.2587,-1.3311,-1.3954,-1.2609,-1.3252,-1.2815,-1.3458,-1.4046,-1.4689,-1.4714,-1.5357,-1.5932,-1.6575,-1.6303,-1.6946,-1.6349,-1.6992,-1.6775,-1.7418,-1.6942,-1.7585,-1.5658,-1.6301,-1.4712,-1.5355,-1.5788,-1.6430,-1.5698,-1.6341,-1.4986,-1.5629,-1.4144,-1.4786,-1.3390,-1.4033,-1.2106,-1.2749,-1.3168,-1.3811,-1.4500,-1.5143,-1.4531,-1.5173,-1.5238,-1.5881,-1.3939,-1.4582,-1.5202,-1.5845,-1.6206,-1.6849,-1.6213,-1.6856,-1.5033,-1.5676,-1.5502,-1.6145,-1.5285,-1.5928,-1.4634,-1.5277,-1.3299,-1.3942,-1.4175,-1.4818,-1.3751,-1.4394,-1.5110,-1.5753,-1.6515,-1.7158,-1.6517,-1.7160,-1.6647,-1.7290,-1.6744,-1.7387,-1.5495,-1.6138,-1.5790,-1.6433,-1.4305,-1.4948,-1.5001,-1.5644,-1.4213,-1.4856,-1.2791,-1.3434,-1.3971,-1.4614,-1.5468,-1.6111,-1.4774,-1.5417,-1.5356,-1.5998,-1.6228,-1.6871,-1.4925,-1.5568,-1.5616,-1.6258,-1.5817,-1.6459,-1.4873,-1.5516,-1.4050", "k": 5, "boxcount_dim": 2} AS ag_detour;

SELECT "nearest_fleet_id" AS "nearest_fleet_id",
       "trajectory_distance" AS "trajectory_distance",
       "trace_complexity" AS "trace_complexity"
FROM "ag_detour";

-- ---------------------------------------------------------------------------
-- 13. track_anomaly: a track deviation and its heading exponent.
--
-- Vessel 1's current track is its baseline shifted hard; the heading
-- series swings hard in the middle of the walk.
-- ---------------------------------------------------------------------------
-- @fixture ag_tracks {"rows": [
--   {"id": 1, "baseline": "1.6240,1.1078,0.8093,1.7458", "current": "2.2240,0.6078,-0.0907,2.5458"},
--   {"id": 2, "baseline": "1.1078,0.8093,1.7458,0.9493", "current": "1.1578,0.8593,1.7958,0.9993"},
--   {"id": 3, "baseline": "0.8093,1.7458,0.9493,0.4500", "current": "0.8593,1.7958,0.9993,0.5000"},
--   {"id": 4, "baseline": "1.7458,0.9493,0.4500,0.6187", "current": "1.7958,0.9993,0.5000,0.6687"},
--   {"id": 5, "baseline": "0.9493,0.4500,0.6187,0.3498", "current": "0.9993,0.5000,0.6687,0.3998"},
--   {"id": 6, "baseline": "0.4500,0.6187,0.3498,0.3396", "current": "0.5000,0.6687,0.3998,0.3896"},
--   {"id": 7, "baseline": "0.6187,0.3498,0.3396,0.1644", "current": "0.6687,0.3998,0.3896,0.2144"},
--   {"id": 8, "baseline": "0.3498,0.3396,0.1644,1.6218", "current": "0.3998,0.3896,0.2144,1.6718"}
-- ]};

-- @fixture ag_heading {"rows": [
--   {"id": 1, "s": "-0.010927,-0.016013,-0.016153,-0.031144,-0.041287,-0.043681,-0.029128,-0.022426,-0.028855,-0.031314,-0.040296,-0.038018,-0.023573,-0.010955,-0.011847,-0.003801,-0.000901,0.012127,0.010719,0.002182,0.008023,0.016903,0.010398,0.010815,0.000091,-0.011477,-0.017411,-0.028935,-0.019575,-0.017958,-0.020818,-0.009631,-0.010391,-0.018642,-0.024361,-0.034114,-0.044019,-0.056554,-0.047227,-0.216392,-0.360572,-0.508438,-0.474271,-0.564754,-0.603929,-0.664067,-0.710320,-0.707742,-0.822099,-0.986988,-1.095394,-1.062181,-1.183238,-1.115773,-1.226316,-1.385852,-1.303994,-1.327981,-1.471644,-1.549562,-1.561740,-1.565449,-1.565905,-1.570166,-1.571842,-1.559001,-1.549539,-1.560295,-1.559403,-1.552282,-1.543854,-1.536321,-1.523483,-1.534096,-1.547423,-1.547725,-1.554801,-1.541811,-1.554443,-1.564477,-1.564549,-1.552753,-1.557441,-1.555269,-1.548763,-1.535410,-1.544166,-1.539930,-1.553518,-1.567573,-1.567591,-1.568888,-1.569861,-1.557370,-1.560322,-1.545468,-1.552430,-1.544550,-1.530332,-1.542132,-1.557101,-1.550159,-1.555975,-1.564697,-1.551666,-1.558575,-1.560585,-1.551154,-1.542914,-1.557360,-1.555308,-1.545836,-1.556512,-1.547278,-1.537532,-1.546649,-1.548431,-1.540205,-1.532120,-1.521143"}
-- ]};

SELECT fractal_dimension_dfa("s") AS "dfa_exponent"
FROM "ag_heading";

-- The shipped agent: the same composition, one call.
-- @call agent/track_anomaly {"track_table": "ag_tracks", "emb_col": "current",
--     "id_column": "id", "baseline_vec": "1.6240,1.1078,0.8093,1.7458",
--     "current_vec": "2.2240,0.6078,-0.0907,2.5458", "heading_series_table": "ag_heading",
--     "heading_series_column": "s", "k": 5} AS ag_track;

SELECT "nearest_fleet_id" AS "nearest_fleet_id",
       "trajectory_distance" AS "trajectory_distance",
       "dfa_exponent" AS "dfa_exponent"
FROM "ag_track";

-- ---------------------------------------------------------------------------
-- 14. network_coverage_alert: a sensor grid's morphology and its drift.
--
-- The box count over the whole grid is a service operation: it is a
-- count over a cloud of points, and as an expression it would run once
-- per row of the group.
-- ---------------------------------------------------------------------------
-- @fixture ag_grid {"rows": [
--   {"x": 0.0022, "y": -0.098},
--   {"x": -0.098, "y": 0.8587},
--   {"x": -0.1413, "y": 1.9071},
--   {"x": -0.0929, "y": 3.0285},
--   {"x": 0.0285, "y": 3.8962},
--   {"x": -0.1038, "y": 5.0578},
--   {"x": 0.0578, "y": 5.9052},
--   {"x": -0.0948, "y": 6.8633},
--   {"x": -0.1367, "y": 8.0702},
--   {"x": 0.0702, "y": 8.9794},
--   {"x": -0.0206, "y": 9.8769},
--   {"x": -0.1231, "y": 10.9332},
--   {"x": -0.0668, "y": 11.8782},
--   {"x": -0.1218, "y": 12.9629},
--   {"x": -0.0371, "y": 13.9954},
--   {"x": -0.0046, "y": 14.9574},
--   {"x": -0.0426, "y": 15.9832},
--   {"x": -0.0168, "y": 17.1284},
--   {"x": 0.1284, "y": 18.0946},
--   {"x": 0.0946, "y": 18.8924},
--   {"x": 0.8924, "y": 0.0089},
--   {"x": 1.0089, "y": 1.0712},
--   {"x": 1.0712, "y": 2.0843},
--   {"x": 1.0843, "y": 3.0753},
--   {"x": 1.0753, "y": 4.1284},
--   {"x": 1.1284, "y": 4.8939},
--   {"x": 0.8939, "y": 5.8667},
--   {"x": 0.8667, "y": 6.997},
--   {"x": 0.997, "y": 7.9292},
--   {"x": 0.9292, "y": 9.1299},
--   {"x": 1.1299, "y": 9.8737},
--   {"x": 0.8737, "y": 10.8997},
--   {"x": 0.8997, "y": 11.9993},
--   {"x": 0.9993, "y": 13.118},
--   {"x": 1.118, "y": 13.9531},
--   {"x": 0.9531, "y": 15.0217},
--   {"x": 1.0217, "y": 16.0651},
--   {"x": 1.0651, "y": 17.1335},
--   {"x": 1.1335, "y": 17.9124},
--   {"x": 0.9124, "y": 19.0424},
--   {"x": 2.0424, "y": -0.1359},
--   {"x": 1.8641, "y": 0.8594},
--   {"x": 1.8594, "y": 1.9998},
--   {"x": 1.9998, "y": 2.987},
--   {"x": 1.987, "y": 3.9903},
--   {"x": 1.9903, "y": 5.1249},
--   {"x": 2.1249, "y": 5.9705},
--   {"x": 1.9705, "y": 7.1485},
--   {"x": 2.1485, "y": 7.9304},
--   {"x": 1.9304, "y": 9.0788},
--   {"x": 2.0788, "y": 10.1422},
--   {"x": 2.1422, "y": 10.882},
--   {"x": 1.882, "y": 11.8503},
--   {"x": 1.8503, "y": 13.0694},
--   {"x": 2.0694, "y": 13.9418},
--   {"x": 1.9418, "y": 14.9128},
--   {"x": 1.9128, "y": 16.1303},
--   {"x": 2.1303, "y": 16.9309},
--   {"x": 1.9309, "y": 17.9799},
--   {"x": 1.9799, "y": 19.0943},
--   {"x": 3.0943, "y": 0.0824},
--   {"x": 3.0824, "y": 0.8555},
--   {"x": 2.8555, "y": 2.0205},
--   {"x": 3.0205, "y": 3.0947},
--   {"x": 3.0947, "y": 3.8932},
--   {"x": 2.8932, "y": 5.0923},
--   {"x": 3.0923, "y": 6.0975},
--   {"x": 3.0975, "y": 6.9088},
--   {"x": 2.9088, "y": 7.9822},
--   {"x": 2.9822, "y": 9.0823},
--   {"x": 3.0823, "y": 10.0808},
--   {"x": 3.0808, "y": 11.1098},
--   {"x": 3.1098, "y": 11.8749},
--   {"x": 2.8749, "y": 13.0668},
--   {"x": 3.0668, "y": 14.1001},
--   {"x": 3.1001, "y": 15.1288},
--   {"x": 3.1288, "y": 16.0303},
--   {"x": 3.0303, "y": 16.9944},
--   {"x": 2.9944, "y": 18.1216},
--   {"x": 3.1216, "y": 18.855},
--   {"x": 3.855, "y": -0.1255},
--   {"x": 3.8745, "y": 1.063},
--   {"x": 4.063, "y": 2.0066},
--   {"x": 4.0066, "y": 3.1177},
--   {"x": 4.1177, "y": 4.1347},
--   {"x": 4.1347, "y": 5.0068},
--   {"x": 4.0068, "y": 5.9257},
--   {"x": 3.9257, "y": 6.9494},
--   {"x": 3.9494, "y": 8.1225},
--   {"x": 4.1225, "y": 9.0149},
--   {"x": 4.0149, "y": 9.8732},
--   {"x": 3.8732, "y": 11.0047},
--   {"x": 4.0047, "y": 11.9033},
--   {"x": 3.9033, "y": 12.9859},
--   {"x": 3.9859, "y": 14.0677},
--   {"x": 4.0677, "y": 15.0739},
--   {"x": 4.0739, "y": 16.0012},
--   {"x": 4.0012, "y": 17.0519},
--   {"x": 4.0519, "y": 17.8565},
--   {"x": 3.8565, "y": 19.0665},
--   {"x": 5.0665, "y": 0.1086},
--   {"x": 5.1086, "y": 1.09},
--   {"x": 5.09, "y": 1.9993},
--   {"x": 4.9993, "y": 3.04},
--   {"x": 5.04, "y": 3.9044},
--   {"x": 4.9044, "y": 4.9666},
--   {"x": 4.9666, "y": 6.142},
--   {"x": 5.142, "y": 6.9533},
--   {"x": 4.9533, "y": 8.1419},
--   {"x": 5.1419, "y": 8.9896},
--   {"x": 4.9896, "y": 10.0603},
--   {"x": 5.0603, "y": 11.0984},
--   {"x": 5.0984, "y": 11.8504},
--   {"x": 4.8504, "y": 12.8746},
--   {"x": 4.8746, "y": 14.1218},
--   {"x": 5.1218, "y": 15.0666},
--   {"x": 5.0666, "y": 15.9869},
--   {"x": 4.9869, "y": 16.8912},
--   {"x": 4.8912, "y": 18.0332},
--   {"x": 5.0332, "y": 18.9041},
--   {"x": 5.9041, "y": 0.019},
--   {"x": 6.019, "y": 0.8783},
--   {"x": 5.8783, "y": 2.1422},
--   {"x": 6.1422, "y": 3.0383},
--   {"x": 6.0383, "y": 3.9415},
--   {"x": 5.9415, "y": 5.088},
--   {"x": 6.088, "y": 5.8977},
--   {"x": 5.8977, "y": 6.9903},
--   {"x": 5.9903, "y": 8.0249},
--   {"x": 6.0249, "y": 8.9021},
--   {"x": 5.9021, "y": 10.0067},
--   {"x": 6.0067, "y": 10.9614},
--   {"x": 5.9614, "y": 12.1105},
--   {"x": 6.1105, "y": 13.042},
--   {"x": 6.042, "y": 13.9309},
--   {"x": 5.9309, "y": 15.116},
--   {"x": 6.116, "y": 16.1415},
--   {"x": 6.1415, "y": 16.9773},
--   {"x": 5.9773, "y": 17.9315},
--   {"x": 5.9315, "y": 18.9139},
--   {"x": 6.9139, "y": 0.0948},
--   {"x": 7.0948, "y": 1.0892},
--   {"x": 7.0892, "y": 2.0273},
--   {"x": 7.0273, "y": 2.9182},
--   {"x": 6.9182, "y": 4.1475},
--   {"x": 7.1475, "y": 4.8843},
--   {"x": 6.8843, "y": 6.1094},
--   {"x": 7.1094, "y": 6.9587},
--   {"x": 6.9587, "y": 8.0378},
--   {"x": 7.0378, "y": 8.9964},
--   {"x": 6.9964, "y": 9.9369},
--   {"x": 6.9369, "y": 11.0713},
--   {"x": 7.0713, "y": 11.9933},
--   {"x": 6.9933, "y": 12.999},
--   {"x": 6.999, "y": 13.8721},
--   {"x": 6.8721, "y": 14.9993},
--   {"x": 6.9993, "y": 16.1002},
--   {"x": 7.1002, "y": 16.9688},
--   {"x": 6.9688, "y": 18.1046},
--   {"x": 7.1046, "y": 19.0178},
--   {"x": 8.0178, "y": 0.0696},
--   {"x": 8.0696, "y": 0.9691},
--   {"x": 7.9691, "y": 1.9527},
--   {"x": 7.9527, "y": 3.0311},
--   {"x": 8.0311, "y": 3.9204},
--   {"x": 7.9204, "y": 4.9728},
--   {"x": 7.9728, "y": 6.0382},
--   {"x": 8.0382, "y": 6.9696},
--   {"x": 7.9696, "y": 8.0505},
--   {"x": 8.0505, "y": 9.0611},
--   {"x": 8.0611, "y": 9.9974},
--   {"x": 7.9974, "y": 10.8837},
--   {"x": 7.8837, "y": 11.9562},
--   {"x": 7.9562, "y": 12.9535},
--   {"x": 7.9535, "y": 14.0735},
--   {"x": 8.0735, "y": 15.1326},
--   {"x": 8.1326, "y": 16.0131},
--   {"x": 8.0131, "y": 17.0251},
--   {"x": 8.0251, "y": 18.0793},
--   {"x": 8.0793, "y": 18.9461},
--   {"x": 8.9461, "y": 0.0455},
--   {"x": 9.0455, "y": 0.8629},
--   {"x": 8.8629, "y": 2.1461},
--   {"x": 9.1461, "y": 3.1391},
--   {"x": 9.1391, "y": 4.1084},
--   {"x": 9.1084, "y": 4.9567},
--   {"x": 8.9567, "y": 5.9063},
--   {"x": 8.9063, "y": 6.9486},
--   {"x": 8.9486, "y": 8.0345},
--   {"x": 9.0345, "y": 8.8588},
--   {"x": 8.8588, "y": 10.0304},
--   {"x": 9.0304, "y": 11.142},
--   {"x": 9.142, "y": 12.1259},
--   {"x": 9.1259, "y": 12.9966},
--   {"x": 8.9966, "y": 13.8555},
--   {"x": 8.8555, "y": 14.9261},
--   {"x": 8.9261, "y": 16.035},
--   {"x": 9.035, "y": 17.0396},
--   {"x": 9.0396, "y": 17.9705},
--   {"x": 8.9705, "y": 18.9258},
--   {"x": 9.9258, "y": 0.0107},
--   {"x": 10.0107, "y": 0.9344},
--   {"x": 9.9344, "y": 2.0039},
--   {"x": 10.0039, "y": 2.998},
--   {"x": 9.998, "y": 3.9834},
--   {"x": 9.9834, "y": 5.0943},
--   {"x": 10.0943, "y": 5.9797},
--   {"x": 9.9797, "y": 6.9256},
--   {"x": 9.9256, "y": 7.9642},
--   {"x": 9.9642, "y": 8.8857},
--   {"x": 9.8857, "y": 9.9547},
--   {"x": 9.9547, "y": 10.9322},
--   {"x": 9.9322, "y": 11.9578},
--   {"x": 9.9578, "y": 13.1115},
--   {"x": 10.1115, "y": 14.0096},
--   {"x": 10.0096, "y": 14.9509},
--   {"x": 9.9509, "y": 15.9203},
--   {"x": 9.9203, "y": 16.9608},
--   {"x": 9.9608, "y": 18.056},
--   {"x": 10.056, "y": 19.0058},
--   {"x": 11.0058, "y": 0.1191},
--   {"x": 11.1191, "y": 1.0688},
--   {"x": 11.0688, "y": 2.0194},
--   {"x": 11.0194, "y": 2.9428},
--   {"x": 10.9428, "y": 4.1463},
--   {"x": 11.1463, "y": 4.8594},
--   {"x": 10.8594, "y": 5.9379},
--   {"x": 10.9379, "y": 7.114},
--   {"x": 11.114, "y": 7.897},
--   {"x": 10.897, "y": 8.9402},
--   {"x": 10.9402, "y": 10.1177},
--   {"x": 11.1177, "y": 10.987},
--   {"x": 10.987, "y": 12.0202},
--   {"x": 11.0202, "y": 13.0624},
--   {"x": 11.0624, "y": 13.9176},
--   {"x": 10.9176, "y": 14.952},
--   {"x": 10.952, "y": 16.0689},
--   {"x": 11.0689, "y": 17.1329},
--   {"x": 11.1329, "y": 17.9844},
--   {"x": 10.9844, "y": 19.0368},
--   {"x": 12.0368, "y": -0.0242},
--   {"x": 11.9758, "y": 0.9596},
--   {"x": 11.9596, "y": 2.0395},
--   {"x": 12.0395, "y": 3.1361},
--   {"x": 12.1361, "y": 3.8793},
--   {"x": 11.8793, "y": 4.8912},
--   {"x": 11.8912, "y": 6.1123},
--   {"x": 12.1123, "y": 7.1254},
--   {"x": 12.1254, "y": 8.0949},
--   {"x": 12.0949, "y": 9.1276},
--   {"x": 12.1276, "y": 10.0843},
--   {"x": 12.0843, "y": 10.9548},
--   {"x": 11.9548, "y": 12.0289},
--   {"x": 12.0289, "y": 12.9469},
--   {"x": 11.9469, "y": 14.0647},
--   {"x": 12.0647, "y": 15.0667},
--   {"x": 12.0667, "y": 16.0459},
--   {"x": 12.0459, "y": 17.096},
--   {"x": 12.096, "y": 18.1165},
--   {"x": 12.1165, "y": 18.9665},
--   {"x": 12.9665, "y": 0.0794},
--   {"x": 13.0794, "y": 1.1117},
--   {"x": 13.1117, "y": 1.9436},
--   {"x": 12.9436, "y": 3.1358},
--   {"x": 13.1358, "y": 3.9479},
--   {"x": 12.9479, "y": 5.1433},
--   {"x": 13.1433, "y": 6.0169},
--   {"x": 13.0169, "y": 7.1158},
--   {"x": 13.1158, "y": 8.1081},
--   {"x": 13.1081, "y": 9.0644},
--   {"x": 13.0644, "y": 9.9408},
--   {"x": 12.9408, "y": 11.1027},
--   {"x": 13.1027, "y": 11.9861},
--   {"x": 12.9861, "y": 13.008},
--   {"x": 13.008, "y": 14.0148},
--   {"x": 13.0148, "y": 14.9063},
--   {"x": 12.9063, "y": 15.9217},
--   {"x": 12.9217, "y": 17.0459},
--   {"x": 13.0459, "y": 18.0542},
--   {"x": 13.0542, "y": 18.98},
--   {"x": 13.98, "y": 0.0856},
--   {"x": 14.0856, "y": 0.9625},
--   {"x": 13.9625, "y": 1.9564},
--   {"x": 13.9564, "y": 2.9814},
--   {"x": 13.9814, "y": 4.1159},
--   {"x": 14.1159, "y": 5.0723},
--   {"x": 14.0723, "y": 5.9095},
--   {"x": 13.9095, "y": 6.9634},
--   {"x": 13.9634, "y": 7.9645},
--   {"x": 13.9645, "y": 9.104},
--   {"x": 14.104, "y": 9.9989},
--   {"x": 13.9989, "y": 10.8817},
--   {"x": 13.8817, "y": 12.0883},
--   {"x": 14.0883, "y": 12.8887},
--   {"x": 13.8887, "y": 14.0021},
--   {"x": 14.0021, "y": 14.8914},
--   {"x": 13.8914, "y": 16.1187},
--   {"x": 14.1187, "y": 17.0784},
--   {"x": 14.0784, "y": 18.1322},
--   {"x": 14.1322, "y": 18.9638},
--   {"x": 14.9638, "y": 0.1195},
--   {"x": 15.1195, "y": 1.0341},
--   {"x": 15.0341, "y": 1.9409},
--   {"x": 14.9409, "y": 3.1245},
--   {"x": 15.1245, "y": 3.9738},
--   {"x": 14.9738, "y": 4.9729},
--   {"x": 14.9729, "y": 6.1154},
--   {"x": 15.1154, "y": 6.9919},
--   {"x": 14.9919, "y": 8.13},
--   {"x": 15.13, "y": 8.8578},
--   {"x": 14.8578, "y": 9.8612},
--   {"x": 14.8612, "y": 10.9363},
--   {"x": 14.9363, "y": 11.8864},
--   {"x": 14.8864, "y": 13.0947},
--   {"x": 15.0947, "y": 13.9372},
--   {"x": 14.9372, "y": 15.1427},
--   {"x": 15.1427, "y": 16.0467},
--   {"x": 15.0467, "y": 17.0985},
--   {"x": 15.0985, "y": 18.0104},
--   {"x": 15.0104, "y": 18.9147},
--   {"x": 15.9147, "y": -0.0824},
--   {"x": 15.9176, "y": 0.9125},
--   {"x": 15.9125, "y": 1.9243},
--   {"x": 15.9243, "y": 2.9048},
--   {"x": 15.9048, "y": 4.0457},
--   {"x": 16.0457, "y": 5.0122},
--   {"x": 16.0122, "y": 6.0954},
--   {"x": 16.0954, "y": 7.0739},
--   {"x": 16.0739, "y": 7.8892},
--   {"x": 15.8892, "y": 9.0687},
--   {"x": 16.0687, "y": 10.0229},
--   {"x": 16.0229, "y": 11.0333},
--   {"x": 16.0333, "y": 11.9889},
--   {"x": 15.9889, "y": 13.0271},
--   {"x": 16.0271, "y": 13.8589},
--   {"x": 15.8589, "y": 15.0807},
--   {"x": 16.0807, "y": 16.1094},
--   {"x": 16.1094, "y": 16.98},
--   {"x": 15.98, "y": 17.9604},
--   {"x": 15.9604, "y": 18.9099},
--   {"x": 16.9099, "y": 0.0771},
--   {"x": 17.0771, "y": 1.1117},
--   {"x": 17.1117, "y": 1.9371},
--   {"x": 16.9371, "y": 3.0406},
--   {"x": 17.0406, "y": 4.1138},
--   {"x": 17.1138, "y": 5.0785},
--   {"x": 17.0785, "y": 6.0078},
--   {"x": 17.0078, "y": 7.0429},
--   {"x": 17.0429, "y": 7.958},
--   {"x": 16.958, "y": 8.9688},
--   {"x": 16.9688, "y": 9.9512},
--   {"x": 16.9512, "y": 11.0698},
--   {"x": 17.0698, "y": 11.8623},
--   {"x": 16.8623, "y": 12.95},
--   {"x": 16.95, "y": 14.0319},
--   {"x": 17.0319, "y": 15.1043},
--   {"x": 17.1043, "y": 16.1445},
--   {"x": 17.1445, "y": 17.0891},
--   {"x": 17.0891, "y": 18.0965},
--   {"x": 17.0965, "y": 18.8705},
--   {"x": 17.8705, "y": -0.118},
--   {"x": 17.882, "y": 0.9229},
--   {"x": 17.9229, "y": 2.0726},
--   {"x": 18.0726, "y": 2.8607},
--   {"x": 17.8607, "y": 4.0256},
--   {"x": 18.0256, "y": 5.0422},
--   {"x": 18.0422, "y": 6.0658},
--   {"x": 18.0658, "y": 7.0648},
--   {"x": 18.0648, "y": 7.9191},
--   {"x": 17.9191, "y": 9.1239},
--   {"x": 18.1239, "y": 9.8585},
--   {"x": 17.8585, "y": 11.1058},
--   {"x": 18.1058, "y": 12.0757},
--   {"x": 18.0757, "y": 13.1464},
--   {"x": 18.1464, "y": 14.098},
--   {"x": 18.098, "y": 15.0765},
--   {"x": 18.0765, "y": 15.9803},
--   {"x": 17.9803, "y": 16.874},
--   {"x": 17.874, "y": 18.0614},
--   {"x": 18.0614, "y": 19.016},
--   {"x": 19.016, "y": 0.0737},
--   {"x": 19.0737, "y": 1.0579},
--   {"x": 19.0579, "y": 2.054},
--   {"x": 19.054, "y": 2.9923},
--   {"x": 18.9923, "y": 3.9229},
--   {"x": 18.9229, "y": 5.0236},
--   {"x": 19.0236, "y": 5.9705},
--   {"x": 18.9705, "y": 6.891},
--   {"x": 18.891, "y": 7.9408},
--   {"x": 18.9408, "y": 9.1359},
--   {"x": 19.1359, "y": 9.99},
--   {"x": 18.99, "y": 11.0396},
--   {"x": 19.0396, "y": 12.1275},
--   {"x": 19.1275, "y": 12.9475},
--   {"x": 18.9475, "y": 14.1185},
--   {"x": 19.1185, "y": 14.8538},
--   {"x": 18.8538, "y": 15.976},
--   {"x": 18.976, "y": 17.052},
--   {"x": 19.052, "y": 18.0619},
--   {"x": 19.0619, "y": 19.0864}
-- ]};

-- @fixture ag_cloud {"rows": [
--   {"id": 1, "cloud": "0.0022,-0.0980,-0.0980,0.8587,-0.1413,1.9071,-0.0929,3.0285,0.0285,3.8962,-0.1038,5.0578,0.0578,5.9052,-0.0948,6.8633,-0.1367,8.0702,0.0702,8.9794,-0.0206,9.8769,-0.1231,10.9332,-0.0668,11.8782,-0.1218,12.9629,-0.0371,13.9954,-0.0046,14.9574,-0.0426,15.9832,-0.0168,17.1284,0.1284,18.0946,0.0946,18.8924,0.8924,0.0089,1.0089,1.0712,1.0712,2.0843,1.0843,3.0753,1.0753,4.1284,1.1284,4.8939,0.8939,5.8667,0.8667,6.9970,0.9970,7.9292,0.9292,9.1299,1.1299,9.8737,0.8737,10.8997,0.8997,11.9993,0.9993,13.1180,1.1180,13.9531,0.9531,15.0217,1.0217,16.0651,1.0651,17.1335,1.1335,17.9124,0.9124,19.0424,2.0424,-0.1359,1.8641,0.8594,1.8594,1.9998,1.9998,2.9870,1.9870,3.9903,1.9903,5.1249,2.1249,5.9705,1.9705,7.1485,2.1485,7.9304,1.9304,9.0788,2.0788,10.1422,2.1422,10.8820,1.8820,11.8503,1.8503,13.0694,2.0694,13.9418,1.9418,14.9128,1.9128,16.1303,2.1303,16.9309,1.9309,17.9799,1.9799,19.0943,3.0943,0.0824,3.0824,0.8555,2.8555,2.0205,3.0205,3.0947,3.0947,3.8932,2.8932,5.0923,3.0923,6.0975,3.0975,6.9088,2.9088,7.9822,2.9822,9.0823,3.0823,10.0808,3.0808,11.1098,3.1098,11.8749,2.8749,13.0668,3.0668,14.1001,3.1001,15.1288,3.1288,16.0303,3.0303,16.9944,2.9944,18.1216,3.1216,18.8550,3.8550,-0.1255,3.8745,1.0630,4.0630,2.0066,4.0066,3.1177,4.1177,4.1347,4.1347,5.0068,4.0068,5.9257,3.9257,6.9494,3.9494,8.1225,4.1225,9.0149,4.0149,9.8732,3.8732,11.0047,4.0047,11.9033,3.9033,12.9859,3.9859,14.0677,4.0677,15.0739,4.0739,16.0012,4.0012,17.0519,4.0519,17.8565,3.8565,19.0665,5.0665,0.1086,5.1086,1.0900,5.0900,1.9993,4.9993,3.0400,5.0400,3.9044,4.9044,4.9666,4.9666,6.1420,5.1420,6.9533,4.9533,8.1419,5.1419,8.9896,4.9896,10.0603,5.0603,11.0984,5.0984,11.8504,4.8504,12.8746,4.8746,14.1218,5.1218,15.0666,5.0666,15.9869,4.9869,16.8912,4.8912,18.0332,5.0332,18.9041,5.9041,0.0190,6.0190,0.8783,5.8783,2.1422,6.1422,3.0383,6.0383,3.9415,5.9415,5.0880,6.0880,5.8977,5.8977,6.9903,5.9903,8.0249,6.0249,8.9021,5.9021,10.0067,6.0067,10.9614,5.9614,12.1105,6.1105,13.0420,6.0420,13.9309,5.9309,15.1160,6.1160,16.1415,6.1415,16.9773,5.9773,17.9315,5.9315,18.9139,6.9139,0.0948,7.0948,1.0892,7.0892,2.0273,7.0273,2.9182,6.9182,4.1475,7.1475,4.8843,6.8843,6.1094,7.1094,6.9587,6.9587,8.0378,7.0378,8.9964,6.9964,9.9369,6.9369,11.0713,7.0713,11.9933,6.9933,12.9990,6.9990,13.8721,6.8721,14.9993,6.9993,16.1002,7.1002,16.9688,6.9688,18.1046,7.1046,19.0178,8.0178,0.0696,8.0696,0.9691,7.9691,1.9527,7.9527,3.0311,8.0311,3.9204,7.9204,4.9728,7.9728,6.0382,8.0382,6.9696,7.9696,8.0505,8.0505,9.0611,8.0611,9.9974,7.9974,10.8837,7.8837,11.9562,7.9562,12.9535,7.9535,14.0735,8.0735,15.1326,8.1326,16.0131,8.0131,17.0251,8.0251,18.0793,8.0793,18.9461,8.9461,0.0455,9.0455,0.8629,8.8629,2.1461,9.1461,3.1391,9.1391,4.1084,9.1084,4.9567,8.9567,5.9063,8.9063,6.9486,8.9486,8.0345,9.0345,8.8588,8.8588,10.0304,9.0304,11.1420,9.1420,12.1259,9.1259,12.9966,8.9966,13.8555,8.8555,14.9261,8.9261,16.0350,9.0350,17.0396,9.0396,17.9705,8.9705,18.9258,9.9258,0.0107,10.0107,0.9344,9.9344,2.0039,10.0039,2.9980,9.9980,3.9834,9.9834,5.0943,10.0943,5.9797,9.9797,6.9256,9.9256,7.9642,9.9642,8.8857,9.8857,9.9547,9.9547,10.9322,9.9322,11.9578,9.9578,13.1115,10.1115,14.0096,10.0096,14.9509,9.9509,15.9203,9.9203,16.9608,9.9608,18.0560,10.0560,19.0058,11.0058,0.1191,11.1191,1.0688,11.0688,2.0194,11.0194,2.9428,10.9428,4.1463,11.1463,4.8594,10.8594,5.9379,10.9379,7.1140,11.1140,7.8970,10.8970,8.9402,10.9402,10.1177,11.1177,10.9870,10.9870,12.0202,11.0202,13.0624,11.0624,13.9176,10.9176,14.9520,10.9520,16.0689,11.0689,17.1329,11.1329,17.9844,10.9844,19.0368,12.0368,-0.0242,11.9758,0.9596,11.9596,2.0395,12.0395,3.1361,12.1361,3.8793,11.8793,4.8912,11.8912,6.1123,12.1123,7.1254,12.1254,8.0949,12.0949,9.1276,12.1276,10.0843,12.0843,10.9548,11.9548,12.0289,12.0289,12.9469,11.9469,14.0647,12.0647,15.0667,12.0667,16.0459,12.0459,17.0960,12.0960,18.1165,12.1165,18.9665,12.9665,0.0794,13.0794,1.1117,13.1117,1.9436,12.9436,3.1358,13.1358,3.9479,12.9479,5.1433,13.1433,6.0169,13.0169,7.1158,13.1158,8.1081,13.1081,9.0644,13.0644,9.9408,12.9408,11.1027,13.1027,11.9861,12.9861,13.0080,13.0080,14.0148,13.0148,14.9063,12.9063,15.9217,12.9217,17.0459,13.0459,18.0542,13.0542,18.9800,13.9800,0.0856,14.0856,0.9625,13.9625,1.9564,13.9564,2.9814,13.9814,4.1159,14.1159,5.0723,14.0723,5.9095,13.9095,6.9634,13.9634,7.9645,13.9645,9.1040,14.1040,9.9989,13.9989,10.8817,13.8817,12.0883,14.0883,12.8887,13.8887,14.0021,14.0021,14.8914,13.8914,16.1187,14.1187,17.0784,14.0784,18.1322,14.1322,18.9638,14.9638,0.1195,15.1195,1.0341,15.0341,1.9409,14.9409,3.1245,15.1245,3.9738,14.9738,4.9729,14.9729,6.1154,15.1154,6.9919,14.9919,8.1300,15.1300,8.8578,14.8578,9.8612,14.8612,10.9363,14.9363,11.8864,14.8864,13.0947,15.0947,13.9372,14.9372,15.1427,15.1427,16.0467,15.0467,17.0985,15.0985,18.0104,15.0104,18.9147,15.9147,-0.0824,15.9176,0.9125,15.9125,1.9243,15.9243,2.9048,15.9048,4.0457,16.0457,5.0122,16.0122,6.0954,16.0954,7.0739,16.0739,7.8892,15.8892,9.0687,16.0687,10.0229,16.0229,11.0333,16.0333,11.9889,15.9889,13.0271,16.0271,13.8589,15.8589,15.0807,16.0807,16.1094,16.1094,16.9800,15.9800,17.9604,15.9604,18.9099,16.9099,0.0771,17.0771,1.1117,17.1117,1.9371,16.9371,3.0406,17.0406,4.1138,17.1138,5.0785,17.0785,6.0078,17.0078,7.0429,17.0429,7.9580,16.9580,8.9688,16.9688,9.9512,16.9512,11.0698,17.0698,11.8623,16.8623,12.9500,16.9500,14.0319,17.0319,15.1043,17.1043,16.1445,17.1445,17.0891,17.0891,18.0965,17.0965,18.8705,17.8705,-0.1180,17.8820,0.9229,17.9229,2.0726,18.0726,2.8607,17.8607,4.0256,18.0256,5.0422,18.0422,6.0658,18.0658,7.0648,18.0648,7.9191,17.9191,9.1239,18.1239,9.8585,17.8585,11.1058,18.1058,12.0757,18.0757,13.1464,18.1464,14.0980,18.0980,15.0765,18.0765,15.9803,17.9803,16.8740,17.8740,18.0614,18.0614,19.0160,19.0160,0.0737,19.0737,1.0579,19.0579,2.0540,19.0540,2.9923,18.9923,3.9229,18.9229,5.0236,19.0236,5.9705,18.9705,6.8910,18.8910,7.9408,18.9408,9.1359,19.1359,9.9900,18.9900,11.0396,19.0396,12.1275,19.1275,12.9475,18.9475,14.1185,19.1185,14.8538,18.8538,15.9760,18.9760,17.0520,19.0520,18.0619,19.0619,19.0864"}
-- ]};

-- @fixture ag_regime {"rows": [
--   {"id": 1, "series": "4.5585,4.6040,5.0657,5.4504,5.8769,5.6947,4.9819,5.3177,4.7694,4.0158,3.9437,3.1273,2.9512,2.4609,2.7112,2.5906,2.8559,2.9655,3.1339,3.7397,4.3336,4.3674,4.8533,5.3094,5.8800,5.6470,5.1332,4.9511,4.3923,4.2474,4.1090,3.6236,2.8947,2.8676,2.5932,2.8676,2.6281,2.7107,3.4679,3.9884,4.0413,4.6685,4.7513,5.0099,5.3156,5.1814,5.6113,1.1379,2.6715,6.3115,6.1569,2.3727,1.0758,4.4692,6.8314,4.5424,0.9502,2.4461,6.2153,6.2386,2.2601,1.1993,4.6310,6.9409,4.3209,0.9837,2.5127,6.3202,6.1677,2.1415,1.3626,4.6711,6.8032,4.3110,1.0610,2.6286,6.4122,5.8951,2.1487,1.3239,4.8374,6.9516,4.2880,1.1919,2.7424,6.5674,6.0779,2.2309,1.4780,5.1611,6.8175,3.8382,1.0424,2.8857,6.7801,5.7377"}
-- ]};

-- @call boxcount {"datasource": "ag_grid", "xColumn": "x", "yColumn": "y",
--                 "dim": 2} AS ag_gridbox;

SELECT "dim" AS "morph_dimension" FROM "ag_gridbox";

REPLACE INTO ag_cover_drift OVERWRITE ALL
SELECT fractal_dimension_drift("series", 48) AS "dj"
FROM "ag_regime"
PARTITIONED BY ALL;

SELECT fractal_json_value("dj", '$.drift') AS "drift"
FROM "ag_cover_drift" GROUP BY "dj";

-- The shipped agent: the same composition, one call.
-- @call agent/network_coverage_alert {"point_cloud_table": "ag_cloud",
--     "point_cloud_column": "cloud", "drift_series_table": "ag_regime",
--     "drift_series_column": "series", "boxcount_dim": 2, "drift_win": 48,
--     "drift_threshold": 0.5} AS ag_cover;

SELECT "morph_dimension" AS "morph_dimension",
       "lacunarity" AS "lacunarity",
       "drift_detected" AS "drift_detected"
FROM "ag_cover";

-- ---------------------------------------------------------------------------
-- 15. regime_triage: the DFA exponent, the regime drift, and the
-- one-line reading of the change.
-- ---------------------------------------------------------------------------
-- @call agent/regime_triage {"series_table": "ag_regime", "series_column": "series",
--                            "win": 64, "drift_threshold": 0.5} AS ag_regime_triage;

SELECT "dfa_exponent" AS "dfa_exponent",
       "drift_detected" AS "drift_detected",
       "recent_alpha" AS "recent_alpha",
       "baseline_alpha" AS "baseline_alpha",
       "rationale" AS "rationale"
FROM "ag_regime_triage";

-- ---------------------------------------------------------------------------
-- 16. The universal agents.
--
-- The trajectory predictor walks a real vector column; the loop
-- detector fingerprints the states of a state log and looks for a
-- cycle; the planner branches from a state; the search and RAG agents
-- answer a question over a table's embeddings.
-- ---------------------------------------------------------------------------
-- @call agent/trajectory_predict {"table": "ag_vehicles", "col": "current",
--                                 "id": 1, "steps": 8} AS ag_traj;

SELECT "id" AS "id", "current" AS "current", "predicted" AS "predicted"
FROM "ag_traj";

-- A SimHash fingerprint follows a state's direction, not its magnitude, so a
-- one-dimensional state collapses to its sign. The states are therefore
-- two-dimensional: a bot that toggles between two directions, and an actor
-- that wanders.
-- @fixture ag_loop {"rows": [{"id": 1, "log": "1.0,0.0,0.0,1.0,1.0,0.0,0.0,1.0,1.0,0.0,0.0,1.0,1.0,0.0,0.0,1.0,1.0,0.0,0.0,1.0,1.0,0.0,0.0,1.0,1.0,0.0,0.0,1.0,1.0,0.0,0.0,1.0"}]};
-- @fixture ag_wander {"rows": [{"id": 1, "log": "1.0,0.0,0.6,0.8,-0.3,0.95,-0.9,0.4,-0.8,-0.6,0.1,-1.0,0.9,-0.4,0.5,0.5"}]};

-- @call agent/detect_loop {"agent_id": "agents-demo-loop",
--                          "state_log_table": "ag_loop", "state_log_column": "log",
--                          "dim": 2, "n_bits": 64} AS ag_loop_scan;

-- @call agent/detect_loop {"agent_id": "agents-demo-wander",
--                          "state_log_table": "ag_wander", "state_log_column": "log",
--                          "dim": 2, "n_bits": 64} AS ag_wander_scan;

SELECT "agent_id" AS "agent_id", "is_loop_detected" AS "is_loop_detected",
       "cycle_length" AS "cycle_length", "n_states" AS "n_states"
FROM "ag_loop_scan"
UNION ALL
SELECT "agent_id", "is_loop_detected", "cycle_length", "n_states"
FROM "ag_wander_scan";

-- @call agent/plan_explore {"state": "0.1,0.2,0.3", "table": "ag_catalog",
--                           "col": "emb", "branches": 3} AS ag_plan;

SELECT "branches" AS "branches" FROM "ag_plan";

-- The outlier screen: the table-driven form of the interceptor. Every
-- proposed state is screened against the known signatures.
-- @call agent/outlier_screen {"proposed_table": "ag_proposed",
--                             "state_column": "state", "id_column": "id",
--                             "label_column": "label", "history_table": "ag_badstates",
--                             "emb_column": "emb", "history_id_column": "id",
--                             "threshold": 0.5, "metric": "cosine"} AS ag_screen;

SELECT "id" AS "id", "label" AS "label", "intercepted" AS "intercepted",
       "distance" AS "distance"
FROM "ag_screen";

-- ---------------------------------------------------------------------------
-- 17. feedback_audit: the diversity quotient and the diagnostics.
--
-- The agent is self-contained: it enables the diversify monitor, warms
-- its rolling window with varied queries, isolates the nearest row as
-- negative feedback, reads the quotient and the diagnostics -- and
-- disables the monitor again.
-- ---------------------------------------------------------------------------
-- The catalog the audit searches, and the queries that warm its rolling window.
-- @fixture ag_fcatalog {"rows": [
--   {"id": 1, "emb": "1.0,0.0,0.0"},
--   {"id": 2, "emb": "0.9,0.1,0.0"},
--   {"id": 3, "emb": "0.0,1.0,0.0"},
--   {"id": 4, "emb": "0.0,0.9,0.1"},
--   {"id": 5, "emb": "0.0,0.0,1.0"},
--   {"id": 6, "emb": "0.1,0.0,0.9"},
--   {"id": 7, "emb": "0.5,0.5,0.0"},
--   {"id": 8, "emb": "0.5,0.5,0.5"}
-- ]};

-- @fixture ag_fwarmup {"rows": [
--   {"id": 1, "center": "1.0,0.2,0.0"},
--   {"id": 2, "center": "0.2,1.0,0.0"},
--   {"id": 3, "center": "0.0,0.2,1.0"},
--   {"id": 4, "center": "0.8,0.0,0.4"},
--   {"id": 5, "center": "0.4,0.8,0.0"},
--   {"id": 6, "center": "0.0,0.4,0.8"},
--   {"id": 7, "center": "0.6,0.6,0.1"},
--   {"id": 8, "center": "0.3,0.3,0.9"}
-- ]};

-- @call agent/feedback_audit {"catalog_table": "ag_fcatalog", "emb_col": "emb",
--                            "query_vec": "0.5,0.5,0.5",
--                            "warmup_table": "ag_fwarmup", "warmup_vec_col": "center",
--                            "warmup_count": 8, "k": 3} AS ag_feedback_audit;

SELECT "diversity_quotient" AS "diversity_quotient",
       "explanation" AS "explanation"
FROM "ag_feedback_audit";

-- ---------------------------------------------------------------------------
-- 18. diverse_portfolios: the multimodal optimizer.
--
-- Enterprise-gated: the core
-- symbols are not in the community archive, so this needs the
-- licensed core. It is the one agent here that does.
-- ---------------------------------------------------------------------------
-- @call agent/diverse_portfolios {"mu": "0.05,0.1", "cov": "1,0,0,1", "cardinality": 1,
--                                 "n_restarts": 4, "overlap_threshold": 0.15,
--                                 "quality_frac": 0.90, "objective_mode": "sharpe"} AS ag_diverse;

SELECT "objective_mode" AS "objective_mode", "candidates" AS "candidates"
FROM "ag_diverse";

-- ---------------------------------------------------------------------------
-- 19. sql_agent: the self-correcting SQL agent.
--
-- Generate a statement, check it against the operator's allowlist and
-- against Druid's own parser, have the model review its own work, and
-- retry with the rejection as feedback.
-- ---------------------------------------------------------------------------
-- @call agent/sql_agent {"question": "total amount spent per category in ag_data",
--                        "table_names": ["ag_data"], "max_retries": 3,
--                        "auto_execute": 1} AS ag_sql_agent;

SELECT "generated_sql" AS "generated_sql",
       "execution_status" AS "execution_status",
       "retry_count" AS "retry_count"
FROM "ag_sql_agent";

-- ---------------------------------------------------------------------------
-- 20. Closing narrative: one reasoning call over the real results.
--
-- The numbers come into the context as text read out of the JSON
-- documents the core wrote: Druid's planner rewrites a one-argument
-- CAST into a broken two-argument form, so a number is never cast by
-- hand here.
-- ---------------------------------------------------------------------------
SELECT fractal_reason(
    'Synthesize a one-paragraph ops brief across the agent tier: the '
    || 'anomaly-triage threat score, the allocation Sharpe, the route_task '
    || 'routed_to and confidence, the outlier_intercept decisions, the '
    || 'recall, the patient triage, the workload assignment, the rebalance, '
    || 'the detour and track readings, and the coverage and regime drift '
    || 'flags above, and what each implies for the on-call engineer.',
    '{"source": "demo-agents.sql",'
    || '"drift": "' || (SELECT fractal_json_text("d", '$.drift') FROM "ag_drift")
    || '", "routed_to": "' || (SELECT "routed_to" FROM "ag_route")
    || '", "sharpe": "' || (SELECT fractal_json_text("rj", '$.sharpe') FROM "ag_opt")
    || '"}'
) AS "narrative";

-- ---------------------------------------------------------------------------
-- 21. The headline.
--
-- The kit passes when the tier really did what it claims: the drifting
-- host's series really does carry a regime change, the router really
-- did pick the capability nearest the task, the interceptor really did
-- separate the near probe from the far one, the recall really was
-- restricted to the cohort, and the patient's cohort really is the
-- two-predicate one.
-- ---------------------------------------------------------------------------
SELECT CASE
           WHEN (SELECT COUNT(*) FROM "ag_logs") = 98
            AND (SELECT ABS(fractal_json_value("d", '$.drift')) FROM "ag_drift" GROUP BY "d") > 0.5
            AND (SELECT ABS("threat_score") FROM "ag_triage") > 0.5
            AND (SELECT "routed_to" FROM "ag_route") = 'root-cause-analyzer'
            AND (SELECT "intercepted" FROM "ag_out_near") = 'true'
            AND (SELECT "intercepted" FROM "ag_out_far") = 'false'
            AND (SELECT "intercepted" FROM "ag_out_l2") = 'false'
            AND (SELECT COUNT(*) FROM "ag_recall") = 2
            AND (SELECT COUNT(*) FROM "ag_mem" WHERE "customer_id" = 'cust-a') = 2
            AND (SELECT COUNT(*) FROM "ag_patients"
                 WHERE "age" > 65 AND "condition" = 'sepsis') = 2
            AND (SELECT fractal_dimension_dfa("s") FROM "ag_heading") > 1.0
            THEN 'HEADLINE kit=demo-agents ok'
            ELSE 'HEADLINE kit=demo-agents FAILED'
       END AS "headline";
