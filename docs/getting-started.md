<p align="center">
  <img src="../FractalSQLforDruid.jpg" alt="FractalSQL for Apache Druid" width="720">
</p>

# Getting Started: From Zero to Your First Agent

This guide takes you from a fresh checkout to a running agentic Druid cluster
in about ten minutes: no Druid install and no model download required to
start. By the end you will have:

- a Druid cluster with the FractalSQL extension loaded, and `fractalsqld`
  running beside it,
- a diverse vector search that runs with **no model** connected,
- a live reasoning call against a real LLM, and
- all 16 agents demoable on demand (15 run on Community; the 16th,
  `fractal_agent_diverse_portfolios`, needs the [enterprise library](enterprise.md)
  and returns a clear "enterprise tier not loaded" error without it).

The fastest path is Docker. For a real Druid cluster, start at
[Install without Docker](#5-install-without-docker) and come back for the first
search and first agent.

> **The 10-minute path:** [1. Running in 60 seconds](#1-running-in-60-seconds-docker)
> → [2. Your first search](#2-your-first-search-no-model-needed)
> → [3. Turn on reasoning](#3-turn-on-reasoning) → [4. Your first agent](#4-your-first-agent)
> → [where next](#where-next).

| You need | |
| --- | --- |
| Apache Druid | 37 or 38, on **Linux or macOS** |
| Java | 17, 21 or 25 to run Druid (the JAR is Java 17 bytecode; Druid 37's image runs 17, Druid 38's runs 21); JDK 17 or newer to build it |
| Docker | for the demo stack |

---

## 1. Running in 60 seconds (Docker)

The Druid image copies in a prebuilt extension JAR, so get one first. Either
take `fractalsql-druid-extension.jar` from the latest
[release](https://github.com/FractalSQLabs/fractalsql-druid/releases) (it carries the native payload for every
platform), or build it on Linux from the repo root (the native shim first, then the JAR):

```bash
sh druid-extension/src/main/native/build-native-linux.sh linux-x86_64   # or linux-aarch64
mvn -f druid-extension/pom.xml package -DskipTests
```

Stage the JAR where the image build reads it:

```bash
mkdir -p docker/druid/extensions/fractalsql-druid
cp druid-extension/target/fractalsql-druid-*.jar \
   docker/druid/extensions/fractalsql-druid/fractalsql-druid.jar   # or the downloaded release JAR
chmod 0755 docker/druid/extensions docker/druid/extensions/fractalsql-druid
chmod 0644 docker/druid/extensions/fractalsql-druid/fractalsql-druid.jar
```

Set the shared signing key (the extension and `fractalsqld` authenticate every call with it, and the compose
file refuses to start without it), then bring the stack up. Every published port is bound to `127.0.0.1`; the
demo is for a trusted workstation.

```bash
export FSQL_HMAC_KEY=$(openssl rand -hex 32)
docker compose -f docker/docker-compose.yml up -d
```

That starts ZooKeeper, a coordinator (which also runs the overlord), a broker, a historical, a middle manager
and a router, plus `fractalsqld`, with the extension baked into the Druid image. No model is configured yet;
you add a provider in [step 3](#3-turn-on-reasoning). The demo scripts are in `demo/`.

Verify FractalSQL is alive once the router is up (about half a minute):

```bash
curl -s -X POST -H 'Content-Type: application/json' \
  --data-binary '{"query":"SELECT fractal_edition(), fractal_version()"}' \
  http://localhost:8888/druid/v2/sql
```

```
[{"EXPR$0":"Community","EXPR$1":"2.0.0"}]
```

> **No Python on your host?** The demo runner is a standard-library Python 3.8+
> script. Every call below can also be made with `curl` against the router
> (`:8888`) and the broker (`:8082`, where the `/fractalsql/*` endpoints live).

---

## 2. Your first search (no model needed)

FractalSQL's core is a **Stochastic Fractal Search** optimizer. It comes in
two flavours that solve different problems:

- **Sniper** (`fractal_search`): converge to the single best point in a
  continuous space.
- **Scout** (`fractal_search_explore`): discover the *diverse* structure of
  your own data, finding distinct "islands" instead of collapsing to one
  nearest neighbour.

Scout is what makes FractalSQL different from a plain vector DB, and it runs
with **no model connected**. Druid has no DDL, so the demo runner loads a small
fixture datasource with an MSQ write, then runs both searches against it:

```bash
cat > first-search.sql <<'sql'
-- @fixture demo_points {"rows": [
--   {"ts": "now", "id": 1, "pt": "[0.1,0.1,0.1]"},
--   {"ts": "now", "id": 2, "pt": "[0.9,0.9,0.9]"},
--   {"ts": "now", "id": 3, "pt": "[0.2,0.8,0.2]"}
-- ]};

-- Sniper: converge toward the query, one score per row
SELECT "id", fractal_search("pt", '0.5,0.5,0.5') AS "dist"
FROM "demo_points"
GROUP BY "id"
ORDER BY "dist" ASC;

-- Scout: discover the distinct basins in the data (not just the closest row)
-- @call search/explore {"datasource": "demo_points", "vectorColumn": "pt", "idColumn": "id",
--                       "query": "0.5,0.5,0.5", "k": 3,
--                       "params": "{\"population_size\": 20, \"iterations\": 10, \"walk\": 0}"} AS scout;
SELECT "ord", "doc_id" FROM "scout";   -- the picked rows, as ids from your id column
sql

python3 demo/run_demo.py --file first-search.sql
```

You get a spread of rows from the distinct clusters in your datasource, where a
`top-K` query would return three rows from the same neighbourhood. Re-running it
is safe: the fixture is replaced each time.

Two Druid SQL rules shape these queries: in an aggregating query every projected
column must be a grouping key, and a non-aggregating query can only `ORDER BY`
`__time`, so a query that ranks by a computed value has to aggregate (`GROUP BY
"id"` is still one group per row). [Druid integration](druid-integration.md)
explains why, and which parts of the surface are SQL expressions and which are
`/fractalsql` service calls.

→ For the Scout-vs-top-K benchmark that makes the difference concrete, see
**[docs/docker-demo.md](docker-demo.md)** (`demo/benchmark.sql`).

---

## 3. Turn on reasoning

Search finds data; **reasoning** turns it into insight, and it is opt-in. Point
`fractalsqld` at a provider: Ollama locally, or AWS Bedrock, Azure OpenAI or GCP
Vertex in the cloud. The provider is an operator setting in the daemon's
configuration; a request cannot change it.

With the Docker stack, the settings are environment variables that become
`fractalsqld.conf` keys. Point them at Ollama (or any OpenAI-compatible endpoint)
and recreate the stack:

```bash
export FSQLD_REASONING_URL=http://<provider>:11434/v1/chat/completions
export FSQLD_REASONING_MODEL=gpt-oss:20b
export FSQLD_REASONING_ALLOW_PLAINTEXT=true     # only for a plain-HTTP endpoint you trust
export FSQLD_EMBED_URL=http://<provider>:11434/v1/embeddings
export FSQLD_EMBED_MODEL=nomic-embed-text:latest
export FSQLD_THINK=low                           # cap a thinking model's effort so it answers
docker compose -f docker/docker-compose.yml down -v
docker compose -f docker/docker-compose.yml up -d
```

(Run `ollama pull gpt-oss:20b` and `ollama pull nomic-embed-text` once on the provider: about 13.8 GB and a few
hundred MB.) Then reason:

```bash
curl -s -X POST -H 'Content-Type: application/json' \
  --data-binary '{"query":"SELECT fractal_reason('"'"'Reply with exactly: FSQL_LIVE_OK'"'"', '"'"''"'"') AS reply"}' \
  http://localhost:8888/druid/v2/sql
```

```
[{"reply":"FSQL_LIVE_OK"}]
```

The embedder works the same way (it powers the vectorizer and any RAG-style agent):

```sql
SELECT fractal_vector_dims(fractal_embed('hello world')) AS embed_dim;
--  768
```

→ For a cloud endpoint, the daemon's keys and slow-hardware timeouts, see
**[docs/reasoning-setup.md](reasoning-setup.md)**.

---

## 4. Your first agent

The **Agent Tier** composes Discovery + Cognition into self-correcting
routines. On Druid an agent is an HTTP operation on the extension
(`POST /fractalsql/agent/<name>`), because it reads a datasource and reasons
over the result, which a scalar SQL expression cannot do. One script exercises
all **16 agents** end to end: anomaly triage, portfolio allocation, hybrid recall,
route planning, deterioration triage, regime detection, and the rest:

```bash
python3 demo/run_demo.py --file demo/demo-agents.sql
```

Each section loads its own fixture datasources (replaced on each run) and calls
one agent. With a model configured every section gives reasoned output; without
one, retrieval and optimization still run and only the closing narrative is
missing. On a Community build the file prints one expected error, from the
enterprise-tier agent, and carries on.

Prefer a specific industry? The vertical demos are one command each, e.g.
cybersecurity threat detection:

```bash
python3 demo/run_demo.py --file demo/demo-vertical-cybersecurity-threat-detection.sql
```

→ To pick the right agent for your problem, see the decision table in
**[docs/api-agency.md](api-agency.md#which-agent-should-i-use)**. To pick the
right *industry* starting point, see
**[docs/starter-kits.md](starter-kits.md)**.

---

## 5. Install without Docker

### Option A: one command

`easy_install.sh`, published with every release, picks the right package for the
machine, checks it against the release's `SHA256SUMS`, installs it, and prints what to add to Druid:

```bash
curl -fsSL https://github.com/FractalSQLabs/fractalsql-druid/releases/latest/download/easy_install.sh | bash
# or, copying the extension into a Druid installation as well:
curl -fsSL https://github.com/FractalSQLabs/fractalsql-druid/releases/latest/download/easy_install.sh | bash -s -- --druid-home /opt/druid
```

It takes `--version`, `--from-file`, `--druid-home`, `--yes`, `--dry-run` and `--uninstall` (see `--help`), and it
never edits your Druid configuration or starts anything. It uses the `.deb` on Debian and Ubuntu, the `.rpm` on Red Hat
family systems, the zip on macOS and the tarball elsewhere. It sends no telemetry.

### Option B: manual / air-gapped

For a compliance environment or an air-gapped box, take the packages from
[GitHub Releases](https://github.com/FractalSQLabs/fractalsql-druid/releases). The Linux packages are built on glibc
2.34, so they install on RHEL 9 (and Rocky or Alma 9), Ubuntu 22.04, Debian 12 and anything newer. The daemon needs
Java 17 or newer. File names carry no version, so `releases/latest/download/<name>` is always the newest.

| Platform | Package |
| --- | --- |
| Debian, Ubuntu | `fractalsql-druid-amd64.deb`, `fractalsql-druid-arm64.deb` |
| RHEL, Rocky, Alma | `fractalsql-druid-amd64.rpm`, `fractalsql-druid-arm64.rpm` |
| Any Linux | `fractalsql-druid-linux-amd64.tar.gz`, `fractalsql-druid-linux-arm64.tar.gz` |
| macOS | `fractalsql-druid-macos-amd64.zip`, `fractalsql-druid-macos-arm64.zip` |
| Just the extension | `fractalsql-druid-extension.jar` |

```bash
# Debian / Ubuntu
sudo apt install ./fractalsql-druid-amd64.deb

# RHEL / Rocky / Alma
sudo dnf install ./fractalsql-druid-amd64.rpm
```

On macOS, and for a tarball anywhere, unpack the bundle and run its installer:

```bash
tar -xzf fractalsql-druid-linux-<arch>.tar.gz          # macOS: unzip fractalsql-druid-macos-<arch>.zip
cd fractalsql-druid-<version>
./install.sh --druid-home /opt/druid          # add --dry-run to see what it would do
```

Each package holds the extension JAR (with the native payload for every platform), the daemon `fractalsqld`, its CLI
`fsqlctl`, the MCP server `fractalsql-druid-mcp`, and the two ledger tools (see
[Enterprise Tier](enterprise.md#auditing-a-cluster-a-ledger-per-host)). The installer copies the JAR into
`<druid-home>/extensions/fractalsql-druid/`, installs the daemon and tools under `/usr/local` (`--prefix` changes
that), writes a daemon config and a random signing key if none exist, and prints the Druid runtime properties to add.
It does not edit your Druid configuration or start anything; `--no-daemon` installs the extension only. The JAR is
also on GitHub Packages (`com.fractalsqlabs:fractalsql-druid`), which needs a token to download; for a plain download
use `fractalsql-druid-extension.jar` from the release. Package contents and requirements are in
[packaging/README.md](../packaging/README.md).

**By hand.** Druid's extension loader treats each entry of `druid.extensions.loadList` as a **directory** and scans it
for `*.jar`. So the JAR goes in

```
<druid>/extensions/fractalsql-druid/fractalsql-druid.jar
```

and the runtime properties gain:

```properties
druid.extensions.loadList=["fractalsql-druid", ...]
```

Restart the node. The extension should now appear in the routine catalog:

```sql
SELECT "ROUTINE_NAME", "IS_AGGREGATOR", "SIGNATURES"
FROM INFORMATION_SCHEMA.ROUTINES
WHERE "ROUTINE_NAME" = 'fractal_search';
```

```
[{"ROUTINE_NAME":"fractal_search","IS_AGGREGATOR":"YES",
  "SIGNATURES":"'fractal_search(<ARRAY>, <CHARACTER>)'"}]
```

> **If that query returns nothing, the extension did not load.** The usual
> cause is the SPI file name: it must be
> `META-INF/services/org.apache.druid.initialization.DruidModule`.
> A wrong name fails *silently*: there is no error anywhere.

Reasoning and embedding calls need [`fractalsqld`](fractalsql-daemon.md) on the host that runs your brokers, with the
extension pointed at its socket (see [Druid integration](druid-integration.md#25-where-the-daemon-runs)). Provider
setup is in **[docs/reasoning-setup.md](reasoning-setup.md)**.

### Build it yourself

From the repo root: the native shim for your platform first, then the JAR, which packages the shim.

```bash
# one of: linux-x86_64, linux-aarch64, darwin-x86_64, darwin-arm64
sh druid-extension/src/main/native/build-native-linux.sh linux-x86_64
mvn -f druid-extension/pom.xml package
```

This needs JDK 17 or newer and Maven 3.9 or newer. On Java 24 and newer the JVM warns when native code loads; add
`--enable-native-access=ALL-UNNAMED` to the Druid JVM options (`JAVA_OPTS` for the Druid image) to silence it. The
daemon's launchers already pass it. The module's build reference is
[druid-extension/README.md](../druid-extension/README.md).

To run the tests:

```bash
./build_test.sh                 # the whole suite
./build_test.sh --quick         # the gates that need no Docker
./build_test.sh --list          # list the gates
./build_test.sh --gate <n>[,<n>]  # only these gates
```

The gates that run against a live cluster need Docker and skip loudly when no daemon is reachable. `build_test.sh` also
has sanitizer, coverage, fuzz, fault and profile modes for the native code (see the usage comment at the top of the
script).

---

## Where next

You have finished step 2 of the path in the [README](../README.md).

| Step | Question | Go to |
|------|----------|-------|
| 3 | *"How do I apply this to **my** industry?"* | **[docs/starter-kits.md](starter-kits.md)** |
| 4 | *"How does a specific agent work, and what are its inputs?"* | **[docs/api-agency.md](api-agency.md)** |
| 5 | *"How do I build a proprietary agent that isn't in the box?"* | **[docs/composition-guide.md](composition-guide.md)** |

For the full Docker walkthrough (multi-host layout, enterprise tier, demo datasource), see
**[docs/docker-demo.md](docker-demo.md)**. For how the extension is built and the Druid constraints behind it, see
**[docs/druid-integration.md](druid-integration.md)**.
