#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
# SPDX-FileCopyrightText: 2026 Daniel Gardiner d/b/a FractalSQLabs
"""Calls every MCP tool with one argument at a time changed, and sweeps the
resource and prompt methods.

The tool table is read from the server itself (tools/list), so a new tool is
swept without editing this file. For each tool a base argument set is built from
its input schema (names that carry meaning, like a vector or a table, get a
fitting value); the base call is made, then one argument at a time is replaced
with each value from a list of bad shapes: null, the wrong JSON type, empty,
negative, huge, a very long string, a nested structure, non-finite numbers.

What must hold for every call: the server answers with a well-formed JSON-RPC
response carrying the same id, it is still running afterwards, and the answer is
never the "server" error class (an internal error that escaped a handler's own
validation). With no Druid behind the server (the default here) the calls that
get past validation end in a connectivity error, which is the expected
answer; against a live cluster (DRUID_URL set and FSQL_MUTATE_LIVE=1) the same
sweep reaches the engine too.

usage: mcp_mutate.py PATH_TO_SERVER
  MCP_MUTATE_STRIDE=N   keep every Nth mutation (default 1)
  FSQL_MUTATE_LIVE=1    a Druid is behind DRUID_URL: skip the tools that rewrite
                        configuration, the ledger or a vectorizer
"""
import json
import os
import select
import subprocess
import sys
import time

binary = sys.argv[1]
stride = max(1, int(os.environ.get("MCP_MUTATE_STRIDE", "1")))
live = os.environ.get("FSQL_MUTATE_LIVE") == "1"
mock_url = os.environ.get("FSQL_MUTATE_URL")          # a stand-in Druid (mock_druid.py) instead of a refused connection
only = [x for x in os.environ.get("MCP_MUTATE_ONLY", "").split(",") if x]   # sweep only tools whose name contains one of these
allow_server = os.environ.get("MCP_MUTATE_ALLOW_SERVER") == "1"   # an engine that answers with the wrong type is a contract break: the server class is the designed answer
parts = os.environ.get("MCP_MUTATE_PARTS", "all")     # "tools": only the tool sweep (the protocol parts do not depend on the engine)
failures = []
counts = {"calls": 0, "tools": 0, "restarts": 0, "classes": {}}


def check(name, cond, detail=""):
    if not cond:
        print("FAIL " + name + "  " + str(detail)[:300])
        failures.append(name)


# Rewrites configuration, the ledger or a vectorizer: only swept against a server with no Druid behind it.
DESTRUCTIVE = ("fractal_config_set", "fractal_configure_reasoning", "fractal_ledger_flush", "fractal_ledger_compact",
               "fractal_ledger_reset_soft", "fractal_vectorizer_drop", "fractal_vectorizer_create")

Q = [1.0, 0.0, 0.0]
SERIES = [round(0.1 * (i % 7) + 0.01 * i, 4) for i in range(48)]
SQUARE = [0, 0, 1, 0, 1, 1, 0, 1]
NAMED = {
    "vector": Q, "query": Q, "baseline_vec": Q, "current_vec": Q, "baseline_vector": Q, "current_vector": Q, "task_emb": Q,
    "task_vec": Q, "state_vec": Q, "query_vec": Q, "clinical_vector": Q, "morphology_vector": Q, "surrogate_vector": Q,
    "series": SERIES, "heading_series": SERIES, "drift_series": SERIES, "state_log": SERIES[:24],
    "points": SQUARE, "point_cloud": SQUARE, "gps_trace": SQUARE, "node_coords": [0, 0, 0, 1, 0, 0, 1, 1, 0, 0, 1, 1],
    "edges": [0, 1, 1, 2, 2, 3], "mu": [0.1, 0.2, 0.15, 0.05], "item_values": [0.12, 0.09, 0.15, 0.06],
    "cov": [0.1, 0.01, 0, 0, 0.01, 0.2, 0, 0, 0, 0, 0.15, 0, 0, 0, 0, 0.1], "corpus": [0, 0, 1, 1, 2, 2, 3, 3],
    "fingerprints": [1, 2, 3, 1, 2, 3], "table_names": ["t"], "cohort_doc_ids": [1, 2], "a": [1, 2, 3], "b": [3, 2, 1],
    "table_name": "t", "source_table": "t", "vector_col": "emb", "emb_col": "emb", "text_col": "body", "id_col": "id",
    "embedding_col": "emb", "question": "count the rows", "text": "[1,2,3]", "input": "hello", "context": "ctx",
    "key": "think", "value": "low", "dim": 2, "k": 3, "limit": 5, "seed": 7, "id": 1, "n_bits": 64,
}


