/*
 * SPDX-License-Identifier: Apache-2.0
 * Copyright 2026 Daniel Gardiner d/b/a FractalSQLabs
 */
package com.fractalsqlabs.fractalsql.druid;

import org.junit.jupiter.api.Test;

import static org.junit.jupiter.api.Assertions.assertNull;
import static org.junit.jupiter.api.Assertions.assertTrue;

/**
 * The JNI shim must not trust the lengths the Java side hands it: the core relies on a byte or element count
 * that the shim derives from one argument, while the buffer it is read from comes from another. Each case here
 * gives the shim lengths that disagree (SECURITY_AUDIT.md 3.2, 3.3, 3.6 and 3.13) and requires it to refuse
 * (NaN, or null) instead of reading past the buffer. These call Native directly, so they test the shim itself,
 * not the Java validation in front of it.
 */
public class NativeBoundsTest {

    private static double[] ramp(int n)
    {
        final double[] d = new double[n];
        for (int i = 0; i < n; i++) {
            d[i] = (i % 7) * 0.25 + i * 0.01;
        }
        return d;
    }

    @Test
    void cycleDetectRefusesAFingerprintShorterThanTheWidth()
    {
        NativeLoader.load();
        // 64 bits is 8 bytes; the fingerprint is 1 byte.
        assertNull(Native.cycleDetect(new byte[][]{{0}}, 64, 3));
        // The first is right, the second is short.
        assertNull(Native.cycleDetect(new byte[][]{new byte[8], new byte[3]}, 64, 3));
        // Longer than the width is a mismatch too.
        assertNull(Native.cycleDetect(new byte[][]{new byte[8], new byte[9]}, 64, 3));
    }

    @Test
    void cycleDetectStillWorksWithMatchingFingerprints()
    {
        NativeLoader.load();
        final byte[] a = {1, 2, 3, 4, 5, 6, 7, 8};
        final byte[] b = {8, 7, 6, 5, 4, 3, 2, 1};
        final String verdict = Native.cycleDetect(new byte[][]{a, b, a, b, a, b}, 64, 0);
        assertTrue(verdict != null && verdict.contains("cycle_detected"), String.valueOf(verdict));
    }

    @Test
    void vascularNetworkRefusesAnEdgeCountThatDisagreesWithTheEdges()
    {
        NativeLoader.load();
        final double[] nodes = ramp(9);          // three nodes
        final double[] edges = {0, 1};           // one edge
        final double[] arcs = ramp(1000);        // a thousand arc lengths
        final double[] out = new double[4];
        assertTrue(Double.isNaN(Native.callFn(11, nodes, nodes.length, edges, edges.length, arcs, arcs.length, 0, 0, 0, out)),
                "arc lengths for 1000 edges, edges for 1");
        // an odd number of edge indices
        assertTrue(Double.isNaN(Native.callFn(11, nodes, nodes.length, new double[]{0, 1, 2}, 3, ramp(1), 1, 0, 0, 0, out)));
    }

    @Test
    void portfolioRefusesAnExpectedReturnVectorShorterThanTheAssetCount()
    {
        NativeLoader.load();
        final double[] mu = {1.0};               // one asset
        final double[] cov = ramp(36);           // six assets
        final double[] out = new double[16];
        assertTrue(Double.isNaN(Native.callFn(8, mu, mu.length, cov, cov.length, null, 0, 2, 0, 0, out)));
        assertTrue(Double.isNaN(Native.callFn(14, mu, mu.length, cov, cov.length, null, 0, 2, 0, 0, out)));
    }

    @Test
    void stateFingerprintRefusesAWidthBeyondTheCoresLimitBeforeAllocating()
    {
        NativeLoader.load();
        final double[] v = {1.0, 2.0, 3.0};
        final double[] out = new double[8];
        final long t0 = System.nanoTime();
        // 2^30 bits would be a 128 MiB buffer.
        assertTrue(Double.isNaN(Native.callFn(10, v, v.length, null, 0, null, 0, 1073741824.0, 0, 0, out)));
        assertTrue(Double.isNaN(Native.callFn(10, v, v.length, null, 0, null, 0, 2147483647.0, 0, 0, out)));
        assertTrue(Double.isNaN(Native.callFn(10, v, v.length, null, 0, null, 0, -8.0, 0, 0, out)));
        assertTrue((System.nanoTime() - t0) < 2_000_000_000L, "a refused width must not cost an allocation");
    }
}
