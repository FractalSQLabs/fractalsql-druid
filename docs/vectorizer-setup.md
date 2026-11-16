<p align="center">
  <img src="../FractalSQLforDruid.jpg" alt="FractalSQL for Apache Druid" width="720">
</p>

# Vectorizer Setup Guide

The Vectorizer is the Cognition tier's automation engine. It keeps raw text and semantic embeddings in sync automatically, so your data is always "search-ready" without external middleware or a separate ETL pipeline.

The embedding sync runs on your broker, with the model reached through `fractalsqld` beside it. That removes the "data shuffle" and keeps your semantic index a real-time reflection of your data.

---

## Prerequisites

To enable automated embeddings, the following configuration is required (Community edition, no separate tier or license needed). The settings live in `fractalsqld.conf`, beside the broker (see [reasoning-setup.md](reasoning-setup.md)); the extension only needs to reach the service.

1. **Reasoning Plugin**: the `reasoning_plugin` key must point at the compiled `fractalsql-reasoning-http` plugin (`reasoning_plugin = /opt/fractalsql/fractalsql-reasoning-http.so` — see [reasoning-setup.md](reasoning-setup.md)).
2. **Embeddings Endpoint**: the `embed_url` key must be set to your provider's **embeddings** endpoint. This is a distinct path from the chat endpoint (e.g., `/v1/embeddings` vs `/v1/chat/completions`).
3. **Embedding Model**: the `embed_model` key specifies the purpose-trained model. If left unset, the plugin defaults to `text-embedding-3-small`. **Important**: Never reuse a chat model for embeddings; they are mathematically distinct tasks.

**Connectivity Check**:
Confirm the embed path is active before creating a vectorizer:
```sql
SELECT fractal_embed('hello world');
--  [0.0023064255,-0.009327292,...]
```

---

## Quick Start: Automated Sync

### 1. Define your table
Your datasource needs an id column and a text column. The embeddings are written to a **companion datasource** (`docs_embeddings` by default) holding each row's `id` and its vector in the core's JSON text form, because Druid's segments are immutable and there is no `ALTER TABLE` to add a column afterwards.

```sql
REPLACE INTO "docs" OVERWRITE ALL
SELECT TIMESTAMP '2026-01-01' AS "__time", "id", "body"
FROM (VALUES (1, 'first doc'), (2, 'second doc')) AS t("id", "body")
PARTITIONED BY ALL;
```

*Druid difference:* Druid has no typed column of fixed width, so a `fractal_vector(n)`-style column type with built-in **dimension-drift protection** (rejecting a 384-dim vector written into a 1536-dim column) has no direct counterpart here — a wrong-width vector from a misconfigured model is stored, not rejected. Guard the width when you read it back, e.g. `WHERE fractal_vector_dims("embedding") = 1536`.

### 2. Create the Vectorizer
Druid has no triggers, so the vectorizer registers the datasource and a **backfill job** finds the rows still missing an embedding and writes them to the companion datasource with MSQ. The source and embedding columns must exist, and the id column is required: it is how an embedding finds its row.

```sh
curl -s -X POST http://localhost:8082/fractalsql/vectorizer \
  -H 'Content-Type: application/json' \
  -d '{"action": "create", "source_table": "docs", "source_column": "body",
       "embedding_column": "embedding", "id_column": "id"}'
```

### 3. Process the Queue
Since FractalSQL respects your resource boundaries, it does not run a background worker either. You trigger the embedding process on your own schedule (e.g., a cron job calling the backfill endpoint).

```sh
curl -s -X POST http://localhost:8082/fractalsql/vectorizer \
  -H 'Content-Type: application/json' -d '{"action": "process_queue", "batch_size": 100}'
# {"embedded": 2, "failed": 0, "throttled": 0, "written": ["docs_embeddings"], ...}
```

