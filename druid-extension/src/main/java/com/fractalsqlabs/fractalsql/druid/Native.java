/*
 * SPDX-License-Identifier: Apache-2.0
 * Copyright 2026 Daniel Gardiner d/b/a FractalSQLabs
 */
package com.fractalsqlabs.fractalsql.druid;

/**
 * The native bridge to the pure-C FractalSQL core.
 *
 * <p>Every method here forwards to {@code fractalsql_jni.c}, which in
 * turn calls the vendored core archive in {@code include/<os>-<arch>/}.
 * The core is a core library: this class never reimplements any of its
 * behaviour, it only marshals arguments across the JNI boundary.
 *
 * <p>The core's own contract applies throughout:
 * <ul>
 *   <li>result JSON is owned by the core and stays valid until the next
 *       call on the same context -- {@link #release(long)} frees it early;</li>
 *   <li>a context is not thread-safe; use one per thread, or serialise
 *       access;</li>
 *   <li>errors are reported through {@link #lastError(long)}, not thrown.</li>
 * </ul>
 */
public final class Native {

    static {
        // The shim has to be loaded before ANY native method on this
        // class is called -- not just before the ones the broker uses.
        //
        // The refinement runs at PLAN time, in the broker. The
        // aggregation runs at EXECUTION time, on the historical. A
        // historical that has never loaded the shim fails with
        // "UnsatisfiedLinkError: Native.cosineDistance" on the first
        // native call, which is a long way from the cause.
        //
        // A static initialiser ties the load to the class, so every
        // node that touches the native surface loads the shim first.
        NativeLoader.load();
    }

    private Native() {
    }

    // -- lifecycle ----------------------------------------------------

    /** A sovereign-tier context (the full surface), or 0 on failure. */
    public static native long newSovereign();

    /** A minimal-tier context, or 0 on failure. */
    public static native long newMinimal();

    /** Destroy a context. Safe on 0. */
    public static native void free(long handle);

    /** Free the result buffer early; the context stays usable. */
    public static native void release(long handle);

    /** Last error text, or "" if none. */
    public static native String lastError(long handle);

    // -- informational ------------------------------------------------

    public static native String edition();

    public static native String storage();

    public static native String version();

    public static native String abiVersion();

    // -- search -------------------------------------------------------

    /**
     * Whole-corpus search over a flat row-major {@code double[]}.
     *
     * @param corpus   {@code n_rows * dim} doubles, row-major
     * @param query    {@code query_dim} doubles
     * @param k        number of top matches to return
     * @param params   the SFS parameter JSON, or null for defaults
     * @return the core's result JSON, or null on failure
     */
    public static native byte[] searchPtr(
            long handle,
            double[] corpus, int nRows, int dim,
            double[] query, int queryDim,
            int k, byte[] params);

    /**
     * Whole-corpus search with the corpus and query in the core's text
     * form (CSV or bracketed JSON).
     *
     * @return the core's result JSON, or null on failure
     */
    public static native byte[] searchText(
            long handle, byte[] corpus, byte[] query, int k, byte[] params);

    // -- the Diversify monitor -----------------------------------------
    //
    // The core's opt-in v2.0 search behaviour: the divergence monitor
    // and the repulsive post-filter, enabled per context, tuned by a
    // parameter document, and read back as the most recent D_q and the
    // rolling p99 of the monitor's own overhead.

    /** Enable the divergence monitor on a context. */
    public static native int diversifyEnable(long handle);

    /** Disable it. */
    public static native int diversifyDisable(long handle);

    /** Tune it: the D_q window, the stall threshold, the repulsion's sigma and weight, and the shadow and tail caps. */
    public static native int diversifySetParams(
            long handle,
            int windowN, double stallThreshold, double repulsionSigma,
            double repulsionWeight, int maxShadows, int tailBufferCap);

    /** The most recently computed D_q, or NaN. */
    public static native double diversifyCurrentDq(long handle);

    /** The rolling p99 of the monitor's overhead, in microseconds, or NaN. */
    public static native double diversifyOverheadP99(long handle);

    // -- vector math --------------------------------------------------

    /** Cosine distance between two equal-length vectors; 1.0 if either has zero norm. */
    public static native double cosineDistance(double[] a, double[] b);

    // -- generic function dispatch --------------------------------------

    /**
     * Call a core function through the generic dispatcher.
     *
     * <p>The dispatcher takes the widest shape any function needs:
     * three arrays, three scalars, and a scratch array for the extra
     * outputs. The return value is the function's primary scalar result;
     * {@code out} carries anything else (secondary metrics, weights,
     * indices).
     *
     * @param fnId  the function id -- a {@code FractalFn} id
     * @param a     the first array argument, or null
     * @param b     the second array argument, or null
     * @param c     the third array argument, or null
     * @param p1    the first scalar argument
     * @param p2    the second scalar argument
     * @param p3    the third scalar argument
     * @param out   scratch for the function's extra outputs; may be null
     * @return the function's primary scalar result, or NaN if the core
     *         reported an error
     */
    public static native double callFn(
            int fnId,
            double[] a, int aLen,
            double[] b, int bLen,
            double[] c, int cLen,
            double p1, double p2, double p3,
            double[] out);

    /**
     * Call a vector-returning core function through the generic
     * dispatcher.
     *
     * @return the resulting vector, or null if the core reported an error
     */
    public static native double[] callVec(
            int fnId,
            double[] a, int aLen,
            double[] b, int bLen,
            double[] c, int cLen,
            double p1, double p2, double p3);

    /**
     * The core's cycle detector, over a sequence of state fingerprints.
     *
     * @param fingerprints one byte array per state
     * @param nBits        the fingerprint's width in bits
     * @param hammingThreshold how far apart two states may be and still
     *                         count as the same state
     * @return a JSON verdict: {@code {"cycle_detected":bool,
     *         "cycle_length":N,"cycle_start":I,...}}
     */
    public static native String cycleDetect(
            byte[][] fingerprints, int nBits, int hammingThreshold);
}
