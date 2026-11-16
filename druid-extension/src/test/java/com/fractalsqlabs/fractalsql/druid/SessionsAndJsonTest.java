/*
 * SPDX-License-Identifier: Apache-2.0
 * Copyright 2026 Daniel Gardiner d/b/a FractalSQLabs
 */
package com.fractalsqlabs.fractalsql.druid;

import com.fasterxml.jackson.databind.JsonNode;
import org.junit.jupiter.api.Test;

import java.util.Map;

import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertFalse;
import static org.junit.jupiter.api.Assertions.assertNull;
import static org.junit.jupiter.api.Assertions.assertTrue;

/** The session overlay and the minimal JSON writer/reader. */
public class SessionsAndJsonTest {

    @Test
    void sessionOverlayLifecycle()
    {
        final FractalSqlSessions s = new FractalSqlSessions();
        assertNull(s.get(null, "k"));
        assertNull(s.get("", "k"));
        assertNull(s.get("nobody", "k"));
        assertEquals(Map.of(), s.overrides("nobody"));
        assertEquals(0, s.reset("nobody"));

        assertEquals("v", s.set("a", "k", "v"));
        s.set("a", "k2", "v2");
        assertEquals("v", s.get("a", "k"));
        assertNull(s.get("a", "absent"));
        assertEquals(2, s.overrides("a").size());
        assertEquals(1, s.size());
        assertEquals(2, s.reset("a"));
        assertEquals(0, s.size());
    }

    @Test
    void oldestSessionsAreEvicted()
    {
        final FractalSqlSessions s = new FractalSqlSessions();
        for (int i = 0; i < 1100; i++) {
            s.set("s" + i, "k", "v");
        }
        assertEquals(1024, s.size());
        assertNull(s.get("s0", "k"));
        assertEquals("v", s.get("s1099", "k"));
    }

    @Test
    void diversifyFeedbackAndIsolation()
    {
        final FractalSqlSessions s = new FractalSqlSessions();
        assertFalse(s.diversifyEnabled());
        s.setDiversifyEnabled(true);
        assertTrue(s.diversifyEnabled());
        s.setDiversifyEnabled(false);
        assertFalse(s.diversifyEnabled());

        assertTrue(s.feedback().isEmpty());
        s.reportFeedback(7, "click", 120.0);
        s.reportFeedback(7, "skip", 3.0);
        assertEquals(2, s.feedback().size());
        assertEquals("click", s.feedback().get(0).get("kind"));
        assertEquals("2", s.get("feedback", "feedback.7"));
        s.clearFeedback();
        assertTrue(s.feedback().isEmpty());

        assertTrue(s.isolated().isEmpty());
        s.isolate(5);
        s.isolate(9);
        assertEquals(java.util.Set.of("5", "9"), s.isolated());
    }

    @Test
    void writerEscapesAndFormats()
    {
        final String json = new FractalJson()
                .num("d", 1.5)
                .num("nan", Double.NaN)
                .num("inf", Double.POSITIVE_INFINITY)
                .num("n", 42L)
                .str("s", "a\"b\\c\nd\re\tf\u0001")
                .str("null", null)
                .arr("a", new double[]{1, Double.NaN, 3}, 3)
                .arrFrom("b", new double[]{1, 2, 3, 4}, 2, 1)
                .arr("short", new double[]{1}, 5)
                .arrFrom("past", new double[]{1}, 2, 9)
                .raw("r", "{\"x\":1}")
                .raw("rn", null)
                .build();
        final JsonNode n = FractalJson.read(json, "$");
        assertEquals(1.5, n.get("d").asDouble());
        assertTrue(n.get("nan").isNull());
        assertTrue(n.get("inf").isNull());
        assertEquals(42, n.get("n").asLong());
        assertEquals("a\"b\\c\nd\re\tf\u0001", n.get("s").asText());
        assertTrue(n.get("null").isNull());
        assertTrue(n.get("a").get(1).isNull());
        assertEquals(2.0, n.get("b").get(0).asDouble());
        assertEquals(1, n.get("short").size());
        assertEquals(0, n.get("past").size());
        assertEquals(1, n.get("r").get("x").asInt());
        assertTrue(n.get("rn").isNull());
    }

    @Test
    void readerPaths()
    {
        final String doc = "{\"a\":{\"b\":5},\"frames\":[{\"t\":1},{\"t\":2}],\"v\":[9,8]}";
        assertEquals(5, FractalJson.read(doc, "$.a.b").asInt());
        assertEquals(2, FractalJson.read(doc, "$.frames[1].t").asInt());
        assertNull(FractalJson.read(doc, "$.frames[7]"));
        assertNull(FractalJson.read(doc, "$.nope[0]"));
        assertNull(FractalJson.read(doc, "$.nope.deeper"));
        assertEquals(8, FractalJson.read("[9,8]", "$[1]").asInt());
        assertNull(FractalJson.read("[9,8]", "$[5]"));
        assertEquals(9, FractalJson.read(doc, "$.v[0]").asInt());
        assertEquals(doc.length() > 0, FractalJson.read(doc, "").isObject());
        assertNull(FractalJson.read(null, "$"));
        assertNull(FractalJson.read("", "$"));
        assertNull(FractalJson.read(doc, null));
        assertNull(FractalJson.read("{bad", "$.a"));
        assertNull(FractalJson.read(doc, "$.frames[x]"));
    }
}
