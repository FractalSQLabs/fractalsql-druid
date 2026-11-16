#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
# SPDX-FileCopyrightText: 2026 Daniel Gardiner d/b/a FractalSQLabs
"""fractalsql-ledger-check: re-check collected ledger snapshots away from the daemon that wrote them.

    fractalsql-ledger-check STORE_OR_SNAPSHOT [...]

Each argument is either one snapshot (a directory holding MANIFEST.json, as fractalsql-ledger-collect
writes it) or an audit store (<store>/<host>/<time>/ snapshots). For every snapshot it checks:

  * the files are exactly what was collected (SHA256SUMS);
  * the daemon reported both chains verified when it collected them (MANIFEST.json);
  * the chain file is well formed, with no partial record at its end;
  * every record's hash is SHA256(prev || body || mac) and links to the previous record of its kind;
  * the head file's row count for each kind equals the rows in the chain, so a chain cut short at a
    record boundary is visible;
  * the CSV mirror, when present, says exactly what the chain says.

For each host with several snapshots it also checks that the history only grew: each snapshot's chain
must begin with the previous snapshot's chain, byte for byte.

What this cannot do: check the MACs. They need the ledger key and are verified by the daemon on its own
host (fractal_ledger_verify), which is what the manifest records. And the head file's own MAC is checked
there too. This tool shows structure, linkage, completeness and growth, from the copy alone.

exit: 0 every snapshot checks out   1 something failed   2 usage
"""
import base64
import hashlib
import json
import os
import struct
import sys

MAGIC = b"FSQLLDGR"
FILE_HEADER = len(MAGIC) + 1                      # magic + format version
REC_FIXED = struct.calcsize("<IIBBH")             # kind, body length, has_mac, sealed, reserved
REC_HASHES = 32 * 3 + 8                           # mac, prev, hash, updated
ZERO = b"\0" * 32


def sha256_file(path):
    h = hashlib.sha256()
    with open(path, "rb") as f:
        for block in iter(lambda: f.read(1 << 20), b""):
            h.update(block)
    return h.hexdigest()


def parse_chain(data):
    """The chain's records, or raises ValueError saying what is wrong with the file."""
    if len(data) < FILE_HEADER or data[:len(MAGIC)] != MAGIC:
        raise ValueError("not a fractalsql ledger (bad magic)")
    if data[len(MAGIC)] != 1:
        raise ValueError("unsupported ledger format version %d" % data[len(MAGIC)])
    recs, off, n = [], FILE_HEADER, 0
    while off < len(data):
        if len(data) - off < REC_FIXED + REC_HASHES:
            raise ValueError("a partial record at the end of the chain (offset %d)" % off)
        kind, blen, has_mac, sealed, _ = struct.unpack_from("<IIBBH", data, off)
        p = off + REC_FIXED
        mac, prev, h = data[p:p + 32], data[p + 32:p + 64], data[p + 64:p + 96]
        updated = struct.unpack_from("<Q", data, p + 96)[0]
        body_at = p + REC_HASHES
        if body_at + blen > len(data):
            raise ValueError("a record's body runs past the end of the file (record %d)" % (n + 1))
        n += 1
        recs.append({"id": n, "kind": kind, "has_mac": has_mac, "sealed": sealed, "mac": mac, "prev": prev,
                     "hash": h, "updated": updated, "body": data[body_at:body_at + blen]})
        off = body_at + blen
    return recs


def check_links(recs):
    problems, last = [], {}
    for r in recs:
        want_prev = last.get(r["kind"], ZERO)
        if r["prev"] != want_prev:
            problems.append("record %d (kind %d) does not link to the previous record of its kind" % (r["id"], r["kind"]))
        calc = hashlib.sha256(r["prev"] + r["body"] + r["mac"]).digest()
        if calc != r["hash"]:
            problems.append("record %d (kind %d) has a hash that does not match its content" % (r["id"], r["kind"]))
        last[r["kind"]] = r["hash"]
    return problems


def read_head(path):
    rows = {}
    with open(path, "r", encoding="ascii", errors="replace") as f:
        for line in f:
            fields = dict(p.split("=", 1) for p in line.split() if "=" in p)
            if "kind" in fields and "rows" in fields:
                rows[int(fields["kind"])] = int(fields["rows"])
    return rows


