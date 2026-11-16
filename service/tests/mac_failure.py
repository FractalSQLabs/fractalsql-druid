#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
# SPDX-FileCopyrightText: 2026 Daniel Gardiner d/b/a FractalSQLabs
"""Frame authentication needs no allocation, and a forged frame is refused whatever the allocator does (SECURITY_AUDIT.md 3.1).

usage: mac_failure.py SOCKET KEYFILE PAYLOAD_LEN
The daemon runs with fail_size_preload.so and FSQL_FAIL_SIZE = 32 + PAYLOAD_LEN, so a buffer of the size the daemon used to
allocate to authenticate a PAYLOAD_LEN-byte request fails. Before the fix the daemon zeroed the expected tag in that case,
so a frame carrying an all-zero tag was accepted and answered. Now the tag is computed without a buffer: the forged frame is
refused and the genuine one is answered, exactly as without the failure.
"""
import sys

import fsq_client as fc

sock, keyfile, plen = sys.argv[1], sys.argv[2], int(sys.argv[3])
key = fc.load_key(keyfile)
failures = []


def check(name, cond, detail=""):
    print(("ok   " if cond else "FAIL ") + name + ("" if cond else "  " + str(detail)))
    if not cond:
        failures.append(name)


def refused(bad_tag, size):
    c = fc.Client(sock, key, timeout=5)
    try:
        c.request(fc.OP_PING, b"x" * size, bad_tag=bad_tag)
        return False
    except (ConnectionError, OSError):
        return True
    finally:
        c.close()


check("a forged (all-zero tag) frame is refused when its authentication buffer cannot be allocated", refused(True, plen))
check("a genuine frame of that size is answered (authentication allocates nothing)", not refused(False, plen))
check("a forged frame of another size is refused as always", refused(True, plen + 1))
check("a genuine frame of another size is answered", not refused(False, plen + 1))
sys.exit(1 if failures else 0)
