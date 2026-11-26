/*
 * SPDX-License-Identifier: Apache-2.0
 * Copyright 2026 Daniel Gardiner d/b/a FractalSQLabs
 */
package com.fractalsqlabs.fractalsql.druid;

import com.google.inject.Inject;
import com.google.inject.Provider;
import com.google.inject.Singleton;
import org.apache.druid.java.util.common.logger.Logger;

import java.util.Collections;
import java.util.LinkedHashMap;
import java.util.LinkedHashSet;
import java.util.Map;
import java.util.Properties;
import java.util.Set;
import java.util.TreeMap;

/**
 * The extension's configuration.
 *
 * <p>Read from the node's runtime properties, under
 * {@code druid.fractalsql.*}. Two channels, and the split between them
 * is the point of this class:
 *
 * <ul>
 *   <li><b>Operator keys.</b> Set in the node's properties. They decide
 *       which code runs, where outbound traffic goes, and what the
 *       operator's credentials are. A request cannot change them — the
 *       request context is caller-supplied, so a request that could
 *       re-point the LLM endpoint would exfiltrate the operator's
 *       token, and a request that could name the reasoning plugin would
 *       run attacker-chosen code.</li>
 *   <li><b>Request keys.</b> Tuning only: the model name, the THINK
 *       level, the text-to-SQL attempt count. A request may change
 *       these.</li>
 * </ul>
 *
 * <p>This is the same split the daemon makes
 * ({@code service/adapter/src/fractalsql_config.h}), for the same
 * reasons. The difference is that Druid's per-request channel is the
 * <i>query context</i>, which is entirely caller-supplied — so the deny
 * list has to be enforced here, explicitly, rather than by the host's
 * own config machinery.
 */
@Singleton
public class FractalSqlConfig {

    private static final Logger log = new Logger(FractalSqlConfig.class);

    /** The prefix every key carries. */
    public static final String PREFIX = "druid.fractalsql.";

    /** The prefix a request context uses for an override. */
    public static final String REQUEST_PREFIX = "fractalsql.";

    /** The kind of value a key holds. */
    public enum Kind {
        STRING,
        PATH,
        INT,
        LONG,
        DOUBLE,
        BOOL
    }

    /** One configuration key. */
    public static final class Key {
        private final String name;
        private final Kind kind;
        private final boolean requestOverridable;
        private final String defaultValue;
        private final String reason;

        Key(String name, Kind kind, boolean requestOverridable, String defaultValue, String reason)
        {
            this.name = name;
            this.kind = kind;
            this.requestOverridable = requestOverridable;
            this.defaultValue = defaultValue;
            this.reason = reason;
        }

        /** The key's name, without the prefix: {@code search.population_size}. */
        public String name()
        {
            return name;
        }

        /** The kind of value it holds. */
        public Kind kind()
        {
            return kind;
        }

        /** Whether a request may override it. */
        public boolean isRequestOverridable()
        {
            return requestOverridable;
        }

        /** The value used when the operator has not set one. */
        public String defaultValue()
        {
            return defaultValue;
        }

        /** Why it is (or is not) request-overridable. */
        public String reason()
        {
            return reason;
        }
    }

    private static final Map<String, Key> KEYS = new LinkedHashMap<>();

    private static void key(
            String name,
            Kind kind,
            boolean requestOverridable,
            String defaultValue,
            String reason)
    {
        KEYS.put(name, new Key(name, kind, requestOverridable, defaultValue, reason));
    }

