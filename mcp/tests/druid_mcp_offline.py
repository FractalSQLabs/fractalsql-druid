#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
# SPDX-FileCopyrightText: 2026 Daniel Gardiner d/b/a FractalSQLabs
"""The MCP server's protocol and tool surface, with no Druid behind it.

usage: druid_mcp_offline.py PATH_TO_SERVER
"""
import json
import os
import subprocess
import sys

binary = sys.argv[1]
failures = []


def check(name, cond, detail=""):
    print(("ok   " if cond else "FAIL ") + name + ("" if cond else "  " + str(detail)[:300]))
    if not cond:
        failures.append(name)


env = dict(os.environ, DRUID_URL="http://127.0.0.1:1")
p = subprocess.Popen([binary], stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL,
                     env=env, text=True)


def rpc(i, method, params=None):
    p.stdin.write(json.dumps({"jsonrpc": "2.0", "id": i, "method": method, "params": params or {}}) + "\n")
    p.stdin.flush()
    return json.loads(p.stdout.readline())


r = rpc(1, "initialize", {"protocolVersion": "2024-11-05", "capabilities": {}, "clientInfo": {"name": "t", "version": "1"}})
info = r["result"]["serverInfo"]
check("initialize names the server", info["name"] == "fractalsql-druid-mcp", info)
check("the server offers tools, prompts and resources", {"tools", "prompts", "resources"} <= set(r["result"]["capabilities"]))
p.stdin.write(json.dumps({"jsonrpc": "2.0", "method": "notifications/initialized"}) + "\n")
p.stdin.flush()

tools = rpc(2, "tools/list")["result"]["tools"]
by = {t["name"]: t for t in tools}
check("78 tools are published", len(tools) == 78, len(tools))
check("every tool has an object input schema", all(t["inputSchema"].get("type") == "object" for t in tools))
check("every tool declares its four hints", all({"readOnlyHint", "destructiveHint", "idempotentHint", "openWorldHint"} <= set(t["annotations"]) for t in tools))
check("no parameter is published as a nullable union", not any(isinstance(v.get("type"), list) for t in tools for v in t["inputSchema"].get("properties", {}).values()))


def props(name):
    return by[name]["inputSchema"].get("properties", {})


def required(name):
    return set(by[name]["inputSchema"].get("required", []))


# the settled naming and defaults of the alignment standard
check("spectrogram_entropy publishes window", "window" in props("fractal_spectrogram_entropy") and "win" not in props("fractal_spectrogram_entropy"))
check("dimension_drift keeps win, default 48", props("fractal_dimension_drift")["win"].get("default") == 48)
check("state_fingerprint publishes vector", "vector" in props("fractal_state_fingerprint") and "vec" not in props("fractal_state_fingerprint"))
check("state_fingerprint n_bits is optional, default 128", "n_bits" not in required("fractal_state_fingerprint") and props("fractal_state_fingerprint")["n_bits"].get("default") == 128)
for q in ("fractal_vector_quantize_binary", "fractal_vector_quantize_int8"):
    check(q + " publishes vector", "vector" in props(q) and "v" not in props(q))
tda = props("fractal_tda_persistence_diagram")
check("tda: max_dim optional with default 0", "max_dim" not in required("fractal_tda_persistence_diagram") and tda["max_dim"].get("default") == 0)
check("tda: max_thresh required", "max_thresh" in required("fractal_tda_persistence_diagram"))
check("seeds are integers", all(v.get("type") == "integer" for t in tools for k, v in t["inputSchema"].get("properties", {}).items() if k == "seed"))
a = by["fractal_agent_trajectory_predict"]["annotations"]
check("trajectory_predict is read-only and idempotent", a["readOnlyHint"] and a["idempotentHint"])
reasoning = [t for t in tools if t["annotations"].get("secretHint")]
check("the tools that reach a model carry secretHint", len(reasoning) == 21, len(reasoning))
check("fractal_reason is open-world", by["fractal_reason"]["annotations"]["openWorldHint"])

# tools with no Druid backing are absent, and the Druid forms are published
for gone in ("fractal_search", "fractal_optimize_subset", "fractal_store_morphology", "fractal_mine_topology_negatives"):
    check(gone + " is not published", gone not in by)
check("search_explore reads a datasource", {"table_name", "vector_col", "query"} <= set(props("fractal_search_explore")))
check("vectorizer_create takes an id column", "id_col" in props("fractal_vectorizer_create"))
keydoc = by["fractal_config_set"]["inputSchema"]["properties"]["key"].get("description", "")
check("config keys use the daemon's names", "reasoning_url" in keydoc and "t2s_max_attempts" in keydoc and "http_url" not in keydoc, keydoc)

# errors are classified
c = rpc(3, "tools/call", {"name": "fractal_dimension_dfa", "arguments": {}})["result"]
check("a missing argument is a schema error", c["isError"] and c["structuredContent"]["error_class"] == "schema", c)
c = rpc(4, "tools/call", {"name": "fractal_version", "arguments": {}})["result"]
check("an unreachable Druid is a connectivity error", c["isError"] and c["structuredContent"]["error_class"] == "connectivity", c)
c = rpc(5, "tools/call", {"name": "fractal_no_such_tool", "arguments": {}})
check("an unknown tool is refused", "error" in c or c["result"].get("isError"), c)

p.terminate()
print("\n%d failure(s)" % len(failures))
sys.exit(1 if failures else 0)
