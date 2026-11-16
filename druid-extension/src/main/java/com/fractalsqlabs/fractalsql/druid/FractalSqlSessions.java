/*
 * SPDX-License-Identifier: Apache-2.0
 * Copyright 2026 Daniel Gardiner d/b/a FractalSQLabs
 */
package com.fractalsqlabs.fractalsql.druid;

import com.google.inject.Singleton;

import java.util.ArrayList;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.concurrent.ConcurrentHashMap;

/**
 * The session overlay: the per-session configuration values.
 *
 * <p>This is the config/session tier's home in this port. The other * ports keep the overlay in the daemon, keyed by the session the
 * protocol carries; the extension keeps it here, keyed by a session id
 * the caller names, because a Druid query has no connection to hang a
 * session on and the query context is per-request rather than
 * per-session.
 *
 * <p><b>What may live here.</b> Only the <i>tuning</i> keys -- the ones
 * {@link FractalSqlConfig} marks request-overridable. The operator's
 * settings (the provider URL, the plugin, the ledger key, the
 * credentials) are not session state and are refused here; see
 * {@link FractalSqlConfig#operatorOnlyKeys()}. That split is the whole
 * point of the tier: a request may tune the search, and may not
 * re-point the model.
 *
 * <p>The overlay is per node. In production the session tier belongs to
 * {@code fractalsqld}, so every Druid process that uses a daemon shares that daemon's
 * overlay (one per host in a multi-host layout); the extension's copy is what a
 * single-node deployment and the demo suite use.
 */
@Singleton
public class FractalSqlSessions {

    /** How many sessions are kept before the oldest are dropped. */
    private static final int MAX_SESSIONS = 1024;

    /** The overlay for each session: key -> value. */
    private final ConcurrentHashMap<String, Map<String, String>> sessions = new ConcurrentHashMap<>();

    /** The feedback reported so far, waiting for the ledger to take it. */
    private final List<Map<String, Object>> feedback = new ArrayList<>();

    /** The order the sessions were first seen, for the eviction. */
    private final LinkedHashMap<String, Boolean> order = new LinkedHashMap<>();

    /** Whether the Diversify monitor is on. */
    private volatile boolean diversifyEnabled;

    /**
     * Set a value in a session's overlay.
     *
     * @param sessionId the session the value belongs to
     * @param name the setting's name
     * @param value the value
     * @return the value, so the caller can use it in an expression
     */
    public String set(String sessionId, String name, String value)
    {
        final Map<String, String> overlay = overlay(sessionId);
        synchronized (overlay) {
            overlay.put(name, value);
        }
        return value;
    }

    /**
     * A session's override for a setting, or null if it has none.
     *
     * @param sessionId the session
     * @param name the setting's name
     */
    public String get(String sessionId, String name)
    {
        if (sessionId == null || sessionId.isEmpty()) {
            return null;
        }
        final Map<String, String> overlay = sessions.get(sessionId);
        if (overlay == null) {
            return null;
        }
        synchronized (overlay) {
            return overlay.get(name);
        }
    }

    /** Forget a session's overlay, and report how many values it held. */
    public int reset(String sessionId)
    {
        final Map<String, String> overlay = sessions.remove(sessionId);
        synchronized (order) {
            order.remove(sessionId);
        }
        if (overlay == null) {
            return 0;
        }
        return overlay.size();
    }

    /** A session's overrides, as a map. */
    public Map<String, String> overrides(String sessionId)
    {
        final Map<String, String> overlay = sessions.get(sessionId);
        if (overlay == null) {
            return Map.of();
        }
        synchronized (overlay) {
            return new LinkedHashMap<>(overlay);
        }
    }

    /** How many sessions are held. */
    public int size()
    {
        return sessions.size();
    }

    // -- the session tier's own state ------------------------------------

    /** Whether the Diversify monitor is on. */
    public boolean diversifyEnabled()
    {
        return diversifyEnabled;
    }

    /** Turn the Diversify monitor on. */
    public void setDiversifyEnabled(boolean enabled)
    {
        this.diversifyEnabled = enabled;
    }

    /**
     * Record the caller's verdict on a result.
     *
     * <p>The ledger keeps the reports; the session keeps the count.
     */
    public synchronized void reportFeedback(long docId, String kind, double dwellMs)
    {
        final Map<String, String> overlay = overlay("feedback");
        synchronized (overlay) {
            final String key = "feedback." + docId;
            final String previous = overlay.get(key);
            final int count = previous == null ? 0 : Integer.parseInt(previous);
            overlay.put(key, Integer.toString(count + 1));
            overlay.put("feedback.kind." + docId, kind);
            overlay.put("feedback.dwell." + docId, Double.toString(dwellMs));
        }
        final Map<String, Object> one = new LinkedHashMap<>();
        one.put("id", docId);
        one.put("kind", kind);
        one.put("dwell_ms", dwellMs);
        synchronized (feedback) {
            feedback.add(one);
        }
    }

    /**
     * The feedback reported so far, and nothing more.
     *
     * <p>The ledger consumes it: a report is a fact about a result, and
     * the ledger is where the facts accumulate.
     */
    public List<Map<String, Object>> feedback()
    {
        final List<Map<String, Object>> out = new ArrayList<>();
        synchronized (feedback) {
            for (Map<String, Object> one : feedback) {
                out.add(one);
            }
        }
        return out;
    }

    /** Forget the reported feedback. */
    public void clearFeedback()
    {
        synchronized (feedback) {
            feedback.clear();
        }
    }

    /** Set a result aside. */
    public void isolate(long docId)
    {
        final Map<String, String> overlay = overlay("isolated");
        synchronized (overlay) {
            overlay.put("isolated." + docId, "true");
        }
    }

    /** The results the caller has set aside. */
    public java.util.Set<String> isolated()
    {
        final java.util.Set<String> out = new java.util.LinkedHashSet<>();
        final Map<String, String> overlay = sessions.get("isolated");
        if (overlay != null) {
            synchronized (overlay) {
                for (Map.Entry<String, String> entry : overlay.entrySet()) {
                    if (entry.getKey().startsWith("isolated.")) {
                        out.add(entry.getKey().substring("isolated.".length()));
                    }
                }
            }
        }
        return out;
    }

    /** The session's overlay, created if it is new. */
    private Map<String, String> overlay(String sessionId)
    {
        final Map<String, String> existing = sessions.get(sessionId);
        if (existing != null) {
            return existing;
        }
        final Map<String, String> created = new ConcurrentHashMap<>();
        final Map<String, String> raced = sessions.putIfAbsent(sessionId, created);
        if (raced != null) {
            return raced;
        }
        synchronized (order) {
            order.put(sessionId, Boolean.TRUE);
            while (order.size() > MAX_SESSIONS) {
                final String oldest = order.keySet().iterator().next();
                order.remove(oldest);
                sessions.remove(oldest);
            }
        }
        return created;
    }
}
