/*
 * SPDX-License-Identifier: Apache-2.0
 * Copyright 2026 Daniel Gardiner d/b/a FractalSQLabs
 */
package com.fractalsqlabs.fractalsql.druid;

import com.fasterxml.jackson.databind.JsonNode;
import com.fasterxml.jackson.databind.ObjectMapper;
import org.apache.calcite.rel.type.RelDataType;
import org.apache.calcite.rex.RexBuilder;
import org.apache.calcite.rex.RexNode;
import org.apache.calcite.sql.fun.SqlStdOperatorTable;
import org.apache.calcite.sql.type.SqlTypeName;
import org.apache.druid.segment.column.ColumnType;
import org.apache.druid.segment.column.RowSignature;
import org.junit.jupiter.api.Test;

import java.lang.reflect.InvocationTargetException;
import java.lang.reflect.Method;
import java.util.Properties;

import static org.junit.jupiter.api.Assertions.assertArrayEquals;
import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertFalse;
import static org.junit.jupiter.api.Assertions.assertNotNull;
import static org.junit.jupiter.api.Assertions.assertThrows;
import static org.junit.jupiter.api.Assertions.assertTrue;

/** The small pure helpers behind the endpoints, and the planner-facing parts of the aggregate. */
public class PrivateHelpersTest {

    private static final ObjectMapper MAPPER = new ObjectMapper();

    private static Object call(Class<?> cls, String name, Class<?>[] types, Object... args) throws Exception
    {
        final Method m = cls.getDeclaredMethod(name, types);
        m.setAccessible(true);
        try {
            return m.invoke(null, args);
        } catch (InvocationTargetException e) {
            if (e.getCause() instanceof Exception) {
                throw (Exception) e.getCause();
            }
            throw e;
        }
    }

    private static final Class<?>[] S = {String.class};
    private static final Class<?>[] SS = {String.class, String.class};
    private static final Class<?>[] J = {JsonNode.class};

    @Test
    void leadingKeywordInBothClasses() throws Exception
    {
        for (Class<?> c : new Class<?>[]{FractalSqlResource.class, FractalSqlAgents3.class}) {
            assertEquals("select", call(c, "leadingKeyword", S, "  SELECT 1"));
            assertEquals("with", call(c, "leadingKeyword", S, "\t\r\n((With x AS (SELECT 1)) SELECT 1)"));
            assertEquals("", call(c, "leadingKeyword", S, (Object) null));
            assertEquals("", call(c, "leadingKeyword", S, ""));
            assertEquals("", call(c, "leadingKeyword", S, "   "));
            assertEquals("", call(c, "leadingKeyword", S, "123 select"));
            assertEquals("insert", call(c, "leadingKeyword", S, "INSERT"));
        }
    }

    @Test
    void allowListAndReviewVerdict() throws Exception
    {
        final Class<?> r = FractalSqlResource.class;
        assertEquals(true, call(r, "isAllowed", SS, "select, insert", "insert"));
        assertEquals(true, call(r, "isAllowed", SS, " SELECT ", "select"));
        assertEquals(false, call(r, "isAllowed", SS, "select", "delete"));
        assertEquals(false, call(r, "isAllowed", SS, "", "select"));
        assertEquals(false, call(r, "isAllowed", SS, ",,", ""));
        assertEquals(false, call(r, "isAllowed", SS, null, "select"));

        assertEquals(true, call(r, "reviewPassed", S, "PASS\nlooks fine"));
        assertEquals(true, call(r, "reviewPassed", S, "  pass"));
        assertEquals(false, call(r, "reviewPassed", S, "FAIL: no"));
        assertEquals(false, call(r, "reviewPassed", S, "maybe"));
        assertEquals(false, call(r, "reviewPassed", S, (Object) null));

        assertEquals("select 1", call(r, "extractSql", S, "here: select 1; thanks"));
        assertEquals("select 2", call(r, "extractSql", S, "select 2"));
        assertEquals(null, call(r, "extractSql", S, "no statement"));
    }

    @Test
    void taskStatusDocuments() throws Exception
    {
        final Class<?> s = FractalSqlService.class;
        assertEquals("SUCCESS", call(s, "taskState", J, MAPPER.readTree("{\"status\":{\"status\":\"SUCCESS\"}}")));
        assertEquals("RUNNING", call(s, "taskState", J, MAPPER.readTree("{\"status\":{\"statusCode\":\"RUNNING\"}}")));
        assertEquals("", call(s, "taskState", J, MAPPER.readTree("{\"status\":{\"other\":1}}")));
        assertEquals("", call(s, "taskState", J, MAPPER.readTree("{\"status\":{\"status\":5,\"statusCode\":5}}")));
        assertEquals("FAILED", call(s, "taskState", J, MAPPER.readTree("{\"status\":\"FAILED\"}")));
        assertEquals("", call(s, "taskState", J, MAPPER.readTree("{\"status\":7}")));
        assertEquals("", call(s, "taskState", J, MAPPER.readTree("{}")));

        assertEquals("boom", call(s, "taskError", J, MAPPER.readTree("{\"status\":{\"errorMsg\":\"boom\"}}")));
        assertEquals("", call(s, "taskError", J, MAPPER.readTree("{\"status\":{\"errorMsg\":null}}")));
        assertEquals("", call(s, "taskError", J, MAPPER.readTree("{\"status\":{}}")));
        assertEquals("", call(s, "taskError", J, MAPPER.readTree("{\"status\":\"x\"}")));
        assertEquals("", call(s, "taskError", J, MAPPER.readTree("{}")));
    }

