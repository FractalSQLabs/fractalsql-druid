/*
 * SPDX-License-Identifier: Apache-2.0
 * Copyright 2026 Daniel Gardiner d/b/a FractalSQLabs
 */
package com.fractalsqlabs.fractalsql.druid;

import org.apache.calcite.rel.core.AggregateCall;
import org.apache.calcite.rex.RexLiteral;
import org.apache.calcite.rex.RexNode;
import org.apache.calcite.sql.SqlAggFunction;
import org.apache.calcite.sql.SqlFunctionCategory;
import org.apache.calcite.sql.type.SqlTypeFamily;
import org.apache.calcite.sql.type.SqlTypeName;
import org.apache.druid.segment.column.RowSignature;
import org.apache.druid.sql.calcite.aggregation.Aggregation;
import org.apache.druid.sql.calcite.aggregation.SqlAggregator;
import org.apache.druid.sql.calcite.expression.OperatorConversions;
import org.apache.druid.sql.calcite.planner.PlannerContext;
import org.apache.druid.sql.calcite.rel.InputAccessor;
import org.apache.druid.sql.calcite.rel.VirtualColumnRegistry;

import com.google.inject.Inject;

import java.nio.charset.StandardCharsets;
import java.util.List;

/**
 * The SQL surface for {@code fractal_search_distance}.
 *
 * <p>This aggregate scores a STORED column against a query;
 * {@code fractal_search} is the indexed search over a datasource. A Calcite
 * operator cannot carry two operators with one name, so the aggregate
 * carries its own.
 *
 * <p>Signature:
 * <pre>
 *   fractal_search_distance(vector_column, query_text) -&gt; DOUBLE
 * </pre>
 * where {@code vector_column} is a Druid ARRAY column -- or a VARCHAR
 * column holding the vector in the core's text form -- and
 * {@code query_text} is a VARCHAR literal holding the query vector in
 * the core's text form -- CSV ({@code "1.0,0.5,-0.25"}) or bracketed
 * JSON ({@code "[1.0,0.5,-0.25]"}).
 *
 * <p>The value is the cosine distance from a row's vector to the
 * SFS-refined query point, aggregated as a minimum over the group.
 *
 * <p><b>Where the refinement happens.</b> The core's SFS optimizer
 * refines the query into a projection, and that refinement does not
 * depend on the corpus. So it is done ONCE, here, at plan time in the
 * broker -- one JNI call -- and the refined point is baked into the
 * aggregator factory that goes out to the data nodes. The data nodes
 * only ever do the cheap per-row scoring.
 */
public class FractalSearchSqlAggregator implements SqlAggregator {

    /** The SQL-visible name. */
    public static final String FUNCTION_NAME = "FRACTAL_SEARCH_DISTANCE";

    /** The node's configuration: the SFS tuning the core is driven with. */
    private final FractalSqlConfig config;

    /** The node's core context, where the Diversify monitor lives. */
    private final FractalSqlCore core;

    @Inject
    public FractalSearchSqlAggregator(FractalSqlConfig config, FractalSqlCore core)
    {
        this.config = config;
        this.core = core;
    }

    @Override
    public SqlAggFunction calciteFunction()
    {
        return OperatorConversions
                .aggregatorBuilder(FUNCTION_NAME)
                // The vector column may be an ARRAY or a VARCHAR: the
                // core's vector interchange format is text, so a column
                // that holds a vector as text is as good as one that
                // holds it as an array.
                .operandTypes(SqlTypeFamily.ANY, SqlTypeFamily.CHARACTER)
                .requiredOperands(2)
                .returnTypeNonNull(SqlTypeName.DOUBLE)
                .functionCategory(SqlFunctionCategory.USER_DEFINED_FUNCTION)
                .build();
    }

    @Override
    public Aggregation toDruidAggregation(
            PlannerContext plannerContext,
            VirtualColumnRegistry virtualColumnRegistry,
            String aggregatorName,
            AggregateCall aggregateCall,
            InputAccessor inputAccessor,
            List<Aggregation> otherAggregations,
            boolean aggregateOtherAggregationsInProjection)
    {
        // AggregateCall.getArgList() holds operand *indices*, not
        // expressions; the InputAccessor turns them into the RexNodes the
        // planner actually built.
        final List<RexNode> args = inputAccessor.getFields(aggregateCall.getArgList());
        if (args.size() != 2) {
            throw new IllegalArgumentException(
                    "fractalsql: " + FUNCTION_NAME + "() takes exactly 2 arguments, got " + args.size());
        }

        final String columnName = resolveColumnName(inputAccessor.getInputRowSignature(), args.get(0));
        final double[] refined = refine(extractQuery(args.get(1)));

        return Aggregation.create(
                new FractalSearchAggregatorFactory(outputName(aggregatorName), columnName, refined));
    }

    /**
     * The output name of the aggregation.
     *
     * <p>The aggregator factory's {@code getName()} must never be null:
     * the broker serialises the factory to the data nodes, and a null
     * name makes the historical fail to deserialise the whole query with
     * a confusing "Cannot construct instance of TopNQuery" error. Druid
     * does not always hand the name over on this path, so fall back to a
     * constant.
     */
    private static String outputName(String aggregatorName)
    {
        if (aggregatorName != null && !aggregatorName.isEmpty()) {
            return aggregatorName;
        }
        return "fractal_search_distance";
    }

