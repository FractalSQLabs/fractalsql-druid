#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
# SPDX-FileCopyrightText: 2026 Daniel Gardiner d/b/a FractalSQLabs
#
# build_test.sh: the validation gate runner for fractalsql-druid. It mirrors what CI runs, so a
# local run and a CI run are the same run. Gates are numbered, each prints PASS / FAIL / SKIP lines,
# and the script exits non-zero if any assertion failed.
#
#   ./build_test.sh                  every gate that can run here (Docker gates are skipped without Docker)
#   ./build_test.sh --list           print the gate matrix
#   ./build_test.sh --quick          the gates that need no Docker and finish in about a minute
#   ./build_test.sh --gate 04,05     run only these gates
#   ./build_test.sh --no-docker      skip the gates that start the Druid stack
#   ./build_test.sh --llm URL        use this OpenAI-compatible endpoint for the stack gates instead of the mock
#                                    (set FSQLD_REASONING_MODEL and FSQLD_EMBED_MODEL; FSQLD_THINK defaults to low)
#   ./build_test.sh --keep           leave the daemon and the stack running afterwards
#   ./build_test.sh --asan | --ubsan | --tsan    rebuild the C daemon and the MCP server with that sanitizer, in a private copy, and run
#                                    the daemon and MCP gates against them (a report in a log is a failure)
#   ./build_test.sh --coverage       the same with gcov, then a report for src (the C daemon and the extension's Java) and a second one
#                                    for mcp: lines, functions and branches, against an 80% target (best effort)
#   ./build_test.sh --fuzz           libFuzzer on the MCP server's parsers and on the daemon's own parsers
#                                    (FSQL_FUZZ_SECS per target, default 30; eleven targets, so about five minutes)
#   ./build_test.sh --analyze        static analysis of the C sources (gcc -fanalyzer, clang-tidy, cppcheck) against the
#                                    accepted findings in tests/analysis/baseline.txt
#   ./build_test.sh --analyze-cpp    the same for the MCP server's C++17 (clang-tidy, cppcheck) against tests/analysis/baseline-cpp.txt;
#                                    clang-tidy over the C++ is slow (about two to three minutes on four processes), so it is a mode, not a gate
#   ./build_test.sh --fault          a provider that hangs, answers garbage, errors or cuts off; a daemon killed mid-call; bad inputs at start
#   ./build_test.sh --profile        valgrind memcheck over the C daemon and the MCP server
#
# What is tested
#   * fractalsqld, in both forms: the C daemon (the reference) and the JVM daemon (the one the Druid
#     deployment runs). Both must answer the same wire protocol the same way.
#   * The four reasoning contexts (chat, text-to-SQL, review, embed), by checking what each sends to a
#     deterministic mock provider.
#   * The enterprise tier: signature checking, the ledger, the dormant path.
#   * The extension: unit tests, packaging, and (with Docker) the real Druid cluster.
#   * The MCP server: the tool table and its locks, the alignment contract, the protocol, and (with
#     Docker) every tool family against the live cluster.
#
# Each gate is held to a short wall-clock budget; the gate's elapsed time is printed beside its verdict.

set -u
cd "$(dirname "$0")"
ROOT="$PWD"
ART="${FSQL_TEST_DIR:-$(mktemp -d "${TMPDIR:-/tmp}/fsql-druid-test.XXXXXX")}"
mkdir -p "$ART"
NICE="nice -n 15"
command -v ionice >/dev/null 2>&1 && NICE="ionice -c2 -n7 nice -n 15"

PASS=0; FAIL=0; SKIP=0
ONLY=""; NO_DOCKER=0; QUICK=0; KEEP=0; LLM_URL=""; LIST=0; SAN=""; COV=0; MODE=""
while [ $# -gt 0 ]; do
  case "$1" in
    --list) LIST=1;;
    --quick) QUICK=1; NO_DOCKER=1;;
    --gate) ONLY="$2"; shift;;
    --no-docker) NO_DOCKER=1;;
    --keep) KEEP=1;;
    --llm) LLM_URL="$2"; shift;;
    --asan) SAN=asan;;
    --ubsan) SAN=ubsan;;
    --tsan) SAN=tsan;;
    --coverage) COV=1;;
    --fuzz) MODE=fuzz;;
    --analyze) MODE=analyze;;
    --analyze-cpp) MODE=analyze_cpp;;
    --fault) MODE=fault;;
    --profile) MODE=profile;;
    -h|--help) sed -n 2,30p "$0"; exit 0;;
    *) echo "unknown option: $1" >&2; exit 2;;
  esac
  shift
done

# Native modes: --asan / --ubsan / --tsan / --coverage rebuild the C daemon and the MCP server instrumented, in a private copy of the tree
# (the copy re-runs this script with FSQL_NATIVE=1), and run the daemon and MCP gates against them. The JVM daemon is not instrumented.
SAN="${FSQL_SAN:-$SAN}"; COV="${FSQL_COV:-$COV}"; NATIVE="${FSQL_NATIVE:-0}"
SANMAKE=""
case "$SAN" in asan) SANMAKE="ASAN=1";; ubsan) SANMAKE="UBSAN=1";; tsan) SANMAKE="TSAN=1";; esac
[ "$COV" = 1 ] && SANMAKE="COVERAGE=1"
KINDS="c jvm"; DK=jvm
[ "$NATIVE" = 1 ] && { KINDS="c"; DK=c; }
VG=""   # set by --profile: a valgrind command line that wraps the C daemon
export ASAN_OPTIONS="${ASAN_OPTIONS:-detect_leaks=0:halt_on_error=1}" UBSAN_OPTIONS="${UBSAN_OPTIONS:-print_stacktrace=1:halt_on_error=1}" TSAN_OPTIONS="${TSAN_OPTIONS:-halt_on_error=1}"

pass() { PASS=$((PASS+1)); echo "PASS  $*"; }
fail() { FAIL=$((FAIL+1)); echo "FAIL  $*"; }
skip() { SKIP=$((SKIP+1)); echo "SKIP  $*"; }
check() { # check "name" command...
  local name="$1"; shift
  if "$@" >"$ART/last.out" 2>&1; then pass "$name"; else fail "$name"; sed 's/^/      /' "$ART/last.out" | tail -8; fi
}
expect_fail() { # expect_fail "name" command...   the command must exit non-zero
  local name="$1"; shift
  if "$@" >"$ART/last.out" 2>&1; then fail "$name (it succeeded)"; else pass "$name"; fi
}
have() { command -v "$1" >/dev/null 2>&1; }

# The sanitized processes need a fixed address space layout: ThreadSanitizer refuses the
# layouts a high-entropy ASLR kernel produces ("unexpected memory mapping"), and
# AddressSanitizer's allocator can fail to reserve its region for the same reason (the
# runtime dies at start-up with "AddressSanitizer:DEADLYSIGNAL", and then spins). setarch -R
# turns the randomization off for the process and for everything it starts. It needs
# CAP_SYS_ADMIN, so it is used only where it works; this is about the test run only, and
# the shipped binaries are unaffected.
SAN_PREFIX=""
if have setarch && setarch "$(uname -m)" -R true >/dev/null 2>&1; then
  SAN_PREFIX="setarch $(uname -m) -R"
fi

# ---------------------------------------------------------------------------------------------
# Helpers: the mock provider and a daemon under test
# ---------------------------------------------------------------------------------------------
MOCK_PORT="${FSQL_TEST_MOCK_PORT:-18765}"
MOCK_PID=""
mock_start() {
  : > "$ART/mock.log"
  # a free port, so a leftover process from another run can never answer for this one
  MOCK_PORT="$(python3 -c 'import socket; s=socket.socket(); s.bind(("127.0.0.1",0)); print(s.getsockname()[1])')"
  python3 service/tests/mock_llm.py "$MOCK_PORT" "$ART/mock.log" >/dev/null 2>&1 &
  MOCK_PID=$!
  for _ in $(seq 1 30); do (exec 3<>"/dev/tcp/127.0.0.1/$MOCK_PORT") 2>/dev/null && return 0; sleep 0.2; done
  return 1
}
mock_stop() { [ -n "$MOCK_PID" ] && kill "$MOCK_PID" 2>/dev/null; MOCK_PID=""; }

DPID=""
DAEMON_WRAP=""   # a program the daemon is started through (the file-size case in gate 30)
D="$ART/d"
FSQLD_C="$ROOT/service/build/fractalsqld"
FSQLD_JAR="$ROOT/service/build/jvm/fractalsqld.jar"
FSQLD_JNI="$ROOT/service/build/jvm/libfsqld_jni.so"
FSQLCTL="$ROOT/service/build/fsqlctl"
PLUGIN="$ROOT/include/linux-x86_64/fractalsql-reasoning-http.so"
ENTLIB="$ROOT/include/linux-x86_64/libfractalsql-enterprise-sovereign-c.so"

# daemon_conf FILE [extra lines...]: a config that points at the mock provider
daemon_conf() {
  local f="$1"; shift
  mkdir -p "$D"; umask 077
  [ -f "$D/hmac.key" ] || openssl rand -hex 32 > "$D/hmac.key"
  {
    echo "socket_path = $D/d.sock"
    echo "hmac_key_file = $D/hmac.key"
    echo "allowed_uids = $(id -u)"
    echo "reasoning_plugin = $PLUGIN"
    echo "reasoning_url = http://127.0.0.1:$MOCK_PORT/v1/chat/completions"
    echo "reasoning_model = mock-chat"
    echo "reasoning_allow_plaintext = true"
    echo "embed_url = http://127.0.0.1:$MOCK_PORT/v1/embeddings"
    echo "embed_model = mock-embed"
    for l in "$@"; do echo "$l"; done
  } > "$f"
}

# daemon_start KIND CONF [ENV=VAL...]   KIND is c or jvm
daemon_start() {
  local kind="$1" conf="$2"; shift 2
  rm -f "$D/d.sock"; : > "$D/daemon.log"
  # Under ASAN the daemon's leaks are checked: the sanitizer reports
  # them when the process exits, and daemon_stop reads the log.
  local sanenv=()
  [ "$SAN" = asan ] && sanenv=("ASAN_OPTIONS=detect_leaks=1:halt_on_error=1" \
                               "LSAN_OPTIONS=suppressions=$ROOT/tests/lsan.supp:print_suppressions=1")
  if [ "$kind" = c ]; then
    env "$@" "${sanenv[@]}" $NICE $VG $DAEMON_WRAP "$FSQLD_C" -c "$conf" >"$D/daemon.log" 2>&1 &
  else
    env "$@" "${sanenv[@]}" $NICE java -Dfsqld.native="$FSQLD_JNI" -jar "$FSQLD_JAR" -c "$conf" >"$D/daemon.log" 2>&1 &
  fi
  DPID=$!
  local tries=100; [ -n "$VG" ] && tries=900   # valgrind starts slowly
  for _ in $(seq 1 "$tries"); do [ -S "$D/d.sock" ] && return 0; kill -0 "$DPID" 2>/dev/null || return 1; sleep 0.2; done
  return 1
}
# Stopping a daemon also says what the sanitizer or valgrind saw: a report in its log is a failure.
daemon_stop() {
  local rc=0
  [ -n "$DPID" ] && { kill "$DPID" 2>/dev/null; wait "$DPID" 2>/dev/null; rc=$?; }
  DPID=""; rm -f "$D/d.sock"
  if [ -n "$SAN" ] && grep -qE 'AddressSanitizer|LeakSanitizer|ThreadSanitizer|UndefinedBehaviorSanitizer|runtime error:' "$D/daemon.log" 2>/dev/null; then
    fail "the $SAN build reported a problem in the daemon log"; sed 's/^/      /' "$D/daemon.log" | head -30
  fi
  if [ -n "$VG" ] && { [ "$rc" = 99 ] || grep -q '^==[0-9]*== ERROR SUMMARY: [1-9]' "$D/daemon.log" 2>/dev/null; }; then
    fail "valgrind reported errors in the daemon"; sed 's/^/      /' "$D/daemon.log" | grep -v "^      $" | head -40
  fi
}
ctl() { FSQLCTL_SOCKET="$D/d.sock" FSQLCTL_KEY="$D/hmac.key" "$FSQLCTL" "$@"; }

cleanup() {
  daemon_stop; mock_stop
  if [ "$KEEP" = 0 ] && [ "${STACK_UP:-}" = 1 ]; then stack_down; fi
}
trap cleanup EXIT

# ---------------------------------------------------------------------------------------------
# Gates
# ---------------------------------------------------------------------------------------------
gate_01_build_daemon() {
  # The C daemon and its command-line client compile clean under -Werror with no database headers.
  check "make daemon and fsqlctl${SAN:+ ($SAN)}" $NICE make -C service all $SANMAKE
  check "fractalsqld built" test -x "$FSQLD_C"
  check "fsqlctl built" test -x "$FSQLCTL"
  check "the daemon needs no database client library" bash -c "! ldd '$FSQLD_C' | grep -qiE 'mysql|mariadb|sqlite'"
}

gate_02_build_jvm() {
  check "make jvm (JNI library and server jar)" $NICE make -C service jvm
  check "native library built" test -f "$FSQLD_JNI"
  check "server jar built" test -f "$FSQLD_JAR"
  check "the jar names its main class" bash -c "unzip -p '$FSQLD_JAR' META-INF/MANIFEST.MF | grep -q 'Main-Class: com.fractalsqlabs.fractalsql.daemon.Fsqld'"
}

gate_03_jvm_selftest() {
  check "server self-test (frames, HMAC vector, cache, config)" $NICE make -C service jvm-test
}

gate_04_protocol_c() {
  mock_start || { fail "mock provider did not start"; return; }
  daemon_conf "$D/c.conf"
  if daemon_start c "$D/c.conf"; then
    check "C daemon: ping and key check" ctl check
    check "C daemon: protocol conformance" python3 service/tests/conformance.py "$D/d.sock" "$D/hmac.key" "$D/daemon.log"
  else fail "C daemon did not start"; tail -5 "$D/daemon.log"; fi
  daemon_stop; mock_stop
}

gate_05_protocol_jvm() {
  mock_start || { fail "mock provider did not start"; return; }
  daemon_conf "$D/j.conf"
  if daemon_start jvm "$D/j.conf"; then
    check "JVM daemon: ping and key check" ctl check
    check "JVM daemon: protocol conformance" python3 service/tests/conformance.py "$D/d.sock" "$D/hmac.key" "$D/daemon.log"
  else fail "JVM daemon did not start"; tail -5 "$D/daemon.log"; fi
  daemon_stop; mock_stop
}

gate_06_parity() {
  # The JVM daemon answers pure calls exactly as the C daemon does.
  daemon_conf "$D/p.conf"
  local calls=("fractal_version" "fractal_edition" "fractal_vector_norm s:[3,4]" "fractal_vector_dims s:[1,2,3]"
               "fractal_vector_normalize s:[3,4]" "fractal_vector_l2_distance s:[0,0] s:[3,4]"
               "fractal_vector_cosine_distance s:[1,0] s:[0,1]" "fractal_t2s_check_allowlist s:SELECT\ 1"
               "fractal_t2s_check_allowlist s:DROP\ TABLE\ x" "fractal_config_keys")
  daemon_start c "$D/p.conf" || { fail "C daemon did not start"; return; }
  : > "$D/parity.c"; for c in "${calls[@]}"; do eval "ctl call $c" >> "$D/parity.c" 2>&1; done
  daemon_stop
  daemon_start jvm "$D/p.conf" || { fail "JVM daemon did not start"; return; }
  : > "$D/parity.j"; for c in "${calls[@]}"; do eval "ctl call $c" >> "$D/parity.j" 2>&1; done
  daemon_stop
  check "JVM and C daemons agree on ${#calls[@]} pure calls" diff "$D/parity.c" "$D/parity.j"
}

