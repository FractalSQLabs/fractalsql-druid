/*
 * SPDX-License-Identifier: Apache-2.0
 * Copyright 2026 Daniel Gardiner d/b/a FractalSQLabs
 */
package com.fractalsqlabs.fractalsql.daemon;

import java.nio.ByteBuffer;
import java.nio.ByteOrder;
import java.security.MessageDigest;
import javax.crypto.Mac;
import javax.crypto.spec.SecretKeySpec;

/** The FSQ wire protocol, version 2: frame layout, opcodes, status codes. */
final class Protocol {

    static final byte[] MAGIC = {'F', 'S', 'Q', '1'};
    static final int VERSION = 2;
    static final int HEADER_LEN = 32;
    static final int TAG_LEN = 32;
    static final int MAX_PAYLOAD = 80 * 1024 * 1024;
    static final int MAX_ARGS = 64;
    static final int MSG_MAX = 512;

    static final int FLAG_RESPONSE = 0x1;
    static final int FLAG_ERROR = 0x2;

    static final int OP_PING = 0x0001;
    static final int OP_VERSION = 0x0002;
    static final int OP_UDF_INIT = 0x0010;
    static final int OP_UDF_CALL = 0x0011;
    static final int OP_UDF_DEINIT = 0x0012;
    static final int OP_CANCEL = 0x0013;
    static final int OP_RELOAD = 0x0014;

    static final int OK = 0;
    static final int ERR_ARGS = 1;
    static final int ERR_LIMIT = 2;
    static final int ERR_CORE = 3;
    static final int ERR_INTERNAL = 6;
    static final int ERR_NOTSUP = 7;
    static final int ERR_BUSY = 8;

    static final int T_STRING = 1;
    static final int T_INT = 2;
    static final int T_REAL = 3;
    static final int T_DECIMAL = 4;

    private Protocol() {}

    /** A decoded frame header. */
    record Header(int version, int opcode, int flags, int requestId, long context,
                  int authLen, long payloadLen) {}

    /** Reads a header, or returns null on a bad magic. */
    static Header decode(byte[] in)
    {
        for (int i = 0; i < 4; i++) {
            if (in[i] != MAGIC[i]) {
                return null;
            }
        }
        final ByteBuffer b = ByteBuffer.wrap(in).order(ByteOrder.LITTLE_ENDIAN);
        return new Header(b.getShort(4) & 0xffff, b.getShort(6) & 0xffff, b.getInt(8),
                b.getInt(12), b.getLong(16), b.getInt(24), b.getInt(28) & 0xffffffffL);
    }

    static byte[] encode(int opcode, int flags, int requestId, long context, int payloadLen)
    {
        final ByteBuffer b = ByteBuffer.allocate(HEADER_LEN).order(ByteOrder.LITTLE_ENDIAN);
        b.put(MAGIC);
        b.putShort((short) VERSION);
        b.putShort((short) opcode);
        b.putInt(flags);
        b.putInt(requestId);
        b.putLong(context);
        b.putInt(TAG_LEN);
        b.putInt(payloadLen);
        return b.array();
    }

    /** HMAC-SHA256 over the header followed by the payload. */
    static byte[] tag(byte[] key, byte[] header, byte[] payload)
    {
        try {
            final Mac mac = Mac.getInstance("HmacSHA256");
            mac.init(new SecretKeySpec(key, "HmacSHA256"));
            mac.update(header);
            if (payload != null && payload.length > 0) {
                mac.update(payload);
            }
            return mac.doFinal();
        } catch (java.security.GeneralSecurityException e) {
            throw new IllegalStateException(e);
        }
    }

    /** Constant-time tag comparison. */
    static boolean tagsEqual(byte[] a, byte[] b)
    {
        return MessageDigest.isEqual(a, b);
    }

    static long u32(byte[] p, int off)
    {
        return ByteBuffer.wrap(p).order(ByteOrder.LITTLE_ENDIAN).getInt(off) & 0xffffffffL;
    }

    static long u64(byte[] p, int off)
    {
        return ByteBuffer.wrap(p).order(ByteOrder.LITTLE_ENDIAN).getLong(off);
    }
}
