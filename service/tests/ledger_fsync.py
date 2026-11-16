#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
# SPDX-FileCopyrightText: 2026 Daniel Gardiner d/b/a FractalSQLabs
"""An acknowledged ledger write has been synced to disk before the answer goes out.

usage: ledger_fsync.py DAEMON CONF KEYFILE ENTLIB FSYNC_SHIM.so [CALLS]

A SIGKILL does not lose the page cache, so killing the daemon cannot show whether a
write was synced (ledger_crash.py shows the process-level contract and cannot see this one).
Here the daemon runs with a shim (fsync_count.c) that records every fsync and fdatasync it
makes. After each acknowledged fractal_audit_log the record must already hold at least one more
sync than before the call: the answer is sent after the sync, so a sync that is missing, or that
comes after the answer, shows as a count that has not moved when the answer arrives.
"""
import json
import os
import shutil
import signal
import socket
import subprocess
import sys
import tempfile
import time

import fsq_client as fc

daemon_bin, conf_path, keyfile, entlib, shim = sys.argv[1:6]
CALLS = int(sys.argv[6]) if len(sys.argv) > 6 else 30
KEY = fc.load_key(keyfile)


def main():
    work = tempfile.mkdtemp(prefix="fsql-fsync-")
    sock = os.path.join(work, "d.sock")
    ledger = os.path.join(work, "ledger.dat")
    log = os.path.join(work, "fsync.log")
    open(log, "w").close()
    conf = os.path.join(work, "c.conf")
    with open(conf, "w") as fh:
        fh.write("socket_path = %s\nhmac_key_file = %s\nallowed_uids = %s\n" % (sock, keyfile, os.getuid()))
        fh.write("enterprise_lib = %s\nenterprise_require_signature = false\nenterprise_ledger_path = %s\n" % (entlib, ledger))
    os.chmod(conf, 0o600)   # the daemon refuses a configuration file that others can read
    env = dict(os.environ, LD_PRELOAD=os.path.abspath(shim), FSQL_FSYNC_LOG=log)
    p = subprocess.Popen([daemon_bin, "-c", conf], env=env, stdout=open(os.path.join(work, "d.log"), "wb"), stderr=subprocess.STDOUT)
    problems = []
    try:
        for _ in range(200):
            try:
                s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
                s.settimeout(2)
                s.connect(sock)
                s.close()
                break
            except Exception:
                time.sleep(0.05)
        c = fc.Client(sock, KEY, timeout=20)
        unsynced = 0
        acked = 0
        for n in range(CALLS):
            before = os.path.getsize(log)
            st, _v = c.call("fractal_audit_log", "fsync", json.dumps({"n": n}), 1, "ci")
            after = os.path.getsize(log)
            if st != 0:
                problems.append("call %d was not acknowledged (status %s)" % (n, st))
                continue
            acked += 1
            if after <= before:
                unsynced += 1
        c.close()
        print("%d acknowledged write(s); %d answered with no sync made since the call began; %d sync(s) recorded in all"
              % (acked, unsynced, os.path.getsize(log)))
        if acked == 0:
            problems.append("no write was acknowledged")
        if unsynced:
            problems.append("%d acknowledged write(s) were answered before (or without) a sync" % unsynced)
    finally:
        try:
            p.send_signal(signal.SIGTERM)
            p.wait(timeout=10)
        except Exception:
            p.kill()
        shutil.rmtree(work, ignore_errors=True)
    for x in problems:
        print("FAIL " + x)
    return 1 if problems else 0


if __name__ == "__main__":
    sys.exit(main())
