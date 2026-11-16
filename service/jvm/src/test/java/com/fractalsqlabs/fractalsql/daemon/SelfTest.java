/*
 * SPDX-License-Identifier: Apache-2.0
 * Copyright 2026 Daniel Gardiner d/b/a FractalSQLabs
 */
package com.fractalsqlabs.fractalsql.daemon;

import java.nio.charset.StandardCharsets;
import java.nio.file.Files;
import java.nio.file.Path;
import java.nio.file.attribute.PosixFilePermissions;

/** Checks for the parts of the server that need no native library. Exits non-zero on a failure. */
public final class SelfTest {

    private static int failures;

    private SelfTest() {}

    private static void check(String name, boolean ok)
    {
        System.out.println((ok ? "ok   " : "FAIL ") + name);
        if (!ok) {
            failures++;
        }
    }

    public static void main(String[] args) throws Exception
    {
        frames();
        cache();
        config();
        System.out.println(failures + " failure(s)");
        System.exit(failures == 0 ? 0 : 1);
    }

    private static void frames()
    {
        final byte[] hdr = Protocol.encode(Protocol.OP_UDF_CALL, 0, 7, 0xabcdefL, 5);
        check("a header is 32 bytes", hdr.length == Protocol.HEADER_LEN);
        final Protocol.Header h = Protocol.decode(hdr);
        check("a header round-trips", h != null && h.opcode() == Protocol.OP_UDF_CALL && h.requestId() == 7
                && h.context() == 0xabcdefL && h.payloadLen() == 5 && h.authLen() == Protocol.TAG_LEN
                && h.version() == Protocol.VERSION);
        final byte[] bad = hdr.clone();
        bad[0] = 'X';
        check("a bad magic is refused", Protocol.decode(bad) == null);

        final byte[] key = "0123456789abcdef".getBytes(StandardCharsets.US_ASCII);
        final byte[] payload = "payload".getBytes(StandardCharsets.US_ASCII);
        final byte[] tag = Protocol.tag(key, hdr, payload);
        check("a tag is 32 bytes", tag.length == Protocol.TAG_LEN);
        check("the same input gives the same tag", Protocol.tagsEqual(tag, Protocol.tag(key, hdr, payload)));
        check("a changed payload changes the tag",
                !Protocol.tagsEqual(tag, Protocol.tag(key, hdr, "payloaD".getBytes(StandardCharsets.US_ASCII))));
        check("a changed key changes the tag",
                !Protocol.tagsEqual(tag, Protocol.tag("0123456789abcdeX".getBytes(StandardCharsets.US_ASCII), hdr, payload)));
        // A known HMAC-SHA256 vector (RFC 4231, test case 2).
        final byte[] v = Protocol.tag("Jefe".getBytes(StandardCharsets.US_ASCII), new byte[0],
                "what do ya want for nothing?".getBytes(StandardCharsets.US_ASCII));
        final StringBuilder hex = new StringBuilder();
        for (byte b : v) {
            hex.append(String.format("%02x", b));
        }
        check("HMAC-SHA256 matches the RFC 4231 vector",
                hex.toString().equals("5bdcc146bf60754e6a042426089575c75a003f089d2739839dec58b964ec3843"));
        check("u32 reads little-endian", Protocol.u32(new byte[] {1, 2, 3, (byte) 0x80}, 0) == 0x80030201L);
    }

    private static void cache()
    {
        final IdempotencyCache c = new IdempotencyCache();
        final IdempotencyCache.Reply r = new IdempotencyCache.Reply(0, 0, new byte[] {1, 2, 3});
        c.put(42, "fractal_x", r);
        final IdempotencyCache.Reply hit = c.replay(42, "fractal_x");
        check("a stored reply is replayed", hit != null && hit.body().length == 3);
        check("a replay is a copy", hit != null && hit.body() != r.body());
        check("another function name is a miss", c.replay(42, "fractal_y") == null);
        check("another token is a miss", c.replay(43, "fractal_x") == null);
        c.put(0, "fractal_x", r);
        check("token 0 is never cached", c.replay(0, "fractal_x") == null);
        for (int i = 1; i <= IdempotencyCache.ENTRIES + 10; i++) {
            c.put(1000 + i, "fractal_x", r);
        }
        check("the oldest entry is evicted past 256", c.replay(1001, "fractal_x") == null);
        check("a recent entry survives", c.replay(1000 + IdempotencyCache.ENTRIES + 10, "fractal_x") != null);
        c.put(7, "fractal_x", new IdempotencyCache.Reply(0, 0, new byte[IdempotencyCache.ENTRY_MAX + 1]));
        check("an oversize reply is not cached", c.replay(7, "fractal_x") == null);
    }

