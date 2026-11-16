-- demo/demo-vectorizer.sql
--
-- Runnable walkthrough of the vectorizer tier: a vectorizer watches a
-- table's text column and writes each row's embedding into a companion
-- column.
--
--   1. Some rows before the vectorizer exists.
--   2. fractal_vectorizer_create: the registry takes the source table,
--      the text column and the column the embeddings belong in.
--   3. A new row after the vectorizer exists.
--   4. fractal_vectorizer_process_queue: the embeddings.
--   5. The results.
--
-- Prerequisites: the extension is loaded on the Druid cluster, and an
-- embedding endpoint is configured (docs/vectorizer-setup.md).
--
-- Run:
--   python3 demo/run_demo.py --file demo/demo-vectorizer.sql
--
-- ===========================================================================
-- Notes on how this runs on Druid
-- ===========================================================================
--
--   * The registry and the queue are the extension's, not TEMP tables on
--     a connection: a Druid query has no connection to hang them on.
--   * The embeddings come back as rows rather than being written into
--     the source table. Druid's SQL has no DML, and an MSQ write's
--     SELECT can only read tables -- there is no way to inject a value
--     the extension computed. So the caller writes the embeddings where
--     they belong, which is what the "AS" clause on the call does.
--
-- Safe to re-run: the fixture replaces the documents each time.

-- ---------------------------------------------------------------------------
-- 0. Sanity check: extension loaded?
-- ---------------------------------------------------------------------------
SELECT fractal_edition(), fractal_version();

-- ---------------------------------------------------------------------------
-- 1. A clean slate.
--
-- The vectorizer's REGISTRY lives in the extension, per NODE -- Druid
-- has no connection to hang a per-session registry on. So the
-- registry carries over from whatever ran before on this node, and a
-- queue pass would embed every table any earlier kit registered, not
-- just this kit's.
--
-- So the kit starts by dropping what is there. On a demo node that is
-- the honest thing to do: the kit is about the vectorizer, and it
-- wants to see only its own work.
-- ---------------------------------------------------------------------------
-- @call vectorizer {"action": "list"};

-- @call vectorizer {"action": "drop", "id": 1} AS vectorizer_dropped_1;
-- @call vectorizer {"action": "drop", "id": 2} AS vectorizer_dropped_2;
-- @call vectorizer {"action": "drop", "id": 3} AS vectorizer_dropped_3;
-- @call vectorizer {"action": "drop", "id": 4} AS vectorizer_dropped_4;
-- @call vectorizer {"action": "drop", "id": 5} AS vectorizer_dropped_5;
-- @call vectorizer {"action": "drop", "id": 6} AS vectorizer_dropped_6;

-- @call vectorizer {"action": "list"};

-- ---------------------------------------------------------------------------
-- 1. Some rows before the vectorizer exists.
--
-- A toy document store -- one row per short passage.
-- ---------------------------------------------------------------------------
-- @fixture docs {"rows": [
--   {"id": 1, "body": "FractalSQL runs Stochastic Fractal Search directly inside the Druid query engine."},
--   {"id": 2, "body": "The reasoning plugin speaks the OpenAI chat-completions and embeddings shapes."},
--   {"id": 3, "body": "fractal_text_to_sql never executes what it generates -- that is always separate."}
-- ]};

SELECT "id", "body" FROM "docs";

-- ---------------------------------------------------------------------------
-- 2. Create the vectorizer.
--
-- The single-column key ('id') is introspected; there is no key
-- argument.
-- ---------------------------------------------------------------------------
-- @call vectorizer {"action": "create", "source_table": "docs",
--                   "source_column": "body", "embedding_column": "embedding",
--                   "id_column": "id"} AS vectorizer_created;

SELECT "id", "source_table", "source_column", "embedding_column", "paused"
FROM "vectorizer_created";

-- The registry, as it stands.
-- @call vectorizer {"action": "list"};

-- ---------------------------------------------------------------------------
-- 3. A new row after the vectorizer exists.
--
-- The vectorizer picks it up on its next pass; there is no separate
-- step.
-- ---------------------------------------------------------------------------
-- @fixture docs {"rows": [
--   {"id": 1, "body": "FractalSQL runs Stochastic Fractal Search directly inside the Druid query engine."},
--   {"id": 2, "body": "The reasoning plugin speaks the OpenAI chat-completions and embeddings shapes."},
--   {"id": 3, "body": "fractal_text_to_sql never executes what it generates -- that is always separate."},
--   {"id": 4, "body": "Sniper Search refines a query point; Scout Mode returns a diverse population instead."}
-- ]};

SELECT COUNT(*) AS "documents" FROM "docs";

-- ---------------------------------------------------------------------------
-- 4. Process the queue.
--
-- This is the one call you put on a schedule. The timing below includes
-- real network calls to the embedding endpoint.
-- ---------------------------------------------------------------------------
-- @call vectorizer {"action": "process_queue"} AS vectorizer_queue;

-- ---------------------------------------------------------------------------
-- 5. The results.
--
-- The embeddings land beside the documents: the vectorizer's rows carry
-- the row's identity and its embedding.
-- ---------------------------------------------------------------------------
SELECT d."id" AS "id", d."body" AS "body",
       (q."embedding" IS NOT NULL) AS "has_embedding",
       fractal_vector_dims(q."embedding") AS "dim"
FROM "docs" d, "vectorizer_queue" q
WHERE q."id" = d."id";

-- How many the vectorizer embedded.
SELECT COUNT(*) AS "embedded" FROM "vectorizer_queue";

-- ---------------------------------------------------------------------------
-- 6. The headline.
--
-- The kit passes when every document was embedded and every embedding
-- has a dimension -- that is, the vectorizer watched the table, the
-- provider answered for every row, and the embeddings came back in the
-- core's text form.
-- ---------------------------------------------------------------------------
SELECT CASE
           WHEN (SELECT COUNT(*) FROM "docs") = 4
            AND (SELECT COUNT(*) FROM "vectorizer_queue") = 4
            AND (SELECT COUNT(*) FROM "vectorizer_queue"
                 WHERE fractal_vector_dims("embedding") > 0) = 4
            THEN 'HEADLINE kit=demo-vectorizer ok'
            ELSE 'HEADLINE kit=demo-vectorizer FAILED'
       END AS "headline";
