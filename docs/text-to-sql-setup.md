<p align="center">
  <img src="../FractalSQLforDruid.jpg" alt="FractalSQL for Apache Druid" width="720">
</p>

# Production-Safe Text-to-SQL

`fractal_text_to_sql` is a core primitive of the **Cognition Tier**, served on Druid by `POST /fractalsql/text-to-sql`. It transforms natural-language questions into mechanically validated SQL statements, providing a safe bridge between intent and execution.

Unlike naive LLM-to-SQL wrappers, FractalSQL treats SQL generation as a **hard-constrained engineering problem**, not a probabilistic one. It employs a multi-stage validation pipeline to ensure that every returned statement is syntactically correct, semantically valid, and policy-compliant before it ever reaches your application.

---

## Quick Start

By default, `fractal_text_to_sql` auto-discovers every datasource in the catalog (from `INFORMATION_SCHEMA`). That's the simplest, most effective default for most use cases.

```sh
curl -s -X POST http://localhost:8082/fractalsql/text-to-sql \
  -H 'Content-Type: application/json' \
  -d '{"question": "How many orders does customer acme have?"}'
# {"question":"...","generated_sql":"SELECT COUNT(*) FROM \"orders\" WHERE \"customer\" = 'acme'","valid":true,"attempts":1}
```

### Scoping the Context
For large schemas, you can explicitly narrow the schema context sent to the LLM. This reduces token cost, minimizes noise, and allows you to strictly control what metadata leaves your database boundary. On Druid the narrowing knob is the `tables` argument, a JSON array of datasource names:

```sh
curl -s -X POST http://localhost:8082/fractalsql/text-to-sql \
  -H 'Content-Type: application/json' \
  -d '{"question": "How many orders does customer acme have?", "tables": ["orders", "customers"]}'
```

(Without `tables` the endpoint auto-discovers; audit the discovery with `GET /fractalsql/schema-context`.)

---

## The Safety Pipeline: How it Works

FractalSQL implements a rigorous verification loop to eliminate "hallucinated" SQL.

```
GENERATE ──▶ ALLOWLIST ──▶ [REVIEW, optional] ──▶ PLAN-CHECK ──▶ RETURN
   ▲                              │                   │
   └──────────── retry, with the specific failure fed back ──────┘
```

1. **GENERATE**: The question and schema description (from `/fractalsql/schema-context`, embedded in the prompt) are sent to the LLM.
2. **ALLOWLIST**: The candidate first passes a raw-text first-keyword screen
3. **REVIEW** *(Optional)*: A second LLM call critiques the candidate against the original question.
4. **MECHANICAL CHECK**: `EXPLAIN PLAN FOR` against the broker **is** the mechanical check here — and it consults the engine that will actually run the statement, so it catches what a plain parse would not (a recursive CTE, for one). The parse step still catches syntax errors and unknown-table shapes, without running the statement.
5. **RETURN or RETRY**: On success, the SQL is returned. On failure, the specific error (from the allowlist or the parse) is fed back into the next generation attempt, up to `t2s_max_attempts`.

### The Execution Guardrail (Safe Agency)
While `fractal_text_to_sql` only returns text, its logic is the foundation for the `sql_agent`. Containing execution failures to the agent's own attempt is a core pillar of our **Safe Agency** promise: it ensures that a late-stage failure (e.g., a query that plans but cannot run) is reported back to the agent for that attempt only, leaving your session intact and allowing the agent to self-correct.

---

## `GET /fractalsql/schema-context`

Builds the schema description used as the LLM's context. You can call this directly to audit exactly what the model sees. It reads `INFORMATION_SCHEMA.COLUMNS`: with no `datasource` it lists every datasource with its column count (table-count capped), and with `?datasource=orders` it returns that datasource's columns.

```sh
curl -s 'http://localhost:8082/fractalsql/schema-context?datasource=orders'
# {"datasource":"orders","columns":[{"name":"__time","type":"TIMESTAMP","nullable":"NO","position":1},
#   {"name":"customer","type":"VARCHAR","nullable":"YES","position":2},
#   {"name":"total_cents","type":"BIGINT","nullable":"YES","position":3}]}
```

**Sovereignty Note**: Auto-discovery pulls every datasource in the catalog

---

## Configuration & Security

### Config Keys
These are `fractalsqld.conf` keys (apply changes with `fsqlctl reload`). A session may override `t2s_max_attempts` and `t2s_use_review` with `fractal_config_set`; `t2s_allowed_statements` is operator-only:

| Config key | Default | Notes |
| --- | --- | --- |
| `t2s_max_attempts` | `2` | Shared budget across all rejection types (range 1–10). |
| `t2s_allowed_statements` | `'select'` | `'select_insert_update'` permits writes; see **Secure it** below. |
| `t2s_use_review` | `off` | Enable for higher accuracy at the cost of latency. |

```ini
t2s_use_review = on
```

### Secure it: Authorization vs. Correctness
**Crucial**: This pipeline is a *correctness* aid, not an *authorization* mechanism. The allowlist and plan checks catch shape and schema problems, but they do not decide who may read what: that is Druid's authorizer.

To secure your Text-to-SQL implementation:
1. **Dedicated Identity**: Give the identity that reaches the endpoint only the datasources necessary for the use case — Druid authorization applies to the caller of the statement you execute, not inside the generated text.
2. **Authorizer**: Use Druid's authorizer (for example the basic-security extension's roles and permissions) so the *executed* SQL is rejected unless its datasources and actions are permitted.
3. **Application-Side Filtering**: Enforce row-level visibility with Druid's row-level policies, or by running the agent over tenant-scoped datasources.

---

## Validation & Testing

FractalSQL includes a comprehensive test suite to ensure the pipeline's robustness:

- **Allowlist and refusals**: `tests/druid_service.py` (run by `build_test.sh`) drives the extension's `/fractalsql/text-to-sql` endpoint, including answers that must be refused: stacked statements, DDL and statements outside the allowed set.
- **Daemon conformance**: `build_test.sh` checks the daemon's frame protocol, the four reasoning contexts and the text-to-SQL settings against both the C and JVM daemons.
- **Live model**: pass `--llm URL` to `build_test.sh` to run the stack gates against a real OpenAI-compatible endpoint instead of the bundled mock.

---

## Known Limitations

- **Distinct-Value Sampling**: The current version does not sample enum-like columns (e.g., `'Completed'` vs `'completed'`) to help the LLM with value normalization.
- **Table Ranking**: Auto-discovery reads the catalog's datasources in order, without ranking them. On a very large schema, name the datasources you want in the `tables` argument.
- **Schema Caps**: `sql_agent`'s and the endpoint's explicit `tables` array is capped at 512 entries to bound prompt overhead; auto-discovery applies the same table-count cap.
