#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
# SPDX-FileCopyrightText: 2026 Daniel Gardiner d/b/a FractalSQLabs
#
# Installs FractalSQL for Apache Druid from an unpacked release bundle on Linux or macOS.
#
#   tar -xzf fractalsql-druid-<version>-<os>-<arch>.tar.gz
#   cd fractalsql-druid-<version>
#   ./install.sh --druid-home /opt/druid
#
# What it does:
#   * copies the extension JAR to <druid-home>/extensions/fractalsql-druid/ (when --druid-home is given)
#   * installs the daemon (fractalsqld), its CLI (fsqlctl) and the MCP server under <prefix>
#   * writes <conf>/fractalsqld.conf and a random <conf>/hmac.key, unless they already exist
#   * prints the Druid runtime properties to add, and how to start the daemon
#
# It does not edit your Druid configuration and it does not start anything.
#
# usage: install.sh [--druid-home DIR] [--prefix DIR] [--conf DIR] [--no-daemon] [--dry-run]
#   --druid-home DIR   a Druid installation to put the extension in
#   --prefix DIR       where the daemon and tools go (default /usr/local): bin/, lib/fractalsql-druid/
#   --conf DIR         daemon configuration directory (default <prefix>/etc/fractalsql)
#   --no-daemon        install the extension only
#   --dry-run          print what would be done and change nothing

set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
DRUID_HOME=""
PREFIX="/usr/local"
CONF=""
DAEMON=1
DRY=0

while [ $# -gt 0 ]; do
  case "$1" in
    --druid-home) DRUID_HOME="$2"; shift 2;;
    --prefix)     PREFIX="$2"; shift 2;;
    --conf)       CONF="$2"; shift 2;;
    --no-daemon)  DAEMON=0; shift;;
    --dry-run)    DRY=1; shift;;
    -h|--help)    sed -n 2,23p "$0" | sed 's/^# \{0,1\}//'; exit 0;;
    *) echo "unknown option: $1" >&2; exit 2;;
  esac
done
[ -n "$CONF" ] || CONF="$PREFIX/etc/fractalsql"

[ -f "$HERE/extensions/fractalsql-druid/fractalsql-druid.jar" ] || { echo "run this from the unpacked release bundle: extensions/fractalsql-druid/fractalsql-druid.jar not found" >&2; exit 1; }
[ -z "$DRUID_HOME" ] || [ -d "$DRUID_HOME/extensions" ] || { echo "not a Druid installation (no extensions/ directory): $DRUID_HOME" >&2; exit 1; }
[ "$DAEMON" = 0 ] || command -v java >/dev/null 2>&1 || echo "warning: no java on PATH; the daemon needs a Java 17 or newer runtime" >&2

case "$(uname -s)" in
  Darwin) SOCKET="$PREFIX/var/run/fractalsql/fractalsqld.sock";;
  *)      SOCKET="/run/fractalsql/fractalsqld.sock";;
esac

run() { if [ "$DRY" = 1 ]; then echo "+ $*"; else "$@"; fi; }

if [ -n "$DRUID_HOME" ]; then
  echo "== extension: $DRUID_HOME/extensions/fractalsql-druid"
  run mkdir -p "$DRUID_HOME/extensions/fractalsql-druid"
  run install -m 0644 "$HERE/extensions/fractalsql-druid/fractalsql-druid.jar" "$DRUID_HOME/extensions/fractalsql-druid/fractalsql-druid.jar"
fi

if [ "$DAEMON" = 1 ]; then
  echo "== daemon and tools: $PREFIX"
  run mkdir -p "$PREFIX/bin" "$PREFIX/lib/fractalsql-druid" "$CONF"
  run cp -R "$HERE/fractalsqld" "$HERE/mcp" "$PREFIX/lib/fractalsql-druid/"
  run install -m 0755 "$HERE/bin/fractalsqld" "$HERE/bin/fsqlctl" "$HERE/bin/fractalsql-druid-mcp" "$PREFIX/bin/"
  run install -m 0755 "$HERE/bin/fractalsql-ledger-collect" "$HERE/bin/fractalsql-ledger-check" "$PREFIX/bin/"
  # the MCP server looks for its lock files beside its executable
  run install -m 0644 "$HERE/bin/.mcp-schema-lock" "$HERE/bin/.mcp-safety-annotations-lock" "$PREFIX/bin/"

  if [ -f "$CONF/fractalsqld.conf" ]; then
    echo "== keeping the existing $CONF/fractalsqld.conf"
  else
    echo "== writing $CONF/fractalsqld.conf"
    if [ "$DRY" = 1 ]; then echo "+ write $CONF/fractalsqld.conf (socket $SOCKET, key $CONF/hmac.key)"; else
      sed -e "s#^socket_path *=.*#socket_path   = $SOCKET#" \
          -e "s#^hmac_key_file *=.*#hmac_key_file = $CONF/hmac.key#" \
          -e "s#^allowed_uids *=.*#allowed_uids  = $(id -u)#" \
          "$HERE/conf/fractalsqld.conf.example" > "$CONF/fractalsqld.conf"
      chmod 0640 "$CONF/fractalsqld.conf"
    fi
  fi
  if [ -f "$CONF/hmac.key" ]; then
    echo "== keeping the existing $CONF/hmac.key"
  else
    echo "== generating $CONF/hmac.key"
    if [ "$DRY" = 1 ]; then echo "+ write a random 32-byte hex key to $CONF/hmac.key"; else
      ( umask 027; od -An -N32 -tx1 /dev/urandom | tr -d ' \n' > "$CONF/hmac.key" )
    fi
  fi
fi

cat <<EOF

Done. Next:

1. Load the extension: add "fractalsql-druid" to druid.extensions.loadList in your Druid
   common.runtime.properties, and restart the Druid services that should serve the functions
   (broker, historical).
EOF
if [ "$DAEMON" = 1 ]; then
cat <<EOF

2. Tell the extension how to reach the daemon (reasoning, embedding and the enterprise tier):

     druid.fractalsql.daemon_socket=$SOCKET
     druid.fractalsql.daemon_hmac_key_file=$CONF/hmac.key

   Run the daemon on each host whose Druid processes call it (the brokers). Those processes
   must be able to read the key file and reach the socket; it is a Unix socket, so the daemon
   and the Druid process share a host.

3. Configure the model provider in $CONF/fractalsqld.conf, then start the daemon:

     $PREFIX/bin/fractalsqld -c $CONF/fractalsqld.conf

   On Linux, conf/fractalsqld.service in the bundle is a ready systemd unit.

4. Check it: curl http://<broker>:8082/fractalsql/health
EOF
fi
