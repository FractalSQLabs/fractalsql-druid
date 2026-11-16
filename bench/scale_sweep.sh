#!/usr/bin/env bash
# bench/scale_sweep.sh: the exact scan against Scout at a range of corpus sizes, dim fixed.
#
# Regenerates bench_vectors at each N with data_gen.py, then runs head_to_head.py --quiet. Prints one
# block per N so the sweep reads as a table you can eyeball for the latency and island trend.
#
# usage: bench/scale_sweep.sh [dim]
# Environment: DRUID_URL, DRUID_FRACTALSQL_URL (defaults: localhost:8888 and localhost:8082)
set -euo pipefail
DIM="${1:-32}"
for N in 1000 2000 5000 10000; do
  echo "== N=$N dim=$DIM"
  python3 bench/data_gen.py --n "$N" --dim "$DIM" --clusters 20 > /dev/null
  python3 bench/head_to_head.py --quiet --queries 5
done
