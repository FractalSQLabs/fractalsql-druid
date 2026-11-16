#!/bin/bash
# SPDX-License-Identifier: Apache-2.0
# SPDX-FileCopyrightText: 2026 Daniel Gardiner d/b/a FractalSQLabs
#
# scripts/easy_install.sh
#
# The "easy button" for FractalSQL on Apache Druid. One command takes a Linux or macOS machine to an
# installed extension JAR, the fractalsqld service, the fsqlctl CLI and the MCP server.
#
# Usage (fresh machine):
#   curl -fsSL https://github.com/FractalSQLabs/fractalsql-druid/releases/latest/download/easy_install.sh | bash
#
# Usage (a Druid you want the extension copied into, or a package you already downloaded):
#   ./scripts/easy_install.sh --druid-home /opt/druid
#   ./scripts/easy_install.sh --from-file ./fractalsql-druid-amd64.deb
#
# Flags (all optional; anything you omit is asked, or defaulted with --yes):
#   --version <X.Y.Z>     release to install (default: this script's own)
#   --from-file <path>    install this .deb / .rpm / .tar.gz / .zip instead of downloading
#   --druid-home <dir>    also copy the extension JAR into this Druid installation's extensions/
#   --yes                 pre-confirm every prompt (needed for CI and other non-tty runs)
#   --dry-run             print what would happen, change nothing
#   --uninstall           remove what this script installed
#   -h, --help
#
# What it does:
#   - Linux: installs the .deb or .rpm for your architecture with apt or dnf. That puts the extension,
#     fractalsqld (with a systemd unit), fsqlctl and the MCP server under /usr, writes
#     /etc/fractalsql/fractalsqld.conf and generates /etc/fractalsql/hmac.key. On a system with neither
#     apt nor dnf it unpacks the release tarball and runs the bundle's install.sh into /usr/local.
#   - macOS: unpacks the release zip and runs the bundle's install.sh into /usr/local, then clears the
#     Gatekeeper quarantine flag on what it installed.
#   - With --druid-home it copies the extension JAR into <druid-home>/extensions/fractalsql-druid.
#   - Never edits your Druid configuration and never starts or restarts anything. It prints the
#     runtime properties to add and the command that starts the daemon.
#
# No telemetry. This script never reports anything anywhere.

set -euo pipefail

FSQL_VERSION="@@FSQL_VERSION@@"
if [[ "${FSQL_VERSION}" == "@@FSQL_VERSION@@" ]]; then
    HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    if [[ -f "${HERE}/../druid-extension/pom.xml" ]]; then
        FSQL_VERSION="$(sed -n 's#.*<version>\(.*\)</version>.*#\1#p' "${HERE}/../druid-extension/pom.xml" | head -1)"
    else
        FSQL_VERSION="latest"
    fi
fi

REPO="FractalSQLabs/fractalsql-druid"
PREFIX_LOCAL="/usr/local"

if [[ -t 1 ]]; then G="\033[32m"; R="\033[31m"; Y="\033[33m"; B="\033[1m"; Z="\033[0m"; else G=""; R=""; Y=""; B=""; Z=""; fi
log()  { printf "${B}==>${Z} %s\n" "$1"; }
ok()   { printf "  ${G}✓${Z} %s\n" "$1"; }
warn() { printf "  ${Y}!${Z} %s\n" "$1" >&2; }
err()  { printf "  ${R}✗${Z} %s\n" "$1" >&2; }
die()  { err "$1"; exit 1; }

