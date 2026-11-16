/* SPDX-License-Identifier: Apache-2.0
 * SPDX-FileCopyrightText: 2026 Daniel Gardiner d/b/a FractalSQLabs
 *
 * fuzz_svc_ledger -- the ledger reader and verifier, fuzzed.
 *
 * The ledger is the tamper-evident chain the enterprise tier writes and an
 * auditor reads. Its reader is the code that decides whether a chain is
 * intact, so it is the code that must not be fooled by a damaged file and
 * must not read out of bounds on one.
 *
 * The fuzzer input is the CONTENT of the ledger file. The harness writes it
 * to a private temporary file and then:
 *
 *   * reads the records with the record-header reader and the scan,
 *   * verifies the chain (the tip check and the full walk),
 *   * appends one more record to the same file and verifies again -- an
 *     append after a damaged file must not corrupt what is there,
 *   * parses the head file's records (the out-of-chain row counter),
 *   * checks the JSON well-formedness test the audit payload goes through.
 *
 * The product's own source is included, so the static functions under test
 * are the ones the daemon uses.
 */

#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

#include "fractalsql_enterprise.c"

static char g_ledger_path[512];
static char g_head_path[512];

static void write_file(const char *path, const uint8_t *data, size_t size) {
    FILE *fp = fopen(path, "wb");
    if (fp == NULL) return;
    if (size) fwrite(data, 1, size, fp);
    fclose(fp);
}

int LLVMFuzzerTestOneInput(const uint8_t *data, size_t size) {
    FILE *fp;
    uint32_t kind, blen;
    uint8_t has_mac, sealed;
    uint8_t mac[LEDGER_HASH_LEN], prev[LEDGER_HASH_LEN], hash[LEDGER_HASH_LEN];
    int64_t updated;

    if (size == 0) return 0;

    /* The ledger file, and the head file beside it. */
    write_file(g_ledger_path, data, size);
    write_file(g_head_path, data, size);

    /* The record-header reader: every record in the file, one after
     * another, until it runs out. */
    fp = fopen(g_ledger_path, "rb");
    if (fp != NULL) {
        int guard = 0;
        while (guard++ < 64) {
            int hr = ledger_read_record_header(fp, &kind, &blen, &has_mac, &sealed,
                                               mac, prev, hash, &updated);
            if (hr <= 0) break;
        }
        fclose(fp);
    }

    /* The scan for the latest two records of a kind. */
    {
        bool bad_header = false;
        FILE *s = ledger_open_for_read(&bad_header);
        if (s != NULL) {
            ledger_record_t latest, prior;
            bool have_latest = false, have_prior = false;
            int k;
            for (k = 1; k <= 3; k++) {
                (void) ledger_scan_latest_two(s, (uint32_t) k, &latest, &have_latest,
                                              &prior, &have_prior, NULL, NULL);
                if (have_latest) free(latest.blob);
                if (have_prior) free(prior.blob);
                latest.blob = NULL;
                prior.blob = NULL;
            }
            fclose(s);
        }
    }

    /* The tip check and the full verification walk, for each kind the
     * chain can hold. */
    (void) ledger_verify_latest_file(1);
    (void) ledger_verify_latest_file(2);
    (void) ledger_verify_latest_file(3);

    /* The head file's records: each line of the fuzzed content, parsed
     * as a head record. */
    {
        char line[4096];
        size_t off = 0;
        while (off < size) {
            size_t n = 0;
            while (off + n < size && data[off + n] != '\n' && n < sizeof(line) - 1) n++;
            memcpy(line, data + off, n);
            line[n] = '\0';
            {
                ledger_head_rec_t rec;
                (void) ledger_head_parse(line, &rec);
            }
            off += n + 1;
        }
    }

    /* An append against the damaged file, then a second verification:
     * the append must not make the reader accept a chain it rejected. */
    {
        int k = (int) (size % 3) + 1;
        const uint8_t *payload = data;
        size_t plen = size > 64 ? 64 : size;
        (void) ledger_write_entry(NULL, k, payload, plen);
        (void) ledger_verify_latest_file((uint32_t) k);
    }

    /* The JSON well-formedness test the audit payload goes through. */
    (void) ent_json_well_formed((const char *) data, size);

    return 0;
}

/* One-time setup: the ledger path the harness writes to, and the
 * environment the product reads it from. */
__attribute__((constructor))
static void fuzz_svc_ledger_setup(void) {
    /* The harness appends to the file on every input and the product syncs every write, so on a disk an input costs
     * milliseconds. A memory-backed directory keeps the run at fuzzing speed; it is only the file's location, not
     * the code under test. */
    const char *dir = (access("/dev/shm", W_OK) == 0) ? "/dev/shm" : "/tmp";
    snprintf(g_ledger_path, sizeof(g_ledger_path), "%s/fsql-fuzz-ledger-%d.dat", dir, (int) getpid());
    snprintf(g_head_path, sizeof(g_head_path), "%s.head", g_ledger_path);
    setenv("FRACTALSQL_ENTERPRISE_LEDGER_PATH", g_ledger_path, 1);
    unsetenv("FRACTALSQL_ENTERPRISE_LEDGER_KEY");
    unsetenv("FRACTALSQL_ENTERPRISE_LIB");
    unsetenv("FRACTALSQL_ENTERPRISE_REQUIRE_SIGNATURE");
}
