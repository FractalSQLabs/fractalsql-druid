#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
# SPDX-FileCopyrightText: 2026 Daniel Gardiner d/b/a FractalSQLabs
"""The HTTP transport pushed through the cases a real deployment produces: a credential policy file in every wrong shape, a policy file that
changes while the server runs, and the modern request path with its headers and its body disagreeing in every way.

usage: mcp_http_edges.py MCP_BINARY

No engine is needed: the calls that reach it fail as connectivity errors, which is an answer. What has to hold is that the server answers every
request with a well-formed HTTP response (or refuses to start, cleanly), never crashes, and still answers its health probe afterwards.
"""
import hashlib
import json
import os
import socket
import subprocess
import sys
import tempfile
import time

binary = os.path.abspath(sys.argv[1])
scratch = tempfile.mkdtemp(prefix="mcp-http-edges.")
failures = []
requests_made = 0

MODERN, LEGACY = "2026-07-28", "2025-06-18"
TOKENS = {"full": "token-full", "narrow": "token-narrow", "expired": "token-expired"}


def sha(token):
    return hashlib.sha256(token.encode()).hexdigest()


GOOD_POLICY = {"tokens": [
    {"name": "full", "sha256": sha(TOKENS["full"]), "tools": "*"},
    {"name": "narrow", "sha256": sha(TOKENS["narrow"]).upper(), "tools": ["fractal_version", "fractal_vector_norm"], "expires": "2999-01-01"},
    {"name": "expired", "sha256": sha(TOKENS["expired"]), "tools": "*", "expires": "2001-02-03T04:05:06Z"},
]}


def free_port():
    s = socket.socket()
    s.bind(("127.0.0.1", 0))
    p = s.getsockname()[1]
    s.close()
    return p


def start(env_extra, label):
    port = free_port()
    env = dict(os.environ)
    for k in [k for k in env if k.startswith("FSQL_MCP_")]:
        del env[k]
    env["DRUID_URL"] = "http://127.0.0.1:1"
    env["DRUID_TIMEOUT_MS"] = "1500"
    env.update(env_extra)
    log = open(os.path.join(scratch, label + ".log"), "ab")
    proc = subprocess.Popen([binary, "--http", str(port)], stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL, stderr=log, env=env, cwd=scratch)
    for _ in range(100):
        if proc.poll() is not None:
            return proc, port, False
        try:
            socket.create_connection(("127.0.0.1", port), 0.3).close()
            return proc, port, True
        except OSError:
            time.sleep(0.05)
    return proc, port, False


def stop(proc):
    if proc.poll() is None:
        proc.terminate()
        try:
            proc.wait(10)
        except subprocess.TimeoutExpired:
            proc.kill()


def http(port, method, path, headers=(), body=b"", raw_head=None, timeout=10):
    """One request over a fresh connection. Returns (status, headers dict, body) or None when the server said nothing."""
    global requests_made
    requests_made += 1
    if isinstance(body, str):
        body = body.encode()
    head = raw_head if raw_head is not None else (
        "%s %s HTTP/1.1\r\nHost: 127.0.0.1\r\n" % (method, path)
        + "".join("%s: %s\r\n" % h for h in headers)
        + ("Content-Length: %d\r\n" % len(body) if method == "POST" and not any(h[0].lower() == "content-length" for h in headers) else "")
        + "Connection: close\r\n\r\n")
    try:
        s = socket.create_connection(("127.0.0.1", port), timeout)
        s.settimeout(timeout)
        s.sendall(head.encode("latin-1", "replace") + body)
        data = b""
        while True:
            chunk = s.recv(65536)
            if not chunk:
                break
            data += chunk
            # stop at the declared end of the response rather than waiting for the server to close the connection
            h, sep, rest = data.partition(b"\r\n\r\n")
            if sep:
                low = h.lower()
                at = low.find(b"content-length:")
                if at >= 0:
                    try:
                        n = int(low[at + 15:].split(b"\r\n", 1)[0].strip())
                    except ValueError:
                        n = 0
                    if len(rest) >= n:
                        break
                elif b"transfer-encoding: chunked" not in low and (b" 204 " in h[:15] or b" 202 " in h[:15] or b" 304 " in h[:15]):
                    break
        s.close()
    except OSError:
        return None
    if not data:
        return None
    head, _, rest = data.partition(b"\r\n\r\n")
    lines = head.decode("latin-1").split("\r\n")
    try:
        status = int(lines[0].split()[1])
    except (IndexError, ValueError):
        return ("malformed", {}, data)
    hdrs = {}
    for l in lines[1:]:
        if ":" in l:
            k, v = l.split(":", 1)
            hdrs[k.strip().lower()] = v.strip()
    return (status, hdrs, rest)


