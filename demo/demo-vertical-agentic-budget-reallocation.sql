-- demo/demo-vertical-agentic-budget-reallocation.sql
--
-- FractalSQL for Apache Druid -- industry vertical: agentic budget
-- reallocation. AGENTIC kit: six channels x 64 days of attributed
-- outcomes. The DFA exponent finds the channel whose outcomes are
-- accelerating rather than merely high, the optimizer picks the three
-- channels that get the budget, and every journey is dispatched to the
-- routing model that fits it.
--
--   1. fractal_dimension_dfa over each channel's outcomes.
--   2. fractal_optimize_portfolio: pick 3 channels.
--   3. fractal_agent_allocate: the same optimizer plus a rationale.
--   4. fractal_agent_route_task: dispatch each journey to a model.
--   5. A closing fractal_reason() writes the reallocation rationale.
--
-- Prerequisites: the extension is loaded on the Druid cluster. The closing
-- fractal_reason() narrative and the agents' rationales need a reasoning
-- provider (docs/reasoning-setup.md); every other step runs with no model.
--
-- Run:
--   python3 demo/run_demo.py --file demo/demo-vertical-agentic-budget-reallocation.sql
--
-- ===========================================================================
-- Notes on how this runs on Druid
-- ===========================================================================
--
--   * The fixtures are MSQ writes and @fixture directives: Druid has no
--     DDL, no VALUES and no recursive CTE.
--   * The optimizer's risk matrix is a cross join of the profile rows,
--     folded into one flat vector with ARRAY_AGG: Druid has no
--     group_concat and no json_each.
--   * The agents are service calls, not SQL functions: an agent reads a
--     table and reasons about it, and a Druid SQL function can do
--     neither. The router's call covers the whole table of journeys, so
--     its result lands in a datasource the kit can query.
--
-- Notes:
--   * Fully deterministic fixtures (no random()).
--   * The optimizer maximizes a Sharpe-style ratio: mu is the mean daily
--     outcomes per unit of spend, the matrix is the response risk
--     (variance x DFA exponent).
--   * Model capability vectors = [single-step, recency-weighted, mid-path-
--     heavy, cross-device].
--   * Ends with a HEADLINE line computed from the kit's own results
--     (HEADLINE kit=<name> ok); the build_test kit gate greps for it.

-- ---------------------------------------------------------------------------
-- 0. Sanity check: extension loaded?
-- ---------------------------------------------------------------------------
SELECT fractal_edition(), fractal_version();

-- ---------------------------------------------------------------------------
-- 1. Six channels x 64 days of attributed outcomes.
--
-- channel-d accelerates from day 41.
-- ---------------------------------------------------------------------------
REPLACE INTO abr_outcome OVERWRITE ALL
SELECT "ent", "seq", "val"
FROM (
    SELECT CASE
               WHEN g <= 64 THEN 'channel-a'
               WHEN g <= 128 THEN 'channel-b'
               WHEN g <= 192 THEN 'channel-c'
               WHEN g <= 256 THEN 'channel-d'
               WHEN g <= 320 THEN 'channel-e'
               ELSE 'channel-f'
           END AS "ent",
           CASE
               WHEN g <= 64 THEN g
               WHEN g <= 128 THEN g - 64
               WHEN g <= 192 THEN g - 128
               WHEN g <= 256 THEN g - 192
               WHEN g <= 320 THEN g - 256
               ELSE g - 320
           END AS "seq",
           CASE
               WHEN g <= 64 THEN 120.0
               WHEN g <= 128 THEN 95.0
               WHEN g <= 192 THEN 140.0
               WHEN g <= 256 THEN 110.0
               WHEN g <= 320 THEN 160.0
               ELSE 85.0
           END * (1.0 + 0.06 * MOD(CASE
               WHEN g <= 64 THEN g
               WHEN g <= 128 THEN g - 64
               WHEN g <= 192 THEN g - 128
               WHEN g <= 256 THEN g - 192
               WHEN g <= 320 THEN g - 256
               ELSE g - 320
           END + CASE
               WHEN g <= 64 THEN 1
               WHEN g <= 128 THEN 2
               WHEN g <= 192 THEN 3
               WHEN g <= 256 THEN 4
               WHEN g <= 320 THEN 5
               ELSE 6
           END, 7) / 7.0)
           + CASE WHEN g > 192 + 40 AND g <= 256
                  THEN 0.45 * (g - 192 - 40) * (g - 192 - 40)
                  ELSE 0 END AS "val"
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
        377, 378, 379, 380, 381, 382, 383, 384]) AS t(g)
) s
PARTITIONED BY ALL;

-- ---------------------------------------------------------------------------
-- 2. DFA exponent of each channel.
--
-- The series is folded into one vector per channel with ARRAY_AGG: the
-- DFA exponent is order-sensitive.
-- ---------------------------------------------------------------------------
REPLACE INTO abr_prof OVERWRITE ALL
SELECT "ent",
       AVG("val") AS "mean_v",
       AVG("val" * "val") - AVG("val") * AVG("val") AS "var_v",
       fractal_dimension_dfa(
           ARRAY_TO_STRING(ARRAY_AGG(CAST("val" AS VARCHAR), 16384), ',')) AS "dfa_alpha"
FROM "abr_outcome"
GROUP BY "ent"
PARTITIONED BY ALL;

