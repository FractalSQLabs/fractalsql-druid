#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
# SPDX-FileCopyrightText: 2026 Daniel Gardiner d/b/a FractalSQLabs
#
# Builds the FractalSQL for Apache Druid release bundle from what is already built:
#
#   druid-extension/target/fractalsql-druid-<version>.jar    (mvn package)
#   service/build/jvm/{fractalsqld.jar,libfsqld_jni.so}     (make -C service jvm)
#   service/build/fsqlctl                                    (make -C service all)
#   mcp/fractalsql-druid-mcp                                 (make -C mcp)
#
# Output (dist/packages/). The file names carry no version, so that
# .../releases/latest/download/<name> always points at the newest release; the version is inside.
#   fractalsql-druid-linux-<arch>.tar.gz      arch is amd64 or arm64
#   fractalsql-druid-<arch>.deb               (Linux, with dpkg-deb or ar)
#   fractalsql-druid-<arch>.rpm               (Linux, when rpmbuild is available)
#   fractalsql-druid-macos-<arch>.zip         (macOS)
# Every package puts the MCP server's two lock files beside its executable, which is where the server looks.
#
# usage: scripts/package.sh [--version X] [--arch amd64|arm64]
set -euo pipefail
cd "$(dirname "$0")/.."
ROOT="$PWD"

VERSION="$(sed -n 's#.*<version>\(.*\)</version>.*#\1#p' druid-extension/pom.xml | head -1)"
case "$(uname -s)" in Linux) OSNAME=linux;; Darwin) OSNAME=darwin;; *) echo "unsupported system $(uname -s)" >&2; exit 2;; esac
case "$(uname -m)" in x86_64) ARCH=amd64;; aarch64|arm64) ARCH=arm64;; *) echo "unsupported machine $(uname -m)" >&2; exit 2;; esac
while [ $# -gt 0 ]; do
  case "$1" in --version) VERSION="$2"; shift;; --arch) ARCH="$2"; shift;; *) echo "unknown option $1" >&2; exit 2;; esac
  shift
done
# The directory name the vendored core drop and the native payloads use for this platform.
case "$OSNAME-$ARCH" in
  linux-amd64) PLAT=linux-x86_64;; linux-arm64) PLAT=linux-aarch64;;
  darwin-amd64) PLAT=darwin-x86_64;; darwin-arm64) PLAT=darwin-arm64;;
  *) echo "unsupported platform $OSNAME-$ARCH" >&2; exit 2;;
esac

JAR="druid-extension/target/fractalsql-druid-$VERSION.jar"
for f in "$JAR" service/build/jvm/fractalsqld.jar service/build/jvm/libfsqld_jni.so service/build/fsqlctl \
         mcp/fractalsql-druid-mcp "include/$PLAT/fractalsql-reasoning-http.so" "include/$PLAT/fractalsql-reasoning-http.so.sig"; do
  [ -f "$f" ] || { echo "missing $f: build it first (make -C service, make -C mcp, mvn -f druid-extension/pom.xml package)" >&2; exit 1; }
done

OUT="$ROOT/dist/packages"; STAGE="$(mktemp -d)"; NAME="fractalsql-druid-$VERSION"
trap 'rm -rf "$STAGE"' EXIT
mkdir -p "$OUT" "$STAGE/$NAME"/{extensions/fractalsql-druid,fractalsqld,bin,mcp,docs,conf}

install -m 0644 "$JAR" "$STAGE/$NAME/extensions/fractalsql-druid/fractalsql-druid.jar"
install -m 0644 service/build/jvm/fractalsqld.jar service/build/jvm/libfsqld_jni.so "$STAGE/$NAME/fractalsqld/"
install -m 0644 "include/$PLAT/fractalsql-reasoning-http.so" "include/$PLAT/fractalsql-reasoning-http.so.sig" "$STAGE/$NAME/fractalsqld/"
# The enterprise library is licensed and never vendored here. It goes into a bundle only when it was dropped beside the community
# core, and only with its signature: the daemon will not load an unsigned library.
ENT="include/$PLAT/libfractalsql-enterprise-sovereign-c.so"
if [ -f "$ENT" ]; then
  [ -f "$ENT.sig" ] || { echo "$ENT has no .sig beside it" >&2; exit 1; }
  mkdir -p "$STAGE/$NAME/fractalsqld/enterprise"
  install -m 0644 "$ENT" "$ENT.sig" "$STAGE/$NAME/fractalsqld/enterprise/"
