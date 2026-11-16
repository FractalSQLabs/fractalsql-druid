#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
# SPDX-FileCopyrightText: 2026 Daniel Gardiner d/b/a FractalSQLabs
"""
bench/data_gen.py: generate the synthetic "Island" dataset in Apache Druid.

Creates N points in d dimensions, organized into K Gaussian clusters. Cluster centers are placed
uniformly in [-1, 1]^d; each point is sampled from a Gaussian around its assigned center. Values are
clipped to [-1, 1] so they fall within FractalSQL's default search bounds.

Writes one datasource, bench_vectors(__time, id, cluster_id, emb), where emb is the vector in the
core's JSON text form, using MSQ batches (the first replaces, the rest append). Cluster k holds ids
k*per .. (k+1)*per - 1, so a result's id says which island it came from.

usage: data_gen.py [--n 5000] [--clusters 20] [--dim 32] [--sigma 0.05] [--seed 7]
Environment: DRUID_URL (default http://localhost:8888)
"""
import argparse
import os
import sys
import time

import numpy as np

sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "demo"))
import run_demo as rd  # noqa: E402


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--n", type=int, default=5000)
    ap.add_argument("--clusters", type=int, default=20)
    ap.add_argument("--dim", type=int, default=32)
    ap.add_argument("--sigma", type=float, default=0.05)
    ap.add_argument("--seed", type=int, default=7)
    ap.add_argument("--batch", type=int, default=400)
    args = ap.parse_args()

    druid = os.environ.get("DRUID_URL", "http://localhost:8888").rstrip("/")
    sql_url, task_url = druid + "/druid/v2/sql", druid + "/druid/v2/sql/task"
    rng = np.random.default_rng(args.seed)
    per = args.n // args.clusters
    centers = rng.uniform(-1, 1, size=(args.clusters, args.dim))

    rows = []
    for k in range(args.clusters):
        pts = np.clip(centers[k] + rng.normal(0, args.sigma, size=(per, args.dim)), -1, 1)
        for j in range(per):
            rows.append((k * per + j, k, "[" + ",".join("%.5f" % v for v in pts[j]) + "]"))

    first = True
    for start in range(0, len(rows), args.batch):
        chunk = rows[start:start + args.batch]
        values = ", ".join("(%d, %d, '%s')" % r for r in chunk)
        verb = "REPLACE INTO \"bench_vectors\" OVERWRITE ALL" if first else "INSERT INTO \"bench_vectors\""
        sql = (verb + " SELECT TIMESTAMP '2026-01-01' AS \"__time\", \"id\", \"cluster_id\", \"emb\" FROM (VALUES "
               + values + ") AS t(\"id\", \"cluster_id\", \"emb\") PARTITIONED BY ALL")
        rd.run_write(sql, sql_url, task_url, {})
        first = False
        print("wrote %d / %d rows" % (min(start + args.batch, len(rows)), len(rows)), flush=True)
    rd.wait_for_datasource('SELECT "id", "cluster_id", "emb" FROM "bench_vectors"', druid, 180)
    # The datasource can be queryable before every segment is published, so wait for the whole row count: a benchmark that
    # started on a partly visible corpus would measure the wrong thing.
    deadline = time.time() + 180
    while True:
        status, body = rd.post_json(sql_url, {"query": 'SELECT COUNT(*) AS "c" FROM "bench_vectors"', "resultFormat": "array"})
        seen = body[0][0] if status == 200 and body else 0
        if seen >= len(rows) or time.time() > deadline:
            break
        time.sleep(2)
    if seen < len(rows):
        sys.exit("bench_vectors has %d of %d rows after waiting; not publishing the centres" % (seen, len(rows)))
    np.save(os.path.join(os.path.dirname(os.path.abspath(__file__)), "bench_centers.npy"), centers)
    print("bench_vectors: %d vectors, %d clusters, dim=%d" % (len(rows), args.clusters, args.dim))


if __name__ == "__main__":
    main()
