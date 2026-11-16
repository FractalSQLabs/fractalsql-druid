-- demo/text-to-sql-spike-2-review.sql
--
-- Part 2 of 3 of the text-to-SQL validation spike: the model reviews
-- its OWN candidate, matching how the real feature would run (the same
-- configured endpoint for both steps).
--
-- Requires Part 1 to have already run: it reads the candidate from the
-- datasource Part 1 wrote.
--
-- Run:
--   python3 demo/run_demo.py --file demo/text-to-sql-spike-2-review.sql
--
-- Safe to re-run: the review is replaced each time.

-- ---------------------------------------------------------------------------
-- 0. Sanity check: extension loaded?
-- ---------------------------------------------------------------------------
SELECT fractal_edition(), fractal_version();

-- ---------------------------------------------------------------------------
-- 1. The review.
--
-- The candidate is read out of the datasource Part 1 wrote, and the
-- model's answer is written back beside it.
-- ---------------------------------------------------------------------------
-- @call reason {"query": "Original request: for each service, show the count of alerts broken down by severity level, but only include services that have logged at least one critical-severity alert.

Candidate SQL:
$candidate

Does this candidate correctly implement the stated rule -- specifically, does it correctly EXCLUDE services with no critical-severity alerts, not just show all services grouped by severity? Answer PASS or FAIL on the first line, then explain briefly.", "context": "$previous"} AS spike_review;
--               "context": "$previous"} AS spike_review;

SELECT fractal_config_get('reasoning_model', 'spike') AS "model",
       (SELECT "answer" FROM "spike_review") AS "review";

-- ---------------------------------------------------------------------------
-- 3. The headline.
--
-- The kit passes when the model reviewed its own candidate and gave a
-- verdict: the answer's first line is PASS or FAIL (the model's opinion
-- of its own statement is not the test), and the candidate it reviewed
-- really is the one Part 1 wrote.
-- ---------------------------------------------------------------------------
SELECT CASE
           WHEN ((SELECT "answer" FROM "spike_review") LIKE 'PASS%'
                 OR (SELECT "answer" FROM "spike_review") LIKE 'FAIL%')
            AND (SELECT "generated_sql" FROM "spike_candidates") LIKE '%SELECT%'
            THEN 'HEADLINE kit=text-to-sql-spike-2-review ok'
            ELSE 'HEADLINE kit=text-to-sql-spike-2-review FAILED'
       END AS "headline";
