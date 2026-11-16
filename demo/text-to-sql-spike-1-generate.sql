-- demo/text-to-sql-spike-1-generate.sql
--
-- Part 1 of 3 of the text-to-SQL validation spike: generate a
-- candidate statement for a question, with the configured model.
--
-- On Druid the generation is a service call -- it has to reach the
-- model and validate the answer against Druid's own parser -- and the
-- candidate lands in a datasource the next two parts read.
--
-- The question: for each service, show the count of alerts broken down
-- by severity level, but only include services that have logged at
-- least one critical-severity alert.
--
-- Run:
--   python3 demo/run_demo.py --file demo/text-to-sql-spike-1-generate.sql
--
-- Safe to re-run: the candidate is replaced each time.

-- ---------------------------------------------------------------------------
-- 0. Sanity check: extension loaded?
-- ---------------------------------------------------------------------------
SELECT fractal_edition(), fractal_version();

-- ---------------------------------------------------------------------------
-- 1. Generate the candidate.
--
-- The service validates the statement with EXPLAIN PLAN FOR before it
-- returns it, so a candidate that Druid cannot run never gets here.
-- ---------------------------------------------------------------------------
-- @call text-to-sql {"question": "for each service, show the count of alerts broken down by severity level, but only include services that have logged at least one critical-severity alert",
--                   "tables": ["demo_alerts"]} AS spike_candidates;

SELECT "generated_sql" AS "sql_text" FROM "spike_candidates";

-- ---------------------------------------------------------------------------
-- 2. The candidate, with the model that wrote it.
-- ---------------------------------------------------------------------------
SELECT fractal_config_get('reasoning_model', 'spike') AS "model",
       (SELECT "generated_sql" FROM "spike_candidates") AS "sql_text";

-- ---------------------------------------------------------------------------
-- 3. The headline.
--
-- The kit passes when the model produced a statement and the service
-- accepted it: the service validates the candidate with EXPLAIN PLAN
-- FOR before it returns it, so a statement Druid cannot run never
-- gets here.
-- ---------------------------------------------------------------------------
SELECT CASE
           WHEN (SELECT "generated_sql" FROM "spike_candidates") LIKE '%SELECT%'
            AND fractal_config_get('reasoning_model', 'spike') IS NOT NULL
            THEN 'HEADLINE kit=text-to-sql-spike-1-generate ok'
            ELSE 'HEADLINE kit=text-to-sql-spike-1-generate FAILED'
       END AS "headline";
