#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
# SPDX-FileCopyrightText: 2026 Daniel Gardiner d/b/a FractalSQLabs
"""Damage a ledger file the way a crash or a bad disk would, for the recovery paths of the enterprise ledger.

usage: ledger_damage.py LEDGER_PATH VARIANT
  VARIANT is a number (one kind of damage to the chain or its head file),
          headN  (the head file replaced by the Nth malformed head below),
          flipN  (one byte of the chain changed at offset N, counted from the start; negative from the end),
          list   (print how many head variants there are)
"""
import os
import sys

# Head files that are almost right: each breaks one rule of the parser a different way.
HEADS = [
    "1 5\n", "1 x\n", "1\n", "1 5 junk\n", "  \t1   5  \n", "x 5\n", "99999999999999999999 5\n", "1 99999999999999999999\n",
    "kind=x rows=5\n", "kind= rows=5\n", "kind=1 rows=y\n", "kind=1 rows=\n", "kind=1\n", "rows=5\n", "kind=-1 rows=5\n", "kind=1 rows=-5\n",
    "kind=1 rows=5 mac=zz\n", "kind=1 rows=5 mac=00\n", "kind=1 rows=5 mac=" + "0" * 64 + "\n", "kind=1 rows=5 mac=" + "g" * 64 + "\n",
    "kind=1 rows=5 bogus=1\n", "kind=1 rows=5 mac=" + "0" * 63 + "\n", "# a comment\n\nkind=1 rows=5\n", "kind=1 rows=5\nkind=1 rows=6\n",
    "".join("kind=%d rows=%d\n" % (i % 4, i) for i in range(40)), "kind=1 rows=5 " + "x" * 600 + "\n", "kind=1 rows=5\r\n", "\n\n\n",
    "kind=1 rows=5 mac=" + "A" * 64 + "\n", "kind=0 rows=0\n", "kind=2 rows=3\n", "kind=3 rows=1 \n",
]
if sys.argv[2] == "list":
    print(len(HEADS))
    sys.exit(0)
path = sys.argv[1]
spec = sys.argv[2]
v = int(spec) if spec.lstrip("-").isdigit() else -1
b = bytearray(open(path, "rb").read()) if os.path.exists(path) else bytearray()
head = path + ".head"
n = len(b)
if v == 0:
    b = b[: max(0, n - 1)]                      # the last byte lost: a torn tail
elif v == 1:
    b = b[: max(0, n - 60)]                     # the tail cut inside a record
elif v == 2:
    b = b[: max(0, n - 130)]                    # cut near a record boundary
elif v == 3:
    b = b[: n // 2]                             # half the file
elif v == 4:
    b = b[:9]                                   # a header and nothing else
elif v == 5:
    b = b[:4]                                   # less than a header
elif v == 6:
    b = bytearray()                             # empty
elif v == 7 and n > 40:
    b[20] ^= 0xFF                               # a byte changed in the first record
elif v == 8 and n > 200:
    b[n - 20] ^= 0x55                           # a byte changed near the end
elif v == 9:
    b += os.urandom(37)                         # garbage after the last record
elif v == 10:
    b += b"\x01\x00\x00\x00" + (2 ** 31).to_bytes(4, "little") + bytes(104)   # a record claiming a huge body
elif v == 11 and n > 20:
    b[9:13] = (7).to_bytes(4, "little")         # an unknown record kind
elif v == 12:
    b[:8] = b"NOTALEDG"                         # the magic gone
elif v == 13:
    if os.path.exists(head):
        os.remove(head)                         # the head file removed
elif v == 14:
    open(head, "wb").write(os.urandom(64))      # a head file of noise
elif v == 15:
    open(head, "wb").write(b"")                 # an empty head file
elif v == 16:
    open(head, "w").write("rows=999999\n")      # a head file counting rows that are not there
elif v == 17:
    b = b + b                                   # the chain written twice over
elif spec.startswith("head"):
    open(head, "w").write(HEADS[int(spec[4:]) % len(HEADS)])
elif spec.startswith("flip") and b:
    off = int(spec[4:])
    b[off % len(b)] ^= 0xA5
open(path, "wb").write(b)
