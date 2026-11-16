/*
 * SPDX-License-Identifier: Apache-2.0
 * Copyright 2026 Daniel Gardiner d/b/a FractalSQLabs
 */
package com.fractalsqlabs.fractalsql.druid;

import org.junit.jupiter.api.Test;

import java.io.IOException;
import java.lang.reflect.InvocationTargetException;
import java.lang.reflect.Method;
import java.nio.charset.StandardCharsets;
import java.nio.file.Files;
import java.nio.file.Path;
import java.util.HashMap;
import java.util.Map;
import java.util.Properties;

import static org.junit.jupiter.api.Assertions.assertArrayEquals;
import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertFalse;
import static org.junit.jupiter.api.Assertions.assertNotNull;
import static org.junit.jupiter.api.Assertions.assertNull;
import static org.junit.jupiter.api.Assertions.assertThrows;
import static org.junit.jupiter.api.Assertions.assertTrue;

/** The vector text format, the configuration surface and the daemon client's encoders. */
public class TextAndConfigTest {

    @Test
    void parseVectorForms()
    {
        assertArrayEquals(new double[]{1, 2, 3}, VectorText.parseVector("1,2,3"), 1e-12);
        assertArrayEquals(new double[]{1, 2, 3}, VectorText.parseVector(" [ 1 , 2 , 3 ] "), 1e-12);
        assertArrayEquals(new double[]{1.5, -2}, VectorText.parseVector("[\"1.5\", \"-2\"]"), 1e-12);
        assertArrayEquals(new double[]{7}, VectorText.parseVector("7"), 1e-12);
        assertNull(VectorText.parseVector(null));
        assertNull(VectorText.parseVector(""));
        assertNull(VectorText.parseVector("   "));
        assertNull(VectorText.parseVector("[1,2"));
        assertNull(VectorText.parseVector("[]"));
        assertNull(VectorText.parseVector("[  ]"));
        assertNull(VectorText.parseVector("1,,2"));
        assertNull(VectorText.parseVector("1,2,"));
        assertNull(VectorText.parseVector(",1"));
        assertNull(VectorText.parseVector("1,x"));
        assertNull(VectorText.parseVector("1,NaN"));
        assertNull(VectorText.parseVector("1,Infinity"));
        assertNull(VectorText.parseVector("\"\",1"));
    }

    @Test
    void extractBestPointForms()
    {
        final byte[] ok = "{\"dim\":3,\"best_point\":[1.0, 2.0,3.5],\"x\":1}".getBytes(StandardCharsets.UTF_8);
        assertArrayEquals(new double[]{1, 2, 3.5}, VectorText.extractBestPoint(ok, 3), 1e-12);
        assertNull(VectorText.extractBestPoint(ok, 2));
        assertNull(VectorText.extractBestPoint(null, 3));
        assertNull(VectorText.extractBestPoint(new byte[0], 3));
        assertNull(VectorText.extractBestPoint("{\"a\":1}".getBytes(StandardCharsets.UTF_8), 3));
        assertNull(VectorText.extractBestPoint("{\"best_point\":".getBytes(StandardCharsets.UTF_8), 3));
        assertNull(VectorText.extractBestPoint("{\"best_point\":[1,2".getBytes(StandardCharsets.UTF_8), 3));
        assertNull(VectorText.extractBestPoint("{\"best_point\":[]}".getBytes(StandardCharsets.UTF_8), 3));
        assertNull(VectorText.extractBestPoint("{\"best_point\":[1,,2]}".getBytes(StandardCharsets.UTF_8), 3));
        assertNull(VectorText.extractBestPoint("{\"best_point\":[1,abc]}".getBytes(StandardCharsets.UTF_8), 3));
    }

