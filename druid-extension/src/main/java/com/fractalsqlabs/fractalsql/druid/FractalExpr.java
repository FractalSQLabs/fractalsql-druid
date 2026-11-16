/*
 * SPDX-License-Identifier: Apache-2.0
 * Copyright 2026 Daniel Gardiner d/b/a FractalSQLabs
 */
package com.fractalsqlabs.fractalsql.druid;

import com.fasterxml.jackson.databind.JsonNode;
import org.apache.druid.math.expr.Expr;
import org.apache.druid.math.expr.ExprEval;
import org.apache.druid.math.expr.ExprMacroTable;
import org.apache.druid.math.expr.ExpressionType;

import java.util.ArrayList;
import java.util.HashSet;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.Set;

/**
 * The native expression behind one {@code fractal_*} function.
 *
 * <p>This is where a function is actually evaluated: the arguments come
 * out of the binding, the core is called through {@link Native}, and the
 * result is shaped for Druid.
 *
 * <p>A vector argument may be a Druid ARRAY column or its text form (CSV or
 * bracketed JSON).
 */
public class FractalExpr extends ExprMacroTable.BaseMacroFunctionExpr {

    /** The mapper the config tier writes its JSON documents with. */
    private static final com.fasterxml.jackson.databind.ObjectMapper MAPPER =
            new com.fasterxml.jackson.databind.ObjectMapper();

    /** The function this expression evaluates. */
    private final FractalFn.Spec spec;

    /** The reasoning tier, for the functions that need it. */
    private final ReasoningBridge bridge;

    /** The node's configuration, for the config/session tier. */
    private final FractalSqlConfig config;

    /** The session overlay, for the config/session tier. */
    private final FractalSqlSessions sessions;

    /** The node's core context, for the session tier. */
    private final FractalSqlCore core;

    /** The enterprise tier, for the ledger and the CISO audit. */
    private final FractalSqlEnterprise enterprise;
    private final FractalSqlDaemon daemon;

    /** The index tier, for the IVF index and the indexed search. */
    private final FractalSqlIndex index;

    FractalExpr(
            ExprMacroTable.ExprMacro macro,
            FractalFn.Spec spec,
            List<Expr> args,
            ReasoningBridge bridge)
    {
        this(macro, spec, args, bridge, null, null, null, null, null, null);
    }

    FractalExpr(
            ExprMacroTable.ExprMacro macro,
            FractalFn.Spec spec,
            List<Expr> args,
            ReasoningBridge bridge,
            FractalSqlConfig config,
            FractalSqlSessions sessions,
            FractalSqlCore core,
            FractalSqlEnterprise enterprise,
            FractalSqlDaemon daemon)
    {
        this(macro, spec, args, bridge, config, sessions, core, enterprise, daemon, null);
    }

    FractalExpr(
            ExprMacroTable.ExprMacro macro,
            FractalFn.Spec spec,
            List<Expr> args,
            ReasoningBridge bridge,
            FractalSqlConfig config,
            FractalSqlSessions sessions,
            FractalSqlCore core,
            FractalSqlEnterprise enterprise,
            FractalSqlDaemon daemon,
            FractalSqlIndex index)
    {
        super(macro, args);
        this.daemon = daemon;
        this.index = index;
        this.spec = spec;
        this.bridge = bridge;
        this.config = config;
        this.sessions = sessions;
        this.core = core;
        this.enterprise = enterprise;
    }

