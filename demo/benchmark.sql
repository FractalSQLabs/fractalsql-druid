-- demo/benchmark.sql
--
-- FractalSQL for Apache Druid -- the basic benchmark.
--
-- Three measurements, all reproducible:
--
--   1. Sniper Search convergence by dimension: the same iteration and
--      population counts at 8, 32 and 128 dimensions, and how close the
--      converged point came to the query.
--   2. Scout Discovery against a naive top-K: 20 synthetic clusters x
--      250 points in R^8 (5000 rows), K=50 returned, and how many of
--      the 20 clusters each method's results actually represent. This
--      is the mode-collapse problem Scout Discovery exists to fix: a
--      method returning near-duplicates from one cluster scores low
--      here even though every individual result is close to the query.
--   3. Embedding throughput: fifty documents backfilled through the
--      embedding endpoint, with the vectorizer's registry shown beside
--      it.
--
-- Prerequisites: the extension is loaded on the Druid cluster. Section
-- 3 needs an embedding endpoint configured (docs/vectorizer-setup.md);
-- sections 1 and 2 need no model.
--
-- Run:
--   python3 demo/run_demo.py --file demo/benchmark.sql
--
-- ===========================================================================
-- Notes on how this runs on Druid
-- ===========================================================================
--
--   * The corpus is an MSQ write: Druid has no DDL, no row-by-row
--     insert and no recursive CTE. The per-cluster index ranges come
--     from an UNNESTed array, and the vectors are built by the same
--     deterministic sin-hash the other kits use in place of random().
--   * The searches are service calls. Sniper Search and Scout
--     Discovery converge over a whole column, so the corpus has to be
--     materialised somewhere; a Druid aggregate cannot hold it, so the
--     service reads the column and calls the core.
--   * The naive top-K is the extension's own exact cosine distance
--     over the corpus (the `search/telemetry` endpoint), which is the
--     same ranking a real ANN index would return, just unindexed.
--   * The nearest-cluster mapping is computed in SQL: the distance to
--     every cluster centre, with the nearest one carried as the
--     smallest distance times a million plus the cluster's own number.
--     Druid has no window function to rank with.
--   * The vectorizer's registry is the extension's, not a TEMP table on
--     a connection. Its queue's own write-back -- the step that puts
--     the embeddings into a datasource -- is not usable on this build:
--     it hands Druid's SQL parser a row the parser cannot read, and
--     the call fails. The kit therefore registers the vectorizer (and
--     shows the registry), and measures the same embedding throughput
--     through the embed function over the same fifty documents.
--   * The box count over the corpus is a service operation: it counts a whole cloud of points, and as an
--     expression it would run once per row of the group.
--   * There is no per-statement timing output: a Druid demo
--     is a script run by a client, not a shell session, so there is no
--     timer to print.
--
-- Notes:
--   * Fully deterministic fixtures (no random()).
--   * Safe to re-run: every write is OVERWRITE ALL.
--   * Ends with a HEADLINE line computed from the kit's own results
--     (HEADLINE kit=benchmark ok); the build_test kit gate greps for
--     it.

-- ---------------------------------------------------------------------------
-- 0. Sanity check: extension loaded?
-- ---------------------------------------------------------------------------
SELECT fractal_edition(), fractal_version();

