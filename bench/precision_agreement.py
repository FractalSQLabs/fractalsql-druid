#!/usr/bin/env python3
"""
bench/precision_agreement.py -- the precision-contract agreement metric
for this host's SQL vector functions.

For each dimension it draws unit vectors, computes the cosine distance
through the extension's SQL functions (fractal_vector_cosine_distance and
friends) and compares them with a float64 reference (numpy) and with the
sequential-double reference the precision contract specifies. It reports
the top-10 agreement, the maximum absolute and relative error against the
float64 reference, and the share of results BIT-identical to the
sequential double reference (1.0000 expected).

On Druid the SQL surface is Druid's own SQL API over HTTP, so the driver
posts a query to /druid/v2/sql. The IVF index (the fractal_index_* family
and the indexed fractal_search) is a separate benchmark track: see
index_head_to_head.py.

Usage:
    python3 bench/precision_agreement.py [--url http://localhost:8888]
        [--dims 128,768,1536] [--n 400] [--queries 20]
        [--embeddings FILE.npy]
"""
import argparse
import json
import math
import os
import struct
import sys
import urllib.error
import urllib.request

import numpy as np


def vtxt(v):
    """The canonical vector text this host uses: the numbers in the
    shortest float32 round-tripping form."""
    f = np.asarray(v, dtype="<f4")
    return "[" + ",".join(repr(float(x)) for x in f) + "]"


def seq_cos(a, b):
    d = x = y = 0.0
    for p, q in zip(a.tolist(), b.tolist()):
        d += p * q
        x += p * p
        y += q * q
    return 1.0 if x == 0 or y == 0 else 1.0 - d / (math.sqrt(x) * math.sqrt(y))


class Druid(object):
    """Druid's SQL API over HTTP."""

    def __init__(self, url):
        self.url = url.rstrip("/") + "/druid/v2/sql"

    def query(self, sql, parameters=None):
        body = {"query": sql, "resultFormat": "object", "header": True, "types": True}
        if parameters:
            body["parameters"] = parameters
        request = urllib.request.Request(
            self.url,
            data=json.dumps(body).encode("utf-8"),
            headers={"Content-Type": "application/json"},
            method="POST",
        )
        try:
            with urllib.request.urlopen(request, timeout=600) as response:
                return json.loads(response.read().decode("utf-8", "replace"))
        except urllib.error.HTTPError as exc:
            detail = exc.read().decode("utf-8", "replace")
            raise RuntimeError("the SQL query failed: {}".format(detail))


def scalar(db, sql, parameters=None):
    rows = db.query(sql, parameters)
    if not rows:
        return None
    row = rows[0]
    for value in row.values():
        return value
    return None


def run(db, name, X, Q):
    agree = 0
    exact = tot = 0
    max_abs = max_rel = 0.0
    X64 = X.astype(np.float64)
    for q in Q:
        sql = np.array(
            [
                float(scalar(db, "SELECT fractal_vector_cosine_distance(?, ?)",
                             [{"type": "VARCHAR", "value": vtxt(q)}, {"type": "VARCHAR", "value": vtxt(x)}]))
                for x in X
            ],
            dtype=np.float64,
        )
        q64 = q.astype(np.float64)
        ref64 = 1.0 - (X64 @ q64) / (np.linalg.norm(X64, axis=1) * np.linalg.norm(q64))
        seq = np.array([seq_cos(q, x) for x in X])
        agree += int(
            list(np.lexsort((np.arange(len(X)), sql))[:10])
            == list(np.lexsort((np.arange(len(X)), ref64))[:10])
        )
        err = np.abs(sql - ref64)
        max_abs = max(max_abs, err.max())
        max_rel = max(max_rel, (err / np.maximum(np.abs(ref64), 1e-30)).max())
        exact += int((sql.view(np.uint64) == seq.view(np.uint64)).sum())
        tot += len(X)
    return {
        "function": name,
        "top10_agreement": round(agree / max(1, len(Q)), 4),
        "max_abs_error_vs_float64": float(max_abs),
        "max_rel_error_vs_float64": float(max_rel),
        "bit_identical_to_sequential_double": round(exact / max(1, tot), 4),
    }


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--url", default=os.environ.get("DRUID_URL", "http://localhost:8888"), help="the Druid SQL API (the router), default DRUID_URL or http://localhost:8888")
    parser.add_argument("--dims", default="128,768,1536")
    parser.add_argument("--n", type=int, default=400, help="rows per query")
    parser.add_argument("--queries", type=int, default=20)
    parser.add_argument("--embeddings", default=None, help="a .npy of the corpus")
    args = parser.parse_args(argv)

    db = Druid(args.url)
    try:
        scalar(db, "SELECT 1")
    except Exception as exc:
        print("SKIP: the Druid SQL endpoint is not reachable ({}).".format(exc))
        return 0

    rng = np.random.default_rng(20261118)
    results = []
    for dim in [int(d) for d in args.dims.split(",") if d.strip()]:
        if args.embeddings:
            X = np.load(args.embeddings)[: args.n]
            X = X / np.maximum(np.linalg.norm(X, axis=1, keepdims=True), 1e-12)
        else:
            X = rng.normal(size=(args.n, dim)).astype(np.float32)
            X /= np.maximum(np.linalg.norm(X, axis=1, keepdims=True), 1e-12)
        Q = []
        for _ in range(args.queries):
            q = rng.normal(size=dim).astype(np.float32)
            q /= max(float(np.linalg.norm(q)), 1e-12)
            Q.append(q)
        results.append(run(db, "fractal_vector_cosine_distance", X, Q))
        print(json.dumps(results[-1]))

    worst = min(r["bit_identical_to_sequential_double"] for r in results)
    print("---")
    print("bit-identical to the sequential double reference: {} (1.0000 expected)".format(worst))
    return 0 if worst >= 1.0 else 1


if __name__ == "__main__":
    sys.exit(main())
