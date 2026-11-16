#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
# SPDX-FileCopyrightText: 2026 Daniel Gardiner d/b/a FractalSQLabs
"""The MCP server's connection to a Druid that speaks TLS, and to one that resets the connection.

usage: mcp_druid_tls.py PATH_TO_SERVER

mock_druid.py serves TLS when it is given a certificate (MOCK_TLS_CERT, MOCK_TLS_KEY). The server is then pointed at it
with https:// and each way the client can treat the certificate:

  DRUID_TLS_INSECURE=true     the certificate is not checked: the call is answered
  default                     the certificate is checked against the system's roots and fails: a connectivity error,
                              never a crash and never a silent fallback to plain text
  SSL_CERT_FILE=<the cert>    the certificate is checked against it and passes: the call is answered
  an https URL on a plain Druid   the handshake fails: a connectivity error

and, over plain HTTP, a Druid that resets the connection after reading the request. What must hold: a connectivity
error (never the "server" class), the server answers the next call, and it is still running at the end.
"""
import json
import os
import select
import shutil
import subprocess
import sys
import tempfile
import urllib.request

binary = os.path.abspath(sys.argv[1])
here = os.path.dirname(os.path.abspath(__file__))
failures = []


def check(name, cond, detail=""):
    print(("PASS " if cond else "FAIL ") + name + ("" if cond else "  " + str(detail)[:240]))
    if not cond:
        failures.append(name)


def mock(env_extra=None):
    p = subprocess.Popen([sys.executable, "-I", os.path.join(here, "mock_druid.py"), "0"], stdout=subprocess.PIPE, text=True,
                         env=dict(os.environ, **(env_extra or {})))
    return p, int(p.stdout.readline())


def set_mode(port, mode, scheme="http"):
    import ssl
    ctx = ssl.create_default_context()
    ctx.check_hostname = False
    ctx.verify_mode = ssl.CERT_NONE
    urllib.request.urlopen("%s://127.0.0.1:%d/_mode/%s" % (scheme, port, mode), timeout=10, context=ctx if scheme == "https" else None).read()


def session(env, calls):
    e = dict(os.environ, DRUID_TIMEOUT_MS="4000")
    for k in ("SSL_CERT_FILE", "DRUID_TLS_INSECURE", "DRUID_USER", "DRUID_PASSWORD", "DRUID_TOKEN"):
        e.pop(k, None)
    e.update(env)
    p = subprocess.Popen([binary], stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, text=True, env=e)
    out = []
    i = 0

    def rpc(method, params):
        nonlocal i
        i += 1
        p.stdin.write(json.dumps({"jsonrpc": "2.0", "id": i, "method": method, "params": params}) + "\n")
        p.stdin.flush()
        r, _, _ = select.select([p.stdout], [], [], 40)
        return json.loads(p.stdout.readline()) if r else None

    rpc("initialize", {"protocolVersion": "2025-06-18", "capabilities": {}, "clientInfo": {"name": "tls", "version": "1"}})
    for tool, args in calls:
        out.append(rpc("tools/call", {"name": tool, "arguments": args}))
    alive = p.poll() is None
    p.stdin.close()
    try:
        p.wait(10)
    except subprocess.TimeoutExpired:
        p.kill()
    return out, alive


def cls(r):
    res = (r or {}).get("result") or {}
    return (res.get("structuredContent") or {}).get("error_class") if res.get("isError") else None


def main():
    work = tempfile.mkdtemp(prefix="fsql-druid-tls-")
    cert, key = os.path.join(work, "c.pem"), os.path.join(work, "k.pem")
    cnf = os.path.join(work, "o.cnf")
    open(cnf, "w").write("[req]\ndistinguished_name=dn\nx509_extensions=v3\nprompt=no\n[dn]\nCN=127.0.0.1\n"
                         "[v3]\nsubjectAltName=IP:127.0.0.1,DNS:localhost\n")
    if subprocess.call(["openssl", "req", "-x509", "-newkey", "rsa:2048", "-nodes", "-days", "2", "-config", cnf,
                        "-keyout", key, "-out", cert], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL) != 0:
        print("SKIP no openssl to make a certificate")
        return 0
    V = [("fractal_version", {})]
    tls, tport = mock({"MOCK_TLS_CERT": cert, "MOCK_TLS_KEY": key})
    plain, pport = mock()
    try:
        url = "https://127.0.0.1:%d" % tport
        out, alive = session({"DRUID_URL": url, "DRUID_TLS_INSECURE": "true"}, V * 3)
        check("TLS, certificate not checked: the call is answered", all(r and cls(r) in (None, "server", "engine") for r in out), out)
        check("TLS, certificate not checked: the server is still running", alive)
        out, alive = session({"DRUID_URL": url}, V * 2)
        check("TLS, certificate checked and not trusted: a connectivity error", all(cls(r) == "connectivity" for r in out), out)
        check("TLS, certificate checked and not trusted: the server is still running", alive)
        out, alive = session({"DRUID_URL": url, "SSL_CERT_FILE": cert}, V * 3)
        check("TLS, certificate checked against its own file: the call is answered", all(r and cls(r) != "connectivity" for r in out), out)
        out, alive = session({"DRUID_URL": url, "DRUID_TLS_INSECURE": "true", "DRUID_USER": "u", "DRUID_PASSWORD": "p"}, V * 2)
        check("TLS with Basic credentials: answered", all(r and cls(r) != "connectivity" for r in out), out)
        out, alive = session({"DRUID_URL": url, "DRUID_TLS_INSECURE": "true", "DRUID_TOKEN": "t"}, V * 2)
        check("TLS with a bearer token: answered", all(r and cls(r) != "connectivity" for r in out), out)
        out, alive = session({"DRUID_URL": "https://127.0.0.1:%d" % pport, "DRUID_TLS_INSECURE": "true"}, V * 2)
        check("an https URL on a plain Druid: a connectivity error (the handshake fails)", all(cls(r) == "connectivity" for r in out), out)
        check("an https URL on a plain Druid: the server is still running", alive)
        # the connection reset after the request was read, then a good Druid again
        set_mode(pport, "reset")
        out, alive = session({"DRUID_URL": "http://127.0.0.1:%d" % pport}, V * 3)
        check("a Druid that resets the connection: a connectivity error, never the server class", all(cls(r) in ("connectivity", "engine") for r in out), out)
        check("a Druid that resets the connection: the server is still running", alive)
        for mode in ("close", "garbage", "truncated", "err401", "err403", "err502"):
            set_mode(pport, mode)
            out, alive = session({"DRUID_URL": "http://127.0.0.1:%d" % pport, "DRUID_USER": "u", "DRUID_PASSWORD": "p"}, V * 2)
            check("a Druid in mode %s: well-formed answers, the server is still running" % mode, all(r is not None for r in out) and alive, out)
        set_mode(pport, "ok")
    finally:
        tls.kill()
        plain.kill()
        shutil.rmtree(work, ignore_errors=True)
    print("%d failure(s)" % len(failures))
    return 1 if failures else 0


if __name__ == "__main__":
    sys.exit(main())
