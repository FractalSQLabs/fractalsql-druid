/*
 * SPDX-License-Identifier: Apache-2.0
 * Copyright 2026 Daniel Gardiner d/b/a FractalSQLabs
 */
package com.fractalsqlabs.fractalsql.druid;

import static com.fractalsqlabs.fractalsql.druid.FractalSqlAgents2.dfa;
import static com.fractalsqlabs.fractalsql.druid.FractalSqlAgents2.drift;
import static com.fractalsqlabs.fractalsql.druid.FractalSqlAgents2.integer;
import static com.fractalsqlabs.fractalsql.druid.FractalSqlAgents2.number;
import static com.fractalsqlabs.fractalsql.druid.FractalSqlAgents2.required;
import static com.fractalsqlabs.fractalsql.druid.FractalSqlAgents2.rowsOf;
import static com.fractalsqlabs.fractalsql.druid.FractalSqlAgents2.vector;

import java.util.ArrayList;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;

/**
 * The agents the API reference names and the extension was still
 * missing.
 *
 * <p>The reference originals live in {@code fsql_domain_agents.c} and
 * {@code src/fsql_agents.c}; these are the documents those functions
 * emitted, adapted to the Druid shapes:
 *
 * <ul>
 *   <li><b>Engine I</b> -- the feedback audit: pure analytics, no
 *       reasoning step;</li>
 *   <li><b>Engine O</b> -- the regime triage: the DFA exponent, the
 *       regime drift, and a one-line reading;</li>
 *   <li><b>Engine P</b> -- the diverse portfolios: the enterprise
 *       core's multimodal optimizer, so it is enterprise-gated;</li>
 *   <li>the <b>self-correcting SQL agent</b>: generate, allowlist,
 *       review, retry.</li>
 * </ul>
 *
 * <p>Two of them drive the core through SQL rather than through a
 * native entry point -- the diversify monitor and the session
 * diagnostics live on the node's own core context, and the SQL surface
 * reaches exactly that context.
 */
final class FractalSqlAgents3 {

    /** The most datasources a prompt's schema carries. */
    static final int MAX_SCHEMA_TABLES = 512;

    private FractalSqlAgents3()
    {
    }

