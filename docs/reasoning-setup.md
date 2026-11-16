<p align="center">
  <img src="../FractalSQLforDruid.jpg" alt="FractalSQL for Apache Druid" width="720">
</p>

# Sovereign Reasoning Setup Guide

The **Cognition Tier** is the intelligence layer of FractalSQL. It provides a pluggable bridge that lets Druid call Large Language Models (LLMs) and embedding providers directly from SQL.

By bringing reasoning directly into your Druid cluster, FractalSQL lets you synthesize, analyze, and reason over your data without an external application-middleware hop. Sovereignty here is a deployment choice, not a guarantee baked into every provider: local models (Ollama/vLLM) keep data on your own infrastructure, while cloud providers (Bedrock, Azure OpenAI, Vertex) send it to that provider under your own account and compliance agreement.

---

## 🧠 The Cognition Model

At its core, the Cognition tier provides the `fractal_reason(query, context)` primitive. Unlike traditional RAG, which relies on external orchestrators, FractalSQL performs the synthesis through `fractalsqld`, the service that runs beside your brokers:

1. **Context Assembly**: You use ordinary SQL (subqueries, `ARRAY_AGG`/`JSON_OBJECT`, or the `/fractalsql/search/explore` Scout endpoint) to gather the precise data needed.
2. **Sovereign Dispatch**: The extension dispatches the query and context to `fractalsqld`, which calls your configured LLM through the reasoning plugin.
3. **In-Place Synthesis**: The response is returned directly into your query result, allowing you to combine reasoning with standard SQL filters, joins, and aggregations in a single statement.

---

## 🛠️ Prerequisites

To activate the Cognition tier, you need a reasoning plugin and a configured endpoint.

### 1. The Reasoning Plugin
The reasoning plugin (`fractalsql-reasoning-http.so`; note the `.so` suffix on macOS too) is installed alongside the extension. Installing the file does not activate the feature; you must set the plugin path as `reasoning_plugin` in `fractalsqld.conf`.

It sits beside `fractalsqld`, the daemon that hosts the provider client, on Linux and macOS alike.

### 2. Technical Requirements
- **Extension Version**: `fractalsql-druid` 2.0.0+ (`SELECT fractal_version();`).
- **Plugin Version**: `fractalsql-reasoning-http` v1.2.1+ (required for Response Modes and System Tags).
- **Host Dependencies**: `libcurl` 7.75.0+ on the host that runs `fractalsqld` (required for AWS SigV4 auth).
- **Endpoint**: An LLM provider (Ollama, AWS Bedrock, Azure OpenAI, GCP Vertex, or any OpenAI-compatible API).

> **Shortcut**: the Docker stack in `docker/docker-compose.yml` starts `fractalsqld`
> and writes `fractalsqld.conf` for you from `FSQLD_*` environment variables
> (`FSQLD_REASONING_URL` sets `reasoning_url`, and so on); see
> **[docs/docker-demo.md](docker-demo.md)**. The walkthrough below still applies for
> Bedrock, Azure and Vertex.

---

## 🚀 Setup Sequence

