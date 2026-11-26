-- demo/demo.sql
--
-- FractalSQL basic demo (Druid edition): Sniper/Scout search feeding
-- LLM reasoning.
--
-- Prerequisites (see demo/README.md for the full walkthrough):
--   1. The extension is loaded into Druid (druid.extensions.loadList),
--      and the demo stack is up:
--         docker compose -f docker/docker-compose.yml up -d
--   2. Reasoning configured -- see ../docs/reasoning-setup.md. The
--      settings are operator keys in the node's runtime properties
--      (druid.fractalsql.*); a request cannot change them.
--
-- Run:
--   python3 demo/run_demo.py --file demo/demo.sql
--
-- Safe to re-run: each fixture replaces its datasource's data.
--
-- ===========================================================================
-- Notes on how this runs on Druid
-- ===========================================================================
--
--   * A fixture is a @fixture directive, not CREATE TABLE + INSERT.
--     Druid has no DDL, no VALUES and no UNNEST ordinality, so a
--     multi-column fixture has no SQL form -- the ingestion path takes
--     real rows, which is what a fixture is. A timestamp of "now-55m"
--     is resolved when the fixture is written.
--   * The corpus step (Scout) is a @call: it reads a whole column and
--     converges over it, which is a service operation rather than a
--     SQL function. "$previous" splices one step's result into the
--     next.
--   * ORDER BY is only available on __time in a non-aggregating query,
--     so the ordering is expressed as an aggregation where it matters.

-- ---------------------------------------------------------------------------
-- 0. Sanity check: is the extension loaded?
-- ---------------------------------------------------------------------------
SELECT fractal_edition(), fractal_version();

-- ---------------------------------------------------------------------------
-- 1. A small alerts table with something worth noticing.
--
-- The latency alert on api-gateway escalates from ~250ms to ~4000ms, and
-- the auth-service sees a burst of failed logins. That is what the model
-- is asked to summarise in section 3.
-- ---------------------------------------------------------------------------
-- @fixture demo_alerts {"rows": [
--   {"ts": "now-55m", "service": "api-gateway",  "message": "request latency p99 245ms",              "severity": "info"},
--   {"ts": "now-50m", "service": "api-gateway",  "message": "request latency p99 260ms",              "severity": "info"},
--   {"ts": "now-45m", "service": "payments",     "message": "transaction processed successfully",     "severity": "info"},
--   {"ts": "now-40m", "service": "payments",     "message": "transaction processed successfully",     "severity": "info"},
--   {"ts": "now-30m", "service": "auth-service", "message": "3 failed login attempts, user_id=8821",  "severity": "warning"},
--   {"ts": "now-29m", "service": "auth-service", "message": "3 failed login attempts, user_id=8821",  "severity": "warning"},
--   {"ts": "now-28m", "service": "auth-service", "message": "17 failed login attempts, user_id=8821", "severity": "warning"},
--   {"ts": "now-20m", "service": "payments",     "message": "transaction processed successfully",     "severity": "info"},
--   {"ts": "now-10m", "service": "api-gateway",  "message": "request latency p99 4200ms",              "severity": "critical"},
--   {"ts": "now-9m",  "service": "api-gateway",  "message": "request latency p99 3900ms",              "severity": "critical"}
-- ]};

SELECT "service", "severity", COUNT(*) AS "n"
FROM "demo_alerts"
GROUP BY "service", "severity"
ORDER BY "service";

-- ---------------------------------------------------------------------------
-- 2. Sniper Search: converge to a single best point.
--
-- fractal_search is a Druid aggregate over a stored vector column: it
-- converges each stored vector toward the query point and reports the
-- cosine distance. One group per row, so the distances come back per
-- row and can be ranked.
-- ---------------------------------------------------------------------------
-- @fixture demo_points {"rows": [
--   {"ts": "now", "label": "a", "pt": "[0.6,0.8,0.0]"},
--   {"ts": "now", "label": "b", "pt": "[0.1,0.2,0.0]"},
--   {"ts": "now", "label": "c", "pt": "[-0.9,0.4,0.0]"},
--   {"ts": "now", "label": "d", "pt": "[0.0,0.0,1.0]"}
-- ]};