gate_07_contexts() {
  # Four reasoning contexts, checked against what each sends to the provider, for both daemons and
  # all three chat modes. The chat mode is the only one that is configurable.
  mock_start || { fail "mock provider did not start"; return; }
  daemon_conf "$D/x.conf"
  local kind mode
  for kind in $KINDS; do for mode in text code json; do
    : > "$D/req.log"
    local envv=("FSQL_X=1"); [ "$mode" != text ] && envv=("FSQL_REASONING_HTTP_RESPONSE_MODE=$mode")
    # the request log is the mock's own; point the checker at it
    : > "$ART/mock.log"
    if daemon_start "$kind" "$D/x.conf" "${envv[@]}"; then
      check "$kind daemon, chat mode $mode: contexts" python3 service/tests/contexts.py "$D/d.sock" "$D/hmac.key" "$ART/mock.log" "$mode"
    else fail "$kind daemon did not start"; fi
    daemon_stop
  done; done
  mock_stop
}

gate_08_daemon_config() {
  daemon_conf "$D/ok.conf"
  # a world-readable key file is refused at start
  cp "$D/ok.conf" "$D/perm.conf"; chmod 0644 "$D/hmac.key"
  expect_fail "a world-readable hmac key is refused" timeout 5 "$FSQLD_C" -c "$D/perm.conf"
  chmod 0600 "$D/hmac.key"
  daemon_conf "$D/range.conf" "t2s_max_attempts = 99"
  expect_fail "t2s_max_attempts outside [1,10] is refused at start" timeout 5 "$FSQLD_C" -c "$D/range.conf"
  daemon_conf "$D/path.conf" "enterprise_lib = relative/lib.so"
  expect_fail "a relative enterprise_lib is refused at start" timeout 5 "$FSQLD_C" -c "$D/path.conf"
  daemon_conf "$D/allow.conf" "t2s_allowed_statements = anything"
  expect_fail "an unknown t2s_allowed_statements value is refused" timeout 5 "$FSQLD_C" -c "$D/allow.conf"
  # reload: a good edit applies, a bad edit is refused and the running configuration stays
  mock_start
  daemon_conf "$D/r.conf"
  daemon_start $DK "$D/r.conf" || { fail "JVM daemon did not start"; return; }
  check "reload with no change" ctl reload
  cp "$D/r.conf" "$D/r.good"; echo "t2s_max_attempts = 99" >> "$D/r.conf"
  expect_fail "a reload with a bad provider value is refused" ctl reload
  check "the running configuration is unchanged after a refused reload" bash -c "FSQLCTL_SOCKET='$D/d.sock' FSQLCTL_KEY='$D/hmac.key' '$FSQLCTL' call fractal_t2s_config i:1 | grep -q '\"max_attempts\":2'"
  cp "$D/r.good" "$D/r.conf"; echo "t2s_max_attempts = 4" >> "$D/r.conf"
  check "a good reload applies" ctl reload
  check "the new value is live" bash -c "FSQLCTL_SOCKET='$D/d.sock' FSQLCTL_KEY='$D/hmac.key' '$FSQLCTL' call fractal_t2s_config i:1 | grep -q '\"max_attempts\":4'"
  daemon_stop; mock_stop
}

gate_09_daemon_security() {
  daemon_conf "$D/s.conf" "max_connections = 3" "idle_timeout_secs = 2"
  daemon_start $DK "$D/s.conf" || { fail "JVM daemon did not start"; return; }
  check "security: refusals, limits and idle timeout" python3 service/tests/security.py "$D/d.sock" "$D/hmac.key"
  # the socket carries no access for others, and the private directory it was bound in is gone (SECURITY_AUDIT.md 3.26)
  check "the daemon socket is owner and group only, with no staging directory left" \
    bash -c "m=\$(stat -c %a '$D/d.sock' 2>/dev/null || stat -f %Lp '$D/d.sock'); [ \"\$m\" = 660 ] && [ -z \"\$(ls -d '$D'/.fsqld-* 2>/dev/null)\" ]"
  daemon_stop
  # a uid that is not on the allow-list is refused
  daemon_conf "$D/u.conf"; sed -i "s/^allowed_uids = .*/allowed_uids = 65534/" "$D/u.conf"
  daemon_start $DK "$D/u.conf" || { fail "JVM daemon did not start"; return; }
  expect_fail "a caller whose uid is not allowed is refused" ctl ping
  daemon_stop
  # The text-to-SQL policy table: every case in tests/svc/t2s_policy_cases.py, against the
  # documented rules, in both of the daemon's allowed-statement modes.
  local pmode
  for pmode in select select_insert_update; do
    daemon_conf "$D/pol.conf"
    daemon_start $DK "$D/pol.conf" "FRACTALSQL_TEXT_TO_SQL_ALLOWED_STATEMENTS=$pmode" || { fail "the daemon did not start (text-to-SQL policy)"; continue; }
    check "the text-to-SQL policy table ($pmode): every case matches the documented rules" python3 service/tests/t2s_policy.py "$D/d.sock" "$D/hmac.key" "$pmode"
    daemon_stop
  done
  # The two surfaces that call a model, against a provider that answers what it is told: generate returns the fenced block's
  # interior; review reads the verdict off the front of the answer (the word PASS, not the letters).
  check "text-to-SQL generate and review against a scripted provider" python3 service/tests/t2s_surfaces.py "$FSQLD_C" "$PLUGIN" "$D/hmac.key"
}

gate_10_enterprise() {
  [ -f "$ENTLIB" ] || { skip "no enterprise library in include/"; return; }
  local kind
  for kind in $KINDS; do
    daemon_conf "$D/e.conf" "enterprise_lib = $ENTLIB" "enterprise_ledger_path = $D/ledger.dat"
    rm -f "$D"/ledger.dat*
    daemon_start "$kind" "$D/e.conf" || { fail "$kind daemon did not start"; continue; }
    check "$kind: the signed enterprise library loads" ctl call fractal_ledger_flush i:1
    check "$kind: audit_log writes" ctl call fractal_audit_log s:test_event 's:{"n":1}' i:1 s:ci
    check "$kind: the chain verifies" bash -c "FSQLCTL_SOCKET='$D/d.sock' FSQLCTL_KEY='$D/hmac.key' '$FSQLCTL' call fractal_ledger_verify i:1 | grep -q '\"ok\":true'"
    daemon_stop
  done
  # a tampered signature is refused; no library is dormant, not a crash
  mkdir -p "$D/t"; cp "$ENTLIB" "$D/t/ent.so"; head -c 64 /dev/urandom > "$D/t/ent.so.sig"
  daemon_conf "$D/t.conf" "enterprise_lib = $D/t/ent.so" "enterprise_ledger_path = $D/ledger2.dat"
  daemon_start $DK "$D/t.conf" || { fail "JVM daemon did not start"; return; }
  expect_fail "a tampered signature is refused" ctl call fractal_ledger_flush i:1
  check "the refusal names the signature" grep -q "signature" "$D/daemon.log"
  daemon_stop
  daemon_conf "$D/n.conf"
  daemon_start $DK "$D/n.conf" || { fail "JVM daemon did not start"; return; }
  expect_fail "with no library the ledger is dormant" ctl call fractal_ledger_flush i:1
  check "the daemon is still up after a dormant call" ctl ping
  daemon_stop
}

# The platform key of this machine: the directory name of its native payload.
host_platform() {
  case "$(uname -s)-$(uname -m)" in
    Linux-x86_64) echo linux-x86_64;;
    Linux-aarch64|Linux-arm64) echo linux-aarch64;;
    Darwin-x86_64) echo darwin-x86_64;;
    Darwin-arm64) echo darwin-arm64;;
    *) echo "unsupported-$(uname -s)-$(uname -m)";;
  esac
}

gate_11_extension() {
  if ! have mvn; then skip "mvn not installed"; return; fi
  local plat ext lib; plat="$(host_platform)"
  case "$plat" in unsupported-*) skip "no native payload for this platform ($plat)"; return;; esac
  case "$plat" in darwin-*) ext=dylib;; *) ext=so;; esac
  lib="druid-extension/src/main/native-resources/native/$plat/libfractalsql-jni.$ext"
  # The payload is built here, from the vendored core archive, so the jar's shim always matches the sources it ships with.
  check "native payload for $plat" sh druid-extension/src/main/native/build-native-linux.sh "$plat"
  check "extension unit tests" bash -c "cd druid-extension && $NICE mvn -q test -Dfsql.platform=$plat ${FSQL_DRUID_VERSION:+-Ddruid.version=$FSQL_DRUID_VERSION}"
  check "extension package" bash -c "cd druid-extension && $NICE mvn -q clean package -DskipTests ${FSQL_DRUID_VERSION:+-Ddruid.version=$FSQL_DRUID_VERSION}"
  local jar; jar="$(ls druid-extension/target/fractalsql-druid-*.jar 2>/dev/null | head -1)"
  check "the jar carries the $plat native payload" bash -c "unzip -l '$jar' | grep -q 'native/$plat/libfractalsql-jni.$ext'"
  check "the jar carries the daemon client" bash -c "unzip -l '$jar' | grep -q 'FsqClient.class'"
  check "the jar carries no HTTP provider client of its own" bash -c "! unzip -l '$jar' | grep -q 'ReasoningHttp'"
  case "$plat" in
    linux-*)
      check "the extension links no provider library" bash -c "! ldd '$lib' | grep -qi curl"
      check "the native payload has no undefined symbols" bash -c "! ldd -r '$lib' 2>&1 | grep -q 'undefined symbol'";;
    darwin-*)
      check "the extension links no provider library" bash -c "! otool -L '$lib' | grep -qi curl";;
  esac
  # A release jar carries every platform's payload; the release workflow assembles them and sets FSQL_ALL_PAYLOADS=1.
  if [ "${FSQL_ALL_PAYLOADS:-0}" = 1 ]; then
    local p
    for p in linux-x86_64 linux-aarch64 darwin-x86_64 darwin-arm64; do
      case "$p" in darwin-*) e=dylib;; *) e=so;; esac
      check "the jar carries the $p native payload" bash -c "unzip -l '$jar' | grep -q 'native/$p/libfractalsql-jni.$e'"
    done
  fi
}

gate_12_mcp_build() {
  check "make the MCP server${SAN:+ ($SAN)}" $NICE make -C mcp $SANMAKE
  check "the MCP server reports its version" bash -c "mcp/fractalsql-druid-mcp --version | grep -q '^2\\.'"
  local n; n="$(mcp/fractalsql-druid-mcp --list-tools | wc -l)"
  check "the tool table has 78 tools" test "$n" -eq 78
  check "the server binary has no database engine inside" bash -c "! strings mcp/fractalsql-druid-mcp | grep -q 'sqlite3_'"
}

gate_13_mcp_locks() {
  local bin=mcp/fractalsql-druid-mcp tmp="$ART/locks"; mkdir -p "$tmp"
  cp mcp/.mcp-schema-lock "$tmp/schema.before"
  (cd mcp && ../$bin --write-schema-lock --schema-lock-path "$tmp/schema.after") >/dev/null 2>&1
  check "the schema lock matches the published tool table" cmp "$tmp/schema.before" "$tmp/schema.after"
  cp mcp/.mcp-safety-annotations-lock "$tmp/safety.before"
  check "the safety-annotations lock is present and non-empty" test -s "$tmp/safety.before"
  check "the manifest lists 78 tools" python3 -c "import json,sys; d=json.load(open('mcp/manifest.json')); n=len(d.get('tools',d)); sys.exit(0 if n==78 else 1)"
}

gate_14_mcp_contract() {
  local checker="$ROOT/../fractalsql-align/fractalsql-align-check.py"
  if [ ! -f "$checker" ]; then skip "the alignment checker is not beside this repository"; return; fi
  check "the MCP surface matches the alignment contract" python3 "$checker" --repo druid
}

gate_15_mcp_protocol() {
  check "MCP protocol (offline): initialize, tools, annotations, schemas" python3 mcp/tests/druid_mcp_offline.py mcp/fractalsql-druid-mcp
}

gate_29_mcp_mock() {
  [ -x mcp/fractalsql-druid-mcp ] || { fail "build the MCP server first (gate 12)"; return; }
  check "MCP against a stand-in Druid: every tool, then each way the engine or its proxy fails" python3 -I mcp/tests/mcp_mock_sweep.py mcp/fractalsql-druid-mcp
  check "MCP over HTTP: credential policy files in every shape, a hot reload, headers and body disagreeing, framing and limits" python3 -I mcp/tests/mcp_http_edges.py mcp/fractalsql-druid-mcp
  check "MCP valid calls: each argument-dependent path in the adapters and the Druid client, against the stand-in Druid" python3 -I mcp/tests/mcp_valid_calls.py mcp/fractalsql-druid-mcp
  check "MCP to a Druid over TLS (certificate not checked, untrusted, trusted), a plain Druid on https, a reset connection, and error replies" python3 -I mcp/tests/mcp_druid_tls.py mcp/fractalsql-druid-mcp
  have cc && check "MCP server under failing socket calls (EINTR, EAGAIN, ECONNRESET, EPIPE, short reads and writes, ...), over HTTP and towards Druid" python3 -I mcp/tests/mcp_syscall_faults.py mcp/fractalsql-druid-mcp
  check "MCP: a DRUID_URL that does not serve /fractalsql (404 or 405) is warned about once; a 500, a separate DRUID_FRACTALSQL_URL and a healthy endpoint are not" python3 -I mcp/tests/druid_service_warning.py mcp/fractalsql-druid-mcp
}

# A daemon that must either start and keep answering, or refuse to start without crashing.
edge_case() { # edge_case LABEL [ENV=VAL...]   (the config is $D/edge.conf)
  local label="$1"; shift
  if daemon_start c "$D/edge.conf" "$@"; then
    local k
    ctl call fractal_ledger_flush i:1 >/dev/null 2>&1
    ctl call fractal_audit_log s:edge 's:{"n":1}' i:1 s:ci >/dev/null 2>&1
    for k in 1 2 3; do ctl call fractal_ledger_verify i:$k >/dev/null 2>&1; done
    ctl call fractal_ledger_truth_count i:1 >/dev/null 2>&1; ctl call fractal_ledger_shadow_count i:1 >/dev/null 2>&1
    ctl call fractal_ledger_load i:1 >/dev/null 2>&1; ctl call fractal_ledger_compact i:1 >/dev/null 2>&1
    check "$label: it starts and keeps answering" ctl ping
  else
    local rc=0; [ -n "$DPID" ] && { wait "$DPID" 2>/dev/null; rc=$?; }; DPID=""
    check "$label: it refuses to start, without crashing" bash -c "[ $rc -lt 128 ] && ! grep -qiE 'segmentation|core dumped' '$D/daemon.log'"
  fi
  daemon_stop
}

