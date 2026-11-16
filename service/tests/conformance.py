#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
# SPDX-FileCopyrightText: 2026 Daniel Gardiner d/b/a FractalSQLabs
"""Protocol conformance checks for a running fractalsqld (C or JVM).

usage: conformance.py SOCKET KEYFILE [DAEMON_LOG]
"""
import sys
import threading
import time

import fsq_client as fc

sock, keyfile = sys.argv[1], sys.argv[2]
log = sys.argv[3] if len(sys.argv) > 3 else None
key = fc.load_key(keyfile)
failures = []


def check(name, cond, detail=""):
    print(("ok   " if cond else "FAIL ") + name + ("" if cond else "  " + str(detail)))
    if not cond:
        failures.append(name)


def client():
    return fc.Client(sock, key)


c = client()
r = c.request(fc.OP_PING)
check("ping answers protocol 2", r.status == 0 and r.body == b"\x02\x00", r.body)
r = c.request(fc.OP_VERSION)
check("version names the daemon", r.status == 0 and r.text().startswith("fractalsqld "), r.text())

st, v = c.call("fractal_version")
check("fractal_version returns a version", st == 0 and v and v[0].isdigit(), (st, v))
st, v = c.call("fractal_edition")
check("fractal_edition returns an edition", st == 0 and v in ("Community", "Enterprise"), (st, v))
st, v = c.call("fractal_no_such_function")
check("an unknown function is NOTSUP", st == fc.NOTSUP, (st, v))
st, v = c.call("fractal_dimension_dfa", "1,2,3,4", 5)
check("a wrong argument count is ARGS with the adapter's message", st == fc.ARGS and "expected" in v, (st, v))
st, v = c.call("fractal_vector_dims", "[1,2,3]")
check("an integer result comes back as an integer", st == 0 and v == 3, (st, v))
st, v = c.call("fractal_vector_norm", "[3,4]")
check("a real result comes back as a real", st == 0 and abs(v - 5.0) < 1e-9, (st, v))

# A handle belongs to its connection.
h, _ = c.init("fractal_version")
other = client()
rr = other.call_handle("fractal_version", h)
check("another connection cannot use a handle", rr.status == fc.ARGS, rr.status)
# A cancel from a second connection marks the handle: the next call is BUSY, once.
rc = other.cancel(h)
check("a cancel from another connection is accepted", rc.status == 0, rc.status)
b1 = c.call_handle("fractal_version", h)
check("the call after a cancel is BUSY", b1.status == fc.BUSY, b1.status)
b2 = c.call_handle("fractal_version", h)
check("the cancel is one-shot", b2.status == 0, b2.status)
check("cancel of an unknown handle is ARGS", other.cancel(2 ** 40).status == fc.ARGS)
c.deinit(h)
other.close()

# An idempotency token replays the cached reply.
tok = 0x5eed0000 + int(time.time()) % 100000
a = c.call("fractal_config_get", "think_provider", 1, token=tok)
b = c.call("fractal_config_get", "think_provider", 1, token=tok)
check("a call with a token succeeds", a[0] == 0, a)
check("a resend with the same token returns the same reply", a == b, (a, b))
if log:
    time.sleep(0.3)
    check("the resend was served from the cache", "idempotency cache" in open(log, errors="replace").read())

# Parallel connections, each running its own calls.
errs = []


def worker():
    try:
        w = client()
        for _ in range(25):
            s, val = w.call("fractal_vector_norm", "[3,4]")
            if s != 0 or abs(val - 5.0) > 1e-9:
                errs.append((s, val))
        w.close()
    except Exception as e:  # noqa: BLE001
        errs.append(e)


ts = [threading.Thread(target=worker) for _ in range(8)]
[t.start() for t in ts]
[t.join() for t in ts]
check("8 connections x 25 calls in parallel", not errs, errs[:2])

# Authentication: a bad tag closes the connection.
bad = client()
try:
    bad.request(fc.OP_PING, bad_tag=True)
    closed = False
except (ConnectionError, OSError):
    closed = True
check("a bad HMAC tag closes the connection", closed)

# A reload with no change succeeds.
r = c.request(fc.OP_RELOAD)
check("reload with no change", r.status == 0 and r.text() == "reloaded", r.text())
r = c.request(fc.OP_RELOAD, b"x")
check("reload with a payload is refused", r.status == fc.ARGS, r.status)

c.close()
print("\n%d failure(s)" % len(failures))
sys.exit(1 if failures else 0)
