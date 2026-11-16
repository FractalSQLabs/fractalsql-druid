/*
 * SPDX-License-Identifier: Apache-2.0
 * Copyright 2026 Daniel Gardiner d/b/a FractalSQLabs
 */
package com.fractalsqlabs.fractalsql.daemon;

import java.nio.ByteBuffer;
import java.nio.ByteOrder;
import java.nio.charset.StandardCharsets;
import java.nio.file.Path;
import java.util.HashMap;
import java.util.List;
import java.util.Map;
import java.util.concurrent.atomic.AtomicReference;

/** Runs one request: the control opcodes, and the function calls through the native side. */
final class Dispatcher {

    static final String VERSION = "2.0.0";

    private final HandleTable handles = new HandleTable();
    private final IdempotencyCache cache = new IdempotencyCache();
    private final Map<String, Integer> fnIndex = new HashMap<>();
    private final AtomicReference<DaemonConfig> config;
    private final Path configPath;

    Dispatcher(AtomicReference<DaemonConfig> config, Path configPath)
    {
        this.config = config;
        this.configPath = configPath;
        final int n = Native.functionCount();
        for (int i = 0; i < n; i++) {
            fnIndex.put(Native.functionName(i), i);
        }
    }

    /** The reply to a request: a status, the adapter's return code, a body. */
    private static IdempotencyCache.Reply text(int status, String text)
    {
        byte[] b = text.getBytes(StandardCharsets.UTF_8);
        if (b.length >= Protocol.MSG_MAX) {
            b = java.util.Arrays.copyOf(b, Protocol.MSG_MAX - 1);
        }
        return new IdempotencyCache.Reply(status, 0, b);
    }

    private static final byte[] NONE = new byte[0];

    IdempotencyCache.Reply dispatch(long conn, Protocol.Header h, byte[] payload)
    {
        switch (h.opcode()) {
            case Protocol.OP_PING: {
                final byte[] v = ByteBuffer.allocate(2).order(ByteOrder.LITTLE_ENDIAN)
                        .putShort((short) Protocol.VERSION).array();
                return new IdempotencyCache.Reply(Protocol.OK, 0, v);
            }
            case Protocol.OP_VERSION:
                return text(Protocol.OK, "fractalsqld " + VERSION + " protocol " + Protocol.VERSION);
            case Protocol.OP_UDF_INIT:
                return init(conn, payload);
            case Protocol.OP_UDF_CALL:
                return call(conn, h.context(), payload);
            case Protocol.OP_UDF_DEINIT:
                return deinit(conn, payload);
            case Protocol.OP_CANCEL:
                return cancel(payload);
            case Protocol.OP_RELOAD:
                if (payload.length != 0) {
                    return text(Protocol.ERR_ARGS, "RELOAD takes no payload");
                }
                return reload();
            default:
                return text(Protocol.ERR_NOTSUP, "");
        }
    }

    /** One argument off the wire. */
    private record Arg(int type, boolean isNull, byte[] bytes) {}

    private static Arg[] parseArgs(byte[] p, int off, int nargs)
    {
        final Arg[] out = new Arg[nargs];
        for (int i = 0; i < nargs; i++) {
            if (p.length - off < 6) {
                return null;
            }
            final int type = p[off] & 0xff;
            final boolean isNull = p[off + 1] != 0;
            final long len = Protocol.u32(p, off + 2);
            off += 6;
            if (p.length - off < len) {
                return null;
            }
            out[i] = new Arg(type, isNull, java.util.Arrays.copyOfRange(p, off, off + (int) len));
            off += (int) len;
        }
        return off == p.length ? out : null;
    }

    private static int wireToItem(int t)
    {
        switch (t) {
            case Protocol.T_INT: return 2;
            case Protocol.T_REAL: return 1;
            case Protocol.T_DECIMAL: return 4;
            default: return 0;
        }
    }

    private static int itemToWire(int t)
    {
        switch (t) {
            case 2: return Protocol.T_INT;
            case 1: return Protocol.T_REAL;
            case 4: return Protocol.T_DECIMAL;
            default: return Protocol.T_STRING;
        }
    }