gate_30_enterprise_edges() {
  # The enterprise ledger's recovery and the signed library's loading, pushed through the cases a crash, a bad disk or a bad install makes:
  # every kind of malformed head file, a byte changed at many places in the chain, and a library, a signature, a temp directory or a ledger
  # path that is wrong. The daemon either answers afterwards or refuses cleanly; it never crashes.
  [ -f "$ENTLIB" ] || { skip "no enterprise library in include/"; return; }
  mock_start || { fail "mock provider did not start"; return; }
  local i n spec L="$D/edge-ledger.dat"
  daemon_conf "$D/edge.conf" "enterprise_lib = $ENTLIB" "enterprise_ledger_path = $L"
  rm -f "$D"/edge-ledger.dat* "$D"/pristine.*
  daemon_start c "$D/edge.conf" || { fail "daemon did not start (enterprise edges: fresh)"; mock_stop; return; }
  for i in 1 2 3 4 5 6; do ctl call fractal_audit_log s:edge "s:{\"i\":$i}" i:1 s:ci >/dev/null 2>&1; done
  ctl call fractal_ledger_flush i:1 >/dev/null 2>&1
  daemon_stop
  cp "$L" "$D/pristine.dat"; cp "$L.head" "$D/pristine.head" 2>/dev/null
  n="$(python3 service/tests/ledger_damage.py x list)"
  for spec in $(seq -f 'head%g' 0 $((n-1))) flip0 flip4 flip8 flip12 flip16 flip24 flip32 flip48 flip64 flip96 flip128 flip200 flip-1 flip-8 flip-16 flip-33 flip-64 flip-100; do
    rm -f "$L" "$L.head"; cp "$D/pristine.dat" "$L"; [ -f "$D/pristine.head" ] && cp "$D/pristine.head" "$L.head"
    python3 service/tests/ledger_damage.py "$L" "$spec"
    edge_case "enterprise ledger, $spec"
  done
  # the ledger path itself
  mkdir -p "$D/edge-dir"; rm -rf "$D/edge-dir/"*
  daemon_conf "$D/edge.conf" "enterprise_lib = $ENTLIB" "enterprise_ledger_path = $D/edge-dir"; edge_case "a ledger path that is a directory"
  daemon_conf "$D/edge.conf" "enterprise_lib = $ENTLIB" "enterprise_ledger_path = /proc/no/such/ledger.dat"; edge_case "a ledger path in a missing directory"
  daemon_conf "$D/edge.conf" "enterprise_lib = $ENTLIB" "enterprise_ledger_path = $D/$(printf 'x%.0s' $(seq 1 4300)).dat"; edge_case "a ledger path far too long"
  cp "$D/pristine.dat" "$D/edge-open.dat"; chmod 0644 "$D/edge-open.dat"
  daemon_conf "$D/edge.conf" "enterprise_lib = $ENTLIB" "enterprise_ledger_path = $D/edge-open.dat"; edge_case "a ledger file readable by everyone"
  ln -sf "$D/pristine.dat" "$D/edge-link.dat"
  daemon_conf "$D/edge.conf" "enterprise_lib = $ENTLIB" "enterprise_ledger_path = $D/edge-link.dat"; edge_case "a ledger path that is a symbolic link"
  # the library, its signature and the temp directory the verified copy is made in
  local T="$D/lib"; rm -rf "$T"; mkdir -p "$T"
  daemon_conf "$D/edge.conf" "enterprise_lib = $ENTLIB" "enterprise_ledger_path = $D/edge-t.dat"
  edge_case "a missing temp directory" TMPDIR=/nonexistent/dir
  : > "$T/afile"; edge_case "a temp directory that is a file" TMPDIR="$T/afile"
  edge_case "a temp directory that is far too long" TMPDIR="/tmp/$(printf 'd%.0s' $(seq 1 4300))"
  edge_case "a temp directory that is read-only" TMPDIR=/proc
  edge_case "an empty temp directory setting" TMPDIR=
  local bad
  for bad in nosig sigempty sigshort sigzero sigbig sigdir libcut libgarbage libempty; do
    rm -rf "$T/c"; mkdir -p "$T/c"; cp "$ENTLIB" "$T/c/ent.so"; cp "$ENTLIB.sig" "$T/c/ent.so.sig" 2>/dev/null
    case "$bad" in
      nosig)     rm -f "$T/c/ent.so.sig";;
      sigempty)  : > "$T/c/ent.so.sig";;
      sigshort)  head -c 10 /dev/urandom > "$T/c/ent.so.sig";;
      sigzero)   head -c 64 /dev/zero > "$T/c/ent.so.sig";;
      sigbig)    head -c 200000 /dev/urandom > "$T/c/ent.so.sig";;
      sigdir)    rm -f "$T/c/ent.so.sig"; mkdir "$T/c/ent.so.sig";;
      libcut)    head -c 1000 "$ENTLIB" > "$T/c/ent.so";;
      libgarbage) head -c 40000 /dev/urandom > "$T/c/ent.so";;
      libempty)  : > "$T/c/ent.so";;
    esac
    daemon_conf "$D/edge.conf" "enterprise_lib = $T/c/ent.so" "enterprise_ledger_path = $D/edge-t.dat"; edge_case "a signed library gone wrong ($bad)"
  done
  daemon_conf "$D/edge.conf" "enterprise_lib = $T" "enterprise_ledger_path = $D/edge-t.dat"; edge_case "an enterprise library that is a directory"
  daemon_conf "$D/edge.conf" "enterprise_lib = $T/no-such.so" "enterprise_ledger_path = $D/edge-t.dat"; edge_case "an enterprise library that is not there"
  daemon_conf "$D/edge.conf" "enterprise_lib = $D/hmac.key" "enterprise_ledger_path = $D/edge-t.dat"; edge_case "an enterprise library that is a text file"
  # a ledger that cannot grow: the write fails part way (a full disk, a file-size limit), the record is refused, the daemon keeps answering.
  # The limit is a count of 512-byte blocks, set by a wrapper around the daemon; SIGXFSZ is ignored so the failed write is an error, not a signal.
  local sz blk extra
  printf '#!/bin/sh\ntrap "" XFSZ\nulimit -f "$FSQL_WRAP_FSIZE"\nexec "$@"\n' > "$D/fsize-wrap.sh"; chmod 700 "$D/fsize-wrap.sh"
  sz="$(stat -c %s "$D/pristine.dat")"
  for extra in -1 0 1 3; do
    blk=$(( sz / 512 + extra )); [ "$blk" -lt 1 ] && blk=1
    rm -f "$D/edge-full.dat" "$D/edge-full.dat.head"; cp "$D/pristine.dat" "$D/edge-full.dat"; [ -f "$D/pristine.head" ] && cp "$D/pristine.head" "$D/edge-full.dat.head"
    daemon_conf "$D/edge.conf" "enterprise_lib = $ENTLIB" "enterprise_ledger_path = $D/edge-full.dat"
    DAEMON_WRAP="$D/fsize-wrap.sh"; edge_case "a ledger that cannot grow past $blk blocks" FSQL_WRAP_FSIZE="$blk"; DAEMON_WRAP=""
  done
  mock_stop
}

gate_31_enterprise_mock() {
  # The daemon's side of the enterprise seam against a stand-in library (service/tests/mock_enterprise.c): answers the real library never
  # gives (errors, counts out of range, a result that overclaims, a buffer that has to grow) and a library with symbols missing.
  # It loads unsigned, so the signature requirement is switched off for this gate only.
  command -v cc >/dev/null 2>&1 || { skip "no C compiler"; return; }
  mock_start || { fail "mock provider did not start"; return; }
  local M="$D/mockent" spec v flags
  mkdir -p "$M"
  for spec in full: nopf:-DNO_PORTFOLIO noreq:-DNO_REQUIRED; do
    v="${spec%%:*}"; flags="${spec#*:}"
    : > "$M/mode"
    check "build the stand-in enterprise library ($v)" cc -shared -fPIC -O1 $flags -o "$M/$v.so" service/tests/mock_enterprise.c
    daemon_conf "$D/mockent.conf" "enterprise_lib = $M/$v.so" "enterprise_ledger_path = $M/$v-ledger.dat" "enterprise_require_signature = false"
    daemon_start c "$D/mockent.conf" FSQL_MOCK_ENT_MODE="$M/mode" || { fail "daemon did not start (stand-in enterprise library: $v)"; daemon_stop; continue; }
    check "the enterprise seam against the stand-in library ($v)" python3 service/tests/enterprise_mock.py "$D/d.sock" "$D/hmac.key" "$M/mode" "$v"
    check "the daemon still answers ($v)" ctl ping
    daemon_stop
  done
  mock_stop
}

# ---------------------------------------------------------------------------------------------
# The hardening gate: the binaries this repository builds carry the standard
# hardening flags (see service/Makefile and mcp/Makefile), and the gate
# checks the produced binaries rather than the flags on the command line.
# ---------------------------------------------------------------------------------------------

# hardening_report LABEL FILE: print the hardening properties of one ELF file. Used for the
# binaries that are REPORTED, not checked (the prebuilt ones in include/, which are not built here).
hardening_report() {
  local label="$1" f="$2"
  [ -f "$f" ] || { echo "    $label: not present"; return; }
  local pie="no" relro="no" canary="no" nx="yes" fortify=0
  readelf -h "$f" 2>/dev/null | grep -q 'Type:.*DYN' && pie="yes"
  readelf -lW "$f" 2>/dev/null | grep -q GNU_RELRO && relro="yes"
  readelf -dW "$f" 2>/dev/null | grep -qE 'BIND_NOW|FLAGS.*NOW' && relro="full"
  readelf -sW "$f" 2>/dev/null | grep -q '__stack_chk_fail' && canary="yes"
  readelf -lW "$f" 2>/dev/null | grep 'GNU_STACK' | grep -qE 'RWE' && nx="no"
  fortify="$(readelf -sW "$f" 2>/dev/null | grep -cE '__[a-z0-9_]+_chk')"
  echo "    $label: pie=$pie relro=$relro stack_canary=$canary non_exec_stack=$nx fortify_symbols=$fortify"
}

# hardening_check LABEL FILE KIND: check one binary we build here. KIND is exec or so.
# A shared object is not a position independent executable, so PIE is not required of it.
hardening_check() {
  local label="$1" f="$2" kind="$3"
  if [ "$(uname -s)" = Darwin ]; then
    check "$label: position independent" bash -c "otool -hv '$f' | grep -q PIE"
    return 0
  fi
  have readelf || { skip "readelf is not installed (the hardening gate needs it)"; return; }
  [ -f "$f" ] || { skip "$label is not built"; return; }
  if [ "$kind" = exec ]; then
    check "$label: position independent executable" bash -c "readelf -h '$f' | grep -q 'Type:.*DYN'"
  fi
  check "$label: full RELRO" bash -c "readelf -lW '$f' | grep -q GNU_RELRO && readelf -dW '$f' | grep -qE 'BIND_NOW|FLAGS.*NOW'"
  check "$label: a stack canary" bash -c "readelf -sW '$f' 2>/dev/null | grep -q '__stack_chk_fail'"
  check "$label: a non-executable stack" bash -c "! readelf -lW '$f' | grep 'GNU_STACK' | grep -qE 'RWE'"
  # A fortified call: a binary that makes no fortifiable call may legitimately have none.
  # The exemption list is explicit, and each entry says why.
  case "$label" in
    "fsqlctl") check "$label: a fortified call" bash -c "readelf -sW '$f' 2>/dev/null | grep -qE '__[a-z0-9_]+_chk'";;
    *)         check "$label: a fortified call" bash -c "readelf -sW '$f' 2>/dev/null | grep -qE '__[a-z0-9_]+_chk'";;
  esac
}

hardening_objects_check() {
  local dir="$1" o
  have readelf || return 0
  [ -f "$dir/fractalsqld.o" ] || { skip "fractalsqld's own objects are not built"; return; }
  check "fractalsqld's own objects: a stack canary" bash -c "readelf -sW '$dir/fractalsqld.o' 2>/dev/null | grep -q '__stack_chk_fail'"
  check "fractalsqld's own objects: a fortified call" bash -c "readelf -sW '$dir/fractalsqld.o' 2>/dev/null | grep -qE '__[a-z0-9_]+_chk'"
  check "the adapter's own objects: a stack canary and a fortified call" bash -c "c=0; f=0; for o in '$dir'/fractalsql*.o; do s=\$(readelf -sW \"\$o\" 2>/dev/null); echo \"\$s\" | grep -q '__stack_chk_fail' && c=1; echo \"\$s\" | grep -qE '__[a-z0-9_]+_chk' && f=1; done; [ \$c = 1 ] && [ \$f = 1 ]"
}

