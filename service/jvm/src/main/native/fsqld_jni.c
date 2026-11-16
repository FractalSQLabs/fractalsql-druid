/* SPDX-License-Identifier: Apache-2.0
 * SPDX-FileCopyrightText: 2026 Daniel Gardiner d/b/a FractalSQLabs
 *
 * fsqld_jni.c -- the native half of the JVM fractalsqld.
 *
 * The Java server owns the socket, the framing, the authentication and the
 * connection lifecycle. This file is the seam to the function bodies: it
 * links the same adapter objects the C daemon links, and runs a named
 * function through the init / call / deinit convention those bodies use.
 *
 * A call must run on the thread that opened its handle's connection, so the
 * Java side serves each connection on one platform thread.
 */
#include <jni.h>
#include <pwd.h>
#include <stdbool.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

#include "fsql_udf_types.h"
#include "fractalsql_config.h"
#include "fractalsql_interrupt.h"
#include "fractalsql_provider.h"

#define FSQ_MAX_ARGS 64
#define FSQ_MSG_MAX  512

enum fsq_kind { FSQ_KIND_CTL, FSQ_KIND_STR, FSQ_KIND_INT, FSQ_KIND_REAL };

struct fsq_fn {
    const char *name;
    enum fsq_kind kind;
    void *init;
    void *deinit;
    void *main;
};

#include "daemon_udfs.h"

/* The string as real UTF-8, malloc'd (free() it). GetStringUTFChars returns JNI "modified UTF-8", which writes a character
 * outside the BMP as two 3-byte surrogates (CESU-8): not UTF-8, and a C consumer that takes it for UTF-8 (a path, a URL, a
 * model name) misreads it (SECURITY_AUDIT.md 3.28). Converted here from the UTF-16 code units. */
static char *utf8_of(JNIEnv *env, jstring v)
{
    const jsize n = (*env)->GetStringLength(env, v);
    const jchar *u = (*env)->GetStringChars(env, v, NULL);
    char *out, *w;
    if (!u) return NULL;
    out = malloc((size_t) n * 3 + 1);   /* a code unit is at most 3 bytes; a surrogate pair is 4 bytes for 2 units */
    if (!out) { (*env)->ReleaseStringChars(env, v, u); return NULL; }
    w = out;
    for (jsize i = 0; i < n; i++) {
        uint32_t c = u[i];
        if (c >= 0xD800 && c <= 0xDBFF && i + 1 < n && u[i + 1] >= 0xDC00 && u[i + 1] <= 0xDFFF) {
            c = 0x10000 + ((c - 0xD800) << 10) + (u[i + 1] - 0xDC00);
            i++;
        }
        if (c < 0x80) *w++ = (char) c;
        else if (c < 0x800) { *w++ = (char) (0xC0 | (c >> 6)); *w++ = (char) (0x80 | (c & 0x3F)); }
        else if (c < 0x10000) { *w++ = (char) (0xE0 | (c >> 12)); *w++ = (char) (0x80 | ((c >> 6) & 0x3F)); *w++ = (char) (0x80 | (c & 0x3F)); }
        else { *w++ = (char) (0xF0 | (c >> 18)); *w++ = (char) (0x80 | ((c >> 12) & 0x3F)); *w++ = (char) (0x80 | ((c >> 6) & 0x3F)); *w++ = (char) (0x80 | (c & 0x3F)); }
    }
    *w = '\0';
    (*env)->ReleaseStringChars(env, v, u);
    return out;
}

typedef char *(*fsq_str_fn)(UDF_INIT *, UDF_ARGS *, char *, unsigned long *, char *, char *);
typedef long long (*fsq_int_fn)(UDF_INIT *, UDF_ARGS *, char *, char *);
typedef double (*fsq_real_fn)(UDF_INIT *, UDF_ARGS *, char *, char *);
typedef void (*fsq_deinit_fn)(UDF_INIT *);
typedef bool (*fsq_init_fn)(UDF_INIT *, UDF_ARGS *, char *);

extern void fractal_enterprise_release_thread_read_buffers(void);

#define FN_COUNT ((int) (sizeof(g_fn_table) / sizeof(g_fn_table[0])))