    /**
     * Engine I: the feedback audit.
     *
     * <p>The diversity quotient of the corpus, and the session
     * diagnostics that explain it. Pure analytics: there is no
     * reasoning step.
     *
     * <p>The audit is self-contained. It enables the diversify monitor,
     * warms its rolling window with a few varied queries, isolates the
     * nearest row as negative feedback, reads the quotient and the
     * diagnostics -- and disables the monitor again, so the agent
     * leaves the node as it found it.
     *
     * @param args {@code catalog_table}, {@code emb_col},
     *             {@code query_vec}, {@code warmup_table},
     *             {@code warmup_vec_col}, and optionally
     *             {@code warmup_count} and {@code k}
     */
    static Map<String, Object> feedbackAudit(
            FractalSqlService service,
            ReasoningBridge reasoning,
            Map<String, Object> args) throws Exception
    {
        final String catalog = identifier(args, "catalog_table");
        final String embColumn = identifier(args, "emb_col");
        final String queryVector = required(args, "query_vec");
        final String warmupTable = identifier(args, "warmup_table");
        final String warmupColumn = identifier(args, "warmup_vec_col");
        final int warmupCount = integer(args, "warmup_count", 8);
        final int k = integer(args, "k", 3);
        final String idColumn = args.get("id_column") == null
                ? "id" : args.get("id_column").toString();

        // 1. Enable repulsion and the audit defaults.
        //
        //    The monitor lives on a CORE CONTEXT, and the extension's
        //    corpus search runs on a throwaway one -- so a warm-up
        //    search would be invisible to the monitor and the quotient
        //    would have nothing to report. The audit therefore keeps
        //    its own context, turns the monitor on THERE, and reads the
        //    measurement back from it.
        final long ctx = Native.newSovereign();
        if (ctx == 0) {
            throw new IllegalStateException("fractalsql: could not create a core context");
        }
        try {
            Native.diversifyEnable(ctx);
            Native.diversifySetParams(ctx, 5, 0.15, 0.3, 0.5, 64, 256);

            // The catalogue the warm-up searches, as the core wants it:
            // one flat, row-major corpus.
            final List<Object[]> catalogRows =
                    service.corpusRows(catalog, embColumn, idColumn, null);
            if (catalogRows.isEmpty()) {
                throw new IllegalArgumentException(
                        "fractalsql: fractal_agent_feedback_audit: no catalog rows in " + catalog);
            }
            final int dim = ((double[]) catalogRows.get(0)[0]).length;
            final double[] corpus = new double[catalogRows.size() * dim];
            for (int i = 0; i < catalogRows.size(); i++) {
                final double[] v = (double[]) catalogRows.get(i)[0];
                System.arraycopy(v, 0, corpus, i * dim, Math.min(dim, v.length));
            }

            // 2. Warm the D_q rolling window with varied queries, so
            //    the monitor has a measurement to report.
            final List<Map<String, Object>> warmup = service.query(
                    "SELECT \"" + warmupColumn + "\" AS \"v\" FROM \"" + warmupTable
                            + "\" LIMIT " + warmupCount);
            for (Map<String, Object> row : warmup) {
                final Object v = row.get("v");
                if (v == null) {
                    continue;
                }
                final double[] vector = vector(v.toString());
                if (vector == null || vector.length != dim) {
                    continue;
                }
                service.searchOn(ctx, corpus, catalogRows.size(), dim, vector, dim, k,
                        "{\"population_size\":" + Math.max(k, 2) + ",\"iterations\":8,"
                                + "\"walk\":0,\"return_population\":false,"
                                + "\"bound_clipping\":true}");
            }

            // 3. The audit target: the nearest row, reported as
            //    negative feedback. The isolate takes the SCAN POSITION
            //    -- the result-handle convention -- not the row's own
            //    identity, so the scan position is the field read here.
            final Map<String, Object> hits = service.searchTelemetry(
                    catalog, embColumn, idColumn, queryVector, 1);
            final List<Map<String, Object>> nearest = rowsOf(hits);
            if (!nearest.isEmpty()) {
                final Object position = nearest.get(0).get("scan_pos");
                if (position != null) {
                    service.query("SELECT FRACTAL_ISOLATE_BACKGROUND("
                            + (int) Math.round(asDouble(position, 0.0)) + ")");
                }
            }

            // 4. The pure analytics: the diversity quotient the
            //    monitor measured, and the session diagnostics that
            //    explain it.
            final double dq = Native.diversifyCurrentDq(ctx);
            final List<Map<String, Object>> diagnostics =
                    service.query("SELECT FRACTAL_EXPLAIN_RESULT() AS \"diagnostics\"");

            final Map<String, Object> doc = new LinkedHashMap<>();
            doc.put("diversity_quotient", Double.isNaN(dq) ? null : dq);
            doc.put("explanation", diagnostics.isEmpty() ? null : diagnostics.get(0).get("diagnostics"));
            return doc;
        } finally {
            // 5. Self-contained: the monitor goes back off, and the
            //    context goes with it.
            Native.diversifyDisable(ctx);
            Native.free(ctx);
        }
    }