### 4. Monitor Progress
```sh
curl -s -X POST http://localhost:8082/fractalsql/vectorizer \
  -H 'Content-Type: application/json' -d '{"action": "status", "id": 1}'
# {"id": 1, "source_table": "docs", ..., "done": 2, "failed": 0, "pending": 0,
#  "last_error": null, "last_failure_at": null}
```
`status` reports how many rows are embedded (`done`), how many embedding calls failed, how many rows are still `pending`, and the most recent failure.

*Druid difference:* the registry lives in the extension, per node, and `list` shows every vectorizer registered on that node — so create, process and monitor a vectorizer through the same node.

---

## Storage: the text form vs an ARRAY column

FractalSQL reads embeddings in two column shapes:

- **The text form** (`'0.6,0.8,0.0,0.0'` or bracketed JSON `'[0.6,0.8,0.0,0.0]'`): the plain,
  portable form the vectorizer writes and every vector function returns — any
  tool can read it. The scan must parse the string into floats for every row,
  and the dimension is *unchecked*: a column happily holds a 384-dim vector one
  day and a 1536-dim vector the next, silently corrupting your index.
- **A numeric `ARRAY` column** (`DOUBLE ARRAY`, ingested with
  `arrayIngestMode: "array"`): Druid's own typed form. Every vector function
  accepts it directly as an argument, with no parse. See `bench/README.md`
  before treating any speed difference as a promise.

Prefer an `ARRAY` column when you ingest vectors yourself. Use the text form
when you need human-inspectable vectors, or when a value comes out of a
function (a function's vector result is always the text form, because Druid 38
cannot carry an `ARRAY` out of a native expression). Neither enforces a
column-wide fixed width — read back with `WHERE fractal_vector_dims(x) = <n>`
if you want dimension-drift protection.

### Functions & helpers
The vector surface carries its own distance functions and vector arithmetic, so
a query can stay entirely in vector form without round-tripping through
text (Druid SQL has no custom operators — the operator syntax below maps to these
functions):

| Operator syntax elsewhere | Druid function | Meaning |
| --- | --- | --- |
| `a <-> b` | `fractal_vector_l2_distance(a, b)` | L2 (Euclidean) distance |
| `a <=> b` | `fractal_vector_cosine_distance(a, b)` | Cosine distance |
| `a <#> b` | `fractal_vector_negative_inner_product(a, b)` | Negative inner product (for max-inner-product ranking) |
| `fractal_vector_l2_squared(a, b)` | same | Squared L2 distance (no `sqrt`, cheaper for ordering) |
| `fractal_vector_cosine_similarity(a, b)` | same | Cosine *similarity* (1 − cosine distance) |
| `fractal_vector_norm(a)` / `fractal_vector_normalize(a)` | same | L2 norm / unit vector |
| `a + b`, `a - b`, `a * s` | `fractal_vector_add(a, b)` / `fractal_vector_sub(a, b)` / `fractal_vector_scale(v, s)` | Element-wise add / subtract / scalar-multiply |
| `fractal_vector_lp_distance(a, b, p)` | same | Generalized $L_p$ distance, any $p > 0$ (for $0 < p < 1$ this is not a proper metric; use explicitly, never as a silent L2 substitute) |
| — | `fractal_vector_quantize_int8(a)` | Symmetric int8 quantization, 4x compression, returns `{"scale":S,"codes":[..]}` as TEXT (JSON) |
| — | `fractal_vector_quantize_binary(a)` | 1-bit quantization: the sign bits as a text array of `0`/`1` values, padded with zeros to a multiple of 8 entries |
| — | `fractal_vector_hamming_distance(a, b)` | Hamming distance between two quantized vectors (cheap candidate filtering ahead of a full-precision L2/cosine re-rank) |
| — | `fractal_vector_dims(v)` / `fractal_vector_to_json(v)` | Dimension / JSON-array dump of a stored vector |

### Constructors
`fractal_vector(dim)` builds a zero vector; `fractal_vector_from_text(t)`
converts CSV/JSON text into the canonical text form:

```sql
-- the canonical form from CSV text (also the form the vectorizer writes)
SELECT fractal_vector_from_text('1,0,0');
-- dimension of a stored vector
SELECT fractal_vector_dims("embedding") FROM "docs_embeddings" LIMIT 1;
```

Write your embeddings through `fractal_vector_from_text()` (or read them back
with `fractal_vector_to_json()`), and a malformed vector fails decode with a
clean `malformed vector` error rather than silently poisoning the index. See
the dimension-mismatch assertions in `demo/demo-fractal-vector.sql`.

---

## Endpoint Providers

The Vectorizer leverages the same auth-bridge as the Cognition tier's reasoning endpoint. Credentials and region settings are shared; only the URL and model change. Each block below is the `fractalsqld.conf` lines to set, then apply with `fsqlctl reload`.

### Ollama (Local or Private Network)
Ideal for fully air-gapped deployments where data never leaves your VPC.

```ini
# chat / text-to-sql
reasoning_url = http://127.0.0.1:11434/v1/chat/completions
reasoning_model = gpt-oss:20b
reasoning_allow_plaintext = on

# embeddings
embed_url = http://127.0.0.1:11434/v1/embeddings
embed_model = nomic-embed-text
```
*Note: You must run `ollama pull nomic-embed-text` separately.*

