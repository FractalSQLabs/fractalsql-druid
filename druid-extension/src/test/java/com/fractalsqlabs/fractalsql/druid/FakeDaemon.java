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
import java.nio.channels.ServerSocketChannel;
import java.nio.channels.SocketChannel;
import java.nio.charset.StandardCharsets;
import java.nio.file.Files;
import java.nio.file.Path;
import java.security.MessageDigest;
import java.util.concurrent.atomic.AtomicInteger;
import javax.crypto.Mac;
import javax.crypto.spec.SecretKeySpec;

/**
 * A stand-in for {@code fractalsqld} that speaks its frame protocol and answers every call with
 * text, so the service tier's reasoning and embedding steps run with no model behind them.
 *
 * <p>{@code fractal_embed} answers a three-number vector; {@code fractal_reason} answers a
 * statement the SQL pipeline accepts; the rest answer a short text. {@link #fail} makes every
 * call drop its connection, the way a daemon that has died would.
 */
final class FakeDaemon implements AutoCloseable {

    private static final byte[] KEY = new byte[] {1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16};

    final Path socket;
    final Path keyFile;
    final AtomicInteger calls = new AtomicInteger();
    volatile boolean fail;
    /** When set, every call answers with this text instead of its usual answer. */
    volatile String forced;
    /** Answers for particular functions, which win over {@link #forced} and the usual answers. */
    final java.util.concurrent.ConcurrentHashMap<String, String> answers = new java.util.concurrent.ConcurrentHashMap<>();
    /** Functions whose calls drop the connection, while the rest answer. */
    final java.util.Set<String> failing = java.util.concurrent.ConcurrentHashMap.newKeySet();
    /** When true, every call answers NULL. */
    volatile boolean nullReply;
    /** When set, every call answers with this integer (the type the ledger's counts come back as). */
    volatile Long forcedInt;
    /** When not zero, every call fails with this protocol status (and with {@link #replyCore} as the core's code). */
    volatile int replyStatus;
    volatile int replyCore;

    private final ServerSocketChannel server;

    FakeDaemon(Path dir) throws Exception
    {
        socket = dir.resolve("d.sock");
        keyFile = dir.resolve("hmac.key");
        Files.writeString(keyFile, "0102030405060708090a0b0c0d0e0f10\n");
        server = ServerSocketChannel.open(StandardProtocolFamily.UNIX);
        server.bind(UnixDomainSocketAddress.of(socket));
        final Thread acceptor = new Thread(() -> {
            while (server.isOpen()) {
                try {
                    final SocketChannel ch = server.accept();
                    final Thread t = new Thread(() -> serve(ch));
                    t.setDaemon(true);
                    t.start();
                } catch (IOException e) {
                    return;
                }
            }
        });
        acceptor.setDaemon(true);
        acceptor.start();
    }

    @Override
    public void close() throws IOException
    {
        server.close();
    }

    private static byte[] hmac(byte[] a, byte[] b) throws Exception
    {
        final Mac m = Mac.getInstance("HmacSHA256");
        m.init(new SecretKeySpec(KEY, "HmacSHA256"));
        m.update(a);
        m.update(b);
        return m.doFinal();
    }

    private static boolean readFully(SocketChannel ch, byte[] dst) throws IOException
    {
        final ByteBuffer b = ByteBuffer.wrap(dst);
        while (b.hasRemaining()) {
            if (ch.read(b) < 0) {
                return false;
            }
        }
        return true;
    }

    private static String answer(String fn)
    {
        switch (fn) {
            case "fractal_embed":
                return "[0.1,0.2,0.3]";
            case "fractal_reason":
                return "SELECT COUNT(*) FROM \"t\";";
            case "fractal_ledger_verify":
                return "{\"ok\":true,\"rows\":0}";
            case "fractal_edition":
                return "Community";
            default:
                return "1";
        }
    }

    private void serve(SocketChannel ch)
    {
        try {
            String fn = "";
            while (true) {
                final byte[] hdr = new byte[32];
                if (!readFully(ch, hdr)) {
                    return;
                }
                final byte[] tag = new byte[32];
                readFully(ch, tag);
                final ByteBuffer hb = ByteBuffer.wrap(hdr).order(ByteOrder.LITTLE_ENDIAN);
                final int opcode = hb.getShort(6) & 0xffff;
                final int requestId = hb.getInt(12);
                final long context = hb.getLong(16);
                final byte[] payload = new byte[hb.getInt(28)];
                readFully(ch, payload);
                if (!MessageDigest.isEqual(tag, hmac(hdr, payload))) {
                    return;
                }
                byte[] body = new byte[0];
                if (opcode == 0x10) {
                    final int n = payload[0] & 0xff;
                    fn = new String(payload, 1, n, StandardCharsets.UTF_8);
                    final ByteBuffer b = ByteBuffer.allocate(17 + 1).order(ByteOrder.LITTLE_ENDIAN);
                    b.putLong(42).putInt(1 << 20).put((byte) 1).putInt(1).put((byte) 1);
                    body = b.array();
                } else if (opcode == 0x11) {
                    calls.incrementAndGet();
                    if (fail || failing.contains(fn)) {
                        ch.close();
                        return;
                    }
                    final Long fi = forcedInt;
                    final String own = answers.get(fn);
                    final String f = own != null ? own : forced;
                    final byte[] out = (f != null ? f : answer(fn)).getBytes(StandardCharsets.UTF_8);
                    final ByteBuffer b = ByteBuffer.allocate(6 + out.length).order(ByteOrder.LITTLE_ENDIAN);
                    if (fi != null) {
                        final ByteBuffer ib = ByteBuffer.allocate(14).order(ByteOrder.LITTLE_ENDIAN);
                        ib.put((byte) 2).put((byte) 0).putInt(8).putLong(fi);
                        body = ib.array();
                    } else if (nullReply) {
                        b.put((byte) 1).put((byte) 1).putInt(0);
                    } else {
                        b.put((byte) 1).put((byte) 0).putInt(out.length).put(out);
                    }
                    if (fi == null) {
                        body = b.array();
                    }
                }
                final byte[] rp = new byte[8 + body.length];
                final boolean failing = opcode == 0x11 && replyStatus != 0;
                ByteBuffer.wrap(rp).order(ByteOrder.LITTLE_ENDIAN)
                        .putInt(failing ? replyStatus : 0).putInt(failing ? replyCore : 0).put(body);
                final ByteBuffer rh = ByteBuffer.allocate(32).order(ByteOrder.LITTLE_ENDIAN);
                rh.put(new byte[] {'F', 'S', 'Q', '1'}).putShort((short) 2).putShort((short) opcode)
                        .putInt(1).putInt(requestId).putLong(context).putInt(32).putInt(rp.length);
                final byte[] rtag = hmac(rh.array(), rp);
                final ByteBuffer frame = ByteBuffer.allocate(64 + rp.length);
                frame.put(rh.array()).put(rtag).put(rp).flip();
                while (frame.hasRemaining()) {
                    ch.write(frame);
                }
            }
        } catch (Exception e) {
            // the connection ended
        }
    }
}
