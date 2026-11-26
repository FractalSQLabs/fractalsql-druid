/* src/main/native/fractalsql_jni.c
 *
 * JNI shim for libfractalsql-core -- the bridge between the Druid
 * extension's Java classes and the pure-C FractalSQL core.
 *
 * SPDX-License-Identifier: Apache-2.0 AND BSD-2-Clause
 * SPDX-FileCopyrightText: 2026 Daniel Gardiner d/b/a FractalSQLabs
 *
 * This file is a TRANSLATION LAYER ONLY. It contains no FractalSQL
 * algorithm: every call forwards to the vendored core archive in
 * ../../include/<os>-<arch>/, which is linked at build time and never
 * modified.
 *
 * The shim exists because Druid's extension ABI is Java, and Druid
 * offers no native-plugin interface of its own (the only JNI in Druid
 * is internal, org.apache.druid.java.util.common.io.NativeIO). So a
 * Java extension that wants the core must carry its own native
 * payload -- which is what this is.
 *
 * Built per platform:
 *   linux-x86_64    libfractalsql-jni.so
 *   linux-aarch64   libfractalsql-jni.so
 *   darwin-x86_64   libfractalsql-jni.dylib
 *   darwin-arm64    libfractalsql-jni.dylib
 */

/*
 * setenv and unsetenv are POSIX, not ISO C, and a strict -std=c11
 * hides their declarations -- the calls then come back as implicit
 * int. They must be requested before the first system header.
 */
#  ifndef _DEFAULT_SOURCE
#    define _DEFAULT_SOURCE 1
#  endif
#  ifndef _POSIX_C_SOURCE
#    define _POSIX_C_SOURCE 200809L
#  endif
#  ifndef _GNU_SOURCE
#    define _GNU_SOURCE 1
#  endif

#include <jni.h>

#include <math.h>
#include <stdint.h>
#include <stdlib.h>
#include <string.h>

#include "fractalsql.h"
#include "fractalsql_sql.h"

/* The core ctx is an opaque pointer; Java holds it as a jlong. */
#define CTX(ptr) ((fsql_ctx *)(intptr_t)(ptr))

/*
 * The Java-side class these entry points belong to. If the Java class
 * is renamed or moved, these names must change with it -- a mismatch
 * shows up as UnsatisfiedLinkError at the first call, which is why the
 * build_test.sh gate exercises every one of them.
 */
#define JCLASS "com/fractalsqlabs/fractalsql/druid/Native"

/* ------------------------------------------------------------------ */
/* Informational                                                       */
/* ------------------------------------------------------------------ */

JNIEXPORT jstring JNICALL
Java_com_fractalsqlabs_fractalsql_druid_Native_edition(JNIEnv *env, jclass cls)
{
    (void) cls;
    return (*env)->NewStringUTF(env, fsql_edition());
}

JNIEXPORT jstring JNICALL
Java_com_fractalsqlabs_fractalsql_druid_Native_storage(JNIEnv *env, jclass cls)
{
    (void) cls;
    return (*env)->NewStringUTF(env, fsql_storage());
}

JNIEXPORT jstring JNICALL
Java_com_fractalsqlabs_fractalsql_druid_Native_version(JNIEnv *env, jclass cls)
{
    (void) cls;
    return (*env)->NewStringUTF(env, fsql_version());
}

JNIEXPORT jstring JNICALL
Java_com_fractalsqlabs_fractalsql_druid_Native_abiVersion(JNIEnv *env, jclass cls)
{
    (void) cls;
    return (*env)->NewStringUTF(env, fsql_abi_version());
}

/* ------------------------------------------------------------------ */
/* Context lifecycle                                                   */
/* ------------------------------------------------------------------ */

/*
 * New sovereign context.
 *
 * The ledger and the reasoning plugin live in fractalsqld, so this context
 * carries neither a storage VFS nor a reasoning VFS: it serves the search
 * and the session state of this node.
 *
 * Returns a handle, or 0 on allocation failure.
 */
JNIEXPORT jlong JNICALL
Java_com_fractalsqlabs_fractalsql_druid_Native_newSovereign(JNIEnv *env, jclass cls)
{
    (void) env;
    (void) cls;
    fsql_ctx *ctx = fsql_new_sovereign(NULL, NULL);
    return (jlong)(intptr_t) ctx;
}

/* Minimal-tier context (no sovereign symbols). */
JNIEXPORT jlong JNICALL
Java_com_fractalsqlabs_fractalsql_druid_Native_newMinimal(JNIEnv *env, jclass cls)
{
    (void) env;
    (void) cls;
    fsql_ctx *ctx = fsql_new_minimal();
    return (jlong)(intptr_t) ctx;
}

JNIEXPORT void JNICALL
Java_com_fractalsqlabs_fractalsql_druid_Native_free(JNIEnv *env, jclass cls, jlong handle)
{
    (void) env;
    (void) cls;
    fsql_ctx *ctx = CTX(handle);
    if (ctx) {
        fsql_free(ctx);
    }
}

/* Early-free the result buffer; the ctx stays usable. */
JNIEXPORT void JNICALL
Java_com_fractalsqlabs_fractalsql_druid_Native_release(JNIEnv *env, jclass cls, jlong handle)
{
    (void) env;
    (void) cls;
    fsql_ctx *ctx = CTX(handle);
    if (ctx) {
        fsql_release(ctx);
    }
}

/* Last error text for a ctx, or "" if none / handle is null. */
JNIEXPORT jstring JNICALL
Java_com_fractalsqlabs_fractalsql_druid_Native_lastError(JNIEnv *env, jclass cls, jlong handle)
{
    (void) env;
    (void) cls;
    fsql_ctx *ctx = CTX(handle);
    const char *err = ctx ? fsql_last_error(ctx) : NULL;
    return (*env)->NewStringUTF(env, err ? err : "");
}

