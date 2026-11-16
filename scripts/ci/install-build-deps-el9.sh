#!/bin/sh
# SPDX-License-Identifier: Apache-2.0
# SPDX-FileCopyrightText: 2026 Daniel Gardiner d/b/a FractalSQLabs
#
# Installs what the Linux release build needs on a Rocky Linux 9 image.
#
# The release binaries are built on Rocky 9 (glibc 2.34) rather than on a current Ubuntu runner (glibc 2.39): a binary built against a
# newer glibc will not start on an older distribution, and Rocky 9 gives a floor that covers Ubuntu 22.04, Debian 12 and RHEL 9.
#
# usage: scripts/ci/install-build-deps-el9.sh        (as root, inside the image)
set -eu

MAVEN_VERSION=3.9.9
# The published SHA-512 of apache-maven-$MAVEN_VERSION-bin.tar.gz (https://archive.apache.org/dist/maven/maven-3/$MAVEN_VERSION/binaries/).
MAVEN_SHA512=a555254d6b53d267965a3404ecb14e53c3827c09c3b94b5678835887ab404556bfaf78dcfe03ba76fa2508649dca8531c74bca4d5846513522404d48e8c4ac8b

dnf install -y -q gcc gcc-c++ make openssl-devel java-21-openjdk-devel python3 unzip tar gzip which findutils binutils diffutils rpm-build

# The distribution's Maven is older than the build needs, so a pinned release is installed and checked against its published hash.
if ! command -v mvn >/dev/null 2>&1 || ! mvn -v 2>/dev/null | grep -q "Apache Maven 3\.9"; then
  tmp="$(mktemp -d)"
  curl -fsSL "https://archive.apache.org/dist/maven/maven-3/$MAVEN_VERSION/binaries/apache-maven-$MAVEN_VERSION-bin.tar.gz" -o "$tmp/maven.tar.gz"
  echo "$MAVEN_SHA512  $tmp/maven.tar.gz" | sha512sum -c - >/dev/null
  mkdir -p /opt
  tar -xzf "$tmp/maven.tar.gz" -C /opt
  ln -sf "/opt/apache-maven-$MAVEN_VERSION/bin/mvn" /usr/local/bin/mvn
  rm -rf "$tmp"
fi
java -version 2>&1 | head -1
mvn -v | head -1
