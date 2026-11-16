-- demo/demo-fractal-vector.sql
--
-- FractalSQL for Apache Druid -- the vector-function surface.
--
-- The dimensions of a vector, the vectorizer writing embeddings, the
-- trajectory search over a vector column, the distance and arithmetic
-- surface, the storage forms a vector can take, and the L_p-distance
-- and quantization surface.
--
-- Prerequisites: the extension is loaded on the Druid cluster, and an
-- embedding endpoint is configured (docs/vectorizer-setup.md) for the
-- vectorizer section. Every other section runs with no model.
--
-- Run:
--   python3 demo/run_demo.py --file demo/demo-fractal-vector.sql
--
-- ===========================================================================
-- Notes on how this runs on Druid
-- ===========================================================================
--
--   * A vector is TEXT on Druid. Druid's column types have no packed float32 BLOB form, so the interchange format is the text form -- CSV ("0.1,0.2,0.3") or bracketed JSON
--     ("[0.1,0.2,0.3]") -- which every vector function reads and the
--     vectorizer writes.
--   * There is no CHECK constraint on Druid, so there is no dimension guard on write. The demonstration is the one Druid can actually make: the width of a stored
--     vector is whatever the value is, and the refusal moves to the
--     function -- a vector that is not a vector comes back as NULL
--     rather than as a corrupt vector, and the width is reported, not
--     assumed. Section 1 shows both halves: the wrong-width row is
--     stored (Druid does not check it), and the malformed input is
--     refused (the function does).
--   * The vectorizer's registry and its queue are the extension's, not
--     TEMP objects on a connection, and its embeddings come back as
--     rows rather than being written into the source table -- so the
--     width the model produces is shown beside the fixture's 4-dim
--     stand-ins rather than replacing them. The kit drives the
--     embedding endpoint the vectorizer drives.
--   * fractal_search_trajectory is a service call (search/trajectory):
--     it reads a table's column and scans it, which a Druid SQL
--     function can do neither of.
--   * The storage comparison is between the two text forms, plus the
--     size the packed float32 form would have taken -- Druid has no
--     column type for it.
--   * The quantized binary code is a text array of sign bits on Druid,
--     not a BLOB, so the kit reports its width instead of its bytes.
--   * The two sample documents are short sentences about the engine.
--
-- Safe to re-run: the fixture is written with OVERWRITE ALL.

-- ---------------------------------------------------------------------------
-- 0. Sanity check: extension loaded?
-- ---------------------------------------------------------------------------
SELECT fractal_edition(), fractal_version();

-- ---------------------------------------------------------------------------
-- 1. The documents, and what a vector's width is on Druid.
--
-- Three documents, each with a vector in the text form. The third one
-- deliberately carries the wrong width: Druid has no CHECK
-- constraint, so the write accepts it -- and the width it actually
-- has is reported, not assumed.
-- ---------------------------------------------------------------------------
-- @fixture fv_docs {"rows": [
--   {"id": 1, "body": "FractalSQL runs Stochastic Fractal Search directly inside the Druid query engine.", "embedding": "0.6,0.8,0.0,0.0"},
--   {"id": 2, "body": "The reasoning plugin speaks the OpenAI chat-completions and embeddings shapes.", "embedding": "0.1,0.2,-0.3,0.4"},
--   {"id": 3, "body": "deliberately wrong dimension", "embedding": "0.1,0.2"}
-- ]};

SELECT "id", "body" FROM "fv_docs";

-- The width each stored vector actually has.
SELECT "id", "embedding", fractal_vector_dims("embedding") AS "dims"
FROM "fv_docs"
GROUP BY "id", "embedding", fractal_vector_dims("embedding")
ORDER BY "id";

-- ---------------------------------------------------------------------------
-- 1b. The refusal, live.
--
-- A wrong-width vector does not fail the write on Druid -- there is no CHECK -- so what refuses a bad vector is the
-- function that reads it: it hands back nothing at all rather than a
-- corrupt vector, and it reports zero dimensions for text that is not
-- a vector.
--
-- That is the replacement for a CHECK constraint: the
-- refusal moves from the write to the read, and the width is data,
-- not a promise.
-- ---------------------------------------------------------------------------
SELECT fractal_vector_from_text('0.1,not-a-number') AS "refused_vector",
       fractal_vector_to_json('0.1,not-a-number') AS "refused_json",
       fractal_vector_dims('0.1,not-a-number') AS "refused_dims";

