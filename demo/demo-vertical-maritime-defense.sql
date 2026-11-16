-- demo/demo-vertical-maritime-defense.sql
--
-- FractalSQL for Apache Druid -- industry vertical: maritime defense.
-- Thirty vessels, each with a BASELINE track vector (their filed or
-- typical route) and a CURRENT one. Vessel 7 gets a deliberate large
-- deviation -- a course change and a speed drop, the classic "gone
-- dark then reappeared off track" pattern -- and everyone else's
-- current stays close to their baseline.
--
--   1. fractal_search_trajectory: current vs. baseline DELTA for the
--      flagged vessel -- which stored tracks does this deviation most
--      resemble? "What changed", not "what's closest".
--   2. fractal_search_telemetry / fractal_search_explore: the nearest
--      vessels to a contact position, and the fleet's diverse traffic
--      patterns.
--   3. fractal_dimension_dfa: maneuvering-pattern irregularity -- a
--      smooth transit heading series against vessel 7's erratic one.
--   4. fractal_agent_track_anomaly: the same reading, as one document.
--
-- Prerequisites: the extension is loaded on the Druid cluster. The agent's
-- rationale needs a reasoning provider (docs/reasoning-setup.md); every
-- other step runs with no model.
--
-- Run:
--   python3 demo/run_demo.py --file demo/demo-vertical-maritime-defense.sql
--
-- ===========================================================================
-- Notes on how this runs on Druid
-- ===========================================================================
--
--   * The vessels are an MSQ write: Druid has no DDL, no VALUES and no
--     recursive CTE, and random values are the deterministic sin-hash the other kits use.
--   * The heading series is a fixture: Druid has no window functions, and a fixture's
--     rows keep their order through the write and the scan, so the DFA
--     exponent still sees the walk in the right order.
--   * The searches and the agent are service calls: an agent reads a
--     table and reasons about it, and a Druid SQL function can do
--     neither.
--
-- Notes:
--   * Fully deterministic fixtures (no random()).

-- ---------------------------------------------------------------------------
-- 0. Sanity check: extension loaded?
-- ---------------------------------------------------------------------------
SELECT fractal_edition(), fractal_version();

