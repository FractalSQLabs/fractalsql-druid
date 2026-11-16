#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
# SPDX-FileCopyrightText: 2026 Daniel Gardiner d/b/a FractalSQLabs
"""The ledger under the crashes ledger_crash.py does not cover.

usage: ledger_variants.py DAEMON KEYFILE ENTLIB [ITERATIONS] [SEED]

ledger_crash.py kills the daemon with SIGKILL while one connection appends. This runs the other
shapes the plan lists, each ITERATIONS times (default 5):

  sigterm      SIGTERM while appending: an orderly stop must leave a sound chain too
  two-writers  two connections append at once, then SIGKILL
  ops          the other ledger operations (flush, compact, reset_soft, reset_hard) interleaved with
               appends, then SIGKILL; a reset legitimately changes the row count, so only soundness is asserted
  file-limit   the daemon runs with a file-size limit (RLIMIT_FSIZE) a little above the first records and
               SIGXFSZ ignored, so a write fails with EFBIG: the daemon must refuse it (never acknowledge it),
               and the chain, started again without the limit, must verify and take a new append
  ops-sequence each ledger operation on its own with no kill: append, operation, verify, append, verify
  file-limit-kill  the same limit with the signal's default action: SIGXFSZ ends the daemon mid-write; the
               chain after the restart must verify (the torn tail is repaired)

The contract after the restart, as in ledger_crash.py:
  * every acknowledged write is in the chain (except after a reset in "ops");
  * the chain verifies (after a write the operating system cut short, verify may first report the torn tail;
    the daemon repairs it on the next append); * a new append works and the chain then verifies, with at least the
    acknowledged writes and the new one.
"""
import json
import os
import random
import resource
import shutil
import signal
import socket
import subprocess
import sys
import tempfile
import threading
import time

import fsq_client as fc

daemon_bin, keyfile, entlib = sys.argv[1:4]
ITER = int(sys.argv[4]) if len(sys.argv) > 4 else 5
SEED = int(sys.argv[5]) if len(sys.argv) > 5 else 20261116
KEY = fc.load_key(keyfile)
rnd = random.Random(SEED)
FSIZE_MODE = "efbig"   # or "kill": the signal ends the daemon


def start(conf, sock, fsize=None):
    try:
        os.remove(sock)
    except OSError:
        pass

    def limit():
        if fsize:
            # SIGXFSZ ignored (it stays ignored across exec): the write then fails with EFBIG, which the daemon has to
            # report, instead of the signal ending it. Both are tested: see the file-limit-kill scenario.
            if FSIZE_MODE == "efbig":
                signal.signal(signal.SIGXFSZ, signal.SIG_IGN)
            resource.setrlimit(resource.RLIMIT_FSIZE, (fsize, fsize))

    p = subprocess.Popen([daemon_bin, "-c", conf], preexec_fn=limit if fsize else None,
                         stdout=open(conf + ".log", "ab"), stderr=subprocess.STDOUT)
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


def stop(p, sig):
    if p is None:
        return
    try:
        p.send_signal(sig)
    except Exception:
        pass
    try:
        p.wait(timeout=15)
    except Exception:
        p.kill()


def write_conf(path, sock, ledger, sealed):
    with open(path, "w") as fh:
        fh.write("socket_path = %s\nhmac_key_file = %s\nallowed_uids = %s\n" % (sock, keyfile, os.getuid()))
        fh.write("enterprise_lib = %s\nenterprise_require_signature = false\nenterprise_ledger_path = %s\n" % (entlib, ledger))
        if sealed:
            fh.write("enterprise_ledger_key = %s\n" % ("ab" * 32))
    os.chmod(path, 0o600)   # the daemon refuses a configuration file that others can read


