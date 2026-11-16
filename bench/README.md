<p align="center">
  <img src="../FractalSQLforDruid.jpg" alt="FractalSQL for Apache Druid" width="720">
</p>

# FractalSQL benchmark: exact scan vs Scout Mode on Druid

A head-to-head of an exact nearest-neighbour scan against FractalSQL's Scout
Mode (`/fractalsql/search/explore`), on a synthetic Gaussian-cluster dataset
in Druid. It measures search latency and how many distinct clusters
("islands") the top-k results touch.

An exact top-k by distance collapses onto whichever one cluster is closest to
the query. Scout trades some latency for a spread across clusters. Both are
linear scans over the column: neither is an approximate index.

## Prerequisites

- A running Druid with the extension loaded and `fractalsqld` reachable (the
  demo stack: `docker compose -f docker/docker-compose.yml up -d`)
- Python 3.9+ and `numpy` (`pip install -r bench/requirements.txt`)

The scripts read `DRUID_URL` (default `http://localhost:8888`) and
`DRUID_FRACTALSQL_URL` (default `http://localhost:8082`).

## Run it

```bash
python3 bench/data_gen.py                # write the bench_vectors datasource
python3 bench/head_to_head.py            # exact scan vs Scout, averaged over queries
bench/scale_sweep.sh [dim]               # the same at N = 1000, 2000, 5000, 10000
```

`data_gen.py` takes `--n` (default 5000), `--clusters` (20), `--dim` (32),
`--sigma` (0.05) and `--seed` (7). It writes one datasource,
`bench_vectors(__time, id, cluster_id, emb)`, where `emb` is the vector in the
core's JSON text form. Cluster `k` holds ids `k*per .. (k+1)*per - 1`, so a
result's id says which island it came from.

`head_to_head.py` takes `--queries` (default 5), `--k` (50) and `--quiet`. For
each query, a point near the first cluster's centre, it reports each method's
latency and the number of distinct clusters its k results touch.

## Reading the result

Expect the exact scan to return the k nearest rows, almost all from one
cluster, and Scout to return a diverse population from several. Both costs
grow linearly with the number of stored vectors and with the dimension, since
each scans the whole column. Latency depends heavily on your hardware, so
run the benchmark on your own cluster for numbers that mean something for
your workload.

## Measured results

One run on a development VM: 5 vCPUs and 7 GiB of RAM, Linux, Docker, the demo stack
(Druid 38 in the micro-quickstart topology, one historical, `fractalsqld` beside the
coordinator). Dimension 32, 20 clusters, `k` = 50, each point the average over the
queries shown. Times include the HTTP round trip. This is a single run, not a
statistical study: the first query of a run is often slower than the rest, and your
cluster will differ.

| Stored vectors | Exact scan (ms) | Exact: clusters touched | Scout (ms) | Scout: clusters touched | Queries |
| ---: | ---: | ---: | ---: | ---: | ---: |
| 1,000 | 97 | 1.0 | 77 | 3.6 | 5 |
| 2,000 | 154 | 1.0 | 135 | 3.8 | 5 |
| 5,000 | 267 | 1.0 | 235 | 3.8 | 5 |
| 10,000 | 483 | 1.0 | 524 | 3.8 | 5 |
| 5,000 (default run) | 381 | 1.0 | 350 | 4.0 | 10 |

What it shows: the exact top-50 always lands in a single cluster, and Scout's 50
results span 3 to 6 of the 20 clusters, at about the same latency. Both grow roughly
linearly with the number of stored vectors, as expected of two scans. The scripts
write the dataset with MSQ batches, so loading is slower than querying: 5,000 vectors
took about four minutes to load on this VM.
