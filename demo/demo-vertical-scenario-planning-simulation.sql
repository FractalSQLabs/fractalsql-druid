-- demo/demo-vertical-scenario-planning-simulation.sql
--
-- FractalSQL for Apache Druid -- industry vertical: strategic scenario
-- planning and simulation training -- business continuity, logistics
-- contingency, tabletop and training exercises. A DOMAIN kit built on
-- one installed agent, fractal_agent_plan_explore (MCTS-style
-- exploration), reused verbatim: its designed job is to produce a
-- SPREAD of distinct, non-overlapping strategy trajectories from a
-- seed state, which is exactly a scenario variant set.
--
--   1. A strategy / scenario space (24 candidate scenarios placed in a
--      4-dimension option space: cost, risk, speed, resilience).
--   2. fractal_search_explore (Scout, the diversity-first search) over
--      the raw option space -- pure analytics, no model -- to pick six
--      deliberately different scenarios.
--   3. fractal_agent_plan_explore -- the shipped agent: Scout-searches
--      the scenarios' embeddings for diverse branches from a seed
--      state.
--   4. A closing fractal_reason() summarizes the generated scenario
--      set.
--
-- Prerequisites: the extension is loaded on the Druid cluster. The
-- agent's rationale and the closing narrative need a reasoning provider
-- (docs/reasoning-setup.md); every other step runs with no model.
--
-- Run:
--   python3 demo/run_demo.py --file demo/demo-vertical-scenario-planning-simulation.sql
--
-- ===========================================================================
-- Notes on how this runs on Druid
-- ===========================================================================
--
--   * The scenario space is a fixture: Druid has no DDL, no VALUES and
--     no recursive CTE, so the 24 candidates' coordinates are computed
--     by the generator and handed over as rows.
--   * The scenario descriptions' embeddings are a deterministic
--     fixture. The vectorizer's registry is per node on Druid, so a kit that
--     registered one would leave it running for every other kit on the
--     shared node. The tier itself is exercised in demo-vectorizer.sql.
--   * The planner's seed is a vector, not a sentence: the agent's
--     argument is the vector, so the seed is the disruption profile
--     itself.
--   * Scout over the whole option space is a @call service call
--     (search/explore): it is a corpus search, not a Druid aggregate.
--   * The picks are matched back to their scenario rows by their id,
--     not by their coordinates: the service returns the id of every
--     row the population chose.
--
-- Notes:
--   * Fully deterministic fixtures (no random()).
--   * Scout (fractal_search_explore) is a MMR diversity search:
--     lowering mmr_lambda trades relevance to the seed for spread.

-- ---------------------------------------------------------------------------
-- 0. Sanity check: extension loaded?
-- ---------------------------------------------------------------------------
SELECT fractal_edition(), fractal_version();

