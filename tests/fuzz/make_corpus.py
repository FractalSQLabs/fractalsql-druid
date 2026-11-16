#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
# SPDX-FileCopyrightText: 2026 Daniel Gardiner d/b/a FractalSQLabs
"""Write the seed corpora for the daemon's fuzz targets.

usage: python3 tests/fuzz/make_corpus.py [DIR]

Every corpus is small and deterministic: the same script always writes the
same files, so a corpus change is a reviewable diff and not a pile of
random bytes. The seeds are the inputs the product documents -- the vector
and series texts, the audit payloads, the statements the text-to-SQL
policy has opinions about, a real ledger and the ways a ledger gets
damaged, the protocol frames, and the configuration file.

The UDF corpus is not written here: it comes from the live daemon, which
knows the registry better than a script does. service/tests/workout.py
writes it when FSQL_WORKOUT_DUMP_CORPUS names a directory.

usage: FSQL_WORKOUT_DUMP_CORPUS=tests/fuzz/corpus_svc_udf python3 service/tests/workout.py SOCKET KEYFILE
"""
import os
import struct
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)

# ---- the inputs each target starts from -----------------------------------

VECTORS = [
    "", " ", "[]", "[1]", "[1,2,3]", "1,2,3", "[3,4]", "0,0;1,1",
    "[[1,2,3],[4,5,6]]", "[1,2,3];[4,5,6]", "[[1,2],[3]]", "[1,2",
    "1,,2", "[1,2,]", "[-1.5,2.5]", "[1e309]", "[nan]", "[inf]", "[-inf]",
    "[0]", "[0,0,0]", "[1e-320]", "[1e308,-1e308]", "[ 1 , 2 ]", "[\t1\n]",
    "[1,2,3] trailing", "leading [1,2,3]", "[1;2]", "[1,2];;[3,4]",
    "x" * 300, "1,2,3" * 100, "[0.1,0.2,0.3]",
]

SERIES = [
    ",".join("%.4f" % (i * 0.5) for i in range(64)),
    ",".join("%.4f" % (i % 7) for i in range(120)),
    ",".join(str(i) for i in range(16)),
    ",".join("0.5" for _ in range(40)),
    "1,2", "1", "",
]

INDEXES = [
    "0,1,2", "0", "", "0,1,2,3", "0;1", "0,1,2", "-1", "0,,1",
    "999999999999999999999", "0x10", " 0 , 1 ",
]

AUDIT = [
    '{"question":"a customer row","sql":"SELECT \'x\' FROM t WHERE y = \'z\'"}',
    '{"a":1}', '{"a":', '{}', '[]', 'null', '123', '"a string"', '{"a":{"b":{"c":1}}}',
    '{"rows":[[1,"a"],[2,"b"]],"analysis":"free text"}', '{"api_key":"secret","n":1}',
    '{"password":"x","token":"y","authorization":"z"}', '{"n":1.5e3,"b":true,"z":null}',
    '{"u":"\\u0000nul"}', '{"k":"' + "w" * 200 + '"}', '{"a":1} trailing', '{"a":1,}',
    "{'a':1}", '{"nested":{"deep":{"list":[1,2,{"k":"v"}],"s":"text"}}}',
]

