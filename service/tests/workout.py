#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
# SPDX-FileCopyrightText: 2026 Daniel Gardiner d/b/a FractalSQLabs
"""Every function in the registry used the way its documentation says, plus the stateful sequences around them.

usage: workout.py SOCKET KEYFILE [enterprise]

The junk-argument test (calls_all.py) reaches the error paths; this one reaches the working paths: real series, real vectors, a
session's configuration set, read back, listed and reset, the diversifier, the feedback and agent hooks, and, when the daemon was
given the enterprise library, the ledger and the audit trail. A few answers are checked against values known in advance (the
vector arithmetic, the config round trip); the rest must simply answer and leave the daemon up.
"""
import json
import math
import os
import random
import struct
import sys

import fsq_client as fc

sock, keyfile = sys.argv[1:3]
enterprise = len(sys.argv) > 3 and sys.argv[3] == "enterprise"
key = fc.load_key(keyfile)
failures = []
calls = 0
# Under allocation-failure injection (FSQL_OOM=1) answers are allowed to be errors; only the daemon dying counts.
lenient = bool(os.environ.get("FSQL_OOM"))


def check(name, cond, detail=""):
    if not cond and not lenient:
        print("FAIL " + name + ("  " + str(detail)[:200] if detail != "" else ""))
        failures.append(name)


SEEN = []


def call(name, *args, token=0):
    global calls
    calls += 1
    if len(SEEN) < 4000 and name != "fractal_lock_destructive":
        SEEN.append((name, args))
    c = fc.Client(sock, key, timeout=15 if lenient else 60)
    try:
        return c.call(name, *args, token=token)
    except Exception as e:  # a dropped connection is reported, the daemon check below decides if it is fatal
        return -1, str(e)
    finally:
        try:
            c.close()
        except Exception:
            pass


def ok(name, *args, token=0):
    st, v = call(name, *args, token=token)
    check("%s(%s) answers" % (name, ", ".join(repr(a)[:24] for a in args[:3])), st == 0, (st, v))
    return v


rnd = random.Random(7)
walk = [0.0]
for _ in range(255):
    walk.append(walk[-1] + rnd.gauss(0, 1))
