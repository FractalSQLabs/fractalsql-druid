-- demo/demo-vertical-cybersecurity-threat-detection.sql
--
-- FractalSQL for Apache Druid -- industry vertical: cybersecurity threat
-- detection. Thirty-five hosts, each with a BASELINE network-behaviour
-- vector and a CURRENT one. Host 7 is compromised: its outbound
-- connections, destination ports and DNS volume all spike, while
-- failed-auth barely moves.
--
--   1. The hosts: baseline vs. current network-behaviour vectors.
--   2. Diverse traffic-profile clustering (threat hunting).
--   3. Zone-restricted search: the DMZ hosts only.
--   4. fractal_search_trajectory: host 7's drift against the fleet.
--   5. Host 7's connection-rate regime change (DFA + drift).
--   6. Host 7's connection-rate periodogram (a beaconing-interval check).
--   7. Reasoning: carried by the two composition rationales.
--
-- Prerequisites: the extension is loaded on the Druid cluster. The
-- rationales need a reasoning provider (docs/reasoning-setup.md); every
-- other step runs with no model.
--
-- Run:
--   python3 demo/run_demo.py --file demo/demo-vertical-cybersecurity-threat-detection.sql
--
-- ===========================================================================
-- Notes on how this runs on Druid
-- ===========================================================================
--
--   * The hosts are a fixture: Druid has no DDL, no VALUES and no
--     recursive CTE, and random values are the deterministic sin-hash the other kits use.
--   * The searches and the compositions are service calls: an agent
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
-- 1. Thirty-five hosts: baseline vs. current network-behaviour vectors.
--
-- The vector is [outbound connections, destination ports, DNS volume,
-- failed auth]. Host 7's current is its baseline plus the compromise.
-- ---------------------------------------------------------------------------
-- @fixture vcy_hosts {"rows": [
--   {"id": 1, "hostname": "HOST-1", "zone": "dmz", "baseline": "0.2857,0.4180,0.2006,0.5759", "current": "0.2829,0.4009,0.2123,0.5937"},
--   {"id": 2, "hostname": "HOST-2", "zone": "internal", "baseline": "0.4180,0.2006,0.5759,0.9815", "current": "0.4009,0.2123,0.5937,0.9685"},
--   {"id": 3, "hostname": "HOST-3", "zone": "guest", "baseline": "0.2006,0.5759,0.9815,0.9206", "current": "0.2123,0.5937,0.9685,0.9214"},
--   {"id": 4, "hostname": "HOST-4", "zone": "dmz", "baseline": "0.5759,0.9815,0.9206,0.4703", "current": "0.5937,0.9685,0.9214,0.4489"},
--   {"id": 5, "hostname": "HOST-5", "zone": "internal", "baseline": "0.9815,0.9206,0.4703,0.7682", "current": "0.9685,0.9214,0.4489,0.7451"},
--   {"id": 6, "hostname": "HOST-6", "zone": "guest", "baseline": "0.9206,0.4703,0.7682,0.5967", "current": "0.9214,0.4489,0.7451,0.5848"},
--   {"id": 7, "hostname": "HOST-7", "zone": "dmz", "baseline": "0.4703,0.7682,0.5967,0.9343", "current": "1.2703,1.4682,1.1967,0.9843"},
--   {"id": 8, "hostname": "HOST-8", "zone": "internal", "baseline": "0.7682,0.5967,0.9343,0.4531", "current": "0.7451,0.5848,0.9113,0.4718"},
--   {"id": 9, "hostname": "HOST-9", "zone": "guest", "baseline": "0.5967,0.9343,0.4531,0.2154", "current": "0.5848,0.9113,0.4718,0.2186"},
--   {"id": 10, "hostname": "HOST-10", "zone": "dmz", "baseline": "0.9343,0.4531,0.2154,0.6947", "current": "0.9113,0.4718,0.2186,0.6890"},
--   {"id": 11, "hostname": "HOST-11", "zone": "internal", "baseline": "0.4531,0.2154,0.6947,0.7960", "current": "0.4718,0.2186,0.6890,0.8184"},
--   {"id": 12, "hostname": "HOST-12", "zone": "guest", "baseline": "0.2154,0.6947,0.7960,0.2832", "current": "0.2186,0.6890,0.8184,0.2817"},
--   {"id": 13, "hostname": "HOST-13", "zone": "dmz", "baseline": "0.6947,0.7960,0.2832,0.5139", "current": "0.6890,0.8184,0.2817,0.4974"},
--   {"id": 14, "hostname": "HOST-14", "zone": "internal", "baseline": "0.7960,0.2832,0.5139,0.1425", "current": "0.8184,0.2817,0.4974,0.1311"},
--   {"id": 15, "hostname": "HOST-15", "zone": "guest", "baseline": "0.2832,0.5139,0.1425,0.1144", "current": "0.2817,0.4974,0.1311,0.0949"},
--   {"id": 16, "hostname": "HOST-16", "zone": "dmz", "baseline": "0.5139,0.1425,0.1144,0.3022", "current": "0.4974,0.1311,0.0949,0.2824"},
--   {"id": 17, "hostname": "HOST-17", "zone": "internal", "baseline": "0.1425,0.1144,0.3022,0.1159", "current": "0.1311,0.0949,0.2824,0.0908"},
--   {"id": 18, "hostname": "HOST-18", "zone": "guest", "baseline": "0.1144,0.3022,0.1159,0.8120", "current": "0.0949,0.2824,0.0908,0.8307"},
--   {"id": 19, "hostname": "HOST-19", "zone": "dmz", "baseline": "0.3022,0.1159,0.8120,0.5539", "current": "0.2824,0.0908,0.8307,0.5249"},
--   {"id": 20, "hostname": "HOST-20", "zone": "internal", "baseline": "0.1159,0.8120,0.5539,0.4046", "current": "0.0908,0.8307,0.5249,0.3799"},
--   {"id": 21, "hostname": "HOST-21", "zone": "guest", "baseline": "0.8120,0.5539,0.4046,0.8729", "current": "0.8307,0.5249,0.3799,0.8476"},
--   {"id": 22, "hostname": "HOST-22", "zone": "dmz", "baseline": "0.5539,0.4046,0.8729,0.4747", "current": "0.5249,0.3799,0.8476,0.4806"},
--   {"id": 23, "hostname": "HOST-23", "zone": "internal", "baseline": "0.4046,0.8729,0.4747,0.2250", "current": "0.3799,0.8476,0.4806,0.2095"},
--   {"id": 24, "hostname": "HOST-24", "zone": "guest", "baseline": "0.8729,0.4747,0.2250,0.3093", "current": "0.8476,0.4806,0.2095,0.3026"},
--   {"id": 25, "hostname": "HOST-25", "zone": "dmz", "baseline": "0.4747,0.2250,0.3093,0.1749", "current": "0.4806,0.2095,0.3026,0.1646"},
--   {"id": 26, "hostname": "HOST-26", "zone": "internal", "baseline": "0.2250,0.3093,0.1749,0.1698", "current": "0.2095,0.3026,0.1646,0.1619"},
--   {"id": 27, "hostname": "HOST-27", "zone": "guest", "baseline": "0.3093,0.1749,0.1698,0.0822", "current": "0.3026,0.1646,0.1619,0.0826"},
--   {"id": 28, "hostname": "HOST-28", "zone": "dmz", "baseline": "0.1749,0.1698,0.0822,0.8109", "current": "0.1646,0.1619,0.0826,0.7913"},
--   {"id": 29, "hostname": "HOST-29", "zone": "internal", "baseline": "0.1698,0.0822,0.8109,0.0167", "current": "0.1619,0.0826,0.7913,-0.0116"},
--   {"id": 30, "hostname": "HOST-30", "zone": "guest", "baseline": "0.0822,0.8109,0.0167,0.0881", "current": "0.0826,0.7913,-0.0116,0.0695"},
--   {"id": 31, "hostname": "HOST-31", "zone": "dmz", "baseline": "0.8109,0.0167,0.0881,0.0775", "current": "0.7913,-0.0116,0.0695,0.0832"},
--   {"id": 32, "hostname": "HOST-32", "zone": "internal", "baseline": "0.0167,0.0881,0.0775,0.5976", "current": "-0.0116,0.0695,0.0832,0.5768"},
--   {"id": 33, "hostname": "HOST-33", "zone": "guest", "baseline": "0.0881,0.0775,0.5976,0.2415", "current": "0.0695,0.0832,0.5768,0.2531"},
--   {"id": 34, "hostname": "HOST-34", "zone": "dmz", "baseline": "0.0775,0.5976,0.2415,0.3881", "current": "0.0832,0.5768,0.2531,0.3691"},
--   {"id": 35, "hostname": "HOST-35", "zone": "internal", "baseline": "0.5976,0.2415,0.3881,0.3282", "current": "0.5768,0.2531,0.3691,0.3009"}
-- ]};