gate_32_hardening() {
  # The daemon, its command-line client, the JNI library and the MCP server are built with the
  # standard hardening flags. This gate reads the binaries themselves, so a flag that was
  # dropped from a Makefile, or a toolchain that dropped it, is caught.
  # It says nothing about the sanitizer builds: their flags differ by design.
  if [ -n "$SAN" ] || [ "$COV" = 1 ]; then skip "the hardening gate does not apply to an instrumented build"; return; fi
  have readelf || { skip "readelf is not installed"; return; }
  hardening_check "fractalsqld" "$FSQLD_C" exec
  # The linked daemon also carries the vendored core archive, which has its own canary and fortified calls, so the
  # checks above cannot tell whether THIS repository's flags reached the daemon's own code. These read the daemon's
  # own object files (before the link): a Makefile that dropped the flags fails here even though the core hides it.
  hardening_objects_check "$ROOT/service/build/daemon"
  hardening_check "fsqlctl" "$FSQLCTL" exec
  hardening_check "libfsqld_jni.so" "$FSQLD_JNI" so
  hardening_check "fractalsql-druid-mcp" "$ROOT/mcp/fractalsql-druid-mcp" exec
  # The prebuilt binaries in include/ are not built here: they are reported, never failed on.
  local plat p f
  plat="$(host_platform)"
  echo "    the prebuilt payloads in include/$plat (reported, not built here):"
  for f in "$ROOT"/include/$plat/*.so; do
    [ -f "$f" ] || continue
    hardening_report "$(basename "$f")" "$f"
  done
  # the vendored core archives are not executables; they carry no ELF program headers to read
  for f in "$ROOT"/include/$plat/*.a; do
    [ -f "$f" ] || continue
    echo "    $(basename "$f"): an archive (not an ELF object with program headers)"
  done
}

gate_33_analysis() {
  # The static analysis of the C sources, against the accepted findings.
  # The same work as the --analyze mode, in the default run; the mode
  # exists for a run that only wants this.
  if [ -n "$SAN" ] || [ "$COV" = 1 ]; then skip "the analysis gate does not apply to an instrumented build"; return; fi
  have gcc && have clang-tidy || { skip "gcc and clang-tidy are needed for the analysis gate"; return; }
  mode_analyze "$ART/analyze"
}

gate_35_stress() {
  # Concurrent, mixed use of the daemon: many threads on many
  # connections, the configuration overlay, the session tier, connection
  # churn, a reload in the middle, and (with the enterprise library) the
  # audit chain -- with the answers checked, not just the absence of a
  # crash.
  # Under a sanitizer the run is slower, so it is shorter: the point of the
  # sanitizer run is the race reports, not the length of the run.
  local kind secs="${FSQL_STRESS_SECONDS:-60}"
  [ -n "$SAN" ] && secs="${FSQL_STRESS_SECONDS_SAN:-25}"
  for kind in $KINDS; do
    daemon_conf "$D/stress.conf"
    local ent=()
    if [ -f "$ENTLIB" ]; then
      rm -f "$D"/stress-ledger.dat*
      daemon_conf "$D/stress.conf" "enterprise_lib = $ENTLIB" "enterprise_ledger_path = $D/stress-ledger.dat"
      ent=("enterprise")
    fi
    if daemon_start "$kind" "$D/stress.conf" "FSQL_REASONING_HTTP_TIMEOUT_MS=10000"; then
      check "$kind daemon: concurrent, mixed use, with the answers checked" \
        env FSQLCTL_BIN="$FSQLCTL" python3 service/tests/stress.py "$D/d.sock" "$D/hmac.key" "${ent[@]}" "$secs"
    else fail "$kind daemon did not start (stress)"; fi
    daemon_stop
  done
}

gate_36_ledger_crash() {
  # The daemon killed while it writes to the ledger: the chain must still
  # be sound afterwards, and the acknowledged writes must still be in it.
  # The stand-in enterprise library is used, so this runs without the
  # licensed one.
  have cc || { skip "no C compiler (the stand-in enterprise library cannot be built)"; return; }
  local iters="${FSQL_LEDGER_CRASH_ITERS:-40}" M="$D/crash-ent"
  mkdir -p "$M"
  daemon_conf "$D/crash.conf"   # this is what creates the key file the script needs
  check "build the stand-in enterprise library" cc -shared -fPIC -O1 -o "$M/ent.so" service/tests/mock_enterprise.c
  [ -x "$M/ent.so" ] || { fail "the stand-in enterprise library did not build"; return; }
  local conf="$D/crash.conf" sock="$D/crash.sock"
  check "the daemon is killed while it writes: the chain stays sound" \
    python3 service/tests/ledger_crash.py "$FSQLD_C" "$conf" "$D/hmac.key" "$M/ent.so" "$iters" "${FSQL_LEDGER_CRASH_SEED:-20261116}"
}

gate_37_ledger_variants() {
  # The crashes gate 36 does not cover: SIGTERM, two connections appending at once, the other ledger operations
  # (flush, compact, reset) interleaved with appends, and a file-size limit that cuts a write short. The same
  # contract after the restart: the chain verifies, the acknowledged writes are in it, a new append works.
  have cc || { skip "no C compiler (the stand-in enterprise library cannot be built)"; return; }
  local M="$D/variants-ent"
  mkdir -p "$M"
  daemon_conf "$D/variants.conf"   # this is what creates the key file the script needs
  check "build the stand-in enterprise library" cc -shared -fPIC -O1 -o "$M/ent.so" service/tests/mock_enterprise.c
  [ -x "$M/ent.so" ] || { fail "the stand-in enterprise library did not build"; return; }
  check "the daemon under SIGTERM, two writers, the other ledger operations and a file-size limit: the chain stays sound" \
    python3 service/tests/ledger_variants.py "$FSQLD_C" "$D/hmac.key" "$M/ent.so" "${FSQL_LEDGER_VARIANT_ITERS:-5}" "${FSQL_LEDGER_CRASH_SEED:-20261116}"
}

gate_38_ledger_fsync() {
  # A SIGKILL does not lose the page cache, so gate 36 cannot see a missing fsync. This runs the daemon with a shim
  # that records every fsync/fdatasync, and checks that each acknowledged audit write was preceded by one.
  have cc || { skip "no C compiler"; return; }
  local M="$D/fsync-ent"
  mkdir -p "$M"
  daemon_conf "$D/fsync.conf"
  check "build the stand-in enterprise library and the fsync shim" bash -c "cc -shared -fPIC -O1 -o '$M/ent.so' service/tests/mock_enterprise.c && cc -shared -fPIC -O1 -o '$M/fsync_count.so' service/tests/fsync_count.c -ldl"
  [ -x "$M/ent.so" ] && [ -x "$M/fsync_count.so" ] || { fail "the stand-in library or the shim did not build"; return; }
  check "each acknowledged ledger write is synced before it is answered" \
    python3 service/tests/ledger_fsync.py "$FSQLD_C" "$D/fsync.conf" "$D/hmac.key" "$M/ent.so" "$M/fsync_count.so" "${FSQL_LEDGER_FSYNC_CALLS:-30}"
}

gate_39_mcp_cli() {
  # The MCP server started in every way its command line, environment and Druid connection allow (one-shot flags and
  # working directories, the lock checks, the tuning knobs, --http/--https settings, an unusable Druid): it must always end
  # in order. Against a stand-in Druid, so no cluster is needed. About 30 s.
  [ -x mcp/fractalsql-druid-mcp ] || { fail "build the MCP server first (gate 12)"; return; }
  check "MCP command line, environment and Druid settings: the server always ends in order" \
    env MCP_SERVER_EXE="$PWD/mcp/fractalsql-druid-mcp" MCP_HERE="$PWD/mcp" python3 -I mcp/tests/mcp_cli.py
}

gate_43_analyze_java() {
  # SpotBugs with the find-sec-bugs rules over the extension, against the accepted findings (tests/analysis/baseline-java.txt).
  # On demand (--gate 43), not in the default set: the plugins are downloaded on first use, so it needs network or a warm
  # ~/.m2. A finding not in the baseline fails. It reads bytecode, so it does not see SQL built by concatenation and sent to
  # Druid over HTTP (SECURITY_AUDIT.md 3.5): that is covered by AgentFilterAndCoreTest.
  have mvn || { skip "mvn is not installed"; return; }
  local plat; plat="$(host_platform)"
  check "spotbugs + find-sec-bugs run over the extension" \
    bash -c "cd druid-extension && $NICE mvn -q -Dfsql.platform=$plat -DskipTests compile com.github.spotbugs:spotbugs-maven-plugin:4.8.6.0:spotbugs -Dspotbugs.plugins=com.h3xstream.findsecbugs:findsecbugs-plugin:1.13.0 -Dspotbugs.effort=Max -Dspotbugs.threshold=Medium -Dspotbugs.xmlOutput=true"
  check "no finding beyond the accepted ones" python3 tests/analysis/spotbugs_check.py druid-extension/target/spotbugsXml.xml tests/analysis/baseline-java.txt
}

gate_42_mcp_audit() {
  # SECURITY_AUDIT.md findings in the MCP server: the vector format's dimension limit (unit probe on src/db.h), the numeric
  # bound and the endless Druid answer (stdio, against the stand-in), . The HTTP transport's own findings (origin check,
  # repeated headers, context cap, cancel bookkeeping, /readyz caching) are in mcp_http_edges.py's audit_regressions, run by the
  # MCP-over-HTTP gate. About 15 s.
  [ -x mcp/fractalsql-druid-mcp ] || { fail "build the MCP server first (gate 12)"; return; }
  have g++ || { skip "g++ is needed for the vecform probe"; return; }
  mkdir -p "$D"
  g++ -std=c++17 -O1 -Wall -Wextra -I mcp/src mcp/tests/vecform_probe.cpp -o "$D/vecform_probe" -lssl -lcrypto -lpthread 2>"$D/vecform.build" \
    || { fail "the vecform probe did not build"; cat "$D/vecform.build"; return; }
  check "the vector format refuses a vector over its 16-bit dimension" "$D/vecform_probe"
  check "the MCP server holds the numeric-bound and Druid-response limits" python3 -I mcp/tests/mcp_audit_limits.py "$PWD/mcp/fractalsql-druid-mcp"
}

gate_40_jni_sanitizers() {
  # The JNI shim built with AddressSanitizer and with UndefinedBehaviorSanitizer (a test build in a scratch directory;
  # the packaged shim is not touched), with the extension's native tests run against it. What this covers: the shim's own
  # code and the buffers it allocates. What it cannot see: the vendored core is not instrumented, and a read by the core
  # of a Java array is not a read the sanitizer tracks, so the length checks in the shim are guarded by NativeBoundsTest
  # (gate 11 runs it too), not by this cell.
  if ! have mvn || ! have cc; then skip "mvn and cc are needed for the JNI sanitizer cell"; return; fi
  local plat; plat="$(host_platform)"
  case "$plat" in linux-*) ;; *) skip "the JNI sanitizer cell is Linux only"; return;; esac
  local san rt out
  for san in address undefined; do
    out="$D/jni-$san"; mkdir -p "$out"
    case "$san" in address) rt="$(cc -print-file-name=libasan.so)";; undefined) rt="$(cc -print-file-name=libubsan.so)";; esac
    [ -f "$rt" ] || { skip "no $san runtime for the JNI cell ($rt)"; continue; }
    check "build the JNI shim with -fsanitize=$san" env FSQL_JNI_SAN="$san" FSQL_JNI_OUT="$out" sh druid-extension/src/main/native/build-native-linux.sh "$plat"
    check "the extension's native tests under $san" bash -c "cd druid-extension && LD_PRELOAD='$rt' ASAN_OPTIONS=detect_leaks=0 UBSAN_OPTIONS=halt_on_error=1:print_stacktrace=1 $NICE mvn -q test -Dtest='NativeBoundsTest,NativeBridgeTest,FractalExprSweepTest' -Dfsql.platform=$plat -DargLine='-Dfsql.native.path=$out'"
  done
}

gate_34_rss_growth() {
  # A daemon that runs for months must not grow. The same call mix is run
  # in a loop and the daemon's resident size is sampled after every pass;
  # the first two passes are warm-up and are not counted, and the growth
  # across the rest must stay under the bound.
  #
  # The bound is FSQL_RSS_GROWTH_KB (kilobytes, default 512 for the C daemon)
  # and FSQL_RSS_GROWTH_KB_JVM (default 2048 for the JVM daemon, whose heap
  # moves in larger steps). The C daemon's observed growth after the warm-up
  # is 0 kB (it settles on a plateau within the first passes), so 512 kB is
  # headroom for a busy machine; over the ten counted passes of 740 calls it
  # still catches a leak of roughly 70 bytes per call that touches its memory.
  # The JVM daemon's heap is reported too; the assertion is on the process's
  # resident size.
  local passes warm bound kind i rss first last
  for kind in $KINDS; do
    daemon_conf "$D/rss.conf"
    # The JVM daemon is given a bounded heap, so that what the check
    # measures is the daemon's own growth and not the JVM deciding how
    # much heap to keep.
    local jopt=()
    [ "$kind" = jvm ] && jopt=("JAVA_TOOL_OPTIONS=-Xmx96m -Xms32m")
    if ! daemon_start "$kind" "$D/rss.conf" "${jopt[@]}"; then fail "$kind daemon did not start (resident size)"; continue; fi
    bound="${FSQL_RSS_GROWTH_KB:-512}"; passes="${FSQL_RSS_PASSES:-12}"; warm=3
    # The JVM daemon's resident size is flat for the first eleven passes and then steps up by about 40 MB at the twelfth
    # (the JIT compiler tiers up the hot methods; the step is at the same pass on every run) and stays flat afterwards
    # (0.5 MB over the next eighteen). Warming it up for fifteen passes puts the step before the measurement.
    if [ "$kind" = jvm ]; then bound="${FSQL_RSS_GROWTH_KB_JVM:-2048}"; passes="${FSQL_RSS_PASSES_JVM:-30}"; warm=16; fi
    first=0; last=0; local samples="" heap=""
    local mixrc=0
    for i in $(seq 1 "$passes"); do
      python3 service/tests/rss_mix.py "$D/d.sock" "$D/hmac.key" >"$D/rss-mix.out" 2>&1 || mixrc=$?
      rss="$(awk '/^VmRSS:/{print $2}' "/proc/$DPID/status" 2>/dev/null)"
      [ -z "$rss" ] && break
      samples="$samples $rss"
      if [ "$i" = "$warm" ]; then first="$rss"; fi
      last="$rss"
    done
    # The JVM daemon's heap, while it is still running: the assertion
    # below is on the process's resident size, but the heap is what
    # explains it.
    if [ "$kind" = jvm ] && have jcmd; then
      heap="$(jcmd "$DPID" GC.heap_info 2>/dev/null | tr '\n' ' ' | cut -c1-200)"
    fi
    daemon_stop
    if [ "$mixrc" -ne 0 ]; then
      fail "$kind daemon: the call mix did not run (the measurement would be meaningless)"
      sed 's/^/      /' "$D/rss-mix.out" | tail -5
      continue
    fi
    if [ -z "$first" ]; then fail "$kind daemon: the resident size could not be sampled"; continue; fi
    # The mix must have DONE its calls: a mix that exits 0 having made none (or having had every call refused) measures the
    # absence of work, and a flat resident size then proves nothing.
    local mixcalls mixerrs
    mixcalls="$(sed -n 's/^\([0-9][0-9]*\) call(s), .*/\1/p' "$D/rss-mix.out" | tail -1)"
    mixerrs="$(sed -n 's/^[0-9][0-9]* call(s), \([0-9][0-9]*\) error(s)/\1/p' "$D/rss-mix.out" | tail -1)"
    echo "    $kind daemon: the last pass made ${mixcalls:-0} call(s), ${mixerrs:-?} error(s)"
    if [ "${mixcalls:-0}" -lt 100 ] || [ "${mixerrs:-1}" -ne 0 ]; then
      fail "$kind daemon: the call mix did not do its work (${mixcalls:-0} call(s), ${mixerrs:-?} error(s))"
      continue
    fi
    echo "    $kind daemon resident size after each pass (kB):$samples"
    [ -n "$heap" ] && echo "    $kind daemon heap (jcmd): $heap"
    echo "    $kind daemon: growth after the warm-up: $((last - first)) kB (the bound is $bound kB)"
    if [ "$((last - first))" -gt "$bound" ]; then
      fail "$kind daemon: the resident size grew by $((last - first)) kB over the passes (the bound is $bound kB)"
    else
      pass "$kind daemon: the resident size does not grow over the passes"
    fi
  done
}


# ---------------------------------------------------------------------------------------------
# The Druid stack (Docker)
# ---------------------------------------------------------------------------------------------
STACK_UP=""
# FSQL_COMPOSE_OVERRIDE=FILE adds a compose override (to stage the licensed enterprise library from outside the repository, for gates 26 and 27)
COMPOSE="docker compose -p fsqld-test -f docker/docker-compose.yml ${FSQL_COMPOSE_OVERRIDE:+-f $FSQL_COMPOSE_OVERRIDE} ${FSQL_COV_OVERRIDE:+-f $FSQL_COV_OVERRIDE} --profile test"
export DRUID_URL="${DRUID_URL:-http://127.0.0.1:8888}"
export DRUID_FRACTALSQL_URL="${DRUID_FRACTALSQL_URL:-http://127.0.0.1:8082}"

# Under coverage the Druid services carry the JaCoCo agent, which writes its data when the JVM exits: stop them gently first.
stack_down() { [ -n "${FSQL_COV_OVERRIDE:-}" ] && $COMPOSE --profile multihost stop -t 90 >/dev/null 2>&1
  $COMPOSE --profile multihost down -v >/dev/null 2>&1; STACK_UP=""; }

# A stack started by an earlier run (or by hand) counts: the gates only need it to answer.
need_stack() {
  [ -n "$STACK_UP" ] && return 0
  if curl -sf -m 3 "$DRUID_FRACTALSQL_URL/fractalsql/health" >/dev/null 2>&1; then STACK_UP=0; return 0; fi
  return 1
}

stack_ready() {
  for _ in $(seq 1 90); do
    curl -sf -m 3 "$DRUID_FRACTALSQL_URL/fractalsql/health" >/dev/null 2>&1 && \
    curl -sf -m 3 -X POST -H 'Content-Type: application/json' -d '{"query":"SELECT 1"}' "$DRUID_URL/druid/v2/sql" >/dev/null 2>&1 && return 0
    sleep 3
  done
  return 1
}

gate_16_think() {
  # Reasoning effort: each setting of think / think_provider, checked against the request the provider receives, for both daemons.
  # The settings are daemon config keys, so each variant is a daemon start.
  mock_start || { fail "mock provider did not start"; return; }
  local kind v lines
  for kind in $KINDS; do for v in unset none medium off ollama anthropic vllm grok; do
    case "$v" in
      unset)     lines=();;
      none)      lines=("think = none");;
      medium)    lines=("think = medium");;
      off)       lines=("think = off");;
      ollama)    lines=("think = high" "think_provider = ollama" "think_num_ctx = 8192");;
      anthropic) lines=("think = high" "think_provider = anthropic");;
      vllm)      lines=("think = low" "think_provider = vllm");;
      grok)      lines=("think = low" "think_provider = grok");;
    esac
    daemon_conf "$D/think.conf" "${lines[@]}"
    : > "$ART/mock.log"
    if daemon_start "$kind" "$D/think.conf"; then
      check "$kind daemon, think $v" python3 service/tests/think.py "$D/d.sock" "$D/hmac.key" "$ART/mock.log" "$v"
    else fail "$kind daemon did not start (think $v)"; fi
    daemon_stop
  done; done
  # a bad value is refused at start, and a reload applies a new one
  daemon_conf "$D/think-bad.conf" "think_num_ctx = -5"
  expect_fail "a negative think_num_ctx is refused at start" timeout 5 "$FSQLD_C" -c "$D/think-bad.conf"
  mock_stop
}

gate_17_calls_all() {
  # Every function in the registry, with ordinary and junk arguments, on both daemons: errors are fine, a crash is not.
  mock_start || { fail "mock provider did not start"; return; }
  local kind
  for kind in $KINDS; do
    daemon_conf "$D/calls.conf"
    if daemon_start "$kind" "$D/calls.conf" "FSQL_REASONING_HTTP_TIMEOUT_MS=5000"; then
      check "$kind daemon: every registry function survives ordinary and junk arguments" python3 service/tests/calls_all.py "$D/d.sock" "$D/hmac.key" service/protocol/functions.def
    else fail "$kind daemon did not start"; fi
    daemon_stop
  done
  mock_stop
}