-- ---------------------------------------------------------------------------
-- 1. Thirty vessels: baseline vs. current AIS track vectors.
--
-- The vector is [lat_norm, lon_norm, speed_norm, heading_norm]. The
-- current vector is the baseline plus transit noise; vessel 7's current
-- vector is its baseline shifted hard.
-- ---------------------------------------------------------------------------
-- @fixture vmd_vessels {"rows": [
--   {"id": 1, "mmsi": "MMSI-100000001", "baseline": "0.1144,1.1164,0.7475,0.9070", "current": "0.0984,1.1412,0.7791,0.9012"},
--   {"id": 2, "mmsi": "MMSI-100000002", "baseline": "1.1164,0.7475,0.9070,1.2522", "current": "1.1412,0.7633,0.9012,1.2949"},
--   {"id": 3, "mmsi": "MMSI-100000003", "baseline": "0.7475,0.9070,1.2522,0.3312", "current": "0.7633,0.9041,1.2949,0.3246"},
--   {"id": 4, "mmsi": "MMSI-100000004", "baseline": "0.9070,1.2522,0.3312,0.6582", "current": "0.9041,1.2735,0.3246,0.6726"},
--   {"id": 5, "mmsi": "MMSI-100000005", "baseline": "1.2522,0.3312,0.6582,1.0792", "current": "1.2735,0.3279,0.6726,1.0615"},
--   {"id": 6, "mmsi": "MMSI-100000006", "baseline": "0.3312,0.6582,1.0792,1.9430", "current": "0.3279,0.6654,1.0615,1.9690"},
--   {"id": 7, "mmsi": "MMSI-100000007", "baseline": "0.6582,1.0792,1.9430,1.6424", "current": "1.2582,0.5792,1.0430,2.4424"},
--   {"id": 8, "mmsi": "MMSI-100000008", "baseline": "1.0792,1.9430,1.6424,0.3581", "current": "1.0703,1.9560,1.6480,0.3742"},
--   {"id": 9, "mmsi": "MMSI-100000009", "baseline": "1.9430,1.6424,0.3581,1.9903", "current": "1.9560,1.6452,0.3742,1.9822"},
--   {"id": 10, "mmsi": "MMSI-100000010", "baseline": "1.6424,0.3581,1.9903,1.6321", "current": "1.6452,0.3661,1.9822,1.5957"},
--   {"id": 11, "mmsi": "MMSI-100000011", "baseline": "0.3581,1.9903,1.6321,0.8836", "current": "0.3661,1.9863,1.5957,0.8666"},
--   {"id": 12, "mmsi": "MMSI-100000012", "baseline": "1.9903,1.6321,0.8836,1.8538", "current": "1.9863,1.6139,0.8666,1.8533"},
--   {"id": 13, "mmsi": "MMSI-100000013", "baseline": "1.6321,0.8836,1.8538,0.8684", "current": "1.6139,0.8751,1.8533,0.8184"},
--   {"id": 14, "mmsi": "MMSI-100000014", "baseline": "0.8836,1.8538,0.8684,1.2884", "current": "0.8751,1.8536,0.8184,1.2546"},
--   {"id": 15, "mmsi": "MMSI-100000015", "baseline": "1.8538,0.8684,1.2884,0.6453", "current": "1.8536,0.8434,1.2546,0.6373"},
--   {"id": 16, "mmsi": "MMSI-100000016", "baseline": "0.8684,1.2884,0.6453,1.5208", "current": "0.8434,1.2715,0.6373,1.5693"},
--   {"id": 17, "mmsi": "MMSI-100000017", "baseline": "1.2884,0.6453,1.5208,1.1121", "current": "1.2715,0.6413,1.5693,1.1344"},
--   {"id": 18, "mmsi": "MMSI-100000018", "baseline": "0.6453,1.5208,1.1121,1.3218", "current": "0.6413,1.5451,1.1344,1.3004"},
--   {"id": 19, "mmsi": "MMSI-100000019", "baseline": "1.5208,1.1121,1.3218,0.8387", "current": "1.5451,1.1233,1.3004,0.8305"},
--   {"id": 20, "mmsi": "MMSI-100000020", "baseline": "1.1121,1.3218,0.8387,0.2715", "current": "1.1233,1.3111,0.8305,0.2416"},
--   {"id": 21, "mmsi": "MMSI-100000021", "baseline": "1.3218,0.8387,0.2715,0.6609", "current": "1.3111,0.8346,0.2416,0.6685"},
--   {"id": 22, "mmsi": "MMSI-100000022", "baseline": "0.8387,0.2715,0.6609,0.9906", "current": "0.8346,0.2565,0.6685,1.0388"},
--   {"id": 23, "mmsi": "MMSI-100000023", "baseline": "0.2715,0.6609,0.9906,0.0006", "current": "0.2565,0.6647,1.0388,0.0427"},
--   {"id": 24, "mmsi": "MMSI-100000024", "baseline": "0.6609,0.9906,0.0006,0.3238", "current": "0.6647,1.0147,0.0427,0.3208"},
--   {"id": 25, "mmsi": "MMSI-100000025", "baseline": "0.9906,0.0006,0.3238,0.8404", "current": "1.0147,0.0216,0.3208,0.8672"},
--   {"id": 26, "mmsi": "MMSI-100000026", "baseline": "0.0006,0.3238,0.8404,1.9702", "current": "0.0216,0.3223,0.8672,1.9799"},
--   {"id": 27, "mmsi": "MMSI-100000027", "baseline": "0.3238,0.8404,1.9702,1.4468", "current": "0.3223,0.8538,1.9799,1.4902"},
--   {"id": 28, "mmsi": "MMSI-100000028", "baseline": "0.8404,1.9702,1.4468,0.5714", "current": "0.8538,1.9750,1.4902,0.5667"},
--   {"id": 29, "mmsi": "MMSI-100000029", "baseline": "1.9702,1.4468,0.5714,0.8361", "current": "1.9750,1.4685,0.5667,0.8076"},
--   {"id": 30, "mmsi": "MMSI-100000030", "baseline": "1.4468,0.5714,0.8361,0.4012", "current": "1.4685,0.5691,0.8076,0.4207"}
-- ]};