    @Override
    public ExprEval eval(Expr.ObjectBinding bindings)
    {
        final int arity = spec.arity();
        final Object[] raw = new Object[arity];
        for (int i = 0; i < arity; i++) {
            raw[i] = valueOf(getArgs().get(i).eval(bindings));
        }
        if (spec.id() == 38) { // fractal_reason
            final String answer = bridge == null
                    ? null
                    : bridge.reason(asText(raw[0]), asText(raw[1]));
            return ExprEval.ofString(answer);
        }
        if (spec.id() == 39) { // fractal_embed
            final String vector = bridge == null ? null : bridge.embed(asText(raw[0]));
            return ExprEval.ofString(vector);
        }
        if (spec.id() == 42) { // fractal_version
            return ExprEval.ofString(extensionVersion());
        }
        if (spec.id() == 43) { // fractal_edition
            return ExprEval.ofString(Native.edition());
        }
        if (spec.id() == 40 || spec.id() == 41) { // fractal_json_value / _text
            final JsonNode value = FractalJson.read(asText(raw[0]), asText(raw[1]));
            if (spec.id() == 40) {
                return ExprEval.of(value == null || !value.isNumber() ? Double.NaN : value.asDouble());
            }
            return ExprEval.ofString(value == null || value.isNull()
                    ? null
                    : value.isTextual() ? value.asText() : value.toString());
        }
        if (spec.id() == 44) { // fractal_config_set
            return ExprEval.ofString(configSet(raw));
        }
        if (spec.id() == 45) { // fractal_config_get
            return ExprEval.ofString(configGet(raw));
        }
        if (spec.id() == 46) { // fractal_config_reset
            return ExprEval.ofLong(configReset(raw));
        }
        if (spec.id() == 47) { // fractal_config_list
            return ExprEval.ofString(configList(raw));
        }
        if (spec.id() == 48) { // fractal_config_keys
            return ExprEval.ofString(configKeys());
        }
        if (spec.id() == 59) { // fractal_lock_destructive
            // The one-way latch. It is deliberately NOT gated on the
            // enterprise library: it is the operator's safety valve,
            // and it has to be settable on a Community deployment too.
            if (enterprise == null) {
                throw new IllegalStateException(
                        "fractalsql: the enterprise tier is not available on this node");
            }
            // 1 when this call latched it, 0 when it was already
            // latched -- the latch is one-way, so the second call is
            // not an error, just a no-op.
            return ExprEval.ofLong(enterprise.lockDestructive() ? 1L : 0L);
        }
        if (spec.id() >= 60 && spec.id() <= 69) { // the enterprise tier
            final Object answer = enterprise(spec.id(), raw);
            if (answer instanceof Number) {
                return ExprEval.ofLong(((Number) answer).longValue());
            }
            return ExprEval.ofString(String.valueOf(answer));
        }
        if (spec.id() == 78 || spec.id() == 79) { // the feature store
            return ExprEval.ofString(featureStore(spec.id(), raw));
        }
        if (spec.id() >= 70 && spec.id() <= 75) { // the index tier
            return ExprEval.ofString(indexTier(spec.id(), raw));
        }
        if (spec.id() == 49) { // fractal_search_explore
            return ExprEval.ofString(searchExplore(raw));
        }
        if (spec.id() == 50) { // fractal_sfs_converge_debug
            return ExprEval.ofString(searchDebug(raw));
        }
        if (spec.id() == 76) { // fractal_sfs_converge: the same search without the trace
            return ExprEval.ofString(sfsConverge(raw));
        }
        if (spec.id() == 51) { // fractal_diversify_enable
            diversifyEnable();
            return ExprEval.of(null);
        }
        if (spec.id() == 52) { // fractal_diversify_disable
            diversifyDisable();
            return ExprEval.of(null);
        }
        if (spec.id() == 53) { // fractal_diversify_set_params
            diversifySetParams(asText(raw[0]));
            return ExprEval.of(null);
        }
        if (spec.id() == 54) { // fractal_explain_result
            return ExprEval.ofString(explainResult());
        }
        if (spec.id() == 55) { // fractal_detect_collapse
            final double dq = core().locked(h -> Native.diversifyCurrentDq(h));
            if (Double.isNaN(dq)) {
                // A null DOUBLE, and not a null unboxed on the way
                // to it: the ternary's type is Double, so
                // `ExprEval.of(Double)` resolves to of(double) and the
                // null branch throws when it is unboxed. ofType builds
                // the null with the expression's own type.
                return ExprEval.ofType(ExpressionType.DOUBLE, null);
            }
            return ExprEval.of(dq);
        }
        if (spec.id() == 56) { // fractal_feedback_report
            feedbackReport(raw);
            return ExprEval.of(null);
        }
        if (spec.id() == 57) { // fractal_isolate_background
            isolateBackground(raw);
            return ExprEval.of(null);
        }
        if (spec.id() == 58) { // fractal_cycle_detect
            return ExprEval.ofString(cycleDetect(raw));
        }
        if (spec.id() == 16 || spec.id() == 17 || spec.id() == 18) {
            // The multimodal portfolio family: enterprise-gated, and
            // with their own entry points because they return a
            // candidates list rather than a scalar.
            return portfolioMultimodal(spec, raw);
        }
        return evaluate(spec, raw);
    }

    /**
     * The multimodal portfolio family.
     *
     * <p>Enterprise-gated: the three symbols live in the separately
     * licensed enterprise library, and they are OPTIONAL symbols there
     * -- an enterprise library built before them still loads for the
     * ledger surface. So a missing symbol is reported as "this
     * enterprise build does not have it", which is a different thing
     * from "the tier is not loaded".
     *
     * <p>The trailing arguments take the documented defaults:
     * eight restarts, an overlap threshold of 0.15 and a quality
     * fraction of 0.90; the Pareto front holds eight points.
     */
    private ExprEval portfolioMultimodal(FractalFn.Spec spec, Object[] raw)
    {
        if (enterprise == null || !enterprise.loaded()) {
            throw new IllegalStateException(
                    FractalSqlEnterprise.NOT_LOADED + " (" + spec.sqlName() + "). "
                            + "the multimodal portfolio search is a FractalSQL "
                            + "Enterprise feature");
        }
        final double[] mu  = toVector(raw[0]);
        final double[] cov = toVector(raw[1]);
        final int k = (int) toDouble(raw[2]);

        final String json;
        if (spec.id() == 17) {
            final boolean useObl = toDouble(raw[3]) != 0;
            final int diffusion = (int) toDouble(raw[4]);
            json = enterprise.portfolioMultimodalEx(
                    mu, cov, k, 8, 0.15, 0.90, 0L, useObl, diffusion);
        } else if (spec.id() == 18) {
            json = enterprise.portfolioMultimodalPareto(
                    mu, cov, k, 8, 8, 0L, false, 0);
        } else {
            json = enterprise.portfolioMultimodal(
                    mu, cov, k, 8, 0.15, 0.90, 0L);
        }
        if (json == null) {
            throw new IllegalStateException(
                    "fractalsql: " + spec.sqlName() + " is not available in "
                            + "this enterprise build (it needs a newer "
                            + "FractalSQL Enterprise core)");
        }
        return ExprEval.ofString(json);
    }