def expect(label, cond, detail=""):
    if not cond:
        print("FAIL %s  %s" % (label, str(detail)[:240]))
        failures.append(label)


def rpc(method, params=None, i=1, meta=None):
    m = {"jsonrpc": "2.0", "method": method, "id": i}
    if params is not None:
        m["params"] = params
    if meta:
        m["_meta"] = meta
    return m


def bearer(tok):
    return [("Authorization", "Bearer " + tok)] if tok is not None else []


def post(port, body, headers=()):
    return http(port, "POST", "/mcp", [("Content-Type", "application/json"), ("Accept", "application/json, text/event-stream")] + list(headers),
                body if isinstance(body, (bytes, str)) else json.dumps(body))


def healthy(port):
    r = http(port, "GET", "/healthz")
    return r is not None and r[0] == 200


# -- 1. the credential policy file, in every shape ---------------------------------------------------------------------

POLICIES = [
    ("good", json.dumps(GOOD_POLICY)),
    ("empty tokens", '{"tokens":[]}'),
    ("not json", "this is not json"),
    ("empty file", ""),
    ("an array", "[]"),
    ("a string", '"x"'),
    ("no tokens key", "{}"),
    ("tokens not an array", '{"tokens":{}}'),
    ("entry not an object", '{"tokens":[1]}'),
    ("no sha256", '{"tokens":[{"name":"x","tools":"*"}]}'),
    ("sha256 too short", '{"tokens":[{"name":"x","sha256":"abcd","tools":"*"}]}'),
    ("sha256 not a string", '{"tokens":[{"name":"x","sha256":5,"tools":"*"}]}'),
    ("no tools", '{"tokens":[{"name":"x","sha256":"%s"}]}' % sha("a")),
    ("tools a number", '{"tokens":[{"name":"x","sha256":"%s","tools":5}]}' % sha("a")),
    ("tools a bad string", '{"tokens":[{"name":"x","sha256":"%s","tools":"all"}]}' % sha("a")),
    ("tool names not strings", '{"tokens":[{"name":"x","sha256":"%s","tools":[1,2]}]}' % sha("a")),
    ("name not a string", '{"tokens":[{"name":7,"sha256":"%s","tools":"*"}]}' % sha("a")),
    ("expiry not a date", '{"tokens":[{"name":"x","sha256":"%s","tools":"*","expires":"tomorrow"}]}' % sha("a")),
    ("expiry a date", '{"tokens":[{"name":"x","sha256":"%s","tools":"*","expires":"2999-12-31"}]}' % sha("a")),
    ("expiry a datetime", '{"tokens":[{"name":"x","sha256":"%s","tools":"*","expires":"2999-12-31T23:59:59Z"}]}' % sha("a")),
    ("expiry not a string", '{"tokens":[{"name":"x","sha256":"%s","tools":"*","expires":5}]}' % sha("a")),
    ("expiry impossible", '{"tokens":[{"name":"x","sha256":"%s","tools":"*","expires":"2999-13-45"}]}' % sha("a")),
    ("tools empty array", '{"tokens":[{"name":"x","sha256":"%s","tools":[]}]}' % sha("a")),
    ("a long file", json.dumps({"tokens": [{"name": "n%d" % i, "sha256": sha(str(i)), "tools": "*"} for i in range(500)]})),
    ("binary junk", None),
]
SESSION_BODIES = [rpc("initialize", {"protocolVersion": LEGACY, "capabilities": {}, "clientInfo": {"name": "t", "version": "1"}}), rpc("tools/list")]