    /**
     * Resolve the vector column's name from the planner's expression.
     *
     * <p>Handles the two shapes a column argument arrives in: a direct
     * reference to an input column ({@code RexInputRef}) and a call to
     * the {@code ITEM} accessor Druid generates for nested columns.
     */
    private static String resolveColumnName(RowSignature signature, RexNode arg)
    {
        if (arg instanceof org.apache.calcite.rex.RexInputRef) {
            final int index = ((org.apache.calcite.rex.RexInputRef) arg).getIndex();
            if (index < 0 || index >= signature.size()) {
                throw new IllegalArgumentException(
                        "fractalsql: " + FUNCTION_NAME + "() could not resolve its column argument: " + arg);
            }
            return signature.getColumnName(index);
        }
        if (arg instanceof org.apache.calcite.rex.RexCall) {
            final org.apache.calcite.rex.RexCall call = (org.apache.calcite.rex.RexCall) arg;
            if (!call.getOperands().isEmpty()) {
                final RexNode operand = call.getOperands().get(0);
                if (operand instanceof org.apache.calcite.rex.RexInputRef) {
                    final int index = ((org.apache.calcite.rex.RexInputRef) operand).getIndex();
                    if (index >= 0 && index < signature.size()) {
                        return signature.getColumnName(index);
                    }
                }
            }
        }
        throw new IllegalArgumentException(
                "fractalsql: " + FUNCTION_NAME + "() needs a plain column reference "
                        + "as its first argument, got: " + arg);
    }

    /**
     * Pull the query vector out of the planner's expression.
     *
     * <p>It arrives as a VARCHAR literal. Anything else -- a column
     * reference, an expression -- is rejected, because the refinement
     * has to happen at plan time and needs a constant.
     *
     * <p>Two shapes have to be handled. Calcite represents a CHAR/VARCHAR
     * literal's value as an {@code NlsString}, not a {@code String} --
     * {@code getValue()} returns the former -- so the conversion goes
     * through {@code getValueAs(String.class)}. And the planner may wrap
     * the literal in a CAST, which shows up as a {@code RexCall}.
     */
    private static double[] extractQuery(RexNode arg)
    {
        final String text = literalText(arg);
        if (text == null) {
            throw new IllegalArgumentException(
                    "fractalsql: " + FUNCTION_NAME + "() needs a literal query vector "
                            + "as its second argument, got: " + arg);
        }
        final double[] q = VectorText.parseVector(text);
        if (q == null) {
            throw new IllegalArgumentException(
                    "fractalsql: " + FUNCTION_NAME + "() could not parse the query vector: " + text);
        }
        return q;
    }

    /**
     * The text of a character literal, or null if the expression is not
     * a literal.
     */
    private static String literalText(RexNode arg)
    {
        if (arg instanceof RexLiteral) {
            final RexLiteral literal = (RexLiteral) arg;
            try {
                return literal.getValueAs(String.class);
            } catch (RuntimeException e) {
                // Not a character literal. Fall through to the raw value
                // in case the planner handed us a plain String.
                final Object raw = literal.getValue();
                return raw instanceof String ? (String) raw : null;
            }
        }
        if (arg instanceof org.apache.calcite.rex.RexCall) {
            final org.apache.calcite.rex.RexCall call = (org.apache.calcite.rex.RexCall) arg;
            // Unwrap a CAST / SAFE_CAST around the literal.
            if (!call.getOperands().isEmpty() && call.getOperands().size() == 1) {
                return literalText(call.getOperands().get(0));
            }
        }
        return null;
    }

    /**
     * Run the core's SFS once, over the query alone, and return the
     * refined point.
     *
     * <p>The core's best-point computation is corpus-independent, so a
     * one-row corpus (the query itself) satisfies the C API contract
     * while producing the same refined point a full corpus would.
     */
    double[] refine(double[] query)
    {
        NativeLoader.load();
        // The node's shared context, not a throwaway one: the Diversify
        // monitor and the repulsive post-filter live on the context,
        // so a session that turned the monitor on must have its
        // searches run on that same context.
        final byte[] params = config.searchParamsJson().getBytes(StandardCharsets.UTF_8);
        final String[] errOut = new String[1];
        // Under the context lock: the context is shared by every query thread on the node.
        final byte[] result = core.locked(ctx -> {
            final byte[] r = Native.searchPtr(ctx, query, 1, query.length, query, query.length, 1, params);
            if (r == null) {
                errOut[0] = Native.lastError(ctx);
            }
            return r;
        });
        if (result == null) {
            final String err = errOut[0];
            throw new IllegalStateException(
                    "fractalsql: SFS refinement failed: "
                            + (err == null || err.isEmpty() ? "(no detail)" : err));
        }
        final double[] refined = VectorText.extractBestPoint(result, query.length);
        if (refined == null || refined.length != query.length) {
            throw new IllegalStateException(
                    "fractalsql: SFS refinement returned no usable best_point");
        }
        return refined;
    }
}