    /**
     * The enterprise tier: the QTL ledger and the CISO audit.
     *
     * <p>These are enterprise features. The ledger's blob format and
     * its truth/shadow semantics belong to the separately licensed
     * enterprise core, which the native tier loads at run time after
     * checking its detached Ed25519 signature. Without it the tier is
     * dormant and the gated calls say so -- the same shape the
     * every edition has.
     *
     * <p>{@code fractal_ledger_verify} is the exception: it reads the
     * port's own chain file rather than the core's, so it stays live
     * and an auditor can check the chain on a Community deployment.
     */
    private Object enterprise(int id, Object[] raw)
    {
        if (enterprise == null) {
            throw new IllegalStateException(
                    "fractalsql: the enterprise tier is not available on this node");
        }
        try {
            switch (id) {
                case 60:
                    return enterprise.flush();
                case 61:
                    return enterprise.load();
                case 62:
                    return enterprise.compact();
                case 63:
                    return enterprise.resetSoft();
                case 64:
                    return enterprise.resetHard();
                case 65:
                    return enterprise.truthCount();
                case 66:
                    return enterprise.shadowCount();
                case 67:
                    return enterprise.auditUnpack(asText(raw[0]));
                case 68:
                    return enterprise.verify();
                case 69:
                    // The general decision-audit record: a second,
                    // independent chain alongside kind=1's QTL blobs.
                    // The payload is stored verbatim, as text.
                    enterprise.auditLog(asText(raw[0]), asText(raw[1]));
                    return ExprEval.ofLong(1L);
                default:
                    throw new IllegalArgumentException("no such enterprise call");
            }
        } catch (IllegalArgumentException | IllegalStateException e) {
            // The dormancy message and the argument errors carry their
            // own text; wrapping them would bury it.
            throw e;
        } catch (Exception e) {
            throw new IllegalStateException("fractalsql: the ledger call failed: " + e.getMessage(), e);
        }
    }

    // -- the session tier ------------------------------------------------

    /** The node's core context, where the session's state lives. */
    private FractalSqlCore core()
    {
        if (core == null) {
            throw new IllegalStateException("fractalsql: the session tier is not available on this node");
        }
        return core;
    }

    /** Turn the divergence monitor on. */
    private void diversifyEnable()
    {
        final int rc = core().locked(h -> Native.diversifyEnable(h));
        if (rc != 0) {
            throw new IllegalStateException(
                    "fractalsql: could not enable the diversify monitor: " + core().locked(h -> Native.lastError(h)));
        }
        if (sessions != null) {
            sessions.setDiversifyEnabled(true);
        }
    }

    /** Turn it off. */
    private void diversifyDisable()
    {
        final int rc = core().locked(h -> Native.diversifyDisable(h));
        if (rc != 0) {
            throw new IllegalStateException(
                    "fractalsql: could not disable the diversify monitor: " + core().locked(h -> Native.lastError(h)));
        }
        if (sessions != null) {
            sessions.setDiversifyEnabled(false);
        }
    }

    /**
     * Tune the monitor.
     *
     * <p>The parameter document is a flat object holding any subset of {window_n, stall_threshold, repulsion_sigma,
     * repulsion_weight, max_shadows_considered, tail_buffer_cap}. The
     * values that are not named keep the core's own current setting,
     * which the extension reads back before setting.
     */
    private void diversifySetParams(String json)
    {
        int window = 5;
        double stall = 0.15;
        double sigma = Double.NaN;
        double weight = Double.NaN;
        int shadows = 64;
        int tail = 256;
        if (json != null && !json.trim().isEmpty()) {
            try {
                final JsonNode root = MAPPER.readTree(json);
                window = root.path("window_n").asInt(window);
                stall = root.path("stall_threshold").asDouble(stall);
                if (root.has("repulsion_sigma")) {
                    sigma = root.get("repulsion_sigma").asDouble();
                }
                if (root.has("repulsion_weight")) {
                    weight = root.get("repulsion_weight").asDouble();
                }
                shadows = root.path("max_shadows_considered").asInt(shadows);
                tail = root.path("tail_buffer_cap").asInt(tail);
            } catch (Exception e) {
                throw new IllegalArgumentException(
                        "fractalsql: could not read the diversify parameters: " + e.getMessage());
            }
        }
        // The core's defaults for the two repulsion knobs are
        // dimension-dependent, so an unnamed one is left at the core's
        // own value: NaN tells the shim to keep it.
        if (Double.isNaN(sigma)) {
            sigma = 0.0;
        }
        if (Double.isNaN(weight)) {
            weight = 0.0;
        }
        final int windowF = window;
        final double stallF = stall;
        final double sigmaF = sigma;
        final double weightF = weight;
        final int shadowsF = shadows;
        final int tailF = tail;
        final int rc = core().locked(h -> Native.diversifySetParams(
                h, windowF, stallF, sigmaF, weightF, shadowsF, tailF));
        if (rc != 0) {
            throw new IllegalStateException(
                    "fractalsql: could not set the diversify parameters: "
                            + core().locked(h -> Native.lastError(h)));
        }
    }

    /**
     * The Diversify inspector's snapshot: the last computed D_q,
     * whether the monitor is on, and its own overhead.
     */
    private String explainResult()
    {
        final double dq = core().locked(h -> Native.diversifyCurrentDq(h));
        final double p99 = core().locked(h -> Native.diversifyOverheadP99(h));
        return "{\"dq\":" + (Double.isNaN(dq) ? "null" : String.format("%.6f", dq))
                + ",\"diversify_enabled\":" + (diversifyEnabled() ? "true" : "false")
                + ",\"overhead_p99_us\":" + (Double.isNaN(p99) ? "null" : String.format("%.6f", p99))
                + "}";
    }

    /** Whether the divergence monitor is on. */
    private boolean diversifyEnabled()
    {
        return sessions != null && sessions.diversifyEnabled();
    }