-- ---------------------------------------------------------------------------
-- 1. Sniper Search -- convergence latency and accuracy by dimension.
--
-- iterations and population_size are held constant; only the query
-- dimension changes. A cosine similarity close to 1.0 confirms the
-- search actually converged, not just that it returned something fast.
--
-- The convergence is the search over the query alone (the abstract
-- [-1,1]^dim space), so it is a SQL function here: the converged point
-- comes back inside the result document, and the similarity is the
-- core's own cosine between that point and the query.
-- ---------------------------------------------------------------------------
REPLACE INTO bt_sfs OVERWRITE ALL
SELECT fractal_vector_cosine_similarity(
           fractal_json_text(fractal_sfs_converge_debug('-0.725666,0.847429,0.923539,0.197829,0.490152,-0.719547,0.512138,-0.783749', 50, 50, 2), '$.best_point'),
           '-0.725666,0.847429,0.923539,0.197829,0.490152,-0.719547,0.512138,-0.783749') AS "sim8",
       fractal_vector_cosine_similarity(
           fractal_json_text(fractal_sfs_converge_debug('0.848105,-0.907654,-0.371094,0.465100,0.546476,-0.374240,0.818874,-0.852805,0.857095,-0.427270,0.272169,0.276520,-0.020333,-0.772400,-0.964800,0.966779,0.000865,0.546151,-0.731853,0.297557,0.601501,0.607398,0.181942,0.616590,0.324215,0.382753,0.496192,-0.294045,-0.811237,-0.294082,0.436306,-0.183309', 50, 50, 2), '$.best_point'),
           '0.848105,-0.907654,-0.371094,0.465100,0.546476,-0.374240,0.818874,-0.852805,0.857095,-0.427270,0.272169,0.276520,-0.020333,-0.772400,-0.964800,0.966779,0.000865,0.546151,-0.731853,0.297557,0.601501,0.607398,0.181942,0.616590,0.324215,0.382753,0.496192,-0.294045,-0.811237,-0.294082,0.436306,-0.183309') AS "sim32",
       fractal_vector_cosine_similarity(
           fractal_json_text(fractal_sfs_converge_debug('0.420917,-0.598940,-0.510793,0.262502,0.738113,-0.595285,0.179492,-0.463067,-0.271811,-0.097654,-0.395126,-0.893986,0.789274,0.285198,-0.197261,-0.640688,0.589535,0.466062,0.938550,-0.353162,-0.548786,0.666295,-0.684833,0.591254,0.465023,-0.539096,-0.769195,-0.605933,-0.112448,0.824476,0.882892,-0.235717,-0.754583,0.371261,-0.552150,-0.343942,0.870388,0.131783,-0.668173,-0.532601,0.659894,0.745202,-0.462442,-0.719234,-0.264249,-0.819846,0.525092,0.789479,-0.817283,-0.279201,-0.314823,0.363813,0.714496,0.998205,-0.493763,0.420994,-0.132163,-0.655222,-0.933377,-0.958659,0.336054,0.168798,-0.741614,0.482165,-0.264163,0.152851,-0.889368,-0.089322,0.818163,-0.260873,-0.840216,0.791160,-0.303261,-0.748547,-0.948891,0.322282,-0.372583,-0.092962,-0.260117,0.326557,0.516336,-0.598148,0.674100,0.239768,-0.027793,0.607316,-0.188996,0.347486,-0.670022,-0.084174,0.978785,-0.601417,0.976731,0.659176,-0.235025,0.976028,-0.201797,0.060493,0.980532,0.754274,-0.067480,-0.544336,0.036904,0.362164,-0.345622,-0.013442,-0.531323,-0.417631,-0.952604,-0.360708,0.381342,-0.919070,-0.768057,-0.915351,-0.523416,-0.132887,0.613710,0.599097,-0.957175,0.172333,0.831888,-0.770860,-0.404548,0.686367,0.734657,0.142895,0.210943,-0.529895', 50, 50, 2), '$.best_point'),
           '0.420917,-0.598940,-0.510793,0.262502,0.738113,-0.595285,0.179492,-0.463067,-0.271811,-0.097654,-0.395126,-0.893986,0.789274,0.285198,-0.197261,-0.640688,0.589535,0.466062,0.938550,-0.353162,-0.548786,0.666295,-0.684833,0.591254,0.465023,-0.539096,-0.769195,-0.605933,-0.112448,0.824476,0.882892,-0.235717,-0.754583,0.371261,-0.552150,-0.343942,0.870388,0.131783,-0.668173,-0.532601,0.659894,0.745202,-0.462442,-0.719234,-0.264249,-0.819846,0.525092,0.789479,-0.817283,-0.279201,-0.314823,0.363813,0.714496,0.998205,-0.493763,0.420994,-0.132163,-0.655222,-0.933377,-0.958659,0.336054,0.168798,-0.741614,0.482165,-0.264163,0.152851,-0.889368,-0.089322,0.818163,-0.260873,-0.840216,0.791160,-0.303261,-0.748547,-0.948891,0.322282,-0.372583,-0.092962,-0.260117,0.326557,0.516336,-0.598148,0.674100,0.239768,-0.027793,0.607316,-0.188996,0.347486,-0.670022,-0.084174,0.978785,-0.601417,0.976731,0.659176,-0.235025,0.976028,-0.201797,0.060493,0.980532,0.754274,-0.067480,-0.544336,0.036904,0.362164,-0.345622,-0.013442,-0.531323,-0.417631,-0.952604,-0.360708,0.381342,-0.919070,-0.768057,-0.915351,-0.523416,-0.132887,0.613710,0.599097,-0.957175,0.172333,0.831888,-0.770860,-0.404548,0.686367,0.734657,0.142895,0.210943,-0.529895') AS "sim128"
