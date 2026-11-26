/*
 * SPDX-License-Identifier: Apache-2.0
 * Copyright 2026 Daniel Gardiner d/b/a FractalSQLabs
 */
package com.fractalsqlabs.fractalsql.druid;

import com.fractalsqlabs.fractalsql.druid.fn.FractalFnBindings;
import com.google.inject.Binder;
import org.apache.druid.guice.ExpressionModule;
import org.apache.druid.guice.Jerseys;
import org.apache.druid.initialization.DruidModule;
import org.apache.druid.math.expr.ExprMacroTable;
import org.apache.druid.sql.calcite.expression.SqlOperatorConversion;
import org.apache.druid.sql.guice.SqlBindings;

import java.util.List;

/**
 * The Druid extension entry point.
 *
 * <p>Registered by Druid through
 * {@code META-INF/services/org.apache.druid.initialization.DruidModule}
 * and loaded when the JAR is dropped into an extensions directory and
 * named in {@code druid.extensions.loadList}.
 *
 * <p>What it registers:
 * <ul>
 *   <li>the {@code fractal_*} functions -- each one a native
 *       expression macro (so the function works in a projection, a
 *       filter or a virtual column) bound to a SQL operator;</li>
 *   <li>{@link FractalSearchSqlAggregator} -- the {@code fractal_search}
 *       SQL aggregate, which is the one function that has to scan a
 *       column rather than score a single row.</li>
 * </ul>
 *
 * <p><b>Versioning caveat.</b> {@code SqlBindings} and
 * {@code ExpressionModule.addExprMacro} are not part of Druid's
 * documented, versioned extension surface -- the "Creating extensions"
 * page does not list SQL functions among the supported targets, and
 * Druid's versioning policy treats un-annotated interfaces as internal
 * and liable to change between patch releases. The mechanism is the one
 * Apache's own in-tree extensions use (the DataSketches extension
 * registers its SQL functions exactly this way), so it works, but this
 * extension is version-locked to a Druid release range (see
 * docs/druid-integration.md, "Known limits").
 */
public class FractalSqlDruidModule implements DruidModule {

    @Override
    public void configure(Binder binder) {
        // The node's configuration, read from druid.fractalsql.* in the
        // runtime properties. It carries the allow/deny split between
        // what an operator owns and what a request may change.
        binder.bind(FractalSqlConfig.class);
        binder.bind(FractalSqlDaemon.class);
        binder.bind(ReasoningBridge.class);
        binder.bind(FractalSqlService.class);
        binder.bind(FractalSqlAgents.class);
        // The session overlay: the config/session tier's per-session
        // values.
        binder.bind(FractalSqlSessions.class);
        binder.bind(FractalSqlCore.class);
        // The vectorizer tier: the registry and the queue.
        binder.bind(FractalSqlVectorizer.class);
        // The index tier: the IVF index and the datasource that holds it.
        binder.bind(FractalSqlIndex.class);
        // The enterprise tier: the QTL ledger and the CISO audit.
        binder.bind(FractalSqlEnterprise.class);

        // The service tier: the operations that cannot be SQL functions,
        // because they need to issue queries, call a provider, or hold
        // state. Druid's own Jersey binding is the documented way for an
        // extension to add an endpoint.
        Jerseys.addResource(binder, FractalSqlResource.class);

        // The SQL surface: a Calcite aggregate bound to a native Druid
        // aggregator, so the work runs on the data nodes rather than at
        // the broker.
        SqlBindings.addAggregator(binder, FractalSearchSqlAggregator.class);

        // The function surface: a native expression macro per
        // function, and the SQL binding that turns a SQL call into a
        // call of that macro.
        for (Class<? extends ExprMacroTable.ExprMacro> macro : FractalFnBindings.MACROS) {
            ExpressionModule.addExprMacro(binder, macro);
        }
        // The reasoning functions carry the bridge, so their macros are
        // hand-written rather than generated.
        ExpressionModule.addExprMacro(binder, FractalReasonExprMacro.class);
        ExpressionModule.addExprMacro(binder, FractalEmbedExprMacro.class);
        for (Class<? extends SqlOperatorConversion> conversion : FractalFnBindings.CONVERSIONS) {
            SqlBindings.addOperatorConversion(binder, conversion);
        }
    }

    /**
     * Register the aggregator factory's JSON subtype, so the broker can
     * deserialise it when it hands the native query to the data nodes.
     *
     * <p>Druid's own {@code AggregatorsModule} does this for the
     * built-in aggregators; an extension has to register its own.
     */
    @Override
    public List<? extends com.fasterxml.jackson.databind.Module> getJacksonModules()
    {
        return List.of(
                new com.fasterxml.jackson.databind.module.SimpleModule("fractalsql-druid")
                        .registerSubtypes(
                                new com.fasterxml.jackson.databind.jsontype.NamedType(
                                        FractalSearchAggregatorFactory.class,
                                        FractalSearchAggregatorFactory.TYPE)));
    }
}
