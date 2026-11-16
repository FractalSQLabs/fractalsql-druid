#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
# SPDX-FileCopyrightText: 2026 Daniel Gardiner d/b/a FractalSQLabs
"""One pass of the call mix the resident-size check measures.

usage: rss_mix.py SOCKET KEYFILE

A fixed list of calls over the registry's working paths: the vectors, the
dimension and analytics functions, the search, the configuration overlay,
the sessions, and the ledger's read-only probes. It is deliberately
small and fixed, so that a pass takes the same shape every time: the
resident-size check runs it in a loop and compares the daemon's size
after one pass with its size after the next.

Nothing here needs a provider, so the pass is fast and does not depend on
a mock being up.
"""
import os
import sys

import fsq_client as fc

SERIES = ",".join("%.4f" % (i * 0.37) for i in range(96))
PTS2 = ",".join("%.3f" % ((i * 7) % 11 / 11.0) for i in range(60))
PTS3 = ",".join("%.3f" % ((i * 5) % 7 / 7.0) for i in range(60))
CORPUS = "[[1,2,3,4],[4,3,2,1],[1,1,1,1],[2,2,2,2]]"
COV = ",".join("%.4f" % (0.05 if i == j else 0.004) for i in range(6) for j in range(6))

CALLS = [
    ("fractal_version", []),
    ("fractal_edition", []),
    ("fractal_vector_dims", ["[1,2,3]"]),
    ("fractal_vector_norm", ["[3,4]"]),
    ("fractal_vector_normalize", ["[3,4]"]),
    ("fractal_vector_add", ["[1,2]", "[3,4]"]),
    ("fractal_vector_l2_distance", ["[0,0]", "[3,4]"]),
    ("fractal_vector_cosine_similarity", ["[1,0]", "[0,1]"]),
    ("fractal_vector_to_json", ["[1,2,3]"]),
    ("fractal_vector_quantize_int8", ["[0.5,-0.5]"]),
    ("fractal_dimension_dfa", [SERIES]),
    ("fractal_dimension_boxcount", [PTS2, 2]),
    ("fractal_dimension_drift", [SERIES, 64]),
    ("fractal_change_point_detect", [SERIES, 16, 3.0, 10]),
    ("fractal_periodogram", [SERIES, 5]),
    ("fractal_spectrogram_entropy", [SERIES]),
    ("fractal_state_fingerprint", ["[1,2,3,4]", 64, 0]),
    ("fractal_cycle_detect", [",".join(str(i % 251) for i in range(96)), 8, 4]),
    ("fractal_tda_persistence_diagram", [PTS3, 3, 1, 2.0, 10]),
    ("fractal_search", [CORPUS, "[1,2,3,4]", 2, "{}"]),
    ("fractal_search_explore", [CORPUS, "[1,2,3,4]", "{}"]),
    ("fractal_optimize_portfolio", ["0.1,0.2,0.3", COV, 3, "{}"]),
    ("fractal_optimize_subset", ["5,4,3,2,1,6", "1,1,1,1,1,1", 3, "{}"]),
    ("fractal_t2s_check_allowlist", ["SELECT 1 FROM t"]),
    ("fractal_t2s_check_allowlist", ["DROP TABLE t"]),
    ("fractal_config_keys", []),
    ("fractal_config_get", ["think", 1]),
    ("fractal_config_set", ["think", "high", 1]),
    ("fractal_config_reset", [1]),
    ("fractal_diversify_enable", [1]),
    ("fractal_detect_collapse", [1]),
    ("fractal_explain_result", [1]),
    ("fractal_diversify_disable", [1]),
    ("fractal_session_close", [1]),
    ("fractal_ledger_truth_count", [1]),
    ("fractal_ledger_shadow_count", [1]),
    ("fractal_ledger_verify", [1]),
]


def main():
    sock, keyfile = sys.argv[1:3]
    key = fc.load_key(keyfile)
    # The mix is repeated, so that a pass is long enough for the daemon
    # (and, for the JVM daemon, the JVM itself) to be doing real work
    # rather than warming up: a pass that takes a millisecond measures
    # the start-up, not the growth.
    repeat = int(os.environ.get("FSQL_RSS_MIX_REPEAT", "20"))
    c = fc.Client(sock, key, timeout=30)
    errors = 0
    calls = 0
    try:
        for _ in range(repeat):
            for name, args in CALLS:
                try:
                    c.call(name, *args)
                    calls += 1
                except Exception:
                    errors += 1
    finally:
        try:
            c.close()
        except Exception:
            pass
    print("%d call(s), %d error(s)" % (calls, errors))
    return 0


if __name__ == "__main__":
    sys.exit(main())
