/*
 * SPDX-License-Identifier: Apache-2.0
 * Copyright 2026 Daniel Gardiner d/b/a FractalSQLabs
 */
package com.fractalsqlabs.fractalsql.druid;

import java.io.IOException;
import java.net.StandardProtocolFamily;
import java.net.UnixDomainSocketAddress;
import java.nio.ByteBuffer;
import java.nio.ByteOrder;
import java.nio.channels.SocketChannel;
import java.nio.charset.StandardCharsets;
import java.nio.file.Files;
import java.nio.file.Path;
import java.security.MessageDigest;
import java.security.SecureRandom;
import java.util.ArrayDeque;
import java.util.Set;
import java.util.concurrent.Executors;
import java.util.concurrent.ScheduledExecutorService;
import java.util.concurrent.ScheduledFuture;
import java.util.concurrent.TimeUnit;
import javax.crypto.Mac;
import javax.crypto.spec.SecretKeySpec;

/**
 * A client for fractalsqld, over the FSQ wire protocol (version 2).
 *
 * <p>Each call opens a handle on a named function, calls it, and closes it, on one
 * pooled connection. A call that fails in transport is sent once more with the
 * same idempotency token, so the daemon answers a stateful call from its cache
 * rather than running it twice. Calls that reach the provider are never resent.
 */
public final class FsqClient {

    private static final int HEADER_LEN = 32;
    private static final int TAG_LEN = 32;
    private static final int OP_PING = 0x0001;
    private static final int OP_INIT = 0x0010;
    private static final int OP_CALL = 0x0011;
    private static final int OP_DEINIT = 0x0012;
    private static final int MAX_IDLE = 8;

    /** Statuses the daemon reports. */
    public static final int OK = 0;
    public static final int ERR_ARGS = 1;
    public static final int ERR_CORE = 3;
    public static final int ERR_BUSY = 8;

    /** Functions that reach the provider: never resent after a transport failure. */
    private static final Set<String> EXPENSIVE = Set.of(
            "fractal_reason", "fractal_embed", "fractal_t2s_generate", "fractal_t2s_review");

    /** A pooled connection idle longer than this is closed rather than reused (well inside the daemon's own idle limit). */
    private static final long IDLE_REUSE_NANOS = 60_000_000_000L;

    private static final int T_STRING = 1;
    private static final int T_INT = 2;
    private static final int T_REAL = 3;

    /** A call the daemon refused or could not complete. */
    public static final class FsqException extends Exception {
        private static final long serialVersionUID = 1L;
        private final int status;

        FsqException(int status, String message)
        {
            super(message);
            this.status = status;
        }

        /** The daemon's status code, or -1 for a transport failure. */
        public int status()
        {
            return status;
        }
    }

    /** One result value. */
    public static final class Result {
        private final int kind;
        private final boolean isNull;
        private final byte[] raw;

        Result(int kind, boolean isNull, byte[] raw)
        {
            this.kind = kind;
            this.isNull = isNull;
            this.raw = raw;
        }

        public boolean isNull()
        {
            return isNull;
        }

        public String text()
        {
            if (isNull) {
                return null;
            }
            if (kind == T_INT) {
                return Long.toString(asLong());
            }
            if (kind == T_REAL) {
                return Double.toString(asDouble());
            }
            return new String(raw, StandardCharsets.UTF_8);
        }

        public long asLong()
        {
            return ByteBuffer.wrap(raw).order(ByteOrder.LITTLE_ENDIAN).getLong();
        }

        public double asDouble()
        {
            return ByteBuffer.wrap(raw).order(ByteOrder.LITTLE_ENDIAN).getDouble();
        }
    }

    private static final ScheduledExecutorService WATCHDOG = Executors.newSingleThreadScheduledExecutor(r -> {
        final Thread t = new Thread(r, "fractalsql-fsq-timeout");
        t.setDaemon(true);
        return t;
    });

    private final java.util.function.Supplier<String> socketPath;
    private final java.util.function.Supplier<String> keyFile;
    private final java.util.function.LongSupplier timeoutMs;
    private final SecureRandom random = new SecureRandom();
    private final ArrayDeque<Connection> idle = new ArrayDeque<>();

    public FsqClient(
            java.util.function.Supplier<String> socketPath,
            java.util.function.Supplier<String> keyFile,
            java.util.function.LongSupplier timeoutMs)
    {
        this.socketPath = socketPath;
        this.keyFile = keyFile;
        this.timeoutMs = timeoutMs;
    }

    /** Whether the daemon answers a ping. */
    public boolean available()
    {
        try {
            final Connection c = borrow();
            try {
                c.request(OP_PING, new byte[0], 0L);
            } catch (IOException | FsqException e) {
                c.close();
                return false;
            }
            release(c);
            return true;
        } catch (IOException | FsqException e) {
            return false;
        }
    }

