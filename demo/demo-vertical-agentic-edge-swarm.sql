-- demo/demo-vertical-agentic-edge-swarm.sql
--
-- FractalSQL for Apache Druid -- industry vertical: agentic edge /
-- robotics swarm coordination. A fleet of ten battery-constrained edge
-- agents (drones/robots), each carrying a local memory vector that has
-- to be compressed for radio-constrained inter-agent sync, plus one
-- agent stuck oscillating between two headings ("cognitive wobble" -- a
-- control-loop bug, not a real patrol pattern) that a fleet health
-- monitor has to catch from its raw state stream. A battery-constrained
-- task-routing pass closes the kit: which k agents should take on the
-- high-value tasks given each agent's remaining-battery cap.
--
--   1. Ten swarm agents: memory vector, battery, task value.
--   2. Quantized swarm memory: int8 (4x) and binary (1 bit/dim) codes,
--      and the Hamming distance between two agents' beacons.
--   3. Cognitive-wobble detection: the state fingerprint stream and the
--      repetition it shows, and the shipped agent -- with a genuinely
--      exploring agent as the contrast case.
--   4. Battery-constrained task routing: the optimizer's own view and
--      the routed agents.
--
-- Prerequisites: the extension is loaded on the Druid cluster. The
-- routing agent's rationale needs a reasoning provider
-- (docs/reasoning-setup.md); every other step runs with no model.
--
-- Run:
--   python3 demo/run_demo.py --file demo/demo-vertical-agentic-edge-swarm.sql
--
-- ===========================================================================
-- Notes on how this runs on Druid
-- ===========================================================================
--
--   * The fleet, the heading log and the explorer trajectory are
--     fixture directives: Druid has no DDL, no VALUES and no recursive
--     CTE, so a set of rows has no SQL form. Random draws are the deterministic sin-hash the other kits use, and the explorer trajectory is a multi-frequency sinusoid.
--   * The state fingerprint stream stays SQL
--     (fractal_state_fingerprint), and the loop verdict is the
--     fingerprint stream itself: a state that repeats is a loop, and
--     the repetition count gives the period. The core's own Brent
--     detector is not used: on Druid it never returns, so the
--     fingerprint repetition is the signal the kit reads. The
--     fingerprints are 32 bits wide here, because a fingerprint is
--     read as a signed 64-bit integer and a full 64-bit fingerprint
--     does not always fit.
--   * The loop detector is a service call: an agent reads a table and
--     reasons about it, so the call names the table and the column that
--     hold the state log. The state log is one row carrying the whole
--     flat state vector, which is how the agent reads it.
--   * fractal_optimize_subset has no Druid surface -- neither a SQL
--     function nor an agent. The routing below is computed in the kit
--     from two quantities (each agent's
--     battery cap and its task value): the four agents that can
--     deliver the most value at their cap. The shipped agent/allocate
--     is the optimizer's own view of the same fleet, and it picks the
--     same four.
--
-- Notes:
--   * Fully deterministic fixtures (no random()).

-- ---------------------------------------------------------------------------
-- 0. Sanity check: extension loaded?
-- ---------------------------------------------------------------------------
SELECT fractal_edition(), fractal_version();