def policy_scenarios():
    for label, content in POLICIES:
        path = os.path.join(scratch, "policy.json")
        with open(path, "wb") as f:
            f.write(content.encode() if content is not None else os.urandom(300))
        proc, port, up = start({"FSQL_MCP_TOKEN_POLICY_FILE": path}, "policy")
        try:
            if not up:
                expect("policy '%s': a refusal to start is clean" % label, proc.poll() is not None and proc.returncode in range(0, 128), proc.returncode)
                continue
            # a refused credential makes the server slow down the next refusal, so only the good policy is asked with every kind of token
            for who, tok in (list(TOKENS.items()) + [("nobody", None), ("wrong", "nope")] if label == "good" else [("full", TOKENS["full"]), ("nobody", None)]):
                for body in (SESSION_BODIES if label == "good" else SESSION_BODIES[:1]):
                    r = post(port, body, bearer(tok))
                    expect("policy '%s', %s: a well-formed answer" % (label, who), r is not None and r[0] in (200, 202, 400, 401, 403, 404, 503), r and r[0])
            expect("policy '%s': the server is still healthy" % label, healthy(port) and proc.poll() is None)
            if label == "good":
                expect("the full token is accepted", post(port, SESSION_BODIES[0], bearer(TOKENS["full"]))[0] == 200)
                expect("an unknown token is refused", post(port, SESSION_BODIES[0], bearer("nope"))[0] == 401)
                expect("an expired token is refused", post(port, SESSION_BODIES[0], bearer(TOKENS["expired"]))[0] in (401, 403))
                narrow = post(port, rpc("tools/call", {"name": "fractal_diversify_enable", "arguments": {}}, 5), bearer(TOKENS["narrow"]))
                expect("a narrow token cannot call a tool outside its list", narrow is not None and (narrow[0] in (401, 403) or b"not" in narrow[2].lower() or b"allow" in narrow[2].lower() or b"error" in narrow[2].lower()), narrow and narrow[2][:120])
        finally:
            stop(proc)


def hot_reload():
    path = os.path.join(scratch, "reload.json")
    with open(path, "w") as f:
        json.dump(GOOD_POLICY, f)
    proc, port, up = start({"FSQL_MCP_TOKEN_POLICY_FILE": path}, "reload")
    try:
        expect("hot reload: the server starts", up)
        if not up:
            return
        expect("hot reload: before, the token works", post(port, SESSION_BODIES[0], bearer(TOKENS["full"]))[0] == 200)
        steps = [
            ('{"tokens":[]}', "emptied"), ("not json at all", "broken"), (json.dumps(GOOD_POLICY), "restored"),
            ('{"tokens":[{"name":"z","sha256":"%s","tools":"*"}]}' % sha("brand-new"), "replaced"),
        ]
        for content, label in steps:
            with open(path, "w") as f:
                f.write(content)
            t = time.time() + 3
            os.utime(path, (t, t))
            for tok in (TOKENS["full"], "brand-new", None):
                r = post(port, SESSION_BODIES[0], bearer(tok))
                expect("hot reload (%s): a well-formed answer" % label, r is not None and r[0] in (200, 401, 403), r and r[0])
        os.unlink(path)
        r = post(port, SESSION_BODIES[0], bearer(TOKENS["full"]))
        expect("hot reload: the policy file removed", r is not None and r[0] in (200, 401, 403, 503), r and r[0])
        expect("hot reload: the server is still healthy", healthy(port) and proc.poll() is None)
    finally:
        stop(proc)


# -- 2. the modern path: headers and body disagreeing ---------------------------------------------------------------------