gate_18_workout() {
  # Every function used the way its documentation says, on both daemons: the working paths, not only the refusals. The enterprise
  # library, when it is here, is loaded for the second half, with each audit-redaction mode in turn.
  #
  # The systematic sweep (workout.py's FSQL_WORKOUT_SWEEP) is off by default: measured uninstrumented, it adds about 200 s to this
  # gate and raises branch coverage by about 1.3 points. Its value is finding memory errors, so it runs under the sanitizers
  # (--asan, --ubsan), where the run is already slow and the extra coverage is what the sanitizer needs to see. The cap is the
  # number of calls of the same shape the sweep makes; 2 is enough to reach every boundary of every shape without the gate
  # running for ten minutes.
  local sweep=""
  case "$SAN" in asan|ubsan) sweep="FSQL_WORKOUT_SWEEP=${FSQL_WORKOUT_SWEEP:-1}";; esac
  mock_start || { fail "mock provider did not start"; return; }
  local kind mode mut emut
  for kind in $KINDS; do
    mut="${FSQL_WORKOUT_MUTATIONS:-30}"; [ "$kind" = jvm ] && mut="${FSQL_WORKOUT_MUTATIONS_JVM:-8}"   # the JVM daemon is slower per call; its adapter is the same C code
    # The enterprise phase runs the same mutation count as the main workout unless FSQL_WORKOUT_MUTATIONS_ENTERPRISE says
    # otherwise: every acknowledged audit write fsyncs, so on a filesystem where fsync is slow, lower it here (not in the default).
    emut="${FSQL_WORKOUT_MUTATIONS_ENTERPRISE:-$mut}"
    daemon_conf "$D/work.conf"
    if daemon_start "$kind" "$D/work.conf" "FSQL_REASONING_HTTP_TIMEOUT_MS=5000"; then
      check "$kind daemon: the registry, used as documented" env FSQL_WORKOUT_MUTATIONS=$mut $sweep python3 service/tests/workout.py "$D/d.sock" "$D/hmac.key"
      # The fuzz corpus, replayed through the live daemon: the in-process
      # harness sees one call per input, and this sees the state the daemon
      # keeps between them. It runs under the sanitizers, where the sweep
      # runs too.
      if [ -n "$sweep" ]; then
        check "$kind daemon: the fuzz corpus, replayed through the daemon" python3 service/tests/fuzz_corpus_replay.py "$D/d.sock" "$D/hmac.key" tests/fuzz/corpus_svc_udf
      fi
    else fail "$kind daemon did not start (workout)"; fi
    daemon_stop
    [ -f "$ENTLIB" ] || continue
    for mode in none hash truncate; do
      daemon_conf "$D/work-e.conf" "enterprise_lib = $ENTLIB" "enterprise_ledger_path = $D/work-ledger.dat"
      rm -f "$D"/work-ledger.dat*
      if daemon_start "$kind" "$D/work-e.conf" "FSQL_REASONING_HTTP_TIMEOUT_MS=5000" "FSQL_AUDIT_REDACT=$mode"; then
        # The enterprise phase's mutations are the expensive ones: every
        # acknowledged audit write fsyncs, so this phase's wall clock is
        # set by its mutation count. The argument fuzzing is the first
        # workout's job; this one checks that the ledger and the audit
        # trail work.
        check "$kind daemon, enterprise, audit redaction $mode: ledger and audit work" env FSQL_WORKOUT_MUTATIONS="$emut" python3 service/tests/workout.py "$D/d.sock" "$D/hmac.key" enterprise
      else fail "$kind daemon did not start (workout, enterprise, $mode)"; fi
      daemon_stop
    done
  done
  # configuration files and boot environments of every odd kind: a daemon refuses what it must and never crashes
  local n=0 line
  while IFS= read -r line; do
    n=$((n+1)); daemon_conf "$D/cfg-$n.conf"
    printf '%b\n' "$line" >> "$D/cfg-$n.conf"
    check "config variant $n: the daemon starts or refuses, without a crash" bash -c "timeout 0.8 '$FSQLD_C' -c '$D/cfg-$n.conf' >'$D/cfg-$n.log' 2>&1; rc=\$?; [ \$rc -ne 134 ] && [ \$rc -ne 139 ] && [ \$rc -ne 136 ]"
  done <<'CFG'
# only a comment
   indented = 1
no_equals_sign_here
=novalue
key_only =
max_connections = 0
max_connections = 99999999999
max_connections = -1
max_connections = abc
idle_timeout_secs = 0
idle_timeout_secs = -5
allowed_uids = 1,2,3,x
allowed_uids =
allowed_uids = 99999999999999
think = high
think = bogus
think_provider = nope
think_native_url = not a url
think_native_url = http://127.0.0.1:1/x
think_num_ctx = 0
think_num_ctx = 99999999999
reasoning_plugin = /nonexistent/plugin.so
reasoning_plugin = ../x.so
reasoning_plugin =
reasoning_url = ftp://x
reasoning_allow_plaintext = maybe
embed_url = http://127.0.0.1:1/e
enterprise_lib = /nonexistent/e.so
enterprise_ledger_path = relative/path
enterprise_ledger_path = /nonexistent-dir/l.dat
unknown_key = 1
socket_path =
hmac_key_file = /nonexistent/key
log_level = verbose
a = b\nc = d\ne = f\n\n\n
key = value with trailing spaces   
key=value=with=equals
long_key_aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa = 1
CFG
  # the text-to-SQL defaults from the boot environment
  local e
  for e in "FRACTALSQL_TEXT_TO_SQL_ALLOWED_STATEMENTS=select_insert_update" "FRACTALSQL_TEXT_TO_SQL_ALLOWED_STATEMENTS=bogus" \
           "FRACTALSQL_TEXT_TO_SQL_MAX_ATTEMPTS=5" "FRACTALSQL_TEXT_TO_SQL_MAX_ATTEMPTS=0" "FRACTALSQL_TEXT_TO_SQL_MAX_ATTEMPTS=abc" \
           "FRACTALSQL_TEXT_TO_SQL_USE_REVIEW=1" "FRACTALSQL_TEXT_TO_SQL_USE_REVIEW=false" "FRACTALSQL_TEXT_TO_SQL_USE_REVIEW=maybe"; do
    daemon_conf "$D/env.conf"
    if daemon_start c "$D/env.conf" "$e"; then
      ctl call fractal_t2s_config >/dev/null 2>&1; ctl call fractal_t2s_check_allowlist "s:INSERT INTO t VALUES (1)" >/dev/null 2>&1
      check "boot environment $e: the daemon answers" ctl ping
    else fail "daemon did not start ($e)"; fi
    daemon_stop
  done
  # a ledger damaged the way a crash or a bad disk would: the daemon starts, says what is wrong, and never crashes
  if [ -f "$ENTLIB" ]; then
    local v
    for v in 0 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17; do
      daemon_conf "$D/dmg.conf" "enterprise_lib = $ENTLIB" "enterprise_ledger_path = $D/dmg-ledger.dat"
      rm -f "$D"/dmg-ledger.dat*
      daemon_start c "$D/dmg.conf" || { fail "daemon did not start (ledger damage $v: fresh)"; continue; }
      local i; for i in 1 2 3 4 5; do ctl call fractal_audit_log s:damage "s:{\"i\":$i}" i:1 s:ci >/dev/null 2>&1; done
      ctl call fractal_ledger_flush i:1 >/dev/null 2>&1
      daemon_stop
      python3 service/tests/ledger_damage.py "$D/dmg-ledger.dat" "$v"
      if daemon_start c "$D/dmg.conf"; then
        ctl call fractal_ledger_verify i:1 >/dev/null 2>&1; ctl call fractal_ledger_truth_count i:1 >/dev/null 2>&1
        ctl call fractal_audit_log s:after s:'{"n":1}' i:1 s:ci >/dev/null 2>&1; ctl call fractal_ledger_flush i:1 >/dev/null 2>&1
        ctl call fractal_ledger_load i:1 >/dev/null 2>&1; ctl call fractal_ledger_compact i:1 >/dev/null 2>&1
        check "enterprise daemon, ledger damaged (kind $v): it starts and keeps answering" ctl ping
      else check "enterprise daemon, ledger damaged (kind $v): it refuses to start, without crashing" bash -c "! grep -qiE 'segmentation|core dumped' '$D/daemon.log'"; fi
      daemon_stop
    done
  fi
  mock_stop
}

gate_19_oom() {
  # Allocation failures at random while the registry is used: errors are fine, a crash or a wedged daemon is not. The C daemon only
  # (a JVM has its own memory discipline), and not under a sanitizer or valgrind, which interpose on malloc themselves.
  [ -n "$SAN" ] || [ -n "$VG" ] && { skip "allocation-failure injection does not mix with a sanitizer or valgrind"; return; }
  have gcc || { skip "gcc is not installed"; return; }
  mkdir -p "$D"
  gcc -shared -fPIC -O1 -o "$D/oom.so" service/tests/oom_preload.c -ldl 2>"$D/oom.build" || { fail "the allocation-failure shim did not build"; cat "$D/oom.build"; return; }
  mock_start || { fail "mock provider did not start"; return; }
  local seed ent
  for ent in "" "$ENTLIB"; do
    [ -n "$ent" ] && ! [ -f "$ent" ] && continue
    for seed in 1 2 3; do
      if [ -n "$ent" ]; then daemon_conf "$D/oom.conf" "enterprise_lib = $ent" "enterprise_ledger_path = $D/oom-ledger.dat"; rm -f "$D"/oom-ledger.dat*
      else daemon_conf "$D/oom.conf"; fi
      if daemon_start c "$D/oom.conf" "LD_PRELOAD=$D/oom.so" "FSQL_OOM_SEED=$seed" "FSQL_OOM_PERMILLE=8" "FSQL_OOM_AFTER=3000" "FSQL_REASONING_HTTP_TIMEOUT_MS=3000"; then
        FSQL_OOM=1 timeout 240 python3 service/tests/workout.py "$D/d.sock" "$D/hmac.key" ${ent:+enterprise} >"$D/oom.out" 2>&1
        kill -USR2 "$DPID" 2>/dev/null; sleep 0.5
        check "allocation failures, seed $seed${ent:+, enterprise}: the daemon survives and answers afterwards" ctl ping
      else fail "daemon did not start (allocation failures, seed $seed)"; fi
      daemon_stop
    done
  done
  mock_stop
}

gate_44_jni_tsan() {
  # The JNI shim built with ThreadSanitizer and driven from eight threads (tests/tsan/ShimStress.java). On demand (--gate 44): a JVM under
  # TSan needs the fixed address layout (setarch -R, with LD_PRELOAD set inside it), -Xint -Xrs and a serial GC, and runs slowly.
  # Only the shim is instrumented; the vendored core is not, so a race inside the core is not seen. A TSan report fails the gate.
  have java && have javac && have mvn && have cc || { skip "java, javac, mvn and cc are needed"; return; }
  local plat; plat="$(host_platform)"
  case "$plat" in linux-*) ;; *) skip "the JNI TSan cell is Linux only"; return;; esac
  have setarch || { skip "setarch is needed for the fixed address layout"; return; }
  local rt out="$D/jni-thread" cls="$D/jni-thread-classes"
  rt="$(cc -print-file-name=libtsan.so)"; [ -f "$rt" ] || { skip "no TSan runtime ($rt)"; return; }
  mkdir -p "$out" "$cls"
  check "build the JNI shim with -fsanitize=thread" env FSQL_JNI_SAN=thread FSQL_JNI_OUT="$out" sh druid-extension/src/main/native/build-native-linux.sh "$plat"
  check "compile the extension classes" bash -c "cd druid-extension && $NICE mvn -q -o -Dfsql.platform=$plat -DskipTests compile"
  check "compile the stress driver" javac -cp druid-extension/target/classes -d "$cls" tests/tsan/ShimStress.java
  local log="$D/jni-tsan.log"
  setarch "$(uname -m)" -R env LD_PRELOAD="$rt" TSAN_OPTIONS="halt_on_error=0:report_signal_unsafe=0:ignore_noninstrumented_modules=1" \
    timeout 600 java -Xint -Xrs -XX:+UseSerialGC -Dfsql.native.path="$out" -cp "druid-extension/target/classes:$cls" ShimStress >"$log" 2>&1
  if grep -q "shim stress done" "$log" && ! grep -q "WARNING: ThreadSanitizer" "$log"; then pass "the shim under ThreadSanitizer, eight threads: no data race reported"
  else grep -E "WARNING: ThreadSanitizer|FATAL" "$log" | head -5; fail "the TSan run did not finish clean (see $log)"; fi
}

gate_41_frame_auth() {
  # SECURITY_AUDIT.md 3.1 and 3.22. Authenticating a frame allocates nothing: with the allocation of one chosen size failed
  # deterministically (the size the daemon once allocated for it), a forged all-zero-tag frame is still refused.
  # And a key shorter than 16 bytes is not accepted at start-up. The C daemon only (an LD_PRELOAD shim; the JVM daemon's
  # key check is in its self-test).
  [ -n "$SAN" ] || [ -n "$VG" ] && { skip "allocation-failure injection does not mix with a sanitizer or valgrind"; return; }
  have gcc || { skip "gcc is not installed"; return; }
  [ "$(uname -s)" = Linux ] || { skip "frame_auth needs LD_PRELOAD and /proc (Linux only)"; return; }
  mkdir -p "$D"
  gcc -shared -fPIC -O1 -o "$D/failsize.so" service/tests/fail_size_preload.c -ldl 2>"$D/failsize.build" || { fail "the failure shim did not build"; cat "$D/failsize.build"; return; }
  mock_start || { fail "mock provider did not start"; return; }
  daemon_conf "$D/auth.conf"
  if daemon_start c "$D/auth.conf" "LD_PRELOAD=$D/failsize.so" "FSQL_FAIL_SIZE=$((32 + 777))"; then
    check "frame authentication: a forged frame is refused, a genuine one answered, with the old tag buffer size failing" python3 service/tests/mac_failure.py "$D/d.sock" "$D/hmac.key" 777
    check "a declared-but-unsent payload is not allocated before authentication" python3 service/tests/preauth_memory.py "$D/d.sock" "$DPID"
  else fail "daemon did not start (frame authentication)"; fi
  daemon_stop
  local hex n
  cp "$D/hmac.key" "$D/hmac.key.keep"
  for hex in 00 0011223344556677 00112233445566778899aabbccddee; do
    printf '%s\n' "$hex" > "$D/hmac.key"
    if daemon_start c "$D/auth.conf"; then fail "a ${#hex}-hex-digit key was accepted"; daemon_stop
    else pass "a $((${#hex} / 2))-byte key is refused at start-up"; fi
  done
  cp "$D/hmac.key.keep" "$D/hmac.key"; rm -f "$D/hmac.key.keep"
  mock_stop
}