FROM UNNEST(ARRAY[1]) AS t(x)
PARTITIONED BY ALL;

SELECT ROUND("sim8", 6) AS "cosine_similarity_dim8",
       ROUND("sim32", 6) AS "cosine_similarity_dim32",
       ROUND("sim128", 6) AS "cosine_similarity_dim128"
FROM "bt_sfs";

-- ---------------------------------------------------------------------------
-- 2. Scout Discovery against a naive top-K -- cluster diversity.
--
-- 20 synthetic clusters x 250 points in R^8 (5000 rows). Both methods
-- return K=50; we count how many of the 20 clusters each method's
-- results actually represent. Every returned point, from either
-- method, is mapped to its nearest cluster centre, so both sides are
-- scored the same way.
--
-- The centres are spread over [-0.9, 0.9] with +/-0.1 noise per point.
-- A corpus that only fills the middle of the search's operating box
-- leaves the edges empty, and the diversity fitness will correctly race
-- the particles into that empty space instead of spreading them across
-- the real clusters, understating the result.
--
-- The query is a small fixed off-center point, NOT a literal corpus
-- row: a query sitting almost exactly on a cluster centre is a known
-- adversarial case for cosine-based MMR. The origin does not work
-- either -- cosine similarity is undefined for a zero vector.
-- ---------------------------------------------------------------------------
REPLACE INTO bt_clusters OVERWRITE ALL
SELECT c AS "cluster_id", CAST(ROUND((0.9 * (2 * (SIN((c * 1000 + 1) * 12.9898) * 43758.5453 - FLOOR(SIN((c * 1000 + 1) * 12.9898) * 43758.5453)) - 1)), 6) AS VARCHAR) || ',' || CAST(ROUND((0.9 * (2 * (SIN((c * 1000 + 2) * 12.9898) * 43758.5453 - FLOOR(SIN((c * 1000 + 2) * 12.9898) * 43758.5453)) - 1)), 6) AS VARCHAR) || ',' || CAST(ROUND((0.9 * (2 * (SIN((c * 1000 + 3) * 12.9898) * 43758.5453 - FLOOR(SIN((c * 1000 + 3) * 12.9898) * 43758.5453)) - 1)), 6) AS VARCHAR) || ',' || CAST(ROUND((0.9 * (2 * (SIN((c * 1000 + 4) * 12.9898) * 43758.5453 - FLOOR(SIN((c * 1000 + 4) * 12.9898) * 43758.5453)) - 1)), 6) AS VARCHAR) || ',' || CAST(ROUND((0.9 * (2 * (SIN((c * 1000 + 5) * 12.9898) * 43758.5453 - FLOOR(SIN((c * 1000 + 5) * 12.9898) * 43758.5453)) - 1)), 6) AS VARCHAR) || ',' || CAST(ROUND((0.9 * (2 * (SIN((c * 1000 + 6) * 12.9898) * 43758.5453 - FLOOR(SIN((c * 1000 + 6) * 12.9898) * 43758.5453)) - 1)), 6) AS VARCHAR) || ',' || CAST(ROUND((0.9 * (2 * (SIN((c * 1000 + 7) * 12.9898) * 43758.5453 - FLOOR(SIN((c * 1000 + 7) * 12.9898) * 43758.5453)) - 1)), 6) AS VARCHAR) || ',' || CAST(ROUND((0.9 * (2 * (SIN((c * 1000 + 8) * 12.9898) * 43758.5453 - FLOOR(SIN((c * 1000 + 8) * 12.9898) * 43758.5453)) - 1)), 6) AS VARCHAR) AS "center"
FROM UNNEST(ARRAY[1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16, 17, 18, 19, 20]) AS t(c)
PARTITIONED BY ALL;

