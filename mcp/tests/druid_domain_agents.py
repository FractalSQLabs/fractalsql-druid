#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 Daniel Gardiner d/b/fractalsqlabs
"""mcp/tests/druid_domain_agents.py -- the nine domain agents against a live Druid cluster.

usage: druid_domain_agents.py PATH_TO_SERVER
Environment: DRUID_URL (default http://127.0.0.1:8888), DRUID_FRACTALSQL_URL (default http://127.0.0.1:8082).
The cluster's daemon must point at a provider; the build_test mock is enough.

The nine agents the other hosts' gates cover (detect_loop, detour_classify,
network_coverage_alert, patient_deterioration_triage, rebalance_sibling,
recall_hybrid, regime_triage, schedule_workload, track_anomaly) are the JVM
daemon's: the C daemon has no agent layer, so the coverage has to run against
the JVM extension over the MCP, which is how a Druid deployment reaches them.

Each agent gets the fixture it documents: a datasource to search, an inline
vector where the agent takes one, an inline series where it takes one. The
assertion is the agent's own result shape -- the key it documents -- so a
silently empty answer fails the gate rather than passing it.
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

SQL, TASK = druid + "/druid/v2/sql", druid + "/druid/v2/sql/task"
CTX = {"arrayIngestMode": "array"}


def check(name, cond, detail=""):
    print(("ok   " if cond else "FAIL ") + name + ("" if cond else "  " + str(detail)[:400]))
    if not cond:
        failures.append(name)


def seed(name, columns, values):
    """One Druid datasource: the columns the agents read, and the rows.

    The rows come in as a VALUES list with the column names as the aliases,
    which is how the SQL task takes them (the demo's own seeding does the
    same)."""
    rd.run_write('REPLACE INTO "%s" OVERWRITE ALL\nSELECT TIMESTAMP \'2026-01-01\' AS "__time", %s\n'
                 'FROM (VALUES %s) AS t(%s)\nPARTITIONED BY ALL' % (name, columns, values, columns),
                 SQL, TASK, CTX)
    rd.wait_for_datasource('SELECT %s FROM "%s"' % (columns, name), druid, 180)


# The datasources the nine agents search. The id column holds values that are
# NOT scan positions (the agents would otherwise be unable to tell the two
# apart), and the vectors are the JSON-array text the extension parses.
seed("fsql_vecs", '"id", "body", "emb"',
     '(1, \'alpha\', \'[1,0,0,0,0,0,0,0]\'), (2, \'beta\', \'[0,1,0,0,0,0,0,0]\'), (3, \'gamma\', \'[0.9,0.1,0,0,0,0,0,0]\')')
seed("fsql_tracks", '"id", "emb"',
     '(11, \'[1,0,0,0,0,0,0,0]\'), (12, \'[0,1,0,0,0,0,0,0]\')')
seed("fsql_fleet", '"id", "emb"',
     '(21, \'[1,0,0,0,0,0,0,0]\'), (22, \'[0,1,0,0,0,0,0,0]\')')
seed("fsql_nodes", '"id", "emb"',
     '(31, \'[1,0,0,0,0,0,0,0]\'), (32, \'[0,1,0,0,0,0,0,0]\')')
seed("fsql_allocs", '"id", "emb"',
     '(41, \'[1,0,0,0,0,0,0,0]\'), (42, \'[0,1,0,0,0,0,0,0]\')')
seed("fsql_patients", '"id", "emb"',
     '(51, \'[1,0,0,0,0,0,0,0]\'), (52, \'[0,1,0,0,0,0,0,0]\')')

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

SERIES = [0.1 * (i % 7) + 0.01 * i for i in range(96)]
HEADING = [0.3 * (i % 5) - 0.2 * (i % 3) for i in range(64)]
GPS = [0.1 * i + 0.2 * (i % 4) for i in range(24)]

# The nine agents, each with the fixture it documents and the result key it
# promises. The key is the agent's own: an agent that answers with a different
# shape (or an empty document) fails here.
CASES = [
    ("regime_triage", {"series": SERIES, "win": 48}, "dfa_exponent"),
    ("detect_loop", {"agent_id": "gate48", "state_log": [1.0, 0.0, 0.0, 1.0, 0.0, 0.0] * 4, "dim": 3},
     "is_loop_detected"),
    # The point cloud is a flat list of numbers (the box-counting input), the
    # same shape the agent's gps_trace takes.
    ("network_coverage_alert", {"point_cloud": [0.1 * i + 0.2 * (i % 5) + 0.3 * (i % 3) for i in range(72)],
                               "drift_series": SERIES}, "morph_dimension"),
    ("recall_hybrid", {"mem_table": "fsql_vecs", "vec_col": "emb", "query_vec": [1.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0],
                       "k": 2, "id_col": "id", "content_col": "body"}, "memories"),
    ("recommend_diverse", {"catalog_table": "fsql_vecs", "emb_col": "emb", "query_vec": [1.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0],
                           "k": 2, "id_col": "id"}, "items"),
    ("track_anomaly", {"track_table": "fsql_tracks", "emb_col": "emb", "baseline_vec": [1.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0],
                       "current_vec": [0.9, 0.1, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0], "heading_series": HEADING, "k": 2, "id_col": "id"},
     "nearest_fleet_id"),
    ("detour_classify", {"vehicle_table": "fsql_fleet", "emb_col": "emb", "baseline_vec": [1.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0],
                          "current_vec": [0.9, 0.1, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0], "gps_trace": GPS, "k": 2, "id_col": "id"},
     "trace_complexity"),
    ("schedule_workload", {"task_vec": [1.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0], "node_table": "fsql_nodes", "node_emb_col": "emb",
                           "node_id_col": "id", "iterations": 5, "population": 8, "k": 2}, "assigned_node"),
    ("patient_deterioration_triage", {"patient_table": "fsql_patients", "vec_col": "emb",
                                      "query_vec": [1.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0], "baseline_vec": [1.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0],
                                      "current_vec": [0.9, 0.1, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0], "k": 2, "id_col": "id"}, "nearest_cohort_id"),
    # The baseline is compared against the OPTIMISER's output, so it has mu's
    # dimension (3), not the corpus'.
    ("rebalance_sibling", {"mu": [0.1, 0.2, 0.15], "cov": [0.02, 0.001, 0.001, 0.001, 0.03, 0.001, 0.001, 0.001, 0.04],
                           "cardinality": 2, "alloc_table": "fsql_allocs", "alloc_emb_col": "emb",
                           "baseline_vec": [0.25, 0.25, 0.25], "seed": 7, "k": 2, "id_col": "id"}, "sharpe"),
]

for short, args, key in CASES:
    name = "fractal_agent_" + short
    err, out = call(name, **args)
    check("%s answers with its %s" % (name, key), not err and key in json.dumps(out), out)

p.terminate()
print("\n%d failure(s)" % len(failures))
sys.exit(1 if failures else 0)
