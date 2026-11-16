/* SPDX-License-Identifier: Apache-2.0
 * SPDX-FileCopyrightText: 2026 Daniel Gardiner d/b/a FractalSQLabs
 *
 * fuzz_svc_redact -- the audit redactor, fuzzed in all three modes.
 *
 * The audit trail is what an operator reads when something went wrong, and
 * the redactor is what decides what a row of it is allowed to show. It
 * parses JSON (its own hand-written parser, not a library's) and rewrites
 * the values under sensitive keys. A parser bug here is a leak: text that
 * should have been redacted, kept.
 *
 * The header is included directly, so the static functions are the ones the
 * product uses. The mode comes from FSQL_AUDIT_REDACT, which the harness
 * sets for each of the three modes in turn.
 */

#include <stdint.h>
#include <stdlib.h>
#include <string.h>

#include "fsql_audit_redact.h"

int LLVMFuzzerTestOneInput(const uint8_t *data, size_t size) {
    static const char *const modes[] = {"none", "hash", "truncate"};
    size_t m;

    if (size == 0) return 0;

    /* The redactor works on a NUL-terminated string, so the input is
     * copied with a NUL at the end and the first NUL in it is honoured
     * (a JSON document cannot contain one). */
    for (m = 0; m < sizeof(modes) / sizeof(modes[0]); m++) {
        char *text;
        char out[FSQL_AUDIT_REDACT_MAX * 4];
        char *redacted;

        setenv("FSQL_AUDIT_REDACT", modes[m], 1);

        text = (char *) malloc(size + 1);
        if (text == NULL) return 0;
        memcpy(text, data, size);
        text[size] = '\0';

        /* The byte form (length-delimited, so an embedded NUL is kept). */
        (void) fsql_audit_redact_bytes(text, size, out, sizeof(out));
        /* The text form. */
        (void) fsql_audit_redact_text(text, out, sizeof(out));
        /* The JSON form: the document is redacted by key name. */
        redacted = fsql_audit_redact_json(text);
        free(redacted);

        free(text);
    }
    return 0;
}
