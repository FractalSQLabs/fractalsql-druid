# Security and memory-safety audit — FractalSQL-for-Druid

Audit date: 2026-11-16
Scope: the first-party source trees under this repository (C, C++, Java, JNI).
Deliverable: this report. **No fixes were applied** — every "suggested fix" below is a proposal only.

---

## 1. Inventory

### 1.1 Source trees and build systems

| Tree | Language | Build system | First-party? |
|---|---|---|---|
| `service/adapter/src/` | C99/C11 | `service/Makefile` (plain make, no CMake) | Yes |
| `service/daemon/`, `service/cli/` | C11 (POSIX) | `service/Makefile` | Yes |
| `service/common/`, `service/protocol/` | C11 headers | `service/Makefile` | Yes |
| `service/jvm/src/` | Java 21 + JNI (C11) | `service/Makefile` (JNI shim) | Yes |
| `mcp/src/` | C++17 | `mcp/Makefile` | Yes |
| `druid-extension/src/main/java/` | Java | Maven (`druid-extension/pom.xml`) | Yes |
| `druid-extension/src/main/native/` | C11 (JNI shim) | `druid-extension/src/main/native/build-native-linux.sh` (POSIX `sh`) | Yes |
| `include/<os>-<arch>/libfractalsql-*.a`, `*.so` | C (compiled) | prebuilt binaries, linked only — never rebuilt here | **Vendored / third-party** |
| `mcp/vendor/json.hpp` | C++ (nlohmann/json) | vendored header | **Vendored / third-party** |
| `mcp/vendor/` (sqlite3, openssl) | C | vendored | **Vendored / third-party** |

Per the audit's rules, the vendored trees were **not** analysed, with one exception: `include/fractalsql_sql.h` (the public header of the vendored core) was read as the **authoritative contract** for the JNI boundary, because first-party code calls into it. That header is where the byte-count and array-length guarantees the JNI shim violates are documented.

### 1.2 First-party files by language and size

**C — 20,140 lines** (excluding `mcp/vendor`)

```
 3411  service/adapter/src/fractalsql.c
 4087  service/adapter/src/fractalsql_enterprise.c
 1868  service/adapter/src/fractalsql_textsql.c
 1845  service/daemon/fractalsqld.c
 1434  service/adapter/src/fractalsql_cognition.c
 1352  service/adapter/src/fractalsql_vector.c
  769  service/adapter/src/fractalsql_config.c
  721  service/cli/fsqlctl.c
  674  service/adapter/src/fractalsql_session.c
  550  service/jvm/src/main/native/fsqld_jni.c
  496  service/adapter/src/fsq_audit_redact.h
  467  service/adapter/src/fractalsql_config_udf.c
  387  service/adapter/src/fractalsql_parse.c
  300  service/build/gen/daemon_udfs.h            (generated)
  286  service/adapter/src/fractalsql_config.h
  260  service/adapter/src/fractalsql_session.h
  207  service/adapter/src/fractalsql_hmac.h
  193  service/common/fsq_sha256.h
  130  service/adapter/src/fractalsql_provider.h
  125  service/protocol/fsq_protocol.h
   75  service/build/gen/shim_udfs.h              (generated)
   61  service/adapter/src/fractalsql_enterprise.h
   53  service/adapter/src/fractalsql_parse.h
   51  service/adapter/src/fractalsql_interrupt.h
   49  service/adapter/src/fsq_udf_types.h
   40  service/tests/fsync_count.c
   16  service/adapter/src/fractalsql_interrupt.c
```

**C++ — 7,836 lines**

```
 1651  mcp/src/transport_http.cpp
 1043  mcp/src/db.h
  575  mcp/src/main.cpp
  409  mcp/src/adapters/agency.cpp
  369  mcp/src/jsonrpc_server.cpp
  343  mcp/src/prompts.cpp
  300  mcp/src/tool_registry.h
  282  mcp/src/adapters/analytics.cpp
  263  mcp/src/adapters/admin.cpp
  232  mcp/src/resources.cpp
  194  mcp/src/adapters/discovery.cpp
  166  mcp/src/vectors.cpp
  163  mcp/src/logging.cpp
  138  mcp/src/concurrency.h
  115  mcp/src/policy.h
  112  mcp/src/transport_socket_posix.cpp
  108  mcp/src/jsonrpc_server.h
  107  mcp/src/errors.cpp
  105  mcp/src/transport_stdio.cpp
  105  mcp/src/lock_paths.h
  103  mcp/src/schema_lock.cpp
   93  mcp/src/adapters/enterprise.cpp
   81  mcp/src/rows.h
   79  mcp/src/mcp_json.h
```

**Java — 14,978 lines**

```
 1140  druid-extension/.../FractalSqlAgents.java
 1127  druid-extension/.../FractalExpr.java
  990  druid-extension/.../FractalSqlResource.java
  892  druid-extension/.../FractalSqlService.java
  706  druid-extension/.../FractalFn.java
  536  druid-extension/.../FractalSqlAgents3.java
  519  druid-extension/.../FractalSearchAggregatorFactory.java
  467  druid-extension/.../FractalSqlAgents2.java
  422  druid-extension/.../FsqClient.java
  403  druid-extension/.../FractalSqlVectorizer.java
  355  druid-extension/.../FractalSqlConfig.java
  351  druid-extension/.../FractalSqlEnterprise.java
  335  druid-extension/.../FractalSqlAgents.java (dispatch)
  328  service/jvm/.../Dispatcher.java
  250  druid-extension/.../FractalSearchSqlAggregator.java
  235  druid-extension/.../FractalSqlSessions.java
  214  druid-extension/.../FractalOperatorConversion.java
  198  druid-extension/.../FractalJson.java
  186  service/jvm/.../Connection.java
  182  druid-extension/.../Native.java
  180  service/jvm/.../Server.java
  173  service/jvm/.../SelfTest.java
  171  druid-extension/.../ReasoningBridge.java
  164  druid-extension/.../fn/FractalFnBindings.java
  159  druid-extension/.../NativeLoader.java
  150  druid-extension/.../VectorText.java
  119  druid-extension/.../FractalExprMacro.java
  112  service/jvm/.../Protocol.java
```

### 1.3 Hardening posture already present

Both Makefiles and the JNI build script already probe and apply: `-fstack-protector-strong`, `-fstack-clash-protection`, `-fcf-protection` (x86-64 Linux only), `-D_FORTIFY_SOURCE=2`, `-fPIE`/`-pie`, `-Wl,-z,relro,-z,now`, `-Wl,-z,noexecstack`. ASAN, UBSAN, TSAN and coverage build variants exist for the daemon and the MCP server. `build_test.sh` gate 32 asserts these properties on the produced binaries. The gaps are listed in §5.

---

## 2. Trust boundaries

| # | Boundary | Where untrusted data enters |
|---|---|---|
| B1 | Unix socket | `service/daemon/fractalsqld.c` — a client connects; the frame header (`opcode`, `payload_len`, `context`) is attacker-controlled before authentication. Peer identity is restricted to a uid allow-list via `SO_PEERCRED`/`getpeereid` (`fractalsqld.c:1442-1467`). |
| B2 | Daemon CLI | `service/cli/fsqlctl.c` — argv and the key file. |
| B3 | JNI boundary (Druid → native core) | `druid-extension/src/main/native/fractalsql_jni.c` — SQL-supplied `double[]`/`byte[]` arrays and scalars cross into the vendored C core. **Both sides must be treated as one dataflow.** |
| B4 | Druid SQL | `druid-extension/.../FractalExpr.java` — expression macros. Any user who can submit a Druid query can call every registered function with arbitrary arguments. |
| B5 | Druid HTTP (extension endpoints) | `druid-extension/.../FractalSqlResource.java` — `@Path("/fractalsql")`, `POST /agent/{name}` takes a free-form JSON body that becomes the agent's arguments. |
| B6 | Druid HTTP → Druid SQL (loopback) | `FractalSqlService.query()` / `corpusRows()` issue `POST http://127.0.0.1:<port>/druid/v2/sql` with **no** `Authorization` header (`FractalSqlService.java:545-575`). |
| B7 | MCP HTTP | `mcp/src/transport_http.cpp` — bearer-token auth, loopback-origin check, per-request threads, 32 MiB body cap. |
| B8 | MCP → Druid | `mcp/src/db.h` — `DbConnection` talks to Druid over HTTP/TLS. |
| B9 | Config / env | `service/daemon/fractalsqld.c` config file, `FractalSqlConfig.java` properties, `FractalSqlConfig` env overrides. |
| B10 | Native library extraction | `druid-extension/.../NativeLoader.java` — the JNI `.so` is extracted from the JAR to a temp file and `System.load`ed. |
| B11 | Model output | `FractalSqlAgents3.sqlAgent` — SQL written by a reasoning model, gated by a statement allow-list. |

Findings below are ordered by severity. "Reachability" states the entry point and the call chain, and says explicitly when a finding is **not** reachable from untrusted input.

---

## 3. Findings

---

### 3.1 Daemon accepts a forged frame when the HMAC buffer allocation fails (fail-open authentication)

* **File:line:** `service/daemon/fractalsqld.c:648-656` and `service/daemon/fractalsqld.c:1576-1577`
* **Language:** C
* **Severity:** High · **CWE-390** (Detection of Error Condition Without Action), **CWE-347** (Improper Verification of Cryptographic Signature)

**Defect.** `mac()` computes the expected HMAC tag into a freshly `malloc`ed buffer, and on allocation failure it fills that buffer with zeros and returns normally — so the subsequent tag comparison degenerates into "does the client's tag equal 32 zero bytes?" instead of failing closed.

**Code.**

```c
/* fractalsqld.c:648 */
static void mac(const struct fsq_config *cfg, const uint8_t *hdr,
                const uint8_t *payload, size_t plen, uint8_t tag[FSQ_TAG_LEN]) {
    uint8_t *msg = malloc(FSQ_HEADER_LEN + plen);
    if (!msg) { memset(tag, 0, FSQ_TAG_LEN); return; }   /* <-- fail-open */
    memcpy(msg, hdr, FSQ_HEADER_LEN);
    if (plen) memcpy(msg + FSQ_HEADER_LEN, payload, plen);
    fsq_hmac_sha256(cfg->key, cfg->key_len, msg, FSQ_HEADER_LEN + plen, tag);
    free(msg);
}
```

```c
/* fractalsqld.c:1576 */
        mac(cfg, hdr, payload, h.payload_len, want);
        if (!fsq_ct_equal(tag, want, FSQ_TAG_LEN)) {
            fsq_log("WARN", "connection %llu from %s failed authentication (opcode 0x%04x, request %u)",
                    (unsigned long long) t_conn, peer, (unsigned) h.opcode, (unsigned) h.request_id);
            free(payload);
            break;
        }
```

**Reachability.** Reachable from untrusted input: the Unix socket (B1). `handle_conn()` reads the frame, then calls `mac()` and compares. The peer must be in the uid allow-list (`fractalsqld.c:1442-1467`), so this is an allow-listed-but-unauthenticated peer — the HMAC is the second factor, and it is the one that fails open.

**Failure scenario.** The daemon allocates the *entire* payload before authenticating it (see finding 3.9), so an allow-listed peer can drive the daemon's heap into exhaustion with concurrent 80 MiB frames. Under that pressure `malloc(FSQ_HEADER_LEN + plen)` fails, `want` becomes 32 zero bytes, and the peer sends a 32-byte zero tag. `fsq_ct_equal` returns 1 and the frame is dispatched as authenticated — a full authentication bypass, executing an arbitrary opcode with attacker-chosen arguments.

**Suggested fix.** Do not overwrite the expected tag on the error path; make the failure fatal to the request instead:

```diff
 static void mac(const struct fsq_config *cfg, const uint8_t *hdr,
                 const uint8_t *payload, size_t plen, uint8_t tag[FSQ_TAG_LEN]) {
     uint8_t *msg = malloc(FSQ_HEADER_LEN + plen);
-    if (!msg) { memset(tag, 0, FSQ_TAG_LEN); return; }
+    if (!msg) {
+        /* Fail closed: an all-zero tag would be accepted by a client
+           that sends an all-zero tag. Use a value no real HMAC can take. */
+        memset(tag, 0xA5, FSQ_TAG_LEN);
+        return;
+    }
```

and, better, change `mac()` to return `int` (`0` on success) and have `handle_conn()` break out of the connection on a non-zero return, so an allocation failure is never confused with a tag mismatch.

**Confidence.** **Confirmed** for the defect (the fail-open path is present verbatim and the comparison is a plain equality against the buffer `mac()` filled). **Plausible** for the end-to-end bypass, because it additionally requires the allocator to fail at that exact point; the assumption a reviewer must confirm is that the daemon's heap can be exhausted by concurrent pre-auth payloads on the target deployment (bounded by `FSQ_DEFAULT_MAX_CONNECTIONS` = 64 at `fractalsqld.c:59` and `FSQ_MAX_PAYLOAD` = 80 MiB at `fsq_protocol.h:21`).

---

### 3.2 JNI cycle-detect feeds the core a fingerprint shorter than the detector's width — heap over-read

* **File:line:** `druid-extension/src/main/native/fractalsql_jni.c:473-499`; caller `druid-extension/src/main/java/com/fractalsqlabs/fractalsql/druid/FractalExpr.java:462-505`
* **Language:** C (JNI) + Java
* **Severity:** High · **CWE-125** (Out-of-bounds Read)

