-- demo/demo-vertical-event-stream-anomaly-triage.sql
--
-- FractalSQL for Apache Druid -- industry vertical: high-frequency
-- event-stream latency and rate anomaly triage. Four endpoints x 96
-- one-minute intervals of request latency; one endpoint (EP-C) develops
-- an accelerating latency ramp (a timeout cascade) and a second (EP-B)
-- has a retry-storm oscillation in its request rate. The regime shift
-- is flagged, the retry-storm period is found, and the endpoints whose
-- health moved the same way are found.
--
--   1. fractal_dimension_drift / fractal_agent_anomaly_triage: which
--      endpoint's latency changed regime.
--   2. fractal_periodogram: the dominant period of each endpoint's
--      request rate (a retry loop shows as a sharp line).
--   3. fractal_search_trajectory: endpoints whose health moved like
--      the degraded one (baseline -> current).
--   4. A closing fractal_reason() writes the triage line.
--
-- Prerequisites: the extension is loaded on the Druid cluster. The closing
-- fractal_reason() narrative and any agent rationale need a reasoning
-- provider (docs/reasoning-setup.md); every other step runs with no model.
--
-- Run:
--   python3 demo/run_demo.py --file demo/demo-vertical-event-stream-anomaly-triage.sql
--
-- ===========================================================================
-- Notes on how this runs on Druid
-- ===========================================================================
--
--   * The fixtures are MSQ writes and @fixture directives: Druid has no
--     DDL, no VALUES and no recursive CTE, so the interval index comes
--     from an UNNESTed array.
--   * The series is folded into one vector per endpoint with ARRAY_AGG:
--     Druid has no group_concat, and the drift exponent is
--     order-sensitive.
--   * The agents and the trajectory search are service calls: an agent
--     reads a table and reasons about it, and a Druid SQL function can
--     do neither.
--
-- Notes:
--   * Fully deterministic fixtures (no random()).

-- ---------------------------------------------------------------------------
-- 0. Sanity check: extension loaded?
-- ---------------------------------------------------------------------------
SELECT fractal_edition(), fractal_version();