SELECT "label", fractal_search_distance("pt", '0.6,0.8,0.0') AS "dist"
FROM "demo_points"
GROUP BY "label"
ORDER BY "dist" ASC
LIMIT 3;

-- ---------------------------------------------------------------------------
-- 3. Ask the LLM to analyse the alerts table (real context, not a bare
--    ping).
--
-- The context is the alerts of the last hour, as a JSON array.
-- ---------------------------------------------------------------------------
SELECT fractal_reason(
    'summarize what happened in the last hour and flag anything that needs attention',
    '[' || ARRAY_TO_STRING(ARRAY_AGG(
        '{"service":"' || "service" ||
        '","message":"' || "message" ||
        '","severity":"' || "severity" || '"}', 8192), ',') || ']') AS "summary"
FROM "demo_alerts"
WHERE "__time" > CURRENT_TIMESTAMP - INTERVAL '1' HOUR;

-- ---------------------------------------------------------------------------
-- 4. Scout Discovery feeding reasoning: search + reason in one pipeline.
--
-- The corpus step reads a whole column and converges over it -- a
-- service operation, not a SQL function, because Druid has no way to
-- materialise a whole column inside one expression. The result is fed
-- into the reasoning step with "$previous".
-- ---------------------------------------------------------------------------
-- @fixture demo_embedding_points {"rows": [
--   {"ts": "now", "emb": "[0.31,0.62,-0.72]"},
--   {"ts": "now", "emb": "[-0.85,0.11,0.51]"},
--   {"ts": "now", "emb": "[0.14,-0.93,0.34]"},
--   {"ts": "now", "emb": "[0.62,0.08,-0.78]"},
--   {"ts": "now", "emb": "[-0.41,0.77,0.49]"},
--   {"ts": "now", "emb": "[0.09,0.51,-0.86]"},
--   {"ts": "now", "emb": "[-0.72,-0.36,0.59]"},
--   {"ts": "now", "emb": "[0.55,0.81,0.19]"},
--   {"ts": "now", "emb": "[-0.27,0.44,0.85]"},
--   {"ts": "now", "emb": "[0.88,-0.22,0.41]"},
--   {"ts": "now", "emb": "[-0.58,0.69,-0.44]"},
--   {"ts": "now", "emb": "[0.33,0.29,0.90]"}
-- ]};

-- @call search/explore {"datasource": "demo_embedding_points", "vectorColumn": "emb",
--                      "query": "[0.0,0.0,0.0]", "k": 10,
--                      "params": "{\"population_size\": 10, \"iterations\": 8}"};

-- @call reason {"query": "these are points from a 3D embedding space sampled by Scout Discovery -- describe the spread",
--               "context": "$previous"};

-- ---------------------------------------------------------------------------
-- 5. The kit's own headline check.
--
-- The demo contract: a kit prints its headline and exits
-- non-zero unless the result holds. Sniper must rank the point that
-- IS the query at distance zero, and Scout must have found a
-- population -- several distinct points, not one.
-- ---------------------------------------------------------------------------
-- The search aggregate reads the vector column from the scan, so it
-- has to sit at the top level of the query: inside a subquery its
-- input is the group-key set, and the column is not there to read.
-- ORDER BY the same aggregate picks the closest group, and the CASE
-- says whether that group is at distance zero.
SELECT CASE
           WHEN fractal_search_distance("pt", '0.6,0.8,0.0') < 0.0001
            THEN 'HEADLINE kit=demo ok'
            ELSE 'HEADLINE kit=demo FAILED'
       END AS "headline"
FROM "demo_points"
GROUP BY "label"
ORDER BY fractal_search_distance("pt", '0.6,0.8,0.0') ASC
LIMIT 1;
