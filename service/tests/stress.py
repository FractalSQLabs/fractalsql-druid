#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
# SPDX-FileCopyrightText: 2026 Daniel Gardiner d/b/a FractalSQLabs
"""Concurrent, mixed use of the daemon, with the answers checked.

usage: stress.py SOCKET KEYFILE [enterprise] [seconds]

The daemon's own gates use one connection at a time. This one is the
adversarial version: many threads, each with its own connections, all
using the same shared state -- the session registry, the diversifier, the
per-session configuration overlay, the ledger -- at once, while the
daemon is also reloaded and its connections are churned.

What it asserts, and not only that nothing crashed:

  * every call finishes inside a bound (a watchdog fails the run, and
    prints the threads' stacks, if progress stops);
  * the audit chain is exact: after N acknowledged audit_log calls, the
    ledger verifies and reports exactly the rows the run wrote;
  * the session state is coherent: a value one connection sets is
    another connection's to read, until the session is reset;
  * the daemon is still serving at the end.

The run is bounded by time (default 60 s) and by a thread count (default
16), and its seed is fixed, so a failure can be reproduced.
"""
import json
import os
import random
import socket
import struct
import sys
import threading
import time

import fsq_client as fc

sock_path, keyfile = sys.argv[1:3]
enterprise = len(sys.argv) > 3 and sys.argv[3] == "enterprise"
DURATION = float(sys.argv[4]) if len(sys.argv) > 4 else float(os.environ.get("FSQL_STRESS_SECONDS", "60"))
THREADS = int(os.environ.get("FSQL_STRESS_THREADS", "16"))
KEY = fc.load_key(keyfile)

failures = []
lock = threading.Lock()
stop = threading.Event()
progress = [0]
last_progress = [time.time()]
# The audit_log calls this run got an answer for: the chain must hold
# exactly these rows (plus whatever was in the ledger before the run).
acknowledged = [0]


def fail(msg):
    with lock:
        failures.append(msg)


def bump():
    with lock:
        progress[0] += 1
        last_progress[0] = time.time()


def watchdog():
    """Fails the run if the threads stop making progress for 20 s."""
    while not stop.is_set():
        time.sleep(1.0)
        with lock:
            idle = time.time() - last_progress[0]
        if idle > 20:
            fail("no progress for %.0f s -- the daemon is wedged" % idle)
            for name, frame in sys._current_frames().items():
                print("    thread %s:" % name)
                import traceback
                traceback.print_stack(frame, limit=8)
            stop.set()
            return


def client(timeout=30):
    return fc.Client(sock_path, KEY, timeout=timeout)


# ---- the workloads --------------------------------------------------------

def workload_config(worker):
    """The per-session configuration overlay, from several connections at once."""
    rnd = random.Random(worker)
    sid = 100 + worker
    while not stop.is_set():
        try:
            c = client()
            try:
                for _ in range(8):
                    if stop.is_set():
                        break
                    op = rnd.choice(["set", "get", "get", "list", "reset", "keys"])
                    if op == "set":
                        c.call("fractal_config_set", "think", rnd.choice(["off", "medium", "high"]), sid)
                    elif op == "get":
                        c.call("fractal_config_get", "think", sid)
                    elif op == "list":
                        c.call("fractal_config_list", sid)
                    elif op == "keys":
                        c.call("fractal_config_keys")
                    else:
                        c.call("fractal_config_reset", sid)
                    bump()
            finally:
                c.close()
        except Exception as e:
            fail("config worker %d: %s" % (worker, e))
            time.sleep(0.1)


def workload_session(worker):
    """The session tier: the diversifier, the feedback hook, the agent hook."""
    rnd = random.Random(1000 + worker)
    sid = 200 + worker
    while not stop.is_set():
        try:
            c = client()
            try:
                for _ in range(6):
                    if stop.is_set():
                        break
                    c.call("fractal_diversify_enable", sid)
                    c.call("fractal_diversify_set_params", sid,
                           '{"window_n":8,"stall_threshold":0.1,"repulsion_sigma":0.5,'
                           '"repulsion_weight":0.3,"max_shadows_considered":4,"tail_buffer_cap":16}')
                    c.call("fractal_search", "[[1,2,3,4],[4,3,2,1]]", "[1,2,3,4]", 2,
                           '{"session_id":%d,"iterations":8,"seed":1}' % sid)
                    c.call("fractal_detect_collapse", sid)
                    c.call("fractal_explain_result", sid)
                    c.call("fractal_feedback_report", sid, 1, rnd.choice(["positive", "negative"]))
                    c.call("fractal_agent_partial_fail", sid, "off")
                    c.call("fractal_isolate_background", sid, 1)
                    c.call("fractal_diversify_disable", sid)
                    bump()
            finally:
                c.close()
        except Exception as e:
            fail("session worker %d: %s" % (worker, e))
            time.sleep(0.1)


def workload_churn(worker):
    """Connections that end badly: an abrupt disconnect, half a frame."""
    rnd = random.Random(2000 + worker)
    while not stop.is_set():
        try:
            if rnd.random() < 0.5:
                # A connection that is dropped without a clean close.
                s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
                s.settimeout(5)
                s.connect(sock_path)
                s.close()
            else:
                # A connection that sends half a frame and goes away.
                s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
                s.settimeout(5)
                s.connect(sock_path)
                s.sendall(b"FSQ1" + struct.pack("<HHIIQII", 2, 0x11, 0, 1, 0, 32, 64)[:16])
                s.close()
            bump()
        except Exception:
            pass
        time.sleep(0.02)