def base_args(schema):
    props = schema.get("properties", {})
    out = {}
    for k, v in props.items():
        if k in NAMED:
            out[k] = NAMED[k]
        elif "default" in v:
            out[k] = v["default"]
        elif v.get("enum"):
            out[k] = v["enum"][0]
        else:
            t = v.get("type")
            out[k] = {"string": "x", "integer": 2, "number": 0.5, "boolean": False, "array": [1, 2, 3], "object": {}}.get(t, "x")
    return out


def mutations(v):
    t = v.get("type")
    m = [None, "", "x" * 70000, [], {}, [[1, 2], [3]], {"a": {"b": [1]}}, -1, 0, 2 ** 40, 1e308, -1e308, 0.5, True, "NaN", "[1,2", "1e999",
         "\u0000", "'; DROP TABLE t; --", [None], ["a", "b"], [1e308, -1e308], [float("1e-320")] * 3]
    if t == "string":
        m += [12, [1], {"k": "v"}]
    elif t in ("integer", "number"):
        m += ["3", [3], {"k": 3}, 2 ** 63, -2 ** 63]
    elif t == "array":
        m += ["[1,2,3]", 7, {"k": [1]}, [1] * 5000]
    elif t == "boolean":
        m += ["true", 1, []]
    elif t == "object":
        m += [[1], "{}", {"seed": "x"}, {"population_size": -1}]
    return m


class Server:
    def __init__(self):
        env = dict(os.environ)
        if not live:
            env["DRUID_URL"] = "http://127.0.0.1:1"
            env["DRUID_TIMEOUT_MS"] = "2000"
        self.start()

    def start(self):
        self.p = subprocess.Popen([binary], stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, text=True,
                                  env=dict(os.environ, **({} if live else {"DRUID_URL": mock_url or "http://127.0.0.1:1", "DRUID_TIMEOUT_MS": "2000"})))
        self.n = 0
        self.rpc("initialize", {"protocolVersion": "2025-06-18", "capabilities": {}, "clientInfo": {"name": "mutate", "version": "1"}})
        self.p.stdin.write(json.dumps({"jsonrpc": "2.0", "method": "notifications/initialized"}) + "\n")
        self.p.stdin.flush()

    def rpc(self, method, params=None, timeout=float(os.environ.get("MCP_MUTATE_RPC_TIMEOUT", "60"))):
        self.n += 1
        try:
            self.p.stdin.write(json.dumps({"jsonrpc": "2.0", "id": self.n, "method": method, "params": params if params is not None else {}}) + "\n")
            self.p.stdin.flush()
        except (BrokenPipeError, ValueError):
            return None
        r, _, _ = select.select([self.p.stdout], [], [], timeout)
        if not r:
            return "timeout"
        line = self.p.stdout.readline()
        if not line:
            return None
        try:
            return json.loads(line)
        except ValueError:
            return "garbled: " + line[:100]

    def alive(self):
        return self.p.poll() is None

    def restart(self):
        counts["restarts"] += 1
        try:
            self.p.kill()
        except OSError:
            pass
        self.start()


S = Server()


def settle(label, resp, expect_id=None):
    """A response must be well formed; a restart follows a death or a hang."""
    counts["calls"] += 1
    if resp is None or isinstance(resp, str):
        check(label + ": the server answered", False, resp)
        S.restart()
        return None
    check(label + ": the id comes back", resp.get("id") == S.n, resp)
    check(label + ": a result or an error, not both", ("result" in resp) != ("error" in resp), resp)
    res = resp.get("result")
    if isinstance(res, dict) and res.get("isError"):
        cls = (res.get("structuredContent") or {}).get("error_class", "?")
        counts["classes"][cls] = counts["classes"].get(cls, 0) + 1
        check(label + ": never the server error class", allow_server or cls != "server", res)
    return resp


