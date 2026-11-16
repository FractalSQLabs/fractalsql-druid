-- demo/demo-vertical-biotech-genomics.sql
--
-- FractalSQL for Apache Druid -- industry vertical: Biotech & Genomics
-- (structural biology / single-cell transcriptomics).
--
-- A synthetic point cloud standing in for two shapes this vertical
-- actually analyzes: (a) a protein backbone's 3D atomic coordinates
-- traced through a folding trajectory, and (b) a low-dimensional
-- embedding of scRNA-seq cells (e.g. a UMAP/PCA projection) clustering
-- into two cell-type populations. Both are "does this point cloud have
-- interesting topological structure -- clusters, loops" questions, which
-- is exactly what a persistence diagram answers. Lp distance is shown
-- separately as the generic point-to-point metric this domain uses at
-- different p (L1/Manhattan for robust feature comparison, L2/Euclidean
-- for raw coordinate distance) rather than being hardcoded to one norm.
--
-- Prerequisites: the extension is loaded. This demo needs no reasoning
-- provider and no embedding endpoint.
--
-- Run:
--   python3 demo/run_demo.py --file demo/demo-vertical-biotech-genomics.sql
--
-- ===========================================================================
-- Notes on how this runs on Druid
-- ===========================================================================
--
--   * The fixture is an MSQ write, not CREATE TABLE + INSERT, and the
--     coordinates are computed in the query rather than by random():
--     Druid has no recursive CTE and no seedable RNG, so the noise is
--     the deterministic sin-hash of the sample index (the same
--     construction the RF kit uses). The topological structure -- the
--     clusters and the bridging ring -- is what the demo's claims rest
--     on, and that is built into the construction, not into particular
--     noise values.
--   * The flat point list is ARRAY_TO_STRING(ARRAY_AGG(...)), because
--     Druid has no group_concat. ARRAY_AGG preserves order.
--   * fractal_json_value instead of json_extract: Druid's JSON_VALUE
--     reads a COMPLEX column, not a JSON string.
--   * The persistence diagram's document has "n_bars", and its second
--     argument is the dimension -- it computes the 0-dimensional diagram exactly
--     and the graph's cycle rank, with the threshold and the maximum
--     dimension fixed at the primitive's defaults.
--
-- *** SCOPE NOTE (carried forward from fractal_tda_persistence_diagram's
-- own doc comment -- read this before treating betti1 as a full TDA
-- result): the 0-dimensional persistence diagram (the H0 bars, their
-- birth/death) is an EXACT, complete computation -- single-linkage
-- clustering is mathematically equivalent to 0-dim persistent homology of
-- the Vietoris-Rips filtration. betti1 (requested via max_dim=1) is the
-- bare 1-skeleton GRAPH's cycle rank, NOT full simplicial H1 of the
-- Vietoris-Rips complex -- it over-counts true H1 whenever a filled
-- triangle exists in the point cloud. A real TDA library (Ripser/GUDHI)
-- computes full H1 via boundary-matrix reduction; this primitive
-- deliberately doesn't attempt that. Treat betti1 here as "how many
-- independent cycles exist in the neighbor graph at this threshold", a
-- useful but strictly weaker signal than true H1 -- not as a drop-in
-- replacement for a real TDA library's loop count. ***
--
-- Safe to re-run: each fixture is a REPLACE INTO ... OVERWRITE ALL, so
-- the datasources hold exactly this run's rows.

-- ---------------------------------------------------------------------------
-- 0. Sanity check: extension loaded?
-- ---------------------------------------------------------------------------
SELECT fractal_edition(), fractal_version();

-- ---------------------------------------------------------------------------
-- 1. scRNA-seq-style point cloud: 22 cells in a 3D embedding -- two
-- well-separated clusters (8 "T-cell-like" + 8 "B-cell-like") plus 6
-- points bridging them in a rough ring, deliberately built so both
-- H0 (two clusters merging at some threshold) and the graph-cycle-rank
-- betti1 (the bridging ring) have real, non-degenerate structure to find.
--
-- Cluster A is kept small (8 points) deliberately: any cluster whose own
-- internal spread falls entirely inside the chosen threshold becomes a
-- near-complete subgraph, and a complete graph's cycle rank grows
-- combinatorially with point count (C(n,2)-(n-1)), which would swamp
-- the ring's real signal if the clusters were large.
-- ---------------------------------------------------------------------------
REPLACE INTO vbg_cells OVERWRITE ALL
SELECT CONCAT('[', CAST("x" AS VARCHAR), ',', CAST("y" AS VARCHAR), ',', CAST("z" AS VARCHAR), ']') AS "coord",
       CASE WHEN g <= 8 THEN 'T-cell-like' WHEN g <= 16 THEN 'B-cell-like' ELSE 'transitional' END AS "cell_type"
FROM (
    -- The three coordinates are computed in their own level, and the
    -- coordinate string is built from the columns.
    SELECT CASE WHEN g <= 8 THEN 0.6 * (SIN(g * 12.9898) * 43758.5453 - FLOOR(SIN(g * 12.9898) * 43758.5453)) WHEN g <= 16 THEN 6.0 + 0.6 * (SIN((g - 8) * 12.9898) * 43758.5453 - FLOOR(SIN((g - 8) * 12.9898) * 43758.5453)) ELSE 3.0 + 3.2 * COS((g - 17) * 2 * 3.14159265 / 6.0) END AS "x",
           CASE WHEN g <= 8 THEN 0.6 * (SIN((g + 100) * 12.9898) * 43758.5453 - FLOOR(SIN((g + 100) * 12.9898) * 43758.5453)) WHEN g <= 16 THEN 6.0 + 0.6 * (SIN((g + 92) * 12.9898) * 43758.5453 - FLOOR(SIN((g + 92) * 12.9898) * 43758.5453)) ELSE 3.0 + 3.2 * SIN((g - 17) * 2 * 3.14159265 / 6.0) END AS "y",
           CASE WHEN g <= 8 THEN 0.6 * (SIN((g + 200) * 12.9898) * 43758.5453 - FLOOR(SIN((g + 200) * 12.9898) * 43758.5453)) WHEN g <= 16 THEN 0.6 * (SIN((g + 192) * 12.9898) * 43758.5453 - FLOOR(SIN((g + 192) * 12.9898) * 43758.5453)) ELSE 0.0 END AS "z",
           g
    FROM UNNEST(ARRAY[
        1, 2, 3, 4, 5, 6, 7, 8,
        9, 10, 11, 12, 13, 14, 15, 16,
        17, 18, 19, 20, 21, 22]) AS t(g)
) s
PARTITIONED BY ALL;