gate_20_stack_up() {
  have docker || { skip "docker is not installed"; return; }
  [ "$NO_DOCKER" = 1 ] && { skip "--no-docker"; return; }
  export FSQL_HMAC_KEY="${FSQL_HMAC_KEY:-$(openssl rand -hex 32)}"
  if [ -z "$LLM_URL" ]; then
    export FSQLD_REASONING_URL="http://mock-llm:18765/v1/chat/completions"
    export FSQLD_EMBED_URL="http://mock-llm:18765/v1/embeddings"
    export FSQLD_REASONING_MODEL=mock-chat FSQLD_EMBED_MODEL=mock-embed
  else
    export FSQLD_REASONING_URL="$LLM_URL/v1/chat/completions" FSQLD_EMBED_URL="$LLM_URL/v1/embeddings"
    export FSQLD_THINK="${FSQLD_THINK:-low}"   # a model that thinks (gpt-oss) takes ~16s per call without a cap, ~1s with one
    export FSQL_REAL_LLM=1   # the gates then check that the provider answered, not what the mock says
  fi
  export FSQLD_REASONING_ALLOW_PLAINTEXT=true
  mkdir -p docker/druid/extensions/fractalsql-druid
  cp druid-extension/target/fractalsql-druid-*.jar docker/druid/extensions/fractalsql-druid/fractalsql-druid.jar 2>/dev/null || { fail "build the extension first (gate 11)"; return; }
  # earlier gates set umask 077 (the daemon's key and config are private); the Druid container's user must still be able to read the jar
  chmod 0755 docker/druid/extensions docker/druid/extensions/fractalsql-druid; chmod 0644 docker/druid/extensions/fractalsql-druid/fractalsql-druid.jar
  # The compose file pins container names, so a stack from another project name (a demo left running) would collide and the gates
  # would silently talk to it. Stop here and say so.
  other="$(docker ps -a --format '{{.Names}} {{.Label "com.docker.compose.project"}}' 2>/dev/null | awk '$1 ~ /^fractalsql-druid-/ && $2 != "fsqld-test" {print $1}' | tr '\n' ' ')"
  if [ -n "$other" ]; then fail "containers from another stack are using this stack's names ($other); run 'docker compose -p <project> down -v' for it first"; return; fi
  check "compose build" $NICE $COMPOSE build
  check "compose up" $COMPOSE up -d
  STACK_UP=1
  check "the extension answers on the broker and the router answers SQL" stack_ready
  check "fractalsqld is healthy" bash -c "$COMPOSE ps fractalsqld | grep -q healthy"
}

sql() { curl -sf -m 120 -X POST -H 'Content-Type: application/json' -d "$1" "$DRUID_URL/druid/v2/sql"; }

gate_21_sql_functions() {
  need_stack || { skip "no stack"; return; }
  check "SQL functions: vectors, TDA, session settings, reasoning through the daemon" python3 tests/druid_sql.py "$DRUID_URL"
}

gate_22_service() {
  need_stack || { skip "no stack"; return; }
  check "service endpoints: health, schema, text-to-SQL, agents, vectorizer, ledger" python3 tests/druid_service.py "$DRUID_URL" "$DRUID_FRACTALSQL_URL"
}

gate_23_mcp_e2e() {
  need_stack || { skip "no stack"; return; }
  check "MCP against the live cluster: every tool family" python3 mcp/tests/druid_mcp_e2e.py mcp/fractalsql-druid-mcp
}

gate_24_demo() {
  need_stack || { skip "no stack"; return; }
  # Every write in a demo is a Druid ingestion task, so a kit costs about a minute. Two small kits keep the gate inside its budget: one
  # that runs the fixtures and the SQL functions, one that also calls the embedding endpoint through the daemon. The 1000-line API
  # reference kit is a long run and is opt-in (FSQL_DEMO_FULL=1).
  check "demo runner: the SQL function kit" bash -c "cd demo && $NICE timeout 300 python3 run_demo.py --file demo.sql --quiet"
  check "demo runner: the vector kit, including an embedding call" bash -c "cd demo && $NICE timeout 300 python3 run_demo.py --file demo-fractal-vector.sql --quiet"
  if [ "${FSQL_DEMO_FULL:-0}" = 1 ]; then
    check "demo runner: the API reference kit" bash -c "cd demo && $NICE timeout 1800 python3 run_demo.py --file benchmark-api-reference.sql --quiet"
  fi
}

# The MCP protocol conformance driver: both protocol eras, authentication, framing, operator switches and the catalog's shape, against a
# real server over its real transports. It is the same driver the other FractalSQL engines run; the variables below are Druid's. The
# server's config-write tools are exercised too, but the daemon refuses operator keys, so the running stack is not changed.
gate_25_mcp_conformance() {
  [ -x mcp/fractalsql-druid-mcp ] || { fail "build the MCP server first (gate 12)"; return; }
  if ! need_stack; then
    # No cluster: the same driver against the stand-in Druid. Nothing it checks depends on what Druid answers.
    check "MCP conformance against a stand-in Druid: protocol eras, authentication, framing, switches, catalog" \
      python3 -I mcp/tests/conformance_mock.py "$PWD/mcp/fractalsql-druid-mcp" 25
    return
  fi
  local w; w="$(mktemp -d "$ART/conformance.XXXXXX")"
  check "MCP conformance: protocol eras, authentication, framing, switches, catalog" \
    env MCP_SERVER_EXE="$PWD/mcp/fractalsql-druid-mcp" MCP_SERVER_CWD="$w" MCPC_TOKEN=conformance-token MCPC_GATE=25 \
        MCPC_LOCK_DIR="$PWD/mcp" MCPC_PASSTHROUGH_ENV=DRUID_URL,DRUID_FRACTALSQL_URL MCPC_READ_TOOL=fractal_version \
        MCPC_SAFE_KEY=reasoning_model MCPC_UNSAFE_KEY=reasoning_url MCPC_SECRET_KEY=reasoning_token \
        "MCPC_SKIP=H02=Diversify state is a node-level setting on Druid, not per MCP context" \
        DRUID_URL="$DRUID_URL" DRUID_FRACTALSQL_URL="$DRUID_FRACTALSQL_URL" \
        python3 -u mcp/tests/mcp_conformance.py
}

# The multi-host layout: a second broker with a daemon of its own (compose profile multihost). Each broker reaches only its own daemon,
# as brokers on two machines would. Both gates below start it when it is not up and remove it again only if they started it.
MH_STARTED=""
multihost_up() {
  # A stack started by an earlier run has the daemon's settings only in its container; give compose the same values.
  if [ -z "${FSQL_HMAC_KEY:-}" ]; then
    eval "$(docker inspect fractalsql-druid-fractalsqld --format '{{range .Config.Env}}{{println .}}{{end}}' 2>/dev/null \
      | grep -E '^(FSQL_HMAC_KEY|FSQLD_|FSQL_REASONING)' | sed 's/^/export /; s/=\(.*\)$/="\1"/')"
  fi
  # The mock provider has one model name; the second daemon gets another, so a reply shows which daemon (and so which broker) answered.
  case "${FSQLD_REASONING_MODEL:-}" in mock*) export FSQLD_REASONING_MODEL_B="${FSQLD_REASONING_MODEL}-b";; esac
  if curl -sf -m 3 http://127.0.0.1:8084/fractalsql/health >/dev/null 2>&1; then return 0; fi
  MH_STARTED=1
  check "the second broker and its daemon start" $NICE $COMPOSE --profile multihost up -d fractalsqld-b broker-b
  check "the second broker answers" bash -c 'for _ in $(seq 1 60); do curl -sf -m 3 http://127.0.0.1:8084/fractalsql/health >/dev/null 2>&1 && exit 0; sleep 3; done; exit 1'
}
multihost_down() {
  [ -n "$MH_STARTED" ] || return 0
  $COMPOSE --profile multihost rm -sf broker-b fractalsqld-b >/dev/null 2>&1
  MH_STARTED=""
}

# Opt-in, because it adds a broker to the stack: --gate 26, or FSQL_MULTIHOST=1.
gate_26_multihost() {
  case ",$ONLY," in *",26,"*) ;; *) [ "${FSQL_MULTIHOST:-0}" = 1 ] || { skip "opt-in: --gate 26 or FSQL_MULTIHOST=1"; return; };; esac
  need_stack || { skip "no stack"; return; }
  multihost_up
  check "two brokers, each through its own daemon; the router spreads over both; one daemon down affects only its broker" \
    python3 tests/druid_multihost.py "$DRUID_URL" "$DRUID_FRACTALSQL_URL" http://127.0.0.1:8084 fractalsql-druid-fractalsqld-b
  # a run that selects gate 27 as well leaves the pair up for it
  case ",$ONLY," in *",27,"*) ;; *) multihost_down;; esac
}

# A ledger per host: each daemon keeps its own chain; fractalsql-ledger-collect snapshots it into an audit store and fractalsql-ledger-check
# re-checks the store away from the daemons, including tampered copies. Opt-in (--gate 27 or FSQL_LEDGER=1). It needs the enterprise library
# staged in both daemons (docs/docker-demo.md, "The enterprise tier") and skips without it.
gate_27_ledger_collect() {
  case ",$ONLY," in *",27,"*) ;; *) [ "${FSQL_LEDGER:-0}" = 1 ] || { skip "opt-in: --gate 27 or FSQL_LEDGER=1"; return; };; esac
  need_stack || { skip "no stack"; return; }
  multihost_up
  local w rc; w="$(mktemp -d "$ART/ledger.XXXXXX")"
  python3 tests/druid_ledger_collect.py "$DRUID_FRACTALSQL_URL" http://127.0.0.1:8084 fractalsql-druid-fractalsqld fractalsql-druid-fractalsqld-b "$PWD/scripts" "$w"
  rc=$?
  if [ "$rc" = 77 ]; then skip "the daemons have no ledger (stage the enterprise library)"; else check "a ledger per host: collect, check away from the daemon, catch tampering" test "$rc" = 0; fi
  multihost_down
}

# The daemon goes away under a running stack: Druid keeps answering (the daemon-backed functions return NULL, everything else works), and
# the same broker serves the calls again once the daemon is back, with no restart.
gate_28_daemon_outage() {
  need_stack || { skip "no stack"; return; }
  check "a daemon outage: Druid keeps answering, and the calls recover with no restart" \
    python3 tests/druid_daemon_outage.py "$DRUID_URL" "$DRUID_FRACTALSQL_URL" fractalsql-druid-fractalsqld
}

# ---------------------------------------------------------------------------------------------
# The matrix
# ---------------------------------------------------------------------------------------------
GATES=(
  "01 build_daemon      C daemon and fsqlctl build clean, no database client            ~15s"
  "02 build_jvm         JVM daemon: JNI library and jar                                  ~20s"
  "03 jvm_selftest      frames, HMAC vector, idempotency cache, config parser            ~5s"
  "04 protocol_c        FSQ v2 conformance against the C daemon                          ~15s"
  "05 protocol_jvm      FSQ v2 conformance against the JVM daemon                        ~15s"
  "06 parity            the JVM daemon answers pure calls exactly as the C one           ~10s"
  "07 contexts          four reasoning contexts x both daemons x three chat modes        ~60s"
  "08 daemon_config     config validation, reload refusal and apply                      ~15s"
  "09 daemon_security   wrong key, uid allow-list, connection and idle limits            ~15s"
  "10 enterprise        signature check, ledger, tamper refusal, dormant path            ~30s"
  "11 extension         unit tests, package, jar contents                                ~90s"
  "12 mcp_build         MCP server builds, 78 tools, no embedded engine                  ~40s"
  "13 mcp_locks         schema lock, safety lock and manifest agree with the table       ~5s"
  "14 mcp_contract      alignment checker                                                ~5s"
  "15 mcp_protocol      MCP initialize/tools/annotations/schema errors, no cluster       ~10s"
  "16 think            reasoning effort per setting and provider shape, both daemons, never on embeds   ~40s"
  "17 calls_all        every registry function with ordinary and junk arguments, both daemons: never a crash   ~60s"
  "18 workout          every registry function used as documented, sessions, ledger and audit; both daemons   ~60s"
  "19 oom              allocation failures injected at random while the registry is used: the daemon survives   ~45s"
  "20 stack_up          docker compose: fractalsqld + Druid + mock provider              ~3m"
  "21 sql_functions     SQL expressions, session config, reasoning through the daemon    ~20s"
  "22 service           /fractalsql endpoints: schema, text-to-SQL, agents, vectorizer   ~60s"
  "23 mcp_e2e           every MCP tool family against the live cluster                   ~90s"
  "24 demo              the demo runner on two small kits (full reference kit: FSQL_DEMO_FULL=1)  ~2m"
  "25 mcp_conformance   MCP protocol eras, auth, framing, switches and catalog; live cluster, or the stand-in Druid with no stack    ~60s"
  "26 multihost         opt-in: two brokers, a daemon each; router spread; one down affects only its broker   ~90s"
  "27 ledger_collect    opt-in: a ledger per host collected, checked offline, tampering caught  ~30s"
  "28 daemon_outage     the daemon stopped under a running stack: Druid keeps answering, calls recover with no restart  ~60s"
  "29 mcp_mock         every MCP tool against a stand-in Druid, healthy and failing; no cluster       ~60s"
  "30 enterprise_edges malformed head files, bytes changed in the chain, a bad library or signature or temp dir or ledger path   ~90s"
  "31 enterprise_mock  the enterprise seam against a stand-in library: errors, counts out of range, missing symbols   ~30s"
  "32 hardening        the daemon, the CLI, the JNI library and the MCP server carry the hardening flags   ~20s"
  "33 analysis         static analysis of the C sources against the accepted findings   ~100s"
  "34 rss_growth       the daemon's resident size does not grow over repeated passes   ~90s"
  "35 stress           concurrent, mixed use of the daemon, with the answers checked   ~90s"
  "36 ledger_crash     the daemon killed while it writes: the chain is still sound   ~120s"
  "37 ledger_variants  SIGTERM, two writers, flush/compact/reset in the mix and a file-size limit: the chain is still sound   ~60s"
  "38 ledger_fsync     each acknowledged ledger write is synced to disk before it is answered   ~5s"
  "39 mcp_cli          the MCP server started with every command line, environment and Druid setting: it always ends in order   ~30s"
  "40 jni_sanitizers   the JNI shim built with ASan and UBSan, the extension's native tests run against it   ~120s"
  "44 jni_tsan         the JNI shim built with ThreadSanitizer, driven from eight threads (on demand: --gate 44)   ~60s"
  "43 analyze_java     SpotBugs + find-sec-bugs over the extension against the accepted findings (on demand: --gate 43)   ~60s"
  "42 mcp_audit        vector dimension limit, numeric bounds, an endless Druid answer   ~15s"
  "41 frame_auth       a forged frame is refused when its tag cannot be computed; keys under 16 bytes are refused   ~10s"
)

# ---------------------------------------------------------------------------------------------
# Modes: --asan --ubsan --tsan --coverage --fuzz --analyze --fault --profile
# ---------------------------------------------------------------------------------------------
NATIVE_GATES="01,04,07,08,09,10,12,13,15,16,17,18,19,25,29,30,31,35,39,41,42"

# the percentage and the counts for one metric in an lcov summary
lcov_metric() { # lcov_metric FILE lines|functions|branches
  lcov --summary "$1" --rc branch_coverage=1 --ignore-errors inconsistent,unused,mismatch,empty 2>/dev/null | sed -n "s/^ *$2\\.*: *\\([0-9.]*%\\) (\\([0-9]*\\) of \\([0-9]*\\).*/\\1 \\2 \\3/p" | head -1
}

# coverage_row LABEL FILE: one report row, and a note for anything under the 80% target
coverage_row() {
  local label="$1" info="$2" m pct cnt note=""
  printf '  %s\n' "$label"
  for m in lines functions branches; do
    read -r pct cnt _ < <(lcov_metric "$info" "$m" | awk '{print $1, $2"/"$3}')
    pct="${pct:-n/a}"; cnt="${cnt:-0/0}"
    printf '    %-10s %8s   (%s)\n' "$m" "$pct" "$cnt"
    case "$pct" in n/a) ;; *) awk -v p="${pct%\%}" 'BEGIN{exit !(p+0 < 80)}' && note="$note $m";; esac
  done
  [ -n "$note" ] && printf '    below the 80%% target:%s (best effort)\n' "$note"
  return 0
}

