#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
# SPDX-FileCopyrightText: 2026 Daniel Gardiner d/b/a FractalSQLabs
"""Limits the MCP server must hold on input it is given (SECURITY_AUDIT.md 3.20, 3.21; 3.19 is in vecform_probe.cpp).

usage: mcp_audit_limits.py MCP_BINARY
  3.20  a limit bound that is not a number is refused, not cast (NaN to int64 is undefined behaviour);
  3.21  a Druid answer that never ends is cut off at the server's limit: an error, the process alive and its memory bounded.
"""
import json
import os
import select
import subprocess
import sys
import urllib.request

binary = os.path.abspath(sys.argv[1])
here = os.path.dirname(os.path.abspath(__file__))
failures = []


def check(name, cond, detail=""):
    print(("ok   " if cond else "FAIL ") + name + ("" if cond else "  " + str(detail)[:300]))
    if not cond:
        failures.append(name)


class Server:
    def __init__(self, env):
        self.p = subprocess.Popen([binary], stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, text=True, env=env)
        self.n = 0
        self.rpc("initialize", {"protocolVersion": "2025-06-18", "capabilities": {}, "clientInfo": {"name": "audit", "version": "1"}})
        self.p.stdin.write(json.dumps({"jsonrpc": "2.0", "method": "notifications/initialized"}) + "\n")
        self.p.stdin.flush()

    def rpc(self, method, params=None, timeout=60):
        self.n += 1
        self.p.stdin.write(json.dumps({"jsonrpc": "2.0", "id": self.n, "method": method, "params": params or {}}) + "\n")
        self.p.stdin.flush()
        r, _, _ = select.select([self.p.stdout], [], [], timeout)
        if not r:
            return "timeout"
        line = self.p.stdout.readline()
        return json.loads(line) if line else None

    def call(self, name, args, timeout=60):
        return self.rpc("tools/call", {"name": name, "arguments": args}, timeout)

    def rss_mib(self):
        try:
            for line in open("/proc/%d/status" % self.p.pid):
                if line.startswith("VmRSS"):
                    return int(line.split()[1]) // 1024
        except OSError:
            pass
        return None   # no /proc (macOS): the memory check is skipped

    def close(self):
        try:
            self.p.stdin.close()
            self.p.wait(10)
        except Exception:
            self.p.kill()


def text_of(r):
    if not isinstance(r, dict):
        return str(r)
    return json.dumps(r.get("result") or r.get("error"))


mock = subprocess.Popen([sys.executable, "-I", os.path.join(here, "mock_druid.py"), "0"], stdout=subprocess.PIPE, text=True)
url = "http://127.0.0.1:%d" % int(mock.stdout.readline())
try:
    s = Server(dict(os.environ, DRUID_URL=url, DRUID_TIMEOUT_MS="5000"))
    # 3.20
    for bad in ("many", "NaN", None, 1e300):
        r = s.call("fractal_periodogram", {"series": [0.1, 0.5, 0.2, 0.9, 0.3, 0.7, 0.1, 0.4], "max_peaks": bad})
        check("3.20: a non-numeric or out-of-range max_peaks (%r) gets an answer, not a crash" % (bad,), isinstance(r, dict), r)
    check("3.20: the server is still running", s.p.poll() is None)
    s.close()
    # 3.21
    urllib.request.urlopen(url + "/_mode/endless", timeout=5).read()
    s = Server(dict(os.environ, DRUID_URL=url, DRUID_TIMEOUT_MS="20000"))
    before = s.rss_mib()
    r = s.call("fractal_version", {}, timeout=60)
    after = s.rss_mib() if s.p.poll() is None else None
    check("3.21: an endless Druid answer ends in an error", isinstance(r, dict) and (r.get("result", {}).get("isError") or "error" in r), text_of(r))
    check("3.21: the process is alive afterwards", s.p.poll() is None)
    if before is not None and after is not None:
        check("3.21: its memory is bounded (resident %s -> %s MiB, limit 256 MiB of body)" % (before, after), after - before < 700, (before, after))
    s.close()
finally:
    mock.kill()
print("%d failure(s)" % len(failures))
sys.exit(1 if failures else 0)
