#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
# SPDX-FileCopyrightText: 2026 Daniel Gardiner d/b/a FractalSQLabs
"""The extension's /fractalsql endpoints against a live Druid cluster.

usage: druid_service.py DRUID_URL SERVICE_URL
Needs a cluster whose daemon points at a provider (the build_test mock is enough).
"""
import json
import os
import sys
import urllib.request

sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "demo"))
import run_demo as rd  # noqa: E402

druid, service = sys.argv[1].rstrip("/"), sys.argv[2].rstrip("/")
SQL, TASK = druid + "/druid/v2/sql", druid + "/druid/v2/sql/task"
failures = []


def check(name, cond, detail=""):
    print(("ok   " if cond else "FAIL ") + name + ("" if cond else "  " + str(detail)[:300]))
    if not cond:
        failures.append(name)


def post(path, body, timeout=300):
    req = urllib.request.Request(service + path, data=json.dumps(body).encode(),
                                 headers={"Content-Type": "application/json"})
    try:
        with urllib.request.urlopen(req, timeout=timeout) as r:
            return r.status, json.loads(r.read() or b"null")
    except urllib.error.HTTPError as e:
        try:
            return e.code, json.loads(e.read() or b"null")
        except ValueError:
            return e.code, None


def get(path):
    with urllib.request.urlopen(service + path, timeout=60) as r:
        return r.status, json.loads(r.read())


def write(sql):
    rd.run_write(sql, SQL, TASK, {"arrayIngestMode": "array"})
    rd.wait_for_datasource(sql, druid, 180)


# A small corpus to work on.
write('''REPLACE INTO "svc_docs" OVERWRITE ALL
SELECT TIMESTAMP '2026-01-01' AS "__time", "id", "body", "category"
FROM (VALUES (1, 'first doc', 'a'), (2, 'second doc', 'b'), (3, 'third doc', 'a')) AS t("id", "body", "category")
PARTITIONED BY ALL''')

st, health = get("/fractalsql/health")
check("health answers", st == 200 and isinstance(health, dict), health)
check("health reports the daemon reachable", health.get("providerConfigured") is True, health)

st, ctx = get("/fractalsql/schema-context?datasource=svc_docs")
names = [c["name"] for c in ctx.get("columns", [])]
check("schema-context lists a datasource's columns", {"id", "body", "category"} <= set(names), ctx)
st, inv = get("/fractalsql/schema-context")
check("schema-context lists the datasources", any(d["datasource"] == "svc_docs" for d in inv.get("datasources", [])), inv)

st, r = post("/fractalsql/reason", {"query": "hello", "context": "{}"})
check("reason answers through the daemon", st == 200, (st, r))
st, r = post("/fractalsql/embed", {"text": "hello"})
check("embed answers through the daemon", st == 200, (st, r))
st, r = post("/fractalsql/review", {"question": "count rows", "sql": "SELECT COUNT(*) FROM svc_docs"})
check("review answers", st == 200 and r.get("passed") is True, (st, r))
st, r = post("/fractalsql/review", {"question": "count rows FAILME", "sql": "SELECT 1"})
check("a failing review is reported", st == 200 and r.get("passed") is False, (st, r))

# text-to-SQL: the mock answers "SELECT 1 AS one", which Druid's planner accepts
st, r = post("/fractalsql/text-to-sql", {"question": "count the rows", "tables": ["svc_docs"]})
check("text-to-sql returns a statement", st == 200 and r.get("generated_sql"), (st, r))
check("text-to-sql validates it with EXPLAIN PLAN", r.get("valid") is True, r)
check("text-to-sql reports its attempts", r.get("attempts") == 1, r)
st, r = post("/fractalsql/text-to-sql", {"question": "count the rows"})
check("text-to-sql discovers the schema with no tables named", st == 200 and r.get("valid") is True, (st, r))

# a session can tighten text-to-SQL for itself
st, r = post("/fractalsql/text-to-sql", {"question": "count FAILME rows", "tables": ["svc_docs"], "session": "svc-ci"})
check("text-to-sql with a session answers", st == 200, (st, r))

# the vectorizer runs on a table of its own per run, so the companion datasource starts empty
import time
VEC = "svc_vec_%d" % int(time.time())
write('''REPLACE INTO "''' + VEC + '''" OVERWRITE ALL
SELECT TIMESTAMP '2026-01-01' AS "__time", "id", "body"
FROM (VALUES (1, 'first doc'), (2, 'second doc'), (3, 'third doc')) AS t("id", "body")
PARTITIONED BY ALL''')
st, r = post("/fractalsql/vectorizer", {"action": "create", "source_table": VEC, "source_column": "nope",
                                       "embedding_column": "embedding", "id_column": "id"})
check("a vectorizer on a missing column is refused", st == 400 and "does not exist" in json.dumps(r), (st, r))
st, r = post("/fractalsql/vectorizer", {"action": "create", "source_table": VEC, "source_column": "body",
                                       "embedding_column": "embedding", "id_column": "id",
                                       "options": {"max_embeds_per_window": 100}})
check("a vectorizer is created", st == 200 and r.get("id"), (st, r))
vid = r.get("id", 0)
st, r = post("/fractalsql/vectorizer", {"action": "status", "id": vid})
check("status reports three pending rows", st == 200 and r.get("pending") == 3, (st, r))
st, r = post("/fractalsql/vectorizer", {"action": "process_queue", "batch_size": 2})
mine = lambda r: [x for x in r.get("rows", []) if x.get("vectorizer_id") == vid]
check("process_queue honours batch_size", st == 200 and len(mine(r)) == 2, (st, r))
check("process_queue appends to the companion datasource", VEC + "_embeddings" in json.dumps(r.get("written")), r)
st, r = post("/fractalsql/vectorizer", {"action": "process_queue", "batch_size": 2})
check("the next run embeds only the remaining row", st == 200 and len(mine(r)) == 1, (st, r))
st, r = post("/fractalsql/vectorizer", {"action": "pause", "id": vid})
check("pause is idempotent", st == 200 and post("/fractalsql/vectorizer", {"action": "pause", "id": vid})[0] == 200)
st, r = post("/fractalsql/vectorizer", {"action": "pause", "id": 9999})
check("a nonexistent id is a clear error", st == 400, (st, r))
st, r = post("/fractalsql/vectorizer", {"action": "drop", "id": vid})
check("drop deregisters", st == 200 and r.get("dropped") is True, (st, r))

# an agent: partial-result honesty with the mock provider answering normally
st, r = post("/fractalsql/agent/outlier_screen", {"proposed_table": "svc_docs", "state_column": "body",
                                                   "history_table": "svc_docs", "emb_column": "body", "threshold": 0.5})
check("an agent endpoint answers (or refuses clearly)", st in (200, 400), (st, r))
st, r = post("/fractalsql/agent/no_such_agent", {})
check("an unknown agent is refused", st in (400, 404, 500), (st, r))

# the ledger endpoint is dormant or live, never a crash
st, r = post("/fractalsql/ledger", {"action": "status"})
check("the ledger status answers", st == 200 and "loaded" in r, (st, r))
st, r = post("/fractalsql/ledger", {"action": "verify"})
check("verify answers without the licence", st == 200, (st, r))

print("\n%d failure(s)" % len(failures))
sys.exit(1 if failures else 0)