    static {
        // -- the search tuning ------------------------------------------
        // The SFS budget is the operator's: it decides how much work a
        // query may spend, so a request must not be able to raise it.
        key("search.max_generation", Kind.INT, false, "30",
                "the SFS budget: a request must not be able to spend the operator's compute");
        key("search.population_size", Kind.INT, false, "50",
                "the SFS budget: a request must not be able to spend the operator's compute");
        key("search.maximum_diffusion", Kind.INT, false, "2",
                "the SFS budget: a request must not be able to spend the operator's compute");
        key("search.walk", Kind.DOUBLE, false, "0.5",
                "the SFS budget: a request must not be able to spend the operator's compute");
        key("search.bound_clipping", Kind.BOOL, false, "true",
                "the SFS budget: a request must not be able to spend the operator's compute");
        key("search.params", Kind.STRING, false, "",
                "the whole SFS parameter document, when the operator wants to set it directly");

        // -- the daemon ---------------------------------------------------
        // The reasoning, embedding and enterprise settings belong to
        // fractalsqld, which runs beside the broker: they live in its
        // own fractalsqld.conf. The extension only needs to reach it.
        key("daemon_socket", Kind.PATH, false, "/run/fractalsql/fractalsqld.sock",
                "where the daemon listens: a request that could re-point it would send the node's calls elsewhere");
        key("daemon_hmac_key_file", Kind.PATH, false, "/run/fractalsql/hmac.key",
                "the key the daemon's frames are signed with");
        key("daemon_timeout_ms", Kind.LONG, false, "300000",
                "a request that could raise the timeout could hold a query thread open");

        key("ledger.allow_destructive", Kind.BOOL, false, "false",
                "an operator switch, off by default: without it the ledger's destructive operations (compact, reset) refuse, so a node "
                        + "nobody configured cannot have its audit chain destroyed by a query");
        key("ledger.read_only", Kind.BOOL, false, "false",
                "a deliberate posture flag: it latches the ledger's destructive operations");
        key("agent_use_index", Kind.STRING, false, "off",
                "an operator switch, off by default (off, on or auto; true and false still mean on and off): with it on, the nearest-row agents "
                        + "(route_task, outlier_intercept, schedule_workload) search through a fractal_index when one covers the table and column; "
                        + "auto uses an index only when it is ready, was calibrated to its target recall (an estimate from a sample, made at build time) and "
                        + "the table has at least agent_index_min_rows rows; otherwise it scans exactly. An index can rarely "
                        + "pick a different nearest row than the exact scan");
        key("agent_index_min_rows", Kind.INT, false, "10000",
                "auto mode: the smallest table the agents search through an index (below it the exact scan is as fast and exact)");
        key("agent_context_row_bytes", Kind.INT, false, "8192",
                "the longest text cell the retrieval agents pass to the model; longer cells are cut with a marker (0 = no limit)");
        key("coordinator_url", Kind.PATH, false, "",
                "where the coordinator is reachable: the task status lives there, not on the node that submitted the task");
    }

    /** The keys a request may override. */
    public static Set<String> requestOverridableKeys()
    {
        final Set<String> out = new LinkedHashSet<>();
        for (Key k : KEYS.values()) {
            if (k.isRequestOverridable()) {
                out.add(k.name());
            }
        }
        return Collections.unmodifiableSet(out);
    }

    /** The keys a request may not override. */
    public static Set<String> operatorOnlyKeys()
    {
        final Set<String> out = new LinkedHashSet<>();
        for (Key k : KEYS.values()) {
            if (!k.isRequestOverridable()) {
                out.add(k.name());
            }
        }
        return Collections.unmodifiableSet(out);
    }

    /** Every key, and why it is what it is. */
    public static Map<String, Key> keys()
    {
        return Collections.unmodifiableMap(KEYS);
    }

    private final Properties properties;

    @Inject
    public FractalSqlConfig(Provider<Properties> properties)
    {
        this.properties = properties.get();
        // The effective configuration, with the credentials redacted.
        // Logged once, so an operator can see what the node is actually
        // running with -- and so a gate can check that the runtime
        // properties really reached the extension.
        log.info("fractalsql: configuration %s", describe());
    }

    /** The operator's raw value for a key, or its default. */
    public String operatorValue(String name)
    {
        final Key k = requireKey(name);
        final String value = properties.getProperty(PREFIX + name);
        return value != null ? value : k.defaultValue();
    }

    /**
     * The effective value for a request.
     *
     * <p>A request may override a tuning key. It may not override an
     * operator key: the attempt is refused and the operator's value
     * stands. Refusing rather than throwing keeps a hostile context
     * from being able to fail a query; the refusal is recorded so it
     * can be reported.
     *
     * @param requestContext the request's query context, or null
     * @return the effective value
     */
    public String effectiveValue(String name, Map<String, String> requestContext)
    {
        final Key k = requireKey(name);
        final String override = requestValue(name, requestContext);
        if (override == null) {
            return operatorValue(name);
        }
        if (!k.isRequestOverridable()) {
            refused.add(k.name());
            return operatorValue(name);
        }
        return override;
    }

