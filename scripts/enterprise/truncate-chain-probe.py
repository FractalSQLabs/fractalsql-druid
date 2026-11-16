#!/usr/bin/env python3
"""Prove that the ledger's head file makes a TRUNCATED chain visible.

The chain is append-only and hash-linked, so a rewritten or removed
record in the middle breaks the linkage and fractal_ledger_verify
finds it. But the chain CANNOT show that records were removed from its
very end: every surviving record still links to its predecessor, so
the chain alone looks perfectly healthy. The head file is what closes
that gap -- it lives OUTSIDE the chain, carries its own MAC, and still
says how many records there were.

This probe truncates the chain AT A RECORD BOUNDARY, so what is left
is a set of complete, correctly linked records -- exactly the case the
chain itself cannot detect, and exactly the case the head exists for.

Usage:
    truncate-chain-probe.py [container] [ledger-path-in-container]
"""

import base64
import json
import subprocess
import sys
import urllib.request

CONTAINER = sys.argv[1] if len(sys.argv) > 1 else "fractalsql-druid-broker"
LEDGER = (
    sys.argv[2]
    if len(sys.argv) > 2
    else "/opt/druid/var/fractalsql/fractalsql_ledger.dat"
)

MAGIC_LEN = 8
HEADER_LEN = 4 + 4 + 1 + 1 + 2 + 32 + 32 + 32 + 8   # kind, blen, has_mac, sealed, reserved, mac, prev, hash, updated
FILE_HEADER_LEN = MAGIC_LEN + 1


def docker(args, stdin=None):
    return subprocess.run(
        ["docker", "exec", "-i", CONTAINER] + args,
        input=stdin,
        stdout=subprocess.PIPE,
        stderr=subprocess.STDOUT,
        check=True,
    ).stdout


def read_chain():
    return docker(["cat", LEDGER])


def write_chain(data):
    # base64 through the shell: the chain is binary, and a shell
    # redirection of binary bytes is not portable.
    payload = base64.b64encode(data).decode("ascii")
    docker(
        ["sh", "-c", "base64 -d > '%s'" % LEDGER],
        stdin=payload.encode("ascii"),
    )


def sql(query):
    body = json.dumps({"query": query, "resultFormat": "object"}).encode("utf-8")
    req = urllib.request.Request(
        "http://localhost:8888/druid/v2/sql",
        data=body,
        headers={"Content-Type": "application/json"},
    )
    with urllib.request.urlopen(req, timeout=60) as r:
        return json.loads(r.read().decode("utf-8"))


def verdict():
    rows = sql("SELECT FRACTAL_LEDGER_VERIFY()")
    if not rows:
        return "(no rows)"
    # The column is the generated EXPR$0 (there is no alias).
    return rows[0].get("EXPR$0", rows[0])


def head():
    try:
        return docker(["cat", LEDGER + ".head"]).decode("utf-8").strip()
    except subprocess.CalledProcessError:
        return "(none)"


def record_boundaries(data):
    """The byte offsets at which a record starts."""
    offsets = []
    pos = FILE_HEADER_LEN
    while pos + HEADER_LEN <= len(data):
        kind = int.from_bytes(data[pos:pos + 4], "little")
        blen = int.from_bytes(data[pos + 4:pos + 8], "little")
        offsets.append((pos, kind))
        pos += HEADER_LEN + blen
    return offsets, pos


def main():
    original = read_chain()
    bounds, end = record_boundaries(original)
    print("== before ==")
    print("  head:   %s" % head())
    print("  bytes:  %d" % len(original))
    print("  records: %d" % len(bounds))
    print("  verify: %s" % verdict())

    if len(bounds) < 2:
        print("\nnot enough records to truncate -- flush a few times first")
        return 0

    # Cut after the second record: what remains is two COMPLETE,
    # correctly linked records. The chain itself cannot tell that two
    # records are missing -- only the head can.
    cut = bounds[2][0]
    print("\n== truncating at a record boundary ==")
    print("  keeping %d of %d records (%d of %d bytes)"
          % (2, len(bounds), cut, len(original)))
    write_chain(original[:cut])

    print("\n== after ==")
    print("  head:   %s" % head())
    print("  bytes:  %d" % cut)
    print("  verify: %s" % verdict())

    print("\n== restoring ==")
    write_chain(original)
    print("  verify: %s" % verdict())
    return 0


if __name__ == "__main__":
    sys.exit(main())
