/*
 * SPDX-License-Identifier: Apache-2.0
 * Copyright 2026 Daniel Gardiner d/b/a FractalSQLabs
 */
package com.fractalsqlabs.fractalsql.daemon;

import java.io.IOException;
import java.nio.charset.StandardCharsets;
import java.nio.file.Files;
import java.nio.file.Path;
import java.nio.file.attribute.PosixFilePermission;
import java.util.ArrayList;
import java.util.List;
import java.util.Set;

/**
 * One parsed fractalsqld.conf: the listener and limits, plus the provider
 * settings (reasoning, embedding, THINK, text-to-SQL, enterprise).
 *
 * <p>A snapshot is immutable once published. A reload parses a new one and
 * swaps it in; an established connection keeps the snapshot it started with.
 */
final class DaemonConfig {

    static final int DEFAULT_MAX_CONNECTIONS = 64;
    static final int MAX_CONNECTIONS_LIMIT = 1024;
    static final int DEFAULT_IDLE_TIMEOUT_SECS = 300;
    static final int MAX_ALLOWED_UIDS = 16;

    /** Presence bits, one per provider key. */
    static final int P_PLUGIN = 1 << 0;
    static final int P_URL = 1 << 1;
    static final int P_TOKEN = 1 << 2;
    static final int P_MODEL = 1 << 3;
    static final int P_PLAINTEXT = 1 << 4;
    static final int P_EMBED_URL = 1 << 5;
    static final int P_EMBED_MODEL = 1 << 6;
    static final int P_THINK = 1 << 7;
    static final int P_THINK_PROVIDER = 1 << 8;
    static final int P_NATIVE_URL = 1 << 9;
    static final int P_NUM_CTX = 1 << 10;
    static final int P_T2S_ATTEMPTS = 1 << 11;
    static final int P_T2S_ALLOWED = 1 << 12;
    static final int P_T2S_REVIEW = 1 << 13;
    static final int P_ENT_LIB = 1 << 14;
    static final int P_ENT_LEDGER_PATH = 1 << 15;
    static final int P_ENT_LEDGER_KEY = 1 << 16;
    static final int P_ENT_REQUIRE_SIG = 1 << 17;

    String socketPath = "";
    String keyPath = "";
    String logPath = "";
    final List<Integer> allowedUids = new ArrayList<>();
    byte[] key = new byte[0];
    int maxConnections = DEFAULT_MAX_CONNECTIONS;
    int idleTimeoutSecs = DEFAULT_IDLE_TIMEOUT_SECS;

    int present;
    String reasoningPlugin = "";
    String reasoningUrl = "";
    String reasoningToken = "";
    String reasoningModel = "";
    boolean reasoningAllowPlaintext;
    String embedUrl = "";
    String embedModel = "";
    String think = "";
    String thinkProvider = "";
    String thinkNativeUrl = "";
    long thinkNumCtx;
    long t2sMaxAttempts;
    String t2sAllowedStatements = "";
    boolean t2sUseReview;
    String enterpriseLib = "";
    String enterpriseLedgerPath = "";
    String enterpriseLedgerKey = "";
    boolean enterpriseRequireSignature;

    /** Thrown for a config that cannot be used. */
    static final class ConfigException extends Exception {
        private static final long serialVersionUID = 1L;

        ConfigException(String message)
        {
            super(message);
        }
    }

    /** The widest value each string key may hold. A longer value fails the parse. */
    private static String limited(String key, String value, int cap) throws ConfigException
    {
        if (value.getBytes(StandardCharsets.UTF_8).length >= cap) {
            throw new ConfigException("config: the value of " + key + " is too long");
        }
        return value;
    }

    /** A boolean reads like the matching environment variable: empty and 0 are false, and so are false, off and no. */
    static boolean truthy(String v)
    {
        if (v.isEmpty() || v.equals("0")) {
            return false;
        }
        final String lower = v.toLowerCase(java.util.Locale.ROOT);
        return !(lower.equals("false") || lower.equals("off") || lower.equals("no"));
    }

    private static long lenient(String v)
    {
        try {
            return Long.parseLong(v);
        } catch (NumberFormatException e) {
            return -1;
        }
    }

