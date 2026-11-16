-- demo/response-modes.sql
--
-- FractalSQL reasoning response modes: text | code | json.
--
-- Prerequisites:
--   1. Run demo.sql first -- this reuses its demo_alerts datasource.
--   2. Reasoning already configured per ../docs/reasoning-setup.md.
--
-- Run:
--   python3 demo/run_demo.py --file demo/response-modes.sql
--
-- ===========================================================================
-- How the response modes work on Druid
-- ===========================================================================
--
--   * The reasoning tier runs through FOUR INDEPENDENT
--     CONTEXTS, and a context's mode is a property of what the call is
--     FOR, not of the operator's configuration:
--
--       chat   -- a question answered in prose. The operator's choice:
--                 text (the default), code or json.
--       t2s    -- a statement generated. Always code, so the fenced
--                 block comes back as the statement itself.
--       review -- a PASS/FAIL judgment on a candidate. Always text, so
--                 the verdict can be read off the front.
--       embed  -- a vector. Always the embedding shape.
--
--     
--   * So the three modes below are still three KINDS OF QUESTION, and
--     the kit shows what each one produces. The difference is that the
--     code mode is now what the text-to-SQL tier actually runs in --
--     the answer to question 2 is exactly what the tier hands to
--     Druid's parser -- and the json mode's document is structurally
--     checked before it is handed back.
--   * The JSON mode's parse is the extension's own fractal_json_value, and
--     it answers null on a malformed document rather than raising --
--     so the JSON section below cannot fail the kit on a model that
--     answered with prose around its JSON.
--
-- Safe to re-run: the kit only reads the demo_alerts datasource.

-- ---------------------------------------------------------------------------
-- 0. Sanity check: extension loaded?
-- ---------------------------------------------------------------------------
SELECT fractal_edition(), fractal_version();

-- ---------------------------------------------------------------------------
-- 1. MODE: text -- the raw model output, unchanged.
--
-- This is what demo.sql and every other example in the docs already
-- use, and it is the chat context's default. The context is the alert
-- stream, as text.
-- ---------------------------------------------------------------------------
SELECT fractal_reason(
    'summarize what happened in demo_alerts in one sentence',
    (SELECT ARRAY_TO_STRING(
                ARRAY_AGG("service" || ' / ' || "severity" || ': ' || "message", 8192),
                ' | ')
     FROM "demo_alerts")) AS "text_mode_answer";

-- ---------------------------------------------------------------------------
-- 2. MODE: code -- the model answers with a statement.
--
-- Asked for a statement, the model answers with a fenced code block.
-- In the chat context's default (text) mode the answer comes back as
-- the model wrote it, fences and all. With the daemon started in code
-- mode (FSQL_REASONING_HTTP_RESPONSE_MODE=code) it comes back as the
-- block's interior: the statement itself, no fence markers. That is
-- the shape the text-to-SQL tier always runs in, because its context
-- is fixed to code.
-- ---------------------------------------------------------------------------
SELECT fractal_reason(
    'write a single Apache Druid SQL SELECT statement that selects all rows from demo_alerts where severity is critical',
    '{}') AS "code_mode_answer";

-- ---------------------------------------------------------------------------
-- 3. MODE: json -- the model answers with a document, and the caller
-- parses it.
--
-- The parse is independent of whatever validated the model's answer: a
-- malformed document reads as null here rather than being accepted.
-- ---------------------------------------------------------------------------
SELECT fractal_json_value(
           fractal_reason(
               'return a JSON object with keys critical_count, warning_count and info_count summarizing the severities present',
               (SELECT ARRAY_TO_STRING(ARRAY_AGG("severity", 8192), ',')
                FROM "demo_alerts")),
           '$.critical_count') AS "critical_count";

-- ---------------------------------------------------------------------------
-- The headline.
--
-- The kit passes when the model answered in all three shapes: the text
-- mode said something, the code mode produced a statement, and the JSON
-- question was answered and read without raising. A model that wraps
-- its JSON in prose or a fence reads as null, which is not a failure:
-- the model's formatting is not the test.
-- ---------------------------------------------------------------------------
SELECT CASE
           WHEN (SELECT COUNT(*) FROM "demo_alerts") = 10
            AND LENGTH((SELECT fractal_reason(
                                  'summarize what happened in demo_alerts in one sentence',
                                  (SELECT ARRAY_TO_STRING(
                                              ARRAY_AGG("service" || ' / ' || "severity" || ': ' || "message", 8192),
                                              ' | ')
                                   FROM "demo_alerts")))) > 0
            AND (SELECT fractal_reason(
                                  'write a single Apache Druid SQL SELECT statement that selects all rows from demo_alerts where severity is critical',
                                  '{}')) LIKE '%SELECT%'
            AND (SELECT COALESCE(CAST(fractal_json_value(
                                  fractal_reason(
                                      'return a JSON object with keys critical_count, warning_count and info_count summarizing the severities present',
                                      (SELECT ARRAY_TO_STRING(ARRAY_AGG("severity", 8192), ',')
                                       FROM "demo_alerts")),
                                  '$.critical_count') AS VARCHAR), 'unparsed')) IS NOT NULL
            THEN 'HEADLINE kit=response-modes ok'
            ELSE 'HEADLINE kit=response-modes FAILED'
       END AS "headline";