    /**
     * Runs one function.
     *
     * @param args {@link Long}, {@link Integer}, {@link Double}, {@link String} or null
     */
    public Result call(String function, Object... args) throws FsqException
    {
        long token = random.nextLong();
        if (token == 0) {
            token = 1;
        }
        final int attempts = EXPENSIVE.contains(function) ? 1 : 2;
        FsqException last = null;
        int stale = 0;
        for (int attempt = 0; attempt < attempts; attempt++) {
            Connection c = null;
            try {
                c = borrow();
                final Result r = c.invoke(function, args, token);
                release(c);
                return r;
            } catch (IOException e) {
                // A pooled connection can be dead without anyone having noticed: the daemon restarted, or it closed the
                // connection for idling. If the failure came before the call itself was sent, the daemon never saw the
                // call, so trying again on another connection is safe even for a provider call, which is otherwise
                // never sent twice. Each such failure uses up one pooled connection, so the retries are bounded.
                final boolean neverSent = c != null && c.reused && !c.callSent;
                if (c != null) {
                    c.close();
                }
                last = new FsqException(-1, "the daemon is not reachable: " + e.getMessage());
                if (neverSent && stale++ < MAX_IDLE) {
                    attempt--;
                }
            } catch (FsqException e) {
                if (c != null) {
                    release(c);
                }
                throw e;
            }
        }
        throw last;
    }

    private synchronized Connection pollIdle()
    {
        return idle.pollFirst();
    }

    private Connection borrow() throws IOException, FsqException
    {
        Connection c;
        while ((c = pollIdle()) != null) {
            c.reused = true;
            // The daemon closes a connection that has been idle for its limit (300 s by default). A call that fails on such
            // a connection is a call that never ran, but the expensive calls are not retried, so a stale connection must
            // never be handed out in the first place.
            if (System.nanoTime() - c.lastUsed <= IDLE_REUSE_NANOS) {
                return c;
            }
            c.close();
        }
        return new Connection();
    }

    private void release(Connection c)
    {
        c.lastUsed = System.nanoTime();
        synchronized (this) {
            if (idle.size() < MAX_IDLE) {
                idle.addFirst(c);
                return;
            }
        }
        c.close();
    }

    private static byte[] hexKey(String path) throws IOException
    {
        final String text = Files.readString(Path.of(path), StandardCharsets.US_ASCII).replaceAll("\\s", "");
        if (text.isEmpty() || text.length() % 2 != 0) {
            throw new IOException("the HMAC key file " + path + " is not valid hex");
        }
        final byte[] out = new byte[text.length() / 2];
        for (int i = 0; i < out.length; i++) {
            final int hi = Character.digit(text.charAt(2 * i), 16);
            final int lo = Character.digit(text.charAt(2 * i + 1), 16);
            if (hi < 0 || lo < 0) {
                throw new IOException("the HMAC key file " + path + " is not valid hex");
            }
            out[i] = (byte) ((hi << 4) | lo);
        }
        return out;
    }

    private static byte[] tlv(Object v)
    {
        if (v == null) {
            return new byte[] {T_STRING, 1, 0, 0, 0, 0};
        }
        if (v instanceof Long || v instanceof Integer) {
            final ByteBuffer b = ByteBuffer.allocate(14).order(ByteOrder.LITTLE_ENDIAN);
            b.put((byte) T_INT).put((byte) 0).putInt(8).putLong(((Number) v).longValue());
            return b.array();
        }
        if (v instanceof Double || v instanceof Float) {
            final ByteBuffer b = ByteBuffer.allocate(14).order(ByteOrder.LITTLE_ENDIAN);
            b.put((byte) T_REAL).put((byte) 0).putInt(8).putDouble(((Number) v).doubleValue());
            return b.array();
        }
        final byte[] s = v.toString().getBytes(StandardCharsets.UTF_8);
        final ByteBuffer b = ByteBuffer.allocate(6 + s.length).order(ByteOrder.LITTLE_ENDIAN);
        b.put((byte) T_STRING).put((byte) 0).putInt(s.length).put(s);
        return b.array();
    }

    /** One connection to the daemon. */
    private final class Connection {
        private final SocketChannel channel;
        private final byte[] key;
        private int requestId;
        volatile long lastUsed = System.nanoTime();
        /** Handed out from the pool rather than freshly connected. */
        volatile boolean reused;
        /** The call itself (not the handle open before it) has been sent on this connection. */
        volatile boolean callSent;

        Connection() throws IOException, FsqException
        {
            final String path = socketPath.get();
            if (path == null || path.isEmpty()) {
                throw new FsqException(-1, "druid.fractalsql.daemon_socket is not set");
            }
            this.key = hexKey(keyFile.get());
            this.channel = SocketChannel.open(StandardProtocolFamily.UNIX);
            try {
                channel.connect(UnixDomainSocketAddress.of(path));
            } catch (IOException e) {
                close();
                throw e;
            }
        }

