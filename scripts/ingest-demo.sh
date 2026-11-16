#!/bin/bash
# Ingest the FractalSQL-for-Druid demo datasource.
#
# Posts the demo_vecs batch-ingestion spec to a running Druid and waits for the task to finish. The datasource holds a small set of rows
# with a 3-dimensional embedding in a Druid ARRAY column -- the column type the fractal_search aggregate reads.
#
# usage: scripts/ingest-demo.sh [--overlord URL] [--datasource NAME] [--timeout SECONDS]
#
# Ingestion tasks go to the OVERLORD, not the router. In the demo stack the coordinator runs as the overlord too
# ("druid.coordinator.asOverlord.enabled") and serves both on port 8081; the router on 8888 only knows the query types.

set -euo pipefail

OVERLORD="http://localhost:8081"
DATASOURCE="demo_vecs"
TIMEOUT=300

while [ $# -gt 0 ]; do
  case "$1" in
    --overlord)   OVERLORD="$2"; shift 2;;
    --datasource) DATASOURCE="$2"; shift 2;;
    --timeout)    TIMEOUT="$2"; shift 2;;
    -h|--help)    sed -n 2,10p "$0" | sed 's/^# \{0,1\}//'; exit 0;;
    *) echo "unknown option $1" >&2; exit 2;;
  esac
done

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SPEC="$ROOT/docker/druid/seed/ingest-spec.json"
[ -f "$SPEC" ] || { echo "ingestion spec not found: $SPEC" >&2; exit 1; }
command -v curl >/dev/null || { echo "curl is required" >&2; exit 1; }
command -v python3 >/dev/null || { echo "python3 is required" >&2; exit 1; }

# The overlord accepts task submissions as soon as its Jetty is up, but it is the last of the services to come online.
# Wait for it rather than racing it.
waited=0
until [ "$(curl -sf -m 5 "$OVERLORD/status/health" 2>/dev/null || true)" = "true" ]; do
  [ "$waited" -lt 300 ] || { echo "the overlord at $OVERLORD did not become healthy" >&2; exit 1; }
  sleep 5; waited=$((waited + 5))
done

# The spec's basePath is a container path; the seed data is mounted read-only at /demo/seed in the Druid container.
echo "submitting the ingestion task for '$DATASOURCE'"
resp="$(curl -sf -m 60 -X POST -H 'Content-Type: application/json' --data-binary "@$SPEC" "$OVERLORD/druid/indexer/v1/task")"
task="$(python3 -c 'import json,sys; print(json.load(sys.stdin)["task"])' <<< "$resp")"
echo "task: $task"

deadline=$((SECONDS + TIMEOUT))
while [ "$SECONDS" -lt "$deadline" ]; do
  sleep 2
  status="$(curl -sf -m 30 "$OVERLORD/druid/indexer/v1/task/$task/status")"
  # The status endpoint nests the state: { status: { status: "SUCCESS", ... } }.
  state="$(python3 -c 'import json,sys; d=json.load(sys.stdin); s=d.get("status") or {}; print((s.get("status") if isinstance(s, dict) else s) or d.get("statusCode") or "")' <<< "$status")"
  case "$state" in
    SUCCESS) echo "ingestion succeeded"; exit 0;;
    FAILED|CANCELED) echo "ingestion task $task ended $state: $status" >&2; exit 1;;
  esac
done
echo "ingestion task $task did not finish within $TIMEOUT seconds" >&2
exit 1