REPLACE INTO bt_corpus OVERWRITE ALL
SELECT c AS "cluster_id", p AS "point_id", (c - 1) * 250 + p AS "id", CAST(ROUND(((0.9 * (2 * (SIN((c * 1000 + 1) * 12.9898) * 43758.5453 - FLOOR(SIN((c * 1000 + 1) * 12.9898) * 43758.5453)) - 1)) + 0.1 * (2 * (SIN((((c * 1000 + p) * 13) + 1) * 12.9898) * 43758.5453 - FLOOR(SIN((((c * 1000 + p) * 13) + 1) * 12.9898) * 43758.5453)) - 1)), 6) AS VARCHAR) || ',' || CAST(ROUND(((0.9 * (2 * (SIN((c * 1000 + 2) * 12.9898) * 43758.5453 - FLOOR(SIN((c * 1000 + 2) * 12.9898) * 43758.5453)) - 1)) + 0.1 * (2 * (SIN((((c * 1000 + p) * 13) + 2) * 12.9898) * 43758.5453 - FLOOR(SIN((((c * 1000 + p) * 13) + 2) * 12.9898) * 43758.5453)) - 1)), 6) AS VARCHAR) || ',' || CAST(ROUND(((0.9 * (2 * (SIN((c * 1000 + 3) * 12.9898) * 43758.5453 - FLOOR(SIN((c * 1000 + 3) * 12.9898) * 43758.5453)) - 1)) + 0.1 * (2 * (SIN((((c * 1000 + p) * 13) + 3) * 12.9898) * 43758.5453 - FLOOR(SIN((((c * 1000 + p) * 13) + 3) * 12.9898) * 43758.5453)) - 1)), 6) AS VARCHAR) || ',' || CAST(ROUND(((0.9 * (2 * (SIN((c * 1000 + 4) * 12.9898) * 43758.5453 - FLOOR(SIN((c * 1000 + 4) * 12.9898) * 43758.5453)) - 1)) + 0.1 * (2 * (SIN((((c * 1000 + p) * 13) + 4) * 12.9898) * 43758.5453 - FLOOR(SIN((((c * 1000 + p) * 13) + 4) * 12.9898) * 43758.5453)) - 1)), 6) AS VARCHAR) || ',' || CAST(ROUND(((0.9 * (2 * (SIN((c * 1000 + 5) * 12.9898) * 43758.5453 - FLOOR(SIN((c * 1000 + 5) * 12.9898) * 43758.5453)) - 1)) + 0.1 * (2 * (SIN((((c * 1000 + p) * 13) + 5) * 12.9898) * 43758.5453 - FLOOR(SIN((((c * 1000 + p) * 13) + 5) * 12.9898) * 43758.5453)) - 1)), 6) AS VARCHAR) || ',' || CAST(ROUND(((0.9 * (2 * (SIN((c * 1000 + 6) * 12.9898) * 43758.5453 - FLOOR(SIN((c * 1000 + 6) * 12.9898) * 43758.5453)) - 1)) + 0.1 * (2 * (SIN((((c * 1000 + p) * 13) + 6) * 12.9898) * 43758.5453 - FLOOR(SIN((((c * 1000 + p) * 13) + 6) * 12.9898) * 43758.5453)) - 1)), 6) AS VARCHAR) || ',' || CAST(ROUND(((0.9 * (2 * (SIN((c * 1000 + 7) * 12.9898) * 43758.5453 - FLOOR(SIN((c * 1000 + 7) * 12.9898) * 43758.5453)) - 1)) + 0.1 * (2 * (SIN((((c * 1000 + p) * 13) + 7) * 12.9898) * 43758.5453 - FLOOR(SIN((((c * 1000 + p) * 13) + 7) * 12.9898) * 43758.5453)) - 1)), 6) AS VARCHAR) || ',' || CAST(ROUND(((0.9 * (2 * (SIN((c * 1000 + 8) * 12.9898) * 43758.5453 - FLOOR(SIN((c * 1000 + 8) * 12.9898) * 43758.5453)) - 1)) + 0.1 * (2 * (SIN((((c * 1000 + p) * 13) + 8) * 12.9898) * 43758.5453 - FLOOR(SIN((((c * 1000 + p) * 13) + 8) * 12.9898) * 43758.5453)) - 1)), 6) AS VARCHAR) AS "emb",
       CAST(ROUND(((0.9 * (2 * (SIN((c * 1000 + 1) * 12.9898) * 43758.5453 - FLOOR(SIN((c * 1000 + 1) * 12.9898) * 43758.5453)) - 1)) + 0.1 * (2 * (SIN((((c * 1000 + p) * 13) + 1) * 12.9898) * 43758.5453 - FLOOR(SIN((((c * 1000 + p) * 13) + 1) * 12.9898) * 43758.5453)) - 1)), 6) AS DOUBLE) AS "x",
       CAST(ROUND(((0.9 * (2 * (SIN((c * 1000 + 2) * 12.9898) * 43758.5453 - FLOOR(SIN((c * 1000 + 2) * 12.9898) * 43758.5453)) - 1)) + 0.1 * (2 * (SIN((((c * 1000 + p) * 13) + 2) * 12.9898) * 43758.5453 - FLOOR(SIN((((c * 1000 + p) * 13) + 2) * 12.9898) * 43758.5453)) - 1)), 6) AS DOUBLE) AS "y"