-- ---------------------------------------------------------------------------
-- 1. 24 candidate scenarios in four clusters of six. Coordinates are
-- [cost, risk, speed, resilience], each in 0..1.
-- ---------------------------------------------------------------------------
-- @fixture sps_scenarios {"rows": [
--   {"id": 1, "description": "nearshore relocation of critical lines (variant 1)", "cost": 0.86, "risk": 0.36, "speed": 0.26, "resilience": 0.79, "opt_vec": "0.860,0.360,0.260,0.790", "embedding": "0.4050,0.5950,0.2600,0.7900"},
--   {"id": 2, "description": "regional hub-and-spoke redistribution (variant 2)", "cost": 0.42, "risk": 0.32, "speed": 0.67, "resilience": 0.58, "opt_vec": "0.420,0.320,0.670,0.580", "embedding": "0.6100,0.3900,0.6700,0.5800"},
--   {"id": 3, "description": "expedited air-freight surge capacity (variant 3)", "cost": 0.93, "risk": 0.55, "speed": 0.98, "resilience": 0.32, "opt_vec": "0.930,0.550,0.980,0.320", "embedding": "0.8150,0.2000,0.9800,0.3200"},
--   {"id": 4, "description": "dual-source suppliers with safety stock (variant 4)", "cost": 0.74, "risk": 0.21, "speed": 0.4, "resilience": 0.81, "opt_vec": "0.740,0.210,0.400,0.810", "embedding": "0.2200,0.7950,0.4000,0.8100"},
--   {"id": 5, "description": "nearshore relocation of critical lines (variant 5)", "cost": 0.85, "risk": 0.37, "speed": 0.26, "resilience": 0.8, "opt_vec": "0.850,0.370,0.260,0.800", "embedding": "0.4000,0.5900,0.2600,0.8000"},
--   {"id": 6, "description": "regional hub-and-spoke redistribution (variant 6)", "cost": 0.41, "risk": 0.3, "speed": 0.67, "resilience": 0.59, "opt_vec": "0.410,0.300,0.670,0.590", "embedding": "0.6050,0.4000,0.6700,0.5900"},
--   {"id": 7, "description": "expedited air-freight surge capacity (variant 7)", "cost": 0.92, "risk": 0.56, "speed": 0.98, "resilience": 0.33, "opt_vec": "0.920,0.560,0.980,0.330", "embedding": "0.8100,0.1950,0.9800,0.3300"},
--   {"id": 8, "description": "dual-source suppliers with safety stock (variant 8)", "cost": 0.73, "risk": 0.22, "speed": 0.4, "resilience": 0.82, "opt_vec": "0.730,0.220,0.400,0.820", "embedding": "0.2150,0.7900,0.4000,0.8200"},
--   {"id": 9, "description": "nearshore relocation of critical lines (variant 9)", "cost": 0.89, "risk": 0.35, "speed": 0.26, "resilience": 0.76, "opt_vec": "0.890,0.350,0.260,0.760", "embedding": "0.4200,0.6000,0.2600,0.7600"},
--   {"id": 10, "description": "regional hub-and-spoke redistribution (variant 10)", "cost": 0.4, "risk": 0.31, "speed": 0.67, "resilience": 0.6, "opt_vec": "0.400,0.310,0.670,0.600", "embedding": "0.6000,0.3950,0.6700,0.6000"},
--   {"id": 11, "description": "expedited air-freight surge capacity (variant 11)", "cost": 0.91, "risk": 0.57, "speed": 0.98, "resilience": 0.34, "opt_vec": "0.910,0.570,0.980,0.340", "embedding": "0.8050,0.1900,0.9800,0.3400"},
--   {"id": 12, "description": "dual-source suppliers with safety stock (variant 12)", "cost": 0.72, "risk": 0.2, "speed": 0.4, "resilience": 0.83, "opt_vec": "0.720,0.200,0.400,0.830", "embedding": "0.2100,0.8000,0.4000,0.8300"},
--   {"id": 13, "description": "nearshore relocation of critical lines (variant 13)", "cost": 0.88, "risk": 0.36, "speed": 0.26, "resilience": 0.77, "opt_vec": "0.880,0.360,0.260,0.770", "embedding": "0.4150,0.5950,0.2600,0.7700"},
--   {"id": 14, "description": "regional hub-and-spoke redistribution (variant 14)", "cost": 0.44, "risk": 0.32, "speed": 0.67, "resilience": 0.56, "opt_vec": "0.440,0.320,0.670,0.560", "embedding": "0.6200,0.3900,0.6700,0.5600"},
--   {"id": 15, "description": "expedited air-freight surge capacity (variant 15)", "cost": 0.9, "risk": 0.55, "speed": 0.98, "resilience": 0.35, "opt_vec": "0.900,0.550,0.980,0.350", "embedding": "0.8000,0.2000,0.9800,0.3500"},
--   {"id": 16, "description": "dual-source suppliers with safety stock (variant 16)", "cost": 0.71, "risk": 0.21, "speed": 0.4, "resilience": 0.84, "opt_vec": "0.710,0.210,0.400,0.840", "embedding": "0.2050,0.7950,0.4000,0.8400"},
--   {"id": 17, "description": "nearshore relocation of critical lines (variant 17)", "cost": 0.87, "risk": 0.37, "speed": 0.26, "resilience": 0.78, "opt_vec": "0.870,0.370,0.260,0.780", "embedding": "0.4100,0.5900,0.2600,0.7800"},
--   {"id": 18, "description": "regional hub-and-spoke redistribution (variant 18)", "cost": 0.43, "risk": 0.3, "speed": 0.67, "resilience": 0.57, "opt_vec": "0.430,0.300,0.670,0.570", "embedding": "0.6150,0.4000,0.6700,0.5700"},
--   {"id": 19, "description": "expedited air-freight surge capacity (variant 19)", "cost": 0.94, "risk": 0.56, "speed": 0.98, "resilience": 0.31, "opt_vec": "0.940,0.560,0.980,0.310", "embedding": "0.8200,0.1950,0.9800,0.3100"},
--   {"id": 20, "description": "dual-source suppliers with safety stock (variant 20)", "cost": 0.7, "risk": 0.22, "speed": 0.4, "resilience": 0.85, "opt_vec": "0.700,0.220,0.400,0.850", "embedding": "0.2000,0.7900,0.4000,0.8500"},
--   {"id": 21, "description": "nearshore relocation of critical lines (variant 21)", "cost": 0.86, "risk": 0.35, "speed": 0.26, "resilience": 0.79, "opt_vec": "0.860,0.350,0.260,0.790", "embedding": "0.4050,0.6000,0.2600,0.7900"},
--   {"id": 22, "description": "regional hub-and-spoke redistribution (variant 22)", "cost": 0.42, "risk": 0.31, "speed": 0.67, "resilience": 0.58, "opt_vec": "0.420,0.310,0.670,0.580", "embedding": "0.6100,0.3950,0.6700,0.5800"},
--   {"id": 23, "description": "expedited air-freight surge capacity (variant 23)", "cost": 0.93, "risk": 0.57, "speed": 0.98, "resilience": 0.32, "opt_vec": "0.930,0.570,0.980,0.320", "embedding": "0.8150,0.1900,0.9800,0.3200"},
--   {"id": 24, "description": "dual-source suppliers with safety stock (variant 24)", "cost": 0.74, "risk": 0.2, "speed": 0.4, "resilience": 0.81, "opt_vec": "0.740,0.200,0.400,0.810", "embedding": "0.2200,0.8000,0.4000,0.8100"}
-- ]};

