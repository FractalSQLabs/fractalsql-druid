/*
 * SPDX-License-Identifier: Apache-2.0
 * Copyright 2026 Daniel Gardiner d/b/a FractalSQLabs
 */
package com.fractalsqlabs.fractalsql.daemon;

import java.io.IOException;
import java.nio.channels.SocketChannel;
import java.util.Set;

/** One client connection: vetting, then a request loop until it ends. */
final class Connection implements Runnable {

    private final SocketChannel channel;
    private final long id;
    private final DaemonConfig cfg;
    private final Dispatcher dispatcher;
    private final Set<Connection> registry;
    private final Runnable onClosed;
    private volatile long lastActive = System.nanoTime();
    private volatile boolean busy;

    Connection(SocketChannel channel, long id, DaemonConfig cfg, Dispatcher dispatcher,
               Set<Connection> registry, Runnable onClosed)
    {
        this.channel = channel;
        this.id = id;
        this.cfg = cfg;
        this.dispatcher = dispatcher;
        this.registry = registry;
        this.onClosed = onClosed;
    }

    long id()
    {
        return id;
    }

    boolean busy()
    {
        return busy;
    }

    long lastActive()
    {
        return lastActive;
    }

    long idleNanos()
    {
        return cfg.idleTimeoutSecs * 1_000_000_000L;
    }

    int idleSecs()
    {
        return cfg.idleTimeoutSecs;
    }

    void close()
    {
        Server.closeQuietly(channel);
    }

    /** Whether the caller is on the allow-list, and a log-safe description of it. */
    private String peer()
    {
        try {
            final jdk.net.UnixDomainPrincipal p = channel.getOption(jdk.net.ExtendedSocketOptions.SO_PEERCRED);
            return p.user().getName();
        } catch (IOException | UnsupportedOperationException e) {
            return null;
        }
    }

    private boolean allowed(String user)
    {
        if (user == null) {
            return false;
        }
        for (int uid : cfg.allowedUids) {
            if (user.equals(Native.userName(uid))) {
                return true;
            }
        }
        return false;
    }

    @Override
    public void run()
    {
        try {
            serve();
        } finally {
            dispatcher.releaseOwner(id);
            Native.releaseThreadBuffers();
            close();
            registry.remove(this);
            onClosed.run();
        }
    }

    private void serve()
    {
        final String user = peer();
        if (!allowed(user)) {
            Log.warn("connection from " + (user == null ? "unknown peer" : "user " + user)
                    + " refused: not in the allow-list");
            return;
        }
        final String peer = "user " + user;
        final byte[] hdr = new byte[Protocol.HEADER_LEN];
        final byte[] tag = new byte[Protocol.TAG_LEN];
        try {
            for (;;) {
                if (!Server.readFully(channel, hdr, 0, hdr.length)) {
                    return;
                }
                lastActive = System.nanoTime();
                final Protocol.Header h = Protocol.decode(hdr);
                if (h == null) {
                    Log.warn("connection " + id + " from " + peer + " sent a malformed header");
                    return;
                }
                if (h.version() != Protocol.VERSION || h.authLen() != Protocol.TAG_LEN) {
                    Log.warn("connection " + id + " from " + peer + " sent protocol version " + h.version());
                    return;
                }
                if (h.payloadLen() > Protocol.MAX_PAYLOAD) {
                    Log.warn("connection " + id + " from " + peer + " sent a " + h.payloadLen()
                            + "-byte payload over the limit");
                    return;
                }
                if ((h.flags() & Protocol.FLAG_RESPONSE) != 0) {
                    return;
                }
                if (!Server.readFully(channel, tag, 0, tag.length)) {
                    return;
                }
                final byte[] payload = new byte[(int) h.payloadLen()];
                if (payload.length > 0 && !Server.readFully(channel, payload, 0, payload.length)) {
                    return;
                }
                if (!Protocol.tagsEqual(tag, Protocol.tag(cfg.key, hdr, payload))) {
                    Log.warn("connection " + id + " from " + peer + " failed authentication (opcode 0x"
                            + String.format("%04x", h.opcode()) + ", request " + (h.requestId() & 0xffffffffL) + ")");
                    return;
                }

                busy = true;
                final IdempotencyCache.Reply rep;
                try {
                    rep = dispatcher.dispatch(id, h, payload);
                } finally {
                    busy = false;
                    lastActive = System.nanoTime();
                }
                if (rep.status() != Protocol.OK) {
                    final String body = new String(rep.body(), 0, Math.min(rep.body().length, 200),
                            java.nio.charset.StandardCharsets.UTF_8);
                    Log.warn("opcode 0x" + String.format("%04x", h.opcode()) + " failed: status " + rep.status()
                            + ", core rc " + rep.coreRc() + ", " + body);
                }
                send(h, rep);
            }
        } catch (IOException e) {
            // The peer went away or the connection was closed under us.
        } catch (RuntimeException e) {
            Log.error("connection " + id + ": " + e);
        }
    }

    private void send(Protocol.Header req, IdempotencyCache.Reply rep) throws IOException
    {
        final byte[] payload = new byte[8 + rep.body().length];
        java.nio.ByteBuffer.wrap(payload).order(java.nio.ByteOrder.LITTLE_ENDIAN)
                .putInt(rep.status()).putInt(rep.coreRc()).put(rep.body());
        final int flags = Protocol.FLAG_RESPONSE | (rep.status() != Protocol.OK ? Protocol.FLAG_ERROR : 0);
        final byte[] hdr = Protocol.encode(req.opcode(), flags, req.requestId(), req.context(), payload.length);
        final byte[] tag = Protocol.tag(cfg.key, hdr, payload);
        final byte[] frame = new byte[hdr.length + tag.length + payload.length];
        System.arraycopy(hdr, 0, frame, 0, hdr.length);
        System.arraycopy(tag, 0, frame, hdr.length, tag.length);
        System.arraycopy(payload, 0, frame, hdr.length + tag.length, payload.length);
        Server.writeFully(channel, frame);
    }
}
