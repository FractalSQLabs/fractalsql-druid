-- demo/demo-vertical-telecom-traffic-routing.sql
--
-- FractalSQL for Apache Druid -- industry vertical: telecom traffic
-- routing. Four edge nodes with different capability profiles and five
-- incoming session requests. The router sends each request to the node
-- whose capabilities are nearest its need; a second pass routes only
-- over the nodes with headroom, which re-homes one request.
--
--   1. The nodes and the incoming requests.
--   2. The dispatch: the nearest capable node per request.
--   3. fractal_agent_route_task: the same routing, with a rationale.
--   4. Load awareness: route over the nodes with headroom.
--   5. Reasoning: the dispatch summary.
--
-- Prerequisites: the extension is loaded on the Druid cluster. The agent's
-- rationale and the closing narrative need a reasoning provider
-- (docs/reasoning-setup.md); every other step runs with no model.
--
-- Run:
--   python3 demo/run_demo.py --file demo/demo-vertical-telecom-traffic-routing.sql
--
-- ===========================================================================
-- Notes on how this runs on Druid
-- ===========================================================================
--
--   * The fixtures are @fixture directives: Druid has no DDL and no
--     VALUES, so a set of rows has no SQL form.
--   * The routing is one service call over the whole table of
--     requests: an agent reads a table and reasons about it, and a
--     Druid SQL function can do neither.
--
-- Notes:
--   * Fully deterministic fixtures (no random()).

-- ---------------------------------------------------------------------------
-- 0. Sanity check: extension loaded?
-- ---------------------------------------------------------------------------
SELECT fractal_edition(), fractal_version();

-- ---------------------------------------------------------------------------
-- 1. Nodes and incoming requests.
--
-- The capability vector is [bulk bandwidth, low latency, mobility
-- tolerance, east-region affinity].
-- ---------------------------------------------------------------------------
-- @fixture ttr_nodes {"rows": [
--   {"id": 1, "node": "edge-core-east", "capacity": 400, "load": 120, "caps": "0.95,0.20,0.10,0.90"},
--   {"id": 2, "node": "edge-lowlat-west", "capacity": 150, "load": 60, "caps": "0.30,0.95,0.15,0.10"},
--   {"id": 3, "node": "edge-mobile-hub", "capacity": 250, "load": 200, "caps": "0.50,0.50,0.85,0.50"},
--   {"id": 4, "node": "edge-backup-west", "capacity": 200, "load": 20, "caps": "0.55,0.55,0.40,0.15"}
-- ]};

-- @fixture ttr_requests {"rows": [
--   {"id": 1, "label": "R1 bulk video backhaul, east", "need": "0.90,0.15,0.10,0.85"},
--   {"id": 2, "label": "R2 cloud-gaming session, west", "need": "0.35,0.92,0.12,0.12"},
--   {"id": 3, "label": "R3 mobile handover burst", "need": "0.45,0.50,0.88,0.45"},
--   {"id": 4, "label": "R4 enterprise VPN, west", "need": "0.50,0.60,0.30,0.12"},
--   {"id": 5, "label": "R5 software update fan-out, east", "need": "0.92,0.10,0.20,0.88"}
-- ]};

SELECT "node", "capacity", "load",
       ROUND(100.0 * "load" / "capacity") AS "pct_loaded"
FROM "ttr_nodes";

-- ---------------------------------------------------------------------------
-- 2. The dispatch: the nearest capable node per request.
--
-- One call covers the whole table of requests; the result is one row
-- per request, with the node it went to and the confidence
-- (1/(1+distance)).
-- ---------------------------------------------------------------------------
-- @call agent/route_task {"task_table": "ttr_requests", "task_column": "need",
--                         "task_id_column": "id",
--                         "cap_table": "ttr_nodes", "cap_emb_col": "caps",
--                         "cap_id_col": "node", "budget": 1000} AS ttr_routed;

SELECT q."label" AS "label", r."routed_to" AS "routed_to",
       ROUND(r."confidence", 4) AS "confidence"
FROM "ttr_routed" r, "ttr_requests" q
WHERE r."req_id" = q."id";

-- ---------------------------------------------------------------------------
-- 3. fractal_agent_route_task: the same routing, with a rationale.
-- ---------------------------------------------------------------------------
-- @call agent/route_task {"task_table": "ttr_requests", "task_column": "need",
--                         "task_id_column": "id",
--                         "cap_table": "ttr_nodes", "cap_emb_col": "caps",
--                         "cap_id_col": "node", "budget": 1000} AS ttr_routed_agent;

-- ---------------------------------------------------------------------------
-- 4. Load awareness: edge-mobile-hub is at 80% load. Route over only
-- the nodes with headroom (below 75% loaded) and R3 is re-homed.
-- ---------------------------------------------------------------------------
REPLACE INTO ttr_available OVERWRITE ALL
SELECT "node", "caps" FROM "ttr_nodes"
WHERE 100.0 * "load" / "capacity" < 75
PARTITIONED BY ALL;

-- @call agent/route_task {"task_table": "ttr_requests", "task_column": "need",
--                         "task_id_column": "id",
--                         "cap_table": "ttr_available", "cap_emb_col": "caps",
--                         "cap_id_col": "node", "budget": 1000} AS ttr_routed_free;

SELECT q."label" AS "label", r."routed_to" AS "routed_to"
FROM "ttr_routed_free" r, "ttr_requests" q
WHERE r."req_id" = q."id";

-- ---------------------------------------------------------------------------
-- 5. Reasoning: the dispatch summary.
--
-- The context is the routing the previous step returned.
-- ---------------------------------------------------------------------------
-- @call reason {"query": "one-line summary of how these session requests were dispatched and why one was re-homed",
--               "context": "$previous"};

-- ---------------------------------------------------------------------------
-- The headline.
--
-- The kit passes when all five sessions were routed, the loaded hub was
-- taken out of the pool, and R3 -- the session that had been going to
-- it -- was re-homed. The re-homing IS the finding.
-- ---------------------------------------------------------------------------
SELECT CASE
           WHEN (SELECT COUNT(*) FROM "ttr_nodes") = 4
            AND (SELECT COUNT(*) FROM "ttr_requests") = 5
            AND (SELECT COUNT(*) FROM "ttr_routed" r, "ttr_requests" q
                 WHERE r."req_id" = q."id") = 5
            AND (SELECT COUNT(*) FROM "ttr_available") = 3
            AND (SELECT COUNT(*) FROM "ttr_routed_free" r, "ttr_requests" q
                 WHERE r."req_id" = q."id" AND r."routed_to" = 'edge-mobile-hub') = 0
            THEN 'HEADLINE kit=telecom-traffic-routing ok'
            ELSE 'HEADLINE kit=telecom-traffic-routing FAILED'
       END AS "headline";
