/*
 * SPDX-License-Identifier: Apache-2.0
 * Copyright 2026 Daniel Gardiner d/b/a FractalSQLabs
 */
package com.fractalsqlabs.fractalsql.daemon;

import java.io.IOException;
import java.nio.file.Path;
import java.util.concurrent.atomic.AtomicReference;

/** fractalsqld for Druid: the FSQ server on the JVM, running the function bodies through JNI. */
public final class Fsqld {

    private static final String CONFIG_ENV = "FRACTALSQL_CONFIG";
    private static final String CONFIG_DEFAULT = "/etc/fractalsql/fractalsqld.conf";

    private Fsqld() {}

    public static void main(String[] args)
    {
        System.exit(run(args));
    }

    static int run(String[] args)
    {
        String configPath = System.getenv(CONFIG_ENV);
        for (int i = 0; i < args.length; i++) {
            if (args[i].equals("-c") && i + 1 < args.length) {
                configPath = args[++i];
            } else {
                System.err.println("usage: fractalsqld [-c config]");
                return 2;
            }
        }
        if (configPath == null) {
            configPath = CONFIG_DEFAULT;
        }
        final Path path = Path.of(configPath);

        try {
            Native.load();
        } catch (UnsatisfiedLinkError e) {
            System.err.println("fractalsqld: cannot load the native library: " + e.getMessage());
            return 1;
        }
        final DaemonConfig cfg;
        try {
            cfg = DaemonConfig.load(path);
        } catch (DaemonConfig.ConfigException e) {
            System.err.println("fractalsqld: " + e.getMessage());
            return 1;
        }
        Native.boot();

        if (Native.euid() == 0) {
            Log.error("refusing to run as root: run as the service user (the container image runs it as an unprivileged user)");
            return 1;
        }
        if (!cfg.validatePlatform(path) || !cfg.checkProvider()) {
            return 1;
        }
        if (!cfg.applyProvider()) {
            System.err.println("fractalsqld: could not apply the provider settings");
            return 1;
        }

        final AtomicReference<DaemonConfig> published = new AtomicReference<>(cfg);
        final Dispatcher dispatcher = new Dispatcher(published, path);
        final Server server = new Server(published, dispatcher);
        try {
            server.open();
        } catch (IOException e) {
            Log.error("cannot listen on " + cfg.socketPath + ": " + e.getMessage());
            return 1;
        }
        Runtime.getRuntime().addShutdownHook(new Thread(server::stop, "fsq-shutdown"));
        server.serve();
        return 0;
    }
}
