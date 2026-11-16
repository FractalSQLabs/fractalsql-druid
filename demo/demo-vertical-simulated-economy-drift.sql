-- demo/demo-vertical-simulated-economy-drift.sql
--
-- FractalSQL for Apache Druid -- industry vertical: simulated-economy
-- drift. Six markets x 96 days of price index; mkt-d inflates from
-- day 65. The weekly cycle and the non-linearity are measured per
-- market (the DFA exponent and the periodogram's top frequency), a
-- sink program picks three markets with `fractal_optimize_portfolio`,
-- and `fractal_agent_detect_loop` separates an automated actor (a
-- period-2 state flip) from a varied one (a smooth walk).
--
--   1. Six markets x 96 days of price index.
--   2. Weekly cycle and non-linearity per market.
--   3. fractal_optimize_portfolio: pick 3 markets for the sink program.
--   4. fractal_agent_detect_loop: automated actor vs varied actor.
--   5. A closing fractal_reason() writes the balance note.
--
-- Prerequisites: the extension is loaded on the Druid cluster. The closing
-- fractal_reason() narrative needs a reasoning provider
-- (docs/reasoning-setup.md); every other step runs with no model.
--
-- Run:
--   python3 demo/run_demo.py --file demo/demo-vertical-simulated-economy-drift.sql
--
-- ===========================================================================
-- Notes on how this runs on Druid
-- ===========================================================================
--
--   * The fixtures are MSQ writes and @fixture directives: Druid has no
--     DDL, no VALUES and no recursive CTE, so the day index comes from
--     an UNNESTed array.
--   * The risk matrix is a cross join of the profile rows, folded into
--     one flat vector with ARRAY_AGG: Druid has no group_concat and no
--     json_each.
--   * The loop detector is a service call: its state log is computed in
--     SQL, and an agent's arguments are values, so the log is written
--     to a datasource and the agent reads it from there.
--
-- Notes:
--   * Fully deterministic fixtures (no random()).
--   * Ends with a HEADLINE line computed from the kit's own results
--     (HEADLINE kit=<name> ok); the build_test kit gate greps for it.

-- ---------------------------------------------------------------------------
-- 0. Sanity check: extension loaded?
-- ---------------------------------------------------------------------------
SELECT fractal_edition(), fractal_version();

-- ---------------------------------------------------------------------------
-- 1. Six markets x 96 days of price index.
--
-- mkt-d's index inflates quadratically from day 65; the others carry a
-- weekly cycle.
-- ---------------------------------------------------------------------------
REPLACE INTO sed_price OVERWRITE ALL
SELECT "ent", "seq", "val"
FROM (
    SELECT CASE
               WHEN g <= 96 THEN 'mkt-a'
               WHEN g <= 192 THEN 'mkt-b'
               WHEN g <= 288 THEN 'mkt-c'
               WHEN g <= 384 THEN 'mkt-d'
               WHEN g <= 480 THEN 'mkt-e'
               ELSE 'mkt-f'
           END AS "ent",
           CASE
               WHEN g <= 96 THEN g
               WHEN g <= 192 THEN g - 96
               WHEN g <= 288 THEN g - 192
               WHEN g <= 384 THEN g - 288
               WHEN g <= 480 THEN g - 384
               ELSE g - 480
           END AS "seq",
           CASE
               WHEN g <= 96 THEN 100.0
               WHEN g <= 192 THEN 80.0
               WHEN g <= 288 THEN 140.0
               WHEN g <= 384 THEN 120.0
               WHEN g <= 480 THEN 90.0
               ELSE 200.0
           END * (1.0
               + CASE
                     WHEN g <= 96 THEN 0.12
                     WHEN g <= 192 THEN 0.15
                     WHEN g <= 288 THEN 0.10
                     WHEN g <= 384 THEN 0.14
                     WHEN g <= 480 THEN 0.12
                     ELSE 0.08
                 END * SIN(2 * 3.141592653589793 * (CASE
                     WHEN g <= 96 THEN g
                     WHEN g <= 192 THEN g - 96
                     WHEN g <= 288 THEN g - 192
                     WHEN g <= 384 THEN g - 288
                     WHEN g <= 480 THEN g - 384
                     ELSE g - 480
                 END) / 7.0)
               + 0.004 * MOD(CASE
                     WHEN g <= 96 THEN g
                     WHEN g <= 192 THEN g - 96
                     WHEN g <= 288 THEN g - 192
                     WHEN g <= 384 THEN g - 288
                     WHEN g <= 480 THEN g - 384
                     ELSE g - 480
                 END, 5))
               + CASE WHEN g > 288 + 64 AND g <= 384
                      THEN 120.0 * 0.0024 * (g - 288 - 64) * (g - 288 - 64)
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
        377, 378, 379, 380, 381, 382, 383, 384, 385, 386, 387, 388, 389, 390,
        391, 392, 393, 394, 395, 396, 397, 398, 399, 400, 401, 402, 403, 404,
        405, 406, 407, 408, 409, 410, 411, 412, 413, 414, 415, 416, 417, 418,
        419, 420, 421, 422, 423, 424, 425, 426, 427, 428, 429, 430, 431, 432,
        433, 434, 435, 436, 437, 438, 439, 440, 441, 442, 443, 444, 445, 446,
        447, 448, 449, 450, 451, 452, 453, 454, 455, 456, 457, 458, 459, 460,
        461, 462, 463, 464, 465, 466, 467, 468, 469, 470, 471, 472, 473, 474,
        475, 476, 477, 478, 479, 480, 481, 482, 483, 484, 485, 486, 487, 488,
        489, 490, 491, 492, 493, 494, 495, 496, 497, 498, 499, 500, 501, 502,
        503, 504, 505, 506, 507, 508, 509, 510, 511, 512, 513, 514, 515, 516,
        517, 518, 519, 520, 521, 522, 523, 524, 525, 526, 527, 528, 529, 530,
        531, 532, 533, 534, 535, 536, 537, 538, 539, 540, 541, 542, 543, 544,
        545, 546, 547, 548, 549, 550, 551, 552, 553, 554, 555, 556, 557, 558,
        559, 560, 561, 562, 563, 564, 565, 566, 567, 568, 569, 570, 571, 572,
        573, 574, 575, 576]) AS t(g)
) s
PARTITIONED BY ALL;

