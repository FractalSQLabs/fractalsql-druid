/* SPDX-License-Identifier: Apache-2.0
 * SPDX-FileCopyrightText: 2026 Daniel Gardiner d/b/a FractalSQLabs
 *
 * Allocation-failure injection for the test gates: LD_PRELOAD this and malloc, calloc and realloc fail at random.
 *
 *   FSQL_OOM_PERMILLE  chance, in thousandths, that an allocation fails (default 5)
 *   FSQL_OOM_SEED      seed of the generator (default 1)
 *   FSQL_OOM_AFTER     allocations to let through before the first failure (default 20000, past start-up)
 *
 * Only allocations made by the executable itself fail (the daemon and its adapter); the libraries it uses (OpenSSL, libcurl, libc)
 * are not made to fail, because they do not promise to survive it.
 *
 * SIGUSR2 turns the injection off, so a daemon can shut down and write its coverage data without failing there.
 * Used only by build_test.sh --fault and --coverage; never shipped.
 */
#define _GNU_SOURCE
#include <dlfcn.h>
#include <link.h>
#include <errno.h>
#include <signal.h>
#include <stdatomic.h>
#include <stdint.h>
#include <stdlib.h>
#include <string.h>

static void *(*real_malloc)(size_t);
static void *(*real_calloc)(size_t, size_t);
static void *(*real_realloc)(void *, size_t);
static _Atomic uint64_t rng = 1, seen = 0;
static _Atomic int off = 0, resolving = 0;
static unsigned permille = 5;
static uint64_t after = 20000;
static char boot[65536];
static size_t boot_used;

static uintptr_t exe_lo, exe_hi;

static int find_exe(struct dl_phdr_info *i, size_t sz, void *d)
{
    (void) sz; (void) d;
    for (int k = 0; k < i->dlpi_phnum; k++)
        if (i->dlpi_phdr[k].p_type == PT_LOAD && (i->dlpi_phdr[k].p_flags & PF_X)) {
            exe_lo = i->dlpi_addr + i->dlpi_phdr[k].p_vaddr;
            exe_hi = exe_lo + i->dlpi_phdr[k].p_memsz;
        }
    return 1;   /* the first object is the executable */
}

static void stop(int s) { (void) s; atomic_store(&off, 1); }

__attribute__((constructor)) static void oom_init(void)
{
    const char *p = getenv("FSQL_OOM_PERMILLE"), *s = getenv("FSQL_OOM_SEED"), *a = getenv("FSQL_OOM_AFTER");
    if (p) permille = (unsigned) strtoul(p, NULL, 10);
    if (s) atomic_store(&rng, strtoull(s, NULL, 10) * 2654435761u + 1);
    if (a) after = strtoull(a, NULL, 10);
    dl_iterate_phdr(find_exe, NULL);
    signal(SIGUSR2, stop);
}

static void resolve(void)
{
    if (real_malloc) return;
    atomic_store(&resolving, 1);
    real_calloc = dlsym(RTLD_NEXT, "calloc");
    real_realloc = dlsym(RTLD_NEXT, "realloc");
    real_malloc = dlsym(RTLD_NEXT, "malloc");
    atomic_store(&resolving, 0);
}

static int fail_now(void *caller)
{
    if ((uintptr_t) caller < exe_lo || (uintptr_t) caller >= exe_hi) return 0;
    if (atomic_load(&off) || atomic_fetch_add(&seen, 1) < after) return 0;
    uint64_t x = atomic_load(&rng);
    x ^= x << 13; x ^= x >> 7; x ^= x << 17;   /* xorshift64: racy between threads, which only adds noise */
    atomic_store(&rng, x);
    return (x % 1000) < permille;
}

void *malloc(size_t n)
{
    if (atomic_load(&resolving)) { void *b = boot + boot_used; boot_used += (n + 15) & ~(size_t) 15; return boot_used <= sizeof boot ? b : NULL; }
    resolve();
    if (fail_now(__builtin_return_address(0))) { errno = ENOMEM; return NULL; }
    return real_malloc(n);
}

void *calloc(size_t a, size_t b)
{
    if (atomic_load(&resolving)) { void *p = boot + boot_used; boot_used += (a * b + 15) & ~(size_t) 15; return boot_used <= sizeof boot ? p : NULL; }
    resolve();
    if (fail_now(__builtin_return_address(0))) { errno = ENOMEM; return NULL; }
    return real_calloc(a, b);
}

void *realloc(void *p, size_t n)
{
    resolve();
    if (fail_now(__builtin_return_address(0))) { errno = ENOMEM; return NULL; }
    return real_realloc(p, n);
}