    static DaemonConfig load(Path path) throws ConfigException
    {
        final List<String> lines;
        try {
            lines = Files.readAllLines(path, StandardCharsets.UTF_8);
        } catch (IOException e) {
            throw new ConfigException("cannot read config " + path);
        }
        final DaemonConfig c = new DaemonConfig();
        for (String line : lines) {
            final int eq = line.indexOf('=');
            if (eq < 0 || line.startsWith("#")) {
                continue;
            }
            final String k = line.substring(0, eq).strip();
            final String v = line.substring(eq + 1).strip();
            c.set(k, v);
        }
        if (c.socketPath.isEmpty() || c.keyPath.isEmpty()) {
            throw new ConfigException("config: socket_path and hmac_key_file are required");
        }
        if (c.socketPath.getBytes(StandardCharsets.UTF_8).length >= 108) {
            throw new ConfigException("config: socket_path is too long for a Unix socket");
        }
        if (c.allowedUids.isEmpty()) {
            c.allowedUids.add(Native.euid());
        }
        if (c.maxConnections <= 0 || c.maxConnections > MAX_CONNECTIONS_LIMIT) {
            throw new ConfigException("config: max_connections must be in [1," + MAX_CONNECTIONS_LIMIT + "]");
        }
        if (c.idleTimeoutSecs <= 0) {
            throw new ConfigException("config: idle_timeout_secs must be positive");
        }
        c.key = loadKey(c.keyPath);
        return c;
    }

    private void set(String k, String v) throws ConfigException
    {
        switch (k) {
            case "socket_path" -> socketPath = limited(k, v, 256);
            case "hmac_key_file" -> keyPath = limited(k, v, 512);
            case "log_file" -> logPath = limited(k, v, 512);
            case "max_connections" -> maxConnections = (int) Math.max(Integer.MIN_VALUE, Math.min(Integer.MAX_VALUE, lenient(v)));
            case "idle_timeout_secs" -> idleTimeoutSecs = (int) Math.max(Integer.MIN_VALUE, Math.min(Integer.MAX_VALUE, lenient(v)));
            case "allowed_uids" -> {
                for (String tok : v.split(",")) {
                    final String t = tok.strip();
                    if (t.isEmpty()) {
                        continue;
                    }
                    if (allowedUids.size() >= MAX_ALLOWED_UIDS) {
                        throw new ConfigException("config: too many allowed_uids");
                    }
                    allowedUids.add((int) Long.parseLong(t));
                }
            }
            case "reasoning_plugin" -> { reasoningPlugin = limited(k, v, 512); present |= P_PLUGIN; }
            case "reasoning_url" -> { reasoningUrl = limited(k, v, 512); present |= P_URL; }
            case "reasoning_token" -> { reasoningToken = limited(k, v, 1024); present |= P_TOKEN; }
            case "reasoning_model" -> { reasoningModel = limited(k, v, 128); present |= P_MODEL; }
            case "reasoning_allow_plaintext" -> { reasoningAllowPlaintext = truthy(v); present |= P_PLAINTEXT; }
            case "embed_url" -> { embedUrl = limited(k, v, 512); present |= P_EMBED_URL; }
            case "embed_model" -> { embedModel = limited(k, v, 128); present |= P_EMBED_MODEL; }
            case "think" -> { think = limited(k, v, 64); present |= P_THINK; }
            case "think_provider" -> { thinkProvider = limited(k, v, 64); present |= P_THINK_PROVIDER; }
            case "think_native_url" -> { thinkNativeUrl = limited(k, v, 512); present |= P_NATIVE_URL; }
            case "think_num_ctx" -> { thinkNumCtx = lenient(v); present |= P_NUM_CTX; }
            case "t2s_max_attempts" -> { t2sMaxAttempts = lenient(v); present |= P_T2S_ATTEMPTS; }
            case "t2s_allowed_statements" -> { t2sAllowedStatements = limited(k, v, 32); present |= P_T2S_ALLOWED; }
            case "t2s_use_review" -> { t2sUseReview = truthy(v); present |= P_T2S_REVIEW; }
            case "enterprise_lib" -> { enterpriseLib = limited(k, v, 512); present |= P_ENT_LIB; }
            case "enterprise_ledger_path" -> { enterpriseLedgerPath = limited(k, v, 1024); present |= P_ENT_LEDGER_PATH; }
            case "enterprise_ledger_key" -> { enterpriseLedgerKey = limited(k, v, 1024); present |= P_ENT_LEDGER_KEY; }
            case "enterprise_require_signature" -> { enterpriseRequireSignature = truthy(v); present |= P_ENT_REQUIRE_SIG; }
            default -> Log.warn("config: unknown key '" + k + "' ignored");
        }
    }