def writer(sock, stop_ev, acked, ops):
    c = None
    n = 0
    while not stop_ev.is_set():
        try:
            if c is None:
                c = fc.Client(sock, KEY, timeout=10)
            if ops and n % 4 == 3:
                fn = ("fractal_ledger_flush", "fractal_ledger_compact", "fractal_ledger_reset_soft", "fractal_ledger_reset_hard")[(n // 4) % 4]
                c.call(fn, 1)
                with acked["lock"]:
                    acked["reset"] = acked["reset"] or fn.startswith("fractal_ledger_reset")
            else:
                st, _v = c.call("fractal_audit_log", "variant", json.dumps({"n": n}), 1, "ci")
                if st == 0:
                    with acked["lock"]:
                        acked["n"] += 1
            n += 1
        except Exception:
            try:
                if c is not None:
                    c.close()
            except Exception:
                pass
            c = None
            time.sleep(0.01)


def check_after(conf, sock, acked, label, i, require_rows=True, allow_torn=False):
    problems = []
    p = start(conf, sock)
    if p is None or not os.path.exists(sock):
        stop(p, signal.SIGKILL)
        return ["%s %d: the daemon did not start again" % (label, i)], None
    c = fc.Client(sock, KEY, timeout=20)
    rows = None
    try:
        st, v = c.call("fractal_ledger_verify", 1, 2)
        d = json.loads(v) if v else {}
        rows = d.get("rows_verified")
        # A write that the operating system cut short leaves a torn record at the end. The daemon repairs it on the next
        # append (ledger_repair_torn_tail), so until then verify reports it ("truncated ..."): that is the honest answer,
        # not a failure. Everything else must verify at once.
        torn = (not d.get("ok")) and allow_torn and "truncated" in (d.get("reason") or "")
        if not d.get("ok") and not torn:
            problems.append("%s %d: the chain does not verify after the restart (%s)" % (label, i, d.get("reason")))
        if require_rows and not torn and rows is not None and rows < acked:
            problems.append("%s %d: %d acknowledged write(s) but the chain holds %d row(s)" % (label, i, acked, rows))
        st2, _ = c.call("fractal_audit_log", "after", json.dumps({"i": i}), 1, "ci")
        if st2 != 0:
            problems.append("%s %d: an append after the restart was not acknowledged" % (label, i))
        st3, v3 = c.call("fractal_ledger_verify", 1, 2)
        d3 = json.loads(v3) if v3 else {}
        if not d3.get("ok"):
            problems.append("%s %d: the chain does not verify after the new append (%s)" % (label, i, d3.get("reason")))
        elif require_rows and d3.get("rows_verified") is not None and d3["rows_verified"] < acked + 1:
            problems.append("%s %d: %d acknowledged write(s) and one more append, but the chain holds %d row(s)"
                            % (label, i, acked, d3["rows_verified"]))
        rows = d3.get("rows_verified") if torn else rows
    finally:
        c.close()
        stop(p, signal.SIGTERM)
    return problems, rows


def scenario(name, i, work):
    sock = os.path.join(work, "d.sock")
    ledger = os.path.join(work, "%s-%d.dat" % (name, i))
    conf = os.path.join(work, "%s-%d.conf" % (name, i))
    for suf in ("", ".head", ".csv"):
        try:
            os.remove(ledger + suf)
        except OSError:
            pass
    write_conf(conf, sock, ledger, sealed=(i % 2 == 1))
    acked = {"n": 0, "lock": threading.Lock(), "reset": False}
    stop_ev = threading.Event()
    fsize = None
    global FSIZE_MODE
    FSIZE_MODE = "kill" if name == "file-limit-kill" else "efbig"
    if name in ("file-limit", "file-limit-kill"):
        fsize = 6000 + rnd.randint(0, 3000)   # past the first records, short of many
    p = start(conf, sock, fsize)
    if p is None or not os.path.exists(sock):
        stop(p, signal.SIGKILL)
        return ["%s %d: the daemon did not start" % (name, i)], acked["n"], None
    nthreads = 2 if name == "two-writers" else 1
    ts = [threading.Thread(target=writer, args=(sock, stop_ev, acked, name == "ops"), daemon=True) for _ in range(nthreads)]
    for t in ts:
        t.start()
    time.sleep(rnd.uniform(0.2, 1.2) if not name.startswith("file-limit") else 2.0)
    stop(p, signal.SIGTERM if name == "sigterm" else signal.SIGKILL)
    stop_ev.set()
    for t in ts:
        t.join(timeout=10)
    # the limit is off for the restart
    require = not (name == "ops" and acked["reset"])
    problems, rows = check_after(conf, sock, acked["n"], name, i, require_rows=require, allow_torn=name.startswith("file-limit"))
    return problems, acked["n"], rows


def ops_sequence(i, work):
    """Each ledger operation on its own, with no kill: append, run the operation, verify, append, verify. A kill at a
    random moment seldom lands right after a flush or a compact, so the chain they leave is checked directly."""
    sock = os.path.join(work, "d.sock")
    ledger = os.path.join(work, "opsseq-%d.dat" % i)
    conf = os.path.join(work, "opsseq-%d.conf" % i)
    write_conf(conf, sock, ledger, sealed=(i % 2 == 1))
    p = start(conf, sock)
    if p is None or not os.path.exists(sock):
        stop(p, signal.SIGKILL)
        return ["ops-sequence %d: the daemon did not start" % i], 0, None
    problems = []
    c = fc.Client(sock, KEY, timeout=20)
    rows = 0
    try:
        for op in ("fractal_ledger_flush", "fractal_ledger_compact", "fractal_ledger_flush", "fractal_ledger_reset_soft",
                   "fractal_ledger_flush", "fractal_ledger_compact"):
            for n in range(3):
                c.call("fractal_audit_log", "seq", json.dumps({"op": op, "n": n}), 1, "ci")
            st, _ = c.call(op, 1)
            st, v = c.call("fractal_ledger_verify", 1, 2)
            d = json.loads(v) if v else {}
            if not d.get("ok"):
                problems.append("ops-sequence %d: the chain does not verify right after %s (%s)" % (i, op, d.get("reason")))
            c.call("fractal_audit_log", "seq-after", json.dumps({"op": op}), 1, "ci")
            st, v = c.call("fractal_ledger_verify", 1, 2)
            d = json.loads(v) if v else {}
            rows = d.get("rows_verified") or rows
            if not d.get("ok"):
                problems.append("ops-sequence %d: the chain does not verify after %s and one more append (%s)" % (i, op, d.get("reason")))
    finally:
        c.close()
        stop(p, signal.SIGTERM)
    return problems, rows, rows


def main():
    work = tempfile.mkdtemp(prefix="fsql-variants-")
    allp = []
    try:
        for name in ("sigterm", "two-writers", "ops", "file-limit", "file-limit-kill"):
            for i in range(ITER):
                problems, acked, rows = scenario(name, i, work)
                print("%-11s %2d: acknowledged=%-4s rows=%-4s %s" % (name, i, acked, rows, "ok" if not problems else "PROBLEM"))
                sys.stdout.flush()
                allp += problems
        for i in range(ITER):
            problems, _a, rows = ops_sequence(i, work)
            print("%-11s %2d: rows=%-4s %s" % ("ops-sequence", i, rows, "ok" if not problems else "PROBLEM"))
            allp += problems
    finally:
        shutil.rmtree(work, ignore_errors=True)
    print("%d scenario run(s), %d problem(s)" % (6 * ITER, len(allp)))
    for p in allp[:20]:
        print("FAIL " + p)
    return 1 if allp else 0


if __name__ == "__main__":
    sys.exit(main())