# the Java side: JaCoCo over the extension's unit tests
coverage_java() {
  have mvn || { echo "    (no mvn: the extension's Java coverage is not measured)"; return; }
  local plat; plat="$(host_platform)"
  sh druid-extension/src/main/native/build-native-linux.sh "$plat" >/dev/null 2>&1 || { echo "    (the native payload did not build: Java coverage skipped)"; return; }
  ( cd druid-extension && mvn -q -B org.jacoco:jacoco-maven-plugin:0.8.12:prepare-agent test \
      -Dfsql.platform="$plat" >"$ART/jacoco.out" 2>&1
    # exec files concatenate: the unit tests' data and what the live cluster recorded make one report
    if [ -s "$ART/jacoco/cluster.exec" ]; then cat "$ART/jacoco/cluster.exec" >> target/jacoco.exec; echo "  (the live-cluster gates add their coverage of the extension)" >>"$ART/jacoco.out"; fi
    mvn -q -B org.jacoco:jacoco-maven-plugin:0.8.12:report >>"$ART/jacoco.out" 2>&1 )
  python3 - "$PWD/druid-extension/target/site/jacoco/jacoco.xml" <<'PY'
import sys, xml.etree.ElementTree as ET
try:
    root = ET.parse(sys.argv[1]).getroot()
except Exception as e:
    print("    (no JaCoCo report: %s)" % e); sys.exit(0)
c = {x.get("type"): (int(x.get("covered")), int(x.get("missed"))) for x in root.findall("counter")}
print("  Druid extension (Java, unit tests and the live-cluster gates)")
low = []
for label, key in (("lines", "LINE"), ("functions", "METHOD"), ("branches", "BRANCH")):
    cov, miss = c.get(key, (0, 0)); tot = cov + miss
    pct = 100.0 * cov / tot if tot else 0.0
    print("    %-10s %7.1f%%   (%d/%d)" % (label, pct, cov, tot))
    if tot and pct < 80: low.append(label)
if low: print("    below the 80%% target: %s (best effort)" % " ".join(low))
PY
}

coverage_report() { # coverage_report TREE : run inside the instrumented copy
  local W="$1" out="$ART/cov"; mkdir -p "$out"
  ( cd "$W"
    lcov --capture --directory service/build --output-file "$out/svc.all" --rc branch_coverage=1 --filter branch,line --ignore-errors inconsistent,unused,mismatch,gcov,source,negative >/dev/null 2>&1
    lcov --extract "$out/svc.all" "$W/service/*" --output-file "$out/svc.part" --rc branch_coverage=1 --ignore-errors unused,inconsistent >/dev/null 2>&1
    lcov --remove "$out/svc.part" "$W/service/build/*" "$W/service/tests/*" --output-file "$out/svc.info" --rc branch_coverage=1 --ignore-errors unused,inconsistent >/dev/null 2>&1
    lcov --capture --directory mcp/src --output-file "$out/mcp.all" --rc branch_coverage=1 --filter branch,line --ignore-errors inconsistent,unused,mismatch,gcov,source,negative >/dev/null 2>&1
    lcov --extract "$out/mcp.all" "$W/mcp/src/*" --output-file "$out/mcp.info" --rc branch_coverage=1 --ignore-errors unused,inconsistent >/dev/null 2>&1
  )
  echo
  echo "============================================================"
  echo "coverage: src   (target: 80% lines, functions, branches; best effort)"
  echo "============================================================"
  coverage_row "C daemon and adapter (service/), from the daemon gates" "$out/svc.info"
  ( cd "$W" && coverage_java )
  echo
  echo "============================================================"
  echo "coverage: mcp   (target: 80% lines, functions, branches; best effort)"
  echo "============================================================"
  coverage_row "MCP server (mcp/src), from the offline MCP gates" "$out/mcp.info"
  echo "  by file (lines / functions / branches):"
  python3 - "$out/mcp.info" "$W/" <<'PY'
import sys
info, root = sys.argv[1], sys.argv[2]
rows, cur = [], None
for ln in open(info, errors="replace"):
    ln = ln.strip()
    if ln.startswith("SF:"):
        cur = {"f": ln[3:].replace(root, ""), "LF": 0, "LH": 0, "FNF": 0, "FNH": 0, "BRF": 0, "BRH": 0}
    elif cur is not None and ":" in ln and ln.split(":")[0] in cur:
        cur[ln.split(":")[0]] = int(ln.split(":")[1])
    elif ln == "end_of_record" and cur is not None:
        rows.append(cur); cur = None
pc = lambda h, t: ("%5.1f%%" % (100.0 * h / t)) if t else "   -  "
for r in sorted(rows, key=lambda r: r["f"]):
    print("    %-34s %s  %s  %s" % (r["f"], pc(r["LH"], r["LF"]), pc(r["FNH"], r["FNF"]), pc(r["BRH"], r["BRF"])))
PY
  # worklists: what is still uncovered, per file and function (the filtered MCP view drops compiler-generated scope-exit branches)
  python3 scripts/cov_worklist.py lcov "$out/svc.info" "$out/worklist-svc.txt" --root "$W/" >/dev/null 2>&1
  python3 scripts/cov_worklist.py lcov "$out/mcp.info" "$out/worklist-mcp.txt" --root "$W/" >/dev/null 2>&1
  python3 scripts/cov_worklist.py lcov "$out/mcp.info" "$out/worklist-mcp-filtered.txt" --filter-scope-exit --root "$W/" 2>&1 | sed 's/^/  /'
  [ -f "$W/druid-extension/target/site/jacoco/jacoco.xml" ] && python3 scripts/cov_worklist.py jacoco "$W/druid-extension/target/site/jacoco/jacoco.xml" "$out/worklist-java.txt" >/dev/null 2>&1
  echo "  reports: $out"
}

