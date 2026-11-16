-- demo/demo-vertical-coordinated-record-detection.sql
--
-- FractalSQL for Apache Druid -- industry vertical: coordinated-record
-- detection: ring signatures and severity-trajectory analysis. A review
-- desk screens new submissions against known ring signatures, finds the
-- records that moved from the normal severity baseline the way a staged
-- ring does, and measures the geographic footprint of event locations.
--
--   1. fractal_agent_outlier_intercept: hold new records that match a
--      known ring signature.
--   2. fractal_search_trajectory: which open records moved the way the
--      ring's records did.
--   3. fractal_dimension_boxcount: the footprint of event locations,
--      organic vs ring.
--   4. A closing fractal_reason() writes the referral line.
--
-- Prerequisites: the extension is loaded on the Druid cluster. The closing
-- fractal_reason() narrative and any agent rationale need a reasoning
-- provider (docs/reasoning-setup.md); every other step runs with no model.
--
-- Run:
--   python3 demo/run_demo.py --file demo/demo-vertical-coordinated-record-detection.sql
--
-- ===========================================================================
-- Notes on how this runs on Druid
-- ===========================================================================
--
--   * The fixtures are @fixture directives: Druid has no DDL and no
--     VALUES, so a set of rows has no SQL form.
--   * The screen, the trajectory search and the box counter are service
--     calls: an agent reads a table and reasons about it, and a corpus-
--     wide count is once per cloud, not once per row. Each lands in a
--     datasource the kit can query.
--   * The event locations are computed in the query (random-free integer arithmetic, no recursive CTE).
--
-- Notes:
--   * Fully deterministic fixtures (no random()).
--   * Ring signature = [record velocity, shared provider, shared
--     representative, soft-tissue ratio, address clustering].
--   * Ends with a HEADLINE line computed from the kit's own results
--     (HEADLINE kit=<name> ok); the build_test kit gate greps for it.

-- ---------------------------------------------------------------------------
-- 0. Sanity check: extension loaded?
-- ---------------------------------------------------------------------------
SELECT fractal_edition(), fractal_version();

-- ---------------------------------------------------------------------------
-- 1. Known ring signatures + proposed new records.
-- ---------------------------------------------------------------------------
-- @fixture crd_known {"rows": [
--   {"id": 1, "label": "staged-event ring: same provider and representative", "vec": "0.95,0.9,0.85,0.1,0.2"},
--   {"id": 2, "label": "synthetic-severity ring: repeated minor-severity pile-up", "vec": "0.9,0.05,0.3,0.95,0.4"},
--   {"id": 3, "label": "phantom-participant records, one address cluster", "vec": "0.05,0.05,0.1,0.1,0.95"},
--   {"id": 4, "label": "provider-collusion ring: repeat billing", "vec": "0.1,0.8,0.9,0.85,0.3"}
-- ]};

-- @fixture crd_proposed {"rows": [
--   {"id": 1, "label": "P1 staged-pattern record, usual provider and representative", "vec": "0.92,0.88,0.8,0.12,0.18"},
--   {"id": 2, "label": "P2 isolated single-party record", "vec": "0.02,0,0.05,0,0.05"},
--   {"id": 3, "label": "P3 new provider, same city", "vec": "0,0.02,0.7,0.04,0.05"},
--   {"id": 4, "label": "P4 faint minor-severity pattern, far away", "vec": "0.4,0.02,0.12,0.42,0.16"}
-- ]};

-- ---------------------------------------------------------------------------
-- 2. fractal_agent_outlier_intercept (cosine, threshold 0.10).
-- ---------------------------------------------------------------------------
-- @call agent/outlier_screen {"proposed_table": "crd_proposed", "state_column": "vec",
--                            "id_column": "id", "label_column": "label",
--                            "history_table": "crd_known", "emb_column": "vec",
--                            "threshold": 0.1, "metric": "cosine"} AS crd_screen;

SELECT "id", "label", "intercepted", "metric" FROM "crd_screen"
WHERE "id" IS NOT NULL;

