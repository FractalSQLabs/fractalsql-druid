-- demo/demo-vertical-outlier-interception-footprint.sql
--
-- FractalSQL for Apache Druid -- industry vertical: Outlier interception
-- with a spatial footprint. DOMAIN kit: four known abuse signatures and
-- four proposed traffic sessions, screened with
-- `fractal_agent_outlier_intercept` under two metrics (cosine and exact
-- Euclidean); then a click-map topology -- organic traffic against an
-- automated farm -- measured with `fractal_dimension_boxcount`, which
-- shows the farm's requests lie on a line (a low dimension) while the
-- organic traffic fills the plane.
--
--   1. The known signatures and the proposed sessions.
--   2. fractal_agent_outlier_intercept: cosine, threshold 0.10.
--   3. The same screen under exact Euclidean distance, threshold 0.30.
--   4. fractal_dimension_boxcount: the click map's topology.
--   5. A closing fractal_reason() writes the hold/release justification.
--
-- Prerequisites: the extension is loaded on the Druid cluster. The closing
-- fractal_reason() narrative needs a reasoning provider
-- (docs/reasoning-setup.md); every other step runs with no model.
--
-- Run:
--   python3 demo/run_demo.py --file demo/demo-vertical-outlier-interception-footprint.sql
--
-- ===========================================================================
-- Notes on how this runs on Druid
-- ===========================================================================
--
--   * The fixtures are @fixture directives -- a set of rows has no SQL
--     form on Druid, so the runner turns each into an MSQ write.
--   * The screen is a service call: an agent reads a table and reasons
--     about it, and a Druid SQL function can do neither. The call's
--     "AS <datasource>" clause materialises its rows, so the kit's own
--     headline can query them.
--   * The click map's points are folded into one vector per source with
--     ARRAY_AGG, because Druid has no group_concat.
--
-- Safe to re-run: each fixture is a REPLACE INTO ... OVERWRITE ALL, so
-- the datasources hold exactly this run's rows.

-- ---------------------------------------------------------------------------
-- 0. Sanity check: extension loaded?
-- ---------------------------------------------------------------------------
SELECT fractal_edition(), fractal_version();

-- ---------------------------------------------------------------------------
-- 1. Known abuse signatures + proposed traffic sessions.
--
-- The vector is [request burst, headless share, session reuse, proxy
-- share, geo spread].
-- ---------------------------------------------------------------------------
-- @fixture oif_known {"rows": [
--   {"id": 1, "label": "automated farm: one device pool, burst requests", "vec": "0.95,0.9,0.85,0.1,0.2"},
--   {"id": 2, "label": "datacenter bot traffic, headless browsers", "vec": "0.9,0.05,0.3,0.95,0.4"},
--   {"id": 3, "label": "residential-proxy request spoofing", "vec": "0.05,0.05,0.1,0.1,0.95"},
--   {"id": 4, "label": "request-stacking ring", "vec": "0.1,0.8,0.9,0.85,0.3"}
-- ]};

-- @fixture oif_proposed {"rows": [
--   {"id": 1, "label": "T1 burst requests from a shared device pool", "vec": "0.92,0.88,0.8,0.12,0.18"},
--   {"id": 2, "label": "T2 organic referral session", "vec": "0.02,0,0.05,0,0.05"},
--   {"id": 3, "label": "T3 returning user on a new device", "vec": "0,0.02,0.7,0.04,0.05"},
--   {"id": 4, "label": "T4 faint headless traffic, far geo", "vec": "0.4,0.02,0.12,0.42,0.16"}
-- ]};

-- ---------------------------------------------------------------------------
-- 2. fractal_agent_outlier_intercept (cosine, threshold 0.10).
--
-- The call's "AS oif_screen" writes its rows into a datasource, so the
-- kit's headline can query them.
-- ---------------------------------------------------------------------------
-- @call agent/outlier_screen {"proposed_table": "oif_proposed", "state_column": "vec",
--                            "id_column": "id", "label_column": "label",
--                            "history_table": "oif_known", "emb_column": "vec",
--                            "threshold": 0.1, "metric": "cosine"} AS oif_screen;

SELECT "id", "label", "intercepted", "metric" FROM "oif_screen" GROUP BY "id", "label", "intercepted", "metric" ORDER BY "id";

-- ---------------------------------------------------------------------------
-- 3. Same screen under exact Euclidean distance (threshold 0.30).
-- ---------------------------------------------------------------------------
-- @call agent/outlier_screen {"proposed_table": "oif_proposed", "state_column": "vec",
--                            "id_column": "id", "label_column": "label",
--                            "history_table": "oif_known", "emb_column": "vec",
--                            "threshold": 0.3, "metric": "l2"} AS oif_screen_l2;

SELECT "id", "label", "intercepted", "metric" FROM "oif_screen_l2" GROUP BY "id", "label", "intercepted", "metric" ORDER BY "id";

