/*
 * SPDX-License-Identifier: Apache-2.0
 * Copyright 2026 Daniel Gardiner d/b/a FractalSQLabs
 */
package com.fractalsqlabs.fractalsql.daemon;

/**
 * Remembers the reply of a call that carried an idempotency token, so a
 * resend of the same call is answered from here and not run twice.
 *
 * <p>Keyed by the token and checked against the function name. Shared by
 * every connection on purpose: a resend arrives on a new connection, because
 * the old one is what died. A fixed ring of 256 replies, 64 MiB in all.
 */
final class IdempotencyCache {

    static final int ENTRIES = 256;
    static final long MAX_BYTES = 64L * 1024 * 1024;
    static final int ENTRY_MAX = 8 * 1024 * 1024;

    /** A reply: status, the adapter's return code, and the body. */
    record Reply(int status, int coreRc, byte[] body) {}

    private static final class Entry {
        long token;
        String name;
        Reply reply;
    }

    private final Entry[] ring = new Entry[ENTRIES];
    private int next;
    private long bytes;

    private int find(long token)
    {
        for (int i = 0; i < ENTRIES; i++) {
            if (ring[i] != null && ring[i].token == token) {
                return i;
            }
        }
        return -1;
    }

    /** The cached reply for this token and function, or null. */
    synchronized Reply replay(long token, String name)
    {
        final int i = find(token);
        if (i < 0 || !ring[i].name.equals(name)) {
            return null;
        }
        final Reply r = ring[i].reply;
        return new Reply(r.status(), r.coreRc(), r.body().clone());
    }

    synchronized void put(long token, String name, Reply reply)
    {
        if (token == 0 || reply.body().length > ENTRY_MAX || name.isEmpty() || name.length() >= 64) {
            return;
        }
        final Reply copy = new Reply(reply.status(), reply.coreRc(), reply.body().clone());
        final int hit = find(token);
        if (hit >= 0) {
            bytes -= ring[hit].reply.body().length;
            ring[hit].name = name;
            ring[hit].reply = copy;
            bytes += copy.body().length;
            return;
        }
        for (int scanned = 0; bytes + copy.body().length > MAX_BYTES && scanned <= ENTRIES; scanned++) {
            if (ring[next] != null) {
                bytes -= ring[next].reply.body().length;
                ring[next] = null;
            }
            next = (next + 1) % ENTRIES;
        }
        if (bytes + copy.body().length > MAX_BYTES) {
            return;
        }
        if (ring[next] != null) {
            bytes -= ring[next].reply.body().length;
        }
        final Entry e = new Entry();
        e.token = token;
        e.name = name;
        e.reply = copy;
        ring[next] = e;
        next = (next + 1) % ENTRIES;
        bytes += copy.body().length;
    }
}
