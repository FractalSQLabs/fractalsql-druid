#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
# SPDX-FileCopyrightText: 2026 Daniel Gardiner d/b/a FractalSQLabs
"""Drives the MCP server against a stand-in Druid (mock_druid.py) with no cluster.

A healthy Druid first: every tool, resource, prompt and protocol method is swept
(mcp_mutate.py), so each tool's call, result-handling and error paths run against
answers of many shapes. Then each way an engine or a proxy in front of it can
fail (error statuses, a body that is not JSON, a bad chunk, a cut-off reply, a
reply that is not HTTP, a closed connection, a slow reply): the sweep must still
see well-formed answers, never a crash and never the "server" error class.

usage: mcp_mock_sweep.py PATH_TO_SERVER
  MCP_MOCK_STRIDE=N   keep every Nth mutation in the failure modes (default 40)
"""
import os
import subprocess
import sys
import urllib.request

here = os.path.dirname(os.path.abspath(__file__))
binary = sys.argv[1]
stride = os.environ.get("MCP_MOCK_STRIDE", "40")

mock = subprocess.Popen([sys.executable, "-I", os.path.join(here, "mock_druid.py"), "0"], stdout=subprocess.PIPE, text=True)
port = int(mock.stdout.readline())
url = "http://127.0.0.1:%d" % port
failed = []


def mode(name):
    urllib.request.urlopen(url + "/_mode/" + name, timeout=5).read()


def sweep(label, env_extra):
    env = dict(os.environ, FSQL_MUTATE_URL=url, **env_extra)
    r = subprocess.run([sys.executable, "-I", os.path.join(here, "mcp_mutate.py"), binary], env=env,
                       stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True, timeout=900)
    last = [l for l in r.stdout.splitlines() if l.startswith("mutate:") or "failure" in l]
    print("  %-10s %s" % (label, " | ".join(last)))
    if r.returncode != 0:
        failed.append(label)
        for l in r.stdout.splitlines()[:12]:
            if l.startswith("FAIL"):
                print("    " + l)


try:
    mode("ok")
    sweep("ok", {"MCP_MUTATE_STRIDE": os.environ.get("MCP_MOCK_STRIDE_OK", "4"), "MCP_MUTATE_ALLOW_SERVER": "1"})
    mode("chunked")
    sweep("chunked", {"MCP_MUTATE_STRIDE": stride, "MCP_MUTATE_PARTS": "tools", "MCP_MUTATE_ALLOW_SERVER": "1"})
    mode("bigrows")
    sweep("bigrows", {"MCP_MUTATE_STRIDE": stride, "MCP_MUTATE_PARTS": "tools", "MCP_MUTATE_ALLOW_SERVER": "1"})
    for m in ("err500", "err502", "err401", "err403", "err404", "err400", "err429", "notjson", "scalar", "object", "emptybody",
              "close", "garbage", "truncated", "badchunk", "hugechunk", "shortchunk", "nostatus", "noheaders"):
        mode(m)
        sweep(m, {"MCP_MUTATE_STRIDE": "1000", "MCP_MUTATE_PARTS": "tools",
                  "MCP_MUTATE_ALLOW_SERVER": "1" if m in ("scalar", "object", "emptybody") else "0"})
    mode("slow")
    # Every reply takes longer than the server's own timeout, so each call waits out its retries; on a loaded machine (the stack
    # running beside it) that needs more than the default minute.
    sweep("slow", {"MCP_MUTATE_RPC_TIMEOUT": "240", "MCP_MUTATE_STRIDE": "1000", "MCP_MUTATE_PARTS": "tools", "MCP_MUTATE_ONLY": "fractal_version,fractal_vector_norm,fractal_agent_allocate"})
finally:
    mock.kill()
print("%d mode(s) failed" % len(failed))
sys.exit(1 if failed else 0)