    private IdempotencyCache.Reply init(long conn, byte[] p)
    {
        final IdempotencyCache.Reply bad = text(Protocol.ERR_ARGS, "malformed init request");
        if (p.length < 1) {
            return bad;
        }
        final int namelen = p[0] & 0xff;
        if (p.length < 1 + namelen + 4) {
            return bad;
        }
        final String name = new String(p, 1, namelen, StandardCharsets.UTF_8);
        final long n = Protocol.u32(p, 1 + namelen);
        if (n > Protocol.MAX_ARGS) {
            return bad;
        }
        final int nargs = (int) n;
        final Arg[] in = parseArgs(p, 1 + namelen + 4, nargs);
        if (in == null) {
            return bad;
        }
        final Integer idx = fnIndex.get(name);
        if (idx == null) {
            return text(Protocol.ERR_NOTSUP, "unknown function");
        }
        final int[] types = new int[nargs];
        final byte[][] consts = new byte[nargs][];
        for (int i = 0; i < nargs; i++) {
            types[i] = wireToItem(in[i].type());
            if (in[i].isNull()) {
                continue;
            }
            if ((types[i] == 2 || types[i] == 1) && in[i].bytes().length != 8) {
                return bad;
            }
            consts[i] = in[i].bytes();
        }
        final byte[] msg = new byte[Protocol.MSG_MAX];
        final long ptr = Native.open(idx, types, consts, msg);
        if (ptr == 0) {
            int len = 0;
            while (len < msg.length && msg[len] != 0) {
                len++;
            }
            return text(Protocol.ERR_ARGS, len > 0 ? new String(msg, 0, len, StandardCharsets.UTF_8)
                    : "initialization failed");
        }
        final int[] info = Native.info(ptr);
        final long id = handles.allocateId();
        final ByteBuffer body = ByteBuffer.allocate(17 + nargs).order(ByteOrder.LITTLE_ENDIAN);
        body.putLong(id);
        body.putInt(info[0]);
        body.put((byte) (info[1] != 0 ? 1 : 0));
        body.putInt(nargs);
        for (int i = 0; i < nargs; i++) {
            body.put((byte) itemToWire(info[2 + i]));
        }
        handles.add(new HandleTable.Handle(id, idx, name, ptr, nargs, conn));
        return new IdempotencyCache.Reply(Protocol.OK, 0, body.array());
    }

    private static IdempotencyCache.Reply tlv(int type, boolean isNull, byte[] bytes)
    {
        final ByteBuffer b = ByteBuffer.allocate(6 + bytes.length).order(ByteOrder.LITTLE_ENDIAN);
        b.put((byte) type);
        b.put((byte) (isNull ? 1 : 0));
        b.putInt(bytes.length);
        b.put(bytes);
        return new IdempotencyCache.Reply(Protocol.OK, 0, b.array());
    }

    private IdempotencyCache.Reply call(long conn, long token, byte[] p)
    {
        final IdempotencyCache.Reply bad = text(Protocol.ERR_ARGS, "");
        if (p.length < 1) {
            return bad;
        }
        final int namelen = p[0] & 0xff;
        if (p.length < 1 + namelen + 12) {
            return bad;
        }
        final String name = new String(p, 1, namelen, StandardCharsets.UTF_8);
        final long id = Protocol.u64(p, 1 + namelen);
        final long n = Protocol.u32(p, 1 + namelen + 8);
        if (n > Protocol.MAX_ARGS) {
            return bad;
        }
        final Arg[] in = parseArgs(p, 1 + namelen + 12, (int) n);
        if (in == null) {
            return bad;
        }

        // A resend is answered before the handle is looked up: it arrives on a
        // new connection, and the handle died with the old one.
        if (token != 0) {
            final IdempotencyCache.Reply cached = cache.replay(token, name);
            if (cached != null) {
                Log.info("UDF_CALL replayed from the idempotency cache (token "
                        + Long.toUnsignedString(token) + ", " + cached.body().length + " bytes)");
                return cached;
            }
        }

        final HandleTable.Handle h = handles.find(id, conn);
        if (h == null || !h.name.equals(name) || h.nargs != in.length) {
            return bad;
        }
        final byte[][] vals = new byte[in.length][];
        for (int i = 0; i < in.length; i++) {
            vals[i] = in[i].isNull() ? null : in[i].bytes();
        }
        final byte[][] res = new byte[1][];
        final int[] meta = new int[2];
        final int rc = Native.call(h.nativePtr, vals, res, meta);

        final IdempotencyCache.Reply out;
        switch (rc) {
            case Native.CALL_OK:
                out = tlv(meta[0], meta[1] != 0, res[0] != null ? res[0] : NONE);
                break;
            case Native.CALL_CORE_ERROR:
                Log.warn(h.name + ": adapter reported an error for this call");
                out = text(Protocol.ERR_CORE, "");
                break;
            case Native.CALL_CANCELLED_MID:
                Log.info(h.name + ": cancelled mid-call");
                return text(Protocol.ERR_BUSY, "cancelled");
            case Native.CALL_CANCELLED_BEFORE:
                return text(Protocol.ERR_BUSY, "cancelled");
            case Native.CALL_LIMIT:
                return text(Protocol.ERR_LIMIT, "");
            case Native.CALL_INTERNAL:
                return text(Protocol.ERR_INTERNAL, "");
            case Native.CALL_NOTSUP:
                return text(Protocol.ERR_NOTSUP, "");
            default:
                return bad;
        }
        if (token != 0) {
            cache.put(token, h.name, out);
        }
        return out;
    }