# Every download is a release asset fetched over the network; pin curl to https.
fetch() {
    curl -fsSL --proto '=https' "$@" || return $?
    # Release assets are verified against the release's SHA256SUMS before anything installs them.
    # Set FSQL_ALLOW_UNVERIFIED=1 only for a release that predates SHA256SUMS.
    local url="" out="" prev="" a
    for a in "$@"; do
        [[ "$prev" == "-o" ]] && out="$a"
        [[ "$a" == https://* ]] && url="$a"
        prev="$a"
    done
    [[ -n "$url" && -n "$out" && "$url" == */releases/download/* && "${url##*/}" != "SHA256SUMS" ]] || return 0
    local sums="${out}.SHA256SUMS.check" want got
    if ! curl -fsSL --proto '=https' "${url%/*}/SHA256SUMS" -o "$sums" 2>/dev/null; then
        rm -f "$sums"
        if [[ "${FSQL_ALLOW_UNVERIFIED:-0}" == "1" ]]; then echo "WARNING: no SHA256SUMS for this release; installing unverified (FSQL_ALLOW_UNVERIFIED=1)" >&2; return 0; fi
        echo "ERROR: ${url%/*}/SHA256SUMS could not be fetched; refusing to install an unverified download (set FSQL_ALLOW_UNVERIFIED=1 to override)" >&2
        rm -f "$out"; return 1
    fi
    want="$(awk -v f="${url##*/}" '{n=$2; sub(/^\*/,"",n); if (n==f) {print $1; exit}}' "$sums")"
    rm -f "$sums"
    got="$(sha256sum "$out" 2>/dev/null | awk '{print $1}')"; [[ -n "$got" ]] || got="$(shasum -a 256 "$out" | awk '{print $1}')"
    if [[ -z "$want" || "$want" != "$got" ]]; then
        echo "ERROR: checksum mismatch or missing entry for ${url##*/} (expected '${want:-none}', got '$got'); removing the download" >&2
        rm -f "$out"; return 1
    fi
}

YES=0; DRY_RUN=0; UNINSTALL=0
FROM_FILE=""; DRUID_HOME=""

usage() { sed -n '5,/^set -euo/p' "$0" | sed '$d' | sed 's/^# \{0,1\}//'; }

while [[ $# -gt 0 ]]; do
    case "$1" in
        --version)    FSQL_VERSION="${2:?--version needs a value}"; shift ;;
        --from-file)  FROM_FILE="${2:?--from-file needs a path}"; shift ;;
        --druid-home) DRUID_HOME="${2:?--druid-home needs a directory}"; shift ;;
        --yes|-y)     YES=1 ;;
        --dry-run)    DRY_RUN=1 ;;
        --uninstall)  UNINSTALL=1 ;;
        -h|--help)    usage; exit 0 ;;
        *)            die "unknown argument '$1' (try --help)" ;;
    esac
    shift
done

[[ "${FSQL_VERSION}" == "latest" || "${FSQL_VERSION}" =~ ^[0-9]+\.[0-9]+\.[0-9]+([-.][A-Za-z0-9.]+)?$ ]] \
    || die "--version '${FSQL_VERSION}' is not a version number"
[[ -z "${DRUID_HOME}" || "${DRUID_HOME}" =~ ^[A-Za-z0-9_./+@:-]+$ ]] \
    || die "'${DRUID_HOME}' has characters that are not allowed in a path here"
[[ -z "${DRUID_HOME}" || -d "${DRUID_HOME}/extensions" ]] \
    || die "not a Druid installation (no extensions/ directory): ${DRUID_HOME}"

run() { if [[ "${DRY_RUN}" -eq 1 ]]; then printf "  [dry-run] %s\n" "$*"; else "$@"; fi; }
sudo_run() {
    if [[ "$(id -u)" -eq 0 ]]; then run "$@"
    elif command -v sudo >/dev/null 2>&1; then run sudo "$@"
    else die "needs root to run: $* (install sudo, or run this script as root)"; fi
}

confirm() {
    [[ "${YES}" -eq 1 ]] && { ok "$1 -> yes (--yes)"; return 0; }
    [[ -e /dev/tty ]] || die "'$1' needs an answer but there is no terminal (pass --yes)"
    local reply; read -r -p "$1 [Y/n] " reply < /dev/tty || true
    [[ -z "${reply}" || "${reply}" =~ ^[Yy] ]]
}

# --- platform ---------------------------------------------------------------
OS="$(uname -s)"; MACH="$(uname -m)"
case "${MACH}" in
    x86_64|amd64)  ARCH=amd64 ;;
    aarch64|arm64) ARCH=arm64 ;;
    *) die "unsupported architecture '${MACH}' (the extension is built for amd64 and arm64)" ;;
esac
case "${OS}" in
    Linux|Darwin) ;;
    *) die "unsupported OS '${OS}' (Apache Druid runs on Linux and macOS)" ;;
esac

# --- uninstall --------------------------------------------------------------
if [[ "${UNINSTALL}" -eq 1 ]]; then
    log "Uninstalling FractalSQL for Apache Druid"
    if [[ "${OS}" == "Linux" ]] && command -v dpkg >/dev/null 2>&1 && dpkg -s fractalsql-druid >/dev/null 2>&1; then
        sudo_run apt-get remove -y fractalsql-druid
    elif [[ "${OS}" == "Linux" ]] && command -v rpm >/dev/null 2>&1 && rpm -q fractalsql-druid >/dev/null 2>&1; then
        sudo_run "$(command -v dnf || command -v yum)" remove -y fractalsql-druid
    fi
    for f in "${PREFIX_LOCAL}/bin/fractalsqld" "${PREFIX_LOCAL}/bin/fsqlctl" "${PREFIX_LOCAL}/bin/fractalsql-druid-mcp" \
             "${PREFIX_LOCAL}/bin/fractalsql-ledger-collect" "${PREFIX_LOCAL}/bin/fractalsql-ledger-check" \
             "${PREFIX_LOCAL}/bin/.mcp-schema-lock" "${PREFIX_LOCAL}/bin/.mcp-safety-annotations-lock"; do
        [[ -e "${f}" ]] && sudo_run rm -f "${f}"
    done
    [[ -d "${PREFIX_LOCAL}/lib/fractalsql-druid" ]] && sudo_run rm -rf "${PREFIX_LOCAL}/lib/fractalsql-druid"
    if [[ -n "${DRUID_HOME}" && -d "${DRUID_HOME}/extensions/fractalsql-druid" ]]; then
        sudo_run rm -rf "${DRUID_HOME}/extensions/fractalsql-druid"
        ok "removed the extension from ${DRUID_HOME}; also remove \"fractalsql-druid\" from druid.extensions.loadList"
    fi
    ok "done. Configuration and the signing key (the conf directory) are left in place."
    exit 0
