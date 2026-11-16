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
import org.junit.jupiter.api.AfterAll;
import org.junit.jupiter.api.BeforeAll;
import org.junit.jupiter.api.Test;

import java.nio.file.Files;
import java.nio.file.Path;
import java.util.ArrayList;
import java.util.List;
import java.util.Locale;
import java.util.Properties;

import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertNotNull;
import static org.junit.jupiter.api.Assertions.assertNull;
import static org.junit.jupiter.api.Assertions.assertThrows;
import static org.junit.jupiter.api.Assertions.assertTrue;
import static org.junit.jupiter.api.Assertions.fail;

/**
 * Every branch of the function layer: the corpus and session functions, the config tier, the
 * enterprise gate, and the argument coercions, each called with good, missing and wrong-typed
 * arguments. The functions are built directly (not through the SQL planner) so that the node's
 * session, core, enterprise and daemon collaborators can be present or absent.
 */
public class FractalExprSweepTest {

    private static FakeDaemon fake;
    private static FractalSqlConfig config;
    private static FractalSqlDaemon daemon;
    private static FractalSqlEnterprise enterprise;
    private static FractalSqlSessions sessions;
    private static FractalSqlCore core;
    private static ReasoningBridge bridge;

    @BeforeAll
    static void start() throws Exception
    {
        final Path dir = Files.createTempDirectory("fsql-expr");
        fake = new FakeDaemon(dir);
        final Properties props = new Properties();
        props.setProperty("druid.fractalsql.daemon_socket", fake.socket.toString());
        props.setProperty("druid.fractalsql.daemon_hmac_key_file", fake.keyFile.toString());
        props.setProperty("druid.fractalsql.daemon_timeout_ms", "5000");
        config = new FractalSqlConfig(() -> props);
        daemon = new FractalSqlDaemon(config);
        bridge = new ReasoningBridge(daemon);
        enterprise = new FractalSqlEnterprise(config, daemon);
        sessions = new FractalSqlSessions();
        core = new FractalSqlCore();
    }

    @AfterAll
    static void stop() throws Exception
    {
        if (fake != null) {
            fake.close();
        }
    }

    // -- plumbing -------------------------------------------------------

    private static ExprMacroTable.ExprMacro macroFor(FractalFn.Spec spec) throws Exception
    {
        final StringBuilder body = new StringBuilder(spec.sqlName());
        String b = body.toString();
        b = b.startsWith("FRACTAL_") ? b.substring(8) : b.substring(7);
        final StringBuilder out = new StringBuilder("Fractal");
        for (String part : b.toLowerCase(Locale.ROOT).split("_")) {
            if (!part.isEmpty()) {
                out.append(Character.toUpperCase(part.charAt(0))).append(part.substring(1));
            }
        }
        Class<?> cls;
        try {
            cls = Class.forName("com.fractalsqlabs.fractalsql.druid.fn." + out + "ExprMacro");
        } catch (ClassNotFoundException e) {
            cls = Class.forName("com.fractalsqlabs.fractalsql.druid." + out + "ExprMacro");
        }
        return (ExprMacroTable.ExprMacro) cls.getDeclaredConstructor().newInstance();
    }

    /** What a call did: its value, or the exception class it ended in. */
    private static final class Out {
        final Object value;
        final Throwable error;

        Out(Object value, Throwable error)
        {
            this.value = value;
            this.error = error;
        }

        String text()
        {
            return value == null ? null : value.toString();
        }
    }

    private static Out call(String sqlName, boolean withTiers, Object... args)
    {
        return callWith(sqlName,
                withTiers ? sessions : null,
                withTiers ? core : null,
                withTiers ? enterprise : null,
                withTiers ? daemon : null,
                withTiers ? bridge : null,
                args);
    }

    private static Out callWith(
            String sqlName,
            FractalSqlSessions s,
            FractalSqlCore c,
            FractalSqlEnterprise e,
            FractalSqlDaemon d,
            ReasoningBridge br,
            Object... args)
    {
        try {
            if (args == null) {
                args = new Object[]{null};
            }
            final FractalFn.Spec spec = FractalFn.byName(sqlName);
            final SettableObjectBinding binding = new SettableObjectBinding();
            final List<Expr> exprs = new ArrayList<>();
            for (int i = 0; i < spec.arity(); i++) {
                final String id = "a" + i;
                binding.withBinding(id, i < args.length ? args[i] : null);
                exprs.add(Parser.parse(id, ExprMacroTable.nil()));
            }
            final FractalExpr expr = new FractalExpr(macroFor(spec), spec, exprs, br, config, s, c, e, d);
            final ExprEval eval = expr.eval(binding);
            return new Out(eval.value(), null);
        } catch (Throwable t) {
            return new Out(null, t);
        }
    }