-- ---------------------------------------------------------------------------
-- 2. Weekly cycle and non-linearity per market.
--
-- The series is folded into one vector per market with ARRAY_AGG: the
-- DFA exponent and the periodogram are both order-sensitive.
-- ---------------------------------------------------------------------------
REPLACE INTO sed_prof OVERWRITE ALL
SELECT "ent",
       AVG("val") AS "mean_v",
       AVG("val" * "val") - AVG("val") * AVG("val") AS "var_v",
       fractal_dimension_dfa(
           ARRAY_TO_STRING(ARRAY_AGG(CAST("val" AS VARCHAR), 16384), ',')) AS "dfa_alpha",
       fractal_periodogram(
           ARRAY_TO_STRING(ARRAY_AGG(CAST("val" AS VARCHAR), 16384), ',')) AS "pj"
FROM "sed_price"
GROUP BY "ent"
PARTITIONED BY ALL;

SELECT "ent", ROUND("mean_v", 4) AS "mean_v", ROUND("var_v", 4) AS "var_v",
       ROUND("dfa_alpha", 3) AS "dfa_alpha",
       ROUND(fractal_json_value("pj", '$.freqs[0]'), 4) AS "top_freq"
FROM "sed_prof"
GROUP BY "ent", "mean_v", "var_v", "dfa_alpha", "pj"
ORDER BY "ent";

-- ---------------------------------------------------------------------------
-- 3. fractal_optimize_portfolio: pick 3 markets for the sink program.
-- ---------------------------------------------------------------------------
REPLACE INTO sed_result OVERWRITE ALL
SELECT fractal_optimize_portfolio(
           ARRAY_TO_STRING(ARRAY_AGG(CAST(ROUND(a."mean_v" / 100.0, 4) AS VARCHAR), 8192), ','),
           ARRAY_TO_STRING(ARRAY_AGG(
               CAST(ROUND(CASE WHEN a."ent" = b."ent"
                               THEN a."var_v" * a."dfa_alpha" / 100.0
                               ELSE 0 END, 4) AS VARCHAR), 8192), ','),
           3) AS "rj"
FROM "sed_prof" a, "sed_prof" b
PARTITIONED BY ALL;

SELECT fractal_json_value("rj", '$.sharpe') AS "sharpe" FROM "sed_result" GROUP BY "rj";

-- ---------------------------------------------------------------------------
-- 4. fractal_agent_detect_loop: automated actor vs varied actor.
--
-- The two state logs are computed here and handed to the agent through
-- a datasource: an agent's arguments are values, and these are
-- computed.
-- ---------------------------------------------------------------------------
REPLACE INTO sed_log_varied OVERWRITE ALL
SELECT ARRAY_TO_STRING(ARRAY_AGG(
           CAST(SIN(t * 1.41421356) AS VARCHAR) || ',' ||
           CAST(SIN(t * 1.73205081) AS VARCHAR) || ',' ||
           CAST(SIN(t * 2.23606798) AS VARCHAR) || ',' ||
           CAST(SIN(t * 2.64575131) AS VARCHAR) || ',' ||
           CAST(SIN(t * 3.31662479) AS VARCHAR) || ',' ||
           CAST(SIN(t * 3.60555128) AS VARCHAR) || ',' ||
           CAST(SIN(t * 3.87298335) AS VARCHAR) || ',' ||
           CAST(SIN(t * 4.12310563) AS VARCHAR), 16384), ',') AS "log"