**Defect.** The shim initialises the core's cycle detector with `n_bytes = (bits+7)/8` taken from one SQL argument, then feeds it fingerprints whose byte length comes from a *different*, unrelated JSON payload — without ever checking that the two agree, so the core reads `n_bytes` bytes out of a shorter buffer.

**Code.**

```c
/* fractalsql_jni.c:473 */
    const jsize n = fingerprints ? (*env)->GetArrayLength(env, fingerprints) : 0;
    const size_t bits = (size_t) (nBits > 0 ? nBits : 64);
    const size_t n_bytes = (bits + 7) / 8;

    fsql_cycle_state_t cs;
    memset(&cs, 0, sizeof cs);
    if (fsql_cycle_detect_init(&cs, n_bytes, (size_t) (hammingThreshold > 0 ? hammingThreshold : 0)) != FSQL_OK) {
        return NULL;
    }

    int    detected  = 0;
    size_t cycle_len = 0;
    long   at_index  = -1;

    for (jsize i = 0; i < n; i++) {
        jbyteArray one = (jbyteArray) (*env)->GetObjectArrayElement(env, fingerprints, i);
        if (one == NULL) {
            continue;
        }
        jbyte *bytes = (jbyte *) (*env)->GetByteArrayElements(env, one, NULL);
        int    d = 0;
        size_t cl = 0;
        const int rc = fsql_cycle_detect_feed(&cs, (const uint8_t *) bytes, &d, &cl);
```

The vendored core's own contract states the requirement the shim omits:

```c
/* include/fractalsql_sql.h:696 */
/* Feeds the next fingerprint in the stream (n_bytes bytes, matching the
 * size passed to fsql_cycle_detect_init). The first call after
 * init just seeds the checkpoint. */
FSQL_API int fsql_cycle_detect_feed(fsql_cycle_state_t *cs, const uint8_t *fingerprint,
                                    int *out_detected, size_t *out_cycle_len);
```

and on the Java side nothing cross-checks the lengths either:

```java
/* FractalExpr.java:462 */
    private String cycleDetect(Object[] raw)
    {
        final String json = asText(raw[0]);
        final int bits = (int) number(raw[1], 64);
        final int threshold = (int) number(raw[2], 3);
        final List<byte[]> fingerprints = new ArrayList<>();
        try {
            final JsonNode root = MAPPER.readTree(json == null ? "[]" : json);
            if (root.isArray()) {
                for (JsonNode node : root) {
                    fingerprints.add(hexToBytes(node.asText()));
                }
            }
        } catch (Exception e) { ... }
        final byte[][] array = fingerprints.toArray(new byte[0][]);
        final String verdict = Native.cycleDetect(array, bits, threshold);
```

**Reachability.** Reachable from untrusted input: a Druid SQL expression (B4). `FRACTAL_CYCLE_DETECT(json, bits, threshold)` dispatches at `FractalExpr.java:194` (`spec.id() == 58`) → `cycleDetect(raw)` → `Native.cycleDetect` → the shim.

**Failure scenario.** `SELECT FRACTAL_CYCLE_DETECT('["00"]', 64, 3)` — one fingerprint of 1 byte, `bits = 64` so `n_bytes = 8`. The core's `fsql_cycle_detect_feed` reads 8 bytes from the 1-byte Java `byte[]`. The JVM's `byte[]` is heap-allocated; the read runs off the end of the array into adjacent heap objects, and the bytes compared become the Hamming-distance input and the checkpoint the detector stores. Depending on what follows the array in the Java heap, the result is either a wrong verdict or a JVM heap corruption. Because `bits` and the JSON array are independent arguments, the attacker chooses the over-read length exactly.

**Suggested fix.** Validate on both sides. In `FractalExpr.java`, reject fingerprints whose length does not match the requested width:

```diff
-        final byte[][] array = fingerprints.toArray(new byte[0][]);
+        final int nBytes = (bits + 7) / 8;
+        for (byte[] fp : fingerprints) {
+            if (fp.length != nBytes) {
+                throw new IllegalArgumentException(
+                        "fractalsql: fractal_cycle_detect() expects " + nBytes
+                        + "-byte fingerprints for " + bits + " bits, got " + fp.length);
+            }
+        }
+        final byte[][] array = fingerprints.toArray(new byte[0][]);
```

and, independently, in the shim — the shim must not trust Java:

```diff
-        const int rc = fsql_cycle_detect_feed(&cs, (const uint8_t *) bytes, &d, &cl);
+        const jsize have = (*env)->GetArrayLength(env, one);
+        if (have < 0 || (size_t) have != n_bytes) {
+            (*env)->ReleaseByteArrayElements(env, one, bytes, JNI_ABORT);
+            (*env)->DeleteLocalRef(env, one);
+            break;   /* or return an error: the fingerprint width is wrong */
+        }
+        const int rc = fsql_cycle_detect_feed(&cs, (const uint8_t *) bytes, &d, &cl);
```

**Confidence.** **Confirmed.** The core's contract in `include/fractalsql_sql.h:696-698` explicitly fixes the byte count to the `fsql_cycle_detect_init` width, and no length comparison exists anywhere between `FractalExpr.hexToBytes` (which produces `s.length()/2` bytes from an arbitrary hex string) and `fsql_cycle_detect_feed`. The disassembled `cycle_detect_sovereign.o` in the vendored archive confirms the core copies a fixed `n_bytes` from the supplied pointer.

---

### 3.3 JNI vascular network passes an edge count that does not match the edges array — heap over-read

* **File:line:** `druid-extension/src/main/native/fractalsql_jni.c:764-776`
* **Language:** C (JNI)
* **Severity:** High · **CWE-125** (Out-of-bounds Read)

**Defect.** `n_edges` is taken from the length of the *arc-length* array while the *edge index* array is a different, independently sized array, so the core is told there are more edges than the array holds.

**Code.**

```c
/* fractalsql_jni.c:764 */
        case 11: { /* fractal_vascular_network(nodes, edges, arc_lengths) */
            if (a && b && c) {
                size_t *edges = doubles_to_sizes(b, (size_t)bLen);
                if (edges) {
                    double tortuosity = 0.0, branch_density = 0.0, dimension = 0.0;
                    rc = fsql_vascular_network(a, (size_t)aLen / 3, edges, c, (size_t)cLen,
                                               &tortuosity, &branch_density, &dimension);
```

The core's contract:

```c
/* include/fractalsql_sql.h:897 */
FSQL_API int fsql_vascular_network(const double *node_coords, size_t n_nodes,
                                   const size_t *edges, const double *edge_arc_length,
                                   size_t n_edges,
                                   double *out_mean_tortuosity, double *out_branch_density,
                                   double *out_fractal_dimension);
```

with the header's own note that `edges` is `n_edges * 2` node indices, and the sibling function at `fractalsql_jni.c:807` getting the same thing right (`(size_t)bLen / 2`).

**Reachability.** Reachable from untrusted input: a Druid SQL expression (B4) → `FractalExpr.evaluate` → `Native.callFn(11, a, aLen, b, bLen, c, cLen, …)` (`FractalExpr.java:861-867`).

**Failure scenario.** `SELECT FRACTAL_VASCULAR_NETWORK(<3 doubles per node>, <2 doubles = 1 edge>, <1000 arc lengths>)`. `bLen = 2` gives a 2-element `edges` array, but `cLen = 1000` tells the core there are 1000 edges, i.e. 2000 node indices. The core reads `edges[0..2000)` from a 2-element heap buffer — a 1998-`size_t` (≈16 KB) heap over-read whose contents become node indices used to index the `node_coords` array, so the corrupted values also drive out-of-bounds reads inside the core's own graph traversal.

**Suggested fix.** Derive the edge count from the edges array and cross-check it against the arc-length array:

```diff
-                    rc = fsql_vascular_network(a, (size_t)aLen / 3, edges, c, (size_t)cLen,
+                    if ((size_t)bLen % 2 != 0) { free(edges); break; }
+                    const size_t n_edges = (size_t)bLen / 2;
+                    if ((size_t)cLen != n_edges) { free(edges); break; }
+                    rc = fsql_vascular_network(a, (size_t)aLen / 3, edges, c, n_edges,
                                                &tortuosity, &branch_density, &dimension);
```