tools = S.rpc("tools/list")["result"]["tools"]
for t in tools:
    name = t["name"]
    if live and name in DESTRUCTIVE:
        continue
    if only and not any(o in name for o in only):
        continue
    schema = t.get("inputSchema", {})
    base = base_args(schema)
    counts["tools"] += 1
    settle(name + " base", S.rpc("tools/call", {"name": name, "arguments": base}))
    settle(name + " no arguments", S.rpc("tools/call", {"name": name, "arguments": {}}))
    settle(name + " arguments null", S.rpc("tools/call", {"name": name, "arguments": None}))
    settle(name + " arguments an array", S.rpc("tools/call", {"name": name, "arguments": [1]}))
    settle(name + " unknown argument", S.rpc("tools/call", {"name": name, "arguments": {**base, "zz_unknown": 1}}))
    i = 0
    for arg, spec in schema.get("properties", {}).items():
        for mv in mutations(spec):
            i += 1
            if i % stride:
                continue
            settle("%s.%s=%s" % (name, arg, json.dumps(mv)[:30]), S.rpc("tools/call", {"name": name, "arguments": {**base, arg: mv}}))
        # the argument left out, when the base had it
        a2 = dict(base)
        a2.pop(arg, None)
        settle(name + " without " + arg, S.rpc("tools/call", {"name": name, "arguments": a2}))
    check(name + ": the server is still running", S.alive())
    if not S.alive():
        S.restart()

def finish():
    r = S.rpc("ping")
    check("the server answers a ping at the end", isinstance(r, dict) and "result" in r, r)
    try:
        S.p.stdin.close()          # end of input is a normal shutdown: the coverage counters are written on a clean exit
    except OSError:
        pass
    try:
        S.p.wait(10)
    except subprocess.TimeoutExpired:
        S.p.kill()
    print("mutate: %d calls over %d tools, %d restarts, error classes %s" % (counts["calls"], counts["tools"], counts["restarts"], counts["classes"]))
    print("%d failure(s)" % len(failures))
    sys.exit(1 if failures else 0)


if parts == "tools":
    finish()

# resources: every listed URI, then bad ones
res = S.rpc("resources/list")["result"]["resources"]
for r in res:
    resp = settle("resources/read " + r["uri"], S.rpc("resources/read", {"uri": r["uri"]}))
for uri in ("", "fractalsql://", "fractalsql://nope", "fractalsql://ledger/", "fractalsql://ledger/0", "fractalsql://ledger/3",
            "fractalsql://ledger/x", "fractalsql://ledger/1/extra", "fractalsql://vectorizer", "fractalsql://schema/", "file:///etc/passwd",
            "x" * 5000, "fractalsql://agents?x=1"):
    settle("resources/read bad uri " + uri[:30], S.rpc("resources/read", {"uri": uri}))
for params in (None, {}, {"uri": None}, {"uri": 5}, {"uri": []}, {"uri": {}}, [1], "x"):
    settle("resources/read params " + json.dumps(params)[:30], S.rpc("resources/read", params))
settle("resources/templates/list", S.rpc("resources/templates/list"))
settle("resources/subscribe", S.rpc("resources/subscribe", {"uri": "fractalsql://schema"}))
settle("resources/list with a cursor", S.rpc("resources/list", {"cursor": "abc"}))

