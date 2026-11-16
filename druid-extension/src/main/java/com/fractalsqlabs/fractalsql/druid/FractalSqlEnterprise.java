/*
 * SPDX-License-Identifier: Apache-2.0
 * Copyright 2026 Daniel Gardiner d/b/a FractalSQLabs
 */
package com.fractalsqlabs.fractalsql.druid;

import org.apache.druid.java.util.common.logger.Logger;
import com.google.inject.Inject;
import com.google.inject.Singleton;

import java.util.LinkedHashMap;
import java.util.Map;

/**
 * The enterprise tier: the QTL ledger and the CISO audit.
 *
 * <p>The ledger is an append-only chain: each record carries the epoch, the
 * document it is about, the signal it carries (a confirmed truth, a rejected
 * shadow) and a link to the record before it. A rewritten or removed record
 * breaks every link after it, so the chain is tamper-evident.
 *
 * <p>The tier runs in fractalsqld, beside the broker, so every Druid process that uses
 * a daemon shares its ledger and its licensed library. A cluster with a daemon per host
 * has one ledger per host. The daemon loads the enterprise
 * library lazily, after checking its detached Ed25519 signature. Without the
 * library the tier is dormant: the gated functions say so, and the rest of the
 * extension carries on. {@link #verify()} is the exception: it reads the chain
 * file, so an auditor can use it either way.
 */
@Singleton
public class FractalSqlEnterprise {

    /** What every gated function reports when the tier is dormant. */
    public static final String NOT_LOADED =
            "fractalsql: enterprise tier not loaded";

    private static final String NOT_LOADED_HINT =
            "the QTL ledger and the CISO audit are FractalSQL Enterprise "
                    + "features. Install the enterprise core library where "
                    + "fractalsqld runs and set enterprise_lib in its "
                    + "configuration, or contact your vendor for FractalSQL Enterprise.";

    private static final long SESSION = FractalSqlDaemon.NODE_SESSION;

    private final FractalSqlConfig config;
    private final FractalSqlDaemon daemon;

    /** Set once the destructive operations have been latched. */
    private volatile boolean destructiveLocked;

    @Inject
    public FractalSqlEnterprise(FractalSqlConfig config, FractalSqlDaemon daemon)
    {
        this.config = config;
        this.daemon = daemon;
    }

    private FsqClient.Result call(String function, Object... args)
    {
        try {
            return daemon.client().call(function, args);
        } catch (FsqClient.FsqException e) {
            if (e.status() == FsqClient.ERR_CORE) {
                throw new IllegalStateException(NOT_LOADED + " (" + function + "). " + NOT_LOADED_HINT);
            }
            throw new IllegalStateException("fractalsql: " + function + " failed: "
                    + (e.getMessage().isEmpty() ? "status " + e.status() : e.getMessage()));
        }
    }

    /** Applies the read-only posture, once the daemon is reachable. */
    private void applyPosture()
    {
        if (!destructiveLocked && config.operatorBool("ledger.read_only")) {
            lockDestructive();
        }
    }

    /** True once the daemon has loaded the enterprise core and resolved its symbols. */
    public boolean loaded()
    {
        try {
            daemon.client().call("fractal_ledger_truth_count", SESSION);
            return true;
        } catch (FsqClient.FsqException e) {
            return false;
        }
    }

    /** The enterprise library's path, as the daemon has it, or null. */
    public String libraryPath()
    {
        return daemon.textOrNull("fractal_config_get", "enterprise_lib", SESSION);
    }

    /** The chain file's path, as the daemon has it, or null. */
    public String ledgerPath()
    {
        return daemon.textOrNull("fractal_config_get", "enterprise_ledger_path", SESSION);
    }

    // -- the gated surface ---------------------------------------------

    /**
     * Latch the destructive operations, one way.
     *
     * <p>Once latched, the ledger's mutating operations refuse for the life of
     * the node. A node that has latched does not unlatch.
     *
     * @return true when this call latched it, false when it was already latched
     */
    public boolean lockDestructive()
    {
        if (destructiveLocked) {
            return false;
        }
        destructiveLocked = true;
        try {
            daemon.client().call("fractal_lock_destructive", SESSION);
        } catch (FsqClient.FsqException e) {
            // The latch also holds here, so a daemon that is down or dormant does not matter.
        }
        return true;
    }