    /** The shortest HMAC key accepted, in bytes. */
    static final int MIN_KEY_BYTES = 16;

    /** The shared HMAC key: hex text, whitespace ignored, 16 to 64 bytes. */
    static byte[] loadKey(String path) throws ConfigException
    {
        final String text;
        try {
            text = Files.readString(Path.of(path), StandardCharsets.US_ASCII);
        } catch (IOException e) {
            throw new ConfigException("cannot read the hmac key file " + path);
        }
        final StringBuilder hex = new StringBuilder();
        for (int i = 0; i < text.length() && hex.length() < 256; i++) {
            final char ch = text.charAt(i);
            if (ch != '\n' && ch != '\r' && ch != ' ' && ch != '\t') {
                hex.append(ch);
            }
        }
        final int n = hex.length();
        if (n == 0 || n % 2 != 0 || n / 2 > 64) {
            throw new ConfigException("the hmac key file " + path + " is not valid hex");
        }
        if (n / 2 < MIN_KEY_BYTES) {
            // 128 bits at least: a one-byte key would be guessed in 256 tries (SECURITY_AUDIT.md 3.22).
            throw new ConfigException("the hmac key file " + path + " holds " + n / 2
                    + " bytes; at least " + MIN_KEY_BYTES + " are required");
        }
        final byte[] out = new byte[n / 2];
        for (int i = 0; i < out.length; i++) {
            final int hi = Character.digit(hex.charAt(2 * i), 16);
            final int lo = Character.digit(hex.charAt(2 * i + 1), 16);
            if (hi < 0 || lo < 0) {
                throw new ConfigException("the hmac key file " + path + " is not valid hex");
            }
            out[i] = (byte) ((hi << 4) | lo);
        }
        return out;
    }

    /** The checks a config must pass to be used: neither file may be readable by other users. */
    boolean validatePlatform(Path configPath)
    {
        if (configPath != null && worldAccessible(configPath)) {
            Log.error("config file " + configPath + " grants access to other users: remove world permissions");
            return false;
        }
        if (worldAccessible(Path.of(keyPath))) {
            Log.error("hmac_key_file " + keyPath + " grants access to other users: remove world permissions");
            return false;
        }
        return true;
    }

    private static boolean worldAccessible(Path p)
    {
        try {
            final Set<PosixFilePermission> perms = Files.getPosixFilePermissions(p);
            return perms.contains(PosixFilePermission.OTHERS_READ)
                    || perms.contains(PosixFilePermission.OTHERS_WRITE)
                    || perms.contains(PosixFilePermission.OTHERS_EXECUTE);
        } catch (IOException | UnsupportedOperationException e) {
            return false;
        }
    }