/* ------------------------------------------------------------------ */
/* Search (corpus)                                                     */
/* ------------------------------------------------------------------ */

/*
 * Zero-copy corpus search. The corpus is a flat row-major double[]
 * of n_rows x dim; the query is query_dim doubles. Returns the core's
 * result JSON as a byte[], or null if the call failed (the reason is
 * on the ctx, readable via nLastError).
 *
 * This is the whole-corpus entry point the Druid aggregate uses: the
 * SFS optimizer converges over the corpus, then ranks.
 */
JNIEXPORT jbyteArray JNICALL
Java_com_fractalsqlabs_fractalsql_druid_Native_searchPtr(
    JNIEnv *env, jclass cls, jlong handle,
    jdoubleArray corpus, jint nRows, jint dim,
    jdoubleArray query, jint queryDim,
    jint k, jbyteArray params)
{
    (void) cls;
    fsql_ctx *ctx = CTX(handle);
    if (!ctx || !corpus || !query) {
        return NULL;
    }
    if (nRows <= 0 || dim <= 0 || queryDim <= 0) {
        return NULL;
    }
    /* The corpus must be exactly n_rows x dim; a mismatch is a caller bug. */
    if ((*env)->GetArrayLength(env, corpus) < (jsize)((jlong)nRows * (jlong)dim)) {
        return NULL;
    }
    if ((*env)->GetArrayLength(env, query) < queryDim) {
        return NULL;
    }

    jdouble *cptr = (*env)->GetDoubleArrayElements(env, corpus, NULL);
    jdouble *qptr = (*env)->GetDoubleArrayElements(env, query, NULL);
    if (!cptr || !qptr) {
        if (cptr) {
            (*env)->ReleaseDoubleArrayElements(env, corpus, cptr, JNI_ABORT);
        }
        if (qptr) {
            (*env)->ReleaseDoubleArrayElements(env, query, qptr, JNI_ABORT);
        }
        return NULL;
    }

    char *params_c = NULL;
    jsize params_len = 0;
    if (params) {
        params_len = (*env)->GetArrayLength(env, params);
        params_c = (char *)malloc((size_t)params_len + 1);
        if (!params_c) {
            (*env)->ReleaseDoubleArrayElements(env, corpus, cptr, JNI_ABORT);
            (*env)->ReleaseDoubleArrayElements(env, query, qptr, JNI_ABORT);
            return NULL;
        }
        (*env)->GetByteArrayRegion(env, params, 0, params_len, (jbyte *)params_c);
        params_c[params_len] = '\0';
    }

    const char *result_json = NULL;
    size_t result_len = 0;
    int rc = fsql_search_ptr(
        ctx,
        cptr, (size_t)nRows, (size_t)dim,
        qptr, (size_t)queryDim,
        (int)k,
        params_c, (size_t)params_len,
        &result_json, &result_len);

    (*env)->ReleaseDoubleArrayElements(env, corpus, cptr, JNI_ABORT);
    (*env)->ReleaseDoubleArrayElements(env, query, qptr, JNI_ABORT);
    free(params_c);

    if (rc != FSQL_OK || !result_json) {
        return NULL;
    }

    jbyteArray out = (*env)->NewByteArray(env, (jsize)result_len);
    if (!out) {
        return NULL;
    }
    (*env)->SetByteArrayRegion(env, out, 0, (jsize)result_len, (const jbyte *)result_json);
    return out;
}

/*
 * Text-form search: corpus and query as the core's CSV / bracketed-JSON
 * text form. Returns the result JSON as a byte[], or null on failure.
 */
JNIEXPORT jbyteArray JNICALL
Java_com_fractalsqlabs_fractalsql_druid_Native_searchText(
    JNIEnv *env, jclass cls, jlong handle,
    jbyteArray corpus, jbyteArray query, jint k, jbyteArray params)
{
    (void) cls;
    fsql_ctx *ctx = CTX(handle);
    if (!ctx || !corpus || !query) {
        return NULL;
    }

    jsize corpus_len = (*env)->GetArrayLength(env, corpus);
    jsize query_len = (*env)->GetArrayLength(env, query);
    char *corpus_c = (char *)malloc((size_t)corpus_len + 1);
    char *query_c = (char *)malloc((size_t)query_len + 1);
    if (!corpus_c || !query_c) {
        free(corpus_c);
        free(query_c);
        return NULL;
    }
    (*env)->GetByteArrayRegion(env, corpus, 0, corpus_len, (jbyte *)corpus_c);
    corpus_c[corpus_len] = '\0';
    (*env)->GetByteArrayRegion(env, query, 0, query_len, (jbyte *)query_c);
    query_c[query_len] = '\0';

    char *params_c = NULL;
    jsize params_len = 0;
    if (params) {
        params_len = (*env)->GetArrayLength(env, params);
        params_c = (char *)malloc((size_t)params_len + 1);
        if (!params_c) {
            free(corpus_c);
            free(query_c);
            return NULL;
        }
        (*env)->GetByteArrayRegion(env, params, 0, params_len, (jbyte *)params_c);
        params_c[params_len] = '\0';
    }

    const char *result_json = NULL;
    size_t result_len = 0;
    int rc = fsql_search(
        ctx,
        corpus_c, (size_t)corpus_len,
        query_c, (size_t)query_len,
        (int)k,
        params_c, (size_t)params_len,
        &result_json, &result_len);

    free(corpus_c);
    free(query_c);
    free(params_c);

    if (rc != FSQL_OK || !result_json) {
        return NULL;
    }

    jbyteArray out = (*env)->NewByteArray(env, (jsize)result_len);
    if (!out) {
        return NULL;
    }
    (*env)->SetByteArrayRegion(env, out, 0, (jsize)result_len, (const jbyte *)result_json);
    return out;
}

/* ------------------------------------------------------------------ */
/* Vector math (used by the vector surface and by SFS scoring)         */
/* ------------------------------------------------------------------ */

