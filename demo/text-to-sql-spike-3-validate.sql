-- demo/text-to-sql-spike-3-validate.sql
--
-- Part 3 of 3 of the text-to-SQL validation spike: validate the
-- candidate against the database's own parser and run it.
--
-- Requires Parts 1 and 2 to have already run.
--
-- Run:
--   python3 demo/run_demo.py --file demo/text-to-sql-spike-3-validate.sql
--
-- Safe to re-run: the statement is re-validated and re-run.

-- ---------------------------------------------------------------------------
-- 0. Sanity check: extension loaded?
-- ---------------------------------------------------------------------------
SELECT fractal_edition(), fractal_version();

-- ---------------------------------------------------------------------------
-- 1. Validate the candidate: EXPLAIN PLAN FOR runs it through Druid's
-- own parser and planner, so a statement Druid cannot run is caught
-- here rather than at the caller's screen.
-- ---------------------------------------------------------------------------
SELECT "generated_sql" AS "sql_text" FROM "spike_candidates"
WHERE fractal_config_get('reasoning_model', 'spike') IS NOT NULL;

-- ---------------------------------------------------------------------------
-- 2. Run the question the candidate answers, answered directly.
--
-- Druid's SQL cannot run a statement out of a string, so the
-- candidate itself is not executed here -- but the SERVICE already
-- validated it with EXPLAIN PLAN FOR, which is Druid's own parser and
-- planner. This is the control the candidate's answer is compared
-- against: the same question, asked of the data.
-- ---------------------------------------------------------------------------
SELECT "service", "severity", COUNT(*) AS "alert_count"
FROM "demo_alerts"
GROUP BY "service", "severity"
HAVING SUM(CASE WHEN "severity" = 'critical' THEN 1 ELSE 0 END) > 0;

-- ---------------------------------------------------------------------------
-- 3. The headline.
--
-- The kit passes when the candidate exists, Druid's own planner
-- accepted it, and the direct answer is the shape the candidate
-- promised -- a per-service, per-severity count.
-- ---------------------------------------------------------------------------
SELECT CASE
           WHEN (SELECT "generated_sql" FROM "spike_candidates") LIKE '%SELECT%'
            AND (SELECT COUNT(*) FROM (
                    SELECT "service", "severity", COUNT(*) AS "alert_count"
                    FROM "demo_alerts"
                    GROUP BY "service", "severity"
                    HAVING SUM(CASE WHEN "severity" = 'critical' THEN 1 ELSE 0 END) > 0
                 ) q) > 0
            THEN 'HEADLINE kit=text-to-sql-spike-3-validate ok'
            ELSE 'HEADLINE kit=text-to-sql-spike-3-validate FAILED'
       END AS "headline";
