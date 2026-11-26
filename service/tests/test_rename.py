#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
# SPDX-FileCopyrightText: 2026 Daniel Gardiner d/b/a FractalSQLabs
"""service/tests/test_rename.py -- the fleet-wide rename of the table-free
convergence function (gate 46).

The table-free convergence function was RENAMED fractal_search ->
fractal_sfs_converge on 2026-11-18: it runs SFS toward the query direction,
it is NOT a retrieval function. There is NO alias -- the old call fails with a
message that names the new name. The debug form is
fractal_sfs_converge_debug.

The driver talks to fractalsqld over the FSQ v2 socket, so it needs no
database and no Druid.

usage: test_rename.py SOCKET KEYFILE FUNCTIONS_DEF
"""
import sys

import fsq_client as fc

SOCK = sys.argv[1] if len(sys.argv) > 1 else None
KEYFILE = sys.argv[2] if len(sys.argv) > 2 else None
FUNCTIONS_DEF = sys.argv[3] if len(sys.argv) > 3 else None

failures = []


def check(ok, name, detail=""):
    print(("  [PASS] " if ok else "  [FAIL] ") + name + ("" if ok or not detail else ": " + str(detail)[:400]))
    if not ok:
        failures.append(name)


def main():
    if not SOCK or not KEYFILE:
        print("usage: test_rename.py SOCKET KEYFILE FUNCTIONS_DEF")
        return 2
    key = fc.load_key(KEYFILE)
    c = fc.Client(SOCK, key, timeout=60)

    corpus = "[[1,0],[0,1],[0.6,0.8]]"
    query = "[0.6,0.8]"

    # the new name runs the convergence search
    st, v = c.call("fractal_sfs_converge", corpus, query, 3, '{"iterations":50,"population_size":30}')
    check(st == fc.OK and isinstance(v, str) and '"best_point"' in v,
          "fractal_sfs_converge(vector_csv, query_csv, k, params) runs the convergence search",
          "status %s value %r" % (st, v))

    # the debug form is the convergence trace
    st, v = c.call("fractal_sfs_converge_debug", "[1,2,3]", 20, 10, 2, 42)
    check(st == fc.OK and isinstance(v, str) and '"best_point"' in v,
          "fractal_sfs_converge_debug is the convergence trace",
          "status %s value %r" % (st, v))

    # the OLD name is refused, and the refusal names the new one
    st, v = c.call("fractal_search", corpus, query, 3, "{}")
    check(st != fc.OK and isinstance(v, str) and "fractal_sfs_converge" in v,
          "the old fractal_search(vector, query, k, params) call is refused and names fractal_sfs_converge",
          "status %s value %r" % (st, v))

    # the registry carries the new names and the tombstone
    if FUNCTIONS_DEF:
        names = set()
        for line in open(FUNCTIONS_DEF):
            line = line.strip()
            if line.startswith("X("):
                names.add(line[2:].split(",")[0].strip())
        check("fractal_sfs_converge" in names, "the registry carries fractal_sfs_converge")
        check("fractal_sfs_converge_debug" in names, "the registry carries fractal_sfs_converge_debug")
        check("fractal_search" in names, "the registry keeps fractal_search as the tombstone")
        check("fractal_search_debug" not in names, "the registry no longer carries fractal_search_debug")

    c.close()
    print("%d checks failed" % len(failures))
    return 1 if failures else 0


if __name__ == "__main__":
    sys.exit(main())
