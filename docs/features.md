<p align="center">
  <img src="../FractalSQLforDruid.jpg" alt="FractalSQL for Apache Druid" width="720">
</p>

# FractalSQL Feature Specification

FractalSQL is a tiered capability framework that runs discovery, reasoning, and agentic workflows beside your data in your own Druid cluster: no external RAG middleware shuffling data between the database and the LLM. The analytic functions run inside Druid, the agents run as a service on the broker, and reasoning runs in `fractalsqld` next to it (see [Druid Integration](druid-integration.md)). It provides a progression from basic vector discovery to autonomous agentic reasoning.

---

## 🏗️ Capability Tiering Model

FractalSQL ships in two editions, each unlocking more of the four capability tiers described below (Discovery → Cognition → Agency → Analytics). The editions are a *build/licensing* axis: which capability set the install was built and licensed to serve; the capability tiers are a *functional* axis: what that set can do. The two are orthogonal: a single install belongs to one edition and exposes whichever capability tiers that edition includes.

| Tier | Focus | Key Capabilities | Build / Requirement |
| --- | --- | --- | --- |
| **Community** | Discovery, Cognition, Agency | SFS Core, Sniper Search, Scout Discovery, In-DB Reasoning and Embeddings (through `fractalsqld`), 15 of the 16 Agents, the vectorizer | The extension JAR, statically linked against the community core (`libfractalsql-community-sovereign-c.a`); everything most installs need |
| **Enterprise** | Governance | Tamper-evident decision ledger (hash chain), audit trail, detached-signature verification | Community install + the licensed enterprise library, loaded by `fractalsqld` from its `enterprise_lib` setting. See [Enterprise Tier](enterprise.md) |

---

## 🔍 Tier 1: Discovery

FractalSQL has two ways to find rows. The **Stochastic Fractal Search (SFS)** engine treats
the problem as continuous optimization and powers `fractal_sfs_converge` (Sniper) and
the diverse **Scout** discovery; the **IVF index** gives fast, verified nearest-neighbour
search over your stored rows, like an index lookup in standard HNSW or IVFFlat, with exact
distances and a recall you can measure.

