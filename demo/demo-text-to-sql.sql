-- demo/demo-text-to-sql.sql
--
-- FractalSQL for Apache Druid -- the text-to-SQL tier.
--
-- A plain-English question goes in, a Druid SQL statement comes out. The
-- generation, the statement's admissibility and the review are all
-- service calls on the extension's own endpoints: a model has to be
-- reached, and the candidate has to be checked against Druid's own
-- parser before anyone is asked to run it.
--
--   1. The schema the questions are asked over: customers -> orders ->
--      order_items, with the foreign keys that make the joins real.
--   2. A simple single-table question.
--   3. A question that needs the join across the FK chain.
--   4. A question that needs all three tables.
--   5. The allowlist check: what class of statement the service may
--      return, and whether each candidate plans.
--   6. The review: the model reads its own candidate back.
--   7. Running the generated statement -- explicitly, never as a side
--      effect of generating it.
--
-- Prerequisites:
--   * the extension is loaded on the Druid cluster;
--   * a reasoning provider is configured (docs/reasoning-setup.md).
--     Without one the service calls report a clean error and the kit
--     carries on.
--
-- Run:
--   python3 demo/run_demo.py --file demo/demo-text-to-sql.sql
--
-- ===========================================================================
-- Notes on how this runs on Druid
-- ===========================================================================
--
--   * The three tables are fixtures. Druid has no DDL, no INSERT and no
--     VALUES, so a set of rows has no SQL form: the runner loads them
--     with an MSQ write (REPLACE INTO ... OVERWRITE ALL), which is also
--     what makes the kit re-runnable.
--   * The generation is a service call, not a SQL function. The model is
--     reached over HTTP, so the generation is
--     `-- @call text-to-sql {...}` against the extension's own endpoint.
--     The endpoint validates the candidate with EXPLAIN PLAN FOR
--     before it returns it, so a statement Druid cannot plan is
--     reported as not valid rather than handed over as if it worked.
--   * There is no schema discovery. The service is given the table NAMES
--     and nothing else, so the kit names the columns in the question
--     itself and audits the schema through INFORMATION_SCHEMA. (The
--     extension exposes the schema context at GET
--     /fractalsql/schema-context; the runner calls services with POST,
--     so the kit reads it from INFORMATION_SCHEMA.)
--   * The allowlist check is the service's own: the candidate goes
--     through Druid's own planner, and the operator's knob --
--     text_to_sql.allowed_statements, 'select' by default -- is read
--     back here with fractal_config_get.
--   * The review is a service call as well: `-- @call reason {...}`
--     with the candidate spliced in from the previous call.
--   * The generated statement is run as a separate, explicit step. Druid
--     has no dynamic SQL execution, so it goes through the extension's
--     data-analyst agent, which validates a statement with EXPLAIN PLAN
--     FOR and then executes it.
--
-- Safe to re-run: every fixture is written with OVERWRITE ALL.

-- ---------------------------------------------------------------------------
-- 0. Sanity check: extension loaded?
-- ---------------------------------------------------------------------------
SELECT fractal_edition(), fractal_version();

-- ---------------------------------------------------------------------------
-- 1. The schema: customers -> orders -> order_items.
--
-- The three tables the questions are asked over, with the foreign keys
-- that make the joins real. They are fixtures, because a Druid
-- datasource is a set of rows, not a table definition.
-- ---------------------------------------------------------------------------
-- @fixture t2s_customers {"rows": [
--   {"id": 1, "name": "acme", "status": "active"},
--   {"id": 2, "name": "globex", "status": "active"},
--   {"id": 3, "name": "initech", "status": "churned"}
-- ]};

-- @fixture t2s_orders {"rows": [
--   {"id": 1, "customer_id": 1, "status": "paid", "placed_at": "2026-11-01T09:00:00Z"},
--   {"id": 2, "customer_id": 1, "status": "paid", "placed_at": "2026-11-01T09:00:00Z"},
--   {"id": 3, "customer_id": 1, "status": "refunded", "placed_at": "2026-11-01T09:00:00Z"},
--   {"id": 4, "customer_id": 2, "status": "paid", "placed_at": "2026-11-01T09:00:00Z"},
--   {"id": 5, "customer_id": 3, "status": "cancelled", "placed_at": "2026-11-01T09:00:00Z"}
-- ]};

