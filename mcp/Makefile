# mcp/Makefile mirrors the repo's own top-level Makefile conventions
# (plain Makefile, no CMake; one binary; vendored sources; no package
# manager). The binary talks to Apache Druid over HTTP (the SQL API and the
# extension's /fractalsql endpoints) and links OpenSSL for TLS and the
# schema-lock SHA-256, and pthreads.
#
# Build:    make            (Linux/macOS; g++ or clang >= 11)
# Try it:   ./fractalsql-druid-mcp --list-tools
# Regenerate locks (after any tool-table change):
#   ./fractalsql-druid-mcp --write-schema-lock
#   ./fractalsql-druid-mcp --write-safety-annotations-lock
#   ./fractalsql-druid-mcp --write-manifest

CXX      ?= g++
CC       ?= gcc
CXXFLAGS ?= -std=c++17 -O2 -Wall -Wextra
# Empty by default; a cross-arch build passes CFLAGS="-arch x86_64".
CFLAGS   ?=
DEFS     := -DFSQL_MCP_VERSION="\"2.0.0\""

# src/vectors.cpp uses std::to_chars on a double (shortest round-trip form), which
# Apple's libc++ marks unavailable before macOS 13.3. CI exports
# MACOSX_DEPLOYMENT_TARGET=11.0 for the extension; the MCP server is a separate
# binary, so it carries its own, newer minimum.
ifeq ($(shell uname -s),Darwin)
  CXXFLAGS += -mmacosx-version-min=13.3
  CFLAGS   += -mmacosx-version-min=13.3   # sqlite3.o: same floor, or ld warns when built on a newer macOS
endif

# Coverage builds (build_test.sh --coverage): same posture as the
# top-level Makefile's own COVERAGE block: gcov instrumentation on
# both compile and link, appended (not replacing the caller's own
# -arch etc.) to both the C++ and C flags since the final link reuses
# CXXFLAGS directly and sqlite3.o is its own TU compiled with CFLAGS.
# -fprofile-update=atomic: unlike the top-level Makefile (whose gate
# workers are separate sqlite3 CLI processes, never racing on the same
# counters), this binary spawns a std::thread per HTTP connection
# in-process (transport_http.cpp) -- concurrent, non-atomic counter
# increments on shared code (including inherited libstdc++ template
# instantiations) corrupt gcov's counts, surfacing as geninfo's
# "Unexpected negative count ... Perhaps you need to compile with
# '-fprofile-update=atomic'" error during lcov capture.
ifdef COVERAGE
  CXXFLAGS := $(CXXFLAGS) -O1 -g --coverage -fprofile-update=atomic
  CFLAGS   := $(CFLAGS) -O1 -g --coverage -fprofile-update=atomic
endif

# Sanitizer builds (build_test.sh --asan / --ubsan / --tsan): the same
# switches the top-level Makefile takes, applied to the MCP server so its
# own C++ is instrumented, not just the extension it loads.
# ASAN=1 / UBSAN=1 compose freely; TSAN=1 composes with UBSAN=1 but NOT
# with ASAN=1 (the runtimes cannot share a binary). UBSAN builds do not
# recover: the first undefined-behaviour hit aborts the server, so a
# build_test.sh gate cannot pass over it.
# The vendored sqlite3 amalgamation is instrumented under ASAN/UBSAN but
# left plain under TSAN: its own mutexes are pthread calls TSan already
# intercepts, and instrumenting 250k lines of third-party C only adds
# noise to a report about this server's threads.
SANITIZE =
ifeq ($(ASAN),1)
  SANITIZE += -fsanitize=address
endif
ifeq ($(UBSAN),1)
  SANITIZE += -fsanitize=undefined -fno-sanitize-recover=undefined
endif
ifeq ($(TSAN),1)
  ifeq ($(ASAN),1)
    $(error TSAN=1 cannot be combined with ASAN=1 -- their runtimes cannot link into the same binary)
  endif
  SANITIZE += -fsanitize=thread
