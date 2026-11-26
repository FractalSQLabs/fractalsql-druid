#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
# SPDX-FileCopyrightText: 2026 Daniel Gardiner d/b/a FractalSQLabs
"""The multi-host layout: two brokers, each with a daemon of its own.

usage: druid_multihost.py ROUTER_URL BROKER_A_URL BROKER_B_URL DAEMON_B_CONTAINER

Checks that both brokers are in the cluster and answer through their own daemon; that stopping one daemon
affects only the broker beside it, and that broker still answers everything that needs no daemon; and that
it recovers when its daemon comes back.
"""
import json
import subprocess
import sys
import time
import urllib.error
import urllib.request

router, broker_a, broker_b, daemon_b = [a.rstrip("/") for a in sys.argv[1:5]]
failures = []


def check(name, cond, detail=""):
    print(("ok   " if cond else "FAIL ") + name + ("" if cond else "  " + str(detail)[:300]))
    if not cond:
        failures.append(name)


def q(base, sql, timeout=60):
    """The first cell of the first row, or a RuntimeError carrying the server's message."""
    req = urllib.request.Request(base + "/druid/v2/sql",
                                 data=json.dumps({"query": sql, "resultFormat": "array"}).encode(),
                                 headers={"Content-Type": "application/json"})
    try:
        rows = json.loads(urllib.request.urlopen(req, timeout=timeout).read())
    except urllib.error.HTTPError as e:
        return RuntimeError(e.read().decode()[:400])
    except Exception as e:  # a timeout or a refused connection
        return RuntimeError(repr(e))
    return rows[0][0] if rows else None


def embeds(base):
    v = q(base, "SELECT FRACTAL_EMBED('hello')")
    return isinstance(v, str) and v.startswith("[")


def docker(*args):
    return subprocess.run(["docker", *args], capture_output=True, text=True, timeout=120)


# 1. both brokers are in the cluster
deadline = time.time() + 120
brokers = 0
while time.time() < deadline:
    n = q(router, "SELECT COUNT(*) FROM sys.servers WHERE server_type = 'broker'")
    brokers = n if isinstance(n, int) else 0
    if brokers >= 2:
        break
    time.sleep(3)
check("the cluster has two brokers", brokers == 2, brokers)

# 2. each broker answers through its own daemon
for name, base in (("broker A", broker_a), ("broker B", broker_b)):
    check(name + ": FRACTAL_EMBED goes through its daemon", embeds(base), q(base, "SELECT FRACTAL_EMBED('hello')"))
    r = q(base, "SELECT FRACTAL_REASON('hello', '{}')")
    check(name + ": FRACTAL_REASON goes through its daemon", "mock provider" in str(r), r)
check("the router answers SQL", q(router, "SELECT FRACTAL_VECTOR_NORM('[3,4]')") == 5.0)

# 3. through the router: it spreads SQL over both brokers, each answering through its own daemon
# The daemons are told apart by their reasoning model (the compose file gives the second one its own name).
model_a = q(broker_a, "SELECT FRACTAL_CONFIG_GET('reasoning_model', 'lb')")
model_b = q(broker_b, "SELECT FRACTAL_CONFIG_GET('reasoning_model', 'lb')")
if isinstance(model_a, str) and isinstance(model_b, str) and model_a != model_b:
    seen = {}
    for _ in range(40):
        v = q(router, "SELECT FRACTAL_CONFIG_GET('reasoning_model', 'lb')")
        seen[str(v)] = seen.get(str(v), 0) + 1
    print("     router spread over 40 queries: " + ", ".join("%s x%d" % (k, n) for k, n in sorted(seen.items())))
    check("router: every query was answered", set(seen) <= {model_a, model_b}, seen)
    check("router: both brokers took part, each through its own daemon", set(seen) == {model_a, model_b}, seen)
else:
    print("skip router spread: the two daemons are not told apart (set FSQLD_REASONING_MODEL_B)")
try:
    status = urllib.request.urlopen(router + "/fractalsql/health", timeout=10).status
except urllib.error.HTTPError as e:
    status = e.code
except Exception:
    status = 0
check("router: /fractalsql is not forwarded (call a broker for the service endpoints)", status != 200, status)

# state belongs to a daemon: a session setting made through broker A is not seen through broker B
q(broker_a, "SELECT FRACTAL_CONFIG_SET('t2s_max_attempts', '7', 'mh-session')")
check("broker A: a session setting is kept by its daemon", q(broker_a, "SELECT FRACTAL_CONFIG_GET('t2s_max_attempts', 'mh-session')") == "7")
check("broker B: it does not see broker A's session setting", q(broker_b, "SELECT FRACTAL_CONFIG_GET('t2s_max_attempts', 'mh-session')") != "7")

