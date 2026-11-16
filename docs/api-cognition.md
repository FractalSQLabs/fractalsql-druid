<p align="center">
  <img src="../FractalSQLforDruid.jpg" alt="FractalSQL for Apache Druid" width="720">
</p>

# Cognition API Reference

The Cognition tier provides the provider bridge that connects the SFS core to Large Language Models (LLMs) and embedding providers.

---

## `fractal_reason`
**LLM Dispatch**

Dispatches a natural language query and a context payload to the configured LLM reasoning plugin.

### Signature
```sql
fractal_reason(
    query   text,
    context text DEFAULT '{}'
) RETURNS text
```

### Arguments
| Argument | Type | Default | Description |
| --- | --- | --- | --- |
| `query` | `text` | (Required) | The question or instruction for the LLM. |
| `context` | `text` | `'{}'` | A JSON payload containing search results, schema, or other data. |

### Reasoning Effort
Hybrid-thinker models' internal reasoning trace is throttled via the `think` setting (`SELECT fractal_config_set('think', 'medium', 'my-session');`) and related keys -- see [Reasoning Setup: Reasoning Effort](reasoning-setup.md#reasoning-effort).

On Druid the setting is *session* state: `fractal_config_set` takes the
session's id as its third argument, because a Druid query has no
connection to hang a session on. The operator's own settings -- the
provider URL, the token -- are **not** session state: they
live in `fractalsqld.conf` (see the [FractalSQL Daemon](fractalsql-daemon.md#provider-keys)), and a request cannot change them.

---

## `fractal_embed`
**Semantic Vector Generation**

Generates a high-dimensional vector from text using the configured embedding model.

### Signature
```sql
fractal_embed(
    input text
) RETURNS text   -- the vector's JSON text form, e.g. '[0.1,0.2,...]'
```

### Requirements
Requires the embedding endpoint to be configured **by the operator**, in
`fractalsqld.conf`:

```ini
embed_url   = http://127.0.0.1:11434/v1/embeddings
embed_model = nomic-embed-text
```

A request cannot re-point `embed_url`: `fractal_config_set` refuses an
operator-only setting, and so does the query context.

---

## `fractal_text_to_sql`
**Safe SQL Generation**

Turns a natural-language question into a single, parse-validated SQL statement.

### Signature
```sql
fractal_text_to_sql(
    question text
) RETURNS text
```

### Arguments
| Argument | Type | Default | Description |
| --- | --- | --- | --- |
| `question` | `text` | (Required) | The natural language question. |

*Druid difference:* text-to-SQL is served by `POST /fractalsql/text-to-sql` with a JSON body `{"question": "...", "tables": ["orders","customers"]}`. `tables` is optional: without it the schema is auto-discovered from `INFORMATION_SCHEMA`. Use the `sql_agent` agent (`POST /fractalsql/agent/sql_agent`) when you also want the statement executed.

### Safety Pipeline
1. **Keyword pre-check**: raw-text first-keyword screen rejects multi-statement / DDL / utility candidates before any parse.
2. **Allowlist**: the statement type must be permitted (e.g. `SELECT` only). On Druid the check is the broker's own planner: the candidate is parsed with `EXPLAIN PLAN FOR`, which never executes it.
3. **Parse-Check**: `EXPLAIN PLAN FOR` against the broker *is* the mechanical check here -- and a stronger one than a plain parse, because it consults the engine that will actually run the statement. A construct a plain parse would accept and Druid's planner rejects is caught here with the planner's own error.

---

## `fractal_schema_context`
**Schema Introspection**

Builds a plain-text description of the database schema for use as LLM context.

### Signature
```
GET /fractalsql/schema-context[?datasource=<name>]
```

### Arguments
One optional query parameter, `datasource`. The endpoint reads `INFORMATION_SCHEMA.COLUMNS`: with no `datasource` it lists every datasource with its column count, and with one it returns that datasource's columns. Call it directly to audit exactly what the model sees.
