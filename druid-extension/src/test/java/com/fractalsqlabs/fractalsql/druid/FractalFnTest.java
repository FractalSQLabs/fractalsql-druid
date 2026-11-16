/*
 * SPDX-License-Identifier: Apache-2.0
 * Copyright 2026 Daniel Gardiner d/b/a FractalSQLabs
 */
package com.fractalsqlabs.fractalsql.druid;

import org.apache.druid.math.expr.Expr;
import org.apache.druid.math.expr.ExprEval;
import org.apache.druid.math.expr.ExprMacroTable;
import org.apache.druid.math.expr.Parser;
import org.apache.druid.math.expr.SettableObjectBinding;
import org.junit.jupiter.api.Test;

import java.util.ArrayList;
import java.util.List;

import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertNotNull;
import static org.junit.jupiter.api.Assertions.assertTrue;

/**
 * The ported function surface.
 *
 * <p>These tests drive the functions the way Druid does -- through the
 * native expression layer -- rather than through the SQL planner, which
 * needs a cluster. The end-to-end SQL path is covered by the
 * {@code build_test.sh} gates.
 */
public class FractalFnTest {

    /** The camel-case name the generator turns a SQL name into. */
    private static String camel(String sqlName)
    {
        String body = sqlName;
        if (body.startsWith("FRACTAL_")) {
            body = body.substring("FRACTAL_".length());
        } else if (body.startsWith("FRACTAL")) {
            body = body.substring("FRACTAL".length());
        }
        final StringBuilder out = new StringBuilder("Fractal");
        for (String part : body.toLowerCase(java.util.Locale.ROOT).split("_")) {
            if (!part.isEmpty()) {
                out.append(Character.toUpperCase(part.charAt(0))).append(part.substring(1));
            }
        }
        return out.toString();
    }

    /** Every registered function, as a macro table. */
    private static ExprMacroTable macroTable() throws Exception
    {
        final List<org.apache.druid.math.expr.ExprMacroTable.ExprMacro> macros = new ArrayList<>();
        for (FractalFn.Spec spec : FractalFn.all()) {
            final Class<?> cls = macroClass(spec.sqlName());
            macros.add((org.apache.druid.math.expr.ExprMacroTable.ExprMacro)
                    cls.getDeclaredConstructor().newInstance());
        }
        return new ExprMacroTable(macros);
    }

    /**
     * The macro class for a function.
     *
     * <p>Most are generated into the {@code fn} package; the reasoning
     * functions are hand-written in the base package, because they carry
     * the reasoning bridge.
     */
    private static Class<?> macroClass(String sqlName) throws ClassNotFoundException
    {
        try {
            return Class.forName(
                    "com.fractalsqlabs.fractalsql.druid.fn." + camel(sqlName) + "ExprMacro");
        } catch (ClassNotFoundException e) {
            return Class.forName(
                    "com.fractalsqlabs.fractalsql.druid." + camel(sqlName) + "ExprMacro");
        }
    }

    @Test
    public void registryMatchesTheNativeTable()
    {
        assertTrue(
                FractalFn.idsMatchTheNativeTable(),
                "the registry and the native dispatcher disagree on the function ids");
    }

    @Test
    public void everyNativeFunctionHasACaseInTheShim() throws Exception
    {
        // The dispatcher switches on the registry's ids. An id with no case
        // reads the wrong core function -- or none at all -- and does so
        // silently, so it is worth asserting against the source.
        final java.nio.file.Path shim = java.nio.file.Paths.get("src", "main", "native", "fractalsql_jni.c");
        final String source = new String(java.nio.file.Files.readAllBytes(shim), java.nio.charset.StandardCharsets.UTF_8);
        final List<Integer> cases = new ArrayList<>();
        final java.util.regex.Matcher matcher =
                java.util.regex.Pattern.compile("case (\\d+):").matcher(source);
        while (matcher.find()) {
            cases.add(Integer.parseInt(matcher.group(1)));
        }
        assertTrue(cases.size() > 20, "the shim looks like it has no dispatcher at all");

        final List<String> missing = new ArrayList<>();
        for (FractalFn.Spec spec : FractalFn.all()) {
            if (!spec.isJavaOnly() && !cases.contains(spec.id())) {
                missing.add(spec.sqlName() + " (id " + spec.id() + ")");
            }
        }
        assertTrue(missing.isEmpty(), "the JNI shim has no case for: " + String.join(", ", missing));
    }

    @Test
    public void everyFunctionHasAMacroAndASqlBinding() throws Exception
    {
        for (FractalFn.Spec spec : FractalFn.all()) {
            final Class<?> macroClass = macroClass(spec.sqlName());
            final org.apache.druid.math.expr.ExprMacroTable.ExprMacro macro =
                    (org.apache.druid.math.expr.ExprMacroTable.ExprMacro)
                            macroClass.getDeclaredConstructor().newInstance();
            assertEquals(spec.nativeName(), macro.name(), spec.sqlName() + ": macro name");

            final Class<?> bindingClass = Class.forName(
                    "com.fractalsqlabs.fractalsql.druid.fn." + camel(spec.sqlName())
                            + "OperatorConversion");
            final FractalOperatorConversion binding =
                    (FractalOperatorConversion) bindingClass.getDeclaredConstructor().newInstance();
            assertEquals(spec.sqlName(), binding.calciteOperator().getName());
            assertEquals(spec.arity(), binding.calciteOperator().getOperandCountRange().getMin());
        }
    }

