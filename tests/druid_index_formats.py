#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
# SPDX-FileCopyrightText: 2026 Daniel Gardiner d/b/a FractalSQLabs
"""Every fractal_index vector_format on Druid, and the wide-vector cases.

usage: druid_index_formats.py ROUTER_URL BROKER_URL BROKER_CONTAINER

For INT8, INT4, FP16 and FP32 (8-dimension, 60 rows): the index builds and reports its format, the recall@10 at every cell meets the format's
floor, every returned distance is the exact cosine, and a search at nprobe 1 goes through the index and scans fewer rows than the table.

Then the wide-vector cases: an INT8 index over 768-dimension vectors builds (its model is over a megabyte, so it is stored as parts), a rebuild
keeps the index's format, and an index can be dropped and created again under the same name; the rebuilt index survives a broker restart.
"""
import json
import math
import os
import random
import struct
import subprocess
import sys
import time
import urllib.error
import urllib.request

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.join(os.path.dirname(HERE), "demo"))
import run_demo  # noqa: E402

router, broker, container = [a.rstrip("/") for a in sys.argv[1:4]]
failures = []
SUF = str(int(time.time()))[-6:]


def check(name, cond, detail=""):
    print(("ok   " if cond else "FAIL ") + name + ("" if cond else "  " + str(detail)[:300]))
    if not cond:
        failures.append(name)


def call(path, body, timeout=900):
    req = urllib.request.Request(broker + "/fractalsql/" + path, data=json.dumps(body).encode(),
                                 headers={"Content-Type": "application/json"}, method="POST")
    try:
        return json.loads(urllib.request.urlopen(req, timeout=timeout).read())
    except urllib.error.HTTPError as e:
        return {"error": e.read().decode()[:300]}
    except Exception as e:
        return {"error": repr(e)}


def wait_for(fn, seconds=90):
    end = time.time() + seconds
    while time.time() < end:
        if fn():
            return True
        time.sleep(3)
    return fn()


def wait_health(seconds=240):
    def up():
        try:
            return urllib.request.urlopen(broker + "/fractalsql/health", timeout=3).status == 200
        except Exception:
            return False
    return wait_for(up, seconds)


def fp16(v):
    """The vector as the index stores it for the verify step: Druid's distances are exact to FP16 precision (docs/api-discovery.md)."""
    return [struct.unpack("<e", struct.pack("<e", x))[0] for x in v]


def cosine_distance(a, b):
    dot = sum(x * y for x, y in zip(a, b))
    return 1.0 - dot / (math.sqrt(sum(x * x for x in a)) * math.sqrt(sum(y * y for y in b)))


def load(table, vectors):
    rows = [{"id": i + 1, "embedding": ",".join(repr(x) for x in v)} for i, v in enumerate(vectors)]
    run_demo.run_write(run_demo.fixture_sql(table, {"rows": rows}), router + "/druid/v2/sql", router + "/druid/v2/sql/task", {})


def names():
    return [i.get("name") for i in (call("index", {"action": "list"}).get("indexes") or [])]