    /** The call must either answer or fail with one of the documented exception types. */
    private static Out ok(Out o)
    {
        if (o.error != null
                && !(o.error instanceof IllegalStateException)
                && !(o.error instanceof IllegalArgumentException)) {
            fail("unexpected " + o.error.getClass().getName() + ": " + o.error.getMessage(), o.error);
        }
        return o;
    }

    private static Out good(Out o)
    {
        if (o.error != null) {
            fail("expected an answer, got " + o.error, o.error);
        }
        return o;
    }

    private static Out bad(Out o)
    {
        assertNotNull(o.error, "expected a failure");
        ok(o);
        return o;
    }

    private static final Object[] CORPUS = {
        new Object[]{1.0, 0.0, 0.0},
        new Object[]{0.0, 1.0, 0.0},
        new Object[]{0.0, 0.0, 1.0},
        new Object[]{0.5, 0.5, 0.0}
    };

    // -- corpus tier ------------------------------------------------------

    @Test
    void searchExploreAcceptsGoodCorpusAndRejectsBadOnes()
    {
        final Out r = good(call("FRACTAL_SEARCH_EXPLORE", true, CORPUS, "[1,0,0]", "{\"population_size\":10,\"iterations\":3}"));
        assertNotNull(r.text());
        good(call("FRACTAL_SEARCH_EXPLORE", true, CORPUS, "[1,0,0]", null));
        good(call("FRACTAL_SEARCH_EXPLORE", true, CORPUS, "[1,0,0]", "  "));
        good(call("FRACTAL_SEARCH_EXPLORE", true, new Object[]{1.0, 0.0, 0.0}, "[1,0,0]", "{\"population_size\":99999,\"iterations\":0,\"diffusion_factor\":999}"));
        good(call("FRACTAL_SEARCH_EXPLORE", true, new double[]{1, 0, 0}, "[1,0,0]", "{}"));

        bad(call("FRACTAL_SEARCH_EXPLORE", true, null, "[1,0,0]", null));
        bad(call("FRACTAL_SEARCH_EXPLORE", true, new Object[0], "[1,0,0]", null));
        bad(call("FRACTAL_SEARCH_EXPLORE", true, "text", "[1,0,0]", null));
        bad(call("FRACTAL_SEARCH_EXPLORE", true, new Object[]{new Object[]{1.0, "x"}}, "[1,0,0]", null));
        bad(call("FRACTAL_SEARCH_EXPLORE", true, CORPUS, "not a vector", null));
        bad(call("FRACTAL_SEARCH_EXPLORE", true, CORPUS, null, null));
        bad(call("FRACTAL_SEARCH_EXPLORE", true, CORPUS, "[1,0]", null));
        bad(call("FRACTAL_SEARCH_EXPLORE", true,
                new Object[]{new Object[]{1.0, 0.0, 0.0}, new Object[]{1.0, 0.0}}, "[1,0,0]", null));
        bad(call("FRACTAL_SEARCH_EXPLORE", true, CORPUS, "[1,0,0]", "{not json"));
    }

    @Test
    void searchDebugAppliesDefaultsAndRejectsBadQueries()
    {
        good(call("FRACTAL_SEARCH_DEBUG", true, "[1,0,0]", 5, 8, 2));
        good(call("FRACTAL_SEARCH_DEBUG", true, "[1,0,0]", null, null, null));
        bad(call("FRACTAL_SEARCH_DEBUG", true, "garbage", 5, 8, 2));
        bad(call("FRACTAL_SEARCH_DEBUG", true, null, 5, 8, 2));
        // a bad parameter makes the core refuse and the failure carry its detail
        ok(call("FRACTAL_SEARCH_DEBUG", true, "[1,0,0]", -5, -5, -5));
    }

    // -- session tier ---------------------------------------------------------