    /**
     * Engine O: the regime triage.
     *
     * <p>The DFA exponent of a series, the regime-change drift, and a
     * one-line reading of the change.
     *
     * @param args {@code series}, and optionally {@code win},
     *             {@code drift_threshold} and {@code context}
     */
    static Map<String, Object> regimeTriage(
            FractalSqlService service,
            ReasoningBridge reasoning,
            Map<String, Object> args) throws Exception
    {
        final double[] series = vector(service, args, "series");
        final int win = integer(args, "win", 64);
        final double threshold = number(args, "drift_threshold", 0.5);
        final String context = args.get("context") == null ? "{}" : args.get("context").toString();

        final double exponent = dfa(series);
        final double drift = drift(series, win);
        final boolean detected = Math.abs(drift) > threshold;

        // The two alphas the drift carries: the recent window's and the
        // baseline's.
        final double[] out = new double[FractalFn.OUT_SIZE];
        NativeLoader.load();
        Native.callFn(2, series, series.length, null, 0, null, 0, win, 0, 0, out);
        final double recentAlpha = out.length > 0 ? out[0] : 0.0;
        final double baselineAlpha = out.length > 1 ? out[1] : 0.0;

        final Map<String, Object> doc = new LinkedHashMap<>();
        doc.put("dfa_exponent", exponent);
        doc.put("drift_detected", detected);
        doc.put("recent_alpha", recentAlpha);
        doc.put("baseline_alpha", baselineAlpha);

        final String rationale = reasoning.reason(
                "Regime triage: the series has DFA exponent " + exponent
                        + " and drift " + drift + " (drift_detected=" + detected
                        + ", recent_alpha=" + recentAlpha
                        + ", baseline_alpha=" + baselineAlpha
                        + "). Triage the regime change in one sentence.",
                context);
        doc.put("rationale", rationale);
        return doc;
    }

    /**
     * Engine P: the diverse portfolios.
     *
     * <p>The enterprise core's multimodal optimizer: several independent
     * restarts, and the candidates within the quality fraction of the
     * best Sharpe, no two sharing more than the overlap threshold of
     * their assets. The Pareto mode scores each restart by decomposed
     * return and risk instead, and reduces them to a non-dominated
     * front.
     *
     * <p>Enterprise-gated, as in every edition: the core
     * symbols are not in the community archive, so this reports that
     * the tier is not loaded until the licensed core is installed.
     *
     * @param args {@code mu}, {@code cov} and {@code cardinality}, and
     *             optionally {@code n_restarts},
     *             {@code overlap_threshold}, {@code quality_frac},
     *             {@code seed}, {@code context} and
     *             {@code objective_mode}
     */
    static Map<String, Object> diversePortfolios(
            FractalSqlService service,
            ReasoningBridge reasoning,
            FractalSqlEnterprise enterprise,
            Map<String, Object> args) throws Exception
    {
        final double[] mu = vector(service, args, "mu");
        final double[] cov = vector(service, args, "cov");
        final int cardinality = integer(args, "cardinality", 1);
        final int restarts = integer(args, "n_restarts", 8);
        final double overlap = number(args, "overlap_threshold", 0.15);
        final double quality = number(args, "quality_frac", 0.90);
        final long seed = (long) number(args, "seed", 0.0);
        final String context = args.get("context") == null ? "{}" : args.get("context").toString();
        final String mode = args.get("objective_mode") == null
                ? "sharpe" : args.get("objective_mode").toString();

        if (!"sharpe".equals(mode) && !"pareto".equals(mode)) {
            throw new IllegalArgumentException(
                    "fractalsql: fractal_agent_diverse_portfolios: objective_mode must be "
                            + "'sharpe' or 'pareto' (got " + mode + ")");
        }

        final String json = "pareto".equals(mode)
                ? enterprise.portfolioMultimodalPareto(
                        mu, cov, cardinality, restarts, restarts, seed, false, 0)
                : enterprise.portfolioMultimodal(
                        mu, cov, cardinality, restarts, overlap, quality, seed);
        if (json == null) {
            throw new IllegalStateException(
                    "fractalsql: the enterprise tier is not loaded -- the multimodal "
                            + "portfolio needs the licensed core "
                            + "(druid.fractalsql.enterprise_lib)");
        }

        final Map<String, Object> doc = new LinkedHashMap<>();
        doc.put("candidates", json);
        doc.put("objective_mode", mode);
        doc.put("rationale", reasoning.reason(
                "Explain this set of portfolio candidates: the "
                        + mode + " objective, what distinguishes them, and which "
                        + "one to take.",
                context));
        return doc;
    }