/*
 * Cosine distance between two equal-length double vectors. 1.0 when
 * either vector has zero norm, matching the reference extension's
 * cosine_distance() helper.
 */
JNIEXPORT jdouble JNICALL
Java_com_fractalsqlabs_fractalsql_druid_Native_cosineDistance(
    JNIEnv *env, jclass cls, jdoubleArray a, jdoubleArray b)
{
    (void) cls;
    if (!a || !b) {
        return 1.0;
    }
    jsize n = (*env)->GetArrayLength(env, a);
    if (n != (*env)->GetArrayLength(env, b) || n <= 0) {
        return 1.0;
    }
    jdouble *ap = (*env)->GetDoubleArrayElements(env, a, NULL);
    jdouble *bp = (*env)->GetDoubleArrayElements(env, b, NULL);
    if (!ap || !bp) {
        if (ap) {
            (*env)->ReleaseDoubleArrayElements(env, a, ap, JNI_ABORT);
        }
        if (bp) {
            (*env)->ReleaseDoubleArrayElements(env, b, bp, JNI_ABORT);
        }
        return 1.0;
    }
    double dot = 0.0, na = 0.0, nb = 0.0;
    for (jsize i = 0; i < n; i++) {
        dot += ap[i] * bp[i];
        na += ap[i] * ap[i];
        nb += bp[i] * bp[i];
    }
    (*env)->ReleaseDoubleArrayElements(env, a, ap, JNI_ABORT);
    (*env)->ReleaseDoubleArrayElements(env, b, bp, JNI_ABORT);
    if (na == 0.0 || nb == 0.0) {
        return 1.0;
    }
    return 1.0 - dot / (sqrt(na) * sqrt(nb));
}

/* ------------------------------------------------------------------ */
/* Generic function dispatch                                            */
/* ------------------------------------------------------------------ */

/*
 * One entry point for the whole registry.
 *
 * The core's functions have different shapes -- some take one array and
 * a scalar, some two or three arrays, some write several outputs -- so
 * the dispatcher takes the widest common shape: three double arrays,
 * three scalars, and a scratch array for the extra outputs. The return
 * value is the function's primary scalar result; out[] carries
 * anything else (secondary metrics, weights, indices).
 *
 * The fn ids are the FN_* constants in FractalFn.java. They must be
 * kept in step with that file: a mismatch reads the wrong core function.
 *
 * The scratch layout per function is documented beside each case below
 * and mirrored in FractalExpr.java, which turns out[] into the JSON
 * document the SQL function returns.
 */

#define FSQL_MAX_PEAKS 8
#define FSQL_MAX_FRAMES 32
#define FSQL_MAX_BARS 16
#define FSQL_MAX_CHANGE_POINTS 64

/* Copy a Java double[] into a C buffer; NULL when the array is absent. */
static jdouble *copy_doubles(JNIEnv *env, jdoubleArray arr, jint len)
{
    if (!arr || len <= 0) {
        return NULL;
    }
    jdouble *p = (jdouble *)malloc(sizeof(jdouble) * (size_t)len);
    if (!p) {
        return NULL;
    }
    (*env)->GetDoubleArrayRegion(env, arr, 0, len, p);
    return p;
}

/* The core's vector API is float32; widen on the way in. */
static float *doubles_to_floats(const jdouble *a, size_t n)
{
    float *f = (float *)malloc(sizeof(float) * (n ? n : 1));
    if (!f) {
        return NULL;
    }
    for (size_t i = 0; i < n; i++) {
        f[i] = (float)a[i];
    }
    return f;
}

/* Index lists (edges, faces) arrive as doubles and go in as size_t. */
static size_t *doubles_to_sizes(const jdouble *a, size_t n)
{
    size_t *s = (size_t *)malloc(sizeof(size_t) * (n ? n : 1));
    if (!s) {
        return NULL;
    }
    for (size_t i = 0; i < n; i++) {
        s[i] = (size_t)a[i];
    }
    return s;
}

/* Popcount over two byte buffers. */
static size_t hamming_bytes(const uint8_t *a, const uint8_t *b, size_t n)
{
    size_t d = 0;
    for (size_t i = 0; i < n; i++) {
        uint8_t x = a[i] ^ b[i];
        while (x) {
            d += (size_t)(x & 1u);
            x >>= 1;
        }
    }
    return d;
}

/* ------------------------------------------------------------------ */
/* The cycle detector                                                 */
/* ------------------------------------------------------------------ */

/*
 * The core's own streaming Brent detector, over a sequence of state
 * fingerprints.
 *
 * The port used to reimplement Brent's algorithm in Java, walking the
 * sequence by INDEX. That is the right shape for a sequence -- but the
 * Java version indexed the sequence with the fingerprint's own VALUE,
 * treating each fingerprint as a pointer into the sequence. A
 * fingerprint is a hash, so the walk was nonsense: it either spun
 * forever or ran off the end.
 *
 * The core already implements this, with a Hamming threshold so that
 * near-identical states count as the same state. The Druid extension calls
 * the core's version rather than inventing its own answer.
 *
 * The fingerprints arrive as byte arrays, one per state.
 */