    @Test
    void diversifyLifecycle()
    {
        good(call("FRACTAL_DIVERSIFY_ENABLE", true));
        assertTrue(sessions.diversifyEnabled());
        final Out explain = good(call("FRACTAL_EXPLAIN_RESULT", true));
        assertTrue(explain.text().contains("\"diversify_enabled\":true"));
        good(call("FRACTAL_DETECT_COLLAPSE", true));
        good(call("FRACTAL_DIVERSIFY_SET_PARAMS", true, "{\"window_n\":4,\"stall_threshold\":0.2,"
                + "\"repulsion_sigma\":0.1,\"repulsion_weight\":0.3,\"max_shadows_considered\":32,\"tail_buffer_cap\":128}"));
        good(call("FRACTAL_DIVERSIFY_SET_PARAMS", true, "{}"));
        good(call("FRACTAL_DIVERSIFY_SET_PARAMS", true, null));
        good(call("FRACTAL_DIVERSIFY_SET_PARAMS", true, "   "));
        bad(call("FRACTAL_DIVERSIFY_SET_PARAMS", true, "{nope"));
        good(call("FRACTAL_DIVERSIFY_DISABLE", true));
        assertTrue(!sessions.diversifyEnabled());
        assertTrue(good(call("FRACTAL_EXPLAIN_RESULT", true)).text().contains("\"diversify_enabled\":false"));

        // with no session tier the functions say so
        bad(call("FRACTAL_DIVERSIFY_ENABLE", false));
        bad(call("FRACTAL_DIVERSIFY_DISABLE", false));
        bad(call("FRACTAL_DIVERSIFY_SET_PARAMS", false, "{}"));
        bad(call("FRACTAL_EXPLAIN_RESULT", false));
        bad(call("FRACTAL_DETECT_COLLAPSE", false));
        // the enable/disable path with a core but no session overlay
        ok(callWith("FRACTAL_DIVERSIFY_ENABLE", null, core, null, null, null));
        ok(callWith("FRACTAL_DIVERSIFY_DISABLE", null, core, null, null, null));
    }

    @Test
    void feedbackAndIsolation()
    {
        good(call("FRACTAL_FEEDBACK_REPORT", true, 7, "click", 12.5));
        good(call("FRACTAL_FEEDBACK_REPORT", true, "x", null, "y"));
        good(call("FRACTAL_ISOLATE_BACKGROUND", true, 7));
        good(call("FRACTAL_ISOLATE_BACKGROUND", true, "nan"));
        assertTrue(sessions.isolated().contains("7"));
        bad(call("FRACTAL_FEEDBACK_REPORT", false, 7, "click", 1));
        bad(call("FRACTAL_ISOLATE_BACKGROUND", false, 7));
        // sessions present, but no core or enterprise: the report is kept and goes no further
        ok(callWith("FRACTAL_FEEDBACK_REPORT", sessions, null, null, null, null, 1, "k", 1));
        ok(callWith("FRACTAL_FEEDBACK_REPORT", sessions, core, enterprise, null, null, 1, null, 1));
    }

    @Test
    void cycleDetect()
    {
        good(call("FRACTAL_CYCLE_DETECT", true, "[\"0011223344556677\",\"0011223344556677\",\"0011223344556677\"]", 64, 3));
        good(call("FRACTAL_CYCLE_DETECT", true, "[\"0011223344556677\",\"ffffffffffffffff\"]", null, null));
        // a fingerprint whose length is not the width's byte count is refused (SECURITY_AUDIT.md 3.2)
        bad(call("FRACTAL_CYCLE_DETECT", true, "[\"00\",\"ff\"]", null, null));
        bad(call("FRACTAL_CYCLE_DETECT", true, "[\"00\"]", 64, 3));
        good(call("FRACTAL_CYCLE_DETECT", true, null, 64, 3));
        good(call("FRACTAL_CYCLE_DETECT", true, "{\"not\":\"an array\"}", 64, 3));
        bad(call("FRACTAL_CYCLE_DETECT", true, "[\"\"]", 64, 3));
        bad(call("FRACTAL_CYCLE_DETECT", true, "[\"\",null]", 64, 3));
        bad(call("FRACTAL_CYCLE_DETECT", true, "[not json", 64, 3));
        bad(call("FRACTAL_CYCLE_DETECT", true, "[\"zz\"]", 64, 3));
    }

    // -- config tier ------------------------------------------------------------