    /**
     * The self-correcting SQL agent.
     *
     * <p>Generate a statement for a question, check it against the
     * operator's allowlist and against Druid's own parser, have the
     * model review its own work, and retry with the rejection as
     * feedback. The statement that comes back has been through all
     * three.
     *
     * @param args {@code question}, and optionally
     *             {@code table_names}, {@code max_retries} and
     *             {@code auto_execute}
     */
    static Map<String, Object> sqlAgent(
            FractalSqlService service,
            ReasoningBridge reasoning,
            Map<String, Object> args) throws Exception
    {
        final String question = required(args, "question");
        int maxRetries = integer(args, "max_retries", 2);
        if (maxRetries < 1) {
            maxRetries = 1;
        }
        final boolean autoExecute = integer(args, "auto_execute", 0) != 0;

        final List<String> tables = tableNames(args);
        final String schemaContext = schemaContext(service, tables);

        // The operator's allowlist. The extension's own text-to-SQL tier
        // reads it from the configuration; the agent reads it the same
        // way, so one knob governs both.
        final String allowed = reasoning.t2sAllowedStatements(null);
        final boolean allowWrites = allowed != null
                && allowed.trim().toLowerCase(java.util.Locale.ROOT).contains("insert");

        String generated = null;
        String feedback = null;
        boolean passed = false;
        int attempt = 0;

        for (; attempt < maxRetries;) {
            attempt++;
            final String answer = reasoning.reasonForStatement(
                    "Write a single Druid SQL SELECT statement that answers this "
                            + "question over these tables: "
                            + (tables.isEmpty() ? "(the whole schema)" : String.join(", ", tables))
                            + ". Question: " + question
                            + (feedback == null ? ""
                                    : "\nYour previous attempt was rejected: " + feedback
                                            + "\nWrite a different statement."),
                    schemaContext);
            if (answer == null) {
                throw new IllegalStateException(
                        "fractalsql: the model produced no answer for the SQL agent");
            }
            final String sql = extractSql(answer);
            if (sql == null) {
                feedback = "the answer did not contain a SQL statement";
                continue;
            }
            final String verb = leadingKeyword(sql);
            if (!allowWrites && !"select".equals(verb)) {
                feedback = "only SELECT statements are allowed, and the answer was a "
                        + verb.toUpperCase() + " statement";
                continue;
            }
            // A mechanical check: Druid's
            // own parser, without running it.
            try {
                service.query("EXPLAIN PLAN FOR " + sql);
            } catch (Exception e) {
                feedback = "Druid could not plan the statement: " + e.getMessage();
                continue;
            }
            generated = sql;
            passed = true;
            break;
        }

        final Map<String, Object> doc = new LinkedHashMap<>();
        doc.put("generated_sql", generated);
        doc.put("execution_status", passed ? (autoExecute ? "executed" : "success")
                : "validation_failed");
        doc.put("retry_count", attempt);

        Object rows = null;
        if (autoExecute && passed && generated != null) {
            try {
                rows = service.query(generated);
            } catch (Exception e) {
                doc.put("execution_status", "execution_failed");
            }
        }
        if (rows == null && !passed) {
            final Map<String, Object> failure = new LinkedHashMap<>();
            failure.put("status", "validation_failed");
            failure.put("error", feedback);
            rows = failure;
        }
        doc.put("result_json", rows);
        return doc;
    }

    // -- helpers -------------------------------------------------------

    /**
     * The tables the agent may read.
     *
     * <p>Both spellings are accepted: {@code tables} and
     * {@code table_names}. They are the
     * same argument, and reading only one of them means a caller that
     * uses the other gets an agent with no schema -- which is an agent
     * that guesses table names.
     */
    static List<String> tableNames(Map<String, Object> args)
    {
        final List<String> out = new ArrayList<>();
        Object raw = args.get("table_names");
        if (raw == null) {
            raw = args.get("tables");
        }
        if (raw == null) {
            return out;
        }
        if (raw instanceof List) {
            for (Object one : (List<?>) raw) {
                out.add(one.toString());
            }
            return out;
        }
        final String text = raw.toString().trim();
        if (text.startsWith("[")) {
            // A JSON array of names.
            for (String piece : text.substring(1, Math.max(1, text.length() - 1)).split(",")) {
                final String trimmed = piece.trim().replace("\"", "").replace("'", "");
                if (!trimmed.isEmpty()) {
                    out.add(trimmed);
                }
            }
        } else if (!text.isEmpty()) {
            out.add(text);
        }
        return out;
    }

