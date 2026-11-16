#!/bin/sh
# SPDX-License-Identifier: Apache-2.0
# SPDX-FileCopyrightText: 2026 Daniel Gardiner d/b/a FractalSQLabs
#
# fractalsql-ledger-collect: take a verified snapshot of this host's fractalsqld ledger into an audit store.
#
# Every fractalsqld keeps its own ledger, a hash chain in a local file (enterprise_ledger_path) with a
# head file and a CSV mirror beside it. A cluster with a daemon on each host therefore has one chain per
# host. They are not merged; each is verified where it lives and a copy is kept off the host. Run this
# on every daemon host, on a schedule, as the user the daemon runs as (the files are owner-only):
#
#   fractalsql-ledger-collect --dest /mnt/audit-store
#
# What it does:
#   1. asks the daemon to verify the whole chain (fractal_ledger_verify, both chains);
#   2. copies the ledger, its .head and its .csv;
#   3. asks again, and retries if the chain changed while it was copying, so a snapshot is never torn;
#   4. writes MANIFEST.json and SHA256SUMS beside the copy and moves it into
#        <dest>/<host-id>/<UTC time>/
#      (it never overwrites a snapshot, and never writes to the ledger).
#
# A chain that fails verification is still copied: that copy is the evidence. The exit status says so.
#
# usage: fractalsql-ledger-collect --dest DIR [--conf FILE] [--host-id NAME]
#                                  [--socket PATH --key-file PATH --ledger PATH] [--fsqlctl PATH]
#   --dest DIR        the audit store (a directory; mount object storage or a share there)
#   --conf FILE       the daemon's config (default /etc/fractalsql/fractalsqld.conf); the socket, the key
#                     file and the ledger path are read from it
#   --host-id NAME    names this host in the store (default: the hostname)
#   --socket / --key-file / --ledger   give these directly instead of reading the config
#   --fsqlctl PATH    the CLI (default: fsqlctl on PATH)
#
# exit: 0 verified and stored   3 stored, but a chain failed verification   1 error   2 usage
set -eu

CONF=/etc/fractalsql/fractalsqld.conf
DEST=""; HOST_ID=""; SOCKET=""; KEYFILE=""; LEDGER=""; FSQLCTL=fsqlctl

usage() { sed -n '/^# usage:/,/^# exit:/p' "$0" | sed 's/^# \{0,1\}//'; }
die()   { echo "fractalsql-ledger-collect: $*" >&2; exit 1; }

while [ $# -gt 0 ]; do
  case "$1" in
    --dest)      DEST="${2:?--dest needs a directory}"; shift 2;;
    --conf)      CONF="${2:?--conf needs a file}"; shift 2;;
    --host-id)   HOST_ID="${2:?--host-id needs a name}"; shift 2;;
    --socket)    SOCKET="${2:?--socket needs a path}"; shift 2;;
    --key-file)  KEYFILE="${2:?--key-file needs a path}"; shift 2;;
    --ledger)    LEDGER="${2:?--ledger needs a path}"; shift 2;;
    --fsqlctl)   FSQLCTL="${2:?--fsqlctl needs a path}"; shift 2;;
    -h|--help)   usage; exit 0;;
    *) echo "unknown option: $1" >&2; usage >&2; exit 2;;
  esac
done
[ -n "$DEST" ] || { echo "--dest is required" >&2; usage >&2; exit 2; }

# the value of a key in the daemon's config: "key = value", comments after #
conf_value() {
  [ -f "$CONF" ] || return 0
  sed -n "s/^[[:space:]]*$1[[:space:]]*=[[:space:]]*//p" "$CONF" | sed 's/[[:space:]]*#.*$//; s/[[:space:]]*$//' | tail -n 1
}
[ -n "$SOCKET" ]  || SOCKET="$(conf_value socket_path)"
[ -n "$KEYFILE" ] || KEYFILE="$(conf_value hmac_key_file)"
[ -n "$LEDGER" ]  || LEDGER="$(conf_value enterprise_ledger_path)"
[ -n "$SOCKET" ]  || die "no socket: pass --socket or a config with socket_path ($CONF)"
[ -n "$KEYFILE" ] || die "no key file: pass --key-file or a config with hmac_key_file ($CONF)"
[ -n "$LEDGER" ]  || die "no ledger: this daemon has no enterprise_ledger_path (the enterprise tier is not set up here)"
[ -f "$LEDGER" ]  || die "the ledger file does not exist yet: $LEDGER"
command -v "$FSQLCTL" >/dev/null 2>&1 || die "fsqlctl not found (use --fsqlctl)"
[ -n "$HOST_ID" ] || HOST_ID="$(hostname 2>/dev/null || echo unknown-host)"
case "$HOST_ID" in *[!A-Za-z0-9._-]*|"") die "--host-id may contain only letters, digits, . _ -";; esac