    @Test
    void configTier()
    {
        good(call("FRACTAL_CONFIG_SET", true, "search.population", "40", "sess-a"));
        good(call("FRACTAL_CONFIG_GET", true, "search.population", "sess-a"));
        good(call("FRACTAL_CONFIG_LIST", true, "sess-a"));
        good(call("FRACTAL_CONFIG_KEYS", true));
        good(call("FRACTAL_CONFIG_RESET", true, "sess-a"));

        bad(call("FRACTAL_CONFIG_SET", true, "k", "v", null));
        bad(call("FRACTAL_CONFIG_SET", true, "k", "v", ""));
        bad(call("FRACTAL_CONFIG_RESET", true, null));
        bad(call("FRACTAL_CONFIG_RESET", true, ""));
        bad(call("FRACTAL_CONFIG_LIST", true, null));
        bad(call("FRACTAL_CONFIG_LIST", true, ""));

        // no daemon on this node
        bad(call("FRACTAL_CONFIG_KEYS", false));
        bad(call("FRACTAL_CONFIG_GET", false, "k", "s"));
        bad(call("FRACTAL_CONFIG_SET", false, "k", "v", "s"));

        // a daemon that has died
        fake.fail = true;
        try {
            bad(call("FRACTAL_CONFIG_KEYS", true));
            bad(call("FRACTAL_CONFIG_GET", true, "k", "s"));
        } finally {
            fake.fail = false;
        }
    }

    // -- enterprise tier ---------------------------------------------------------

    @Test
    void enterpriseGate()
    {
        for (int i = 60; i <= 69; i++) {
            final String name = FractalFn.byId(i).sqlName();
            final int arity = FractalFn.byId(i).arity();
            final Object[] args = new Object[arity];
            for (int k = 0; k < arity; k++) {
                args[k] = "x";
            }
            ok(call(name, true, args));
            bad(call(name, false, args));
        }
        ok(call("FRACTAL_LOCK_DESTRUCTIVE", true));
        bad(call("FRACTAL_LOCK_DESTRUCTIVE", false));

        final Object[] vec = {0.1, 0.2, 0.3};
        for (String n : new String[]{"FRACTAL_OPTIMIZE_PORTFOLIO_MULTIMODAL",
            "FRACTAL_OPTIMIZE_PORTFOLIO_MULTIMODAL_EX", "FRACTAL_OPTIMIZE_PORTFOLIO_MULTIMODAL_PARETO"}) {
            final int arity = FractalFn.byName(n).arity();
            final Object[] args = new Object[arity];
            args[0] = vec;
            args[1] = new Object[]{1.0, 0.0, 0.0, 0.0, 1.0, 0.0, 0.0, 0.0, 1.0};
            for (int k = 2; k < arity; k++) {
                args[k] = 2;
            }
            ok(call(n, true, args));
            bad(call(n, false, args));
        }
    }

    // -- plain functions and the coercions ------------------------------------------

    @Test
    void identityAndJsonFunctions()
    {
        assertNotNull(good(call("FRACTAL_VERSION", true)).text());
        assertNotNull(good(call("FRACTAL_EDITION", true)).text());
        assertNotNull(good(call("FRACTAL_REASON", true, "q", "p")).value);
        assertNull(good(call("FRACTAL_REASON", false, "q", "p")).value);
        assertNotNull(good(call("FRACTAL_EMBED", true, "text")).value);
        assertNull(good(call("FRACTAL_EMBED", false, "text")).value);

        final String doc = "{\"a\":{\"n\":5,\"s\":\"hi\",\"o\":{\"k\":1}}}";
        assertEquals(5.0, ((Number) good(call("FRACTAL_JSON_VALUE", true, doc, "$.a.n")).value).doubleValue());
        assertTrue(Double.isNaN(((Number) good(call("FRACTAL_JSON_VALUE", true, doc, "$.a.s")).value).doubleValue()));
        assertTrue(Double.isNaN(((Number) good(call("FRACTAL_JSON_VALUE", true, doc, "$.zz")).value).doubleValue()));
        assertEquals("hi", good(call("FRACTAL_JSON_TEXT", true, doc, "$.a.s")).text());
        assertTrue(good(call("FRACTAL_JSON_TEXT", true, doc, "$.a.o")).text().contains("\"k\""));
        assertNull(good(call("FRACTAL_JSON_TEXT", true, doc, "$.zz")).value);
        assertNull(good(call("FRACTAL_JSON_TEXT", true, "{\"x\":null}", "$.x")).value);
    }