-- ---------------------------------------------------------------------------
-- 2. Diverse traffic-profile clustering (threat hunting): "what KINDS
-- of behaviour profiles are actually running right now" instead of
-- cosine top-K, which would return six near-duplicates.
-- ---------------------------------------------------------------------------
-- @call search/explore {"datasource": "vcy_hosts", "vectorColumn": "current",
--                      "idColumn": "id", "query": "0,0.2,0,0", "k": 6,
--                      "params": "{\"population_size\": 6, \"iterations\": 8}"} AS vcy_scout;

SELECT r."ord" AS "ord", h."hostname" AS "hostname", h."zone" AS "zone"
FROM "vcy_scout" r, "vcy_hosts" h
WHERE r."doc_id" = h."id";

-- ---------------------------------------------------------------------------
-- 3. Zone-restricted search: the DMZ hosts only.
-- ---------------------------------------------------------------------------
-- @call search/telemetry {"table": "vcy_hosts", "column": "current", "id_column": "id",
--                        "query": "0.9,0.8,0.7,0.1", "k": 3,
--                        "filter": "\"zone\" = 'dmz'"} AS vcy_dmz;

SELECT r."doc_id" AS "id", h."hostname" AS "hostname", ROUND(r."distance", 4) AS "distance"
FROM "vcy_dmz" r, "vcy_hosts" h
WHERE r."doc_id" = h."id";

