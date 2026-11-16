#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
# SPDX-FileCopyrightText: 2026 Daniel Gardiner d/b/a FractalSQLabs
"""A provider that misbehaves, for fault-injection tests.

usage: fault_llm.py PORT MODE
  hang       reads the request and never answers
  garbage    200 with a body that is not JSON
  error500   500 Internal Server Error
  truncated  promises a long body, sends a few bytes, closes the connection
  empty      200 with a JSON body that carries no answer
  longerr    500 with a long error body: quotes, control characters and multi-byte text, to be carried into an error message
  cycle      a different wrong answer on every request: no choices, no message, null content, wrong types, an oversize answer,
             an embedding that is not numbers, error documents, rate limits, an unauthorised caller, a redirect, then good answers
"""
import sys
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

MODE = sys.argv[2]
COUNT = [0]
BIG = b'{"choices":[{"message":{"content":"' + b"x" * 3000000 + b'"}}]}'
CYCLE = [
    (200, b'{"choices":[]}'), (200, b'{"choices":[{"message":{}}]}'), (200, b'{"choices":[{"message":{"content":null}}]}'),
    (200, b'{"choices":"x"}'), (200, b'[]'), (200, b'"just a string"'), (200, BIG), (200, b'{"data":[]}'),
    (200, b'{"data":[{"embedding":"x"}]}'), (200, b'{"data":[{"embedding":[1,"a",null]}]}'), (200, b'{"data":[{"embedding":[]}]}'),
    (200, b'{"error":{"message":"quota exceeded"}}'), (429, b'{"error":"rate limited"}'), (401, b'unauthorized'), (503, b''),
    (200, b'{"choices":[{"message":{"content":"a fine answer"}}]}'), (200, b'{"data":[{"embedding":[0.1,0.2,0.3]}]}'),
    (200, b'{"choices":[{"message":{"content":"say \\"hi\\"\\n"}}]}'), (200, b'{"choices":[{"text":"old style"}]}'),
    (200, b'{"choices":[{"message":{"content":["a","b"]}}]}'), (500, b'{"choices":[{"message":{"content":"but a 500"}}]}'),
]


class Handler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def log_message(self, fmt, *args):
        pass

    def do_POST(self):
        length = int(self.headers.get("Content-Length", 0))
        self.rfile.read(length)
        if MODE == "hang":
            time.sleep(300)
            return
        if MODE == "garbage":
            body = b"this is { not json <<<"
            self.send_response(200)
        elif MODE == "error500":
            body = b"boom"
            self.send_response(500)
        elif MODE == "longerr":
            body = (b'"quoted" back\\slash \n tab\t ctl\x01 caf\xc3\xa9 \xe2\x82\xac ' * 300)
            self.send_response(500)
        elif MODE == "cycle":
            COUNT[0] += 1
            status, body = CYCLE[COUNT[0] % len(CYCLE)]
            self.send_response(status)
        elif MODE == "empty":
            body = b"{}"
            self.send_response(200)
        elif MODE == "truncated":
            self.send_response(200)
            self.send_header("Content-Type", "application/json")
            self.send_header("Content-Length", "1000")
            self.end_headers()
            self.wfile.write(b'{"choices":[{"mess')
            self.wfile.flush()
            self.close_connection = True
            return
        else:
            sys.exit("unknown mode " + MODE)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)


ThreadingHTTPServer(("127.0.0.1", int(sys.argv[1])), Handler).serve_forever()