    @Test
    public void vectorMathIsCorrect() throws Exception
    {
        final ExprMacroTable table = macroTable();
        final SettableObjectBinding binding = new SettableObjectBinding()
                .withBinding("a", new Double[]{3.0, 4.0})
                .withBinding("b", new Double[]{3.0, 4.0})
                .withBinding("c", new Double[]{0.0, 0.0});

        assertEquals(5.0, eval(table, "fractal_vector_norm(a)", binding), 1e-9);
        assertEquals(0.0, eval(table, "fractal_vector_l2_distance(a, b)", binding), 1e-9);
        assertEquals(0.0, eval(table, "fractal_vector_cosine_distance(a, b)", binding), 1e-9);
        assertEquals(1.0, eval(table, "fractal_vector_cosine_similarity(a, b)", binding), 1e-9);
        assertEquals(-25.0, eval(table, "fractal_vector_negative_inner_product(a, b)", binding), 1e-9);
        assertEquals(2.0, eval(table, "fractal_vector_dims(a)", binding), 1e-9);
    }

    @Test
    public void vectorFunctionsReturnVectors() throws Exception
    {
        final ExprMacroTable table = macroTable();
        final SettableObjectBinding binding = new SettableObjectBinding()
                .withBinding("a", new Double[]{3.0, 4.0})
                .withBinding("b", new Double[]{1.0, 0.0});

        // A vector comes back in the core's JSON text form -- the same
        // convention the reference extension used.
        final double[] sum = VectorText.parseVector(
                Parser.parse("fractal_vector_add(a, b)", table).eval(binding).asString());
        assertNotNull(sum);
        assertEquals(4.0, sum[0], 1e-6);
        assertEquals(4.0, sum[1], 1e-6);

        final double[] scaled = VectorText.parseVector(
                Parser.parse("fractal_vector_scale(a, 2)", table).eval(binding).asString());
        assertEquals(6.0, scaled[0], 1e-6);
        assertEquals(8.0, scaled[1], 1e-6);

        // The core's vector API is float32, so the tolerance is float-sized.
        final double[] normalized = VectorText.parseVector(
                Parser.parse("fractal_vector_normalize(a)", table).eval(binding).asString());
        assertEquals(0.6, normalized[0], 1e-6);
        assertEquals(0.8, normalized[1], 1e-6);

        final double[] fromText = VectorText.parseVector(
                Parser.parse("fractal_vector_from_text('[1,2,3]')", table).eval(binding).asString());
        assertNotNull(fromText);
        assertEquals(3, fromText.length);
        assertEquals(2.0, fromText[1]);

        final double[] zero = VectorText.parseVector(
                Parser.parse("fractal_vector(3)", table).eval(binding).asString());
        assertNotNull(zero);
        assertEquals(3, zero.length);
        assertEquals(0.0, zero[0]);
    }

    @Test
    public void analyticsFunctionsRun() throws Exception
    {
        final ExprMacroTable table = macroTable();
        final double[] series = new double[128];
        for (int i = 0; i < series.length; i++) {
            series[i] = Math.sin(i / 8.0) + 0.01 * i;
        }
        final SettableObjectBinding binding = new SettableObjectBinding()
                .withBinding("s", box(series));

        final double alpha = eval(table, "fractal_dimension_dfa(s)", binding);
        assertTrue(alpha > 0.0 && alpha < 5.0, "DFA alpha was " + alpha);

        final String drift =
                Parser.parse("fractal_dimension_drift(s, 32)", table).eval(binding).asString();
        assertNotNull(drift);
        assertTrue(drift.contains("\"drift\""), "drift document was " + drift);

        final String points =
                Parser.parse("fractal_change_point_detect(s, 32, 1.0)", table).eval(binding).asString();
        assertTrue(points.contains("\"count\""), "change-point document was " + points);
    }

    @Test
    public void stateFingerprintIsStableAndMeasuresDistance() throws Exception
    {
        final ExprMacroTable table = macroTable();
        final SettableObjectBinding binding = new SettableObjectBinding()
                .withBinding("a", new Double[]{1.0, 2.0, 3.0, 4.0})
                .withBinding("b", new Double[]{1.0, 2.0, 3.0, 4.0})
                .withBinding("c", new Double[]{-1.0, -2.0, -3.0, -4.0});

        // The fingerprint is carried as hex, the way the daemon
        // carries it.
        final String fp = Parser.parse("fractal_state_fingerprint(a, 64)", table)
                .eval(binding).asString();
        assertNotNull(fp);
        assertEquals(16, fp.length(), "64 bits is 8 bytes of hex");
        assertEquals(fp, Parser.parse("fractal_state_fingerprint(b, 64)", table)
                .eval(binding).asString(), "the same state has the same fingerprint");

        // And the distance between two states is what the fingerprint
        // exists to answer.
        assertEquals(0.0, eval(table, "fractal_state_distance(a, b, 64)", binding), 1e-9);
        assertTrue(eval(table, "fractal_state_distance(a, c, 64)", binding) > 0.0);
    }

    private static Object box(double[] v)
    {
        final Double[] out = new Double[v.length];
        for (int i = 0; i < v.length; i++) {
            out[i] = v[i];
        }
        return out;
    }

    private static double eval(
            ExprMacroTable table,
            String expression,
            SettableObjectBinding binding)
    {
        return Parser.parse(expression, table).eval(binding).asDouble();
    }
}
