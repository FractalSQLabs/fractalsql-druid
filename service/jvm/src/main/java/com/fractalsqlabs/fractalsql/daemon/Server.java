/*
 * SPDX-License-Identifier: Apache-2.0
 * Copyright 2026 Daniel Gardiner d/b/a FractalSQLabs
 */
package com.fractalsqlabs.fractalsql.daemon;

import java.io.IOException;
import java.net.StandardProtocolFamily;
import java.net.UnixDomainSocketAddress;
import java.nio.ByteBuffer;
import java.nio.channels.ClosedChannelException;
import java.nio.channels.ServerSocketChannel;
import java.nio.channels.SocketChannel;
import java.nio.file.Files;
import java.nio.file.Path;
import java.nio.file.attribute.PosixFilePermissions;
import java.util.Set;
import java.util.concurrent.ConcurrentHashMap;
import java.util.concurrent.atomic.AtomicInteger;
import java.util.concurrent.atomic.AtomicLong;
import java.util.concurrent.atomic.AtomicReference;

/**
 * The FSQ listener: a Unix domain socket, one platform thread per connection.
 *
 * <p>A function call runs on its connection's own thread, as it does in the
 * C daemon, because the native side keeps per-thread state.
 */
final class Server {

    private final AtomicReference<DaemonConfig> config;
    private final Dispatcher dispatcher;
    private final AtomicLong nextConn = new AtomicLong(1);
    private final AtomicInteger active = new AtomicInteger();
    private final Set<Connection> connections = ConcurrentHashMap.newKeySet();
    private volatile boolean stopping;
    private ServerSocketChannel listener;

    Server(AtomicReference<DaemonConfig> config, Dispatcher dispatcher)
    {
        this.config = config;
        this.dispatcher = dispatcher;
    }

    /** Binds the socket. */
    void open() throws IOException
    {
        final DaemonConfig cfg = config.get();
        final Path sock = Path.of(cfg.socketPath);
        if (Files.exists(sock, java.nio.file.LinkOption.NOFOLLOW_LINKS)
                && !Files.isRegularFile(sock, java.nio.file.LinkOption.NOFOLLOW_LINKS)
                && !Files.isDirectory(sock, java.nio.file.LinkOption.NOFOLLOW_LINKS)) {
            Files.delete(sock);
        }
        listener = ServerSocketChannel.open(StandardProtocolFamily.UNIX);
        // Bound under a private (0700) directory next to the final path, narrowed, and only then renamed into place: the
        // socket is never reachable by another user while it still has its default mode (SECURITY_AUDIT.md 3.26). A path too
        // long for a second sun_path (108 bytes) falls back to binding in place.
        final Path parent = sock.toAbsolutePath().getParent();
        Path stage = null;
        if (parent != null && parent.toString().length() + 24 < 100) {
            try {
                stage = Files.createTempDirectory(parent, ".fsqld-",
                        java.nio.file.attribute.PosixFilePermissions.asFileAttribute(
                                PosixFilePermissions.fromString("rwx------")));
            } catch (IOException e) {
                stage = null;
            }
        }
        if (stage == null) {
            listener.bind(UnixDomainSocketAddress.of(sock), 64);
            Files.setPosixFilePermissions(sock, PosixFilePermissions.fromString("rw-rw----"));
            return;
        }
        final Path staged = stage.resolve("s");
        try {
            listener.bind(UnixDomainSocketAddress.of(staged), 64);
            Files.setPosixFilePermissions(staged, PosixFilePermissions.fromString("rw-rw----"));
            Files.move(staged, sock, java.nio.file.StandardCopyOption.ATOMIC_MOVE);
        } finally {
            Files.deleteIfExists(staged);
            Files.deleteIfExists(stage);
        }
    }

    /** Accepts until stopped. */
    void serve()
    {
        final DaemonConfig first = config.get();
        Log.info("fractalsqld " + Dispatcher.VERSION + " listening on " + first.socketPath
                + " (max_connections=" + first.maxConnections + ", idle_timeout_secs="
                + first.idleTimeoutSecs + ", allowed_uids=" + first.allowedUids.size() + ")");
        startWatchdog();
        while (!stopping) {
            final SocketChannel ch;
            try {
                ch = listener.accept();
            } catch (ClosedChannelException e) {
                break;
            } catch (IOException e) {
                if (stopping) {
                    break;
                }
                Log.warn("accept: " + e.getMessage() + ", backing off");
                try {
                    Thread.sleep(100);
                } catch (InterruptedException ie) {
                    Thread.currentThread().interrupt();
                    break;
                }
                continue;
            }
            // The limit is read per accept, so a reload applies to the next connection.
            final int max = config.get().maxConnections;
            if (active.incrementAndGet() > max) {
                active.decrementAndGet();
                Log.warn("connection refused: max_connections reached");
                closeQuietly(ch);
                continue;
            }
            final Connection c = new Connection(ch, nextConn.getAndIncrement(), config.get(), dispatcher,
                    connections, active::decrementAndGet);
            connections.add(c);
            try {
                final Thread worker = new Thread(c, "fsq-conn-" + c.id());
                worker.setDaemon(true);
                worker.start();
            } catch (RuntimeException e) {
                Log.error("cannot start a thread for a connection: " + e.getMessage());
                connections.remove(c);
                active.decrementAndGet();
                closeQuietly(ch);
            }
        }
        Log.info("shutting down: no longer accepting connections");
        try {
            Files.deleteIfExists(Path.of(config.get().socketPath));
        } catch (IOException e) {
            // best effort
        }
    }

    void stop()
    {
        stopping = true;
        try {
            if (listener != null) {
                listener.close();
            }
        } catch (IOException e) {
            // closing anyway
        }
    }

    /** Closes connections that have been idle past the limit and are not inside a call. */
    private void startWatchdog()
    {
        final Thread t = new Thread(() -> {
            while (!stopping) {
                try {
                    Thread.sleep(1000);
                } catch (InterruptedException e) {
                    return;
                }
                final long now = System.nanoTime();
                for (Connection c : connections) {
                    if (!c.busy() && now - c.lastActive() > c.idleNanos()) {
                        Log.info("connection " + c.id() + " idle for " + c.idleSecs() + " s, closing");
                        c.close();
                    }
                }
            }
        }, "fsq-idle-watchdog");
        t.setDaemon(true);
        t.start();
    }

    static void closeQuietly(SocketChannel ch)
    {
        try {
            ch.close();
        } catch (IOException e) {
            // already closed
        }
    }

    /** Reads exactly n bytes, or returns false at end of stream. */
    static boolean readFully(SocketChannel ch, byte[] dst, int off, int n) throws IOException
    {
        final ByteBuffer b = ByteBuffer.wrap(dst, off, n);
        while (b.hasRemaining()) {
            if (ch.read(b) < 0) {
                return false;
            }
        }
        return true;
    }

    static void writeFully(SocketChannel ch, byte[] src) throws IOException
    {
        final ByteBuffer b = ByteBuffer.wrap(src);
        while (b.hasRemaining()) {
            ch.write(b);
        }
    }
}
