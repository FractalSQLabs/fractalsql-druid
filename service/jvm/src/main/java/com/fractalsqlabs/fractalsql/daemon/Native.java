/*
 * SPDX-License-Identifier: Apache-2.0
 * Copyright 2026 Daniel Gardiner d/b/a FractalSQLabs
 */
package com.fractalsqlabs.fractalsql.daemon;

/** The native side: the function bodies, run through their init / call / deinit convention. */
final class Native {

    /** Result codes of {@link #call}. */
    static final int CALL_OK = 0;
    static final int CALL_CORE_ERROR = 1;
    static final int CALL_LIMIT = 2;
    static final int CALL_CANCELLED_MID = 3;
    static final int CALL_CANCELLED_BEFORE = 4;
    static final int CALL_BAD_ARG = 5;
    static final int CALL_INTERNAL = 6;
    static final int CALL_NOTSUP = 7;

    /** Function kinds, as the table reports them. */
    static final int KIND_STR = 1;
    static final int KIND_INT = 2;
    static final int KIND_REAL = 3;

    private Native() {}

    /** Loads the native library: -Dfsqld.native=/path/libfsqld_jni.so, else java.library.path. */
    static void load()
    {
        final String path = System.getProperty("fsqld.native");
        if (path != null && !path.isEmpty()) {
            System.load(path);
        } else {
            System.loadLibrary("fsqld_jni");
        }
    }

    static native void boot();

    static native int functionCount();

    static native String functionName(int index);

    static native int functionKind(int index);

    static native int euid();

    static native String userName(int uid);

    static native void releaseThreadBuffers();

    /** Null when the path is acceptable, else the reason it is not. */
    static native String validatePath(String path);

    static native long open(int fnIndex, int[] types, byte[][] consts, byte[] msgOut);

    static native int[] info(long handle);

    static native int call(long handle, byte[][] vals, byte[][] resOut, int[] meta);

    static native void cancel(long handle);

    static native void close(long handle);

    static native int providerCheck(int present, String[] strs, long[] longs, boolean[] bools);

    static native int providerApply(int present, String[] strs, long[] longs, boolean[] bools);
}