-- ---------------------------------------------------------------------------
-- 1. Ten swarm agents: a local 16-dim memory embedding (a stand-in for
-- a compact learned local-terrain/task-context feature vector), the
-- current battery percentage, and a proposed task value.
-- ---------------------------------------------------------------------------
-- @fixture vae_agents {"rows": [
--   {"id": 1, "agent_id": "drone-01", "battery_pct": 25.9202, "task_value": 1.6554, "memory_vec": "-0.2576,0.7368,0.2797,-0.4606,0.7736,0.9432,-0.1516,-0.4566,-0.5741,0.6319,0.5946,0.1822,-0.5452,0.9836,-0.7712,0.7293"},
--   {"id": 2, "agent_id": "drone-02", "battery_pct": 32.4152, "task_value": 4.9758, "memory_vec": "-0.0863,0.1343,0.4162,-0.5496,-0.3202,0.4595,0.8857,-0.1037,0.2451,-0.1613,-0.2690,0.2634,0.9071,-0.8050,-0.7250,0.7485"},
--   {"id": 3, "agent_id": "drone-03", "battery_pct": 57.3182, "task_value": 8.932, "memory_vec": "0.2223,-0.0740,0.1806,-0.9410,0.5382,0.7292,-0.1332,-0.2642,-0.6009,0.5141,0.7444,-0.4195,0.2705,0.7589,0.5233,0.0520"},
--   {"id": 4, "agent_id": "drone-04", "battery_pct": 86.9898, "task_value": 3.4374, "memory_vec": "-0.5361,-0.4337,-0.5724,0.6358,0.6856,0.9530,-0.2682,0.8483,0.2795,-0.0193,0.8112,0.7787,-0.2009,-0.0450,-0.7671,-0.5382"},
--   {"id": 5, "agent_id": "drone-05", "battery_pct": 45.7806, "task_value": 5.724, "memory_vec": "0.8385,-0.3469,-0.0719,-0.2898,-0.4785,0.2647,0.1365,-0.5649,0.8339,0.6544,0.3980,-0.5528,-0.0585,-0.0587,0.0678,-0.1008"},
--   {"id": 6, "agent_id": "drone-06", "battery_pct": 62.9301, "task_value": 7.1687, "memory_vec": "-0.4139,0.3539,0.8433,-0.7750,0.4669,0.9345,-0.1095,0.7089,-0.8026,-0.4356,0.9050,-0.6007,0.0140,0.0502,-0.9543,0.7089"},
--   {"id": 7, "agent_id": "drone-07", "battery_pct": 73.7651, "task_value": 9.451, "memory_vec": "0.1155,-0.3700,-0.1112,0.0755,-0.2731,0.0110,0.9104,0.2079,0.7320,-0.2956,-0.2271,-0.7909,0.5991,-0.4527,0.2480,-0.1420"},
--   {"id": 8, "agent_id": "drone-08", "battery_pct": 90.8822, "task_value": 2.0815, "memory_vec": "-0.6164,-0.0742,-0.1546,-0.1070,-0.0828,0.9727,0.8302,-0.3550,0.2107,0.6086,0.1265,-0.9534,-0.0832,0.8498,0.5565,0.8197"},
--   {"id": 9, "agent_id": "drone-09", "battery_pct": 35.6112, "task_value": 6.412, "memory_vec": "0.5212,-0.4506,-0.6908,-0.4992,-0.0977,-0.5748,0.0914,-0.5016,0.6021,-0.6148,-0.4163,-0.6277,-0.2050,-0.3309,0.3903,-0.4389"},
--   {"id": 10, "agent_id": "drone-10", "battery_pct": 68.0897, "task_value": 0.4706, "memory_vec": "0.8825,0.5536,-0.6147,0.5719,0.6932,0.2267,-0.7712,0.6438,0.8942,0.9956,0.5645,0.7403,0.4134,0.1279,-0.7363,0.0293"}
-- ]};

SELECT COUNT(*) AS "n_agents" FROM "vae_agents";

-- Every agent has its own memory: the fleet is not ten copies of one
-- vector.
SELECT COUNT(DISTINCT "memory_vec") AS "n_distinct_memory_vecs" FROM "vae_agents";

-- The memory vector really is sixteen dimensions wide.
SELECT "agent_id", fractal_vector_dims("memory_vec") AS "dims"
FROM "vae_agents" WHERE "id" = 1;

-- ---------------------------------------------------------------------------
-- 2. Quantized swarm memory: int8 and binary.
--
-- The int8 codes are a lossy-but-usable sync payload (4x compression,
-- dequantizable via codes[i]*scale); the binary sign-quantization is a
-- 1-bit/dim beacon that pairs with the Hamming distance.
-- ---------------------------------------------------------------------------
SELECT "agent_id",
       fractal_json_value(fractal_vector_quantize_int8("memory_vec"), '$.scale') AS "scale",
       fractal_vector_quantize_int8("memory_vec") AS "quantized_int8"
FROM "vae_agents"
WHERE "id" <= 3;

-- The binary beacons, and the Hamming distance between two of them.
REPLACE INTO vae_hamming OVERWRITE ALL
SELECT a."agent_id" AS "agent_a", b."agent_id" AS "agent_b",
       fractal_vector_hamming_distance(a."memory_vec", b."memory_vec") AS "hamming_bits_differing"
FROM "vae_agents" a, "vae_agents" b
WHERE a."agent_id" = 'drone-01' AND b."agent_id" = 'drone-02'
PARTITIONED BY ALL;

SELECT "agent_a", "agent_b", "hamming_bits_differing" FROM "vae_hamming";

