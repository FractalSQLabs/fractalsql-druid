/*
 * SPDX-License-Identifier: Apache-2.0
 * Copyright 2026 Daniel Gardiner d/b/a FractalSQLabs
 */
package com.fractalsqlabs.fractalsql.druid;

import com.google.inject.Inject;
import org.apache.druid.math.expr.Expr;
import org.apache.druid.math.expr.ExprMacroTable;

import java.util.List;

/**
 * The native expression macro for one {@code fractal_*} function.
 *
 * <p>Registering a macro puts the function into Druid's expression
 * language, which is what lets it be used in a projection, a filter or
 * a virtual column -- the same places the reference extension's scalar
 * functions worked.
 *
 * <p>Each function gets a one-line subclass naming its registry entry;
 * the behaviour is shared.
 */
public abstract class FractalExprMacro implements ExprMacroTable.ExprMacro {

    /**
     * The node's configuration, for the config/session tier.
     *
     * <p>Injected into the base class, so every macro -- generated or
     * hand-written -- carries it: the config functions need the
     * allow/deny list, and nothing else does.
     */
    @Inject
    private FractalSqlConfig config;

    /** The session overlay, for the config/session tier. */
    @Inject
    private FractalSqlSessions sessions;

    /**
     * The node's core context, for the session tier.
     *
     * <p>The Diversify monitor and the search's refinement share it,
     * so {@code fractal_diversify_enable()} and the search that follows
     * it talk to the same state.
     */
    @Inject
    private FractalSqlCore core;

    /** The enterprise tier, for the ledger and the CISO audit. */
    @Inject
    private FractalSqlEnterprise enterprise;

    /** The connection to fractalsqld, for the config tier. */
    @Inject
    private FractalSqlDaemon daemon;

    /** The connection to fractalsqld. */
    protected FractalSqlDaemon daemon()
    {
        return daemon;
    }

    /** The node's configuration. */
    protected FractalSqlConfig config()
    {
        return config;
    }

    /** The session overlay. */
    protected FractalSqlSessions sessions()
    {
        return sessions;
    }

    /** The node's core context. */
    protected FractalSqlCore core()
    {
        return core;
    }

    /** The enterprise tier, for the ledger and the CISO audit. */
    protected FractalSqlEnterprise enterprise()
    {
        return enterprise;
    }

    /** The registry entry for this function. */
    protected abstract FractalFn.Spec spec();

    @Override
    public String name()
    {
        return spec().nativeName();
    }

    @Override
    public Expr apply(List<Expr> args)
    {
        final FractalFn.Spec s = spec();
        if (args.size() != s.arity()) {
            throw new IllegalArgumentException(
                    "fractalsql: " + s.sqlName() + "() takes " + s.arity()
                            + " arguments, got " + args.size());
        }
        return create(s, args);
    }

    /**
     * The expression this macro evaluates.
     *
     * <p>Overridden by the macros that need the reasoning tier, which
     * carries a bridge the rest do not.
     */
    protected FractalExpr create(FractalFn.Spec spec, List<Expr> args)
    {
        return new FractalExpr(this, spec, args, null, config, sessions, core, enterprise, daemon);
    }
}
