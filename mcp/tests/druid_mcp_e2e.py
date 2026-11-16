#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
# SPDX-FileCopyrightText: 2026 Daniel Gardiner d/b/a FractalSQLabs
"""Every MCP tool family against a live Druid cluster.

usage: druid_mcp_e2e.py PATH_TO_SERVER
Environment: DRUID_URL (default http://127.0.0.1:8888), DRUID_FRACTALSQL_URL (default http://127.0.0.1:8082).
The cluster's daemon must point at a provider; the build_test mock is enough.
"""
import json
import os
import subprocess
import sys

sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "..", "demo"))
import run_demo as rd  # noqa: E402

binary = sys.argv[1]
druid = os.environ.get("DRUID_URL", "http://127.0.0.1:8888").rstrip("/")
os.environ.setdefault("DRUID_URL", druid)
os.environ.setdefault("DRUID_FRACTALSQL_URL", "http://127.0.0.1:8082")
failures = []


def check(name, cond, detail=""):
    print(("ok   " if cond else "FAIL ") + name + ("" if cond else "  " + str(detail)[:400]))
    if not cond:
        failures.append(name)


# Seed what the tools read.
SQL, TASK = druid + "/druid/v2/sql", druid + "/druid/v2/sql/task"
ctx = {"arrayIngestMode": "array"}
rd.run_write('''REPLACE INTO "mcp_vecs" OVERWRITE ALL
SELECT TIMESTAMP '2026-01-01' AS "__time", "id", "body", "emb"
FROM (VALUES (1, 'alpha', '[1,0,0]'), (2, 'beta', '[0,1,0]'), (3, 'gamma', '[0.9,0.1,0]')) AS t("id", "body", "emb")
PARTITIONED BY ALL''', SQL, TASK, ctx)
rd.wait_for_datasource('SELECT "id", "body", "emb" FROM "mcp_vecs"', druid, 180)

p = subprocess.Popen([binary], stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, text=True)
_id = [0]


def rpc(method, params=None):
    _id[0] += 1
    p.stdin.write(json.dumps({"jsonrpc": "2.0", "id": _id[0], "method": method, "params": params or {}}) + "\n")
    p.stdin.flush()
    return json.loads(p.stdout.readline())


def call(name, **args):
    r = rpc("tools/call", {"name": name, "arguments": args})["result"]
    return r["isError"], r.get("structuredContent", r.get("content"))


rpc("initialize", {"protocolVersion": "2024-11-05", "capabilities": {}, "clientInfo": {"name": "t", "version": "1"}})
p.stdin.write(json.dumps({"jsonrpc": "2.0", "method": "notifications/initialized"}) + "\n")
p.stdin.flush()

# admin
err, out = call("fractal_version")
check("fractal_version", not err and "version" in out, out)
err, out = call("fractal_config_set", key="think", value="low")
check("a tuning key can be set for the session", not err, out)
err, out = call("fractal_config_get", key="think")
check("and reads back", not err and "low" in json.dumps(out), out)
err, out = call("fractal_config_set", key="reasoning_url", value="http://evil.invalid")
check("an operator key is refused by the daemon", err or "cannot be changed by a session" in json.dumps(out), out)

# analytics and vectors: expressions the cluster evaluates
series = [0.1 * (i % 7) + 0.01 * i for i in range(96)]
err, out = call("fractal_dimension_dfa", series=series)
check("dimension_dfa", not err, out)
err, out = call("fractal_dimension_drift", series=series, win=48)
check("dimension_drift", not err and "drift" in json.dumps(out), out)
err, out = call("fractal_tda_persistence_diagram", points=[0, 0, 1, 0, 0, 1, 1, 1], dim=2, max_dim=1, max_thresh=2.5)
check("tda with max_dim and max_thresh", not err, out)
err, out = call("fractal_state_fingerprint", vector=[1, 2, 3, 4], n_bits=64)
check("state_fingerprint", not err, out)
err, qa = call("fractal_vector_quantize_binary", vector=[1, -1, 1, -1])
check("vector_quantize_binary", not err, qa)
err, qb = call("fractal_vector_quantize_binary", vector=[1, 1, 1, -1])
err, out = call("fractal_vector_hamming_distance", a=qa if isinstance(qa, str) else str(qa), b=qb if isinstance(qb, str) else str(qb))
check("vector_hamming_distance over quantized vectors", not err, out)
err, out = call("fractal_periodogram", series=series, max_peaks=4)
check("periodogram", not err, out)

