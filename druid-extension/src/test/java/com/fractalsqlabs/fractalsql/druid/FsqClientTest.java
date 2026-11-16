/*
 * SPDX-License-Identifier: Apache-2.0
 * Copyright 2026 Daniel Gardiner d/b/a FractalSQLabs
 */
package com.fractalsqlabs.fractalsql.druid;

import org.junit.jupiter.api.AfterEach;
import org.junit.jupiter.api.BeforeEach;
import org.junit.jupiter.api.Test;
import org.junit.jupiter.api.io.TempDir;

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

import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertFalse;
import static org.junit.jupiter.api.Assertions.assertNull;
import static org.junit.jupiter.api.Assertions.assertThrows;
import static org.junit.jupiter.api.Assertions.assertTrue;

/** The FSQ client, against a small in-test server that speaks the protocol. */
public class FsqClientTest {

    private static final byte[] KEY = new byte[] {1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16};

    @TempDir
    Path dir;

    private ServerSocketChannel server;
    private Thread acceptor;
    private final AtomicInteger calls = new AtomicInteger();
    private volatile boolean dropFirstCall;
    private volatile boolean sawBadTag;
    private volatile boolean closeAfterEachCall;

    private FsqClient client;

    @BeforeEach
    public void start() throws Exception
    {
        final Path sock = dir.resolve("d.sock");
        final Path key = dir.resolve("hmac.key");
        Files.writeString(key, "0102030405060708090a0b0c0d0e0f10\n");
        server = ServerSocketChannel.open(StandardProtocolFamily.UNIX);
        server.bind(UnixDomainSocketAddress.of(sock));
        acceptor = new Thread(() -> {
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
        client = new FsqClient(sock::toString, key::toString, () -> 5000L);
    }

    @AfterEach
    public void stop() throws Exception
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

    /** A function table of one: echo(text) returns its argument upper-cased; "nothing" returns NULL. */
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
                    sawBadTag = true;
                    return;
                }
                byte[] body = new byte[0];
                int status = 0;
                if (opcode == 0x10) {
                    final int n = payload[0] & 0xff;
                    fn = new String(payload, 1, n, StandardCharsets.UTF_8);
                    if (fn.equals("fractal_unknown")) {
                        status = 7;
                        body = "unknown function".getBytes(StandardCharsets.UTF_8);
                    } else {
                        final ByteBuffer b = ByteBuffer.allocate(17 + 1).order(ByteOrder.LITTLE_ENDIAN);
                        b.putLong(42).putInt(1 << 20).put((byte) 1).putInt(1).put((byte) 1);
                        body = b.array();
                    }
                } else if (opcode == 0x11) {
                    calls.incrementAndGet();
                    if (dropFirstCall && calls.get() == 1) {
                        ch.close();
                        return;
                    }
                    final int n = payload[0] & 0xff;
                    final int argsAt = 1 + n + 8 + 4;
                    final int len = ByteBuffer.wrap(payload).order(ByteOrder.LITTLE_ENDIAN).getInt(argsAt + 2);
                    final String text = new String(payload, argsAt + 6, len, StandardCharsets.UTF_8);
                    final boolean isNull = text.equals("nothing");
                    final byte[] out = isNull ? new byte[0] : text.toUpperCase().getBytes(StandardCharsets.UTF_8);
                    final ByteBuffer b = ByteBuffer.allocate(6 + out.length).order(ByteOrder.LITTLE_ENDIAN);
                    b.put((byte) 1).put((byte) (isNull ? 1 : 0)).putInt(out.length).put(out);
                    body = b.array();
                }
                final byte[] rp = new byte[8 + body.length];
                ByteBuffer.wrap(rp).order(ByteOrder.LITTLE_ENDIAN).putInt(status).putInt(0).put(body);
                final ByteBuffer rh = ByteBuffer.allocate(32).order(ByteOrder.LITTLE_ENDIAN);
                rh.put(new byte[] {'F', 'S', 'Q', '1'}).putShort((short) 2).putShort((short) opcode)
                        .putInt(1 | (status != 0 ? 2 : 0)).putInt(requestId).putLong(context).putInt(32).putInt(rp.length);
                final byte[] rtag = hmac(rh.array(), rp);
                final ByteBuffer frame = ByteBuffer.allocate(64 + rp.length);
                frame.put(rh.array()).put(rtag).put(rp).flip();
                while (frame.hasRemaining()) {
                    ch.write(frame);
                }
                if (closeAfterEachCall && opcode == 0x12) {
                    ch.close();   // the daemon closed (or restarted): the client's pooled connection is now dead
                    return;
                }
            }
        } catch (Exception e) {
            // the connection ended
        }
    }

    @Test
    public void aCallRoundTrips() throws Exception
    {
        assertEquals("HELLO", client.call("fractal_echo", "hello").text());
        assertEquals(1, calls.get());
    }

    @Test
    public void aNullResultIsNull() throws Exception
    {
        assertTrue(client.call("fractal_echo", "nothing").isNull());
        assertNull(client.call("fractal_echo", "nothing").text());
    }

    @Test
    public void connectionsAreReused() throws Exception
    {
        for (int i = 0; i < 5; i++) {
            assertEquals("A", client.call("fractal_echo", "a").text());
        }
        assertEquals(5, calls.get());
    }

    @Test
    public void anUnknownFunctionIsRefusedWithItsStatus()
    {
        final FsqClient.FsqException e =
                assertThrows(FsqClient.FsqException.class, () -> client.call("fractal_unknown"));
        assertEquals(7, e.status());
        assertEquals("unknown function", e.getMessage());
    }

    @Test
    public void aDroppedCallIsSentOnceMore() throws Exception
    {
        dropFirstCall = true;
        assertEquals("AGAIN", client.call("fractal_echo", "again").text());
        assertEquals(2, calls.get());
    }

    @Test
    public void aCallToTheProviderIsNotResent() throws Exception
    {
        dropFirstCall = true;
        final FsqClient.FsqException e =
                assertThrows(FsqClient.FsqException.class, () -> client.call("fractal_reason", 1L, "q"));
        assertEquals(-1, e.status());
        assertEquals(1, calls.get());
    }

    @Test
    public void aStalePooledConnectionDoesNotFailAProviderCall() throws Exception
    {
        closeAfterEachCall = true;
        // The first call opens a connection, which the daemon closes after the call; the client pools it anyway.
        assertEquals("A", client.call("fractal_embed", "a").text());
        // The second call picks up the dead connection. Nothing was sent on it, so the call may safely go to a fresh one,
        // even though a provider call is never resent once it has been sent.
        assertEquals("B", client.call("fractal_embed", "b").text());
        assertEquals(2, calls.get());
    }

    @Test
    public void everyFrameIsAuthenticated() throws Exception
    {
        client.call("fractal_echo", "x");
        assertFalse(sawBadTag);
    }

    @Test
    public void aMissingDaemonIsReportedNotThrownAsAnError()
    {
        final FsqClient none = new FsqClient(() -> dir.resolve("none.sock").toString(),
                () -> dir.resolve("hmac.key").toString(), () -> 1000L);
        assertFalse(none.available());
        assertThrows(FsqClient.FsqException.class, () -> none.call("fractal_echo", "x"));
    }

    @Test
    public void theDaemonIsAvailableWhenItAnswers()
    {
        assertTrue(client.available());
    }
}