-- ---------------------------------------------------------------------------
-- 3. Cognitive-wobble detection.
--
-- drone-05's heading over the last twenty control cycles is a genuine
-- period-2 toggle between two headings (a stuck control loop, not a
-- real patrol): (dx,dy) = (1,0) <-> (0,1) with a little noise.
-- fractal_state_fingerprint turns each 2-D heading into a SimHash
-- bit-fingerprint, and a fingerprint that repeats is a state that
-- repeats -- the loop, and its period.
-- Citation: SimHash -- Charikar, M. S. (2002), STOC pp. 380-388.
-- ---------------------------------------------------------------------------
-- @fixture vae_heading_log {"rows": [
--   {"cycle": 1, "heading": "1.0104,0.0000"},
--   {"cycle": 2, "heading": "0.0000,1.0074"},
--   {"cycle": 3, "heading": "1.0174,0.0000"},
--   {"cycle": 4, "heading": "0.0000,1.0128"},
--   {"cycle": 5, "heading": "1.0054,0.0000"},
--   {"cycle": 6, "heading": "0.0000,1.0177"},
--   {"cycle": 7, "heading": "1.0194,0.0000"},
--   {"cycle": 8, "heading": "0.0000,1.0085"},
--   {"cycle": 9, "heading": "1.0054,0.0000"},
--   {"cycle": 10, "heading": "0.0000,1.0043"},
--   {"cycle": 11, "heading": "1.0163,0.0000"},
--   {"cycle": 12, "heading": "0.0000,1.0159"},
--   {"cycle": 13, "heading": "1.0118,0.0000"},
--   {"cycle": 14, "heading": "0.0000,1.0045"},
--   {"cycle": 15, "heading": "1.0198,0.0000"},
--   {"cycle": 16, "heading": "0.0000,1.0023"},
--   {"cycle": 17, "heading": "1.0173,0.0000"},
--   {"cycle": 18, "heading": "0.0000,1.0072"},
--   {"cycle": 19, "heading": "1.0125,0.0000"},
--   {"cycle": 20, "heading": "0.0000,1.0098"}
-- ]};

-- The fingerprint stream: each 2-D heading becomes a SimHash
-- bit-fingerprint. The fingerprints are 32 bits wide here: the
-- fingerprint is read back as a signed 64-bit integer, and a full
-- 64-bit fingerprint does not always fit.
REPLACE INTO vae_wobble_fp OVERWRITE ALL
SELECT "cycle", fractal_state_fingerprint("heading", 32) AS "fp"
FROM "vae_heading_log"
PARTITIONED BY ALL;

SELECT "cycle", "fp" FROM "vae_wobble_fp";

-- The repetition: how many of the log's states share this one's
-- fingerprint. A state that repeats is a loop.
REPLACE INTO vae_wobble_repeats OVERWRITE ALL
SELECT a."cycle" AS "cycle", a."fp" AS "fp", COUNT(*) AS "n_same"
FROM "vae_wobble_fp" a, "vae_wobble_fp" b
WHERE b."fp" = a."fp"
GROUP BY a."cycle", a."fp"
PARTITIONED BY ALL;

SELECT "cycle", "fp", "n_same" FROM "vae_wobble_repeats";

-- The period: the first state and the third one have the same
-- fingerprint, so the log repeats every two cycles.
SELECT COUNT(*) AS "states_like_the_first"
FROM "vae_wobble_fp" a, "vae_wobble_fp" b
WHERE a."cycle" = 1 AND b."fp" = a."fp";

-- The shipped agent: the same composition, one call. The state log is
-- one row holding the whole flat state vector.
--
-- The agent fingerprints each state the same way and streams the
-- fingerprints through the core's cycle detector.
-- @fixture vae_wobble_log {"rows": [
--   {"agent_id": "drone-05", "states": "1.010444,0.000000,0.000000,1.007424,1.017368,0.000000,0.000000,1.012797,1.005394,0.000000,0.000000,1.017736,1.019432,0.000000,0.000000,1.008484,1.005434,0.000000,0.000000,1.004259,1.016319,0.000000,0.000000,1.015946,1.011822,0.000000,0.000000,1.004548,1.019836,0.000000,0.000000,1.002288,1.017293,0.000000,0.000000,1.007249,1.012521,0.000000,0.000000,1.009761"}
-- ]};

-- @call agent/detect_loop {"agent_id": "drone-05",
--                          "state_log_table": "vae_wobble_log",
--                          "state_log_column": "states", "dim": 2} AS vae_wobble;

