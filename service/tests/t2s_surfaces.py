#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
# SPDX-FileCopyrightText: 2026 Daniel Gardiner d/b/a FractalSQLabs
"""The two text-to-SQL surfaces that call a model, against a provider that answers what it is told to.

usage: t2s_surfaces.py DAEMON REASONING_PLUGIN KEYFILE

t2s_policy.py covers the allowlist, which never calls a model. This covers the other two:

  fractal_t2s_generate  (the "text-to-SQL" context: code mode, hardcoded). The documented rule
      (docs/reasoning-setup.md, "The four contexts"): the fenced-block extraction is what makes the statement
      come back clean, so a reply with a fenced block returns the block's interior, whatever surrounds it.
  fractal_t2s_review    (the "review" context: text mode, hardcoded). The documented rule: "a PASS/FAIL
      judgment on a candidate; the verdict is read off the front of the answer". A reply that begins with
      PASS (any case, after leading whitespace) is a pass and the call answers NULL; any other reply is the
      critique and comes back verbatim. PASS has to be the word, not the first four letters of one: "Password
      column is missing" is a critique.

The provider is a stand-in that answers the next scripted reply, so each case sets exactly what the model said.
"""
import os
import queue
import shutil
import signal
import socket
import subprocess
import sys
import tempfile
import threading
import time
from http.server import BaseHTTPRequestHandler, HTTPServer
import json

import fsq_client as fc

daemon_bin, plugin, keyfile = [os.path.realpath(a) for a in sys.argv[1:4]]   # the daemon refuses a plugin path with '..'
KEY = fc.load_key(keyfile)
REPLIES = queue.Queue()


class H(BaseHTTPRequestHandler):
    def log_message(self, *a):
        pass

    def do_POST(self):
        n = int(self.headers.get("Content-Length", 0))
        self.rfile.read(n)
        try:
            answer = REPLIES.get_nowait()
        except queue.Empty:
            answer = "(no scripted reply)"
        body = json.dumps({"choices": [{"message": {"content": answer}}]}).encode()
        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)


GENERATE = [
    ("fence-with-language", "```sql\nSELECT 1\n```", "SELECT 1"),
    ("fence-without-language", "```\nSELECT 2\n```", "SELECT 2"),
    ("chatter-around-the-fence", "Here is the query:\n```sql\nSELECT 3 FROM t\n```\nHope that helps.", "SELECT 3 FROM t"),
    ("multi-line-interior", "```sql\nSELECT a,\n       b\nFROM t\n```", "SELECT a,\n       b\nFROM t"),
]

# (id, the model's reply, what the call must answer: None for a pass, or the critique text)
REVIEW = [
    ("pass-upper", "PASS", None),
    ("pass-lower", "pass", None),
    ("pass-mixed-case", "Pass", None),
    ("pass-leading-whitespace", "  \n PASS", None),
    ("pass-with-reason", "PASS: matches the question", None),
    ("pass-with-newline-reason", "PASS\nlooks right", None),
    ("pass-with-full-stop", "PASS.", None),
    ("fail-with-reason", "FAIL: wrong table", "FAIL: wrong table"),
    ("fail-newline", "FAIL\nthe statement does not answer the request", "FAIL\nthe statement does not answer the request"),
    ("pass-not-at-the-front", "The statement is fine. PASS", "The statement is fine. PASS"),
    ("critique-without-verdict", "It selects the wrong column.", "It selects the wrong column."),
    ("word-starting-with-pass-is-not-a-pass", "Password column is missing", "Password column is missing"),
    ("passage-is-not-a-pass", "Passage of time is not modelled", "Passage of time is not modelled"),
    ("pass-then-digit-is-not-a-pass", "PASS2 is not a verdict", "PASS2 is not a verdict"),
]


def main():
    srv = HTTPServer(("127.0.0.1", 0), H)
    port = srv.server_address[1]
    threading.Thread(target=srv.serve_forever, daemon=True).start()
    work = tempfile.mkdtemp(prefix="fsql-t2s-surfaces-")
    sock = os.path.join(work, "d.sock")
    conf = os.path.join(work, "c.conf")
    with open(conf, "w") as fh:
        fh.write("socket_path = %s\nhmac_key_file = %s\nallowed_uids = %s\n" % (sock, keyfile, os.getuid()))
        fh.write("reasoning_plugin = %s\nreasoning_url = http://127.0.0.1:%d/v1/chat/completions\n" % (plugin, port))
        fh.write("reasoning_model = scripted\nreasoning_allow_plaintext = true\n")
    os.chmod(conf, 0o600)
    p = subprocess.Popen([daemon_bin, "-c", conf], stdout=open(os.path.join(work, "d.log"), "wb"), stderr=subprocess.STDOUT)
    failures = []
    ran = 0
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
        if not os.path.exists(sock):
            print("FAIL the daemon did not start: " + open(os.path.join(work, "d.log"), errors="replace").read()[-400:])
            return 1
        c = fc.Client(sock, KEY, timeout=30)
        for cid, reply, want in GENERATE:
            REPLIES.put(reply)
            st, val = c.call("fractal_t2s_generate", 1, "count the rows", "table t(a, b)", "Apache Druid SQL")
            ran += 1
            if st != 0 or val != want:
                failures.append("generate %s: the model said %r; expected %r, got status %s value %r" % (cid, reply, want, st, val))
        for cid, reply, want in REVIEW:
            REPLIES.put(reply)
            st, val = c.call("fractal_t2s_review", 1, "count the rows", "SELECT COUNT(*) FROM t")
            ran += 1
            if st != 0 or val != want:
                failures.append("review %s: the model said %r; expected %r, got status %s value %r" % (cid, reply, want, st, val))
        c.close()
    finally:
        try:
            p.send_signal(signal.SIGTERM)
            p.wait(timeout=10)
        except Exception:
            p.kill()
        srv.shutdown()
        shutil.rmtree(work, ignore_errors=True)
    print("%d case(s), %d failure(s)" % (ran, len(failures)))
    for f in failures:
        print("FAIL " + f)
    return 1 if failures else 0


if __name__ == "__main__":
    sys.exit(main())
