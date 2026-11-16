#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
# SPDX-FileCopyrightText: 2026 Daniel Gardiner d/b/a FractalSQLabs
"""The MCP server's socket calls failing, over HTTP and towards Druid.

usage: mcp_syscall_faults.py PATH_TO_SERVER

syscall_fault.c (an LD_PRELOAD shim, built here) makes every Nth recv, send, accept, poll, connect, socket or
setsockopt fail with an errno (EINTR, EAGAIN, ECONNRESET, EPIPE, ...), return short (one byte) or report the peer
closed. The retry and error arms behind those calls are reached by nothing else: a test cannot make a healthy kernel
return EINTR on demand.

Two ways to use the server are run under each fault:
  the HTTP transport   --http, thirty requests (health, an initialize, a tool call, a notification, a bad one)
  towards Druid        a stdio session against the stand-in Druid, calling tools that each make a request

What must hold: the server is still running at the end and still answers a plain request once the fault is off;
every answer it did give is well formed. Individual requests may fail (that is the point), so the test does not
assert that any one of them succeeds.
"""
import json
import os
import select
import shutil
import socket
import subprocess
import sys
import tempfile
import time

binary = os.path.abspath(sys.argv[1])
here = os.path.dirname(os.path.abspath(__file__))
failures = []
runs = 0

SPECS = []
for call, hows in (("recv", ("EINTR", "EAGAIN", "ECONNRESET", "short", "zero", "EIO")), ("send", ("EINTR", "EAGAIN", "EPIPE", "ECONNRESET", "short")),
                   ("accept", ("EINTR", "ECONNABORTED", "EMFILE", "ENOMEM")), ("accept4", ("EINTR", "ECONNABORTED", "EMFILE")),
                   ("poll", ("EINTR", "ENOMEM")), ("connect", ("ECONNRESET", "ETIMEDOUT", "EINTR")), ("socket", ("EMFILE", "ENOMEM")),
                   ("setsockopt", ("EBADF", "ENOMEM"))):
    for how in hows:
        for every in (2, 5):
            SPECS.append("%s=%s/%d" % (call, how, every))
SPECS += ["recv=short/1,send=short/1", "recv=EINTR/2,send=EINTR/2,poll=EINTR/3"]


def check(name, cond, detail=""):
    if not cond:
        print("FAIL " + name + "  " + str(detail)[:240])
        failures.append(name)


def free_port():
    s = socket.socket()
    s.bind(("127.0.0.1", 0))
    p = s.getsockname()[1]
    s.close()
    return p


def http_get(port, path="/healthz", timeout=5, method="GET", body=None, headers=()):
    try:
        c = socket.create_connection(("127.0.0.1", port), timeout)
        c.settimeout(timeout)
        req = "%s %s HTTP/1.1\r\nHost: x\r\n%sConnection: close\r\n" % (method, path, "".join("%s: %s\r\n" % h for h in headers))
        if body is not None:
            req += "Content-Length: %d\r\n" % len(body)
        c.sendall((req + "\r\n").encode() + (body or b""))
        data = b""
        while True:
            chunk = c.recv(65536)
            if not chunk:
                break
            data += chunk
        c.close()
        return data
    except OSError:
        return None


def well_formed(data):
    return data is None or data == b"" or data.startswith(b"HTTP/1.")


