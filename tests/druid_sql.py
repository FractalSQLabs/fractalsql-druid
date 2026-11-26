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
sub = q("SELECT FRACTAL_OPTIMIZE_SUBSET('[0.9,0.1,0.5,0.8,0.2,0.7]','[0.6,0.6,0.6,0.6,0.6,0.6]',2,NULL,0,7)")
sw = json.loads(sub)["weights"] if isinstance(sub, str) else []
check("FRACTAL_OPTIMIZE_SUBSET weights sum to 1, at most k are nonzero and none passes its bound",
      len(sw) == 6 and abs(sum(sw) - 1.0) < 1e-6 and sum(1 for x in sw if x > 1e-9) <= 2 and all(x <= 0.6 + 1e-6 for x in sw), sub)
check("FRACTAL_OPTIMIZE_SUBSET picks the two most valuable items", len(sw) == 6 and sw[0] > 0 and sw[3] > 0, sub)
check("FRACTAL_OPTIMIZE_SUBSET refuses bounds that cannot sum to 1",
      isinstance(q("SELECT FRACTAL_OPTIMIZE_SUBSET('[0.9,0.1,0.5,0.8]','[0.1,0.1,0.1,0.1]',2,NULL,0,7)"), Exception))
# the named feature store (a datasource: the newest row of a doc_id wins)
import time
for did, vec in ((9101, "[1,0,0]"), (9102, "0.9,0.1,0"), (9103, "[0,1,0]"), (9102, "0.8,0.2,0"), (9109, "[1,1]")):
    q("SELECT FRACTAL_STORE_MORPHOLOGY(%d,'%s')" % (did, vec))
fm = []
for _ in range(30):
    got = q("SELECT FRACTAL_MINE_TOPOLOGY_NEGATIVES('[1,0,0]',50)")
    fm = [h for h in json.loads(got) if h["doc_id"] in (9101, 9102, 9103)] if isinstance(got, str) else []
    if len(fm) == 3 and abs(fm[1]["distance"] - 0.28284271) < 1e-5:
        break
    time.sleep(2)
check("the feature store mines nearest first and the newest write of a doc wins",
      [h["doc_id"] for h in fm] == [9101, 9102, 9103] and abs(fm[1]["distance"] - 0.28284271) < 1e-5, fm)
check("the feature store skips a vector of another dimension", all(h["doc_id"] != 9109 for h in fm))
check("the feature store refuses k = 0", isinstance(q("SELECT FRACTAL_MINE_TOPOLOGY_NEGATIVES('[1,0,0]',0)"), Exception))
check("the feature store refuses a negative doc_id", isinstance(q("SELECT FRACTAL_STORE_MORPHOLOGY(-1,'[1]')"), Exception))
conv = q("SELECT FRACTAL_SFS_CONVERGE('[1,0,0]',5,8,2)")
check("FRACTAL_SFS_CONVERGE answers {dim, population_size, best_point, best_fit} without a trace",
      isinstance(conv, str) and all(k in conv for k in ("dim", "population_size", "best_point", "best_fit")) and "paths" not in conv, conv)
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