SERIES = ",".join("%.4f" % x for x in walk)
SIN = ",".join("%.4f" % math.sin(i * 0.4) for i in range(128))
STEP = ",".join("%.1f" % (0.0 if i < 60 else 5.0) for i in range(120))
PTS = ",".join("%.3f" % rnd.random() for _ in range(2 * 60))
BIG2 = ",".join("%.3f" % rnd.random() for _ in range(2 * 600))
BIG3 = ",".join("%.3f" % rnd.random() for _ in range(3 * 600))
BYTES = ",".join(str((i * 37 + (i // 8) % 3) % 256) for i in range(96))
PTS3 = ",".join("%.3f" % rnd.random() for _ in range(3 * 40))
V4, W4 = "[1,2,3,4]", "[4,3,2,1]"
MU = "0.10,0.12,0.08,0.15,0.11,0.09"
COV = ",".join("%.4f" % (0.04 if i == j else 0.005) for i in range(6) for j in range(6))
FP = json.dumps(["%016x" % (0xABCDEF0123456789 ^ (i % 3)) for i in range(12)])

# ---- vectors
call("fractal_vector", 3)
check("dims", ok("fractal_vector_dims", V4) == 4)
check("norm", abs(ok("fractal_vector_norm", "[3,4]") - 5.0) < 1e-9)
check("l2 distance", abs(ok("fractal_vector_l2_distance", "[0,0]", "[3,4]") - 5.0) < 1e-9)
check("l2 squared", abs(ok("fractal_vector_l2_squared", "[0,0]", "[3,4]") - 25.0) < 1e-9)
check("cosine similarity of a vector with itself", abs(ok("fractal_vector_cosine_similarity", V4, V4) - 1.0) < 1e-5)
check("cosine distance of a vector with itself", abs(ok("fractal_vector_cosine_distance", V4, V4)) < 1e-5)
check("negative inner product", abs(ok("fractal_vector_negative_inner_product", "[1,2]", "[3,4]") + 11.0) < 1e-9)
check("lp distance p=1", abs(ok("fractal_vector_lp_distance", "[0,0]", "[3,4]", 1.0) - 7.0) < 1e-9)
check("add", json.loads(ok("fractal_vector_add", "[1,2]", "[3,4]")) == [4, 6])
check("sub", json.loads(ok("fractal_vector_sub", "[3,4]", "[1,2]")) == [2, 2])
check("scale", json.loads(ok("fractal_vector_scale", "[1,2]", 2.0)) == [2, 4])
n = json.loads(ok("fractal_vector_normalize", "[3,4]"))
check("normalize gives a unit vector", abs(math.hypot(*n) - 1.0) < 1e-6, n)
ok("fractal_vector_from_text", "1,0,0")
ok("fractal_vector_to_json", V4)
call("fractal_vector_from_float8_array", "{1.5,2.5,3.5}")
ok("fractal_vector_from_float8_array", "1.5,2.5,3.5")
ok("fractal_vector_to_float8_array", V4)
q8 = ok("fractal_vector_quantize_int8", "[0.5,-0.5,1,-1]")
qb = ok("fractal_vector_quantize_binary", "[0.5,-0.5,1,-1,2,-2,3,-3,1]")
call("fractal_vector_hamming_distance", qb, qb)
for p in (0.5, 2.0, 3.0, 1.0):
    call("fractal_vector_lp_distance", V4, W4, p)
for d in range(1, 6):
    call("fractal_vector_norm", "[" + ",".join(str(i) for i in range(d)) + "]")
call("fractal_vector_add", V4, "[1,2]")          # mismatched dimensions
call("fractal_vector_normalize", "[0,0,0]")       # a zero vector

# ---- dimension, analytics
check("DFA of a random walk is a number", isinstance(ok("fractal_dimension_dfa", SERIES), float))
ok("fractal_dimension_dfa", SIN)
ok("fractal_dimension_boxcount", BIG2, 2)
call("fractal_dimension_boxcount", BIG3, 3)
ok("fractal_dimension_drift", SERIES, 64)
ok("fractal_dimension_drift", SERIES, 32)
ok("fractal_change_point_detect", STEP, 10, 1.0, 5)
ok("fractal_change_point_detect", SERIES, 16, 3.0, 10)
ok("fractal_periodogram", SIN, 3)
ok("fractal_periodogram", SERIES, 5)
ok("fractal_spectrogram_entropy", SIN)
ok("fractal_spectrogram_entropy", SIN, 32, 16)
ok("fractal_spectrogram_entropy", SERIES, 64, 32, 4)
ok("fractal_state_fingerprint", V4, 64, 0)
ok("fractal_state_fingerprint", V4, 256, 42)
ok("fractal_state_fingerprint", "[1,2,3,4,5,6,7,8]", 1024, 7)
ok("fractal_cycle_detect", BYTES, 8, 4)
ok("fractal_cycle_detect", BYTES, 8, 0)
ok("fractal_tda_persistence_diagram", PTS, 2, 1, 1.0, 10)
ok("fractal_tda_persistence_diagram", PTS3, 3, 1, 2.0, 10)
call("fractal_vascular_network", "0,0;1,0;1,1;0,1", "0,1;1,2;2,3;3,0", "1,1,1,1")
call("fractal_vascular_network", "0,0,0;1,0,0;1,1,0;0,1,1", "0,1;1,2;2,3", "1,1.2,0.9")
call("fractal_cortical_folding", "0,0,0;1,0,0;0,1,0;0,0,1", "0,1,2;0,1,3;0,2,3;1,2,3")
call("fractal_nerve_plexus_metric", "0,0;1,0;1,1;0,1;2,2", 2, "0,1;1,2;2,3;3,0;2,4")
call("fractal_morphological_complexity", PTS, 2)
call("fractal_morphological_complexity", PTS3, 3)

# ---- portfolio and subset optimisation
ok("fractal_optimize_portfolio", MU, COV, 3, "{}")
ok("fractal_optimize_portfolio", MU, COV, 3, '{"seed":5,"use_obl":true,"diffusion_mode":"levy"}')
ok("fractal_optimize_portfolio", MU, COV, 3, '{"seed":5,"use_obl":false,"diffusion_mode":"gaussian"}')
ok("fractal_optimize_subset", "5,4,3,2,1,6", "1,1,1,1,1,1", 3, "{}")
ok("fractal_optimize_subset", "5,4,3,2,1,6", "1,1,1,1,1,1", 3, '{"seed":3,"prev_weights":[0.2,0.2,0.2,0.1,0.1,0.2],"turnover_penalty":0.5}')
ok("fractal_optimize_portfolio_multimodal", MU, COV, 3, 4, 0.5, 0.9, 2)
ok("fractal_optimize_portfolio_multimodal_ex", MU, COV, 3, 4, 0.5, 0.9, 2, 1, "levy")
ok("fractal_optimize_portfolio_multimodal_ex", MU, COV, 3, 4, 0.5, 0.9, 2, 0, "gaussian")
ok("fractal_optimize_portfolio_multimodal_pareto", MU, COV, 3, 4, 3, 2, 1, "gaussian")
ok("fractal_optimize_portfolio_multimodal_pareto", MU, COV, 3, 4, 3, 2, 0, "levy")

for prm in ('{"seed":0}', '{"seed":-1}', '{"seed":"x"}', '{"use_obl":1}', '{"use_obl":"yes"}', '{"diffusion_mode":"x"}', '{"diffusion_mode":3}', "[]", "", "null", '{"seed":18446744073709551615}'):
    call("fractal_optimize_portfolio", MU, COV, 3, prm)
    call("fractal_optimize_subset", "5,4,3,2,1,6", "1,1,1,1,1,1", 3, prm)
for k in (0, 1, 6, 7, -1):
    call("fractal_optimize_portfolio", MU, COV, k, "{}")
    call("fractal_optimize_portfolio_multimodal", MU, COV, k, 2, 0.5, 0.9, 1)
    call("fractal_optimize_portfolio_multimodal_pareto", MU, COV, k, 2, 3, 1, 0, "gaussian")
for a in ((0, 0.5, 0.9, 1), (4, 0.0, 0.9, 1), (4, 1.5, 0.9, 1), (4, 0.5, 0.0, 1), (4, 0.5, 1.5, 1), (4, 0.5, 0.9, 0), (-1, 0.5, 0.9, 1), (100000, 0.5, 0.9, 1)):
    call("fractal_optimize_portfolio_multimodal", MU, COV, 3, *a)
    call("fractal_optimize_portfolio_multimodal_ex", MU, COV, 3, *a, 1, "levy")

# ---- search
CORPUS = "[[1,2,3,4],[4,3,2,1],[1,1,1,1],[2,2,2,2],[9,8,7,6]]"
ok("fractal_search", CORPUS, V4, 2, "{}")
ok("fractal_search", CORPUS, V4, 3, '{"iterations":20,"population_size":16,"diffusion_factor":2,"walk":0.5,"seed":4}')
ok("fractal_search", "1,2,3,4;4,3,2,1;1,1,1,1", "1,2,3,4", 2, '{"debug":true}')
ok("fractal_search_explore", CORPUS, V4, '{"iterations":10,"seed":2}')
ok("fractal_search_debug", V4)
ok("fractal_search_debug", V4, 10, 8, 2, 3)

# ---- configuration: per session, validated, listed, reset
keys = json.loads(ok("fractal_config_keys") or "[]")
check("the key list is not empty", len(keys) > 10, keys)
names = [k.get("name") for k in keys if isinstance(k, dict)]
sess_names = [k.get("name") for k in keys if isinstance(k, dict) and k.get("session_overridable")]
for sess in (1, 2):
    for name, val in (("think", "high"), ("think", "off"), ("think", "medium"), ("think", "bogus"),
                      ("think_num_ctx", "4096"), ("think_num_ctx", "-3"), ("think_num_ctx", "x"),
                      ("agent_partial_reasoning_fail", "on"), ("agent_partial_reasoning_fail", "off"),
                      ("agent_partial_reasoning_fail", "maybe"), ("no_such_key", "1"), ("", "")):
        call("fractal_config_set", name, val, sess)
check("a session's setting reads back", ok("fractal_config_set", "think", "high", 3) is not None and
      ok("fractal_config_get", "think", 3) == "high")
for nm in names:
    if nm:
        call("fractal_config_get", nm, 1)
for nm in sess_names:
    for val in ("1", "on", "off", "high", "x" * 40, "/etc/passwd", "../x", "999999999999", "-1", "", "0.5", "low", "ollama"):
        call("fractal_config_set", nm, val, 9)
for nm in names:
    if nm not in sess_names:
        call("fractal_config_set", nm, "1", 9)       # not session-overridable: refused
call("fractal_config_get", "x" * 300, 1)
ok("fractal_config_list", 3)
ok("fractal_config_list", 9)
ok("fractal_config_list", 1234)
check("reset clears a session", ok("fractal_config_reset", 3) is not None)
call("fractal_config_reset", 99999)
for sid in (3, 9, 1, 2):
    call("fractal_session_close", sid)

# ---- diversifier, feedback, agents
for sid in (21, 22):
    ok("fractal_diversify_enable", sid)
    ok("fractal_diversify_set_params", sid, '{"window_n":8,"stall_threshold":0.1,"repulsion_sigma":0.5,"repulsion_weight":0.3,"max_shadows_considered":4,"tail_buffer_cap":16}')
    call("fractal_diversify_set_params", sid, '{"window_n":-1}')
    call("fractal_diversify_set_params", sid, "not json")
    for _ in range(4):
        call("fractal_search", CORPUS, V4, 2, '{"session_id":%d,"iterations":8,"seed":1}' % sid)
    ok("fractal_detect_collapse", sid)
    ok("fractal_explain_result", sid)
    call("fractal_isolate_background", sid, 1)
    ok("fractal_diversify_disable", sid)
    call("fractal_session_close", sid)
call("fractal_feedback_report", 23, 1, "negative")
call("fractal_feedback_report", 23, 1, "positive", 1200)
call("fractal_feedback_report", 23, 1, "bogus", 1)
for mode in ("on", "off", "maybe", ""):
    call("fractal_agent_partial_fail", 23, mode)

# ---- provider-backed (the mock answers these); text to SQL
ok("fractal_reason", 24, "reply with a short confirmation")
call("fractal_reason", 24, "a", "b")
call("fractal_reason", 24, "a", "chat")
call("fractal_reason", 24, "a", "code")
call("fractal_reason", 24, "a", "json")
ok("fractal_embed", 24, "hello world")
call("fractal_embed", 24, "")
call("fractal_t2s_config")
call("fractal_t2s_generate", 24, "count the rows", "table t(a int, b int)", "Apache Druid SQL")
call("fractal_t2s_generate", 24, "count the rows", "table t(a int, b int)", "")
call("fractal_t2s_review", 24, "count the rows", "SELECT COUNT(*) FROM t")
for sql in ("SELECT a FROM t", "SELECT * FROM t; DROP TABLE t", "DROP TABLE t", "SELECT a FROM u", "", "SELECT 1 UNION SELECT 2",
            "WITH x AS (SELECT 1) SELECT * FROM x", "select a from t -- comment", "INSERT INTO t VALUES (1)"):
    call("fractal_t2s_check_allowlist", sql)
SQLS = ["SELECT 1", "  select 1", "/* lead */ SELECT 1", "-- c\nSELECT 1", "# c\nSELECT 1", "/*! SELECT 1 */", "/*!50000 DROP TABLE t */ SELECT 1",
        "SELECT 1 INTO OUTFILE '/tmp/x'", "SELECT 1 INTO DUMPFILE '/tmp/x'", "SELECT LOAD_FILE('/etc/passwd')", "SELECT SLEEP(5)",
        "SELECT BENCHMARK(1,1)", "SELECT 'a;b'", "SELECT \"a;b\"", "SELECT `a;b` FROM t", "SELECT 1; SELECT 2", "SELECT 1;", "SELECT 1 ; ",
        "EXPLAIN SELECT 1", "SHOW TABLES", "DESCRIBE t", "UPDATE t SET a=1", "DELETE FROM t", "CREATE TABLE t(a int)", "ALTER TABLE t ADD b int",
        "GRANT ALL ON *.* TO x", "CALL p()", "EXEC p", "EXECUTE IMMEDIATE 'x'", "SET @a=1", "USE db", "LOCK TABLES t READ", "REPLACE INTO t VALUES (1)",
        "(SELECT 1)", "((SELECT 1))", "WITH RECURSIVE r AS (SELECT 1) SELECT * FROM r", "VALUES (1)", "TABLE t", "SELECT * FROM t FOR UPDATE",
        "SELECT * FROM t LOCK IN SHARE MODE", "select/**/1", "SEL/**/ECT 1", "SELECT 1 /* unterminated", "SELECT 'unterminated", "SELECT \"x",
        "SELECT 1 -- trailing", "SELECT 1 /* a */ ; /* b */", "\n\t SELECT 1", "SELECT\u00a01", "SELECT " + "(" * 200 + "1" + ")" * 200,
        "SELECT " + "a," * 3000 + "b FROM t", "SELECT 1 UNION ALL SELECT 2", "SELECT * FROM information_schema.tables",
        "SELECT * FROM mysql.user", "SELECT user()", "SELECT @@version", "SELECT 1 FROM t WHERE a IN (SELECT b FROM u)"]
for sql in SQLS:
    call("fractal_t2s_check_allowlist", sql)
    call("fractal_t2s_review", 24, "question text", sql)
    call("fractal_t2s_generate", 24, sql, "table t(a int)", "Apache Druid SQL")

# ---- ledger and audit (a community daemon refuses these; the enterprise one does the work)
for fn in ("fractal_ledger_truth_count", "fractal_ledger_shadow_count", "fractal_ledger_flush", "fractal_ledger_load",
           "fractal_ledger_verify", "fractal_ledger_compact"):
    call(fn, 1)
if enterprise:
    for i in range(6):
        ok("fractal_audit_log", "workout", json.dumps({"i": i, "question": "a customer row %d" % i, "sql": "SELECT 'x' FROM t"}), 1, "ci")
        call("fractal_audit_log", "workout", "plain text, not json", 1, "ci")
    PAYLOADS = ['{"a":"x\\ny\\t\\u00e9\\"q\\""}', '{"nested":{"deep":{"list":[1,2,{"k":"v"}],"s":"text"}},"n":1.5e3,"b":true,"z":null}',
                '[1,2,3]', '"just a string"', '123', 'null', '{}', '[]', '{"a":', '{"a":1,}', "{'a':1}", '{"k":"' + "w" * 5000 + '"}',
                '{"question":"quote \\" and \\\\ backslash","sql":"SELECT \'a\' FROM t WHERE x = \\"y\\""}',
                '{"u":"\\ud83d\\ude00 emoji","v":"\\u0000nul"}', '{"rows":[[1,"a"],[2,"b"]],"analysis":"free text here"}',
                '{"a":{"b":{"c":{"d":{"e":{"f":{"g":{"h":1}}}}}}}}', '{"key with space":1,"":2}', ' {"lead":1}', '{"x":1} trailing']
    for pl in PAYLOADS:
        call("fractal_audit_log", "workout", pl, 1, "ci")
        call("fractal_audit_log", "t" * 70, pl, 1, "a" * 80)
        call("fractal_audit_log", "", pl)
    call("fractal_audit_log", "workout", '{"i":1}', 1)
    call("fractal_audit_log", "workout", '{"i":1}', 0, "ci")
    ok("fractal_ledger_flush", 1)
    ok("fractal_ledger_truth_count", 1)
    ok("fractal_ledger_shadow_count", 1)
    v = ok("fractal_ledger_verify", 1)
    check("the chain verifies", v is not None and '"ok":true' in v.replace(" ", ""), v)
    call("fractal_ledger_verify", 1, 2)
    call("fractal_audit_unpack", "")
    call("fractal_audit_unpack", "zz")
    call("fractal_ledger_load", 1)
    call("fractal_ledger_compact", 1)
    call("fractal_ledger_reset_soft", 1)
    call("fractal_ledger_flush", 1)
    call("fractal_ledger_reset_hard", 1)


# ---- mutations: every call above, replayed with its arguments bent (cut short, swapped, doubled, extreme, junk). The parsers and
# validators have a branch for each of these; none may take the daemon down.
MUTATIONS = int(os.environ.get("FSQL_WORKOUT_MUTATIONS", "30"))
mr = random.Random(11)
JUNK = ["", " ", "[", "]", "[]", "{", "}", "{}", "null", "NaN", "inf", "-inf", "1e999", "-1e999", "0", "-0", "1", "-1", "2147483648",
        "-2147483649", "18446744073709551616", "0x10", "1,,2", ",", ";", ";;", "a;b", "[[1,2],[3]]", "[1,2", "1 2 3", "\u0000", "\xff\xfe",
        '{"a":', '{"seed":-1}', '{"seed":"x"}', '{"iterations":0}', '{"iterations":99999999}', '{"k":-1}', "'", '"', "%s%n", "../..", "\\",
        "/etc/passwd", "a\x00b", "/*", "--", "a" * 64, "a" * 256, "a" * 4096]
EXTREME = [0, 1, -1, 2, 7, 255, 256, 65535, 2 ** 31 - 1, 2 ** 31, -2 ** 31, 2 ** 63 - 1, -2 ** 63, 0.0, -0.0, 1e-300, 1e300, float("inf"), float("nan")]


def bend(v):
    r = mr.random()
    if isinstance(v, (int, float)) and not isinstance(v, bool):
        return mr.choice(EXTREME) if r < 0.7 else str(v)
    if v is None:
        return mr.choice(JUNK)
    t = v if isinstance(v, str) else v.decode("latin1")
    if r < 0.15:
        return None
    if r < 0.30:
        return t[: mr.randint(0, max(0, len(t)))]
    if r < 0.45:
        return t + mr.choice(JUNK)
    if r < 0.55:
        i = mr.randint(0, len(t))
        return t[:i] + mr.choice(JUNK) + t[i:]
    if r < 0.65:
        return mr.choice(EXTREME)
    if r < 0.75:
        return (t + ",") * mr.randint(2, 6)
    if r < 0.82:
        return t.replace(",", ";", mr.randint(1, 5))
    return mr.choice(JUNK)


if MUTATIONS:
    cli = None
    for name, args in list(SEEN):
        for _ in range(MUTATIONS):
            a = list(args)
            if a:
                if mr.random() < 0.15:
                    del a[mr.randrange(len(a))]
                elif mr.random() < 0.1:
                    a.append(mr.choice(JUNK))
                for _k in range(mr.randint(1, 2)):
                    if a:
                        i = mr.randrange(len(a))
                        a[i] = bend(a[i])
            try:
                if cli is None:
                    cli = fc.Client(sock, key, timeout=15 if lenient else 30)
                cli.call(name, *a)
            except Exception:
                try:
                    cli.close()
                except Exception:
                    pass
                cli = None
            calls += 1
    if cli is not None:
        cli.close()

# A systematic sweep: each working call above, with one argument at a time replaced by every value in a pool for its kind (and with the last
# argument left off, and one added). The random mutations above reach the same code by luck; this reaches each boundary on purpose.
#
# The pools carry the boundaries that matter: the length limits a path or a name may have (63, 64, 65, 255, 256, 4095, 4096, 65535,
# 65536 characters), the 32-bit and 64-bit integer limits, the empty and the whitespace-only string, an embedded NUL, invalid UTF-8,
# and the strings that look like paths (which the config and path rules have their own opinions about).
SWEEP = int(os.environ.get("FSQL_WORKOUT_SWEEP", "0"))
POOL = {
    str: ["", None, " ", "x", "[", "[]", "{}", "null", "NaN", "1", "1,2", "1,,2", ";", "[1,2,3]", "[[1,2],[3,4]]", '{"a":1}', '{"seed":-1}',
          '{"iterations":0,"population_size":1}', "1e999", "-1", "a" * 300, "\u00e9\u20ac", "0,0;1,1", "1,2,3;4,5",
          # the length boundaries
          "a" * 63, "a" * 64, "a" * 65, "a" * 255, "a" * 256, "a" * 4095, "a" * 4096, "a" * 65535, "a" * 65536,
          # an embedded NUL, and bytes that are not valid UTF-8
          "a\x00b", "\x00", "a\x00", b"\xff\xfe", b"\xc3", b"a\x80b",
          # things that look like paths
          "/etc/passwd", "../..", "./x", "/", "//host/share", "~/x", "a/b/c", "\\\\server\\share",
          # the text shapes the parsers have opinions about
          "SELECT 1", "SELECT 1; DROP TABLE t", "\t\n ", "--", "/*", "/*!", "0x10", "1_000", "  1  ",
          ],
    int: [None, 0, 1, -1, 2, 3, 7, 64, 65, 255, 256, 2 ** 31 - 1, 2 ** 31, -2 ** 31, 2 ** 63 - 1, -2 ** 63,
          2 ** 32 - 1, 2 ** 32, -2 ** 32, 2 ** 16 - 1, 2 ** 16, 4095, 4096, 65535, 65536],
    float: [None, 0.0, -0.0, 1e-300, 1e300, float("inf"), float("nan"), 0.5, 1.0, 1.5, -1.0,
            2 ** 53, -(2 ** 53), 1e-320, 5e-324],
}
if SWEEP:
    cli = None
    seen_shapes = {}
    for name, args in list(SEEN):
        shape = (name, tuple(type(a) for a in args))
        if seen_shapes.get(shape, 0) >= SWEEP:
            continue
        seen_shapes[shape] = seen_shapes.get(shape, 0) + 1
        variants = [list(args[:-1])] if args else []
        variants.append(list(args) + ["x"])
        for i, a0 in enumerate(args):
            for v in POOL.get(type(a0), POOL[str]):
                a = list(args)
                a[i] = v
                variants.append(a)
        for a in variants:
            try:
                if cli is None:
                    cli = fc.Client(sock, key, timeout=15 if lenient else 30)
                cli.call(name, *a)
            except Exception:
                try:
                    cli.close()
                except Exception:
                    pass
                cli = None
            calls += 1
    if cli is not None:
        cli.close()

# The daemon must still be there
if not lenient:
    st, v = call("fractal_version")
    check("the daemon is still up after the workout", st == 0 and v, (st, v))

# The corpus for the fuzzers: every call above, with its function name and arguments, in the
# format tests/fuzz/fuzz_svc_udf.c reads. It is what the fuzzer starts from, so the first
# inputs it tries are the ones the product documents.
DUMP = os.environ.get("FSQL_WORKOUT_DUMP_CORPUS")
if DUMP:
    os.makedirs(DUMP, exist_ok=True)
    for n, (name, args) in enumerate(SEEN):
        blob = bytearray()
        nb = name.encode("utf-8")
        blob.append(len(nb))
        blob += nb
        blob.append(min(len(args), 255))
        for a in args:
            if a is None:
                blob.append(1)                       # NULL
                blob += struct.pack("<I", 0)
                continue
            if isinstance(a, bool):
                a = int(a)
            if isinstance(a, int):
                try:
                    v = struct.pack("<q", a)
                except struct.error:
                    v = struct.pack("<q", 0)
                blob.append(2)                       # an int argument
                blob += struct.pack("<I", len(v))
                blob += v
                continue
            if isinstance(a, float):
                v = struct.pack("<d", a)
                blob.append(4)                       # a real argument
                blob += struct.pack("<I", len(v))
                blob += v
                continue
            if isinstance(a, str):
                v = a.encode("utf-8", "surrogateescape")
            else:
                v = bytes(a)
            blob.append(0)                           # a string argument
            blob += struct.pack("<I", len(v))
            blob += v
        with open(os.path.join(DUMP, "udf_%05d.bin" % n), "wb") as fh:
            fh.write(bytes(blob))
    print("%d corpus file(s) written to %s" % (len(SEEN), DUMP))

print("%d calls" % calls)
print("%d failure(s)" % len(failures))
sys.exit(1 if failures else 0)