/* Result codes returned by nCall. */
enum {
    CALL_OK = 0,
    CALL_CORE_ERROR = 1,
    CALL_LIMIT = 2,
    CALL_CANCELLED_MID = 3,
    CALL_CANCELLED_BEFORE = 4,
    CALL_BAD_ARG = 5,
    CALL_INTERNAL = 6,
    CALL_NOTSUP = 7
};

/* Wire value types. */
enum { WIRE_STRING = 1, WIRE_INT = 2, WIRE_REAL = 3 };

typedef struct fsq_handle {
    const struct fsq_fn *fn;
    UDF_INIT init;
    UDF_ARGS args;
    char *const_buf[FSQ_MAX_ARGS];
    volatile int cancelled;
} fsq_handle;

/* The handle whose call is running on this thread. The interrupt hook reads
 * it, so a cancel reaches a computation loop without any signal. */
static __thread fsq_handle *t_active = NULL;

static int check_cancelled(void)
{
    fsq_handle *h = t_active;
    return h ? __atomic_load_n(&h->cancelled, __ATOMIC_SEQ_CST) : 0;
}

static uint64_t get_u64(const uint8_t *p)
{
    uint64_t v = 0;
    for (int i = 7; i >= 0; i--) v = (v << 8) | p[i];
    return v;
}

static void put_u64(uint8_t *p, uint64_t v)
{
    for (int i = 0; i < 8; i++) p[i] = (uint8_t) (v >> (8 * i));
}

static void free_args(fsq_handle *h)
{
    for (int i = 0; i < FSQ_MAX_ARGS; i++) {
        free(h->const_buf[i]);
        h->const_buf[i] = NULL;
    }
    free(h->args.arg_type);
    free(h->args.args);
    free(h->args.lengths);
    free(h->args.maybe_null);
    h->args.arg_type = NULL;
    h->args.args = NULL;
    h->args.lengths = NULL;
    h->args.maybe_null = NULL;
}

/* ------------------------------------------------------------------ */
/* Process setup and the function table                                */
/* ------------------------------------------------------------------ */

JNIEXPORT void JNICALL
Java_com_fractalsqlabs_fractalsql_daemon_Native_boot(JNIEnv *env, jclass cls)
{
    (void) env;
    (void) cls;
    fractalsql_interrupt_hook_set(check_cancelled);
}

JNIEXPORT jint JNICALL
Java_com_fractalsqlabs_fractalsql_daemon_Native_functionCount(JNIEnv *env, jclass cls)
{
    (void) env;
    (void) cls;
    return FN_COUNT;
}

JNIEXPORT jstring JNICALL
Java_com_fractalsqlabs_fractalsql_daemon_Native_functionName(JNIEnv *env, jclass cls, jint i)
{
    (void) cls;
    if (i < 0 || i >= FN_COUNT) return NULL;
    return (*env)->NewStringUTF(env, g_fn_table[i].name);
}

JNIEXPORT jint JNICALL
Java_com_fractalsqlabs_fractalsql_daemon_Native_functionKind(JNIEnv *env, jclass cls, jint i)
{
    (void) env;
    (void) cls;
    if (i < 0 || i >= FN_COUNT) return -1;
    return (jint) g_fn_table[i].kind;
}

JNIEXPORT jint JNICALL
Java_com_fractalsqlabs_fractalsql_daemon_Native_euid(JNIEnv *env, jclass cls)
{
    (void) env;
    (void) cls;
    return (jint) geteuid();
}

JNIEXPORT jstring JNICALL
Java_com_fractalsqlabs_fractalsql_daemon_Native_userName(JNIEnv *env, jclass cls, jint uid)
{
    struct passwd pw, *res = NULL;
    char buf[1024];
    (void) cls;
    if (getpwuid_r((uid_t) uid, &pw, buf, sizeof buf, &res) != 0 || res == NULL) return NULL;
    return (*env)->NewStringUTF(env, pw.pw_name);
}

JNIEXPORT void JNICALL
Java_com_fractalsqlabs_fractalsql_daemon_Native_releaseThreadBuffers(JNIEnv *env, jclass cls)
{
    (void) env;
    (void) cls;
    fractal_enterprise_release_thread_read_buffers();
}

