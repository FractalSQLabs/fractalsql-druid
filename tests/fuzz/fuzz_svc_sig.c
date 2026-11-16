/* SPDX-License-Identifier: Apache-2.0
 * SPDX-FileCopyrightText: 2026 Daniel Gardiner d/b/a FractalSQLabs
 *
 * fuzz_svc_sig -- the enterprise library signature gate, fuzzed.
 *
 * The enterprise library is the licensed part of the product: it is
 * dlopen'd, and its bytes are checked against a detached Ed25519 signature
 * before it is loaded. A bug here is either a crash on a malformed file or
 * -- much worse -- an unverified library loaded.
 *
 * The fuzzer input is the CONTENT of the library file; the signature file
 * beside it is a second, derived input (the first 64 bytes of the input,
 * or a fixed pattern), so both the "the .sig is wrong" path and the "the
 * library bytes are wrong" path are exercised.
 *
 * Every input must be refused. The harness checks that: it fails the run
 * if the gate ever says "this library may be loaded".
 */

#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

#include "fractalsql_enterprise.c"

static char g_lib_path[512];
static char g_sig_path[512];

int LLVMFuzzerTestOneInput(const uint8_t *data, size_t size) {
    unsigned char *verified = NULL;
    size_t verified_len = 0;
    bool ok = false;
    char err[256];
    FILE *fp;

    if (size == 0) return 0;

    /* The library file is the fuzzed bytes. */
    fp = fopen(g_lib_path, "wb");
    if (fp == NULL) return 0;
    fwrite(data, 1, size, fp);
    fclose(fp);

    /* The signature file: sometimes the first 64 bytes of the input
     * (so the two files are related), sometimes a fixed pattern, and
     * sometimes nothing at all (the "missing signature" path). */
    switch (data[0] % 3) {
        case 0: {
            uint8_t sig[64];
            size_t n = size < 64 ? size : 64;
            memcpy(sig, data, n);
            if (n < 64) memset(sig + n, 0, 64 - n);
            fp = fopen(g_sig_path, "wb");
            if (fp != NULL) { fwrite(sig, 1, 64, fp); fclose(fp); }
            break;
        }
        case 1: {
            uint8_t sig[64];
            memset(sig, 0xEE, sizeof(sig));
            fp = fopen(g_sig_path, "wb");
            if (fp != NULL) { fwrite(sig, 1, 64, fp); fclose(fp); }
            break;
        }
        default:
            remove(g_sig_path);
            break;
    }

    /* The gate: the enterprise library's own signature check. */
    ok = ent_signature_gate(g_lib_path, &verified, &verified_len, NULL);
    free(verified);
    verified = NULL;
    verified_len = 0;
    if (ok) {
        fprintf(stderr, "sig gate: a fuzzed library was accepted\n");
        abort();
    }

    /* The reasoning plugin's check, which uses the same verifier with a
     * different key and a different policy. */
    err[0] = '\0';
    if (fractal_plugin_verify(g_lib_path, err, sizeof(err))) {
        fprintf(stderr, "plugin verify: a fuzzed plugin was accepted\n");
        abort();
    }

    /* The verifier on its own: the result must be one of the three
     * refusal results, never "verified". */
    {
        ent_sig_result_t r = ent_verify_signature(g_lib_path, FSQL_ENTERPRISE_PUBKEY, NULL, NULL);
        if (r == ENT_SIG_OK) {
            fprintf(stderr, "sig verify: a fuzzed library verified\n");
            abort();
        }
    }
    return 0;
}

__attribute__((constructor))
static void fuzz_svc_sig_setup(void) {
    snprintf(g_lib_path, sizeof g_lib_path, "/tmp/fsql-fuzz-ent-%d.so", (int) getpid());
    snprintf(g_sig_path, sizeof g_sig_path, "%s.sig", g_lib_path);
    unsetenv("FRACTALSQL_ENTERPRISE_REQUIRE_SIGNATURE");
    unsetenv("FRACTALSQL_ENTERPRISE_LIB");
}