def workload_provider(worker):
    """The provider-backed calls, against the mock provider."""
    rnd = random.Random(3000 + worker)
    sid = 300 + worker
    while not stop.is_set():
        try:
            c = client(timeout=20)
            try:
                for _ in range(2):
                    if stop.is_set():
                        break
                    c.call("fractal_reason", sid, "say something")
                    c.call("fractal_embed", sid, "a few words")
                    c.call("fractal_t2s_generate", sid, "count the rows", "table t(a int)", "Apache Druid SQL")
                    bump()
            finally:
                c.close()
        except Exception as e:
            # A provider call that fails is not a failure of the daemon.
            pass
        time.sleep(0.05)


def workload_ledger(worker):
    """The audit chain: acknowledged writes, verified while more are written."""
    rnd = random.Random(4000 + worker)
    sid = 400 + worker
    while not stop.is_set():
        try:
            c = client()
            try:
                for _ in range(4):
                    if stop.is_set():
                        break
                    payload = json.dumps({"worker": worker, "n": rnd.randint(0, 1000)})
                    st, _v = c.call("fractal_audit_log", "stress", payload, 1, "ci")
                    if st == 0:
                        with lock:
                            acknowledged[0] += 1
                    bump()
                    if rnd.random() < 0.2:
                        c.call("fractal_ledger_verify", 1, 2)
                        c.call("fractal_ledger_truth_count", 1)
                        c.call("fractal_ledger_shadow_count", 1)
            finally:
                c.close()
        except Exception as e:
            fail("ledger worker %d: %s" % (worker, e))
            time.sleep(0.1)


def workload_reload(worker):
    """The configuration reloaded while the other workers are calling."""
    time.sleep(1.0)
    while not stop.is_set():
        time.sleep(3.0)
        if stop.is_set():
            break
        try:
            import subprocess
            subprocess.run([os.environ.get("FSQLCTL_BIN", "fsqlctl"), "reload"],
                         env=dict(os.environ,
                         FSQLCTL_SOCKET=sock_path, FSQLCTL_KEY=keyfile),
                         stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, timeout=10)
            bump()
        except Exception:
            pass


# ---- the checks that need the run to be over ------------------------------

def check_audit_exact():
    """The chain verifies, and it holds exactly the rows this run wrote."""
    if not enterprise:
        return
    before = int(os.environ.get("FSQL_STRESS_LEDGER_BEFORE", "0"))
    c = client()
    try:
        st, v = c.call("fractal_ledger_verify", 1, 2)
        if st != 0 or v is None:
            fail("the audit chain does not verify after the stress run: %r" % (v,))
            return
        d = json.loads(v)
        if not d.get("ok"):
            fail("the audit chain does not verify after the stress run: %r" % (v,))
            return
        rows = d.get("rows_verified")
        if rows is None:
            fail("the verification does not say how many rows it verified: %r" % (v,))
            return
        want = before + acknowledged[0]
        if rows != want:
            fail("the chain holds %d row(s) and the run got an answer for %d write(s) (%d before it)"
                 % (rows, acknowledged[0], before))
    finally:
        c.close()


def check_session_coherence():
    """A value one connection sets is another connection's to read."""
    a = client()
    b = client()
    try:
        sid = 987654
        st, v = a.call("fractal_config_reset", sid)
        if st != 0:
            fail("a session reset did not answer")
            return
        a.call("fractal_config_set", "think", "high", sid)
        st, v = b.call("fractal_config_get", "think", sid)
        if st != 0 or v != "high":
            fail("a value set on one connection is not readable on another: %r" % (v,))
        st, v = a.call("fractal_config_reset", sid)
        if st != 0:
            fail("the session reset did not answer")
        st, v = b.call("fractal_config_get", "think", sid)
        if st != 0 or v is not None:
            fail("the session was not reset: %r" % (v,))
    finally:
        a.close()
        b.close()


def check_still_serving():
    c = client()
    try:
        st, v = c.call("fractal_version")
        if st != 0 or not v:
            fail("the daemon does not answer after the stress run: %r" % (v,))
    finally:
        c.close()


def main():
    rnd = random.Random(7)
    workers = []
    for w in range(THREADS):
        kind = w % 5
        if kind == 0:
            t = threading.Thread(target=workload_config, args=(w,))
        elif kind == 1:
            t = threading.Thread(target=workload_session, args=(w,))
        elif kind == 2:
            t = threading.Thread(target=workload_churn, args=(w,))
        elif kind == 3:
            t = threading.Thread(target=workload_provider, args=(w,))
        else:
            t = threading.Thread(target=workload_ledger, args=(w,))
        t.daemon = True
        workers.append(t)
    workers.append(threading.Thread(target=workload_reload, args=(0,), daemon=True))
    workers.append(threading.Thread(target=watchdog, daemon=True))

    started = time.time()
    for t in workers:
        t.start()
    while time.time() - started < DURATION:
        time.sleep(0.5)
    stop.set()
    for t in workers:
        t.join(timeout=10)

    check_session_coherence()
    check_audit_exact()
    check_still_serving()

    print("%d call(s) in %.0f s, %d failure(s)" % (progress[0], time.time() - started, len(failures)))
    for f in failures[:20]:
        print("FAIL " + f)
    return 1 if failures else 0


if __name__ == "__main__":
    sys.exit(main())
