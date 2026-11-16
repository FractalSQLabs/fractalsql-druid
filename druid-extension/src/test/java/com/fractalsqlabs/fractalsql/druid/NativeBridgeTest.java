/*
 * SPDX-License-Identifier: Apache-2.0
 * Copyright 2026 Daniel Gardiner d/b/a FractalSQLabs
 */
package com.fractalsqlabs.fractalsql.druid;

import org.junit.jupiter.api.Test;

import java.nio.charset.StandardCharsets;

import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertNotNull;
import static org.junit.jupiter.api.Assertions.assertNull;
import static org.junit.jupiter.api.Assertions.assertTrue;

/**
 * Proves the JNI bridge actually reaches the FractalSQL core.
 *
 * <p>This is the first gate in the chain: if the native shim does not
 * load, or the core archive is not linked into it correctly, everything
 * above it (the Calcite aggregate, the whole extension) fails in ways
 * that are hard to read. So it is tested directly, first.
 */
public class NativeBridgeTest {

    @Test
    void nativeLibraryLoads()
    {
        NativeLoader.load();
        assertTrue(NativeLoader.isLoaded(), "the JNI shim should be loaded");
    }

    @Test
    void coreReportsItsIdentity()
    {
        NativeLoader.load();
        assertNotNull(Native.edition());
        assertNotNull(Native.storage());
        assertNotNull(Native.version());
        assertNotNull(Native.abiVersion());
        // The vendored drop is the sovereign-tier community core.
        assertEquals("Sovereign", Native.storage());
        assertTrue(Native.version().startsWith("2."), "unexpected core version: " + Native.version());
    }

    @Test
    void contextLifecycleWorks()
    {
        NativeLoader.load();
        final long ctx = Native.newSovereign();
        assertTrue(ctx != 0, "a sovereign context should be created");
        try {
            assertEquals("", Native.lastError(ctx));
        } finally {
            Native.free(ctx);
        }
    }

    /**
     * The core's search over a small corpus. A three-point corpus with a
     * query equal to one of the points must come back with that point at
     * distance 0.
     */
    @Test
    void corpusSearchFindsTheExactMatch()
    {
        NativeLoader.load();
        final long ctx = Native.newSovereign();
        assertTrue(ctx != 0);
        try {
            final double[] corpus = {
                    1.0, 0.0, 0.0,
                    0.0, 1.0, 0.0,
                    0.0, 0.0, 1.0
            };
            final double[] query = {1.0, 0.0, 0.0};
            final byte[] params = "{}".getBytes(StandardCharsets.UTF_8);

            final byte[] result = Native.searchPtr(ctx, corpus, 3, 3, query, 3, 3, params);
            assertNotNull(result, "the search should have returned a result: " + Native.lastError(ctx));

            final String json = new String(result, StandardCharsets.UTF_8);
            assertTrue(json.contains("\"best_point\""), "result should carry a best_point: " + json);
            assertTrue(json.contains("\"top_k\""), "result should carry a top_k: " + json);

            // The refined point must be extractable -- the SQL aggregate
            // depends on it.
            final double[] refined = VectorText.extractBestPoint(result, 3);
            assertNotNull(refined, "best_point should be extractable from: " + json);
            assertEquals(3, refined.length, "the refined point should keep the query's dimension");
        } finally {
            Native.free(ctx);
        }
    }

    @Test
    void cosineDistanceBehaves()
    {
        NativeLoader.load();
        // Identical vectors: distance 0.
        assertEquals(0.0, Native.cosineDistance(
                new double[]{1.0, 2.0, 3.0},
                new double[]{1.0, 2.0, 3.0}), 1e-12);
        // Orthogonal vectors: distance 1.
        assertEquals(1.0, Native.cosineDistance(
                new double[]{1.0, 0.0},
                new double[]{0.0, 1.0}), 1e-12);
        // A zero vector has no direction: the core reports maximal distance.
        assertEquals(1.0, Native.cosineDistance(
                new double[]{0.0, 0.0},
                new double[]{1.0, 1.0}), 1e-12);
    }

    @Test
    void vectorTextParsesBothForms()
    {
        final double[] csv = VectorText.parseVector("1.0,0.5,-0.25");
        assertNotNull(csv);
        assertEquals(3, csv.length);
        assertEquals(1.0, csv[0], 1e-12);
        assertEquals(-0.25, csv[2], 1e-12);

        final double[] json = VectorText.parseVector("[1.0, 0.5, -0.25]");
        assertNotNull(json);
        assertEquals(3, json.length);
        assertEquals(0.5, json[1], 1e-12);

        // Malformed input is rejected, not silently half-parsed.
        assertNull(VectorText.parseVector("1.0,,2.0"));
        assertNull(VectorText.parseVector("[1.0,2.0"));
        assertNull(VectorText.parseVector("not,a,vector"));
        assertNull(VectorText.parseVector(""));
        assertNull(VectorText.parseVector(null));
    }
}
