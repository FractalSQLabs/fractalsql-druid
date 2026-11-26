#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
# SPDX-FileCopyrightText: 2026 Daniel Gardiner d/b/a FractalSQLabs
"""A stand-in for a Druid router/broker, for exercising the MCP server's HTTP client
and result handling with no cluster.

It answers POST /druid/v2/sql and the extension's /fractalsql/* endpoints. What it
answers is set by a mode, changed at run time with GET /_mode/NAME, so one process
can play a healthy Druid and then every way a Druid (or a proxy in front of it)
goes wrong: error statuses, a body that is not JSON, a chunked body with a bad
chunk size, a response cut short, a reply that is not HTTP at all, a connection
closed with no reply, a slow reply.

usage: mock_druid.py PORT      (PORT 0 picks a free port and prints it)
"""
import json
import os
import socket
import sys
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

MODE = {"name": "ok"}
COUNT = {"n": 0}
LOCK = threading.Lock()

# What one result cell can look like to the client: numbers, text, a vector in the core's
# text form, a hex fingerprint, null, a boolean, a nested value, a JSON document.
CELLS = [
    1, "text", "[0.1,0.2,0.3]", "00ff10ab", None, 2.5, True, {"a": [1, 2]},
    "{\"freqs\":[1,2,3,4],\"power\":[1,2,3,4],\"indices\":[1,2,3,4],\"entropy\":[1,2,3,4]}",
    "[]", "", 7, "1e999", [1, 2],
]
SERVICE_BODIES = [
    {"ok": True}, {"result": [1, 2, 3]}, {"verify": "ok"}, {"rows": []}, [], "text", 12, None,
    {"error": "an error in a 200"}, {"items": [{"id": 1, "score": 0.5}], "partial": False},
]


def rotate():
    with LOCK:
        COUNT["n"] += 1
        return COUNT["n"]