fi

# --- find the package -------------------------------------------------------
log "FractalSQL for Apache Druid ${FSQL_VERSION} on ${OS}/${MACH}"
TMP="$(mktemp -d)"; trap 'rm -rf "${TMP}"' EXIT
BASE="https://github.com/${REPO}/releases"
if [[ "${FSQL_VERSION}" == "latest" ]]; then URL_BASE="${BASE}/latest/download"; else URL_BASE="${BASE}/download/v${FSQL_VERSION}"; fi

pm=""
if [[ "${OS}" == "Linux" ]]; then
    if   command -v apt-get >/dev/null 2>&1 && command -v dpkg >/dev/null 2>&1; then pm=deb
    elif command -v dnf     >/dev/null 2>&1; then pm=rpm
    elif command -v yum     >/dev/null 2>&1; then pm=rpm
    fi
fi

PKG=""
if [[ -n "${FROM_FILE}" ]]; then
    [[ -f "${FROM_FILE}" ]] || die "--from-file: no such file '${FROM_FILE}'"
    PKG="${FROM_FILE}"
    ok "using ${PKG}"
else
    if   [[ "${OS}" == "Darwin" ]]; then asset="fractalsql-druid-macos-${ARCH}.zip"
    elif [[ -n "${pm}" ]];          then asset="fractalsql-druid-${ARCH}.${pm}"
    else                                 asset="fractalsql-druid-linux-${ARCH}.tar.gz"; fi
    log "Downloading ${asset}"
    if [[ "${DRY_RUN}" -eq 1 ]]; then
        printf "  [dry-run] curl -fsSL --proto '=https' -o %s %s/%s\n" "${asset}" "${URL_BASE}" "${asset}"
        PKG="${TMP}/${asset}"
    else
        fetch -o "${TMP}/${asset}" "${URL_BASE}/${asset}" || die "could not download ${URL_BASE}/${asset}"
        PKG="${TMP}/${asset}"
        ok "downloaded ${asset}"
    fi
fi

command -v java >/dev/null 2>&1 || warn "no java on PATH; fractalsqld needs a Java 17 or newer runtime (the .deb and .rpm depend on one)"

# --- install ----------------------------------------------------------------
JAR=""
install_bundle() {   # install_bundle <archive-kind> : unpack the bundle and run its own install.sh
    local kind="$1" dir="${TMP}/bundle"
    mkdir -p "${dir}"
    if [[ "${DRY_RUN}" -eq 1 ]]; then
        printf "  [dry-run] unpack %s and run its install.sh --prefix %s\n" "${PKG##*/}" "${PREFIX_LOCAL}"
        JAR="${PREFIX_LOCAL}/lib/fractalsql-druid/extensions/fractalsql-druid.jar"
        return
    fi
    case "${kind}" in
        zip) command -v unzip >/dev/null 2>&1 || die "unzip is required for the macOS archive"; unzip -qo "${PKG}" -d "${dir}" ;;
        tgz) tar -xzf "${PKG}" -C "${dir}" ;;
    esac
    local b; b="$(find "${dir}" -maxdepth 2 -name install.sh -print -quit)"
    [[ -n "${b}" ]] || die "no install.sh in ${PKG##*/}"
    b="$(dirname "${b}")"
    local args=(--prefix "${PREFIX_LOCAL}")
    [[ -z "${DRUID_HOME}" ]] || args+=(--druid-home "${DRUID_HOME}")
    if [[ "$(id -u)" -eq 0 ]]; then "${b}/install.sh" "${args[@]}"
    elif command -v sudo >/dev/null 2>&1; then sudo "${b}/install.sh" "${args[@]}"
    else die "needs root to install into ${PREFIX_LOCAL} (install sudo, or run this script as root)"; fi
    JAR="${b}/extensions/fractalsql-druid/fractalsql-druid.jar"
}