JNIEXPORT jstring JNICALL
Java_com_fractalsqlabs_fractalsql_daemon_Native_validatePath(JNIEnv *env, jclass cls, jstring path)
{
    char err[256];
    const char *p;
    int rc;
    (void) cls;
    if (!path) return NULL;
    p = (*env)->GetStringUTFChars(env, path, NULL);
    if (!p) return NULL;
    rc = fractal_config_validate_path(p, err, sizeof err);
    (*env)->ReleaseStringUTFChars(env, path, p);
    return rc == 0 ? NULL : (*env)->NewStringUTF(env, err);
}

/* ------------------------------------------------------------------ */
/* Statement handles                                                   */
/* ------------------------------------------------------------------ */

/* types[i]: the item kind (0 string, 1 real, 2 int, 4 decimal). consts[i]:
 * the constant value the function's init may inspect, or null. Returns the
 * handle, or 0 with a NUL-terminated message in msgOut. */
JNIEXPORT jlong JNICALL
Java_com_fractalsqlabs_fractalsql_daemon_Native_open(JNIEnv *env, jclass cls, jint fnIndex,
                                                     jintArray types, jobjectArray consts,
                                                     jbyteArray msgOut)
{
    fsq_handle *h;
    jsize nargs;
    char msg[FSQ_MSG_MAX];
    bool failed;
    (void) cls;

    if (fnIndex < 0 || fnIndex >= FN_COUNT) return 0;
    nargs = (*env)->GetArrayLength(env, types);
    if (nargs < 0 || nargs > FSQ_MAX_ARGS) return 0;

    h = calloc(1, sizeof(*h));
    if (!h) return 0;
    h->fn = &g_fn_table[fnIndex];
    h->args.arg_count = (unsigned int) nargs;
    h->args.arg_type = calloc(nargs ? (size_t) nargs : 1, sizeof(enum Item_result));
    h->args.args = calloc(nargs ? (size_t) nargs : 1, sizeof(char *));
    h->args.lengths = calloc(nargs ? (size_t) nargs : 1, sizeof(unsigned long));
    h->args.maybe_null = calloc(nargs ? (size_t) nargs : 1, 1);
    if (!h->args.arg_type || !h->args.args || !h->args.lengths || !h->args.maybe_null) {
        free_args(h);
        free(h);
        return 0;
    }

    {
        /* the types array must cover every argument: the loop below reads nargs entries (SECURITY_AUDIT.md 3.27) */
        if (!types || (*env)->GetArrayLength(env, types) < nargs) { free_args(h); free(h); return 0; }
        jint *t = (*env)->GetIntArrayElements(env, types, NULL);
        if (!t) { free_args(h); free(h); return 0; }
        for (jsize i = 0; i < nargs; i++) h->args.arg_type[i] = (enum Item_result) t[i];
        (*env)->ReleaseIntArrayElements(env, types, t, JNI_ABORT);
    }

    for (jsize i = 0; i < nargs; i++) {
        jbyteArray v = (jbyteArray) (*env)->GetObjectArrayElement(env, consts, i);
        jsize len;
        enum Item_result t = h->args.arg_type[i];
        if (!v) continue;
        len = (*env)->GetArrayLength(env, v);
        h->const_buf[i] = malloc((size_t) len + 8 + 1);
        if (!h->const_buf[i]) { free_args(h); free(h); return 0; }
        if (t == INT_RESULT || t == REAL_RESULT) {
            uint8_t raw[8];
            if (len != 8) { free_args(h); free(h); return 0; }
            (*env)->GetByteArrayRegion(env, v, 0, 8, (jbyte *) raw);
            if (t == INT_RESULT) {
                long long iv = (long long) get_u64(raw);
                memcpy(h->const_buf[i], &iv, 8);
            } else {
                uint64_t bits = get_u64(raw);
                double d;
                memcpy(&d, &bits, 8);
                memcpy(h->const_buf[i], &d, 8);
            }
            h->args.lengths[i] = 8;
        } else {
            if (len) (*env)->GetByteArrayRegion(env, v, 0, len, (jbyte *) h->const_buf[i]);
            h->const_buf[i][len] = '\0';
            h->args.lengths[i] = (unsigned long) len;
        }
        h->args.args[i] = h->const_buf[i];
        (*env)->DeleteLocalRef(env, v);
    }

    msg[0] = '\0';
    failed = ((fsq_init_fn) h->fn->init)(&h->init, &h->args, msg);
    if (failed) {
        if (msgOut) {
            size_t n = strlen(msg);
            jsize cap = (*env)->GetArrayLength(env, msgOut);
            if (cap > 0) {
                if ((jsize) n >= cap) n = (size_t) cap - 1;
                (*env)->SetByteArrayRegion(env, msgOut, 0, (jsize) n, (const jbyte *) msg);
                (*env)->SetByteArrayRegion(env, msgOut, (jsize) n, 1, (const jbyte *) "\0");
            }
        }
        free_args(h);
        free(h);
        return 0;
    }
    return (jlong) (intptr_t) h;
}