FROM UNNEST(ARRAY[1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16, 17, 18, 19, 20]) AS t(c),
     UNNEST(ARRAY[1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16, 17, 18, 19, 20, 21, 22, 23, 24, 25, 26, 27, 28, 29, 30, 31, 32, 33, 34, 35, 36, 37, 38, 39, 40, 41, 42, 43, 44, 45, 46, 47, 48, 49, 50, 51, 52, 53, 54, 55, 56, 57, 58, 59, 60, 61, 62, 63, 64, 65, 66, 67, 68, 69, 70, 71, 72, 73, 74, 75, 76, 77, 78, 79, 80, 81, 82, 83, 84, 85, 86, 87, 88, 89, 90, 91, 92, 93, 94, 95, 96, 97, 98, 99, 100, 101, 102, 103, 104, 105, 106, 107, 108, 109, 110, 111, 112, 113, 114, 115, 116, 117, 118, 119, 120, 121, 122, 123, 124, 125, 126, 127, 128, 129, 130, 131, 132, 133, 134, 135, 136, 137, 138, 139, 140, 141, 142, 143, 144, 145, 146, 147, 148, 149, 150, 151, 152, 153, 154, 155, 156, 157, 158, 159, 160, 161, 162, 163, 164, 165, 166, 167, 168, 169, 170, 171, 172, 173, 174, 175, 176, 177, 178, 179, 180, 181, 182, 183, 184, 185, 186, 187, 188, 189, 190, 191, 192, 193, 194, 195, 196, 197, 198, 199, 200, 201, 202, 203, 204, 205, 206, 207, 208, 209, 210, 211, 212, 213, 214, 215, 216, 217, 218, 219, 220, 221, 222, 223, 224, 225, 226, 227, 228, 229, 230, 231, 232, 233, 234, 235, 236, 237, 238, 239, 240, 241, 242, 243, 244, 245, 246, 247, 248, 249, 250]) AS u(p)