# 3b. the vectorizer registry belongs to a broker, and the embedding happens through that broker's own daemon
import os
sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "demo"))
import run_demo as rd  # noqa: E402


def vpost(base, body):
    req = urllib.request.Request(base + "/fractalsql/vectorizer", data=json.dumps(body).encode(),
                                 headers={"Content-Type": "application/json"})
    try:
        with urllib.request.urlopen(req, timeout=300) as r:
            return r.status, json.loads(r.read() or b"null")
    except urllib.error.HTTPError as e:
        try:
            return e.code, json.loads(e.read() or b"null")
        except ValueError:
            return e.code, None


VEC = "mh_vec_%d" % int(time.time())
wsql = ('REPLACE INTO "%s" OVERWRITE ALL SELECT TIMESTAMP \'2026-01-01\' AS "__time", "id", "body" '
        'FROM (VALUES (1, \'first doc\'), (2, \'second doc\'), (3, \'third doc\')) AS t("id", "body") PARTITIONED BY ALL' % VEC)
rd.run_write(wsql, router + "/druid/v2/sql", router + "/druid/v2/sql/task", {"arrayIngestMode": "array"})
rd.wait_for_datasource(wsql, router, 180)
spec = {"action": "create", "source_table": VEC, "source_column": "body", "embedding_column": "embedding", "id_column": "id"}
st, ra = vpost(broker_a, spec)
check("broker A: a vectorizer is created", st == 200 and ra.get("id"), (st, ra))
st, rb = vpost(broker_b, {"action": "status", "id": ra.get("id", 0)})
check("broker B: it does not know broker A's vectorizer (the registry is per broker)", st == 400, (st, rb))
st, rb = vpost(broker_b, spec)
check("broker B: the same vectorizer is created in its own registry", st == 200 and rb.get("id"), (st, rb))
st, r = vpost(broker_a, {"action": "process_queue", "batch_size": 2})
mine_a = [x for x in (r or {}).get("rows", []) if x.get("vectorizer_id") == ra.get("id")]
check("broker A embeds two rows through its daemon", st == 200 and len(mine_a) == 2, (st, r))
# Druid ingests the embeddings asynchronously: broker B can only see (and so skip) the rows broker A embedded once they have landed
# in the companion datasource. Without this wait B reads an empty datasource and embeds all three rows again.
end = time.time() + 180
while time.time() < end and q(router, 'SELECT COUNT(*) FROM "%s_embeddings"' % VEC) != 2:
    time.sleep(3)
st, r = vpost(broker_b, {"action": "process_queue", "batch_size": 10})
mine_b = [x for x in (r or {}).get("rows", []) if x.get("vectorizer_id") == rb.get("id")]
check("broker B embeds only the row broker A left, through its own daemon", st == 200 and len(mine_b) == 1, (st, r))
time.sleep(2)
n = q(router, 'SELECT COUNT(*) FROM "%s_embeddings"' % VEC)
check("the companion datasource holds each row once", n == 3, n)
vpost(broker_a, {"action": "drop", "id": ra.get("id", 0)})
vpost(broker_b, {"action": "drop", "id": rb.get("id", 0)})

# 4. stop broker B's daemon: only broker B loses the daemon-backed functions
stopped = docker("stop", daemon_b)
check("stopped the second daemon", stopped.returncode == 0, stopped.stderr)
time.sleep(2)
t0 = time.time()
r = q(broker_b, "SELECT FRACTAL_EMBED('hello')", timeout=90)
took = time.time() - t0
# The Cognition functions return NULL when the daemon cannot be reached, so one failed row does not fail the query.
check("broker B: a daemon-backed call returns NULL quickly, not a hang or a crash", r is None and took < 30, (took, r))
r = q(broker_b, "SELECT FRACTAL_REASON('hello', '{}')", timeout=90)
check("broker B: FRACTAL_REASON returns NULL too", r is None, r)
check("broker B: functions that need no daemon still work", q(broker_b, "SELECT FRACTAL_VECTOR_NORM('[3,4]')") == 5.0)
check("broker B: the extension still reports its version", q(broker_b, "SELECT FRACTAL_VERSION()") == "2.0.0")
check("broker A: unaffected, still embeds through its own daemon", embeds(broker_a))

# 5. start it again: broker B recovers without a restart
started = docker("start", daemon_b)
check("started the second daemon", started.returncode == 0, started.stderr)
deadline = time.time() + 90
ok = False
while time.time() < deadline:
    if embeds(broker_b):
        ok = True
        break
    time.sleep(3)
check("broker B: recovers when its daemon is back", ok, q(broker_b, "SELECT FRACTAL_EMBED('hello')"))

print("\n%d failure(s)" % len(failures))
sys.exit(1 if failures else 0)
