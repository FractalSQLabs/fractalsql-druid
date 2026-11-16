#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
# SPDX-FileCopyrightText: 2026 Daniel Gardiner d/b/a FractalSQLabs
"""A deterministic OpenAI-compatible provider for tests.

usage: mock_llm.py PORT REQUEST_LOG [HOST]

HOST defaults to 127.0.0.1; a container passes 0.0.0.0.

Chat completions answer from the request: a request that asks for a fenced code block gets one,
a request that asks for a PASS or FAIL verdict gets one (FAIL when the text contains "FAILME"),
anything else gets a plain sentence. Embeddings return a fixed 8-dimension vector derived from the
input. Every request body is appended to REQUEST_LOG as one JSON line, so a test can check what the
daemon sent.
"""
import hashlib
import json
import sys
from http.server import BaseHTTPRequestHandler, HTTPServer

LOG = sys.argv[2] if len(sys.argv) > 2 else None


class Handler(BaseHTTPRequestHandler):
    def log_message(self, fmt, *args):
        pass

    def _send(self, obj):
        body = json.dumps(obj).encode()
        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def do_POST(self):
        length = int(self.headers.get("Content-Length", 0))
        req = json.loads(self.rfile.read(length) or b"{}")
        if LOG:
            with open(LOG, "a") as f:
                f.write(json.dumps({"path": self.path, "body": req}) + "\n")
        if self.path.endswith("/embeddings"):
            text = str(req.get("input", ""))
            digest = hashlib.sha256(text.encode()).digest()
            vec = [round(b / 255.0, 6) for b in digest[:8]]
            self._send({"data": [{"embedding": vec, "index": 0}]})
            return
        messages = req.get("messages", [])
        everything = " ".join(str(m.get("content", "")) for m in messages)
        if "single fenced code block" in everything:
            answer = "```sql\nSELECT 1 AS n\n```"
        elif "single JSON object in a fenced code block" in everything:
            answer = '```json\n{"count": 5}\n```'
        elif "Answer PASS or FAIL" in everything:
            answer = "FAIL\nthe statement does not answer the request" if "FAILME" in everything else "PASS\nlooks right"
        else:
            answer = "a plain answer from the mock provider"
        self._send({"choices": [{"message": {"content": answer}}]})


if __name__ == "__main__":
    HTTPServer((sys.argv[3] if len(sys.argv) > 3 else "127.0.0.1", int(sys.argv[1])), Handler).serve_forever()