    /** True once the destructive operations have been latched. */
    public boolean destructiveLocked()
    {
        return destructiveLocked;
    }

    private void refuseIfDestructiveLocked()
    {
        applyPosture();
        if (destructiveLocked) {
            throw new IllegalStateException(
                    "fractalsql: the ledger's destructive operations are locked on this node");
        }
    }

    private static final Logger log = new Logger(FractalSqlEnterprise.class);

    /**
     * The gate of the operations that destroy ledger records (compact, reset): refused unless the operator has switched them
     * on with {@code ledger.allow_destructive}, and always refused once the one-way latch is set. Every attempt is logged,
     * allowed or refused, so a destroyed chain is never silent (SECURITY_AUDIT.md 3.12). Who may run SQL at all is Druid's
     * own authorisation to decide; this is the extension's own default-safe posture beneath it.
     */
    private void requireDestructiveAllowed(String operation)
    {
        applyPosture();
        if (destructiveLocked) {
            log.warn("fractalsql: %s refused: the ledger's destructive operations are latched on this node", operation);
            throw new IllegalStateException(
                    "fractalsql: the ledger's destructive operations are locked on this node");
        }
        if (!config.operatorBool("ledger.allow_destructive")) {
            log.warn("fractalsql: %s refused: druid.fractalsql.ledger.allow_destructive is not set", operation);
            throw new IllegalStateException(
                    "fractalsql: " + operation + " destroys ledger records and is disabled; an operator enables it with "
                            + "druid.fractalsql.ledger.allow_destructive=true");
        }
        log.warn("fractalsql: %s allowed (ledger.allow_destructive is set)", operation);
    }

    /** Seal the core's ledgers into the chain. */
    public long flush()
    {
        refuseIfDestructiveLocked();
        call("fractal_ledger_flush", SESSION);
        return truthCount() + shadowCount();
    }

    /** Rehydrate the core's ledgers from the chain. */
    public long load()
    {
        call("fractal_ledger_load", SESSION);
        return truthCount() + shadowCount();
    }

    /** Compact the chain. */
    public long compact()
    {
        requireDestructiveAllowed("compact");
        call("fractal_ledger_compact", SESSION);
        return recordCount(1);
    }

    /** Drop the shadow ledger; keep the truth ledger. */
    public long resetSoft()
    {
        requireDestructiveAllowed("reset_soft");
        final long before = shadowCount();
        call("fractal_ledger_reset_soft", SESSION);
        return before;
    }

    /** Drop both ledgers and restart the epoch. */
    public long resetHard()
    {
        requireDestructiveAllowed("reset_hard");
        final long before = truthCount() + shadowCount();
        call("fractal_ledger_reset_hard", SESSION);
        return before;
    }

    /** How many records the chain holds. */
    public long recordCount(int kind)
    {
        final String json = verify();
        final int at = json.indexOf("\"rows_verified\":");
        if (at < 0) {
            return 0;
        }
        int end = at + "\"rows_verified\":".length();
        final int start = end;
        while (end < json.length() && Character.isDigit(json.charAt(end))) {
            end++;
        }
        return end > start ? Long.parseLong(json.substring(start, end)) : 0;
    }

    /** How many confirmed truths the ledger holds. */
    public long truthCount()
    {
        return call("fractal_ledger_truth_count", SESSION).asLong();
    }

    /** How many rejected shadows the ledger holds. */
    public long shadowCount()
    {
        return call("fractal_ledger_shadow_count", SESSION).asLong();
    }

    /**
     * Decode a QTL blob into the CISO event log.
     *
     * @param blob the blob the ledger sealed; empty means the last blob the ledger sealed
     */
    public String auditUnpack(String blob)
    {
        if (blob == null) {
            throw new IllegalArgumentException(
                    "fractalsql: fractal_audit_unpack needs a blob to decode, or '' for the last one the ledger sealed");
        }
        final boolean latest = blob.trim().isEmpty();
        final String json = call("fractal_audit_unpack", latest ? "" : blob).text();
        if (json == null) {
            throw new IllegalStateException(latest
                    ? "fractalsql: the chain holds no sealed blob to decode yet; fractal_ledger_flush seals one"
                    : "fractalsql: the audit blob could not be decoded");
        }
        return json;
    }