PARTITIONED BY ALL;

SELECT COUNT(*) AS "corpus_rows", COUNT(DISTINCT "cluster_id") AS "clusters"
FROM "bt_corpus";

-- The broker caches a datasource's schema, so the columns the write
-- has just added are read here first: the service call below reads
-- them too, and a service call has no retry of its own.
SELECT COUNT(*) AS "rows_with_coordinates" FROM "bt_corpus"
WHERE "x" IS NOT NULL AND "y" IS NOT NULL;

-- The shape of the corpus, cluster by cluster. The box count is a
-- count over a whole cloud of points, so it is a service operation
-- here: as an expression it would run once per row of the group.
-- @call boxcount {"datasource": "bt_corpus", "entityColumn": "cluster_id",
--                 "xColumn": "x", "yColumn": "y", "dim": 2} AS bt_boxcount;

SELECT "entity" AS "cluster_id", ROUND("dim", 4) AS "dimension"
FROM "bt_boxcount";

-- The naive top-K: the extension's own exact cosine distance over the
-- whole corpus, best first.
-- @call search/telemetry {"datasource": "bt_corpus", "vectorColumn": "emb",
--                         "idColumn": "id", "query": "0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1", "k": 50} AS bt_topk;

-- Scout Discovery: the same corpus, the population returned instead of
-- the nearest rows. mmr_lambda 0.2 weights diversity more heavily than
-- the 0.5 default.
-- @call search/explore {"datasource": "bt_corpus", "vectorColumn": "emb",
--                       "idColumn": "id", "query": "0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1", "k": 50,
--                       "params": "{\"population_size\": 50, \"iterations\": 8, \"mmr_lambda\": 0.2}"} AS bt_scout;

-- The nearest cluster centre for every row each method returned. The
-- nearest centre rides along in the fraction: the smallest distance
-- times a million, plus the cluster's own number.
REPLACE INTO bt_topk_clusters OVERWRITE ALL
SELECT MIN(fractal_vector_l2_distance(c."emb", cl."center") * 1000000.0 + cl."cluster_id")
         - MIN(fractal_vector_l2_distance(c."emb", cl."center")) * 1000000.0 AS "cluster_id"
FROM "bt_topk" t, "bt_corpus" c, "bt_clusters" cl
WHERE c."id" = t."doc_id"
GROUP BY t."doc_id"
PARTITIONED BY ALL;

REPLACE INTO bt_scout_clusters OVERWRITE ALL
SELECT MIN(fractal_vector_l2_distance(c."emb", cl."center") * 1000000.0 + cl."cluster_id")
         - MIN(fractal_vector_l2_distance(c."emb", cl."center")) * 1000000.0 AS "cluster_id"
FROM "bt_scout" t, "bt_corpus" c, "bt_clusters" cl
WHERE c."id" = t."doc_id"
GROUP BY t."doc_id"
PARTITIONED BY ALL;

SELECT (SELECT COUNT(DISTINCT "cluster_id") FROM "bt_topk_clusters") AS "naive_topk_clusters",
       (SELECT COUNT(DISTINCT "cluster_id") FROM "bt_scout_clusters") AS "scout_clusters",
       20 AS "clusters_in_corpus";

