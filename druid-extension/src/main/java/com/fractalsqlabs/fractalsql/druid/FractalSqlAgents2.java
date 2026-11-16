/*
 * SPDX-License-Identifier: Apache-2.0
 * Copyright 2026 Daniel Gardiner d/b/a FractalSQLabs
 */
package com.fractalsqlabs.fractalsql.druid;

import java.util.ArrayList;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;

/**
 * The rest of the composite agents.
 *
 * <p>The same shape as {@link FractalSqlAgents}: read the data, compute
 * the analytic, reason about the result, emit a decision document. These
 * are the agents that compose a corpus search with a core primitive --
 * a trajectory search with a box count, a drift with a hybrid recall.
 *
 * <p>The reference originals live in {@code fsql_domain_agents.c}; the
 * documents below are the ones those functions emitted.
 */
final class FractalSqlAgents2 {

    private FractalSqlAgents2()
    {
    }

    /**
     * Engine L: the detour classifier.
     *
     * <p>Which stored vehicle most resembles this vehicle's movement,
     * and how complex the GPS trace it left.
     */
    static Map<String, Object> detourClassify(
            FractalSqlService service,
            ReasoningBridge reasoning,
            Map<String, Object> args) throws Exception
    {
        final String table = required(args, "vehicle_table");
        final String column = required(args, "emb_col");
        final String idColumn = args.get("id_column") == null ? "id" : args.get("id_column").toString();
        final int k = integer(args, "k", 5);
        final double[] baseline = vector(service, args, "baseline_vec");
        final double[] current = vector(service, args, "current_vec");
        final String trace = required(args, "gps_trace");
        final int boxcountDim = integer(args, "boxcount_dim", 2);

        final Map<String, Object> hits = service.searchTelemetry(
                table, column, idColumn, text(delta(baseline, current)), k);
        final List<Map<String, Object>> rows = rowsOf(hits);
        final Map<String, Object> doc = new LinkedHashMap<>();
        doc.put("nearest_fleet_id", rows.isEmpty() ? null : rows.get(0).get("doc_id"));
        doc.put("trajectory_distance", rows.isEmpty() ? null : rows.get(0).get("distance"));
        doc.put("trace_complexity", service.boxcountOf(trace, boxcountDim));
        doc.put("rationale", reasoning.reason(
                "Classify this detour: which stored vehicle does the movement resemble, "
                        + "and how complex was the GPS trace?",
                String.valueOf(doc)));
        return doc;
    }

    /**
     * Engine M: the track-anomaly reader.
     *
     * <p>The nearest stored track, how far the movement was, and the
     * heading series' own DFA exponent.
     */
    static Map<String, Object> trackAnomaly(
            FractalSqlService service,
            ReasoningBridge reasoning,
            Map<String, Object> args) throws Exception
    {
        final String table = required(args, "track_table");
        final String column = required(args, "emb_col");
        final String idColumn = args.get("id_column") == null ? "id" : args.get("id_column").toString();
        final int k = integer(args, "k", 5);
        final double[] baseline = vector(service, args, "baseline_vec");
        final double[] current = vector(service, args, "current_vec");
        final double[] heading = vector(service, args, "heading_series");

        final Map<String, Object> hits = service.searchTelemetry(
                table, column, idColumn, text(delta(baseline, current)), k);
        final List<Map<String, Object>> rows = rowsOf(hits);

        final Map<String, Object> doc = new LinkedHashMap<>();
        doc.put("nearest_fleet_id", rows.isEmpty() ? null : rows.get(0).get("doc_id"));
        doc.put("trajectory_distance", rows.isEmpty() ? null : rows.get(0).get("distance"));
        doc.put("dfa_exponent", dfa(heading));
        doc.put("rationale", reasoning.reason(
                "Read this track anomaly: the nearest fleet track, how far the movement "
                        + "was, and what the heading series' exponent says.",
                String.valueOf(doc)));
        return doc;
    }