JNIEXPORT jstring JNICALL
Java_com_fractalsqlabs_fractalsql_druid_Native_cycleDetect(
        JNIEnv *env, jclass cls,
        jobjectArray fingerprints, jint nBits, jint hammingThreshold)
{
    (void) cls;

    const jsize n = fingerprints ? (*env)->GetArrayLength(env, fingerprints) : 0;
    const size_t bits = (size_t) (nBits > 0 ? nBits : 64);
    const size_t n_bytes = (bits + 7) / 8;

    fsql_cycle_state_t cs;
    memset(&cs, 0, sizeof cs);
    if (fsql_cycle_detect_init(&cs, n_bytes, (size_t) (hammingThreshold > 0 ? hammingThreshold : 0)) != FSQL_OK) {
        return NULL;
    }

    int    detected  = 0;
    size_t cycle_len = 0;
    long   at_index  = -1;

    for (jsize i = 0; i < n; i++) {
        jbyteArray one = (jbyteArray) (*env)->GetObjectArrayElement(env, fingerprints, i);
        if (one == NULL) {
            continue;
        }
        /* The core reads exactly n_bytes from the fingerprint: a Java array of any other length is a different width
         * and would be read past its end (or read short). The shim does not trust the Java side to have checked. */
        const jsize have = (*env)->GetArrayLength(env, one);
        if (have < 0 || (size_t) have != n_bytes) {
            (*env)->DeleteLocalRef(env, one);
            fsql_cycle_detect_free(&cs);
            return NULL;
        }
        jbyte *bytes = (jbyte *) (*env)->GetByteArrayElements(env, one, NULL);
        if (bytes == NULL) {
            (*env)->DeleteLocalRef(env, one);
            fsql_cycle_detect_free(&cs);
            return NULL;
        }
        int    d = 0;
        size_t cl = 0;
        const int rc = fsql_cycle_detect_feed(&cs, (const uint8_t *) bytes, &d, &cl);
        if (bytes != NULL) {
            (*env)->ReleaseByteArrayElements(env, one, bytes, JNI_ABORT);
        }
        (*env)->DeleteLocalRef(env, one);
        if (rc != FSQL_OK) {
            break;
        }
        if (d) {
            detected  = 1;
            cycle_len = cl;
            at_index  = (long) i;
            break;
        }
    }
    fsql_cycle_detect_free(&cs);

    char buf[256];
    snprintf(buf, sizeof buf,
             "{\"cycle_detected\":%s,\"cycle_length\":%zu,\"cycle_start\":%ld,"
             "\"n_states\":%d,\"n_bits\":%zu,\"hamming_threshold\":%d}",
             detected ? "true" : "false",
             cycle_len,
             at_index,
             (int) n,
             bits,
             (int) hammingThreshold);
    return (*env)->NewStringUTF(env, buf);
}

/* The objective FRACTAL_OPTIMIZE_SUBSET maximises: sum(weight[i] * item_value[i]). The core's search minimises, so this is the negated sum. */
static double
fsql_jni_subset_value_objective(const double *weights, size_t n, void *ctx)
{
    const double *item_values = (const double *)ctx;
    double sum = 0.0;
    for (size_t i = 0; i < n; i++) {
        sum += weights[i] * item_values[i];
    }
    return -sum;
}