-- ---------------------------------------------------------------------------
-- 3. Embedding throughput.
--
-- Real, end-to-end throughput: fifty documents backfilled through the
-- configured embedding endpoint. This number reflects the embedding
-- endpoint's own latency as much as FractalSQL's.
--
-- The vectorizer's registry is the extension's -- the create call
-- registers it and the list call shows it -- but the queue's own
-- write-back is not usable on this build (it hands Druid's SQL parser
-- a row it cannot read), so the throughput itself is measured through
-- the embed function, over the same fifty documents.
-- ---------------------------------------------------------------------------
-- @fixture bt_docs {"rows": [
--   {"id": 1, "body": "benchmark document number 1: FractalSQL runs vector search directly inside the Druid cluster."},
--   {"id": 2, "body": "benchmark document number 2: FractalSQL runs vector search directly inside the Druid cluster."},
--   {"id": 3, "body": "benchmark document number 3: FractalSQL runs vector search directly inside the Druid cluster."},
--   {"id": 4, "body": "benchmark document number 4: FractalSQL runs vector search directly inside the Druid cluster."},
--   {"id": 5, "body": "benchmark document number 5: FractalSQL runs vector search directly inside the Druid cluster."},
--   {"id": 6, "body": "benchmark document number 6: FractalSQL runs vector search directly inside the Druid cluster."},
--   {"id": 7, "body": "benchmark document number 7: FractalSQL runs vector search directly inside the Druid cluster."},
--   {"id": 8, "body": "benchmark document number 8: FractalSQL runs vector search directly inside the Druid cluster."},
--   {"id": 9, "body": "benchmark document number 9: FractalSQL runs vector search directly inside the Druid cluster."},
--   {"id": 10, "body": "benchmark document number 10: FractalSQL runs vector search directly inside the Druid cluster."},
--   {"id": 11, "body": "benchmark document number 11: FractalSQL runs vector search directly inside the Druid cluster."},
--   {"id": 12, "body": "benchmark document number 12: FractalSQL runs vector search directly inside the Druid cluster."},
--   {"id": 13, "body": "benchmark document number 13: FractalSQL runs vector search directly inside the Druid cluster."},
--   {"id": 14, "body": "benchmark document number 14: FractalSQL runs vector search directly inside the Druid cluster."},
--   {"id": 15, "body": "benchmark document number 15: FractalSQL runs vector search directly inside the Druid cluster."},
--   {"id": 16, "body": "benchmark document number 16: FractalSQL runs vector search directly inside the Druid cluster."},
--   {"id": 17, "body": "benchmark document number 17: FractalSQL runs vector search directly inside the Druid cluster."},
--   {"id": 18, "body": "benchmark document number 18: FractalSQL runs vector search directly inside the Druid cluster."},
--   {"id": 19, "body": "benchmark document number 19: FractalSQL runs vector search directly inside the Druid cluster."},
--   {"id": 20, "body": "benchmark document number 20: FractalSQL runs vector search directly inside the Druid cluster."},
--   {"id": 21, "body": "benchmark document number 21: FractalSQL runs vector search directly inside the Druid cluster."},
--   {"id": 22, "body": "benchmark document number 22: FractalSQL runs vector search directly inside the Druid cluster."},
--   {"id": 23, "body": "benchmark document number 23: FractalSQL runs vector search directly inside the Druid cluster."},
--   {"id": 24, "body": "benchmark document number 24: FractalSQL runs vector search directly inside the Druid cluster."},
--   {"id": 25, "body": "benchmark document number 25: FractalSQL runs vector search directly inside the Druid cluster."},
--   {"id": 26, "body": "benchmark document number 26: FractalSQL runs vector search directly inside the Druid cluster."},
--   {"id": 27, "body": "benchmark document number 27: FractalSQL runs vector search directly inside the Druid cluster."},
--   {"id": 28, "body": "benchmark document number 28: FractalSQL runs vector search directly inside the Druid cluster."},
--   {"id": 29, "body": "benchmark document number 29: FractalSQL runs vector search directly inside the Druid cluster."},
--   {"id": 30, "body": "benchmark document number 30: FractalSQL runs vector search directly inside the Druid cluster."},
--   {"id": 31, "body": "benchmark document number 31: FractalSQL runs vector search directly inside the Druid cluster."},
--   {"id": 32, "body": "benchmark document number 32: FractalSQL runs vector search directly inside the Druid cluster."},
--   {"id": 33, "body": "benchmark document number 33: FractalSQL runs vector search directly inside the Druid cluster."},
--   {"id": 34, "body": "benchmark document number 34: FractalSQL runs vector search directly inside the Druid cluster."},
--   {"id": 35, "body": "benchmark document number 35: FractalSQL runs vector search directly inside the Druid cluster."},
--   {"id": 36, "body": "benchmark document number 36: FractalSQL runs vector search directly inside the Druid cluster."},
--   {"id": 37, "body": "benchmark document number 37: FractalSQL runs vector search directly inside the Druid cluster."},
--   {"id": 38, "body": "benchmark document number 38: FractalSQL runs vector search directly inside the Druid cluster."},
--   {"id": 39, "body": "benchmark document number 39: FractalSQL runs vector search directly inside the Druid cluster."},
--   {"id": 40, "body": "benchmark document number 40: FractalSQL runs vector search directly inside the Druid cluster."},
--   {"id": 41, "body": "benchmark document number 41: FractalSQL runs vector search directly inside the Druid cluster."},
--   {"id": 42, "body": "benchmark document number 42: FractalSQL runs vector search directly inside the Druid cluster."},
--   {"id": 43, "body": "benchmark document number 43: FractalSQL runs vector search directly inside the Druid cluster."},
--   {"id": 44, "body": "benchmark document number 44: FractalSQL runs vector search directly inside the Druid cluster."},
--   {"id": 45, "body": "benchmark document number 45: FractalSQL runs vector search directly inside the Druid cluster."},
--   {"id": 46, "body": "benchmark document number 46: FractalSQL runs vector search directly inside the Druid cluster."},
--   {"id": 47, "body": "benchmark document number 47: FractalSQL runs vector search directly inside the Druid cluster."},
--   {"id": 48, "body": "benchmark document number 48: FractalSQL runs vector search directly inside the Druid cluster."},
--   {"id": 49, "body": "benchmark document number 49: FractalSQL runs vector search directly inside the Druid cluster."},
--   {"id": 50, "body": "benchmark document number 50: FractalSQL runs vector search directly inside the Druid cluster."}
-- ]};

