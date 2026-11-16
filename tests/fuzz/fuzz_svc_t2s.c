/* SPDX-License-Identifier: Apache-2.0
 * SPDX-FileCopyrightText: 2026 Daniel Gardiner d/b/a FractalSQLabs
 *
 * fuzz_svc_t2s -- the text-to-SQL policy, fuzzed, with an oracle.
 *
 * The text-to-SQL allowlist is a security control: it decides whether a
 * generated statement may run. Memory-safety tools do not find a policy
 * that misses an evasion, so this harness does two things at once:
 *
 *   1. It fuzzes the scanners themselves (the statement counter, the
 *      leading-statement classifier, the denied-call scan, the INTO
 *      OUTFILE scan, the versioned-comment scan), so a crash or an
 *      out-of-bounds read in them is found.
 *
 *   2. It compares two of them against a second, independent
 *      implementation -- the oracle below -- and fails when they
 *      disagree. The oracle implements the DOCUMENTED rules (the comment
 *      forms, the keyword list, the denied-prefix list) in the simplest
 *      way that could work, with no quote handling, no comment skipping
 *      and no state machine: it is deliberately naive so that a
 *      disagreement points at the product's scanner rather than at a
 *      shared subtlety.
 *
 * The oracle only runs on plain text: no quote characters and no comment
 * markers, and ASCII only. On such text the oracle's "strip the comments,
 * read the first word" answer is exactly the documented rule, and its
 * "does any identifier start with a denied prefix" answer is a superset
 * of the product's (the product additionally requires an opening
 * parenthesis, so it can only ever find fewer). A disagreement in that
 * direction is therefore a real finding: the product accepted something
 * the documented rule rejects.
 *
 * A disagreement aborts, so libFuzzer keeps the input as an artifact.
 */

#include <ctype.h>
#include <stdbool.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <strings.h>

/* The product's own scanner, included so its static functions are the
 * ones under test. */
#include "fractalsql_textsql.c"

/* ------------------------------------------------------------------ */
/* The oracle                                                          */
/* ------------------------------------------------------------------ */

#define ORACLE_UNDECIDED "UNDECIDED"

/* The documented keyword list, and nothing else. */
static const char *const oracle_keywords[] = {
    "SELECT", "INSERT", "UPDATE", "DELETE", "REPLACE", NULL
};

/* The documented denied-prefix list (the same list the product keeps in
 * t2s_denied_call_prefixes). */
static const char *const oracle_denied[] = {
    "fractal_audit_log", "fractal_ledger_", "fractal_lock_destructive",
    "fractal_store_", "fractal_diversify_", "fractal_feedback_report",
    "fractal_isolate_background", "fractal_sql_agent", "fractal_agent_",
    "fractal_vectorizer_", "fractal_daemon_config_set",
    "extern",
    NULL
};

static bool oracle_is_plain(const char *s, size_t len) {
    size_t i;
    for (i = 0; i < len; i++) {
        unsigned char c = (unsigned char) s[i];
        if (c >= 0x80) return false;             /* not plain ASCII */
        if (c == '\'' || c == '"' || c == '`') return false;  /* a quoted run */
        if (c == '#') return false;               /* a line comment */
        if (c == '/' && i + 1 < len && (s[i + 1] == '*' || s[i + 1] == '/')) return false;   /* a block comment, or Druid SQL's "//" line comment */
        if (c == '\\') return false;              /* an escape: Druid SQL has none, MariaDB's strings have */
        if (c == '-' && i + 1 < len && s[i + 1] == '-') return false;
    }
    return true;
}

/* Strip the leading whitespace and the documented comment forms, then
 * read the first word. */