JNIEXPORT jdouble JNICALL
Java_com_fractalsqlabs_fractalsql_druid_Native_callFn(
    JNIEnv *env, jclass cls,
    jint fnId,
    jdoubleArray aArr, jint aLen,
    jdoubleArray bArr, jint bLen,
    jdoubleArray cArr, jint cLen,
    jdouble p1, jdouble p2, jdouble p3,
    jdoubleArray outArr)
{
    (void) cls;
    double result = 0.0;
    int rc = -1;
    double *out = NULL;
    jsize outLen = 0;

    jdouble *a = copy_doubles(env, aArr, aLen);
    jdouble *b = copy_doubles(env, bArr, bLen);
    jdouble *c = copy_doubles(env, cArr, cLen);

    if (outArr) {
        outLen = (*env)->GetArrayLength(env, outArr);
        out = (double *)calloc((size_t)(outLen > 0 ? outLen : 1), sizeof(double));
        if (!out) {
            free(a);
            free(b);
            free(c);
            return 0.0;
        }
    }

    switch (fnId) {
        case 1: { /* fractal_dimension_dfa(series) -> alpha */
            double alpha = 0.0;
            rc = fsql_dimension_dfa(a, (size_t)aLen, &alpha);
            result = alpha;
            break;
        }
        case 2: { /* fractal_dimension_drift(series, window) -> drift */
            double drift = 0.0, recent = 0.0, baseline = 0.0;
            rc = fsql_dimension_drift(a, (size_t)aLen, (size_t)p1, &drift, &recent, &baseline);
            result = drift;
            if (out) {
                if (outLen > 0) { out[0] = recent; }
                if (outLen > 1) { out[1] = baseline; }
            }
            break;
        }
        case 3: { /* fractal_dimension_boxcount(points, dim) -> dimension */
            double dimension = 0.0;
            /* The core takes the POINT count, not the component count:
             * the points arrive as one flat row-major array, so the
             * count is the length divided by the dimension. */
            size_t dim = (size_t)p1;
            size_t n_points = dim ? (size_t)aLen / dim : 0;
            if (dim && n_points >= 8) {
                rc = fsql_dimension_boxcount(a, n_points, dim, &dimension);
            } else {
                rc = FSQL_ERR_INVALID;
            }
            result = dimension;
            break;
        }
        case 4: { /* fractal_change_point_detect(series, window, threshold) */
            size_t indices[FSQL_MAX_CHANGE_POINTS];
            size_t n = 0;
            rc = fsql_change_point_detect(a, (size_t)aLen, (size_t)p1, p2,
                                          indices, FSQL_MAX_CHANGE_POINTS, &n);
            result = (double)n;
            if (out) {
                for (size_t i = 0; i < n && (jsize)(i + 1) < outLen; i++) {
                    out[i] = (double)indices[i];
                }
            }
            break;
        }
        case 5: { /* fractal_periodogram(series) -> peak frequency */
            double freqs[FSQL_MAX_PEAKS];
            double power[FSQL_MAX_PEAKS];
            size_t n = 0;
            rc = fsql_periodogram(a, (size_t)aLen, freqs, power, FSQL_MAX_PEAKS, &n);
            /* The strongest peak is the interesting number; report its
             * frequency, and hand back the whole peak list. */
            if (rc == FSQL_OK && n > 0) {
                size_t best = 0;
                for (size_t i = 1; i < n; i++) {
                    if (power[i] > power[best]) {
                        best = i;
                    }
                }
                result = freqs[best];
            }
            if (out) {
                if (outLen > 0) { out[0] = (double)n; }
                for (size_t i = 0; i < n; i++) {
                    if ((jsize)(1 + i) < outLen) { out[1 + i] = freqs[i]; }
                    if ((jsize)(1 + n + i) < outLen) { out[1 + n + i] = power[i]; }
                }
            }
            break;
        }
        case 6: { /* fractal_spectrogram_entropy(series, window, hop) */
            double entropy[FSQL_MAX_FRAMES];
            size_t n_frames = 0;
            rc = fsql_spectrogram_entropy(a, (size_t)aLen, (size_t)p1, (size_t)p2,
                                          entropy, FSQL_MAX_FRAMES, &n_frames);
            /* The core reports the mean; the per-frame values come back
             * in the scratch array. */
            result = 0.0;
            if (rc == FSQL_OK && n_frames > 0) {
                double sum = 0.0;
                for (size_t i = 0; i < n_frames; i++) {
                    sum += entropy[i];
                }
                result = sum / (double)n_frames;
            }
            if (out) {
                if (outLen > 0) { out[0] = (double)n_frames; }
                for (size_t i = 0; i < n_frames; i++) {
                    if ((jsize)(1 + i) < outLen) { out[1 + i] = entropy[i]; }
                }
            }
            break;
        }
        case 7: { /* fractal_morphological_complexity(points, dim) */
            double dimension = 0.0, lacunarity = 0.0;
            /* The point count, not the component count. */
            size_t dim = (size_t)p1;
            size_t n_points = dim ? (size_t)aLen / dim : 0;
            if (dim && n_points) {
                rc = fsql_morphological_complexity(a, n_points, dim, &dimension, &lacunarity);
            } else {
                rc = FSQL_ERR_INVALID;
            }
            result = dimension;
            if (out && outLen > 0) { out[0] = lacunarity; }
            break;
        }
        case 8:   /* fractal_optimize_portfolio(mu, cov, k) */
        case 14: { /* fractal_optimize_portfolio_ex(mu, cov, k, obl, diffusion) */
            /* The covariance matrix arrives flattened: n*n entries,
             * row-major, so the asset count falls out of its length. */
            size_t n_assets = 0;
            if (b && bLen > 0) {
                n_assets = (size_t)llround(sqrt((double)bLen));
            }
            /* The core reads n_assets expected returns from mu and n_assets*n_assets covariances: both arrays must
             * be at least that long (a short mu was read past its end). */
            if (n_assets > 0 && a && aLen > 0 && (size_t)aLen >= n_assets
                    && b && (size_t)bLen >= n_assets * n_assets) {
                double *weights = (double *)calloc(n_assets, sizeof(double));
                if (weights) {
                    double sharpe = 0.0;
                    if (fnId == 8) {
                        rc = fsql_optimize_portfolio(a, b, n_assets, (size_t)p1,
                                                     (uint64_t)0, weights, &sharpe);
                    } else {
                        rc = fsql_optimize_portfolio_ex(a, b, n_assets, (size_t)p1,
                                                       (uint64_t)0, (int)p2, (int)p3,
                                                       weights, &sharpe);
                    }
                    result = sharpe;
                    if (out) {
                        if (outLen > 0) { out[0] = (double)n_assets; }
                        for (size_t i = 0; i < n_assets; i++) {
                            if ((jsize)(1 + i) < outLen) { out[1 + i] = weights[i]; }
                        }
                    }
                    free(weights);
                }
            }
            break;
        }
        case 77: { /* fractal_optimize_subset(item_values, upper_bounds, k, prev_weights, turnover_penalty, seed) */
            size_t n_items = (size_t)aLen;
            /* the weights come back in out[1..n]: at most outLen - 1 items */
            if (a && b && n_items > 0 && (size_t)bLen == n_items && (jsize)(n_items + 1) <= outLen
                    && (!c || cLen <= 0 || (size_t)cLen == n_items)) {
                double *weights = (double *)calloc(n_items, sizeof(double));
                if (weights) {
                    double score = 0.0;
                    rc = fsql_optimize_subset(fsql_jni_subset_value_objective, (void *)a, n_items, (size_t)p1, NULL, b,
                                              (c && cLen > 0) ? c : NULL, p2, (uint64_t)p3, weights, &score);
                    result = -score;   /* the achieved value-weighted sum (higher is better) */
                    if (out) {
                        out[0] = (double)n_items;
                        for (size_t i = 0; i < n_items; i++) { out[1 + i] = weights[i]; }
                    }
                    free(weights);
                }
            }
            break;
        }
        case 9: { /* fractal_tda_persistence_diagram(points, dim, max_dim, max_thresh) -> betti1 */
            size_t betti1 = 0;
            size_t max_bars = 0;
            fsql_tda_bar_t bars[FSQL_MAX_BARS];
            /* The point count, not the component count. */
            size_t dim = (size_t)p1;
            size_t n_points = dim ? (size_t)aLen / dim : 0;
            if (dim && n_points) {
                rc = fsql_tda_persistence_diagram(a, n_points, dim, (size_t)p2, p3,
                                                   bars, FSQL_MAX_BARS, &max_bars, &betti1);
            } else {
                rc = FSQL_ERR_INVALID;
            }
            result = (double)betti1;
            if (out) {
                if (outLen > 0) { out[0] = (double)max_bars; }
                for (size_t i = 0; i < max_bars; i++) {
                    if ((jsize)(1 + 2 * i) < outLen) { out[1 + 2 * i] = bars[i].birth; }
                    if ((jsize)(2 + 2 * i) < outLen) { out[2 + 2 * i] = bars[i].death; }
                }
            }
            break;
        }
        case 10: { /* fractal_state_fingerprint(vec, n_bits) -> the fingerprint */
            /* The core returns the fingerprint bytes: out[0] is the byte count and
             * out[1..] are the bytes. The Java side carries them as hex. */
            /* The width comes straight from a SQL argument and sizes the buffer below, so it is bounded BEFORE the
             * allocation: not negative or non-finite, at most 1 MiB bits, and (the core's own work limit) at most
             * 2^28 bits*dimensions. A width the core would refuse never costs an allocation. */
            size_t n_bits = 0;
            if (!(p1 >= 0.0 && p1 <= 1048576.0)) {
                break;
            }
            n_bits = (size_t)p1;
            if (n_bits == 0) {
                n_bits = 64;
            }
            if (aLen <= 0 || n_bits > ((size_t)1 << 28) / (size_t)aLen) {
                break;
            }
            size_t n_bytes = (n_bits + 7) / 8;
            uint8_t *fp = (uint8_t *)calloc(n_bytes, 1);
            if (fp) {
                rc = fsql_state_fingerprint(a, (size_t)aLen, n_bits, p2, fp);
                if (rc == FSQL_OK) {
                    result = (double)n_bytes;
                    if (out) {
                        if (outLen > 0) { out[0] = (double)n_bytes; }
                        for (size_t i = 0; i < n_bytes; i++) {
                            if ((jsize)(1 + i) < outLen) { out[1 + i] = (double)fp[i]; }
                        }
                    }
                }
            }
            free(fp);
            break;
        }
        case 15: { /* fractal_state_distance(a, b, n_bits) -> hamming */
            /* A Druid addition: how far apart two states are, which is
             * the question a fingerprint exists to answer. */
            size_t n_bits = (size_t)p1;
            if (n_bits == 0) {
                n_bits = 64;
            }
            size_t n_bytes = (n_bits + 7) / 8;
            uint8_t *fa = (uint8_t *)calloc(n_bytes, 1);
            uint8_t *fb = (uint8_t *)calloc(n_bytes, 1);
            if (fa && fb) {
                int ra = fsql_state_fingerprint(a, (size_t)aLen, n_bits, 0.0, fa);
                int rb = fsql_state_fingerprint(b, (size_t)bLen, n_bits, 0.0, fb);
                if (ra == FSQL_OK && rb == FSQL_OK) {
                    result = (double)hamming_bytes(fa, fb, n_bytes);
                    rc = FSQL_OK;
                }
            }
            free(fa);
            free(fb);
            break;
        }
        case 11: { /* fractal_vascular_network(nodes, edges, arc_lengths) */
            /* edges holds n_edges*2 node indices and edge_arc_length holds n_edges lengths: the count comes from the
             * edges array and the lengths array has to agree with it (a larger count read past the edges). */
            if (a && b && c && bLen > 0 && (bLen % 2) == 0 && (size_t)cLen == (size_t)bLen / 2) {
                size_t *edges = doubles_to_sizes(b, (size_t)bLen);
                if (edges) {
                    double tortuosity = 0.0, branch_density = 0.0, dimension = 0.0;
                    rc = fsql_vascular_network(a, (size_t)aLen / 3, edges, c, (size_t)bLen / 2,
                                               &tortuosity, &branch_density, &dimension);
                    result = tortuosity;
                    if (out) {
                        if (outLen > 0) { out[0] = branch_density; }
                        if (outLen > 1) { out[1] = dimension; }
                    }
                    free(edges);
                }
            }
            break;
        }
        case 12: { /* fractal_cortical_folding(vertices, faces) */
            if (a && b) {
                size_t *faces = doubles_to_sizes(b, (size_t)bLen);
                if (faces) {
                    double mesh_area = 0.0, hull_area = 0.0, gyrification = 0.0;
                    rc = fsql_cortical_folding(a, (size_t)aLen / 3, faces, (size_t)bLen / 3,
                                               &mesh_area, &hull_area, &gyrification);
                    result = mesh_area;
                    if (out) {
                        if (outLen > 0) { out[0] = hull_area; }
                        if (outLen > 1) { out[1] = gyrification; }
                    }
                    free(faces);
                }
            }
            break;
        }
        case 13: { /* fractal_nerve_plexus_metric(nodes, dim, edges) */
            if (a && b) {
                size_t dim = (size_t)p1;
                if (dim == 0) {
                    dim = 2;
                }
                size_t *edges = doubles_to_sizes(b, (size_t)bLen);
                if (edges) {
                    double density = 0.0, branch_density = 0.0, dimension = 0.0;
                    rc = fsql_nerve_plexus_metric(a, (size_t)aLen / dim, dim, edges,
                                                  (size_t)bLen / 2,
                                                  &density, &branch_density, &dimension);
                    result = density;
                    if (out) {
                        if (outLen > 0) { out[0] = branch_density; }
                        if (outLen > 1) { out[1] = dimension; }
                    }
                    free(edges);
                }
            }
            break;
        }
        case 20:   /* fractal_vector_l2_distance(a, b) */
        case 21:   /* fractal_vector_l2_squared(a, b) */
        case 22:   /* fractal_vector_cosine_distance(a, b) */
        case 23:   /* fractal_vector_cosine_similarity(a, b) */
        case 24:   /* fractal_vector_negative_inner_product(a, b) */
        case 25:   /* fractal_vector_norm(a) */
        case 26: { /* fractal_vector_lp_distance(a, b, p) */
            if (a) {
                float *fa = doubles_to_floats(a, (size_t)aLen);
                float *fb = b ? doubles_to_floats(b, (size_t)bLen) : NULL;
                if (fa && (b ? fb != NULL : 1)) {
                    float v = 0.0f;
                    switch (fnId) {
                        case 20:
                            rc = fsql_vector_l2(fa, fb, (size_t)aLen, &v);
                            break;
                        case 21:
                            rc = fsql_vector_l2_sq(fa, fb, (size_t)aLen, &v);
                            break;
                        case 22:
                            rc = fsql_vector_cosine_distance(fa, fb, (size_t)aLen, &v);
                            break;
                        case 23:
                            rc = fsql_vector_cosine_similarity(fa, fb, (size_t)aLen, &v);
                            break;
                        case 24: {
                            float dot = 0.0f;
                            rc = fsql_vector_dot(fa, fb, (size_t)aLen, &dot);
                            v = -dot;
                            break;
                        }
                        case 25:
                            rc = fsql_vector_norm(fa, (size_t)aLen, &v);
                            break;
                        default:
                            rc = fsql_vector_lp_distance(fa, fb, (size_t)aLen, (float)p1, &v);
                            break;
                    }
                    result = (double)v;
                }
                free(fa);
                free(fb);
            }
            break;
        }
        case 27: { /* fractal_vector_hamming_distance(a, b) */
            if (a && b) {
                size_t dim = (size_t)aLen;
                size_t n_bytes = (dim + 7) / 8;
                float *fa = doubles_to_floats(a, dim);
                float *fb = doubles_to_floats(b, (size_t)bLen);
                uint8_t *ba = (uint8_t *)calloc(n_bytes, 1);
                uint8_t *bb = (uint8_t *)calloc(n_bytes, 1);
                if (fa && fb && ba && bb) {
                    int ra = fsql_vector_quantize_binary(fa, dim, ba);
                    int rb = fsql_vector_quantize_binary(fb, dim, bb);
                    if (ra == FSQL_OK && rb == FSQL_OK) {
                        size_t dist = 0;
                        rc = fsql_vector_hamming_distance(ba, bb, n_bytes, &dist);
                        result = (double)dist;
                    }
                }
                free(fa);
                free(fb);
                free(ba);
                free(bb);
            }
            break;
        }
        case 33: { /* fractal_vector_quantize_int8(a) */
            if (a) {
                size_t dim = (size_t)aLen;
                float *fa = doubles_to_floats(a, dim);
                int8_t *codes = (int8_t *)malloc(dim ? dim : 1);
                if (fa && codes) {
                    float scale = 0.0f;
                    rc = fsql_vector_quantize_int8(fa, dim, codes, &scale);
                    result = 0.0;
                    if (out) {
                        if (outLen > 0) { out[0] = (double)scale; }
                        if (outLen > 1) { out[1] = (double)dim; }
                        for (size_t i = 0; i < dim; i++) {
                            if ((jsize)(2 + i) < outLen) { out[2 + i] = (double)codes[i]; }
                        }
                    }
                }
                free(fa);
                free(codes);
            }
            break;
        }
        case 34: /* fractal_vector_dims(a) */
            result = (double)aLen;
            rc = FSQL_OK;
            break;
        default:
            rc = -1;
            break;
    }

    if (out && outArr && outLen > 0) {
        (*env)->SetDoubleArrayRegion(env, outArr, 0, outLen, out);
    }
    free(a);
    free(b);
    free(c);
    free(out);
    /* A non-zero rc is a core error; the caller sees it as NaN, which is
     * how a failed computation should read in SQL. */
    return rc == FSQL_OK ? result : (jdouble)NAN;
}