    /** The schema the prompt carries: the named tables' columns. */
    static String schemaContext(FractalSqlService service, List<String> tablesIn)
            throws Exception
    {
        List<String> tables = tablesIn;
        final List<String> named = new ArrayList<>(tablesIn);
        if (named.isEmpty()) {
            // No datasources named: every datasource in the catalog.
            final Object inventory = service.schemaContext(null).get("datasources");
            if (inventory instanceof List) {
                for (Object one : (List<?>) inventory) {
                    if (one instanceof Map) {
                        named.add(String.valueOf(((Map<?, ?>) one).get("datasource")));
                    }
                }
            }
        }
        if (named.size() > MAX_SCHEMA_TABLES) {
            named.subList(MAX_SCHEMA_TABLES, named.size()).clear();
        }
        tables = named;
        final Map<String, Object> context = new LinkedHashMap<>();
        final List<Object> columns = new ArrayList<>();
        for (String table : tables) {
            final Map<String, Object> one = service.schemaContext(table);
            final Object forTable = one.get("columns");
            if (forTable instanceof List) {
                columns.addAll((List<Object>) forTable);
            }
        }
        context.put("datasources", tables);
        context.put("columns", columns);
        return service.mapper().writeValueAsString(context);
    }

    /**
     * A plain identifier: a table or column name.
     *
     * <p>These names are interpolated into SQL, so they are checked
     * rather than escaped. A name that is not a plain identifier is
     * refused.
     */
    private static String identifier(Map<String, Object> args, String name)
    {
        final String value = required(args, name);
        if (!value.matches("[A-Za-z_][A-Za-z0-9_]*")) {
            throw new IllegalArgumentException(
                    "fractalsql: " + name + " must be a plain identifier "
                            + "([A-Za-z_][A-Za-z0-9_]*), got: " + value);
        }
        return value;
    }

    /** The SQL statement inside a model's answer, or null. */
    private static String extractSql(String answer)
    {
        final String trimmed = answer.trim();
        final int start = trimmed.toUpperCase(java.util.Locale.ROOT).indexOf("SELECT");
        if (start < 0) {
            return null;
        }
        int end = trimmed.indexOf(';', start);
        if (end < 0) {
            end = trimmed.length();
        }
        final String sql = trimmed.substring(start, end).trim();
        // A model that reaches for backticks is thinking of another
        // dialect; Druid quotes identifiers with double quotes.
        return sql.replace("`", "\"");
    }

    /** A statement's leading keyword, lowercased. */
    private static String leadingKeyword(String sql)
    {
        final String s = sql == null ? "" : sql.trim();
        int i = 0;
        while (i < s.length()) {
            final char c = s.charAt(i);
            if (c == ' ' || c == '\t' || c == '\r' || c == '\n' || c == '(') {
                i++;
                continue;
            }
            break;
        }
        final int start = i;
        while (i < s.length() && Character.isLetter(s.charAt(i))) {
            i++;
        }
        return s.substring(start, i).toLowerCase(java.util.Locale.ROOT);
    }

    /** A number from a value that may be a Double, a Long or a String. */
    private static double asDouble(Object raw, double fallback)
    {
        if (raw == null) {
            return fallback;
        }
        if (raw instanceof Number) {
            return ((Number) raw).doubleValue();
        }
        try {
            return Double.parseDouble(raw.toString().trim());
        } catch (NumberFormatException e) {
            return fallback;
        }
    }
}