-- @fixture t2s_order_items {"rows": [
--   {"id": 1, "order_id": 1, "sku": "widget-a", "quantity": 3, "unit_cents": 500},
--   {"id": 2, "order_id": 1, "sku": "widget-b", "quantity": 1, "unit_cents": 1200},
--   {"id": 3, "order_id": 2, "sku": "widget-a", "quantity": 2, "unit_cents": 500},
--   {"id": 4, "order_id": 3, "sku": "widget-c", "quantity": 1, "unit_cents": 4000},
--   {"id": 5, "order_id": 4, "sku": "widget-b", "quantity": 5, "unit_cents": 1200}
-- ]};

SELECT "id", "name", "status" FROM "t2s_customers";

SELECT "id", "customer_id", "placed_at", "status" FROM "t2s_orders";

SELECT "id", "order_id", "sku", "quantity", "unit_cents" FROM "t2s_order_items";

-- The schema context: the columns the questions are about, read from
-- the catalog rather than from a table definition.
SELECT "TABLE_NAME", "COLUMN_NAME", "DATA_TYPE"
FROM INFORMATION_SCHEMA.COLUMNS
WHERE "TABLE_NAME" IN ('t2s_customers', 't2s_orders', 't2s_order_items')
GROUP BY "TABLE_NAME", "COLUMN_NAME", "DATA_TYPE"
ORDER BY "TABLE_NAME", "COLUMN_NAME";

-- ---------------------------------------------------------------------------
-- 2. A simple single-table question.
--
-- The service is given the table names; the columns are in the
-- question. The candidate comes back with a validity flag: the service
-- ran it through Druid's own planner before returning it.
-- ---------------------------------------------------------------------------
-- @call text-to-sql {"question": "How many customers have status active? The table t2s_customers has columns id (long), name (varchar), status (varchar); status is one of active or churned, written in lower case. Answer with one number.",
--                   "tables": ["t2s_customers"]} AS t2s_simple;

SELECT "generated_sql" AS "sql_text", "valid" FROM "t2s_simple";

-- ---------------------------------------------------------------------------
-- 3. A question that needs the join across the FK chain.
-- ---------------------------------------------------------------------------
-- @call text-to-sql {"question": "List the names of customers who have at least one paid order, with how many paid orders each has. The table t2s_customers has columns id (long), name (varchar), status (varchar); the table t2s_orders has columns id (long), customer_id (long), placed_at (varchar), status (varchar); an order's status is one of pending, paid, refunded, cancelled, written in lower case.",
--                   "tables": ["t2s_customers", "t2s_orders"]} AS t2s_join;

SELECT "generated_sql" AS "sql_text", "valid" FROM "t2s_join";

-- ---------------------------------------------------------------------------
-- 4. A question that needs all three tables.
-- ---------------------------------------------------------------------------
-- @call text-to-sql {"question": "For each customer, what is the total value in cents of their paid orders (quantity times unit price, summed across all line items)? The table t2s_customers has columns id (long), name (varchar), status (varchar); the table t2s_orders has columns id (long), customer_id (long), placed_at (varchar), status (varchar); the table t2s_order_items has columns id (long), order_id (long), sku (varchar), quantity (long), unit_cents (long); an order's status is one of pending, paid, refunded, cancelled, written in lower case.",
--                   "tables": ["t2s_customers", "t2s_orders", "t2s_order_items"]} AS t2s_full;

SELECT "generated_sql" AS "sql_text", "valid" FROM "t2s_full";