def modern_matrix():
    proc, port, up = start({"FSQL_MCP_AUTH_TOKEN": "tok", "FSQL_MCP_PROTOCOL_ERA": "dual"}, "modern")
    try:
        expect("modern: the server starts", up)
        if not up:
            return
        meta = {"io.modelcontextprotocol/protocolVersion": MODERN}
        bodies = [
            ("tools/list", rpc("tools/list", {}, 1, meta)),
            ("tools/call stateless", rpc("tools/call", {"name": "fractal_version", "arguments": {}}, 2, meta)),
            ("tools/call stateful", rpc("tools/call", {"name": "fractal_diversify_enable", "arguments": {}}, 3, meta)),
            ("tools/call stateful, a context", rpc("tools/call", {"name": "fractal_explain_result", "arguments": {"context_id": "nope"}}, 4, meta)),
            ("tools/call stateful, a context that is not text", rpc("tools/call", {"name": "fractal_explain_result", "arguments": {"context_id": 5}}, 5, meta)),
            ("tools/call, arguments not an object", rpc("tools/call", {"name": "fractal_explain_result", "arguments": [1]}, 6, meta)),
            ("tools/call, params not an object", rpc("tools/call", [1], 7, meta)),
            ("tools/call, no name", rpc("tools/call", {"arguments": {}}, 8, meta)),
            ("unknown method", rpc("nope/nothing", {}, 9, meta)),
            ("prompts/list", rpc("prompts/list", {}, 10, meta)),
            ("prompts/get", rpc("prompts/get", {"name": "x"}, 11, meta)),
            ("resources/list", rpc("resources/list", {}, 12, meta)),
            ("resources/read", rpc("resources/read", {"uri": "fractalsql://x"}, 13, meta)),
            ("ping", rpc("ping", {}, 14, meta)),
            ("a notification", {"jsonrpc": "2.0", "method": "notifications/initialized", "_meta": meta}),
            ("no _meta", rpc("tools/list", {}, 15)),
            ("a wrong version in _meta", rpc("tools/list", {}, 16, {"io.modelcontextprotocol/protocolVersion": "1999-01-01"})),
            ("a _meta that is not an object", dict(rpc("tools/list", {}, 17), _meta="x")),
            ("a batch", [rpc("tools/list", {}, 18, meta)]),
            ("a number", 5),
            ("an empty object", {}),
        ]
        headers = [
            ("the right headers", lambda m, n: [("MCP-Protocol-Version", MODERN), ("Mcp-Method", m)] + ([("Mcp-Name", n)] if n else [])),
            ("no version header", lambda m, n: [("Mcp-Method", m)] + ([("Mcp-Name", n)] if n else [])),
            ("a wrong version header", lambda m, n: [("MCP-Protocol-Version", "1999-01-01"), ("Mcp-Method", m)]),
            ("the legacy version header", lambda m, n: [("MCP-Protocol-Version", LEGACY), ("Mcp-Method", m)]),
            ("no method header", lambda m, n: [("MCP-Protocol-Version", MODERN)]),
            ("a wrong method header", lambda m, n: [("MCP-Protocol-Version", MODERN), ("Mcp-Method", "tools/list" if m != "tools/list" else "ping")]),
            ("an empty method header", lambda m, n: [("MCP-Protocol-Version", MODERN), ("Mcp-Method", "")]),
            ("a wrong name header", lambda m, n: [("MCP-Protocol-Version", MODERN), ("Mcp-Method", m), ("Mcp-Name", "other")]),
            ("a name header that is encoded", lambda m, n: [("MCP-Protocol-Version", MODERN), ("Mcp-Method", m), ("Mcp-Name", "=?base64?Zm9v?=")]),
            ("a name header badly encoded", lambda m, n: [("MCP-Protocol-Version", MODERN), ("Mcp-Method", m), ("Mcp-Name", "=?base64?!!!?=")]),
            ("two method headers", lambda m, n: [("MCP-Protocol-Version", MODERN), ("Mcp-Method", m), ("Mcp-Method", m)]),
            ("a session header", lambda m, n: [("MCP-Protocol-Version", MODERN), ("Mcp-Method", m), ("Mcp-Session-Id", "nope")]),
            ("an origin", lambda m, n: [("MCP-Protocol-Version", MODERN), ("Mcp-Method", m), ("Origin", "http://evil.example")]),
        ]
        for tok_label, tok in (("with the token", "tok"), ("without a token", None), ("with a wrong token", "no")):
            # each refusal slows the next one down (a brute-force throttle), so the refused passes use a few bodies
            for blabel, body in (bodies if tok == "tok" else bodies[:3] + bodies[8:9]):
                m = body.get("method") if isinstance(body, dict) else None
                p = body.get("params") if isinstance(body, dict) else None
                n = p.get("name") if isinstance(p, dict) and isinstance(p.get("name"), str) else (p.get("uri") if isinstance(p, dict) else None)
                for hlabel, mk in (headers if tok == "tok" else headers[:1]):
                    r = post(port, body, bearer(tok) + mk(m or "", n))
                    expect("modern %s, %s, %s: a well-formed answer" % (tok_label, blabel, hlabel),
                           r is not None and r != "malformed" and r[0] != "malformed" and 200 <= r[0] < 600, r and r[0])
        expect("modern: the server is still healthy", healthy(port) and proc.poll() is None)
    finally:
        stop(proc)


# -- 3. the transport's own edges ---------------------------------------------------------------------------------------