def check_csv(path, recs):
    problems = []
    with open(path, "r", encoding="ascii", errors="replace") as f:
        lines = [ln.rstrip("\n") for ln in f if ln.strip()]
    if len(lines) != len(recs):
        return ["the CSV mirror has %d rows, the chain has %d" % (len(lines), len(recs))]
    for ln, r in zip(lines, recs):
        c = ln.split(",")
        try:
            same = (int(c[0]) == r["id"] and int(c[1]) == r["kind"] and base64.b64decode(c[2]) == r["body"]
                    and c[3] == r["mac"].hex() and c[4] == r["prev"].hex() and c[5] == r["hash"].hex()
                    and int(c[6]) == r["sealed"] and int(c[7]) == r["updated"])
        except (ValueError, IndexError):
            same = False
        if not same:
            problems.append("the CSV mirror disagrees with the chain at record %d" % r["id"])
    return problems


def check_snapshot(d):
    """(problems, chain bytes or None, summary)"""
    problems = []
    try:
        manifest = json.load(open(os.path.join(d, "MANIFEST.json")))
    except (OSError, ValueError) as e:
        return ["no readable MANIFEST.json: %s" % e], None, ""
    sums = os.path.join(d, "SHA256SUMS")
    if not os.path.isfile(sums):
        problems.append("no SHA256SUMS")
    else:
        for line in open(sums):
            if not line.strip():
                continue
            want, name = line.split(None, 1)
            name = name.strip().lstrip("*")
            path = os.path.join(d, name)
            if not os.path.isfile(path):
                problems.append("%s is listed in SHA256SUMS and is missing" % name)
            elif sha256_file(path) != want:
                problems.append("%s has changed since it was collected" % name)
    if manifest.get("verified_ok") is not True:
        problems.append("the daemon reported a chain that did not verify when it was collected: %s"
                        % json.dumps(manifest.get("verify")))
    ledger_name = os.path.basename(manifest.get("ledger_path", ""))
    chain_path = os.path.join(d, ledger_name)
    if not ledger_name or not os.path.isfile(chain_path):
        return problems + ["the chain file is missing"], None, ""
    data = open(chain_path, "rb").read()
    try:
        recs = parse_chain(data)
    except ValueError as e:
        return problems + [str(e)], data, ""
    problems += check_links(recs)
    counts = {}
    for r in recs:
        counts[r["kind"]] = counts.get(r["kind"], 0) + 1
    head_path = chain_path + ".head"
    if os.path.isfile(head_path):
        head = read_head(head_path)
        for kind in sorted(set(head) | set(counts)):
            if head.get(kind, 0) != counts.get(kind, 0):
                problems.append("kind %d: the head file says %d rows, the chain has %d (a chain cut short, or a head out of step)"
                                % (kind, head.get(kind, 0), counts.get(kind, 0)))
    else:
        problems.append("no head file: a chain cut short would not show")
    csv_path = chain_path + ".csv"
    if os.path.isfile(csv_path):
        problems += check_csv(csv_path, recs)
    summary = "%d record(s): %s" % (len(recs), ", ".join("kind %d: %d" % (k, counts[k]) for k in sorted(counts)) or "empty")
    return problems, data, summary


def snapshots_under(path):
    if os.path.isfile(os.path.join(path, "MANIFEST.json")):
        return {os.path.basename(os.path.dirname(os.path.abspath(path))): [path]}
    hosts = {}
    for host in sorted(os.listdir(path)):
        hd = os.path.join(path, host)
        if not os.path.isdir(hd) or host.startswith("."):
            continue
        snaps = [os.path.join(hd, s) for s in sorted(os.listdir(hd))
                 if not s.startswith(".") and os.path.isfile(os.path.join(hd, s, "MANIFEST.json"))]
        if snaps:
            hosts[host] = snaps
    return hosts


def main(argv):
    if not argv or argv[0] in ("-h", "--help"):
        print(__doc__)
        return 2 if not argv else 0
    failed = 0
    for arg in argv:
        if not os.path.isdir(arg):
            print("not a directory: %s" % arg, file=sys.stderr)
            return 2
        hosts = snapshots_under(arg)
        if not hosts:
            print("no snapshots under %s" % arg, file=sys.stderr)
            return 2
        for host, snaps in hosts.items():
            previous = None
            for s in snaps:
                problems, data, summary = check_snapshot(s)
                if data is not None and previous is not None and not problems:
                    prev_name, prev_data = previous
                    if not data.startswith(prev_data):
                        problems.append("the history changed since %s: this chain does not begin with the earlier one" % prev_name)
                print("%s  %s/%s  %s" % ("FAIL" if problems else "ok  ", host, os.path.basename(s), summary))
                for p in problems:
                    print("       - " + p)
                failed += 1 if problems else 0
                if data is not None and not problems:
                    previous = (os.path.basename(s), data)
    print("\n%s" % ("every snapshot checks out" if not failed else "%d snapshot(s) failed" % failed))
    return 1 if failed else 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