# ---- the four formats --------------------------------------------------------------------------------------------------------------
rng = random.Random(5)
DIM, N = 8, 60
centers = [[rng.gauss(0, 1) for _ in range(DIM)] for _ in range(6)]
vecs = [[round(x + 0.25 * rng.gauss(0, 1), 4) for x in rng.choice(centers)] for _ in range(N)]
TABLE = "fmt_docs_" + SUF
load(TABLE, vecs)
query = vecs[7]
qtxt = "[" + ",".join(repr(x) for x in query) + "]"
truth = [i + 1 for i in sorted(range(N), key=lambda i: (cosine_distance(vecs[i], query), i))[:10]]
for fmt, floor in (("INT8", 0.40), ("INT4", 0.40), ("FP16", 0.98), ("FP32", 0.99)):
    name = "fmt_%s_%s" % (fmt.lower(), SUF)
    made = call("index", {"action": "create", "table": TABLE, "column": "embedding",
                          "options": {"name": name, "id_col": "id", "vector_format": fmt, "nlist": 6, "seed": 3}})
    check("%s: the index builds and reports its format and rows" % fmt, made.get("error") is None and made.get("format") == fmt and made.get("rows") == N, made)
    if made.get("error"):
        continue
    full = call("index", {"action": "search", "table": TABLE, "column": "embedding", "query": qtxt, "k": 10, "options": {"nprobe": 6}})
    got = full.get("candidates") or []
    hit = len({int(float(c["doc_id"])) for c in got} & set(truth)) / 10.0
    check("%s: recall@10 at every cell is at least %.2f (got %.2f)" % (fmt, floor, hit), full.get("error") is None and hit >= floor, full)
    bad = [c for c in got if abs(float(c["distance"]) - cosine_distance(fp16(vecs[int(float(c["doc_id"])) - 1]), query)) > 1e-6]
    check("%s: every returned distance is the exact cosine of the FP16 vector the index verifies against" % fmt, len(got) >= 10 and not bad, bad[:2])
    few = call("index", {"action": "search", "table": TABLE, "column": "embedding", "query": qtxt, "k": 10, "options": {"nprobe": 1}})
    check("%s: a search at nprobe 1 goes through the index and scans fewer rows than the table" % fmt,
          few.get("error") is None and isinstance(few.get("rows_scanned"), int) and 0 < few["rows_scanned"] < N, few)
    call("index", {"action": "drop", "name": name})

# ---- wide vectors, rebuild and re-create ---------------------------------------------------------------------------------------------
WD, WN = 768, 24
wide = [[round(rng.gauss(0, 1), 3) for _ in range(WD)] for _ in range(WN)]
WT = "fmt_wide_" + SUF
load(WT, wide)
WNAME = "fmt_w_%s" % SUF
made = call("index", {"action": "create", "table": WT, "column": "embedding", "options": {"name": WNAME, "id_col": "id", "vector_format": "INT8", "nlist": 4}})
check("an INT8 index over 768-dimension vectors builds (its model is stored as parts)", made.get("error") is None and made.get("state") == "ready" and made.get("dim") == WD, made)
wq = "[" + ",".join(repr(x) for x in wide[3]) + "]"
s = call("index", {"action": "search", "table": WT, "column": "embedding", "query": wq, "k": 3, "options": {"nprobe": 4}})
check("...and answers a search", s.get("error") is None and len(s.get("candidates") or []) == 3, s)
reb = call("index", {"action": "rebuild", "name": WNAME})
check("a rebuild succeeds on the wide index", reb.get("error") is None and reb.get("state") == "ready", reb)
info = call("index", {"action": "info", "name": WNAME})
check("the rebuild keeps the index's format and the next generation", info.get("format") == "INT8" and info.get("generation") == 2, info)
check("the wide index survives a broker restart", (subprocess.run(["docker", "restart", container], check=True, capture_output=True) and wait_health())
      and wait_for(lambda: WNAME in names()), names())
info = call("index", {"action": "info", "name": WNAME})
check("...as generation 2 with its model intact", info.get("error") is None and info.get("generation") == 2 and info.get("status") in ("ready", "stale"), info)
s = call("index", {"action": "search", "table": WT, "column": "embedding", "query": wq, "k": 3, "options": {"nprobe": 4}})
check("...and still answers through the index", s.get("error") is None and len(s.get("candidates") or []) == 3, s)
d = call("index", {"action": "drop", "name": WNAME})
check("the wide index drops", d.get("error") is None, d)
again = call("index", {"action": "create", "table": WT, "column": "embedding", "options": {"name": WNAME, "id_col": "id", "vector_format": "FP16", "nlist": 4}})
check("an index can be created again under a dropped index's name", again.get("error") is None and again.get("state") == "ready" and again.get("format") == "FP16", again)
info = call("index", {"action": "info", "name": WNAME})
check("...and the new one is the one that is listed (FP16)", info.get("error") is None and info.get("format") == "FP16", info)
call("index", {"action": "drop", "name": WNAME})
print("failed: %d" % len(failures))
sys.exit(1 if failures else 0)
