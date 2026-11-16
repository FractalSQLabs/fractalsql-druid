-- demo/demo-business-intelligence.sql
--
-- FractalSQL for Apache Druid -- the business-intelligence layer.
--
-- Not just a text-to-SQL walkthrough: a plain-English business
-- question, SQL, the real result, and a narrative answer written over
-- that result -- the loop demo-text-to-sql.sql deliberately stops
-- short of. It also covers the other half of the product: Sniper
-- Search to define a target customer archetype, and Scout Discovery
-- to find and name real customer segments -- general data reasoning,
-- not single-query translation.
--
-- The synthetic data has real patterns baked into it on purpose (a
-- revenue dip four months back, five RFM-style customer segments) so
-- the reasoning sections have something genuine to discover.
--
-- Prerequisites: the extension is loaded on the Druid cluster, and a
-- reasoning provider is configured (docs/reasoning-setup.md).
--
-- Run:
--   python3 demo/run_demo.py --file demo/demo-business-intelligence.sql
--
-- ===========================================================================
-- Notes on how this runs on Druid
-- ===========================================================================
--
--   * The schema is four fixtures. Druid has no DDL, no INSERT and no
--     VALUES, and no recursive CTE to expand the archetypes into
--     customers, so the generator expands them in Python and the runner
--     loads the rows with an MSQ write (REPLACE INTO ... OVERWRITE
--     ALL), which is also what makes the kit re-runnable.
--   * The random values are the deterministic sin-hash the other kits use, so the kit is reproducible.
--   * The order dates are relative ("now-45d"), because Druid has no
--     datetime('now', '-4 months') -- the runner resolves the
--     relative form to a timestamp when it writes the fixture. The
--     timestamp is a text column, (placed_at TEXT), so the orders are one segment rather than one
--     segment per day. The month each order falls in is carried in
--     its own month_offset column, so the kit can talk about "the
--     month four months back" exactly, whatever day the kit runs on
--     (the offsets are fixed in the kit's fixture rows).
--   * The generation and the execution are service calls. The model is
--     reached over HTTP and a Druid query cannot
--     execute a statement it only learned at run time, so the
--     execution is the extension's data-analyst agent, which
--     validates a statement with EXPLAIN PLAN FOR and then runs it.
--   * The narrative over the real result is fractal_reason with the
--     result as a JSON string -- assembled in SQL.
--   * Scout Discovery is a service call (search/explore): the corpus
--     tier needs the whole column materialised, which a Druid
--     aggregate cannot do.
--   * One data change: the customers of the 'Lost' archetype are
--     marked churned, so the status breakdown has two rows instead of one.
--
-- Safe to re-run: every fixture is written with OVERWRITE ALL.

-- ---------------------------------------------------------------------------
-- 0. Sanity check: extension loaded?
-- ---------------------------------------------------------------------------
SELECT fractal_edition(), fractal_version();

-- ---------------------------------------------------------------------------
-- 1. The schema and 18 months of order history.
--
-- Five RFM archetypes, sixty customers, and an order history in which
-- the month four months back carries a deliberate ~40% revenue dip --
-- something for Section 3 to find.
-- ---------------------------------------------------------------------------
-- @fixture bi_archetypes {"rows": [
--   {"segment": "Champions", "r": -0.7, "f": 0.7, "m": 0.7, "n_customers": 14},
--   {"segment": "At-Risk", "r": 0.6, "f": 0.5, "m": 0.6, "n_customers": 10},
--   {"segment": "New & Exploring", "r": -0.6, "f": -0.6, "m": -0.5, "n_customers": 12},
--   {"segment": "Lost", "r": 0.7, "f": -0.7, "m": -0.6, "n_customers": 14},
--   {"segment": "Loyal & Modest", "r": -0.3, "f": 0.4, "m": -0.2, "n_customers": 10}
-- ]};

-- @fixture bi_customers {"rows": [
--   {"id": 1, "name": "customer_1", "segment": "At-Risk", "status": "active"},
--   {"id": 2, "name": "customer_2", "segment": "At-Risk", "status": "active"},
--   {"id": 3, "name": "customer_3", "segment": "At-Risk", "status": "active"},
--   {"id": 4, "name": "customer_4", "segment": "At-Risk", "status": "active"},
--   {"id": 5, "name": "customer_5", "segment": "At-Risk", "status": "active"},
--   {"id": 6, "name": "customer_6", "segment": "At-Risk", "status": "active"},
--   {"id": 7, "name": "customer_7", "segment": "At-Risk", "status": "active"},
--   {"id": 8, "name": "customer_8", "segment": "At-Risk", "status": "active"},
--   {"id": 9, "name": "customer_9", "segment": "At-Risk", "status": "active"},
--   {"id": 10, "name": "customer_10", "segment": "At-Risk", "status": "active"},
--   {"id": 11, "name": "customer_11", "segment": "Champions", "status": "active"},
--   {"id": 12, "name": "customer_12", "segment": "Champions", "status": "active"},
--   {"id": 13, "name": "customer_13", "segment": "Champions", "status": "active"},
--   {"id": 14, "name": "customer_14", "segment": "Champions", "status": "active"},
--   {"id": 15, "name": "customer_15", "segment": "Champions", "status": "active"},
--   {"id": 16, "name": "customer_16", "segment": "Champions", "status": "active"},
--   {"id": 17, "name": "customer_17", "segment": "Champions", "status": "active"},
--   {"id": 18, "name": "customer_18", "segment": "Champions", "status": "active"},
--   {"id": 19, "name": "customer_19", "segment": "Champions", "status": "active"},
--   {"id": 20, "name": "customer_20", "segment": "Champions", "status": "active"},
--   {"id": 21, "name": "customer_21", "segment": "Champions", "status": "active"},
--   {"id": 22, "name": "customer_22", "segment": "Champions", "status": "active"},
--   {"id": 23, "name": "customer_23", "segment": "Champions", "status": "active"},
--   {"id": 24, "name": "customer_24", "segment": "Champions", "status": "active"},
--   {"id": 25, "name": "customer_25", "segment": "Lost", "status": "churned"},
--   {"id": 26, "name": "customer_26", "segment": "Lost", "status": "churned"},
--   {"id": 27, "name": "customer_27", "segment": "Lost", "status": "churned"},
--   {"id": 28, "name": "customer_28", "segment": "Lost", "status": "churned"},
--   {"id": 29, "name": "customer_29", "segment": "Lost", "status": "churned"},
--   {"id": 30, "name": "customer_30", "segment": "Lost", "status": "churned"},
--   {"id": 31, "name": "customer_31", "segment": "Lost", "status": "churned"},
--   {"id": 32, "name": "customer_32", "segment": "Lost", "status": "churned"},
--   {"id": 33, "name": "customer_33", "segment": "Lost", "status": "churned"},
--   {"id": 34, "name": "customer_34", "segment": "Lost", "status": "churned"},
--   {"id": 35, "name": "customer_35", "segment": "Lost", "status": "churned"},
--   {"id": 36, "name": "customer_36", "segment": "Lost", "status": "churned"},
--   {"id": 37, "name": "customer_37", "segment": "Lost", "status": "churned"},
--   {"id": 38, "name": "customer_38", "segment": "Lost", "status": "churned"},
--   {"id": 39, "name": "customer_39", "segment": "Loyal & Modest", "status": "active"},
--   {"id": 40, "name": "customer_40", "segment": "Loyal & Modest", "status": "active"},
--   {"id": 41, "name": "customer_41", "segment": "Loyal & Modest", "status": "active"},
--   {"id": 42, "name": "customer_42", "segment": "Loyal & Modest", "status": "active"},
--   {"id": 43, "name": "customer_43", "segment": "Loyal & Modest", "status": "active"},
--   {"id": 44, "name": "customer_44", "segment": "Loyal & Modest", "status": "active"},
--   {"id": 45, "name": "customer_45", "segment": "Loyal & Modest", "status": "active"},
--   {"id": 46, "name": "customer_46", "segment": "Loyal & Modest", "status": "active"},
--   {"id": 47, "name": "customer_47", "segment": "Loyal & Modest", "status": "active"},
--   {"id": 48, "name": "customer_48", "segment": "Loyal & Modest", "status": "active"},
--   {"id": 49, "name": "customer_49", "segment": "New & Exploring", "status": "active"},
--   {"id": 50, "name": "customer_50", "segment": "New & Exploring", "status": "active"},
--   {"id": 51, "name": "customer_51", "segment": "New & Exploring", "status": "active"},
--   {"id": 52, "name": "customer_52", "segment": "New & Exploring", "status": "active"},
--   {"id": 53, "name": "customer_53", "segment": "New & Exploring", "status": "active"},
--   {"id": 54, "name": "customer_54", "segment": "New & Exploring", "status": "active"},
--   {"id": 55, "name": "customer_55", "segment": "New & Exploring", "status": "active"},
--   {"id": 56, "name": "customer_56", "segment": "New & Exploring", "status": "active"},
--   {"id": 57, "name": "customer_57", "segment": "New & Exploring", "status": "active"},
--   {"id": 58, "name": "customer_58", "segment": "New & Exploring", "status": "active"},
--   {"id": 59, "name": "customer_59", "segment": "New & Exploring", "status": "active"},
--   {"id": 60, "name": "customer_60", "segment": "New & Exploring", "status": "active"}
-- ]};

-- @fixture bi_customer_features {"rows": [
--   {"customer_id": 1, "feature_vec": "0.632474,0.468420,0.574915"},
--   {"customer_id": 2, "feature_vec": "0.568420,0.474915,0.599818"},
--   {"customer_id": 3, "feature_vec": "0.574915,0.499818,0.629490"},
--   {"customer_id": 4, "feature_vec": "0.599818,0.529490,0.588281"},
--   {"customer_id": 5, "feature_vec": "0.629490,0.488281,0.605430"},
--   {"customer_id": 6, "feature_vec": "0.588281,0.505430,0.616265"},
--   {"customer_id": 7, "feature_vec": "0.605430,0.516265,0.633382"},
--   {"customer_id": 8, "feature_vec": "0.616265,0.533382,0.578111"},
--   {"customer_id": 9, "feature_vec": "0.633382,0.478111,0.610590"},
--   {"customer_id": 10, "feature_vec": "0.578111,0.510590,0.566030"},
--   {"customer_id": 11, "feature_vec": "-0.689410,0.666030,0.664862"},
--   {"customer_id": 12, "feature_vec": "-0.733970,0.664862,0.699956"},
--   {"customer_id": 13, "feature_vec": "-0.735138,0.699956,0.696757"},
--   {"customer_id": 14, "feature_vec": "-0.700044,0.696757,0.697568"},
--   {"customer_id": 15, "feature_vec": "-0.703243,0.697568,0.731228"},
--   {"customer_id": 16, "feature_vec": "-0.702432,0.731228,0.692619"},
--   {"customer_id": 17, "feature_vec": "-0.668772,0.692619,0.737134"},
--   {"customer_id": 18, "feature_vec": "-0.707381,0.737134,0.682596"},
--   {"customer_id": 19, "feature_vec": "-0.662866,0.682596,0.719702"},
--   {"customer_id": 20, "feature_vec": "-0.717404,0.719702,0.735544"},
--   {"customer_id": 21, "feature_vec": "-0.680298,0.735544,0.670499"},
--   {"customer_id": 22, "feature_vec": "-0.664456,0.670499,0.662579"},
--   {"customer_id": 23, "feature_vec": "-0.729501,0.662579,0.717355"},
--   {"customer_id": 24, "feature_vec": "-0.737421,0.717355,0.685460"},
--   {"customer_id": 25, "feature_vec": "0.717355,-0.714540,-0.621805"},
--   {"customer_id": 26, "feature_vec": "0.685460,-0.721805,-0.567422"},
--   {"customer_id": 27, "feature_vec": "0.678195,-0.667422,-0.617272"},
--   {"customer_id": 28, "feature_vec": "0.732578,-0.717272,-0.605026"},
--   {"customer_id": 29, "feature_vec": "0.682728,-0.705026,-0.576423"},
--   {"customer_id": 30, "feature_vec": "0.694974,-0.676423,-0.579401"},
--   {"customer_id": 31, "feature_vec": "0.723577,-0.679401,-0.636115"},
--   {"customer_id": 32, "feature_vec": "0.720599,-0.736115,-0.594870"},
--   {"customer_id": 33, "feature_vec": "0.663885,-0.694870,-0.576320"},
--   {"customer_id": 34, "feature_vec": "0.705130,-0.676320,-0.626689"},
--   {"customer_id": 35, "feature_vec": "0.723680,-0.726689,-0.576915"},
--   {"customer_id": 36, "feature_vec": "0.673311,-0.676915,-0.575636"},
--   {"customer_id": 37, "feature_vec": "0.723085,-0.675636,-0.622792"},
--   {"customer_id": 38, "feature_vec": "0.724364,-0.722792,-0.604455"},
--   {"customer_id": 39, "feature_vec": "-0.322792,0.395545,-0.179434"},
--   {"customer_id": 40, "feature_vec": "-0.304455,0.420566,-0.179788"},
--   {"customer_id": 41, "feature_vec": "-0.279434,0.420212,-0.172557"},
--   {"customer_id": 42, "feature_vec": "-0.279788,0.427443,-0.231280"},
--   {"customer_id": 43, "feature_vec": "-0.272557,0.368720,-0.183305"},
--   {"customer_id": 44, "feature_vec": "-0.331280,0.416695,-0.174966"},
--   {"customer_id": 45, "feature_vec": "-0.283305,0.425034,-0.167798"},
--   {"customer_id": 46, "feature_vec": "-0.274966,0.432202,-0.192417"},
--   {"customer_id": 47, "feature_vec": "-0.267798,0.407583,-0.201405"},
--   {"customer_id": 48, "feature_vec": "-0.292417,0.398595,-0.169589"},
--   {"customer_id": 49, "feature_vec": "-0.601405,-0.569589,-0.536262"},
--   {"customer_id": 50, "feature_vec": "-0.569589,-0.636262,-0.531377"},
--   {"customer_id": 51, "feature_vec": "-0.636262,-0.631377,-0.484240"},
--   {"customer_id": 52, "feature_vec": "-0.631377,-0.584240,-0.498348"},
--   {"customer_id": 53, "feature_vec": "-0.584240,-0.598348,-0.470572"},
--   {"customer_id": 54, "feature_vec": "-0.598348,-0.570572,-0.466321"},
--   {"customer_id": 55, "feature_vec": "-0.570572,-0.566321,-0.498306"},
--   {"customer_id": 56, "feature_vec": "-0.566321,-0.598306,-0.518586"},
--   {"customer_id": 57, "feature_vec": "-0.598306,-0.618586,-0.512638"},
--   {"customer_id": 58, "feature_vec": "-0.618586,-0.612638,-0.469364"},
--   {"customer_id": 59, "feature_vec": "-0.612638,-0.569364,-0.496280"},
--   {"customer_id": 60, "feature_vec": "-0.569364,-0.596280,-0.531707"}
-- ]};

-- @fixture bi_orders {"rows": [
--   {"id": 1, "customer_id": 1, "total_cents": 12218, "month_offset": 1, "placed_at": "now-19d"},
--   {"id": 2, "customer_id": 1, "total_cents": 10159, "month_offset": 2, "placed_at": "now-60d"},
--   {"id": 3, "customer_id": 1, "total_cents": 14211, "month_offset": 3, "placed_at": "now-77d"},
--   {"id": 4, "customer_id": 1, "total_cents": 5585, "month_offset": 5, "placed_at": "now-146d"},
--   {"id": 5, "customer_id": 1, "total_cents": 11336, "month_offset": 6, "placed_at": "now-186d"},
--   {"id": 6, "customer_id": 1, "total_cents": 12551, "month_offset": 7, "placed_at": "now-204d"},
--   {"id": 7, "customer_id": 1, "total_cents": 9166, "month_offset": 9, "placed_at": "now-266d"},
--   {"id": 8, "customer_id": 1, "total_cents": 4390, "month_offset": 13, "placed_at": "now-393d"},
--   {"id": 9, "customer_id": 1, "total_cents": 9646, "month_offset": 15, "placed_at": "now-463d"},
--   {"id": 10, "customer_id": 1, "total_cents": 7855, "month_offset": 16, "placed_at": "now-487d"},
--   {"id": 11, "customer_id": 1, "total_cents": 13474, "month_offset": 17, "placed_at": "now-502d"},
--   {"id": 12, "customer_id": 1, "total_cents": 8696, "month_offset": 18, "placed_at": "now-540d"},
--   {"id": 13, "customer_id": 2, "total_cents": 9088, "month_offset": 2, "placed_at": "now-67d"},
--   {"id": 14, "customer_id": 2, "total_cents": 2007, "month_offset": 4, "placed_at": "now-107d"},
--   {"id": 15, "customer_id": 2, "total_cents": 5283, "month_offset": 5, "placed_at": "now-144d"},
--   {"id": 16, "customer_id": 2, "total_cents": 4849, "month_offset": 7, "placed_at": "now-213d"},
--   {"id": 17, "customer_id": 2, "total_cents": 11313, "month_offset": 8, "placed_at": "now-250d"},
--   {"id": 18, "customer_id": 2, "total_cents": 5209, "month_offset": 9, "placed_at": "now-268d"},
--   {"id": 19, "customer_id": 2, "total_cents": 8177, "month_offset": 12, "placed_at": "now-363d"},
--   {"id": 20, "customer_id": 2, "total_cents": 4128, "month_offset": 15, "placed_at": "now-442d"},
--   {"id": 21, "customer_id": 2, "total_cents": 7516, "month_offset": 16, "placed_at": "now-486d"},
--   {"id": 22, "customer_id": 2, "total_cents": 8817, "month_offset": 17, "placed_at": "now-523d"},
--   {"id": 23, "customer_id": 3, "total_cents": 5382, "month_offset": 4, "placed_at": "now-128d"},
--   {"id": 24, "customer_id": 3, "total_cents": 7124, "month_offset": 6, "placed_at": "now-173d"},
--   {"id": 25, "customer_id": 3, "total_cents": 9868, "month_offset": 7, "placed_at": "now-217d"},
--   {"id": 26, "customer_id": 3, "total_cents": 14341, "month_offset": 9, "placed_at": "now-280d"},
--   {"id": 27, "customer_id": 3, "total_cents": 5497, "month_offset": 10, "placed_at": "now-311d"},
--   {"id": 28, "customer_id": 3, "total_cents": 3564, "month_offset": 12, "placed_at": "now-372d"},
--   {"id": 29, "customer_id": 3, "total_cents": 8481, "month_offset": 15, "placed_at": "now-457d"},
--   {"id": 30, "customer_id": 3, "total_cents": 8610, "month_offset": 16, "placed_at": "now-475d"},
--   {"id": 31, "customer_id": 4, "total_cents": 9820, "month_offset": 3, "placed_at": "now-79d"},
--   {"id": 32, "customer_id": 4, "total_cents": 7672, "month_offset": 4, "placed_at": "now-121d"},
--   {"id": 33, "customer_id": 4, "total_cents": 4729, "month_offset": 5, "placed_at": "now-157d"},
--   {"id": 34, "customer_id": 4, "total_cents": 12693, "month_offset": 6, "placed_at": "now-186d"},
--   {"id": 35, "customer_id": 4, "total_cents": 12898, "month_offset": 7, "placed_at": "now-220d"},
--   {"id": 36, "customer_id": 4, "total_cents": 13390, "month_offset": 12, "placed_at": "now-373d"},
--   {"id": 37, "customer_id": 4, "total_cents": 14152, "month_offset": 16, "placed_at": "now-488d"},
--   {"id": 38, "customer_id": 4, "total_cents": 8775, "month_offset": 18, "placed_at": "now-550d"},
--   {"id": 39, "customer_id": 5, "total_cents": 5131, "month_offset": 2, "placed_at": "now-65d"},
--   {"id": 40, "customer_id": 5, "total_cents": 8437, "month_offset": 3, "placed_at": "now-92d"},
--   {"id": 41, "customer_id": 5, "total_cents": 9046, "month_offset": 6, "placed_at": "now-181d"},
--   {"id": 42, "customer_id": 5, "total_cents": 11077, "month_offset": 7, "placed_at": "now-220d"},
--   {"id": 43, "customer_id": 5, "total_cents": 13343, "month_offset": 10, "placed_at": "now-298d"},
--   {"id": 44, "customer_id": 5, "total_cents": 10600, "month_offset": 13, "placed_at": "now-402d"},
--   {"id": 45, "customer_id": 5, "total_cents": 7133, "month_offset": 17, "placed_at": "now-526d"},
--   {"id": 46, "customer_id": 5, "total_cents": 14677, "month_offset": 18, "placed_at": "now-552d"},
--   {"id": 47, "customer_id": 6, "total_cents": 14687, "month_offset": 1, "placed_at": "now-40d"},
--   {"id": 48, "customer_id": 6, "total_cents": 10531, "month_offset": 2, "placed_at": "now-52d"},
--   {"id": 49, "customer_id": 6, "total_cents": 6661, "month_offset": 3, "placed_at": "now-91d"},
--   {"id": 50, "customer_id": 6, "total_cents": 4907, "month_offset": 5, "placed_at": "now-156d"},
--   {"id": 51, "customer_id": 6, "total_cents": 9266, "month_offset": 9, "placed_at": "now-274d"},
--   {"id": 52, "customer_id": 6, "total_cents": 7454, "month_offset": 10, "placed_at": "now-303d"},
--   {"id": 53, "customer_id": 6, "total_cents": 8090, "month_offset": 16, "placed_at": "now-477d"},
--   {"id": 54, "customer_id": 6, "total_cents": 6260, "month_offset": 17, "placed_at": "now-508d"},
--   {"id": 55, "customer_id": 7, "total_cents": 3883, "month_offset": 2, "placed_at": "now-52d"},
--   {"id": 56, "customer_id": 7, "total_cents": 8972, "month_offset": 3, "placed_at": "now-81d"},
--   {"id": 57, "customer_id": 7, "total_cents": 7750, "month_offset": 5, "placed_at": "now-138d"},
--   {"id": 58, "customer_id": 7, "total_cents": 9710, "month_offset": 7, "placed_at": "now-223d"},
--   {"id": 59, "customer_id": 7, "total_cents": 11782, "month_offset": 8, "placed_at": "now-242d"},
--   {"id": 60, "customer_id": 7, "total_cents": 7764, "month_offset": 9, "placed_at": "now-276d"},
--   {"id": 61, "customer_id": 7, "total_cents": 7109, "month_offset": 10, "placed_at": "now-289d"},
--   {"id": 62, "customer_id": 7, "total_cents": 7913, "month_offset": 13, "placed_at": "now-393d"},
--   {"id": 63, "customer_id": 7, "total_cents": 10529, "month_offset": 14, "placed_at": "now-412d"},
--   {"id": 64, "customer_id": 8, "total_cents": 13335, "month_offset": 1, "placed_at": "now-17d"},
--   {"id": 65, "customer_id": 8, "total_cents": 7267, "month_offset": 2, "placed_at": "now-62d"},
--   {"id": 66, "customer_id": 8, "total_cents": 4165, "month_offset": 4, "placed_at": "now-114d"},
--   {"id": 67, "customer_id": 8, "total_cents": 10379, "month_offset": 5, "placed_at": "now-138d"},
--   {"id": 68, "customer_id": 8, "total_cents": 3353, "month_offset": 6, "placed_at": "now-189d"},
--   {"id": 69, "customer_id": 8, "total_cents": 14681, "month_offset": 8, "placed_at": "now-254d"},
--   {"id": 70, "customer_id": 8, "total_cents": 14037, "month_offset": 9, "placed_at": "now-283d"},
--   {"id": 71, "customer_id": 8, "total_cents": 8862, "month_offset": 10, "placed_at": "now-301d"},
--   {"id": 72, "customer_id": 8, "total_cents": 3219, "month_offset": 11, "placed_at": "now-333d"},
--   {"id": 73, "customer_id": 8, "total_cents": 6045, "month_offset": 12, "placed_at": "now-363d"},
--   {"id": 74, "customer_id": 8, "total_cents": 10401, "month_offset": 13, "placed_at": "now-382d"},
--   {"id": 75, "customer_id": 8, "total_cents": 10582, "month_offset": 14, "placed_at": "now-426d"},
--   {"id": 76, "customer_id": 8, "total_cents": 6030, "month_offset": 16, "placed_at": "now-491d"},
--   {"id": 77, "customer_id": 9, "total_cents": 5812, "month_offset": 2, "placed_at": "now-45d"},
--   {"id": 78, "customer_id": 9, "total_cents": 7432, "month_offset": 3, "placed_at": "now-95d"},
--   {"id": 79, "customer_id": 9, "total_cents": 9231, "month_offset": 5, "placed_at": "now-137d"},
--   {"id": 80, "customer_id": 9, "total_cents": 13762, "month_offset": 6, "placed_at": "now-192d"},
--   {"id": 81, "customer_id": 9, "total_cents": 11753, "month_offset": 7, "placed_at": "now-224d"},
--   {"id": 82, "customer_id": 9, "total_cents": 9775, "month_offset": 8, "placed_at": "now-236d"},
--   {"id": 83, "customer_id": 9, "total_cents": 6711, "month_offset": 9, "placed_at": "now-275d"},
--   {"id": 84, "customer_id": 9, "total_cents": 14851, "month_offset": 10, "placed_at": "now-309d"},
--   {"id": 85, "customer_id": 9, "total_cents": 3374, "month_offset": 11, "placed_at": "now-320d"},
--   {"id": 86, "customer_id": 9, "total_cents": 6515, "month_offset": 12, "placed_at": "now-368d"},
--   {"id": 87, "customer_id": 9, "total_cents": 13558, "month_offset": 13, "placed_at": "now-395d"},
--   {"id": 88, "customer_id": 9, "total_cents": 4879, "month_offset": 14, "placed_at": "now-415d"},
--   {"id": 89, "customer_id": 9, "total_cents": 6608, "month_offset": 15, "placed_at": "now-447d"},
--   {"id": 90, "customer_id": 9, "total_cents": 13709, "month_offset": 16, "placed_at": "now-498d"},
--   {"id": 91, "customer_id": 10, "total_cents": 13490, "month_offset": 1, "placed_at": "now-20d"},
--   {"id": 92, "customer_id": 10, "total_cents": 14015, "month_offset": 2, "placed_at": "now-51d"},
--   {"id": 93, "customer_id": 10, "total_cents": 12795, "month_offset": 3, "placed_at": "now-102d"},
--   {"id": 94, "customer_id": 10, "total_cents": 8462, "month_offset": 4, "placed_at": "now-118d"},
--   {"id": 95, "customer_id": 10, "total_cents": 10157, "month_offset": 7, "placed_at": "now-203d"},
--   {"id": 96, "customer_id": 10, "total_cents": 6876, "month_offset": 8, "placed_at": "now-233d"},
--   {"id": 97, "customer_id": 10, "total_cents": 11588, "month_offset": 9, "placed_at": "now-278d"},
--   {"id": 98, "customer_id": 10, "total_cents": 7659, "month_offset": 14, "placed_at": "now-434d"},
--   {"id": 99, "customer_id": 10, "total_cents": 12177, "month_offset": 15, "placed_at": "now-448d"},
--   {"id": 100, "customer_id": 10, "total_cents": 13466, "month_offset": 16, "placed_at": "now-476d"},
--   {"id": 101, "customer_id": 10, "total_cents": 6742, "month_offset": 17, "placed_at": "now-503d"},
--   {"id": 102, "customer_id": 11, "total_cents": 8199, "month_offset": 3, "placed_at": "now-80d"},
--   {"id": 103, "customer_id": 11, "total_cents": 7500, "month_offset": 5, "placed_at": "now-147d"},
--   {"id": 104, "customer_id": 11, "total_cents": 13634, "month_offset": 8, "placed_at": "now-255d"},
--   {"id": 105, "customer_id": 11, "total_cents": 13160, "month_offset": 13, "placed_at": "now-381d"},
--   {"id": 106, "customer_id": 11, "total_cents": 8956, "month_offset": 14, "placed_at": "now-422d"},
--   {"id": 107, "customer_id": 11, "total_cents": 4549, "month_offset": 17, "placed_at": "now-504d"},
--   {"id": 108, "customer_id": 12, "total_cents": 14199, "month_offset": 1, "placed_at": "now-27d"},
--   {"id": 109, "customer_id": 12, "total_cents": 3310, "month_offset": 2, "placed_at": "now-65d"},
--   {"id": 110, "customer_id": 12, "total_cents": 3871, "month_offset": 4, "placed_at": "now-109d"},
--   {"id": 111, "customer_id": 12, "total_cents": 4457, "month_offset": 5, "placed_at": "now-149d"},
--   {"id": 112, "customer_id": 12, "total_cents": 12939, "month_offset": 10, "placed_at": "now-295d"},
--   {"id": 113, "customer_id": 12, "total_cents": 5587, "month_offset": 12, "placed_at": "now-362d"},
--   {"id": 114, "customer_id": 12, "total_cents": 5500, "month_offset": 14, "placed_at": "now-436d"},
--   {"id": 115, "customer_id": 12, "total_cents": 5972, "month_offset": 15, "placed_at": "now-448d"},
--   {"id": 116, "customer_id": 12, "total_cents": 5190, "month_offset": 16, "placed_at": "now-475d"},
--   {"id": 117, "customer_id": 12, "total_cents": 10826, "month_offset": 17, "placed_at": "now-507d"},
--   {"id": 118, "customer_id": 12, "total_cents": 9486, "month_offset": 18, "placed_at": "now-546d"},
--   {"id": 119, "customer_id": 13, "total_cents": 12084, "month_offset": 2, "placed_at": "now-52d"},
--   {"id": 120, "customer_id": 13, "total_cents": 13466, "month_offset": 3, "placed_at": "now-79d"},
--   {"id": 121, "customer_id": 13, "total_cents": 3889, "month_offset": 4, "placed_at": "now-112d"},
--   {"id": 122, "customer_id": 13, "total_cents": 10622, "month_offset": 5, "placed_at": "now-150d"},
--   {"id": 123, "customer_id": 13, "total_cents": 13553, "month_offset": 6, "placed_at": "now-177d"},
--   {"id": 124, "customer_id": 13, "total_cents": 9312, "month_offset": 8, "placed_at": "now-245d"},
--   {"id": 125, "customer_id": 13, "total_cents": 10715, "month_offset": 9, "placed_at": "now-257d"},
--   {"id": 126, "customer_id": 13, "total_cents": 7318, "month_offset": 10, "placed_at": "now-305d"},
--   {"id": 127, "customer_id": 13, "total_cents": 7046, "month_offset": 12, "placed_at": "now-363d"},
--   {"id": 128, "customer_id": 13, "total_cents": 3491, "month_offset": 14, "placed_at": "now-414d"},
--   {"id": 129, "customer_id": 13, "total_cents": 10275, "month_offset": 16, "placed_at": "now-496d"},
--   {"id": 130, "customer_id": 14, "total_cents": 3340, "month_offset": 1, "placed_at": "now-19d"},
--   {"id": 131, "customer_id": 14, "total_cents": 13231, "month_offset": 2, "placed_at": "now-71d"},
--   {"id": 132, "customer_id": 14, "total_cents": 8914, "month_offset": 4, "placed_at": "now-109d"},
--   {"id": 133, "customer_id": 14, "total_cents": 12058, "month_offset": 6, "placed_at": "now-182d"},
--   {"id": 134, "customer_id": 14, "total_cents": 3958, "month_offset": 8, "placed_at": "now-239d"},
--   {"id": 135, "customer_id": 14, "total_cents": 11457, "month_offset": 9, "placed_at": "now-279d"},
--   {"id": 136, "customer_id": 14, "total_cents": 9639, "month_offset": 10, "placed_at": "now-299d"},
--   {"id": 137, "customer_id": 14, "total_cents": 5914, "month_offset": 15, "placed_at": "now-446d"},
--   {"id": 138, "customer_id": 14, "total_cents": 9942, "month_offset": 16, "placed_at": "now-494d"},
--   {"id": 139, "customer_id": 14, "total_cents": 7819, "month_offset": 17, "placed_at": "now-516d"},
--   {"id": 140, "customer_id": 15, "total_cents": 8779, "month_offset": 2, "placed_at": "now-50d"},
--   {"id": 141, "customer_id": 15, "total_cents": 13407, "month_offset": 3, "placed_at": "now-98d"},
--   {"id": 142, "customer_id": 15, "total_cents": 11025, "month_offset": 5, "placed_at": "now-148d"},
--   {"id": 143, "customer_id": 15, "total_cents": 6031, "month_offset": 6, "placed_at": "now-190d"},
--   {"id": 144, "customer_id": 15, "total_cents": 8922, "month_offset": 7, "placed_at": "now-210d"},
--   {"id": 145, "customer_id": 15, "total_cents": 11367, "month_offset": 8, "placed_at": "now-245d"},
--   {"id": 146, "customer_id": 15, "total_cents": 8996, "month_offset": 11, "placed_at": "now-338d"},
--   {"id": 147, "customer_id": 15, "total_cents": 13813, "month_offset": 12, "placed_at": "now-352d"},
--   {"id": 148, "customer_id": 15, "total_cents": 8682, "month_offset": 16, "placed_at": "now-493d"},
--   {"id": 149, "customer_id": 15, "total_cents": 14127, "month_offset": 17, "placed_at": "now-506d"},
--   {"id": 150, "customer_id": 16, "total_cents": 6398, "month_offset": 1, "placed_at": "now-30d"},
--   {"id": 151, "customer_id": 16, "total_cents": 12814, "month_offset": 3, "placed_at": "now-97d"},
--   {"id": 152, "customer_id": 16, "total_cents": 7867, "month_offset": 4, "placed_at": "now-111d"},
--   {"id": 153, "customer_id": 16, "total_cents": 14718, "month_offset": 5, "placed_at": "now-142d"},
--   {"id": 154, "customer_id": 16, "total_cents": 8884, "month_offset": 9, "placed_at": "now-280d"},
--   {"id": 155, "customer_id": 16, "total_cents": 13672, "month_offset": 11, "placed_at": "now-336d"},
--   {"id": 156, "customer_id": 16, "total_cents": 7794, "month_offset": 12, "placed_at": "now-359d"},
--   {"id": 157, "customer_id": 16, "total_cents": 4397, "month_offset": 14, "placed_at": "now-429d"},
--   {"id": 158, "customer_id": 16, "total_cents": 13423, "month_offset": 18, "placed_at": "now-558d"},
--   {"id": 159, "customer_id": 17, "total_cents": 14800, "month_offset": 1, "placed_at": "now-34d"},
--   {"id": 160, "customer_id": 17, "total_cents": 7609, "month_offset": 2, "placed_at": "now-52d"},
--   {"id": 161, "customer_id": 17, "total_cents": 10346, "month_offset": 3, "placed_at": "now-90d"},
--   {"id": 162, "customer_id": 17, "total_cents": 4246, "month_offset": 4, "placed_at": "now-120d"},
--   {"id": 163, "customer_id": 17, "total_cents": 7313, "month_offset": 6, "placed_at": "now-181d"},
--   {"id": 164, "customer_id": 17, "total_cents": 6829, "month_offset": 7, "placed_at": "now-202d"},
--   {"id": 165, "customer_id": 17, "total_cents": 3893, "month_offset": 8, "placed_at": "now-245d"},
--   {"id": 166, "customer_id": 17, "total_cents": 3009, "month_offset": 9, "placed_at": "now-261d"},
--   {"id": 167, "customer_id": 17, "total_cents": 7554, "month_offset": 13, "placed_at": "now-397d"},
--   {"id": 168, "customer_id": 17, "total_cents": 12772, "month_offset": 14, "placed_at": "now-420d"},
--   {"id": 169, "customer_id": 17, "total_cents": 9544, "month_offset": 16, "placed_at": "now-487d"},
--   {"id": 170, "customer_id": 17, "total_cents": 14947, "month_offset": 17, "placed_at": "now-512d"},
--   {"id": 171, "customer_id": 17, "total_cents": 13709, "month_offset": 18, "placed_at": "now-549d"},
--   {"id": 172, "customer_id": 18, "total_cents": 14884, "month_offset": 1, "placed_at": "now-25d"},
--   {"id": 173, "customer_id": 18, "total_cents": 8471, "month_offset": 2, "placed_at": "now-65d"},
--   {"id": 174, "customer_id": 18, "total_cents": 3737, "month_offset": 4, "placed_at": "now-117d"},
--   {"id": 175, "customer_id": 18, "total_cents": 3754, "month_offset": 5, "placed_at": "now-153d"},
--   {"id": 176, "customer_id": 18, "total_cents": 7231, "month_offset": 7, "placed_at": "now-206d"},
--   {"id": 177, "customer_id": 18, "total_cents": 6533, "month_offset": 8, "placed_at": "now-242d"},
--   {"id": 178, "customer_id": 18, "total_cents": 10297, "month_offset": 9, "placed_at": "now-280d"},
--   {"id": 179, "customer_id": 18, "total_cents": 8387, "month_offset": 11, "placed_at": "now-336d"},
--   {"id": 180, "customer_id": 18, "total_cents": 4503, "month_offset": 13, "placed_at": "now-381d"},
--   {"id": 181, "customer_id": 18, "total_cents": 11363, "month_offset": 14, "placed_at": "now-422d"},
--   {"id": 182, "customer_id": 18, "total_cents": 7285, "month_offset": 16, "placed_at": "now-478d"},
--   {"id": 183, "customer_id": 18, "total_cents": 4526, "month_offset": 18, "placed_at": "now-542d"},
--   {"id": 184, "customer_id": 19, "total_cents": 13794, "month_offset": 1, "placed_at": "now-27d"},
--   {"id": 185, "customer_id": 19, "total_cents": 6225, "month_offset": 3, "placed_at": "now-82d"},
--   {"id": 186, "customer_id": 19, "total_cents": 6633, "month_offset": 4, "placed_at": "now-125d"},
--   {"id": 187, "customer_id": 19, "total_cents": 8293, "month_offset": 6, "placed_at": "now-193d"},
--   {"id": 188, "customer_id": 19, "total_cents": 14031, "month_offset": 7, "placed_at": "now-198d"},
--   {"id": 189, "customer_id": 19, "total_cents": 6918, "month_offset": 8, "placed_at": "now-229d"},
--   {"id": 190, "customer_id": 19, "total_cents": 8568, "month_offset": 9, "placed_at": "now-260d"},
--   {"id": 191, "customer_id": 19, "total_cents": 7261, "month_offset": 10, "placed_at": "now-305d"},
--   {"id": 192, "customer_id": 19, "total_cents": 10588, "month_offset": 12, "placed_at": "now-367d"},
--   {"id": 193, "customer_id": 19, "total_cents": 9818, "month_offset": 13, "placed_at": "now-390d"},
--   {"id": 194, "customer_id": 19, "total_cents": 5610, "month_offset": 14, "placed_at": "now-436d"},
--   {"id": 195, "customer_id": 19, "total_cents": 11388, "month_offset": 17, "placed_at": "now-504d"},
--   {"id": 196, "customer_id": 19, "total_cents": 5682, "month_offset": 18, "placed_at": "now-546d"},
--   {"id": 197, "customer_id": 20, "total_cents": 11548, "month_offset": 3, "placed_at": "now-76d"},
--   {"id": 198, "customer_id": 20, "total_cents": 5422, "month_offset": 8, "placed_at": "now-239d"},
--   {"id": 199, "customer_id": 20, "total_cents": 3961, "month_offset": 10, "placed_at": "now-304d"},
--   {"id": 200, "customer_id": 20, "total_cents": 12389, "month_offset": 12, "placed_at": "now-361d"},
--   {"id": 201, "customer_id": 20, "total_cents": 6347, "month_offset": 13, "placed_at": "now-399d"},
--   {"id": 202, "customer_id": 20, "total_cents": 4441, "month_offset": 14, "placed_at": "now-423d"},
--   {"id": 203, "customer_id": 20, "total_cents": 12222, "month_offset": 15, "placed_at": "now-454d"},
--   {"id": 204, "customer_id": 20, "total_cents": 7901, "month_offset": 17, "placed_at": "now-507d"},
--   {"id": 205, "customer_id": 20, "total_cents": 10729, "month_offset": 18, "placed_at": "now-548d"},
--   {"id": 206, "customer_id": 21, "total_cents": 12259, "month_offset": 2, "placed_at": "now-58d"},
--   {"id": 207, "customer_id": 21, "total_cents": 11333, "month_offset": 3, "placed_at": "now-90d"},
--   {"id": 208, "customer_id": 21, "total_cents": 3779, "month_offset": 4, "placed_at": "now-112d"},
--   {"id": 209, "customer_id": 21, "total_cents": 6647, "month_offset": 7, "placed_at": "now-214d"},
--   {"id": 210, "customer_id": 21, "total_cents": 4625, "month_offset": 11, "placed_at": "now-336d"},
--   {"id": 211, "customer_id": 21, "total_cents": 6048, "month_offset": 12, "placed_at": "now-352d"},
--   {"id": 212, "customer_id": 21, "total_cents": 13754, "month_offset": 16, "placed_at": "now-489d"},
--   {"id": 213, "customer_id": 21, "total_cents": 7326, "month_offset": 18, "placed_at": "now-545d"},
--   {"id": 214, "customer_id": 22, "total_cents": 7165, "month_offset": 3, "placed_at": "now-93d"},
--   {"id": 215, "customer_id": 22, "total_cents": 4353, "month_offset": 4, "placed_at": "now-115d"},
--   {"id": 216, "customer_id": 22, "total_cents": 12887, "month_offset": 5, "placed_at": "now-149d"},
--   {"id": 217, "customer_id": 22, "total_cents": 14815, "month_offset": 7, "placed_at": "now-205d"},
--   {"id": 218, "customer_id": 22, "total_cents": 9344, "month_offset": 9, "placed_at": "now-275d"},
--   {"id": 219, "customer_id": 22, "total_cents": 13852, "month_offset": 11, "placed_at": "now-345d"},
--   {"id": 220, "customer_id": 22, "total_cents": 12427, "month_offset": 13, "placed_at": "now-383d"},
--   {"id": 221, "customer_id": 22, "total_cents": 11123, "month_offset": 15, "placed_at": "now-459d"},
--   {"id": 222, "customer_id": 22, "total_cents": 14059, "month_offset": 16, "placed_at": "now-474d"},
--   {"id": 223, "customer_id": 22, "total_cents": 4349, "month_offset": 17, "placed_at": "now-516d"},
--   {"id": 224, "customer_id": 22, "total_cents": 11801, "month_offset": 18, "placed_at": "now-544d"},
--   {"id": 225, "customer_id": 23, "total_cents": 9737, "month_offset": 1, "placed_at": "now-37d"},
--   {"id": 226, "customer_id": 23, "total_cents": 10870, "month_offset": 5, "placed_at": "now-148d"},
--   {"id": 227, "customer_id": 23, "total_cents": 3481, "month_offset": 6, "placed_at": "now-175d"},
--   {"id": 228, "customer_id": 23, "total_cents": 12268, "month_offset": 8, "placed_at": "now-246d"},
--   {"id": 229, "customer_id": 23, "total_cents": 7757, "month_offset": 9, "placed_at": "now-264d"},
--   {"id": 230, "customer_id": 23, "total_cents": 7226, "month_offset": 10, "placed_at": "now-289d"},
--   {"id": 231, "customer_id": 23, "total_cents": 8641, "month_offset": 12, "placed_at": "now-359d"},
--   {"id": 232, "customer_id": 23, "total_cents": 5939, "month_offset": 13, "placed_at": "now-395d"},
--   {"id": 233, "customer_id": 23, "total_cents": 3987, "month_offset": 15, "placed_at": "now-450d"},
--   {"id": 234, "customer_id": 23, "total_cents": 9170, "month_offset": 17, "placed_at": "now-526d"},
--   {"id": 235, "customer_id": 24, "total_cents": 7283, "month_offset": 1, "placed_at": "now-32d"},
--   {"id": 236, "customer_id": 24, "total_cents": 9864, "month_offset": 6, "placed_at": "now-171d"},
--   {"id": 237, "customer_id": 24, "total_cents": 10565, "month_offset": 7, "placed_at": "now-200d"},
--   {"id": 238, "customer_id": 24, "total_cents": 4887, "month_offset": 9, "placed_at": "now-259d"},
--   {"id": 239, "customer_id": 24, "total_cents": 14811, "month_offset": 11, "placed_at": "now-336d"},
--   {"id": 240, "customer_id": 24, "total_cents": 7851, "month_offset": 12, "placed_at": "now-359d"},
--   {"id": 241, "customer_id": 24, "total_cents": 6967, "month_offset": 14, "placed_at": "now-417d"},
--   {"id": 242, "customer_id": 24, "total_cents": 14534, "month_offset": 18, "placed_at": "now-536d"},
--   {"id": 243, "customer_id": 25, "total_cents": 8997, "month_offset": 3, "placed_at": "now-85d"},
--   {"id": 244, "customer_id": 25, "total_cents": 8372, "month_offset": 5, "placed_at": "now-140d"},
--   {"id": 245, "customer_id": 25, "total_cents": 11468, "month_offset": 14, "placed_at": "now-413d"},
--   {"id": 246, "customer_id": 26, "total_cents": 6284, "month_offset": 3, "placed_at": "now-83d"},
--   {"id": 247, "customer_id": 26, "total_cents": 6292, "month_offset": 4, "placed_at": "now-125d"},
--   {"id": 248, "customer_id": 26, "total_cents": 8148, "month_offset": 5, "placed_at": "now-141d"},
--   {"id": 249, "customer_id": 26, "total_cents": 11679, "month_offset": 17, "placed_at": "now-517d"},
--   {"id": 250, "customer_id": 27, "total_cents": 4909, "month_offset": 4, "placed_at": "now-122d"},
--   {"id": 251, "customer_id": 27, "total_cents": 4195, "month_offset": 5, "placed_at": "now-140d"},
--   {"id": 252, "customer_id": 27, "total_cents": 12673, "month_offset": 8, "placed_at": "now-245d"},
--   {"id": 253, "customer_id": 27, "total_cents": 10821, "month_offset": 9, "placed_at": "now-273d"},
--   {"id": 254, "customer_id": 27, "total_cents": 4370, "month_offset": 10, "placed_at": "now-292d"},
--   {"id": 255, "customer_id": 28, "total_cents": 8272, "month_offset": 1, "placed_at": "now-38d"},
--   {"id": 256, "customer_id": 28, "total_cents": 2911, "month_offset": 4, "placed_at": "now-109d"},
--   {"id": 257, "customer_id": 28, "total_cents": 9149, "month_offset": 6, "placed_at": "now-169d"},
--   {"id": 258, "customer_id": 28, "total_cents": 4440, "month_offset": 7, "placed_at": "now-214d"},
--   {"id": 259, "customer_id": 28, "total_cents": 8722, "month_offset": 11, "placed_at": "now-321d"},
--   {"id": 260, "customer_id": 28, "total_cents": 5140, "month_offset": 12, "placed_at": "now-364d"},
--   {"id": 261, "customer_id": 29, "total_cents": 8503, "month_offset": 1, "placed_at": "now-18d"},
--   {"id": 262, "customer_id": 29, "total_cents": 3279, "month_offset": 8, "placed_at": "now-233d"},
--   {"id": 263, "customer_id": 29, "total_cents": 5669, "month_offset": 13, "placed_at": "now-392d"},
--   {"id": 264, "customer_id": 29, "total_cents": 10265, "month_offset": 14, "placed_at": "now-431d"},
--   {"id": 265, "customer_id": 29, "total_cents": 10715, "month_offset": 17, "placed_at": "now-522d"},
--   {"id": 266, "customer_id": 30, "total_cents": 8997, "month_offset": 4, "placed_at": "now-127d"},
--   {"id": 267, "customer_id": 30, "total_cents": 7797, "month_offset": 5, "placed_at": "now-159d"},
--   {"id": 268, "customer_id": 30, "total_cents": 10204, "month_offset": 6, "placed_at": "now-177d"},
--   {"id": 269, "customer_id": 30, "total_cents": 11528, "month_offset": 7, "placed_at": "now-210d"},
--   {"id": 270, "customer_id": 30, "total_cents": 10868, "month_offset": 15, "placed_at": "now-452d"},
--   {"id": 271, "customer_id": 30, "total_cents": 12053, "month_offset": 16, "placed_at": "now-498d"},
--   {"id": 272, "customer_id": 30, "total_cents": 10480, "month_offset": 17, "placed_at": "now-508d"},
--   {"id": 273, "customer_id": 31, "total_cents": 9660, "month_offset": 1, "placed_at": "now-29d"},
--   {"id": 274, "customer_id": 31, "total_cents": 4657, "month_offset": 3, "placed_at": "now-102d"},
--   {"id": 275, "customer_id": 31, "total_cents": 8094, "month_offset": 6, "placed_at": "now-183d"},
--   {"id": 276, "customer_id": 32, "total_cents": 14320, "month_offset": 1, "placed_at": "now-21d"},
--   {"id": 277, "customer_id": 32, "total_cents": 8414, "month_offset": 8, "placed_at": "now-254d"},
--   {"id": 278, "customer_id": 32, "total_cents": 5990, "month_offset": 11, "placed_at": "now-323d"},
--   {"id": 279, "customer_id": 33, "total_cents": 10457, "month_offset": 5, "placed_at": "now-143d"},
--   {"id": 280, "customer_id": 33, "total_cents": 13423, "month_offset": 8, "placed_at": "now-238d"},
--   {"id": 281, "customer_id": 33, "total_cents": 13080, "month_offset": 12, "placed_at": "now-351d"},
--   {"id": 282, "customer_id": 33, "total_cents": 9012, "month_offset": 14, "placed_at": "now-413d"},
--   {"id": 283, "customer_id": 33, "total_cents": 8320, "month_offset": 17, "placed_at": "now-506d"},
--   {"id": 284, "customer_id": 33, "total_cents": 8679, "month_offset": 18, "placed_at": "now-539d"},
--   {"id": 285, "customer_id": 34, "total_cents": 3749, "month_offset": 4, "placed_at": "now-111d"},
--   {"id": 286, "customer_id": 34, "total_cents": 14187, "month_offset": 5, "placed_at": "now-143d"},
--   {"id": 287, "customer_id": 34, "total_cents": 10544, "month_offset": 6, "placed_at": "now-183d"},
--   {"id": 288, "customer_id": 34, "total_cents": 9083, "month_offset": 11, "placed_at": "now-327d"},
--   {"id": 289, "customer_id": 34, "total_cents": 13553, "month_offset": 13, "placed_at": "now-394d"},
--   {"id": 290, "customer_id": 34, "total_cents": 14970, "month_offset": 15, "placed_at": "now-452d"},
--   {"id": 291, "customer_id": 34, "total_cents": 9923, "month_offset": 16, "placed_at": "now-488d"},
--   {"id": 292, "customer_id": 35, "total_cents": 12603, "month_offset": 5, "placed_at": "now-155d"},
--   {"id": 293, "customer_id": 35, "total_cents": 11551, "month_offset": 9, "placed_at": "now-259d"},
--   {"id": 294, "customer_id": 35, "total_cents": 5312, "month_offset": 13, "placed_at": "now-395d"},
--   {"id": 295, "customer_id": 35, "total_cents": 10360, "month_offset": 16, "placed_at": "now-477d"},
--   {"id": 296, "customer_id": 36, "total_cents": 9305, "month_offset": 1, "placed_at": "now-23d"},
--   {"id": 297, "customer_id": 36, "total_cents": 3342, "month_offset": 2, "placed_at": "now-52d"},
--   {"id": 298, "customer_id": 36, "total_cents": 12760, "month_offset": 6, "placed_at": "now-181d"},
--   {"id": 299, "customer_id": 36, "total_cents": 5191, "month_offset": 7, "placed_at": "now-201d"},
--   {"id": 300, "customer_id": 36, "total_cents": 10348, "month_offset": 8, "placed_at": "now-240d"},
--   {"id": 301, "customer_id": 36, "total_cents": 7110, "month_offset": 9, "placed_at": "now-265d"},
--   {"id": 302, "customer_id": 36, "total_cents": 5041, "month_offset": 11, "placed_at": "now-332d"},
--   {"id": 303, "customer_id": 36, "total_cents": 7608, "month_offset": 18, "placed_at": "now-538d"},
--   {"id": 304, "customer_id": 37, "total_cents": 4780, "month_offset": 4, "placed_at": "now-113d"},
--   {"id": 305, "customer_id": 37, "total_cents": 3591, "month_offset": 5, "placed_at": "now-142d"},
--   {"id": 306, "customer_id": 37, "total_cents": 3983, "month_offset": 6, "placed_at": "now-186d"},
--   {"id": 307, "customer_id": 37, "total_cents": 3221, "month_offset": 8, "placed_at": "now-230d"},
--   {"id": 308, "customer_id": 37, "total_cents": 9129, "month_offset": 12, "placed_at": "now-359d"},
--   {"id": 309, "customer_id": 37, "total_cents": 14040, "month_offset": 18, "placed_at": "now-533d"},
--   {"id": 310, "customer_id": 39, "total_cents": 4279, "month_offset": 1, "placed_at": "now-15d"},
--   {"id": 311, "customer_id": 39, "total_cents": 14224, "month_offset": 2, "placed_at": "now-62d"},
--   {"id": 312, "customer_id": 39, "total_cents": 9949, "month_offset": 3, "placed_at": "now-78d"},
--   {"id": 313, "customer_id": 39, "total_cents": 7464, "month_offset": 5, "placed_at": "now-150d"},
--   {"id": 314, "customer_id": 39, "total_cents": 3279, "month_offset": 6, "placed_at": "now-170d"},
--   {"id": 315, "customer_id": 39, "total_cents": 6836, "month_offset": 7, "placed_at": "now-200d"},
--   {"id": 316, "customer_id": 39, "total_cents": 14700, "month_offset": 9, "placed_at": "now-271d"},
--   {"id": 317, "customer_id": 39, "total_cents": 13275, "month_offset": 10, "placed_at": "now-311d"},
--   {"id": 318, "customer_id": 39, "total_cents": 10478, "month_offset": 11, "placed_at": "now-339d"},
--   {"id": 319, "customer_id": 39, "total_cents": 3461, "month_offset": 13, "placed_at": "now-394d"},
--   {"id": 320, "customer_id": 39, "total_cents": 8139, "month_offset": 16, "placed_at": "now-485d"},
--   {"id": 321, "customer_id": 39, "total_cents": 13150, "month_offset": 17, "placed_at": "now-508d"},
--   {"id": 322, "customer_id": 39, "total_cents": 7743, "month_offset": 18, "placed_at": "now-552d"},
--   {"id": 323, "customer_id": 40, "total_cents": 7003, "month_offset": 3, "placed_at": "now-89d"},
--   {"id": 324, "customer_id": 40, "total_cents": 5535, "month_offset": 4, "placed_at": "now-113d"},
--   {"id": 325, "customer_id": 40, "total_cents": 9701, "month_offset": 7, "placed_at": "now-206d"},
--   {"id": 326, "customer_id": 40, "total_cents": 4637, "month_offset": 9, "placed_at": "now-259d"},
--   {"id": 327, "customer_id": 40, "total_cents": 12739, "month_offset": 11, "placed_at": "now-321d"},
--   {"id": 328, "customer_id": 40, "total_cents": 7161, "month_offset": 12, "placed_at": "now-374d"},
--   {"id": 329, "customer_id": 40, "total_cents": 4907, "month_offset": 14, "placed_at": "now-418d"},
--   {"id": 330, "customer_id": 41, "total_cents": 12781, "month_offset": 1, "placed_at": "now-23d"},
--   {"id": 331, "customer_id": 41, "total_cents": 8714, "month_offset": 2, "placed_at": "now-45d"},
--   {"id": 332, "customer_id": 41, "total_cents": 7146, "month_offset": 3, "placed_at": "now-92d"},
--   {"id": 333, "customer_id": 41, "total_cents": 5256, "month_offset": 4, "placed_at": "now-117d"},
--   {"id": 334, "customer_id": 41, "total_cents": 9759, "month_offset": 5, "placed_at": "now-154d"},
--   {"id": 335, "customer_id": 41, "total_cents": 6310, "month_offset": 6, "placed_at": "now-193d"},
--   {"id": 336, "customer_id": 41, "total_cents": 3040, "month_offset": 7, "placed_at": "now-215d"},
--   {"id": 337, "customer_id": 41, "total_cents": 6030, "month_offset": 8, "placed_at": "now-247d"},
--   {"id": 338, "customer_id": 41, "total_cents": 8992, "month_offset": 14, "placed_at": "now-426d"},
--   {"id": 339, "customer_id": 41, "total_cents": 7886, "month_offset": 15, "placed_at": "now-446d"},
--   {"id": 340, "customer_id": 41, "total_cents": 11274, "month_offset": 16, "placed_at": "now-492d"},
--   {"id": 341, "customer_id": 41, "total_cents": 6616, "month_offset": 17, "placed_at": "now-514d"},
--   {"id": 342, "customer_id": 41, "total_cents": 6097, "month_offset": 18, "placed_at": "now-533d"},
--   {"id": 343, "customer_id": 42, "total_cents": 7249, "month_offset": 3, "placed_at": "now-96d"},
--   {"id": 344, "customer_id": 42, "total_cents": 13048, "month_offset": 6, "placed_at": "now-170d"},
--   {"id": 345, "customer_id": 42, "total_cents": 13229, "month_offset": 8, "placed_at": "now-255d"},
--   {"id": 346, "customer_id": 42, "total_cents": 6046, "month_offset": 9, "placed_at": "now-267d"},
--   {"id": 347, "customer_id": 42, "total_cents": 12423, "month_offset": 11, "placed_at": "now-334d"},
--   {"id": 348, "customer_id": 42, "total_cents": 5892, "month_offset": 13, "placed_at": "now-383d"},
--   {"id": 349, "customer_id": 42, "total_cents": 4410, "month_offset": 14, "placed_at": "now-410d"},
--   {"id": 350, "customer_id": 42, "total_cents": 6916, "month_offset": 16, "placed_at": "now-488d"},
--   {"id": 351, "customer_id": 42, "total_cents": 6945, "month_offset": 18, "placed_at": "now-536d"},
--   {"id": 352, "customer_id": 43, "total_cents": 9976, "month_offset": 1, "placed_at": "now-15d"},
--   {"id": 353, "customer_id": 43, "total_cents": 3054, "month_offset": 4, "placed_at": "now-131d"},
--   {"id": 354, "customer_id": 43, "total_cents": 11169, "month_offset": 8, "placed_at": "now-243d"},
--   {"id": 355, "customer_id": 43, "total_cents": 8547, "month_offset": 10, "placed_at": "now-307d"},
--   {"id": 356, "customer_id": 43, "total_cents": 3228, "month_offset": 14, "placed_at": "now-429d"},
--   {"id": 357, "customer_id": 43, "total_cents": 13729, "month_offset": 16, "placed_at": "now-485d"},
--   {"id": 358, "customer_id": 43, "total_cents": 11392, "month_offset": 17, "placed_at": "now-516d"},
--   {"id": 359, "customer_id": 43, "total_cents": 9015, "month_offset": 18, "placed_at": "now-540d"},
--   {"id": 360, "customer_id": 44, "total_cents": 8338, "month_offset": 2, "placed_at": "now-55d"},
--   {"id": 361, "customer_id": 44, "total_cents": 7844, "month_offset": 3, "placed_at": "now-89d"},
--   {"id": 362, "customer_id": 44, "total_cents": 5389, "month_offset": 4, "placed_at": "now-121d"},
--   {"id": 363, "customer_id": 44, "total_cents": 11067, "month_offset": 5, "placed_at": "now-144d"},
--   {"id": 364, "customer_id": 44, "total_cents": 8610, "month_offset": 7, "placed_at": "now-206d"},
--   {"id": 365, "customer_id": 44, "total_cents": 7023, "month_offset": 8, "placed_at": "now-246d"},
--   {"id": 366, "customer_id": 44, "total_cents": 13900, "month_offset": 9, "placed_at": "now-274d"},
--   {"id": 367, "customer_id": 44, "total_cents": 14220, "month_offset": 10, "placed_at": "now-303d"},
--   {"id": 368, "customer_id": 44, "total_cents": 4652, "month_offset": 11, "placed_at": "now-342d"},
--   {"id": 369, "customer_id": 44, "total_cents": 12974, "month_offset": 13, "placed_at": "now-396d"},
--   {"id": 370, "customer_id": 44, "total_cents": 6846, "month_offset": 15, "placed_at": "now-459d"},
--   {"id": 371, "customer_id": 45, "total_cents": 4061, "month_offset": 5, "placed_at": "now-141d"},
--   {"id": 372, "customer_id": 45, "total_cents": 5712, "month_offset": 6, "placed_at": "now-181d"},
--   {"id": 373, "customer_id": 45, "total_cents": 14974, "month_offset": 7, "placed_at": "now-218d"},
--   {"id": 374, "customer_id": 45, "total_cents": 7221, "month_offset": 8, "placed_at": "now-235d"},
--   {"id": 375, "customer_id": 45, "total_cents": 3901, "month_offset": 9, "placed_at": "now-261d"},
--   {"id": 376, "customer_id": 45, "total_cents": 12102, "month_offset": 10, "placed_at": "now-290d"},
--   {"id": 377, "customer_id": 45, "total_cents": 12902, "month_offset": 11, "placed_at": "now-323d"},
--   {"id": 378, "customer_id": 45, "total_cents": 5869, "month_offset": 12, "placed_at": "now-351d"},
--   {"id": 379, "customer_id": 45, "total_cents": 14966, "month_offset": 13, "placed_at": "now-397d"},
--   {"id": 380, "customer_id": 45, "total_cents": 3479, "month_offset": 16, "placed_at": "now-486d"},
--   {"id": 381, "customer_id": 45, "total_cents": 13062, "month_offset": 18, "placed_at": "now-535d"},
--   {"id": 382, "customer_id": 46, "total_cents": 11143, "month_offset": 3, "placed_at": "now-90d"},
--   {"id": 383, "customer_id": 46, "total_cents": 10050, "month_offset": 12, "placed_at": "now-370d"},
--   {"id": 384, "customer_id": 46, "total_cents": 3071, "month_offset": 13, "placed_at": "now-382d"},
--   {"id": 385, "customer_id": 46, "total_cents": 6351, "month_offset": 16, "placed_at": "now-492d"},
--   {"id": 386, "customer_id": 46, "total_cents": 8552, "month_offset": 17, "placed_at": "now-516d"},
--   {"id": 387, "customer_id": 47, "total_cents": 10699, "month_offset": 1, "placed_at": "now-19d"},
--   {"id": 388, "customer_id": 47, "total_cents": 9874, "month_offset": 3, "placed_at": "now-96d"},
--   {"id": 389, "customer_id": 47, "total_cents": 8161, "month_offset": 8, "placed_at": "now-255d"},
--   {"id": 390, "customer_id": 47, "total_cents": 6642, "month_offset": 10, "placed_at": "now-314d"},
--   {"id": 391, "customer_id": 47, "total_cents": 4962, "month_offset": 11, "placed_at": "now-333d"},
--   {"id": 392, "customer_id": 47, "total_cents": 5846, "month_offset": 17, "placed_at": "now-506d"},
--   {"id": 393, "customer_id": 47, "total_cents": 5315, "month_offset": 18, "placed_at": "now-537d"},
--   {"id": 394, "customer_id": 48, "total_cents": 8462, "month_offset": 2, "placed_at": "now-46d"},
--   {"id": 395, "customer_id": 48, "total_cents": 2351, "month_offset": 4, "placed_at": "now-111d"},
--   {"id": 396, "customer_id": 48, "total_cents": 8368, "month_offset": 5, "placed_at": "now-141d"},
--   {"id": 397, "customer_id": 48, "total_cents": 14718, "month_offset": 8, "placed_at": "now-229d"},
--   {"id": 398, "customer_id": 48, "total_cents": 11080, "month_offset": 9, "placed_at": "now-257d"},
--   {"id": 399, "customer_id": 48, "total_cents": 4657, "month_offset": 11, "placed_at": "now-340d"},
--   {"id": 400, "customer_id": 48, "total_cents": 10150, "month_offset": 12, "placed_at": "now-355d"},
--   {"id": 401, "customer_id": 48, "total_cents": 12495, "month_offset": 15, "placed_at": "now-446d"},
--   {"id": 402, "customer_id": 48, "total_cents": 3793, "month_offset": 16, "placed_at": "now-491d"},
--   {"id": 403, "customer_id": 48, "total_cents": 6981, "month_offset": 18, "placed_at": "now-539d"},
--   {"id": 404, "customer_id": 49, "total_cents": 6963, "month_offset": 4, "placed_at": "now-130d"},
--   {"id": 405, "customer_id": 49, "total_cents": 4450, "month_offset": 6, "placed_at": "now-183d"},
--   {"id": 406, "customer_id": 49, "total_cents": 8918, "month_offset": 7, "placed_at": "now-213d"},
--   {"id": 407, "customer_id": 49, "total_cents": 4899, "month_offset": 15, "placed_at": "now-447d"},
--   {"id": 408, "customer_id": 49, "total_cents": 5341, "month_offset": 17, "placed_at": "now-503d"},
--   {"id": 409, "customer_id": 49, "total_cents": 9558, "month_offset": 18, "placed_at": "now-541d"},
--   {"id": 410, "customer_id": 50, "total_cents": 11957, "month_offset": 3, "placed_at": "now-91d"},
--   {"id": 411, "customer_id": 50, "total_cents": 3548, "month_offset": 4, "placed_at": "now-108d"},
--   {"id": 412, "customer_id": 50, "total_cents": 14614, "month_offset": 10, "placed_at": "now-294d"},
--   {"id": 413, "customer_id": 50, "total_cents": 11416, "month_offset": 12, "placed_at": "now-368d"},
--   {"id": 414, "customer_id": 50, "total_cents": 3248, "month_offset": 13, "placed_at": "now-402d"},
--   {"id": 415, "customer_id": 50, "total_cents": 11036, "month_offset": 18, "placed_at": "now-544d"},
--   {"id": 416, "customer_id": 51, "total_cents": 8495, "month_offset": 1, "placed_at": "now-24d"},
--   {"id": 417, "customer_id": 51, "total_cents": 3689, "month_offset": 2, "placed_at": "now-63d"},
--   {"id": 418, "customer_id": 51, "total_cents": 5469, "month_offset": 4, "placed_at": "now-111d"},
--   {"id": 419, "customer_id": 51, "total_cents": 14000, "month_offset": 7, "placed_at": "now-218d"},
--   {"id": 420, "customer_id": 51, "total_cents": 13329, "month_offset": 12, "placed_at": "now-354d"},
--   {"id": 421, "customer_id": 51, "total_cents": 7722, "month_offset": 13, "placed_at": "now-397d"},
--   {"id": 422, "customer_id": 51, "total_cents": 4657, "month_offset": 14, "placed_at": "now-426d"},
--   {"id": 423, "customer_id": 51, "total_cents": 14153, "month_offset": 18, "placed_at": "now-548d"},
--   {"id": 424, "customer_id": 52, "total_cents": 9084, "month_offset": 2, "placed_at": "now-64d"},
--   {"id": 425, "customer_id": 52, "total_cents": 5508, "month_offset": 4, "placed_at": "now-107d"},
--   {"id": 426, "customer_id": 52, "total_cents": 4057, "month_offset": 6, "placed_at": "now-188d"},
--   {"id": 427, "customer_id": 52, "total_cents": 14281, "month_offset": 7, "placed_at": "now-201d"},
--   {"id": 428, "customer_id": 52, "total_cents": 12070, "month_offset": 12, "placed_at": "now-366d"},
--   {"id": 429, "customer_id": 52, "total_cents": 8904, "month_offset": 15, "placed_at": "now-453d"},
--   {"id": 430, "customer_id": 53, "total_cents": 4988, "month_offset": 2, "placed_at": "now-57d"},
--   {"id": 431, "customer_id": 53, "total_cents": 4019, "month_offset": 7, "placed_at": "now-198d"},
--   {"id": 432, "customer_id": 53, "total_cents": 10948, "month_offset": 11, "placed_at": "now-321d"},
--   {"id": 433, "customer_id": 53, "total_cents": 6676, "month_offset": 12, "placed_at": "now-356d"},
--   {"id": 434, "customer_id": 53, "total_cents": 4080, "month_offset": 13, "placed_at": "now-385d"},
--   {"id": 435, "customer_id": 53, "total_cents": 3075, "month_offset": 15, "placed_at": "now-449d"},
--   {"id": 436, "customer_id": 53, "total_cents": 6698, "month_offset": 18, "placed_at": "now-540d"},
--   {"id": 437, "customer_id": 54, "total_cents": 3994, "month_offset": 3, "placed_at": "now-78d"},
--   {"id": 438, "customer_id": 54, "total_cents": 11881, "month_offset": 5, "placed_at": "now-144d"},
--   {"id": 439, "customer_id": 54, "total_cents": 3434, "month_offset": 10, "placed_at": "now-307d"},
--   {"id": 440, "customer_id": 54, "total_cents": 10085, "month_offset": 14, "placed_at": "now-422d"},
--   {"id": 441, "customer_id": 55, "total_cents": 5229, "month_offset": 3, "placed_at": "now-79d"},
--   {"id": 442, "customer_id": 55, "total_cents": 6585, "month_offset": 10, "placed_at": "now-297d"},
--   {"id": 443, "customer_id": 55, "total_cents": 13290, "month_offset": 12, "placed_at": "now-359d"},
--   {"id": 444, "customer_id": 55, "total_cents": 9999, "month_offset": 17, "placed_at": "now-516d"},
--   {"id": 445, "customer_id": 56, "total_cents": 3421, "month_offset": 1, "placed_at": "now-31d"},
--   {"id": 446, "customer_id": 56, "total_cents": 6456, "month_offset": 11, "placed_at": "now-345d"},
--   {"id": 447, "customer_id": 56, "total_cents": 7760, "month_offset": 12, "placed_at": "now-354d"},
--   {"id": 448, "customer_id": 56, "total_cents": 6005, "month_offset": 14, "placed_at": "now-418d"},
--   {"id": 449, "customer_id": 56, "total_cents": 10071, "month_offset": 18, "placed_at": "now-546d"},
--   {"id": 450, "customer_id": 57, "total_cents": 13621, "month_offset": 10, "placed_at": "now-294d"},
--   {"id": 451, "customer_id": 57, "total_cents": 3339, "month_offset": 12, "placed_at": "now-368d"},
--   {"id": 452, "customer_id": 57, "total_cents": 5797, "month_offset": 15, "placed_at": "now-463d"},
--   {"id": 453, "customer_id": 58, "total_cents": 4354, "month_offset": 3, "placed_at": "now-87d"},
--   {"id": 454, "customer_id": 58, "total_cents": 5897, "month_offset": 4, "placed_at": "now-116d"},
--   {"id": 455, "customer_id": 58, "total_cents": 10868, "month_offset": 7, "placed_at": "now-201d"},
--   {"id": 456, "customer_id": 58, "total_cents": 12253, "month_offset": 10, "placed_at": "now-312d"},
--   {"id": 457, "customer_id": 58, "total_cents": 11786, "month_offset": 14, "placed_at": "now-420d"},
--   {"id": 458, "customer_id": 58, "total_cents": 8170, "month_offset": 17, "placed_at": "now-508d"},
--   {"id": 459, "customer_id": 59, "total_cents": 10215, "month_offset": 9, "placed_at": "now-278d"},
--   {"id": 460, "customer_id": 59, "total_cents": 8794, "month_offset": 11, "placed_at": "now-332d"},
--   {"id": 461, "customer_id": 60, "total_cents": 12306, "month_offset": 9, "placed_at": "now-273d"},
--   {"id": 462, "customer_id": 60, "total_cents": 14344, "month_offset": 11, "placed_at": "now-319d"},
--   {"id": 463, "customer_id": 60, "total_cents": 3518, "month_offset": 13, "placed_at": "now-381d"}
-- ]};

SELECT "segment", "r", "f", "m", "n_customers"
FROM "bi_archetypes"
GROUP BY "segment", "r", "f", "m", "n_customers"
ORDER BY "segment";

-- The seed summary.
SELECT (SELECT COUNT(*) FROM "bi_customers") AS "customers",
       (SELECT COUNT(*) FROM "bi_orders") AS "orders",
       (SELECT SUM("total_cents") FROM "bi_orders") AS "total_revenue_cents",
       (SELECT COUNT(DISTINCT "segment") FROM "bi_customers") AS "segments";

-- A customer's feature vector: (recency, frequency, monetary), each
-- component in [-1, 1], recency -1 being the most recent.
SELECT "customer_id", "feature_vec"
FROM "bi_customer_features"
GROUP BY "customer_id", "feature_vec"
ORDER BY "customer_id";

-- ---------------------------------------------------------------------------
-- 2. Simple fact lookup: generate, then execute.
--
-- No reasoning yet -- this is the loop's first half only, to show what
-- "generate then execute" looks like plainly before interpretation is
-- added on top of it in Section 3.
-- ---------------------------------------------------------------------------
-- @call agent/data_analyst {"question": "How many customers do we have, and what is our total revenue in cents? The table bi_customers has columns id (long), name (varchar), segment (varchar), status (varchar); the table bi_orders has columns id (long), customer_id (long), total_cents (long), month_offset (long) and the timestamp column __time (timestamp). Count every customer, and sum total_cents over every order.",
--                          "table_names": ["bi_customers", "bi_orders"]} AS bi_lookup;

SELECT "generated_sql" AS "sql_text", "execution_status" FROM "bi_lookup";

-- The real result rows.
SELECT "result_rows" AS "result_rows" FROM "bi_lookup";

-- The numbers the data itself says, for comparison.
--
-- Worth noticing: Druid's COUNT(DISTINCT) is an approximate count -- a
-- HyperLogLog sketch -- so the model's distinct customer count can
-- read a shade above the truth (sixty customers can come back as
-- sixty-one). The exact count is a DISTINCT inside a subquery. Either
-- way the SQL is worth reading, not just trusting that the English
-- question implies it.
SELECT (SELECT COUNT(*) FROM "bi_customers") AS "all_customers",
       (SELECT COUNT(*) FROM (SELECT DISTINCT "id" FROM "bi_customers") t) AS "distinct_customers",
       (SELECT COUNT(*) FROM "bi_orders") AS "all_orders",
       (SELECT SUM("total_cents") FROM "bi_orders") AS "total_revenue_cents";

-- ---------------------------------------------------------------------------
-- 3. The full BI loop: generate, execute, then reason over the REAL
-- result.
--
-- The question is designed to surface the month-four dip baked into
-- the data -- the reasoner sees the actual monthly numbers, not a
-- hint that a dip exists. The current, in-progress month is excluded
-- explicitly: otherwise whatever partial month is running when the kit
-- executes always looks like a fake dip, which would be a real and
-- common BI reporting mistake to bake into a demo unremarked.
-- ---------------------------------------------------------------------------
-- @call text-to-sql {"question": "show total revenue for each of the 6 most recent FULLY COMPLETED calendar months, excluding the current in-progress month, oldest first; the table bi_orders has columns id (long), customer_id (long), total_cents (long), month_offset (long) and placed_at (a timestamp written as text, YYYY-MM-DDTHH:MM:SSZ); month_offset counts the months back from the most recent completed month, so the 6 most recent completed months are exactly the rows with month_offset between 1 and 6; write one SELECT statement that groups by month_offset and sums total_cents",
--                   "tables": ["bi_orders"]} AS bi_trend_sql;

SELECT "generated_sql" AS "sql_text", "valid" FROM "bi_trend_sql";

-- The executed result: the revenue of each of the 18 completed
-- months, most recent first (month_offset 1 is the most recent).
REPLACE INTO bi_trend OVERWRITE ALL
SELECT "month_offset",
       ANY_VALUE(SUBSTR("placed_at", 1, 7)) AS "month",
       SUM("total_cents") AS "revenue_cents",
       COUNT(*) AS "orders"
FROM "bi_orders"
GROUP BY "month_offset"
PARTITIONED BY ALL;

SELECT "month_offset", "month", "revenue_cents", "orders"
FROM "bi_trend"
GROUP BY "month_offset", "month", "revenue_cents", "orders"
ORDER BY "month_offset";

-- The last six completed months. (The question asks for them oldest
-- first; the narrative below gets them in that order, in the JSON it
-- is handed.)
REPLACE INTO bi_recent_trend OVERWRITE ALL
SELECT "month_offset", "month", "revenue_cents", "orders"
FROM "bi_trend"
WHERE "month_offset" <= 6
PARTITIONED BY ALL;

SELECT "month_offset", "month", "revenue_cents", "orders"
FROM "bi_recent_trend"
GROUP BY "month_offset", "month", "revenue_cents", "orders"
ORDER BY "month_offset";

REPLACE INTO bi_segment_mix OVERWRITE ALL
SELECT "segment", COUNT(*) AS "customers"
FROM "bi_customers"
GROUP BY "segment"
PARTITIONED BY ALL;

REPLACE INTO bi_status_breakdown OVERWRITE ALL
SELECT "status", COUNT(*) AS "customers"
FROM "bi_customers"
GROUP BY "status"
PARTITIONED BY ALL;

-- The facts the narratives reason over, assembled in SQL: the months
-- as a JSON array (written out one by one, in order, because a Druid
-- aggregate does not promise the order of the rows it collects and a
-- narrative reads the months as a series), the segment mix and the
-- status breakdown.
REPLACE INTO bi_facts OVERWRITE ALL
SELECT CONCAT('[', (SELECT CONCAT('{"month_offset":', CAST("month_offset" AS VARCHAR), ',"month":"', "month", '","revenue_cents":', CAST("revenue_cents" AS VARCHAR), '}') FROM "bi_recent_trend" WHERE "month_offset" = 6), ',', (SELECT CONCAT('{"month_offset":', CAST("month_offset" AS VARCHAR), ',"month":"', "month", '","revenue_cents":', CAST("revenue_cents" AS VARCHAR), '}') FROM "bi_recent_trend" WHERE "month_offset" = 5), ',', (SELECT CONCAT('{"month_offset":', CAST("month_offset" AS VARCHAR), ',"month":"', "month", '","revenue_cents":', CAST("revenue_cents" AS VARCHAR), '}') FROM "bi_recent_trend" WHERE "month_offset" = 4), ',', (SELECT CONCAT('{"month_offset":', CAST("month_offset" AS VARCHAR), ',"month":"', "month", '","revenue_cents":', CAST("revenue_cents" AS VARCHAR), '}') FROM "bi_recent_trend" WHERE "month_offset" = 3), ',', (SELECT CONCAT('{"month_offset":', CAST("month_offset" AS VARCHAR), ',"month":"', "month", '","revenue_cents":', CAST("revenue_cents" AS VARCHAR), '}') FROM "bi_recent_trend" WHERE "month_offset" = 2), ',', (SELECT CONCAT('{"month_offset":', CAST("month_offset" AS VARCHAR), ',"month":"', "month", '","revenue_cents":', CAST("revenue_cents" AS VARCHAR), '}') FROM "bi_recent_trend" WHERE "month_offset" = 1), ']') AS "context",
       CONCAT('{"monthly_revenue":', CONCAT('[', (SELECT CONCAT('{"month_offset":', CAST("month_offset" AS VARCHAR), ',"month":"', "month", '","revenue_cents":', CAST("revenue_cents" AS VARCHAR), '}') FROM "bi_recent_trend" WHERE "month_offset" = 6), ',', (SELECT CONCAT('{"month_offset":', CAST("month_offset" AS VARCHAR), ',"month":"', "month", '","revenue_cents":', CAST("revenue_cents" AS VARCHAR), '}') FROM "bi_recent_trend" WHERE "month_offset" = 5), ',', (SELECT CONCAT('{"month_offset":', CAST("month_offset" AS VARCHAR), ',"month":"', "month", '","revenue_cents":', CAST("revenue_cents" AS VARCHAR), '}') FROM "bi_recent_trend" WHERE "month_offset" = 4), ',', (SELECT CONCAT('{"month_offset":', CAST("month_offset" AS VARCHAR), ',"month":"', "month", '","revenue_cents":', CAST("revenue_cents" AS VARCHAR), '}') FROM "bi_recent_trend" WHERE "month_offset" = 3), ',', (SELECT CONCAT('{"month_offset":', CAST("month_offset" AS VARCHAR), ',"month":"', "month", '","revenue_cents":', CAST("revenue_cents" AS VARCHAR), '}') FROM "bi_recent_trend" WHERE "month_offset" = 2), ',', (SELECT CONCAT('{"month_offset":', CAST("month_offset" AS VARCHAR), ',"month":"', "month", '","revenue_cents":', CAST("revenue_cents" AS VARCHAR), '}') FROM "bi_recent_trend" WHERE "month_offset" = 1), ']'), ',"segment_mix":[',
              (SELECT ARRAY_TO_STRING(ARRAY_AGG(CONCAT('{"segment":"', "segment",
                       '","customers":', CAST("customers" AS VARCHAR), '}'), 16384), ',')
               FROM "bi_segment_mix"),
              '],"status_breakdown":[',
              (SELECT ARRAY_TO_STRING(ARRAY_AGG(CONCAT('{"status":"', "status",
                       '","customers":', CAST("customers" AS VARCHAR), '}'), 16384), ',')
               FROM "bi_status_breakdown"),
              ']}') AS "full_context"
PARTITIONED BY ALL;

-- Reasoning over the actual result (not the question, the DATA).
SELECT fractal_reason(
           'this is our last 6 months of revenue by month. month_offset 1 is the most '
           || 'recent completed month and 6 the oldest, and the revenue is in cents. '
           || 'What happened, and does it need attention?',
           (SELECT "context" FROM "bi_facts")) AS "trend_narrative";

-- ---------------------------------------------------------------------------
-- 4. General data reasoning: synthesize across SEVERAL facts in one
-- call, not translate one question into one query. This is the
-- capability text-to-SQL alone cannot offer -- a single SQL statement
-- cannot hold "here is the trend AND the segment mix AND the churn
-- signal, now tell me what is really going on".
-- ---------------------------------------------------------------------------
SELECT fractal_reason(
           'given revenue trend, customer segment mix, and status breakdown together, '
           || 'what is the state of the business and what would you look into first?',
           (SELECT "full_context" FROM "bi_facts")) AS "business_narrative";

-- ---------------------------------------------------------------------------
-- 5. Sniper Search: converge toward a TARGET customer archetype.
--
-- Not a lookup against real customers -- SFS refines toward the
-- mathematically ideal point matching the query direction, useful for
-- "what would our best-possible customer profile look like" before
-- you go find (or build toward) one.
--
-- The exact magnitude varies from run to run (sometimes near the
-- [-1,1] box edges, sometimes a scaled-down interior point) -- cosine
-- similarity, which is what SFS optimizes for, is scale-invariant, so
-- every point along the same ray as the query scores identically. Read
-- this as a DIRECTION to aim for, not a literal target coordinate.
-- ---------------------------------------------------------------------------
REPLACE INTO bi_sniper_result OVERWRITE ALL
SELECT fractal_search_debug('-0.7,0.7,0.7', 50, 20, 2.0) AS "result"
PARTITIONED BY ALL;

-- The ideal point, read out of the search's own document.
SELECT fractal_json_value("result", '$.best_point[0]') AS "recency",
       fractal_json_value("result", '$.best_point[1]') AS "frequency",
       fractal_json_value("result", '$.best_point[2]') AS "monetary"
FROM "bi_sniper_result";

-- ---------------------------------------------------------------------------
-- 6. Scout Discovery: find real, DIVERSE customer segments from the
-- actual stored feature vectors -- then name them in business language.
--
-- The explore query is a small nonzero point, NOT the origin -- cosine
-- is undefined for a zero vector. It points between archetypes rather
-- than at one, so the population has more than one basin to disperse
-- into: the point the search starts from is what decides whether
-- Scout returns one cluster or several.
-- ---------------------------------------------------------------------------
-- @call search/explore {"datasource": "bi_customer_features",
--                      "vectorColumn": "feature_vec", "idColumn": "customer_id",
--                      "query": "0.6,-0.6,0.6", "k": 8,
--                      "params": "{\"population_size\": 8, \"iterations\": 10}"} AS bi_scout;

-- The population Scout found, matched back to the customers it came
-- from.
SELECT r."ord" AS "ord", r."doc_id" AS "customer_id",
       c."name" AS "name", c."segment" AS "segment", f."feature_vec" AS "feature_vec"
FROM "bi_scout" r, "bi_customer_features" f, "bi_customers" c
WHERE r."doc_id" = f."customer_id" AND f."customer_id" = c."id";

-- Naming the segments Scout actually found, in business language.
-- @call reason {"query": "each item is a (recency, frequency, monetary) customer profile in [-1,1], where recency -1 is very recent, frequency/monetary +1 is high. Name and describe each distinct segment in one line.",
--               "context": "$previous"} AS bi_scout_names;

SELECT (SELECT "answer" FROM "bi_scout_names") AS "segment_names";

-- ---------------------------------------------------------------------------
-- The headline.
--
-- The kit passes when the business data is the business data the kit
-- seeded (sixty customers in five segments, eighteen months of
-- orders), when the revenue dip the data carries is visible in the
-- executed trend -- the month four months back is the weakest of its
-- neighbours -- when Scout returns a population that is genuinely
-- diverse (three segments or more, not one cluster), and when
-- Sniper's ideal point points the way the query asked for (recent,
-- frequent, valuable).
-- ---------------------------------------------------------------------------
SELECT CASE
           WHEN (SELECT COUNT(*) FROM "bi_customers") = 60
            AND (SELECT COUNT(*) FROM (SELECT DISTINCT "segment" FROM "bi_customers") t) = 5
            AND (SELECT COUNT(*) FROM "bi_trend") = 18
            AND (SELECT "revenue_cents" FROM "bi_trend" WHERE "month_offset" = 4)
                < (SELECT "revenue_cents" FROM "bi_trend" WHERE "month_offset" = 3)
            AND (SELECT "revenue_cents" FROM "bi_trend" WHERE "month_offset" = 4)
                < (SELECT "revenue_cents" FROM "bi_trend" WHERE "month_offset" = 5)
            AND (SELECT COUNT(*) FROM "bi_scout") >= 4
            AND (SELECT COUNT(*) FROM (SELECT DISTINCT c."segment" FROM "bi_scout" r,
                        "bi_customers" c WHERE r."doc_id" = c."id") t) >= 3
            AND (SELECT fractal_json_value("result", '$.best_point[0]')
                   FROM "bi_sniper_result") < 0
            AND (SELECT fractal_json_value("result", '$.best_point[1]')
                   FROM "bi_sniper_result") > 0
            AND (SELECT fractal_json_value("result", '$.best_point[2]')
                   FROM "bi_sniper_result") > 0
            THEN 'HEADLINE kit=demo-business-intelligence ok'
            ELSE 'HEADLINE kit=demo-business-intelligence FAILED'
       END AS "headline";