### Docker Model Runner (DMR)
Same Docker Desktop feature as the reasoning endpoint (see
[reasoning-setup.md](reasoning-setup.md#docker-model-runner-dmr)); only
the model names change for embeddings.

```ini
# chat / text-to-sql
reasoning_url = http://127.0.0.1:12434/engines/v1/chat/completions
reasoning_model = ai/gpt-oss:20b   # or 'ai/gemma4:12b' or 'ai/phi4'
reasoning_allow_plaintext = on

# embeddings
embed_url = http://127.0.0.1:12434/engines/v1/embeddings
embed_model = ai/nomic-embed-text-v1.5
```
*Note: Run `docker model pull ai/nomic-embed-text-v1.5` before connecting.*

### OpenAI-Compatible (OpenAI, Together AI, Fireworks, vLLM)
```ini
reasoning_url = https://api.openai.com/v1/chat/completions
reasoning_token = sk-...
reasoning_model = gpt-4o-mini

embed_url = https://api.openai.com/v1/embeddings
embed_model = text-embedding-3-small
```

### AWS Bedrock
Uses `AUTH_TYPE=aws-sigv4` via environment variables (see `docs/reasoning-setup.md`).

```ini
reasoning_url = https://bedrock-runtime.us-east-1.amazonaws.com/openai/v1/chat/completions
embed_url = https://bedrock-runtime.us-east-1.amazonaws.com/openai/v1/embeddings
embed_model = amazon.titan-embed-text-v2:0
```

### Azure OpenAI
Requires a **separate deployment resource** for the embedding model.

```ini
reasoning_url = https://<resource>.openai.azure.com/openai/deployments/<chat-deploy>/chat/completions?api-version=2024-02-01
embed_url = https://<resource>.openai.azure.com/openai/deployments/<embed-deploy>/embeddings?api-version=2024-02-01
```

### Google Vertex AI
Uses the same OAuth access token as the reasoning endpoint (see
`docs/reasoning-setup.md`, Vertex AI block), only the URL and model change.
Point the embed path at the `openapi/v1/embeddings` surface of your project's
region endpoint.

```ini
embed_url = https://{LOCATION}-aiplatform.googleapis.com/v1/projects/{PROJECT}/locations/{LOCATION}/endpoints/openapi/embeddings
embed_model = text-embedding-005
```

---

## SQL API Reference

### `create` — `{"action": "create", "source_table", "source_column", "embedding_column", "id_column", "options"}`
Registers a vectorizer. The source and id columns must exist in the source datasource, or the call is refused with `fractal_vectorizer_create: column "x" does not exist in table "t"`. `options` is a JSON object: `embeddings_table` (default `<source_table>_embeddings`), `max_embeds_per_window` and `rate_window_secs`.

### `pause` / `resume` — `{"action": "pause", "id": 1}`
Toggles the `paused` state. While paused, the processor skips the vectorizer. Refused with a clear message on a nonexistent id. Idempotent: pausing an already-paused vectorizer is a no-op.

### `drop` — `{"action": "drop", "id": 1}`
Permanently deregisters the vectorizer; the embeddings already written stay in the companion datasource. Irreversible -- for a temporary stop, use `pause` instead. Needed before re-creating a vectorizer on the same `(source_table, source_column, embedding_column)`, since that triple is unique.

### `process_queue` — `{"action": "process_queue", "batch_size": 100}`
The engine that drives the synchronization. It embeds at most `batch_size` (default 100) rows per vectorizer, skips rows that already have an embedding, and appends the new embeddings to the companion datasource with an MSQ `INSERT`. A row whose embedding call fails is counted in `failed` and stays pending for the next run.

### `status` and `list`
`status` (`"id"`) reports `done`, `failed`, `pending` and the last failure; `list` shows every vectorizer registered on the node.

### Rate Capping
To prevent provider throttling, set `options.max_embeds_per_window` (int) and `options.rate_window_secs` (default 3600) during creation. Tracked per vectorizer: the cap holds attempts (not just successes) within a window, and rolls over once `rate_window_secs` elapses since the window started.
```sh
curl -s -X POST http://localhost:8082/fractalsql/vectorizer -H 'Content-Type: application/json' \
  -d '{"action": "create", "source_table": "documents", "source_column": "body",
       "embedding_column": "embedding", "id_column": "id",
       "options": {"max_embeds_per_window": 500, "rate_window_secs": 3600}}'
```
Calls over the cap in a window are counted as `throttled` and picked up in a later window.

---

## Design & Safety

### The "No-Worker" Architecture
Unlike traditional extensions that spawn background workers (which can be unstable or conflict with managed cloud environments), FractalSQL uses a **pull-based queue**. You control exactly when and how often the embedder runs, making it compatible with every Druid deployment from a laptop to a cluster.

### Where the embedding runs
The embedding happens in the Druid process that serves `/fractalsql/vectorizer`: the broker, through its own
daemon. The batch is then written with an MSQ `INSERT` that carries the finished vectors, so the ingestion
task hosts (middle managers and indexers) call no provider and need no daemon for the vectorizer. They need
one only if your own ingestion SQL calls `fractal_embed` or `fractal_reason` per row. In a multi-host cluster,
call the vectorizer on a broker that has a daemon; the registry is node-local (below).

### Crash Safety & Authorization
- **Atomic Recovery**: each batch is written with a single MSQ `INSERT`. If the process stops mid-batch, nothing from that batch is written, and the rows remain `pending` for the next run.
- **Sovereign Authorization**: The registry is node-local, so a vectorizer never leaks between nodes. The writes run as the node's own MSQ tasks; give the identity that reaches `/fractalsql/vectorizer` only the datasources it should embed.
- **Identifier Safety**: All table and column names are validated (alphanumerics + underscore per segment) and double-quoted before interpolation to prevent SQL injection.

---

## Known Constraints

- **Text Chunking**: Current version sends the full text of the column to the provider. For documents exceeding model context limits, we recommend pre-chunking into a separate "chunks" table.
- **Spend Caps**: Rate capping is based on call count, not dollar cost.
- **Automatic Retries**: Failed rows are not retried automatically; they must be reset to `pending` by the administrator.
- **Backfill Batching**: Initial backfill for very large tables (millions of rows) happens in a single transaction.

---

## When to use the Vectorizer

The Vectorizer is the right choice when you need **seamless semantic synchronization**. If your application requires that every single text update is immediately reflected in your vector index without managing external Python/Node.js workers, the Vectorizer closes that gap.

If you already have a robust external ETL pipeline, you can skip the Vectorizer and use `fractal_embed()` directly to populate your `fractal_vector` columns.
