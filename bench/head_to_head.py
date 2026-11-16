#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
# SPDX-FileCopyrightText: 2026 Daniel Gardiner d/b/a FractalSQLabs
"""
bench/head_to_head.py: an exact nearest-neighbour scan against Scout Mode, on Druid.

For each query (a point near the first cluster's center) it runs
  exact   Druid SQL ordering the datasource by cosine distance, top k
  Scout   POST /fractalsql/search/explore (SFS + MMR over the same column), population k
and reports each one's latency and how many distinct clusters ("islands") its k results touch.

An exact top-k collapses onto the one cluster nearest the query; Scout trades some latency for a
spread across clusters. Both are linear scans: this is not an approximate index.

usage: head_to_head.py [--queries 5] [--k 50] [--quiet]
Environment: DRUID_URL (default http://localhost:8888), DRUID_FRACTALSQL_URL (default http://localhost:8082)
Run data_gen.py first.
"""
import argparse
import json
import os
import time
import urllib.request

import numpy as np

HERE = os.path.dirname(os.path.abspath(__file__))
DRUID = os.environ.get("DRUID_URL", "http://localhost:8888").rstrip("/")
SERVICE = os.environ.get("DRUID_FRACTALSQL_URL", "http://localhost:8082").rstrip("/")


def post(url, body, timeout=600):
    req = urllib.request.Request(url, data=json.dumps(body).encode(), headers={"Content-Type": "application/json"})
    with urllib.request.urlopen(req, timeout=timeout) as r:
        return json.loads(r.read())


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--queries", type=int, default=5)
    ap.add_argument("--k", type=int, default=50)
    ap.add_argument("--quiet", action="store_true")
    args = ap.parse_args()

    centers = np.load(os.path.join(HERE, "bench_centers.npy"))
    rng = np.random.default_rng(11)
    n_rows = post(DRUID + "/druid/v2/sql", {"query": 'SELECT COUNT(*) FROM "bench_vectors"', "resultFormat": "array"})[0][0]
    per = n_rows // len(centers)
    print("Benchmark: %d stored vectors, %d clusters, dim=%d" % (n_rows, len(centers), centers.shape[1]))
    print("  exact: Druid SQL, cosine distance, top-%d" % args.k)
    print("  Scout: population=%d (walk=0, brute-force relevance scan + MMR)\n" % args.k)
    print("qi |     exact ms   exact islands |    Scout ms   Scout islands")

    totals = np.zeros(4)
    for qi in range(args.queries):
        q = np.clip(centers[0] + rng.normal(0, 0.02, size=centers.shape[1]), -1, 1)
        qtext = "[" + ",".join("%.5f" % v for v in q) + "]"

        t0 = time.time()
        rows = post(DRUID + "/druid/v2/sql", {
            "query": ('SELECT "id", FRACTAL_VECTOR_COSINE_DISTANCE("emb", \'%s\') AS "d" FROM "bench_vectors" '
                      'GROUP BY "id", "emb" ORDER BY "d" LIMIT %d') % (qtext, args.k),
            "resultFormat": "array"})
        exact_ms = (time.time() - t0) * 1000
        exact_islands = len({int(r[0]) // per for r in rows})

        t0 = time.time()
        out = post(SERVICE + "/fractalsql/search/explore", {
            "datasource": "bench_vectors", "vectorColumn": "emb", "idColumn": "id",
            "query": qtext, "k": args.k, "params": json.dumps({"population_size": args.k, "walk": 0})})
        scout_ms = (time.time() - t0) * 1000
        hits = out.get("rows", []) if isinstance(out, dict) else out
        ids = []
        for h in hits if isinstance(hits, list) else []:
            if isinstance(h, dict) and "doc_id" in h:
                ids.append(int(h["doc_id"]))
        scout_islands = len({i // per for i in ids}) if ids else 0

        totals += (exact_ms, exact_islands, scout_ms, scout_islands)
        print("%2d | %12.0f %14d | %11.0f %14d" % (qi, exact_ms, exact_islands, scout_ms, scout_islands))

    avg = totals / args.queries
    print("\navg | %12.0f %14.1f | %11.0f %14.1f" % tuple(avg))
    if not args.quiet:
        print("\nIslands is the number of distinct clusters among the k results (more = a more diverse set).")


if __name__ == "__main__":
    main()