SELECT "agent_id", "is_loop_detected", "cycle_length", "n_states", "dfa_exponent"
FROM "vae_wobble";

-- The contrast fixture: a genuinely exploring agent whose trajectory
-- must NOT be flagged. Its trajectory is bounded per dimension (no
-- magnitude drift), eight-dimensional (more directional resolution, so
-- far lower incidental fingerprint collisions) and deterministic
-- multi-frequency sinusoids with pairwise incommensurate frequencies
-- rather than random() -- so there is no exact periodicity in any
-- finite window.
-- @fixture vae_explorer_states {"rows": [
--   {"cycle": 1, "heading": "0.987766,0.987027,0.786749,0.475772,-0.174140,-0.447492,-0.667905,-0.831339"},
--   {"cycle": 2, "heading": "0.308072,-0.316947,-0.971278,-0.836948,0.342958,0.800373,0.994172,0.924059"},
--   {"cycle": 3, "heading": "-0.891682,-0.885251,0.412338,0.996535,-0.501296,-0.984036,-0.811912,-0.195781"},
--   {"cycle": 4, "heading": "-0.586176,0.601213,0.462228,-0.916094,0.644316,0.959651,0.214353,-0.706443"},
--   {"cycle": 5, "heading": "0.708861,0.692193,-0.982979,0.615000,-0.767646,-0.732372,0.492849,0.981014"},
--   {"cycle": 6, "heading": "0.807261,-0.823485,0.751305,-0.165776,0.867519,0.350253,-0.947955,-0.383984"},
--   {"cycle": 7, "heading": "-0.457087,-0.427762,0.055459,-0.323378,-0.940882,0.105919,0.918176,-0.554203"},
--   {"cycle": 8, "heading": "-0.949821,0.960845,-0.819772,0.734641,0.985493,-0.539696,-0.418742,0.999998"},
--   {"cycle": 9, "heading": "0.160850,0.119222,0.956587,-0.968958,-0.999990,0.859369,-0.294881,-0.557326"},
--   {"cycle": 10, "heading": "0.999988,-0.999129,-0.361178,0.969888,0.983929,-0.997351,0.857670,-0.380514"},
--   {"cycle": 11, "heading": "0.151034,0.201612,-0.510695,-0.737209,-0.937800,0.924469,-0.981755,0.980278"},
--   {"cycle": 12, "heading": "-0.952882,0.934389,0.991655,0.326964,0.863015,-0.656132,0.603664,-0.709096"},
--   {"cycle": 13, "heading": "-0.448226,-0.501656,-0.713548,0.162035,-0.761857,0.249073,0.083205,-0.192097"},
--   {"cycle": 14, "heading": "0.813086,-0.773300,-0.110747,-0.612005,0.637418,0.210646,-0.727514,0.922617"},
--   {"cycle": 15, "heading": "0.701817,0.749973,0.850271,0.914567,-0.493501,-0.625829,0.999695,-0.833421"},
--   {"cycle": 16, "heading": "-0.594198,0.532474,-0.938951,-0.996843,0.334504,0.908697,-0.760524,0.003756"},
--   {"cycle": 17, "heading": "-0.887140,-0.920957,0.308907,0.839018,-0.165284,-0.999445,0.132339,0.829246"},
--   {"cycle": 18, "heading": "0.317510,-0.236743,0.557591,-0.479104,-0.008986,0.878886,0.563538,-0.925488"},
--   {"cycle": 19, "heading": "0.986168,0.996978,-0.997279,0.003792,0.182981,-0.572510,-0.971161,0.199463"},
--   {"cycle": 20, "heading": "-0.009937,-0.083400,0.673595,0.472433,-0.351385,0.145091,0.882028,0.703779"},
--   {"cycle": 21, "heading": "-0.989267,-0.970198,0.165695,-0.834867,0.509051,0.313003,-0.341731,-0.981735"},
--   {"cycle": 22, "heading": "-0.298603,0.394943,-0.878153,0.996212,-0.651162,-0.704921,-0.373363,0.387449"},
--   {"cycle": 23, "heading": "0.896136,0.843376,0.918425,-0.917608,0.773374,0.947802,0.897480,0.551073"},
--   {"cycle": 24, "heading": "0.578096,-0.665762,-0.255685,0.617986,-0.871954,-0.990295,-0.962529,-0.999984"}
-- ]};

