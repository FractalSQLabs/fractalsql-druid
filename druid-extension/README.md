<p align="center">
  <img src="../FractalSQLforDruid.jpg" alt="FractalSQL for Apache Druid" width="720">
</p>

# fractalsql-druid

The Apache Druid extension for FractalSQL.

This module builds the JAR that a Druid node loads through
`druid.extensions.loadList`. It carries:

- the extension classes — a `DruidModule` plus the Calcite bridge that
  registers the `fractal_*` SQL surface;
- a **JNI shim** (`src/main/native/fractalsql_jni.c`) linked against the
  vendored FractalSQL core in `../include/<os>-<arch>/`.

The core in `../include/` is a **core library**: it is linked, never edited
and never rebuilt here.

---

## What it does

The extension registers two kinds of SQL function.

**Per-row functions** — the ported `fractal_*` functions are Druid
*native expressions*: a registered `ExprMacro` whose `Expr` evaluates per
row and is pushable to the data nodes. They read a Druid `ARRAY` column (or
a vector in the core's text form) and give a number, a vector or a JSON
document back.

```sql
SELECT "id",
       FRACTAL_VECTOR_COSINE_DISTANCE("emb", '[1.0,0.0,0.0]') AS "dist",
       FRACTAL_DIMENSION_DFA("series") AS "dfa"
FROM "demo_vecs"
GROUP BY "id", "emb", "series"
ORDER BY "dist" ASC
LIMIT 10;
```

> Druid requires every projected column to be a grouping key in an
> aggregating query, hence `"emb"` and `"series"` in the `GROUP BY`; and
> `ORDER BY` in a non-aggregating query is restricted to `__time`, so a
> query that ranks by a computed value has to aggregate.

A **vector argument** is a Druid `ARRAY` column or the core's text form —
CSV (`'1.0,0.5,-0.25'`) or bracketed JSON (`'[1.0,0.5,-0.25]'`). A
**vector result** comes back in the core's JSON text form, the same
convention of the core.

**One aggregate** — `fractal_search_distance(vector_column, query_text)` scores each
row's embedding against a query vector, using the core's Stochastic Fractal
Search optimizer to refine the query into a projection and then taking the
cosine distance to it. Lower is closer; `0.0` is an exact match. It is an
aggregate because it has to scan the column as a corpus rather than score a
single row, so it is expressed as an aggregate over one group per row.

```sql
SELECT "id", fractal_search_distance("emb", '[1.0,0.0,0.0]') AS "dist"
FROM "demo_vecs"
GROUP BY "id"
ORDER BY "dist" ASC
LIMIT 10;
```

The query vector is a `VARCHAR` literal in the core's text form — CSV
(`'1.0,0.5,-0.25'`) or bracketed JSON (`'[1.0,0.5,-0.25]'`). The vector
column is a Druid `ARRAY` column.

### The function surface

`FractalFn.java` is the registry: for every function it fixes the SQL
name, the shape of the arguments, where each argument lands in the native
call, and what the function returns. The Calcite binding and the native
expression macro are generated from it by
`tools/generate-fn-bindings.py`, and the JNI dispatcher switches on the
same ids — so the three cannot drift.

| Tier | Functions |
| --- | --- |
| Analytics | `fractal_dimension_dfa`, `fractal_dimension_drift`, `fractal_dimension_boxcount`, `fractal_change_point_detect`, `fractal_periodogram`, `fractal_spectrogram_entropy`, `fractal_morphological_complexity`, `fractal_optimize_portfolio`, `fractal_optimize_portfolio_ex`, `fractal_tda_persistence_diagram`, `fractal_state_fingerprint`, `fractal_state_distance`, `fractal_vascular_network`, `fractal_cortical_folding`, `fractal_nerve_plexus_metric` |
| Vector | `fractal_vector`, `fractal_vector_from_text`, `fractal_vector_to_json`, `fractal_vector_dims`, `fractal_vector_scale`, `fractal_vector_norm`, `fractal_vector_normalize`, `fractal_vector_l2_distance`, `fractal_vector_l2_squared`, `fractal_vector_cosine_distance`, `fractal_vector_cosine_similarity`, `fractal_vector_negative_inner_product`, `fractal_vector_lp_distance`, `fractal_vector_quantize_int8`, `fractal_vector_quantize_binary`, `fractal_vector_hamming_distance`, `fractal_vector_add`, `fractal_vector_sub` |

Functions that return a JSON document answer with
one here, so `JSON_VALUE` reads the fields back. Which tiers are service
calls rather than SQL functions, and why, is in `../docs/druid-integration.md`.

---

## Building

Requires JDK 17 or newer (the jar is Java 17 bytecode; Druid 37 runs on Java 17, Druid 38 on 21 and 25) and Maven 3.9+.

```bash
# The Java classes
mvn -f druid-extension/pom.xml package

# The JNI shim for the host platform: linux-x86_64, linux-aarch64, darwin-x86_64 or darwin-arm64
src/main/native/build-native-linux.sh linux-x86_64
```

The shim is staged in `src/main/native-resources/native/<os>-<arch>/` and
packaged into the JAR. That directory is deliberately **not** under
`target/`: `mvn clean` wipes `target/`, and a clean would take the
per-platform payloads with it.

The JAR lands at `druid-extension/target/fractalsql-druid-<version>.jar`.

### One JAR for every platform

A release JAR carries all four payloads, one per platform, and
`NativeLoader` picks the one that matches the running JVM. Each payload is
built natively on its own platform (the release workflow builds them on
Linux x86-64, Linux ARM64, and macOS Intel and Apple Silicon runners) and the
JAR is assembled from the four. A JAR built on one machine has only that
machine's payload.

---

## Installing into Druid

Druid's extension loader treats each entry of `druid.extensions.loadList`
as a **directory** and scans it for `*.jar`. So the JAR goes in a
directory named after the extension:

```
extensions/fractalsql-druid/fractalsql-druid.jar
```

and the properties gain:

```properties
druid.extensions.loadList=["fractalsql-druid", ...]
```

The demo stack in `../docker/` does exactly this — the JAR is baked into the
image rather than bind-mounted, because replacing a file a running
container has open truncates it mid-read and every service dies with
`ZipException: zip file is empty`.

---

## Testing

```bash
./build_test.sh                 # the whole suite
./build_test.sh --quick         # the gates that need no Docker
./build_test.sh --list          # list the gates
```

The suite covers:

- **Builds:** the extension (Java 17 bytecode), the JNI shim against the vendored core, the packaged JAR with its native payload, the `fractalsqld` daemon (C and JVM) and the MCP server.
- **The extension:** unit tests for the JNI bridge, the aggregator factory's broker-to-historical JSON round trip, and the agreement between the function registry, the macros and the SQL bindings.
- **The daemons:** protocol conformance, configuration and security refusals, the reasoning contexts, the enterprise ledger, and behaviour under bad input and allocation failure.
- **The MCP server:** schema and safety locks, protocol conformance, and every tool family.
- **Against a live Druid stack (needs Docker):** the SQL functions, the service endpoints, the demo runner, and a daemon outage with Druid still answering.

`--quick` runs everything that needs no Docker; without Docker the stack checks are skipped and say so. `--list` prints the full matrix.

---

## Layout

```
druid-extension/
  pom.xml
  tools/generate-fn-bindings.py       generates the per-function bindings
  src/main/java/com/fractalsqlabs/fractalsql/druid/
    FractalSqlDruidModule.java        the DruidModule -- the SPI entry point
    FractalFn.java                    the function registry -- the contract
    FractalExpr.java                  the native expression: evaluate a function
    FractalExprMacro.java             the ExprMacro base
    FractalOperatorConversion.java    the SQL operator base
    FractalJson.java                  the JSON writer for the document results
    FractalSqlResource.java           the /fractalsql HTTP endpoints (the service tier)
    FractalSqlService.java            the service's reads: Druid SQL, corpora, searches
    FractalSqlAgents.java             the agents (with FractalSqlAgents2 and FractalSqlAgents3)
    FractalSqlVectorizer.java         the embedding pipeline
    FractalSqlEnterprise.java         the enterprise tier, through the daemon
    FractalSqlSessions.java           per-session settings
    FractalSqlConfig.java             the extension's configuration
    FsqClient.java                    the client for the fractalsqld protocol
    FractalSqlDaemon.java             the connection to fractalsqld
    ReasoningBridge.java              reasoning and embedding calls, through the daemon
    FractalSearchSqlAggregator.java   the Calcite aggregate
    FractalSearchAggregatorFactory.java the native Druid aggregator
    Native.java                       the JNI surface
    NativeLoader.java                 finds and loads the shim
    VectorText.java                   vector text parsing
    fn/                               the generated per-function bindings
  src/main/native/
    fractalsql_jni.c                  the JNI shim
    build-native-linux.sh             cc build for Linux and macOS
  src/main/resources/META-INF/services/
    org.apache.druid.initialization.DruidModule   the SPI file
  src/main/native-resources/native/    staged payloads (build output)
```