SELECT COUNT(*) AS "scenarios" FROM "sps_scenarios";

-- ---------------------------------------------------------------------------
-- 2. Scout over the raw option space: six deliberately different
-- scenarios around the seed "current plan" (cost 0.6, risk 0.3,
-- speed 0.5, resilience 0.7). A low mmr_lambda favours spread.
-- ---------------------------------------------------------------------------
-- @call search/explore {"datasource": "sps_scenarios", "vectorColumn": "opt_vec",
--                      "idColumn": "id", "query": "0.6,0.3,0.5,0.7", "k": 6,
--                      "params": "{\"population_size\": 6, \"iterations\": 8, \"mmr_lambda\": 0.15}"} AS sps_scout;

SELECT b."ord" AS "ord", s."id" AS "id", s."description" AS "description"
FROM "sps_scout" b, "sps_scenarios" s
WHERE b."doc_id" = s."id";

-- Coverage: the scenario clusters represented in the six picks.
SELECT COUNT(DISTINCT MOD(s."id", 4)) AS "clusters_covered_of_4"
FROM "sps_scout" b, "sps_scenarios" s
WHERE b."doc_id" = s."id";

-- ---------------------------------------------------------------------------
-- 3. The shipped agent: MCTS-style exploration from a seed state.
--
-- The seed is the disruption profile itself -- a two-week port closure
-- moves cost up, risk up, speed down, resilience down -- expressed in
-- the same four dimensions the scenarios are placed in.
-- ---------------------------------------------------------------------------
-- @call agent/plan_explore {"state": "0.5000,0.5000,0.5000,0.5000",
--                           "table": "sps_scenarios", "col": "embedding",
--                           "branches": 4} AS sps_branches;

SELECT "branches" AS "branches", "state" AS "state" FROM "sps_branches";

-- ---------------------------------------------------------------------------
-- 4. Reasoning: a summary of the generated scenario set.
-- ---------------------------------------------------------------------------
-- The narrative's context is built in its own table: Druid's planner
-- rewrites a number inside a concatenation that is an argument of a
-- SQL function, and the reasoning call is one.
REPLACE INTO sps_context OVERWRITE ALL
SELECT '{"scenarios":"' || (SELECT ARRAY_TO_STRING(ARRAY_AGG("description", 16384), '; ')
                            FROM "sps_scout" b, "sps_scenarios" s
                            WHERE b."doc_id" = s."id") || '"}' AS "context"
PARTITIONED BY ALL;

SELECT fractal_reason(
    'one-line summary of how these continuity scenarios differ and when to use each',
    "context") AS "narrative"
FROM "sps_context";

-- ---------------------------------------------------------------------------
-- 5. The headline.
--
-- The kit passes when the space is the one the kit drew: 24 candidate
-- scenarios, six Scout picks, at least three of the four scenario
-- clusters represented among them, and the planner's four branches
-- materialized. Those are the kit's own numbers, not the model's
-- opinion of them.
-- ---------------------------------------------------------------------------
SELECT CASE
           WHEN (SELECT COUNT(*) FROM "sps_scenarios") = 24
            AND (SELECT COUNT(*) FROM "sps_scout") = 6
            AND (SELECT COUNT(DISTINCT MOD(s."id", 4))
                 FROM "sps_scout" b, "sps_scenarios" s
                 WHERE b."doc_id" = s."id") >= 3
            AND (SELECT COUNT(*) FROM "sps_branches") = 1
            AND (SELECT "branches" FROM "sps_branches") = 4
            THEN 'HEADLINE kit=scenario-planning-simulation ok'
            ELSE 'HEADLINE kit=scenario-planning-simulation FAILED'
       END AS "headline";
