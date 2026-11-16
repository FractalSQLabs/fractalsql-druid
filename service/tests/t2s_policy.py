#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
# SPDX-FileCopyrightText: 2026 Daniel Gardiner d/b/a FractalSQLabs
"""The text-to-SQL policy table, run against a live daemon.

usage: t2s_policy.py SOCKET KEYFILE MODE

MODE is "select" or "select_insert_update": the daemon's
FRACTALSQL_TEXT_TO_SQL_ALLOWED_STATEMENTS, which decides whether INSERT
and UPDATE are permitted as well as SELECT. The table (tests/svc/
t2s_policy_cases.py) says what the documented rules require for every
statement; this script says what the daemon actually does, and reports
the cases where the two differ.

A case whose result differs from the documented rule is a finding. The
findings that are already known are listed in the table's
KNOWN_DIFFERENCES, each with the finding it belongs to; a NEW difference
fails the run.
"""
import os
import sys

import fsq_client as fc

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.join(HERE, "..", "..", "tests", "svc"))
import t2s_policy_cases as table  # noqa: E402


def main():
    sock, keyfile, mode = sys.argv[1:4]
    key = fc.load_key(keyfile)
    # The case tuple is (id, category, statement, select_mode, insert_update_mode, reason).
    idx = 4 if mode == "select_insert_update" else 3

    differences = []
    failures = []
    c = fc.Client(sock, key, timeout=30)
    try:
        for case in table.CASES:
            cid, category, statement, allow_a, allow_b, reason = case
            expected = allow_b if idx == 4 else allow_a
            if isinstance(reason, tuple):
                reason = reason[1] if idx == 4 else reason[0]
            try:
                status, value = c.call("fractal_t2s_check_allowlist", statement)
            except Exception as e:
                failures.append("%s: the call failed (%s)" % (cid, e))
                continue
            if status != 0:
                # The function refused to even look at the statement: that
                # is a rejection as far as the policy is concerned.
                got = "reject"
                text = str(value)
            elif value is None:
                got = "allow"
                text = ""
            else:
                got = "reject"
                text = str(value)
            if got != expected:
                differences.append((cid, category, statement, expected, got, text))
                continue
            if got == "reject" and reason:
                if reason.lower() not in text.lower():
                    failures.append("%s: rejected, but the reason does not mention %r (%s)"
                                    % (cid, reason, text[:120]))
    finally:
        c.close()

    for cid, category, statement, expected, got, text in differences:
        note = table.KNOWN_DIFFERENCES.get(cid, "")
        print("%s %s: the documented rule says %s, the daemon says %s%s"
              % ("KNOWN" if note else "DIFFERENCE", cid, expected, got,
                 (" -- " + note) if note else ""))
        print("    %s" % statement[:160].replace("\n", "\\n"))
        if text:
            print("    the daemon said: %s" % text[:160].replace("\n", " "))

    new = [d for d in differences if d[0] not in table.KNOWN_DIFFERENCES]
    print("%d case(s), %d difference(s) from the documented rule (%d new), %d other failure(s)"
          % (len(table.CASES), len(differences), len(new), len(failures)))
    for f in failures:
        print("FAIL " + f)
    return 1 if (new or failures) else 0


if __name__ == "__main__":
    sys.exit(main())