/*
 * The vector-returning functions.
 *
 * The same argument shape as callFn, but the result is a vector rather
 * than a number, so it comes back as a fresh double[].
 */
JNIEXPORT jdoubleArray JNICALL
Java_com_fractalsqlabs_fractalsql_druid_Native_callVec(
    JNIEnv *env, jclass cls,
    jint fnId,
    jdoubleArray aArr, jint aLen,
    jdoubleArray bArr, jint bLen,
    jdoubleArray cArr, jint cLen,
    jdouble p1, jdouble p2, jdouble p3)
{
    (void) cls;
    (void) cArr;
    (void) cLen;
    (void) p2;
    (void) p3;
    int rc = -1;
    double *result = NULL;
    size_t result_len = 0;

    jdouble *a = copy_doubles(env, aArr, aLen);
    jdouble *b = copy_doubles(env, bArr, bLen);

    switch (fnId) {
        case 10: { /* fractal_state_fingerprint(v, n_bits) */
            /* The fingerprint comes back as its bytes, one per
             * component -- the same shape the scalar dispatcher puts
             * in its out[] array. The loop detector needs it here:
             * it fingerprints each state and compares the results,
             * and without this case every state fingerprinted as
             * EMPTY, so every pair compared equal and every log
             * looked like a loop. */
            if (a) {
                size_t dim = (size_t)aLen;
                size_t n_bits = (size_t)(p1 > 0 ? p1 : 64);
                size_t n_bytes = (n_bits + 7) / 8;
                uint8_t *fp = (uint8_t *)calloc(n_bytes ? n_bytes : 1, 1);
                if (fp) {
                    rc = fsql_state_fingerprint(a, dim, n_bits, p2, fp);
                    if (rc == FSQL_OK) {
                        result = (double *)malloc(sizeof(double) * (n_bytes ? n_bytes : 1));
                        if (result) {
                            for (size_t i = 0; i < n_bytes; i++) {
                                result[i] = (double)fp[i];
                            }
                            result_len = n_bytes;
                        }
                    }
                    free(fp);
                }
            }
            break;
        }
        case 28:   /* fractal_vector_add(a, b) */
        case 29:   /* fractal_vector_sub(a, b) */
        case 30: { /* fractal_vector_scale(a, s) */
            if (a) {
                size_t dim = (size_t)aLen;
                float *fa = doubles_to_floats(a, dim);
                float *fb = b ? doubles_to_floats(b, (size_t)bLen) : NULL;
                float *fv = (float *)malloc(sizeof(float) * (dim ? dim : 1));
                if (fa && fv && (fnId == 30 || fb)) {
                    if (fnId == 28) {
                        rc = fsql_vector_add(fa, fb, dim, fv);
                    } else if (fnId == 29) {
                        rc = fsql_vector_sub(fa, fb, dim, fv);
                    } else {
                        rc = fsql_vector_scale(fa, dim, (float)p1, fv);
                    }
                    if (rc == FSQL_OK) {
                        result = (double *)malloc(sizeof(double) * (dim ? dim : 1));
                        if (result) {
                            for (size_t i = 0; i < dim; i++) {
                                result[i] = (double)fv[i];
                            }
                            result_len = dim;
                        }
                    }
                }
                free(fa);
                free(fb);
                free(fv);
            }
            break;
        }
        case 31: { /* fractal_vector_normalize(a) */
            if (a) {
                size_t dim = (size_t)aLen;
                float *fa = doubles_to_floats(a, dim);
                float *fv = (float *)malloc(sizeof(float) * (dim ? dim : 1));
                if (fa && fv) {
                    rc = fsql_vector_normalize(fa, dim, fv);
                    if (rc == FSQL_OK) {
                        result = (double *)malloc(sizeof(double) * (dim ? dim : 1));
                        if (result) {
                            for (size_t i = 0; i < dim; i++) {
                                result[i] = (double)fv[i];
                            }
                            result_len = dim;
                        }
                    }
                }
                free(fa);
                free(fv);
            }
            break;
        }
        case 32: { /* fractal_vector_quantize_binary(a) */
            if (a) {
                size_t dim = (size_t)aLen;
                size_t n_bytes = (dim + 7) / 8;
                float *fa = doubles_to_floats(a, dim);
                uint8_t *bits = (uint8_t *)calloc(n_bytes, 1);
                if (fa && bits) {
                    rc = fsql_vector_quantize_binary(fa, dim, bits);
                    if (rc == FSQL_OK) {
                        /* Hand back one bit per component, MSB first --
                         * the same order the packed form uses. */
                        size_t n_bits = n_bytes * 8;
                        result = (double *)malloc(sizeof(double) * (n_bits ? n_bits : 1));
                        if (result) {
                            for (size_t i = 0; i < n_bits; i++) {
                                result[i] = (double)((bits[i / 8] >> (7 - (i % 8))) & 1u);
                            }
                            result_len = n_bits;
                        }
                    }
                }
                free(fa);
                free(bits);
            }
            break;
        }
        default:
            rc = -1;
            break;
    }

    free(a);
    free(b);

    if (rc != FSQL_OK || !result) {
        free(result);
        return NULL;
    }

    jdoubleArray out = (*env)->NewDoubleArray(env, (jsize)result_len);
    if (!out) {
        free(result);
        return NULL;
    }
    (*env)->SetDoubleArrayRegion(env, out, 0, (jsize)result_len, result);
    free(result);
    return out;
}