    /**
     * The feedback report: the caller's verdict on a result.
     *
     * <p>The ledger records it; the session keeps the count.
     */
    private void feedbackReport(Object[] raw)
    {
        final long docId = (long) number(raw[0], 0);
        final String kind = asText(raw[1]);
        final double dwell = number(raw[2], 0);
        if (sessions == null) {
            throw new IllegalStateException("fractalsql: the session tier is not available on this node");
        }
        sessions.reportFeedback(docId, kind == null ? "positive" : kind, dwell);
        // The core's truth/shadow ledgers are what the enterprise
        // ledger seals: a feedback event that never reaches the core
        // can never be in the chain. This is the community core's own
        // symbol, so it works on a Community deployment too -- the
        // ledger that reads it back is what is enterprise-gated.
        if (enterprise != null && core != null) {
            enterprise.feedback(docId, kind == null ? "positive" : kind, dwell);
        }
    }

    /** The isolated background: a result the caller has set aside. */
    private void isolateBackground(Object[] raw)
    {
        final long docId = (long) number(raw[0], 0);
        if (sessions == null) {
            throw new IllegalStateException("fractalsql: the session tier is not available on this node");
        }
        sessions.isolate(docId);
    }

    /**
     * The cycle detector: Brent's algorithm over a stream of state
     * fingerprints.
     *
     * <p>The fingerprints arrive as a JSON array of hex strings, the
     * form {@code fractal_state_fingerprint} returns.
     */
    private String cycleDetect(Object[] raw)
    {
        final String json = asText(raw[0]);
        final int bits = (int) number(raw[1], 64);
        final int threshold = (int) number(raw[2], 3);
        final List<byte[]> fingerprints = new ArrayList<>();
        try {
            final JsonNode root = MAPPER.readTree(json == null ? "[]" : json);
            if (root.isArray()) {
                for (JsonNode node : root) {
                    fingerprints.add(hexToBytes(node.asText()));
                }
            }
        } catch (Exception e) {
            throw new IllegalArgumentException(
                    "fractalsql: fractal_cycle_detect() could not read the fingerprints: "
                            + e.getMessage());
        }
        // The core's own streaming Brent detector: it takes the
        // fingerprints one at a time and matches them within a
        // Hamming threshold, so near-identical states count as the
        // same state. Every edition calls this
        // same core function, so the answer is the core's rather than a
        // Java reimplementation of it.
        // The fingerprints and the width come from different arguments: each fingerprint must be exactly the
        // width's byte count, or the core would read past (or short of) it. The shim checks too.
        final int nBytes = ((bits > 0 ? bits : 64) + 7) / 8;
        for (byte[] fp : fingerprints) {
            if (fp.length != nBytes) {
                throw new IllegalArgumentException(
                        "fractalsql: fractal_cycle_detect() expects " + nBytes + "-byte fingerprints for "
                                + (bits > 0 ? bits : 64) + " bits, got " + fp.length);
            }
        }
        final byte[][] array = fingerprints.toArray(new byte[0][]);
        final String verdict = Native.cycleDetect(array, bits, threshold);
        if (verdict == null) {
            throw new IllegalStateException(
                    "fractalsql: the cycle detector could not be initialised");
        }
        return verdict;
    }

    /** A hex string as bytes. */
    private static byte[] hexToBytes(String hex)
    {
        final String s = hex == null ? "" : hex.trim();
        final int n = s.length() / 2;
        final byte[] out = new byte[n];
        for (int i = 0; i < n; i++) {
            out[i] = (byte) Integer.parseInt(s.substring(i * 2, i * 2 + 2), 16);
        }
        return out;
    }

    // -- the corpus tier ------------------------------------------------

    /**
     * Scout: the SFS over a whole corpus, with the walk turned off and
     * the final population returned, so it disperses across distinct
     * basins instead of collapsing into one.
     *
     * <p>The corpus arrives as an ARRAY -- {@code ARRAY_AGG} over the
     * column -- because a Druid aggregate cannot hold a growable
     * buffer, which is what the corpus is.
     */
    /** The feature store: fractal_store_morphology (78) and fractal_mine_topology_negatives (79). */
    private String featureStore(int id, Object[] raw)
    {
        if (index == null) {
            throw new IllegalStateException("fractalsql: the feature store is not available on this node");
        }
        try {
            if (id == 78) {
                if (raw[0] == null || raw[1] == null) {
                    return null;
                }
                return index.storeFeature((long) number(raw[0], -1), asText(raw[1]));
            }
            if (raw[0] == null || raw[1] == null) {
                return null;
            }
            return MAPPER.writeValueAsString(index.mineFeatures(asText(raw[0]), (int) number(raw[1], 10)));
        } catch (IllegalStateException | IllegalArgumentException e) {
            throw e;
        } catch (Exception e) {
            throw new IllegalStateException("fractalsql: the feature store failed: " + e.getMessage(), e);
        }
    }