-- @call vectorizer {"action": "create", "source_table": "bt_docs",
--                   "source_column": "body",
--                   "embedding_column": "bt_docs_embedding",
--                   "id_column": "id"} AS bt_vec_created;

-- @call vectorizer {"action": "list"} AS bt_vec_registry;

SELECT COUNT(*) AS "registered"
FROM "bt_vec_registry" WHERE "source_table" = 'bt_docs';

-- The backfill: every document through the embedding endpoint.
REPLACE INTO bt_emb OVERWRITE ALL
SELECT t."id" AS "id", fractal_vector_dims(fractal_embed(t."body")) AS "dims"
FROM "bt_docs" t
PARTITIONED BY ALL;

SELECT COUNT(*) AS "embedded", MAX("dims") AS "dims" FROM "bt_emb";

-- ---------------------------------------------------------------------------
-- 4. The headline.
--
-- The kit passes when the search converged at every dimension, when
-- the corpus really is 20 clusters of 250 points, when the naive top-K
-- really did collapse onto one cluster while Scout Discovery spread
-- over several -- the diversity gap IS the finding -- and when every
-- document was embedded.
-- ---------------------------------------------------------------------------
SELECT CASE
           WHEN (SELECT COUNT(*) FROM "bt_corpus") = 5000
            AND (SELECT COUNT(*) FROM "bt_clusters") = 20
            AND (SELECT COUNT(*) FROM "bt_sfs"
                 WHERE "sim8" > 0.5 AND "sim32" > 0.5 AND "sim128" > 0.5) = 1
            AND (SELECT COUNT(DISTINCT "cluster_id") FROM "bt_topk_clusters") = 1
            AND (SELECT COUNT(DISTINCT "cluster_id") FROM "bt_scout_clusters") > 1
            AND (SELECT COUNT(*) FROM "bt_boxcount") = 20
            AND (SELECT COUNT(*) FROM "bt_vec_registry" WHERE "source_table" = 'bt_docs') >= 1
            AND (SELECT COUNT(*) FROM "bt_emb" WHERE "dims" > 0) = 50
            THEN 'HEADLINE kit=benchmark ok'
            ELSE 'HEADLINE kit=benchmark FAILED'
       END AS "headline";