-- ---------------------------------------------------------------------------
-- 2. Vessel 7's deviation against the fleet.
--
-- The baseline and the current vector are read out of the datasource,
-- because they are computed.
-- ---------------------------------------------------------------------------
REPLACE INTO vmd_v7 OVERWRITE ALL
SELECT "baseline", "current" FROM "vmd_vessels" WHERE "id" = 7
PARTITIONED BY ALL;

-- @call search/trajectory {"table": "vmd_vessels", "column": "current", "id_column": "id",
--                         "baseline_table": "vmd_v7", "baseline_column": "baseline",
--                         "current_table": "vmd_v7", "current_column": "current",
--                         "k": 5} AS vmd_traj;

SELECT r."doc_id" AS "id", v."mmsi" AS "mmsi", ROUND(r."distance", 4) AS "distance"
FROM "vmd_traj" r, "vmd_vessels" v
WHERE r."doc_id" = v."id";

-- ---------------------------------------------------------------------------
-- 3. The nearest vessels to a contact position, and the fleet's
-- diverse traffic patterns.
-- ---------------------------------------------------------------------------
-- @call search/telemetry {"table": "vmd_vessels", "column": "current", "id_column": "id",
--                        "query": "0.2,0.2,0.5,0.0", "k": 5} AS vmd_near;

SELECT r."doc_id" AS "id", v."mmsi" AS "mmsi", ROUND(r."distance", 4) AS "distance"
FROM "vmd_near" r, "vmd_vessels" v
WHERE r."doc_id" = v."id";

-- @call search/explore {"datasource": "vmd_vessels", "vectorColumn": "current",
--                      "idColumn": "id", "query": "0,0.2,0,0", "k": 6,
--                      "params": "{\"population_size\": 6, \"iterations\": 8}"} AS vmd_scout;

SELECT r."ord" AS "ord", v."mmsi" AS "mmsi"
FROM "vmd_scout" r, "vmd_vessels" v
WHERE r."doc_id" = v."id";

-- The same traffic patterns, scored by their closeness to the first
-- vessel's own current vector.
-- @call search/telemetry {"table": "vmd_vessels", "column": "current", "id_column": "id",
--                        "query_table": "vmd_vessels", "query_column": "current",
--                        "k": 6} AS vmd_rec;

SELECT r."doc_id" AS "item_id", v."mmsi" AS "mmsi", ROUND(1.0 - r."distance", 4) AS "score"
FROM "vmd_rec" r, "vmd_vessels" v
WHERE r."doc_id" = v."id";