    // -- live without the enterprise library ---------------------------

    /**
     * The forensic walk over the chain file.
     *
     * <p>Not gated: an auditor can check the chain whether or not the licence is installed.
     *
     * @return {@code {"ok":true,"rows_verified":N}} or
     *         {@code {"ok":false,"first_failure_id":N,"reason":"..."}}
     */
    public String verify()
    {
        return verify(1);
    }

    /** As {@link #verify()}, for a chain kind: 1 is the QTL chain, 2 the decision-audit chain. */
    public String verify(int kind)
    {
        final String json = daemon.textOrNull("fractal_ledger_verify", SESSION, (long) kind);
        return json != null ? json
                : "{\"ok\":false,\"first_failure_id\":0,\"reason\":\"the ledger could not be read\"}";
    }

    /**
     * Append one entry to the decision-audit chain.
     *
     * @param entryType what kind of decision this is
     * @param payload   the decision itself, as a JSON document
     */
    public void auditLog(String entryType, String payload)
    {
        refuseIfDestructiveLocked();
        call("fractal_audit_log", entryType, payload, SESSION, null);
    }

    /** Report one engagement event into the truth and shadow ledgers, which {@link #flush()} seals. */
    public void feedback(long docId, String kind, double dwellMs)
    {
        call("fractal_feedback_report", SESSION, docId, kind, (long) dwellMs);
    }

    // -- the multimodal portfolio search ---------------------------------

    private static String csv(double[] v)
    {
        final StringBuilder sb = new StringBuilder();
        for (int i = 0; i < v.length; i++) {
            if (i > 0) {
                sb.append(',');
            }
            sb.append(v[i]);
        }
        return sb.toString();
    }

    /** A portfolio result; a NULL answer means the enterprise core is not loaded. */
    private String portfolioResult(FsqClient.Result r)
    {
        final String text = r.text();
        if (text == null && !loaded()) {
            throw new IllegalStateException(NOT_LOADED + " (the multimodal portfolio search). " + NOT_LOADED_HINT);
        }
        return text;
    }

    private static String diffusionName(int mode)
    {
        return mode == 1 ? "levy" : "gaussian";
    }

    /** Several diverse portfolios, best Sharpe first, as JSON. */
    public String portfolioMultimodal(double[] mu, double[] cov, int k, int restarts,
            double overlap, double quality, long seed)
    {
        return portfolioResult(call("fractal_optimize_portfolio_multimodal", csv(mu), csv(cov), (long) k, (long) restarts,
                overlap, quality, seed));
    }

    /** As {@link #portfolioMultimodal}, with the opposition-based and Levy-flight options. */
    public String portfolioMultimodalEx(double[] mu, double[] cov, int k, int restarts,
            double overlap, double quality, long seed, boolean useObl, int diffusion)
    {
        return portfolioResult(call("fractal_optimize_portfolio_multimodal_ex", csv(mu), csv(cov), (long) k, (long) restarts,
                overlap, quality, seed, useObl ? 1L : 0L, diffusionName(diffusion)));
    }

    /** The Pareto front of risk and return, as JSON. */
    public String portfolioMultimodalPareto(double[] mu, double[] cov, int k, int restarts,
            int maxFront, long seed, boolean useObl, int diffusion)
    {
        return portfolioResult(call("fractal_optimize_portfolio_multimodal_pareto", csv(mu), csv(cov), (long) k,
                (long) restarts, (long) maxFront, seed, useObl ? 1L : 0L, diffusionName(diffusion)));
    }

    /** The tier's status, for the service endpoint. */
    public Map<String, Object> status()
    {
        final Map<String, Object> out = new LinkedHashMap<>();
        out.put("loaded", loaded());
        out.put("library", libraryPath());
        out.put("ledger_path", ledgerPath());
        out.put("edition", daemon.textOrNull("fractal_edition"));
        out.put("destructive_locked", destructiveLocked);
        return out;
    }
}
