/*
 * SPDX-License-Identifier: Apache-2.0
 * Copyright 2026 Daniel Gardiner d/b/a FractalSQLabs
 */
import com.fractalsqlabs.fractalsql.druid.FractalSqlCore;
import com.fractalsqlabs.fractalsql.druid.Native;
import com.fractalsqlabs.fractalsql.druid.NativeLoader;

/**
 * Drives the JNI shim from several threads at once, for the ThreadSanitizer build (build_test.sh gate 40): the pure functions,
 * the cycle detector, the vector functions and the node-wide diversify context (under its lock). TSan
 * instruments the shim only; the vendored core is not instrumented, so a race inside the core is not seen.
 */
public class ShimStress {
    public static void main(String[] args) throws Exception
    {
        NativeLoader.load();
        final FractalSqlCore core = new FractalSqlCore();
        final Thread[] threads = new Thread[8];
        for (int t = 0; t < threads.length; t++) {
            threads[t] = new Thread(() -> {
                final double[] mu = {0.1, 0.2};
                final double[] cov = {1, 0, 0, 1};
                final double[] out = new double[8];
                for (int i = 0; i < 300; i++) {
                    Native.cycleDetect(new byte[][]{new byte[8], new byte[8], new byte[8]}, 64, 3);
                    Native.cosineDistance(new double[]{1, 2, 3}, new double[]{3, 2, 1});
                    Native.callFn(8, mu, mu.length, cov, cov.length, null, 0, 1, 0, 0, out);
                    Native.callFn(10, mu, mu.length, null, 0, null, 0, 64, 0, 0, out);
                    core.locked(h -> Native.diversifyCurrentDq(h));
                    if (i % 50 == 0) {
                        core.locked(h -> Native.diversifyEnable(h));
                        core.locked(h -> Native.diversifyDisable(h));
                    }
                }
            });
            threads[t].start();
        }
        for (Thread t : threads) {
            t.join();
        }
        System.out.println("shim stress done " + Native.version());
    }
}
