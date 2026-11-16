#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
# SPDX-FileCopyrightText: 2026 Daniel Gardiner d/b/a FractalSQLabs
"""A ledger per host: collect each daemon's chain into an audit store and check it away from the daemon.

usage: druid_ledger_collect.py BROKER_A_URL BROKER_B_URL DAEMON_A_CONTAINER DAEMON_B_CONTAINER SCRIPTS_DIR WORKDIR

Needs both daemons to have the enterprise library (a daemon is given a ledger path only then); exits 77, "skipped",
when they do not. Writes decision-audit records through each broker, runs fractalsql-ledger-collect inside each
daemon's container as the user that owns the ledger, copies the snapshots into WORKDIR/store, and runs
fractalsql-ledger-check over them: first on the genuine copies, then on tampered ones.
"""
import hashlib
import json
import os
import shutil
import struct
import subprocess
import sys
import time
import urllib.request

broker_a, broker_b, cont_a, cont_b, scripts, work = sys.argv[1:7]
CTL = ["fsqlctl", "-s", "/run/fractalsql/fractalsqld.sock", "-k", "/run/fractalsql/hmac.key"]
LEDGER = "/var/lib/fractalsql/fractalsql_ledger.dat"
failures = []


def check(name, cond, detail=""):
    print(("ok   " if cond else "FAIL ") + name + ("" if cond else "  " + str(detail)[:300]))
    if not cond:
        failures.append(name)


def sh(*args, timeout=120):
    return subprocess.run(args, capture_output=True, text=True, timeout=timeout)


def q(base, sql):
    req = urllib.request.Request(base + "/druid/v2/sql", data=json.dumps({"query": sql, "resultFormat": "array"}).encode(),
                                 headers={"Content-Type": "application/json"})
    return json.loads(urllib.request.urlopen(req, timeout=60).read())


def audit(base, n):
    for i in range(n):
        q(base, "SELECT FRACTAL_AUDIT_LOG('collect-test', '{\"i\":%d,\"t\":%d}')" % (i, time.time_ns()))


def flush(base, n):
    """Each flush seals the truth and shadow ledgers into a kind-1 record, so a chain gets several of them."""
    for _ in range(n):
        q(base, "SELECT FRACTAL_LEDGER_FLUSH()")


def collect(container, host):
    dest = "/tmp/audit-%d" % time.time_ns()
    r = sh("docker", "exec", container, "sh", "/tmp/ledger-collect.sh", "--conf", "/run/fractalsql/fractalsqld.conf",
           "--dest", dest, "--host-id", host)
    os.makedirs(os.path.join(work, "store", host), exist_ok=True)
    sh("docker", "cp", "%s:%s/%s/." % (container, dest, host), os.path.join(work, "store", host))
    return r


def checker(*paths):
    r = subprocess.run([sys.executable, os.path.join(scripts, "ledger-check.py"), *paths], capture_output=True, text=True)
    return r.returncode, r.stdout


# A daemon has a ledger only when the enterprise library is set up in it, which shows in its config. (The file alone is not
# the signal: a volume keeps the ledger of an earlier run.)
if any(sh("docker", "exec", c, "grep", "-q", "^enterprise_ledger_path", "/run/fractalsql/fractalsqld.conf").returncode != 0
       for c in (cont_a, cont_b)):
    print("skip: the daemons have no ledger (stage the enterprise library: docs/docker-demo.md, 'The enterprise tier')")
    sys.exit(77)
audit(broker_a, 1)
audit(broker_b, 1)

shutil.rmtree(os.path.join(work, "store"), ignore_errors=True)
for c in (cont_a, cont_b):
    sh("docker", "cp", os.path.join(scripts, "ledger-collect.sh"), c + ":/tmp/ledger-collect.sh")

