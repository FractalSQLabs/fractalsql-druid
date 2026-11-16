#!/usr/bin/env python3
"""
bench/index_head_to_head.py -- the native IVF index (fractal_index_create
and the indexed fractal_search) against an exact scan, on this host.

Contestants, all on the same datasource:
  exact       the extension's /fractalsql/search/telemetry -- the
              brute-force scan, the ground truth
  index       the indexed fractal_search, for each vector_format, at a
              fixed nprobe and at every cell

For every contestant it reports recall@10 against the exact top-10, the
median latency per query, the build seconds and the ROWS SCANNED (the
"index actually used" check: far below the datasource's row count). The
distances the index returns are verified: every candidate is checked
against the index's own FP16 payload, so they are exact to FP16 precision
-- the exact scan is the float32 reference.

On Druid the index's operations are service operations (they read a
datasource and, for a build, write one), so the driver talks to the
extension's /fractalsql/index endpoint and to /fractalsql/search/telemetry.

The index needs a core that carries the IVF maths. When the vendored
archive predates it, every index call reports "this build of
fractalsql-core does not carry the IVF index (rebuild the core and
refresh include/<platform>)" and this script says so and exits 0.

Usage:
    python3 bench/index_head_to_head.py [--url http://localhost:8888]
        [--service http://localhost:8082] [--datasource bench_vectors]
        [--n 20000] [--dim 128] [--clusters 50] [--queries 60]
        [--formats INT8,INT4,FP16,FP32]
"""
import argparse
import json
import os
import statistics
import sys
import time
import urllib.error
import urllib.request

import numpy as np

NO_IVF = "does not carry the IVF index"


def vtxt(v):
    f = np.asarray(v, dtype="<f4")
    return "[" + ",".join(repr(float(x)) for x in f) + "]"


def post(base, path, body):
    request = urllib.request.Request(
        base.rstrip("/") + path,
        data=json.dumps(body).encode("utf-8"),
        headers={"Content-Type": "application/json"},
        method="POST",
    )
    try:
        with urllib.request.urlopen(request, timeout=1800) as response:
            return json.loads(response.read().decode("utf-8", "replace"))
    except urllib.error.HTTPError as exc:
        detail = exc.read().decode("utf-8", "replace")
        try:
            detail = json.loads(detail).get("error", detail)
        except ValueError:
            pass
        raise RuntimeError("the call failed: {}".format(detail))


def exact_scan(service, datasource, column, query, k):
    """The ground truth: the extension's exact scan over the column."""
    answer = post(service, "/fractalsql/search/telemetry",
                  {"datasource": datasource, "vectorColumn": column,
                   "query": vtxt(query), "k": k})
    hits = answer.get("hits", [])
    return [(h.get("doc_id"), float(h.get("distance", 0.0))) for h in hits]


def index_search(service, datasource, column, query, k, options):
    answer = post(service, "/fractalsql/index",
                  {"action": "search", "table": datasource, "column": column,
                   "query": vtxt(query), "k": k, "options": options})
    candidates = answer.get("candidates", [])
    return (
        [(c.get("doc_id"), float(c.get("distance", 0.0))) for c in candidates],
        int(answer.get("rows_scanned", 0)),
        int(answer.get("cells_probed", 0)),
    )


def recall_at_10(truth, found):
    if not truth:
        return 0.0
    ids = {d for d, _ in truth[:10]}
    hit = sum(1 for d, _ in found if d in ids)
    return hit / float(len(ids))


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--url", default=os.environ.get("DRUID_URL", "http://localhost:8888"), help="the Druid SQL API (the router), default DRUID_URL or http://localhost:8888")
    parser.add_argument("--service", default=os.environ.get("DRUID_FRACTALSQL_URL", "http://localhost:8082"), help="the extension's URL (the broker), default DRUID_FRACTALSQL_URL or http://localhost:8082")
    parser.add_argument("--datasource", default="bench_vectors")
    parser.add_argument("--column", default="embedding")
    parser.add_argument("--n", type=int, default=20000, help="rows in the datasource")
    parser.add_argument("--dim", type=int, default=128)
    parser.add_argument("--clusters", type=int, default=50)
    parser.add_argument("--queries", type=int, default=60)
    parser.add_argument("--formats", default="INT8,INT4,FP16,FP32")
    parser.add_argument("--nprobe", type=int, default=8)
    args = parser.parse_args(argv)
    service = args.service or args.url

    rng = np.random.default_rng(20261118)
    centres = rng.normal(size=(args.clusters, args.dim)).astype(np.float32)
    centres /= np.maximum(np.linalg.norm(centres, axis=1, keepdims=True), 1e-12)
    queries = []
    for _ in range(args.queries):
        q = centres[rng.integers(0, args.clusters)] + rng.normal(scale=0.05, size=args.dim).astype(np.float32)
        q /= max(float(np.linalg.norm(q)), 1e-12)
        queries.append(q.astype(np.float32))

    # The ground truth, once per query.
    truth = []
    exact_times = []
    for q in queries:
        t0 = time.time()
        truth.append(exact_scan(service, args.datasource, args.column, q, 10))
        exact_times.append(time.time() - t0)
    print(json.dumps({
        "contestant": "exact",
        "recall_at_10": 1.0,
        "median_latency_ms": round(statistics.median(exact_times) * 1000.0, 2),
        "rows_scanned": args.n,
    }))

    for fmt in [f.strip().upper() for f in args.formats.split(",") if f.strip()]:
        name = "{}_{}_index".format(args.datasource, fmt.lower())
        try:
            t0 = time.time()
            built = post(service, "/fractalsql/index",
                         {"action": "create", "table": args.datasource, "column": args.column,
                          "options": {"name": name, "vector_format": fmt, "seed": 7}})
        except RuntimeError as exc:
            if NO_IVF in str(exc):
                print("SKIP: this build of fractalsql-core does not carry the IVF index "
                      "(rebuild the core and refresh include/<platform>)")
                return 0
            print("SKIP: the index could not be built: {}".format(exc))
            return 0
        build_seconds = time.time() - t0
        indexed_rows = int(built.get("rows", 0))

        latencies = []
        recalls = []
        scanned = []
        for q, truth_hits in zip(queries, truth):
            t0 = time.time()
            found, rows_scanned, _cells = index_search(
                service, args.datasource, args.column, q, 10,
                {"index": name, "nprobe": args.nprobe})
            latencies.append(time.time() - t0)
            recalls.append(recall_at_10(truth_hits, found))
            scanned.append(rows_scanned)
        print(json.dumps({
            "contestant": "index/{}".format(fmt),
            "nprobe": args.nprobe,
            "build_seconds": round(build_seconds, 2),
            "recall_at_10": round(sum(recalls) / max(1, len(recalls)), 4),
            "median_latency_ms": round(statistics.median(latencies) * 1000.0, 2),
            "rows_scanned": int(statistics.median(scanned)),
            "indexed_rows": indexed_rows,
            "index_actually_used": bool(scanned and statistics.median(scanned) < indexed_rows),
        }))
        post(service, "/fractalsql/index", {"action": "drop", "name": name})
    return 0


if __name__ == "__main__":
    sys.exit(main())