SELECT "ent", ROUND("mean_v", 4) AS "mean_v", ROUND("var_v", 4) AS "var_v",
       ROUND("dfa_alpha", 3) AS "dfa_alpha"
FROM "abr_prof"
GROUP BY "ent", "mean_v", "var_v", "dfa_alpha" ORDER BY "ent";

-- ---------------------------------------------------------------------------
-- 3. fractal_optimize_portfolio: pick 3 channels.
-- ---------------------------------------------------------------------------
REPLACE INTO abr_result OVERWRITE ALL
SELECT fractal_optimize_portfolio(
           ARRAY_TO_STRING(ARRAY_AGG(CAST(ROUND(a."mean_v" / 100.0, 4) AS VARCHAR), 8192), ','),
           ARRAY_TO_STRING(ARRAY_AGG(
               CAST(ROUND(CASE WHEN a."ent" = b."ent"
                               THEN a."var_v" * a."dfa_alpha" / 100.0
                               ELSE 0 END, 4) AS VARCHAR), 8192), ','),
           3) AS "rj"
FROM "abr_prof" a, "abr_prof" b
PARTITIONED BY ALL;

SELECT fractal_json_value("rj", '$.sharpe') AS "sharpe" FROM "abr_result" GROUP BY "rj";

-- The shipped agent: optimizer + reasoned rationale, one call.
-- @call agent/allocate {"table": "abr_outcome", "column": "val",
--                      "entity_column": "ent", "cardinality": 3};

-- ---------------------------------------------------------------------------
-- 4. Dispatch each journey to a routing model.
-- ---------------------------------------------------------------------------
-- @fixture abr_models {"rows": [
--   {"id": 1, "label": "single-step",       "vec": "0.95,0.2,0.1,0.1"},
--   {"id": 2, "label": "time-decay",        "vec": "0.3,0.95,0.2,0.15"},
--   {"id": 3, "label": "mid-path-weighted", "vec": "0.2,0.3,0.9,0.2"},
--   {"id": 4, "label": "cross-device",      "vec": "0.35,0.4,0.45,0.95"}
-- ]};

-- @fixture abr_events {"rows": [
--   {"id": 1, "label": "J1 one-step direct path",           "vec": "0.92,0.15,0.1,0.1"},
--   {"id": 2, "label": "J2 week-long path, recent contact", "vec": "0.3,0.92,0.2,0.15"},
--   {"id": 3, "label": "J3 multi-channel path, mid-touch heavy", "vec": "0.2,0.3,0.88,0.2"},
--   {"id": 4, "label": "J4 cross-device path",             "vec": "0.35,0.4,0.45,0.92"},
--   {"id": 5, "label": "J5 direct return visit",            "vec": "0.9,0.25,0.1,0.12"}
-- ]};

-- @call agent/route_task {"task_table": "abr_events", "task_column": "vec",
--                         "task_id_column": "id",
--                         "cap_table": "abr_models", "cap_emb_col": "vec",
--                         "cap_id_col": "label", "budget": 1000} AS abr_routed;

SELECT "req_id", "routed_to", ROUND("confidence", 4) AS "confidence", "remaining_budget"
FROM "abr_routed" WHERE "req_id" IS NOT NULL;

-- ---------------------------------------------------------------------------
-- 5. Reasoning: reallocation rationale.
-- ---------------------------------------------------------------------------
SELECT fractal_reason(
    'one-line rationale for this cross-channel budget reallocation and the capped test on the surging channel',
    '{"surging_channel":"' || (SELECT ARRAY_TO_STRING(ARRAY_AGG(CAST("ent" AS VARCHAR), 8192), ',')
                               FROM "abr_prof" WHERE "dfa_alpha" > 1.2 GROUP BY "ent")
     || '","journeys_routed":"' || (SELECT ARRAY_TO_STRING(ARRAY_AGG(CAST("req_id" AS VARCHAR), 8192), ',')
                                   FROM "abr_routed" WHERE "req_id" IS NOT NULL)
     || '"}') AS "narrative";

-- ---------------------------------------------------------------------------
-- 6. The kit's own headline check.
--
-- The demo contract: a kit prints its headline and exits
-- non-zero unless the result holds. channel-d is the accelerating one
-- and the only one above 1.2; all five journeys are routed; the
-- one-step journey goes to the single-step model and the cross-device
-- journey to the cross-device one.
-- ---------------------------------------------------------------------------
SELECT CASE
           WHEN (SELECT "dfa_alpha" FROM "abr_prof" WHERE "ent" = 'channel-d' GROUP BY "dfa_alpha") > 1.2
            AND (SELECT COUNT(*) FROM "abr_prof" WHERE "dfa_alpha" > 1.2) = 1
            AND (SELECT COUNT(*) FROM "abr_routed" WHERE "req_id" IS NOT NULL) = 5
            AND (SELECT "routed_to" FROM "abr_routed" WHERE "req_id" = 1 GROUP BY "routed_to") = 'single-step'
            AND (SELECT "routed_to" FROM "abr_routed" WHERE "req_id" = 4 GROUP BY "routed_to") = 'cross-device'
            THEN 'HEADLINE kit=agentic-budget-reallocation ok'
            ELSE 'HEADLINE kit=agentic-budget-reallocation FAILED'
       END AS "headline";
