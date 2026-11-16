/*
 * SPDX-License-Identifier: Apache-2.0
 * Copyright 2026 Daniel Gardiner d/b/a FractalSQLabs
 */
package com.fractalsqlabs.fractalsql.daemon;

import java.time.Instant;
import java.time.temporal.ChronoUnit;

/** One-line log records on stderr, in the same shape every fractalsqld writes. */
final class Log {

    private static final long PID = ProcessHandle.current().pid();

    private Log() {}

    static synchronized void log(String level, String message)
    {
        System.err.println(Instant.now().truncatedTo(ChronoUnit.SECONDS) + " fractalsqld[" + PID + "] "
                + level + " " + message);
    }

    static void info(String message)
    {
        log("INFO", message);
    }

    static void warn(String message)
    {
        log("WARN", message);
    }

    static void error(String message)
    {
        log("ERROR", message);
    }
}