def run_http(env_fault, shim, mock_url):
    global runs
    port = free_port()
    env = dict(os.environ, DRUID_URL=mock_url, DRUID_TIMEOUT_MS="3000", FSQL_MCP_AUTH_TOKEN="tok", LD_PRELOAD=shim)
    env.update(env_fault)
    for k in [k for k in env if k.startswith("FSQL_MCP_") and k not in ("FSQL_MCP_AUTH_TOKEN",)]:
        pass
    work = tempfile.mkdtemp(prefix="fsql-fault-")
    p = subprocess.Popen([binary, "--http", str(port)], stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
                         env=env, cwd=work)
    try:
        up = False
        for _ in range(100):
            if p.poll() is not None:
                break
            try:
                socket.create_connection(("127.0.0.1", port), 0.3).close()
                up = True
                break
            except OSError:
                time.sleep(0.05)
        if not up:
            return p.poll() is not None      # a refusal to start under a faulted socket is an acceptable end
        H = [("Authorization", "Bearer tok"), ("Content-Type", "application/json"), ("Accept", "application/json")]
        bodies = [json.dumps({"jsonrpc": "2.0", "id": 1, "method": "initialize", "params": {"protocolVersion": "2025-06-18", "capabilities": {},
                                                                                           "clientInfo": {"name": "f", "version": "1"}}}),
                  json.dumps({"jsonrpc": "2.0", "id": 2, "method": "tools/list"}),
                  json.dumps({"jsonrpc": "2.0", "id": 3, "method": "tools/call", "params": {"name": "fractal_version", "arguments": {}}}),
                  json.dumps({"jsonrpc": "2.0", "method": "notifications/initialized"}), "{ bad json"]
        for i in range(6):
            runs += 1
            check("http under %s: healthz is well formed" % env_fault["FSQL_FAULT"], well_formed(http_get(port)))
            for b in bodies:
                runs += 1
                d = http_get(port, "/mcp", method="POST", body=b.encode(), headers=H)
                check("http under %s: a POST is well formed" % env_fault["FSQL_FAULT"], well_formed(d), d and d[:60])
        alive = p.poll() is None
        check("http under %s: the server is still running" % env_fault["FSQL_FAULT"], alive)
        return alive
    finally:
        if p.poll() is None:
            p.terminate()
            try:
                p.wait(10)
            except subprocess.TimeoutExpired:
                p.kill()
        shutil.rmtree(work, ignore_errors=True)


def run_druid(env_fault, shim, mock_url):
    global runs
    env = dict(os.environ, DRUID_URL=mock_url, DRUID_TIMEOUT_MS="3000", LD_PRELOAD=shim)
    env.update(env_fault)
    p = subprocess.Popen([binary], stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, text=True, env=env)
    n = 0
    answered = 0

    def rpc(method, params):
        nonlocal n
        n += 1
        try:
            p.stdin.write(json.dumps({"jsonrpc": "2.0", "id": n, "method": method, "params": params}) + "\n")
            p.stdin.flush()
        except (BrokenPipeError, OSError):
            return None
        r, _, _ = select.select([p.stdout], [], [], 30)
        if not r:
            return "timeout"
        line = p.stdout.readline()
        if not line:
            return None
        try:
            return json.loads(line)
        except ValueError:
            return "garbled"

    rpc("initialize", {"protocolVersion": "2025-06-18", "capabilities": {}, "clientInfo": {"name": "f", "version": "1"}})
    for tool, args in (("fractal_version", {}), ("fractal_vector_lp_distance", {"a": [0, 0], "b": [3, 4], "p": 1}),
                       ("fractal_ledger_verify", {}), ("fractal_agent_data_analyst", {"question": "q"}),
                       ("fractal_vectorizer_process_queue", {}), ("fractal_version", {})) * 2:
        runs += 1
        r = rpc("tools/call", {"name": tool, "arguments": args})
        check("druid under %s: %s answers or ends in order" % (env_fault["FSQL_FAULT"], tool), r is None or isinstance(r, dict), r)
        if isinstance(r, dict):
            answered += 1
        if r is None:
            break
    alive = p.poll() is None
    try:
        p.stdin.close()
    except OSError:
        pass
    try:
        p.wait(10)
    except subprocess.TimeoutExpired:
        p.kill()
    return alive or answered > 0


def main():
    work = tempfile.mkdtemp(prefix="fsql-faultshim-")
    shim = os.path.join(work, "syscall_fault.so")
    if subprocess.call(["cc", "-shared", "-fPIC", "-O1", "-o", shim, os.path.join(here, "syscall_fault.c"), "-ldl"],
                       stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL) != 0:
        print("SKIP no C compiler for the fault shim")
        return 0
    mock = subprocess.Popen([sys.executable, "-I", os.path.join(here, "mock_druid.py"), "0"], stdout=subprocess.PIPE, text=True)
    url = "http://127.0.0.1:%d" % int(mock.stdout.readline())
    try:
        for spec in SPECS:
            run_http({"FSQL_FAULT": spec}, shim, url)
            run_druid({"FSQL_FAULT": spec}, shim, url)
        # the server must be healthy again with no fault
        run_http({"FSQL_FAULT": "recv=EINTR/1000000"}, shim, url)
    finally:
        mock.kill()
        shutil.rmtree(work, ignore_errors=True)
    print("syscall faults: %d fault settings, %d requests; %d failure(s)" % (len(SPECS), runs, len(failures)))
    return 1 if failures else 0


if __name__ == "__main__":
    sys.exit(main())