-- ---------------------------------------------------------------------------
-- 4. fractal_dimension_dfa: maneuvering-pattern irregularity.
--
-- A smooth transit heading series (a vessel on a steady course) against
-- vessel 7's erratic one. The walks are fixtures: Druid has no window
-- functions, and a fixture's rows keep their order, so the exponent
-- still sees the walk in the right order.
-- ---------------------------------------------------------------------------
-- @fixture vmd_walk_smooth {"rows": [
--   {"t": 1, "s": -0.009629},
--   {"t": 2, "s": 0.005226},
--   {"t": 3, "s": 0.014707},
--   {"t": 4, "s": 0.012962},
--   {"t": 5, "s": 0.025768},
--   {"t": 6, "s": 0.023794},
--   {"t": 7, "s": 0.02812},
--   {"t": 8, "s": 0.022799},
--   {"t": 9, "s": 0.03061},
--   {"t": 10, "s": 0.032291},
--   {"t": 11, "s": 0.037117},
--   {"t": 12, "s": 0.034698},
--   {"t": 13, "s": 0.02377},
--   {"t": 14, "s": 0.018685},
--   {"t": 15, "s": 0.018544},
--   {"t": 16, "s": 0.003554},
--   {"t": 17, "s": -0.006589},
--   {"t": 18, "s": -0.008983},
--   {"t": 19, "s": 0.005569},
--   {"t": 20, "s": 0.012271},
--   {"t": 21, "s": 0.005843},
--   {"t": 22, "s": 0.003384},
--   {"t": 23, "s": -0.005598},
--   {"t": 24, "s": -0.003321},
--   {"t": 25, "s": 0.011125},
--   {"t": 26, "s": 0.023742},
--   {"t": 27, "s": 0.02285},
--   {"t": 28, "s": 0.030896},
--   {"t": 29, "s": 0.033796},
--   {"t": 30, "s": 0.046824},
--   {"t": 31, "s": 0.045417},
--   {"t": 32, "s": 0.036879},
--   {"t": 33, "s": 0.042721},
--   {"t": 34, "s": 0.0516},
--   {"t": 35, "s": 0.045096},
--   {"t": 36, "s": 0.045513},
--   {"t": 37, "s": 0.034789},
--   {"t": 38, "s": 0.02322},
--   {"t": 39, "s": 0.017286},
--   {"t": 40, "s": 0.005763},
--   {"t": 41, "s": 0.015123},
--   {"t": 42, "s": 0.01674},
--   {"t": 43, "s": 0.013879},
--   {"t": 44, "s": 0.025066},
--   {"t": 45, "s": 0.024306},
--   {"t": 46, "s": 0.016056},
--   {"t": 47, "s": 0.010336},
--   {"t": 48, "s": 0.000584},
--   {"t": 49, "s": -0.009322},
--   {"t": 50, "s": -0.021856},
--   {"t": 51, "s": -0.012529},
--   {"t": 52, "s": -0.027029},
--   {"t": 53, "s": -0.039387},
--   {"t": 54, "s": -0.052062},
--   {"t": 55, "s": -0.049133},
--   {"t": 56, "s": -0.056889},
--   {"t": 57, "s": -0.060247},
--   {"t": 58, "s": -0.065401},
--   {"t": 59, "s": -0.069366},
--   {"t": 60, "s": -0.069145},
--   {"t": 61, "s": -0.078947},
--   {"t": 62, "s": -0.09308},
--   {"t": 63, "s": -0.102372},
--   {"t": 64, "s": -0.099525},
--   {"t": 65, "s": -0.109902},
--   {"t": 66, "s": -0.104119},
--   {"t": 67, "s": -0.113594},
--   {"t": 68, "s": -0.127268},
--   {"t": 69, "s": -0.120252},
--   {"t": 70, "s": -0.122308},
--   {"t": 71, "s": -0.134622},
--   {"t": 72, "s": -0.141301},
--   {"t": 73, "s": -0.153479},
--   {"t": 74, "s": -0.157188},
--   {"t": 75, "s": -0.157644},
--   {"t": 76, "s": -0.161905},
--   {"t": 77, "s": -0.163581},
--   {"t": 78, "s": -0.15074},
--   {"t": 79, "s": -0.141277},
--   {"t": 80, "s": -0.152033},
--   {"t": 81, "s": -0.151142},
--   {"t": 82, "s": -0.144021},
--   {"t": 83, "s": -0.135593},
--   {"t": 84, "s": -0.128059},
--   {"t": 85, "s": -0.115222},
--   {"t": 86, "s": -0.125834},
--   {"t": 87, "s": -0.139161},
--   {"t": 88, "s": -0.139463},
--   {"t": 89, "s": -0.146539},
--   {"t": 90, "s": -0.133549},
--   {"t": 91, "s": -0.146181},
--   {"t": 92, "s": -0.156215},
--   {"t": 93, "s": -0.156288},
--   {"t": 94, "s": -0.144492},
--   {"t": 95, "s": -0.14918},
--   {"t": 96, "s": -0.147008},
--   {"t": 97, "s": -0.140502},
--   {"t": 98, "s": -0.127149},
--   {"t": 99, "s": -0.135904},
--   {"t": 100, "s": -0.131668},
--   {"t": 101, "s": -0.145256},
--   {"t": 102, "s": -0.159312},
--   {"t": 103, "s": -0.15933},
--   {"t": 104, "s": -0.160627},
--   {"t": 105, "s": -0.161599},
--   {"t": 106, "s": -0.149108},
--   {"t": 107, "s": -0.15206},
--   {"t": 108, "s": -0.137207},
--   {"t": 109, "s": -0.144169},
--   {"t": 110, "s": -0.136288},
--   {"t": 111, "s": -0.12207},
--   {"t": 112, "s": -0.133871},
--   {"t": 113, "s": -0.148839},
--   {"t": 114, "s": -0.141897},
--   {"t": 115, "s": -0.147713},
--   {"t": 116, "s": -0.156435},
--   {"t": 117, "s": -0.143404},
--   {"t": 118, "s": -0.150313},
--   {"t": 119, "s": -0.152323},
--   {"t": 120, "s": -0.142892}
-- ]};