# The extension runs inside Druid in the live-cluster gates; a JaCoCo agent on those JVMs records which of its lines that exercised.
cov_cluster_setup() {
  local dir="$ART/jacoco" ov="$ART/cov-override.yml" svc
  mkdir -p "$dir"; chmod 0777 "$dir"
  mvn -q -B org.apache.maven.plugins:maven-dependency-plugin:3.6.1:copy -Dartifact=org.jacoco:org.jacoco.agent:0.8.12:jar:runtime \
      -DoutputDirectory="$dir" -f druid-extension/pom.xml >"$ART/jacoco-agent.out" 2>&1 || { echo "(the JaCoCo agent did not download: the extension is measured by its unit tests only)"; return; }
  chmod 0644 "$dir"/*.jar
  {
    echo "services:"
    for svc in coordinator-overlord broker historical router broker-b; do
      echo "  $svc:"
      echo "    environment:"
      echo "      JAVA_TOOL_OPTIONS: \"-javaagent:/jacoco/org.jacoco.agent-0.8.12-runtime.jar=destfile=/jacoco/cluster.exec,includes=com.fractalsqlabs.*,append=true\""
      echo "    volumes:"
      echo "      - $dir:/jacoco"
    done
  } > "$ov"
  export FSQL_COV_OVERRIDE="$ov" FSQL_JACOCO_DIR="$dir"
}

run_native() {
  have rsync || { echo "rsync is needed for the native modes" >&2; exit 2; }
  local W="$ART/native" rc
  mkdir -p "$W"
  rsync -a --exclude build --exclude '*.o' --exclude '*.d' --exclude '*.gcda' --exclude '*.gcno' --exclude target --exclude dist \
        --exclude 'mcp/fractalsql-druid-mcp' --exclude 'docker/druid/extensions' --exclude .git ./ "$W/"
  echo "fractalsql-druid build_test  ${SAN:+$SAN }$([ "$COV" = 1 ] && echo "coverage ")(instrumented copy: $W)"
  # The sanitized runs start with a fixed address space layout (see SAN_PREFIX above).
  local pre=""
  case "$SAN" in tsan|asan|ubsan) pre="$SAN_PREFIX";; esac
  local gates="${ONLY:-$NATIVE_GATES}"
  [ "$COV" = 1 ] && [ -z "$ONLY" ] && [ "$NO_DOCKER" = 0 ] && have docker && have mvn && cov_cluster_setup
  # coverage also drives the MCP server through the live cluster (every tool family), when Docker is here
  [ "$COV" = 1 ] && [ -z "$ONLY" ] && [ "$NO_DOCKER" = 0 ] && have docker && have mvn && gates="$gates,11,20,21,22,23,24,25"
  ( cd "$W" && FSQL_NATIVE=1 FSQL_SAN="$SAN" FSQL_COV="$COV" FSQL_TEST_DIR="$ART/run" $pre ./build_test.sh --gate "$gates" )
  rc=$?
  if [ "$COV" = 1 ]; then
    # the daemon's error paths: a misbehaving provider, a killed daemon, bad inputs
    ( cd "$W" && FSQL_NATIVE=1 FSQL_COV=1 FSQL_TEST_DIR="$ART/run-fault" ./build_test.sh --fault ) >"$ART/fault.out" 2>&1 || { echo "(the fault scenarios under coverage failed: $ART/fault.out)"; }
  fi
  [ "$COV" = 1 ] && coverage_report "$W"
  exit "$rc"
}

mode_fuzz() {
  local fz secs="${FSQL_FUZZ_SECS:-30}" W="$ART/fuzz" t
  for fz in clang++-18 clang++-17 clang++-16 clang++; do have "$fz" && break; fz=""; done
  [ -n "$fz" ] || { skip "no clang++ with libFuzzer"; return; }
  mkdir -p "$W"
  local common=(-std=c++17 -O1 -g -fsanitize=fuzzer,address -Imcp/src -Imcp/vendor)
  echo "---- fuzz (libFuzzer, ${secs}s per target)"
  check "build fuzz_mcp_vectors" $fz "${common[@]}" tests/fuzz/fuzz_mcp_vectors.cpp mcp/src/vectors.cpp mcp/src/errors.cpp -o "$W/fuzz_mcp_vectors"
  check "build fuzz_mcp_jsonrpc" $fz "${common[@]}" tests/fuzz/fuzz_mcp_jsonrpc.cpp tests/fuzz/mcp_evp_stub.cpp mcp/src/jsonrpc_server.cpp \
        mcp/src/errors.cpp mcp/src/logging.cpp mcp/src/prompts.cpp mcp/src/resources.cpp mcp/src/tool_registry.cpp -lssl -lcrypto -lpthread -o "$W/fuzz_mcp_jsonrpc"
  for t in vectors jsonrpc; do
    [ -x "$W/fuzz_mcp_$t" ] || continue
    mkdir -p "$W/new_$t"
    check "replay the $t corpus" env ASAN_OPTIONS=detect_leaks=0 "$W/fuzz_mcp_$t" -runs=0 "tests/fuzz/corpus_mcp_$t/"
    check "fuzz $t for ${secs}s" env ASAN_OPTIONS=detect_leaks=0 "$W/fuzz_mcp_$t" -max_total_time="$secs" -artifact_prefix="$W/crash_$t-" "$W/new_$t" "tests/fuzz/corpus_mcp_$t/"
  done

  # ---- the daemon's own targets: the C adapter and the daemon, fuzzed.
  # A C compiler with libFuzzer (and its runtime) is needed; the probe
  # below says so plainly when there is none.
  fzc=""
  local c
  for c in clang-18 clang-17 clang-16 clang-15 clang-14 clang-13 clang-12 clang; do
    have "$c" || continue
    printf 'int LLVMFuzzerTestOneInput(const unsigned char*d,unsigned long s){return 0;}\n' > "$W/probe.c"
    if "$c" -fsanitize=fuzzer,address -O1 "$W/probe.c" -o "$W/probe" >/dev/null 2>&1; then fzc="$c"; break; fi
  done
  if [ -z "$fzc" ]; then
    skip "no clang with libFuzzer (the daemon's fuzz targets are skipped)"
    return
  fi
  local plat core gen
  plat="$(host_platform)"
  core="include/$plat/libfractalsql-community-sovereign-c.a"
  [ -f "$core" ] || core="include/libfractalsql-community-sovereign-c.a"
  [ -f "$core" ] || { skip "no vendored core archive for $plat (the daemon's fuzz targets are skipped)"; return; }
  gen="$W/gen"; mkdir -p "$gen"
  if ! python3 service/scripts/gen_udf.py "$gen" >"$W/gen_udf.out" 2>&1; then
    fail "the function table could not be generated"; sed 's/^/      /' "$W/gen_udf.out" | tail -5; return
  fi
  # The daemon's sources, instrumented, linked against the vendored core.
  local svc_common=(-O1 -g -fsanitize=fuzzer,address,undefined -fno-omit-frame-pointer
                    -Iinclude -Iservice/adapter/src -Iservice/protocol -Iservice -I"$gen")
  local svc_libs=(-lcrypto -lpthread -ldl -lm)

  # svc_fuzz_run BIN CORPUS OUT LOG ARGS...
  # Runs the fuzzer and says what happened:
  #   0  the run finished
  #   1  the run found something: a sanitizer report, a libFuzzer crash
  #      report, or a crash artifact
  #   2  the sanitizer would not start: the process died before it
  #      printed anything. The sanitizer reserves a very large address
  #      space at start-up, and that reservation fails intermittently on
  #      some hosts (a container with a fragmented address space, for
  #      one). Such a run says nothing about the code under test, so it
  #      is retried, and reported if it keeps happening.
  svc_fuzz_run() {
    local prefix="$1" bin="$2" corpus="$3" out="$4" log="$5"; shift 5
    local attempt=1 rc=1
    while [ "$attempt" -le 3 ]; do
      env ASAN_OPTIONS=detect_leaks=0 UBSAN_OPTIONS=print_stacktrace=1 \
        $SAN_PREFIX "$bin" "$@" -artifact_prefix="$prefix" "$out" "$corpus" >"$log" 2>&1
      rc=$?
      [ "$rc" -eq 0 ] && return 0
      if grep -qE 'AddressSanitizer|runtime error:|libFuzzer: deadly signal|SUMMARY: (Address|Undefined)|ERROR:' "$log"; then
        return 1
      fi
      if [ -s "$log" ]; then return 1; fi
      attempt=$((attempt+1))
    done
    return 2
  }

  # svc_fuzz_target NAME HARNESS [EXCLUDED_ADAPTER_SOURCE]
  # The harness is compiled together with the adapter's sources, so the
  # static functions it needs are the product's own. A harness that
  # includes an adapter source itself excludes that source from the
  # separately compiled list (it would be defined twice).
  svc_fuzz_target() {
    local name="$1" harness="$2" excl="${3:-}" srcs=() f bin corpus dict="" rc
    for f in service/adapter/src/*.c; do
      [ -n "$excl" ] && [ "$(basename "$f")" = "$excl" ] && continue
      srcs+=("$f")
    done
    bin="$W/fuzz_svc_$name"
    if ! check "build fuzz_svc_$name" $fzc "${svc_common[@]}" "$harness" "${srcs[@]}" "$core" "${svc_libs[@]}" -o "$bin"; then
      sed 's/^/      /' "$ART/last.out" | tail -12
      return
    fi
    corpus="tests/fuzz/corpus_svc_$name"
    mkdir -p "$corpus" "$W/new_svc_$name"
    rc=0
    svc_fuzz_run "$W/crash_svc_${name}_" "$bin" "$corpus" "$W/new_svc_$name" "$W/replay_svc_$name.out" -runs=0 || rc=$?
    case "$rc" in
      0) pass "replay the $name corpus";;
      2) skip "the sanitizer would not start for the $name corpus (the host's address space)";;
      *) fail "replay the $name corpus"; sed 's/^/      /' "$W/replay_svc_$name.out" | tail -12
         ls -1 "$W"/crash_svc_* 2>/dev/null | sed 's/^/      artifact: /';;
    esac
    [ -f tests/fuzz/dict_svc.dict ] && dict="-dict=tests/fuzz/dict_svc.dict"
    # The time-bounded run: the new interesting inputs land in the
    # artifact directory, a crash in the artifact directory too.
    rc=0
    svc_fuzz_run "$W/crash_svc_${name}_" "$bin" "$corpus" "$W/new_svc_$name" "$W/fuzz_svc_$name.out" \
      -max_total_time="$secs" $dict || rc=$?
    case "$rc" in
      0) pass "fuzz $name for ${secs}s";;
      2) skip "the sanitizer would not start for $name (the host's address space)";;
      *) fail "fuzz $name for ${secs}s"
         sed 's/^/      /' "$W/fuzz_svc_$name.out" | tail -12
         ls -1 "$W"/crash_svc_* 2>/dev/null | sed 's/^/      artifact: /';;
    esac
    grep -E "^#.*(cov|ft|corp|exec/s)" "$W/fuzz_svc_$name.out" | tail -1 | sed 's/^/      /'
    echo "      new interesting inputs: $(find "$W/new_svc_$name" -type f | wc -l) (in $W/new_svc_$name)"
  }

  svc_fuzz_target udf    tests/fuzz/fuzz_svc_udf.c
  svc_fuzz_target parse  tests/fuzz/fuzz_svc_parse.c
  svc_fuzz_target redact tests/fuzz/fuzz_svc_redact.c
  svc_fuzz_target t2s    tests/fuzz/fuzz_svc_t2s.c    fractalsql_textsql.c
  svc_fuzz_target ledger tests/fuzz/fuzz_svc_ledger.c fractalsql_enterprise.c
  svc_fuzz_target frame  tests/fuzz/fuzz_svc_frame.c
  svc_fuzz_target frame_auth tests/fuzz/fuzz_svc_frame_auth.c
  svc_fuzz_target config tests/fuzz/fuzz_svc_config.c
  svc_fuzz_target sig    tests/fuzz/fuzz_svc_sig.c    fractalsql_enterprise.c
}

mode_analyze() {
  # Static analysis of the C sources, against a baseline of the findings
  # that have been read and accepted (tests/analysis/baseline.txt). A
  # finding that is not in the baseline fails the run; so does a baseline
  # entry that is no longer reported.
  #
  # The three tools read the same sources and share nothing, so they run at
  # the same time: the wall clock is the slowest one, not the sum.
  #
  # The check sets, and why each one is what it is, are in
  # tests/analysis/README.md. The tool versions are recorded in the run's
  # output.
  local out="${1:-$ART/analyze}"; mkdir -p "$out"
  echo "---- static analysis"
  local pids=()

  if have gcc; then
    echo "    gcc $(gcc -dumpversion)"
    (
      t0=$(date +%s)
      # One file at a time, each compiled to /dev/null: the analyzer's
      # leak checker only runs on a real compilation, and this way no
      # object file is left in the tree.
      ( cd service && for f in adapter/src/*.c daemon/fractalsqld.c cli/fsqlctl.c; do
          gcc -fanalyzer -Wall -Wextra -std=gnu11 -O1 -I../include -Iadapter/src -Ibuild/gen \
              -c "$f" -o /dev/null
        done ) > "$out/gcc-fanalyzer.txt" 2>&1
      echo "    gcc -fanalyzer: $(( $(date +%s) - t0 ))s, $(grep -c 'warning:' "$out/gcc-fanalyzer.txt") finding(s)"
    ) & pids+=($!)
  else
    echo "    (gcc is not installed: the gcc -fanalyzer pass is skipped)"
  fi

  if have clang-tidy; then
    echo "    clang-tidy $(clang-tidy --version | sed -n 's/.*version \([0-9.]*\).*/\1/p' | head -1)"
    (
      t0=$(date +%s)
      ( cd service && clang-tidy -quiet \
          --checks="-*,clang-analyzer-*,-clang-analyzer-security.insecureAPI.DeprecatedOrUnsafeBufferHandling,bugprone-*,cert-*,-bugprone-easily-swappable-parameters,-cert-err33-c" \
          adapter/src/*.c daemon/fractalsqld.c cli/fsqlctl.c \
          -- -I../include -Iadapter/src -Ibuild/gen -std=gnu11 ) > "$out/clang-tidy.txt" 2>&1
      echo "    clang-tidy: $(( $(date +%s) - t0 ))s, $(grep -c 'warning:' "$out/clang-tidy.txt") finding(s)"
    ) & pids+=($!)
  else
    echo "    (clang-tidy is not installed: the clang-tidy pass is skipped)"
  fi

  if have cppcheck; then
    echo "    $(cppcheck --version)"
    (
      t0=$(date +%s)
      # --max-configs=1: one preprocessor configuration per file. Checking every #ifdef combination took four minutes here
      # and reported the same findings as one configuration.
      cppcheck --enable=warning,portability --inline-suppr --std=c11 --quiet --max-configs=1 -j4 --suppress=toomanyconfigs \
          -I include -I service/adapter/src -I service/protocol \
          service/adapter/src service/daemon service/cli > "$out/cppcheck.txt" 2>&1
      echo "    cppcheck: $(( $(date +%s) - t0 ))s, $(grep -cE '^[^ ].*:[0-9]+' "$out/cppcheck.txt") finding(s)"
    ) & pids+=($!)
  else
    echo "    (cppcheck is not installed: the cppcheck pass is skipped)"
  fi
  [ "${#pids[@]}" -gt 0 ] && wait "${pids[@]}"

  echo "    reports: $out"
  if [ ! -f tests/analysis/baseline.txt ]; then
    fail "the static-analysis baseline (tests/analysis/baseline.txt) is missing"
    return
  fi
  FSQL_ANALYZE_ROOT="$PWD" python3 tests/analysis/compare.py tests/analysis/baseline.txt \
      "$out/gcc-fanalyzer.txt" "$out/clang-tidy.txt" "$out/cppcheck.txt" > "$out/compare.out" 2>&1
  local rc=$?
  sed 's/^/      /' "$out/compare.out"
  if [ "$rc" -eq 0 ]; then pass "the static-analysis findings match the baseline"; else fail "the static-analysis findings differ from the baseline"; fi
}

mode_analyze_cpp() {
  # The same analysis for the MCP server's C++17 (mcp/src), against tests/analysis/baseline-cpp.txt. clang-tidy over the
  # C++ takes about nine minutes on one core (the JSON library is heavy), so it is spread over four processes and kept
  # out of the default run: it is a mode, not a gate.
  local out="${1:-$ART/analyze-cpp}"; mkdir -p "$out"
  echo "---- static analysis (the MCP server, C++17)"
  local t0
  if have clang-tidy; then
    echo "    clang-tidy $(clang-tidy --version | sed -n 's/.*version \([0-9.]*\).*/\1/p' | head -1)"
    t0=$(date +%s)
    ( cd mcp && ls src/*.cpp src/adapters/*.cpp | xargs -P 4 -I{} clang-tidy -quiet \
        --checks="-*,clang-analyzer-*,-clang-analyzer-security.insecureAPI.DeprecatedOrUnsafeBufferHandling,bugprone-*,cert-*,-bugprone-easily-swappable-parameters,-cert-err33-c" \
        {} -- -std=c++17 -Isrc -Ivendor '-DFSQL_MCP_VERSION="2.0.0"' ) > "$out/clang-tidy-cpp.txt" 2>&1
    echo "    clang-tidy: $(( $(date +%s) - t0 ))s, $(grep -c 'warning:' "$out/clang-tidy-cpp.txt") finding(s)"
  else
    echo "    (clang-tidy is not installed: the clang-tidy pass is skipped)"
  fi
  if have cppcheck; then
    echo "    $(cppcheck --version)"
    t0=$(date +%s)
    cppcheck --enable=warning,portability --inline-suppr --std=c++17 --quiet --max-configs=1 -j4 \
        --suppress=toomanyconfigs --suppress=missingIncludeSystem -I mcp/src -I mcp/vendor mcp/src > "$out/cppcheck-cpp.txt" 2>&1
    echo "    cppcheck: $(( $(date +%s) - t0 ))s, $(grep -cE '^[^ ].*:[0-9]+' "$out/cppcheck-cpp.txt") finding(s)"
  else
    echo "    (cppcheck is not installed: the cppcheck pass is skipped)"
  fi
  echo "    reports: $out"
  if [ ! -f tests/analysis/baseline-cpp.txt ]; then
    fail "the C++ static-analysis baseline (tests/analysis/baseline-cpp.txt) is missing"
    return
  fi
  FSQL_ANALYZE_ROOT="$PWD" python3 tests/analysis/compare.py tests/analysis/baseline-cpp.txt \
      "$out/clang-tidy-cpp.txt" "$out/cppcheck-cpp.txt" > "$out/compare.out" 2>&1
  local rc=$?
  sed 's/^/      /' "$out/compare.out"
  if [ "$rc" -eq 0 ]; then pass "the C++ static-analysis findings match the baseline"; else fail "the C++ static-analysis findings differ from the baseline"; fi
}

mode_fault() {
  echo "---- fault injection (a provider that misbehaves, a daemon that dies)"
  gate_01_build_daemon
  [ "$NATIVE" = 1 ] || gate_02_build_jvm
  local kind m port
  for kind in $KINDS; do
    for m in hang garbage error500 truncated empty longerr cycle; do
      port="$(python3 -c 'import socket; s=socket.socket(); s.bind(("127.0.0.1",0)); print(s.getsockname()[1])')"
      python3 service/tests/fault_llm.py "$port" "$m" >/dev/null 2>&1 &
      local fp=$!
      for _ in $(seq 1 30); do (exec 3<>"/dev/tcp/127.0.0.1/$port") 2>/dev/null && break; sleep 0.2; done
      MOCK_PORT="$port"; daemon_conf "$D/fault.conf"
      if daemon_start "$kind" "$D/fault.conf" "FSQL_REASONING_HTTP_TIMEOUT_MS=3000"; then
        check "$kind daemon, provider $m: calls fail cleanly and the daemon stays up" python3 service/tests/fault.py "$D/d.sock" "$D/hmac.key" "$m"
      else fail "$kind daemon did not start (provider $m)"; fi
      daemon_stop; kill "$fp" 2>/dev/null; wait "$fp" 2>/dev/null
    done
  done
  # the daemon is killed in the middle of a call, then started again
  for kind in $KINDS; do
    port="$(python3 -c 'import socket; s=socket.socket(); s.bind(("127.0.0.1",0)); print(s.getsockname()[1])')"
    python3 service/tests/fault_llm.py "$port" hang >/dev/null 2>&1 &
    local fp=$!
    for _ in $(seq 1 30); do (exec 3<>"/dev/tcp/127.0.0.1/$port") 2>/dev/null && break; sleep 0.2; done
    MOCK_PORT="$port"; daemon_conf "$D/fault.conf"
    if daemon_start "$kind" "$D/fault.conf" "FSQL_REASONING_HTTP_TIMEOUT_MS=60000"; then
      check "$kind daemon killed mid-call: the client gets an error, and a restart serves again" bash -c "
        python3 service/tests/fault.py '$D/d.sock' '$D/hmac.key' killed '$DPID' && rm -f '$D/d.sock'"
    else fail "$kind daemon did not start (kill test)"; fi
    DPID=""; kill "$fp" 2>/dev/null; wait "$fp" 2>/dev/null
    mock_start >/dev/null; daemon_conf "$D/fault.conf"
    if daemon_start "$kind" "$D/fault.conf"; then check "$kind daemon: serves again after being killed" ctl ping; else fail "$kind daemon did not restart"; fi
    daemon_stop; mock_stop
  done
  # bad inputs at start
  daemon_conf "$D/g1.conf"; printf 'this is not a config\n\0\377' >> "$D/g1.conf"
  check "a config with garbage in it does not crash the daemon" bash -c "timeout 3 '$FSQLD_C' -c '$D/g1.conf'; rc=\$?; [ \$rc -ne 134 ] && [ \$rc -ne 139 ]"
  : > "$D/empty.key"; chmod 600 "$D/empty.key"; daemon_conf "$D/g2.conf"; sed -i "s#^hmac_key_file = .*#hmac_key_file = $D/empty.key#" "$D/g2.conf"
  expect_fail "an empty key file is refused" timeout 5 "$FSQLD_C" -c "$D/g2.conf"
  daemon_conf "$D/g3.conf"; sed -i "s#^socket_path = .*#socket_path = /nonexistent-dir/x/d.sock#" "$D/g3.conf"
  expect_fail "a socket path in a missing directory is refused" timeout 5 "$FSQLD_C" -c "$D/g3.conf"
}

mode_profile() {
  have valgrind || { skip "valgrind is not installed"; return; }
  echo "---- profile (valgrind memcheck)"
  gate_01_build_daemon; gate_12_mcp_build
  VG="valgrind -q --error-exitcode=99 --leak-check=full --errors-for-leak-kinds=definite --track-origins=no"
  mock_start || { fail "mock provider did not start"; return; }
  daemon_conf "$D/v.conf"
  if daemon_start c "$D/v.conf"; then
    check "C daemon under valgrind: protocol conformance" python3 service/tests/conformance.py "$D/d.sock" "$D/hmac.key" "$D/daemon.log"
    check "C daemon under valgrind: the reasoning contexts" python3 service/tests/contexts.py "$D/d.sock" "$D/hmac.key" "$ART/mock.log" text
  else fail "C daemon did not start under valgrind"; tail -5 "$D/daemon.log"; fi
  daemon_stop; mock_stop; VG=""
  printf '#!/bin/sh\nexec valgrind -q --error-exitcode=99 --leak-check=full --errors-for-leak-kinds=definite "%s/mcp/fractalsql-druid-mcp" "$@"\n' "$ROOT" > "$ART/mcp-vg.sh"
  chmod +x "$ART/mcp-vg.sh"; cp mcp/.mcp-schema-lock mcp/.mcp-safety-annotations-lock "$ART/" 2>/dev/null
  check "MCP server under valgrind: the offline protocol suite" python3 mcp/tests/druid_mcp_offline.py "$ART/mcp-vg.sh"
}

case "$MODE" in
  fuzz)    mode_fuzz;    echo "============================================================"; echo "passed: $PASS   failed: $FAIL   skipped: $SKIP"; [ "$FAIL" -eq 0 ]; exit;;
  analyze) mode_analyze; echo "============================================================"; echo "passed: $PASS   failed: $FAIL   skipped: $SKIP"; [ "$FAIL" -eq 0 ]; exit;;
  analyze_cpp) mode_analyze_cpp; echo "============================================================"; echo "passed: $PASS   failed: $FAIL   skipped: $SKIP"; [ "$FAIL" -eq 0 ]; exit;;
  fault)   mode_fault;   echo "============================================================"; echo "passed: $PASS   failed: $FAIL   skipped: $SKIP"; [ "$FAIL" -eq 0 ]; exit;;
  profile) mode_profile; echo "============================================================"; echo "passed: $PASS   failed: $FAIL   skipped: $SKIP"; [ "$FAIL" -eq 0 ]; exit;;
esac
if [ "$NATIVE" != 1 ] && { [ -n "$SAN" ] || [ "$COV" = 1 ]; }; then run_native; fi

if [ "$LIST" = 1 ]; then printf '%s\n' "${GATES[@]}"; printf '%s\n' "modes: --asan --ubsan --tsan --coverage (gates $NATIVE_GATES, instrumented)  --fuzz  --analyze  --analyze-cpp  --fault  --profile"; exit 0; fi

want() { # want NN
  [ -z "$ONLY" ] && return 0
  case ",$ONLY," in *",$((10#$1)),"*|*",$1,"*) return 0;; esac
  return 1
}

echo "fractalsql-druid build_test  (artifacts: $ART)"
for g in "${GATES[@]}"; do
  n="${g%% *}"; rest="${g#* }"; name="${rest%% *}"
  want "$n" || continue
  [ "$QUICK" = 1 ] && [ "$((10#$n))" -ge 20 ] && [ "$((10#$n))" -ne 29 ] && [ "$((10#$n))" -ne 30 ] && [ "$((10#$n))" -ne 31 ] && [ "$((10#$n))" -ne 32 ] && continue
  echo "---- gate $n $name"
  t0=$(date +%s)
  "gate_${n}_${name}"
  t1=$(date +%s)
  echo "     ($((t1-t0))s)"
done

echo "============================================================"
echo "passed: $PASS   failed: $FAIL   skipped: $SKIP"
[ "$FAIL" -eq 0 ]
