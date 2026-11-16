#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
# SPDX-FileCopyrightText: 2026 Daniel Gardiner d/b/a FractalSQLabs
#
# Checks an installed fractalsql-druid package (the .deb or the .rpm), run as root: the files are where
# they should be, the MCP server starts, and fractalsqld starts from the installed files and answers.
set -euxo pipefail

test -f /usr/lib/fractalsql-druid/extensions/fractalsql-druid/fractalsql-druid.jar
test -f /usr/lib/fractalsql-druid/fractalsqld/fractalsqld.jar
test -f /usr/lib/fractalsql-druid/fractalsqld/libfsqld_jni.so
test -x /usr/bin/fractalsqld && test -x /usr/bin/fsqlctl
test -x /usr/bin/fractalsql-ledger-collect && test -x /usr/bin/fractalsql-ledger-check

# the version the package manager recorded is the version the MCP server and the daemon report
PKGV="$(dpkg-query -W -f='${Version}' fractalsql-druid 2>/dev/null || rpm -q --qf '%{VERSION}' fractalsql-druid)"
test -n "$PKGV"

# the reasoning plugin ships with its detached signature (64 raw bytes); the daemon refuses an unsigned plugin
test "$(wc -c < /usr/lib/fractalsql-druid/fractalsqld/fractalsql-reasoning-http.so.sig)" -eq 64

# the MCP server: it lists its tools and, with its lock files beside it, starts
test "$(fractalsql-druid-mcp --version)" = "$PKGV"
# the MCP server publishes the tool table the packaged manifest records: the two
# must agree, and neither is written down here (the tool table grows with the
# releases).
MANIFEST_TOOLS="$(grep -c '^      "name":' /usr/lib/fractalsql-druid/mcp/manifest.json)"
test "$(fractalsql-druid-mcp --list-tools | wc -l)" -eq "$MANIFEST_TOOLS"
test -f /usr/bin/.mcp-schema-lock && test -f /usr/bin/.mcp-safety-annotations-lock
test -f /usr/lib/fractalsql-druid/mcp/RUN.txt && test -f /usr/lib/fractalsql-druid/mcp/README.md
test -f /usr/share/doc/fractalsql-druid/getting-started.md && test -f /usr/share/doc/fractalsql-druid/THIRD-PARTY-NOTICES.md
out="$(echo '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2024-11-05","capabilities":{},"clientInfo":{"name":"ci","version":"0"}}}' \
  | DRUID_URL=http://127.0.0.1:1 fractalsql-druid-mcp 2>&1 || true)"
echo "$out" | grep -q schema_lock_ok

# the post-install step created the service user, the key and the config with the right modes
getent passwd fractalsql
test "$(stat -c %a /etc/fractalsql/fractalsqld.conf)" = 640
test "$(stat -c %a /etc/fractalsql/hmac.key)" = 640

# the service starts from the installed files and answers a ping
install -d -o fractalsql -g fractalsql /run/fractalsql
printf 'socket_path = /run/fractalsql/fractalsqld.sock\nhmac_key_file = /etc/fractalsql/hmac.key\nallowed_uids = %s\n' "$(id -u fractalsql)" > /etc/fractalsql/fractalsqld.conf
chown root:fractalsql /etc/fractalsql/fractalsqld.conf
runuser -u fractalsql -- fractalsqld -c /etc/fractalsql/fractalsqld.conf >/tmp/fsqld.log 2>&1 &
for _ in $(seq 1 50); do [ -S /run/fractalsql/fractalsqld.sock ] && break; sleep 0.3; done
runuser -u fractalsql -- fsqlctl -s /run/fractalsql/fractalsqld.sock -k /etc/fractalsql/hmac.key ping
DV="$(runuser -u fractalsql -- fsqlctl -s /run/fractalsql/fractalsqld.sock -k /etc/fractalsql/hmac.key call fractal_version)"
echo "daemon reports: $DV"
echo "$DV" | grep -q "$PKGV"
echo "ok: the installed package works"