/* ------------------------------------------------------------------ */
/* The Diversify monitor                                               */
/* ------------------------------------------------------------------ */

/*
 * The divergence monitor and the repulsive post-filter are the core's
 * opt-in v2.0 search behaviour: enabled per context, tuned by a
 * parameter document, and read back as the most recent D_q and the
 * rolling p99 of its own overhead.
 *
 * The Druid port drives them from the session tier -- fractal_diversify_
 * enable / disable / set_params -- so the session's search is the
 * diversified one.
 */

JNIEXPORT jint JNICALL
Java_com_fractalsqlabs_fractalsql_druid_Native_diversifyEnable(
    JNIEnv *env, jclass cls, jlong handle)
{
    (void) env;
    (void) cls;
    fsql_ctx *ctx = CTX(handle);
    if (!ctx) {
        return -1;
    }
    return (jint) fsql_diversify_enable(ctx);
}

JNIEXPORT jint JNICALL
Java_com_fractalsqlabs_fractalsql_druid_Native_diversifyDisable(
    JNIEnv *env, jclass cls, jlong handle)
{
    (void) env;
    (void) cls;
    fsql_ctx *ctx = CTX(handle);
    if (!ctx) {
        return -1;
    }
    return (jint) fsql_diversify_disable(ctx);
}