    /** The request's override for a key, or null. */
    private String requestValue(String name, Map<String, String> requestContext)
    {
        if (requestContext == null) {
            return null;
        }
        final String v1 = requestContext.get(PREFIX + name);
        if (v1 != null) {
            return v1;
        }
        return requestContext.get(REQUEST_PREFIX + name);
    }

    /** The keys a request tried to override and was not allowed to. */
    private final Set<String> refused = Collections.synchronizedSet(new LinkedHashSet<>());

    /** The keys a request tried to override and was not allowed to. */
    public Set<String> refusedOverrides()
    {
        return Collections.unmodifiableSet(new LinkedHashSet<>(refused));
    }

    /** The operator's value as an int. */
    public int operatorInt(String name)
    {
        return Integer.parseInt(operatorValue(name).trim());
    }

    /** The operator's value as a long. */
    public long operatorLong(String name)
    {
        return Long.parseLong(operatorValue(name).trim());
    }

    /** The operator's value as a double. */
    public double operatorDouble(String name)
    {
        return Double.parseDouble(operatorValue(name).trim());
    }

    /** agent_use_index as a mode: 0 off, 1 on, 2 auto. The old boolean spellings (true, yes, 1) still mean on. */
    public int agentUseIndexMode()
    {
        final String v = operatorValue("agent_use_index").trim().toLowerCase(java.util.Locale.ROOT);
        if (v.equals("auto")) {
            return 2;
        }
        return v.equals("on") || v.equals("true") || v.equals("yes") || v.equals("1") ? 1 : 0;
    }

    /** The operator's value as a boolean. */
    public boolean operatorBool(String name)
    {
        return Boolean.parseBoolean(operatorValue(name).trim());
    }

    /**
     * The SFS parameter document the search aggregate drives the core
     * with.
     *
     * <p>These defaults are the ones the extension uses. The core's own
     * defaults are not equivalent: with them the walk over a one-row
     * corpus divides by a zero difference and the refined point comes
     * back full of NaNs, which then makes every distance NaN.
     */
    public String searchParamsJson()
    {
        final String whole = properties.getProperty(PREFIX + "search.params");
        if (whole != null && !whole.trim().isEmpty()) {
            return whole.trim();
        }
        return "{"
                + "\"max_generation\":" + operatorInt("search.max_generation") + ","
                + "\"population_size\":" + operatorInt("search.population_size") + ","
                + "\"maximum_diffusion\":" + operatorInt("search.maximum_diffusion") + ","
                + "\"walk\":" + operatorDouble("search.walk") + ","
                + "\"bound_clipping\":" + operatorBool("search.bound_clipping")
                + "}";
    }

    /**
     * The effective configuration, with the secrets redacted.
     *
     * <p>For logging and for the service's own status endpoint. A
     * credential never appears here — the daemon makes the same
     * promise about its own config
     * ({@code docs/api-cognition.md:15}: "nothing about the daemon
     * connection can be set or read back through a command").
     */
    public Map<String, String> describe()
    {
        final Map<String, String> out = new TreeMap<>();
        for (Key k : KEYS.values()) {
            final String value = operatorValue(k.name());
            if (value == null || value.isEmpty()) {
                continue;
            }
            out.put(k.name(), isSecret(k.name()) ? "<set>" : value);
        }
        return out;
    }

    /** Whether a key holds a credential. */
    public static boolean isSecret(String name)
    {
        if (name == null) {
            return false;
        }
        // Both separators: the older keys were dotted (reasoning.token)
        // and the current ones are underscored (enterprise_ledger_key).
        return name.endsWith(".token") || name.endsWith(".key")
                || name.endsWith("_token") || name.endsWith("_key")
                // the path of a key file names where the secret is kept
                || name.endsWith("_key_file") || name.endsWith(".key_file");
    }

    private static Key requireKey(String name)
    {
        final Key k = KEYS.get(name);
        if (k == null) {
            throw new IllegalArgumentException("fractalsql: no such configuration key: " + name);
        }
        return k;
    }
}
