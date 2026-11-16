#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
# SPDX-FileCopyrightText: 2026 Daniel Gardiner d/b/a FractalSQLabs
"""The MCP conformance driver (mcp_conformance.py) against a stand-in Druid (mock_druid.py): no cluster.

usage: conformance_mock.py PATH_TO_SERVER [GATE_NUMBER]

The driver checks the protocol eras, authentication, framing, the operator switches and the catalog's shape over the
server's real transports. None of that depends on what Druid answers, so it runs against the mock, in the default
(no Docker) run and under the coverage and sanitizer builds.
"""
import os
import subprocess
import sys
import tempfile

here = os.path.dirname(os.path.abspath(__file__))
server = os.path.abspath(sys.argv[1])
gate = sys.argv[2] if len(sys.argv) > 2 else "25"

mock = subprocess.Popen([sys.executable, "-I", os.path.join(here, "mock_druid.py"), "0"], stdout=subprocess.PIPE, text=True)
try:
    port = int(mock.stdout.readline())
    url = "http://127.0.0.1:%d" % port
    work = tempfile.mkdtemp(prefix="fsql-conformance-")
    env = dict(os.environ,
               MCP_SERVER_EXE=server, MCP_SERVER_CWD=work, MCPC_TOKEN="conformance-token", MCPC_GATE=gate,
               MCPC_LOCK_DIR=os.path.dirname(here), MCPC_PASSTHROUGH_ENV="DRUID_URL,DRUID_FRACTALSQL_URL",
               MCPC_READ_TOOL="fractal_version", MCPC_SAFE_KEY="reasoning_model", MCPC_UNSAFE_KEY="reasoning_url",
               MCPC_SECRET_KEY="reasoning_token",
               MCPC_SKIP="H02=Diversify state is a node-level setting on Druid, not per MCP context",
               DRUID_URL=url, DRUID_FRACTALSQL_URL=url)
    rc = subprocess.call([sys.executable, "-u", os.path.join(here, "mcp_conformance.py")], env=env, timeout=900)
finally:
    mock.kill()
sys.exit(rc)