    /**
     * The index tier: the IVF index and the indexed search.
     *
     * <p>These functions issue queries of their own -- they read a
     * datasource, and building an index writes one -- so they belong to
     * the service tier in practice (the extension's /fractalsql/index
     * endpoint); the SQL form is here so the names are the same
     * everywhere.
     */
    private String indexTier(int id, Object[] raw)
    {
        if (index == null) {
            throw new IllegalStateException("fractalsql: the index tier is not available on this node");
        }
        try {
            final java.util.Map<String, Object> answer;
            switch (id) {
            case 70: // fractal_index_create
                answer = index.create(asText(raw[0]), asText(raw[1]), asText(raw[2]));
                break;
            case 71: // fractal_index_rebuild
                answer = index.rebuild(asText(raw[0]), asText(raw[1]));
                break;
            case 72: // fractal_index_drop
                answer = index.drop(asText(raw[0]));
                break;
            case 73: // fractal_index_info
                answer = index.info(asText(raw[0]));
                break;
            case 74: // fractal_index_candidates
                answer = index.candidates(asText(raw[0]), asText(raw[1]), asText(raw[2]), asText(raw[3]));
                break;
            default: // fractal_search -- the indexed search
                answer = index.search(asText(raw[0]), asText(raw[1]), asText(raw[2]),
                        (int) number(raw[3], 10), asText(raw[4]));
                break;
            }
            return MAPPER.writeValueAsString(answer);
        } catch (IllegalStateException | IllegalArgumentException e) {
            throw e;
        } catch (Exception e) {
            throw new IllegalStateException("fractalsql: the index operation failed: " + e.getMessage(), e);
        }
    }

    private String searchExplore(Object[] raw)
    {
        final double[][] rows = corpusRows(raw[0]);
        if (rows == null || rows.length == 0) {
            throw new IllegalArgumentException(
                    "fractalsql: " + spec.sqlName() + "() needs a corpus of vectors");
        }
        final double[] query = VectorText.parseVector(asText(raw[1]));
        if (query == null) {
            throw new IllegalArgumentException(
                    "fractalsql: " + spec.sqlName() + "() could not parse the query vector");
        }
        final int dim = rows[0].length;
        if (query.length != dim) {
            throw new IllegalArgumentException(
                    "fractalsql: " + spec.sqlName() + "() query dimension " + query.length
                            + " does not match the corpus dimension " + dim);
        }
        final double[] flat = new double[rows.length * dim];
        for (int i = 0; i < rows.length; i++) {
            if (rows[i].length != dim) {
                throw new IllegalArgumentException(
                        "fractalsql: " + spec.sqlName() + "() found a vector of dimension "
                                + rows[i].length + " in a corpus of dimension " + dim);
            }
            System.arraycopy(rows[i], 0, flat, i * dim, dim);
        }
        final byte[] params = scoutParams(asText(raw[2]));
        return runSearch(flat, rows.length, dim, query, 1, params);
    }

    /**
     * The tunable form of the search: the SFS over the query alone,
     * with the iteration count, the population size and the diffusion
     * factor named by the caller.
     */
    private String searchDebug(Object[] raw)
    {
        final double[] query = VectorText.parseVector(asText(raw[0]));
        if (query == null) {
            throw new IllegalArgumentException(
                    "fractalsql: " + spec.sqlName() + "() could not parse the query vector");
        }
        final int iterations = (int) number(raw[1], 30);
        final int population = (int) number(raw[2], 50);
        final int diffusion = (int) number(raw[3], 2);
        final String params = "{\"iterations\":" + iterations
                + ",\"population_size\":" + population
                + ",\"diffusion_factor\":" + diffusion
                + ",\"walk\":0.5,\"no_corpus\":true}";
        // A one-row corpus holding the query itself routes the core
        // through real SFS convergence instead of the brute-force
        // retrieval path.
        return runSearch(query, 1, query.length, query, 1,
                params.getBytes(java.nio.charset.StandardCharsets.UTF_8));
    }

    /** The convergence result without the trajectory trace: {dim, population_size, best_point, best_fit}. */
    private String sfsConverge(Object[] raw)
    {
        final String full = searchDebug(raw);
        try {
            final com.fasterxml.jackson.databind.ObjectMapper om = new com.fasterxml.jackson.databind.ObjectMapper();
            final com.fasterxml.jackson.databind.JsonNode n = om.readTree(full);
            final java.util.Map<String, Object> out = new java.util.LinkedHashMap<>();
            for (String key : new String[]{"dim", "population_size", "best_point", "best_fit"}) {
                if (n.has(key)) {
                    out.put(key, om.convertValue(n.get(key), Object.class));
                } else if (key.equals("population_size")) {
                    out.put(key, (int) number(raw[2], 50));         // the core's no-corpus result does not echo it
                }
            }
            return om.writeValueAsString(out);
        } catch (Exception e) {
            return full;
        }
    }

    /** Run the core's SFS and return its result document. */
    private String runSearch(
            double[] corpus, int nRows, int dim, double[] query, int k, byte[] params)
    {
        NativeLoader.load();
        final long ctx = Native.newSovereign();
        if (ctx == 0) {
            throw new IllegalStateException("fractalsql: could not create a core context");
        }
        try {
            final byte[] result = Native.searchPtr(ctx, corpus, nRows, dim, query, dim, k, params);
            if (result == null) {
                final String err = Native.lastError(ctx);
                throw new IllegalStateException(
                        "fractalsql: the search failed: "
                                + (err == null || err.isEmpty() ? "(no detail)" : err));
            }
            return new String(result, java.nio.charset.StandardCharsets.UTF_8);
        } finally {
            Native.free(ctx);
        }
    }

    /**
     * The corpus's rows, as vectors.
     *
     * <p>The corpus may be one vector (an ARRAY column read directly)
     * or a nest of them (an {@code ARRAY_AGG} over the column), which
     * is how a Druid query hands a whole column to a function.
     */
    private static double[][] corpusRows(Object raw)
    {
        if (raw instanceof Object[]) {
            final Object[] arr = (Object[]) raw;
            if (arr.length == 0) {
                return null;
            }
            if (arr[0] instanceof Number) {
                final double[] one = FractalSearchAggregatorFactory.toDoubles(raw);
                return one == null ? null : new double[][]{one};
            }
            final List<double[]> rows = new ArrayList<>();
            for (Object o : arr) {
                final double[] row = FractalSearchAggregatorFactory.toDoubles(o);
                if (row == null) {
                    return null;
                }
                rows.add(row);
            }
            return rows.toArray(new double[0][]);
        }
        if (raw instanceof double[]) {
            return new double[][]{(double[]) raw};
        }
        return null;
    }