endif
ifneq ($(strip $(SANITIZE)),)
  CXXFLAGS := $(CXXFLAGS) -O1 -g -fno-omit-frame-pointer $(SANITIZE)
  ifneq ($(TSAN),1)
    CFLAGS := $(CFLAGS) -O1 -g -fno-omit-frame-pointer $(SANITIZE)
  endif
endif

# ---- compiler hardening ---------------------------------------------------
# The same posture as service/Makefile: a stack canary, _FORTIFY_SOURCE, a
# stack-clash guard, CET/IBT where the toolchain has it, a position
# independent executable, and a full RELRO with a non-executable stack.
# Every flag is probed, so an older compiler or macOS (no RELRO) still
# builds. _FORTIFY_SOURCE is left out of the sanitizer and coverage builds,
# where it conflicts with the sanitizers' own interceptors.
HARDEN_CXX :=
HARDEN_CXX += $(shell printf 'int fsq_probe(){return 0;}\n' | $(CXX) -O2 -Werror -fstack-protector-strong -x c++ -c - -o /dev/null >/dev/null 2>&1 && echo -fstack-protector-strong)
HARDEN_CXX += $(shell printf 'int fsq_probe(){return 0;}\n' | $(CXX) -O2 -Werror -fstack-clash-protection -x c++ -c - -o /dev/null >/dev/null 2>&1 && echo -fstack-clash-protection)
ifeq ($(shell uname -m),x86_64)
HARDEN_CXX += $(shell printf 'int fsq_probe(){return 0;}\n' | $(CXX) -O2 -Werror -fcf-protection -x c++ -c - -o /dev/null >/dev/null 2>&1 && echo -fcf-protection)
endif
ifeq ($(strip $(SANITIZE)),)
ifeq ($(strip $(COVERAGE)),)
HARDEN_CXX += $(shell printf 'int fsq_probe(){return 0;}\n' | $(CXX) -O2 -Werror -D_FORTIFY_SOURCE=2 -x c++ -c - -o /dev/null >/dev/null 2>&1 && echo -D_FORTIFY_SOURCE=2)
endif
endif
HARDEN_L :=
HARDEN_L += $(shell printf 'int main(){return 0;}\n' | $(CXX) -O2 -pie -x c++ - -o /dev/null >/dev/null 2>&1 && echo -pie)
HARDEN_L += $(shell printf 'int main(){return 0;}\n' | $(CXX) -O2 -Wl,-z,relro,-z,now -x c++ - -o /dev/null >/dev/null 2>&1 && echo -Wl,-z,relro,-z,now)
HARDEN_L += $(shell printf 'int main(){return 0;}\n' | $(CXX) -O2 -Wl,-z,noexecstack -x c++ - -o /dev/null >/dev/null 2>&1 && echo -Wl,-z,noexecstack)

CXXFLAGS := $(CXXFLAGS) $(HARDEN_CXX) -fPIE

SRC  := $(wildcard src/*.cpp) $(wildcard src/adapters/*.cpp)
OBJ  := $(SRC:.cpp=.o)
LIBS := -lssl -lcrypto -lpthread

BIN := fractalsql-druid-mcp

all: $(BIN)

$(BIN): $(OBJ)
	$(CXX) $(CXXFLAGS) $(HARDEN_L) -o $@ $(OBJ) $(LIBS)

%.o: %.cpp
	$(CXX) $(CXXFLAGS) $(DEFS) -Ivendor -Isrc -MMD -MP -c $< -o $@

# Header dependency tracking: without this, a plain `make` after editing a
# header-only change (e.g. bumping kMcpPluginVersion in db.h, with no .cpp
# file's own mtime touched) silently relinks NOTHING -- the rule above only
# lists the .cpp as $(OBJ)'s prerequisite, so make sees every .o as already
# up to date and the existing (now-stale) binary is never rebuilt. The
# -MMD/-MP flags above emit a per-TU .d file recording its actual #include
# graph; pulling those in here is what makes a header edit alone correctly
# trigger a rebuild of every TU that includes it.
-include $(OBJ:.o=.d)

clean:
	rm -f src/*.o src/*.d src/adapters/*.o src/adapters/*.d $(BIN)

.PHONY: all clean