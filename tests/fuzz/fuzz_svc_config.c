/* SPDX-License-Identifier: Apache-2.0
 * SPDX-FileCopyrightText: 2026 Daniel Gardiner d/b/a FractalSQLabs
 *
 * fuzz_svc_config -- the daemon's configuration file parser, fuzzed.
 *
 * The config file is the one file an operator edits by hand and the daemon
 * reloads at runtime, so its parser sees the least trustworthy input in the
 * product: a file whose lines are "key = value", where the key may be
 * unknown, the value may be enormous, and the file may be a different
 * length from the line buffer.
 *
 * The harness writes the fuzzed bytes to a private file and parses them
 * with the daemon's own parser, then runs the same validation the daemon
 * runs before it accepts a configuration -- at startup and again on every
 * RELOAD, so a hostile reload is covered by the same code.
 *
 * The daemon's own source is included, so the parser and the validators
 * under test are the product's own code.
 */

/* The daemon's own source uses the GNU socket extensions (struct
 * ucred), so the feature macro has to be set before ANY header is
 * included -- the daemon's own #define is too late by then, because a
 * system header has already pulled in features.h. */
#define _GNU_SOURCE

#include <stdbool.h>
#include <stdint.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <unistd.h>

#define main fsqld_main_not_used
#include "daemon/fractalsqld.c"
#undef main

static char g_conf_path[512];
static char g_key_path[512];

int LLVMFuzzerTestOneInput(const uint8_t *data, size_t size) {
    struct fsq_config cfg;
    FILE *fp;

    if (size == 0) return 0;

    /* The fuzzed bytes are the config file. */
    fp = fopen(g_conf_path, "wb");
    if (fp == NULL) return 0;
    fwrite(data, 1, size, fp);
    fclose(fp);

    /* The daemon's own parser. It returns -1 for a config it refuses,
     * which is the common case and perfectly fine. */
    if (load_config(g_conf_path, &cfg) == 0) {
        /* The same checks the daemon runs before it accepts a
         * configuration: at startup, and again on every RELOAD. */
        (void) validate_cfg(&cfg);
        (void) validate_provider_cfg(&cfg);
    }
    return 0;
}

__attribute__((constructor))
static void fuzz_svc_config_setup(void) {
    snprintf(g_conf_path, sizeof g_conf_path, "/tmp/fsql-fuzz-conf-%d.conf", (int) getpid());
    snprintf(g_key_path, sizeof g_key_path, "/tmp/fsql-fuzz-key-%d.hex", (int) getpid());
    {
        FILE *f = fopen(g_key_path, "w");
        if (f != NULL) {
            fputs("00112233445566778899aabbccddeeff00112233445566778899aabbccddeeff\n", f);
            fclose(f);
            chmod(g_key_path, 0600);
        }
    }
}
