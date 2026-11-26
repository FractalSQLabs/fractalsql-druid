<p align="center">
  <img src="../FractalSQLforDruid.jpg" alt="FractalSQL for Apache Druid" width="720">
</p>

# FractalSQL demo

`demo.sql` is a runnable, five-minute walkthrough of search and
reasoning in one script: Sniper Search, Scout Discovery, and LLM
reasoning — including Scout's output feeding straight into a reasoning
call, which is the pattern the rest of the docs point at but don't show
running end to end in one place. Text-to-SQL has its own walkthrough —
see [Text-to-SQL](#text-to-sql) below.

`response-modes.sql` is a companion script for `text` / `code` / `json`
response modes — see [Response modes](#response-modes) below for why
it's a separate file from `demo.sql`.

## Prerequisites

1. **The Druid stack is up and the extension is loaded.** Start with
   [../docs/getting-started.md](../docs/getting-started.md), or bring the
   whole stack up with `docker compose -f docker/docker-compose.yml up -d`
   — see [../docs/docker-demo.md](../docs/docker-demo.md). The extension
   is a JAR in the image, named in `druid.extensions.loadList`; the SQL
   endpoint is the router's `http://localhost:8888/druid/v2/sql`.

2. **Reasoning is configured.** Sections 0–2 of `demo.sql` only need the
   extension itself, but sections 3–4 call `fractal_reason()`, which
   needs a working LLM endpoint. Follow
   [../docs/reasoning-setup.md](../docs/reasoning-setup.md) first —
   Ollama, AWS Bedrock, Azure OpenAI, GCP Vertex, and any OpenAI-compatible
   endpoint are all documented there. Configuration is **operator**
   configuration on Druid: the settings live in `fractalsqld.conf`
   beside the broker and a request cannot change them. Confirm it works before running this demo:

   ```sql
   SELECT fractal_reason('reply with a short confirmation that this works', '{}');
   ```

   If that comes back empty, `demo.sql` will hit the same thing at
   section 3 — fix it there first rather than debugging through the demo
   script.

## Running it

The demos run through `demo/run_demo.py`, which speaks Druid's SQL
endpoint and its MSQ task endpoint:

```sh
python3 demo/run_demo.py --file demo/demo.sql
```

Or every demo in the directory:

```sh
python3 demo/run_demo.py --dir demo
```

The runner splits the script into statements, submits the writes as MSQ
tasks and **waits** for them, runs the reads against the SQL endpoint, and
prints the results tab-separated. A statement that fails prints
`ERROR ...` and the run carries on, so one broken step does not hide the
rest of the demo.

**Three directives** carry the steps Druid's SQL cannot express. All
sit in the demo file as comments, so the file is still readable SQL:

- `-- @fixture <datasource> {"rows": [...]}` — the fixture. Druid has no
  DDL, no `VALUES` and no row-wise tuple source, so a set of rows has no
  SQL form; the runner turns the JSON into an MSQ write
  (`REPLACE INTO ... OVERWRITE ALL SELECT ... FROM UNNEST(...)`), which
  is also what makes the demo re-runnable.
- `-- @call <path> {...}` — a service-tier call: the steps that are not
  SQL functions at all (the corpus search, the agents, the reasoning call
  over a corpus). `"$previous"` splices the previous step's result into
  the next one.
- `-- @call <path> {...} AS <datasource>` — the same, with the result
  materialised into a datasource, so a later statement can query it.
  An agent's verdict is exactly the kind of thing a demo's own headline
  check needs to read.

## How the demos run on Druid

Every kit in this directory runs against Druid: no `CREATE TABLE`, no
`INSERT INTO`, no recursive CTE, no window function, and each one closes
with a headline over its own results. They use the pure functions (search,
the vector algebra, the analytics), which Druid's SQL hosts directly, plus
the tiers that reach the extension's own HTTP endpoints.

Those endpoints are on the broker (`http://localhost:8082`). The agentic
verticals, the enterprise tier, the vectorizer and text-to-SQL are
**service calls**, not SQL expressions, so a kit that needs one calls it
with a `-- @call` directive.

The demos are re-runnable: each fixture is a `REPLACE INTO ... OVERWRITE
ALL`, so a second run replaces the data rather than doubling it.

They run the same on the single-host stack and on the multi-host one
(`docker compose -f docker/docker-compose.yml --profile multihost up -d`, which adds a second
broker with its own daemon on `:8084`); see
[the Docker demo](../docs/docker-demo.md#single-host-or-multi-host).

## What each section shows

- **0 — Sanity check.** `fractal_edition()` / `fractal_version()`
  confirm the extension is actually loaded before anything else runs.
- **1 — Setup.** A small `demo_alerts` datasource with a deliberate story
  in it: a login-attempt count that escalates (3 → 3 → 17) and a latency
  spike in the last ~10 minutes. Nothing here calls the LLM yet.
- **2 — Sniper Search.** `fractal_search_distance()` converges a stored column
  toward a query vector — the fast, precise mode. `fractal_sfs_converge_debug`
  exposes the tunable form if you need it; the default form here is
  fixed at the SFS engine's own defaults.
- **3 — Reasoning over real data.** `fractal_reason()` gets a real
  `context` argument this time — the alerts from the last hour,
  serialized to JSON by concatenating the rows in SQL — rather
  than an empty ping. Expect the model to notice the login-attempt
  escalation and the latency spike; exact wording varies by model and
  provider.
- **4 — Scout Discovery feeding reasoning.** `fractal_search_explore()`
  scans your own embedding column and returns a diversity-spread
  population as one JSON document. On Druid it is a **service call**
  (`-- @call search/explore`), not an aggregate: it converges over a
  whole column, which a SQL expression cannot hold. Its result is
  handed to `fractal_reason()` as the context of the next call. This is
  the differentiator pattern: diversity-sampled context instead of a
  plain `WHERE` filter, in one pipeline.

## Response modes

`response-modes.sql` demonstrates the three response shapes —
`text` / `code` / `json` — see
[docs/reasoning-setup.md](../docs/reasoning-setup.md#response-modes)
for the full explanation of each.

It's a **separate file from `demo.sql`**, not another section in it,
because the three shapes are worth seeing side by side over one
datasource, and the file reuses `demo.sql`'s `demo_alerts`.

Run `demo.sql` first if you haven't, then the kit in a single pass:

```sh
python3 demo/run_demo.py --file demo/response-modes.sql
```

There is no mode to switch and no process to restart here. `fractalsqld` reaches the reasoning provider over HTTP, and the
reasoning tier runs through **four independent contexts** — chat,
text-to-SQL, review and embed — each with its own response mode. Only
the chat context's mode is the operator's choice
(`FSQL_REASONING_HTTP_RESPONSE_MODE`, in the `fractalsqld` environment); the other three are
fixed to what they are for. So the three modes in this kit are three
**kinds of question** over the chat context's default mode, and they
run in one pass.

What to expect: the `code` section asks the model for a single Druid
SQL statement, and the answer comes back as the model's own text — the
shaping is the caller's job here.
The `json` section asks for a document and reads it back with the
extension's own `fractal_json_value`, which answers null on a malformed
document rather than raising — so a successful count is proof the
extraction worked, and a model that wrapped its JSON in prose cannot
fail the kit.

What the four contexts change is the tier's own machinery, and the
kits show it: the text-to-SQL tier (the `/text-to-sql` endpoint and the
statement-generating agents) runs in **code** mode, so a generated
statement arrives as a bare statement rather than as prose with the
statement buried in it; and the review tier runs in **text** mode, so
a PASS/FAIL verdict is readable off the front of the answer — see
[docs/reasoning-setup.md](../docs/reasoning-setup.md#the-four-contexts-on-druid).

In the [Docker demo](../docs/docker-demo.md#docker-demo-the-learning-path),
`run_demo.sh` runs `response-modes.sql` in the main loop like every
other kit: one pass, three shapes. The
`--include-response-modes` flag is accepted and ignored, so an existing
script still runs.

## Enterprise Tier — QTL & CISO Audit

`enterprise-qtl-audit.sql` exercises the enterprise-tier **Quantized Ternary
Ledger** (append-only, tamper-evident Truth/Shadow record of search/feedback
events) and **CISO audit unpack** surface. Unlike every other demo here, it
runs in **two** states:

- **Dormant (default — the enterprise core is not installed):** the ledger
  and audit functions are present but inactive. The demo seeds real
  engagement events with the community `fractal_feedback_report` primitive,
  then each enterprise call fails with a clean `fractalsql: enterprise tier
  not loaded` error. `fractal_ledger_verify` is the exception: it reads the
  extension's own chain file rather than the core's, so it answers on a
  Community deployment too — an auditor can always check the chain.
- **Active:** with the enterprise core installed on the node and
  `enterprise_lib` in `fractalsqld.conf` pointing at it (drop the library and its `.sig` beside the community core), the demo seals the
  seeded ledgers into the chain, decodes the persisted QTL blob back into a
  CISO event log with the **enterprise core's own decoder**, then exercises
  `load` / `compact` / `reset_soft` / `reset_hard` end to end.
  The demo stack sets `druid.fractalsql.ledger.allow_destructive=true` (in `docker/druid/common.runtime.properties`); those operations are off by default, so a node of your own needs the same setting to run this demo.

```sh
python3 demo/run_demo.py --file demo/enterprise-qtl-audit.sql
```

The library path is **operator** configuration on Druid —
`enterprise_lib` in `fractalsqld.conf` — not a
per-request setting: a request's query context may not re-point the
enterprise core. The library itself is installed with the daemon (the
daemon build picks up `libfractalsql-enterprise-sovereign-c.so` and its `.sig` sidecar from
`include/<platform>/`, beside the community core, when they are there); it is not part of
the extension JAR and not part of the community drop. Without it the demo
takes the dormant path.

The demo also prints the tier's own status, so you can see which path ran:

```sql
-- @call ledger {"action": "status"};
```

See [docs/enterprise.md](../docs/enterprise.md) for the full mechanism, the
function table, and the append-only chain / signature-verification details.

### Enterprise Tier — Stress & Tamper-Evidence

`enterprise-stress.sql` is the companion to the audit demo above: it
hammers the same enterprise ledger surface under load. It fills the
in-memory Truth/Shadow ledgers to their **capacity bound** (64 each,
`FSQL_TRUTH/SHADOW_DEFAULT_CAP` — 128 events total with disjoint
doc_ids), round-trips them through the QTL encode -> chain -> decode
path, churns flush/load cycles at capacity, and walks the append-only
chain with `fractal_ledger_verify()`. Same dual-state shape as the
audit demo — dormant on the community build, active with a licensed
enterprise core.

> **The events are generated in one statement each**, not one statement
> per event: Druid has no procedural loop, so the 64 events of a batch
> come from an explicit array unnested into the function. Note the
> absence of a `CAST` — Druid 38's planner rewrites a one-argument
> `CAST` into a broken two-argument form ("Function[cast] requires 2
> arguments"), so the array's elements are used as they are.

> **Scope note:** the tamper probes that need to corrupt the *persisted
> bytes* are not SQL — the chain is a file on the node's disk, so they
> live in the gate suite (`build_test.sh`'s enterprise gate), which can reach
> the file. What the kit can show from SQL is the same tamper-evidence
> the chain is built on: the audit log decodes exactly what was
> sealed, and the full-chain walk verifies.

> **Concurrency / cross-session** coverage (parallel last-writer-wins
> flush, and load-in-a-fresh-connection) is exercised by the gate
> suite, which drives a real enterprise core — not something a single
> SQL script can do without a scripting language's control flow.

```sh
python3 demo/run_demo.py --file demo/enterprise-stress.sql
```

## Text-to-SQL

`demo-text-to-sql.sql` walks through the text-to-SQL tier against
a richer three-table schema with real foreign keys (`customers` ->
`orders` -> `order_items`) — single-table questions, a question
requiring a join, and a question requiring all three tables, plus
running a generated statement yourself. On this edition the generation
is a **service call** (`-- @call text-to-sql {...}`) on the extension's
own endpoint rather than an in-database function, so the request names
the tables it may read, and the candidate comes back already validated
against Druid's own planner (`EXPLAIN PLAN FOR`) — a statement Druid
cannot plan is reported as not valid rather than handed over as if it
worked. There is no spool trick here to capture and re-run a generated
statement: Druid has no dynamic SQL execution and no session to hang a
spool on, so the generated statement is run through the extension's
data-analyst agent, which validates it with `EXPLAIN PLAN FOR` and then
executes it — the same explicit, separate step, done by the service
rather than by the shell. Scoping the LLM's view is
the `tables` argument's job (`{"question": "...", "tables": ["orders", "customers"]}`),
and `GET /fractalsql/schema-context` audits the
schema the service was given — it reads `INFORMATION_SCHEMA`. Same prerequisites as `demo.sql` (extension loaded,
reasoning configured). Full pipeline explanation and the config-key
reference are in
[docs/text-to-sql-setup.md](../docs/text-to-sql-setup.md).

```sh
python3 demo/run_demo.py --file demo/demo-text-to-sql.sql
```

`demo/text-to-sql-spike-*.sql` are earlier, throwaway hand-rolled
scripts from before this function existed (single-table, no FKs,
driving `fractal_reason()` directly to validate the approach) — kept
for history, not the recommended starting point.

## Industry vertical demos

Forty-two runnable walkthroughs — thirty-five **domain kits** and seven
**agentic verticals** — each with its own synthetic dataset and its own
subset of the function surface chosen for genuine domain fit, not forced
coverage. Every one ends with a `fractal_reason()` narrative call over
real computed results, same closing pattern as `demo.sql` — except the
two newest verticals, Biotech/Genomics and Agentic Edge Swarm, which are
raw-primitive showcases and run with no reasoning endpoint at all. Same
prerequisites as `demo.sql` (extension loaded; the final reasoning
section in each needs [reasoning configured](../docs/reasoning-setup.md)
— every earlier section runs without it). All forty-two are also wired
into the Docker demo — see [the Learning Path](../docs/docker-demo.md#docker-demo-the-learning-path),
including `run_demo.sh` to run all forty-two (plus every other demo in
this directory) in one sweep: it drives `run_demo.py` once per kit,
writes a log per kit, and prints a summary at the end. Its flags are
`--quiet`, `--only <file>`, `--skip <file>`, `--url <sql-endpoint>`
and `--service-url <broker>`.
A vector column is the core's **text form** here — CSV (`0.1,0.2,0.3`)
or the bracketed JSON form (`[0.1,0.2,0.3]`) — because Druid has no
BLOB column type and no `float8[]`: the vector travels as a STRING
holding the text the core reads. MedTech's `vitals`, Maritime's and
Fleet's and Cybersecurity's `baseline`/`current` hold the CSV form;
Biotech/Genomics' `coord` and `demo.sql`'s `demo_points` hold the
bracketed JSON form. Druid has no `CHECK` constraint either, so the
dimension guard cannot live on the column: the width is reported
rather than assumed, and a value that is not a vector comes back as
NULL rather than as a corrupt vector. See
[demo-fractal-vector.sql](demo-fractal-vector.sql) for both storage
forms and for the size the packed float32 form would have taken.

```sh
python3 demo/run_demo.py --file demo/demo-vertical-quant-finance.sql
```

- **[demo-vertical-quant-finance.sql](demo-vertical-quant-finance.sql)** —
  Quantitative Finance & Algorithmic Trading. A 25-asset factor-model
  portfolio (`fractal_optimize_portfolio` picks the best 8) and a
  300-point price series with a deliberate volatility regime change at
  t=240 (`fractal_dimension_dfa`/`fractal_dimension_drift`, with
  `fractal_change_point_detect` localizing the boundary).
  `fractal_search_trajectory` finds which of 10 historical quarterly
  rebalances the new allocation most resembles.
- **[demo-vertical-medtech-clinical.sql](demo-vertical-medtech-clinical.sql)** —
  MedTech, Clinical Telemetry & Patient Monitoring. 40 synthetic
  patients, `vitals` stored as vector text (dims=5) — a fixed
  five-field clinical vector where dimension-drift
  protection actually matters: `fractal_hybrid_clinical_search` over an
  age/condition cohort computed with ordinary SQL, `fractal_search_
  trajectory` for a patient's current vitals vs. their own admission
  baseline (the exact example in that function's own doc comment, read
  straight out of the stored column), plus all four domain-
  geometry functions (`fractal_vascular_network`,
  `fractal_cortical_folding`, `fractal_nerve_plexus_metric`) on small,
  pre-extracted geometric fixtures — a vessel graph, a reference unit-
  cube mesh, a nerve fiber skeleton.
- **[demo-vertical-recommendation-search.sql](demo-vertical-recommendation-search.sql)** —
  Advanced Recommendation, Search & Discovery Engines. A 300-item, 6-genre
  catalog for diverse "you might also like" discovery
  (`fractal_search_explore`), table-backed top-k
  (`fractal_search_telemetry`), and the **full stateful-diversity
  loop**: enable Diversify, search, report negative feedback on the
  top result, re-search the same query, confirm it's now avoided — the
  real differentiator over plain top-K or MMR, neither of which is
  stateful across searches. Also covers `fractal_cross_modal_search`
  (content + behavior vectors, weighted).
- **[demo-vertical-sovereign-edge-ai.sql](demo-vertical-sovereign-edge-ai.sql)** —
  Sovereign, Edge & Autonomous Systems AI. FractalSQL's whole story fits
  this vertical natively — search and optimization run as pure C inside
  the extension on the Druid node itself (over JNI), and reasoning is
  the extension's own HTTP call to the provider, so no external
  vector-DB service is required. A 50-node edge-compute fleet: Sniper
  Search for an ideal node profile, Scout Discovery for diverse fleet
  profiles, `fractal_dimension_boxcount` over a facility deployment
  grid, and `fractal_optimize_portfolio` repurposed as a general
  on-device black-box resource allocator (picking 6-of-50 nodes for a
  distributed job under contention risk).
- **[demo-vertical-maritime-defense.sql](demo-vertical-maritime-defense.sql)** —
  Maritime, Aviation & Defense (AIS & Radar Tracking). 30 synthetic AIS
  vessel tracks (`baseline`/`current` stored as vector text,
  dims=4 — a fixed track-state vector), one given a deliberate course
  deviation. `fractal_search_trajectory` on the current-vs-baseline
  track delta (a direct fit for "what changed" deviation detection, read
  out of the stored columns), nearest-track/diverse-track
  clustering across the fleet, and `fractal_dimension_dfa` on
  heading-change series to separate smooth transit from erratic
  maneuvering.
- **[demo-vertical-fleet-logistics.sql](demo-vertical-fleet-logistics.sql)** —
  Autonomous Fleet Management & Last-Mile Delivery. A 40-vehicle
  delivery fleet (`baseline`/`current` stored as vector text,
  dims=4), one running a deliberate detour. Diverse route/zone
  clustering for depot coverage, a cohort-restricted search ("today's
  route-3 vehicles only" — the same cohort-then-search composition
  `fractal_hybrid_clinical_search` uses, built here with a cohort
  computed into a datasource instead of that clinically-named function),
  detour detection via `fractal_search_trajectory` (over the stored
  vector text), and GPS-trace complexity via `fractal_dimension_boxcount`.
- **[demo-vertical-smart-cities-iot.sql](demo-vertical-smart-cities-iot.sql)** —
  Smart Cities & IoT Sensor Grids. A 400-sensor city grid
  (traffic/air-quality/noise): spatial coverage diagnostics
  (`fractal_dimension_boxcount`/`fractal_morphological_complexity`),
  an air-quality event detected via `fractal_dimension_dfa`/
  `fractal_dimension_drift` on a sensor series with a deliberate
  regime shift, and diverse representative-zone sampling via Scout
  Discovery.
- **[demo-vertical-cybersecurity-threat-detection.sql](demo-vertical-cybersecurity-threat-detection.sql)** —
  Cybersecurity & Threat Detection (network behavior analytics). A
  35-host fleet across three zones (`baseline`/`current` stored as
  vector text, dims=4), one host showing a stealthy compromise
  pattern — outbound connections, destination ports, and DNS query
  volume all spike while failed-auth stays flat, not a brute-force
  signature. Diverse traffic-profile clustering for threat hunting
  (`fractal_search_explore`), a zone-restricted search ("DMZ hosts
  only" — the same cohort-then-search composition
  `fractal_hybrid_clinical_search` uses), compromise detection via
  `fractal_search_trajectory` (over the stored vector text), and
  connection-rate regime-change detection via `fractal_dimension_dfa`/
  `fractal_dimension_drift` on a beaconing-onset series, with
  `fractal_periodogram` reading the beacon interval itself out of the
  post-shift traffic.
- **[demo-vertical-biotech-genomics.sql](demo-vertical-biotech-genomics.sql)** —
  Structural Biology & Genomics. A synthetic scRNA-seq-style embedding
  in 3D — 60 points in two well-separated clusters (30 + 30) plus 6
  points bridging them in a rough ring — analyzed by
  `fractal_tda_persistence_diagram`: exact 0-dim persistence
  (cluster birth/death bars) plus the graph-cycle-rank Betti-1, which
  flags the closed loop the shape actually has. Then
  `fractal_vector_lp_distance` between the two cluster centroids,
  contrasting p=1 Manhattan (robust to per-feature outliers) against
  p=2 Euclidean. A raw-primitive showcase — no reasoning endpoint
  needed.
- **[demo-vertical-agentic-edge-swarm.sql](demo-vertical-agentic-edge-swarm.sql)** —
  Agentic Edge / Robotics Swarm. A battery- and bandwidth-constrained
  10-node edge swarm: `fractal_vector_quantize_int8` (4x) and
  `fractal_vector_quantize_binary` (32x) for compressed peer-state
  memory with `fractal_vector_hamming_distance` as the cheap candidate
  filter ahead of a full-precision re-rank, `fractal_agent_detect_loop`
  on a node stuck oscillating between two headings vs. one genuinely
  exploring (deterministic multi-frequency sinusoids — the negative
  control that must NOT be flagged), and `fractal_optimize_subset`'s
  value-weighted allocation for battery-constrained task routing. A
  raw-primitive showcase — no reasoning endpoint needed.

### Agentic verticals (Universal Agent composition)

The three agentic verticals exercise the six C-level **Universal Agents**
composed into **Domain Agents** — see
[docs/api-agency.md](../docs/api-agency.md) for the composition pattern.
Unlike the domain verticals above, every section here needs a reasoning
provider configured (the agents reach it over the extension's own HTTP
path), and each is a clean, re-runnable regression test of a
recently-fixed agent code path — nothing commented out, no
skip-wrappers (Druid's SQL has no procedural block of any kind, so
there's no `DO`/`EXCEPTION` to skip with; an agent call with no
provider configured just fails with the clean "no reasoning provider is
configured" error, and the runner prints the `ERROR` line and moves on
to the next statement).

- **[demo-vertical-agentic-ops-devops.sql](demo-vertical-agentic-ops-devops.sql)** —
  DevOps/SRE: Autonomous Incident Triage & Self-Healing. The
  embed-coupled agents on a vectorized `incident_logs` corpus:
  `fractal_search_agent` and `fractal_rag_agent` (retrieve-then-reason),
  both gated on the reasoning provider — a clean hint without one, and
  the analytic sections still run either way — `fractal_agent_detect_loop`
  on a period-2 oscillation in a state-vector log (the SimHash + Brent
  cycle detector flags the 2-state cycle even though its DFA alpha is
  only ~0.04), `fractal_dimension_drift` over a
  non-degenerate latency series, plus `fractal_agent_route_task` and
  `fractal_agent_outlier_intercept` Domain Agent compositions.
- **[demo-vertical-agentic-fintech-mcts.sql](demo-vertical-agentic-fintech-mcts.sql)** —
  FinTech: Scenario Exploration & Safe Execution. `fractal_agent_plan_explore`
  embeds a seed state and Scout-searches a vectorized `trade_strategies`
  corpus (reasoning-provider gated, like every cognition agent),
  `fractal_sql_agent` with `auto_execute => true` running the
  model-generated SQL (the agent writes the statement, Druid's parser
  validates it, and then it runs), and `fractal_optimize_portfolio`
  rebalancing.
- **[demo-vertical-agentic-customer-support.sql](demo-vertical-agentic-customer-support.sql)** —
  Customer Support: Stateful Session & Churn Drift.
  `fractal_agent_trajectory_predict` reads the session stream and
  derives the velocity between the two most recent states of a
  `state_vector` column, derives the dimension from the data, and
  computes a real delta — the column holds CSV/JSON vector text,
  because a vector travels as the core's text form — plus
  `fractal_agent_recall_hybrid`, `fractal_agent_recommend_diverse`, and
  the `fractal_diversify_enable` stateful-diversity loop.


### Newer verticals (automotive, aerospace, telecom, climate tech, RF)

- **[demo-vertical-ev-battery-lifecycle.sql](demo-vertical-ev-battery-lifecycle.sql)** —
  EV Battery Lifecycle (agentic kit). 3 vehicles x 96 readings (state of health, pack temperature, cell voltage); one vehicle develops an accelerating thermal ramp and SoH fade. Chains `fractal_agent_patient_deterioration_triage` (cohort search plus baseline-vs-current trajectory drift: a vehicle's intake baseline plays the patient's admission baseline) with `fractal_agent_anomaly_triage` (the DFA drift exponent of the temperature series), each shown hand-composed first and then as the shipped one-call agent, closing with one maintenance / safety recommendation.
- **[demo-vertical-adas-safety-validation.sql](demo-vertical-adas-safety-validation.sql)** —
  ADAS Safety Validation (agentic kit). A pre-commit safety barrier. `fractal_agent_outlier_intercept` screens three proposed maneuvers against a history of known-bad states (cosine by default, exact Euclidean when magnitude should count: a gentle lane change is intercepted by cosine but allowed by l2), and `fractal_search_trajectory` flags a vehicle whose routing vector has strayed from the fleet baseline. Closes with one go / no-go verdict.
- **[demo-vertical-v2x-warranty-triage.sql](demo-vertical-v2x-warranty-triage.sql)** —
  V2X Warranty Triage (agentic kit). Routes an incoming diagnostic-trouble-code event to the best-capable repair workflow under a token budget (`fractal_agent_route_task`), then recalls similar historical warranty claims with a strict metadata filter (`fractal_agent_recall_hybrid`; a two-predicate model-year-and-component cohort is shown with `fractal_hybrid_clinical_search`). Closes with a dispatch + claim-context summary.
- **[demo-vertical-critical-inventory-routing.sql](demo-vertical-critical-inventory-routing.sql)** —
  Critical Inventory Routing (agentic kit). Six depots x 64 days of consumption. `fractal_dimension_dfa` finds the depot whose demand is accelerating (non-linear) rather than merely high; `fractal_optimize_portfolio` picks which 3 depots get the scheduled replenishment run with the risk matrix inflated by the DFA exponent; the bursty depot is flagged for expedited restock instead. `fractal_agent_allocate` is the shipped one-call form of the optimizer step. Closes with the rebalancing rationale.
- **[demo-vertical-heavy-industry-predictive-maintenance.sql](demo-vertical-heavy-industry-predictive-maintenance.sql)** —
  Heavy-Industry Predictive Maintenance (agentic kit). Four pumps and drives x 96 readings; one pump develops an accelerating bearing-vibration defect. `fractal_agent_anomaly_triage` flags the vibration regime shift and `fractal_agent_patient_deterioration_triage` measures drift from the asset's intake baseline with a same-class cohort search (an asset plays the patient). Closes with a maintenance-window recommendation. This is the wear / lifecycle half of heavy-industry monitoring.
- **[demo-vertical-climatech-grid-balancing.sql](demo-vertical-climatech-grid-balancing.sql)** —
  Climate Tech: Grid Balancing (agentic kit). Grid-frequency telemetry for three balancing areas; one loses damping and its oscillation envelope grows. `fractal_dimension_drift` (the volatility-regime recipe from the quant-finance kit, applied to a grid) detects it, and `fractal_optimize_portfolio` chooses the 4 of 6 generation and storage resources that carry the response, with a ramp-risk matrix in which solar and wind share weather risk. `fractal_agent_anomaly_triage` and `fractal_agent_allocate` are the shipped one-call forms. Closes with the dispatch-plan rationale.
- **[demo-vertical-hazmat-occupational-triage.sql](demo-vertical-hazmat-occupational-triage.sql)** —
  Hazmat / Occupational Exposure (domain kit). 36 workers across work zones and shifts; a reactor-bay night-shift crew shows elevated dose rate, temperature and heart rate. `fractal_agent_patient_deterioration_triage` is reused verbatim (cohort search plus baseline-vs-current drift, with exposure columns in place of clinical vitals). Closes with a medical-countermeasure dispatch recommendation.
- **[demo-vertical-scenario-planning-simulation.sql](demo-vertical-scenario-planning-simulation.sql)** —
  Scenario Planning & Simulation (domain kit). 24 candidate continuity scenarios in four clusters. Scout (`fractal_search_explore`) picks six deliberately different ones with no model; `fractal_agent_plan_explore` (MCTS-style exploration, needs an embedding endpoint) generates scenario variants from a seed state description. Closes with a summary of the scenario set.
- **[demo-vertical-avionics-fault-prediction.sql](demo-vertical-avionics-fault-prediction.sql)** —
  Avionics Fault Prediction (domain kit). A 12-aircraft fleet with planned-path and current-state vectors in 3D; one flight has drifted far off plan and has erratic heading changes. `fractal_agent_track_anomaly` generalizes straight from the maritime kit's 2D tracks to 3D flight paths (trajectory deviation search plus the heading-change DFA exponent). Closes with a reasoned classification of the deviation.
- **[demo-vertical-satellite-constellation-coverage.sql](demo-vertical-satellite-constellation-coverage.sql)** —
  Satellite Constellation Coverage (domain kit). A 20 x 20 footprint lattice, healthy vs a copy missing an 8 x 8 dead zone (the gap raises lacunarity). `fractal_agent_network_coverage_alert` combines the footprint morphology with link-quality telemetry drift; `fractal_agent_schedule_workload` models launch-slot scheduling for the replacement payload. Coverage-gap angle only: orbital drift and collision detection are a different problem.
- **[demo-vertical-telecom-account-anomaly-screening.sql](demo-vertical-telecom-account-anomaly-screening.sql)** —
  Telecom Account-Anomaly Screening (domain kit). Screens proposed account changes (SIM swap, port-out, new device, location jump) against a history of known-anomalous patterns with `fractal_agent_outlier_intercept`, reused verbatim: the same shape as the ADAS kit. Shows cosine (shape of the event) against exact Euclidean (intensity counts). A general pre-commit safety check, not a fraud-specific product.
- **[demo-vertical-telecom-traffic-routing.sql](demo-vertical-telecom-traffic-routing.sql)** —
  Telecom Traffic Routing (domain kit). Five session requests dispatched to the best-capable of four network nodes under a token budget with `fractal_agent_route_task`, reused verbatim; then re-routed over only the nodes with headroom so a loaded node's request is re-homed. Nearest-capable-node dispatch, not multi-hop rerouting around a failed node.
- **[demo-vertical-climatech-emissions-monitoring.sql](demo-vertical-climatech-emissions-monitoring.sql)** —
  Climate Tech: Emissions Monitoring (domain kit). Methane, CO2 and pipeline-pressure sensors; one methane sensor starts leaking (an accelerating concentration ramp). `fractal_agent_anomaly_triage` is reused verbatim to flag the shift into a leak regime; the same call screens a water-distribution pressure series. Closes with a leak narrative and field response.
- **[demo-vertical-climatech-risk-exposure.sql](demo-vertical-climatech-risk-exposure.sql)** —
  Climate Tech: Risk Exposure (domain kit). A 20 x 20 hazard-sensor grid with dry-season and wet-season fuel-moisture deficit indices. `fractal_agent_network_coverage_alert` is reused verbatim: morphology of the elevated-hazard region plus telemetry drift, shaped like the smart-cities kit's sensor grid. Closes with an exposure narrative for an insured portfolio.
- **[demo-vertical-rf-spectrum-sensing.sql](demo-vertical-rf-spectrum-sensing.sql)** —
  RF Spectrum Sensing (domain kit). Three channels x 256 samples: a beacon that gets jammed partway through, an empty noise channel and a steady carrier. `fractal_periodogram` says which frequencies dominate, the new `fractal_spectrogram_entropy` says how ordered the spectrum is window by window, and `fractal_change_point_detect` localizes when the order was lost, straight from the entropy series. A raw-primitive showcase: no agents and no model until the closing triage narrative.


### Event-stream, document, spatial and allocation kits

- **[demo-vertical-event-stream-anomaly-triage.sql](demo-vertical-event-stream-anomaly-triage.sql)** —
  Event-Stream Anomaly Triage (domain kit). Four endpoints x 96 one-minute intervals of request latency; one endpoint (EP-C) develops an accelerating latency ramp (a timeout cascade) and a second (EP-B) has a retry-storm oscillation in its request rate. `fractal_agent_anomaly_triage` flags the latency regime shift, `fractal_periodogram` finds the retry-storm period, and `fractal_search_trajectory` finds which endpoints' success-rate / latency / timeout / fill health has moved the same way EP-C's did.
- **[demo-vertical-outlier-interception-footprint.sql](demo-vertical-outlier-interception-footprint.sql)** —
  Outlier Interception & Footprint Analysis (domain kit). Screens proposed traffic sessions against a history of known-abuse signatures with `fractal_agent_outlier_intercept` (cosine by default, exact Euclidean when magnitude should count), then uses `fractal_dimension_boxcount` on click-coordinate clouds: organic traffic fills the page (a high box-counting dimension) while an automated farm hammering a handful of targets collapses onto a line (a dimension near 1).
- **[demo-vertical-agentic-budget-reallocation.sql](demo-vertical-agentic-budget-reallocation.sql)** —
  Agentic Budget Reallocation (agentic kit). Six channels x 64 days of attributed outcomes. `fractal_dimension_dfa` finds the channel whose response is accelerating (a non-linear surge a plain average would hide); `fractal_optimize_portfolio` picks which 3 channels receive the scheduled budget increase with the risk matrix inflated by the DFA exponent; the surging channel is flagged for a capped, monitored test instead. `fractal_agent_allocate` is the shipped one-call form of the optimizer step, and `fractal_agent_route_task` dispatches each journey to the best-matching model under a token budget.
- **[demo-vertical-stalled-process-triage.sql](demo-vertical-stalled-process-triage.sql)** —
  Stalled-Process Triage (domain kit). 36 open items across segments and stages; three tier-1 items in the review stage show the same stall signature (time-in-stage far above the healthy velocity, falling engagement, a silent owner, deepening concessions). `fractal_agent_patient_deterioration_triage` is reused verbatim (cohort search plus baseline-vs-current drift, with item-health columns in place of clinical vitals): an item's stage-entry telemetry plays the patient's admission baseline.
- **[demo-vertical-intent-matching-discovery.sql](demo-vertical-intent-matching-discovery.sql)** —
  Intent Matching & Diverse Selection (domain kit). 24 target entities in four intent clusters (category + stage signal vectors) and a 30-item content library. Scout (`fractal_search_explore`, the diversity-first MMR search) picks six deliberately different entities around a target profile instead of six near-duplicates, and `fractal_agent_recommend_diverse` returns a repulsion-diverse set of content items for the chosen entity: no model needed for either.
- **[demo-vertical-agentic-next-action-ranking.sql](demo-vertical-agentic-next-action-ranking.sql)** —
  Agentic Ranking & Next-Action Recommendation (agentic kit). 30 candidates across segments, a 12-item action catalog and a natural-language question over the candidate table. `fractal_agent_recall_hybrid` recalls the most similar past candidates inside one segment (a strict metadata filter), `fractal_agent_recommend_diverse` proposes a diverse set of next actions (not four variations of 'send an email'), and `fractal_sql_agent` answers a status question in plain English by generating and running the SQL.
- **[demo-vertical-document-risk-drift.sql](demo-vertical-document-risk-drift.sql)** —
  Document Risk Drift & Diverse Alternatives (domain kit). Four agreements x 96 weekly clause-risk reviews; one agreement's amended terms drift into a new regime (an accelerating risk creep). `fractal_dimension_drift` (the regime-detection recipe from the quant-finance kit, applied to document risk) finds it; Scout (`fractal_search_explore`) pulls six deliberately different clause variants out of the 24-clause corpus so the reviewer sees the spread rather than six near-copies; and `fractal_agent_recommend_diverse` proposes diverse approved replacement language.
- **[demo-vertical-coordinated-record-detection.sql](demo-vertical-coordinated-record-detection.sql)** —
  Record Clustering & Severity Trajectory (domain kit). A review desk screens new submissions against known ring signatures with `fractal_agent_outlier_intercept`, finds the records that moved from the normal severity baseline the way a staged ring does with `fractal_search_trajectory`, and measures the geographic footprint of event locations with `fractal_dimension_boxcount` (organic events scatter across the city; a staged ring repeats along one road).
- **[demo-vertical-sensor-telemetry-allocation.sql](demo-vertical-sensor-telemetry-allocation.sql)** —
  Sensor Telemetry & Resource Allocation (agentic kit). Six sites x 64 days of resource demand from soil-moisture sensors. `fractal_dimension_dfa` finds the site whose demand is accelerating (a non-linear trend or a failing supply line) rather than merely high; `fractal_optimize_portfolio` picks which 3 sites get the scheduled service run with the risk matrix inflated by the DFA exponent; the accelerating site is flagged for an inspection instead. `fractal_agent_allocate` is the shipped one-call form of the optimizer step.
- **[demo-vertical-simulated-economy-drift.sql](demo-vertical-simulated-economy-drift.sql)** —
  Simulated-Economy Drift & Loop Detection (agentic kit). Six markets x 96 days of price index; every market carries a weekly demand cycle, and one (mkt-d) enters an accelerating inflation spiral. `fractal_periodogram` confirms the weekly cycle, `fractal_dimension_dfa` flags the market that is inflating non-linearly, and `fractal_optimize_portfolio` picks the 3 markets for the scheduled sink program (the inflating market goes to an emergency price-cap instead). `fractal_agent_detect_loop` then watches trade-state logs: an automated actor that flips between the same two item states is detected while a varied actor is not.
- **[demo-vertical-multi-series-replenishment.sql](demo-vertical-multi-series-replenishment.sql)** —
  Multi-Series Forecasting & Replenishment (agentic kit). Six locations x 64 days of unit demand. `fractal_dimension_dfa` finds the location whose demand is accelerating (a viral item or a local event) rather than merely high; `fractal_optimize_portfolio` picks which 3 locations get the scheduled replenishment from the central hub with the risk matrix inflated by the DFA exponent; the surging location is flagged for an expedited pick instead. `fractal_agent_allocate` is the shipped one-call form of the optimizer step.
- **[demo-vertical-periodicity-portfolio-selection.sql](demo-vertical-periodicity-portfolio-selection.sql)** —
  Periodicity Detection & Portfolio Selection (domain kit). Six items x 96 days of sales velocity with a weekly demand cycle of differing strength. `fractal_periodogram` quantifies which items are genuinely periodic; `fractal_optimize_portfolio` picks the 3 items that get the scheduled action (a Sharpe-style trade of margin recovered against demand volatility); `fractal_agent_recommend_diverse` proposes a diverse set of substitute items. On the Enterprise edition `fractal_agent_diverse_portfolios` (multimodal optimization) also returns structurally different schedules; on the Community edition that step reports "enterprise tier not loaded".
- **[demo-vertical-agentic-recall-recommendation.sql](demo-vertical-agentic-recall-recommendation.sql)** —
  Agentic Recall & Diverse Recommendation (agentic kit). 24 candidate offers in four clusters and 30 abandoned sessions across categories. Scout (`fractal_search_explore`) picks six deliberately different offers around the user's profile so the follow-up tests variety rather than six near-identical offers; `fractal_agent_recall_hybrid` recalls the most similar past sessions inside the user's category (a strict metadata filter); and `fractal_sql_agent` answers a question over the session table in plain English.
- **[demo-vertical-spatial-footprint-portfolio-risk.sql](demo-vertical-spatial-footprint-portfolio-risk.sql)** —
  Spatial Footprint Complexity & Portfolio Risk (domain kit). Three districts' parcel footprints (a dense grid, a single arterial strip and a two-corridor district) measured with `fractal_dimension_boxcount`: the lower the dimension the more linear the frontage and the more a valuation depends on a few corridors. Six asset classes x 64 months of index values feed `fractal_dimension_dfa` and `fractal_optimize_portfolio` (pick 3 classes for the renewal push; the accelerating one is flagged), and Scout (`fractal_search_explore`) selects six deliberately different comparable parcels so the reviewer sees the spread of the market, not six near-twins.
**A note on `fractal_dimension_boxcount`/`fractal_morphological_complexity`
fixture design**, visible across several of the scripts above: both
functions need enough *space-filling* points (a grid, a path, a real
geometric structure) for their internal box-counting estimator to find
>= 3 valid eps-octaves — its own documented validity filter. A sparse
or purely random scatter of points, even well past the 8-point
minimum, typically fails this and returns an error rather than a wrong
number. Every fixture above was chosen and verified against a live
instance with that requirement in mind.

## The sixteen agents

`demo-agents.sql` validates the sixteen installable agents. The
sixteen ship with the extension, served by `fractalsqld` next to the six
Universal Agents, the reasoning core and the search core, so there is no
separate install step: load the extension and start the daemon and all
sixteen are already there (see
[docs/api-agency.md](../docs/api-agency.md#which-agent-should-i-use)).
An agent reads a table and reasons about it, which a Druid SQL
function can do neither of, so each one is reached as a **service
call** on the extension's own HTTP endpoints (`-- @call agent/<name>`),
and the kit reads the result back out of a datasource.
The demo exercises all sixteen end to end:

- **`fractal_agent_anomaly_triage`** — over a drifting latency series (real
  `fractal_dimension_drift` → real `fractal_reason`).
- **`fractal_agent_allocate`** — on a real `mu`/`cov` (real
  `fractal_optimize_portfolio` → real `fractal_reason`).
- **`fractal_agent_route_task`** — matches a task embedding to the nearest
  capability row (real `fractal_search_telemetry` → real `fractal_reason`).
- **`fractal_agent_outlier_intercept`** — screens a state vector against known
  bad states and compares the real nearest-distance to a threshold (real
  `fractal_search_telemetry` → real `fractal_reason`).
- **`fractal_agent_recall_hybrid`** — vector recall restricted by a metadata
  cohort (real `fractal_hybrid_clinical_search`); pure retrieval, no LLM step.
- **`fractal_agent_recommend_diverse`** — repulsion-diverse top-k over a catalog
  (real `fractal_diversify_enable` + real `fractal_search_telemetry`); pure
  retrieval, no LLM step.
- **`fractal_agent_data_analyst`** — a natural-language question over your
  tables (real `fractal_sql_agent` with `auto_execute => true` → real
  `fractal_reason`); the horizontal catch-all with no vertical preset.
- **`fractal_agent_patient_deterioration_triage`** — cohort-restricted
  nearest patient + baseline→current drift (real
  `fractal_hybrid_clinical_search` + real `fractal_search_trajectory` → real
  `fractal_reason`); the cohort is caller-built so `age>65 AND
  condition='sepsis'` composes in ordinary SQL.
- **`fractal_agent_feedback_audit`** — a self-contained diversify/repulsion
  audit cycle (real `fractal_detect_collapse` + real `fractal_explain_result`);
  pure analytics, **no LLM**, self-disables diversify.
- **`fractal_agent_schedule_workload`** — refines a task vector then finds
  the nearest node (real `fractal_search` + real `fractal_search_telemetry` →
  real `fractal_reason`).
- **`fractal_agent_rebalance_sibling`** — optimized book vs nearest
  historical allocation (real `fractal_optimize_portfolio` + real
  `fractal_search_trajectory` → real `fractal_reason`).
- **`fractal_agent_diverse_portfolios`** — enterprise tier; companion to
  `fractal_agent_allocate` returning several structurally distinct good
  portfolios instead of one (real `fractal_optimize_portfolio_multimodal` →
  real `fractal_reason`); dormant on the community build — the call errors
  with the clean "enterprise tier not loaded" hint and `demo-agents.sql`
  carries on to the next section.
- **`fractal_agent_detour_classify`** — route deviation + GPS-trace
  complexity (real `fractal_search_trajectory` + real
  `fractal_dimension_boxcount` → real `fractal_reason`).
- **`fractal_agent_track_anomaly`** — track deviation + heading DFA (real
  `fractal_search_trajectory` + real `fractal_dimension_dfa` → real
  `fractal_reason`).
- **`fractal_agent_network_coverage_alert`** — sensor-grid morphology +
  telemetry drift (real `fractal_morphological_complexity` + real
  `fractal_dimension_drift` → real `fractal_reason`); 20×20 grid (400 pts).
- **`fractal_agent_regime_triage`** — single-series regime change (real
  `fractal_dimension_dfa` + real `fractal_dimension_drift` → real
  `fractal_reason`).

Thirteen agents are cognition (end in `fractal_reason`); three are pure
retrieval/analytics with no endpoint needed (`recall_hybrid`,
`recommend_diverse`, `feedback_audit`). The script closes with
a `fractal_reason()` narrative over the computed results — same closing
pattern as every other demo.

**Prerequisites:** just the base extension and reasoning (same as
`demo.sql`) — there's no second extension to load:

```sh
python3 demo/run_demo.py --file demo/demo-agents.sql
```

The script is safe to re-run: every fixture is a `@fixture` directive,
which is an MSQ write with `OVERWRITE ALL`, so the agent datasources
(`ag_logs`, `ag_caps`, `ag_badstates`, `ag_mem`, `ag_catalog`, `ag_data`,
`ag_patients`, `ag_fcatalog`/`ag_fwarmup`, `ag_nodes`, `ag_alloc`,
`ag_vehicles`, `ag_tracks`) are replaced rather than doubled. The ten
non-agentic vertical demos (`demo-vertical-quant-finance.sql`,
`demo-vertical-medtech-clinical.sql`, `demo-vertical-recommendation-search.sql`,
`demo-vertical-sovereign-edge-ai.sql`, `demo-vertical-maritime-defense.sql`,
`demo-vertical-fleet-logistics.sql`, `demo-vertical-smart-cities-iot.sql`,
`demo-vertical-cybersecurity-threat-detection.sql`,
`demo-vertical-biotech-genomics.sql`, `demo-vertical-agentic-edge-swarm.sql`)
are separate kits with the same shape — each rewired section keeps its
raw-primitive call as a commented blueprint above the shipped agent call
that generalizes it (the 3 agentic vertical reference blueprints —
`demo-vertical-agentic-ops-devops.sql`,
`demo-vertical-agentic-fintech-mcts.sql`, `demo-vertical-agentic-customer-support.sql` —
stay untouched).
The agents live in the loaded extension, so there's nothing separate to
drop — removing the demo datasources (see [Cleanup](#cleanup)) is all
the teardown there is.

## Full API benchmark

`benchmark-api-reference.sql` is a single pass exercising the
callable functions documented in `sql/fractalsql--1.0.sql`, grouped by
category, against small generated fixtures — a correctness smoke pass
over the whole API surface, distinct from
[`benchmark.sql`](benchmark.sql)'s narrower Sniper-Search/Scout-
Discovery/vectorizer-throughput comparison (which stays scoped to that,
see its own header comment). It runs under the same client as every
other demo: the runner submits each statement and prints the rows, and
a statement that fails prints `ERROR ...` and the pass carries on. A
Druid demo is a script run by a client, not a shell session, so there
is no per-statement timer to print; and Druid's SQL has no procedural
blocks, so there is no `bmk_safe_call()`-style wrapper function to
write around the reasoning-dependent calls (`fractal_reason`,
`fractal_text_to_sql`, `fractal_embed`, and the agent family) — those
come back empty or fail cleanly without a configured provider, the
agent family with the extension's own "no reasoning provider is
configured" message.

```sh
python3 demo/run_demo.py --file demo/benchmark-api-reference.sql
```

## Cleanup

The demo datasources are left in place after running so you can poke at
the results. Druid has no DDL, so there is no `DROP TABLE` to run and no
per-table teardown statement to write — a datasource is a cluster
object, and removing one is a coordinator operation rather than a
query. Two ways to clear them:

- **One datasource at a time** — the coordinator's datasource API takes
  a `DELETE` for a datasource name
  (`DELETE /druid/coordinator/v1/datasources/<name>` on the coordinator at
  `http://localhost:8081`), which marks the datasource's segments unused.
- **The lot** — `docker compose -f docker/docker-compose.yml down -v`
  takes the whole demo stack down, and the `-v` flag removes the named
  volumes: Druid's segment and metadata storage.

Every fixture is written `REPLACE INTO ... OVERWRITE ALL`, so re-running
a kit replaces its data rather than doubling it, and each kit names the
datasources it creates in its own `@fixture` and `REPLACE INTO` lines.

The vectorizer's registry and queue live in the extension, per node,
not in a connection-scoped TEMP object, so there is no per-session
teardown to run: `demo-vectorizer.sql` registers its vectorizer through
the extension's `vectorizer` endpoint, and that service's own `drop`
action is what forgets one. Neither of those kits prints a cleanup
recipe — each closes with its headline check.

## Troubleshooting

- **Section 0 fails** — the extension isn't loaded on the broker. See [../docs/getting-started.md](../docs/getting-started.md).
- **Section 3 or 4 fails** — reasoning isn't configured, or the endpoint
  is unreachable/misconfigured. `fractalsqld` reaches the provider
  over HTTP, so an unconfigured provider shows up as its own
  "no reasoning provider is configured" error (and a stopped daemon as a
  service-unavailable one). See
  [../docs/reasoning-setup.md](../docs/reasoning-setup.md) for the
  provider setup, and note that the other failure shapes you will see
  are an HTTP 401, a timeout, and a non-2xx response.
- **The reasoning response reads oddly** (e.g. the model asks for data
  instead of describing it) — check that the `context` subquery in that
  section actually returned rows. `fractal_reason()` takes the context
  as its second argument, and an empty or NULL context leaves the
  question with nothing to work from; with nothing there, the model
  will say so rather than hallucinate an answer.

* `demo-fractal-index.sql` -- the native IVF index end to end: the build, the indexed
  search, the exact fallback, the delta (a row added after the build) and the proof
  that the index was really used.