    /**
     * The core's Scout parameters, from the caller's JSON document.
     *
     * <p>The defaults are the core's, and the counts are
     * clamped on both sides: an unbounded population or iteration count
     * is in-process resource exhaustion.
     */
    private static byte[] scoutParams(String json)
    {
        int population = 50;
        int iterations = 15;
        int diffusion = 2;
        if (json != null && !json.trim().isEmpty()) {
            try {
                final JsonNode root = MAPPER.readTree(json);
                population = root.path("population_size").asInt(population);
                iterations = root.path("iterations").asInt(iterations);
                diffusion = root.path("diffusion_factor").asInt(diffusion);
            } catch (Exception e) {
                throw new IllegalArgumentException(
                        "fractalsql: could not read the search parameters: " + e.getMessage());
            }
        }
        population = Math.max(2, Math.min(population, 4096));
        iterations = Math.max(1, Math.min(iterations, 4096));
        diffusion = Math.max(1, Math.min(diffusion, 64));
        final String params = "{\"max_generation\":" + iterations
                + ",\"population_size\":" + population
                + ",\"maximum_diffusion\":" + diffusion
                + ",\"walk\":0,\"return_population\":true,\"bound_clipping\":true}";
        return params.getBytes(java.nio.charset.StandardCharsets.UTF_8);
    }

    /** An argument's number, or a fallback. */
    private static double number(Object raw, double fallback)
    {
        if (raw instanceof Number) {
            return ((Number) raw).doubleValue();
        }
        return fallback;
    }

    /**
     * The config/session tier: set a tuning value in a session.
     *
     * <p>The settings live in fractalsqld. Only the tuning keys can be set: the
     * daemon refuses the keys that decide which code runs, where traffic goes
     * and what credentials are used, because the session id is caller-supplied.
     */
    private String configSet(Object[] raw)
    {
        final String name = asText(raw[0]);
        final String value = asText(raw[1]);
        final String session = asText(raw[2]);
        if (session == null || session.isEmpty()) {
            throw new IllegalArgumentException("fractalsql: " + spec.sqlName() + "() needs a session id");
        }
        return daemonText("fractal_config_set", name, value, FractalSqlDaemon.sessionId(session));
    }

    /**
     * The config/session tier: read a setting's effective value.
     *
     * <p>The session's override wins over the operator's value; a secret is redacted.
     */
    private String configGet(Object[] raw)
    {
        return daemonText("fractal_config_get", asText(raw[0]), FractalSqlDaemon.sessionId(asText(raw[1])));
    }

    /**
     * The config/session tier: drop a session's overrides.
     *
     * @return how many overrides the session held
     */
    private long configReset(Object[] raw)
    {
        final String session = asText(raw[0]);
        if (session == null || session.isEmpty()) {
            throw new IllegalArgumentException("fractalsql: " + spec.sqlName() + "() needs a session id");
        }
        return Long.parseLong(daemonText("fractal_config_reset", FractalSqlDaemon.sessionId(session)));
    }

    /** The config/session tier: the session's own overrides, as a JSON object. */
    private String configList(Object[] raw)
    {
        final String session = asText(raw[0]);
        if (session == null || session.isEmpty()) {
            throw new IllegalArgumentException("fractalsql: " + spec.sqlName() + "() needs a session id");
        }
        return daemonText("fractal_config_list", FractalSqlDaemon.sessionId(session));
    }

    /** The config/session tier: every setting the daemon knows, so a caller can discover the surface. */
    private String configKeys()
    {
        return daemonText("fractal_config_keys");
    }

    private String daemonText(String function, Object... args)
    {
        if (daemon == null) {
            throw new IllegalStateException("fractalsql: the config tier is not available on this node");
        }
        try {
            return daemon.client().call(function, args).text();
        } catch (FsqClient.FsqException e) {
            throw new IllegalStateException("fractalsql: " + function + " failed: "
                    + (e.getMessage().isEmpty() ? "the daemon refused the call" : e.getMessage()));
        }
    }

    /** The extension's own version, from its jar; the core's version when run outside a jar. */
    private static String extensionVersion()
    {
        final String v = FractalExpr.class.getPackage().getImplementationVersion();
        return v != null ? v : Native.version();
    }

    /** An argument's text, or null. */
    private static String asText(Object raw)
    {
        return raw == null ? null : raw.toString();
    }

    @Override
    protected Expr.BindingAnalysis supplyAnalyzeInputs()
    {
        final Expr.BindingAnalysis base = Expr.BindingAnalysis.collectExprs(getArgs());
        final Set<Expr> arrayArgs = new HashSet<>();
        for (int i = 0; i < spec.arity(); i++) {
            if (spec.isArrayArg(i)) {
                arrayArgs.add(getArgs().get(i));
            }
        }
        return base
                .withArrayArguments(arrayArgs)
                .withArrayInputs(!arrayArgs.isEmpty());
    }

    @Override
    public ExpressionType getOutputType(Expr.InputBindingInspector inspector)
    {
        switch (spec.retType()) {
            case DOUBLE:
                return ExpressionType.DOUBLE;
            case BIGINT:
                return ExpressionType.LONG;
            default:
                return ExpressionType.STRING;
        }
    }