class H(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def log_message(self, *a):
        pass

    def _send(self, status, body, ctype="application/json", extra=None):
        data = body if isinstance(body, bytes) else body.encode()
        self.send_response(status)
        self.send_header("Content-Type", ctype)
        self.send_header("Content-Length", str(len(data)))
        self.send_header("Connection", "close")
        for k, v in (extra or {}).items():
            self.send_header(k, v)
        self.end_headers()
        self.wfile.write(data)
        self.close_connection = True

    def _raw(self, data):
        try:
            self.wfile.write(data)
            self.wfile.flush()
        except OSError:
            pass
        self.close_connection = True

    def _body(self):
        n = int(self.headers.get("Content-Length") or 0)
        return self.rfile.read(n) if n else b""

    def _sql_rows(self, req):
        q = str(req.get("query", ""))
        if q.strip().upper() == "SELECT 1":
            return [[1]]
        if "FRACTAL_VERSION" in q.upper():
            return [["2.0.0"]]
        if req.get("header"):
            return [["c1", "c2"], [1, "a"]]
        n = rotate()
        if "FRACTAL_LOCK_DESTRUCTIVE" in q.upper():
            return [[1]]
        if n % 17 == 0:
            return []
        if n % 19 == 0:
            return [[1, 2, 3], [4, 5, 6]]
        return [[CELLS[n % len(CELLS)]]]

    def _serve(self, method):
        body = self._body()
        mode = MODE["name"]
        path = self.path
        if path.startswith("/_mode/"):
            MODE["name"] = path[len("/_mode/"):]
            return self._send(200, "{}")
        if path == "/status/health":
            return self._send(200, "true")
        if mode == "reset":
            import struct
            self.connection.setsockopt(socket.SOL_SOCKET, socket.SO_LINGER, struct.pack("ii", 1, 0))
            self.close_connection = True
            return
        if mode == "close":
            self.close_connection = True
            return
        if mode == "garbage":
            return self._raw(b"\x00\x01 not http at all\r\n\r\n")
        if mode == "truncated":
            return self._raw(b"HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: 500\r\n\r\n[[1")
        if mode == "badchunk":
            return self._raw(b"HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\nzz\r\n[[1]]\r\n0\r\n\r\n")
        if mode == "hugechunk":
            return self._raw(b"HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\nffffffffffffffffff\r\n[[1]]\r\n0\r\n\r\n")
        if mode == "shortchunk":
            return self._raw(b"HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\n40\r\n[[1]]\r\n")
        if mode == "nostatus":
            return self._raw(b"HTTP/1.1\r\n\r\n[[1]]")
        if mode == "noheaders":
            return self._raw(b"HTTP/1.1 200 OK")
        if mode == "endless":
            # a body that never ends: the client must stop reading at its own limit
            try:
                self.wfile.write(b"HTTP/1.1 200 OK\r\nContent-Type: application/json\r\n\r\n[")
                block = b"1," * 32768
                for _ in range(100000):
                    self.wfile.write(block)
            except OSError:
                pass
            self.close_connection = True
            return
        if mode == "slow":
            time.sleep(3)
        if mode in ("svc404", "svc405", "svc500") and path.startswith("/fractalsql/"):
            # a router that does not serve the extension's endpoints: SQL still works, /fractalsql/* does not
            return self._send(int(mode[3:]), json.dumps({"error": "mock: no such endpoint"}))
        if mode in ("err500", "err502", "err503", "err401", "err403", "err404", "err400", "err429"):
            st = int(mode[3:])
            # error texts shaped like the ones that leak a credential: the server must mask them before they reach a client
            leaks = ["connect to http://user:s3cret@db.example:8082/druid failed", "https://u:p@h and http://:x@h and ftp://a:@h and ://u:p@h",
                     "PASSWORD=hunter2 failed", "bad AUTH_TOKEN = abc123 value", "api_KEY=zzz and DB_PASSWORD  =  q and TOKEN=notmasked",
                     "KEY= and password= and _key=v", "x://u:p@" + "a" * 600 + " PASSWORD=" + "b" * 600, "=== = == PASSWORD", "PASSWORD=\tx\nAUTH_TOKEN=y"]
            kinds = [{"errorMessage": "mock failure"}, {"error": "mock failure"}, {"message": "mock failure"}, {"error": {"x": 1}}] \
                + [{"errorMessage": t} for t in leaks]
            n = rotate()
            if n % 6 == 0:
                return self._send(st, "plain text failure", "text/plain")
            if n % 7 == 0:
                return self._send(st, "")
            if n % 11 == 0:
                return self._send(st, "x" * 900, "text/plain")
            return self._send(st, json.dumps(kinds[n % len(kinds)]))
        if mode == "notjson":
            return self._send(200, "<html>proxy error</html>", "text/html")
        if mode == "scalar":
            return self._send(200, "42")
        if mode == "object":
            return self._send(200, json.dumps({"a": 1}))
        if mode == "emptybody":
            return self._send(200, "")
        if mode == "chunked":
            payload = self._payload(method, path, body)
            data = payload.encode()
            out = b"HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nTransfer-Encoding: chunked\r\n\r\n"
            half = max(1, len(data) // 2)
            for part in (data[:half], data[half:]):
                if part:
                    out += b"%x\r\n" % len(part) + part + b"\r\n"
            out += b"0\r\n\r\n"
            return self._raw(out)
        if mode == "bigrows":
            if path == "/druid/v2/sql":
                return self._send(200, json.dumps([[i, "row %d" % i] for i in range(6000)]))
        return self._send(200, self._payload(method, path, body))

    def _payload(self, method, path, body):
        if path == "/druid/v2/sql":
            try:
                req = json.loads(body or b"{}")
            except ValueError:
                req = {}
            return json.dumps(self._sql_rows(req))
        if path.startswith("/fractalsql/"):
            return json.dumps(SERVICE_BODIES[rotate() % len(SERVICE_BODIES)])
        return json.dumps({"path": path})

    def do_GET(self):
        self._serve("GET")

    def do_POST(self):
        self._serve("POST")


def main():
    port = int(sys.argv[1]) if len(sys.argv) > 1 else 0
    srv = ThreadingHTTPServer(("127.0.0.1", port), H)
    srv.daemon_threads = True
    srv.handle_error = lambda *a: None      # a client that hangs up mid-reply is part of the exercise
    cert, key = os.environ.get("MOCK_TLS_CERT"), os.environ.get("MOCK_TLS_KEY")
    if cert and key:
        # Druid over TLS (the self-signed certificate the test made): a handshake that fails is the client's to report.
        import ssl
        ctx = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
        ctx.load_cert_chain(cert, key)
        srv.socket = ctx.wrap_socket(srv.socket, server_side=True, do_handshake_on_connect=False)
    print(srv.server_address[1], flush=True)
    srv.serve_forever()


if __name__ == "__main__":
    main()