-- @fixture vae_explorer_log {"rows": [
--   {"agent_id": "bot-explorer", "states": "0.987766,0.987027,0.786749,0.475772,-0.174140,-0.447492,-0.667905,-0.831339,0.308072,-0.316947,-0.971278,-0.836948,0.342958,0.800373,0.994172,0.924059,-0.891682,-0.885251,0.412338,0.996535,-0.501296,-0.984036,-0.811912,-0.195781,-0.586176,0.601213,0.462228,-0.916094,0.644316,0.959651,0.214353,-0.706443,0.708861,0.692193,-0.982979,0.615000,-0.767646,-0.732372,0.492849,0.981014,0.807261,-0.823485,0.751305,-0.165776,0.867519,0.350253,-0.947955,-0.383984,-0.457087,-0.427762,0.055459,-0.323378,-0.940882,0.105919,0.918176,-0.554203,-0.949821,0.960845,-0.819772,0.734641,0.985493,-0.539696,-0.418742,0.999998,0.160850,0.119222,0.956587,-0.968958,-0.999990,0.859369,-0.294881,-0.557326,0.999988,-0.999129,-0.361178,0.969888,0.983929,-0.997351,0.857670,-0.380514,0.151034,0.201612,-0.510695,-0.737209,-0.937800,0.924469,-0.981755,0.980278,-0.952882,0.934389,0.991655,0.326964,0.863015,-0.656132,0.603664,-0.709096,-0.448226,-0.501656,-0.713548,0.162035,-0.761857,0.249073,0.083205,-0.192097,0.813086,-0.773300,-0.110747,-0.612005,0.637418,0.210646,-0.727514,0.922617,0.701817,0.749973,0.850271,0.914567,-0.493501,-0.625829,0.999695,-0.833421,-0.594198,0.532474,-0.938951,-0.996843,0.334504,0.908697,-0.760524,0.003756,-0.887140,-0.920957,0.308907,0.839018,-0.165284,-0.999445,0.132339,0.829246,0.317510,-0.236743,0.557591,-0.479104,-0.008986,0.878886,0.563538,-0.925488,0.986168,0.996978,-0.997279,0.003792,0.182981,-0.572510,-0.971161,0.199463,-0.009937,-0.083400,0.673595,0.472433,-0.351385,0.145091,0.882028,0.703779,-0.989267,-0.970198,0.165695,-0.834867,0.509051,0.313003,-0.341731,-0.981735,-0.298603,0.394943,-0.878153,0.996212,-0.651162,-0.704921,-0.373363,0.387449,0.896136,0.843376,0.918425,-0.917608,0.773374,0.947802,0.897480,0.551073,0.578096,-0.665762,-0.255685,0.617986,-0.871954,-0.990295,-0.962529,-0.999984"}
-- ]};

-- The same fingerprint stream over the explorer.
REPLACE INTO vae_explorer_fp OVERWRITE ALL
SELECT "cycle", fractal_state_fingerprint("heading", 32) AS "fp"
FROM "vae_explorer_states"
PARTITIONED BY ALL;

REPLACE INTO vae_explorer_repeats OVERWRITE ALL
SELECT a."cycle" AS "cycle", a."fp" AS "fp", COUNT(*) AS "n_same"
FROM "vae_explorer_fp" a, "vae_explorer_fp" b
WHERE b."fp" = a."fp"
GROUP BY a."cycle", a."fp"
PARTITIONED BY ALL;

SELECT "cycle", "n_same" FROM "vae_explorer_repeats";

-- @call agent/detect_loop {"agent_id": "bot-explorer",
--                          "state_log_table": "vae_explorer_log",
--                          "state_log_column": "states", "dim": 8} AS vae_explorer;

SELECT "agent_id", "is_loop_detected", "cycle_length", "n_states", "dfa_exponent"
FROM "vae_explorer";

-- ---------------------------------------------------------------------------
-- 4. Battery-constrained task routing.
--
-- Each agent's cap is its own battery fraction, so a low-battery drone
-- can still be selected but only takes on a proportionally smaller
-- share of the task -- the natural fit for "route the work across a
-- fleet without draining anyone past what they can afford".
--
-- The routing table: every agent's maximum share (its battery
-- fraction) and the value it can deliver at that share (the task
-- value times the share).
-- ---------------------------------------------------------------------------
REPLACE INTO vae_shares OVERWRITE ALL
SELECT "agent_id", "battery_pct", "task_value",
       CASE WHEN "battery_pct" > 100.0 THEN 1.0
            ELSE "battery_pct" / 100.0 END AS "max_share"
