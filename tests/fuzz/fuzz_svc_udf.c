/* SPDX-License-Identifier: Apache-2.0
 * SPDX-FileCopyrightText: 2026 Daniel Gardiner d/b/a FractalSQLabs
 *
 * fuzz_svc_udf -- the daemon's UDF layer, fuzzed.
 *
 * This is the highest-value target in the service: the adapter's function
 * bodies are what turn untrusted text (a vector, a series, a JSON payload,
 * a statement) into structures, and every one of them is reachable from the
 * wire through this one calling convention.
 *
 * The harness picks a function from the first input byte and builds a
 * UDF_ARGS from the rest, then calls the function exactly as the daemon's
 * dispatcher does: the init triad first, then the body with the kind's
 * signature, then the deinit. The dispatcher is the reference:
 * service/daemon/fractalsqld.c's handle_init and handle_call.
 *
 * The input format is the one service/tests/workout.py writes when it is
 * asked to dump its corpus (FSQL_WORKOUT_DUMP_CORPUS):
 *
 *   byte 0      the length of the function's name
 *   bytes       the function's name
 *   byte        the argument count, 0..8
 *   per argument:
 *     byte      bit 0: the argument is NULL
 *               bits 1-2: 0 string, 1 int, 2 real
 *     u32 LE    the argument's byte length
 *     bytes     the argument's value (an int or a real uses the first 8
 *               bytes, little-endian, as the daemon stores them)
 *
 * The reasoning functions run with no provider configured, so their error
 * path is what is exercised. fractal_lock_destructive is skipped: it is a
 * one-way latch that would make every later call in the same process fail.
 */

#include <stdbool.h>
#include <stdint.h>
#include <stdlib.h>
#include <string.h>

#include "fsql_udf_types.h"

/* The daemon's own declarations of the registry's shape, so the generated
 * table below is the one the daemon itself dispatches through. */
enum fsq_kind { FSQ_KIND_CTL, FSQ_KIND_STR, FSQ_KIND_INT, FSQ_KIND_REAL };

struct fsq_fn {
    const char *name;
    enum fsq_kind kind;
    void *init;
    void *deinit;
    void *main;
};

#include "daemon_udfs.h"

typedef char *(*fsq_str_fn)(UDF_INIT *, UDF_ARGS *, char *, unsigned long *, char *, char *);
typedef long long (*fsq_int_fn)(UDF_INIT *, UDF_ARGS *, char *, char *);
typedef double (*fsq_real_fn)(UDF_INIT *, UDF_ARGS *, char *, char *);
typedef bool (*fsq_init_fn)(UDF_INIT *, UDF_ARGS *, char *);
typedef void (*fsq_deinit_fn)(UDF_INIT *);

#define FUZZ_MAX_ARGS 8

static uint32_t rd_u32(const uint8_t *p) {
    return (uint32_t) p[0] | ((uint32_t) p[1] << 8) |
           ((uint32_t) p[2] << 16) | ((uint32_t) p[3] << 24);
}

