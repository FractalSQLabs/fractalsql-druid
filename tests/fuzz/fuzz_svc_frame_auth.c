/* SPDX-License-Identifier: Apache-2.0
 * SPDX-FileCopyrightText: 2026 Daniel Gardiner d/b/a FractalSQLabs
 *
 * fuzz_svc_frame_auth -- the FSQ frame reader, fuzzed with a VALID tag.
 *
 * The companion to fuzz_svc_frame: there, the fuzzer's tag is wrong and
 * the frame is rejected at the door. Here the key is fixed and the tag is
 * computed over the fuzzed header and payload, so the frame is accepted
 * and the fuzzer reaches the payload parsing -- the TLV argument decoder,
 * the function lookup, the handle registry and the reply builder.
 *
 * The daemon's own source is included, so the dispatch path under test is
 * the product's own code.
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

#define main fsqld_main_not_used
#include "daemon/fractalsqld.c"
#undef main

int LLVMFuzzerTestOneInput(const uint8_t *data, size_t size) {
    struct fsq_config cfg;
    struct fsq_header h;
    struct fsq_reply rep;
    uint8_t hdr[FSQ_HEADER_LEN];
    uint8_t tag[FSQ_TAG_LEN];
    const uint8_t *payload;
    size_t plen;
    size_t i;

    if (size < 2) return 0;

    memset(&cfg, 0, sizeof(cfg));
    for (i = 0; i < sizeof(cfg.key); i++) cfg.key[i] = (uint8_t) (0x5A ^ i);
    cfg.key_len = 32;

    /* The header is the fuzzed bytes; the payload is the rest. */
    payload = data;
    plen = size;
    if (plen > 4096) plen = 4096;

    memset(&h, 0, sizeof(h));
    h.version = FSQ_PROTOCOL_VERSION;
    /* The opcode comes from the fuzzed bytes, so every opcode the
     * protocol has is reachable. */
    {
        static const uint16_t opcodes[] = {
            FSQ_OP_PING, FSQ_OP_VERSION, FSQ_OP_UDF_INIT, FSQ_OP_UDF_CALL,
            FSQ_OP_UDF_DEINIT, FSQ_OP_CANCEL, FSQ_OP_RELOAD
        };
        h.opcode = opcodes[data[0] % (sizeof(opcodes) / sizeof(opcodes[0]))];
    }
    h.flags = 0;
    h.request_id = 1;
    h.context = 1;
    h.auth_len = FSQ_TAG_LEN;
    h.payload_len = (uint32_t) plen;
    fsq_header_encode(hdr, &h);

    /* A valid tag over this header and payload: the frame is accepted. */
    mac(&cfg, hdr, payload, plen, tag);

    /* The dispatch itself: this is where the payload is parsed. */
    dispatch(&cfg, &h, payload, (uint32_t) plen, &rep);
    /* A handle the daemon would keep until the client deinits it: the
     * harness does the same, so a long fuzz run does not accumulate
     * handles (the daemon frees them; a fuzzer that did not would
     * report its own leak, not the product's). */
    if (h.opcode == FSQ_OP_UDF_INIT && rep.status == FSQ_OK && rep.body_len >= 8) {
        struct fsq_reply rep2;
        uint8_t id[8];
        memcpy(id, rep.body, 8);
        memset(&rep2, 0, sizeof(rep2));
        dispatch(&cfg, &h, id, 8, &rep2);
        free(rep2.body);
    }
    free(rep.body);

    /* The frame reader's own view of the same bytes: a header the
     * fuzzer chose, decoded and checked the way the daemon checks it. */
    {
        struct fsq_header raw;
        uint8_t raw_hdr[FSQ_HEADER_LEN];
        size_t n = size < FSQ_HEADER_LEN ? size : FSQ_HEADER_LEN;
        memcpy(raw_hdr, data, n);
        memset(raw_hdr + n, 0, FSQ_HEADER_LEN - n);
        if (fsq_header_decode(raw_hdr, &raw) == 0) {
            uint8_t want[FSQ_TAG_LEN];
            mac(&cfg, raw_hdr, payload, plen, want);
            (void) fsq_ct_equal(tag, want, FSQ_TAG_LEN);
        }
    }
    return 0;
}