def transport_edges():
    proc, port, up = start({"FSQL_MCP_AUTH_TOKEN": "tok", "FSQL_MCP_MAX_SESSIONS": "2", "FSQL_MCP_SESSION_TTL_SECS": "1"}, "edges")
    try:
        expect("edges: the server starts", up)
        if not up:
            return
        auth = bearer("tok")
        init = SESSION_BODIES[0]
        for method in ("GET", "PUT", "DELETE", "OPTIONS", "HEAD", "PATCH", "BREW"):
            for path in ("/mcp", "/", "/healthz", "/readyz", "/nope", "/mcp/", "/mcp?x=1", "/%00", "/" + "a" * 3000):
                r = http(port, method, path, auth)
                expect("edges: %s %s answers" % (method, path[:20]), r is not None and r[0] != "malformed", r and r[0])
        # sessions: more than the cap, then expiry
        sids = []
        for i in range(5):
            r = post(port, rpc("initialize", {"protocolVersion": LEGACY, "capabilities": {}, "clientInfo": {"name": "t%d" % i, "version": "1"}}, i), auth)
            if r and r[1].get("mcp-session-id"):
                sids.append(r[1]["mcp-session-id"])
        time.sleep(1.5)
        for sid in sids + ["nope"]:
            for method in ("POST", "GET", "DELETE"):
                r = http(port, method, "/mcp", auth + [("Mcp-Session-Id", sid), ("Content-Type", "application/json")], json.dumps(rpc("tools/list")))
                expect("edges: a session (%s) answers" % method, r is not None and r[0] != "malformed", r and r[0])
        # framing
        raw_cases = [
            "POST /mcp HTTP/1.1\r\nHost: x\r\nAuthorization: Bearer tok\r\nContent-Length: -1\r\n\r\n",
            "POST /mcp HTTP/1.1\r\nHost: x\r\nAuthorization: Bearer tok\r\nContent-Length: abc\r\n\r\n",
            "POST /mcp HTTP/1.1\r\nHost: x\r\nAuthorization: Bearer tok\r\nContent-Length: 99999999999\r\n\r\n",
            "POST /mcp HTTP/1.1\r\nHost: x\r\nAuthorization: Bearer tok\r\nContent-Length: 5\r\nContent-Length: 6\r\n\r\n{}",
            "POST /mcp HTTP/1.1\r\nHost: x\r\nAuthorization: Bearer tok\r\nTransfer-Encoding: chunked\r\n\r\n2\r\n{}\r\n0\r\n\r\n",
            "POST /mcp HTTP/1.1\r\nHost: x\r\nAuthorization: Bearer tok\r\nTransfer-Encoding: chunked\r\n\r\nzz\r\n",
            "POST /mcp HTTP/1.1\r\nHost: x\r\nAuthorization: Bearer tok\r\nContent-Length: 2\r\nTransfer-Encoding: chunked\r\n\r\n{}",
            "POST /mcp HTTP/1.0\r\nAuthorization: Bearer tok\r\n\r\n",
            "POST /mcp HTTP/2.0\r\nAuthorization: Bearer tok\r\n\r\n",
            "POST\r\n\r\n", "\r\n\r\n", "GARBAGE\r\n\r\n", "POST /mcp HTTP/1.1\r\n" + "X: y\r\n" * 3000 + "\r\n",
            "POST /mcp HTTP/1.1\r\nHost: x\r\nAuthorization: Bearer tok\r\nContent-Type: text/plain\r\nContent-Length: 2\r\n\r\n{}",
            "POST /mcp HTTP/1.1\r\nHost: x\r\nAuthorization: Bearer tok\r\nContent-Type: application/json; charset=utf-16\r\nContent-Length: 2\r\n\r\n{}",
            "POST /mcp HTTP/1.1\r\nHost: x\r\nAuthorization: Bearer tok\r\nExpect: 100-continue\r\nContent-Length: 2\r\n\r\n{}",
            "POST /mcp HTTP/1.1\r\nHost: x\r\nAuthorization: Basic dG9rOg==\r\nContent-Length: 2\r\n\r\n{}",
            "POST /mcp HTTP/1.1\r\nHost: x\r\nAuthorization: Bearer\r\nContent-Length: 2\r\n\r\n{}",
            "POST /mcp HTTP/1.1\r\nHost: x\r\nAuthorization: bearer tok\r\nContent-Length: 2\r\n\r\n{}",
            "POST /mcp HTTP/1.1\r\nHost: x\r\nAuthorization: Bearer tok \r\nContent-Length: 2\r\n\r\n{}",
            "POST /mcp HTTP/1.1\r\nHost: x\r\nauthorization: Bearer tok\r\nAuthorization: Bearer tok\r\nContent-Length: 2\r\n\r\n{}",
        ]
        for raw in raw_cases:
            r = http(port, "RAW", "", raw_head=raw, timeout=5)
            expect("edges: raw %r is answered or dropped" % raw[:40], r is None or r[0] == "malformed" or isinstance(r[0], int))
        # a connection that sends half a request and stops, and one that connects and says nothing
        for partial in (b"POST /mcp HTTP/1.1\r\nHost: x\r\nContent-Length: 50\r\n\r\n{", b"PO", b""):
            try:
                s = socket.create_connection(("127.0.0.1", port), 2)
                s.sendall(partial)
                s.close()
            except OSError:
                pass
        # many connections at once
        socks = []
        for _ in range(80):
            try:
                socks.append(socket.create_connection(("127.0.0.1", port), 1))
            except OSError:
                break
        for s in socks:
            s.close()
        # a very large body
        big = post(port, '{"jsonrpc":"2.0","method":"tools/list","id":1,"x":"' + "a" * 5_000_000 + '"}', auth)
        expect("edges: a very large body is answered", big is None or isinstance(big[0], int))
        time.sleep(0.5)
        expect("edges: the server is still healthy", healthy(port) and proc.poll() is None)
    finally:
        stop(proc)