-- @fixture vmd_walk_erratic {"rows": [
--   {"t": 1, "s": -0.010927},
--   {"t": 2, "s": -0.016013},
--   {"t": 3, "s": -0.016153},
--   {"t": 4, "s": -0.031144},
--   {"t": 5, "s": -0.041287},
--   {"t": 6, "s": -0.043681},
--   {"t": 7, "s": -0.029128},
--   {"t": 8, "s": -0.022426},
--   {"t": 9, "s": -0.028855},
--   {"t": 10, "s": -0.031314},
--   {"t": 11, "s": -0.040296},
--   {"t": 12, "s": -0.038018},
--   {"t": 13, "s": -0.023573},
--   {"t": 14, "s": -0.010955},
--   {"t": 15, "s": -0.011847},
--   {"t": 16, "s": -0.003801},
--   {"t": 17, "s": -0.000901},
--   {"t": 18, "s": 0.012127},
--   {"t": 19, "s": 0.010719},
--   {"t": 20, "s": 0.002182},
--   {"t": 21, "s": 0.008023},
--   {"t": 22, "s": 0.016903},
--   {"t": 23, "s": 0.010398},
--   {"t": 24, "s": 0.010815},
--   {"t": 25, "s": 9.1e-05},
--   {"t": 26, "s": -0.011477},
--   {"t": 27, "s": -0.017411},
--   {"t": 28, "s": -0.028935},
--   {"t": 29, "s": -0.019575},
--   {"t": 30, "s": -0.017958},
--   {"t": 31, "s": -0.020818},
--   {"t": 32, "s": -0.009631},
--   {"t": 33, "s": -0.010391},
--   {"t": 34, "s": -0.018642},
--   {"t": 35, "s": -0.024361},
--   {"t": 36, "s": -0.034114},
--   {"t": 37, "s": -0.044019},
--   {"t": 38, "s": -0.056554},
--   {"t": 39, "s": -0.047227},
--   {"t": 40, "s": -0.061727},
--   {"t": 41, "s": -0.074085},
--   {"t": 42, "s": -0.086759},
--   {"t": 43, "s": -0.083831},
--   {"t": 44, "s": -0.091586},
--   {"t": 45, "s": -0.094944},
--   {"t": 46, "s": -0.100099},
--   {"t": 47, "s": -0.104063},
--   {"t": 48, "s": -0.103842},
--   {"t": 49, "s": -0.113644},
--   {"t": 50, "s": -0.127778},
--   {"t": 51, "s": -0.13707},
--   {"t": 52, "s": -0.134223},
--   {"t": 53, "s": -0.144599},
--   {"t": 54, "s": -0.138816},
--   {"t": 55, "s": -0.148292},
--   {"t": 56, "s": -0.161966},
--   {"t": 57, "s": -0.15495},
--   {"t": 58, "s": -0.157006},
--   {"t": 59, "s": -0.16932},
--   {"t": 60, "s": -0.247238},
--   {"t": 61, "s": -0.389312},
--   {"t": 62, "s": -0.432587},
--   {"t": 63, "s": -0.437903},
--   {"t": 64, "s": -0.487616},
--   {"t": 65, "s": -0.507168},
--   {"t": 66, "s": -0.357358},
--   {"t": 67, "s": -0.246963},
--   {"t": 68, "s": -0.372451},
--   {"t": 69, "s": -0.362049},
--   {"t": 70, "s": -0.278972},
--   {"t": 71, "s": -0.180642},
--   {"t": 72, "s": -0.092753},
--   {"t": 73, "s": 0.057018},
--   {"t": 74, "s": -0.066795},
--   {"t": 75, "s": -0.222274},
--   {"t": 76, "s": -0.225798},
--   {"t": 77, "s": -0.30835},
--   {"t": 78, "s": -0.156803},
--   {"t": 79, "s": -0.304175},
--   {"t": 80, "s": -0.421238},
--   {"t": 81, "s": -0.422086},
--   {"t": 82, "s": -0.284467},
--   {"t": 83, "s": -0.339158},
--   {"t": 84, "s": -0.313818},
--   {"t": 85, "s": -0.237914},
--   {"t": 86, "s": -0.08213},
--   {"t": 87, "s": -0.184278},
--   {"t": 88, "s": -0.134859},
--   {"t": 89, "s": -0.293387},
--   {"t": 90, "s": -0.457366},
--   {"t": 91, "s": -0.457383},
--   {"t": 92, "s": -0.458681},
--   {"t": 93, "s": -0.459653},
--   {"t": 94, "s": -0.447162},
--   {"t": 95, "s": -0.450114},
--   {"t": 96, "s": -0.435261},
--   {"t": 97, "s": -0.442223},
--   {"t": 98, "s": -0.434342},
--   {"t": 99, "s": -0.420124},
--   {"t": 100, "s": -0.431925},
--   {"t": 101, "s": -0.446893},
--   {"t": 102, "s": -0.439951},
--   {"t": 103, "s": -0.445767},
--   {"t": 104, "s": -0.454489},
--   {"t": 105, "s": -0.441458},
--   {"t": 106, "s": -0.448367},
--   {"t": 107, "s": -0.450377},
--   {"t": 108, "s": -0.440946},
--   {"t": 109, "s": -0.432707},
--   {"t": 110, "s": -0.447153},
--   {"t": 111, "s": -0.445101},
--   {"t": 112, "s": -0.435629},
--   {"t": 113, "s": -0.446304},
--   {"t": 114, "s": -0.43707},
--   {"t": 115, "s": -0.427325},
--   {"t": 116, "s": -0.436442},
--   {"t": 117, "s": -0.438224},
--   {"t": 118, "s": -0.429997},
--   {"t": 119, "s": -0.421912},
--   {"t": 120, "s": -0.410935}
-- ]};

