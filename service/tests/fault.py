#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
# SPDX-FileCopyrightText: 2026 Daniel Gardiner d/b/a FractalSQLabs
"""Faults against a running daemon.

usage: fault.py SOCKET KEYFILE MODE [DAEMON_PID]
  MODE hang | garbage | error500 | truncated | empty | longerr | cycle   the provider misbehaves (see fault_llm.py)
  MODE killed                                          the daemon is killed in the middle of a call (needs DAEMON_PID)

For a provider fault, every call must come back (an error or a NULL, never a hang), the connection must stay up (a crash would drop it),
and the daemon must still answer a call afterwards.
"""
import os
import signal
import sys
import threading
import time

import fsq_client as fc

sock, keyfile, mode = sys.argv[1:4]
key = fc.load_key(keyfile)
failures = []


def check(name, cond, detail=""):
    print(("ok   " if cond else "FAIL ") + name + ("" if cond else "  " + str(detail)[:300]))
    if not cond:
        failures.append(name)


def alive():
    try:
        c = fc.Client(sock, key, timeout=10)
        st, v = c.call("fractal_vector_norm", "[3,4]")
        c.close()
        return st == 0 and v is not None and abs(float(v) - 5.0) < 1e-9
    except Exception:
        return False


if mode == "killed":
    pid = int(sys.argv[4])
    result = {}

    def long_call():
        try:
            c = fc.Client(sock, key, timeout=30)
            result["r"] = c.call("fractal_reason", 1, "this call will outlive the daemon")
        except Exception as e:
            result["e"] = e

    t = threading.Thread(target=long_call)
    t.start()
    time.sleep(1.5)
    os.kill(pid, signal.SIGKILL)
    t0 = time.time()
    t.join(20)
    check("the client is not left hanging when the daemon dies", not t.is_alive() and time.time() - t0 < 15, time.time() - t0)
    check("the client sees an error, not an answer", "e" in result or (result.get("r") and result["r"][0] != 0), result)
    sys.exit(1 if failures else 0)

calls = [
    ("fractal_reason", (1, "say something")),
    ("fractal_embed", (1, "hello")),
    ("fractal_t2s_generate", (1, "count the rows", "table t(a, b)", "Apache Druid SQL")),
    ("fractal_t2s_review", (1, "count the rows", "SELECT COUNT(*) FROM t")),
]
# The wrong-answer modes are run many times, with the session's partial-result mode on and off: the partial path answers with a
# sentinel document that carries the failure's detail, the other one with an error.
reps = {"cycle": 24, "longerr": 4}.get(mode, 1)   # a 500 is retried, so that mode is slow per call
for rep in range(reps):
    if reps > 1:
        try:
            c = fc.Client(sock, key, timeout=40)
            c.call("fractal_agent_partial_fail", 1, "on" if rep % 2 == 0 else "off")
            c.close()
        except Exception as e:
            check("provider %s: the partial-result switch (%r)" % (mode, e), False, e)
    for name, args in calls:
        t0 = time.time()
        try:
            c = fc.Client(sock, key, timeout=40)
            st, v = c.call(name, *args)
            took = time.time() - t0
            check("provider %s, %s: comes back (status %s) in %.1fs" % (mode, name, st, took), took < 30, took)
            c.close()
        except Exception as e:
            check("provider %s, %s: the daemon keeps the connection (%r)" % (mode, name, e), False, e)
check("provider %s: the daemon still answers afterwards" % mode, alive())
sys.exit(1 if failures else 0)
