# SPDX-License-Identifier: Apache-2.0
# FractalSQL service build (spec: FRACTALSQL_SPLIT_PROCESS_SPEC.md).
#
# build/fractalsqld     Apache-2.0 daemon (separate process). Compiles the
#                       adapter sources in adapter/src against the vendored
#                       core archive in ../include -- every function body runs
#                       here, in the daemon, never inside a Druid node.
# build/fsqlctl         the daemon's command-line client (health, call, reload).

CC      ?= gcc
# Both overridable from the environment/command line for a cross build
# (e.g. an x86_64 build on an arm64 macOS runner, which has no x86_64
# `uname -m` to detect): FSQ_PLATFORM picks the vendored core archive,
# FSQ_ARCH_FLAGS (e.g. "-arch x86_64") is added to every compile and
# link below so the adapter objects, the daemon, and the core archive
# all end up the same architecture.
FSQ_PLATFORM ?= $(shell uname -s | tr '[:upper:]' '[:lower:]')-$(shell uname -m)
FSQ_ARCH_FLAGS ?=
CORE_ARCHIVE := $(firstword \
    $(wildcard ../include/$(FSQ_PLATFORM)/libfractalsql-community-sovereign-c.a) \
    ../include/libfractalsql-community-sovereign-c.a)

# OpenSSL for fsqlctl.c's <openssl/hmac.h> use and for
# fractalsql_enterprise.c's Ed25519 check (via ADAPTER_OBJS/CORE_ARCHIVE
# below). Homebrew's openssl@3 is keg-only, so Darwin needs its own path.
# FSQ_OPENSSL_DIR is overridable too: arm-Homebrew's openssl@3 keg has
# no x86_64 objects, so an x86_64 cross build needs a separately built
# tree (see release.yml's build-macos job) passed in explicitly.
ifeq ($(shell uname -s),Darwin)
  FSQ_OPENSSL_DIR ?= $(shell brew --prefix openssl@3 2>/dev/null)
  ifeq ($(strip $(FSQ_OPENSSL_DIR)),)
    $(error darwin build needs Homebrew's openssl@3: brew install openssl@3)
  endif
  FSQ_OPENSSL_CFLAGS  := -I$(FSQ_OPENSSL_DIR)/include
  FSQ_OPENSSL_LDFLAGS := $(FSQ_OPENSSL_DIR)/lib/libcrypto.a
  FSQ_SHARED          := -dynamiclib
else
  FSQ_OPENSSL_CFLAGS  :=
  FSQ_OPENSSL_LDFLAGS := -lcrypto
  FSQ_SHARED          := -shared
endif

BUILD   := build
GEN     := $(BUILD)/gen
ADAPTER_SRCS := $(wildcard adapter/src/*.c)
ADAPTER_OBJS := $(patsubst adapter/src/%.c,$(BUILD)/daemon/%.o,$(ADAPTER_SRCS))

WARN    := -Wall -Wextra -Werror -std=gnu11
CFLAGS  ?= -O2 -g

# The precision contract (precision plan R3): the files that carry a
# float path are built with contraction OFF and with the vectoriser
# disabled, so the double accumulation in adapter/src/fsql_precision.h is
# exactly what runs -- no fused multiply-add, no reassociated reduction.
# The core archive is built with the same flags on the core's side.
FSQ_PRECISION_FLAGS := -ffp-contract=off -fno-tree-vectorize
# fractalsql_vector.c carries the SQL-visible distances/norms/dots;
# fractalsql_index.c carries the verification cosine and the IVF maths.
FSQ_PRECISION_FLAGS_fractalsql_vector := $(FSQ_PRECISION_FLAGS)
FSQ_PRECISION_FLAGS_fractalsql_index  := $(FSQ_PRECISION_FLAGS)

# make COVERAGE=1 / ASAN=1 / UBSAN=1: instrument the daemon (adapter
# objects + fractalsqld.c), for build_test.sh
# --coverage/--asan/--ubsan/--tsan.
ifdef COVERAGE
  FSQ_SAN_FLAGS := --coverage
else ifdef ASAN
  FSQ_SAN_FLAGS := -fsanitize=address -fno-omit-frame-pointer
else ifdef UBSAN
  FSQ_SAN_FLAGS := -fsanitize=undefined -fno-sanitize-recover=undefined
else ifdef TSAN
  FSQ_SAN_FLAGS := -fsanitize=thread
else
  FSQ_SAN_FLAGS :=
endif

# ---- compiler hardening ---------------------------------------------------
# The daemon listens on a socket and parses text it did not choose, so it is
# built with the standard hardening flags: a stack canary, _FORTIFY_SOURCE, a
# stack-clash guard, CET/IBT where the toolchain has it, a position
# independent executable, and a full RELRO with a non-executable stack.
#
# Every flag is probed rather than assumed: the compiler decides whether it
# accepts it, so an older GCC, a Clang without -fstack-clash-protection, or
# macOS (no RELRO, PIE by default) still builds. build_test.sh's gate 32
# checks that the produced binaries really carry the properties.
#
# _FORTIFY_SOURCE is left out of the sanitizer and coverage builds: it needs
# optimisation to do anything, and it conflicts with the sanitizers' own
# interceptors. The other flags are harmless there and stay on.
FSQ_PROBE := printf 'int fsq_probe(void){return 0;}\n'
HARDEN_C :=
HARDEN_C += $(shell printf 'int fsq_probe(void){return 0;}\n' | $(CC) -O2 -Werror -fstack-protector-strong -x c -c - -o /dev/null >/dev/null 2>&1 && echo -fstack-protector-strong)
HARDEN_C += $(shell printf 'int fsq_probe(void){return 0;}\n' | $(CC) -O2 -Werror -fstack-clash-protection -x c -c - -o /dev/null >/dev/null 2>&1 && echo -fstack-clash-protection)
ifeq ($(shell uname -m),x86_64)
HARDEN_C += $(shell printf 'int fsq_probe(void){return 0;}\n' | $(CC) -O2 -Werror -fcf-protection -x c -c - -o /dev/null >/dev/null 2>&1 && echo -fcf-protection)
endif
ifeq ($(strip $(FSQ_SAN_FLAGS)),)
HARDEN_C += $(shell printf 'int fsq_probe(void){return 0;}\n' | $(CC) -O2 -Werror -D_FORTIFY_SOURCE=2 -x c -c - -o /dev/null >/dev/null 2>&1 && echo -D_FORTIFY_SOURCE=2)
endif
HARDEN_L :=
HARDEN_L += $(shell printf 'int main(void){return 0;}\n' | $(CC) -O2 -pie -x c - -o /dev/null >/dev/null 2>&1 && echo -pie)
HARDEN_L += $(shell printf 'int main(void){return 0;}\n' | $(CC) -O2 -Wl,-z,relro,-z,now -x c - -o /dev/null >/dev/null 2>&1 && echo -Wl,-z,relro,-z,now)
HARDEN_L += $(shell printf 'int main(void){return 0;}\n' | $(CC) -O2 -Wl,-z,noexecstack -x c - -o /dev/null >/dev/null 2>&1 && echo -Wl,-z,noexecstack)
# A shared object is not position independent executable, and its link takes
# the relocation and stack flags but not -pie.
HARDEN_SO_L := $(filter-out -pie,$(HARDEN_L))

DAEMON_SRC := daemon/fractalsqld.c common/fsq_sha256.h protocol/fsq_protocol.h protocol/opcodes.def

.PHONY: all daemon clean

all: daemon $(BUILD)/fsqlctl

daemon: $(BUILD)/fractalsqld

$(GEN)/daemon_udfs.h $(GEN)/fsqlctl_functions.h: protocol/opcodes.def protocol/functions.def scripts/gen_udf.py
	python3 scripts/gen_udf.py $(GEN)

$(BUILD):
	mkdir -p $(BUILD)


$(BUILD)/daemon:
	mkdir -p $@

$(BUILD)/daemon/%.o: adapter/src/%.c | $(BUILD)/daemon
	$(CC) -Wall -Wextra -Werror -O2 -g -fPIC $(HARDEN_C) $(FSQ_ARCH_FLAGS) -I../include -Iadapter/src $(FSQ_OPENSSL_CFLAGS) $(FSQ_SAN_FLAGS) $(FSQ_PRECISION_FLAGS_$*) -c -o $@ $<

# The daemon TU is compiled to an object next to the adapter objects
# instead of on the link line, so its -coverage .gcno lands in
# $(BUILD)/daemon/ and lcov pairs it with the .gcda build_test.sh copies in.
$(BUILD)/daemon/fractalsqld.o: daemon/fractalsqld.c $(DAEMON_SRC) $(GEN)/daemon_udfs.h | $(BUILD)/daemon
	$(CC) -Wall -Wextra -Werror -std=gnu11 $(CFLAGS) $(HARDEN_C) -fPIE $(FSQ_ARCH_FLAGS) -I../include -Iadapter/src -I$(GEN) $(FSQ_SAN_FLAGS) -c -o $@ $<

$(BUILD)/fractalsqld: $(BUILD)/daemon/fractalsqld.o $(ADAPTER_OBJS) $(CORE_ARCHIVE) | $(BUILD)
	$(CC) -Wall -Wextra -Werror -std=gnu11 $(CFLAGS) $(FSQ_ARCH_FLAGS) -I../include -Iadapter/src -I$(GEN) $(FSQ_SAN_FLAGS) $(HARDEN_L) \
	    -o $@ $(BUILD)/daemon/fractalsqld.o $(ADAPTER_OBJS) $(CORE_ARCHIVE) -lm -lpthread -ldl $(FSQ_OPENSSL_LDFLAGS)

$(BUILD)/fsqlctl: cli/fsqlctl.c $(GEN)/fsqlctl_functions.h | $(BUILD)
	$(CC) -Wall -Wextra -Werror -std=gnu11 -O2 $(HARDEN_C) -fPIE $(FSQ_ARCH_FLAGS) -I$(GEN) $(FSQ_OPENSSL_CFLAGS) $(HARDEN_L) -o $@ cli/fsqlctl.c $(FSQ_OPENSSL_LDFLAGS)

clean:
	rm -rf $(BUILD)

# ---- the JVM fractalsqld ------------------------------------------------
# build/jvm/libfsqld_jni.so   the function bodies, for the JVM server (JNI)
# build/jvm/fractalsqld.jar   the server (javac + jar, no other dependencies)
JAVA_HOME ?= $(shell dirname $$(dirname $$(readlink -f $$(which javac))))
JNI_CFLAGS := -I$(JAVA_HOME)/include -I$(JAVA_HOME)/include/$(shell uname -s | tr '[:upper:]' '[:lower:]')
JVM_SRCS := $(wildcard jvm/src/main/java/com/fractalsqlabs/fractalsql/daemon/*.java)

.PHONY: jvm jvm-native jvm-jar jvm-test

jvm: jvm-native jvm-jar

jvm-native: $(BUILD)/jvm/libfsqld_jni.so

$(BUILD)/jvm:
	mkdir -p $@

$(BUILD)/jvm/libfsqld_jni.so: jvm/src/main/native/fsqld_jni.c $(GEN)/daemon_udfs.h $(ADAPTER_OBJS) $(CORE_ARCHIVE) | $(BUILD)/jvm
	$(CC) -Wall -Wextra -Werror -std=gnu11 $(CFLAGS) $(FSQ_ARCH_FLAGS) -fPIC $(HARDEN_C) $(FSQ_SHARED) $(HARDEN_SO_L) $(JNI_CFLAGS) -I../include -Iadapter/src -I$(GEN) \
	    -o $@ jvm/src/main/native/fsqld_jni.c $(ADAPTER_OBJS) $(CORE_ARCHIVE) -lm -lpthread -ldl $(FSQ_OPENSSL_LDFLAGS)

jvm-jar: $(BUILD)/jvm/fractalsqld.jar

$(BUILD)/jvm/fractalsqld.jar: $(JVM_SRCS) | $(BUILD)/jvm
	rm -rf $(BUILD)/jvm/classes && mkdir -p $(BUILD)/jvm/classes
	javac --release 17 -Xlint:all -Werror -d $(BUILD)/jvm/classes $(JVM_SRCS)
	jar --create --file $@ --main-class com.fractalsqlabs.fractalsql.daemon.Fsqld -C $(BUILD)/jvm/classes .

# The server's self-test: the parts that need no native library.
jvm-test: jvm-jar
	rm -rf $(BUILD)/jvm/test-classes && mkdir -p $(BUILD)/jvm/test-classes
	javac --release 17 -Xlint:all -Werror -cp $(BUILD)/jvm/classes -d $(BUILD)/jvm/test-classes jvm/src/test/java/com/fractalsqlabs/fractalsql/daemon/SelfTest.java
	java -cp $(BUILD)/jvm/classes:$(BUILD)/jvm/test-classes com.fractalsqlabs.fractalsql.daemon.SelfTest