SQL = [
    "SELECT 1", "SELECT * FROM t", "SELECT a FROM t WHERE a = 1",
    "INSERT INTO t VALUES (1)", "UPDATE t SET a = 1", "DELETE FROM t",
    "REPLACE INTO t VALUES (1)", "DROP TABLE t", "SHOW TABLES", "EXPLAIN SELECT 1",
    "WITH x AS (SELECT 1) SELECT * FROM x", "WITH RECURSIVE r AS (SELECT 1) SELECT * FROM r",
    "SELECT 1; SELECT 2", "SELECT 1;", "(SELECT 1)", "((SELECT 1))",
    "SELECT * FROM t FOR UPDATE", "SELECT 'a;b'", "SELECT \"a;b\"", "SELECT `a;b` FROM t",
    "SELECT 1 INTO OUTFILE '/tmp/x'", "SELECT 1 INTO DUMPFILE '/tmp/x'",
    "SELECT * FROM TABLE(EXTERN('{}', '{}', '[]'))", "SELECT * FROM TABLE(extern ('{}'))", "SELECT SLEEP(5)",
    "SELECT fractal_audit_log('x', '{}')", "SELECT FRACTAL_LEDGER_FLUSH(1)",
    "SELECT 1 -- comment", "SELECT 1 /* comment */", "/*! SELECT 1 */", "/*+ hint */ SELECT 1",
    "/* lead */ SELECT 1", "-- c\nSELECT 1", "# c\nSELECT 1", "SEL/**/ECT 1",
    "SELECT 1 /* unterminated", "SELECT 'unterminated", "SELECT \"x",
    "VALUES (1)", "TABLE t", "SET @a=1", "CALL p()", "GRANT ALL ON *.* TO x",
    "SELECT 1 UNION ALL SELECT 2", "SELECT " + "a," * 200 + "b FROM t",
    "SELECT " + "(" * 100 + "1" + ")" * 100,
]

CONFIGS = [
    "", "# only a comment\n", "socket_path = /tmp/x.sock\nhmac_key_file = /tmp/k\n",
    "socket_path = /tmp/x.sock\nhmac_key_file = /tmp/k\nallowed_uids = 1000\n",
    "max_connections = 0\n", "max_connections = 99999999999\n", "max_connections = -1\n",
    "max_connections = abc\n", "idle_timeout_secs = 0\n", "allowed_uids = 1,2,3,x\n",
    "allowed_uids =\n", "allowed_uids = 99999999999999\n", "unknown_key = 1\n",
    "no_equals_sign_here\n", "=novalue\n", "key_only =\n", "  indented = 1\n",
    "key = value with trailing spaces   \n", "key=value=with=equals\n",
    "reasoning_url = http://127.0.0.1:1/x\n", "reasoning_allow_plaintext = maybe\n",
    "think = bogus\n", "think_num_ctx = 10abc\n", "t2s_max_attempts = 99\n",
    "enterprise_lib = relative/lib.so\n", "enterprise_require_signature = false\n",
    "log_level = verbose\n", "socket_path =\n", "hmac_key_file = /nonexistent/key\n",
    "a = b\\nc = d\\ne = f\\n\\n\\n",
    "long_key_" + "a" * 200 + " = 1\n",
]


def write(dirname, name, data):
    path = os.path.join(dirname, name)
    with open(path, "wb") as fh:
        fh.write(data)


BASE = HERE


def corpus(name):
    d = os.path.join(BASE, "corpus_svc_" + name)
    os.makedirs(d, exist_ok=True)
    for f in os.listdir(d):
        if f.startswith("seed_"):
            os.remove(os.path.join(d, f))
    return d


# ---- the UDF corpus ------------------------------------------------------

def udf_arg_bytes(a):
    if a is None:
        return bytes([1]) + struct.pack("<I", 0)
    if isinstance(a, int):
        try:
            v = struct.pack("<q", a)
        except struct.error:
            v = struct.pack("<q", 0)
        return bytes([2]) + struct.pack("<I", len(v)) + v
    if isinstance(a, float):
        v = struct.pack("<d", a)
        return bytes([4]) + struct.pack("<I", len(v)) + v
    if isinstance(a, str):
        v = a.encode("utf-8", "surrogateescape")
    else:
        v = bytes(a)
    return bytes([0]) + struct.pack("<I", len(v)) + v


def udf_input(name, args):
    nb = name.encode()
    out = bytearray()
    out.append(len(nb))
    out += nb
    out.append(len(args))
    for a in args:
        out += udf_arg_bytes(a)
    return bytes(out)