SELECT COUNT(*) AS "n_cells" FROM "vbg_cells";

-- ---------------------------------------------------------------------------
-- 2. fractal_tda_persistence_diagram: topology of the embedding.
--
-- The shape is fractal_tda_persistence_diagram(points, dim, max_dim, max_thresh): the
-- points as one flat list -- x,y,z per point -- and the dimension.
-- The result is a document carrying the 0-dimensional bars (their birth
-- and death) and the graph's cycle rank.
--
-- betti1 reads noticeably higher than "1 loop": each cluster's internal
-- spread is well inside the threshold, so every cluster becomes a
-- near-complete subgraph on its own points, and a complete graph's
-- cycle rank grows combinatorially. That is the scope note's
-- over-counting behaviour in practice, not a bug: betti1 is the raw
-- 1-skeleton graph's cycle rank, and a densely-sampled cluster IS full
-- of graph cycles at any threshold wide enough to connect it, even
-- though it is not a topological "loop" in any meaningful sense.
-- Citation: Edelsbrunner, H., Letscher, D., & Zomorodian, A. (2002).
-- "Topological persistence and simplification." Discrete &
-- Computational Geometry, 28(4), 511-533.
-- ---------------------------------------------------------------------------
REPLACE INTO vbg_topology OVERWRITE ALL
SELECT fractal_tda_persistence_diagram(
           ARRAY_TO_STRING(ARRAY_AGG("flat", 16384), ','), 3, 1, 2.5) AS "diagram"
FROM (SELECT REPLACE(REPLACE("coord", '[', ''), ']', '') AS "flat"
      FROM "vbg_cells") t
PARTITIONED BY ALL;

SELECT fractal_json_value("diagram", '$.n_bars') AS "n_h0_bars",
       fractal_json_value("diagram", '$.betti1') AS "betti1_graph_cycle_rank"
FROM "vbg_topology";

-- ---------------------------------------------------------------------------
-- 3. fractal_vector_lp_distance: pairwise distance between the two
-- cluster centroids at p=1 (Manhattan -- robust to per-feature outliers,
-- a common choice for noisy expression-derived features) and p=2
-- (Euclidean -- raw embedding distance). p must be > 0; the triangle
-- inequality only holds for p >= 1, a property of Lp spaces themselves
-- (not an approximation in this implementation) -- both values used here
-- are >= 1.
-- Lp distance is a standard, widely-used metric family, not attributed
-- to a single originating paper.
-- ---------------------------------------------------------------------------
REPLACE INTO vbg_centroids OVERWRITE ALL
SELECT "cell_type",
       CONCAT('[',
              CAST(AVG(fractal_json_value("coord", '$[0]')) AS VARCHAR), ',',
              CAST(AVG(fractal_json_value("coord", '$[1]')) AS VARCHAR), ',',
              CAST(AVG(fractal_json_value("coord", '$[2]')) AS VARCHAR),
              ']') AS "centroid"
FROM "vbg_cells"
WHERE "cell_type" IN ('T-cell-like', 'B-cell-like')
GROUP BY "cell_type"
PARTITIONED BY ALL;

SELECT "cell_type", "centroid" FROM "vbg_centroids";

SELECT fractal_vector_lp_distance(a."centroid", b."centroid", 1.0)
           AS "centroid_distance_l1_manhattan",
       fractal_vector_lp_distance(a."centroid", b."centroid", 2.0)
           AS "centroid_distance_l2_euclidean"
FROM "vbg_centroids" a, "vbg_centroids" b
WHERE a."cell_type" = 'T-cell-like' AND b."cell_type" = 'B-cell-like';

-- ---------------------------------------------------------------------------
-- 4. The kit's own headline check.
--
-- The demo contract: a kit prints its headline and exits
-- non-zero unless the result holds. Three claims: the point cloud has
-- real topology (the graph has cycles -- betti1 >= 1), the two
-- centroids are further apart in Manhattan distance than in Euclidean
-- distance, which is what Lp spaces guarantee for p >= 1, and they are
-- far apart in both (the clusters are six units apart, so the Euclidean
-- distance is well over 1).
-- ---------------------------------------------------------------------------
SELECT CASE
           WHEN (SELECT fractal_json_value("diagram", '$.betti1') FROM "vbg_topology") >= 1
            AND fractal_vector_lp_distance(a."centroid", b."centroid", 1.0)
                > fractal_vector_lp_distance(a."centroid", b."centroid", 2.0)
            AND fractal_vector_lp_distance(a."centroid", b."centroid", 2.0) > 1.0
            THEN 'HEADLINE kit=biotech-genomics ok'
            ELSE 'HEADLINE kit=biotech-genomics FAILED'
       END AS "headline"
FROM "vbg_centroids" a, "vbg_centroids" b
WHERE a."cell_type" = 'T-cell-like' AND b."cell_type" = 'B-cell-like';