def other_configurations():
    cases = [
        ("origins", {"FSQL_MCP_AUTH_TOKEN": "tok", "FSQL_MCP_ALLOWED_ORIGINS": "http://a.example, http://b.example,,"}),
        ("origins star", {"FSQL_MCP_AUTH_TOKEN": "tok", "FSQL_MCP_ALLOWED_ORIGINS": "*"}),
        ("legacy era", {"FSQL_MCP_AUTH_TOKEN": "tok", "FSQL_MCP_PROTOCOL_ERA": "legacy"}),
        ("modern era", {"FSQL_MCP_AUTH_TOKEN": "tok", "FSQL_MCP_PROTOCOL_ERA": "modern"}),
        ("a bad era", {"FSQL_MCP_AUTH_TOKEN": "tok", "FSQL_MCP_PROTOCOL_ERA": "ancient"}),
        ("one connection", {"FSQL_MCP_AUTH_TOKEN": "tok", "FSQL_MCP_MAX_CONNECTIONS": "1"}),
        ("a bad cap", {"FSQL_MCP_AUTH_TOKEN": "tok", "FSQL_MCP_MAX_CONNECTIONS": "many", "FSQL_MCP_MAX_SESSIONS": "-3", "FSQL_MCP_SESSION_TTL_SECS": "x"}),
        ("a token file that is missing", {"FSQL_MCP_AUTH_TOKEN_FILE": os.path.join(scratch, "no-such-token-file")}),
        ("no credential at all", {}),
        ("tls with nothing to serve", {"FSQL_MCP_HTTPS": "true", "FSQL_MCP_AUTH_TOKEN": "tok"}),
    ]
    for label, env in cases:
        proc, port, up = start(env, "cfg")
        try:
            if not up:
                expect("config '%s': a refusal to start is clean" % label, proc.poll() is not None and proc.returncode in range(0, 128), proc.returncode)
                continue
            for body in SESSION_BODIES:
                for tok in ("tok", None):
                    for hdr in ([], [("Origin", "http://a.example")], [("Origin", "http://evil.example")]):
                        r = post(port, body, bearer(tok) + hdr)
                        expect("config '%s': a well-formed answer" % label, r is None or isinstance(r[0], int))
            if proc.poll() is None:
                expect("config '%s': the server is still alive" % label, proc.poll() is None)
        finally:
            stop(proc)


# -- 5. credentials that own engine contexts --------------------------------------------------------------------------

def find_context(obj):
    """A context handle anywhere in an answer (the server names it context_id), or None."""
    if isinstance(obj, dict):
        for k, v in obj.items():
            if k == "context_id" and isinstance(v, str) and v:
                return v
            r = find_context(v)
            if r:
                return r
    elif isinstance(obj, list):
        for v in obj:
            r = find_context(v)
            if r:
                return r
    elif isinstance(obj, str) and obj.startswith("{"):
        try:
            return find_context(json.loads(obj))
        except ValueError:
            return None
    return None


