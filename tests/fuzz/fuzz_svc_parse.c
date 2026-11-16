/* SPDX-License-Identifier: Apache-2.0
 * SPDX-FileCopyrightText: 2026 Daniel Gardiner d/b/a FractalSQLabs
 *
 * fuzz_svc_parse -- the vector, corpus and index text parsers, fuzzed.
 *
 * These are the parsers every text-shaped argument in the service goes
 * through: a vector ("[1,2,3]"), a corpus ("[1,2,3];[4,5,6]"), an edge or
 * face index list ("0,1,2"). fractal_embed's raw provider response body
 * reaches parse_vector_csv before any allowlist or schema check, so it is
 * the one genuinely externally-adversarial input in this code.
 *
 * The second half of the harness takes what the parser produced and
 * formats it back out again (fractal_vector_to_json), so the text
 * formatter -- the other side of the same round trip -- is exercised on
 * every input the parser accepted.
 */

#include <stdbool.h>
#include <stdint.h>
#include <stdlib.h>
#include <string.h>

#include "fsql_udf_types.h"
#include "fractalsql_parse.h"

/* The exported vector formatters, called the way the daemon calls them. */
extern bool fractal_vector_to_json_init(UDF_INIT *, UDF_ARGS *, char *);
extern char *fractal_vector_to_json(UDF_INIT *, UDF_ARGS *, char *, unsigned long *, char *, char *);
extern void fractal_vector_to_json_deinit(UDF_INIT *);

#define FSQL_ERRMSG_SIZE_LOCAL 512

int LLVMFuzzerTestOneInput(const uint8_t *data, size_t size) {
    char errmsg[FSQL_ERRMSG_SIZE_LOCAL];
    double *vec = NULL;
    size_t n = 0;
    size_t n_rows = 0, dim = 0;
    size_t *idx = NULL;
    size_t n_idx = 0;
    size_t expected_dim;

    if (size == 0) return 0;

    memset(errmsg, 0, sizeof(errmsg));

    /* The expected dimension is the first byte, so the corpus parser is
     * exercised both with a dimension to enforce and with 0 (infer it). */
    expected_dim = size > 1 ? (size_t) (data[0] % 8) : 0;

    /* parse_vector_csv: a vector's text form. */
    if (parse_vector_csv((const char *) data, size, &vec, &n, errmsg)) {
        UDF_INIT init;
        UDF_ARGS args;
        enum Item_result type = STRING_RESULT;
        char *vals[1];
        unsigned long lens[1];
        char nul[1];
        char *attrs[1];
        unsigned long attrlens[1];
        char msg[FSQL_ERRMSG_SIZE_LOCAL];
        char result[64];
        unsigned long length = 0;
        char is_null = 0, error = 0;

        memset(&init, 0, sizeof(init));
        memset(&args, 0, sizeof(args));
        memset(vals, 0, sizeof(vals));
        memset(lens, 0, sizeof(lens));
        memset(nul, 0, sizeof(nul));
        memset(attrs, 0, sizeof(attrs));
        memset(attrlens, 0, sizeof(attrlens));
        msg[0] = '\0';

        vals[0] = (char *) data;
        lens[0] = (unsigned long) size;
        nul[0] = 1;
        args.arg_count = 1;
        args.arg_type = &type;
        args.args = vals;
        args.lengths = lens;
        args.maybe_null = nul;
        args.attributes = attrs;
        args.attribute_lengths = attrlens;

        /* The formatter's own init/call/deinit, so the vector that came
         * out of the parser goes back through the text formatter. */
        if (!fractal_vector_to_json_init(&init, &args, msg)) {
            fractal_vector_to_json(&init, &args, result, &length, &is_null, &error);
            fractal_vector_to_json_deinit(&init);
        }
        free(vec);
        vec = NULL;
    }

    /* parse_corpus: fractal_search's corpus argument. */
    (void) parse_corpus((const char *) data, size, expected_dim, &vec, &n_rows, &dim, errmsg);
    free(vec);
    vec = NULL;

    /* parse_index_csv: the Analytics-tier edge and face indices. */
    (void) parse_index_csv((const char *) data, size, &idx, &n_idx, errmsg);
    free(idx);

    return 0;
}