/* {max_length, maybe_null, argType0, argType1, ...}: what the init settled on. */
JNIEXPORT jintArray JNICALL
Java_com_fractalsqlabs_fractalsql_daemon_Native_info(JNIEnv *env, jclass cls, jlong hp)
{
    fsq_handle *h = (fsq_handle *) (intptr_t) hp;
    if (!h) return NULL;
    jsize n = (jsize) h->args.arg_count;
    jintArray out = (*env)->NewIntArray(env, 2 + n);
    jint *tmp;
    (void) cls;
    if (!out) return NULL;
    tmp = malloc((size_t) (2 + n) * sizeof(jint));
    if (!tmp) return out;
    tmp[0] = (jint) h->init.max_length;
    tmp[1] = h->init.maybe_null ? 1 : 0;
    for (jsize i = 0; i < n; i++) tmp[2 + i] = (jint) h->args.arg_type[i];
    (*env)->SetIntArrayRegion(env, out, 0, 2 + n, tmp);
    free(tmp);
    return out;
}

/* Runs one call. vals[i] is the argument's raw wire bytes, or null. On
 * CALL_OK, meta[0] is the wire result type, meta[1] is 1 for a NULL result,
 * and resOut[0] holds the result bytes. */
JNIEXPORT jint JNICALL
Java_com_fractalsqlabs_fractalsql_daemon_Native_call(JNIEnv *env, jclass cls, jlong hp,
                                                     jobjectArray vals, jobjectArray resOut,
                                                     jintArray meta)
{
    fsq_handle *h = (fsq_handle *) (intptr_t) hp;
    jsize nargs = (jsize) h->args.arg_count;
    long long ivals[FSQ_MAX_ARGS];
    double rvals[FSQ_MAX_ARGS];
    char *bufs[FSQ_MAX_ARGS];
    char is_null = 0, err = 0;
    int rc = CALL_OK;
    jint m[2] = { 0, 0 };
    (void) cls;

    memset(bufs, 0, sizeof bufs);

    if (__atomic_load_n(&h->cancelled, __ATOMIC_SEQ_CST)) {
        __atomic_store_n(&h->cancelled, 0, __ATOMIC_SEQ_CST);
        return CALL_CANCELLED_BEFORE;
    }

    for (jsize i = 0; i < nargs; i++) {
        jbyteArray v = (jbyteArray) (*env)->GetObjectArrayElement(env, vals, i);
        enum Item_result t = h->args.arg_type[i];
        h->args.lengths[i] = 0;
        h->args.maybe_null[i] = 0;
        if (!v) { h->args.args[i] = NULL; continue; }
        {
            jsize len = (*env)->GetArrayLength(env, v);
            if (t == INT_RESULT || t == REAL_RESULT) {
                uint8_t raw[8];
                if (len != 8) { rc = CALL_BAD_ARG; (*env)->DeleteLocalRef(env, v); goto done; }
                (*env)->GetByteArrayRegion(env, v, 0, 8, (jbyte *) raw);
                if (t == INT_RESULT) {
                    ivals[i] = (long long) get_u64(raw);
                    h->args.args[i] = (char *) &ivals[i];
                } else {
                    uint64_t bits = get_u64(raw);
                    memcpy(&rvals[i], &bits, 8);
                    h->args.args[i] = (char *) &rvals[i];
                }
                h->args.lengths[i] = 8;
            } else {
                bufs[i] = malloc((size_t) len + 1);
                if (!bufs[i]) { rc = CALL_INTERNAL; (*env)->DeleteLocalRef(env, v); goto done; }
                if (len) (*env)->GetByteArrayRegion(env, v, 0, len, (jbyte *) bufs[i]);
                bufs[i][len] = '\0';
                h->args.args[i] = bufs[i];
                h->args.lengths[i] = (unsigned long) len;
            }
        }
        (*env)->DeleteLocalRef(env, v);
    }

    t_active = h;
    if (h->fn->kind == FSQ_KIND_STR) {
        size_t cap = (size_t) h->init.max_length + 1;
        char *result = malloc(cap);
        unsigned long len = 0;
        char *ret;
        if (!result) { rc = CALL_INTERNAL; goto done; }
        ret = ((fsq_str_fn) h->fn->main)(&h->init, &h->args, result, &len, &is_null, &err);
        if (err) {
            rc = CALL_CORE_ERROR;
        } else if (is_null) {
            m[0] = WIRE_STRING; m[1] = 1;
        } else if (len > h->init.max_length) {
            rc = CALL_LIMIT;
        } else {
            const char *src = ret ? ret : result;
            jbyteArray out = (*env)->NewByteArray(env, (jsize) len);
            if (!out) { rc = CALL_INTERNAL; }
            else {
                if (len) (*env)->SetByteArrayRegion(env, out, 0, (jsize) len, (const jbyte *) src);
                (*env)->SetObjectArrayElement(env, resOut, 0, out);
                (*env)->DeleteLocalRef(env, out);
                m[0] = WIRE_STRING;
            }
        }
        free(result);
    } else if (h->fn->kind == FSQ_KIND_INT || h->fn->kind == FSQ_KIND_REAL) {
        uint8_t o[8];
        bool is_int = h->fn->kind == FSQ_KIND_INT;
        if (is_int) {
            long long v = ((fsq_int_fn) h->fn->main)(&h->init, &h->args, &is_null, &err);
            put_u64(o, (uint64_t) v);
        } else {
            double v = ((fsq_real_fn) h->fn->main)(&h->init, &h->args, &is_null, &err);
            uint64_t bits;
            memcpy(&bits, &v, 8);
            put_u64(o, bits);
        }
        if (err) {
            rc = CALL_CORE_ERROR;
        } else {
            jbyteArray out = (*env)->NewByteArray(env, 8);
            if (!out) { rc = CALL_INTERNAL; }
            else {
                (*env)->SetByteArrayRegion(env, out, 0, 8, (const jbyte *) o);
                (*env)->SetObjectArrayElement(env, resOut, 0, out);
                (*env)->DeleteLocalRef(env, out);
                m[0] = is_int ? WIRE_INT : WIRE_REAL;
                m[1] = is_null ? 1 : 0;
            }
        }
    } else {
        rc = CALL_NOTSUP;
    }

    /* A cancel that arrived while the call ran is what stopped it: say so,
     * and consume the one-shot flag. */
    if (rc == CALL_CORE_ERROR && __atomic_load_n(&h->cancelled, __ATOMIC_SEQ_CST)) {
        __atomic_store_n(&h->cancelled, 0, __ATOMIC_SEQ_CST);
        rc = CALL_CANCELLED_MID;
    }

done:
    t_active = NULL;
    for (jsize i = 0; i < nargs; i++) {
        free(bufs[i]);
        h->args.args[i] = NULL;
        h->args.lengths[i] = 0;
    }
    (*env)->SetIntArrayRegion(env, meta, 0, 2, m);
    return rc;
}

