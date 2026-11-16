#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
# SPDX-FileCopyrightText: 2026 Daniel Gardiner d/b/a FractalSQLabs
"""The warning for a DRUID_URL that does not serve /fractalsql, against mock_druid.py.

With DRUID_FRACTALSQL_URL unset, an extension call answered 404 or 405 makes the server print one
WARN line on stderr, and only one however many calls follow. A different status (500), a
DRUID_FRACTALSQL_URL that is set to another address, and a healthy endpoint print nothing.

usage: druid_service_warning.py PATH_TO_SERVER
"""
import json
import os
import subprocess
import sys
import urllib.request

here = os.path.dirname(os.path.abspath(__file__))
binary = sys.argv[1]
failures = []
MARK = "WARN: an extension call to"
ARGS = {"mu": [0.1, 0.2, 0.3], "cov": [1, 0, 0, 0, 1, 0, 0, 0, 1], "cardinality": 2}


def check(name, cond, detail=""):
    print(("ok   " if cond else "FAIL ") + name + ("" if cond else "  " + str(detail)[:300]))
    if not cond:
        failures.append(name)


mock = subprocess.Popen([sys.executable, "-I", os.path.join(here, "mock_druid.py"), "0"], stdout=subprocess.PIPE, text=True)
port = int(mock.stdout.readline())
url = "http://127.0.0.1:%d" % port


def mode(name):
    urllib.request.urlopen(url + "/_mode/" + name, timeout=5).read()


def run(mode_name, calls, extra_env=None):
    """Start the server, make `calls` extension calls, return (stderr lines with the marker, last result)."""
    mode(mode_name)
    env = dict(os.environ, DRUID_URL=url)
    env.pop("DRUID_FRACTALSQL_URL", None)
    env.update(extra_env or {})
    p = subprocess.Popen([binary], stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE, env=env, text=True)
    last = None
    try:
        def rpc(i, method, params=None):
            p.stdin.write(json.dumps({"jsonrpc": "2.0", "id": i, "method": method, "params": params or {}}) + "\n")
            p.stdin.flush()
            return json.loads(p.stdout.readline())
        rpc(0, "initialize", {"protocolVersion": "2024-11-05", "capabilities": {}, "clientInfo": {"name": "t", "version": "1"}})
        for i in range(1, calls + 1):
            last = rpc(i, "tools/call", {"name": "fractal_agent_allocate", "arguments": ARGS})
    finally:
        p.stdin.close()
        err = p.stderr.read()
        p.wait(timeout=20)
    return [l for l in err.splitlines() if MARK in l], last


w, last = run("svc404", 3)
check("404 from /fractalsql/* warns exactly once over three calls", len(w) == 1, w)
check("the warning names the status and the fix", w and "returned 404" in w[0] and "DRUID_FRACTALSQL_URL" in w[0], w)
w, _ = run("svc405", 2)
check("405 warns too", len(w) == 1 and "returned 405" in w[0], w)
w, _ = run("svc500", 2)
check("a 500 does not warn", not w, w)
w, _ = run("svc404", 2, {"DRUID_FRACTALSQL_URL": url})
check("DRUID_FRACTALSQL_URL equal to DRUID_URL still warns", len(w) == 1, w)
mock2 = subprocess.Popen([sys.executable, "-I", os.path.join(here, "mock_druid.py"), "0"], stdout=subprocess.PIPE, text=True)
url2 = "http://127.0.0.1:%d" % int(mock2.stdout.readline())
w, last = run("svc404", 2, {"DRUID_FRACTALSQL_URL": url2})
check("a separate DRUID_FRACTALSQL_URL that serves the endpoints does not warn", not w, w)
mock2.kill()
w, _ = run("ok", 2)
check("a healthy endpoint does not warn", not w, w)
mock.kill()
print("%d failure(s)" % len(failures))
sys.exit(1 if failures else 0)