UDF_CALLS = [
    ("fractal_version", []),
    ("fractal_edition", []),
    ("fractal_vector_dims", ["[1,2,3]"]),
    ("fractal_vector_norm", ["[3,4]"]),
    ("fractal_vector_l2_distance", ["[0,0]", "[3,4]"]),
    ("fractal_vector_normalize", ["[3,4]"]),
    ("fractal_vector_add", ["[1,2]", "[3,4]"]),
    ("fractal_vector_scale", ["[1,2]", 2.0]),
    ("fractal_vector_lp_distance", ["[0,0]", "[3,4]", 1.0]),
    ("fractal_vector_to_json", ["[1,2,3]"]),
    ("fractal_vector_quantize_int8", ["[0.5,-0.5]"]),
    ("fractal_dimension_dfa", [",".join("%.3f" % (i * 0.1) for i in range(64))]),
    ("fractal_dimension_boxcount", [",".join("0.5" for _ in range(40)), 2]),
    ("fractal_dimension_drift", [",".join("%.3f" % (i % 5) for i in range(64)), 64]),
    ("fractal_change_point_detect", [",".join("0" for _ in range(60)), 10, 1.0, 5]),
    ("fractal_periodogram", [",".join("%.3f" % (i % 3) for i in range(64)), 3]),
    ("fractal_spectrogram_entropy", [",".join("%.3f" % (i % 4) for i in range(64))]),
    ("fractal_state_fingerprint", ["[1,2,3,4]", 64, 0]),
    ("fractal_cycle_detect", [",".join(str(i % 256) for i in range(96)), 8, 4]),
    ("fractal_tda_persistence_diagram", [",".join("0.5" for _ in range(40)), 2, 1, 1.0, 10]),
    ("fractal_search", ["[[1,2,3,4],[4,3,2,1]]", "[1,2,3,4]", 2, "{}"]),
    ("fractal_search_explore", ["[[1,2],[3,4]]", "[1,2]", "{}"]),
    ("fractal_optimize_portfolio", ["0.1,0.2,0.3", "0.1,0.2,0.3,0.4,0.5,0.6", 3, "{}"]),
    ("fractal_optimize_subset", ["5,4,3,2,1,6", "1,1,1,1,1,1", 3, "{}"]),
    ("fractal_t2s_check_allowlist", ["SELECT 1"]),
    ("fractal_t2s_config", []),
    ("fractal_config_keys", []),
    ("fractal_config_get", ["think", 1]),
    ("fractal_config_set", ["think", "high", 1]),
    ("fractal_config_reset", [1]),
    ("fractal_diversify_enable", [1]),
    ("fractal_detect_collapse", [1]),
    ("fractal_explain_result", [1]),
    ("fractal_ledger_verify", [1]),
    ("fractal_ledger_truth_count", [1]),
    ("fractal_audit_log", ["test", '{"n":1}', 1, "ci"]),
    ("fractal_vascular_network", ["0,0;1,0;1,1", "0,1;1,2", "1,1,1,1"]),
    ("fractal_cortical_folding", ["0,0,0;1,0,0;0,1,0", "0,1,2;0,1,3", "0,1,2,3"]),
    ("fractal_nerve_plexus_metric", ["0,0;1,0;1,1", 2, "0,1;1,2"]),
    ("fractal_morphological_complexity", [",".join("0.5" for _ in range(40)), 2]),
    ("fractal_reason", [1, "hello"]),
    ("fractal_embed", [1, "hello"]),
]


# ---- the ledger corpus ---------------------------------------------------

LEDGER_MAGIC = b"FSQLLDGR"
LEDGER_VERSION = 1


def ledger_record(kind, blob, has_mac=0):
    """One record in the ledger's own format: the header the reader parses."""
    import hashlib
    mac = hashlib.sha256(bytes(blob)).digest() if has_mac else b"\0" * 32
    prev = b"\0" * 32
    h = hashlib.sha256(prev + blob + mac).digest()
    return (struct.pack("<IBB H", kind, len(blob), has_mac, 0)[:8] +
            mac + prev + h + struct.pack("<q", 0))


def make_ledger():
    out = bytearray()
    out += LEDGER_MAGIC + bytes([LEDGER_VERSION])
    out += ledger_record(1, b"truth-1")
    out += ledger_record(1, b"truth-2")
    out += ledger_record(2, b"audit-1", has_mac=1)
    return bytes(out)


