#!/bin/sh
# Build the FractalSQL-for-Druid JNI shim for a POSIX platform.
#
# Run inside a Linux container with the repository mounted at /work. The
# container needs a C compiler AND the JDK's JNI headers. The
# eclipse-temurin image has the headers but no compiler, so either add
# one (apt-get install build-essential) or mount the headers into a
# build image:
#
#   # once: lift the headers out of a JDK image
#   docker create eclipse-temurin:21-jdk
#   docker cp <id>:/opt/java/openjdk/include /path/to/_jdkinc
#
#   # then: compile in a build image that has a compiler
#   docker run --rm -v "$PWD:/work" -v /path/to/_jdkinc:/jdkinc -w /work \
#       <a build image with cc> sh src/main/native/build-native-linux.sh linux-x86_64
#
# The shim links against the UNMODIFIED vendored core archive in
# include/<os>-<arch>/. That archive is a core library: it is linked,
# never edited and never rebuilt here.
#
# Usage: build-native-linux.sh <platform>
#        platform: linux-x86_64 | linux-aarch64 | darwin-x86_64 | darwin-arm64

set -eu

PLATFORM="${1:-linux-x86_64}"
SHARED="-shared"
HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/../../../.." && pwd)"

# The library file name must be what System.mapLibraryName() produces for
# the platform: "lib<name>.so" on Linux, "lib<name>.dylib" on macOS.
case "$PLATFORM" in
    linux-x86_64)
        EXT=so
        CORE="$ROOT/include/$PLATFORM/libfractalsql-community-sovereign-c.a"
        ARCHFLAG=""
        ;;
    linux-aarch64)
        EXT=so
        CORE="$ROOT/include/$PLATFORM/libfractalsql-community-sovereign-c.a"
        ARCHFLAG=""
        ;;
    darwin-x86_64)
        EXT=dylib
        SHARED="-dynamiclib"
        CORE="$ROOT/include/$PLATFORM/libfractalsql-community-sovereign-c.a"
        ARCHFLAG="-arch x86_64"
        ;;
    darwin-arm64)
        EXT=dylib
        SHARED="-dynamiclib"
        CORE="$ROOT/include/$PLATFORM/libfractalsql-community-sovereign-c.a"
        ARCHFLAG="-arch arm64"
        ;;
    *)
        echo "ERROR: unknown platform '$PLATFORM'" >&2
        exit 2
        ;;
esac

OUTDIR="${FSQL_JNI_OUT:-$ROOT/druid-extension/src/main/native-resources/native/$PLATFORM}"
LIBNAME="libfractalsql-jni.$EXT"

if [ ! -f "$CORE" ]; then
    echo "ERROR: core archive not found: $CORE" >&2
    echo "       The vendored core drop is a core library; it is not rebuilt here." >&2
    exit 2
fi

mkdir -p "$OUTDIR"

# jni.h lives at include/, and the platform header (jni_md.h) at
# include/<os>/ -- both directories have to be on the include path.
JNIINC="${JAVA_HOME:-/usr/lib/jvm/default-java}/include"
if [ ! -f "$JNIINC/jni.h" ]; then
    JNIINC="$(dirname "$(dirname "$(readlink -f "$(command -v javac)")")")/include"
fi
case "$PLATFORM" in
    linux-*)  JNIINC2="$JNIINC/linux" ;;
    darwin-*) JNIINC2="$JNIINC/darwin" ;;
esac

echo "=== Building the FractalSQL-for-Druid JNI shim ==="
echo "    platform : $PLATFORM"
echo "    core     : $CORE"
echo "    output   : $OUTDIR/$LIBNAME"
echo "    jni hdrs : $JNIINC"

# ---- compiler hardening ---------------------------------------------------
# The shim loads the vendored core and calls it from the Druid JVM, so it is
# built with the standard hardening flags. Every flag is probed: the
# toolchain decides whether it accepts it, so an older compiler, a Clang
# without -fstack-clash-protection, or macOS (no RELRO) still builds.
probe_c() { printf 'int fsq_probe(void){return 0;}\n' | cc -O2 -Werror "$1" -x c -c - -o /dev/null >/dev/null 2>&1 && printf '%s ' "$1"; }
probe_l() { printf 'int main(void){return 0;}\n' | cc -O2 "$1" -x c - -o /dev/null >/dev/null 2>&1 && printf '%s ' "$1"; }
HARDEN_C="$(probe_c -fstack-protector-strong)"
HARDEN_C="$HARDEN_C$(probe_c -fstack-clash-protection)"
case "$PLATFORM" in linux-x86_64) HARDEN_C="$HARDEN_C$(probe_c -fcf-protection)";; esac
HARDEN_C="$HARDEN_C$(probe_c -D_FORTIFY_SOURCE=2)"
HARDEN_L="$(probe_l -Wl,-z,relro,-z,now)"
HARDEN_L="$HARDEN_L$(probe_l -Wl,-z,noexecstack)"
echo "    hardening: $HARDEN_C $HARDEN_L"

# FSQL_JNI_SAN=address|undefined|thread builds an instrumented shim (a test build, not a release artifact):
# -O1 -g with the sanitizer, and no _FORTIFY_SOURCE (it conflicts with the sanitizers' interceptors). Set
# FSQL_JNI_OUT to a scratch directory so the packaged shim is not replaced; the extension's tests then load it
# with -Dfsql.native.path=<dir> and the sanitizer runtime preloaded into the JVM (build_test.sh gate 40).
# The warnings are on for every build: the shim holds the length checks the audit found missing, and a mismatched
# type or a dropped return value near them should not pass quietly.
WARN="-Wall -Wextra"
if [ -n "${FSQL_JNI_SAN:-}" ]; then
    OPT="-O1 -g -fno-omit-frame-pointer -fsanitize=$FSQL_JNI_SAN"
    [ "$FSQL_JNI_SAN" = undefined ] && OPT="$OPT -fno-sanitize-recover=undefined"
    HARDEN_C="$(printf '%s' "$HARDEN_C" | sed 's/-D_FORTIFY_SOURCE=2//')"
    echo "    sanitizer: $FSQL_JNI_SAN"
else
    OPT="-O3"
fi

# FSQL_STATIC: selects the core header's static-library declarations.
# -fvisibility=hidden: only the JNI entry points (JNIEXPORT) are exported, not the helpers.
# -fno-strict-aliasing: the shim converts between jdouble*, jbyte* and size_t* views of buffers.
cc -std=c11 $OPT $WARN -fvisibility=hidden -fno-strict-aliasing -fPIC $HARDEN_C $ARCHFLAG $SHARED -DFSQL_STATIC \
    -I"$JNIINC" -I"$JNIINC2" -I"$ROOT/include" \
    "$HERE/fractalsql_jni.c" \
    "$CORE" \
    -o "$OUTDIR/$LIBNAME" $HARDEN_L -lm -ldl -lpthread

echo "=== Native shim built ==="
ls -l "$OUTDIR/$LIBNAME"
