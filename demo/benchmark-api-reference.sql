-- demo/benchmark-api-reference.sql
--
-- FractalSQL for Apache Druid -- the API reference.
--
-- One pass over EVERY callable function the Druid extension exposes, grouped
-- the way its own registry groups them: the meta pair, the
-- search trio, the cognition tier, the vectorizer, the diversify and
-- feedback tier, the dimension analysis, the portfolio family, the
-- domain geometry, the telemetry search family, the analytics, the
-- vector surface, the config/session tier, the JSON accessors and the
-- enterprise tier.
--
-- This is the coverage kit. It is distinct from demo/benchmark.sql,
-- which stays scoped to its own narrower Sniper/Scout/vectorizer
-- comparison (see that file's own header comment) -- this one's job is
-- to touch every function, not to compare two of them.
--
-- Prerequisites:
--   * the extension is loaded on the Druid cluster;
--   * a reasoning provider is configured for the cognition section
--     (docs/vectorizer-setup.md) -- the calls there reach an LLM, and
--     the provider's answer is unbounded, so they are the slowest part
--     of this kit;
--   * the FractalSQL Enterprise core is installed on the node for the
--     enterprise section (the ledger, the audit and the multimodal
--     portfolio family). Without it those calls report that the tier
--     is not loaded.
--
-- Run:
--   python3 demo/run_demo.py --file demo/benchmark-api-reference.sql
--
-- ===========================================================================
-- Table of contents -- the surface this kit exercises
-- ===========================================================================
--
--   Meta ............... fractal_edition, fractal_version
--   Search ............. fractal_search, fractal_search_debug,
--                        fractal_search_explore
--   Cognition .......... fractal_reason, fractal_embed, the text-to-SQL
--                        service, the data-analyst agent
--   Vectorizer ......... the vectorizer service (create, list, pause,
--                        resume) and fractal_embed over the documents
--   Diversify .......... fractal_diversify_enable, fractal_diversify_set_params,
--                        fractal_detect_collapse, fractal_explain_result,
--                        fractal_feedback_report, fractal_isolate_background,
--                        fractal_diversify_disable
--   Dimension .......... fractal_dimension_dfa, fractal_dimension_boxcount,
--                        fractal_dimension_drift
--   Portfolio .......... fractal_optimize_portfolio, fractal_optimize_portfolio_ex,
--                        fractal_optimize_portfolio_multimodal,
--                        fractal_optimize_portfolio_multimodal_ex,
--                        fractal_optimize_portfolio_multimodal_pareto
--   Geometry ........... fractal_vascular_network, fractal_cortical_folding,
--                        fractal_nerve_plexus_metric,
--                        fractal_morphological_complexity
--   Feature store ...... (none: the two feature-store functions are not available on Druid -- see below)
--   Telemetry .......... the search/telemetry, search/hybrid,
--                        search/trajectory, search/cross-modal and boxcount
--                        services
--   Analytics .......... fractal_change_point_detect, fractal_periodogram,
--                        fractal_spectrogram_entropy,
--                        fractal_tda_persistence_diagram,
--                        fractal_state_fingerprint, fractal_state_distance,
--                        fractal_cycle_detect
--   Vector math ........ fractal_vector_l2_distance, fractal_vector_l2_squared,
--                        fractal_vector_cosine_distance,
--                        fractal_vector_cosine_similarity,
--                        fractal_vector_negative_inner_product,
--                        fractal_vector_norm, fractal_vector_lp_distance,
--                        fractal_vector_hamming_distance, fractal_vector_add,
--                        fractal_vector_sub, fractal_vector_scale,
--                        fractal_vector_normalize, fractal_vector_quantize_int8,
--                        fractal_vector_quantize_binary, fractal_vector_dims,
--                        fractal_vector_to_json, fractal_vector_from_text,
--                        fractal_vector
--   Config ............. fractal_config_set, fractal_config_get,
--                        fractal_config_list, fractal_config_keys,
--                        fractal_config_reset
--   JSON ............... fractal_json_value, fractal_json_text
--   Enterprise ......... fractal_ledger_truth_count, fractal_ledger_shadow_count,
--                        fractal_ledger_verify
--                        (the tier's mutating half -- fractal_ledger_flush,
--                        fractal_ledger_load, fractal_ledger_compact,
--                        fractal_ledger_reset_soft,
--                        fractal_ledger_reset_hard and fractal_audit_log --
--                        writes the node's shared chain, and
--                        fractal_audit_unpack decodes the blob a flush
--                        sealed, so section 14 names them and leaves
--                        them to demo/enterprise-qtl-audit.sql)
--
-- ===========================================================================
-- Notes on how this runs on Druid
-- ===========================================================================
--
--   * The registry in druid-extension/.../FractalFn.java defines the surface, and every function here is FRACTAL_*: edition and version are fractal_edition / fractal_version, and configuration is fractal_config_set / fractal_config_get, with the session id as an explicit argument (a Druid query has no connection to hang a
--     session on).
--   * There is no DDL, no VALUES, no recursive CTE, no group_concat
--     and no json_each. The corpus is a fixture, the walks are
--     fixtures, the series are text literals, and a JSON document is
--     read with fractal_json_value / fractal_json_text. Druid 38 has
--     no MOD function either, so a statement that needs a parity says it out.
--   * The vectors are TEXT on Druid -- CSV ("0.1,0.2,0.3") or bracketed
--     JSON -- so each series is one string literal.
--   * A search over a whole corpus is a SERVICE call (search/explore,
--     search/telemetry, search/hybrid, search/trajectory,
--     search/cross-modal, boxcount): a Druid aggregate cannot hold a
--     growable buffer, and a service call has no retry of its own, so
--     the corpus is written first and read back before it is searched.
--   * fractal_search -- the one search that IS a SQL function -- is an
--     aggregate, so it needs a GROUP BY: one group per row of the
--     corpus, and the ordering is the aggregate's, not a window
--     function's.
--   * The reasoning-dependent calls are not guarded here. A failure is a
--     failed statement, so the kit states its prerequisites and calls
--     the tier when it is configured.
--   * fractal_store_morphology and fractal_mine_topology_negatives --
--     the named feature store -- are not available on Druid: the registry has no such functions, so there is no Druid shape for them.
--     Section 8 keeps the place and says so.
--   * fractal_optimize_subset is not carried either: it needs a
--     caller-supplied objective, which the core takes as a callback
--     and a Druid expression cannot. Section 8 keeps the place and
--     says so. The same is true of fractal_vector_from_float8_array / fractal_vector_to_float8_array (Druid has no float8-array type), of fractal_t2s_* (the text-to-SQL tier, which on Druid is the text-to-sql service, not a SQL function), of fractal_session_close (a Druid query has no session to close) and of fractal_agent_partial_fail (the agent tier's
--     partial-failure posture, which on Druid is the operator's
--     agent.partial_reasoning_fail setting).
--   * fractal_schema_context has no SQL shape on Druid either: the
--     schema context is the service's own GET endpoint
--     (/fractalsql/schema-context), and the demo runner speaks POST
--     only, so a kit cannot call it. Section 2 covers the rest of the
--     cognition tier.
--   * The vectorizer's registry and its queue are the extension's, not
--     TEMP objects on a connection, and the handle it hands back is
--     assigned by the node -- a kit cannot pass a computed value into
--     a service call -- so the handle-addressed actions (pause,
--     resume, drop) are not called here, and the queue's own
--     write-back is not usable on this build (it hands Druid's SQL
--     parser a row the parser cannot read). Section 3 says so where
--     it matters.
--   * The enterprise tier is in the kit as well, because the Druid
--     registry carries it: the ledger, the audit and the multimodal
--     portfolio family. fractal_lock_destructive is deliberately NOT
--     called: it is a one-way, node-level latch that no kit may set.
--     The ledger's MUTATING half is not called either: it writes the
--     node's shared chain, and a kit that rewrote the chain on every run would be a poor citizen -- the kit that
--     owns that half is demo/enterprise-qtl-audit.sql, and this kit
--     shows the read-only half (the counts and the verification walk).
--     The chain is shared NODE state, so the tier asserts itself in its
--     own section (the "ledger_check" row) and the headline does not
--     depend on it.
--   * There is no per-statement timing output: a Druid demo
--     is a script run by a client, not a shell session, so there is no
--     timer to print.
--
-- Notes:
--   * Fully deterministic fixtures (no random()).
--   * Safe to re-run: every write is OVERWRITE ALL.
--   * Ends with a HEADLINE line computed from the kit's own results
--     (HEADLINE kit=benchmark-api-reference ok); the build_test kit
--     gate greps for it.

-- ---------------------------------------------------------------------------
-- 0. Meta: the node's own identity.
-- ---------------------------------------------------------------------------
SELECT fractal_edition(), fractal_version();

-- ---------------------------------------------------------------------------
-- 1. Search: the three search forms.
--
-- The corpus is 24 rows in three clusters of eight, in R^8. The query
-- sits on the first cluster's centre, so a search that works ranks
-- that cluster first.
-- ---------------------------------------------------------------------------
-- @fixture bmk_corpus {"rows": [
--   {"id": 1, "label": "alpha", "emb": "-0.635338,0.130074,-0.548970,0.670328,-0.550804,-0.483836,-0.707878,-0.287808"},
--   {"id": 2, "label": "alpha", "emb": "-0.566183,0.007379,-0.404563,0.581608,-0.519270,-0.377950,-0.631127,-0.151591"},
--   {"id": 3, "label": "alpha", "emb": "-0.480425,0.155043,-0.418791,0.648897,-0.591641,-0.509849,-0.553051,-0.296518"},
--   {"id": 4, "label": "alpha", "emb": "-0.572003,0.081675,-0.576079,0.618458,-0.616690,-0.378043,-0.673967,-0.218709"},
--   {"id": 5, "label": "alpha", "emb": "-0.510545,-0.007617,-0.419171,0.536314,-0.613538,-0.395426,-0.562067,-0.296282"},
--   {"id": 6, "label": "alpha", "emb": "-0.553033,0.055017,-0.445804,0.522796,-0.694289,-0.493141,-0.590503,-0.298867"},
--   {"id": 7, "label": "alpha", "emb": "-0.586775,0.103153,-0.479170,0.544815,-0.533616,-0.430181,-0.555334,-0.292633"},
--   {"id": 8, "label": "alpha", "emb": "-0.560958,0.103977,-0.581305,0.676489,-0.653557,-0.344288,-0.649402,-0.213715"},
--   {"id": 9, "label": "beta", "emb": "0.083447,-0.974356,0.378664,-0.571491,0.294358,0.755395,-0.415274,-0.442261"},
--   {"id": 10, "label": "beta", "emb": "0.001555,-0.931297,0.280002,-0.664741,0.126064,0.796387,-0.490727,-0.415549"},
--   {"id": 11, "label": "beta", "emb": "0.064167,-1.033879,0.431861,-0.585002,0.208073,0.836496,-0.550330,-0.481309"},
--   {"id": 12, "label": "beta", "emb": "0.007115,-0.968037,0.258865,-0.631861,0.110348,0.695833,-0.523594,-0.403233"},
--   {"id": 13, "label": "beta", "emb": "-0.067993,-1.056973,0.282315,-0.700339,0.155152,0.846917,-0.394340,-0.357122"},
--   {"id": 14, "label": "beta", "emb": "0.117431,-1.035405,0.338334,-0.702666,0.109210,0.734177,-0.531783,-0.355311"},
--   {"id": 15, "label": "beta", "emb": "0.067503,-0.935410,0.340421,-0.714193,0.224369,0.881075,-0.385440,-0.481515"},
--   {"id": 16, "label": "beta", "emb": "0.076007,-0.902562,0.311037,-0.714245,0.139633,0.698052,-0.474163,-0.439644"},
--   {"id": 17, "label": "gamma", "emb": "-0.911436,0.384609,-0.736942,-0.098901,0.171974,-0.524555,0.263917,-0.314678"},
--   {"id": 18, "label": "gamma", "emb": "-0.865362,0.406054,-0.700369,0.018474,0.111999,-0.669697,0.295197,-0.343754"},
--   {"id": 19, "label": "gamma", "emb": "-0.976897,0.494519,-0.742675,-0.076037,0.056396,-0.568506,0.129074,-0.338760"},
--   {"id": 20, "label": "gamma", "emb": "-0.886655,0.532599,-0.735248,-0.006220,0.005904,-0.687782,0.168491,-0.337833"},
--   {"id": 21, "label": "gamma", "emb": "-0.840873,0.441822,-0.801405,-0.058780,0.074195,-0.662919,0.223217,-0.370505"},
--   {"id": 22, "label": "gamma", "emb": "-0.842217,0.503195,-0.810461,0.065637,0.068647,-0.584608,0.175672,-0.264731"},
--   {"id": 23, "label": "gamma", "emb": "-0.947037,0.402829,-0.716301,-0.080049,0.004568,-0.669831,0.178000,-0.359484"},
--   {"id": 24, "label": "gamma", "emb": "-0.823052,0.508601,-0.738556,-0.066800,0.008978,-0.697999,0.240844,-0.277634"}
-- ]};

SELECT COUNT(*) AS "corpus_rows" FROM "bmk_corpus";

-- Sniper Search: the one search that is a SQL function. It is an
-- aggregate, so it needs a GROUP BY -- one group per row of the
-- corpus -- and the ordering is the aggregate's.
SELECT "id", fractal_search("emb", '-0.574830,0.091362,-0.501643,0.602100,-0.614825,-0.416330,-0.627688,-0.205005') AS "dist"
FROM "bmk_corpus"
GROUP BY "id"
ORDER BY "dist" ASC
LIMIT 3;

-- The tunable form: the SFS over the query alone, with the iteration
-- count, the population size and the diffusion factor named by the
-- caller.
REPLACE INTO bmk_sfs OVERWRITE ALL
SELECT fractal_search_debug('-0.574830,0.091362,-0.501643,0.602100,-0.614825,-0.416330,-0.627688,-0.205005', 20, 50, 2) AS "debug"
FROM UNNEST(ARRAY[1]) AS t(x)
PARTITIONED BY ALL;

SELECT fractal_json_value("debug", '$.best_fit') AS "best_fit",
       fractal_json_text("debug", '$.best_point') AS "best_point"
FROM "bmk_sfs";

-- Scout Discovery: the SFS over a whole corpus, with the walk turned
-- off and the final population returned. The corpus arrives as an
-- ARRAY -- ARRAY_AGG over the column -- because a Druid aggregate
-- cannot hold a growable buffer.
REPLACE INTO bmk_scout OVERWRITE ALL
SELECT fractal_search_explore(ARRAY_AGG("emb", 16384), '0.000000,0.000000,0.000000,0.000000,0.000000,0.000000,0.000000,0.000000',
                              '{"population_size": 6, "iterations": 6, "walk": 0}') AS "scout"
FROM "bmk_corpus"
PARTITIONED BY ALL;

SELECT fractal_json_value("scout", '$.n_corpus') AS "n_corpus",
       fractal_json_value("scout", '$.dim') AS "dim"
FROM "bmk_scout";

-- ---------------------------------------------------------------------------
-- 2. Cognition: the reasoning tier, the embedding tier, the
-- text-to-SQL tier and the agent tier.
--
-- These reach an LLM over the network, so they are the slowest part
-- of the kit. The reason call asks for a one-word answer; the
-- embedding call is read for its width.
--
-- fractal_schema_context is not here: on Druid the
-- schema context is the service's own GET endpoint, and a kit cannot
-- speak GET. The text-to-SQL tier takes its place.
-- ---------------------------------------------------------------------------
SELECT fractal_reason('reply with a one-word confirmation', '{}') AS "reason";

SELECT fractal_vector_dims(fractal_embed('a short benchmark sentence')) AS "embed_dims";

-- The text-to-SQL tier. The endpoint validates the statement it got
-- from the model with EXPLAIN PLAN FOR before it hands it over, so a
-- statement Druid cannot plan comes back as "valid: false" rather than
-- as if it worked.
-- @call text-to-sql {"question": "How many rows are in the table bmk_corpus? The table bmk_corpus has columns id (long), label (varchar), emb (varchar). In Druid SQL the table name is written in double quotes.",
--                   "tables": ["bmk_corpus"]} AS bmk_t2s;

SELECT "generated_sql" AS "sql_text", "valid" FROM "bmk_t2s";

-- The agent tier: the data-analyst agent. It generates the
-- statement, validates it, runs it, and hands back the rows.
-- @call agent/data_analyst {"question": "How many rows are in the table bmk_corpus? The table bmk_corpus has columns id (long), label (varchar), emb (varchar). In Druid SQL the table name is written in double quotes.",
--                          "table_names": ["bmk_corpus"],
--                          "max_retries": 3} AS bmk_agent;

SELECT "generated_sql" AS "sql_text", "execution_status" FROM "bmk_agent";

-- ---------------------------------------------------------------------------
-- 3. The vectorizer: the embedding queue.
--
-- The registry is the extension's, and it lives on the node, so the
-- list call shows every vectorizer the node knows -- this kit's and
-- every other kit's.
-- ---------------------------------------------------------------------------
-- @fixture bmk_docs {"rows": [
--   {"id": 1, "body": "benchmark document number 1: FractalSQL runs vector search directly inside the Druid cluster."},
--   {"id": 2, "body": "benchmark document number 2: FractalSQL runs vector search directly inside the Druid cluster."},
--   {"id": 3, "body": "benchmark document number 3: FractalSQL runs vector search directly inside the Druid cluster."},
--   {"id": 4, "body": "benchmark document number 4: FractalSQL runs vector search directly inside the Druid cluster."},
--   {"id": 5, "body": "benchmark document number 5: FractalSQL runs vector search directly inside the Druid cluster."}
-- ]};

-- @call vectorizer {"action": "create", "source_table": "bmk_docs",
--                   "source_column": "body",
--                   "embedding_column": "bmk_docs_embedding",
--                   "id_column": "id"} AS bmk_vec_created;

-- @call vectorizer {"action": "list"} AS bmk_vec_registry;

SELECT "id" AS "vectorizer_id", "source_table" AS "source_table",
       "embedding_column" AS "embedding_column"
FROM "bmk_vec_registry"
WHERE "source_table" = 'bmk_docs';

-- The pause, resume and drop actions take the vectorizer's handle,
-- and the handle is assigned by the NODE: it is not the row's id, and
-- it is not something a kit can compute. A kit has no way to pass a
-- computed value into a service call -- the runner substitutes only
-- the text of the previous call -- so this kit cannot address the
-- vectorizer it has just created, and it does not pause, resume or
-- drop a handle it does not own: that would be another kit's
-- workload. The registry listing below shows the handle the node
-- assigned to this kit's own vectorizer, which is where the handle-
-- addressed actions would be pointed by a caller that can read it.
--
-- So the vectorizer this kit registers stays in the node's registry,
-- the way demo/benchmark.sql's does. The extension refuses to register
-- the same vectorizer twice, so a second run finds it already there and
-- the runner carries on with the existing entry: the registry does not
-- grow with each run.
--
-- The queue's own write-back (process_queue) is NOT usable on this
-- build: it hands Druid's SQL parser a row the parser cannot read,
-- and the call fails. The embedding itself is measured through
-- fractal_embed below, over the same documents.
REPLACE INTO bmk_emb OVERWRITE ALL
SELECT t."id" AS "id", fractal_vector_dims(fractal_embed(t."body")) AS "dims"
FROM "bmk_docs" t
PARTITIONED BY ALL;

SELECT COUNT(*) AS "embedded", MAX("dims") AS "dims" FROM "bmk_emb";

-- ---------------------------------------------------------------------------
-- 4. Diversify / repulsion and the feedback tier.
--
-- The order matters. fractal_detect_collapse reads the monitor's last
-- diversity quotient, and the monitor has no measurement until a
-- search has run with it on -- so the search comes first.
-- ---------------------------------------------------------------------------
SELECT fractal_diversify_enable();

SELECT fractal_diversify_set_params('{"population_size": 8, "mmr_lambda": 0.5}');

SELECT "id", fractal_search("emb", '-0.574830,0.091362,-0.501643,0.602100,-0.614825,-0.416330,-0.627688,-0.205005') AS "dist"
FROM "bmk_corpus"
GROUP BY "id"
ORDER BY "dist" ASC
LIMIT 3;

SELECT fractal_detect_collapse() AS "dq";

SELECT fractal_explain_result() AS "diagnostics";

-- The feedback report: a caller's verdict on a result, which the
-- ledger records.
SELECT fractal_feedback_report(1, 'positive', 4000);
SELECT fractal_feedback_report(2, 'dwell', 1200);
SELECT fractal_feedback_report(3, 'negative', 0);

-- The isolated background: a result the caller has set aside.
SELECT fractal_isolate_background(2);

SELECT fractal_diversify_disable();

-- ---------------------------------------------------------------------------
-- 5. Dimension analysis.
--
-- The walk is 200 steps of a hashed random walk, carried in the
-- fixture the other kits use in place of a window function; the grid
-- is a 20x20 jittered lattice, which is the shape the box-counting
-- needs to find three valid epsilon octaves.
-- ---------------------------------------------------------------------------
-- @fixture bmk_walk {"rows": [
--   {"t": 1, "s": -0.022139},
--   {"t": 2, "s": -0.019228},
--   {"t": 3, "s": -0.025541},
--   {"t": 4, "s": -0.027867},
--   {"t": 5, "s": -0.021563},
--   {"t": 6, "s": -0.038284},
--   {"t": 7, "s": -0.046828},
--   {"t": 8, "s": -0.044847},
--   {"t": 9, "s": -0.021272},
--   {"t": 10, "s": -0.005212},
--   {"t": 11, "s": -0.02126},
--   {"t": 12, "s": 0.003499},
--   {"t": 13, "s": 0.0193},
--   {"t": 14, "s": 0.016391},
--   {"t": 15, "s": 0.037735},
--   {"t": 16, "s": 0.034444},
--   {"t": 17, "s": 0.041654},
--   {"t": 18, "s": 0.032786},
--   {"t": 19, "s": 0.045805},
--   {"t": 20, "s": 0.048606},
--   {"t": 21, "s": 0.05665},
--   {"t": 22, "s": 0.052617},
--   {"t": 23, "s": 0.034405},
--   {"t": 24, "s": 0.025929},
--   {"t": 25, "s": 0.025695},
--   {"t": 26, "s": 0.000711},
--   {"t": 27, "s": -0.016194},
--   {"t": 28, "s": -0.020184},
--   {"t": 29, "s": 0.00407},
--   {"t": 30, "s": 0.01524},
--   {"t": 31, "s": 0.004525},
--   {"t": 32, "s": 0.000428},
--   {"t": 33, "s": -0.014543},
--   {"t": 34, "s": -0.010746},
--   {"t": 35, "s": 0.01333},
--   {"t": 36, "s": 0.034358},
--   {"t": 37, "s": 0.032872},
--   {"t": 38, "s": 0.046282},
--   {"t": 39, "s": 0.051115},
--   {"t": 40, "s": 0.072828},
--   {"t": 41, "s": 0.070482},
--   {"t": 42, "s": 0.056254},
--   {"t": 43, "s": 0.065989},
--   {"t": 44, "s": 0.080788},
--   {"t": 45, "s": 0.069947},
--   {"t": 46, "s": 0.070643},
--   {"t": 47, "s": 0.052769},
--   {"t": 48, "s": 0.033488},
--   {"t": 49, "s": 0.023598},
--   {"t": 50, "s": 0.004393},
--   {"t": 51, "s": 0.019993},
--   {"t": 52, "s": 0.022687},
--   {"t": 53, "s": 0.01792},
--   {"t": 54, "s": 0.036565},
--   {"t": 55, "s": 0.035298},
--   {"t": 56, "s": 0.021548},
--   {"t": 57, "s": 0.012015},
--   {"t": 58, "s": -0.004239},
--   {"t": 59, "s": -0.020749},
--   {"t": 60, "s": -0.041639},
--   {"t": 61, "s": -0.026094},
--   {"t": 62, "s": -0.050261},
--   {"t": 63, "s": -0.070858},
--   {"t": 64, "s": -0.091981},
--   {"t": 65, "s": -0.0871},
--   {"t": 66, "s": -0.100026},
--   {"t": 67, "s": -0.105623},
--   {"t": 68, "s": -0.114214},
--   {"t": 69, "s": -0.120822},
--   {"t": 70, "s": -0.120453},
--   {"t": 71, "s": -0.13679},
--   {"t": 72, "s": -0.160346},
--   {"t": 73, "s": -0.175832},
--   {"t": 74, "s": -0.171088},
--   {"t": 75, "s": -0.188381},
--   {"t": 76, "s": -0.178743},
--   {"t": 77, "s": -0.194535},
--   {"t": 78, "s": -0.217326},
--   {"t": 79, "s": -0.205632},
--   {"t": 80, "s": -0.209059},
--   {"t": 81, "s": -0.229582},
--   {"t": 82, "s": -0.240713},
--   {"t": 83, "s": -0.26101},
--   {"t": 84, "s": -0.267192},
--   {"t": 85, "s": -0.267951},
--   {"t": 86, "s": -0.275053},
--   {"t": 87, "s": -0.277846},
--   {"t": 88, "s": -0.256445},
--   {"t": 89, "s": -0.240674},
--   {"t": 90, "s": -0.258601},
--   {"t": 91, "s": -0.257115},
--   {"t": 92, "s": -0.245247},
--   {"t": 93, "s": -0.2312},
--   {"t": 94, "s": -0.218644},
--   {"t": 95, "s": -0.197248},
--   {"t": 96, "s": -0.214936},
--   {"t": 97, "s": -0.237147},
--   {"t": 98, "s": -0.237651},
--   {"t": 99, "s": -0.249444},
--   {"t": 100, "s": -0.227794},
--   {"t": 101, "s": -0.248847},
--   {"t": 102, "s": -0.265571},
--   {"t": 103, "s": -0.265692},
--   {"t": 104, "s": -0.246032},
--   {"t": 105, "s": -0.253845},
--   {"t": 106, "s": -0.250225},
--   {"t": 107, "s": -0.239381},
--   {"t": 108, "s": -0.217127},
--   {"t": 109, "s": -0.231719},
--   {"t": 110, "s": -0.224659},
--   {"t": 111, "s": -0.247306},
--   {"t": 112, "s": -0.270732},
--   {"t": 113, "s": -0.270761},
--   {"t": 114, "s": -0.272923},
--   {"t": 115, "s": -0.274544},
--   {"t": 116, "s": -0.253726},
--   {"t": 117, "s": -0.258646},
--   {"t": 118, "s": -0.23389},
--   {"t": 119, "s": -0.245493},
--   {"t": 120, "s": -0.232359},
--   {"t": 121, "s": -0.208663},
--   {"t": 122, "s": -0.22833},
--   {"t": 123, "s": -0.253277},
--   {"t": 124, "s": -0.241707},
--   {"t": 125, "s": -0.251401},
--   {"t": 126, "s": -0.265938},
--   {"t": 127, "s": -0.244219},
--   {"t": 128, "s": -0.255734},
--   {"t": 129, "s": -0.259084},
--   {"t": 130, "s": -0.243366},
--   {"t": 131, "s": -0.229633},
--   {"t": 132, "s": -0.25371},
--   {"t": 133, "s": -0.25029},
--   {"t": 134, "s": -0.234503},
--   {"t": 135, "s": -0.252296},
--   {"t": 136, "s": -0.236906},
--   {"t": 137, "s": -0.220664},
--   {"t": 138, "s": -0.235858},
--   {"t": 139, "s": -0.238828},
--   {"t": 140, "s": -0.225118},
--   {"t": 141, "s": -0.211643},
--   {"t": 142, "s": -0.193348},
--   {"t": 143, "s": -0.214201},
--   {"t": 144, "s": -0.203072},
--   {"t": 145, "s": -0.186382},
--   {"t": 146, "s": -0.164914},
--   {"t": 147, "s": -0.159858},
--   {"t": 148, "s": -0.160795},
--   {"t": 149, "s": -0.14052},
--   {"t": 150, "s": -0.164695},
--   {"t": 151, "s": -0.185613},
--   {"t": 152, "s": -0.175107},
--   {"t": 153, "s": -0.174006},
--   {"t": 154, "s": -0.154387},
--   {"t": 155, "s": -0.131934},
--   {"t": 156, "s": -0.130805},
--   {"t": 157, "s": -0.143195},
--   {"t": 158, "s": -0.15162},
--   {"t": 159, "s": -0.131196},
--   {"t": 160, "s": -0.128716},
--   {"t": 161, "s": -0.149855},
--   {"t": 162, "s": -0.149066},
--   {"t": 163, "s": -0.165186},
--   {"t": 164, "s": -0.16753},
--   {"t": 165, "s": -0.156255},
--   {"t": 166, "s": -0.143939},
--   {"t": 167, "s": -0.143746},
--   {"t": 168, "s": -0.135089},
--   {"t": 169, "s": -0.158999},
--   {"t": 170, "s": -0.147915},
--   {"t": 171, "s": -0.129816},
--   {"t": 172, "s": -0.114815},
--   {"t": 173, "s": -0.11493},
--   {"t": 174, "s": -0.108263},
--   {"t": 175, "s": -0.1242},
--   {"t": 176, "s": -0.129761},
--   {"t": 177, "s": -0.106087},
--   {"t": 178, "s": -0.113866},
--   {"t": 179, "s": -0.090208},
--   {"t": 180, "s": -0.091947},
--   {"t": 181, "s": -0.0819},
--   {"t": 182, "s": -0.0655},
--   {"t": 183, "s": -0.090434},
--   {"t": 184, "s": -0.111332},
--   {"t": 185, "s": -0.091039},
--   {"t": 186, "s": -0.079941},
--   {"t": 187, "s": -0.082124},
--   {"t": 188, "s": -0.100252},
--   {"t": 189, "s": -0.094719},
--   {"t": 190, "s": -0.11071},
--   {"t": 191, "s": -0.107537},
--   {"t": 192, "s": -0.127826},
--   {"t": 193, "s": -0.104128},
--   {"t": 194, "s": -0.097748},
--   {"t": 195, "s": -0.107492},
--   {"t": 196, "s": -0.092827},
--   {"t": 197, "s": -0.10988},
--   {"t": 198, "s": -0.111503},
--   {"t": 199, "s": -0.10736},
--   {"t": 200, "s": -0.123679}
-- ]};

-- The DFA over the walk: the fractal dimension of the series.
REPLACE INTO bmk_dfa OVERWRITE ALL
SELECT fractal_dimension_dfa('-0.022139,-0.019228,-0.025541,-0.027867,-0.021563,-0.038284,-0.046828,-0.044847,-0.021272,-0.005212,-0.021260,0.003499,0.019300,0.016391,0.037735,0.034444,0.041654,0.032786,0.045805,0.048606,0.056650,0.052617,0.034405,0.025929,0.025695,0.000711,-0.016194,-0.020184,0.004070,0.015240,0.004525,0.000428,-0.014543,-0.010746,0.013330,0.034358,0.032872,0.046282,0.051115,0.072828,0.070482,0.056254,0.065989,0.080788,0.069947,0.070643,0.052769,0.033488,0.023598,0.004393,0.019993,0.022687,0.017920,0.036565,0.035298,0.021548,0.012015,-0.004239,-0.020749,-0.041639,-0.026094,-0.050261,-0.070858,-0.091981,-0.087100,-0.100026,-0.105623,-0.114214,-0.120822,-0.120453,-0.136790,-0.160346,-0.175832,-0.171088,-0.188381,-0.178743,-0.194535,-0.217326,-0.205632,-0.209059,-0.229582,-0.240713,-0.261010,-0.267192,-0.267951,-0.275053,-0.277846,-0.256445,-0.240674,-0.258601,-0.257115,-0.245247,-0.231200,-0.218644,-0.197248,-0.214936,-0.237147,-0.237651,-0.249444,-0.227794,-0.248847,-0.265571,-0.265692,-0.246032,-0.253845,-0.250225,-0.239381,-0.217127,-0.231719,-0.224659,-0.247306,-0.270732,-0.270761,-0.272923,-0.274544,-0.253726,-0.258646,-0.233890,-0.245493,-0.232359,-0.208663,-0.228330,-0.253277,-0.241707,-0.251401,-0.265938,-0.244219,-0.255734,-0.259084,-0.243366,-0.229633,-0.253710,-0.250290,-0.234503,-0.252296,-0.236906,-0.220664,-0.235858,-0.238828,-0.225118,-0.211643,-0.193348,-0.214201,-0.203072,-0.186382,-0.164914,-0.159858,-0.160795,-0.140520,-0.164695,-0.185613,-0.175107,-0.174006,-0.154387,-0.131934,-0.130805,-0.143195,-0.151620,-0.131196,-0.128716,-0.149855,-0.149066,-0.165186,-0.167530,-0.156255,-0.143939,-0.143746,-0.135089,-0.158999,-0.147915,-0.129816,-0.114815,-0.114930,-0.108263,-0.124200,-0.129761,-0.106087,-0.113866,-0.090208,-0.091947,-0.081900,-0.065500,-0.090434,-0.111332,-0.091039,-0.079941,-0.082124,-0.100252,-0.094719,-0.110710,-0.107537,-0.127826,-0.104128,-0.097748,-0.107492,-0.092827,-0.109880,-0.111503,-0.107360,-0.123679') AS "alpha"
FROM UNNEST(ARRAY[1]) AS t(x)
PARTITIONED BY ALL;

SELECT "alpha" FROM "bmk_dfa";

-- The box count over the lattice.
REPLACE INTO bmk_boxcount_sql OVERWRITE ALL
SELECT fractal_dimension_boxcount('0.167467,0.112120,0.136044,0.187826,0.049674,0.098733,0.161887,0.291454,0.246357,0.053713,0.298552,0.244808,0.132545,0.278064,0.130259,0.193256,0.096793,0.228113,0.166809,0.198263,1.049661,1.149273,1.267959,1.103122,1.171720,1.215061,1.283529,1.062445,1.192359,1.014119,1.009447,1.149823,1.137028,1.140274,1.274913,1.120478,1.298534,1.080383,1.228806,1.292175,2.111367,2.260524,2.191954,2.080912,2.266034,2.291487,2.127258,2.081517,2.063878,2.244781,2.239189,2.177337,2.068220,2.297546,2.034316,2.259398,2.108733,2.187818,2.146411,2.086917,3.137049,3.170150,3.212432,3.067555,3.101968,3.218932,3.282859,3.134438,3.186771,3.125808,3.109645,3.189507,3.286068,3.029252,3.041248,3.262271,3.275379,3.244899,3.277612,3.234322,4.183341,4.138894,4.177097,4.008856,4.230736,4.259376,4.130019,4.110375,4.059860,4.227113,4.261663,4.087078,4.190570,4.263834,4.228492,4.157807,4.192881,4.107951,4.118779,4.101165,5.069590,5.084951,5.064133,5.245375,5.252841,5.292953,5.109775,5.277246,5.191923,5.147112,5.271681,5.266803,5.119871,5.143243,5.034941,5.069276,5.026634,5.135761,5.260577,5.114150,6.275775,6.097966,6.139209,6.106534,6.078225,6.189707,6.170469,6.065261,6.275090,6.248162,6.209701,6.067073,6.141232,6.141195,6.160163,6.134880,6.008403,6.011443,6.009729,6.144033,7.087910,7.203084,7.276490,7.033745,7.220028,7.290172,7.133577,7.256331,7.029608,7.084656,7.285746,7.059888,7.152106,7.157535,7.006851,7.256339,7.243629,7.246486,7.168444,7.124873,8.167327,8.094505,8.133320,8.161332,8.109034,8.151650,8.286554,8.181189,8.259806,8.105662,8.115941,8.031369,8.239861,8.082101,8.187198,8.128703,8.188252,8.288549,8.037557,8.002512,9.057542,9.138868,9.126808,9.133956,9.137587,9.295898,9.274530,9.096749,9.181598,9.241287,9.168970,9.006991,9.137514,9.277472,9.233480,9.272950,9.066732,9.181636,9.287257,9.248039,10.228180,10.082410,10.046378,10.075115,10.135350,10.063775,10.163704,10.074754,10.240315,10.057776,10.087550,10.055847,10.119249,10.100360,10.208549,10.084167,10.101210,10.225918,10.222191,10.232373,11.282380,11.233044,11.057800,11.235782,11.253979,11.184002,11.034316,11.246569,11.284135,11.299342,11.234672,11.261039,11.212008,11.169185,11.039550,11.154389,11.106935,11.285384,11.070135,11.021179,12.153956,12.086690,12.207451,12.118839,12.132731,12.095849,12.156523,12.046955,12.009282,12.262866,12.263563,12.098174,12.290774,12.114620,12.031998,12.280620,12.173744,12.028031,12.111611,12.006988,13.129717,13.242942,13.210967,13.071123,13.266870,13.046642,13.092000,13.043906,13.042969,13.106228,13.026652,13.000534,13.251214,13.094530,13.255747,13.076169,13.159257,13.235586,13.152322,13.072311,14.216371,14.169345,14.237409,14.180807,14.026536,14.067817,14.299351,14.105532,14.022535,14.227567,14.247556,14.071735,14.299160,14.261467,14.259238,14.011989,14.163676,14.251561,14.017979,14.220955,15.292957,15.202004,15.180311,15.041433,15.178769,15.093879,15.184254,15.237385,15.019833,15.089773,15.099545,15.103807,15.001313,15.007677,15.265987,15.079934,15.080293,15.016030,15.256666,15.260284,16.032994,16.117649,16.138041,16.278848,16.241210,16.070510,16.029410,16.282020,16.175896,16.217605,16.137582,16.294939,16.072859,16.178933,16.276425,16.085038,16.244061,16.060312,16.152115,16.056950,17.064289,17.047747,17.290344,17.193143,17.256131,17.208725,17.112437,17.137313,17.297390,17.174074,17.292089,17.056045,17.055741,17.185632,17.184376,17.160981,17.047660,17.135203,17.268047,17.089632,18.212505,18.085437,18.110360,18.122690,18.010502,18.033854,18.170749,18.088927,18.126787,18.196704,18.184465,18.017625,18.231338,18.144570,18.209345,18.270793,18.219665,18.157563,18.002331,18.129265,19.176021,19.132295,19.200205,19.229783,19.030831,19.050428,19.010816,19.186966,19.148026,19.005230,19.110183,19.050842,19.005195,19.240288,19.001193,19.123535,19.220491,19.295802,19.263966,19.027816', 2) AS "dimension"
FROM UNNEST(ARRAY[1]) AS t(x)
PARTITIONED BY ALL;

SELECT "dimension" FROM "bmk_boxcount_sql";

-- The drift report over the same walk, with a 32-step window.
REPLACE INTO bmk_drift OVERWRITE ALL
SELECT fractal_dimension_drift('-0.022139,-0.019228,-0.025541,-0.027867,-0.021563,-0.038284,-0.046828,-0.044847,-0.021272,-0.005212,-0.021260,0.003499,0.019300,0.016391,0.037735,0.034444,0.041654,0.032786,0.045805,0.048606,0.056650,0.052617,0.034405,0.025929,0.025695,0.000711,-0.016194,-0.020184,0.004070,0.015240,0.004525,0.000428,-0.014543,-0.010746,0.013330,0.034358,0.032872,0.046282,0.051115,0.072828,0.070482,0.056254,0.065989,0.080788,0.069947,0.070643,0.052769,0.033488,0.023598,0.004393,0.019993,0.022687,0.017920,0.036565,0.035298,0.021548,0.012015,-0.004239,-0.020749,-0.041639,-0.026094,-0.050261,-0.070858,-0.091981,-0.087100,-0.100026,-0.105623,-0.114214,-0.120822,-0.120453,-0.136790,-0.160346,-0.175832,-0.171088,-0.188381,-0.178743,-0.194535,-0.217326,-0.205632,-0.209059,-0.229582,-0.240713,-0.261010,-0.267192,-0.267951,-0.275053,-0.277846,-0.256445,-0.240674,-0.258601,-0.257115,-0.245247,-0.231200,-0.218644,-0.197248,-0.214936,-0.237147,-0.237651,-0.249444,-0.227794,-0.248847,-0.265571,-0.265692,-0.246032,-0.253845,-0.250225,-0.239381,-0.217127,-0.231719,-0.224659,-0.247306,-0.270732,-0.270761,-0.272923,-0.274544,-0.253726,-0.258646,-0.233890,-0.245493,-0.232359,-0.208663,-0.228330,-0.253277,-0.241707,-0.251401,-0.265938,-0.244219,-0.255734,-0.259084,-0.243366,-0.229633,-0.253710,-0.250290,-0.234503,-0.252296,-0.236906,-0.220664,-0.235858,-0.238828,-0.225118,-0.211643,-0.193348,-0.214201,-0.203072,-0.186382,-0.164914,-0.159858,-0.160795,-0.140520,-0.164695,-0.185613,-0.175107,-0.174006,-0.154387,-0.131934,-0.130805,-0.143195,-0.151620,-0.131196,-0.128716,-0.149855,-0.149066,-0.165186,-0.167530,-0.156255,-0.143939,-0.143746,-0.135089,-0.158999,-0.147915,-0.129816,-0.114815,-0.114930,-0.108263,-0.124200,-0.129761,-0.106087,-0.113866,-0.090208,-0.091947,-0.081900,-0.065500,-0.090434,-0.111332,-0.091039,-0.079941,-0.082124,-0.100252,-0.094719,-0.110710,-0.107537,-0.127826,-0.104128,-0.097748,-0.107492,-0.092827,-0.109880,-0.111503,-0.107360,-0.123679', 32) AS "report"
FROM UNNEST(ARRAY[1]) AS t(x)
PARTITIONED BY ALL;

SELECT "report" FROM "bmk_drift";

-- ---------------------------------------------------------------------------
-- 6. Portfolio optimization.
--
-- The mean vector, the covariance, and the number of positions to
-- allocate over.
-- ---------------------------------------------------------------------------
REPLACE INTO bmk_portfolio OVERWRITE ALL
SELECT fractal_optimize_portfolio('0.050000,0.080000,0.030000,0.120000,0.070000,0.010000', '0.02,0,0,0,0,0,0,0.03,0,0,0,0,0,0,0.04,0,0,0,0,0,0,0.05,0,0,0,0,0,0,0.06,0,0,0,0,0,0,0.07', 2) AS "allocation"
FROM UNNEST(ARRAY[1]) AS t(x)
PARTITIONED BY ALL;

SELECT "allocation" FROM "bmk_portfolio";

-- The extended form: the same optimization with the core's own knobs
-- named.
REPLACE INTO bmk_portfolio_ex OVERWRITE ALL
SELECT fractal_optimize_portfolio_ex('0.050000,0.080000,0.030000,0.120000,0.070000,0.010000', '0.02,0,0,0,0,0,0,0.03,0,0,0,0,0,0,0.04,0,0,0,0,0,0,0.05,0,0,0,0,0,0,0.06,0,0,0,0,0,0,0.07', 2, 8, 2) AS "allocation"
FROM UNNEST(ARRAY[1]) AS t(x)
PARTITIONED BY ALL;

SELECT "allocation" FROM "bmk_portfolio_ex";

-- The multimodal family. These three are enterprise-gated: their core
-- symbols live in the separately licensed enterprise library, so on a
-- Community build they report that the tier is not loaded rather than
-- answering with a different algorithm.
REPLACE INTO bmk_multimodal OVERWRITE ALL
SELECT fractal_optimize_portfolio_multimodal('0.050000,0.080000,0.030000,0.120000,0.070000,0.010000', '0.02,0,0,0,0,0,0,0.03,0,0,0,0,0,0,0.04,0,0,0,0,0,0,0.05,0,0,0,0,0,0,0.06,0,0,0,0,0,0,0.07', 2) AS "candidates"
FROM UNNEST(ARRAY[1]) AS t(x)
PARTITIONED BY ALL;

SELECT "candidates" FROM "bmk_multimodal";

REPLACE INTO bmk_multimodal_ex OVERWRITE ALL
SELECT fractal_optimize_portfolio_multimodal_ex('0.050000,0.080000,0.030000,0.120000,0.070000,0.010000', '0.02,0,0,0,0,0,0,0.03,0,0,0,0,0,0,0.04,0,0,0,0,0,0,0.05,0,0,0,0,0,0,0.06,0,0,0,0,0,0,0.07', 2, 1, 2) AS "candidates"
FROM UNNEST(ARRAY[1]) AS t(x)
PARTITIONED BY ALL;

SELECT "candidates" FROM "bmk_multimodal_ex";

REPLACE INTO bmk_multimodal_pareto OVERWRITE ALL
SELECT fractal_optimize_portfolio_multimodal_pareto('0.050000,0.080000,0.030000,0.120000,0.070000,0.010000', '0.02,0,0,0,0,0,0,0.03,0,0,0,0,0,0,0.04,0,0,0,0,0,0,0.05,0,0,0,0,0,0,0.06,0,0,0,0,0,0,0.07', 2) AS "front"
FROM UNNEST(ARRAY[1]) AS t(x)
PARTITIONED BY ALL;

SELECT "front" FROM "bmk_multimodal_pareto";

-- ---------------------------------------------------------------------------
-- 7. Domain geometry.
--
-- A 30-node vascular chain with two branch leaves, a unit cube's
-- surface mesh (the known-answer case: the gyrification index is
-- about 1.0), an 80-node nerve plexus, and the jittered lattice
-- again for the morphological complexity.
-- ---------------------------------------------------------------------------
REPLACE INTO bmk_vascular OVERWRITE ALL
SELECT fractal_vascular_network('0.000000,0.000000,0.000000,1.000000,0.000000,0.000000,2.000000,0.000000,0.000000,3.000000,0.000000,0.000000,4.000000,0.000000,0.000000,5.000000,0.000000,0.000000,6.000000,0.000000,0.000000,7.000000,0.000000,0.000000,8.000000,0.000000,0.000000,9.000000,0.000000,0.000000,10.000000,0.000000,0.000000,11.000000,0.000000,0.000000,12.000000,0.000000,0.000000,13.000000,0.000000,0.000000,14.000000,0.000000,0.000000,15.000000,0.000000,0.000000,16.000000,0.000000,0.000000,17.000000,0.000000,0.000000,18.000000,0.000000,0.000000,19.000000,0.000000,0.000000,20.000000,0.000000,0.000000,21.000000,0.000000,0.000000,22.000000,0.000000,0.000000,23.000000,0.000000,0.000000,24.000000,0.000000,0.000000,25.000000,0.000000,0.000000,26.000000,0.000000,0.000000,27.000000,0.000000,0.000000,10.000000,1.000000,0.000000,10.000000,0.000000,1.000000', '0,1,1,2,2,3,3,4,4,5,5,6,6,7,7,8,8,9,9,10,10,11,11,12,12,13,13,14,14,15,15,16,16,17,17,18,18,19,19,20,20,21,21,22,22,23,23,24,24,25,25,26,26,27,10,28,10,29', '1.02,1.02,1.02,1.02,1.02,1.02,1.02,1.02,1.02,1.02,1.02,1.02,1.02,1.02,1.02,1.02,1.02,1.02,1.02,1.02,1.02,1.02,1.02,1.02,1.02,1.02,1.02,1.02,1.02') AS "vascular"
FROM UNNEST(ARRAY[1]) AS t(x)
PARTITIONED BY ALL;

SELECT "vascular" FROM "bmk_vascular";

REPLACE INTO bmk_cortical OVERWRITE ALL
SELECT fractal_cortical_folding('0,0,0, 1,0,0, 1,1,0, 0,1,0, 0,0,1, 1,0,1, 1,1,1, 0,1,1', '0,1,2, 0,2,3, 4,5,6, 4,6,7, 0,1,5, 0,5,4, 3,2,6, 3,6,7, 0,3,7, 0,7,4, 1,2,6, 1,6,5') AS "gyrification"
FROM UNNEST(ARRAY[1]) AS t(x)
PARTITIONED BY ALL;

SELECT "gyrification" FROM "bmk_cortical";

REPLACE INTO bmk_nerve OVERWRITE ALL
SELECT fractal_nerve_plexus_metric('0.00,-0.08,1.00,-0.03,2.00,0.03,3.00,0.08,4.00,-0.08,5.00,-0.03,6.00,0.03,7.00,0.08,8.00,-0.08,9.00,-0.03,10.00,0.03,11.00,0.08,12.00,-0.08,13.00,-0.03,14.00,0.03,15.00,0.08,16.00,-0.08,17.00,-0.03,18.00,0.03,19.00,0.08,20.00,-0.08,21.00,-0.03,22.00,0.03,23.00,0.08,24.00,-0.08,25.00,-0.03,26.00,0.03,27.00,0.08,28.00,-0.08,29.00,-0.03,30.00,0.03,31.00,0.08,32.00,-0.08,33.00,-0.03,34.00,0.03,35.00,0.08,36.00,-0.08,37.00,-0.03,38.00,0.03,39.00,0.08,40.00,-0.08,41.00,-0.03,42.00,0.03,43.00,0.08,44.00,-0.08,45.00,-0.03,46.00,0.03,47.00,0.08,48.00,-0.08,49.00,-0.03,50.00,0.03,51.00,0.08,52.00,-0.08,53.00,-0.03,54.00,0.03,55.00,0.08,56.00,-0.08,57.00,-0.03,58.00,0.03,59.00,0.08,60.00,-0.08,61.00,-0.03,62.00,0.03,63.00,0.08,64.00,-0.08,65.00,-0.03,66.00,0.03,67.00,0.08,68.00,-0.08,69.00,-0.03,70.00,0.03,71.00,0.08,72.00,-0.08,73.00,-0.03,74.00,0.03,75.00,0.08,76.00,-0.08,77.00,-0.03,78.00,0.03,79.00,0.08', 2, '0,1,1,2,2,3,3,4,4,5,5,6,6,7,7,8,8,9,9,10,10,11,11,12,12,13,13,14,14,15,15,16,16,17,17,18,18,19,19,20,20,21,21,22,22,23,23,24,24,25,25,26,26,27,27,28,28,29,29,30,30,31,31,32,32,33,33,34,34,35,35,36,36,37,37,38,38,39,39,40,40,41,41,42,42,43,43,44,44,45,45,46,46,47,47,48,48,49,49,50,50,51,51,52,52,53,53,54,54,55,55,56,56,57,57,58,58,59,59,60,60,61,61,62,62,63,63,64,64,65,65,66,66,67,67,68,68,69,69,70,70,71,71,72,72,73,73,74,74,75,75,76,76,77,77,78,78,79') AS "plexus"
FROM UNNEST(ARRAY[1]) AS t(x)
PARTITIONED BY ALL;

SELECT "plexus" FROM "bmk_nerve";

REPLACE INTO bmk_morphology OVERWRITE ALL
SELECT fractal_morphological_complexity('0.167467,0.112120,0.136044,0.187826,0.049674,0.098733,0.161887,0.291454,0.246357,0.053713,0.298552,0.244808,0.132545,0.278064,0.130259,0.193256,0.096793,0.228113,0.166809,0.198263,1.049661,1.149273,1.267959,1.103122,1.171720,1.215061,1.283529,1.062445,1.192359,1.014119,1.009447,1.149823,1.137028,1.140274,1.274913,1.120478,1.298534,1.080383,1.228806,1.292175,2.111367,2.260524,2.191954,2.080912,2.266034,2.291487,2.127258,2.081517,2.063878,2.244781,2.239189,2.177337,2.068220,2.297546,2.034316,2.259398,2.108733,2.187818,2.146411,2.086917,3.137049,3.170150,3.212432,3.067555,3.101968,3.218932,3.282859,3.134438,3.186771,3.125808,3.109645,3.189507,3.286068,3.029252,3.041248,3.262271,3.275379,3.244899,3.277612,3.234322,4.183341,4.138894,4.177097,4.008856,4.230736,4.259376,4.130019,4.110375,4.059860,4.227113,4.261663,4.087078,4.190570,4.263834,4.228492,4.157807,4.192881,4.107951,4.118779,4.101165,5.069590,5.084951,5.064133,5.245375,5.252841,5.292953,5.109775,5.277246,5.191923,5.147112,5.271681,5.266803,5.119871,5.143243,5.034941,5.069276,5.026634,5.135761,5.260577,5.114150,6.275775,6.097966,6.139209,6.106534,6.078225,6.189707,6.170469,6.065261,6.275090,6.248162,6.209701,6.067073,6.141232,6.141195,6.160163,6.134880,6.008403,6.011443,6.009729,6.144033,7.087910,7.203084,7.276490,7.033745,7.220028,7.290172,7.133577,7.256331,7.029608,7.084656,7.285746,7.059888,7.152106,7.157535,7.006851,7.256339,7.243629,7.246486,7.168444,7.124873,8.167327,8.094505,8.133320,8.161332,8.109034,8.151650,8.286554,8.181189,8.259806,8.105662,8.115941,8.031369,8.239861,8.082101,8.187198,8.128703,8.188252,8.288549,8.037557,8.002512,9.057542,9.138868,9.126808,9.133956,9.137587,9.295898,9.274530,9.096749,9.181598,9.241287,9.168970,9.006991,9.137514,9.277472,9.233480,9.272950,9.066732,9.181636,9.287257,9.248039,10.228180,10.082410,10.046378,10.075115,10.135350,10.063775,10.163704,10.074754,10.240315,10.057776,10.087550,10.055847,10.119249,10.100360,10.208549,10.084167,10.101210,10.225918,10.222191,10.232373,11.282380,11.233044,11.057800,11.235782,11.253979,11.184002,11.034316,11.246569,11.284135,11.299342,11.234672,11.261039,11.212008,11.169185,11.039550,11.154389,11.106935,11.285384,11.070135,11.021179,12.153956,12.086690,12.207451,12.118839,12.132731,12.095849,12.156523,12.046955,12.009282,12.262866,12.263563,12.098174,12.290774,12.114620,12.031998,12.280620,12.173744,12.028031,12.111611,12.006988,13.129717,13.242942,13.210967,13.071123,13.266870,13.046642,13.092000,13.043906,13.042969,13.106228,13.026652,13.000534,13.251214,13.094530,13.255747,13.076169,13.159257,13.235586,13.152322,13.072311,14.216371,14.169345,14.237409,14.180807,14.026536,14.067817,14.299351,14.105532,14.022535,14.227567,14.247556,14.071735,14.299160,14.261467,14.259238,14.011989,14.163676,14.251561,14.017979,14.220955,15.292957,15.202004,15.180311,15.041433,15.178769,15.093879,15.184254,15.237385,15.019833,15.089773,15.099545,15.103807,15.001313,15.007677,15.265987,15.079934,15.080293,15.016030,15.256666,15.260284,16.032994,16.117649,16.138041,16.278848,16.241210,16.070510,16.029410,16.282020,16.175896,16.217605,16.137582,16.294939,16.072859,16.178933,16.276425,16.085038,16.244061,16.060312,16.152115,16.056950,17.064289,17.047747,17.290344,17.193143,17.256131,17.208725,17.112437,17.137313,17.297390,17.174074,17.292089,17.056045,17.055741,17.185632,17.184376,17.160981,17.047660,17.135203,17.268047,17.089632,18.212505,18.085437,18.110360,18.122690,18.010502,18.033854,18.170749,18.088927,18.126787,18.196704,18.184465,18.017625,18.231338,18.144570,18.209345,18.270793,18.219665,18.157563,18.002331,18.129265,19.176021,19.132295,19.200205,19.229783,19.030831,19.050428,19.010816,19.186966,19.148026,19.005230,19.110183,19.050842,19.005195,19.240288,19.001193,19.123535,19.220491,19.295802,19.263966,19.027816', 2) AS "morphology"
FROM UNNEST(ARRAY[1]) AS t(x)
PARTITIONED BY ALL;

SELECT "morphology" FROM "bmk_morphology";

-- ---------------------------------------------------------------------------
-- 8. The named feature store.
--
--   NOT AVAILABLE. fractal_store_morphology and fractal_mine_topology_negatives store named features in the
--   extension's own feature-store table and mine the topology's
--   negatives out of it. Neither name is in the Druid registry, so there is no Druid shape for them:
--   there is nothing to call.
--
--   The closest Druid shape for the second one -- "which stored rows
--   are the negatives of this point?" -- is the telemetry search in
--   section 9, which is exactly what it is: a nearest-neighbour
--   question over a stored corpus. The first one -- "store this
--   named feature" -- has no Druid counterpart at all: a Druid
--   segment is immutable, so a feature store is a datasource, and
--   writing a feature is an ordinary MSQ write.
--
--   fractal_optimize_subset is not available here either:
--   it needs a caller-supplied objective, which the core takes as a
--   callback and a Druid expression cannot be. The portfolio family
--   in section 6 is the available shape.
-- ---------------------------------------------------------------------------

-- ---------------------------------------------------------------------------
-- 9. The table-backed telemetry search family.
--
-- Every one of these reads a whole table and reasons over it, so
-- every one of them is a service call: a Druid SQL function can do
-- neither.
-- ---------------------------------------------------------------------------
-- The nearest rows to a query vector: the extension's own exact
-- cosine distance over the corpus, best first.
-- @call search/telemetry {"datasource": "bmk_corpus", "vectorColumn": "emb",
--                         "idColumn": "id", "query": "-0.574830,0.091362,-0.501643,0.602100,-0.614825,-0.416330,-0.627688,-0.205005", "k": 3} AS bmk_telemetry;

SELECT "doc_id" AS "doc_id", "distance" AS "distance" FROM "bmk_telemetry";

-- The hybrid search: the nearest rows, restricted to a cohort of
-- identities.
-- @call search/hybrid {"datasource": "bmk_corpus", "vectorColumn": "emb",
--                      "idColumn": "id", "query": "-0.574830,0.091362,-0.501643,0.602100,-0.614825,-0.416330,-0.627688,-0.205005",
--                      "docIds": [1, 2, 3], "k": 3} AS bmk_hybrid;

SELECT "doc_id" AS "doc_id", "distance" AS "distance" FROM "bmk_hybrid";

-- The trajectory search: which stored tracks resemble a movement from
-- a baseline state to a current one. The baseline and the current
-- state are the corpus's own first two vectors.
-- @call search/trajectory {"table": "bmk_corpus", "column": "emb",
--                          "id_column": "id",
--                          "baseline": "-0.635338,0.130074,-0.548970,0.670328,-0.550804,-0.483836,-0.707878,-0.287808", "current": "0.083447,-0.974356,0.378664,-0.571491,0.294358,0.755395,-0.415274,-0.442261",
--                          "k": 3} AS bmk_trajectory;

SELECT "doc_id" AS "doc_id", "distance" AS "distance" FROM "bmk_trajectory";

-- The cross-modal search: a query that blends a morphological and a
-- clinical vector. The corpus here is two-dimensional -- two entities
-- of 200 points each, on a jittered lattice.
--
-- The corpus is written here rather than loaded as a fixture: it is
-- computed, and a computed table is an MSQ write. (Druid has no MOD
-- function, so the per-entity index is carried by FLOOR.)
REPLACE INTO bmk_modal OVERWRITE ALL
SELECT FLOOR((t."g" - 1) / 200) + 1 AS "entity",
       t."g" AS "id",
       CAST(ROUND(((t."g" - FLOOR((t."g" - 1) / 200) * 200) - FLOOR((t."g" - FLOOR((t."g" - 1) / 200) * 200) / 10) * 10 - 5 + 0.3 * (SIN((t."g" * 2) * 12.9898) * 43758.5453 - FLOOR(SIN((t."g" * 2) * 12.9898) * 43758.5453))), 6) AS DOUBLE) AS "x",
       CAST(ROUND((FLOOR((t."g" - FLOOR((t."g" - 1) / 200) * 200) / 10) - 10 + 0.3 * (SIN((t."g" * 2 + 1) * 12.9898) * 43758.5453 - FLOOR(SIN((t."g" * 2 + 1) * 12.9898) * 43758.5453))), 6) AS DOUBLE) AS "y",
       CAST(ROUND(((t."g" - FLOOR((t."g" - 1) / 200) * 200) - FLOOR((t."g" - FLOOR((t."g" - 1) / 200) * 200) / 10) * 10 - 5 + 0.3 * (SIN((t."g" * 2) * 12.9898) * 43758.5453 - FLOOR(SIN((t."g" * 2) * 12.9898) * 43758.5453))), 6) AS VARCHAR) || ',' || CAST(ROUND((FLOOR((t."g" - FLOOR((t."g" - 1) / 200) * 200) / 10) - 10 + 0.3 * (SIN((t."g" * 2 + 1) * 12.9898) * 43758.5453 - FLOOR(SIN((t."g" * 2 + 1) * 12.9898) * 43758.5453))), 6) AS VARCHAR) AS "vec"
FROM UNNEST(ARRAY[1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16, 17, 18, 19, 20, 21, 22, 23, 24, 25, 26, 27, 28, 29, 30, 31, 32, 33, 34, 35, 36, 37, 38, 39, 40, 41, 42, 43, 44, 45, 46, 47, 48, 49, 50, 51, 52, 53, 54, 55, 56, 57, 58, 59, 60, 61, 62, 63, 64, 65, 66, 67, 68, 69, 70, 71, 72, 73, 74, 75, 76, 77, 78, 79, 80, 81, 82, 83, 84, 85, 86, 87, 88, 89, 90, 91, 92, 93, 94, 95, 96, 97, 98, 99, 100, 101, 102, 103, 104, 105, 106, 107, 108, 109, 110, 111, 112, 113, 114, 115, 116, 117, 118, 119, 120, 121, 122, 123, 124, 125, 126, 127, 128, 129, 130, 131, 132, 133, 134, 135, 136, 137, 138, 139, 140, 141, 142, 143, 144, 145, 146, 147, 148, 149, 150, 151, 152, 153, 154, 155, 156, 157, 158, 159, 160, 161, 162, 163, 164, 165, 166, 167, 168, 169, 170, 171, 172, 173, 174, 175, 176, 177, 178, 179, 180, 181, 182, 183, 184, 185, 186, 187, 188, 189, 190, 191, 192, 193, 194, 195, 196, 197, 198, 199, 200, 201, 202, 203, 204, 205, 206, 207, 208, 209, 210, 211, 212, 213, 214, 215, 216, 217, 218, 219, 220, 221, 222, 223, 224, 225, 226, 227, 228, 229, 230, 231, 232, 233, 234, 235, 236, 237, 238, 239, 240, 241, 242, 243, 244, 245, 246, 247, 248, 249, 250, 251, 252, 253, 254, 255, 256, 257, 258, 259, 260, 261, 262, 263, 264, 265, 266, 267, 268, 269, 270, 271, 272, 273, 274, 275, 276, 277, 278, 279, 280, 281, 282, 283, 284, 285, 286, 287, 288, 289, 290, 291, 292, 293, 294, 295, 296, 297, 298, 299, 300, 301, 302, 303, 304, 305, 306, 307, 308, 309, 310, 311, 312, 313, 314, 315, 316, 317, 318, 319, 320, 321, 322, 323, 324, 325, 326, 327, 328, 329, 330, 331, 332, 333, 334, 335, 336, 337, 338, 339, 340, 341, 342, 343, 344, 345, 346, 347, 348, 349, 350, 351, 352, 353, 354, 355, 356, 357, 358, 359, 360, 361, 362, 363, 364, 365, 366, 367, 368, 369, 370, 371, 372, 373, 374, 375, 376, 377, 378, 379, 380, 381, 382, 383, 384, 385, 386, 387, 388, 389, 390, 391, 392, 393, 394, 395, 396, 397, 398, 399, 400]) AS t("g")
PARTITIONED BY ALL;

-- @call search/cross-modal {"table": "bmk_modal", "column": "vec",
--                           "id_column": "id",
--                           "morph": "0.6,0.8", "clinical": "-0.5,-0.4",
--                           "alpha": 0.5, "k": 3} AS bmk_crossmodal;

SELECT "doc_id" AS "doc_id", "distance" AS "distance" FROM "bmk_crossmodal";

-- The box count over the same cloud, entity by entity. The box count
-- needs a space-filling cloud, not a scattered one: it looks for
-- three valid epsilon octaves, and an entity of a hundred scattered
-- points has too few.
-- @call boxcount {"datasource": "bmk_modal", "entityColumn": "entity",
--                 "xColumn": "x", "yColumn": "y", "dim": 2} AS bmk_boxcount;

SELECT "entity" AS "entity", ROUND("dim", 4) AS "dimension" FROM "bmk_boxcount";

-- ---------------------------------------------------------------------------
-- 10. Time series, topology and fingerprints.
--
-- A 300-point series with a deliberate mean step at t=150, a
-- 120-point composite of two sinusoids (periods 12 and 5), and a
-- 16-point 2D square ring -- the closed perimeter the cycle-rank
-- Betti-1 should flag.
-- ---------------------------------------------------------------------------
REPLACE INTO bmk_changepoint OVERWRITE ALL
SELECT fractal_change_point_detect('0.103000,0.106000,0.109000,0.112000,0.115000,0.118000,0.100000,0.103000,0.106000,0.109000,0.112000,0.115000,0.118000,0.100000,0.103000,0.106000,0.109000,0.112000,0.115000,0.118000,0.100000,0.103000,0.106000,0.109000,0.112000,0.115000,0.118000,0.100000,0.103000,0.106000,0.109000,0.112000,0.115000,0.118000,0.100000,0.103000,0.106000,0.109000,0.112000,0.115000,0.118000,0.100000,0.103000,0.106000,0.109000,0.112000,0.115000,0.118000,0.100000,0.103000,0.106000,0.109000,0.112000,0.115000,0.118000,0.100000,0.103000,0.106000,0.109000,0.112000,0.115000,0.118000,0.100000,0.103000,0.106000,0.109000,0.112000,0.115000,0.118000,0.100000,0.103000,0.106000,0.109000,0.112000,0.115000,0.118000,0.100000,0.103000,0.106000,0.109000,0.112000,0.115000,0.118000,0.100000,0.103000,0.106000,0.109000,0.112000,0.115000,0.118000,0.100000,0.103000,0.106000,0.109000,0.112000,0.115000,0.118000,0.100000,0.103000,0.106000,0.109000,0.112000,0.115000,0.118000,0.100000,0.103000,0.106000,0.109000,0.112000,0.115000,0.118000,0.100000,0.103000,0.106000,0.109000,0.112000,0.115000,0.118000,0.100000,0.103000,0.106000,0.109000,0.112000,0.115000,0.118000,0.100000,0.103000,0.106000,0.109000,0.112000,0.115000,0.118000,0.100000,0.103000,0.106000,0.109000,0.112000,0.115000,0.118000,0.100000,0.103000,0.106000,0.109000,0.112000,0.115000,0.118000,0.100000,0.103000,0.106000,0.109000,2.112000,2.115000,2.118000,2.100000,2.103000,2.106000,2.109000,2.112000,2.115000,2.118000,2.100000,2.103000,2.106000,2.109000,2.112000,2.115000,2.118000,2.100000,2.103000,2.106000,2.109000,2.112000,2.115000,2.118000,2.100000,2.103000,2.106000,2.109000,2.112000,2.115000,2.118000,2.100000,2.103000,2.106000,2.109000,2.112000,2.115000,2.118000,2.100000,2.103000,2.106000,2.109000,2.112000,2.115000,2.118000,2.100000,2.103000,2.106000,2.109000,2.112000,2.115000,2.118000,2.100000,2.103000,2.106000,2.109000,2.112000,2.115000,2.118000,2.100000,2.103000,2.106000,2.109000,2.112000,2.115000,2.118000,2.100000,2.103000,2.106000,2.109000,2.112000,2.115000,2.118000,2.100000,2.103000,2.106000,2.109000,2.112000,2.115000,2.118000,2.100000,2.103000,2.106000,2.109000,2.112000,2.115000,2.118000,2.100000,2.103000,2.106000,2.109000,2.112000,2.115000,2.118000,2.100000,2.103000,2.106000,2.109000,2.112000,2.115000,2.118000,2.100000,2.103000,2.106000,2.109000,2.112000,2.115000,2.118000,2.100000,2.103000,2.106000,2.109000,2.112000,2.115000,2.118000,2.100000,2.103000,2.106000,2.109000,2.112000,2.115000,2.118000,2.100000,2.103000,2.106000,2.109000,2.112000,2.115000,2.118000,2.100000,2.103000,2.106000,2.109000,2.112000,2.115000,2.118000,2.100000,2.103000,2.106000,2.109000,2.112000,2.115000,2.118000,2.100000,2.103000,2.106000,2.109000,2.112000,2.115000,2.118000', 20, 1.0) AS "change_points"
FROM UNNEST(ARRAY[1]) AS t(x)
PARTITIONED BY ALL;

SELECT "change_points" FROM "bmk_changepoint";

REPLACE INTO bmk_periodogram OVERWRITE ALL
SELECT fractal_periodogram('0.975528,1.159918,0.706107,0.390497,0.500000,0.475528,-0.206107,-1.159918,-1.475528,-0.866025,-0.024472,0.293893,0.206107,0.390497,1.000000,1.341554,0.793893,-0.293893,-0.975528,-0.866025,-0.524472,-0.572133,-0.793893,-0.475528,0.500000,1.341554,1.293893,0.572133,0.024472,-0.000000,-0.024472,-0.572133,-1.293893,-1.341554,-0.500000,0.475528,0.793893,0.572133,0.524472,0.866025,0.975528,0.293892,-0.793893,-1.341554,-1.000000,-0.390497,-0.206107,-0.293892,0.024472,0.866025,1.475528,1.159918,0.206107,-0.475529,-0.500000,-0.390497,-0.706107,-1.159918,-0.975528,0.000000,0.975528,1.159918,0.706107,0.390497,0.500000,0.475528,-0.206108,-1.159918,-1.475528,-0.866025,-0.024471,0.293893,0.206108,0.390497,1.000000,1.341553,0.793892,-0.293893,-0.975529,-0.866026,-0.524472,-0.572133,-0.793892,-0.475528,0.500000,1.341554,1.293893,0.572133,0.024471,-0.000000,-0.024472,-0.572133,-1.293893,-1.341553,-0.500000,0.475529,0.793893,0.572133,0.524472,0.866025,0.975528,0.293892,-0.793893,-1.341554,-1.000000,-0.390497,-0.206107,-0.293892,0.024472,0.866026,1.475528,1.159918,0.206107,-0.475529,-0.500001,-0.390497,-0.706107,-1.159918,-0.975528,0.000000') AS "periodogram"
FROM UNNEST(ARRAY[1]) AS t(x)
PARTITIONED BY ALL;

SELECT "periodogram" FROM "bmk_periodogram";

REPLACE INTO bmk_spectrogram OVERWRITE ALL
SELECT fractal_spectrogram_entropy('0.975528,1.159918,0.706107,0.390497,0.500000,0.475528,-0.206107,-1.159918,-1.475528,-0.866025,-0.024472,0.293893,0.206107,0.390497,1.000000,1.341554,0.793893,-0.293893,-0.975528,-0.866025,-0.524472,-0.572133,-0.793893,-0.475528,0.500000,1.341554,1.293893,0.572133,0.024472,-0.000000,-0.024472,-0.572133,-1.293893,-1.341554,-0.500000,0.475528,0.793893,0.572133,0.524472,0.866025,0.975528,0.293892,-0.793893,-1.341554,-1.000000,-0.390497,-0.206107,-0.293892,0.024472,0.866025,1.475528,1.159918,0.206107,-0.475529,-0.500000,-0.390497,-0.706107,-1.159918,-0.975528,0.000000,0.975528,1.159918,0.706107,0.390497,0.500000,0.475528,-0.206108,-1.159918,-1.475528,-0.866025,-0.024471,0.293893,0.206108,0.390497,1.000000,1.341553,0.793892,-0.293893,-0.975529,-0.866026,-0.524472,-0.572133,-0.793892,-0.475528,0.500000,1.341554,1.293893,0.572133,0.024471,-0.000000,-0.024472,-0.572133,-1.293893,-1.341553,-0.500000,0.475529,0.793893,0.572133,0.524472,0.866025,0.975528,0.293892,-0.793893,-1.341554,-1.000000,-0.390497,-0.206107,-0.293892,0.024472,0.866026,1.475528,1.159918,0.206107,-0.475529,-0.500001,-0.390497,-0.706107,-1.159918,-0.975528,0.000000', 32, 16) AS "spectrogram"
FROM UNNEST(ARRAY[1]) AS t(x)
PARTITIONED BY ALL;

SELECT "spectrogram" FROM "bmk_spectrogram";

REPLACE INTO bmk_tda OVERWRITE ALL
SELECT fractal_tda_persistence_diagram('-2.000000,-2.000000,-1.000000,-2.000000,0.000000,-2.000000,1.000000,-2.000000,2.000000,-2.000000,2.000000,-1.000000,2.000000,0.000000,2.000000,1.000000,2.000000,2.000000,1.000000,2.000000,0.000000,2.000000,-1.000000,2.000000,-2.000000,2.000000,-2.000000,1.000000,-2.000000,0.000000,-2.000000,-1.000000', 2, 1, 2.5) AS "persistence"
FROM UNNEST(ARRAY[1]) AS t(x)
PARTITIONED BY ALL;

SELECT "persistence" FROM "bmk_tda";

-- The SimHash state fingerprints: two nearly-identical states collide,
-- orthogonal states do not.
REPLACE INTO bmk_fingerprints OVERWRITE ALL
SELECT t."i" AS "i",
       fractal_state_fingerprint('1.0,0.0,0.0', 64) AS "fp_a",
       fractal_state_fingerprint('1.001,0.002,0.0', 64) AS "fp_a_near",
       fractal_state_fingerprint('0.0,1.0,0.0', 64) AS "fp_b"
FROM UNNEST(ARRAY[1]) AS t("i")
PARTITIONED BY ALL;

SELECT "fp_a", "fp_a_near", "fp_b" FROM "bmk_fingerprints";

-- The distance between two states.
REPLACE INTO bmk_state_distance OVERWRITE ALL
SELECT fractal_state_distance('1.0,0.0,0.0', '1.001,0.002,0.0', 3.0) AS "distance"
FROM UNNEST(ARRAY[1]) AS t(x)
PARTITIONED BY ALL;

SELECT "distance" FROM "bmk_state_distance";

-- Brent's cycle detection over a clean period-2 fingerprint stream:
-- one-hot directions, so the two states are distinguishable.
--
-- The states are a fixture, not a computed column: a macro argument on
-- this build has to be a literal, a column or another macro call --
-- a CASE expression inside one is read as a function name and the
-- statement fails.
-- @fixture bmk_stream {"rows": [
--   {"i": 1, "state": "1.0,0.0,0.0"},
--   {"i": 2, "state": "0.0,1.0,0.0"},
--   {"i": 3, "state": "1.0,0.0,0.0"},
--   {"i": 4, "state": "0.0,1.0,0.0"},
--   {"i": 5, "state": "1.0,0.0,0.0"},
--   {"i": 6, "state": "0.0,1.0,0.0"}
-- ]};

REPLACE INTO bmk_states OVERWRITE ALL
SELECT t."i" AS "i", fractal_state_fingerprint(t."state", 64) AS "fingerprint"
FROM "bmk_stream" t
PARTITIONED BY ALL;

REPLACE INTO bmk_cycles OVERWRITE ALL
SELECT fractal_cycle_detect(
           CONCAT('["', ARRAY_TO_STRING(ARRAY_AGG("fingerprint", 16384), '","'), '"]'),
           64, 3) AS "cycle"
FROM "bmk_states"
PARTITIONED BY ALL;

SELECT "cycle" FROM "bmk_cycles";

-- ---------------------------------------------------------------------------
-- 11. The vector surface.
--
-- The distances, the arithmetic, the storage forms, the quantized
-- codes and the L_p distance.
-- ---------------------------------------------------------------------------
SELECT fractal_vector_l2_distance('1,0,0', '0.5,0,0') AS "l2_distance",
       fractal_vector_l2_squared('1,0,0', '0.5,0,0') AS "l2_squared",
       fractal_vector_cosine_distance('1,0,0', '0.5,0,0') AS "cosine_distance",
       fractal_vector_cosine_similarity('1,0,0', '0.5,0,0') AS "cosine_similarity",
       fractal_vector_negative_inner_product('1,0,0', '0.5,0,0') AS "neg_inner_product",
       fractal_vector_norm('1,0,0') AS "norm";

-- The generalized L_p distance. For 0 < p < 1 the L_p "distance" is
-- not a proper metric -- use it explicitly, never as a silent L2
-- substitute.
SELECT fractal_vector_lp_distance('1,0,0', '0.5,0,0', 2.0) AS "lp2_euclidean",
       fractal_vector_lp_distance('1,0,0', '0.5,0,0', 1.0) AS "lp1_manhattan",
       fractal_vector_lp_distance('1,0,0', '0.5,0,0', 0.5) AS "lp05_fractional";

-- The arithmetic returns a vector.
SELECT fractal_vector_add('1,0,0', '0,1,0') AS "sum",
       fractal_vector_sub('1,0,0', '0,1,0') AS "difference",
       fractal_vector_scale('1,0,0', 2.0) AS "scaled",
       fractal_vector_normalize('1,0,0') AS "normalized";

-- The constructors, the JSON formatter, and the width of a vector.
SELECT fractal_vector_dims('0.6,0.8,0.0,0.0') AS "dims",
       fractal_vector_to_json('0.6,0.8,0.0,0.0') AS "as_json",
       fractal_vector_from_text('0.6,0.8,0.0,0.0') AS "from_text",
       fractal_vector(3) AS "zero_vector";

-- A vector that is not a vector comes back as nothing rather than as a
-- corrupt vector.
SELECT fractal_vector_from_text('0.1,not-a-number') AS "refused_vector",
       fractal_vector_dims('0.1,not-a-number') AS "refused_dims";

-- int8 quantization: 4x compression, as TEXT (JSON).
SELECT fractal_vector_quantize_int8('0.5,-0.25,0.75,0.0') AS "int8_doc";

-- Binary quantization: the sign bits, one per dimension, as a text
-- array.
SELECT fractal_vector_quantize_binary('1,-1,1,1,-1,1,-1,-1,1,1') AS "binary_code",
       fractal_vector_dims(fractal_vector_quantize_binary('1,-1,1,1,-1,1,-1,-1,1,1')) AS "sign_bits";

-- The Hamming distance between two binary codes: the cheap candidate
-- filter.
SELECT fractal_vector_hamming_distance(
           fractal_vector_quantize_binary('1,-1,1,1,-1,1,-1,-1,1,1'),
           fractal_vector_quantize_binary('1,-1,1,1,-1,1,-1,-1,1,1')) AS "hamming_same",
       fractal_vector_hamming_distance(
           fractal_vector_quantize_binary('1,-1,1,1,-1,1,-1,-1,1,1'),
           fractal_vector_quantize_binary('-1,-1,1,1,-1,1,-1,-1,1,1')) AS "hamming_one_bit";

-- ---------------------------------------------------------------------------
-- 12. The config / session tier.
--
-- A Druid query has no connection to hang a session on, so the
-- session is named by the caller. Only the tuning keys may be set --
-- the operator's settings are refused, and a request that tried
-- would be an error rather than a change.
-- ---------------------------------------------------------------------------
SELECT fractal_config_set('think.level', '1', 'bmkref') AS "set";

SELECT fractal_config_get('think.level', 'bmkref') AS "get";

SELECT fractal_config_list('bmkref') AS "session_overrides";

SELECT fractal_config_keys() AS "known_settings";

SELECT fractal_config_reset('bmkref') AS "dropped";

-- ---------------------------------------------------------------------------
-- 13. Reading the JSON documents these functions answer with.
--
-- Druid's own JSON_VALUE reads a COMPLEX column, not a JSON string,
-- so the extension carries its own accessor for the documents its
-- functions return.
-- ---------------------------------------------------------------------------
SELECT fractal_json_value("debug", '$.best_fit') AS "best_fit",
       fractal_json_text("debug", '$.best_point') AS "best_point",
       fractal_json_text("debug", '$.no_such_key') AS "missing_key"
FROM "bmk_sfs";

-- ---------------------------------------------------------------------------
-- 14. The enterprise tier: the ledger and the audit.
--
-- fractal_lock_destructive is deliberately NOT called here: it is a
-- one-way, node-level latch, and a kit that set it would poison the
-- node for every later kit.
--
-- The tier's MUTATING half -- fractal_ledger_flush, fractal_ledger_load,
-- fractal_ledger_compact, fractal_ledger_reset_soft,
-- fractal_ledger_reset_hard and fractal_audit_log -- writes the node's
-- shared chain, so this kit does not call it: the chain is
-- cluster-wide state that every kit and every audit run depends on,
-- and a kit that rewrote it on every run would be a poor citizen. The kit that owns that half is
-- demo/enterprise-qtl-audit.sql, which seals the ledgers, compacts
-- the chain, resets it and verifies it on every run of the suite.
--
-- What this kit shows is the read-only half: what the chain holds and
-- the chain's own verification walk. fractal_audit_unpack is not called
-- here either: it decodes the last blob a flush sealed, this kit seals
-- nothing, and on a node where nothing has been sealed it reports that
-- there is no blob to decode. The kit that seals the blob decodes it:
-- demo/enterprise-qtl-audit.sql.
-- ---------------------------------------------------------------------------
SELECT fractal_ledger_truth_count() AS "truth_count",
       fractal_ledger_shadow_count() AS "shadow_count";

-- The chain verifies: every MAC matches, and every record carries the
-- hash of the record before it. This one is not gated -- it reads the extension's own chain file, so it answers on a Community deployment too.
SELECT fractal_ledger_verify() AS "verified";

-- The tier's own verdict on the chain. The chain is shared NODE
-- state, so this is asserted here, where it belongs, and not in the
-- headline below.
SELECT CASE WHEN fractal_ledger_verify() LIKE '%"ok":true%'
            THEN 'ledger: the chain verifies'
            ELSE 'ledger: the chain does NOT verify'
       END AS "ledger_check";

-- ---------------------------------------------------------------------------
-- The headline.
--
-- The kit passes when the search really ranked the corpus, the
-- dimension analysis really answered, the corpus-tier searches really
-- returned their rows, the documents really were embedded, and the
-- state stream really carried a cycle.
--
-- The chain is not in the headline: it is shared node state, and
-- section 14 asserts it where it belongs.
-- ---------------------------------------------------------------------------
SELECT CASE
           WHEN (SELECT COUNT(*) FROM "bmk_corpus") = 24
            AND (SELECT COUNT(*) FROM "bmk_telemetry") = 3
            AND (SELECT COUNT(*) FROM "bmk_hybrid") >= 1
            AND (SELECT COUNT(*) FROM "bmk_trajectory") >= 1
            AND (SELECT COUNT(*) FROM "bmk_crossmodal") >= 1
            AND (SELECT COUNT(*) FROM "bmk_boxcount" WHERE "dim" IS NOT NULL) = 2
            AND (SELECT "alpha" FROM "bmk_dfa") > 0
            AND (SELECT "dimension" FROM "bmk_boxcount_sql") > 0
            AND (SELECT COUNT(*) FROM "bmk_states") = 6
            AND (SELECT COUNT(*) FROM "bmk_cycles") = 1
            AND (SELECT COUNT(*) FROM "bmk_vec_registry" WHERE "source_table" = 'bmk_docs') >= 1
            AND (SELECT COUNT(*) FROM "bmk_emb" WHERE "dims" > 0) = 5
            THEN 'HEADLINE kit=benchmark-api-reference ok'
            ELSE 'HEADLINE kit=benchmark-api-reference FAILED'
       END AS "headline";