**Confidence.** **Confirmed.** The header documents `edges` as `n_edges * 2` node indices (`include/fractalsql_sql.h:919` for the sibling, and the core's `fsqli_vascular_network_metrics` entry point in the vendored archive consumes `n_edges*2` edge entries); the shim passes `cLen` as `n_edges` while `edges` is sized from `bLen`.

---

### 3.4 One native core context is shared across every Druid thread although the core is documented as not thread-safe

* **File:line:** `druid-extension/src/main/java/com/fractalsqlabs/fractalsql/druid/FractalSqlCore.java:23-57`; contract in `druid-extension/src/main/java/com/fractalsqlabs/fractalsql/druid/Native.java:15-22`
* **Language:** Java
* **Severity:** High · **CWE-362** (Concurrent Execution using Shared Resource with Improper Synchronization)

**Defect.** A single `long` handle to the native core context is handed to every query thread on the node, while the project's own documentation states that a context is not thread-safe.

**Code.**

```java
/* FractalSqlCore.java:23 */
@Singleton
public class FractalSqlCore {

    /** The handle, or 0 before the context is created. */
    private volatile long handle;

    ...
    public long handle()
    {
        long current = handle;
        if (current != 0) {
            return current;              /* <-- the same context for every thread */
        }
        synchronized (this) {
            if (handle == 0) {
                NativeLoader.load();
                final long created = Native.newSovereign();
                ...
                handle = created;
            }
            return handle;
        }
    }
```

```java
/* Native.java:15 */
 * <p>The core's own contract applies throughout:
 * <ul>
 *   <li>result JSON is owned by the core and stays valid until the next
 *       call on the same context -- {@link #release(long)} frees it early;</li>
 *   <li>a context is not thread-safe; use one per thread, or serialise
 *       access;</li>
```

The `volatile`/`synchronized` block only protects *creation*. It does not serialise *use*. Every consumer takes the same handle:

```java
/* FractalExpr.java:326 */      final int rc = Native.diversifyEnable(core().handle());
/* FractalExpr.java:393 */      core().handle(), window, stall, sigma, weight, shadows, tail);
/* FractalExpr.java:407 */      final double dq = Native.diversifyCurrentDq(core().handle());
/* FractalSearchSqlAggregator.java:233 */  final long ctx = core.handle();
```

**Reachability.** Reachable from untrusted input: any Druid query (B4) that calls a function backed by the shared context — `FRACTAL_DIVERSIFY_ENABLE`, `FRACTAL_DIVERSIFY_METRICS`, the search family — and the search aggregator's `refine()` (`FractalSearchSqlAggregator.java:226-249`), which runs at **plan time in the broker** while the expression macros run at **execution time on the historical**. Two different Druid processes share one native library but, within each, the broker's plan-time call and the historical's execution-time call both hit the same node-local singleton.

**Failure scenario.** Two Druid queries execute concurrently on the same historical. Both call `Native.diversifyEnable(core().handle())` / `Native.diversifyCurrentDq(core().handle())`. The core mutates its internal monitor state and, per its own contract, the "result JSON is owned by the core and stays valid until the next call on the same context" — so thread A reads a result buffer that thread B has already overwritten, or two threads mutate the same monitor state concurrently. The result is corrupted numeric output; where the core's internal state is a linked list or a refcounted buffer, it is a use-after-free or a double-free inside the native library, crashing the JVM with a SIGSEGV in native code (which the JVM cannot catch).

**Suggested fix.** Serialise access to the shared context with a lock held around the whole native call, or give each thread its own context. The cheapest correct change is a lock in `FractalSqlCore`:

```java
@Singleton
public class FractalSqlCore {
    private volatile long handle;
    private final java.util.concurrent.locks.ReentrantLock lock =
            new java.util.concurrent.locks.ReentrantLock();

    /** Runs a native call under the context lock. */
    public <T> T withContext(java.util.function.LongFunction<T> call) {
        lock.lock();
        try {
            return call.apply(handle());
        } finally {
            lock.unlock();
        }
    }
}
```

and route every `Native.*(core().handle(), …)` call through it. (A per-thread context, keyed by `Thread.currentThread()`, is the alternative if the contention matters — but note that the diversify monitor is deliberately *node-wide* state, so a per-thread context changes semantics and a lock is the faithful fix.)

**Confidence.** **Confirmed** for the sharing and the documented non-thread-safety — both are quoted above from first-party files. **Plausible** for the precise crash, because it depends on which core function is entered; the assumption a reviewer must confirm is that the vendored core's context state is genuinely mutated (not read-only) by the functions reachable through these macros. The disassembled `fsqli_diversify_*` entry points in the vendored archive mutate the context's monitor fields, which supports it.

---

### 3.5 SQL injection through unescaped identifiers and a verbatim filter in the agent tier

* **File:line:** `druid-extension/src/main/java/com/fractalsqlabs/fractalsql/druid/FractalSqlAgents.java:989-994`, `:393-396`, `:872-874`; sink `druid-extension/src/main/java/com/fractalsqlabs/fractalsql/druid/FractalSqlService.java:226-236`
* **Language:** Java
* **Severity:** High · **CWE-89** (SQL Injection)

**Defect.** Agent arguments that name a table or a column are concatenated into a SQL string without escaping, and one argument (`meta_filter`) is appended as a complete raw SQL fragment.

**Code.**

```java
/* FractalSqlAgents.java:989 */
    private double[] metricSeries(
            String table, String metricColumn, String timeColumn,
            String filterColumn, String filterValue) throws Exception
    {
        ...
        final String sql = "SELECT CAST(\"" + metricColumn + "\" AS DOUBLE) AS \"v\" FROM \""
                + table + "\" WHERE \"" + filterColumn + "\" = '"
                + filterValue.replace("'", "''") + "'" + order;
```

Note the asymmetry: `filterValue` (a literal) is escaped; `table`, `metricColumn` and `filterColumn` (identifiers) are not.

```java
/* FractalSqlAgents.java:393 */
        final String filter = filterColumn == null || filterValue == null
                ? null
                : "\"" + filterColumn + "\" = '" + filterValue.replace("'", "''") + "'";
        final List<Object[]> rows = service.corpusRows(table, vecColumn, idColumn, filter);
```

```java
/* FractalSqlAgents.java:872 */
        final String metaFilter = args.get("meta_filter") == null ? null : args.get("meta_filter").toString();

        final List<Object[]> rows = service.corpusRows(table, column, null, metaFilter);
```

and the sink, which escapes the identifiers it is given but appends `filter` verbatim:

```java
/* FractalSqlService.java:226 */
    public List<Object[]> corpusRows(
            String datasource,
            String vectorColumn,
            String idColumn,
            String filter) throws Exception
    {
        final StringBuilder sql = new StringBuilder("SELECT ");
        sql.append('"').append(vectorColumn.replace("\"", "\"\"")).append('"');
        ...
        sql.append(" FROM \"").append(datasource.replace("\"", "\"\"")).append('"');
        if (filter != null && !filter.isEmpty()) {
            sql.append(" WHERE ").append(filter);        /* <-- raw */
        }
```

The same file already contains the correct pattern — `oneCell` escapes identifiers, and `FractalSqlAgents3.identifier()` refuses anything that is not a plain identifier:

```java
/* FractalSqlAgents.java:1015 */
        final List<Map<String, Object>> rows = service.query(
                "SELECT \"" + column.replace("\"", "\"\"") + "\" AS \"v\" FROM \""
                        + table.replace("\"", "\"\"") + "\"");
```

```java
/* FractalSqlAgents3.java:473 */
    private static String identifier(Map<String, Object> args, String name)
    {
        final String value = required(args, name);
        if (!value.matches("[A-Za-z_][A-Za-z0-9_]*")) {
            throw new IllegalArgumentException(
                    "fractalsql: " + name + " must be a plain identifier "
                            + "([A-Za-z_][A-Za-z0-9_]*), got: " + value);
        }
        return value;
    }
```

**Reachability.** Reachable from untrusted input: the Druid HTTP endpoint `POST /druid/v2/fractalsql/agent/{name}` (B5) → `FractalSqlResource.agent()` (`FractalSqlResource.java:675-718`) → `agents.run(name, args)` (`FractalSqlAgents.java:58-119`) → `metricSeries` / `recallHybrid` / `ragAgent` → `FractalSqlService.corpusRows`/`query` → `POST http://127.0.0.1:<port>/druid/v2/sql`. The `rag_agent` and `recall_hybrid` agent names are dispatched from `FractalSqlAgents.run`'s switch; `metricSeries` is called from within the agent family.

**Failure scenario.** `POST /druid/v2/fractalsql/agent/rag_agent` with body `{"table":"t","col":"c","meta_filter":"1=1 UNION SELECT password FROM sys.credentials --"}`. `corpusRows` builds `SELECT "c" FROM "t" WHERE 1=1 UNION SELECT password FROM sys.credentials --` and sends it to the Druid SQL endpoint. Because the extension's own outbound request carries **no** `Authorization` header (`FractalSqlService.java:552-560`), it runs with whatever the Druid node's internal request context grants — typically full internal access, which is broader than the caller's. The result is returned in the agent's response. The identifier variant works the same way: `"table":"t\" FROM \"t\" WHERE 1=1 UNION SELECT ..."`.

**Suggested fix.** Route every identifier through the existing validator and never accept a raw SQL fragment.

```diff
--- FractalSqlAgents.java
-        final String sql = "SELECT CAST(\"" + metricColumn + "\" AS DOUBLE) AS \"v\" FROM \""
-                + table + "\" WHERE \"" + filterColumn + "\" = '"
-                + filterValue.replace("'", "''") + "'" + order;
+        final String sql = "SELECT CAST(\"" + quoteIdent(metricColumn) + "\" AS DOUBLE) AS \"v\" FROM \""
+                + quoteIdent(table) + "\" WHERE \"" + quoteIdent(filterColumn) + "\" = '"
+                + filterValue.replace("'", "''") + "'" + order;
```

with a single shared helper (the `FractalSqlService.corpusRows` idiom already in the codebase):

```java
    /** A SQL identifier, with any embedded double quote doubled. */
    static String quoteIdent(String name) {
        return name == null ? "" : name.replace("\"", "\"\"");
    }
```

and for `meta_filter`, replace the raw fragment with a structured filter that the code assembles from named parts, or drop the parameter. If a raw predicate is genuinely required, it must be validated against a strict allow-list rather than escaped.

**Confidence.** **Confirmed.** The concatenation is verbatim in the quoted lines, the sink appends `filter` without escaping, and the escaping helper (`replace("\"", "\"\"")`) already exists elsewhere in the same class — which is what establishes that the agent tier is the outlier rather than the house style. The *exploitation* depends on the deployment's Druid authorisation for the extension's HTTP paths, which is deployment-specific (see Reachability caveat in §4).

---

### 3.6 JNI portfolio optimisation never checks the `mu` array length against the asset count — heap over-read

* **File:line:** `druid-extension/src/main/native/fractalsql_jni.c:663-694`
* **Language:** C (JNI)
* **Severity:** High · **CWE-125** (Out-of-bounds Read)

**Defect.** The asset count is derived from the covariance array's length and the covariance array's size is validated, but the expected-return vector `mu` is passed to the core with no length check against that asset count.

**Code.**

```c
/* fractalsql_jni.c:663 */
        case 8:   /* fractal_optimize_portfolio(mu, cov, k) */
        case 14: { /* fractal_optimize_portfolio_ex(mu, cov, k, obl, diffusion) */
            /* The covariance matrix arrives flattened: n*n entries,
             * row-major, so the asset count falls out of its length. */
            size_t n_assets = 0;
            if (b && bLen > 0) {
                n_assets = (size_t)llround(sqrt((double)bLen));
            }
            if (n_assets > 0 && b && (size_t)bLen >= n_assets * n_assets) {
                double *weights = (double *)calloc(n_assets, sizeof(double));
                if (weights) {
                    double sharpe = 0.0;
                    if (fnId == 8) {
                        rc = fsql_optimize_portfolio(a, b, n_assets, (size_t)p1,
                                                     (uint64_t)0, weights, &sharpe);
```

The core's contract:

```c
/* include/fractalsql_sql.h:723 */
/* mu: n_assets expected returns ... */
FSQL_API int fsql_optimize_portfolio(const double *mu, const double *cov,
                                     size_t n_assets, size_t k, uint64_t seed,
                                     double *out_weights, double *out_sharpe);
```

`aLen` is never compared with `n_assets`, and `p1` (the `k`) is only checked inside the core (`FSQ_ERR_INVALID` for `k > n_assets`).

**Reachability.** Reachable from untrusted input: a Druid SQL expression (B4) → `FractalExpr.evaluate` → `Native.callFn(8|14, a, aLen, b, bLen, c, cLen, …)` (`FractalExpr.java:861-867`, results formatted at `FractalExpr.java:952-958`).

**Failure scenario.** `SELECT FRACTAL_OPTIMIZE_PORTFOLIO(ARRAY[1.0], <36 doubles = 6x6 covariance>)`. `n_assets = round(sqrt(36)) = 6`, the covariance check passes, but `a` holds a single double. The core reads `mu[0..6)` from a 1-element Java `double[]` — a 5-double (40-byte) heap over-read whose values become the assets' expected returns, and therefore the Sharpe ratio the query returns.

**Suggested fix.** Validate the `mu` length against the asset count before the call:

```diff
             if (n_assets > 0 && b && (size_t)bLen >= n_assets * n_assets) {
+                if (!a || (size_t)aLen != n_assets) {
+                    /* mu must have one expected return per asset */
+                    break;
+                }
                 double *weights = (double *)calloc(n_assets, sizeof(double));
```

**Confidence.** **Confirmed.** `aLen` is in scope in this case block and is used for the other cases (e.g. `(size_t)aLen / 3` at `fractalsql_jni.c:768`), so the omission is local to this branch; the core's documented `mu: n_assets expected returns` contract makes the required length exact.

---

### 3.7 The MCP server mints contexts without the session cap that the `initialize` path enforces

* **File:line:** `mcp/src/transport_http.cpp:983-1007` (minting) versus `mcp/src/transport_http.cpp:1137-1143` (the cap)
* **Language:** C++
* **Severity:** Medium · **CWE-770** (Allocation of Resources Without Limits or Throttling)

**Defect.** `resolveContext()` inserts a fresh context into `state.contexts` on every request that names none, with no upper bound, while the `initialize` handler refuses to exceed `maxSessions()`.

**Code.**

```cpp
/* transport_http.cpp:983 */
    static bool resolveContext( ClientState& state, const std::string& requested, const std::string& ownerFp,
                                std::string& contextIdOut, std::string& connKeyOut,
                                std::vector<std::string>& expiredConnKeys )
    {
        std::lock_guard<std::mutex> lk( state.mu );
        expireLocked( state, expiredConnKeys );
        const auto now = std::chrono::steady_clock::now();
        if( !requested.empty() )
        {
            auto it = state.contexts.find( requested );
            if( it == state.contexts.end() || it->second.ownerFp != ownerFp ) return false;
            it->second.lastUse = now;
            contextIdOut = requested;
            connKeyOut = it->second.connKey;
            return true;
        }
        const std::string id = mintContextId();
        // The connection key is derived from the handle, so two contexts
        // never share a connection.
        const std::string connKey = "ctx:" + id;
        state.contexts[ id ] = ClientState::Context{ connKey, ownerFp, now };   /* <-- uncapped */
        contextIdOut = id;
        connKeyOut = connKey;
        return true;
    }
```

```cpp
/* transport_http.cpp:1137 */
            if( state.contexts.size() >= maxSessions() )
            {
                for( const std::string& k : expiredConnKeys ) if( closeSession ) closeSession( k );
                sendHttpJson( io, 503, Json{ { "error", "too many open MCP sessions" } } );
                return;
            }
```

**Reachability.** Reachable from untrusted input: the MCP HTTP transport (B7), after a successful bearer-token check. The `initialize` cap protects only the handshake path; the `resolveContext` path is reached by ordinary tool calls that do not carry a context handle.

**Failure scenario.** An authenticated client sends 10^6 requests, each naming no context. Each mints a new context id, each context owns a `connKey` that the `Db` registry may open a Druid connection for (`mcp/src/db.h:1022-1037`). `state.contexts` and the `Db` connection map grow without bound; the process's memory and its Druid connection count grow with it, exhausting the Druid broker's connection pool and the MCP process's heap.

**Suggested fix.** Apply the same cap inside `resolveContext`, which is the choke point:

```diff
         const std::string id = mintContextId();
         // The connection key is derived from the handle, so two contexts
         // never share a connection.
         const std::string connKey = "ctx:" + id;
+        if( state.contexts.size() >= maxSessions() )
+        {
+            for( const std::string& k : expiredConnKeys ) if( closeSession ) closeSession( k );
+            return false;   /* caller answers 503 */
+        }
         state.contexts[ id ] = ClientState::Context{ connKey, ownerFp, now };
```

**Confidence.** **Confirmed.** The two code paths are quoted above; the cap exists in one and not in the other. Whether `resolveContext`'s callers currently distinguish "no such context" from "too many contexts" (both return `false` today) is the one implementation detail a reviewer must confirm when wiring the 503 through.

---

### 3.8 The MCP cancel set grows without bound, and every cancel echoes the request id to stderr

* **File:line:** `mcp/src/jsonrpc_server.cpp:356` (and the sole erase at `:320-323`); `mcp/src/logging.cpp:95-104`
* **Language:** C++
* **Severity:** Medium · **CWE-770** (Allocation of Resources Without Limits or Throttling)

**Defect.** `cancel()` inserts the request id into `cancelledIds_` unconditionally, but the set is only ever cleared in the completion path of a request that is actually in flight — so cancelling an id that was never in flight leaks it permanently, and the id is written to stderr in full.

**Code.**

```cpp
/* jsonrpc_server.cpp:351 */
    void JsonRpcServer::cancel( const std::string& requestId )
    {
        std::string clientKey;
        {
            std::lock_guard<std::mutex> lk( inflightMu_ );
            cancelledIds_.insert( requestId );            /* <-- unconditional */
            auto it = inflightSessions_.find( requestId );
            if( it != inflightSessions_.end() ) clientKey = it->second;
        }
        if( interruptHook && !clientKey.empty() )
            interruptHook( clientKey );   // adapter-layer interrupt (engine-specific)
        logging::event( "cancel_propagated", Json{ { "request", requestId } } );
    }
```

The only removal:

```cpp
/* jsonrpc_server.cpp:320 */
            bool cancelledAfter = false;
            { std::lock_guard<std::mutex> lk( inflightMu_ );
              cancelledAfter = cancelledIds_.count( requestId ) != 0;
              inflightSessions_.erase( requestId );
              cancelledIds_.erase( requestId ); }
```

and the log write:

```cpp
/* logging.cpp:95 */
    static void emitLine( const Json& extra )
    {
        Json line{ { "ts", nowIso() } };
        for( auto it = extra.begin(); it != extra.end(); ++it )
            line[ it.key() ] = it.value();
        std::lock_guard<std::mutex> lk( g_stderrMu );
        std::fputs( line.dump().c_str(), stderr );
        std::fputc( '\n', stderr );
        std::fflush( stderr );
    }
```

**Reachability.** Reachable from untrusted input: the MCP HTTP transport (B7). `notifications/cancelled` is dispatched by `handleCancelNotification` (`transport_http.cpp:1163-1172`) and by the modern dispatch path (`transport_http.cpp:1199-1268`).

**Failure scenario.** An authenticated client posts 10^7 `notifications/cancelled` messages, each naming a request id that was never issued. `cancelledIds_` grows to 10^7 `std::string`s and never shrinks, and each id is written to stderr — first as memory, then as log volume (the ids are attacker-chosen strings, so the attacker also chooses the bytes written to the log, up to the transport's body cap of 32 MiB per request). The MCP process's RSS grows without bound and its stderr fills the supervisor's log partition.

**Suggested fix.** Only remember ids that are actually in flight, and bound the set:

```diff
         {
             std::lock_guard<std::mutex> lk( inflightMu_ );
-            cancelledIds_.insert( requestId );
             auto it = inflightSessions_.find( requestId );
-            if( it != inflightSessions_.end() ) clientKey = it->second;
+            if( it == inflightSessions_.end() ) { /* nothing to cancel */ }
+            else
+            {
+                clientKey = it->second;
+                if( cancelledIds_.size() < 1024 ) cancelledIds_.insert( requestId );
+            }
         }
```

and truncate the id in the log line (`requestId.substr(0, 64)`).

**Confidence.** **Confirmed.** The insert is unconditional and the only `erase` is in the completion path, which is unreachable for an id that was never in flight.

---

### 3.9 The daemon allocates the whole payload, and then a second copy of it, before authenticating the frame

* **File:line:** `service/daemon/fractalsqld.c:1571-1576` and `service/daemon/fractalsqld.c:650`
* **Language:** C
* **Severity:** Medium · **CWE-789** (Memory Allocation with Excessive Size Value), **CWE-400** (Uncontrolled Resource Consumption)

**Defect.** Up to 80 MiB is allocated and filled from the socket before the HMAC is checked, and the HMAC computation then allocates a second 80 MiB buffer to hash — so an unauthenticated peer can make the daemon hold 160 MiB per connection.

**Code.**

```c
/* fractalsqld.c:1571 */
        if (read_all(fd, tag, FSQ_TAG_LEN) != 0) break;
        if (h.payload_len) {
            payload = malloc(h.payload_len);
            if (!payload || read_all(fd, payload, h.payload_len) != 0) { free(payload); break; }
        }
        mac(cfg, hdr, payload, h.payload_len, want);
```

```c
/* fractalsqld.c:650 */
    uint8_t *msg = malloc(FSQ_HEADER_LEN + plen);
```

The cap is the protocol's, and it is generous:

```c
/* fsq_protocol.h:21 */
#define FSQ_MAX_PAYLOAD      ((uint32_t) 80u * 1024u * 1024u)
```

**Reachability.** Reachable from untrusted input: the Unix socket (B1). The payload length is checked against `FSQ_MAX_PAYLOAD` at `fractalsqld.c:1565`, but that check happens *before* authentication, and the connection cap is 64 (`fractalsqld.c:59`, enforced at `:1748-1762`).

**Failure scenario.** An allow-listed peer opens 64 connections and sends a 80 MiB payload on each. The daemon holds 64 × 80 MiB = 5.1 GiB in `payload`, and while the HMAC is being computed it briefly holds a second copy of each (`msg`), so the peak is 10.2 GiB. On a node with less memory, the daemon's allocations start failing — which is also the precondition for finding 3.1.

**Suggested fix.** Authenticate the header and a hash of the payload before materialising the payload, or at minimum stream the HMAC over the socket rather than buffering it twice:

```diff
-        if (h.payload_len) {
-            payload = malloc(h.payload_len);
-            if (!payload || read_all(fd, payload, h.payload_len) != 0) { free(payload); break; }
-        }
-        mac(cfg, hdr, payload, h.payload_len, want);
+        /* Stream the payload through the HMAC as it arrives, so an
+           unauthenticated peer never makes the daemon hold the whole
+           payload in memory. */
+        ...
```

and reduce `FSQ_MAX_PAYLOAD` to the largest payload the shim actually sends.

**Confidence.** **Confirmed.** The allocation order is verbatim in the quoted lines: `payload` is allocated and filled before `mac()` is called, and `mac()` allocates `FSQ_HEADER_LEN + plen` more.

---

### 3.10 `Db::acquire` holds the global connection-registry mutex across a blocking Druid connect

* **File:line:** `mcp/src/db.h:1022-1037`; the blocking connect at `mcp/src/db.h:492-503`
* **Language:** C++ (header-only)
* **Severity:** Medium · **CWE-667** (Improper Locking)

**Defect.** The registry mutex is held while a new Druid connection is established, so one slow Druid connect stalls every other MCP request that needs the registry.

**Code.**

```cpp
/* db.h:1022 */
        std::shared_ptr<DbConnection> acquire( const std::string& key )
        {
            std::lock_guard<std::mutex> lk( regMu_ );
            auto it = connections_.find( key );
            if( it == connections_.end() )
            {
                auto c = std::make_shared<DbConnection>();
                c->setSession( key );
                c->connect( cfg_, kEngineVersionExpect );   /* <-- network I/O under the lock */
                connections_[ key ] = c;
                for( const std::string& w : c->startupWarnings() )
                    logging::event( "session_startup_warning", Json{ { "session", key }, { "note", w } } );
                return c;
            }
            return it->second;
        }
```

**Reachability.** Reachable from untrusted input: the MCP transport (B7). Each MCP request runs on its own thread (`mcp/src/transport_http.cpp`), and each request that touches Druid calls `acquire`.

**Failure scenario.** A client's first request mints a new context (`"ctx:" + id`, finding 3.7), which needs a new Druid connection. `connect()` performs a `SELECT 1` and a version check against Druid with a socket timeout. While that connect is in flight, `regMu_` is held, so *every* other MCP request — including ones for existing, healthy connections — blocks in `acquire` until the connect completes or times out. A handful of concurrent context-minting requests against an unreachable Druid serialise the whole server's Druid access behind them.

**Suggested fix.** Establish the connection outside the lock, then publish it under the lock with a double-check:

```diff
         std::shared_ptr<DbConnection> acquire( const std::string& key )
         {
-            std::lock_guard<std::mutex> lk( regMu_ );
-            auto it = connections_.find( key );
-            if( it == connections_.end() )
+            {
+                std::lock_guard<std::mutex> lk( regMu_ );
+                auto it = connections_.find( key );
+                if( it != connections_.end() ) return it->second;
+            }
+            /* Connect outside the lock: the connect is blocking network
+               I/O and must not stall every other session. */
+            auto c = std::make_shared<DbConnection>();
+            c->setSession( key );
+            c->connect( cfg_, kEngineVersionExpect );
             {
+                std::lock_guard<std::mutex> lk( regMu_ );
+                auto it = connections_.find( key );
+                if( it != connections_.end() ) return it->second;   /* someone else won */
                 auto c = std::make_shared<DbConnection>();
                 c->setSession( key );
                 c->connect( cfg_, kEngineVersionExpect );
                 connections_[ key ] = c;
                 for( const std::string& w : c->startupWarnings() )
                     logging::event( "session_startup_warning", Json{ { "session", key }, { "note", w } } );
                 return c;
             }
-            return it->second;
         }
```

**Confidence.** **Confirmed** for the locking structure (quoted above) and for the fact that `connect()` performs network I/O (`mcp/src/db.h:492-503` issues `SELECT 1` and a version check). **Plausible** for the severity of the stall, which depends on the Druid client's connect timeout and on how many contexts a deployment mints.

---

### 3.11 The daemon's idempotency cache is not scoped to the connection that created it

* **File:line:** `service/daemon/fractalsqld.c:1175` (lookup) and `service/daemon/fractalsqld.c:1008-1021` (entry layout)
* **Language:** C
* **Severity:** Medium · **CWE-294** (Authentication Bypass by Capture-replay)

**Defect.** The cache that makes a retried call idempotent stores no owner, and the replay check runs before the handle-ownership check, so a token minted by one connection can be replayed on another connection and receive that other connection's cached answer.

**Code.**

```c
/* fractalsqld.c:1175 */
    if (token != 0 && cache_replay(token, rep, name, namelen)) return;

    FSQ_LOCK(g_handles_mu);
    h = handle_find_locked(id);
    FSQ_UNLOCK(g_handles_mu);
```

```c
/* fractalsqld.c:1008 */
struct fsq_cache_entry {
    uint64_t token;
    uint32_t status;
    int32_t  core_rc;
    uint32_t body_len;
    uint8_t *body;      /* NULL when the slot is empty */
    uint8_t  name_len;
    char     name[64];
};
```

Contrast with the handle table, which *does* record an owner and enforces it:

```c
/* fractalsqld.c:805 */
/* Handles are sequential, so IDs are guessable. A connection may only reach
 * handles it created: a foreign ID is "not found", never a use-after-free
 * of another connection's statement. */
static struct fsq_handle *handle_find_locked(uint64_t id) {
    for (struct fsq_handle *h = g_handles; h; h = h->next)
        if (h->id == id && h->owner == t_conn) return h;
    return NULL;
}
```

**Reachability.** Reachable from untrusted input: the Unix socket (B1), by any peer in the uid allow-list. The token is a 64-bit value carried in the frame's `context` field; the daemon does not authenticate the *origin* of a token beyond the HMAC on the frame.

**Failure scenario.** Connection A issues a stateful call with token `T` and gets an answer. Connection B — a different, allow-listed peer — sends a frame with `context = T` and the same function name. `cache_replay` matches the token and the name and returns A's cached result to B, bypassing the handle-ownership check that would otherwise refuse it. The result is a cross-principal information disclosure: one peer's computed result is delivered to another.

**Suggested fix.** Record the owning connection in the cache entry and check it on replay, exactly as `handle_find_locked` does:

```diff
 struct fsq_cache_entry {
     uint64_t token;
+    uint64_t owner;      /* the connection that minted the token */
     uint32_t status;
     ...
 };
```

```diff
-    if (token != 0 && cache_replay(token, rep, name, namelen)) return;
+    if (token != 0 && cache_replay(token, rep, name, namelen, t_conn)) return;
```

with `cache_replay` refusing an entry whose `owner != t_conn`.

**Confidence.** **Confirmed** for the missing ownership field and for the ordering (the cache lookup precedes the ownership-checked handle lookup). **Plausible** for the disclosure, because it additionally requires that the attacker can guess or learn a 64-bit token — the tokens are CSPRNG-minted per the comment at `fractalsqld.c:1173-1174`, so the practical bar is a token leak rather than brute force. The assumption a reviewer must confirm is where the token comes from: if the shim only ever replays its own tokens on its own connection, the exposure is limited to a compromised or buggy shim.

---

### 3.12 The ledger's destructive operations have no authorisation of their own

* **File:line:** `druid-extension/src/main/java/com/fractalsqlabs/fractalsql/druid/FractalExpr.java:282-285`; posture flag `druid-extension/src/main/java/com/fractalsqlabs/fractalsql/druid/FractalSqlConfig.java:154-157`; enforcement `druid-extension/src/main/java/com/fractalsqlabs/fractalsql/druid/FractalSqlEnterprise.java:131-138`
* **Language:** Java
* **Severity:** Medium · **CWE-862** (Missing Authorization)

**Defect.** `FRACTAL_LEDGER_RESET_HARD` and friends are exposed as ordinary SQL functions whose only gate is a configuration flag that defaults to off, so a user with permission to run any query can destroy the node's audit ledger unless an operator has explicitly latched it.

**Code.**

```java
/* FractalExpr.java:275 */
            switch (id) {
                ...
                case 63:
                    return enterprise.resetSoft();
                case 64:
                    return enterprise.resetHard();
```

```java
/* FractalSqlConfig.java:154 */
        key("ledger.read_only", Kind.BOOL, false, "false",
                "a deliberate posture flag: it latches the ledger's destructive operations");
```

```java
/* FractalSqlEnterprise.java:131 */
    private void refuseIfDestructiveLocked()
    {
        applyPosture();
        if (destructiveLocked) {
            throw new IllegalStateException(
                    "fractalsql: the ledger's destructive operations are locked on this node");
        }
    }
```

`flush()`, `compact()`, `resetSoft()` and `resetHard()` all call `refuseIfDestructiveLocked()` — a *posture* check, not an *identity* check. Nothing in the chain asks who the caller is.

**Reachability.** Reachable from untrusted input: any Druid query (B4). The functions are registered as expression macros, so any user who can submit a query can call them.

**Failure scenario.** `SELECT FRACTAL_LEDGER_RESET_HARD()`. `destructiveLocked` is false (the default), so the call proceeds: the truth ledger is dropped and the epoch is restarted. The audit chain — the record the enterprise edition exists to keep — is destroyed by a user whose Druid permissions were only meant to allow reading. The same applies to `FRACTAL_LEDGER_COMPACT()` and `FRACTAL_LEDGER_FLUSH()`.

**Suggested fix.** Gate the destructive functions on an explicit Druid authorisation check, and make the safe default the locked one. Concretely: (a) change the default of `ledger.read_only` to `"true"` so a node that has not been explicitly configured is already latched; (b) in `FractalExpr`, refuse the destructive ids unless the current Druid request context carries the corresponding system permission (Druid's `AuthorizationUtils`/`Resource` model), rather than relying on a node-wide configuration flag alone.

**Confidence.** **Confirmed** for the code path and the default value (both quoted). **Plausible** for the impact, which depends on the deployment's Druid authorisation configuration — the audit report should note that Druid's own authoriser is the intended outer control, and this finding is about the extension not adding a defence in depth of its own.

---

### 3.13 The state-fingerprint path allocates attacker-chosen sizes before the core validates them

* **File:line:** `druid-extension/src/main/native/fractalsql_jni.c:718-741`; `druid-extension/src/main/java/com/fractalsqlabs/fractalsql/druid/FractalExpr.java:895-902`
* **Language:** C (JNI) + Java
* **Severity:** Medium · **CWE-789** (Memory Allocation with Excessive Size Value)

**Defect.** `n_bits` comes straight from a SQL scalar and is used to size a `calloc` *before* the core is asked whether the width is allowed.

**Code.**

```c
/* fractalsql_jni.c:718 */
        case 10: { /* fractal_state_fingerprint(vec, n_bits) -> the fingerprint */
            /* The core returns the fingerprint bytes: out[0] is the byte count and
             * out[1..] are the bytes. The Java side carries them as hex. */
            size_t n_bits = (size_t)p1;
            if (n_bits == 0) {
                n_bits = 64;
            }
            size_t n_bytes = (n_bits + 7) / 8;
            uint8_t *fp = (uint8_t *)calloc(n_bytes, 1);
            if (fp) {
                rc = fsql_state_fingerprint(a, (size_t)aLen, n_bits, p2, fp);
```

The core caps the *work* (`FSQL_LIMIT_FINGERPRINT_WORK`, default 2^28, per `include/fractalsql_sql.h:640-654`), but the shim's `calloc` happens first and is sized purely from the attacker's number.

```java
/* FractalExpr.java:895 */
            case 10: { // state_fingerprint -> the fingerprint, as hex
                final int nBytes = (int) result;
                final StringBuilder hex = new StringBuilder(nBytes * 2);
```

**Reachability.** Reachable from untrusted input: a Druid SQL expression (B4) → `FractalExpr.evaluate` → `Native.callFn(10, …)`.

**Failure scenario.** `SELECT FRACTAL_STATE_FINGERPRINT(ARRAY[1.0], 1073741824)` (2^30 bits). `n_bytes` = 128 MiB and `calloc(128 MiB, 1)` succeeds; the core then rejects the width and the result is discarded, but the 128 MiB was already allocated and, under repeated calls, the historical's heap is exhausted and the query fails with OOM. `n_bits` around 2^34 makes `calloc` fail, which is handled (`if (fp)`), so the exploitable band is "large enough to succeed, small enough to be wasteful".

**Suggested fix.** Clamp the requested width to the core's documented limit *before* allocating:

```diff
             size_t n_bits = (size_t)p1;
             if (n_bits == 0) {
                 n_bits = 64;
             }
+            if (n_bits > FSQL_LIMIT_FINGERPRINT_WORK) {
+                break;   /* refuse before allocating */
+            }
             size_t n_bytes = (n_bits + 7) / 8;
```

**Confidence.** **Confirmed** for the ordering (the `calloc` precedes the core call, and `n_bits` is caller-supplied). **Plausible** for the impact, since it depends on how much memory the Druid historical's JVM heap has and on how the deployment bounds concurrent queries.

---

### 3.14 The unauthenticated `/readyz` endpoint runs a live Druid query on every request

* **File:line:** `mcp/src/transport_http.cpp:593-606`
* **Language:** C++
* **Severity:** Medium · **CWE-770** (Allocation of Resources Without Limits or Throttling)

**Defect.** `/readyz` is served without authentication and its readiness probe is a live query against Druid, so an unauthenticated caller can drive Druid load at will.

**Code.**

```cpp
/* transport_http.cpp:593 */
    // GET /healthz and /readyz are the ONLY two routes served without
    // authentication (10.3). Returns true iff the request was fully
    // handled (i.e. the caller must not do anything else with it).
    static bool handleUnauthenticatedGet( const ConnIo& io, const std::string& method, const std::string& path,
                                          const std::function<bool()>& readinessProbe )
    {
        if( method != "GET" ) return false;
        if( path == "/healthz" ) { sendHttpJson( io, 200, Json{ { "ok", true } } ); return true; }
        if( path == "/readyz" )
        {
            const bool ready = readinessProbe ? readinessProbe() : false;
            sendHttpJson( io, ready ? 200 : 503,
                          Json{ { "ok", ready }, { "probe", "engine version query" } } );
            return true;
        }
        return false;
    }
```

**Reachability.** Reachable from untrusted input: the MCP HTTP transport (B7). The handler is reached before the bearer-token check — that is the point of it.

**Failure scenario.** An unauthenticated attacker loops `GET /readyz`. Each request opens or reuses a Druid connection and issues a version query. Against a Druid broker that is already loaded, this turns a health check into a load amplifier, and it is invisible in the server's own access accounting because the requests never reach the authenticated dispatch path.

**Suggested fix.** Cache the probe result for a short interval, and rate-limit the unauthenticated path:

```cpp
        if( path == "/readyz" )
        {
            /* The probe is a live Druid query; do not run one per request. */
            static std::atomic<long long> lastProbe{0};
            static std::atomic<int> lastResult{0};
            const long long now = std::chrono::duration_cast<std::chrono::seconds>(
                    std::chrono::steady_clock::now().time_since_epoch()).count();
            int ready = lastResult.load();
            if( now - lastProbe.load() >= 5 ) {
                ready = readinessProbe ? readinessProbe() : false;
                lastResult.store( ready );
                lastProbe.store( now );
            }
            ...
        }
```

**Confidence.** **Confirmed** for the code path. **Plausible** for the severity, which depends on how expensive the probe query is on the target Druid.

---

### 3.15 `cov_n != n_assets * n_assets` can overflow on a 32-bit `size_t`

* **File:line:** `service/adapter/src/fractalsql.c:1563`; `service/adapter/src/fractalsql_enterprise.c:3557`, `:3759`, `:4016`; the byte counts at `service/adapter/src/fractalsql.c:1423` and `service/adapter/src/fractalsql_enterprise.c:3418-3423`, `:3861-3862`
* **Language:** C
* **Severity:** Low · **CWE-190** (Integer Overflow or Wraparound)

**Defect.** The asset count is derived from a CSV and squared in `size_t` arithmetic with no overflow check, and the same unchecked product is then used as a `malloc` size and a `memcpy` length.

**Code.**

```c
/* fractalsql.c:1563 */
    if (cov_n != n_assets * n_assets) {
        free(mu); free(cov); *error = 1; return NULL;
    }
```

```c
/* fractalsql.c:1423 */
        size_t   mu_bytes  = n_assets * sizeof(double);
        size_t   cov_bytes = n_assets * n_assets * sizeof(double);
        uint8_t *buf = (uint8_t *) malloc(mu_bytes + cov_bytes);
        if (buf == NULL) return;
        memcpy(buf, mu, mu_bytes);
        memcpy(buf + mu_bytes, cov, cov_bytes);
```

The file already contains the correct sibling — a doubling loop that checks for overflow before growing:

```c
/* fractalsql.c:194 */
```

and `fractalsql_parse.c` already has a helper for exactly this:

```c
/* fractalsql_parse.c:49 */
static bool mul_ok(size_t a, size_t b, size_t c) { ... }
```

which is not used at the covariance check.

**Reachability.** Reachable from untrusted input: the adapter's UDF entry points, whose arguments come from a Druid SQL query (B4). The guard on `args->lengths[]` at `fractalsql.c:1551` bounds the *CSV length* in bytes, not the element count, so `n_assets` can be large relative to the bytes.

**Failure scenario.** On a 32-bit build (`size_t` = 32 bits), a CSV with 65,536 assets makes `n_assets * n_assets` = 2^32 = 0, so `cov_n != 0` is true for any non-empty `cov` and the check fires — but a CSV with exactly 65,536 assets and a matching 2^32-entry covariance is impossible to hold in memory, so the practical outcome is a rejection rather than a bypass. The dangerous shape is `n_assets = 46,341` (46,341² = 2,147,488,281 < 2^32) — no wrap — versus `n_assets = 46,342` (squares to 2,147,533,964, still < 2^32) — so a genuine wrap needs `n_assets ≥ 65,536`, at which point the covariance CSV alone is 34 GiB and the length guard at `:1551` rejects it first. On 64-bit builds the wrap needs `n_assets ≥ 2^32`, unreachable. The residual risk is therefore **latent**, not currently exploitable — the check is one platform/limit change away from being.

**Suggested fix.** Use the existing helper:

```diff
-    if (cov_n != n_assets * n_assets) {
+    size_t cov_cells = 0;
+    if (!mul_ok(n_assets, n_assets, 1, &cov_cells) || cov_n != cov_cells) {
         free(mu); free(cov); *error = 1; return NULL;
     }
```

and apply the same to `cov_bytes` in the three `fractalsql_enterprise.c` sites and the `fractalsql.c:1423` site, guarding `mu_bytes + cov_bytes` against addition overflow as well.

**Confidence.** **Confirmed** for the missing overflow check and for the existence of the unused `mul_ok` helper. **Plausible** for exploitability, and the reasoning above argues it is *not* currently exploitable — the length guard on the CSV bounds the asset count below the wrap threshold. It is reported because the guard is a coincidence of two unrelated limits, not a deliberate check.

---

### 3.16 `str_out_ensure` doubles the capacity without checking for wraparound

* **File:line:** `service/adapter/src/fractalsql_textsql.c:179`; identical copy at `service/adapter/src/fractalsql_cognition.c:193`
* **Language:** C
* **Severity:** Low · **CWE-190** (Integer Overflow or Wraparound)

**Defect.** The growth loop multiplies the capacity by two with no overflow check, so a `need` near `SIZE_MAX` makes `ncap` wrap to zero and the loop never terminates.

**Code.**

```c
/* fractalsql_textsql.c:172 */
static bool
str_out_ensure(str_out_ctx *so, size_t need)
{
    size_t ncap;
    char  *nb;
    if (need <= so->cap) return true;
    ncap = so->cap ? so->cap : 256;
    while (ncap < need) ncap *= 2;      /* <-- no overflow check */
    nb = realloc(so->buf, ncap);
    if (nb == NULL) return false;
    so->buf = nb; so->cap = ncap;
    return true;
}
```

**Reachability.** Reachable from untrusted input: the adapter's UDF output paths (B4), whose `need` is computed from input lengths. On 64-bit builds `need` would have to exceed `SIZE_MAX/2`, which the input length caps make unreachable; on a 32-bit build `need > 2^31` is plausible for a text-generation UDF fed a large corpus.

**Failure scenario.** On a 32-bit build, a text-SQL request whose output needs more than 2 GiB makes `ncap` double to 0; `ncap < need` stays true forever and the call spins at 100% CPU inside a Druid query thread, holding the output buffer. The thread never returns; the historical's query queue backs up.

**Suggested fix.**

```diff
     ncap = so->cap ? so->cap : 256;
-    while (ncap < need) ncap *= 2;
+    while (ncap < need) {
+        if (ncap > SIZE_MAX / 2) { ncap = need; break; }
+        ncap *= 2;
+    }
```

**Confidence.** **Confirmed** for the missing check. **Plausible** for reachability on 32-bit builds (the 64-bit build is unaffected because the input caps keep `need` far below `SIZE_MAX/2`).

---

### 3.17 The MCP origin check accepts any host with a `127.` prefix

* **File:line:** `mcp/src/transport_http.cpp:662-663`
* **Language:** C++
* **Severity:** Low · **CWE-346** (Origin Validation Error)

**Defect.** The loopback-origin test is a string prefix match, so hostnames that merely begin with `127.` are treated as loopback.

**Code.**

```cpp
/* transport_http.cpp:659 */
        const std::size_t colon = host.rfind( ':' );
        if( colon != std::string::npos ) host = host.substr( 0, colon );
        if( host == "localhost" ) return true;
        if( host.rfind( "127.", 0 ) == 0 ) return true;   /* <-- prefix, not a parse */
        return false;
```

**Reachability.** Reachable from untrusted input: the MCP HTTP transport (B7). The `Origin` header is attacker-controlled.

**Failure scenario.** A page served from `http://127.evil.example` sends a request with `Origin: http://127.evil.example`; the prefix test accepts it as a loopback origin, so the browser-based cross-origin check that this function exists to enforce is bypassed for any host whose name starts with `127.`. (Whether a real attacker can obtain such a hostname and serve a page from it is a separate question — the point is that the check does not do what it says.)

**Suggested fix.** Parse the host as an IPv4 address rather than matching a prefix:

```diff
-        if( host.rfind( "127.", 0 ) == 0 ) return true;
+        {
+            /* 127.0.0.0/8 is loopback. Parse it, do not prefix-match it. */
+            in_addr addr{};
+            if( inet_pton( AF_INET, host.c_str(), &addr ) == 1 )
+                return ( ntohl( addr.s_addr ) >> 24 ) == 127;
+        }
         return false;
```

**Confidence.** **Confirmed** for the code. **Plausible** for exploitability, which depends on an attacker being able to serve a page from a host whose name begins with `127.` and get the browser to send that `Origin`.

---

### 3.18 The MCP header parser records repeated headers but never acts on them

* **File:line:** `mcp/src/transport_http.cpp:435` (declaration), `:503` (recording), `:1597` (the framing refusal)
* **Language:** C++
* **Severity:** Low · **CWE-444** (HTTP Request/Response Smuggling)

**Defect.** The parser accumulates the names of headers that arrived more than once, and the struct's own comment says the framing check will refuse them — but the set is never read, so only a repeated `Content-Length` is refused.

**Code.**

```cpp
/* transport_http.cpp:429 */
    struct HttpRequest
    {
        std::string method, target, version;
        std::map<std::string, std::string> headers;   // lower-cased keys
        // Header names that arrived more than once. The map above keeps the
        // last value, but a header sent twice is ambiguous framing, so the
        // names are remembered and the framing check refuses them.
        std::set<std::string> repeated;
        std::string body;
    };
```

```cpp
/* transport_http.cpp:498 */
            // A repeated Content-Length is ambiguous framing, not "the last one wins".
            if( key == "content-length" && out.headers.count( key ) ) return ReadStatus::BadFraming;
            // Same idea for every other header name: remember that it arrived
            // twice, so a request whose framing is ambiguous can be refused
            // rather than served with one of the two values.
            if( out.headers.count( key ) ) out.repeated.insert( key );
```

The refusal that actually exists:

```cpp
/* transport_http.cpp:1594 */
                        case ReadStatus::BadFraming:
                            refusedUnread = true;
                            sendHttpJson( io, 400, Json{ { "error",
                                "ambiguous request framing (repeated or malformed Content-Length)" } } );
                            break;
```

`out.repeated` is written at `:503` and read nowhere in the file.

**Reachability.** Reachable from untrusted input: the MCP HTTP transport (B7).

**Failure scenario.** A request with two `Host:` headers, or two `Content-Type:` headers, or a duplicated `Transfer-Encoding`, is accepted with the last value winning. The recorded set shows the parser's author intended to refuse these. For a server that is not behind another HTTP hop this is a robustness gap rather than a smuggling primitive — the MCP server is the endpoint, not a proxy — but the comment currently overstates what the code does.

**Suggested fix.** Enforce the set that is already being built:

```diff
                         case ReadStatus::BadFraming:
                             refusedUnread = true;
                             sendHttpJson( io, 400, Json{ { "error",
                                 "ambiguous request framing (repeated or malformed Content-Length)" } } );
                             break;
```

and, after the header loop completes, add:

```cpp
            if( !out.repeated.empty() )
            {
                /* A header that arrived twice is ambiguous framing. */
                out.repeated.clear();
                return ReadStatus::BadFraming;
            }
```

**Confidence.** **Confirmed.** `repeated` is written at `:503` and a repository-wide search of `mcp/src` finds no other read of it (the only other mention is the error string at `:1597`, which does not consult the set).

---

### 3.19 `vecform::pack` truncates the vector dimension to 16 bits

* **File:line:** `mcp/src/db.h:350-357`
* **Language:** C++
* **Severity:** Low · **CWE-681** (Incorrect Conversion between Numeric Types)

**Defect.** The packed form's dimension field is 16 bits wide but the vector's length is not checked against it, so a vector of more than 65,535 dimensions is silently truncated.

**Code.**

```cpp
/* db.h:350 */
        inline std::vector<std::uint8_t> pack( const std::vector<float>& v )
        {
            std::vector<std::uint8_t> b( 4 + 4 * v.size() );
            b[ 0 ] = static_cast<std::uint8_t>( v.size() & 0xff );
            b[ 1 ] = static_cast<std::uint8_t>( ( v.size() >> 8 ) & 0xff );
            std::memcpy( b.data() + 4, v.data(), 4 * v.size() );
            return b;
        }
```

The unpacker reads the dimension back out of those two bytes and then checks the buffer length against it:

```cpp
/* db.h:359 */
        inline std::optional<std::string> unpackToText( const std::vector<std::uint8_t>& b )
        {
            if( b.size() < 4 ) return std::nullopt;
            const std::size_t dim = static_cast<std::size_t>( b[ 0 ] ) | ( static_cast<std::size_t>( b[ 1 ] ) << 8 );
            if( b.size() != 4 + 4 * dim ) return std::nullopt;
```

**Reachability.** Reachable from untrusted input: the MCP transport (B7) → the vector-text path. The dimension comes from a client-supplied embedding vector.

**Failure scenario.** A client sends a 70,000-dimensional vector. `pack` writes `0x70,0x11` (70,000 & 0xFFFF = 4,464) into the header and 280,000 bytes of floats. `unpackToText` then computes `dim = 4464` and checks `b.size() != 4 + 4*4464` — 280,000 ≠ 17,860 — so it returns `std::nullopt` and the vector is silently dropped. The failure is a rejected request rather than a memory error, because the length check saves it, but the error message will not make the truncation obvious to the caller.

**Suggested fix.** Refuse to pack a vector that does not fit, rather than truncating:

```diff
         inline std::vector<std::uint8_t> pack( const std::vector<float>& v )
         {
+            if( v.size() > 0xffff ) return {};   /* the dimension field is 16 bits */
             std::vector<std::uint8_t> b( 4 + 4 * v.size() );
```

**Confidence.** **Confirmed** for the truncation and for the length check that prevents it becoming a memory-safety bug.

---

### 3.20 `numberOf` returns NaN and the result is cast to `std::int64_t`

* **File:line:** `mcp/src/db.h:738-743` (producer) and `mcp/src/db.h:776`, `:781`, `:786` (consumers)
* **Language:** C++
* **Severity:** Low · **CWE-681** (Incorrect Conversion between Numeric Types)

**Defect.** A value that is not an integer and not a double yields NaN, and the NaN is then converted to `std::int64_t`, which is undefined behaviour for a value that cannot be represented.

**Code.**

```cpp
/* db.h:738 */
        static double numberOf( const SqlValue& v )
        {
            if( std::holds_alternative<std::int64_t>( v ) ) return static_cast<double>( std::get<std::int64_t>( v ) );
            if( std::holds_alternative<double>( v ) ) return std::get<double>( v );
            return std::nan( "" );
        }
```

```cpp
/* db.h:773 */
            else if( fn == "fractal_periodogram" && b.size() == 2 )
            {
                a.binds.assign( b.begin(), b.begin() + 1 );
                a.trimKey = "freqs"; a.trimTo = static_cast<std::int64_t>( numberOf( b[ 1 ] ) );
            }
```

**Reachability.** Reachable from untrusted input: the MCP transport (B7). The bound values come from the JSON-RPC request.

**Failure scenario.** A tool call binds a string (rather than a number) to the `fractal_periodogram` limit parameter. `numberOf` returns NaN; `static_cast<std::int64_t>(NaN)` is undefined behaviour in C++ (in practice on x86-64 it yields `INT64_MIN`, but the standard permits anything, and UBSan flags it). The resulting `trimTo` is a huge negative number, which is then used as a result-row limit.

**Suggested fix.** Make the conversion explicit and checked:

```diff
         static double numberOf( const SqlValue& v ) { ... }
+
+        static std::int64_t intOf( const SqlValue& v, const char* what )
+        {
+            const double n = numberOf( v );
+            if( std::isnan( n ) || !std::isfinite( n ) )
+                throw ToolError( ErrorClass::Schema, std::string( what ) + " must be a number" );
+            return static_cast<std::int64_t>( n );
+        }
```

and use `intOf( b[ 1 ], "freqs" )` at the three sites.

**Confidence.** **Confirmed** for the NaN path and the cast.

---

### 3.21 The MCP Druid client buffers an unbounded response body

* **File:line:** `mcp/src/db.h:211-233`
* **Language:** C++
* **Severity:** Low · **CWE-770** (Allocation of Resources Without Limits or Throttling)

**Defect.** `readAll()` appends to a `std::string` until the peer closes the connection, with no upper bound.

**Code.**

```cpp
/* db.h:211 */
            // Reads until EOF (the request carries Connection: close).
            std::string readAll()
            {
                std::string out;
                char buf[65536];
                for( ;; )
                {
                    const int n = ssl_ ? SSL_read( ssl_, buf, sizeof buf )
                                       : static_cast<int>( ::recv( fd_, buf, sizeof buf, 0 ) );
                    if( n > 0 ) { out.append( buf, static_cast<std::size_t>( n ) ); continue; }
                    if( n == 0 ) break;
                    ...
                }
                return out;
            }
```

**Reachability.** Reachable from untrusted input: the MCP transport (B7) → the Druid client. The peer is the Druid node, so this is a trust-the-immediate-peer issue rather than an internet-facing one — unless the `coordinator_url` / Druid endpoint can be pointed at an untrusted host by configuration or by a request.

**Failure scenario.** The configured Druid endpoint (or a host that answers on that address) returns a response that never ends. The MCP process grows its heap until it is OOM-killed. If an attacker can influence the configured endpoint — the configuration keys are settable, and `coordinator_url` is one of them — this becomes a remote memory-exhaustion primitive.

**Suggested fix.** Cap the body:

```diff
                 std::string out;
                 char buf[65536];
                 for( ;; )
                 {
                     const int n = ...;
-                    if( n > 0 ) { out.append( buf, static_cast<std::size_t>( n ) ); continue; }
+                    if( n > 0 )
+                    {
+                        if( out.size() + static_cast<std::size_t>( n ) > kMaxDruidResponseBytes )
+                            throw ToolError( ErrorClass::Connectivity, "the Druid response was too large" );
+                        out.append( buf, static_cast<std::size_t>( n ) );
+                        continue;
+                    }
```

**Confidence.** **Confirmed** for the missing bound. **Plausible** for exploitability, which depends on whether the Druid endpoint is attacker-influenceable in the deployment.

---

### 3.22 The daemon accepts an HMAC key of any length, including one byte

* **File:line:** `service/daemon/fractalsqld.c:159`; the same check in the CLI at `service/cli/fsqlctl.c:144`
* **Language:** C
* **Severity:** Low · **CWE-326** (Inadequate Encryption Strength)

**Defect.** The key file is validated for shape (even number of hex digits, fits in the buffer) but not for strength, so a 1-byte key is accepted and the whole protocol's authentication rests on it.

**Code.**

```c
/* fractalsqld.c:159 */
    if (n == 0 || n % 2 != 0 || n / 2 > sizeof(cfg->key)) return -1;
```

```c
/* fsqlctl.c:144 */
    if (n == 0 || n % 2 != 0 || n / 2 > FSQC_MAX_KEY) return -1;
```

**Reachability.** Not reachable from untrusted input at runtime — the key file is written by an operator. It is reachable at *deployment* time by a misconfiguration (or by an attacker who can write the key file, at which point they have already won).

**Failure scenario.** An operator generates a key with `head -c 1 /dev/urandom | xxd -p` and writes it to `hmac.key`. The daemon starts, logs no warning, and authenticates every frame with a 1-byte HMAC key. The key space is 256 values; an allow-listed peer can recover it by sending 256 candidate frames and observing which one is accepted, and from then on forge frames.

**Suggested fix.** Require a minimum key length and log the requirement at startup:

```diff
-    if (n == 0 || n % 2 != 0 || n / 2 > sizeof(cfg->key)) return -1;
+    if (n == 0 || n % 2 != 0 || n / 2 > sizeof(cfg->key)) return -1;
+    if (n / 2 < 32) {
+        fsq_log("ERROR", "hmac_key_file holds only %zu bytes; at least 32 are required", n / 2);
+        return -1;
+    }
```

**Confidence.** **Confirmed** for the missing check and the consequence.

---

### 3.23 The daemon session id is derived from `String.hashCode()`

* **File:line:** `druid-extension/src/main/java/com/fractalsqlabs/fractalsql/druid/FractalSqlDaemon.java:52-58`
* **Language:** Java
* **Severity:** Low · **CWE-330** (Use of Insufficiently Random Values)

**Defect.** A session name is mapped to its numeric id with `String.hashCode()`, which is not a keyed hash and collides freely.

**Code.**

```java
/* FractalSqlDaemon.java:52 */
    public static long sessionId(String name)
    {
        if (name == null || name.isEmpty()) {
            return NODE_SESSION;
        }
        return 2L + (name.hashCode() & 0x7fffffffL);
    }
```

**Reachability.** Reachable from untrusted input: the session name comes from the extension's configuration and from SQL-visible session functions, and the id is the `context` field of a daemon frame.

**Failure scenario.** Two different session names that collide on `hashCode()` — trivially found, since `String.hashCode()` is a well-known 32-bit function — map to the same daemon-side session. The two sessions share state in the core: the diversify monitor's state, the session's ledger, its vector store. One session observes or corrupts the other's state. The `& 0x7fffffffL` also maps `hashCode() == 0x80000000` to `0`, and `2L + 0` is not the node's session, so the comment's "never 0 or 1" claim holds only by the `+2` offset, not by the mask.

**Suggested fix.** Use a keyed hash, or a random per-name id from a persistent map:

```diff
-        return 2L + (name.hashCode() & 0x7fffffffL);
+        /* A stable, collision-free id per session name. */
+        return 2L + (long) SESSION_IDS.computeIfAbsent( name, k -> nextSessionId() );
```

where `SESSION_IDS` is a `ConcurrentHashMap<String, Long>` and `nextSessionId()` draws from a `SecureRandom`.

**Confidence.** **Confirmed** for the code and for `String.hashCode()`'s collision behaviour. **Plausible** for the impact, which depends on whether two colliding session names coexist in one deployment.

---

### 3.24 `daemon_hmac_key_file` is not treated as a secret by the config redactor

* **File:line:** `druid-extension/src/main/java/com/fractalsqlabs/fractalsql/druid/FractalSqlConfig.java:332-341`
* **Language:** Java
* **Severity:** Low · **CWE-522** (Insufficiently Protected Credentials)

**Defect.** The redaction predicate recognises `.token` and `_key` suffixes but not `_key_file`, so the *path* of the daemon's HMAC key file is echoed in full wherever configuration is reported.

**Code.**

```java
/* FractalSqlConfig.java:331 */
    /** Whether a key holds a credential. */
    public static boolean isSecret(String name)
    {
        if (name == null) {
            return false;
        }
        // Both separators: the older keys were dotted (reasoning.token)
        // and the current ones are underscored (enterprise_ledger_key).
        return name.endsWith(".token") || name.endsWith(".key")
                || name.endsWith("_token") || name.endsWith("_key");
    }
```

The key in question:

```java
/* FractalSqlConfig.java:154 */
        key("daemon_hmac_key_file", Kind.PATH, false, "/run/fractalsql/hmac.key",
                "the key the daemon's frames are signed with");
```

**Reachability.** Reachable from untrusted input: the value flows into the extension's configuration-reporting surface (`FractalSqlConfig.java:325-329` builds the redacted map) and hence into HTTP responses.

**Failure scenario.** A caller of the configuration-reporting endpoint receives `daemon_hmac_key_file: /run/fractalsql/hmac.key` in clear text. That is a filesystem path rather than the key itself, so the disclosure is limited — but it tells the reader exactly which file holds the daemon's authentication secret, and the daemon refuses to start if that file is world-readable (`fractalsqld.c:391-394`), so it is a path worth not handing out.

**Suggested fix.**

```diff
-        return name.endsWith(".token") || name.endsWith(".key")
-                || name.endsWith("_token") || name.endsWith("_key");
+        return name.endsWith(".token") || name.endsWith(".key")
+                || name.endsWith("_token") || name.endsWith("_key")
+                || name.endsWith("_key_file") || name.endsWith(".key_file");
```

**Confidence.** **Confirmed** for the predicate and for the key's name.

---

### 3.25 The JNI library is extracted to a temp file with default permissions

* **File:line:** `druid-extension/src/main/java/com/fractalsqlabs/fractalsql/druid/NativeLoader.java:101-112`
* **Language:** Java
* **Severity:** Low · **CWE-377** (Insecure Temporary File)

**Defect.** The native library is extracted to a temporary file whose permissions are whatever `Files.createTempFile` gives (owner-only on most POSIX JDKs, but the code does not set them), and it is then overwritten in place with the JAR's payload.

**Code.**

```java
/* NativeLoader.java:101 */
            final Path tmpdir = System.getProperty("java.io.tmpdir");
            final Path tmp;
            if (tmpdir != null && !tmpdir.isEmpty()) {
                final Path dir = Paths.get(tmpdir);
                Files.createDirectories(dir);
                tmp = Files.createTempFile(dir, "fractalsql-jni-", suffixFor(key));
            } else {
                tmp = Files.createTempFile("fractalsql-jni-", suffixFor(key));
            }
            tmp.toFile().deleteOnExit();
            Files.copy(in, tmp, StandardCopyOption.REPLACE_EXISTING);
            System.load(tmp.toAbsolutePath().toString());
```

**Reachability.** Not reachable from untrusted input at runtime — the payload comes from the extension JAR. It is reachable by an unprivileged local user who shares the temp directory with the Druid process.

**Failure scenario.** The temp directory is shared (`/tmp`). `Files.createTempFile` creates the file with 0600 on POSIX, but the `Files.copy(..., REPLACE_EXISTING)` writes through to the *existing* inode, so the permissions are the ones `createTempFile` chose — which is correct on POSIX. The residual risk is the window between `createTempFile` and `System.load`: the file is written and then mapped by the dynamic loader. A local attacker who can win a race on the temp directory (a `TMPDIR` pointing at a world-writable directory that is not sticky, or a container image with a shared `/tmp`) could substitute the library between the `copy` and the `load`, achieving code execution as the Druid process.

**Suggested fix.** Create the file with explicit owner-only permissions, in a directory the process owns, and load it from there:

```diff
-            tmp.toFile().deleteOnExit();
-            Files.copy(in, tmp, StandardCopyOption.REPLACE_EXISTING);
+            try {
+                Files.setPosixFilePermissions(tmp, PosixFilePermissions.fromString("rwx------"));
+            } catch (UnsupportedOperationException ignored) { /* not POSIX */ }
+            tmp.toFile().deleteOnExit();
+            Files.copy(in, tmp, StandardCopyOption.REPLACE_EXISTING);
```

**Confidence.** **Confirmed** for the code. **Plausible** for the race being winnable — it depends on the temp directory's permissions and on the local threat model, which this audit cannot establish.

---

### 3.26 The JVM daemon binds the Unix socket before restricting its permissions

* **File:line:** `service/jvm/src/main/java/com/fractalsqlabs/fractalsql/daemon/Server.java:55-57`
* **Language:** Java
* **Severity:** Low · **CWE-732** (Incorrect Permission Assignment for Critical Resource)

**Defect.** The socket is bound and therefore reachable before its mode is narrowed to `rw-rw----`.

**Code.**

```java
/* Server.java:54 */
        listener = ServerSocketChannel.open(StandardProtocolFamily.UNIX);
        listener.bind(UnixDomainSocketAddress.of(sock), 64);
        Files.setPosixFilePermissions(sock, PosixFilePermissions.fromString("rw-rw----"));
```

**Reachability.** Not reachable from untrusted input at runtime — the window is between `bind` and `setPosixFilePermissions`, both within the same `Server` constructor, microseconds apart.

**Failure scenario.** A local user polls the socket path in that window and connects. Whether that connection is *useful* depends on the daemon's own authentication: the JVM daemon (`service/jvm/`) is the shim side of the `FSQ1` protocol, so a connected client would attempt an HMAC-authenticated frame and fail without the key. The exposure is therefore a race with a low-value payoff — but the ordering is still wrong, and the fix is free.

**Suggested fix.** Restrict the socket in the same breath as creating it, using `Files.createFile` with POSIX attributes before the bind, or by creating the socket under a directory the process owns with a restrictive mode.

**Confidence.** **Confirmed** for the ordering. **Plausible** for the impact, which is bounded by the protocol's authentication.

---

### 3.27 The `fsqld` JNI shim dereferences handle and array results without checking them

* **File:line:** `service/jvm/src/main/native/fsqld_jni.c:235-236` and `:287-291`
* **Language:** C (JNI)
* **Severity:** Low · **CWE-476** (NULL Pointer Dereference), **CWE-120** (Buffer Copy without Checking Size of Input)

**Defect.** One path reads an array of argument types without checking the array's length against the argument count, and `Native_info` dereferences the handle pointer before checking it.

**Code.**

```c
/* fsqld_jni.c:235 */
    for (jsize i = 0; i < nargs; i++) {
        jbyteArray v = (jbyteArray) (*env)->GetObjectArrayElement(env, consts, i);
        jsize len;
        enum Item_result t = h->args.arg_type[i];
```

`nargs` comes from the caller's array; the loop writes into `h->args.arg_type[i]` for `i < nargs`, but the types array is indexed separately (`t[i]` at `:230`) after `GetIntArrayElements` on a `types` array whose length is never compared with `nargs`:

```c
/* fsqld_jni.c:229 */
    for (jsize i = 0; i < nargs; i++) h->args.arg_type[i] = (enum Item_result) t[i];
```

and:

```c
/* fsqld_jni.c:287 */
JNIEXPORT jintArray JNICALL
Java_com_fractalsqlabs_fractalsql_daemon_Native_info(JNIEnv *env, jclass cls, jlong hp)
{
    fsq_handle *h = (fsq_handle *) (intptr_t) hp;
    jsize n = (jsize) h->args.arg_count;
```

`hp` is a raw pointer cast from a Java `long`; it is dereferenced on the very next line with no NULL check. (The sibling `Native_close` at `:445-455` *does* check, so the omission is local to this function.)

**Reachability.** Reachable from untrusted input: the JVM daemon's JNI surface, reached from the shim, which is reached from the daemon's own callers. The `consts` array comes from Java code that assembles the call arguments.

**Failure scenario.** A Java caller passes a `types` array shorter than `nargs`. `GetIntArrayElements` returns a pointer to the shorter array and the loop reads `t[i]` past its end — a heap over-read of the JVM's `int[]` backing store. A Java caller passing a stale or zero `hp` to `Native_info` causes a NULL dereference inside the JVM, which aborts the process rather than raising a Java exception.

**Suggested fix.** Check the lengths and the handle before use:

```diff
+    if( types && (*env)->GetArrayLength(env, types) < nargs ) { free_args(h); free(h); return 0; }
     for (jsize i = 0; i < nargs; i++) h->args.arg_type[i] = (enum Item_result) t[i];
```

```diff
 Java_com_fractalsqlabs_fractalsql_daemon_Native_info(JNIEnv *env, jclass cls, jlong hp)
 {
     fsq_handle *h = (fsq_handle *) (intptr_t) hp;
+    if( !h ) return NULL;
     jsize n = (jsize) h->args.arg_count;
```

**Confidence.** **Confirmed** for the missing checks and for the inconsistency with `Native_close`. **Plausible** for the array-length over-read being reachable, since it depends on the Java caller always passing a matching `types` array — the Java side of this shim was not fully re-read in this audit.

---

### 3.28 `GetStringUTFChars` is used for provider strings that may contain non-ASCII characters

* **File:line:** `service/jvm/src/main/native/fsqld_jni.c:483-487`
* **Language:** C (JNI)
* **Severity:** Low · **CWE-838** (Inappropriate Encoding for Output Context)

**Defect.** `GetStringUTFChars` returns *modified* UTF-8 (CESU-8), in which a supplementary character is encoded as a surrogate pair of three bytes each. A C consumer that assumes UTF-8 will mis-handle those bytes.

**Code.**

```c
/* fsqld_jni.c:483 */
    for (int i = 0; i < PROV_NSTR; i++) {
        jstring v = (jstring) (*env)->GetObjectArrayElement(env, strs, i);
        js[i] = v;
        got[i] = v ? (*env)->GetStringUTFChars(env, v, NULL) : NULL;
        s[i] = got[i] ? got[i] : "";
    }
```

**Reachability.** Reachable from untrusted input: the provider strings (`reasoning_plugin`, and the other `PROV_NSTR` slots) come from configuration and from the provider handshake.

**Failure scenario.** A reasoning-plugin URL or a provider name contains a character outside the BMP (an emoji, for example). The Java side passes it as UTF-16; `GetStringUTFChars` encodes it as CESU-8 (six bytes). The C side hands those bytes to a string consumer that expects UTF-8 — a JSON serialiser, a path check, or an `strcmp` against a known name. The result is a mangled string, and for a length-sensitive consumer (one that computes a buffer size with `strlen` and then parses multi-byte sequences) a parser disagreement.

**Suggested fix.** Use `GetStringUTFRegion` / `NewStringUTF` carefully, or convert explicitly:

```diff
-        got[i] = v ? (*env)->GetStringUTFChars(env, v, NULL) : NULL;
+        /* Convert through UTF-16 explicitly so the bytes are real UTF-8,
+           not the JNI's modified UTF-8 (CESU-8). */
+        jsize n = v ? (*env)->GetStringLength(env, v) : 0;
+        if( v )
+        {
+            const jsize ulen = (*env)->GetStringLength(env, v);
+            char* buf = malloc( (size_t) ulen * 4 + 1 );
+            ...
+        }
```

**Confidence.** **Confirmed** for the API misuse. **Plausible** for the consequence, which depends on the downstream consumer of the provider strings.

---

## 4. Recurring patterns worth fixing systemically

1. **The JNI shim trusts Java for buffer lengths.** Findings 3.2, 3.3, 3.6 and 3.13 are all the same mistake: a length that the core will rely on is derived from Java-supplied data and never cross-checked. The vendored core's header (`include/fractalsql_sql.h`) documents the expected length for every function; the shim should have a table of those expectations and check each one against the actual array length before the call. A single helper — "validate `a`/`b`/`c` against the contract for this `fnId`" — would have caught all four.

2. **Identifier escaping is applied inconsistently, and there is already a correct implementation in the tree.** Finding 3.5 exists because `FractalSqlService.corpusRows` and `FractalSqlAgents.oneCell` escape identifiers correctly, while `FractalSqlAgents.metricSeries` and `recallHybrid` do not, and `FractalSqlAgents3` has a whole `identifier()` validator. Three implementations of the same rule, one of them a no-op. This should be one shared, tested helper.

3. **Unbounded growth in a long-lived process.** Findings 3.7, 3.8, 3.13 and 3.21 are all "something grows and nothing caps it": `state.contexts`, `cancelledIds_`, the fingerprint allocation, and the Druid response buffer. The daemon's protocol has explicit caps (`FSQ_MAX_PAYLOAD`, `FSQ_MAX_CONNECTIONS`, `FSQ_CACHE_ENTRIES`); the MCP server has caps on *some* paths (`maxSessions()`, `kMaxBodyBytes`) and none on the paths just listed. Every unbounded structure wants a cap and, where the cap can be reached, an eviction or an explicit 503.

4. **Fail-open error handling on a security decision.** Finding 3.1 is the only true instance, but the pattern — "if the thing we need is unavailable, proceed with a value that has no security meaning" — is worth a project-wide convention: security-relevant allocation failures must be fatal to the request, never a default value.

5. **Duplicated code across the three tiers.** `str_out_ensure` is copy-pasted between `fractalsql_textsql.c` and `fractalsql_cognition.c` (finding 3.16 is in both). The `mac()` helper is duplicated between `fractalsqld.c` and `fsqlctl.c`, with the same weak key-length check in both (finding 3.22). The covariance size check is duplicated three times in `fractalsql_enterprise.c` (finding 3.15). Each duplicate is a place where a fix applied to one copy is not applied to the others.

6. **Configuration is the only authorisation mechanism.** Finding 3.12 (and, partly, 3.22) is the general shape: a node-wide configuration flag stands in for a per-caller decision. Where an operation is destructive, the decision should be made per request.

---

## 5. Missing hardening flags and build gaps

**Already present (verified in all three build files):** `-fstack-protector-strong`, `-fstack-clash-protection`, `-fcf-protection` (Linux x86-64), `-D_FORTIFY_SOURCE=2`, `-fPIE`/`-pie`, `-Wl,-z,relro,-z,now`, `-Wl,-z,noexecstack`. ASAN/UBSAN/TSAN and coverage variants exist for the daemon and MCP server, and `build_test.sh` gate 32 asserts the binary properties.

**Gaps:**

| Gap | Where | Note |
|---|---|---|
| `-Wconversion` is not used anywhere | `service/Makefile:48`, `mcp/Makefile:16`, `build-native-linux.sh:107` | `-Wall -Wextra` is present in the two Makefiles, but not `-Wconversion`. Findings 3.15, 3.16, 3.19 and 3.20 are all conversion or overflow issues that `-Wconversion` would have flagged (`size_t` → `uint32_t` counters, `double` → `int64_t`, `size_t` → 16-bit). Enabling it will produce a large volume of warnings on first run, so it is best introduced behind a warning-suppression list and tightened over time. |
| The adapter objects are compiled with `-w` | `service/Makefile:117` | `$(CC) -w -O2 -g -fPIC $(HARDEN_C) …` suppresses **all** warnings for the adapter translation units, including the ones at `-Wall -Wextra -Werror` for the rest of the tree (`service/Makefile:123`, `:126`, `:152`). The adapter is the largest first-party C surface (`fractalsql.c`, `fractalsql_enterprise.c`, `fractalsql_textsql.c`, `fractalsql_cognition.c`). The `-w` should be dropped, or narrowed to the specific warnings that are known-noisy. |
| The Druid JNI shim is built with no warnings enabled | `druid-extension/src/main/native/build-native-linux.sh:107` | `cc -std=c11 -O3 -fPIC $HARDEN_C …` — no `-Wall -Wextra`, unlike every other first-party build. This shim contains findings 3.2, 3.3, 3.6 and 3.13. Add `-Wall -Wextra` (and ideally `-Werror` after the warnings are clean). |
| The JNI shim is never built under a sanitizer | `build-native-linux.sh`; `service/Makefile:152` | The daemon and the MCP server have ASAN/UBSAN/TSAN build variants. The Druid JNI shim — the code with the heap over-reads — has none. Its `calloc`/array-length mismatches are exactly what ASAN's `heap-buffer-overflow` detector catches. Add an ASAN/UBSAN build of `fractalsql_jni.c` and run the extension's tests under it. |
| `-Wl,-z,noexecstack` is missing from the MCP link line | `mcp/Makefile:99` | The MCP Makefile probes `-pie` and `-Wl,-z,relro,-z,now` but not `-Wl,-z,noexecstack`. The service Makefile and `build-native-linux.sh` both have it. Add the probe for parity. |
| `-fstack-clash-protection` / `-fcf-protection` are not probed in the MCP build | `mcp/Makefile:80-99` | The MCP Makefile probes a narrower hardening set than `service/Makefile` and `build-native-linux.sh`. |
| The JNI shim is built with `-O3` and no `-fno-strict-aliasing` | `build-native-linux.sh:107` | `-O3` enables aggressive alias-based optimisation. The shim casts `jdouble*`/`jbyte*` to `uint8_t*`/`size_t*` (`fractalsql_jni.c:764-766`, `doubles_to_sizes` at `:419-429`); a `-fno-strict-aliasing` build, or a `memcpy`-based conversion instead of a cast, removes the question. |
| No `-fvisibility=hidden` on the JNI shim | `build-native-linux.sh:107` | Every exported symbol in `libfractalsql-jni.so` is visible. There is no need for the internal helpers to be exported. |

**Note on the sanitizer variants:** `-D_FORTIFY_SOURCE=2` is deliberately omitted from the sanitizer and coverage builds in both Makefiles (it needs optimisation and conflicts with the sanitizers' interceptors). That is correct and should stay.

---

## 6. Tooling: what was run, and what could not be

| Tool | Coverage | Result |
|---|---|---|
| **cppcheck** (`--enable=all`) | The C tree: `service/`, `druid-extension/src/main/native/` | Ran. No memory-safety findings. (A local configuration problem had to be worked around first: the Strawberry build hardcodes `FILESDIR=R:/winlibs64ucrt_stage/inst_cppcheck-2.14.0/share/Cppcheck` and there is no `R:` drive; the `cfg` directory was copied to a temporary path and `subst`ed to `R:`.) |
| **cppcheck** | The C++ tree: `mcp/src` | **Unusable.** The run aborts on a parse error in the vendored `mcp/vendor/json.hpp` (`syntaxError` at line 3409) and never produced analysis output for the first-party C++ files. **The C++ tree therefore has no cppcheck coverage.** |
| **gcc `-fanalyzer`** | `service/adapter/src` (8 files) | Ran. Clean — no memory-safety findings. |
| **gcc `-fanalyzer`** | `service/daemon/fractalsqld.c`, `service/cli/fsqlctl.c`, `service/jvm/src/main/native/fsqld_jni.c` | **Could not run.** These are POSIX-only sources and the local toolchain is MinGW-w64 on Windows: `fatal error: sys/socket.h: No such file or directory`. **The daemon, the CLI and the `fsqld` JNI shim have no `-fanalyzer` coverage on this machine.** |
| **clang `--analyze`** | 4 files (the adapter plus the headers) | Ran. Clean. The same POSIX limitation applies to the daemon/CLI/JNI shim. |
| **clang-tidy** (`bugprone-*`, `cert-*`, `clang-analyzer-*`) | The C tree | Ran. One candidate, `bugprone-implicit-widening-of-multiplication-result` at `service/adapter/src/fractalsql_session.c:178`, traced to the `(6 * 3600)` int-arithmetic in `#define FSQL_SESSION_IDLE_TTL_SECONDS` — benign, not a finding. `clang-analyzer-security.insecureAPI.DeprecatedOrUnsafeBufferHandling` was excluded: the MSVC-target clang prefers the `*_s` variants and flagged every `snprintf`/`memcpy` in the tree. |
| **spotbugs + find-sec-bugs** | — | **Unavailable.** Neither is installed, and there is no Maven plugin configured for them in `druid-extension/pom.xml`. **The Java tree has no static-analysis coverage from this audit.** |
| **`mvn dependency-check` / `gradle dependencyCheckAnalyze`** | — | **Unavailable.** `mvn` is not installed (`mvn: command not found`) and the repository has no `mvnw` wrapper. **No dependency CVE scan was performed.** From reading `druid-extension/pom.xml` by hand: Druid `38.0.0` is `provided` scope, JUnit `5.10.2`, `maven-compiler-plugin` `3.13.0` with only `-Xlint:-options`. A CVE scan of the resolved dependency tree (and of Druid `38.0.0` itself) still needs to be run. |

**Limitations of this audit, stated plainly:**

- The Java side has **no** static-analysis tool coverage and **no** dependency scan. Findings 3.4, 3.5, 3.12, 3.23, 3.24, 3.25 and 3.26 were found by reading, not by tooling.
- The C++ tree has **no** cppcheck coverage. Findings 3.7, 3.8, 3.10, 3.14, 3.17, 3.18, 3.19, 3.20 and 3.21 were found by reading.
- The daemon, the CLI and the `fsqld` JNI shim have **no** `-fanalyzer` or `clang --analyze` coverage on this machine. Findings 3.1, 3.9, 3.11, 3.15, 3.16 and 3.22 were found by reading.
- The vendored core (`include/<os>-<arch>/*.a`) was not analysed. Its public contract in `include/fractalsql_sql.h` was read as the specification for the JNI boundary, and the byte-count expectations in findings 3.2, 3.3 and 3.6 were additionally confirmed by disassembling the relevant objects from the vendored archive.
- The MCP server's Druid-facing behaviour was reviewed for the HTTP transport, the JSON-RPC dispatch and the Druid client; the `adapters/` files were read only where they feed the surfaces above.

---

## 7. Summary

| # | Finding | Severity | File:line |
|---|---|---|---|
| 3.1 | Daemon accepts a forged frame when the HMAC allocation fails | High | `service/daemon/fractalsqld.c:650`, `:1576` |
| 3.2 | JNI cycle-detect: fingerprint shorter than the detector width | High | `druid-extension/src/main/native/fractalsql_jni.c:487` |
| 3.3 | JNI vascular network: edge count from the wrong array | High | `druid-extension/src/main/native/fractalsql_jni.c:768` |
| 3.4 | One native context shared across Druid threads | High | `druid-extension/.../FractalSqlCore.java:40` |
| 3.5 | SQL injection via unescaped identifiers and a raw filter | High | `druid-extension/.../FractalSqlAgents.java:989`, `:393`, `:872` |
| 3.6 | JNI portfolio: `mu` length never checked against the asset count | High | `druid-extension/src/main/native/fractalsql_jni.c:677` |
| 3.7 | MCP mints contexts past the session cap | Medium | `mcp/src/transport_http.cpp:1003` |
| 3.8 | MCP cancel set grows unbounded; request id echoed to stderr | Medium | `mcp/src/jsonrpc_server.cpp:356` |
| 3.9 | Daemon allocates 2 × 80 MiB per frame before authenticating | Medium | `service/daemon/fractalsqld.c:1573`, `:650` |
| 3.10 | `Db::acquire` holds the registry lock across blocking Druid I/O | Medium | `mcp/src/db.h:1026` |
| 3.11 | Daemon idempotency cache is not scoped to the connection | Medium | `service/daemon/fractalsqld.c:1175` |
| 3.12 | Ledger destructive operations have no authorisation of their own | Medium | `druid-extension/.../FractalExpr.java:284` |
| 3.13 | State-fingerprint allocates attacker-chosen sizes pre-validation | Medium | `druid-extension/src/main/native/fractalsql_jni.c:729` |
| 3.14 | Unauthenticated `/readyz` runs a live Druid query per request | Medium | `mcp/src/transport_http.cpp:599` |
| 3.15 | `n_assets * n_assets` can overflow `size_t` | Low | `service/adapter/src/fractalsql.c:1563` |
| 3.16 | `str_out_ensure` doubles capacity without an overflow check | Low | `service/adapter/src/fractalsql_textsql.c:179` |
| 3.17 | MCP origin check prefix-matches `127.` | Low | `mcp/src/transport_http.cpp:662` |
| 3.18 | MCP records repeated headers but never refuses them | Low | `mcp/src/transport_http.cpp:503` |
| 3.19 | `vecform::pack` truncates the dimension to 16 bits | Low | `mcp/src/db.h:352` |
| 3.20 | NaN cast to `std::int64_t` | Low | `mcp/src/db.h:776` |
| 3.21 | MCP Druid client buffers an unbounded response | Low | `mcp/src/db.h:221` |
| 3.22 | Daemon accepts a 1-byte HMAC key | Low | `service/daemon/fractalsqld.c:159` |
| 3.23 | Session id derived from `String.hashCode()` | Low | `druid-extension/.../FractalSqlDaemon.java:57` |
| 3.24 | `daemon_hmac_key_file` not redacted by `isSecret` | Low | `druid-extension/.../FractalSqlConfig.java:340` |
| 3.25 | JNI library extracted to a temp file with default permissions | Low | `druid-extension/.../NativeLoader.java:108` |
| 3.26 | Unix socket bound before its permissions are narrowed | Low | `service/jvm/.../Server.java:56` |
| 3.27 | `fsqld` JNI: unchecked array length and handle dereference | Low | `service/jvm/src/main/native/fsqld_jni.c:235`, `:289` |
| 3.28 | `GetStringUTFChars` yields modified UTF-8 | Low | `service/jvm/src/main/native/fsqld_jni.c:486` |

Six High, eight Medium, fourteen Low. The three JNI length mismatches (3.2, 3.3, 3.6) are the ones to fix first: each is a heap over-read reachable from an ordinary Druid query, and each is a few lines of validation.