-- A bracketed form with a missing bracket is refused the same way.
SELECT fractal_vector_from_text('[0.1,0.2') AS "refused_vector";

-- ---------------------------------------------------------------------------
-- 2. The model's own embedding.
--
-- The vectorizer drives this same embedding endpoint: it watches a
-- table's text column and writes each row's embedding into a
-- companion column. On Druid its registry and its queue are the
-- extension's, not TEMP objects on a connection, and the embeddings
-- come back as rows rather than being written into the source table
-- (a Druid segment is immutable and there is no ALTER TABLE, so a
-- column cannot be added to a table after the fact). The kit drives
-- the endpoint directly, so the model's own vector can be read beside
-- the fixture's stand-ins.
--
-- The model's own vector is read beside the fixture's. This call
-- includes a real network call to the embedding endpoint.
-- ---------------------------------------------------------------------------
-- @call embed {"text": "FractalSQL runs Stochastic Fractal Search directly inside the Druid query engine."} AS fv_embedded;

SELECT fractal_vector_dims("embedding") AS "model_dims",
       LENGTH("embedding") AS "model_text_bytes"
FROM "fv_embedded";

-- ---------------------------------------------------------------------------
-- 3. fractal_search_trajectory over a vector column.
--
-- Which stored tracks resemble a movement from a baseline to a
-- current state. The baseline and the current vector are read out of
-- a datasource the kit computed, because they are the stored ones: the
-- first document's vector and the second's, so the movement between
-- them is the thing the search is asked about.
--
-- The wrong-width row is skipped by the scan rather than scored: a
-- vector of another dimension is not a candidate, not a mistake.
-- ---------------------------------------------------------------------------
REPLACE INTO fv_v1 OVERWRITE ALL
SELECT a."embedding" AS "baseline", b."embedding" AS "current"
FROM "fv_docs" a, "fv_docs" b
WHERE a."id" = 1 AND b."id" = 2
PARTITIONED BY ALL;

-- @call search/trajectory {"table": "fv_docs", "column": "embedding", "id_column": "id",
--                         "baseline_table": "fv_v1", "baseline_column": "baseline",
--                         "current_table": "fv_v1", "current_column": "current",
--                         "k": 2} AS fv_traj;

SELECT r."doc_id" AS "id", r."distance" AS "distance"
FROM "fv_traj" r;

-- ---------------------------------------------------------------------------
-- 4. The vector functions.
--
-- Distance is l2_distance / cosine_distance / negative_inner_product,
-- and the rest of the measurement surface.
-- ---------------------------------------------------------------------------
SELECT fractal_vector_l2_distance(a."embedding", b."embedding") AS "l2_distance",
       fractal_vector_cosine_distance(a."embedding", b."embedding") AS "cosine_distance",
       fractal_vector_negative_inner_product(a."embedding", b."embedding") AS "neg_inner_product",
       fractal_vector_l2_squared(a."embedding", b."embedding") AS "l2_squared",
       fractal_vector_cosine_similarity(a."embedding", b."embedding") AS "cosine_similarity",
       fractal_vector_norm(a."embedding") AS "norm_a",
       fractal_vector_norm(b."embedding") AS "norm_b"
FROM "fv_docs" a, "fv_docs" b
WHERE a."id" = 1 AND b."id" = 2;

-- Arithmetic and normalize return a vector; fractal_vector_dims
-- confirms the element count is preserved.
SELECT fractal_vector_dims(fractal_vector_add(a."embedding", b."embedding")) AS "add_dims",
       fractal_vector_dims(fractal_vector_sub(a."embedding", b."embedding")) AS "sub_dims",
       fractal_vector_dims(fractal_vector_scale(a."embedding", 2.0)) AS "scale_dims",
       fractal_vector_dims(fractal_vector_normalize(a."embedding")) AS "normalize_dims"
FROM "fv_docs" a, "fv_docs" b
WHERE a."id" = 1 AND b."id" = 2;

-- The arithmetic itself.
SELECT fractal_vector_add(a."embedding", b."embedding") AS "sum",
       fractal_vector_sub(a."embedding", b."embedding") AS "difference",
       fractal_vector_scale(a."embedding", 2.0) AS "scaled",
       fractal_vector_normalize(a."embedding") AS "normalized"
FROM "fv_docs" a, "fv_docs" b
WHERE a."id" = 1 AND b."id" = 2;