static void oracle_classify(const char *s, size_t len, char *out, size_t out_cap) {
    size_t i = 0;
    size_t w = 0;
    int k;
    for (;;) {
        while (i < len && isspace((unsigned char) s[i])) i++;
        if (i + 1 < len && s[i] == '-' && s[i + 1] == '-' &&
            (i + 2 >= len || isspace((unsigned char) s[i + 2]))) {
            while (i < len && s[i] != '\n') i++;
            continue;
        }
        if (i < len && s[i] == '#') {
            while (i < len && s[i] != '\n') i++;
            continue;
        }
        if (i + 1 < len && s[i] == '/' && s[i + 1] == '*') {
            i += 2;
            while (i + 1 < len && !(s[i] == '*' && s[i + 1] == '/')) i++;
            i = (i + 1 < len) ? i + 2 : len;
            continue;
        }
        break;
    }
    if (i >= len) { snprintf(out, out_cap, "OTHER"); return; }
    if (s[i] == '(') { snprintf(out, out_cap, "%s", ORACLE_UNDECIDED); return; }
    /* The word is read with the same identifier characters the product
     * uses (letters, digits, '_' and '$'), so that a keyword followed
     * by one of them is not a keyword: "SELECT$1" is an identifier, not
     * the SELECT statement. */
    while (i + w < len && (isalnum((unsigned char) s[i + w]) || s[i + w] == '_' || s[i + w] == '$')) w++;
    if (w == 0) { snprintf(out, out_cap, "OTHER"); return; }
    {
        char word[64];
        size_t n = w < sizeof(word) - 1 ? w : sizeof(word) - 1;
        memcpy(word, s + i, n);
        word[n] = '\0';
        for (k = 0; oracle_keywords[k]; k++) {
            size_t kl = strlen(oracle_keywords[k]);
            if (kl == n && strncasecmp(word, oracle_keywords[k], kl) == 0) {
                snprintf(out, out_cap, "%s", oracle_keywords[k]);
                return;
            }
        }
        if (strcasecmp(word, "WITH") == 0) {
            /* A WITH clause needs a real parse to say what follows it. */
            snprintf(out, out_cap, "%s", ORACLE_UNDECIDED);
            return;
        }
    }
    snprintf(out, out_cap, "OTHER");
}

/* Does the text call a denied function? The documented rule: an
 * identifier followed by '(' whose lower-cased name starts with a
 * denied prefix. The oracle does not skip quotes or comments (it only
 * runs on plain text, where there are none), so its answer is a
 * superset of the product's. */
static bool oracle_has_denied(const char *s, size_t len, char *which, size_t which_cap) {
    size_t i = 0;
    while (i < len) {
        if (isalnum((unsigned char) s[i]) || s[i] == '_') {
            size_t start = i;
            char name[128];
            size_t n, j;
            int k;
            while (i < len && (isalnum((unsigned char) s[i]) || s[i] == '_' || s[i] == '$')) i++;
            n = i - start;
            if (n >= sizeof(name)) n = sizeof(name) - 1;
            for (j = 0; j < n; j++)
                name[j] = (char) tolower((unsigned char) s[start + j]);
            name[n] = '\0';
            /* A call: the identifier, then an opening parenthesis. */
            while (i < len && (s[i] == ' ' || s[i] == '\t')) i++;
            if (i < len && s[i] == '(') {
                for (k = 0; oracle_denied[k]; k++) {
                    size_t pl = strlen(oracle_denied[k]);
                    if (strncmp(name, oracle_denied[k], pl) == 0) {
                        snprintf(which, which_cap, "%s", oracle_denied[k]);
                        return true;
                    }
                }
            }
            continue;
        }
        i++;
    }
    return false;
}

int LLVMFuzzerTestOneInput(const uint8_t *data, size_t size) {
    const char *sql = (const char *) data;
    const char *kw;
    const char *which = NULL;
    char oracle_kw[64];
    char oracle_which[128];

    if (size == 0) return 0;
    /* The scanners work on a length-delimited buffer, but the SQL they
     * read is text: a NUL would end it early for the product's own
     * string handling and confuse the comparison. */
    if (memchr(data, 0, size) != NULL) return 0;

    /* The product's scanners. */
    kw = t2s_classify_leading_stmt(sql, size);
    (void) t2s_count_statements(sql, size);
    (void) t2s_has_into_outfile(sql, size);
    (void) t2s_has_exec_comment(sql, size);
    (void) t2s_has_denied_call(sql, size, &which);

    if (!oracle_is_plain(sql, size)) return 0;

    /* The oracle's answers. */
    oracle_classify(sql, size, oracle_kw, sizeof(oracle_kw));
    oracle_which[0] = '\0';
    (void) oracle_has_denied(sql, size, oracle_which, sizeof(oracle_which));

    /* The leading statement class. */
    if (strcmp(oracle_kw, ORACLE_UNDECIDED) != 0) {
        const char *product = kw ? kw : "NULL";
        if (strcmp(product, "NULL") == 0) product = "OTHER";
        if (strcmp(oracle_kw, product) != 0) {
            fprintf(stderr, "t2s oracle disagreement: the oracle says \"%s\", "
                            "the product says \"%s\" for: %.*s\n",
                    oracle_kw, product, (int) (size > 200 ? 200 : size), sql);
            abort();
        }
    }

    /* The denied-call scan. The oracle is a superset, so the product
     * must find everything the oracle finds. */
    if (oracle_which[0] && !(which != NULL)) {
        fprintf(stderr, "t2s oracle disagreement: the oracle found the denied call "
                        "\"%s\", the product found none, for: %.*s\n",
                oracle_which, (int) (size > 200 ? 200 : size), sql);
        abort();
    }
    return 0;
}