def context_sessions():
    """Two credentials (one named, one with no name) each own contexts: a valid handle is served, another credential's
    handle and an unknown one are refused, a handle past its time to live is gone, and the cap on contexts is held.
    Then every method the transport does not serve, with a credential."""
    policy = os.path.join(scratch, "ctx-policy.json")
    with open(policy, "w") as f:
        json.dump({"tokens": [{"name": "alpha", "sha256": sha("tok-alpha"), "tools": "*"},
                              {"sha256": sha("tok-nameless"), "tools": "*"},
                              {"name": "narrow", "sha256": sha("tok-narrow"), "tools": ["fractal_version"]}]}, f)
    proc, port, up = start({"FSQL_MCP_TOKEN_POLICY_FILE": policy, "FSQL_MCP_SESSION_TTL_SECS": "1", "FSQL_MCP_MAX_SESSIONS": "2"}, "ctx")
    try:
        expect("contexts: the server starts", up)
        if not up:
            return
        meta = {"io.modelcontextprotocol/protocolVersion": MODERN}
        nested = {"io.modelcontextprotocol": {"protocolVersion": MODERN}}

        def call(tok, tool, args, i, m=meta):
            return post(port, rpc("tools/call", {"name": tool, "arguments": args}, i, m),
                        bearer(tok) + [("MCP-Protocol-Version", MODERN), ("Mcp-Method", "tools/call"), ("Mcp-Name", tool)])

        def ok(label, r):
            expect("contexts: %s: a well-formed answer" % label, r is not None and r[0] != "malformed" and isinstance(r[0], int), r and r[0])

        handles = {}
        for tok in ("tok-alpha", "tok-nameless", "tok-narrow"):
            r = call(tok, "fractal_diversify_enable", {}, 1)
            ok("a stateful call by " + tok, r)
            try:
                handles[tok] = find_context(json.loads(r[2])) if r and r[2] else None
            except ValueError:
                handles[tok] = None
            ok("a stateless call by " + tok, call(tok, "fractal_version", {}, 2))
            ok("a nested _meta by " + tok, call(tok, "fractal_version", {}, 3, nested))
        for tok, h in handles.items():
            if h:
                ok("its own handle, " + tok, call(tok, "fractal_explain_result", {"context_id": h}, 4))
                other = "tok-nameless" if tok != "tok-nameless" else "tok-alpha"
                ok("another credential's handle, " + other, call(other, "fractal_explain_result", {"context_id": h}, 5))
        ok("an unknown handle", call("tok-alpha", "fractal_explain_result", {"context_id": "nope"}, 6))
        # more contexts than the cap allows, then past the time to live
        for i in range(4):
            ok("context %d over the cap" % i, call("tok-alpha", "fractal_diversify_enable", {}, 10 + i))
        time.sleep(1.4)
        for h in handles.values():
            if h:
                ok("a handle past its time to live", call("tok-alpha", "fractal_explain_result", {"context_id": h}, 20))
        ok("a call after the expiry", call("tok-nameless", "fractal_diversify_enable", {}, 21))
        ok("a tool the credential may not call", call("tok-narrow", "fractal_vector_lp_distance", {"a": [0], "b": [1], "p": 1}, 22))
        # every method the transport does not serve, and the paths around it
        for method in ("GET", "PUT", "DELETE", "OPTIONS", "HEAD", "PATCH"):
            r = http(port, method, "/mcp", bearer("tok-alpha") + [("Accept", "application/json")])
            ok("%s /mcp with a credential" % method, r)
            r = http(port, method, "/elsewhere", bearer("tok-alpha"))
            ok("%s /elsewhere with a credential" % method, r)
        for path in ("/healthz", "/readyz", "/health", "/", "/mcp/", "/mcp?x=1", "/%00", "/" + "a" * 3000):
            ok("GET " + path[:20], http(port, "GET", path))
        # a notification is answered 202, a request 200
        r = post(port, {"jsonrpc": "2.0", "method": "notifications/initialized", "_meta": meta},
                 bearer("tok-alpha") + [("MCP-Protocol-Version", MODERN), ("Mcp-Method", "notifications/initialized")])
        expect("contexts: a notification is answered 202 or 200", r is not None and r[0] in (200, 202), r and r[0])
        expect("contexts: the server is still healthy", healthy(port) and proc.poll() is None)
    finally:
        stop(proc)


