#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
# SPDX-FileCopyrightText: 2026 Daniel Gardiner d/b/a FractalSQLabs
"""The ledger, and the daemon killed while it writes.

usage: ledger_crash.py DAEMON CONF KEYFILE ENTLIB ITERATIONS [SEED]

The ledger's recovery is already tested against ledgers that are
damaged (service/tests/ledger_damage.py, gate 30). This is the other
half: the damage a crash does on its own. The daemon is killed with
SIGKILL while it is appending to the chain, then started again on the
same ledger, and the chain is checked.

What the contract is, from the ledger's own code (the comments above
ledger_write_entry, the head-file comment block, and the torn-tail
repair in fractalsql_enterprise.c):

  * an acknowledged write is durable: the record is written and synced
    before the call answers, so the chain must hold at least as many
    rows as the run got an answer for;
  * the chain verifies after the restart -- a write that was in flight
    when the daemon died may be a torn tail, and the repair truncates
    it, but the chain that is left must verify;
  * the head file's counter cannot be ahead of the chain by more than
    the writes that were in flight at the kill; if it is, the verify
    must say so rather than pass;
  * after the restart a new append works, and the chain stays valid.

Each iteration prints one line: the acknowledged count, the rows the
verify reported, the verdict, and the reason when there is one. The
stand-in enterprise library (service/tests/mock_enterprise.c) is used,
so the test runs without the licensed one.
"""
import json
import os
import random
import shutil
import signal
import socket
import subprocess
import sys
import tempfile
import threading
import time

import fsq_client as fc

daemon_bin, conf_tpl, keyfile, entlib = sys.argv[1:5]
ITERATIONS = int(sys.argv[5]) if len(sys.argv) > 5 else 40
SEED = int(sys.argv[6]) if len(sys.argv) > 6 else 20261116

KEY = fc.load_key(keyfile)
rnd = random.Random(SEED)


def start_daemon(conf, sock):
    # The socket file of the previous run is stale: remove it, and wait
    # for a connection to be accepted rather than for the file to exist.
    try:
        os.remove(sock)
    except OSError:
        pass
    p = subprocess.Popen([daemon_bin, "-c", conf],
                         stdout=open(os.path.join(os.path.dirname(conf), "daemon.log"), "ab"),
                         stderr=subprocess.STDOUT)
    for _ in range(200):
        if p.poll() is not None:
            return None
        try:
            s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
            s.settimeout(2)
            s.connect(sock)
            s.close()
            return p
        except Exception:
            time.sleep(0.05)
    return p


def stop_daemon(p, sig=signal.SIGKILL):
    if p is None:
        return
    try:
        p.send_signal(sig)
    except Exception:
        pass
    try:
        p.wait(timeout=10)
    except Exception:
        try:
            p.kill()
        except Exception:
            pass


def write_conf(path, sock, ledger, sealed):
    with open(path, "w") as fh:
        fh.write("socket_path = %s\n" % sock)
        fh.write("hmac_key_file = %s\n" % keyfile)
        fh.write("allowed_uids = %s\n" % os.getuid())
        fh.write("enterprise_lib = %s\n" % entlib)
        fh.write("enterprise_require_signature = false\n")
        fh.write("enterprise_ledger_path = %s\n" % ledger)
        if sealed:
            fh.write("enterprise_ledger_key = %s\n" % ("ab" * 32))
    os.chmod(path, 0o600)   # the daemon refuses a configuration file that others can read