-- ---------------------------------------------------------------------------
-- 3. Open-record severity trajectory: who moved like the ring.
-- ---------------------------------------------------------------------------
-- @fixture crd_records {"rows": [
--   {"id": 1, "label": "REC-001", "vec": "0.05,-0.06,0.03,-0.04"},
--   {"id": 2, "label": "REC-002", "vec": "0.1,-0.02,0.06,0.02"},
--   {"id": 3, "label": "REC-003", "vec": "0.15,0.02,0.09,0.08"},
--   {"id": 4, "label": "REC-004", "vec": "0.2,0.06,0,0.14"},
--   {"id": 5, "label": "REC-005 (ring)", "vec": "1.4,0.9,1.1,1.2"},
--   {"id": 6, "label": "REC-006", "vec": "0.05,0.14,0.06,-0.1"},
--   {"id": 7, "label": "REC-007", "vec": "0.1,-0.1,0.09,-0.04"},
--   {"id": 8, "label": "REC-008", "vec": "0.15,-0.06,0,0.02"},
--   {"id": 9, "label": "REC-009", "vec": "0.2,-0.02,0.03,0.08"},
--   {"id": 10, "label": "REC-010", "vec": "0,0.02,0.06,0.14"},
--   {"id": 11, "label": "REC-011", "vec": "0.05,0.06,0.09,0.2"},
--   {"id": 12, "label": "REC-012", "vec": "0.1,0.1,0,-0.1"},
--   {"id": 13, "label": "REC-013 (ring)", "vec": "1.4,0.9,1.1,1.2"},
--   {"id": 14, "label": "REC-014", "vec": "0.2,-0.1,0.06,0.02"},
--   {"id": 15, "label": "REC-015", "vec": "0,-0.06,0.09,0.08"},
--   {"id": 16, "label": "REC-016", "vec": "0.05,-0.02,0,0.14"},
--   {"id": 17, "label": "REC-017", "vec": "0.1,0.02,0.03,0.2"},
--   {"id": 18, "label": "REC-018", "vec": "0.15,0.06,0.06,-0.1"},
--   {"id": 19, "label": "REC-019", "vec": "0.2,0.1,0.09,-0.04"},
--   {"id": 20, "label": "REC-020", "vec": "0,0.14,0,0.02"},
--   {"id": 21, "label": "REC-021", "vec": "0.05,-0.1,0.03,0.08"},
--   {"id": 22, "label": "REC-022 (ring)", "vec": "1.4,0.9,1.1,1.2"},
--   {"id": 23, "label": "REC-023", "vec": "0.15,-0.02,0.09,0.2"},
--   {"id": 24, "label": "REC-024", "vec": "0.2,0.02,0,-0.1"},
--   {"id": 25, "label": "REC-025", "vec": "0,0.06,0.03,-0.04"},
--   {"id": 26, "label": "REC-026", "vec": "0.05,0.1,0.06,0.02"},
--   {"id": 27, "label": "REC-027", "vec": "0.1,0.14,0.09,0.08"},
--   {"id": 28, "label": "REC-028", "vec": "0.15,-0.1,0,0.14"},
--   {"id": 29, "label": "REC-029", "vec": "0.2,-0.06,0.03,0.2"},
--   {"id": 30, "label": "REC-030", "vec": "0,-0.02,0.06,-0.1"}
-- ]};

-- @call search/trajectory {"table": "crd_records", "column": "vec", "id_column": "id",
--                         "baseline": "0.05,0,0.03,0", "current": "1.4,0.9,1.1,1.2",
--                         "k": 5} AS crd_traj;

SELECT r."doc_id" AS "id", w."label" AS "label", ROUND(r."distance", 4) AS "distance"
FROM "crd_traj" r, "crd_records" w
WHERE r."doc_id" = w."id";

