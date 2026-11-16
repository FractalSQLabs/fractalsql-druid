/*
 * SPDX-License-Identifier: Apache-2.0
 * Copyright 2026 Daniel Gardiner d/b/a FractalSQLabs
 */
package com.fractalsqlabs.fractalsql.druid;

import com.google.inject.Inject;
import com.google.inject.Singleton;

/**
 * The extension's connection to fractalsqld.
 *
 * <p>The reasoning and embedding providers, the enterprise library and its
 * ledger, and the per-session settings all live in the daemon, so there is one
 * ledger and one provider configuration for the whole cluster.
 */
@Singleton
public class FractalSqlDaemon {

    /** The session the node's own calls run in, unless a request names another. */
    public static final long NODE_SESSION = 1L;

    private final FsqClient client;

    @Inject
    public FractalSqlDaemon(FractalSqlConfig config)
    {
        this.client = new FsqClient(
                () -> config.operatorValue("daemon_socket"),
                () -> config.operatorValue("daemon_hmac_key_file"),
                () -> config.operatorLong("daemon_timeout_ms"));
    }

    /** Whether the daemon is reachable. */
    public boolean available()
    {
        return client.available();
    }

    /** The daemon client. */
    public FsqClient client()
    {
        return client;
    }

    /**
     * A session id the daemon can use, from a session name.
     *
     * <p>An empty name is the node's own session. The id is never 0 or 1 for a
     * named session, so a named session cannot collide with the node's.
     */
    public static long sessionId(String name)
    {
        if (name == null || name.isEmpty()) {
            return NODE_SESSION;
        }
        // SHA-256 of the name, 62 bits of it: stable across restarts and nodes, and two names collide with probability
        // ~2^-62 where String.hashCode() (31 bits, not a hash that resists collisions) collided at a few tens of
        // thousands of names, merging two sessions' state.
        try {
            final byte[] d = java.security.MessageDigest.getInstance("SHA-256")
                    .digest(name.getBytes(java.nio.charset.StandardCharsets.UTF_8));
            long v = 0;
            for (int i = 0; i < 8; i++) {
                v = (v << 8) | (d[i] & 0xffL);
            }
            return 2L + (v & 0x3fffffffffffffffL);
        } catch (java.security.NoSuchAlgorithmException e) {
            throw new IllegalStateException("SHA-256 is not available", e);
        }
    }

    /** The result's text, or null when the daemon is unreachable, refuses the call, or returns NULL. */
    public String textOrNull(String function, Object... args)
    {
        try {
            return client.call(function, args).text();
        } catch (FsqClient.FsqException e) {
            return null;
        }
    }
}
