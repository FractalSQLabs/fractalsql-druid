#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
# SPDX-FileCopyrightText: 2026 Daniel Gardiner d/b/a FractalSQLabs
"""The index registry survives a restart and is shared by two brokers.

usage: druid_index_registry.py ROUTER_URL BROKER_A_URL BROKER_B_URL BROKER_A_CONTAINER

Builds an index on broker A and checks that: broker B lists it and searches through it; broker A still lists it, reports
it ready and searches through it after a restart; and a drop is seen by both brokers and stays dropped after a restart.
"""
import json
import math
import os
import subprocess
import sys
import time
import urllib.error
import urllib.request

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.join(os.path.dirname(HERE), "demo"))
import run_demo  # noqa: E402

router, broker_a, broker_b, container_a = [a.rstrip("/") for a in sys.argv[1:5]]
NAME, TABLE = "fi_reg_ix", "fi_reg_docs"
failures = []


def check(name, cond, detail=""):
    print(("ok   " if cond else "FAIL ") + name + ("" if cond else "  " + str(detail)[:300]))
    if not cond:
        failures.append(name)


def call(base, path, body, timeout=600):
    req = urllib.request.Request(base + "/fractalsql/" + path, data=json.dumps(body).encode(),
                                 headers={"Content-Type": "application/json"}, method="POST")
    try:
        return json.loads(urllib.request.urlopen(req, timeout=timeout).read())
    except urllib.error.HTTPError as e:
        return {"error": e.read().decode()[:300]}
    except Exception as e:
        return {"error": repr(e)}


def names(base):
    return [i.get("name") for i in (call(base, "index", {"action": "list"}).get("indexes") or [])]


def wait_for(fn, seconds=60):
    end = time.time() + seconds
    while time.time() < end:
        if fn():
            return True
        time.sleep(3)
    return fn()


def wait_health(base, seconds=240):
    def up():
        try:
            return urllib.request.urlopen(base + "/fractalsql/health", timeout=3).status == 200
        except Exception:
            return False
    return wait_for(up, seconds)


def restart_a():
    subprocess.run(["docker", "restart", container_a], check=True, capture_output=True)
    return wait_health(broker_a)


rows = []
for i in range(24):
    t = 2 * math.pi * i / 24
    v = [round(math.cos(t), 3), round(math.sin(t), 3)] + [round(0.01 * ((i * 7 + j) % 5), 3) for j in range(6)]
    rows.append({"id": i + 1, "embedding": ",".join(str(x) for x in v)})
task = router + "/druid/v2/sql/task"
run_demo.run_write(run_demo.fixture_sql(TABLE, {"rows": rows}), router + "/druid/v2/sql", task, {})
QUERY = "[1.0,0.0,0.0,0.0,0.0,0.0,0.0,0.0]"
try:
    for base in (broker_a, broker_b):
        if NAME in names(base):
            call(base, "index", {"action": "drop", "name": NAME})
    made = call(broker_a, "index", {"action": "create", "table": TABLE, "column": "embedding",
                                    "options": {"name": NAME, "id_col": "id", "vector_format": "INT8", "nlist": 4, "seed": 7}})
    check("the index is built on broker A", made.get("error") is None and made.get("state") == "ready", made)
    check("broker A lists it", NAME in names(broker_a))
    check("broker B lists it (rebuilt from the datasources)", wait_for(lambda: NAME in names(broker_b)), names(broker_b))
    s = call(broker_b, "index", {"action": "search", "table": TABLE, "column": "embedding", "query": QUERY, "k": 3, "options": {"nprobe": 2}})
    check("broker B searches through it", s.get("error") is None and s.get("rows_scanned") is not None, s)
    before = {i["name"]: i for i in call(broker_a, "index", {"action": "list"}).get("indexes", [])}
    check("broker A restarts", restart_a())
    after = {i["name"]: i for i in call(broker_a, "index", {"action": "list"}).get("indexes", [])}
    check("after the restart broker A lists the same index", NAME in after, list(after))
    if NAME in after and NAME in before:
        check("the restarted index has the same shape and rows", all(after[NAME].get(k) == before[NAME].get(k) for k in ("generation", "rows", "dim", "format", "nlist", "source_table")),
              (before[NAME], after[NAME]))
    info = call(broker_a, "index", {"action": "info", "name": NAME})
    check("after the restart the index reports ready", info.get("status") == "ready", info)
    s = call(broker_a, "index", {"action": "search", "table": TABLE, "column": "embedding", "query": QUERY, "k": 3, "options": {"nprobe": 2}})
    check("after the restart the search goes through the index", s.get("error") is None and s.get("rows_scanned") is not None and s.get("rows_scanned") < 24, s)
    d = call(broker_a, "index", {"action": "drop", "name": NAME})
    check("the drop is accepted", d.get("error") is None, d)
    check("broker B sees the drop", wait_for(lambda: NAME not in names(broker_b), 60), names(broker_b))
    check("broker A restarts again", restart_a())
    check("a dropped index stays dropped after a restart", NAME not in names(broker_a), names(broker_a))
finally:
    for base in (broker_a, broker_b):
        try:
            if NAME in names(base):
                call(base, "index", {"action": "drop", "name": NAME})
        except Exception:
            pass
print("failed: %d" % len(failures))
sys.exit(1 if failures else 0)
