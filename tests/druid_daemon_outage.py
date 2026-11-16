#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
# SPDX-FileCopyrightText: 2026 Daniel Gardiner d/b/a FractalSQLabs
"""A daemon outage on a running stack: Druid keeps answering, and the calls recover with no restart.

usage: druid_daemon_outage.py ROUTER_URL BROKER_URL DAEMON_CONTAINER

Stops the fractalsqld container, checks what a Druid user sees, starts it again, and checks the same calls
work without restarting the broker. The container is started again even when a check fails.
"""
import json
import subprocess
import sys
import time
import urllib.error
import urllib.request

router, broker, daemon = [a.rstrip("/") for a in sys.argv[1:4]]
failures = []


def check(name, cond, detail=""):
    print(("ok   " if cond else "FAIL ") + name + ("" if cond else "  " + str(detail)[:300]))
    if not cond:
        failures.append(name)


def q(sql, base=None, timeout=90):
    """The first cell of the first row, or a RuntimeError carrying the server's message."""
    req = urllib.request.Request((base or router) + "/druid/v2/sql",
                                 data=json.dumps({"query": sql, "resultFormat": "array"}).encode(),
                                 headers={"Content-Type": "application/json"})
    try:
        rows = json.loads(urllib.request.urlopen(req, timeout=timeout).read())
    except urllib.error.HTTPError as e:
        return RuntimeError(e.read().decode()[:400])
    except Exception as e:  # a timeout or a refused connection
        return RuntimeError(repr(e))
    return rows[0][0] if rows else None


def embeds():
    v = q("SELECT FRACTAL_EMBED('hello')")
    return isinstance(v, str) and v.startswith("[")


def post(path, body, timeout=90):
    req = urllib.request.Request(broker + path, data=json.dumps(body).encode(),
                                 headers={"Content-Type": "application/json"})
    try:
        with urllib.request.urlopen(req, timeout=timeout) as r:
            return r.status, r.read()[:300]
    except urllib.error.HTTPError as e:
        return e.code, e.read()[:300]
    except Exception as e:
        return 0, repr(e).encode()


def docker(*args):
    return subprocess.run(["docker", *args], capture_output=True, text=True, timeout=120)


# 1. before: the daemon answers
check("before: FRACTAL_EMBED goes through the daemon", embeds(), q("SELECT FRACTAL_EMBED('hello')"))
r = q("SELECT FRACTAL_REASON('hello', '{}')")
check("before: FRACTAL_REASON goes through the daemon", isinstance(r, str) and r.strip() != "", r)
q("SELECT FRACTAL_CONFIG_SET('think', 'low', 'outage-session')")

try:
    # 2. stop it
    stopped = docker("stop", daemon)
    check("stopped the daemon", stopped.returncode == 0, stopped.stderr)
    time.sleep(2)

    t0 = time.time()
    r = q("SELECT FRACTAL_EMBED('hello')")
    check("a daemon-backed SQL call returns NULL quickly, not a hang or a crash", r is None and time.time() - t0 < 30, (time.time() - t0, r))
    check("FRACTAL_REASON returns NULL too", q("SELECT FRACTAL_REASON('hello', '{}')") is None)
    check("functions that need no daemon still work", q("SELECT FRACTAL_VECTOR_NORM('[3,4]')") == 5.0)
    check("the extension still reports its version", isinstance(q("SELECT FRACTAL_VERSION()"), str))
    n = q("SELECT COUNT(*) FROM sys.servers")
    check("an ordinary Druid query is unaffected", isinstance(n, int) and n > 0, n)
    t0 = time.time()
    st, body = post("/fractalsql/reason", {"query": "hello", "context": "{}"})
    check("the reasoning endpoint answers with an error, not a hang", st != 200 and st != 0 and time.time() - t0 < 60, (st, body))
finally:
    # 3. start it again, whatever happened above
    started = docker("start", daemon)
check("started the daemon", started.returncode == 0, started.stderr)

# 4. the same broker recovers with no restart
deadline = time.time() + 120
ok = False
while time.time() < deadline:
    if embeds():
        ok = True
        break
    time.sleep(3)
check("FRACTAL_EMBED recovers when the daemon is back, with no broker restart", ok, q("SELECT FRACTAL_EMBED('hello')"))
r = q("SELECT FRACTAL_REASON('hello', '{}')")
check("FRACTAL_REASON recovers too", isinstance(r, str) and r.strip() != "", r)
check("a stateful call works again (session settings)", q("SELECT FRACTAL_CONFIG_SET('think', 'low', 'outage-session')") == "ok")

print("\n%d failure(s)" % len(failures))
sys.exit(1 if failures else 0)