-- ---------------------------------------------------------------------------
-- 4. Host 7's drift against the fleet.
-- ---------------------------------------------------------------------------
REPLACE INTO vcy_host7 OVERWRITE ALL
SELECT "baseline", "current" FROM "vcy_hosts" WHERE "id" = 7
PARTITIONED BY ALL;

-- @call search/trajectory {"table": "vcy_hosts", "column": "current", "id_column": "id",
--                         "baseline_table": "vcy_host7", "baseline_column": "baseline",
--                         "current_table": "vcy_host7", "current_column": "current",
--                         "k": 5} AS vcy_traj;

SELECT r."doc_id" AS "id", h."hostname" AS "hostname", ROUND(r."distance", 4) AS "distance"
FROM "vcy_traj" r, "vcy_hosts" h
WHERE r."doc_id" = h."id";

-- ---------------------------------------------------------------------------
-- 5. Host 7's connection-rate regime change: the DFA exponent and the
-- drift report over the same series.
--
-- The series is 300 points: a slow oscillation for the first 220, then
-- a fast one -- the beaconing signature.
-- ---------------------------------------------------------------------------
REPLACE INTO vcy_conn_series OVERWRITE ALL
SELECT "t", "conn_rate"
FROM (
    SELECT g AS "t",
           CASE WHEN g < 220
                THEN 4.0 + 1.5 * SIN(g * 0.31)
                     + (SIN((g + 21) * 12.9898) * 43758.5453 - FLOOR(SIN((g + 21) * 12.9898) * 43758.5453) - 0.5) * 0.8
                ELSE 4.0 + 3.0 * SIN(g * 1.4)
                     + (SIN((g + 21) * 12.9898) * 43758.5453 - FLOOR(SIN((g + 21) * 12.9898) * 43758.5453) - 0.5) * 0.4
           END AS "conn_rate"
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
        213, 214, 215, 216, 217, 218, 219, 220, 221, 222, 223, 224, 225, 226, 227,
        228, 229, 230, 231, 232, 233, 234, 235, 236, 237, 238, 239, 240, 241, 242, 243,
        244, 245, 246, 247, 248, 249, 250, 251, 252, 253, 254, 255, 256, 257, 258, 259,
        260, 261, 262, 263, 264, 265, 266, 267, 268, 269, 270, 271, 272, 273, 274,
        275, 276, 277, 278, 279, 280, 281, 282, 283, 284, 285, 286, 287, 288, 289, 290,
        291, 292, 293, 294, 295, 296, 297, 298, 299, 300]) AS t(g)
) s
PARTITIONED BY ALL;

SELECT fractal_dimension_dfa(
           ARRAY_TO_STRING(ARRAY_AGG(CAST("conn_rate" AS VARCHAR), 16384), ',')) AS "full_series_dfa_exponent"
FROM "vcy_conn_series";

