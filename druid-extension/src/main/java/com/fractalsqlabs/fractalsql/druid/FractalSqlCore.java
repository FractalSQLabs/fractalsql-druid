/*
 * SPDX-License-Identifier: Apache-2.0
 * Copyright 2026 Daniel Gardiner d/b/a FractalSQLabs
 */
package com.fractalsqlabs.fractalsql.druid;

import com.google.inject.Inject;
import com.google.inject.Singleton;

/**
 * The node's core context.
 *
 * <p>One context per node, held for the node's life. A database with
 * connections would hold one per connection and the whole session tier -- the Diversify
 * monitor, the search's refinement -- ran on it; a Druid node has no
 * connection, so the node's context is the closest honest equivalent,
 * and it is what makes {@code fractal_diversify_enable()} and the
 * searches that follow it talk to the same state.
 *
 * <p>The context is created on first use and never freed: the node
 * owns it, and the JVM's exit does the rest.
 */
@Singleton
public class FractalSqlCore {

    /** The handle, or 0 before the context is created. */
    private volatile long handle;

    @Inject
    public FractalSqlCore()
    {
    }

    private final java.util.concurrent.locks.ReentrantLock lock = new java.util.concurrent.locks.ReentrantLock();

    /**
     * Runs a call on the node's context with the context locked. The core documents its context as not thread-safe (it
     * mutates the monitor's state, and a result stays valid only until the next call on the same context), and one
     * context serves every query thread on the node: two concurrent diversify calls would otherwise race
     * The state is deliberately node-wide, so a lock, not a context per thread, is the faithful fix.
     */
    public <T> T locked(java.util.function.LongFunction<T> call)
    {
        final long h = handle();
        lock.lock();
        try {
            return call.apply(h);
        } finally {
            lock.unlock();
        }
    }

    /**
     * The node's core context, created on first use.
     *
     * <p>The creation is guarded, so two threads racing for the first
     * search do not leak a context.
     */
    public long handle()
    {
        long current = handle;
        if (current != 0) {
            return current;
        }
        synchronized (this) {
            if (handle == 0) {
                NativeLoader.load();
                final long created = Native.newSovereign();
                if (created == 0) {
                    throw new IllegalStateException("fractalsql: could not create a core context");
                }
                handle = created;
            }
            return handle;
        }
    }
}
