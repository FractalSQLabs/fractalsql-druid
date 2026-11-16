/* SPDX-License-Identifier: Apache-2.0
 * SPDX-FileCopyrightText: 2026 Daniel Gardiner d/b/a FractalSQLabs
 *
 * A stand-in for the enterprise library, to drive the daemon's side of the seam through answers the real library never gives:
 * errors, counts out of range, results that overclaim, a buffer that has to grow. It exports the same symbols as the real one.
 *
 * The behaviour is read from the file named by FSQL_MOCK_ENT_MODE on every call, as "key=value" lines, so a test changes it between
 * calls without restarting the daemon:
 *   ret=N         every ledger and portfolio call returns N (default 0)
 *   count=N       the value the truth and shadow counts report (default 3)
 *   nfound=N      the number of candidates a portfolio call reports (default 2)
 *   nan=1         the weights and sharpes are not finite
 *   unpack=MODE   ok (default), grow (needs a bigger buffer once), huge (asks for more than the daemon allows), overclaim
 *                 (reports more bytes than the buffer holds), fail, empty
 * Built with -DNO_PORTFOLIO the three optional symbols are left out; with -DNO_REQUIRED one required symbol is.
 */
#define _GNU_SOURCE
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

typedef struct fsql_ctx fsql_ctx;
#define FSQL_ETRUNCATED (-57)

static long mode_num(const char *key, long dflt)
{
    const char *path = getenv("FSQL_MOCK_ENT_MODE");
    char line[256];
    FILE *f = path ? fopen(path, "r") : NULL;
    size_t kl = strlen(key);
    long v = dflt;
    if (!f) return dflt;
    while (fgets(line, sizeof line, f))
        if (strncmp(line, key, kl) == 0 && line[kl] == '=') v = strtol(line + kl + 1, NULL, 10);
    fclose(f);
    return v;
}

static int mode_is(const char *key, const char *val)
{
    const char *path = getenv("FSQL_MOCK_ENT_MODE");
    char line[256];
    FILE *f = path ? fopen(path, "r") : NULL;
    size_t kl = strlen(key), vl = strlen(val);
    int is = 0, seen = 0;
    if (!f) return strcmp(val, "ok") == 0;
    while (fgets(line, sizeof line, f))
        if (strncmp(line, key, kl) == 0 && line[kl] == '=') { seen = 1; is = strncmp(line + kl + 1, val, vl) == 0; }
    fclose(f);
    return seen ? is : strcmp(val, "ok") == 0;
}

static int ret(void) { return (int) mode_num("ret", 0); }

#ifndef NO_REQUIRED
int fsql_ledger_flush(fsql_ctx *c) { (void) c; return ret(); }
#endif
int fsql_ledger_load(fsql_ctx *c) { (void) c; return ret(); }
int fsql_ledger_compact(fsql_ctx *c) { (void) c; return ret(); }
int fsql_ledger_reset_soft(fsql_ctx *c) { (void) c; return ret(); }
int fsql_ledger_reset_hard(fsql_ctx *c) { (void) c; return ret(); }
int fsql_ledger_truth_count(const fsql_ctx *c, size_t *out) { (void) c; *out = (size_t) mode_num("count", 3); return ret(); }
int fsql_ledger_shadow_count(const fsql_ctx *c, size_t *out) { (void) c; *out = (size_t) mode_num("count", 3); return ret(); }

int fsql_audit_unpack(const void *blob, size_t len, char *out, size_t *cap)
{
    static int grown;
    const char *s = "{\"mock\":true,\"records\":[]}";
    size_t n = strlen(s);
    (void) blob; (void) len;
    if (mode_is("unpack", "fail")) return -1;
    if (mode_is("unpack", "huge")) { *cap = (size_t) 1 << 30; return FSQL_ETRUNCATED; }
    if (mode_is("unpack", "grow") && !grown) { grown = 1; *cap = 20000; return FSQL_ETRUNCATED; }
    if (mode_is("unpack", "overclaim")) { *cap = *cap + 100; return 0; }
    if (mode_is("unpack", "empty")) { *cap = 0; return 0; }
    grown = 0;
    if (*cap < n) { *cap = n; return FSQL_ETRUNCATED; }
    memcpy(out, s, n);
    *cap = n;
    return 0;
}

#ifndef NO_PORTFOLIO
static void fill(size_t n_assets, int restarts, double *w, double *s, int *found)
{
    int n = (int) mode_num("nfound", 2), c;
    size_t i;
    double bad = mode_num("nan", 0) ? strtod("nan", NULL) : 0.5;
    for (c = 0; c < restarts; c++) {
        s[c] = bad;
        for (i = 0; i < n_assets; i++) w[(size_t) c * n_assets + i] = (bad == bad) ? 1.0 / (double) n_assets : bad;
    }
    *found = n;
}

int fsql_optimize_portfolio_multimodal(const double *mu, const double *cov, size_t n_assets, size_t k, int n_restarts,
                                       double overlap, double qfrac, uint64_t seed, double *w, double *s, int *found)
{
    (void) mu; (void) cov; (void) k; (void) overlap; (void) qfrac; (void) seed;
    if (ret()) return ret();
    fill(n_assets, n_restarts, w, s, found);
    return 0;
}

int fsql_optimize_portfolio_multimodal_ex(const double *mu, const double *cov, size_t n_assets, size_t k, int n_restarts,
                                          double overlap, double qfrac, uint64_t seed, int use_obl, int diffusion,
                                          double *w, double *s, int *found)
{
    (void) mu; (void) cov; (void) k; (void) overlap; (void) qfrac; (void) seed; (void) use_obl; (void) diffusion;
    if (ret()) return ret();
    fill(n_assets, n_restarts, w, s, found);
    return 0;
}

int fsql_optimize_portfolio_multimodal_pareto(const double *mu, const double *cov, size_t n_assets, size_t k, int n_restarts,
                                              int max_front, uint64_t seed, int use_obl, int diffusion,
                                              double *w, double *rets, double *risks, int *found)
{
    int c;
    (void) mu; (void) cov; (void) k; (void) seed; (void) use_obl; (void) diffusion;
    if (ret()) return ret();
    (void) n_restarts;
    /* the daemon sizes the three output arrays by max_front, not by the restarts */
    fill(n_assets, max_front, w, rets, found);
    for (c = 0; c < max_front; c++) risks[c] = 0.1 * (c + 1);
    return 0;
}
#endif
