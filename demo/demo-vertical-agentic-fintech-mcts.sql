-- demo/demo-vertical-agentic-fintech-mcts.sql
--
-- FractalSQL for Apache Druid -- industry vertical: scenario exploration
-- and safe execution. A small space of trading strategies, the
-- portfolios the regulatory audit has to look at, and the decision the
-- agent has to make: which execution paths to explore (MCTS-style
-- branching), what the regulator's question adds up to, and how the
-- portfolio should be rebalanced against the allocations already on
-- record.
--
--   1. The strategy space.
--   2. fractal_agent_plan_explore: the branches to explore.
--   3. fractal_agent_data_analyst: the regulatory audit in plain
--      English, executed against the portfolio tables.
--   4. The rebalance: the optimizer, the nearest prior allocation,
--      and the shipped agent that does both.
--   5. A closing fractal_reason() writes the plan.
--
-- Prerequisites: the extension is loaded on the Druid cluster. The
-- agents' rationales and the closing plan need a reasoning provider
-- (docs/reasoning-setup.md); every other step runs with no model.
--
-- Run:
--   python3 demo/run_demo.py --file demo/demo-vertical-agentic-fintech-mcts.sql
--
-- ===========================================================================
-- Notes on how this runs on Druid
-- ===========================================================================
--
--   * The five tables are @fixture directives: Druid has no DDL, no
--     VALUES and no recursive CTE, so a set of rows has no SQL form.
--   * The strategy descriptions' embeddings are a deterministic
--     fixture. The vectorizer's registry is per node on Druid, so a kit that
--     registered one would leave it running for every other kit on the
--     shared node. The tier itself is exercised in demo-vectorizer.sql.
--   * The optimizer's weights are read back out of its own result with
--     fractal_json_text and written into a datasource, because the
--     trajectory search takes its baseline and current vectors from
--     tables -- an agent's argument cannot be a computed expression.
--   * The text-to-SQL agent names the tables it may use, but it does
--     not see the schema, so the question below carries the column
--     names it needs. The generated statement is validated against
--     Druid's own parser before it runs.
--   * The assets' "value" column is "asset_value" here: VALUE is a
--     reserved word in Druid's SQL, and a column of that name cannot
--     be referenced unquoted.
--   * The agents are service calls: an agent reads a table and reasons
--     about it, and a Druid SQL function can do neither.
--
-- Notes:
--   * Fully deterministic fixtures (no random()).

-- ---------------------------------------------------------------------------
-- 0. Sanity check: extension loaded?
-- ---------------------------------------------------------------------------
SELECT fractal_edition(), fractal_version();

-- ---------------------------------------------------------------------------
-- 1. The strategy space.
--
-- Each strategy carries its trajectory (a CSV vector), its risk
-- constraints (a JSON document), its expected return, and the
-- embedding the exploration searches.
-- ---------------------------------------------------------------------------
-- @fixture afm_trade_strategies {"rows": [
--   {"strategy_id": 1, "description": "low-volatility mean-reversion strategy targeting ESG-compliant equities with tight risk bounds", "trajectory": "0.1,0.2", "constraints": "{\"max_risk\": 0.05}", "expected_return": 0.08, "embedding": "0.2013,0.8387,0.3313"},
--   {"strategy_id": 2, "description": "momentum strategy riding medium-term trends with moderate risk tolerance and diversified sector exposure", "trajectory": "0.5,0.1", "constraints": "{\"max_risk\": 0.10}", "expected_return": 0.12, "embedding": "0.5513,0.2812,0.1847"},
--   {"strategy_id": 3, "description": "high-conviction concentrated strategy with strict risk budget and low expected turnover", "trajectory": "0.9,0.8", "constraints": "{\"max_risk\": 0.02}", "expected_return": 0.04, "embedding": "0.8571,0.1466,0.6021"}
-- ]};

SELECT "strategy_id", "description", "trajectory", "expected_return"
FROM "afm_trade_strategies";

