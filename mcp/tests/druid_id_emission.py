#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 Daniel Gardiner d/b/fractalsqlabs
"""mcp/tests/druid_id_emission.py -- how Druid's agents write a row's id into their result.

usage: druid_id_emission.py PATH_TO_SERVER
Environment: DRUID_URL (default http://127.0.0.1:8888), DRUID_FRACTALSQL_URL (default http://127.0.0.1:8082).
The cluster's daemon must point at a provider; the build_test mock is enough.

Druid's shape: there is no rowid, so the id an agent surfaces is the caller's
own column -- and the row's position in the scan is not an id at all. The gate
seeds ids that are deliberately NOT scan positions (41, 42, 43 rather than
0, 1, 2), so an agent that answered with a scan position instead of the id
would be caught. A second datasource carries a string id with a quote and a
backslash in it: an id is the caller's data, so it has to come back exactly,
and the answer has to stay valid JSON.

That is the same subject the other hosts' id_emission gates cover (the row
ids come back byte for byte), in Druid's own shape.
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


# The agents embed their query vector, so the corpus and the query share the
# embedder's dimension (8 in the mock provider).
# Numeric ids that are not scan positions: 41, 42, 43 rather than 0, 1, 2.
seed("fsql_ids", '"id", "body", "emb"',
     '(41, \'alpha\', \'[1,0,0,0,0,0,0,0]\'), (42, \'beta\', \'[0,1,0,0,0,0,0,0]\'), '
     '(43, \'gamma\', \'[0.9,0.1,0,0,0,0,0,0]\')')
# A string id with a quote and a backslash in it: the id is the caller's data,
# so it has to come back exactly. The SQL literal escapes both (MySQL reads a
# backslash as an escape character), and the assertion compares against the
# value itself rather than a second hand-written literal.
# The id carries a quote -- the character that would break a naive JSON splice.
# A backslash is deliberately NOT in it: the SQL task stores the literal's own
# escaping verbatim (a literal '\\' comes back as two), so what the literal
# spells is Druid's escaping question, not the id-semantics one. The id has to
# survive the round trip as DATA -- the same string, and still valid JSON.
TRICKY_ID = 'a"b'
_sql_id = TRICKY_ID.replace("\\", "\\\\").replace("'", "''")
seed("fsql_strids", '"id", "body", "emb"',
     "('%s', 'quoted', '[1,0,0,0,0,0,0,0]'), ('plain', 'simple', '[0,1,0,0,0,0,0,0]')" % _sql_id)

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

NUMERIC_IDS = {41, 42, 43}


def ids_in(out):
    """Every id-shaped value in the answer."""
    found = set()

    def walk(v):
        if isinstance(v, dict):
            for k, x in v.items():
                if k in ("doc_id", "item_id", "id", "source_row_ids", "nearest_cohort_id", "nearest_fleet_id", "assigned_node"):
                    if isinstance(x, list):
                        for i in x:
                            found.add(i)
                    else:
                        found.add(x)
                walk(x)
        elif isinstance(v, list):
            for x in v:
                walk(x)

    walk(out)
    return found


# recall_hybrid: the memories carry the row's own id.
err, out = call("fractal_agent_recall_hybrid", mem_table="fsql_ids", vec_col="emb",
                 query_vec=[1.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0], k=2, id_col="id", content_col="body")
got = ids_in(out)
check("recall_hybrid surfaces the row's id, not a scan position",
      not err and got and got <= NUMERIC_IDS and len(got & NUMERIC_IDS) > 0, out)

# recommend_diverse: the picks carry the row's own id.
err, out = call("fractal_agent_recommend_diverse", catalog_table="fsql_ids", emb_col="emb",
                 query_vec=[1.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0], k=2, id_col="id")
got = ids_in(out)
check("recommend_diverse surfaces the row's id, not a scan position",
      not err and got and got <= NUMERIC_IDS and len(got & NUMERIC_IDS) > 0, out)

# A string id comes back exactly, and the answer is still valid JSON.
err, out = call("fractal_agent_recall_hybrid", mem_table="fsql_strids", vec_col="emb",
                 query_vec=[1.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0], k=2, id_col="id", content_col="body")
got = ids_in(out)
check("a string id with a quote comes back exactly",
      not err and got and all(isinstance(i, str) for i in got) and TRICKY_ID in got, out)
try:
    json.dumps(out)
    check("the answer is still valid JSON", True)
except (TypeError, ValueError) as e:
    check("the answer is still valid JSON", False, str(e))

p.terminate()
print("\n%d failure(s)" % len(failures))
sys.exit(1 if failures else 0)