-- ---------------------------------------------------------------------------
-- 5. The allowlist check.
--
-- Two halves, both on the service. The admissibility of a candidate
-- is the service's own: it validated the statement with Druid's
-- EXPLAIN PLAN FOR before returning it, and the flags below are what
-- that check said. The operator's knob -- which class of statement may
-- be returned at all -- is deliberately not a request-settable key: a
-- request must not be able to widen it, so it is read here, never
-- written.
-- ---------------------------------------------------------------------------
SELECT fractal_config_get('text_to_sql.allowed_statements', 't2s') AS "allowed_statements";

-- Each candidate, and whether Druid's own planner accepted it.
SELECT "valid" AS "simple_valid" FROM "t2s_simple";

SELECT "valid" AS "join_valid" FROM "t2s_join";

SELECT "valid" AS "all_tables_valid" FROM "t2s_full";

-- ---------------------------------------------------------------------------
-- 6. The review: the model reads its own candidate back.
--
-- The candidate is spliced in from the call above it -- the runner
-- replaces the "$candidate" placeholder with the statement the
-- previous call generated.
--
-- This is the review ENDPOINT, not /reason. The review runs on the
-- review CONTEXT, whose response mode is text -- hardcoded, and not
-- the operator's choice -- because the verdict is read off the front
-- of the answer, and a code- or json-mode answer would not begin with
-- one. 
-- ---------------------------------------------------------------------------
-- @call review {"question": "For each customer, what is the total value in cents of their paid orders (quantity times unit price, summed across all line items)? The table t2s_customers has columns id (long), name (varchar), status (varchar); the table t2s_orders has columns id (long), customer_id (long), placed_at (varchar), status (varchar); the table t2s_order_items has columns id (long), order_id (long), sku (varchar), quantity (long), unit_cents (long); an order's status is one of pending, paid, refunded, cancelled, written in lower case.",
--               "sql": "$candidate"} AS t2s_review;

SELECT "passed" AS "review_passed", "review" AS "review" FROM "t2s_review";

-- ---------------------------------------------------------------------------
-- 7. Running the generated statement.
--
-- Generation never executes anything. This step is explicit: the
-- extension's data-analyst agent writes a statement, validates it with
-- EXPLAIN PLAN FOR, runs it, and answers the question over the real
-- result rows.
-- ---------------------------------------------------------------------------
-- @call agent/data_analyst {"question": "How many line items are there per order on average? The table t2s_orders has columns id (long), customer_id (long), placed_at (varchar), status (varchar); the table t2s_order_items has columns id (long), order_id (long), sku (varchar), quantity (long), unit_cents (long).",
--                          "table_names": ["t2s_orders", "t2s_order_items"]} AS t2s_analysis;

SELECT "generated_sql" AS "sql_text", "execution_status" FROM "t2s_analysis";

-- The real result rows.
SELECT "result_rows" AS "result_rows" FROM "t2s_analysis";

-- The answer, over those rows.
SELECT "analysis" AS "analysis" FROM "t2s_analysis";

-- ---------------------------------------------------------------------------
-- The headline.
--
-- The kit passes when the schema it asks about is the schema it built
-- (two active customers, three paid orders), when the service returned
-- a candidate that Druid's own planner accepted, when the reviewer
-- returned a verdict (pass or fail: the model's opinion is not the
-- test), and when the explicit execution step ran a statement and came
-- back with rows.
-- ---------------------------------------------------------------------------
SELECT CASE
           WHEN (SELECT COUNT(*) FROM "t2s_customers" WHERE "status" = 'active') = 2
            AND (SELECT COUNT(*) FROM "t2s_orders" WHERE "status" = 'paid') = 3
            AND (SELECT COUNT(*) FROM "t2s_order_items") = 5
            AND (SELECT "valid" FROM "t2s_simple") = 'true'
            AND (SELECT "execution_status" FROM "t2s_analysis") = 'success'
            AND (SELECT "passed" FROM "t2s_review") IS NOT NULL
            THEN 'HEADLINE kit=demo-text-to-sql ok'
            ELSE 'HEADLINE kit=demo-text-to-sql FAILED'
       END AS "headline";