    private IdempotencyCache.Reply deinit(long conn, byte[] p)
    {
        if (p.length < 8) {
            return text(Protocol.ERR_ARGS, "");
        }
        final HandleTable.Handle h = handles.remove(Protocol.u64(p, 0), conn);
        if (h != null) {
            Native.close(h.nativePtr);
        }
        return text(Protocol.OK, "");
    }

    private IdempotencyCache.Reply cancel(byte[] p)
    {
        if (p.length < 8) {
            return text(Protocol.ERR_ARGS, "");
        }
        return handles.cancel(Protocol.u64(p, 0))
                ? text(Protocol.OK, "") : text(Protocol.ERR_ARGS, "unknown handle");
    }

    /** Frees every handle a connection still holds, as its deinit would. */
    void releaseOwner(long conn)
    {
        final List<HandleTable.Handle> list = handles.removeOwner(conn);
        for (HandleTable.Handle h : list) {
            Native.close(h.nativePtr);
        }
        if (!list.isEmpty()) {
            Log.info("released " + list.size() + " statement handle(s) from connection " + conn);
        }
    }

    /** Re-reads the config file and swaps it in, all or nothing. */
    private IdempotencyCache.Reply reload()
    {
        final DaemonConfig cur = config.get();
        final DaemonConfig next;
        try {
            next = DaemonConfig.load(configPath);
        } catch (DaemonConfig.ConfigException e) {
            Log.warn("reload: re-reading " + configPath + " failed; keeping the running configuration");
            return text(Protocol.ERR_ARGS, "reload failed: config file unreadable");
        }
        if (!next.socketPath.equals(cur.socketPath) || !next.keyPath.equals(cur.keyPath)) {
            Log.warn("reload: socket_path/hmac_key_file changed in " + configPath + "; that requires a restart");
            return text(Protocol.ERR_ARGS, "socket_path and hmac_key_file changes require a restart");
        }
        if (!next.validatePlatform(configPath)) {
            Log.warn("reload: the new configuration would be refused at startup; keeping the running configuration");
            return text(Protocol.ERR_ARGS, "reload failed: key/config file permissions rejected");
        }
        if (!next.checkProvider()) {
            Log.warn("reload: provider settings rejected; keeping the running configuration");
            return text(Protocol.ERR_ARGS, "reload failed: provider settings rejected (see the daemon log)");
        }
        if (!next.applyProvider()) {
            Log.warn("reload: applying provider settings failed; keeping the running configuration");
            return text(Protocol.ERR_ARGS, "reload failed: applying provider settings (see the daemon log)");
        }
        config.set(next);
        Log.info("reload: configuration reloaded (max_connections=" + next.maxConnections
                + ", idle_timeout_secs=" + next.idleTimeoutSecs + ", allowed=" + next.allowedUids.size() + ")");
        return text(Protocol.OK, "reloaded");
    }
}