audit(broker_a, 3)
audit(broker_b, 2)
flush(broker_a, 3)
audit(broker_a, 1)
flush(broker_a, 2)
flush(broker_b, 2)
r1 = collect(cont_a, "host-a")
r2 = collect(cont_b, "host-b")
check("host A: the collector stores a verified snapshot (exit 0)", r1.returncode == 0, r1.stdout + r1.stderr)
check("host B: the collector stores a verified snapshot (exit 0)", r2.returncode == 0, r2.stdout + r2.stderr)
time.sleep(1.2)
audit(broker_a, 2)
flush(broker_a, 1)
r3 = collect(cont_a, "host-a")
check("host A: a second snapshot, later, also verified", r3.returncode == 0, r3.stdout + r3.stderr)

store = os.path.join(work, "store")
if failures:
    print("\n%d failure(s)" % len(failures))
    sys.exit(1)
rc, out = checker(store)
print(out.rstrip())
check("the store checks out, away from the daemons", rc == 0, out)
check("each host has its own chain: two hosts, three snapshots", out.count("ok  ") == 3, out)
import re
k1 = [int(m) for m in re.findall(r"host-a/\S+\s+\d+ record\(s\):.*?kind 1: (\d+)", out)]
check("host A's chain holds several kind-1 (QTL) records, linked one to the next", k1 and max(k1) >= 5, out)


def copy_store(name):
    d = os.path.join(work, name)
    shutil.rmtree(d, ignore_errors=True)
    shutil.copytree(store, d)
    return d


def snap(d, host, which):
    hd = os.path.join(d, host)
    return os.path.join(hd, sorted(os.listdir(hd))[which])


def resum(s):
    names = [n for n in ("fractalsql_ledger.dat", "fractalsql_ledger.dat.head", "fractalsql_ledger.dat.csv", "MANIFEST.json")
             if os.path.isfile(os.path.join(s, n))]
    with open(os.path.join(s, "SHA256SUMS"), "w") as f:
        for n in names:
            f.write("%s  %s\n" % (hashlib.sha256(open(os.path.join(s, n), "rb").read()).hexdigest(), n))


# a byte changed in a copy
d = copy_store("tamper-byte")
s = snap(d, "host-a", 0)
p = os.path.join(s, "fractalsql_ledger.dat")
b = bytearray(open(p, "rb").read())
b[130] ^= 1
open(p, "wb").write(b)
rc, _ = checker(d)
check("a changed byte is found", rc != 0)
resum(s)
rc, out = checker(d)
check("and still found when the checksums are rewritten too", rc != 0 and "hash that does not match" in out, out)

# a kind-1 record changed in the middle of a chain that mixes both kinds
d = copy_store("tamper-kind1")
s1 = snap(d, "host-a", -1)
p = os.path.join(s1, "fractalsql_ledger.dat")
b = bytearray(open(p, "rb").read())
off, k1_bodies = 9, []
while off < len(b):
    kind, blen = struct.unpack_from("<II", b, off)
    if kind == 1 and blen > 0:
        k1_bodies.append(off + 12 + 104)
    off += 12 + 104 + blen
if len(k1_bodies) >= 2:
    b[k1_bodies[1]] ^= 0x01
    open(p, "wb").write(b)
    resum(s1)
    rc, out = checker(d)
    check("a changed kind-1 record is found even with the checksums rewritten", rc != 0 and "hash that does not match" in out, out)
else:
    check("the chain has at least two kind-1 records with a body to change", False, len(k1_bodies))

# the newest record removed at a record boundary
d = copy_store("tamper-truncate")
s = snap(d, "host-a", -1)
p = os.path.join(s, "fractalsql_ledger.dat")
b = open(p, "rb").read()
off, starts = 9, []
while off < len(b):
    starts.append(off)
    off += 12 + 104 + struct.unpack_from("<I", b, off + 4)[0]
open(p, "wb").write(b[:starts[-1]])
resum(s)
rc, out = checker(d)
check("a chain cut short at a record boundary is found (the head file counts the rows)", rc != 0 and "head file says" in out, out)

# a different chain presented as the host's later history
d = copy_store("tamper-history")
shutil.copytree(snap(d, "host-b", 0), os.path.join(d, "host-a", "99990101T000000Z"))
rc, out = checker(d)
check("a chain that is not the earlier one's continuation is found", rc != 0 and "history changed" in out, out)

print("\n%d failure(s)" % len(failures))
sys.exit(1 if failures else 0)