SELECT fractal_dimension_drift(
           ARRAY_TO_STRING(ARRAY_AGG(CAST("conn_rate" AS VARCHAR), 16384), ','), 60) AS "recent_60min_vs_history"
FROM "vcy_conn_series";

-- The regime triage: the exponent, whether the drift fired, and the two
-- alphas.
SELECT fractal_dimension_dfa(
           ARRAY_TO_STRING(ARRAY_AGG(CAST("conn_rate" AS VARCHAR), 16384), ',')) AS "dfa_exponent",
       (ABS(fractal_json_value(fractal_dimension_drift(
           ARRAY_TO_STRING(ARRAY_AGG(CAST("conn_rate" AS VARCHAR), 16384), ','), 64), '$.drift')) > 0.5)
           AS "drift_detected",
       fractal_json_value(fractal_dimension_drift(
           ARRAY_TO_STRING(ARRAY_AGG(CAST("conn_rate" AS VARCHAR), 16384), ','), 64), '$.recent_alpha')
           AS "recent_alpha",
       fractal_json_value(fractal_dimension_drift(
           ARRAY_TO_STRING(ARRAY_AGG(CAST("conn_rate" AS VARCHAR), 16384), ','), 64), '$.baseline_alpha')
           AS "baseline_alpha"
FROM "vcy_conn_series";

-- @call reason {"query": "one-line regime triage for this host connection-rate series",
--               "context": "$previous"};

-- ---------------------------------------------------------------------------
-- 6. Host 7's connection-rate periodogram: the beaconing window (from
-- t=220), where the fast oscillation shows as a strong line.
-- ---------------------------------------------------------------------------
SELECT fractal_periodogram(
           ARRAY_TO_STRING(ARRAY_AGG(CAST("conn_rate" AS VARCHAR), 16384), ',')) AS "periodogram"
FROM "vcy_conn_series" WHERE "t" >= 220;

SELECT fractal_json_value("periodogram", '$.freqs[0]') AS "dominant_freq",
       fractal_json_value("periodogram", '$.power[0]') AS "dominant_power"
FROM (SELECT fractal_periodogram(
              ARRAY_TO_STRING(ARRAY_AGG(CAST("conn_rate" AS VARCHAR), 16384), ',')) AS "periodogram"
      FROM "vcy_conn_series" WHERE "t" >= 220) p
GROUP BY "periodogram";

-- ---------------------------------------------------------------------------
-- 7. The track-anomaly reading: the nearest fleet host, how far the
-- movement was, and the connection-rate exponent.
-- ---------------------------------------------------------------------------
-- The track-anomaly reading would be the agent `track_anomaly`, given
-- the hosts table, the host-7 baseline and current vectors, and this
-- same connection-rate series as its heading series -- followed by a
-- one-line reading of the result.
--
-- (The agent is not called here: it wants a HEADING SERIES of state
-- vectors, and this kit's series is a single scalar per sample, so the
-- call would read the wrong column. The DFA exponent and the drift
-- above are the same reading, computed directly.)

-- ---------------------------------------------------------------------------
-- The headline.
--
-- The kit passes when the fleet is the size it claims to be and the
-- connection-rate regime really did change: the drift fired and the
-- recent exponent is below the historical one.
-- ---------------------------------------------------------------------------
SELECT CASE
           WHEN (SELECT COUNT(*) FROM "vcy_hosts") = 35
            AND ABS(fractal_json_value(
                    (SELECT fractal_dimension_drift(
                        ARRAY_TO_STRING(ARRAY_AGG(CAST("conn_rate" AS VARCHAR), 16384), ','), 64)
                     FROM "vcy_conn_series"),
                    '$.drift')) > 0.5
            AND fractal_json_value(
                    (SELECT fractal_dimension_drift(
                        ARRAY_TO_STRING(ARRAY_AGG(CAST("conn_rate" AS VARCHAR), 16384), ','), 64)
                     FROM "vcy_conn_series"),
                    '$.baseline_alpha')
                > fractal_json_value(
                    (SELECT fractal_dimension_drift(
                        ARRAY_TO_STRING(ARRAY_AGG(CAST("conn_rate" AS VARCHAR), 16384), ','), 64)
                     FROM "vcy_conn_series"),
                    '$.recent_alpha')
            THEN 'HEADLINE kit=cybersecurity-threat-detection ok'
            ELSE 'HEADLINE kit=cybersecurity-threat-detection FAILED'
       END AS "headline";