    /**
     * Engine J: the workload scheduler.
     *
     * <p>The SFS refines the task's profile, and the refined profile is
     * matched to a real node.
     */
    static Map<String, Object> scheduleWorkload(
            FractalSqlService service,
            ReasoningBridge reasoning,
            Map<String, Object> args) throws Exception
    {
        final double[] task = vector(service, args, "task_vec");
        final String table = required(args, "node_table");
        final String column = required(args, "node_emb_col");
        final String idColumn = required(args, "node_id_col");
        final int iterations = integer(args, "iterations", 30);
        final int population = integer(args, "population", 50);
        final int k = integer(args, "k", 5);

        final double[] refined = refine(task, iterations, population);
        final Map<String, Object> hits = service.searchTelemetry(
                table, column, idColumn, text(refined), k);
        final List<Map<String, Object>> rows = rowsOf(hits);

        final Map<String, Object> doc = new LinkedHashMap<>();
        doc.put("assigned_node", rows.isEmpty() ? null : rows.get(0).get("doc_id"));
        final Object distance = rows.isEmpty() ? null : rows.get(0).get("distance");
        doc.put("confidence", distance == null ? null : 1.0 / (1.0 + ((Number) distance).doubleValue()));
        doc.put("rationale", reasoning.reason(
                "Schedule this workload: which node takes it, and why?",
                String.valueOf(doc)));
        return doc;
    }

    /**
     * Engine N: the network-coverage alert.
     *
     * <p>The morphology of the point cloud and the drift of the series
     * beside it.
     */
    static Map<String, Object> networkCoverageAlert(
            FractalSqlService service,
            ReasoningBridge reasoning,
            Map<String, Object> args) throws Exception
    {
        // The cloud and the series may be given as text, or read out of
        // the datasources the caller computed.
        final String cloud = args.get("point_cloud") != null
                ? required(args, "point_cloud")
                : service.cells(required(args, "point_cloud_table"),
                        required(args, "point_cloud_column"));
        final String series = args.get("drift_series") != null
                ? required(args, "drift_series")
                : service.cells(required(args, "drift_series_table"),
                        required(args, "drift_series_column"));
        final int boxcountDim = integer(args, "boxcount_dim", 2);
        final int driftWindow = integer(args, "drift_win", 48);
        final double driftThreshold = number(args, "drift_threshold", 0.5);

        final double[] points = VectorText.parseVector(cloud);
        final double[] walk = VectorText.parseVector(series);
        final Map<String, Object> doc = new LinkedHashMap<>();
        doc.put("morph_dimension", service.boxcountOf(cloud, boxcountDim));
        doc.put("lacunarity", lacunarity(points, boxcountDim));
        final double drift = drift(walk, driftWindow);
        doc.put("drift_detected", Math.abs(drift) > driftThreshold);
        doc.put("rationale", reasoning.reason(
                "Alert on this network's coverage: what is the morphology of the point "
                        + "cloud, and has the drift series moved?",
                String.valueOf(doc)));
        return doc;
    }

    /**
     * Engine H: the patient-deterioration triage.
     *
     * <p>The nearest cohort member, how far it is, and how far the
     * patient's own state has moved.
     */
    static Map<String, Object> patientDeteriorationTriage(
            FractalSqlService service,
            ReasoningBridge reasoning,
            Map<String, Object> args) throws Exception
    {
        final String table = required(args, "patient_table");
        final String column = required(args, "vec_col");
        final String idColumn = args.get("id_column") == null ? "id" : args.get("id_column").toString();
        final double[] query = vector(service, args, "query_vec");
        final double[] baseline = vector(service, args, "baseline_vec");
        final double[] current = vector(service, args, "current_vec");
        final int k = integer(args, "k", 5);

        final java.util.Set<String> cohort = new java.util.LinkedHashSet<>();
        final Object ids = args.get("cohort_doc_ids");
        if (ids instanceof List) {
            for (Object id : (List<?>) ids) {
                cohort.add(String.valueOf(id));
            }
        } else if (args.get("cohort_doc_ids_table") != null) {
            // The cohort the caller computed, written into a one-row
            // datasource.
            final String text = service.cell(
                    required(args, "cohort_doc_ids_table"),
                    required(args, "cohort_doc_ids_column"));
            for (String id : text.split(",")) {
                final String trimmed = id.trim();
                if (!trimmed.isEmpty()) {
                    cohort.add(trimmed);
                }
            }
        }
        final Map<String, Object> hits = service.searchTelemetry(
                table, column, idColumn, text(query), k, cohort, null);
        final List<Map<String, Object>> rows = rowsOf(hits);

        final Map<String, Object> doc = new LinkedHashMap<>();
        doc.put("nearest_cohort_id", rows.isEmpty() ? null : rows.get(0).get("doc_id"));
        doc.put("cohort_distance", rows.isEmpty() ? null : rows.get(0).get("distance"));
        // The drift distance is the trajectory search's nearest distance:
        // the rows nearest to the movement from baseline to current.
        final List<Map<String, Object>> moved = rowsOf(service.searchTelemetry(
                table, column, idColumn, text(delta(baseline, current)), 1));
        final Object driftDistance = moved.isEmpty() ? null : moved.get(0).get("distance");
        doc.put("drift_distance", driftDistance == null ? 0.0 : driftDistance);
        final List<Map<String, Object>> matches = new ArrayList<>();
        for (Map<String, Object> row : rows) {
            final Map<String, Object> m = new LinkedHashMap<>();
            m.put("id", row.get("doc_id"));
            m.put("distance", row.get("distance"));
            matches.add(m);
        }
        doc.put("cohort_matches", matches);
        doc.put("rationale", reasoning.reason(
                "Triage this patient: how far their state has moved, and who in the "
                        + "cohort they resemble.",
                String.valueOf(doc)));
        return doc;
    }