-- ---------------------------------------------------------------------------
-- 4. Event-location topology: organic vs staged ring.
--
-- The staged ring repeats along one road; the organic records scatter
-- across the city.
-- ---------------------------------------------------------------------------
REPLACE INTO crd_locations OVERWRITE ALL
SELECT "ent", "pt", "x", "y"
FROM (
    SELECT CASE WHEN g <= 200 THEN 'organic-records' ELSE 'staged-ring' END AS "ent",
           CASE WHEN g <= 200 THEN g ELSE g - 200 END AS "pt",
           SIN(g * 12.9898) * 43758.5453
               - FLOOR(SIN(g * 12.9898) * 43758.5453) AS "x",
           CASE WHEN g <= 200
                THEN SIN((g + 61) * 12.9898) * 43758.5453
                     - FLOOR(SIN((g + 61) * 12.9898) * 43758.5453)
                ELSE (SIN((g + 61) * 12.9898) * 43758.5453
                      - FLOOR(SIN((g + 61) * 12.9898) * 43758.5453)) * 0.03
                     + 0.002 * MOD(g, 5)
           END AS "y"
    FROM UNNEST(ARRAY[
        1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16,
        17, 18, 19, 20, 21, 22, 23, 24, 25, 26, 27, 28, 29, 30, 31, 32,
        33, 34, 35, 36, 37, 38, 39, 40, 41, 42, 43, 44, 45, 46, 47, 48,
        49, 50, 51, 52, 53, 54, 55, 56, 57, 58, 59, 60, 61, 62, 63, 64,
        65, 66, 67, 68, 69, 70, 71, 72, 73, 74, 75, 76, 77, 78, 79, 80,
        81, 82, 83, 84, 85, 86, 87, 88, 89, 90, 91, 92, 93, 94, 95, 96,
        97, 98, 99, 100, 101, 102, 103, 104, 105, 106, 107, 108, 109, 110,
        111, 112, 113, 114, 115, 116, 117, 118, 119, 120, 121, 122, 123, 124,
        125, 126, 127, 128, 129, 130, 131, 132, 133, 134, 135, 136, 137, 138,
        139, 140, 141, 142, 143, 144, 145, 146, 147, 148, 149, 150, 151, 152,
        153, 154, 155, 156, 157, 158, 159, 160, 161, 162, 163, 164, 165, 166,
        167, 168, 169, 170, 171, 172, 173, 174, 175, 176, 177, 178, 179, 180,
        181, 182, 183, 184, 185, 186, 187, 188, 189, 190, 191, 192, 193, 194,
        195, 196, 197, 198, 199, 200, 201, 202, 203, 204, 205, 206, 207, 208,
        209, 210, 211, 212, 213, 214, 215, 216, 217, 218, 219, 220, 221, 222,
        223, 224, 225, 226, 227, 228, 229, 230, 231, 232, 233, 234, 235, 236,
        237, 238, 239, 240, 241, 242, 243, 244, 245, 246, 247, 248, 249, 250,
        251, 252, 253, 254, 255, 256, 257, 258, 259, 260, 261, 262, 263, 264,
        265, 266, 267, 268, 269, 270, 271, 272, 273, 274, 275, 276, 277, 278,
        279, 280, 281, 282, 283, 284, 285, 286, 287, 288, 289, 290, 291, 292,
        293, 294, 295, 296, 297, 298, 299, 300, 301, 302, 303, 304, 305, 306,
        307, 308, 309, 310, 311, 312, 313, 314, 315, 316, 317, 318, 319, 320,
        321, 322, 323, 324, 325, 326, 327, 328, 329, 330, 331, 332, 333, 334,
        335, 336, 337, 338, 339, 340, 341, 342, 343, 344, 345, 346, 347, 348,
        349, 350, 351, 352, 353, 354, 355, 356, 357, 358, 359, 360, 361, 362,
        363, 364, 365, 366, 367, 368, 369, 370, 371, 372, 373, 374, 375, 376,
        377, 378, 379, 380, 381, 382, 383, 384, 385, 386, 387, 388, 389, 390,
        391, 392, 393, 394, 395, 396, 397, 398, 399, 400]) AS t(g)
) s
PARTITIONED BY ALL;

-- @call boxcount {"datasource": "crd_locations", "entityColumn": "ent",
--                 "xColumn": "x", "yColumn": "y", "dim": 2} AS crd_dim;

SELECT "entity", "dim" FROM "crd_dim" WHERE "entity" IS NOT NULL;

-- ---------------------------------------------------------------------------
-- 5. Reasoning: the referral.
-- ---------------------------------------------------------------------------
SELECT fractal_reason(
    'one-line referral for the suspected staged-event ring',
    '{"held_record":"' || (SELECT ARRAY_TO_STRING(ARRAY_AGG(CAST("label" AS VARCHAR), 8192), ',')
                            FROM "crd_screen" WHERE "id" = 1)
     || '","ring_records_found":"' || (SELECT ARRAY_TO_STRING(ARRAY_AGG(CAST("id" AS VARCHAR), 8192), ',')
                                    FROM "crd_records" WHERE "id" IN (SELECT "doc_id" FROM "crd_traj" WHERE "distance" < 0.001))
     || '"}') AS "narrative";

-- ---------------------------------------------------------------------------
-- 6. The kit's own headline check.
--
-- The demo contract: a kit prints its headline and exits
-- non-zero unless the result holds. The staged-pattern record and the
-- faint minor-severity pattern are held; the isolated single-party
-- record is not; at least three open records moved like the ring; and
-- the ring's footprint is the more linear of the two.
-- ---------------------------------------------------------------------------
SELECT CASE
           WHEN (SELECT "intercepted" FROM "crd_screen" WHERE "id" = 1 GROUP BY "intercepted") = true
            AND (SELECT "intercepted" FROM "crd_screen" WHERE "id" = 2 GROUP BY "intercepted") = false
            AND (SELECT "intercepted" FROM "crd_screen" WHERE "id" = 4 GROUP BY "intercepted") = true
            AND (SELECT COUNT(*) FROM "crd_traj" WHERE "distance" < 0.001) >= 3
            AND (SELECT "dim" FROM "crd_dim" WHERE "entity" = 'staged-ring' GROUP BY "dim")
                + 0.3 < (SELECT "dim" FROM "crd_dim" WHERE "entity" = 'organic-records' GROUP BY "dim")
            THEN 'HEADLINE kit=coordinated-record-detection ok'
            ELSE 'HEADLINE kit=coordinated-record-detection FAILED'
       END AS "headline";