        void close()
        {
            try {
                channel.close();
            } catch (IOException e) {
                // already closed
            }
        }

        private byte[] mac(byte[] header, byte[] payload) throws IOException
        {
            try {
                final Mac m = Mac.getInstance("HmacSHA256");
                m.init(new SecretKeySpec(key, "HmacSHA256"));
                m.update(header);
                m.update(payload);
                return m.doFinal();
            } catch (java.security.GeneralSecurityException e) {
                throw new IOException(e);
            }
        }

        private void readFully(byte[] dst) throws IOException
        {
            final ByteBuffer b = ByteBuffer.wrap(dst);
            while (b.hasRemaining()) {
                if (channel.read(b) < 0) {
                    throw new IOException("the daemon closed the connection");
                }
            }
        }

        /** Sends one request and returns the reply body, or throws for a non-zero status. */
        byte[] request(int opcode, byte[] payload, long context) throws IOException, FsqException
        {
            final ByteBuffer h = ByteBuffer.allocate(HEADER_LEN).order(ByteOrder.LITTLE_ENDIAN);
            h.put(new byte[] {'F', 'S', 'Q', '1'}).putShort((short) 2).putShort((short) opcode).putInt(0)
                    .putInt(++requestId).putLong(context).putInt(TAG_LEN).putInt(payload.length);
            final byte[] header = h.array();
            final byte[] tag = mac(header, payload);
            final ByteBuffer frame = ByteBuffer.allocate(HEADER_LEN + TAG_LEN + payload.length);
            frame.put(header).put(tag).put(payload).flip();

            final ScheduledFuture<?> timer = WATCHDOG.schedule(this::close, timeoutMs.getAsLong(), TimeUnit.MILLISECONDS);
            try {
                while (frame.hasRemaining()) {
                    channel.write(frame);
                }
                final byte[] rh = new byte[HEADER_LEN];
                readFully(rh);
                final byte[] rtag = new byte[TAG_LEN];
                readFully(rtag);
                final long plen = ByteBuffer.wrap(rh).order(ByteOrder.LITTLE_ENDIAN).getInt(28) & 0xffffffffL;
                if (plen < 8 || plen > 80L * 1024 * 1024) {
                    throw new IOException("the daemon sent a malformed reply");
                }
                final byte[] body = new byte[(int) plen];
                readFully(body);
                if (!MessageDigest.isEqual(rtag, mac(rh, body))) {
                    throw new IOException("the daemon's reply failed authentication");
                }
                final ByteBuffer b = ByteBuffer.wrap(body).order(ByteOrder.LITTLE_ENDIAN);
                final int status = b.getInt();
                b.getInt();
                final byte[] rest = new byte[body.length - 8];
                b.get(rest);
                if (status != OK) {
                    throw new FsqException(status, new String(rest, StandardCharsets.UTF_8));
                }
                return rest;
            } finally {
                timer.cancel(false);
            }
        }

        Result invoke(String function, Object[] args, long token) throws IOException, FsqException
        {
            callSent = false;
            final byte[] name = function.getBytes(StandardCharsets.UTF_8);
            final byte[][] encoded = new byte[args.length][];
            int argBytes = 0;
            for (int i = 0; i < args.length; i++) {
                encoded[i] = tlv(args[i]);
                argBytes += encoded[i].length;
            }
            final ByteBuffer init = ByteBuffer.allocate(1 + name.length + 4 + argBytes).order(ByteOrder.LITTLE_ENDIAN);
            init.put((byte) name.length).put(name).putInt(args.length);
            for (byte[] e : encoded) {
                init.put(e);
            }
            final byte[] opened = request(OP_INIT, init.array(), 0L);
            final long handle = ByteBuffer.wrap(opened).order(ByteOrder.LITTLE_ENDIAN).getLong();
            try {
                final ByteBuffer call = ByteBuffer.allocate(1 + name.length + 12 + argBytes).order(ByteOrder.LITTLE_ENDIAN);
                call.put((byte) name.length).put(name).putLong(handle).putInt(args.length);
                for (byte[] e : encoded) {
                    call.put(e);
                }
                callSent = true;
                final byte[] out = request(OP_CALL, call.array(), token);
                final ByteBuffer b = ByteBuffer.wrap(out).order(ByteOrder.LITTLE_ENDIAN);
                final int type = b.get() & 0xff;
                final boolean isNull = b.get() != 0;
                final int len = b.getInt();
                final byte[] raw = new byte[len];
                b.get(raw);
                return new Result(type, isNull, raw);
            } finally {
                try {
                    request(OP_DEINIT, ByteBuffer.allocate(8).order(ByteOrder.LITTLE_ENDIAN).putLong(handle).array(), 0L);
                } catch (IOException | FsqException e) {
                    // The handle goes away with the connection in any case.
                }
            }
        }
    }
}
