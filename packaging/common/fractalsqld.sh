#!/bin/sh
# Starts fractalsqld on the JVM. Usage: fractalsqld -c /etc/fractalsql/fractalsqld.conf
SELF="$0"
while [ -h "$SELF" ]; do   # resolve symlinks without readlink -f, which older macOS lacks
  D="$(cd "$(dirname "$SELF")" && pwd)"; SELF="$(readlink "$SELF")"
  case "$SELF" in /*) ;; *) SELF="$D/$SELF";; esac
done
HERE="$(cd "$(dirname "$SELF")" && pwd)"
LIB="${FRACTALSQL_HOME:-$HERE/../lib/fractalsql-druid}/fractalsqld"
[ -d "$LIB" ] || LIB="$HERE/../fractalsqld"
exec java --enable-native-access=ALL-UNNAMED -Dfsqld.native="$LIB/libfsqld_jni.so" -jar "$LIB/fractalsqld.jar" "$@"