-- ---------------------------------------------------------------------------
-- 2. fractal_agent_plan_explore: the branches to explore.
--
-- The agent Scout-searches the strategies' embedding column for
-- diverse branches, starting from the seed market state. (The seed is the
-- vector itself, because the agent's argument is the vector.)
--
-- The search the agent wraps, so the branches are queryable.
-- ---------------------------------------------------------------------------
-- @call search/explore {"datasource": "afm_trade_strategies", "vectorColumn": "embedding",
--                      "idColumn": "strategy_id", "query": "0.5,0.3,0.2", "k": 3,
--                      "params": "{\"population_size\": 3, \"iterations\": 8}"} AS afm_branches;

SELECT b."ord" AS "ord", s."strategy_id" AS "strategy_id", s."description" AS "description",
       s."expected_return" AS "expected_return"
FROM "afm_branches" b, "afm_trade_strategies" s
WHERE b."doc_id" = s."strategy_id";

-- The shipped agent: the same composition, one call.
-- ---------------------------------------------------------------------------
-- @call agent/plan_explore {"state": "0.5,0.3,0.2",
--                           "table": "afm_trade_strategies", "col": "embedding",
--                           "branches": 3};

-- ---------------------------------------------------------------------------
-- 3. fractal_agent_data_analyst: the regulatory audit.
--
-- The agent writes the statement, Druid's parser validates it, and
-- then it runs.
-- ---------------------------------------------------------------------------
-- @fixture afm_portfolios {"rows": [
--   {"portfolio_id": 1, "name": "Global Growth"},
--   {"portfolio_id": 2, "name": "ESG Core"},
--   {"portfolio_id": 3, "name": "High Yield"}
-- ]};

-- @fixture afm_assets {"rows": [
--   {"asset_id": 101, "portfolio_id": 1, "esg_restricted": 0, "asset_value": 250000},
--   {"asset_id": 102, "portfolio_id": 1, "esg_restricted": 1, "asset_value": 120000},
--   {"asset_id": 103, "portfolio_id": 2, "esg_restricted": 1, "asset_value": 80000},
--   {"asset_id": 104, "portfolio_id": 3, "esg_restricted": 0, "asset_value": 310000}
-- ]};

-- @fixture afm_restrictions {"rows": [
--   {"restriction_id": 1, "asset_id": 102, "restriction_type": "ESG-fossil-fuel"},
--   {"restriction_id": 2, "asset_id": 103, "restriction_type": "ESG-weapons"}
-- ]};

-- The regulatory tables, read once so the broker's schema cache has
-- them before the agent writes its statement.
SELECT "asset_id", "portfolio_id", "asset_value", "esg_restricted"
FROM "afm_assets";

SELECT "restriction_id", "asset_id", "restriction_type"
FROM "afm_restrictions";

-- @call agent/data_analyst {
--      "question": "What is the total exposure to ESG-restricted assets across all portfolios: the sum of asset_value over every asset whose esg_restricted flag is 1? Use the table afm_assets, whose columns are asset_id (a number), portfolio_id (a number), asset_value (a number) and esg_restricted (a number, 1 when the asset is ESG-restricted).",
--      "table_names": "[\"afm_assets\"]",
--      "max_retries": 4} AS afm_audit;

SELECT "question", "generated_sql", "execution_status" FROM "afm_audit";

-- ---------------------------------------------------------------------------
-- 4. The rebalance.
--
-- The optimizer's own answer: the allocation it would make, and its
-- Sharpe ratio. (cov is a FLATTENED 1-D CSV of length n_assets^2 -- the
-- 2x2 identity here is '1,0,0,1' row-major.)
-- ---------------------------------------------------------------------------
SELECT fractal_optimize_portfolio('0.05,0.1', '1,0,0,1', 2) AS "allocation";

-- The weights, on their own, so the trajectory search can read them.
REPLACE INTO afm_opt OVERWRITE ALL
SELECT fractal_json_text(fractal_optimize_portfolio('0.05,0.1', '1,0,0,1', 2), '$.weights') AS "weights"
PARTITIONED BY ALL;

-- The equal-weight baseline the rebalance is measured from.
-- @fixture afm_baseline {"rows": [
--   {"id": 1, "weights": "0.5,0.5"}
-- ]};

-- The nearest prior allocation: which stored allocation the new one is
-- closest to.
-- @fixture afm_historical_allocations {"rows": [
--   {"alloc_id": 1, "label": "Q1-2025 momentum tilt", "weights": "0.6,0.4"},
--   {"alloc_id": 2, "label": "Q2-2025 defensive tilt", "weights": "0.3,0.7"},
--   {"alloc_id": 3, "label": "Q3-2025 balanced", "weights": "0.5,0.5"}
-- ]};

-- @call search/trajectory {"table": "afm_historical_allocations", "column": "weights",
--                         "id_column": "alloc_id",
--                         "baseline_table": "afm_baseline", "baseline_column": "weights",
--                         "current_table": "afm_opt", "current_column": "weights",
--                         "k": 3} AS afm_traj;

SELECT t."doc_id" AS "alloc_id", h."label" AS "label",
       ROUND(t."distance", 4) AS "distance"
FROM "afm_traj" t, "afm_historical_allocations" h
WHERE t."doc_id" = h."alloc_id";

-- The shipped agent: the same composition, one call.
-- ---------------------------------------------------------------------------
-- @call agent/rebalance_sibling {"mu": "0.05,0.1", "cov": "1,0,0,1", "cardinality": 2,
--                                "alloc_table": "afm_historical_allocations",
--                                "alloc_emb_col": "weights", "id_column": "alloc_id",
--                                "baseline_vec": "0.5,0.5", "k": 3} AS afm_rebalance;

SELECT "sharpe", "nearest_alloc_id", "nearest_distance" FROM "afm_rebalance";

-- ---------------------------------------------------------------------------
-- 5. Reasoning: the plan.
-- ---------------------------------------------------------------------------
SELECT fractal_reason(
    'one-line rebalance rationale for this portfolio: the allocation, the prior allocation it resembles, and the branch to explore',
    '{"branches":"' || (SELECT ARRAY_TO_STRING(ARRAY_AGG(CAST("doc_id" AS VARCHAR), 8192), ',')
                           FROM "afm_branches")
     || '","nearest_allocation":"' || (SELECT ARRAY_TO_STRING(ARRAY_AGG(CAST("doc_id" AS VARCHAR), 8192), ',')
                                      FROM "afm_traj")
     || '","audit":"' || (SELECT CAST("execution_status" AS VARCHAR) FROM "afm_audit")
     || '","sharpe":"' || (SELECT CAST("sharpe" AS VARCHAR) FROM "afm_rebalance")
     || '"}') AS "narrative";

-- ---------------------------------------------------------------------------
-- 6. The kit's own headline check.
--
-- The demo contract: a kit prints its headline and exits
-- non-zero unless the result holds. Three branches explored, the audit
-- statement executed, and the rebalance's nearest prior allocation
-- found.
-- ---------------------------------------------------------------------------
SELECT CASE
           WHEN (SELECT COUNT(*) FROM "afm_trade_strategies") = 3
            AND (SELECT COUNT(*) FROM "afm_branches" WHERE "doc_id" IS NOT NULL) = 3
            AND (SELECT COUNT(*) FROM "afm_audit") = 1
            AND (SELECT "execution_status" FROM "afm_audit") = 'success'
            AND (SELECT COUNT(*) FROM "afm_historical_allocations") = 3
            AND (SELECT COUNT(*) FROM "afm_traj" WHERE "doc_id" IS NOT NULL) >= 1
            AND (SELECT COUNT(*) FROM "afm_rebalance") = 1
            THEN 'HEADLINE kit=agentic-fintech-mcts ok'
            ELSE 'HEADLINE kit=agentic-fintech-mcts FAILED'
       END AS "headline";
