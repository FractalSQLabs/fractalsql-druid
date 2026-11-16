/*
 * SPDX-License-Identifier: Apache-2.0
 * Copyright 2026 Daniel Gardiner d/b/a FractalSQLabs
 */
package com.fractalsqlabs.fractalsql.druid;

import org.apache.calcite.rex.RexCall;
import org.apache.calcite.rex.RexInputRef;
import org.apache.calcite.rex.RexLiteral;
import org.apache.calcite.rex.RexNode;
import org.apache.calcite.sql.SqlFunction;
import org.apache.calcite.sql.SqlFunctionCategory;
import org.apache.calcite.sql.SqlOperator;
import org.apache.calcite.sql.type.SqlTypeFamily;
import org.apache.calcite.sql.type.SqlTypeName;
import org.apache.druid.segment.column.ColumnType;
import org.apache.druid.segment.column.RowSignature;
import org.apache.druid.sql.calcite.expression.DruidExpression;
import org.apache.druid.sql.calcite.expression.OperatorConversions;
import org.apache.druid.sql.calcite.expression.SqlOperatorConversion;
import org.apache.druid.sql.calcite.planner.PlannerContext;

import java.util.ArrayList;
import java.util.List;

/**
 * The SQL binding for one {@code fractal_*} function.
 *
 * <p>Druid's SQL layer turns a SQL call into a native expression; this
 * class does that for one function, mapping each argument onto the
 * native call and leaving the rest to {@link FractalExprMacro}.
 *
 * <p>Each function gets a one-line subclass naming its registry entry;
 * the argument handling is shared here.
 */
public abstract class FractalOperatorConversion implements SqlOperatorConversion {

    /** The registry entry for this function. */
    protected abstract FractalFn.Spec spec();

    @Override
    public SqlOperator calciteOperator()
    {
        final FractalFn.Spec s = spec();
        final OperatorConversions.OperatorBuilder<SqlFunction> builder =
                OperatorConversions.operatorBuilder(s.sqlName());

        final SqlTypeFamily[] families = new SqlTypeFamily[s.arity()];
        for (int i = 0; i < s.arity(); i++) {
            switch (s.argTypes()[i]) {
                case ARRAY:
                    // A vector may be a Druid ARRAY column or the core's
                    // text form -- CSV or bracketed JSON. The operand
                    // type is therefore left open: the function reads
                    // whichever it is given, and a text literal needs no
                    // nesting to be passed.
                    families[i] = SqlTypeFamily.ANY;
                    break;
                case STRING:
                    families[i] = SqlTypeFamily.CHARACTER;
                    break;
                default:
                    families[i] = SqlTypeFamily.NUMERIC;
            }
        }
        // Druid's builder needs the operand list set even when it is
        // empty -- a zero-argument function still has one.
        builder.operandTypes(families);
        builder.requiredOperands(s.arity());

        switch (s.retType()) {
            case DOUBLE:
                builder.returnTypeNonNull(SqlTypeName.DOUBLE);
                break;
            case BIGINT:
                builder.returnTypeNullable(SqlTypeName.BIGINT);
                break;
            default:
                builder.returnTypeNullable(SqlTypeName.VARCHAR);
        }
        builder.functionCategory(SqlFunctionCategory.USER_DEFINED_FUNCTION);
        return builder.build();
    }

    @Override
    public DruidExpression toDruidExpression(
            PlannerContext plannerContext,
            RowSignature signature,
            RexNode rexNode)
    {
        final List<RexNode> operands =
                rexNode instanceof RexCall ? ((RexCall) rexNode).getOperands() : List.of();
        final List<DruidExpression> converted = new ArrayList<>(operands.size());
        for (RexNode operand : operands) {
            converted.add(convert(plannerContext, signature, operand));
        }
        return DruidExpression.fromFunctionCall(spec().nativeName(), converted);
    }