-- The two constructors and the JSON formatter.
SELECT fractal_vector_to_json(a."embedding") AS "as_json",
       fractal_vector_from_text(a."embedding") AS "from_text",
       fractal_vector_dims(fractal_vector_from_text(a."embedding")) AS "round_trip_dims"
FROM "fv_docs" a
WHERE a."id" = 1;

-- ---------------------------------------------------------------------------
-- 5. The storage forms.
--
-- A vector is text on Druid, so the forms to
-- compare are the CSV text and the bracketed JSON text -- and the size
-- the packed float32 form would have taken, which Druid has no column
-- type for.
-- ---------------------------------------------------------------------------
SELECT LENGTH(a."embedding") AS "csv_text_bytes",
       LENGTH(fractal_vector_to_json(a."embedding")) AS "json_text_bytes",
       4 + 4 * fractal_vector_dims(a."embedding") AS "packed_float32_bytes"
FROM "fv_docs" a
WHERE a."id" = 1;

-- ---------------------------------------------------------------------------
-- 6. L_p distance and quantization.
--
-- The compressed-vector surface: generalized L_p distance for any
-- p > 0, and the two quantizers for cheap storage and candidate
-- filtering ahead of a full-precision re-rank.
-- (For 0 < p < 1 the L_p "distance" is not a proper metric -- use it
-- explicitly, never as a silent L2 substitute.)
-- ---------------------------------------------------------------------------
SELECT fractal_vector_lp_distance(a."embedding", b."embedding", 2.0) AS "lp2_euclidean",
       fractal_vector_lp_distance(a."embedding", b."embedding", 1.0) AS "lp1_manhattan",
       fractal_vector_lp_distance(a."embedding", b."embedding", 0.5) AS "lp05_fractional"
FROM "fv_docs" a, "fv_docs" b
WHERE a."id" = 1 AND b."id" = 2;

-- int8 quantization: 4x compression, returns {"scale":S,"codes":[..]}
-- as TEXT (JSON) -- dequantize with codes * scale.
SELECT fractal_vector_quantize_int8(a."embedding") AS "int8_doc"
FROM "fv_docs" a
WHERE a."id" = 1;

-- binary quantization: the sign bits, one per dimension, as a text
-- array.
SELECT fractal_vector_quantize_binary(a."embedding") AS "binary_code",
       fractal_vector_dims(fractal_vector_quantize_binary(a."embedding")) AS "binary_sign_bits"
FROM "fv_docs" a
WHERE a."id" = 1;

-- Hamming distance between the binary codes: the cheap candidate
-- filter. Both vectors are non-negative, so their sign bits agree.
SELECT fractal_vector_hamming_distance(
           fractal_vector_quantize_binary(a."embedding"),
           fractal_vector_quantize_binary(b."embedding")) AS "hamming_dist"
FROM "fv_docs" a, "fv_docs" b
WHERE a."id" = 1 AND b."id" = 2;

-- ---------------------------------------------------------------------------
-- The headline.
--
-- The kit passes when the vector surface answers for the stored
-- vectors: the fixture's widths are what it says they are, a vector
-- that is not a vector is refused rather than mangled, the distance
-- and the arithmetic hold for a known pair, and the trajectory search
-- ranks the stored rows.
-- ---------------------------------------------------------------------------
SELECT CASE
           WHEN (SELECT fractal_vector_dims("embedding") FROM "fv_docs" WHERE "id" = 1) = 4
            AND (SELECT fractal_vector_dims("embedding") FROM "fv_docs" WHERE "id" = 3) = 2
            AND (SELECT fractal_vector_from_text('0.1,not-a-number') FROM "fv_docs" WHERE "id" = 1) IS NULL
            AND (SELECT fractal_vector_dims(fractal_vector_add(a."embedding", b."embedding"))
                   FROM "fv_docs" a, "fv_docs" b
                  WHERE a."id" = 1 AND b."id" = 2) = 4
            AND (SELECT fractal_vector_l2_distance(a."embedding", b."embedding")
                   FROM "fv_docs" a, "fv_docs" b
                  WHERE a."id" = 1 AND b."id" = 2) > 0
            AND (SELECT COUNT(*) FROM "fv_traj") >= 1
            THEN 'HEADLINE kit=demo-fractal-vector ok'
            ELSE 'HEADLINE kit=demo-fractal-vector FAILED'
       END AS "headline";