JNIEXPORT jint JNICALL
Java_com_fractalsqlabs_fractalsql_druid_Native_diversifySetParams(
    JNIEnv *env, jclass cls, jlong handle,
    jint windowN, jdouble stallThreshold, jdouble repulsionSigma,
    jdouble repulsionWeight, jint maxShadows, jint tailBufferCap)
{
    (void) env;
    (void) cls;
    fsql_ctx *ctx = CTX(handle);
    if (!ctx) {
        return -1;
    }
    fsql_diversify_params_t params;
    memset(&params, 0, sizeof(params));
    params.window_n = (uint32_t) windowN;
    params.stall_threshold = stallThreshold;
    params.repulsion_sigma = repulsionSigma;
    params.repulsion_weight = repulsionWeight;
    params.max_shadows_considered = (uint32_t) maxShadows;
    params.tail_buffer_cap = (uint32_t) tailBufferCap;
    return (jint) fsql_diversify_set_params(ctx, &params);
}

JNIEXPORT jdouble JNICALL
Java_com_fractalsqlabs_fractalsql_druid_Native_diversifyCurrentDq(
    JNIEnv *env, jclass cls, jlong handle)
{
    (void) env;
    (void) cls;
    fsql_ctx *ctx = CTX(handle);
    if (!ctx) {
        return NAN;
    }
    return (jdouble) fsql_diversify_current_dq(ctx);
}

JNIEXPORT jdouble JNICALL
Java_com_fractalsqlabs_fractalsql_druid_Native_diversifyOverheadP99(
    JNIEnv *env, jclass cls, jlong handle)
{
    (void) env;
    (void) cls;
    fsql_ctx *ctx = CTX(handle);
    if (!ctx) {
        return NAN;
    }
    return (jdouble) fsql_diversify_overhead_p99_us(ctx);
}