fi
install -m 0755 packaging/common/fractalsqld.sh "$STAGE/$NAME/bin/fractalsqld"
install -m 0755 scripts/install.sh "$STAGE/$NAME/install.sh"
install -m 0755 service/build/fsqlctl "$STAGE/$NAME/bin/fsqlctl"
install -m 0755 mcp/fractalsql-druid-mcp "$STAGE/$NAME/bin/fractalsql-druid-mcp"
install -m 0755 scripts/ledger-collect.sh "$STAGE/$NAME/bin/fractalsql-ledger-collect"
install -m 0755 scripts/ledger-check.py "$STAGE/$NAME/bin/fractalsql-ledger-check"
install -m 0644 mcp/.mcp-schema-lock mcp/.mcp-safety-annotations-lock "$STAGE/$NAME/bin/"
install -m 0644 mcp/manifest.json mcp/README.md mcp/RUN.txt "$STAGE/$NAME/mcp/"
install -m 0640 packaging/common/fractalsqld.conf.example "$STAGE/$NAME/conf/"
install -m 0644 packaging/common/fractalsqld.service "$STAGE/$NAME/conf/"
install -m 0644 docs/*.md "$STAGE/$NAME/docs/"
install -m 0644 LICENSE README.md THIRD-PARTY-NOTICES.md "$STAGE/$NAME/"

if [ "$OSNAME" = darwin ]; then
  command -v zip >/dev/null 2>&1 || { echo "zip is required to build the macOS archive" >&2; exit 1; }
  rm -f "$OUT/fractalsql-druid-macos-$ARCH.zip"
  ( cd "$STAGE" && zip -qr "$OUT/fractalsql-druid-macos-$ARCH.zip" "$NAME" )
  echo "wrote $OUT/fractalsql-druid-macos-$ARCH.zip"
else
  tar -C "$STAGE" -czf "$OUT/fractalsql-druid-linux-$ARCH.tar.gz" "$NAME"
  echo "wrote $OUT/fractalsql-druid-linux-$ARCH.tar.gz"
fi

# A .deb is an ar archive of debian-binary, control.tar.gz and data.tar.gz. dpkg-deb is used when it is there; the release builds
# on a Red Hat style image (an old glibc, so the binaries run on older distributions), which has no dpkg, so ar and tar do the same.
build_deb() {   # build_deb <staged-root> <output.deb>
  if command -v dpkg-deb >/dev/null 2>&1; then
    dpkg-deb --root-owner-group -b "$1" "$2" >/dev/null
    return
  fi
  command -v ar >/dev/null 2>&1 || { echo "neither dpkg-deb nor ar is available: cannot build the .deb" >&2; return 1; }
  local w; w="$(mktemp -d)"
  printf '2.0\n' > "$w/debian-binary"
  tar --owner=0 --group=0 --numeric-owner -C "$1/DEBIAN" -czf "$w/control.tar.gz" .
  tar --owner=0 --group=0 --numeric-owner --exclude=./DEBIAN -C "$1" -czf "$w/data.tar.gz" .
  rm -f "$2"
  ( cd "$w" && ar rc "$2" debian-binary control.tar.gz data.tar.gz )
  rm -rf "$w"
}

if [ "$OSNAME" = linux ] && { command -v dpkg-deb >/dev/null 2>&1 || command -v ar >/dev/null 2>&1; }; then
  D="$STAGE/deb"; L="$D/usr/lib/fractalsql-druid"
  mkdir -p "$D/DEBIAN" "$L" "$D/usr/bin" "$D/etc/fractalsql" "$D/lib/systemd/system" "$D/usr/share/doc/fractalsql-druid"
  cp -r "$STAGE/$NAME/extensions" "$STAGE/$NAME/fractalsqld" "$STAGE/$NAME/mcp" "$L/"
  install -m 0755 "$STAGE/$NAME/bin/fractalsqld" "$STAGE/$NAME/bin/fsqlctl" "$STAGE/$NAME/bin/fractalsql-druid-mcp" "$D/usr/bin/"
  install -m 0755 "$STAGE/$NAME/bin/fractalsql-ledger-collect" "$STAGE/$NAME/bin/fractalsql-ledger-check" "$D/usr/bin/"
  install -m 0644 "$STAGE/$NAME/bin/.mcp-schema-lock" "$STAGE/$NAME/bin/.mcp-safety-annotations-lock" "$D/usr/bin/"
  install -m 0640 packaging/common/fractalsqld.conf.example "$D/etc/fractalsql/fractalsqld.conf"
  install -m 0644 packaging/common/fractalsqld.service "$D/lib/systemd/system/"
  cp "$STAGE/$NAME/docs/"*.md "$D/usr/share/doc/fractalsql-druid/"
  install -Dm0644 mcp/RUN.txt "$D/usr/share/doc/fractalsql-druid/mcp/RUN.txt"
  install -m 0644 LICENSE "$D/usr/share/doc/fractalsql-druid/copyright"
  install -m 0644 THIRD-PARTY-NOTICES.md "$D/usr/share/doc/fractalsql-druid/"
  # md5sums and Installed-Size are what dpkg and apt tooling expect to find in a package
  ( cd "$D" && find . -type f -not -path './DEBIAN/*' -printf '%P\0' | sort -z | xargs -0 md5sum > DEBIAN/md5sums )
  ISIZE="$(du -sk --exclude=DEBIAN "$D" | cut -f1)"
  sed "s/@VERSION@/$VERSION/; s/@ARCH@/$ARCH/; /^Architecture:/a Installed-Size: $ISIZE" packaging/debian/control > "$D/DEBIAN/control"
  install -m 0755 packaging/debian/postinst "$D/DEBIAN/postinst"
  install -m 0755 packaging/debian/prerm "$D/DEBIAN/prerm"
  echo "/etc/fractalsql/fractalsqld.conf" > "$D/DEBIAN/conffiles"
  build_deb "$D" "$OUT/fractalsql-druid-${ARCH}.deb"
  echo "wrote $OUT/fractalsql-druid-${ARCH}.deb"
fi

# The RPM is built from the same staged bundle: packaging/rpm/fractalsql-druid.spec unpacks it from SOURCES/stage.
if [ "$OSNAME" = linux ] && command -v rpmbuild >/dev/null 2>&1; then
  R="$(mktemp -d)"
  mkdir -p "$R"/SOURCES "$R"/SPECS "$R"/BUILD "$R"/RPMS "$R"/SRPMS "$R"/BUILDROOT
  cp -R "$STAGE/$NAME" "$R/SOURCES/stage"
  rpmbuild -bb --define "_topdir $R" --define "pkg_version $VERSION" packaging/rpm/fractalsql-druid.spec >/dev/null
  for f in "$R"/RPMS/*/*.rpm; do cp "$f" "$OUT/fractalsql-druid-${ARCH}.rpm"; echo "wrote $OUT/fractalsql-druid-${ARCH}.rpm"; done
  rm -rf "$R"
fi