    @Test
    void configSurface()
    {
        assertTrue(FractalSqlConfig.isSecret("reasoning.token"));
        assertTrue(FractalSqlConfig.isSecret("a.key"));
        assertTrue(FractalSqlConfig.isSecret("enterprise_ledger_key"));
        assertTrue(FractalSqlConfig.isSecret("a_token"));
        assertFalse(FractalSqlConfig.isSecret("search.walk"));
        assertFalse(FractalSqlConfig.isSecret(null));
        assertFalse(FractalSqlConfig.operatorOnlyKeys().isEmpty());
        assertNotNull(FractalSqlConfig.requestOverridableKeys());
        assertFalse(FractalSqlConfig.keys().isEmpty());

        final Properties p = new Properties();
        p.setProperty("druid.fractalsql.coordinator_url", "http://coord:8081");
        p.setProperty("druid.fractalsql.search.walk", "0.25");
        final FractalSqlConfig c = new FractalSqlConfig(() -> p);

        final Map<String, String> d = c.describe();
        assertEquals("0.25", d.get("search.walk"));
        assertEquals("http://coord:8081", d.get("coordinator_url"));
        assertFalse(d.containsKey("search.params"), "an empty value is left out");
        assertEquals(30, c.operatorInt("search.max_generation"));
        assertEquals(300000L, c.operatorLong("daemon_timeout_ms"));
        assertEquals(0.25, c.operatorDouble("search.walk"), 1e-12);
        assertTrue(c.operatorBool("search.bound_clipping"));
        assertThrows(IllegalArgumentException.class, () -> c.operatorValue("no.such.key"));
        assertThrows(IllegalArgumentException.class, () -> c.effectiveValue("no.such.key", null));

        // a request may not move an operator key; it may move a tuning key
        final Map<String, String> ctx = new HashMap<>();
        for (String name : FractalSqlConfig.keys().keySet()) {
            ctx.put("fractalsql." + name, "7");
        }
        for (String name : FractalSqlConfig.keys().keySet()) {
            final String eff = c.effectiveValue(name, ctx);
            if (FractalSqlConfig.keys().get(name).isRequestOverridable()) {
                assertEquals("7", eff);
            } else {
                assertEquals(c.operatorValue(name), eff);
            }
        }
        assertEquals(c.operatorValue("search.walk"), c.effectiveValue("search.walk", null));
        assertEquals(c.operatorValue("search.walk"), c.effectiveValue("search.walk", Map.of()));
        final Map<String, String> dotted = Map.of("druid.fractalsql.search.walk", "9");
        assertNotNull(c.effectiveValue("search.walk", dotted));
        assertFalse(c.refusedOverrides().isEmpty());

        // the search parameter document: assembled from the knobs, or taken whole
        assertTrue(c.searchParamsJson().contains("\"walk\":0.25"));
        final Properties whole = new Properties();
        whole.setProperty("druid.fractalsql.search.params", "  {\"x\":1}  ");
        assertEquals("{\"x\":1}", new FractalSqlConfig(() -> whole).searchParamsJson());
        final Properties blank = new Properties();
        blank.setProperty("druid.fractalsql.search.params", "   ");
        assertTrue(new FractalSqlConfig(() -> blank).searchParamsJson().startsWith("{\"max_generation\""));
    }

    // -- the daemon client's encoders -----------------------------------------------------

    private static Object call(String name, Class<?> type, Object arg) throws Exception
    {
        final Method m = FsqClient.class.getDeclaredMethod(name, type);
        m.setAccessible(true);
        try {
            return m.invoke(null, arg);
        } catch (InvocationTargetException e) {
            throw (Exception) e.getCause();
        }
    }

    @Test
    void hexKeyFiles() throws Exception
    {
        final Path dir = Files.createTempDirectory("fsq-key");
        final Path good = dir.resolve("good");
        Files.writeString(good, "0a0B\n ff00 \n");
        assertArrayEquals(new byte[]{0x0a, 0x0b, (byte) 0xff, 0}, (byte[]) call("hexKey", String.class, good.toString()));

        final String[] bad = {"", "abc", "zz", "0g"};
        for (int i = 0; i < bad.length; i++) {
            final Path p = dir.resolve("bad" + i);
            Files.writeString(p, bad[i]);
            assertThrows(IOException.class, () -> call("hexKey", String.class, p.toString()));
        }
        assertThrows(IOException.class, () -> call("hexKey", String.class, dir.resolve("missing").toString()));
    }

    @Test
    void tlvEncodings() throws Exception
    {
        assertEquals(6, ((byte[]) call("tlv", Object.class, null)).length);
        assertEquals(14, ((byte[]) call("tlv", Object.class, 5L)).length);
        assertEquals(14, ((byte[]) call("tlv", Object.class, 5)).length);
        assertEquals(14, ((byte[]) call("tlv", Object.class, 1.5)).length);
        assertEquals(14, ((byte[]) call("tlv", Object.class, 1.5f)).length);
        assertEquals(9, ((byte[]) call("tlv", Object.class, "abc")).length);
        assertEquals(6, ((byte[]) call("tlv", Object.class, "")).length);
    }
}
