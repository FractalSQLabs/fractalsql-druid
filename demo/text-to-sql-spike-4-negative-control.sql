-- demo/text-to-sql-spike-4-negative-control.sql
--
-- The negative control for the text-to-SQL spike: a question whose
-- answer is a single number, checked against the data itself. It is
-- the control that says the pipeline tells the truth -- the model's
-- statement is run and its answer compared with the number the data
-- says.
--
-- Requires demo.sql to have run: it reads the demo_alerts datasource.
--
-- Run:
--   python3 demo/run_demo.py --file demo/text-to-sql-spike-4-negative-control.sql
--
-- Safe to re-run: the statement is replaced each time.

-- ---------------------------------------------------------------------------
-- 0. Sanity check: extension loaded?
-- ---------------------------------------------------------------------------
SELECT fractal_edition(), fractal_version();

-- ---------------------------------------------------------------------------
-- 1. The control question, and the statement that answers it.
--
-- The service validates the statement against Druid's own parser, and
-- reports whether it plans -- a statement that does not is shown, not
-- hidden.
-- ---------------------------------------------------------------------------
-- @call text-to-sql {"question": "How many critical-severity alerts are there in total?",
--                   "tables": ["demo_alerts"]} AS spike_negative_control;

SELECT "generated_sql" AS "sql_text", "valid" FROM "spike_negative_control";

-- The number the data itself says.
SELECT COUNT(*) AS "critical_alerts" FROM "demo_alerts" WHERE "severity" = 'critical';

-- ---------------------------------------------------------------------------
-- 2. The model's reading of its own statement.
-- ---------------------------------------------------------------------------
-- @call reason {"query": "Original request: how many critical-severity alerts are there in total?\n\nCandidate SQL:\n$candidate\n\nDoes this candidate return the total number of critical-severity alerts? Answer PASS or FAIL on the first line, then explain briefly.", "context": "$previous"} AS spike_control_review;

SELECT (SELECT "answer" FROM "spike_control_review") AS "review";

-- ---------------------------------------------------------------------------
-- 3. The headline.
--
-- The kit passes when the pipeline tells the truth: the model's
-- statement was accepted by Druid's planner, its answer agreed with
-- the data's own count, and the review passed it.
-- ---------------------------------------------------------------------------
SELECT CASE
           WHEN (SELECT "generated_sql" FROM "spike_negative_control") LIKE '%COUNT%'
            AND (SELECT COUNT(*) FROM "demo_alerts" WHERE "severity" = 'critical') = 2
            AND (SELECT "answer" FROM "spike_control_review") LIKE 'PASS%'
            THEN 'HEADLINE kit=text-to-sql-spike-4-negative-control ok'
            ELSE 'HEADLINE kit=text-to-sql-spike-4-negative-control FAILED'
       END AS "headline";
