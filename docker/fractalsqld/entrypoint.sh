#!/bin/sh
# SPDX-License-Identifier: Apache-2.0
# SPDX-FileCopyrightText: 2026 Daniel Gardiner d/b/a FractalSQLabs
#
# Writes the daemon's config and the shared HMAC key from the environment, then
# starts fractalsqld. Every daemon setting can be given as FSQLD_<KEY>, for
# example FSQLD_REASONING_URL for reasoning_url.
set -eu
: "${FSQL_HMAC_KEY:?set FSQL_HMAC_KEY (hex, for example: openssl rand -hex 32)}"
RUN_DIR="${FSQLD_RUN_DIR:-/run/fractalsql}"
umask 077
mkdir -p "$RUN_DIR"
rm -f "$RUN_DIR/fractalsqld.sock"
printf '%s\n' "$FSQL_HMAC_KEY" > "$RUN_DIR/hmac.key"
chmod 0640 "$RUN_DIR/hmac.key"
CONF="$RUN_DIR/fractalsqld.conf"
{
  echo "socket_path = $RUN_DIR/fractalsqld.sock"
  echo "hmac_key_file = $RUN_DIR/hmac.key"
  echo "allowed_uids = ${FSQLD_ALLOWED_UIDS:-$(id -u)}"
  echo "max_connections = ${FSQLD_MAX_CONNECTIONS:-64}"
  echo "idle_timeout_secs = ${FSQLD_IDLE_TIMEOUT_SECS:-300}"
  if [ -n "${FSQLD_REASONING_URL:-}${FSQLD_EMBED_URL:-}" ]; then
    echo "reasoning_plugin = ${FSQLD_REASONING_PLUGIN:-/opt/fractalsql/fractalsql-reasoning-http.so}"
  fi
  if [ -f /opt/fractalsql/enterprise/libfractalsql-enterprise-sovereign-c.so ]; then
    echo "enterprise_lib = ${FSQLD_ENTERPRISE_LIB:-/opt/fractalsql/enterprise/libfractalsql-enterprise-sovereign-c.so}"
    echo "enterprise_ledger_path = ${FSQLD_ENTERPRISE_LEDGER_PATH:-/var/lib/fractalsql/fractalsql_ledger.dat}"
  fi
  for key in reasoning_url reasoning_token reasoning_model reasoning_allow_plaintext \
             embed_url embed_model think think_provider think_native_url think_num_ctx \
             t2s_max_attempts t2s_allowed_statements t2s_use_review \
             enterprise_ledger_key enterprise_require_signature; do
    var="FSQLD_$(echo "$key" | tr 'a-z' 'A-Z')"
    eval "val=\${$var:-}"
    if [ -n "$val" ]; then echo "$key = $val"; fi
  done
} > "$CONF"
exec java --enable-native-access=ALL-UNNAMED -Dfsqld.native=/opt/fractalsql/libfsqld_jni.so -jar /opt/fractalsql/fractalsqld.jar -c "$CONF"