The settings below are **operator keys** in `fractalsqld.conf`, beside the broker (one daemon per host that needs it; see [Druid integration](druid-integration.md#25-where-the-daemon-runs) and the [FractalSQL Daemon](fractalsql-daemon.md#provider-keys) page for every key). A request's query context cannot change them. The extension only needs to reach the service (`druid.fractalsql.daemon_socket`, `druid.fractalsql.daemon_hmac_key_file`). After editing the file, apply it with `fsqlctl -s <socket> -k <keyfile> reload`; `socket_path` and `hmac_key_file` need a restart.

## Step 1: Activate the Plugin
Add the following to `fractalsqld.conf`:

```ini
# Plugin path must be absolute (traversal-hygiene validated at load time)
reasoning_plugin = /opt/fractalsql/fractalsql-reasoning-http.so
```
The plugin attaches lazily upon the first reasoning call; changing `reasoning_plugin` and running `fsqlctl reload` makes the next call re-attach from the new path.

## Step 2: Universal LLM Connectivity
There is no provider lock-in: your SQL calls to `fractal_reason()` are identical whether the model is local or in the cloud. Pick your provider and add its block to the configuration; only one block should be active at a time.

## Ollama (Local or Private Network)
For air-gapped deployments: traffic stays inside your network.

```ini
# Local Ollama
reasoning_url             = http://127.0.0.1:11434/v1/chat/completions
reasoning_allow_plaintext = on
reasoning_model           = gpt-oss:20b
```
*Note: Run `ollama pull gpt-oss:20b` or `ollama pull gemma4:12b` or `ollama pull phi4:14b` before connecting.*

## Docker Model Runner (DMR)
On Docker Desktop, Docker Model Runner serves local models through an OpenAI-compatible endpoint with no separate
container. Enable host access once (`docker desktop enable model-runner --tcp 12434`, or Settings → Beta features):

```ini
# Docker Model Runner (host-side access)
reasoning_url             = http://127.0.0.1:12434/engines/v1/chat/completions
reasoning_allow_plaintext = on
reasoning_model           = ai/gpt-oss:20b   # or ai/gemma4:12b or ai/phi4
```
*Note: Run `docker model pull ai/gpt-oss:20b` (or `ai/gemma4:12b` / `ai/phi4`) first; `docker model list` shows what is pulled. From inside another container, use `http://model-runner.docker.internal/engines/v1/chat/completions` (no port or host-TCP step).*

## OpenAI-Compatible (OpenAI, Together AI, Fireworks, vLLM)
```ini
reasoning_url   = https://api.openai.com/v1/chat/completions
reasoning_token = sk-...
reasoning_model = gpt-4o-mini
```

## AWS Bedrock
Bedrock uses AWS SigV4 signing. The URL must point to the **OpenAI-compatible** surface.

```ini
reasoning_url   = https://bedrock-runtime.us-east-1.amazonaws.com/openai/v1/chat/completions
reasoning_model = amazon.nova-lite-v1:0
```
**Critical**: Auth type and region are set via the reasoning plugin's own
lower-level environment variables, not `fractalsqld.conf` keys:
```sh
export FSQL_REASONING_HTTP_AUTH_TYPE=aws-sigv4
export FSQL_REASONING_HTTP_AWS_REGION=us-east-1
```

## Azure OpenAI
Azure requires a separate deployment for the chat model.

```ini
reasoning_url   = https://<resource>.openai.azure.com/openai/deployments/<deployment>/chat/completions?api-version=2024-02-01
reasoning_token = <azure-api-key>
reasoning_model = gpt-4o
```

## Google Vertex AI
Vertex AI exposes an OpenAI-compatible endpoint on your project's regional endpoint. Auth is a Google
service-account OAuth access token (a short-lived bearer), supplied via `reasoning_token` like an API key.

```ini
reasoning_url   = https://{LOCATION}-aiplatform.googleapis.com/v1/projects/{PROJECT}/locations/{LOCATION}/endpoints/openapi/chat/completions
reasoning_token = <gcp-oauth-access-token>
reasoning_model = google/gemini-2.5-flash
```

**Generating the token**: `reasoning_token` must be an access token for a service account with the Vertex AI User
role. With a service-account JSON key and the gcloud CLI:

```sh
gcloud auth activate-service-account --key-file=sa-key.json
gcloud auth print-access-token    # paste the output into reasoning_token
```

The token lasts about an hour. For a long-running install, refresh it on a schedule: re-run
`print-access-token`, rewrite the `reasoning_token` line in `fractalsqld.conf`, and run `fsqlctl reload`. The new
token applies from the next call, with no restart.

---

## ⚖️ Hardware & Performance (Local Reasoning)

For users deploying Ollama locally, hardware affects "cold-load" latency.

| Resource | Recommendation | Notes |
| --- | --- | --- |
| **GPU VRAM** | 8GB $\rightarrow$ 16GB | 8GB runs Phi-4/Gemma4 (Q4); 16GB runs GPT-OSS 20B. |
| **System RAM** | 16GB+ | Covers model, OS, and the Druid node's overhead. |
| **CPU** | AVX2 Support | Essential for acceptable CPU-side inference (Post-2016). |

### Handling Constrained Hardware
Local models can take up to 300s to cold-load. To keep `curl` from aborting the request, raise the timeout and low-speed windows in the `fractalsqld` process environment, where the plugin runs:

```sh
export FSQL_REASONING_HTTP_TIMEOUT_MS=330000
export FSQL_REASONING_HTTP_LOW_SPEED_SECS=300
```
*Note: These are plugin environment variables, not config keys; set them before launching `fractalsqld`. Raise `druid.fractalsql.daemon_timeout_ms` to match, so the extension waits as long as the service.*

---

## 🛠️ Advanced Configuration

Every advanced knob at a glance -- details for each are in the sections below:

| Variable | Notes |
| --- | --- |
| `FSQL_REASONING_HTTP_RESPONSE_MODE` | `text` (default) / `code` / `json` -- see [Response Modes](#response-modes) |
| `think` | Reasoning effort for hybrid-thinker models -- see [Reasoning Effort](#reasoning-effort) |
| `think_provider` | Request shape THINK uses -- see [Reasoning Effort](#reasoning-effort) |
| `think_native_url` | Override URL for the ollama/anthropic native shape |
| `think_num_ctx` | Ollama-native context-window cap |
| `FSQL_REASONING_HTTP_AUTH_TYPE` | `bearer` (default) / `api-key` / `aws-sigv4` -- see [AWS Bedrock](#aws-bedrock) |
| `FSQL_REASONING_HTTP_AWS_REGION` | AWS region for `aws-sigv4` |
| `FSQL_REASONING_HTTP_TIMEOUT_MS` | Total request timeout -- see [Handling Constrained Hardware](#handling-constrained-hardware) |
| `FSQL_REASONING_HTTP_LOW_SPEED_SECS` | Slow-response abort window |
| `FSQL_REASONING_HTTP_SYSTEM_PROMPT` | Replaces the baseline anti-injection system prompt -- see [Security & Governance](#-security--governance) |

`think` / `think_provider` / `think_native_url` / `think_num_ctx` are
`fractalsqld.conf` keys (apply with `fsqlctl reload`; a session may override `think` and
`think_num_ctx` with `fractal_config_set`); everything
else in the table is a process environment variable read once at plugin init.

### Response Modes
Shape how the plugin post-processes the LLM response via environment variables:
- `text` (default): Raw content.
- `code`: Forces a single fenced code block and extracts it.
- `json`: Forces a fenced JSON block and validates structural integrity.

Applies to `fractal_reason`

This is not a config key: set `FSQL_REASONING_HTTP_RESPONSE_MODE` in the `fractalsqld` environment and restart
`fractalsqld`; a reload is not enough.

#### The four contexts, on Druid

The reasoning tier runs through four independent contexts, each with its own response mode. The plugin reads its
configuration once, at initialisation, so `fractalsqld` keeps one plugin instance per context.

| Context | Response mode | What it is for |
| --- | --- | --- |
| chat | **the operator's choice**: `text` (the default), `code` or `json` | a question answered in prose -- `fractal_reason`, an agent's rationale |
| text-to-SQL | **code**, hardcoded | a statement generated; the fenced-block extraction is what makes the statement come back clean enough for Druid's parser |
| review | **text**, hardcoded | a PASS/FAIL judgment on a candidate; the verdict is read off the front of the answer |
| embed | **embedding**, hardcoded | a vector |

Only the chat context's mode is yours to choose; the other three are fixed, since a review returned as a code
block could not be judged and a generated statement returned as prose could not be planned. Set the chat mode in
the `fractalsqld` process's environment, and restart `fractalsqld` for a change to take effect:

```sh
export FSQL_REASONING_HTTP_RESPONSE_MODE=text
```

The review context has its own endpoint, so a caller can have a candidate judged without composing the prompt:

```sh
curl -s -X POST http://localhost:8082/fractalsql/review \
  -H 'Content-Type: application/json' \
  -d '{"question": "How many rows are in t?", "sql": "SELECT COUNT(*) FROM t"}'
```

The answer's first line is the verdict, and the response carries a `passed` flag alongside the critique.

### Reasoning Effort
Hybrid-thinker models (Granite 4.2, OpenAI o-series, Claude extended thinking, DeepSeek-R1, QwQ) emit an internal reasoning trace before their final answer -- left uncontrolled, that trace dominates latency and, on memory-constrained GPUs, VRAM. Four config keys throttle it:

| Config key (`fractalsqld.conf`) | Values | Notes |
| --- | --- | --- |
| `think` | unset (default) / `none` / `off` / any other string (`low`, `medium`, `high`, `minimal`, `xhigh`, `max`, ...) | Unset (or `none`) sends no thinking-control field, so the model's own default applies. `off` explicitly disables thinking on the wire -- not the same thing, since a hybrid-thinker model's own default is often ON. Any other value is forwarded to the provider verbatim, not checked against a fixed list -- provider effort scales keep adding tiers, so this plugin doesn't hardcode any one vendor's current names. Applies to `fractal_reason()` and text-to-SQL's GENERATE and REVIEW steps only -- never `fractal_embed()`. |
| `think_provider` | unset (defaults to `openai`) / `openai` / `ollama` / `anthropic` / `vllm` / `grok` | Selects the request SHAPE, not a vendor -- `openai` also covers Azure OpenAI, AWS Bedrock, and Google Vertex AI's OpenAI-compatible surfaces, since this is independent of how `reasoning_url` is authenticated. `grok` is for xAI's Grok models on Bedrock's OpenAI-compatible surface, which take a nested `reasoning.effort` field instead of `openai`'s top-level one. Ollama and Anthropic speak a native request shape instead, since their OpenAI-compatible endpoints don't honor thinking control. Ignored entirely when `think` is unset. |
| `think_native_url` | unset (default) / URL | Only consulted for the ollama/anthropic native shape. Leave unset to target `reasoning_url` verbatim. |
| `think_num_ctx` | unset (default) / positive integer (1 to 10000000) | Ollama-native context window cap (`options.num_ctx`) -- a measured fix for hybrid-thinker VRAM blowup on memory-constrained GPUs. Only applies when `think_provider=ollama`. |

```ini
# Local Ollama, medium reasoning effort, capped context window
think          = medium
think_provider = ollama
think_num_ctx  = 16384
```

The plugin never surfaces the reasoning trace itself -- `fractal_reason()`/`fractal_text_to_sql()` still return the final answer only, regardless of `think_provider`'s shape.

### Target-System Hints
Text-to-SQL passes `Apache Druid SQL` to the model as the target system on every call, so the model uses syntax appropriate for Druid. No setting is needed.

---

## 🔒 Security & Governance

### The Sovereign Guardrail: Dedicated Roles
Druid authorizes access to datasources through its authorizer (for example the basic-security extension's roles and permissions). Give the identity that reaches the `/fractalsql` endpoints only the datasources you want the LLM to be able to see, and expose the endpoints only to callers you trust with them. Config path keys must be absolute with no traversal
segments, enforced by strict validation when `fractalsqld` loads its configuration.

Never expose more of the cluster to a reasoning call than the LLM needs. A restricted-datasource pattern works well: put the LLM-facing columns in a datasource of their own and point `/fractalsql/schema-context` at it, rather than at the base datasources.

### Row-Level Security (RLS)
Enforce row-level visibility with Druid's row-level policies (or a tenant-scoped datasource), so the context subquery only returns rows the connecting user is permitted to see. This prevents "cross-tenant" data leakage to the LLM.

### Prompt Injection (OWASP LLM01)
The plugin prepends a baseline anti-injection instruction to every system message as a best-effort mitigation. No system-prompt instruction can fully prevent prompt injection from untrusted context, since the model still can't reliably distinguish instructions from data. Treat it as raising the bar, not closing the door. The real defense is architectural: RLS and column-level grants restricting what the context subquery can see (above), and treating every LLM response as untrusted output, never executed as SQL (see the checklist below). To replace the baseline instruction, set `FSQL_REASONING_HTTP_SYSTEM_PROMPT`.

---

## 📋 Production Checklist

- [ ] **Plugin Path**: the `reasoning_plugin` config value is absolute, has no `..` segments, and is readable by the `fractalsqld` user.
- [ ] **Service Configuration**: `fractalsqld.conf` and `hmac.key` are not readable by other users (the conf contains `reasoning_token` in plain text), and `allowed_uids` lists only the users that run Druid.
- [ ] **Access Model**: the identity that reaches `/fractalsql` is authorized only for the datasources the LLM may see.
- [ ] **Isolation**: tenant-sensitive rows are only reachable through row-level policies or tenant-scoped datasources.
- [ ] **Egress Review**: Cloud endpoints' DPA/BAA have been reviewed for the specific data classification.
- [ ] **Environment**: `FSQL_REASONING_HTTP_AUTH_TYPE` is correctly exported to the `fractalsqld` process environment (not just the config file).
- [ ] **Output Safety**: LLM responses are treated as untrusted display text and never executed as SQL.