FROM (
    SELECT g AS t
    FROM UNNEST(ARRAY[
        1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16,
        17, 18, 19, 20, 21, 22, 23, 24]) AS s(g)
) w
PARTITIONED BY ALL;

REPLACE INTO sed_log_auto OVERWRITE ALL
SELECT ARRAY_TO_STRING(ARRAY_AGG(
           CASE WHEN MOD(t, 2) = 0 THEN '1,0,0' ELSE '0,1,0' END, 16384), ',') AS "log"
FROM (
    SELECT g AS t
    FROM UNNEST(ARRAY[
        1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16,
        17, 18, 19, 20, 21, 22, 23, 24]) AS s(g)
) w
PARTITIONED BY ALL;

-- @call agent/detect_loop {"agent_id": "varied-actor", "state_log_table": "sed_log_varied",
--                         "state_log_column": "log", "dim": 8} AS sed_loop_varied;

-- @call agent/detect_loop {"agent_id": "auto-actor", "state_log_table": "sed_log_auto",
--                         "state_log_column": "log", "dim": 3} AS sed_loop_auto;

REPLACE INTO sed_loop OVERWRITE ALL
SELECT "agent_id", "is_loop_detected" AS "is_loop", "dfa_exponent" AS "dfa_exponent"
FROM (
    SELECT "agent_id", "is_loop_detected", "dfa_exponent" FROM "sed_loop_varied"
    UNION ALL
    SELECT "agent_id", "is_loop_detected", "dfa_exponent" FROM "sed_loop_auto"
) u
PARTITIONED BY ALL;

SELECT "agent_id", "is_loop", "dfa_exponent" FROM "sed_loop"
GROUP BY "agent_id", "is_loop", "dfa_exponent" ORDER BY "agent_id";

-- ---------------------------------------------------------------------------
-- 5. Reasoning: the balance note.
-- ---------------------------------------------------------------------------
SELECT fractal_reason(
    'one-line balance note: the inflating market, the sink program, and the actor to block',
    '{"inflating_market":"' || (SELECT ARRAY_TO_STRING(ARRAY_AGG(CAST("ent" AS VARCHAR), 8192), ',')
                                FROM "sed_prof" WHERE "dfa_alpha" > 1.2 GROUP BY "ent")
     || '","bot_loops":"' || (SELECT ARRAY_TO_STRING(ARRAY_AGG(CAST("agent_id" AS VARCHAR), 8192), ',')
                              FROM "sed_loop" WHERE "is_loop" = true GROUP BY "agent_id")
     || '"}') AS "narrative";

-- ---------------------------------------------------------------------------
-- 6. The kit's own headline check.
--
-- The demo contract: a kit prints its headline and exits
-- non-zero unless the result holds. mkt-d is the inflating market and
-- the only one above the 1.2 exponent; mkt-b's weekly cycle is around
-- a seventh of a sample; and only the automated actor loops.
-- ---------------------------------------------------------------------------
SELECT CASE
           WHEN (SELECT "dfa_alpha" FROM "sed_prof" WHERE "ent" = 'mkt-d' GROUP BY "dfa_alpha") > 1.2
            AND (SELECT COUNT(*) FROM "sed_prof" WHERE "dfa_alpha" > 1.2) = 1
            AND (SELECT fractal_json_value("pj", '$.freqs[0]') FROM "sed_prof" WHERE "ent" = 'mkt-b' GROUP BY "pj") > 0.13
            AND (SELECT fractal_json_value("pj", '$.freqs[0]') FROM "sed_prof" WHERE "ent" = 'mkt-b' GROUP BY "pj") < 0.16
            AND (SELECT "is_loop" FROM "sed_loop" WHERE "agent_id" = 'auto-actor' GROUP BY "is_loop") = true
            AND (SELECT "is_loop" FROM "sed_loop" WHERE "agent_id" = 'varied-actor' GROUP BY "is_loop") = false
            THEN 'HEADLINE kit=simulated-economy-drift ok'
            ELSE 'HEADLINE kit=simulated-economy-drift FAILED'
       END AS "headline";