    /**
     * Engine K: the sibling-allocation rebalancer.
     *
     * <p>The cardinality-constrained allocation, and the stored
     * allocation it most resembles.
     */
    static Map<String, Object> rebalanceSibling(
            FractalSqlService service,
            ReasoningBridge reasoning,
            Map<String, Object> args) throws Exception
    {
        final double[] mu = vector(required(args, "mu"));
        final double[] cov = vector(required(args, "cov"));
        final int cardinality = integer(args, "cardinality", 1);
        final String table = required(args, "alloc_table");
        final String column = required(args, "alloc_emb_col");
        final String idColumn = args.get("id_column") == null ? "id" : args.get("id_column").toString();
        final double[] baseline = vector(service, args, "baseline_vec");
        final int k = integer(args, "k", 5);

        NativeLoader.load();
        final double[] out = new double[FractalFn.OUT_SIZE];
        final double sharpe = Native.callFn(
                8, mu, mu.length, cov, cov.length, null, 0, cardinality, 0, 0, out);

        // The nearest stored allocation to the optimized weights, by the
        // movement from the baseline to them.
        final double[] optimized = new double[(int) Math.round(Math.sqrt(cov.length))];
        for (int i = 0; i < optimized.length && i + 1 < out.length; i++) {
            optimized[i] = out[i + 1];
        }
        final Map<String, Object> hits = service.searchTelemetry(
                table, column, idColumn, text(delta(baseline, optimized)), k);
        final List<Map<String, Object>> rows = rowsOf(hits);

        final Map<String, Object> doc = new LinkedHashMap<>();
        doc.put("sharpe", sharpe);
        doc.put("weights", weights(out, (int) Math.round(Math.sqrt(cov.length))));
        doc.put("nearest_alloc_id", rows.isEmpty() ? null : rows.get(0).get("doc_id"));
        doc.put("nearest_distance", rows.isEmpty() ? null : rows.get(0).get("distance"));
        doc.put("rationale", reasoning.reason(
                "Explain this sibling rebalance: the allocation it made and the stored "
                        + "allocation it most resembles.",
                String.valueOf(doc)));
        return doc;
    }

    // -- the shared helpers ---------------------------------------------

    /** A required argument. */
    static String required(Map<String, Object> args, String name)
    {
        final Object value = args.get(name);
        if (value == null || value.toString().isEmpty()) {
            throw new IllegalArgumentException("the agent needs a \"" + name + "\"");
        }
        return value.toString();
    }

    /** An integer argument, or a fallback. */
    static int integer(Map<String, Object> args, String name, int fallback)
    {
        final Object value = args.get(name);
        if (value instanceof Number) {
            return ((Number) value).intValue();
        }
        return fallback;
    }

    /** A numeric argument, or a fallback. */
    static double number(Map<String, Object> args, String name, double fallback)
    {
        final Object value = args.get(name);
        if (value instanceof Number) {
            return ((Number) value).doubleValue();
        }
        return fallback;
    }