    // -- evaluation ---------------------------------------------------

    /** The raw value of an evaluated argument. */
    private static Object valueOf(ExprEval eval)
    {
        if (eval == null) {
            return null;
        }
        if (eval.isArray()) {
            return eval.asArray();
        }
        return eval.value();
    }

    /**
     * Run a function over already-evaluated arguments.
     *
     * <p>Split out from {@link #eval} so the unit tests can drive it
     * without a Druid binding.
     */
    static ExprEval evaluate(FractalFn.Spec spec, Object[] raw)
    {
        final int id = spec.id();

        // Place each argument in its slot.
        final double[][] arrays = new double[3][];
        final double[] scalars = new double[3];
        final int[] slots = spec.argSlots();
        for (int i = 0; i < raw.length; i++) {
            final int slot = slots[i];
            if (slot < 3) {
                arrays[slot] = toVector(raw[i]);
            } else {
                scalars[slot - 3] = toDouble(raw[i]);
            }
        }

        final double[] a = arrays[0];
        final double[] b = arrays[1];
        final double[] c = arrays[2];

        // The functions that are pure Java never reach the core.
        if (spec.isJavaOnly()) {
            switch (id) {
                case 35: // vector_to_json
                    return ExprEval.ofString(toJsonArray(a));
                case 36: { // vector_from_text
                    final double[] v = VectorText.parseVector(raw[0] == null ? null : raw[0].toString());
                    return ExprEval.ofString(v == null ? null : toJsonArray(v));
                }
                default: { // fractal_vector(dim)
                    final int dim = (int) toDouble(raw[0]);
                    if (dim <= 0 || dim > 1 << 16) {
                        return ExprEval.of((String) null);
                    }
                    return ExprEval.ofString(toJsonArray(new double[dim]));
                }
            }
        }

        // The functions whose core call produces a vector go through the
        // vector entry point. The result comes back as the core's JSON
        // text form -- the core's convention, and
        // the one that survives Druid's expression layer intact.
        if (spec.isVectorResult()) {
            final double[] v = Native.callVec(
                    id,
                    a, a == null ? 0 : a.length,
                    b, b == null ? 0 : b.length,
                    c, c == null ? 0 : c.length,
                    scalars[0], scalars[1], scalars[2]);
            return ExprEval.ofString(v == null ? null : toJsonArray(v));
        }

        final double[] out = new double[FractalFn.OUT_SIZE];
        final double result = Native.callFn(
                id,
                a, a == null ? 0 : a.length,
                b, b == null ? 0 : b.length,
                c, c == null ? 0 : c.length,
                scalars[0], scalars[1], scalars[2],
                out);

        switch (id) {
            case 1: // dimension_dfa
                return ExprEval.of(result);
            case 3: // dimension_boxcount
                return ExprEval.of(result);
            case 15: // state_distance
                return ExprEval.of(result);
            case 20: // vector_l2_distance
            case 21: // vector_l2_squared
            case 22: // vector_cosine_distance
            case 23: // vector_cosine_similarity
            case 24: // vector_negative_inner_product
            case 25: // vector_norm
            case 26: // vector_lp_distance
                return ExprEval.of(result);
            case 27: // vector_hamming_distance
            case 34: // vector_dims
                // Counts, not measurements: the registry types
                // both as INT.
                return ExprEval.ofLong((long) result);
            case 2: // dimension_drift
                return ExprEval.ofString(new FractalJson()
                        .num("drift", result)
                        .num("recent_alpha", out[0])
                        .num("baseline_alpha", out[1])
                        .build());
            case 10: { // state_fingerprint -> the fingerprint, as hex
                final int nBytes = (int) result;
                final StringBuilder hex = new StringBuilder(nBytes * 2);
                for (int i = 0; i < nBytes && (1 + i) < out.length; i++) {
                    hex.append(String.format("%02x", (int) out[1 + i]));
                }
                return ExprEval.ofString(hex.toString());
            }
            case 4: { // change_point_detect
                final int count = (int) result;
                return ExprEval.ofString(new FractalJson()
                        .num("count", count)
                        .arrFrom("indices", out, count, 0)
                        .build());
            }
            case 5: { // periodogram
                final int n = (int) out[0];
                final FractalJson json = new FractalJson()
                        .num("peak_frequency", result)
                        .num("peak_power", n > 0 ? out[1 + n] : Double.NaN)
                        .num("n_peaks", n)
                        .arrFrom("freqs", out, n, 1)
                        .arrFrom("power", out, n, 1 + n);
                final StringBuilder peaks = new StringBuilder("[");
                for (int i = 0; i < n; i++) {
                    if (i > 0) {
                        peaks.append(',');
                    }
                    peaks.append("{\"frequency\":").append(out[1 + i])
                            .append(",\"power\":").append(out[1 + n + i]).append('}');
                }
                peaks.append(']');
                json.raw("peaks", peaks.toString());
                return ExprEval.ofString(json.build());
            }
            case 6: { // spectrogram_entropy
                final int n = (int) out[0];
                double min = Double.POSITIVE_INFINITY;
                double max = Double.NEGATIVE_INFINITY;
                for (int i = 0; i < n; i++) {
                    final double v = out[1 + i];
                    min = Math.min(min, v);
                    max = Math.max(max, v);
                }
                return ExprEval.ofString(new FractalJson()
                        .num("mean_entropy", result)
                        .num("n_frames", n)
                        .num("min_entropy", n > 0 ? min : Double.NaN)
                        .num("max_entropy", n > 0 ? max : Double.NaN)
                        .arrFrom("frames", out, n, 1)
                        .build());
            }
            case 7: // morphological_complexity
                return ExprEval.ofString(new FractalJson()
                        .num("dimension", result)
                        .num("lacunarity", out[0])
                        .build());
            case 8:   // optimize_portfolio
            case 14: { // optimize_portfolio_ex
                final int n = (int) out[0];
                return ExprEval.ofString(new FractalJson()
                        .num("sharpe", result)
                        .arrFrom("weights", out, n, 1)
                        .build());
            }
            case 77: { // optimize_subset
                if (Double.isNaN(result) || out[0] <= 0) {
                    throw new IllegalArgumentException("fractalsql: fractal_optimize_subset: invalid or infeasible input (equal-length vectors of at most 255 "
                            + "items, upper_bounds in [0, 1], k at most the item count, and the k largest upper bounds adding up to at least 1)");
                }
                final int n = (int) out[0];
                return ExprEval.ofString(new FractalJson()
                        .num("score", result)
                        .arrFrom("weights", out, n, 1)
                        .build());
            }
            case 9: { // tda_persistence_diagram
                final int n = (int) out[0];
                final StringBuilder bars = new StringBuilder("[");
                for (int i = 0; i < n; i++) {
                    if (i > 0) {
                        bars.append(',');
                    }
                    bars.append("{\"birth\":").append(out[1 + 2 * i])
                            .append(",\"death\":").append(out[2 + 2 * i]).append('}');
                }
                bars.append(']');
                return ExprEval.ofString(new FractalJson()
                        .num("betti1", result)
                        .num("n_bars", n)
                        .raw("bars", bars.toString())
                        .build());
            }
            case 11: // vascular_network
                return ExprEval.ofString(new FractalJson()
                        .num("mean_tortuosity", result)
                        .num("branch_density", out[0])
                        .num("fractal_dimension", out[1])
                        .build());
            case 12: // cortical_folding
                return ExprEval.ofString(new FractalJson()
                        .num("mesh_area", result)
                        .num("hull_area", out[0])
                        .num("gyrification_index", out[1])
                        .build());
            case 13: // nerve_plexus_metric
                return ExprEval.ofString(new FractalJson()
                        .num("fiber_length_density", result)
                        .num("branch_density", out[0])
                        .num("fractal_dimension", out[1])
                        .build());
            case 33: { // vector_quantize_int8
                final int n = (int) out[1];
                return ExprEval.ofString(new FractalJson()
                        .num("scale", out[0])
                        .arrFrom("codes", out, n, 2)
                        .build());
            }
            default:
                return ExprEval.of(result);
        }
    }

