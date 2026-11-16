/*
 * SPDX-License-Identifier: Apache-2.0
 * Copyright 2026 Daniel Gardiner d/b/a FractalSQLabs
 */
package com.fractalsqlabs.fractalsql.druid;

import com.google.inject.Inject;
import org.apache.druid.math.expr.Expr;

import java.util.List;

/**
 * The native expression macro for {@code FRACTAL_REASON}.
 *
 * <p>Hand-written rather than generated, because it needs the reasoning
 * bridge — the two plugin instances the cognition tier talks through.
 */
public class FractalReasonExprMacro extends FractalExprMacro {

    private final ReasoningBridge bridge;

    /** For the unit tests, which have no provider to talk to. */
    public FractalReasonExprMacro()
    {
        this.bridge = null;
    }

    @Inject
    public FractalReasonExprMacro(ReasoningBridge bridge)
    {
        this.bridge = bridge;
    }

    @Override
    protected FractalFn.Spec spec()
    {
        return FractalFn.byName("FRACTAL_REASON");
    }

    @Override
    protected FractalExpr create(FractalFn.Spec spec, List<Expr> args)
    {
        return new FractalExpr(this, spec, args, bridge, config(), sessions(), core(), enterprise(), daemon());
    }
}
