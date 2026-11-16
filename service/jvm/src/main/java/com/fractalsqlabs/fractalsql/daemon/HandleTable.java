/*
 * SPDX-License-Identifier: Apache-2.0
 * Copyright 2026 Daniel Gardiner d/b/a FractalSQLabs
 */
package com.fractalsqlabs.fractalsql.daemon;

import java.util.ArrayList;
import java.util.HashMap;
import java.util.List;
import java.util.Map;

/**
 * Open statement handles, one per UDF_INIT until its UDF_DEINIT.
 *
 * <p>A handle belongs to the connection that opened it: a connection can
 * reach only its own. A cancel is the exception, so an operator can stop a
 * running call from a second connection.
 */
final class HandleTable {

    /** One open handle. */
    static final class Handle {
        final long id;
        final int fnIndex;
        final String name;
        final long nativePtr;
        final int nargs;
        final long owner;

        Handle(long id, int fnIndex, String name, long nativePtr, int nargs, long owner)
        {
            this.id = id;
            this.fnIndex = fnIndex;
            this.name = name;
            this.nativePtr = nativePtr;
            this.nargs = nargs;
            this.owner = owner;
        }
    }

    private final Map<Long, Handle> handles = new HashMap<>();
    private long nextId = 1;

    synchronized long allocateId()
    {
        return nextId++;
    }

    synchronized void add(Handle h)
    {
        handles.put(h.id, h);
    }

    synchronized Handle find(long id, long owner)
    {
        final Handle h = handles.get(id);
        return h != null && h.owner == owner ? h : null;
    }

    synchronized Handle remove(long id, long owner)
    {
        final Handle h = handles.get(id);
        if (h != null && h.owner == owner) {
            handles.remove(id);
            return h;
        }
        return null;
    }

    /** Marks a handle cancelled, whichever connection owns it. */
    synchronized boolean cancel(long id)
    {
        final Handle h = handles.get(id);
        if (h == null) {
            return false;
        }
        Native.cancel(h.nativePtr);
        return true;
    }

    /** Removes and returns every handle a connection still holds. */
    synchronized List<Handle> removeOwner(long owner)
    {
        final List<Handle> out = new ArrayList<>();
        for (Handle h : handles.values()) {
            if (h.owner == owner) {
                out.add(h);
            }
        }
        for (Handle h : out) {
            handles.remove(h.id);
        }
        return out;
    }
}