    // -- the planner-facing parts of the aggregate -------------------------------------


    private static RexBuilder rex()
    {
        return new RexBuilder(new org.apache.calcite.jdbc.JavaTypeFactoryImpl(
                org.apache.druid.sql.calcite.planner.DruidTypeSystem.INSTANCE));
    }

    @Test
    void aggregateDeclarationAndArgumentResolution() throws Exception
    {
        final FractalSearchSqlAggregator agg = new FractalSearchSqlAggregator(
                new FractalSqlConfig(() -> new Properties()), new FractalSqlCore());
        assertEquals("FRACTAL_SEARCH_DISTANCE", agg.calciteFunction().getName());

        final RexBuilder rb = rex();
        final RelDataType dbl = rb.getTypeFactory().createSqlType(SqlTypeName.DOUBLE);
        final RelDataType str = rb.getTypeFactory().createSqlType(SqlTypeName.VARCHAR);
        final RowSignature sig = RowSignature.builder().add("emb", ColumnType.STRING).add("other", ColumnType.DOUBLE).build();
        final Class<?> a = FractalSearchSqlAggregator.class;
        final Class<?>[] resolve = {RowSignature.class, RexNode.class};
        final Class<?>[] one = {RexNode.class};

        // a plain column reference, a wrapped one, and the ways to get it wrong
        assertEquals("emb", call(a, "resolveColumnName", resolve, sig, rb.makeInputRef(str, 0)));
        assertEquals("other", call(a, "resolveColumnName", resolve, sig, rb.makeInputRef(dbl, 1)));
        assertEquals("emb", call(a, "resolveColumnName", resolve, sig,
                rb.makeCall(SqlStdOperatorTable.UPPER, rb.makeInputRef(str, 0))));
        assertThrows(IllegalArgumentException.class,
                () -> call(a, "resolveColumnName", resolve, sig, rb.makeInputRef(str, 9)));
        assertThrows(IllegalArgumentException.class,
                () -> call(a, "resolveColumnName", resolve, sig,
                        rb.makeCall(SqlStdOperatorTable.UPPER, rb.makeInputRef(str, 9))));
        assertThrows(IllegalArgumentException.class,
                () -> call(a, "resolveColumnName", resolve, sig,
                        rb.makeCall(SqlStdOperatorTable.UPPER, rb.makeLiteral("x"))));
        assertThrows(IllegalArgumentException.class,
                () -> call(a, "resolveColumnName", resolve, sig, rb.makeLiteral("x")));

        // the query vector: a literal, a cast of one, and the failures
        assertArrayEquals(new double[]{1, 0, 0}, (double[]) call(a, "extractQuery", one, rb.makeLiteral("[1,0,0]")), 1e-9);
        assertArrayEquals(new double[]{1, 2}, (double[]) call(a, "extractQuery", one,
                rb.makeCall(SqlStdOperatorTable.UPPER, rb.makeLiteral("1,2"))), 1e-9);
        assertThrows(IllegalArgumentException.class, () -> call(a, "extractQuery", one, rb.makeLiteral("garbage")));
        assertThrows(IllegalArgumentException.class, () -> call(a, "extractQuery", one, rb.makeInputRef(str, 0)));
        assertThrows(IllegalArgumentException.class, () -> call(a, "extractQuery", one,
                rb.makeCall(SqlStdOperatorTable.PLUS, rb.makeExactLiteral(java.math.BigDecimal.ONE), rb.makeExactLiteral(java.math.BigDecimal.TEN))));

        assertEquals("fractal_search_distance", call(a, "outputName", S, (Object) null));
        assertEquals("fractal_search_distance", call(a, "outputName", S, ""));
        assertEquals("d", call(a, "outputName", S, "d"));
    }

    @Test
    void refinementUsesTheNodeContext() throws Exception
    {
        final FractalSearchSqlAggregator agg = new FractalSearchSqlAggregator(
                new FractalSqlConfig(() -> new Properties()), new FractalSqlCore());
        final double[] refined = agg.refine(new double[]{0.3, 0.4, 0.5});
        assertNotNull(refined);
        assertEquals(3, refined.length);
        assertFalse(Double.isNaN(refined[0]));
        assertTrue(refined.length > 0);
    }
}