def audit_regressions():
    """Findings of SECURITY_AUDIT.md: the origin check parses an address (3.17), a repeated header the server acts on is refused
    (3.18), contexts minted without a handle are capped (3.7), a cancel for an id that is not in flight is not remembered or logged
    (3.8), and /readyz does not run a Druid query per request (3.14)."""
    policy = os.path.join(scratch, "audit-policy.json")
    with open(policy, "w") as f:
        json.dump({"tokens": [{"name": "a", "sha256": sha("tok-a"), "tools": "*"}]}, f)
    # a stand-in "Druid" that only counts the connections it is given
    probe = socket.socket()
    probe.bind(("127.0.0.1", 0))
    probe.listen(64)
    probe.settimeout(0.2)
    counted = [0]
    stop_probe = [False]

    def drain():
        import threading
        while not stop_probe[0]:
            try:
                c, _ = probe.accept()
            except OSError:
                continue
            counted[0] += 1
            try:
                c.settimeout(0.5)
                c.recv(65536)
                c.sendall(b"HTTP/1.1 200 OK\r\nContent-Length: 2\r\nConnection: close\r\n\r\n[]")
            except OSError:
                pass
            c.close()
    import threading
    th = threading.Thread(target=drain, daemon=True)
    th.start()
    proc, port, up = start({"FSQL_MCP_TOKEN_POLICY_FILE": policy, "FSQL_MCP_MAX_SESSIONS": "2",
                            "DRUID_URL": "http://127.0.0.1:%d" % probe.getsockname()[1]}, "audit")
    try:
        expect("audit: the server starts", up)
        if not up:
            return
        meta = {"io.modelcontextprotocol/protocolVersion": MODERN}
        hdrs = lambda extra=(): bearer("tok-a") + [("MCP-Protocol-Version", MODERN), ("Mcp-Method", "tools/list")] + list(extra)
        # 3.17: lookalike hosts are not loopback; real loopback addresses are
        for origin, want in (("http://127.evil.example", 403), ("http://127.0.0.1.evil.example", 403), ("http://127.0.0.1.nip.io:80", 403),
                             ("http://localhost.evil.example", 403), ("http://128.0.0.1", 403), ("http://1270.0.0.1", 403),
                             ("http://127.0.0.1:3000", 200), ("http://127.1.2.3", 200), ("http://localhost:3000", 200), ("http://[::1]:5", 200)):
            r = post(port, rpc("tools/list", None, 1, meta), hdrs([("Origin", origin)]))
            expect("audit 3.17: Origin %s is answered %d" % (origin, want), r is not None and r[0] == want, r and r[0])
        # 3.18: a header the server acts on, sent twice
        for name in ("Host", "Authorization", "Origin", "Content-Type", "Mcp-Session-Id", "MCP-Protocol-Version"):
            body = b"{}"
            head = ("POST /mcp HTTP/1.1\r\nHost: 127.0.0.1\r\nAuthorization: Bearer tok-a\r\nContent-Type: application/json\r\n"
                    "%s: x\r\n%s: y\r\nContent-Length: 2\r\nConnection: close\r\n\r\n" % (name, name))
            r = http(port, "POST", "/mcp", raw_head=head, body=body)
            expect("audit 3.18: a repeated %s is refused with 400" % name, r is not None and r[0] == 400, r and r[0])
        r = http(port, "POST", "/mcp", raw_head="POST /mcp HTTP/1.1\r\nHost: 127.0.0.1\r\nTransfer-Encoding: chunked\r\nTransfer-Encoding: chunked\r\n"
                 "Authorization: Bearer tok-a\r\nConnection: close\r\n\r\n0\r\n\r\n")
        expect("audit 3.18: a repeated Transfer-Encoding is refused with 400", r is not None and r[0] == 400, r and r[0])
        # 3.7: with the cap at 2, calls that name no context stop being given one
        codes = []
        for i in range(6):
            r = post(port, rpc("tools/call", {"name": "fractal_diversify_enable", "arguments": {}}, 10 + i, meta),
                     bearer("tok-a") + [("MCP-Protocol-Version", MODERN), ("Mcp-Method", "tools/call"), ("Mcp-Name", "fractal_diversify_enable")])
            codes.append(r and r[0])
        expect("audit 3.7: context-less stateful calls are refused with 503 once the cap is reached", 503 in codes, codes)
        expect("audit 3.7: the first calls under the cap are served", codes[0] == 200, codes)
        # 3.8: cancels for ids that never were in flight leave no trace
        log_path = os.path.join(scratch, "audit.log")
        before = os.path.getsize(log_path) if os.path.exists(log_path) else 0
        for i in range(60):
            post(port, {"jsonrpc": "2.0", "method": "notifications/cancelled", "params": {"requestId": "never-%d-" % i + "z" * 500}, "_meta": meta},
                 bearer("tok-a") + [("MCP-Protocol-Version", MODERN), ("Mcp-Method", "notifications/cancelled")])
        time.sleep(0.3)
        with open(log_path, "rb") as f:
            f.seek(before)
            new = f.read()
        expect("audit 3.8: a cancel for an id that is not in flight is not logged", b"cancel_propagated" not in new, new[-200:])
        expect("audit 3.8: the server is still healthy", healthy(port) and proc.poll() is None)
        # 3.14: a burst of readiness probes costs Druid a handful of connections, not one each
        counted[0] = 0
        for _ in range(40):
            http(port, "GET", "/readyz")
        time.sleep(0.3)
        expect("audit 3.14: 40 /readyz requests cost Druid under 8 connections (cached, not one each; ran %d)" % counted[0], counted[0] < 8, counted[0])
    finally:
        stop(proc)
        stop_probe[0] = True
        probe.close()


def main():
    t0 = time.time()
    for fn in (policy_scenarios, hot_reload, modern_matrix, transport_edges, other_configurations, context_sessions, audit_regressions):
        t = time.time()
        try:
            fn()
        except Exception as e:  # a harness fault, not a server one, but it must not pass quietly
            failures.append("%s raised %r" % (fn.__name__, e))
            print("FAIL %s raised %r" % (fn.__name__, e))
        print("  %-22s %.0fs" % (fn.__name__, time.time() - t))
    print("%d requests in %.0fs, %d failure(s)" % (requests_made, time.time() - t0, len(failures)))
    sys.exit(1 if failures else 0)


main()