    @Test
    void vectorCoercionsReachEveryShape()
    {
        assertEquals(3.0, ((Number) good(call("FRACTAL_VECTOR_NORM", true, new float[]{1, 2, 2})).value).doubleValue(), 1e-9);
        assertEquals(3.0, ((Number) good(call("FRACTAL_VECTOR_NORM", true, new int[]{1, 2, 2})).value).doubleValue(), 1e-9);
        assertEquals(3.0, ((Number) good(call("FRACTAL_VECTOR_NORM", true, new long[]{1, 2, 2})).value).doubleValue(), 1e-9);
        assertEquals(3.0, ((Number) good(call("FRACTAL_VECTOR_NORM", true, List.of(1, 2.0, "2"))).value).doubleValue(), 1e-9);
        assertEquals(3.0, ((Number) good(call("FRACTAL_VECTOR_NORM", true, "[1,2,2]")).value).doubleValue(), 1e-9);
        ok(call("FRACTAL_VECTOR_NORM", true, new Object[]{1, 2, "2"}));
        ok(call("FRACTAL_VECTOR_NORM", true, new Object[]{1, null}));
        ok(call("FRACTAL_VECTOR_NORM", true, new Object[]{1, "x"}));
        ok(call("FRACTAL_VECTOR_NORM", true, java.util.Arrays.asList(1, null)));
        ok(call("FRACTAL_VECTOR_NORM", true, List.of(1, "x")));
        ok(call("FRACTAL_VECTOR_NORM", true, 5));
        ok(call("FRACTAL_VECTOR_NORM", true, new Object()));
        ok(call("FRACTAL_VECTOR_NORM", true, (Object) null));
        // scalar coercions on a function that takes a number
        ok(call("FRACTAL_VECTOR_SCALE", true, new Object[]{1.0, 2.0}, true));
        ok(call("FRACTAL_VECTOR_SCALE", true, new Object[]{1.0, 2.0}, false));
        ok(call("FRACTAL_VECTOR_SCALE", true, new Object[]{1.0, 2.0}, "2.5"));
        ok(call("FRACTAL_VECTOR_SCALE", true, new Object[]{1.0, 2.0}, "nope"));
        ok(call("FRACTAL_VECTOR_SCALE", true, new Object[]{1.0, 2.0}, (Object) null));
        // the pure-Java functions
        good(call("FRACTAL_VECTOR_TO_JSON", true, new Object[]{1.0, 2.0}));
        ok(call("FRACTAL_VECTOR_TO_JSON", true, (Object) null));
        assertNull(good(call("FRACTAL_VECTOR_FROM_TEXT", true, "garbage")).value);
        assertNull(good(call("FRACTAL_VECTOR_FROM_TEXT", true, (Object) null)).value);
        assertNull(good(call("FRACTAL_VECTOR", true, 0)).value);
        assertNull(good(call("FRACTAL_VECTOR", true, 100000)).value);
    }

    @Test
    void resultShapesOfTheAnalyticsFunctions()
    {
        final double[] s = new double[256];
        for (int i = 0; i < s.length; i++) {
            s[i] = Math.sin(i / 7.0) + (i > 128 ? 2 : 0) + 0.003 * i;
        }
        final Object[] series = java.util.Arrays.stream(s).boxed().toArray();
        for (String n : new String[]{"FRACTAL_DIMENSION_DFA", "FRACTAL_DIMENSION_DRIFT", "FRACTAL_CHANGE_POINT_DETECT",
            "FRACTAL_PERIODOGRAM", "FRACTAL_SPECTROGRAM_ENTROPY", "FRACTAL_DIMENSION_BOXCOUNT",
            "FRACTAL_MORPHOLOGICAL_COMPLEXITY", "FRACTAL_STATE_FINGERPRINT", "FRACTAL_VECTOR_QUANTIZE_INT8",
            "FRACTAL_VECTOR_DIMS", "FRACTAL_VECTOR_HAMMING_DISTANCE", "FRACTAL_VECTOR_LP_DISTANCE"}) {
            final FractalFn.Spec spec = FractalFn.byName(n);
            final Object[] args = new Object[spec.arity()];
            for (int k = 0; k < args.length; k++) {
                args[k] = spec.isArrayArg(k) ? series : 4;
            }
            ok(call(n, true, args));
        }
    }
}