if command -v sha256sum >/dev/null 2>&1; then SHA() { sha256sum "$1" | awk '{print $1}'; }
elif command -v shasum >/dev/null 2>&1;  then SHA() { shasum -a 256 "$1" | awk '{print $1}'; }
else die "neither sha256sum nor shasum is available"; fi

ctl() { "$FSQLCTL" -s "$SOCKET" -k "$KEYFILE" "$@"; }
# the daemon's verdict for one chain kind (1 = the QTL chain, 2 = the decision-audit chain)
verify() { ctl call fractal_ledger_verify i:1 "i:$1"; }
rows_of() { printf '%s' "$1" | sed -n 's/.*"rows_verified":\([0-9][0-9]*\).*/\1/p'; }
ok_of()   { case "$1" in *'"ok":true'*) return 0;; *) return 1;; esac; }

mkdir -p "$DEST/$HOST_ID"
TMP="$(mktemp -d "$DEST/$HOST_ID/.collect.XXXXXX")"
trap 'rm -rf "$TMP"' EXIT INT TERM
BASE="$(basename "$LEDGER")"

attempt=0
while :; do
  attempt=$((attempt + 1))
  V1_BEFORE="$(verify 1)" || die "the daemon did not answer a verify call (socket $SOCKET)"
  V2_BEFORE="$(verify 2)" || die "the daemon did not answer a verify call (socket $SOCKET)"
  for f in "$BASE" "$BASE.head" "$BASE.csv"; do
    src="$(dirname "$LEDGER")/$f"
    [ -f "$src" ] || { [ "$f" = "$BASE.csv" ] && continue; die "missing $src"; }
    cp "$src" "$TMP/$f"
  done
  V1_AFTER="$(verify 1)"; V2_AFTER="$(verify 2)"
  if [ "$V1_BEFORE" = "$V1_AFTER" ] && [ "$V2_BEFORE" = "$V2_AFTER" ] && [ "$(rows_of "$V1_BEFORE")" = "$(rows_of "$V1_AFTER")" ] \
     && [ "$(rows_of "$V2_BEFORE")" = "$(rows_of "$V2_AFTER")" ]; then
    break
  fi
  [ "$attempt" -lt 4 ] || die "the chain kept changing while it was copied (4 tries); run it again when the daemon is quieter"
  sleep 1
done

STATUS=0
ok_of "$V1_AFTER" || STATUS=3
ok_of "$V2_AFTER" || STATUS=3

NOW="$(date -u +%Y-%m-%dT%H:%M:%SZ)"; STAMP="$(date -u +%Y%m%dT%H%M%SZ)"
DAEMON_VERSION="$(ctl version 2>/dev/null | head -n 1 || true)"

json_str() { printf '%s' "$1" | sed 's/\\/\\\\/g; s/"/\\"/g'; }
{
  printf '{\n'
  printf '  "format": 1,\n'
  printf '  "host_id": "%s",\n' "$(json_str "$HOST_ID")"
  printf '  "collected_at": "%s",\n' "$NOW"
  printf '  "daemon_version": "%s",\n' "$(json_str "$DAEMON_VERSION")"
  printf '  "ledger_path": "%s",\n' "$(json_str "$LEDGER")"
  printf '  "verified_ok": %s,\n' "$([ "$STATUS" = 0 ] && echo true || echo false)"
  printf '  "verify": {"kind1": %s, "kind2": %s},\n' "$V1_AFTER" "$V2_AFTER"
  printf '  "files": {\n'
  first=1
  for f in "$BASE" "$BASE.head" "$BASE.csv"; do
    [ -f "$TMP/$f" ] || continue
    [ "$first" = 1 ] || printf ',\n'
    first=0
    printf '    "%s": {"sha256": "%s", "bytes": %s}' "$f" "$(SHA "$TMP/$f")" "$(wc -c < "$TMP/$f" | tr -d ' ')"
  done
  printf '\n  }\n}\n'
} > "$TMP/MANIFEST.json"
( cd "$TMP" && for f in "$BASE" "$BASE.head" "$BASE.csv" MANIFEST.json; do [ -f "$f" ] && printf '%s  %s\n' "$(SHA "$f")" "$f"; done > SHA256SUMS )
chmod 0600 "$TMP"/* 2>/dev/null || true

OUT="$DEST/$HOST_ID/$STAMP"
[ ! -e "$OUT" ] || die "a snapshot already exists at $OUT (run again in a second)"
mv "$TMP" "$OUT"
trap - EXIT INT TERM
R1="$(rows_of "$V1_AFTER")"; R2="$(rows_of "$V2_AFTER")"
echo "stored $OUT  (kind1 rows: ${R1:-not verified}, kind2 rows: ${R2:-not verified})"
if [ "$STATUS" != 0 ]; then
  echo "WARNING: the daemon reports a chain that does not verify; the copy is kept as evidence" >&2
  echo "  kind1: $V1_AFTER" >&2
  echo "  kind2: $V2_AFTER" >&2
fi
exit "$STATUS"
