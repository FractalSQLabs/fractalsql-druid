#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
# SPDX-FileCopyrightText: 2026 Daniel Gardiner d/b/a FractalSQLabs
"""The four reasoning contexts, checked against what a daemon actually sends to the provider.

usage: contexts.py SOCKET KEYFILE REQUEST_LOG CHAT_MODE
  CHAT_MODE is the mode the daemon was started with: text, code or json.
"""
import json
import sys

import fsq_client as fc

sock, keyfile, reqlog, chat_mode = sys.argv[1:5]
c = fc.Client(sock, fc.load_key(keyfile), timeout=60)
failures = []


def check(name, cond, detail=""):
    print(("ok   " if cond else "FAIL ") + name + ("" if cond else "  " + str(detail)))
    if not cond:
        failures.append(name)


def requests():
    with open(reqlog) as f:
        return [json.loads(line) for line in f if line.strip()]


def system_text(req):
    return " ".join(m["content"] for m in req["body"]["messages"] if m.get("role") == "system")


def last_chat():
    chats = [r for r in requests() if r["path"].endswith("/chat/completions")]
    return chats[-1]


# chat context: the operator's mode
st, answer = c.call("fractal_reason", 1, "say something")
check("chat answers", st == 0 and answer, (st, answer))
sys_text = system_text(last_chat())
if chat_mode == "text":
    check("chat in text mode adds no fence instruction", "fenced code block" not in sys_text, sys_text)
    check("chat in text mode returns the answer as written", answer == "a plain answer from the mock provider", answer)
else:
    check("chat in %s mode asks for a fenced block" % chat_mode, "fenced code block" in sys_text, sys_text)
    if chat_mode == "code":
        check("chat in code mode returns the block's interior", answer == "SELECT 1 AS n", answer)
    else:
        check("chat in json mode returns the JSON document", answer == '{"count": 5}', answer)
check("chat sends no target-system tag", "Target system" not in sys_text, sys_text)

# text-to-SQL context: always code, and told the target
st, sql = c.call("fractal_t2s_generate", 1, "count the rows", "table t(a, b)", "Apache Druid SQL")
sys_text = system_text(last_chat())
check("text-to-SQL answers a bare statement", st == 0 and sql == "SELECT 1 AS n", (st, sql))
check("text-to-SQL always asks for a fenced block", "fenced code block" in sys_text, sys_text)
check("text-to-SQL names the target system", "Target system: Apache Druid SQL" in sys_text, sys_text)

# review context: always text, whatever the chat mode is
st, verdict = c.call("fractal_t2s_review", 1, "count the rows", "SELECT COUNT(*) FROM t")
sys_text = system_text(last_chat())
check("a passing review is NULL", st == 0 and verdict is None, (st, verdict))
check("review is never asked for a fenced block", "fenced code block" not in sys_text, sys_text)
st, verdict = c.call("fractal_t2s_review", 1, "count the rows FAILME", "SELECT 1")
check("a failing review returns the critique", st == 0 and verdict and verdict.startswith("FAIL"), (st, verdict))

# embed context
st, vec = c.call("fractal_embed", 1, "hello")
posts = [r for r in requests() if r["path"].endswith("/embeddings")]
check("embed returns a vector", st == 0 and vec and vec.startswith("["), (st, vec))
check("embed posts to the embeddings endpoint", len(posts) >= 1 and posts[-1]["body"].get("input") == "hello")
check("embed carries no chat options", "messages" not in posts[-1]["body"])

print("\n%d failure(s)" % len(failures))
sys.exit(1 if failures else 0)