    /** Loud, specific validation of the provider keys that are present. */
    boolean validateProvider()
    {
        final Object[][] strs = {
            {P_PLUGIN, reasoningPlugin, "reasoning_plugin"},
            {P_URL, reasoningUrl, "reasoning_url"},
            {P_TOKEN, reasoningToken, "reasoning_token"},
            {P_MODEL, reasoningModel, "reasoning_model"},
            {P_EMBED_URL, embedUrl, "embed_url"},
            {P_EMBED_MODEL, embedModel, "embed_model"},
            {P_THINK, think, "think"},
            {P_THINK_PROVIDER, thinkProvider, "think_provider"},
            {P_NATIVE_URL, thinkNativeUrl, "think_native_url"},
            {P_T2S_ALLOWED, t2sAllowedStatements, "t2s_allowed_statements"},
            {P_ENT_LIB, enterpriseLib, "enterprise_lib"},
            {P_ENT_LEDGER_PATH, enterpriseLedgerPath, "enterprise_ledger_path"},
            {P_ENT_LEDGER_KEY, enterpriseLedgerKey, "enterprise_ledger_key"},
        };
        for (Object[] s : strs) {
            if ((present & (Integer) s[0]) != 0 && ((String) s[1]).isEmpty()) {
                Log.error("provider key " + s[2] + ": value must not be empty");
                return false;
            }
        }
        final Object[][] paths = {
            {P_PLUGIN, reasoningPlugin, "reasoning_plugin"},
            {P_ENT_LIB, enterpriseLib, "enterprise_lib"},
            {P_ENT_LEDGER_PATH, enterpriseLedgerPath, "enterprise_ledger_path"},
        };
        for (Object[] p : paths) {
            if ((present & (Integer) p[0]) == 0) {
                continue;
            }
            final String err = Native.validatePath((String) p[1]);
            if (err != null) {
                Log.error("provider key " + p[2] + ": " + err + " (got '" + p[1] + "')");
                return false;
            }
        }
        if ((present & P_NUM_CTX) != 0 && (thinkNumCtx < 1 || thinkNumCtx > 10_000_000L)) {
            Log.error("provider key think_num_ctx: must be an integer in [1,10000000] (got " + thinkNumCtx + ")");
            return false;
        }
        if ((present & P_T2S_ATTEMPTS) != 0 && (t2sMaxAttempts < 1 || t2sMaxAttempts > 10)) {
            Log.error("provider key t2s_max_attempts: must be an integer in [1,10] (got " + t2sMaxAttempts + ")");
            return false;
        }
        if ((present & P_T2S_ALLOWED) != 0 && !t2sAllowedStatements.equals("select")
                && !t2sAllowedStatements.equals("select_insert_update")) {
            Log.error("provider key t2s_allowed_statements: must be \"select\" or \"select_insert_update\"");
            return false;
        }
        return true;
    }

    private String[] strs()
    {
        return new String[] {reasoningPlugin, reasoningUrl, reasoningToken, reasoningModel, embedUrl,
            embedModel, think, thinkProvider, thinkNativeUrl, t2sAllowedStatements, enterpriseLib,
            enterpriseLedgerPath, enterpriseLedgerKey};
    }

    private long[] longs()
    {
        return new long[] {thinkNumCtx, t2sMaxAttempts};
    }

    private boolean[] bools()
    {
        return new boolean[] {reasoningAllowPlaintext, t2sUseReview, enterpriseRequireSignature};
    }

    /** Validation plus the consumers' cross-state checks. Changes nothing. */
    boolean checkProvider()
    {
        return validateProvider() && Native.providerCheck(present, strs(), longs(), bools()) == 0;
    }

    /** Pushes the provider settings into the function bodies. */
    boolean applyProvider()
    {
        if (Native.providerApply(present, strs(), longs(), bools()) != 0) {
            return false;
        }
        final String[] names = {"reasoning_plugin", "reasoning_url", "reasoning_token", "reasoning_model",
            "reasoning_allow_plaintext", "embed_url", "embed_model", "think", "think_provider",
            "think_native_url", "think_num_ctx", "t2s_max_attempts", "t2s_allowed_statements",
            "t2s_use_review", "enterprise_lib", "enterprise_ledger_path", "enterprise_ledger_key",
            "enterprise_require_signature"};
        final int[] bits = {P_PLUGIN, P_URL, P_TOKEN, P_MODEL, P_PLAINTEXT, P_EMBED_URL, P_EMBED_MODEL,
            P_THINK, P_THINK_PROVIDER, P_NATIVE_URL, P_NUM_CTX, P_T2S_ATTEMPTS, P_T2S_ALLOWED,
            P_T2S_REVIEW, P_ENT_LIB, P_ENT_LEDGER_PATH, P_ENT_LEDGER_KEY, P_ENT_REQUIRE_SIG};
        final StringBuilder sb = new StringBuilder();
        for (int i = 0; i < names.length; i++) {
            if ((present & bits[i]) != 0) {
                sb.append(sb.length() > 0 ? ", " : "").append(names[i]);
            }
        }
        Log.info("provider settings applied (keys present: [" + sb
                + "], absent keys fall back to boot environment)");
        return true;
    }
}