err, out = call("fractal_optimize_portfolio", mu=[0.1, 0.2, 0.15, 0.05], cov=[0.1, 0.01, 0.0, 0.0, 0.01, 0.2, 0.0, 0.0, 0.0, 0.0, 0.15, 0.0, 0.0, 0.0, 0.0, 0.1], k=2)
check("optimize_portfolio", not err, out)
err, out = call("fractal_optimize_portfolio_multimodal", mu=[0.1, 0.2, 0.15, 0.05], cov=[0.1, 0.01, 0.0, 0.0, 0.01, 0.2, 0.0, 0.0, 0.0, 0.0, 0.15, 0.0, 0.0, 0.0, 0.0, 0.1], k=2)
check("multimodal portfolio is live or says the tier is not loaded", (not err) or "not loaded" in json.dumps(out), out)

# cognition through the daemon
err, out = call("fractal_reason", query="hello")
# the build_test mock answers with a fixed text; a real provider (build_test --llm) answers in its own words
answered = "mock" in json.dumps(out) if not os.environ.get("FSQL_REAL_LLM") else bool(out)
check("fractal_reason reaches the provider", not err and answered, out)
err, out = call("fractal_embed", input="hello")
check("fractal_embed returns numbers", not err and isinstance(out, (list, dict)), out)
err, out = call("fractal_schema_context")
check("schema_context lists datasources", not err and "mcp_vecs" in json.dumps(out), out)
err, out = call("fractal_text_to_sql", question="count the rows", table_names=["mcp_vecs"])
check("text_to_sql returns a validated statement", not err and "generated_sql" in json.dumps(out), out)

# discovery over a datasource
err, out = call("fractal_search_telemetry", table_name="mcp_vecs", vector_col="emb", query=[1, 0, 0], k=2)
check("search_telemetry", not err, out)
err, out = call("fractal_search_explore", table_name="mcp_vecs", vector_col="emb", query=[1, 0, 0], population_size=3)
check("search_explore", not err, out)
err, out = call("fractal_diversify_enable")
check("diversify_enable", not err, out)
err, out = call("fractal_diversify_disable")
check("diversify_disable", not err, out)

# vectorizer lifecycle
err, out = call("fractal_vectorizer_create", source_table="mcp_vecs", text_col="nope", embedding_col="embedding")
check("a vectorizer on a missing column is refused", err, out)
err, out = call("fractal_vectorizer_create", source_table="mcp_vecs", text_col="body", embedding_col="embedding", id_col="id")
check("vectorizer_create", not err, out)
vid = out.get("id", 1) if isinstance(out, dict) else 1
err, out = call("fractal_vectorizer_process_queue", batch_size=10)
check("vectorizer_process_queue", not err and "embedded" in json.dumps(out), out)
err, out = call("fractal_vectorizer_pause", id=vid)
check("vectorizer_pause", not err, out)
err, out = call("fractal_vectorizer_resume", id=vid)
check("vectorizer_resume", not err, out)
err, out = call("fractal_vectorizer_drop", id=vid)
check("vectorizer_drop", not err, out)

# agency: a table-driven agent and the SQL agent
err, out = call("fractal_sql_agent", question="count the rows", table_names=["mcp_vecs"], max_retries=1)
check("sql_agent", not err, out)

# enterprise: live or dormant, never a crash
err, out = call("fractal_ledger_verify")
check("ledger_verify answers without the licence", not err, out)
err, out = call("fractal_ledger_flush")
check("the gated ledger call is live or says the tier is not loaded", (not err) or "not loaded" in json.dumps(out), out)

p.terminate()
print("\n%d failure(s)" % len(failures))
sys.exit(1 if failures else 0)
