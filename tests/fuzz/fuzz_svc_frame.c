/* SPDX-License-Identifier: Apache-2.0
 * SPDX-FileCopyrightText: 2026 Daniel Gardiner d/b/a FractalSQLabs
 *
 * fuzz_svc_frame -- the FSQ frame reader, fuzzed with the tag check ON.
 *
 * This is what a client that has no key sends: bytes straight at the frame
 * reader. Nearly every input must be rejected, and the point of the harness
 * is that the rejection is clean -- no crash, no out-of-bounds read in the
 * header decode, the length handling, or the HMAC comparison.
 *
 * The daemon's own source is included, so the header decode, the length
 * checks and the tag comparison are the product's own code.
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
    uint8_t hdr[FSQ_HEADER_LEN];
    uint8_t tag[FSQ_TAG_LEN];
    uint8_t want[FSQ_TAG_LEN];
    const uint8_t *payload = NULL;
    size_t plen = 0;
    size_t i;

    if (size < FSQ_HEADER_LEN) return 0;

    memset(&cfg, 0, sizeof(cfg));
    for (i = 0; i < sizeof(cfg.key); i++) cfg.key[i] = (uint8_t) (0xA5 ^ i);
    cfg.key_len = 32;

    /* The header is the first 32 bytes of the input; the rest is the
     * payload (capped: the protocol allows 80 MiB, a fuzzer does not
     * need to hand it that much). */
    memcpy(hdr, data, FSQ_HEADER_LEN);
    payload = data + FSQ_HEADER_LEN;
    plen = size - FSQ_HEADER_LEN;
    if (plen > 4096) plen = 4096;

    /* The magic check, exactly as the daemon does it. */
    if (fsq_header_decode(hdr, &h) != 0) return 0;

    /* The daemon's own frame checks, in its order. */
    if (h.version != FSQ_PROTOCOL_VERSION || h.auth_len != FSQ_TAG_LEN) return 0;
    if (h.payload_len > FSQ_MAX_PAYLOAD) return 0;
    if (h.flags & FSQ_FLAG_RESPONSE) return 0;

    /* The tag the client sent, and the tag the daemon computes. The
     * client's tag is taken from the fuzzed input, so it is wrong
     * almost always -- the comparison must reject it. */
    memcpy(tag, payload, plen < FSQ_TAG_LEN ? plen : FSQ_TAG_LEN);
    mac(&cfg, hdr, payload, plen, want);
    (void) fsq_ct_equal(tag, want, FSQ_TAG_LEN);

    /* The payload length in the header is the daemon's own idea of how
     * long the payload is; the frame reader trusts it. A header that
     * claims more than the input holds is the length-handling case. */
    if (h.payload_len != plen) {
        /* The daemon would read h.payload_len bytes from the socket; a
         * frame that claims fewer than the bytes present is the case
         * where the reader must not over-read. */
        size_t claimed = h.payload_len;
        if (claimed > FSQ_MAX_PAYLOAD) return 0;
        if (claimed > plen) return 0;
        mac(&cfg, hdr, payload, claimed, want);
        (void) fsq_ct_equal(tag, want, FSQ_TAG_LEN);
    }
    return 0;
}
