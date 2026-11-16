#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
# SPDX-FileCopyrightText: 2026 Daniel Gardiner d/b/a FractalSQLabs
"""Reasoning effort (`think`): what a daemon sends to the provider for each setting.

usage: think.py SOCKET KEYFILE REQUEST_LOG VARIANT
  VARIANT names the think settings the daemon was started with: unset, none, medium, off, ollama, anthropic, vllm, grok.

The effort applies to fractal_reason and to text-to-SQL's generate and review steps, never to fractal_embed. The check is on the
request body the provider receives, so it holds for both daemons.
"""
import json
import sys

import fsq_client as fc

sock, keyfile, reqlog, variant = sys.argv[1:5]
c = fc.Client(sock, fc.load_key(keyfile), timeout=60)
failures = []
EFFORT_FIELDS = ("think", "reasoning_effort", "reasoning", "thinking", "output_config", "options")


def check(name, cond, detail=""):
    print(("ok   " if cond else "FAIL ") + name + ("" if cond else "  " + str(detail)[:300]))
    if not cond:
        failures.append(name)


def requests():
    with open(reqlog) as f:
        return [json.loads(line) for line in f if line.strip()]


def bodies_of(call):
    """The provider requests one daemon call produced, by path suffix."""
    before = len(requests())
    call()
    return requests()[before:]


def chat_body(call):
    reqs = [r for r in bodies_of(call) if r["path"].endswith("/chat/completions")]
    return reqs[0]["body"] if reqs else None


def none_of(body):
    return [k for k in EFFORT_FIELDS if k in body]


EXPECT = {
    "unset":     lambda b: not none_of(b),
    "none":      lambda b: not none_of(b),
    "medium":    lambda b: b.get("reasoning_effort") == "medium" and "think" not in b,
    "off":       lambda b: b.get("reasoning_effort") == "none",
    "ollama":    lambda b: b.get("think") == "high" and b.get("options", {}).get("num_ctx") == 8192 and b.get("stream") is False,
    "anthropic": lambda b: b.get("thinking", {}).get("type") == "adaptive" and b.get("output_config", {}).get("effort") == "high",
    "vllm":      lambda b: b.get("reasoning_effort") == "low",
    "grok":      lambda b: b.get("reasoning", {}).get("effort") == "low",
}
if variant not in EXPECT:
    sys.exit("unknown variant " + variant)
ok = EXPECT[variant]

steps = [
    ("fractal_reason", lambda: c.call("fractal_reason", 1, "say something")),
    ("text-to-SQL generate", lambda: c.call("fractal_t2s_generate", 1, "count the rows", "table t(a, b)", "Apache Druid SQL")),
    ("text-to-SQL review", lambda: c.call("fractal_t2s_review", 1, "count the rows", "SELECT COUNT(*) FROM t")),
]
for name, call in steps:
    body = chat_body(call)
    check("think=%s: %s sends the right request" % (variant, name), body is not None and ok(body), body and {k: body.get(k) for k in EFFORT_FIELDS if k in body})

# embeddings never carry an effort
embed = [r for r in bodies_of(lambda: c.call("fractal_embed", 1, "hello")) if r["path"].endswith("/embeddings")]
check("think=%s: embed carries no effort fields" % variant, embed and not none_of(embed[-1]["body"]), embed and embed[-1]["body"])

print("\n%d failure(s)" % len(failures))
sys.exit(1 if failures else 0)