def one_iteration(i, workdir):
    sock = os.path.join(workdir, "d.sock")
    ledger = os.path.join(workdir, "ledger-%d.dat" % i)
    conf = os.path.join(workdir, "conf-%d.conf" % i)
    sealed = (i % 2 == 1)
    for suffix in ("", ".head", ".csv"):
        try:
            os.remove(ledger + suffix)
        except OSError:
            pass
    write_conf(conf, sock, ledger, sealed)

    acked = [0]
    stop = threading.Event()

    def writer():
        c = None
        while not stop.is_set():
            try:
                if c is None:
                    c = fc.Client(sock, KEY, timeout=10)
                st, _v = c.call("fractal_audit_log", "crash", json.dumps({"i": i, "n": acked[0]}), 1, "ci")
                if st == 0:
                    acked[0] += 1
            except Exception:
                try:
                    if c is not None:
                        c.close()
                except Exception:
                    pass
                c = None
                time.sleep(0.01)

    p = start_daemon(conf, sock)
    if p is None or not os.path.exists(sock):
        stop_daemon(p)
        return {"iter": i, "ok": False, "reason": "the daemon did not start"}

    t = threading.Thread(target=writer, daemon=True)
    t.start()
    time.sleep(rnd.uniform(0.05, 1.5))
    stop_daemon(p, signal.SIGKILL)
    stop.set()
    t.join(timeout=10)

    # Start it again on the same ledger.
    p2 = start_daemon(conf, sock)
    result = {"iter": i, "acked": acked[0], "sealed": sealed}
    if p2 is None or not os.path.exists(sock):
        stop_daemon(p2)
        result["ok"] = False
        result["reason"] = "the daemon did not start again"
        return result

    c = fc.Client(sock, KEY, timeout=20)
    try:
        # Both kinds are verified: the audit chain (kind 2, where the
        # writes went) and the truth chain (kind 1).
        for kind in (2, 1):
            st, v = c.call("fractal_ledger_verify", 1, kind)
            d = json.loads(v) if v else {}
            if kind == 2:
                result["rows"] = d.get("rows_verified")
                result["verify_ok"] = bool(d.get("ok"))
                result["reason"] = d.get("reason") or ""
            else:
                result["rows_kind1"] = d.get("rows_verified")
                result["verify_ok_kind1"] = bool(d.get("ok"))

        # An append after the restart must work, and the chain must stay valid.
        st2, _v2 = c.call("fractal_audit_log", "crash-after", json.dumps({"i": i}), 1, "ci")
        result["append_ok"] = (st2 == 0)
        st3, v3 = c.call("fractal_ledger_verify", 1, 2)
        d3 = json.loads(v3) if v3 else {}
        result["rows_after"] = d3.get("rows_verified")
        result["verify_ok_after"] = bool(d3.get("ok"))
        result["reason_after"] = d3.get("reason") or ""
    finally:
        c.close()
        stop_daemon(p2, signal.SIGTERM)

    result["ok"] = True
    return result


def main():
    workdir = tempfile.mkdtemp(prefix="fsql-crash-")
    rows = []
    problems = []
    try:
        for i in range(ITERATIONS):
            r = one_iteration(i, workdir)
            rows.append(r)
            line = ("iteration %3d: acknowledged=%-4s rows=%-4s verify=%-5s append=%-5s rows_after=%-4s verify_after=%-5s%s"
                    % (r["iter"], r.get("acked"), r.get("rows"), r.get("verify_ok"),
                       r.get("append_ok"), r.get("rows_after"), r.get("verify_ok_after"),
                       ("  reason: " + r["reason"]) if r.get("reason") else ""))
            print(line)
            sys.stdout.flush()
            if not r.get("ok"):
                problems.append("iteration %d: %s" % (r["iter"], r.get("reason")))
                continue
            # The contract.
            if r.get("rows") is not None and r.get("acked") is not None:
                if r["rows"] < r["acked"]:
                    problems.append("iteration %d: %d acknowledged write(s) but the chain holds %d row(s)"
                                    % (r["iter"], r["acked"], r["rows"]))
            if not r.get("verify_ok"):
                problems.append("iteration %d: the chain does not verify after the restart (%s)"
                                % (r["iter"], r.get("reason")))
            if not r.get("append_ok"):
                problems.append("iteration %d: an append after the restart did not answer" % r["iter"])
            if not r.get("verify_ok_after"):
                problems.append("iteration %d: the chain does not verify after the append (%s)"
                                % (r["iter"], r.get("reason_after")))
    finally:
        shutil.rmtree(workdir, ignore_errors=True)

    print("%d iteration(s), %d problem(s)" % (len(rows), len(problems)))
    for p in problems[:20]:
        print("FAIL " + p)
    return 1 if problems else 0


if __name__ == "__main__":
    sys.exit(main())