DAEMON_BIN="/usr/bin/fractalsqld"; CONF_DIR="/etc/fractalsql"
case "${PKG}" in
    *.deb)
        confirm "Install ${PKG##*/} with apt?" || die "cancelled"
        sudo_run apt-get install -y "${PKG}"
        JAR="/usr/lib/fractalsql-druid/extensions/fractalsql-druid/fractalsql-druid.jar" ;;
    *.rpm)
        confirm "Install ${PKG##*/} with dnf?" || die "cancelled"
        sudo_run "$(command -v dnf || command -v yum)" install -y "${PKG}"
        JAR="/usr/lib/fractalsql-druid/extensions/fractalsql-druid/fractalsql-druid.jar" ;;
    *.zip)
        confirm "Unpack ${PKG##*/} and install it into ${PREFIX_LOCAL}?" || die "cancelled"
        install_bundle zip
        DAEMON_BIN="${PREFIX_LOCAL}/bin/fractalsqld"; CONF_DIR="${PREFIX_LOCAL}/etc/fractalsql"
        if [[ "${OS}" == "Darwin" ]]; then
            sudo_run xattr -dr com.apple.quarantine "${PREFIX_LOCAL}/lib/fractalsql-druid" || true
            [[ -z "${DRUID_HOME}" ]] || sudo_run xattr -dr com.apple.quarantine "${DRUID_HOME}/extensions/fractalsql-druid" || true
            ok "cleared the Gatekeeper quarantine flag (the binaries are unsigned)"
        fi ;;
    *.tar.gz|*.tgz)
        confirm "Unpack ${PKG##*/} and install it into ${PREFIX_LOCAL}?" || die "cancelled"
        install_bundle tgz
        DAEMON_BIN="${PREFIX_LOCAL}/bin/fractalsqld"; CONF_DIR="${PREFIX_LOCAL}/etc/fractalsql" ;;
    *) die "do not know how to install '${PKG}' (expected .deb, .rpm, .tar.gz or .zip)" ;;
esac
ok "installed"

# The packages install the JAR under /usr/lib; the bundle installer already honoured --druid-home.
if [[ -n "${DRUID_HOME}" && ( "${PKG}" == *.deb || "${PKG}" == *.rpm ) ]]; then
    log "Copying the extension into ${DRUID_HOME}/extensions/fractalsql-druid"
    sudo_run mkdir -p "${DRUID_HOME}/extensions/fractalsql-druid"
    sudo_run cp "${JAR}" "${DRUID_HOME}/extensions/fractalsql-druid/fractalsql-druid.jar"
    ok "extension copied"
fi

if [[ "${DRY_RUN}" -eq 0 && ( "${PKG}" == *.deb || "${PKG}" == *.rpm ) ]]; then
    [[ -x "${DAEMON_BIN}" ]] || warn "${DAEMON_BIN} is not where it was expected"
fi

if [[ -n "${DRUID_HOME}" ]]; then
    EXT_NOTE="The extension is in ${DRUID_HOME}/extensions/fractalsql-druid."
else
    EXT_NOTE="Copy the extension into a Druid installation:  cp ${JAR} <druid-home>/extensions/fractalsql-druid/   (or re-run with --druid-home <dir>)"
fi
case "${OS}" in Darwin) SOCKET="${PREFIX_LOCAL}/var/run/fractalsql/fractalsqld.sock";; *) SOCKET="/run/fractalsql/fractalsqld.sock";; esac
if [[ "${PKG}" == *.deb || "${PKG}" == *.rpm ]]; then START="systemctl enable --now fractalsqld"; else START="${DAEMON_BIN} -c ${CONF_DIR}/fractalsqld.conf"; fi

cat <<EOF

Done. To use it:

  1. ${EXT_NOTE}
     Add "fractalsql-druid" to druid.extensions.loadList in common.runtime.properties and restart the
     Druid services that should serve the functions (broker, historical).

  2. Tell the extension how to reach the daemon (reasoning, embedding and the enterprise tier):
         druid.fractalsql.daemon_socket=${SOCKET}
         druid.fractalsql.daemon_hmac_key_file=${CONF_DIR}/hmac.key

  3. Configure the model provider in ${CONF_DIR}/fractalsqld.conf, then start the daemon. Run one on
     each host whose Druid processes call it (the brokers):
         ${START}

  4. Check it:
         curl http://<broker>:8082/fractalsql/health

The MCP server is installed as fractalsql-druid-mcp (set DRUID_URL, for example http://localhost:8888).
Search, vector math and analytics need no daemon and no provider.
EOF