SELECT fractal_dimension_dfa(
           ARRAY_TO_STRING(ARRAY_AGG(CAST("s" AS VARCHAR), 16384), ',')) AS "normal_vessel_alpha"
FROM "vmd_walk_smooth";

SELECT fractal_dimension_dfa(
           ARRAY_TO_STRING(ARRAY_AGG(CAST("s" AS VARCHAR), 16384), ',')) AS "flagged_vessel_alpha"
FROM "vmd_walk_erratic";

-- ---------------------------------------------------------------------------
-- 5. fractal_agent_track_anomaly: the nearest fleet vessel, the
-- trajectory distance, the heading exponent and a rationale.
-- ---------------------------------------------------------------------------
-- @call agent/track_anomaly {"track_table": "vmd_vessels", "emb_col": "current",
--                           "baseline_vec_table": "vmd_v7", "baseline_vec_column": "baseline",
--                           "current_vec_table": "vmd_v7", "current_vec_column": "current",
--                           "heading_series_table": "vmd_walk_erratic",
--                           "heading_series_column": "s",
--                           "k": 5};

-- ---------------------------------------------------------------------------
-- 6. The headline.
--
-- The kit passes when the fleet is the size it claims to be and the
-- erratic vessel's heading walk really does have a different exponent
-- from the smooth one -- that difference IS the finding.
-- ---------------------------------------------------------------------------
SELECT CASE
           WHEN (SELECT COUNT(*) FROM "vmd_vessels") = 30
            AND (SELECT fractal_dimension_dfa(
                        ARRAY_TO_STRING(ARRAY_AGG(CAST("s" AS VARCHAR), 16384), ','))
                 FROM "vmd_walk_smooth") BETWEEN 1.60 AND 1.67
            AND (SELECT fractal_dimension_dfa(
                        ARRAY_TO_STRING(ARRAY_AGG(CAST("s" AS VARCHAR), 16384), ','))
                 FROM "vmd_walk_erratic") BETWEEN 1.24 AND 1.31
            THEN 'HEADLINE kit=maritime-defense ok'
            ELSE 'HEADLINE kit=maritime-defense FAILED'
       END AS "headline";
