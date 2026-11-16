#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
# SPDX-FileCopyrightText: 2026 Daniel Gardiner d/b/a FractalSQLabs
"""An unauthenticated peer cannot make the daemon hold what it only declared (SECURITY_AUDIT.md 3.9).

usage: preauth_memory.py SOCKET DAEMON_PID
Opens 16 connections, each declaring a 64 MiB payload and sending 100 bytes of it; the daemon's resident size must stay within
32 MiB of where it started (a buffer sized by the declaration would be 1 GiB).
"""
import socket
import struct
import sys
import time

sock, pid = sys.argv[1], sys.argv[2]


def rss_mib():
    for line in open(f"/proc/{pid}/status"):
        if line.startswith("VmRSS"):
            return int(line.split()[1]) // 1024


before = rss_mib()
conns = []
for _ in range(16):
    c = socket.socket(socket.AF_UNIX)
    c.connect(sock)
    c.sendall(b"FSQ1" + struct.pack("<HHIIQII", 2, 1, 0, 1, 0, 32, 64 * 1024 * 1024) + bytes(32) + b"x" * 100)
    conns.append(c)
time.sleep(1.5)
after = rss_mib()
for c in conns:
    c.close()
ok = after - before < 32
print(("ok   " if ok else "FAIL ") + f"16 half-sent 64 MiB frames: resident {before} -> {after} MiB")
sys.exit(0 if ok else 1)