    /**
     * Convert one argument to a native expression.
     *
     * <p>Columns become column references, literals become literals, an
     * {@code ARRAY[...]} constructor becomes Druid's own array
     * constructor, and a call to another function becomes a call
     * to that function's native expression.
     */
    private DruidExpression convert(
            PlannerContext plannerContext,
            RowSignature signature,
            RexNode operand)
    {
        if (operand instanceof RexInputRef) {
            final int index = ((RexInputRef) operand).getIndex();
            if (index < 0 || index >= signature.size()) {
                throw new IllegalArgumentException(
                        "fractalsql: could not resolve the column argument: " + operand);
            }
            return DruidExpression.fromColumn(signature.getColumnName(index));
        }

        if (operand instanceof RexLiteral) {
            final RexLiteral literal = (RexLiteral) operand;
            final SqlTypeName typeName = literal.getTypeName();

            // A character literal. Calcite's NlsString.toString() carries a
            // charset prefix ("_UTF-16LE'...'"), so the value has to be
            // asked for as a plain String.
            if (SqlTypeName.CHAR == typeName || SqlTypeName.VARCHAR == typeName) {
                final String text = literal.getValueAs(String.class);
                return DruidExpression.ofLiteral(
                        ColumnType.STRING,
                        DruidExpression.stringLiteral(text == null ? "" : text));
            }

            final Object value = literal.getValue();
            if (value instanceof Number) {
                return DruidExpression.ofLiteral(
                        ColumnType.DOUBLE,
                        DruidExpression.doubleLiteral(((Number) value).doubleValue()));
            }
            if (value instanceof Object[] || value instanceof List) {
                // An array literal: build it with Druid's array constructor.
                final List<DruidExpression> elements = new ArrayList<>();
                if (value instanceof Object[]) {
                    for (Object element : (Object[]) value) {
                        elements.add(literalElement(element));
                    }
                } else {
                    for (Object element : (List<?>) value) {
                        elements.add(literalElement(element));
                    }
                }
                return DruidExpression.fromFunctionCall("array", elements);
            }
            if (value != null) {
                return DruidExpression.ofLiteral(
                        ColumnType.STRING,
                        DruidExpression.stringLiteral(value.toString()));
            }
            return DruidExpression.fromExpression("null");
        }

        if (operand instanceof RexCall) {
            final RexCall call = (RexCall) operand;
            final String operatorName = call.getOperator().getName();

            if ("ARRAY_CONSTRUCTOR".equals(operatorName) || "ARRAY".equals(operatorName)) {
                final List<DruidExpression> elements = new ArrayList<>();
                for (RexNode element : call.getOperands()) {
                    elements.add(convert(plannerContext, signature, element));
                }
                return DruidExpression.fromFunctionCall("array", elements);
            }

            // A call to another function: keep it a call.
            final FractalFn.Spec nested = FractalFn.findByName(operatorName);
            if (nested != null) {
                final List<DruidExpression> args = new ArrayList<>();
                for (RexNode arg : call.getOperands()) {
                    args.add(convert(plannerContext, signature, arg));
                }
                return DruidExpression.fromFunctionCall(nested.nativeName(), args);
            }

            // Any other call -- CONCAT, a cast, an arithmetic operator --
            // becomes a native expression of the same name, with its
            // operands converted the same way. A demo's argument is
            // often computed, and refusing that would make the
            // functions much less usable than the reference ones.
            final List<DruidExpression> args = new ArrayList<>();
            for (RexNode arg : call.getOperands()) {
                args.add(convert(plannerContext, signature, arg));
            }
            return DruidExpression.fromFunctionCall(operatorName.toLowerCase(java.util.Locale.ROOT), args);
        }

        throw new IllegalArgumentException(
                "fractalsql: " + spec().sqlName() + "() cannot use this argument: " + operand);
    }

    /** A constant element of an array literal. */
    private static DruidExpression literalElement(Object element)
    {
        if (element instanceof Number) {
            return DruidExpression.ofLiteral(
                    ColumnType.DOUBLE,
                    DruidExpression.doubleLiteral(((Number) element).doubleValue()));
        }
        return DruidExpression.ofLiteral(
                ColumnType.STRING,
                DruidExpression.stringLiteral(String.valueOf(element)));
    }
}