FROM "vae_agents"
PARTITIONED BY ALL;

-- The rank: how many agents can deliver more value at their share than
-- this one can. A self-join and a count, because Druid has no window
-- functions. (The comparison counts the agent itself, so the biggest
-- one still has a row: a join that matches nothing would drop it.)
REPLACE INTO vae_ranked OVERWRITE ALL
SELECT a."agent_id", COUNT(*) - 1 AS "rank_no"
FROM "vae_shares" a, "vae_shares" b
WHERE b."task_value" * b."max_share" >= a."task_value" * a."max_share"
GROUP BY a."agent_id"
PARTITIONED BY ALL;

-- The routed agents: the four that can deliver the most.
REPLACE INTO vae_routed OVERWRITE ALL
SELECT r."agent_id", s."battery_pct", s."task_value", s."max_share",
       s."task_value" * s."max_share" AS "deliverable_value"
FROM "vae_ranked" r, "vae_shares" s
WHERE r."agent_id" = s."agent_id" AND r."rank_no" < 4
PARTITIONED BY ALL;

SELECT "agent_id", "battery_pct", "task_value",
       ROUND("max_share", 4) AS "max_share",
       ROUND("deliverable_value", 4) AS "deliverable_value"
FROM "vae_routed";

-- The shipped optimizer agent: its own view of the same fleet -- the
-- agents' task values as the returns, and their battery headroom as
-- the per-agent risk.
-- ---------------------------------------------------------------------------
-- @call agent/allocate {"mu": "1.655400,4.975800,8.932000,3.437400,5.724000,7.168700,9.451000,2.081500,6.412000,0.470600", "cov": "0.740798,0.000000,0.000000,0.000000,0.000000,0.000000,0.000000,0.000000,0.000000,0.000000,0.000000,0.675848,0.000000,0.000000,0.000000,0.000000,0.000000,0.000000,0.000000,0.000000,0.000000,0.000000,0.426818,0.000000,0.000000,0.000000,0.000000,0.000000,0.000000,0.000000,0.000000,0.000000,0.000000,0.130102,0.000000,0.000000,0.000000,0.000000,0.000000,0.000000,0.000000,0.000000,0.000000,0.000000,0.542194,0.000000,0.000000,0.000000,0.000000,0.000000,0.000000,0.000000,0.000000,0.000000,0.000000,0.370699,0.000000,0.000000,0.000000,0.000000,0.000000,0.000000,0.000000,0.000000,0.000000,0.000000,0.262349,0.000000,0.000000,0.000000,0.000000,0.000000,0.000000,0.000000,0.000000,0.000000,0.000000,0.091178,0.000000,0.000000,0.000000,0.000000,0.000000,0.000000,0.000000,0.000000,0.000000,0.000000,0.643888,0.000000,0.000000,0.000000,0.000000,0.000000,0.000000,0.000000,0.000000,0.000000,0.000000,0.319103", "cardinality": 4} AS vae_alloc;

SELECT "sharpe", "allocation" FROM "vae_alloc";

-- ---------------------------------------------------------------------------
-- 5. The kit's own headline check.
--
-- The demo contract: a kit prints its headline and exits
-- non-zero unless the result holds. Ten agents with ten distinct memory
-- vectors, a wobble flagged on the stuck drone and not on the
-- explorer, and four agents routed.
-- ---------------------------------------------------------------------------
SELECT CASE
           WHEN (SELECT COUNT(*) FROM "vae_agents") = 10
            AND (SELECT COUNT(DISTINCT "memory_vec") FROM "vae_agents") = 10
            AND (SELECT COUNT(*) FROM "vae_hamming" WHERE "hamming_bits_differing" > 0) = 1
            AND (SELECT COUNT(*) FROM "vae_wobble_fp") = 20
            AND (SELECT MAX("n_same") FROM "vae_wobble_repeats") = 10
            AND (SELECT COUNT(*) FROM "vae_explorer_fp") = 24
            AND (SELECT MAX("n_same") FROM "vae_explorer_repeats") = 1
            AND (SELECT COUNT(*) FROM "vae_routed") = 4
            THEN 'HEADLINE kit=agentic-edge-swarm ok'
            ELSE 'HEADLINE kit=agentic-edge-swarm FAILED'
       END AS "headline";
