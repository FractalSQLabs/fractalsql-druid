/*
 * SPDX-License-Identifier: Apache-2.0
 * Copyright 2026 Daniel Gardiner d/b/a FractalSQLabs
 */
package com.fractalsqlabs.fractalsql.druid;

import java.io.IOException;
import java.io.InputStream;
import java.nio.file.Files;
import java.nio.file.Path;
import java.nio.file.Paths;
import java.nio.file.StandardCopyOption;
import java.util.Locale;

/**
 * Locates and loads the JNI shim that bridges to the FractalSQL core.
 *
 * <p>Druid has no native-plugin interface of its own -- extensions are
 * pure Java -- so a Java extension that wants the core has to carry its
 * own native payload and load it itself. This class does that:
 *
 * <ol>
 *   <li>work out the {@code <os>-<arch>} key for the running JVM;</li>
 *   <li>find the shim, either under a directory given by the
 *       {@code fsql.native.path} system property (the development
 *       layout) or inside the JAR at
 *       {@code /native/<os>-<arch>/<lib>};</li>
 *   <li>copy it to a temporary file and {@link System#load} it.</li>
 * </ol>
 *
 * <p>The copy is necessary because a JAR entry is not a file the
 * dynamic loader can open. The temporary file is deleted on exit.
 */
public final class NativeLoader {

    /** Dev override: a directory holding the built shim for this platform. */
    public static final String NATIVE_PATH_PROPERTY = "fsql.native.path";

    private static boolean loaded;
    private static UnsatisfiedLinkError failure;

    private NativeLoader() {
    }

    /**
     * Load the shim. Idempotent and safe to call from any thread; the
     * first call does the work and every later call returns.
     *
     * @throws UnsatisfiedLinkError if the shim for this platform is not
     *                              present in the JAR
     */
    public static synchronized void load() {
        if (loaded) {
            return;
        }
        if (failure != null) {
            throw failure;
        }
        try {
            load0();
            loaded = true;
        } catch (UnsatisfiedLinkError e) {
            failure = e;
            throw e;
        }
    }

    /** True once the shim is loaded. */
    public static synchronized boolean isLoaded() {
        return loaded;
    }

    private static void load0() throws UnsatisfiedLinkError {
        String key = platformKey();
        String libName = System.mapLibraryName("fractalsql-jni");

        // 1. Development layout: an explicit directory wins, so a
        //    rebuild does not require repackaging the JAR.
        String devPath = System.getProperty(NATIVE_PATH_PROPERTY);
        if (devPath != null && !devPath.isEmpty()) {
            Path dir = Path.of(devPath);
            Path candidate = dir.resolve(libName);
            if (Files.isRegularFile(candidate)) {
                System.load(candidate.toAbsolutePath().toString());
                return;
            }
        }

        // 2. Packaged layout: inside the JAR.
        String resource = "/native/" + key + "/" + libName;
        try (InputStream in = NativeLoader.class.getResourceAsStream(resource)) {
            if (in == null) {
                throw new UnsatisfiedLinkError(
                        "fractalsql-druid: native shim not found for " + key
                                + " (expected " + resource + " inside the extension JAR, "
                                + "or set -D" + NATIVE_PATH_PROPERTY + " to a directory holding "
                                + libName + "). Payloads ship for linux-x86_64, linux-aarch64, darwin-x86_64 and darwin-arm64.");
            }
            // Druid points java.io.tmpdir at a directory under its own var/, relative to the working directory, and
            // does not always create it (a broker with a fresh var volume has none). Make it, as the JDK will not.
            final String tmpdir = System.getProperty("java.io.tmpdir");
            final Path tmp;
            if (tmpdir != null && !tmpdir.isEmpty()) {
                final Path dir = Paths.get(tmpdir);
                Files.createDirectories(dir);
                tmp = Files.createTempFile(dir, "fractalsql-jni-", suffixFor(key));
            } else {
                tmp = Files.createTempFile("fractalsql-jni-", suffixFor(key));
            }
            // Owner-only before anything is written into it, and before it is loaded.
            try {
                Files.setPosixFilePermissions(tmp, java.nio.file.attribute.PosixFilePermissions.fromString("rwx------"));
            } catch (UnsupportedOperationException ignored) {
                // not a POSIX file system (Windows): the directory's own access rules apply
            }
            tmp.toFile().deleteOnExit();
            Files.copy(in, tmp, StandardCopyOption.REPLACE_EXISTING);
            System.load(tmp.toAbsolutePath().toString());
        } catch (IOException e) {
            throw new UnsatisfiedLinkError(
                    "fractalsql-druid: could not extract the native shim for " + key + ": " + e);
        }
    }

    /**
     * The {@code <os>-<arch>} key for the running JVM, matching the
     * layout of the vendored core drops in {@code include/}.
     */
    public static String platformKey() {
        String os = osKey();
        String arch = archKey();
        // The vendored core drops name Apple Silicon "arm64" and Linux ARM "aarch64".
        if (os.equals("darwin") && arch.equals("aarch64")) {
            arch = "arm64";
        }
        return os + "-" + arch;
    }

    static String osKey() {
        String os = System.getProperty("os.name", "").toLowerCase(Locale.ROOT);
        if (os.contains("mac") || os.contains("darwin")) {
            return "darwin";
        }
        // Linux and the other Unices share the linux build.
        return "linux";
    }

    static String archKey() {
        String arch = System.getProperty("os.arch", "").toLowerCase(Locale.ROOT);
        switch (arch) {
            case "x86_64":
            case "amd64":
                return "x86_64";
            case "aarch64":
            case "arm64":
                return "aarch64";
            default:
                return arch;
        }
    }

    private static String suffixFor(String key) {
        return key.startsWith("darwin") ? ".dylib" : ".so";
    }
}