# prompts: every listed prompt, with all arguments, with some, with none, with bad ones
prompts = S.rpc("prompts/list")["result"]["prompts"]
for p in prompts:
    args = {a["name"]: "t1" for a in p.get("arguments", [])}
    settle("prompts/get " + p["name"], S.rpc("prompts/get", {"name": p["name"], "arguments": args}))
    settle("prompts/get " + p["name"] + " no arguments", S.rpc("prompts/get", {"name": p["name"]}))
    settle("prompts/get " + p["name"] + " empty arguments", S.rpc("prompts/get", {"name": p["name"], "arguments": {}}))
    nums = {a["name"]: "1,2,3,4" for a in p.get("arguments", [])}
    settle("prompts/get " + p["name"] + " numeric text", S.rpc("prompts/get", {"name": p["name"], "arguments": nums}))
    for a in p.get("arguments", []):
        part = dict(args)
        part.pop(a["name"])
        settle("prompts/get %s without %s" % (p["name"], a["name"]), S.rpc("prompts/get", {"name": p["name"], "arguments": part}))
        for mv in (None, 5, [1], {"k": 1}, "", "x" * 20000, "a\nb", "{{x}}", "%s%n"):
            settle("prompts/get %s.%s=%s" % (p["name"], a["name"], json.dumps(mv)[:20]),
                   S.rpc("prompts/get", {"name": p["name"], "arguments": {**args, a["name"]: mv}}))
for params in (None, {}, {"name": None}, {"name": 3}, {"name": "no_such_prompt"}, {"name": "x", "arguments": "y"}, {"name": "x", "arguments": [1]}, [1], "x"):
    settle("prompts/get params " + json.dumps(params)[:30], S.rpc("prompts/get", params))
settle("prompts/list with a cursor", S.rpc("prompts/list", {"cursor": "abc"}))

# the protocol methods themselves
for method, params in (("ping", None), ("ping", {"x": 1}), ("logging/setLevel", {"level": "debug"}), ("logging/setLevel", {"level": 5}),
                       ("logging/setLevel", {}), ("completion/complete", {}), ("server/discover", {}), ("tools/list", {"cursor": "x"}),
                       ("tools/call", None), ("tools/call", {}), ("tools/call", {"name": 5}), ("tools/call", {"name": ""}),
                       ("tools/call", {"name": "fractal_version", "arguments": {}, "_meta": {"progressToken": 1}}),
                       ("tools/call", {"name": "fractal_version", "arguments": {}, "_meta": 5}),
                       ("no/such/method", {}), ("", {}), ("initialize", {}), ("initialize", {"protocolVersion": 5}),
                       ("initialize", {"protocolVersion": "1999-01-01"}), ("initialize", {"protocolVersion": "2025-11-25"})):
    settle("method %s %s" % (method, json.dumps(params)[:24]), S.rpc(method, params))

# raw lines: not JSON, not an object, wrong version, odd ids
for raw in ("", "not json", "[]", "[1,2]", "5", "null", '{"jsonrpc":"1.0","id":1,"method":"ping"}', '{"id":1}', '{"jsonrpc":"2.0","method":5,"id":1}',
            '{"jsonrpc":"2.0","method":"ping","id":null}', '{"jsonrpc":"2.0","method":"ping","id":{"a":1}}', '{"jsonrpc":"2.0","method":"ping","id":1.5}',
            '{"jsonrpc":"2.0","method":"ping","id":"s"}', '{"jsonrpc":"2.0","method":"ping","params":5,"id":2}',
            '{"jsonrpc":"2.0","method":"notifications/cancelled","params":{"requestId":99}}', '{"jsonrpc":"2.0","method":"notifications/cancelled","params":5}',
            '{"jsonrpc":"2.0","method":"$/cancel","params":{}}', '[{"jsonrpc":"2.0","method":"ping","id":3}]', "{" * 300, "x" * 200000):
    try:
        S.p.stdin.write(raw + "\n")
        S.p.stdin.flush()
        r, _, _ = select.select([S.p.stdout], [], [], 1.0)
        if r:
            line = S.p.stdout.readline()
            if line:
                try:
                    json.loads(line)
                except ValueError:
                    check("raw line %r: the answer is JSON" % raw[:30], False, line[:100])
        counts["calls"] += 1
    except (BrokenPipeError, ValueError):
        pass
    if not S.alive():
        check("raw line %r: the server survives" % raw[:30], False)
        S.restart()
    elif select.select([S.p.stdout], [], [], 0)[0]:
        S.p.stdout.readline()
finish()