def main():
    global BASE
    BASE = sys.argv[1] if len(sys.argv) > 1 else HERE
    d = corpus("udf")
    for i, (name, args) in enumerate(UDF_CALLS):
        write(d, "seed_%03d.bin" % i, udf_input(name, args))

    d = corpus("parse")
    for i, v in enumerate(VECTORS + SERIES + INDEXES):
        write(d, "seed_%03d.bin" % i, v.encode())

    d = corpus("redact")
    for i, a in enumerate(AUDIT):
        write(d, "seed_%03d.bin" % i, a.encode())

    d = corpus("t2s")
    for i, s in enumerate(SQL):
        write(d, "seed_%03d.bin" % i, s.encode())

    d = corpus("config")
    for i, c in enumerate(CONFIGS):
        write(d, "seed_%03d.bin" % i, c.encode())

    # The ledger: a real one, then the ways one gets damaged.
    d = corpus("ledger")
    good = make_ledger()
    write(d, "seed_000.bin", good)
    write(d, "seed_001.bin", good[:len(good) // 2])          # a torn tail
    write(d, "seed_002.bin", good[:8])                        # the header alone
    write(d, "seed_003.bin", good[:7])                        # a short header
    write(d, "seed_004.bin", b"")                             # an empty file
    write(d, "seed_005.bin", b"FSQLLDGR" + bytes([2]) + good[9:])   # a wrong version
    write(d, "seed_006.bin", b"X" + good[1:])                # a wrong magic
    write(d, "seed_007.bin", good + b"\x00" * 8)             # trailing rubbish
    flipped = bytearray(good)
    flipped[20] ^= 0xFF
    write(d, "seed_008.bin", bytes(flipped))                 # a byte changed
    flipped = bytearray(good)
    flipped[-1] ^= 0x01
    write(d, "seed_009.bin", bytes(flipped))
    write(d, "seed_010.bin", good[:40] + bytes([0xFF] * 200))   # a huge length field

    # The head file's records, as lines: the harness writes the fuzzed
    # bytes to the head file beside the ledger, so these reach the head
    # parser too.
    for i, line in enumerate(["1 3", "kind=1 rows=3", "kind=1 rows=3 mac=" + "ab" * 32,
                              "kind=1", "rows=3", "kind=x rows=1", "", "kind=1 rows=3 junk",
                              "mac=" + "zz" * 32, "0 0", "kind=1 rows=-1"]):
        write(d, "seed_%03d.bin" % (100 + i), line.encode())

    # The frames: a well-formed one, then the ways one is wrong.
    d = corpus("frame")
    hdr = b"FSQ1" + struct.pack("<HHIIQII", 2, 0x10, 0, 1, 0, 32, 0)
    write(d, "seed_000.bin", hdr)
    write(d, "seed_001.bin", b"XXXX" + hdr[4:])
    write(d, "seed_002.bin", b"FSQ1" + struct.pack("<HHIIQII", 1, 0x10, 0, 1, 0, 32, 0))
    write(d, "seed_003.bin", b"FSQ1" + struct.pack("<HHIIQII", 2, 0x10, 0, 1, 0, 32, 0xFFFFFFFF))
    write(d, "seed_004.bin", b"FSQ1" + struct.pack("<HHIIQII", 2, 0x10, 1, 1, 0, 32, 0))
    write(d, "seed_005.bin", hdr + b"\x00" * 32)

    d = corpus("frame_auth")
    for i, payload in enumerate([b"", b"\x00", b"\x10fractal_version" + struct.pack("<I", 0),
                                 bytes(range(32)), b"\xff" * 64]):
        write(d, "seed_%03d.bin" % i, payload)

    d = corpus("sig")
    write(d, "seed_000.bin", b"")
    write(d, "seed_001.bin", b"\x7fELF")
    write(d, "seed_002.bin", bytes(64))
    write(d, "seed_003.bin", b"\x00" * 4096)
    write(d, "seed_004.bin", bytes(range(256)))

    print("corpora written under %s" % BASE)
    return 0


if __name__ == "__main__":
    sys.exit(main())