-- ---------------------------------------------------------------------------
-- 1. Event-stream telemetry: 4 endpoints x 96 intervals.
--
-- EP-C's latency ramps quadratically from interval 64; EP-B's request
-- rate carries a twelve-interval oscillation.
-- ---------------------------------------------------------------------------
REPLACE INTO esa_latency OVERWRITE ALL
SELECT "ent", "seq", "val"
FROM (
    SELECT CASE
               WHEN g <= 96 THEN 'EP-A'
               WHEN g <= 192 THEN 'EP-B'
               WHEN g <= 288 THEN 'EP-C'
               ELSE 'EP-D'
           END AS "ent",
           CASE
               WHEN g <= 96 THEN g
               WHEN g <= 192 THEN g - 96
               WHEN g <= 288 THEN g - 192
               ELSE g - 288
           END AS "seq",
           CASE
               WHEN g <= 96 THEN 42.0
               WHEN g <= 192 THEN 55.0
               WHEN g <= 288 THEN 48.0
               ELSE 61.0
           END * (1.0 + 0.004 * MOD(CASE
               WHEN g <= 96 THEN g
               WHEN g <= 192 THEN g - 96
               WHEN g <= 288 THEN g - 192
               ELSE g - 288
           END, 8))
           + CASE WHEN g > 192 + 64 AND g <= 288
                  THEN 48.0 * 0.0024 * (g - 192 - 64) * (g - 192 - 64)
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

REPLACE INTO esa_rate OVERWRITE ALL
SELECT "ent", "seq", "val"
FROM (
    SELECT CASE
               WHEN g <= 96 THEN 'EP-A'
               WHEN g <= 192 THEN 'EP-B'
               WHEN g <= 288 THEN 'EP-C'
               ELSE 'EP-D'
           END AS "ent",
           CASE
               WHEN g <= 96 THEN g
               WHEN g <= 192 THEN g - 96
               WHEN g <= 288 THEN g - 192
               ELSE g - 288
           END AS "seq",
           CASE
               WHEN g <= 96 THEN 900.0
               WHEN g <= 192 THEN 800.0
               WHEN g <= 288 THEN 950.0
               ELSE 700.0
           END * (1.0 + 0.02 * SIN(2 * 3.141592653589793 * (CASE
               WHEN g <= 96 THEN g
               WHEN g <= 192 THEN g - 96
               WHEN g <= 288 THEN g - 192
               ELSE g - 288
           END) / 7.0)
               + CASE WHEN g <= 192 AND g > 96 THEN 0.3 END
                 * SIN(2 * 3.141592653589793 * (CASE
                     WHEN g <= 96 THEN g
                     WHEN g <= 192 THEN g - 96
                     WHEN g <= 288 THEN g - 192
                     ELSE g - 288
                 END) / 12.0)) AS "val"
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

SELECT "ent", COUNT(*) AS "intervals" FROM "esa_latency" GROUP BY "ent";

-- ---------------------------------------------------------------------------
-- 2. The latency regime drift per endpoint.
-- ---------------------------------------------------------------------------
REPLACE INTO esa_lprof OVERWRITE ALL
SELECT "ent",
       AVG("val") AS "mean_v",
       AVG("val" * "val") - AVG("val") * AVG("val") AS "var_v",
       fractal_dimension_dfa(
           ARRAY_TO_STRING(ARRAY_AGG(CAST("val" AS VARCHAR), 16384), ',')) AS "dfa_alpha",
       fractal_dimension_drift(
           ARRAY_TO_STRING(ARRAY_AGG(CAST("val" AS VARCHAR), 16384), ','), 32) AS "dj"
FROM "esa_latency"
GROUP BY "ent"
PARTITIONED BY ALL;

SELECT "ent", ROUND("mean_v", 4) AS "mean_v", ROUND("var_v", 4) AS "var_v",
       ROUND("dfa_alpha", 3) AS "dfa_alpha",
       ROUND(fractal_json_value("dj", '$.drift'), 4) AS "drift",
       ROUND(fractal_json_value("dj", '$.recent_alpha'), 4) AS "recent_alpha",
       ROUND(fractal_json_value("dj", '$.baseline_alpha'), 4) AS "baseline_alpha"
FROM "esa_lprof"
GROUP BY "ent", "mean_v", "var_v", "dfa_alpha", "dj";

-- ---------------------------------------------------------------------------
-- 3. fractal_agent_anomaly_triage: degraded vs healthy endpoint.
-- ---------------------------------------------------------------------------
-- @call agent/anomaly_triage {"log_table": "esa_latency", "metric_col": "val",
--                            "time_col": "seq", "filter_col": "ent",
--                            "filter_val": "EP-C", "baseline_window": 32};

-- @call agent/anomaly_triage {"log_table": "esa_latency", "metric_col": "val",
--                            "time_col": "seq", "filter_col": "ent",
--                            "filter_val": "EP-A", "baseline_window": 32};

-- ---------------------------------------------------------------------------
-- 4. Retry-storm period: fractal_periodogram on the request rate.
-- ---------------------------------------------------------------------------
REPLACE INTO esa_rprof OVERWRITE ALL
SELECT "ent",
       AVG("val") AS "mean_v",
       AVG("val" * "val") - AVG("val") * AVG("val") AS "var_v",
       fractal_periodogram(
           ARRAY_TO_STRING(ARRAY_AGG(CAST("val" AS VARCHAR), 16384), ',')) AS "pj"
FROM "esa_rate"
GROUP BY "ent"
PARTITIONED BY ALL;

SELECT "ent", ROUND("mean_v", 4) AS "mean_v", ROUND("var_v", 4) AS "var_v",
       ROUND(fractal_json_value("pj", '$.freqs[0]'), 4) AS "top_freq"
FROM "esa_rprof"
GROUP BY "ent", "mean_v", "var_v", "pj";

-- ---------------------------------------------------------------------------
-- 5. Endpoint health trajectory: who moved like EP-C.
-- ---------------------------------------------------------------------------
-- @fixture esa_health {"rows": [
--   {"id": 1, "label": "EP-01", "vec": "0.05,-0.06,0.03,-0.04"},
--   {"id": 2, "label": "EP-02", "vec": "0.1,-0.02,0.06,0.02"},
--   {"id": 3, "label": "EP-03 (degraded)", "vec": "1.4,0.9,1.1,1.2"},
--   {"id": 4, "label": "EP-04", "vec": "0.2,0.06,0,0.14"},
--   {"id": 5, "label": "EP-05", "vec": "0,0.1,0.03,0.2"},
--   {"id": 6, "label": "EP-06", "vec": "0.05,0.14,0.06,-0.1"},
--   {"id": 7, "label": "EP-07 (degraded)", "vec": "1.4,0.9,1.1,1.2"},
--   {"id": 8, "label": "EP-08", "vec": "0.15,-0.06,0,0.02"},
--   {"id": 9, "label": "EP-09", "vec": "0.2,-0.02,0.03,0.08"},
--   {"id": 10, "label": "EP-10", "vec": "0,0.02,0.06,0.14"},
--   {"id": 11, "label": "EP-11 (degraded)", "vec": "1.4,0.9,1.1,1.2"},
--   {"id": 12, "label": "EP-12", "vec": "0.1,0.1,0,-0.1"},
--   {"id": 13, "label": "EP-13", "vec": "0.15,0.14,0.03,-0.04"},
--   {"id": 14, "label": "EP-14", "vec": "0.2,-0.1,0.06,0.02"},
--   {"id": 15, "label": "EP-15", "vec": "0,-0.06,0.09,0.08"},
--   {"id": 16, "label": "EP-16", "vec": "0.05,-0.02,0,0.14"}
-- ]};

-- @call search/trajectory {"table": "esa_health", "column": "vec", "id_column": "id",
--                         "baseline": "0.05,0,0.03,0", "current": "1.4,0.9,1.1,1.2",
--                         "k": 5} AS esa_traj;

SELECT r."doc_id" AS "id", w."label" AS "label", ROUND(r."distance", 4) AS "distance"
FROM "esa_traj" r, "esa_health" w
WHERE r."doc_id" = w."id";

-- ---------------------------------------------------------------------------
-- 6. Reasoning: the triage line.
-- ---------------------------------------------------------------------------
SELECT fractal_reason(
    'one-line event-stream triage: which endpoint is degrading, since when, and the likely cause',
    '{"worst_endpoint":"' || (SELECT ARRAY_TO_STRING(ARRAY_AGG(CAST("ent" AS VARCHAR), 8192), ',')
                                 FROM "esa_lprof" WHERE fractal_json_value("dj", '$.drift') > 0.5)
     || '","retry_storm_endpoint":"' || (SELECT ARRAY_TO_STRING(ARRAY_AGG(CAST("ent" AS VARCHAR), 8192), ',')
                                       FROM "esa_rprof" WHERE fractal_json_value("pj", '$.freqs[0]') > 0.07)
     || '","nearest_degraded_health":"' || (SELECT ARRAY_TO_STRING(ARRAY_AGG(CAST("label" AS VARCHAR), 8192), ',')
                                            FROM "esa_traj" r, "esa_health" w WHERE r."doc_id" = w."id")
     || '"}') AS "narrative";

-- ---------------------------------------------------------------------------
-- 7. The kit's own headline check.
--
-- The demo contract: a kit prints its headline and exits
-- non-zero unless the result holds. EP-C's latency changed regime and
-- EP-A's did not; EP-B's request rate carries the retry-storm period;
-- and at least three endpoints' health moved like EP-C's.
-- ---------------------------------------------------------------------------
SELECT CASE
           WHEN (SELECT fractal_json_value("dj", '$.drift') FROM "esa_lprof" WHERE "ent" = 'EP-C' GROUP BY "dj") > 0.5
            AND (SELECT fractal_json_value("dj", '$.drift') FROM "esa_lprof" WHERE "ent" = 'EP-A' GROUP BY "dj") < 0
            AND (SELECT fractal_json_value("pj", '$.freqs[0]') FROM "esa_rprof" WHERE "ent" = 'EP-B' GROUP BY "pj") > 0.07
            AND (SELECT fractal_json_value("pj", '$.freqs[0]') FROM "esa_rprof" WHERE "ent" = 'EP-B' GROUP BY "pj") < 0.10
            AND (SELECT COUNT(*) FROM "esa_traj" WHERE "distance" < 0.001) >= 3
            THEN 'HEADLINE kit=event-stream-anomaly-triage ok'
            ELSE 'HEADLINE kit=event-stream-anomaly-triage FAILED'
       END AS "headline";
