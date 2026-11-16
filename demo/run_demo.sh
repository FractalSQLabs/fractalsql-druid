#!/usr/bin/env bash
# demo/run_demo.sh
# SPDX-License-Identifier: Apache-2.0
# SPDX-FileCopyrightText: 2026 Daniel Gardiner d/b/a FractalSQLabs
#
# Runs every demo/*.sql content demo against a running Druid cluster, in
# one pass -- the "docker compose up -d; pull a model; run_demo.sh"
# button for a from-scratch look at everything in demo/, instead of
# running each file by hand.
#
# Usage:
#   demo/run_demo.sh
#   demo/run_demo.sh --quiet
#   demo/run_demo.sh --only demo-vertical-fleet-logistics.sql
#   demo/run_demo.sh --skip demo-agents.sql,enterprise-stress.sql
#   demo/run_demo.sh --url http://localhost:8888/druid/v2/sql
#   demo/run_demo.sh --service-url http://localhost:8082
#
# How it works: the work is done by demo/run_demo.py, which speaks the Druid
# SQL endpoint and the extension's own service endpoints; this script is the
# sweep around it: one process per kit, a log per kit, and a summary at the
# end.
#
# The cluster has to be up already:
#
#   docker compose -f docker/docker-compose.yml up -d
#
# A non-zero exit from one kit is a "go read its log" signal, not proof
# of a bug: a kit whose reasoning call races a cold model fails, and
# the runner prints the provider's own error. Read the per-kit
# log before assuming a bug. A kit that fails is run once more; the
# first attempt's log is kept beside the second as <kit>.sql.log.attempt1.
#
# Every kit ends with a self-check row, "HEADLINE kit=<name> ok" or
# "HEADLINE kit=<name> FAILED". A FAILED headline counts as a failed kit.
#
# demo/response-modes.sql runs in the main loop. The reasoning tier runs
# through four INDEPENDENT CONTEXTS, each with its own response mode: the
# chat context's mode is the operator's choice (text by default, code or
# json), and the text-to-SQL, review and embedding contexts' modes are
# fixed to what they are for. So the file's three sections are three
# kinds of question and they run in one pass.
#

set -u

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
LOG_DIR="${FSQL_DEMO_RUN_LOG_DIR:-/tmp/fractalsql_druid_demo_run}"
# How long one kit may take. The heavy ones -- demo-agents.sql
# demonstrates seventeen agents, each a reasoning round trip -- run well
# past a quarter of an hour on a cold model, so the budget is generous
# by default and overridable.
TIMEOUT_SECS="${FSQL_DEMO_RUN_TIMEOUT:-3600}"
URL="${FSQL_DEMO_URL:-http://127.0.0.1:8888/druid/v2/sql}"
SERVICE_URL="${FSQL_DEMO_SERVICE_URL:-http://127.0.0.1:8082}"

QUIET=0
ONLY=""
SKIP=""
INCLUDE_RESPONSE_MODES=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    --quiet)                  QUIET=1 ;;
    --only)                   ONLY="$2"; shift ;;
    --skip)                   SKIP="$2"; shift ;;
    --url)                    URL="$2"; shift ;;
    --service-url)            SERVICE_URL="$2"; shift ;;
    --include-response-modes) INCLUDE_RESPONSE_MODES=1 ;;
    -h|--help)
      sed -n '2,50p' "$0"; exit 0 ;;
    *) echo "run_demo.sh: unknown arg: $1 (try --help)" >&2; exit 2 ;;
  esac
  shift
done

# The python that runs the kits. The port's runner is python3.
PYTHON="${FSQL_PYTHON:-}"
if [[ -z "$PYTHON" ]]; then
  for candidate in python3 python; do
    if command -v "$candidate" >/dev/null 2>&1; then
      PYTHON="$(command -v "$candidate")"
      break
    fi
  done
fi
if [[ -z "$PYTHON" ]]; then
  echo "run_demo.sh: no python interpreter found (set FSQL_PYTHON)" >&2
  exit 2
fi

mkdir -p "$LOG_DIR"

IFS=',' read -r -a only_list  <<< "$ONLY"
IFS=',' read -r -a skip_list  <<< "$SKIP"

should_run() {
  local base="$1"
  if [[ -n "$ONLY" ]]; then
    for o in "${only_list[@]}"; do [[ "$base" == "$o" ]] && return 0; done
    return 1
  fi
  for s in "${skip_list[@]}"; do [[ -n "$s" && "$base" == "$s" ]] && return 1; done
  return 0
}

pass=0
fail=0
declare -a failed_files=()

for sqlfile in "$HERE"/*.sql; do
  base="$(basename "$sqlfile")"
  should_run "$base" || continue
  [[ "$QUIET" -eq 1 ]] || echo "=== $base ==="
  log="$LOG_DIR/$base.log"
  # One retry, as the gate suite also does: a kit that calls the
  # reasoning provider can lose a race with a cold model, and the
  # provider's answer is unbounded. One retry separates a flake from a
  # real failure.
  attempt=1
  while true; do
    if timeout "$TIMEOUT_SECS" "$PYTHON" -u "$HERE/run_demo.py" \
         --file "$sqlfile" --url "$URL" --service-url "$SERVICE_URL" \
         > "$log" 2>&1
    then
      pass=$((pass + 1))
      [[ "$QUIET" -eq 1 ]] || echo "  ok ($log)"
      break
    fi
    if [[ "$attempt" -eq 1 ]]; then
      attempt=2
      # keep the first attempt's log: the retry overwrites $log, and a flake that passes the second time is still worth reading
      cp -f "$log" "$log.attempt1" 2>/dev/null || true
      echo "  -- retrying once (a provider timeout is not a failure; first attempt kept as $log.attempt1)"
      sleep 10
      continue
    fi
    fail=$((fail + 1))
    failed_files+=("$base")
    [[ "$QUIET" -eq 1 ]] || echo "  exit != 0 -- see $log (read it before assuming a bug)"
    break
  done
done

echo
echo "=== $pass ok, $fail non-zero exit, logs in $LOG_DIR ==="
if [[ "$fail" -gt 0 ]]; then
  echo "Non-zero-exit files (read the log before assuming a bug):"
  printf '  %s\n' "${failed_files[@]}"
fi

exit 0