### Indexed Search (`fractal_search`, `fractal_index_*`)
`fractal_index_create(datasource, column)` builds an index over a datasource's vector column (the cells are written into a companion datasource, because Druid has no DDL and no DML; the index needs a stable id column, `id_col`), and `fractal_search(datasource, column, query, k)` returns the `k` nearest rows to a query vector. With an index the search reads a few cells instead of every row, and it re-scores every candidate against the vector the index carries, so the distances are exact to FP16 precision — not FP32: the index only chooses which rows to look at, it does not approximate the answer. Without an index the same call scans the datasource and returns the same distances, only slower. The search reports the rows it read (`rows_scanned`), far below the datasource's row count, and it does **not** apply the Diversify repulsion layer. The nearest-row agents can search through an index too, off by default — see [Agency](api-agency.md). Building, refreshing and checking an index, and the search options, are in [Discovery](api-discovery.md#fractal_search-the-indexed-search).



### Sniper Search (`fractal_sfs_converge`)
Pure SFS convergence to the single best point minimizing cosine distance to a query over a unit box. It is a "precision" tool for finding the absolute global minimum, and reads no table: `fractal_sfs_converge('query-as-CSV')`.

### Per-row distance (`fractal_search_distance`)
Druid's per-row form of the convergence: `fractal_search_distance(vector_column, 'query-as-CSV')` scores each row in an `ORDER BY ... LIMIT k`. It is not the Sniper; it is the aggregate that scores stored vectors.

### Scout Discovery (`fractal_search_explore`)
Scans a stored corpus and returns a diverse population of results: an SFS population search blended with **Maximal Marginal Relevance (MMR)** re-ranking, so the results cover the data's distinct basins of attraction instead of the "mode collapse" common in top-K search. An aggregate here — `SELECT fractal_search_explore(emb, 'query') FROM corpus` — folding the population into one JSON result (rather than returning one row per matched vector, as a set-returning function would).

### Table-Backed Telemetry (`fractal_search_telemetry`)
A deterministic primitive that returns the $K$ nearest real table rows to a query. This is the ground-truth layer used by all higher-order agentic functions.

---

## 🧠 Tier 2: Cognition

The Cognition tier adds a reasoning bridge to the SFS core, allowing it to call LLMs and embedding models via a pluggable C provider interface. This enables reasoning to happen *beside* the data.

### Reasoning Beside Your Data (`fractal_reason`)
Dispatches a query and a context payload to a configured LLM provider. Because it is a SQL function, you can feed it the results of a Scout search or a SQL query in one statement. The call goes to `fractalsqld`, which holds the provider connection.

**Provider-agnostic**: the same `fractal_reason()` call works against **AWS Bedrock (SigV4)**, **Azure OpenAI**, **GCP Vertex AI**, or **local Ollama**. Switch providers via config without changing a single line of SQL. Local providers keep data on your own infrastructure; cloud providers send it to that provider under your own account and agreement (BAA-covered where your compliance posture requires it).

### Semantic Embeddings (`fractal_embed`)
Generates vectors from text using a purpose-trained embedding model. This removes the need for an external embedding pipeline for many RAG use cases.

### Safe Text-to-SQL (`fractal_text_to_sql`)
Generates SQL from natural language. It uses a three-stage safety pipeline:
1. **Parse-Check**: Validates statement shape (e.g., no DDL) -- a raw-text first-keyword screen plus the broker's own planner (`EXPLAIN PLAN FOR`, which never executes the statement).
2. **Allowlist**: Ensures the statement type is permitted (e.g., `SELECT` only). On Druid the statement type falls out of the planner's parse, so the allowlist is enforced against the same parse.
3. **Mechanical Check**: `EXPLAIN PLAN FOR` against the broker *is* the mechanical check -- and a stronger one than a plain parse, because it consults the engine that will actually run the statement.

---

## 🤖 Tier 3: Agency

The Agency tier composes the Discovery and Cognition primitives into autonomous routines: 16 installable agents, each a productized recipe for a recurring pattern, built on 6 reusable Universal Agent primitives you can also call directly. *Druid difference:* a Druid SQL function cannot issue another query, so the agents are service operations — `POST /fractalsql/agent/<name>` — always present once the extension loads, with no separate install step. See [`docs/api-agency.md`](api-agency.md) for the full argument reference, examples, and notes.

### Agents

| Agent | Recipe | Reasoning |
| --- | --- | --- |
| `fractal_agent_anomaly_triage` | drift exponent on one entity's series → reasoning triage | ✓ |
| `fractal_agent_regime_triage` | DFA + drift over one series → reasoning triage | ✓ |
| `fractal_agent_track_anomaly` | trajectory deviation + heading DFA → reasoning triage | ✓ |
| `fractal_agent_detour_classify` | trajectory deviation + box-counting → reasoning classify | ✓ |
| `fractal_agent_network_coverage_alert` | spatial morphology + telemetry drift → reasoning alert | ✓ |
| `fractal_agent_allocate` | SFS Sharpe optimizer → reasoning rationale | ✓ |
| `fractal_agent_rebalance_sibling` | optimizer + trajectory search → reasoning rationale | ✓ |
| `fractal_agent_diverse_portfolios` (enterprise) | multimodal optimizer → reasoning tradeoff summary | ✓ |
| `fractal_agent_route_task` | nearest-capability search + budget accounting → reasoning rationale | ✓ |
| `fractal_agent_schedule_workload` | `fractal_sfs_converge_debug` refine + nearest node → reasoning rationale | ✓ |
| `fractal_agent_outlier_intercept` | distance-to-bad-state safety barrier → reasoning justification | ✓ |
| `fractal_agent_patient_deterioration_triage` | cohort search + trajectory drift → reasoning triage | ✓ |
| `fractal_agent_data_analyst` | NL → SQL → reasoning analysis (SQL runs only with an explicit `auto_execute`) | ✓ |
| `fractal_agent_recall_hybrid` | cohort-restricted vector recall | — |
| `fractal_agent_recommend_diverse` | repulsion-diverse top-k | — |
| `fractal_agent_feedback_audit` | diversify loop + collapse detection | — |

### Universal Agents

The six building blocks the agents above compose. Call them directly to build your own recipe.

| Function | What it does |
| --- | --- |
| `fractal_search_agent` | Embed a query, Scout-search a table, and reason over the matched rows. |
| `fractal_rag_agent` | Focused single-turn RAG: embed, Scout-search, and reason over the result. |
| `fractal_sql_agent` | Self-correcting NL-to-SQL, retrying on parse/execution failure. |
| `fractal_agent_plan_explore` | MCTS-style exploration of multiple non-overlapping strategy trajectories. |
| `fractal_agent_trajectory_predict` | Forecasts future state from a delta against historical telemetry. |
| `fractal_agent_detect_loop` | Flags infinite/repetitive agent loops via SimHash state fingerprints and Brent's cycle detector, with a DFA drift check. |

### Safe Agency & Guardrails

To prevent "hallucination-driven" database corruption, the Agent Tier implements two primary guardrails:

1. **The Execution Barrier**: Functions like `fractal_sql_agent` with `auto_execute` on run generated SQL read-only. If the statement is refused or an error occurs, the failure is contained to the agent's attempt, the error is fed back to the LLM for a retry, and the main session remains intact.
2. **The Deterministic Allowlist**: The `t2s_allowed_statements` config key (`t2s_allowed_statements = select` in `fractalsqld.conf`) strictly limits the types of SQL the agent can generate (e.g., preventing `DROP TABLE` even if the LLM suggests it).

---

## 📐 Tier 4: Analytics

The final tier provides mathematical primitives for analyzing the "shape" of data and state, turning raw vectors into actionable structural insights.

### Fractal Dimension Analysis
- **DFA (`fractal_dimension_dfa`)**: Analyzes the scaling exponent of a time series to distinguish between noise, random walks, and structured signals.
- **Box-Counting (`fractal_dimension_boxcount`)**: Measures the Minkowski-Bouligand dimension of a point cloud to evaluate spatial complexity.
- **Drift (`fractal_dimension_drift`)**: Detects regime changes by comparing the DFA exponent of a recent window against a baseline.
- **Change-Point Localization (`fractal_change_point_detect`)**: Localizes where a series' mean or variance shifted, complementing DFA's overall characterization.
- **Periodogram (`fractal_periodogram`)**: Exact power spectrum (direct DFT for short series, FFT for longer ones) for cadence detection such as beaconing or retry loops.
- **Spectral entropy (`fractal_spectrogram_entropy`)**: Per-window Shannon entropy of the power spectrum (0 = ordered tone, ~0.9 = noise); pair with `fractal_change_point_detect` to find when order is lost.

### Topology and State Fingerprints
- **Persistence (`fractal_tda_persistence_diagram`)**: Exact 0-dimensional persistence over a point cloud's Vietoris-Rips filtration, plus the graph cycle rank as an informational Betti-number estimate.
- **SimHash (`fractal_state_fingerprint`)**: Folds a state vector into a Hamming-comparable fingerprint where nearly-identical states collide.
- **Cycle Detection (`fractal_cycle_detect`)**: Streaming Brent's algorithm over a fingerprint stream, one result per cycle closure.

### Vector Math
- **$L_p$ Distance (`fractal_vector_lp_distance`)**: Generalized distance over `fractal_vector` for any $p > 0$.
- **Quantization (`fractal_vector_quantize_int8` / `_binary`)**: 4x/32x per-vector compression with optional Hamming pre-filtering ahead of a full-precision re-rank.

### Domain-Specific Geometry
FractalSQL provides optimized routines for pre-extracted biological and technical geometry:
- **Vascular Networks**: Tortuosity and branch-density for vessel graphs.
- **Cortical Folding**: Gyrification Index for brain-surface meshes.
- **Nerve Plexus**: Density and dimension for fiber skeletons.
- **Morphological Complexity**: Combined box-counting and lacunarity for segmented masks.

### Portfolio Optimization
`fractal_optimize_portfolio` uses the SFS engine to solve cardinality-constrained Sharpe-ratio maximization. It finds the best $K$ assets in a large universe without the exponential cost of a brute-force search.

---

## 📈 Benchmarks & Scaling

### A linear scan vs. Scout Discovery
In a benchmark of 100k vectors across 50 Gaussian clusters, measured directly against current Scout (see `bench/README.md` for the full methodology and how to reproduce it):
- **A plain linear scan** (top-50 — not an approximate index like HNSW; see `bench/README.md` for why) typically discovered **1 cluster**, averaging ~381ms per query at this scale.
- **Scout** (pop=50) typically discovered **6-9 clusters** (measured against an exact brute-force KNN -- not an approximate index like HNSW; see `bench/README.md` for why) at this scale.

That tradeoff is the whole point of Scout Mode, not a hidden cost: it's $O(N \times d)$ (linear scan) by design, and it's the only way here to guarantee your LLM receives a genuinely diverse set of perspectives rather than a single collapsed cluster. It is not a drop-in replacement for an exact top-k. Use it where diversity matters more than latency (e.g. curated sub-corpora, not full-corpus top-k at scale).

### Storage: an ARRAY column vs. the text form
A vector is stored either as an `ARRAY` column of numbers or as CSV/JSON text in a string column, and every function accepts both. Druid has no binary vector type, so there is no third format to choose. An `ARRAY` column needs `arrayIngestMode: "array"` on ingestion (see [Druid integration](druid-integration.md#4-storage-and-identity)). Measure on your own data before assuming one form is faster (see `bench/README.md`).

---

## 📚 API Reference

(Detailed argument tables, defaults, and ranges are available in the **[Detailed API Reference](api-discovery.md)**.)

**Discovery**
- `fractal_sfs_converge(query, ...)`: Sniper Mode convergence. $\rightarrow$ **[api-discovery.md](api-discovery.md)**
- `fractal_search_distance(vector, query)`: per-row distance (Druid aggregate form of the convergence). $\rightarrow$ **[api-discovery.md](api-discovery.md)**
- `fractal_search_explore(emb, query, params?)`: Scout Mode diverse exploration (aggregate). $\rightarrow$ **[api-discovery.md](api-discovery.md)**
- `fractal_search_telemetry(table, col, query, k)`: Ground-truth row retrieval. $\rightarrow$ **[api-discovery.md](api-discovery.md)**

**Cognition**
- `fractal_reason(query, context)`: LLM dispatch. $\rightarrow$ **[api-cognition.md](api-cognition.md)**
- `fractal_embed(input)`: Semantic vector generation. $\rightarrow$ **[api-cognition.md](api-cognition.md)**
- `fractal_text_to_sql(question)`: Safe SQL generation. $\rightarrow$ **[api-cognition.md](api-cognition.md)**

**Agency**
- `fractal_agent_data_analyst(...)`: NL question over tables + reasoned summary. $\rightarrow$ **[api-agency.md](api-agency.md)**
- `fractal_agent_route_task(...)`: Sub-agent dispatch. $\rightarrow$ **[api-agency.md](api-agency.md)**
- `fractal_agent_regime_triage(...)` / `_anomaly_triage(...)`: Drift/regime detection. $\rightarrow$ **[api-agency.md](api-agency.md)**
- `fractal_agent_recommend_diverse(...)` / `_recall_hybrid(...)`: Diverse/cohort-restricted retrieval. $\rightarrow$ **[api-agency.md](api-agency.md)**
- 10 more, full list $\rightarrow$ **[api-agency.md](api-agency.md#which-agent-should-i-use)**

**Analytics**
- `fractal_dimension_dfa(series)`: DFA scaling exponent. $\rightarrow$ **[api-analytics.md](api-analytics.md)**
- `fractal_dimension_boxcount(points, dim)`: Box-counting dimension. $\rightarrow$ **[api-analytics.md](api-analytics.md)**
- `fractal_dimension_drift(series, win)`: Regime change detection. $\rightarrow$ **[api-analytics.md](api-analytics.md)**
- `fractal_change_point_detect(series, win, ...)`: Change-point localization. $\rightarrow$ **[api-analytics.md](api-analytics.md)**
- `fractal_periodogram(series, max_peaks?)`: Exact power spectrum. $\rightarrow$ **[api-analytics.md](api-analytics.md)**
- `fractal_spectrogram_entropy(series, window?, hop?, max_frames?)`: Short-time spectral entropy per frame. $\rightarrow$ **[api-analytics.md](api-analytics.md)**
- `fractal_tda_persistence_diagram(points, dim, ...)`: Point-cloud persistence. $\rightarrow$ **[api-analytics.md](api-analytics.md)**
- `fractal_state_fingerprint(v, ...)` / `fractal_cycle_detect(fingerprints, ...)`: SimHash + Brent cycle detection. $\rightarrow$ **[api-analytics.md](api-analytics.md)**
- `fractal_vector_lp_distance(a, b, p)` / `fractal_vector_quantize_int8(v)` / `_binary(v)`: Vector math and quantization. $\rightarrow$ **[api-analytics.md](api-analytics.md)**
- `fractal_optimize_portfolio(...)`: Cardinality-constrained optimization. $\rightarrow$ **[api-analytics.md](api-analytics.md)**
- `fractal_vascular_network(...)`: Vessel tortuosity/density. $\rightarrow$ **[api-analytics.md](api-analytics.md)**
- `fractal_cortical_folding(...)`: Gyrification Index. $\rightarrow$ **[api-analytics.md](api-analytics.md)**
- `fractal_nerve_plexus_metric(...)`: Fiber plexus density. $\rightarrow$ **[api-analytics.md](api-analytics.md)**
- `fractal_morphological_complexity(...)`: Mask complexity. $\rightarrow$ **[api-analytics.md](api-analytics.md)**
