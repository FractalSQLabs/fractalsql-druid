<p align="center">
  <img src="../FractalSQLforDruid.jpg" alt="FractalSQL for Apache Druid" width="720">
</p>

# Docker Demo: The Learning Path

Try FractalSQL without installing anything. `docker/docker-compose.yml` builds
a turnkey Druid stack (ZooKeeper, a coordinator/overlord, a broker, a
historical, a middle manager and a router) with the extension baked into the
image and the reasoning provider pre-configured.

There is nothing to load by hand: the extension is a JAR in the image, listed in
`druid.extensions.loadList`. The demo environment is the SQL endpoint on the
router's port, plus the demo runner that feeds the demo scripts to it.

## 🛠️ Prerequisites

Docker and Docker Compose. The daemon image builds `fractalsqld` from source
inside the image; the Druid image copies in a prebuilt extension JAR, which you
build once on the host or take from a release (see
[Getting Started](getting-started.md#1-running-in-60-seconds-docker)). No local
Druid install is required.

---

## 🚀 Setup Guide

### 1. The turnkey default: `docker compose up -d`

One command, no flags, gives you the bare minimum:

- **A Druid cluster** with the FractalSQL extension loaded on every node:
  the JAR (with its native payload) at
  `/opt/druid/extensions/fractalsql-druid/`, and
  `druid.fractalsql.daemon_socket` in `docker/druid/common.runtime.properties`
  pointing it at the daemon.
- **`fractalsqld`**, the reasoning, embedding and enterprise service (see the
  [FractalSQL Daemon](fractalsql-daemon.md)), as its own container. No provider is configured until [step 2](#2-cognition-point-at-a-provider-opt-in).
- **The SQL endpoint** on the router's port: `http://localhost:8888/druid/v2/sql`.
- **Every demo script** in `demo/`, runnable through the demo runner
  (`demo/run_demo.py`) against that endpoint.

Set the shared signing key first: the extension and `fractalsqld` authenticate
every call with it, and the compose file refuses to start without it. Every
published port is bound to `127.0.0.1`: the demo is for a trusted workstation,
not an untrusted network.

```bash
export FSQL_HMAC_KEY=$(openssl rand -hex 32)
docker compose -f docker/docker-compose.yml up -d
```

**Quick test** (works with no model; the base search needs no LLM). Confirm the
extension is alive and which edition it is:
```bash
curl -s -X POST -H 'Content-Type: application/json' \
  --data-binary '{"query":"SELECT fractal_edition(), fractal_version()"}' \
  http://localhost:8888/druid/v2/sql
# expect: [{"EXPR$0":"Community","EXPR$1":"2.0.0"}]
```

Run any demo (re-runnable; each recreates its own fixture datasource):
```bash
python3 demo/run_demo.py --file demo/demo-vertical-rf-spectrum-sensing.sql
```

The runner splits the script into statements, submits the writes as MSQ
tasks and waits for them, runs the reads against the SQL endpoint, and prints
the results tab-separated. A statement that fails prints `ERROR ...` and the run
carries on.

The extension's `/fractalsql/*` endpoints live on the broker (8082), not on the
router, which forwards only Druid's own routes:

```bash
python3 demo/run_demo.py --file demo/demo.sql --service-url http://localhost:8082
```

Or run every demo in `demo/` in one pass with the `run_demo.sh` runner:
```bash
./demo/run_demo.sh
```

It runs each `demo/*.sql` as its own process, logs per file to
`/tmp/fractalsql_druid_demo_run/`, applies a per-file timeout (default 3600s,
`FSQL_DEMO_RUN_TIMEOUT`), retries a failing file once, and prints a final
`N ok, M non-zero exit` tally. A non-zero exit means "read that file's log", not
necessarily a bug: the usual cause is a reasoning demo run before step 2 is done,
and the enterprise demos report the tier as not loaded on a Community-only
install. Every demo ends with a `HEADLINE kit=<name> ok` or `... FAILED` row.
`run_demo.sh --help` lists the flags (`--quiet`, `--only`, `--skip`, `--url`,
`--service-url`).

To run any SQL by hand against the router, post it to the SQL endpoint:
```bash
curl -s -X POST -H 'Content-Type: application/json' \
  --data-binary '{"query":"SELECT 1"}' http://localhost:8888/druid/v2/sql
```

### Single host or multi-host

`docker compose up -d` is the **single-host** layout: one `fractalsqld`, and every Druid service
mounts its socket volume.

The daemon's Unix socket reaches only its own host, so in a cluster each host that serves FractalSQL
runs its own daemon. The **multi-host** profile shows that layout: it adds a second broker with its own
daemon, and each broker mounts only its own daemon's socket volume:

```bash
docker compose -f docker/docker-compose.yml --profile multihost up -d
```

| | Single host (default) | Multi-host (`--profile multihost`) |
| --- | --- | --- |
| Brokers | one, on `:8082` | two, on `:8082` and `:8084` |
| Daemons | one, shared by every service | one per broker, each with its own socket volume |
| Router (`:8888`) | one broker behind it | both brokers behind it |

Check that both brokers are in the cluster and that each answers through its own daemon:

```bash
curl -s -X POST -H 'Content-Type: application/json' \
  --data-binary '{"query":"SELECT COUNT(*) FROM sys.servers WHERE server_type = '"'"'broker'"'"'"}' \
  http://localhost:8888/druid/v2/sql
# expect: [{"EXPR$0":2}]
for port in 8082 8084; do
  curl -s -X POST -H 'Content-Type: application/json' \
    --data-binary '{"query":"SELECT fractal_embed('"'"'hello'"'"')"}' \
    http://localhost:$port/druid/v2/sql | cut -c1-60
done
```

The router spreads SQL over both brokers, and each answers through its own daemon. Call a broker
directly (`:8082` or `:8084`) for the `/fractalsql` endpoints. Session settings and the enterprise
ledger belong to the daemon, so a setting made through one broker is not seen through the other.

Stop the second daemon (`docker stop fractalsql-druid-fractalsqld-b`) and the second broker's reasoning
and embedding calls return `NULL`, while the first broker and every function that needs no daemon carry
on. Start it again and the second broker recovers without a restart.

With the enterprise library staged (next section), each daemon keeps its own ledger; collecting and
checking them is covered in [Enterprise Tier](enterprise.md#auditing-a-cluster-a-ledger-per-host).
Which hosts need a daemon is in [Druid integration](druid-integration.md#25-where-the-daemon-runs).

### 2. Cognition: point at a provider (opt-in)

Reasoning (`fractal_reason`, `fractal_embed`, `fractal_text_to_sql`) needs a
model. The provider is configured in the `fractalsqld` service, through
environment variables in your shell (or an `.env` file) that
`docker/docker-compose.yml` passes on:

```bash
export FSQL_HMAC_KEY=$(openssl rand -hex 32)
export FSQLD_REASONING_URL=http://<provider>:11434/v1/chat/completions
export FSQLD_REASONING_MODEL=gpt-oss:20b
export FSQLD_REASONING_ALLOW_PLAINTEXT=true
export FSQLD_EMBED_URL=http://<provider>:11434/v1/embeddings
export FSQLD_EMBED_MODEL=nomic-embed-text:latest
# a model that thinks before it answers (gpt-oss, o-series, DeepSeek-R1) can spend its whole token budget thinking; cap the effort
export FSQLD_THINK=low
export FSQL_REASONING_HTTP_TIMEOUT_MS=300000
```

Each `FSQLD_<KEY>` becomes a key in `fractalsqld.conf` (`FSQLD_REASONING_URL`
sets `reasoning_url`). These are operator settings that a query's context cannot
change; see [Reasoning Setup](reasoning-setup.md). After changing them, recreate
the stack:

```bash
docker compose -f docker/docker-compose.yml down -v
docker compose -f docker/docker-compose.yml up -d
```

On Docker Desktop, Docker Model Runner can serve the models with no separate
server to run: see
[reasoning-setup.md](reasoning-setup.md#docker-model-runner-dmr) and point
`FSQLD_REASONING_URL` and `FSQLD_EMBED_URL` at it.

Until a provider is configured, the cognition calls return a clean error.
CPU-only inference can take several minutes per query on modest hardware; the
timeout above is the cold-model-load budget (see the hardware section of
[Reasoning Setup](reasoning-setup.md)).

**Quick test** (now that a provider is configured):
```bash
python3 demo/run_demo.py --file demo/demo-vertical-rf-spectrum-sensing.sql
# the reasoning step now produces a full narrative
```

### 3. The demo datasource

The demo scripts create their own fixture datasources with MSQ writes, so
there is nothing to seed first. The `demo_vecs` datasource the demo stack
ships with is the one the base walkthrough uses:

```bash
scripts/ingest-demo.sh
```

### 4. Try the MCP server

The repo's [`mcp/`](../mcp/) directory builds the production MCP server
binary. It is a client of Druid's SQL endpoint and of the extension's
`/fractalsql` endpoints — see [MCP Plugin](mcp-plugin.md).

---

## 🎓 The Learning Path

Run the demos in this order to see the progression from a vector search tool to a
sovereign agentic database. (Cognition/Agency demos need a provider from step 2;
Discovery demos do not.)

### Level 1: Geometric Discovery
*Focus: Using the fractal core and domain-specific geometry to find structure in noise.*
- **Goal**: Learn to use SFS for high-precision convergence and domain-specific metrics (vascular, cortical, nerve).
- **Demos**:
  ```bash
  # RF: Spectrum Sensing and Interference Triage
  python3 demo/run_demo.py --file demo/demo-vertical-rf-spectrum-sensing.sql
  # Biotech: Cluster structure in single-cell embeddings
  python3 demo/run_demo.py --file demo/demo-vertical-biotech-genomics.sql
  # Climate Tech: Emissions and utility-leak detection
  python3 demo/run_demo.py --file demo/demo-vertical-climatech-emissions-monitoring.sql
  ```

### Level 2: Cognitive Synthesis
*Focus: Composing search with LLM reasoning to generate human-readable insights.*
- **Goal**: Learn to feed Scout Discovery results into `fractal_reason` and use `fractal_text_to_sql` for safe data exploration.
- **Demos**:
  ```bash
  # Recommendations: Advanced Discovery Engines
  python3 demo/run_demo.py --file demo/demo-vertical-recommendation-search.sql
  # Sovereign: Edge & Autonomous Systems AI
  python3 demo/run_demo.py --file demo/demo-vertical-sovereign-edge-ai.sql
  # BI: The Full Reasoning Loop (Question -> SQL -> Result -> Reason)
  python3 demo/run_demo.py --file demo/demo-business-intelligence.sql
  ```

### Level 3: Autonomous Agency
*Focus: Building self-correcting, safe, and predictive agentic workflows.*
- **Goal**: Learn to use loop detection (SimHash fingerprints + cycle detection), trajectory prediction, self-correcting SQL agents, and the sixteen installable agents built on top of them. See [api-agency.md](api-agency.md).
- **Demos**:
  ```bash
  # DevOps: Autonomous Incident Triage & Self-Healing
  python3 demo/run_demo.py --file demo/demo-vertical-agentic-ops-devops.sql
  # Support: Stateful Session & Churn Drift
  python3 demo/run_demo.py --file demo/demo-vertical-agentic-customer-support.sql
  # FinTech: MCTS Scenario Exploration & Safe Execution
  python3 demo/run_demo.py --file demo/demo-vertical-agentic-fintech-mcts.sql
  # Cyber: Threat Detection & Triage
  python3 demo/run_demo.py --file demo/demo-vertical-cybersecurity-threat-detection.sql
  # Edge Swarm: quantized swarm memory, loop detection, task routing (no reasoning needed)
  python3 demo/run_demo.py --file demo/demo-vertical-agentic-edge-swarm.sql
  # The sixteen agents
  python3 demo/run_demo.py --file demo/demo-agents.sql
  ```

See [Agent Recipes](api-agency.md#which-agent-should-i-use) for what each agent
does and when to use it.

### Other demos
`demo/` also contains `demo.sql` (the base walkthrough), `response-modes.sql`,
`demo-text-to-sql.sql`, the `text-to-sql-spike-*.sql` series,
`demo-fractal-vector.sql`, `benchmark.sql`, `benchmark-api-reference.sql`, and the
enterprise-tier `enterprise-qtl-audit.sql` / `enterprise-stress.sql` (see
[the enterprise tier](#the-enterprise-tier-opt-in) below). Run any the same way.

### The enterprise tier (opt-in)
The enterprise tier (the QTL ledger and the CISO audit) is the separately licensed
FractalSQL Enterprise core. It is not in the extension JAR or the community drop,
so the demo runs without it and the gated calls report the tier as not loaded.

To enable it, put the library and its detached Ed25519 signature in
`include/<platform>/`, beside the community core, and rebuild the daemon image:

```bash
# The .sig MUST sit beside the library: the daemon verifies the signature
# over the library's exact bytes before it loads it.
cp libfractalsql-enterprise-sovereign-c.so libfractalsql-enterprise-sovereign-c.so.sig \
   include/linux-x86_64/

docker compose -f docker/docker-compose.yml build fractalsqld
docker compose -f docker/docker-compose.yml up -d --force-recreate
```

The build takes the pair from `include/<platform>/` when it is there and leaves
the tier off when it is not. Git ignores the files, and an image built with them
contains the licensed library, so do not push it. The container's entrypoint sets
`enterprise_lib` and `enterprise_ledger_path` itself.

Check the tier's status on the broker:

```bash
curl -s -X POST -H 'Content-Type: application/json' \
  -d '{"action":"status"}' http://localhost:8082/fractalsql/ledger
```

```json
{"loaded": true, "library": "/opt/fractalsql/libfractalsql-enterprise-sovereign-c.so",
 "ledger_path": "/opt/druid/var/fractalsql/fractalsql_ledger.dat",
 "edition": "Community", "destructive_locked": false}
```

`"loaded": true` means the signature verified and the library loaded.
`"loaded": false` means the tier is dormant; see [Enterprise Tier](enterprise.md)
for the signature policy.

---

## 📊 Validation & Benchmarks

### The gate suite
The extension is verified against a live Druid, end to end:

```bash
./build_test.sh           # Linux; the cluster gates need Docker
```

The gates cover the daemons (build, protocol conformance, security and
config), the extension (native payload, unit tests, packaged JAR), the MCP
server, and then, against a live stack, the SQL functions, the service
endpoints, every MCP tool family and the demo runner. `./build_test.sh --list`
prints the full matrix.

### Scout Discovery vs. naive top-K (run directly against the cluster)
See how Scout Discovery captures more distinct clusters than standard top-K
search; `demo/benchmark.sql` runs both directly against a synthetic
cluster corpus:

```bash
python3 demo/run_demo.py --file demo/benchmark.sql
```

### Full API surface
`demo/benchmark-api-reference.sql` exercises the full function surface (Search,
Reason, Agents, Analytics) in one pass:
```bash
python3 demo/run_demo.py --file demo/benchmark-api-reference.sql
```

---

## 🧹 Cleanup

```bash
docker compose -f docker/docker-compose.yml down -v
```

`-v` removes the named volumes (Druid's segment and metadata storage); drop it to
keep them.
