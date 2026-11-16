#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
# SPDX-FileCopyrightText: 2026 Daniel Gardiner d/b/a FractalSQLabs
"""The extension's SQL functions against a live Druid cluster.

usage: druid_sql.py DRUID_URL
The cluster's daemon must point at a provider (the build_test mock is enough).
"""
import json
import os
import sys
import urllib.error
import urllib.request

druid = sys.argv[1].rstrip("/")
failures = []


def check(name, cond, detail=""):
    print(("ok   " if cond else "FAIL ") + name + ("" if cond else "  " + str(detail)[:300]))
    if not cond:
        failures.append(name)


def q(sql):
    """The first cell of the first row, or an Exception for an error."""
    req = urllib.request.Request(druid + "/druid/v2/sql",
                                 data=json.dumps({"query": sql, "resultFormat": "array"}).encode(),
                                 headers={"Content-Type": "application/json"})
    try:
        rows = json.loads(urllib.request.urlopen(req, timeout=300).read())
    except urllib.error.HTTPError as e:
        return RuntimeError(e.read().decode()[:300])
    return rows[0][0] if rows else None


v = q("SELECT FRACTAL_VERSION()")
check("FRACTAL_VERSION is the extension's version", v == "2.0.0", v)
check("FRACTAL_EDITION answers", q("SELECT FRACTAL_EDITION()") in ("Community", "Enterprise"))
check("a vector function over text", q("SELECT FRACTAL_VECTOR_NORM('[3,4]')") == 5.0)
check("a vector result is the text form", str(q("SELECT FRACTAL_VECTOR_NORMALIZE('[3,4]')")).startswith("["))
check("FRACTAL_VECTOR_DIMS is an integer", q("SELECT FRACTAL_VECTOR_DIMS('[1,2,3]')") == 3)
tda = q("SELECT FRACTAL_TDA_PERSISTENCE_DIAGRAM('0,0,1,0,0,1,1,1', 2, 1, 2.5)")
check("TDA takes max_dim and max_thresh", isinstance(tda, str) and "betti1" in tda, tda)
check("the two-argument TDA form is gone", isinstance(q("SELECT FRACTAL_TDA_PERSISTENCE_DIAGRAM('0,0,1,0', 2)"), Exception))
check("dimension_drift answers a document", "drift" in str(q("SELECT FRACTAL_DIMENSION_DRIFT('" + ",".join(str((i % 7) * 0.1 + i * 0.01) for i in range(96)) + "', 48)")))

# session settings live in the daemon
check("a session setting is stored", q("SELECT FRACTAL_CONFIG_SET('think', 'high', 'ci')") == "ok")
check("and reads back", q("SELECT FRACTAL_CONFIG_GET('think', 'ci')") == "high")
check("another session does not see it", q("SELECT FRACTAL_CONFIG_GET('think', 'other')") != "high")
refused = q("SELECT FRACTAL_CONFIG_SET('reasoning_url', 'http://evil.invalid', 'ci')")
check("an operator key cannot be set from a session", "cannot be changed by a session" in str(refused), refused)
check("and the provider URL is unchanged", "evil" not in str(q("SELECT FRACTAL_CONFIG_GET('reasoning_url', 'ci')")))
check("the key list is the daemon's", "reasoning_url" in str(q("SELECT FRACTAL_CONFIG_KEYS()")))
check("a session can be reset", q("SELECT FRACTAL_CONFIG_RESET('ci')") >= 1)

# reasoning goes through the daemon
# the build_test mock answers with a fixed text; a real provider (build_test --llm) answers in its own words
reason = q("SELECT FRACTAL_REASON('Reply with one short sentence.', '{}')")
if os.environ.get("FSQL_REAL_LLM"):
    check("FRACTAL_REASON reaches the provider", isinstance(reason, str) and reason.strip() != "", reason)
else:
    check("FRACTAL_REASON reaches the provider", "mock provider" in str(reason), reason)
emb = q("SELECT FRACTAL_EMBED('hello')")
check("FRACTAL_EMBED returns a vector", isinstance(emb, str) and emb.startswith("["), emb)

# the enterprise functions are live or say so
r = q("SELECT FRACTAL_LEDGER_VERIFY()")
check("FRACTAL_LEDGER_VERIFY answers without the licence", isinstance(r, str) and '"ok"' in r, r)

print("\n%d failure(s)" % len(failures))
sys.exit(1 if failures else 0)