JNIEXPORT void JNICALL
Java_com_fractalsqlabs_fractalsql_daemon_Native_cancel(JNIEnv *env, jclass cls, jlong hp)
{
    fsq_handle *h = (fsq_handle *) (intptr_t) hp;
    (void) env;
    (void) cls;
    __atomic_store_n(&h->cancelled, 1, __ATOMIC_SEQ_CST);
}

JNIEXPORT void JNICALL
Java_com_fractalsqlabs_fractalsql_daemon_Native_close(JNIEnv *env, jclass cls, jlong hp)
{
    fsq_handle *h = (fsq_handle *) (intptr_t) hp;
    (void) env;
    (void) cls;
    if (!h) return;
    ((fsq_deinit_fn) h->fn->deinit)(&h->init);
    free_args(h);
    free(h);
}

/* ------------------------------------------------------------------ */
/* Provider settings                                                   */
/* ------------------------------------------------------------------ */

/* strs: plugin, url, token, model, embed_url, embed_model, think,
 * think_provider, native_url, t2s_allowed, ent_lib, ent_ledger_path,
 * ent_ledger_key. longs: think_num_ctx, t2s_max_attempts. bools:
 * allow_plaintext, t2s_use_review, ent_require_signature. */
#define PROV_NSTR 13

static int with_provider(JNIEnv *env, jint present, jobjectArray strs, jlongArray longs,
                         jbooleanArray bools, int apply)
{
    struct fsq_provider_cfg pc;
    const char *s[PROV_NSTR];
    const char *got[PROV_NSTR];
    jstring js[PROV_NSTR];
    jlong l[2];
    jboolean b[3];
    char num_ctx_str[24];
    int rc;

    memset(&pc, 0, sizeof pc);
    memset(js, 0, sizeof js);
    memset(got, 0, sizeof got);
    for (int i = 0; i < PROV_NSTR; i++) {
        jstring v = (jstring) (*env)->GetObjectArrayElement(env, strs, i);
        js[i] = v;
        got[i] = v ? utf8_of(env, v) : NULL;
        s[i] = got[i] ? got[i] : "";
    }
    (*env)->GetLongArrayRegion(env, longs, 0, 2, l);
    (*env)->GetBooleanArrayRegion(env, bools, 0, 3, b);

    pc.present = (uint32_t) present;
    pc.reasoning_plugin = s[0];
    pc.reasoning_url = s[1];
    pc.reasoning_token = s[2];
    pc.reasoning_model = s[3];
    pc.reasoning_allow_plaintext = b[0] != 0;
    pc.embed_url = s[4];
    pc.embed_model = s[5];
    pc.think = s[6];
    pc.think_provider = s[7];
    pc.think_native_url = s[8];
    pc.think_num_ctx = (long) l[0];
    pc.t2s_max_attempts = (long) l[1];
    pc.t2s_allowed_statements = s[9];
    pc.t2s_use_review = b[1] != 0;
    pc.enterprise_lib = s[10];
    pc.enterprise_ledger_path = s[11];
    pc.enterprise_ledger_key = s[12];
    pc.enterprise_require_signature = b[2] != 0;

    if (apply) {
        if (present & FSQL_PROV_NUM_CTX) {
            snprintf(num_ctx_str, sizeof num_ctx_str, "%ld", (long) l[0]);
            pc.think_num_ctx_str = num_ctx_str;
        }
        rc = (fractalsql_cognition_apply_provider(&pc) != 0 ||
              fractalsql_textsql_apply_provider(&pc) != 0 ||
              fractalsql_enterprise_apply_provider(&pc) != 0) ? -1 : 0;
    } else {
        rc = (fractalsql_cognition_check_provider(&pc) != 0 ||
              fractalsql_textsql_check_provider(&pc) != 0 ||
              fractalsql_enterprise_check_provider(&pc) != 0) ? -1 : 0;
    }

    for (int i = 0; i < PROV_NSTR; i++) {
        if (js[i]) {
            free((void *) got[i]);
            (*env)->DeleteLocalRef(env, js[i]);
        }
    }
    return rc;
}

JNIEXPORT jint JNICALL
Java_com_fractalsqlabs_fractalsql_daemon_Native_providerCheck(JNIEnv *env, jclass cls, jint present,
                                                              jobjectArray strs, jlongArray longs,
                                                              jbooleanArray bools)
{
    (void) cls;
    return with_provider(env, present, strs, longs, bools, 0);
}

JNIEXPORT jint JNICALL
Java_com_fractalsqlabs_fractalsql_daemon_Native_providerApply(JNIEnv *env, jclass cls, jint present,
                                                              jobjectArray strs, jlongArray longs,
                                                              jbooleanArray bools)
{
    (void) cls;
    return with_provider(env, present, strs, longs, bools, 1);
}