    /** Shape a double array as the core's JSON text form. */
    private static String toJsonArray(double[] v)
    {
        if (v == null) {
            return null;
        }
        final StringBuilder sb = new StringBuilder("[");
        for (int i = 0; i < v.length; i++) {
            if (i > 0) {
                sb.append(',');
            }
            sb.append(v[i]);
        }
        return sb.append(']').toString();
    }

    /**
     * Coerce an argument to a vector.
     *
     * <p>Accepts a Druid array value, a list, a primitive array, or the
     * text form the reference extension took.
     */
    static double[] toVector(Object raw)
    {
        if (raw == null) {
            return null;
        }
        if (raw instanceof double[]) {
            return (double[]) raw;
        }
        if (raw instanceof float[]) {
            final float[] f = (float[]) raw;
            final double[] out = new double[f.length];
            for (int i = 0; i < f.length; i++) {
                out[i] = f[i];
            }
            return out;
        }
        if (raw instanceof int[]) {
            final int[] a = (int[]) raw;
            final double[] out = new double[a.length];
            for (int i = 0; i < a.length; i++) {
                out[i] = a[i];
            }
            return out;
        }
        if (raw instanceof long[]) {
            final long[] a = (long[]) raw;
            final double[] out = new double[a.length];
            for (int i = 0; i < a.length; i++) {
                out[i] = a[i];
            }
            return out;
        }
        if (raw instanceof Object[]) {
            final Object[] a = (Object[]) raw;
            final double[] out = new double[a.length];
            for (int i = 0; i < a.length; i++) {
                final Double d = toDoubleOrNull(a[i]);
                if (d == null) {
                    return null;
                }
                out[i] = d;
            }
            return out;
        }
        if (raw instanceof List) {
            final List<?> a = (List<?>) raw;
            final double[] out = new double[a.size()];
            for (int i = 0; i < a.size(); i++) {
                final Double d = toDoubleOrNull(a.get(i));
                if (d == null) {
                    return null;
                }
                out[i] = d;
            }
            return out;
        }
        if (raw instanceof String) {
            return VectorText.parseVector((String) raw);
        }
        if (raw instanceof Number) {
            return new double[]{((Number) raw).doubleValue()};
        }
        return null;
    }

    private static Double toDoubleOrNull(Object o)
    {
        if (o == null) {
            return null;
        }
        if (o instanceof Number) {
            return ((Number) o).doubleValue();
        }
        try {
            return Double.parseDouble(o.toString());
        } catch (NumberFormatException e) {
            return null;
        }
    }

    /** Coerce an argument to a number. */
    static double toDouble(Object raw)
    {
        if (raw == null) {
            return Double.NaN;
        }
        if (raw instanceof Number) {
            return ((Number) raw).doubleValue();
        }
        if (raw instanceof Boolean) {
            return ((Boolean) raw) ? 1.0 : 0.0;
        }
        try {
            return Double.parseDouble(raw.toString());
        } catch (NumberFormatException e) {
            return Double.NaN;
        }
    }
}