int LLVMFuzzerTestOneInput(const uint8_t *data, size_t size) {
    const size_t nfn = sizeof(g_fn_table) / sizeof(g_fn_table[0]);
    const struct fsq_fn *f = NULL;
    size_t namelen;
    size_t k;

    if (size < 2) return 0;

    /* The function is named, not indexed: the corpus service/tests/workout.py
     * writes carries names, and the registry's order is not something a
     * corpus file should depend on. */
    namelen = data[0];
    if (namelen == 0 || namelen + 2 > size) return 0;
    for (k = 0; k < nfn; k++) {
        if (strlen(g_fn_table[k].name) == namelen &&
            memcmp(g_fn_table[k].name, data + 1, namelen) == 0) {
            f = &g_fn_table[k];
            break;
        }
    }
    if (f == NULL) return 0;
    if (f->kind == FSQ_KIND_CTL) return 0;
    if (strcmp(f->name, "fractal_lock_destructive") == 0) return 0;

    unsigned int nargs = data[1 + namelen] % (FUZZ_MAX_ARGS + 1);

    UDF_INIT init;
    UDF_ARGS args;
    char msg[FSQL_ERRMSG_SIZE];
    char *bufs[FUZZ_MAX_ARGS];
    unsigned long lens[FUZZ_MAX_ARGS];
    enum Item_result types[FUZZ_MAX_ARGS];
    char nul[FUZZ_MAX_ARGS];
    char *attrs[FUZZ_MAX_ARGS];
    unsigned long attrlens[FUZZ_MAX_ARGS];
    size_t off = 2 + namelen;
    unsigned int i;

    memset(&init, 0, sizeof(init));
    memset(&args, 0, sizeof(args));
    memset(bufs, 0, sizeof(bufs));
    memset(lens, 0, sizeof(lens));
    memset(types, 0, sizeof(types));
    memset(nul, 0, sizeof(nul));
    memset(attrs, 0, sizeof(attrs));
    memset(attrlens, 0, sizeof(attrlens));
    msg[0] = '\0';

    for (i = 0; i < nargs; i++) {
        uint8_t spec;
        uint32_t len;
        if (off >= size) break;
        spec = data[off++];
        len = 0;
        if (off + 4 <= size) { len = rd_u32(data + off); off += 4; }
        if (len > size - off) len = (uint32_t) (size - off);
        if (spec & 1) {                     /* NULL argument */
            types[i] = STRING_RESULT;
            bufs[i] = NULL;
            lens[i] = 0;
            off += len;
            continue;
        }
        switch ((spec >> 1) & 3) {
            case 1: types[i] = INT_RESULT; break;
            case 2: types[i] = REAL_RESULT; break;
            default: types[i] = STRING_RESULT; break;
        }
        if (types[i] == INT_RESULT || types[i] == REAL_RESULT) {
            /* The daemon stores an int or a real argument as eight raw
             * bytes, and the body reads it back as a long long or a
             * double through that pointer. */
            unsigned char v[8];
            memset(v, 0, sizeof(v));
            memcpy(v, data + off, len < 8 ? len : 8);
            bufs[i] = (char *) malloc(sizeof(v));
            if (bufs[i] == NULL) break;
            memcpy(bufs[i], v, sizeof(v));
            lens[i] = 8;
            off += len;
        } else {
            bufs[i] = (char *) malloc((size_t) len + 1);
            if (bufs[i] == NULL) break;
            memcpy(bufs[i], data + off, len);
            bufs[i][len] = '\0';
            lens[i] = len;
            off += len;
        }
        nul[i] = 1;
    }

    args.arg_count = i;
    args.arg_type = types;
    args.args = bufs;
    args.lengths = lens;
    args.maybe_null = nul;
    args.attributes = attrs;
    args.attribute_lengths = attrlens;

    /* The dispatcher calls init first. A function that refuses its
     * arguments at init is never called, and its deinit is not called
     * either -- the daemon frees the handle and its argument copies. */
    if (!((fsq_init_fn) f->init)(&init, &args, msg)) {
        char is_null = 0, error = 0;
        unsigned long length = 0;
        char result[64];
        /* The init may have settled on a different type for an argument
         * than the one the caller sent. The daemon's CALL path then
         * lays the arguments out again by the settled type: an int or a
         * real argument is eight raw bytes, and a call that does not
         * carry eight bytes for one is refused before the body runs.
         * The harness does the same, so a coerced argument is never
         * read as more bytes than it holds. */
        int refused = 0;
        for (i = 0; i < args.arg_count; i++) {
            if (args.args[i] == NULL) continue;
            if (args.arg_type[i] == INT_RESULT || args.arg_type[i] == REAL_RESULT) {
                if (lens[i] != 8) { refused = 1; break; }
            }
        }
        if (!refused) {
            switch (f->kind) {
                case FSQ_KIND_STR:
                    result[0] = '\0';
                    ((fsq_str_fn) f->main)(&init, &args, result, &length, &is_null, &error);
                    break;
                case FSQ_KIND_INT:
                    (void) ((fsq_int_fn) f->main)(&init, &args, &is_null, &error);
                    break;
                case FSQ_KIND_REAL:
                    (void) ((fsq_real_fn) f->main)(&init, &args, &is_null, &error);
                    break;
                default:
                    break;
            }
        }
        ((fsq_deinit_fn) f->deinit)(&init);
    }

    for (i = 0; i < FUZZ_MAX_ARGS; i++) free(bufs[i]);
    return 0;
}