-- ---------------------------------------------------------------------------
-- 4. Click-map topology: organic traffic vs an automated farm.
--
-- 200 points each. The farm's requests lie along a narrow strip; the
-- organic traffic spreads over the plane. The coordinates are the
-- deterministic sin-hash of the point's index -- a lattice of points
-- would be a degenerate input for a box counter.
-- ---------------------------------------------------------------------------
REPLACE INTO oif_clicks OVERWRITE ALL
SELECT "ent", "pt", "x", "y"
FROM (
    SELECT CASE WHEN g <= 200 THEN 'organic-source' ELSE 'farm-ring' END AS "ent",
           CASE WHEN g <= 200 THEN g ELSE g - 200 END AS "pt",
           SIN(g * 12.9898) * 43758.5453
               - FLOOR(SIN(g * 12.9898) * 43758.5453) AS "x",
           CASE WHEN g <= 200
                THEN SIN((g + 77) * 12.9898) * 43758.5453
                     - FLOOR(SIN((g + 77) * 12.9898) * 43758.5453)
                ELSE (SIN((g + 77) * 12.9898) * 43758.5453
                      - FLOOR(SIN((g + 77) * 12.9898) * 43758.5453)) * 0.03
                     + 0.002 * MOD(g, 5)
           END AS "y"
    FROM UNNEST(ARRAY[
        1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16, 17, 18, 19, 20,
        21, 22, 23, 24, 25, 26, 27, 28, 29, 30, 31, 32, 33, 34, 35, 36, 37, 38, 39, 40,
        41, 42, 43, 44, 45, 46, 47, 48, 49, 50, 51, 52, 53, 54, 55, 56, 57, 58, 59, 60,
        61, 62, 63, 64, 65, 66, 67, 68, 69, 70, 71, 72, 73, 74, 75, 76, 77, 78, 79, 80,
        81, 82, 83, 84, 85, 86, 87, 88, 89, 90, 91, 92, 93, 94, 95, 96, 97, 98, 99, 100,
        101, 102, 103, 104, 105, 106, 107, 108, 109, 110, 111, 112, 113, 114, 115, 116,
        117, 118, 119, 120, 121, 122, 123, 124, 125, 126, 127, 128, 129, 130, 131, 132,
        133, 134, 135, 136, 137, 138, 139, 140, 141, 142, 143, 144, 145, 146, 147, 148,
        149, 150, 151, 152, 153, 154, 155, 156, 157, 158, 159, 160, 161, 162, 163, 164,
        165, 166, 167, 168, 169, 170, 171, 172, 173, 174, 175, 176, 177, 178, 179, 180,
        181, 182, 183, 184, 185, 186, 187, 188, 189, 190, 191, 192, 193, 194, 195, 196,
        197, 198, 199, 200, 201, 202, 203, 204, 205, 206, 207, 208, 209, 210, 211, 212,
        213, 214, 215, 216, 217, 218, 219, 220, 221, 222, 223, 224, 225, 226, 227, 228,
        229, 230, 231, 232, 233, 234, 235, 236, 237, 238, 239, 240, 241, 242, 243, 244,
        245, 246, 247, 248, 249, 250, 251, 252, 253, 254, 255, 256, 257, 258, 259, 260,
        261, 262, 263, 264, 265, 266, 267, 268, 269, 270, 271, 272, 273, 274, 275, 276,
        277, 278, 279, 280, 281, 282, 283, 284, 285, 286, 287, 288, 289, 290, 291, 292,
        293, 294, 295, 296, 297, 298, 299, 300, 301, 302, 303, 304, 305, 306, 307, 308,
        309, 310, 311, 312, 313, 314, 315, 316, 317, 318, 319, 320, 321, 322, 323, 324,
        325, 326, 327, 328, 329, 330, 331, 332, 333, 334, 335, 336, 337, 338, 339, 340,
        341, 342, 343, 344, 345, 346, 347, 348, 349, 350, 351, 352, 353, 354, 355, 356,
        357, 358, 359, 360, 361, 362, 363, 364, 365, 366, 367, 368, 369, 370, 371, 372,
        373, 374, 375, 376, 377, 378, 379, 380, 381, 382, 383, 384, 385, 386, 387, 388,
        389, 390, 391, 392, 393, 394, 395, 396, 397, 398, 399, 400]) AS t(g)
) s
PARTITIONED BY ALL;

-- The box counter is a service operation: as a SQL expression it would
-- run once per row of the group, which for four hundred points is
-- minutes of core time in the data node.
-- @call boxcount {"datasource": "oif_clicks", "entityColumn": "ent",
--                 "xColumn": "x", "yColumn": "y", "dim": 2} AS oif_dim;

SELECT "entity", "dim" FROM "oif_dim" WHERE "entity" IS NOT NULL;

-- ---------------------------------------------------------------------------
-- 5. Reasoning: hold / release justification.
-- ---------------------------------------------------------------------------
-- The context is the screen's own rows: a reasoning call cannot take a
-- subquery as an argument on Druid (the planner rewrites the
-- concatenation into a one-argument CAST), so the service tier builds
-- the context from what the previous step returned.
-- @call reason {"query": "one-line justification for holding the flagged traffic and the topology evidence for an automated farm",
--               "context": "$previous"};

-- ---------------------------------------------------------------------------
-- 6. The kit's own headline check.
--
-- The demo contract: a kit prints its headline and exits
-- non-zero unless the result holds. The burst session and the faint
-- headless traffic are intercepted; the organic session is not; and the
-- farm's click map is the more linear of the two.
-- ---------------------------------------------------------------------------
SELECT CASE
           WHEN (SELECT "intercepted" FROM "oif_screen" WHERE "id" = 1 GROUP BY "intercepted") = true
            AND (SELECT "intercepted" FROM "oif_screen" WHERE "id" = 2 GROUP BY "intercepted") = false
            AND (SELECT "intercepted" FROM "oif_screen" WHERE "id" = 4 GROUP BY "intercepted") = true
            AND (SELECT "dim" FROM "oif_dim" WHERE "entity" = 'farm-ring')
                + 0.3 < (SELECT "dim" FROM "oif_dim" WHERE "entity" = 'organic-source')
            THEN 'HEADLINE kit=outlier-interception-footprint ok'
            ELSE 'HEADLINE kit=outlier-interception-footprint FAILED'
       END AS "headline";
