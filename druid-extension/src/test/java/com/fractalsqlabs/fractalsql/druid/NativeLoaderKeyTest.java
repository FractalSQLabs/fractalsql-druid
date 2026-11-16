/*
 * SPDX-License-Identifier: Apache-2.0
 * Copyright 2026 Daniel Gardiner d/b/a FractalSQLabs
 */
package com.fractalsqlabs.fractalsql.druid;

import static org.junit.jupiter.api.Assertions.assertEquals;

import org.junit.jupiter.api.Test;

/** The payload directory a JVM maps to: the four platforms the extension ships a native shim for. */
class NativeLoaderKeyTest {

    private static String keyFor(String os, String arch) {
        String savedOs = System.getProperty("os.name");
        String savedArch = System.getProperty("os.arch");
        try {
            System.setProperty("os.name", os);
            System.setProperty("os.arch", arch);
            return NativeLoader.platformKey();
        } finally {
            System.setProperty("os.name", savedOs);
            System.setProperty("os.arch", savedArch);
        }
    }

    @Test
    void linuxAmd64() {
        assertEquals("linux-x86_64", keyFor("Linux", "amd64"));
        assertEquals("linux-x86_64", keyFor("Linux", "x86_64"));
    }

    @Test
    void linuxArm() {
        assertEquals("linux-aarch64", keyFor("Linux", "aarch64"));
    }

    @Test
    void macIntel() {
        assertEquals("darwin-x86_64", keyFor("Mac OS X", "x86_64"));
    }

    @Test
    void macAppleSilicon() {
        // Apple Silicon is "arm64" in the vendored core drop and in the payload directory, "aarch64" in the JVM.
        assertEquals("darwin-arm64", keyFor("Mac OS X", "aarch64"));
        assertEquals("darwin-arm64", keyFor("Mac OS X", "arm64"));
    }
}
