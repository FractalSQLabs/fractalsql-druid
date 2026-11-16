#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
# SPDX-FileCopyrightText: 2026 Daniel Gardiner d/b/a FractalSQLabs
"""Every function in the registry, called with ordinary and with junk arguments.

usage: calls_all.py SOCKET KEYFILE FUNCTIONS_DEF

A wrong call may be refused or answer NULL; it must never take the daemon down or leave a connection hanging. After each function the
daemon is asked a question, so a crash is pinned to the function that caused it.
"""
import re
import sys

import fsq_client as fc

sock, keyfile, defs = sys.argv[1:4]
key = fc.load_key(keyfile)
names = re.findall(r"^X\((fractal_[a-z0-9_]+)", open(defs).read(), re.M)
SKIP = {"fractal_lock_destructive"}   # a one-way latch: it would refuse the destructive calls that come after it

VEC, VEC2 = "[1,2,3,4]", "[4,3,2,1]"
ARGS = [
    (), (VEC,), (VEC, VEC2), (VEC, VEC2, 2), (VEC, 2), (VEC, 2, 1.5), (VEC, VEC2, 2, 8, 2),
    ("1,2,3,4,5,6,7,8", 3), ("1,2,3,4,5,6,7,8", "0.5,0,0,0.5", 2),
    ("x",), ("x", "y"), ("", ""), (None,), (None, None), ("[1,2,",), ("{}",), ("SELECT 1",), ("SELECT 1", "x", "y"),
    (1,), (1, 2), (1, 2, 3), (-1, 0), (0, 0, 0, 0), (2 ** 40, 2 ** 40),
    (1, "hello"), (1, "a", "b"), (1, "a", "b", "c"), (1, "count the rows", "table t(a, b)", "Apache Druid SQL"),
    ("a" * 70000,), (VEC * 4000,), ("nan,inf,-inf",), ("[1e308,1e308]", "[1e308,-1e308]"),
]
failures = []


def alive():
    try:
        c = fc.Client(sock, key, timeout=10)
        st, v = c.call("fractal_version")
        c.close()
        return st == 0 and v
    except Exception:
        return False


calls = 0
for name in names:
    if name in SKIP:
        continue
    for args in ARGS:
        try:
            c = fc.Client(sock, key, timeout=20)
            c.call(name, *args)
            c.close()
        except Exception:
            pass   # a dropped or refused connection is an answer; a dead daemon is not (checked below)
        calls += 1
    if not alive():
        failures.append(name)
        print("FAIL the daemon did not survive %s" % name)
        break

print("%d calls over %d functions" % (calls, len(names) - len(SKIP & set(names))))
print("\n%d failure(s)" % len(failures))
sys.exit(1 if failures else 0)
