#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
# SPDX-FileCopyrightText: 2026 Daniel Gardiner d/b/a FractalSQLabs
"""Refusals, limits and timeouts of a running fractalsqld.

usage: security.py SOCKET KEYFILE
The daemon must be started with max_connections = 3 and idle_timeout_secs = 2.
"""
import socket
import struct
import sys
import time

import fsq_client as fc

sock, keyfile = sys.argv[1:3]
key = fc.load_key(keyfile)
failures = []


def check(name, cond, detail=""):
    print(("ok   " if cond else "FAIL ") + name + ("" if cond else "  " + str(detail)))
    if not cond:
        failures.append(name)


def closed_after(fn):
    try:
        fn()
        return False
    except (ConnectionError, OSError, socket.timeout):
        return True


# an unknown opcode is refused with NOTSUP and the connection stays usable
c = fc.Client(sock, key)
r = c.request(0x7777)
check("an unknown opcode is NOTSUP", r.status == fc.NOTSUP, r.status)
check("the connection survives it", c.request(fc.OP_PING).status == 0)
c.close()

# a malformed magic closes the connection
raw = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
raw.settimeout(5)
raw.connect(sock)
raw.sendall(b"XXXX" + bytes(60))
check("a bad magic closes the connection", closed_after(lambda: (raw.recv(1) or (_ for _ in ()).throw(ConnectionError()))))
raw.close()

# a payload over the 80 MiB limit closes the connection before anything is read
raw = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
raw.settimeout(5)
raw.connect(sock)
hdr = b"FSQ1" + struct.pack("<HHIIQII", 2, fc.OP_PING, 0, 1, 0, 32, 90 * 1024 * 1024)
raw.sendall(hdr + bytes(32))
check("an over-limit payload closes the connection", closed_after(lambda: (raw.recv(1) or (_ for _ in ()).throw(ConnectionError()))))
raw.close()

# a wrong protocol version closes the connection
raw = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
raw.settimeout(5)
raw.connect(sock)
raw.sendall(b"FSQ1" + struct.pack("<HHIIQII", 9, fc.OP_PING, 0, 1, 0, 32, 0) + bytes(32))
check("a wrong protocol version closes the connection", closed_after(lambda: (raw.recv(1) or (_ for _ in ()).throw(ConnectionError()))))
raw.close()

# max_connections = 3: the fourth connection is not served
held = [fc.Client(sock, key) for _ in range(3)]
for h in held:
    h.request(fc.OP_PING)
fourth = fc.Client(sock, key, timeout=5)
check("a connection over max_connections is closed", closed_after(lambda: fourth.request(fc.OP_PING)))
fourth.close()
for h in held:
    h.close()
time.sleep(1)

# idle_timeout_secs = 2: an idle connection is closed
idle = fc.Client(sock, key, timeout=10)
idle.request(fc.OP_PING)
time.sleep(4.5)
check("an idle connection is closed", closed_after(lambda: idle.request(fc.OP_PING)))
idle.close()

# a call in progress is not killed by the idle timeout, and the daemon is still up after all of it
c = fc.Client(sock, key)
check("the daemon still answers after the abuse", c.request(fc.OP_PING).status == 0)
c.close()

print("\n%d failure(s)" % len(failures))
sys.exit(1 if failures else 0)
