#!/bin/sh
# Prove that the ledger's head file makes a TRUNCATED chain visible.
#
# The chain is append-only and hash-linked, so a rewritten or removed
# record in the middle breaks the linkage and fractal_ledger_verify
# finds it. But the chain CANNOT show that records were removed from
# its very end: there is nothing after the last record to notice its
# absence. The head file is what closes that gap -- it lives OUTSIDE
# the chain, carries its own MAC, and still says how many records
# there were.
#
# This probe:
#   1. copies the chain aside (inside the node),
#   2. truncates its tail,
#   3. asks fractal_ledger_verify for a verdict,
#   4. restores the chain from the copy.
#
# Usage: truncate-chain-probe.sh <container> <ledger-path-in-container>

set -eu

CONTAINER="${1:-fractalsql-druid-broker}"
LEDGER="${2:-/opt/druid/var/fractalsql/fractalsql_ledger.dat}"

sql() {
    curl -s -m 60 -X POST -H 'Content-Type: application/json' \
        -d "{\"query\":\"$1\",\"resultFormat\":\"object\"}" \
        http://localhost:8888/druid/v2/sql
}

restore() {
    docker exec "$CONTAINER" sh -c "if [ -f '$LEDGER.probe-backup' ]; then mv -f '$LEDGER.probe-backup' '$LEDGER'; fi" >/dev/null 2>&1 || true
}
trap restore EXIT

echo "== before =="
echo "  head:   $(docker exec "$CONTAINER" cat "$LEDGER.head" 2>&1 || echo '(none)')"
echo "  bytes:  $(docker exec "$CONTAINER" sh -c "wc -c < '$LEDGER'" 2>&1 || echo 0)"
echo "  verify: $(sql 'SELECT FRACTAL_LEDGER_VERIFY()')"

echo
echo "== truncating the tail =="
docker exec "$CONTAINER" cp -f "$LEDGER" "$LEDGER.probe-backup"
# Keep the first half of the file. The chain's own linkage is intact in
# what is left -- every surviving record still links to its
# predecessor -- so the ONLY evidence of the truncation is the head.
SIZE=$(docker exec "$CONTAINER" sh -c "wc -c < '$LEDGER'" | tr -d " ")
KEEP=$((SIZE / 2))
docker exec "$CONTAINER" sh -c "head -c $KEEP '$LEDGER' > '$LEDGER.probe-trunc' && mv -f '$LEDGER.probe-trunc' '$LEDGER'"
echo "  kept:   $KEEP of $SIZE bytes"

echo
echo "== after =="
echo "  head:   $(docker exec "$CONTAINER" cat "$LEDGER.head" 2>&1 || echo '(none)')"
echo "  bytes:  $(docker exec "$CONTAINER" sh -c "wc -c < '$LEDGER'" 2>&1 || echo 0)"
echo "  verify: $(sql 'SELECT FRACTAL_LEDGER_VERIFY()')"

echo
echo "== restoring =="
restore
echo "  verify: $(sql 'SELECT FRACTAL_LEDGER_VERIFY()')"