    private static void config() throws Exception
    {
        check("truthy: off is false", !DaemonConfig.truthy("off") && !DaemonConfig.truthy("No")
                && !DaemonConfig.truthy("0") && !DaemonConfig.truthy("") && !DaemonConfig.truthy("FALSE"));
        check("truthy: on is true", DaemonConfig.truthy("on") && DaemonConfig.truthy("1") && DaemonConfig.truthy("true"));

        final Path dir = Files.createTempDirectory("fsqld-selftest");
        try {
            final Path key = dir.resolve("hmac.key");
            Files.writeString(key, "00 11 22 33\n44 55 66 77\n88 99 aa bb\ncc dd ee ff\n");
            Files.setPosixFilePermissions(key, PosixFilePermissions.fromString("rw-------"));
            final byte[] k = DaemonConfig.loadKey(key.toString());
            check("a hex key is read, whitespace ignored", k.length == 16 && k[0] == 0 && k[15] == (byte) 0xff);
            for (String shortKey : new String[]{"00", "00112233445566", "00112233445566778899aabbccddee"}) {
                Files.writeString(key, shortKey);
                boolean shortRefused = false;
                try {
                    DaemonConfig.loadKey(key.toString());
                } catch (DaemonConfig.ConfigException e) {
                    shortRefused = true;
                }
                check("a " + shortKey.length() / 2 + "-byte key is refused (16 bytes minimum)", shortRefused);
            }
            Files.writeString(key, "xyz");
            boolean refused = false;
            try {
                DaemonConfig.loadKey(key.toString());
            } catch (DaemonConfig.ConfigException e) {
                refused = true;
            }
            check("a key that is not hex is refused", refused);

            Files.writeString(key, "00112233445566778899aabbccddeeff");
            final Path conf = dir.resolve("fractalsqld.conf");
            Files.writeString(conf, String.join("\n",
                    "# a comment",
                    "socket_path = " + dir.resolve("s.sock"),
                    "hmac_key_file = " + key,
                    "allowed_uids = 1000, 1001",
                    "max_connections = 8",
                    "reasoning_url = http://example.invalid/v1/chat/completions",
                    "reasoning_allow_plaintext = off",
                    "t2s_max_attempts = 3",
                    "t2s_use_review = yes",
                    "unknown_key = ignored",
                    ""));
            final DaemonConfig c = DaemonConfig.load(conf);
            check("the listener keys are parsed", c.maxConnections == 8 && c.allowedUids.size() == 2
                    && c.allowedUids.get(1) == 1001 && c.key.length == 16);
            check("a present key sets its bit", (c.present & DaemonConfig.P_URL) != 0
                    && (c.present & DaemonConfig.P_T2S_ATTEMPTS) != 0 && (c.present & DaemonConfig.P_TOKEN) == 0);
            check("booleans read like the environment", !c.reasoningAllowPlaintext && c.t2sUseReview);
            check("integers are read", c.t2sMaxAttempts == 3);

            Files.writeString(conf, "socket_path = /tmp/x.sock\n");
            boolean missing = false;
            try {
                DaemonConfig.load(conf);
            } catch (DaemonConfig.ConfigException e) {
                missing = true;
            }
            check("a config without hmac_key_file is refused", missing);

            Files.writeString(conf, "socket_path = " + dir.resolve("s.sock") + "\nhmac_key_file = " + key
                    + "\nallowed_uids = 1000\nmax_connections = 5000\n");
            boolean tooMany = false;
            try {
                DaemonConfig.load(conf);
            } catch (DaemonConfig.ConfigException e) {
                tooMany = true;
            }
            check("max_connections over 1024 is refused", tooMany);

            Files.writeString(conf, "socket_path = " + dir.resolve("s.sock") + "\nhmac_key_file = " + key
                    + "\nallowed_uids = 1000\nreasoning_token = " + "x".repeat(2000) + "\n");
            boolean tooLong = false;
            try {
                DaemonConfig.load(conf);
            } catch (DaemonConfig.ConfigException e) {
                tooLong = true;
            }
            check("an over-long value is refused, not clipped", tooLong);

            Files.setPosixFilePermissions(key, PosixFilePermissions.fromString("rw-r--r--"));
            final DaemonConfig world = new DaemonConfig();
            world.keyPath = key.toString();
            check("a world-readable key file fails the platform check", !world.validatePlatform(null));
        } finally {
            try (var s = Files.walk(dir)) {
                s.sorted(java.util.Comparator.reverseOrder()).forEach(p -> p.toFile().delete());
            }
        }
    }
}