    /**
     * A vector argument: given as text, or taken from a one-row
     * datasource the caller computed.
     */
    static double[] vector(
            FractalSqlService service, Map<String, Object> args, String key) throws Exception
    {
        final Object direct = args.get(key);
        if (direct != null) {
            return vector(direct.toString());
        }
        final String table = required(args, key + "_table");
        final String column = required(args, key + "_column");
        return vector(service.cells(table, column));
    }

    /** A vector argument. */
    static double[] vector(String text)
    {
        final double[] v = VectorText.parseVector(text);
        if (v == null) {
            throw new IllegalArgumentException("expected a CSV or bracketed-JSON vector");
        }
        return v;
    }

    /** The movement from one state to another. */
    static double[] delta(double[] baseline, double[] current)
    {
        if (baseline.length != current.length) {
            throw new IllegalArgumentException(
                    "the baseline and the current vector must have the same dimension");
        }
        final double[] out = new double[baseline.length];
        for (int i = 0; i < out.length; i++) {
            out[i] = current[i] - baseline[i];
        }
        return out;
    }

    /** A vector as the core's text form. */
    static String text(double[] v)
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

    /** The rows of a search result. */
    static List<Map<String, Object>> rowsOf(Map<String, Object> result)
    {
        final Object rows = result.get("rows");
        if (rows instanceof List) {
            final List<Map<String, Object>> out = new ArrayList<>();
            for (Object row : (List<?>) rows) {
                if (row instanceof Map) {
                    @SuppressWarnings("unchecked")
                    final Map<String, Object> one = (Map<String, Object>) row;
                    out.add(one);
                }
            }
            return out;
        }
        return new ArrayList<>();
    }

    /** The core's regime-change drift for a series. */
    static double drift(double[] series, int window)
    {
        if (series.length == 0) {
            return Double.NaN;
        }
        NativeLoader.load();
        final double[] out = new double[FractalFn.OUT_SIZE];
        return Native.callFn(2, series, series.length, null, 0, null, 0, window, 0, 0, out);
    }

    /** The core's DFA exponent for a series. */
    static double dfa(double[] series)
    {
        if (series.length == 0) {
            return Double.NaN;
        }
        NativeLoader.load();
        final double[] out = new double[FractalFn.OUT_SIZE];
        return Native.callFn(1, series, series.length, null, 0, null, 0, 0, 0, 0, out);
    }

    /** The core's morphological complexity for a point cloud. */
    static double[] morphology(double[] points, int dim)
    {
        NativeLoader.load();
        final double[] out = new double[FractalFn.OUT_SIZE];
        final double dimension = Native.callFn(
                7, points, points.length, null, 0, null, 0, dim, 0, 0, out);
        return new double[]{dimension, out.length > 0 ? out[0] : Double.NaN};
    }

    /** The lacunarity of a point cloud. */
    static double lacunarity(double[] points, int dim)
    {
        if (points == null || points.length == 0 || dim <= 0) {
            return Double.NaN;
        }
        return morphology(points, dim)[1];
    }

    /** The cosine distance between two vectors. */
    static double distance(double[] a, double[] b)
    {
        return Native.cosineDistance(a, b);
    }

    /** The SFS-refined point for a query. */
    static double[] refine(double[] query, int iterations, int population)
    {
        NativeLoader.load();
        final long ctx = Native.newSovereign();
        try {
            final String params = "{\"iterations\":" + iterations
                    + ",\"population_size\":" + population
                    + ",\"diffusion_factor\":2,\"walk\":0.5,\"no_corpus\":true}";
            final byte[] result = Native.searchPtr(
                    ctx, query, 1, query.length, query, query.length, 1,
                    params.getBytes(java.nio.charset.StandardCharsets.UTF_8));
            if (result == null) {
                throw new IllegalStateException("fractalsql: the search failed");
            }
            final double[] refined = VectorText.extractBestPoint(result, query.length);
            if (refined == null) {
                throw new IllegalStateException("fractalsql: the search returned no best point");
            }
            return refined;
        } finally {
            Native.free(ctx);
        }
    }

    /** The optimizer's weights, from its output array. */
    static List<Double> weights(double[] out, int n)
    {
        final List<Double> list = new ArrayList<>();
        for (int i = 0; i < n && i + 1 < out.length; i++) {
            list.add(out[i + 1]);
        }
        return list;
    }
}
