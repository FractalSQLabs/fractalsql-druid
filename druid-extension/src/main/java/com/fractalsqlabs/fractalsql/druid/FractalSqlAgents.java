/*
 * SPDX-License-Identifier: Apache-2.0
 * Copyright 2026 Daniel Gardiner d/b/a FractalSQLabs
 */
package com.fractalsqlabs.fractalsql.druid;

import com.google.inject.Inject;
import com.google.inject.Singleton;

import java.util.ArrayList;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;

/**
 * The agency tier: the composite agents.
 *
 * <p>An agent is a composition -- read the data, compute the analytic,
 * reason about the result, emit a decision document. In a database whose
 * scalar functions can open their own statements, the whole
 * composition can live inside one C function, because a scalar
 * function can open its own statements against the database it is
 * attached to.
 *
 * <p>A Druid SQL function cannot: it has no connection, and a query
 * thread must not be held for the length of an LLM round trip. So the
 * agency tier is a <i>service</i> operation -- an HTTP endpoint on the
 * extension. The service reads the data with the same SQL the demo
 * would have written, computes the analytic through the same core the
 * SQL functions call, and reasons through the same bridge.
 *
 * <p>The documents have the same fields as the SQL agents' result rows,
 * so a demo's own expectations carry over unchanged.
 */
@Singleton
public class FractalSqlAgents {

    private final FractalSqlService service;
    private final ReasoningBridge reasoning;
    private final FractalSqlEnterprise enterprise;

    private FractalSqlIndex index;

    @Inject
    public FractalSqlAgents(FractalSqlService service, ReasoningBridge reasoning,
            FractalSqlEnterprise enterprise)
    {
        this.service = service;
        this.reasoning = reasoning;
        this.enterprise = enterprise;
    }

    /** The index tier the nearest-row agents search through when agent_use_index is on (optional: without it they scan exactly). */
    @Inject(optional = true)
    public void setIndex(FractalSqlIndex index)
    {
        this.index = index;
    }

    /**
     * agent_use_index: the nearest row of table.column to {@code query}, searched through the fractal_index that covers it. Off by
     * default (an index can, rarely, pick a different nearest row than the exact scan; every distance is still exact). Returns
     * {id, distance} (the id is null when {@code idColumn} is null), or null when the setting is off, no index covers the column, the
     * index's id column is not {@code idColumn}, or the index cannot answer: the caller then scans exactly.
     */
    Object[] indexNearest(String table, String column, String idColumn, double[] query)
    {
        return nearestViaIndex(service, index, table, column, idColumn, query);
    }

    static Object[] nearestViaIndex(FractalSqlService service, FractalSqlIndex index, String table, String column,
            String idColumn, double[] query)
    {
        final List<Object[]> top = topViaIndex(service, index, table, column, idColumn, query, 1);
        return top == null ? null : top.get(0);
    }

    /**
     * The {@code k} nearest rows of table.column to {@code query} through the index that covers it, under the same rules as
     * {@link #nearestViaIndex}: each entry is {id, distance} nearest first, every distance exact. Null when the setting is off, no
     * index covers the column, or the index cannot answer; the caller then scans exactly.
     */
    static List<Object[]> topViaIndex(FractalSqlService service, FractalSqlIndex index, String table, String column,
            String idColumn, double[] query, int k)
    {
        return topViaIndex(service, index, table, column, idColumn, query, k, null);
    }

    /** As above, restricted to the rows whose ids are in {@code ids} (the cohort); null means every row. */
    static List<Object[]> topViaIndex(FractalSqlService service, FractalSqlIndex index, String table, String column,
            String idColumn, double[] query, int k, java.util.Collection<?> ids)
    {
        if (index == null || !service.agentUseIndex()) {
            return null;
        }
        final String indexId = index.idColumnFor(table, column);
        if (indexId == null || (idColumn != null && !idColumn.equals(indexId))) {
            return null;
        }
        if (service.agentUseIndexMode() == 2 && !index.readyForAuto(table, column, service.agentIndexMinRows())) {
            return null;
        }
        final StringBuilder q = new StringBuilder("[");
        for (int i = 0; i < query.length; i++) {
            q.append(i == 0 ? "" : ",").append(query[i]);
        }
        q.append(']');
        try {
            final Map<String, Object> result = index.search(table, column, q.toString(), Math.max(1, k), ids == null ? "{}" : idsOption(ids));
            final List<?> hits = (List<?>) result.get("candidates");
            if (hits == null || hits.isEmpty()) {
                return null;
            }
            final List<Object[]> out = new ArrayList<>();
            for (Object o : hits) {
                if (!(o instanceof Map)) {
                    continue;
                }
                final Map<?, ?> hit = (Map<?, ?>) o;
                final Object id = hit.get("doc_id");
                final Object distance = hit.get("distance");
                if (!(distance instanceof Number)) {
                    continue;
                }
                final Object normalised = id instanceof Number && ((Number) id).doubleValue() == Math.rint(((Number) id).doubleValue())
                        ? (Object) Long.valueOf(((Number) id).longValue()) : id;
                out.add(new Object[]{normalised, ((Number) distance).doubleValue()});
                if (out.size() >= k) {
                    break;
                }
            }
            return out.isEmpty() ? null : out;
        } catch (Exception e) {
            return null;
        }
    }

    private static String idsOption(java.util.Collection<?> ids)
    {
        final StringBuilder sb = new StringBuilder("{\"ids\":[");
        boolean first = true;
        for (Object id : ids) {
            if (!(id instanceof Number)) {
                continue;
            }
            sb.append(first ? "" : ",").append(((Number) id).longValue());
            first = false;
        }
        return sb.append("]}").toString();
    }

    /** The retrieval document of an index answer: {"top_k":[{"doc_id":..,"dist":..}],"used_index":true}. */
    private String indexRetrieval(List<Object[]> top) throws Exception
    {
        final List<Map<String, Object>> rows = new ArrayList<>();
        for (Object[] t : top) {
            final Map<String, Object> m = new LinkedHashMap<>();
            m.put("doc_id", t[0]);
            m.put("dist", t[1]);
            rows.add(m);
        }
        final Map<String, Object> doc = new LinkedHashMap<>();
        doc.put("top_k", rows);
        doc.put("used_index", true);
        return service.mapper().writeValueAsString(doc);
    }

    /**
     * Run one agent.
     *
     * @param name the agent's name, without the {@code fractal_agent_}
     *             prefix
     * @param args the agent's arguments, by name
     */
    public Map<String, Object> run(String name, Map<String, Object> args) throws Exception
    {
        // The documented argument is id_col; the demo kits also write id_column.
        // Either spelling names the identity column.
        if (args.get("id_col") != null && args.get("id_column") == null) {
            args = new java.util.LinkedHashMap<>(args);
            args.put("id_column", args.get("id_col"));
        } else if (args.get("id_column") != null && args.get("id_col") == null) {
            args = new java.util.LinkedHashMap<>(args);
            args.put("id_col", args.get("id_column"));
        }
        // The MCP and the SQL-style callers name the retrieval agents' arguments table_name, vector_col and pop_size; the endpoint says
        // table, col and population_size. Either spelling works, and an empty meta_filter ("" or "{}") means no filter.
        if (name.equals("search_agent") || name.equals("rag_agent")) {
            args = new java.util.LinkedHashMap<>(args);
            alias(args, "table_name", "table");
            alias(args, "vector_col", "col");
            alias(args, "pop_size", "population_size");
            final Object mf = args.get("meta_filter");
            if (mf != null && (mf.toString().trim().isEmpty() || mf.toString().trim().equals("{}"))) {
                args.remove("meta_filter");
            }
        }
        switch (name) {
            case "anomaly_triage":
                return anomalyTriage(args);
            case "allocate":
                return allocate(args);
            case "route_task":
                return routeTask(args);
            case "outlier_intercept":
                return outlierIntercept(args);
            case "outlier_screen":
                return outlierScreen(args);
            case "recall_hybrid":
                return recallHybrid(args);
            case "recommend_diverse":
                return recommendDiverse(args);
            case "detect_loop":
                return detectLoop(args);
            case "trajectory_predict":
                return trajectoryPredict(args);
            case "plan_explore":
                return planExplore(args);
            case "data_analyst":
                return dataAnalyst(args);
            case "search_agent":
                return searchAgent(args);
            case "rag_agent":
                return ragAgent(args);
            case "detour_classify":
                return FractalSqlAgents2.detourClassify(service, reasoning, args);
            case "track_anomaly":
                return FractalSqlAgents2.trackAnomaly(service, reasoning, args);
            case "schedule_workload":
                return FractalSqlAgents2.scheduleWorkload(service, reasoning, index, args);
            case "network_coverage_alert":
                return FractalSqlAgents2.networkCoverageAlert(service, reasoning, args);
            case "patient_deterioration_triage":
                return FractalSqlAgents2.patientDeteriorationTriage(service, reasoning, args);
            case "rebalance_sibling":
                return FractalSqlAgents2.rebalanceSibling(service, reasoning, args);
            case "feedback_audit":
                return FractalSqlAgents3.feedbackAudit(service, reasoning, args);
            case "regime_triage":
                return FractalSqlAgents3.regimeTriage(service, reasoning, args);
            case "diverse_portfolios":
                return FractalSqlAgents3.diversePortfolios(service, reasoning, enterprise, args);
            case "sql_agent":
                return FractalSqlAgents3.sqlAgent(service, reasoning, args);
            default:
                throw new IllegalArgumentException("fractalsql: no such agent: " + name);
        }
    }

    // -- the sixteen composite agents ----------------------------------

    /**
     * Engine A: the anomaly triage.
     *
     * <p>The entity's metric series, its regime-change drift, and a
     * one-line triage.
     */
    private Map<String, Object> anomalyTriage(Map<String, Object> args) throws Exception
    {
        final String table = required(args, "log_table");
        final String metric = required(args, "metric_col");
        final String time = required(args, "time_col");
        final String filterCol = required(args, "filter_col");
        final String filterVal = required(args, "filter_val");
        final int window = integer(args, "baseline_window", 32);

        final double[] series = metricSeries(table, metric, time, filterCol, filterVal);
        if (series.length == 0) {
            throw new IllegalArgumentException(
                    "fractalsql: fractal_agent_anomaly_triage: no rows in " + table + "." + metric
                            + " matching " + filterCol + " = " + filterVal);
        }
        // The drift is signed; a series too short for the window has none, which reads as 0, as the SQL surface does.
        final double rawDrift = drift(series, window);
        final double threat = Double.isNaN(rawDrift) ? 0.0 : rawDrift;

        final Map<String, Object> out = new LinkedHashMap<>();
        out.put("threat_score", threat);
        out.put("anomaly_type", "vector_drift");
        final String prompt = String.format(
                "Triage this anomaly: drift score %.10f", threat);
        final String context = "{\"table\":\"" + table + "\",\"filter\":\"" + filterVal + "\"}";
        out.put("triage_summary", reasoning.reason(prompt, context));
        return out;
    }

    /**
     * Engine B: the cardinality-constrained allocation.
     *
     * <p>The optimizer's own result, its Sharpe ratio, and the
     * rationale.
     */
    private Map<String, Object> allocate(Map<String, Object> args) throws Exception
    {
        final double[] mu;
        final double[] cov;
        if (args.get("mu") != null && args.get("cov") != null) {
            mu = vector(required(args, "mu"));
            cov = vector(required(args, "cov"));
        } else if (args.get("mu_table") != null && args.get("cov_table") != null) {
            // The vectors come from datasources the caller computed:
            // one row each, holding the vector as text.
            mu = vector(oneCell(required(args, "mu_table"), required(args, "mu_column")));
            cov = vector(oneCell(required(args, "cov_table"), required(args, "cov_column")));
        } else {
            // The portfolio's own profile: the mean and the variance of
            // each entity's series, with the variance scaled by the
            // series' DFA exponent -- the risk matrix the vertical
            // kits build.
            final double[][] profile = profile(
                    required(args, "table"), required(args, "column"),
                    args.get("entity_column") == null ? "ent" : args.get("entity_column").toString());
            final int n = profile.length;
            mu = new double[n];
            cov = new double[n * n];
            for (int i = 0; i < n; i++) {
                mu[i] = profile[i][0];
                final double risk = profile[i][1] * profile[i][2];
                for (int j = 0; j < n; j++) {
                    cov[i * n + j] = i == j ? risk : 0.0;
                }
            }
        }
        final int cardinality = integer(args, "cardinality", 1);
        final String context = args.get("context") == null ? "{}" : args.get("context").toString();

        final double[] out = new double[FractalFn.OUT_SIZE];
        final double sharpe = Native.callFn(
                8, mu, mu.length, cov, cov.length, null, 0,
                cardinality, 0, 0, out);
        final String allocation = optimizeDocument(sharpe, cov, cardinality, out);

        final Map<String, Object> doc = new LinkedHashMap<>();
        doc.put("allocation", allocation);
        doc.put("sharpe", sharpe);
        doc.put("rationale", reasoning.reason(
                "Explain this cardinality-constrained allocation and its risk/return: "
                        + allocation, context));
        return doc;
    }

    /**
     * Engine C: the task router.
     *
     * <p>The capability whose embedding is nearest the task's, the
     * confidence (1/(1+distance)), and what is left of the budget.
     */
    private Map<String, Object> routeTask(Map<String, Object> args) throws Exception
    {
        if (args.get("task_table") != null) {
            // A whole table of tasks: every row is routed, and the
            // result is one row per task.
            return routeScreen(args);
        }
        final double[] task = vector(required(args, "task_emb"));
        final String table = required(args, "cap_table");
        final String embColumn = required(args, "cap_emb_col");
        final String idColumn = required(args, "cap_id_col");
        final int budget = integer(args, "budget", 0);
        final int cost = integer(args, "cost_per_route", 150);

        Object nearest = null;
        double best = Double.POSITIVE_INFINITY;
        final Object[] viaIndex = indexNearest(table, embColumn, idColumn, task);
        if (viaIndex != null) {
            nearest = viaIndex[0];
            best = (Double) viaIndex[1];
        } else {
            final List<Object[]> rows = service.corpusRows(table, embColumn, idColumn, null);
            if (rows.isEmpty()) {
                throw new IllegalArgumentException(
                        "fractalsql: fractal_agent_route_task: no capability rows in " + table);
            }
            for (Object[] row : rows) {
                final double[] v = (double[]) row[0];
                if (v.length != task.length) {
                    continue;
                }
                final double d = Native.cosineDistance(v, task);
                if (d < best) {
                    best = d;
                    nearest = row[1];
                }
            }
        }
        final String routedTo = nearest == null ? null : nearest.toString();
        final double confidence = 1.0 / (1.0 + best);

        final Map<String, Object> doc = new LinkedHashMap<>();
        doc.put("routed_to", routedTo);
        doc.put("confidence", confidence);
        doc.put("remaining_budget", budget - cost);
        doc.put("rationale", reasoning.reason(
                String.format("Route this task to capability %s (cosine distance %.10f). "
                        + "Justify the routing in one sentence.",
                        routedTo == null ? "?" : routedTo, best),
                "{\"budget\":" + budget + ",\"cost_per_route\":" + cost + "}"));
        return doc;
    }

    /**
     * The router, over a table of tasks.
     *
     * <p>Each task is routed to the capability whose embedding is
     * nearest its own, and the result is one row per task -- the shape
     * a demo's own table needs.
     */
    private Map<String, Object> routeScreen(Map<String, Object> args) throws Exception
    {
        final String taskTable = required(args, "task_table");
        final String taskColumn = required(args, "task_column");
        final String capTable = required(args, "cap_table");
        final String capColumn = required(args, "cap_emb_col");
        final String idColumn = required(args, "cap_id_col");
        final int budget = integer(args, "budget", 0);
        final int cost = integer(args, "cost_per_route", 150);

        final List<Object[]> capabilities = service.corpusRows(capTable, capColumn, idColumn, null);
        if (capabilities.isEmpty()) {
            throw new IllegalArgumentException(
                    "fractalsql: fractal_agent_route_task: no capability rows in " + capTable);
        }
        final String taskId = args.get("task_id_column") == null
                ? null : args.get("task_id_column").toString();
        final String taskLabel = args.get("task_label_column") == null
                ? null : args.get("task_label_column").toString();

        final List<Object[]> tasks = service.corpusRows(taskTable, taskColumn, taskId, null);
        final List<Map<String, Object>> rows = new ArrayList<>();
        for (Object[] task : tasks) {
            final double[] v = (double[]) task[0];
            Object nearest = null;
            double best = Double.POSITIVE_INFINITY;
            for (Object[] capability : capabilities) {
                final double[] c = (double[]) capability[0];
                if (c.length != v.length) {
                    continue;
                }
                final double d = Native.cosineDistance(c, v);
                if (d < best) {
                    best = d;
                    nearest = capability[1];
                }
            }
            final Map<String, Object> row = new LinkedHashMap<>();
            if (taskId != null) {
                row.put("req_id", task[1]);
            }
            if (taskLabel != null) {
                row.put("label", task[1]);
            }
            row.put("routed_to", nearest);
            row.put("confidence", 1.0 / (1.0 + best));
            row.put("remaining_budget", budget - cost);
            rows.add(row);
        }

        final Map<String, Object> doc = new LinkedHashMap<>();
        doc.put("rows", rows);
        doc.put("n_tasks", tasks.size());
        return doc;
    }

    /**
     * Engine D: the outlier interceptor.
     *
     * <p>Whether the state vector is far enough from the history to be
     * worth stopping, in the metric the caller named.
     */
    private Map<String, Object> outlierIntercept(Map<String, Object> args) throws Exception
    {
        final double[] state = vector(required(args, "state_vec"));
        final String table = required(args, "history_table");
        final String embColumn = required(args, "emb_col");
        final double threshold = number(args, "threshold", 0.5);
        final String metric = args.get("metric") == null ? "cosine" : args.get("metric").toString().toLowerCase();
        if (!"cosine".equals(metric) && !"l2".equals(metric)) {
            throw new IllegalArgumentException(
                    "fractalsql: fractal_agent_outlier_intercept: metric must be 'cosine' or 'l2'");
        }

        double nearest = Double.POSITIVE_INFINITY;
        final Object[] viaIndex = "l2".equals(metric) ? null : indexNearest(table, embColumn, null, state);
        if (viaIndex != null) {
            nearest = (Double) viaIndex[1];
        } else {
            final List<Object[]> rows = service.corpusRows(table, embColumn, null, null);
            for (Object[] row : rows) {
                final double[] v = (double[]) row[0];
                if (v.length != state.length) {
                    continue;
                }
                final double d = "l2".equals(metric)
                        ? Native.callFn(20, v, v.length, state, state.length, null, 0, 0, 0, 0, null)
                        : Native.callFn(22, v, v.length, state, state.length, null, 0, 0, 0, 0, null);
                if (d < nearest) {
                    nearest = d;
                }
            }
        }
        if (Double.isInfinite(nearest)) {
            throw new IllegalArgumentException(
                    "fractalsql: fractal_agent_outlier_intercept: no history rows in " + table);
        }
        final boolean intercepted = nearest < threshold;

        final Map<String, Object> doc = new LinkedHashMap<>();
        doc.put("intercepted", intercepted);
        doc.put("metric", metric);
        doc.put("reason", String.format(
                "%s distance to the nearest known state is %.10f (threshold %.10f): %s",
                metric, nearest, threshold,
                intercepted ? "INTERCEPT" : "allow"));
        return doc;
    }

    /**
     * Engine E: the hybrid recall.
     *
     * <p>The k nearest remembered states, filtered by the caller's
     * cohort.
     */
    private Map<String, Object> recallHybrid(Map<String, Object> args) throws Exception
    {
        final String table = required(args, "mem_table");
        final String vecColumn = required(args, "vec_col");
        final double[] query = vector(required(args, "query_vec"));
        final String idColumn = required(args, "id_col");
        final String filterColumn = args.get("filter_col") == null ? null : args.get("filter_col").toString();
        final String filterValue = args.get("filter_val") == null ? null : args.get("filter_val").toString();
        final int k = integer(args, "k", 5);

        final String filter = filterColumn == null || filterValue == null
                ? null
                : equalsFilter(filterColumn, filterValue);
        final List<Object[]> rows = service.corpusRows(table, vecColumn, idColumn, filter);
        List<Object[]> scored = new ArrayList<>();
        // agent_use_index: the cohort becomes the index's ids set; every distance is still exact. Null (off, no covering index, or an index
        // that cannot answer) falls back to the exact cohort scan below.
        boolean usedIndex = false;
        if (!rows.isEmpty()) {
            final List<Object> cohort = new ArrayList<>();
            for (Object[] row : rows) {
                cohort.add(row[1]);
            }
            final List<Object[]> viaIndex = topViaIndex(service, index, table, vecColumn, idColumn, query, k, cohort);
            if (viaIndex != null) {
                scored = new ArrayList<>();
                for (Object[] h : viaIndex) {
                    scored.add(new Object[]{h[1], h[0]});
                }
                usedIndex = true;
            }
        }
        if (!usedIndex) {
            for (Object[] row : rows) {
                final double[] v = (double[]) row[0];
                if (v.length != query.length) {
                    continue;
                }
                scored.add(new Object[]{Native.cosineDistance(v, query), row[1]});
            }
            scored.sort((a, b) -> Double.compare((Double) a[0], (Double) b[0]));
        }
        final List<Map<String, Object>> hits = new ArrayList<>();
        for (int i = 0; i < Math.min(k, scored.size()); i++) {
            final Map<String, Object> hit = new LinkedHashMap<>();
            hit.put("doc_id", scored.get(i)[1]);
            hit.put("distance", scored.get(i)[0]);
            hits.add(hit);
        }
        final Map<String, Object> doc = new LinkedHashMap<>();
        doc.put("memories", hits);
        doc.put("rows", hits);
        doc.put("n_corpus", rows.size());
        doc.put("used_index", usedIndex);
        return doc;
    }

    /**
     * Engine F: the diverse recommender.
     *
     * <p>The catalogue's items, ranked by the SFS's diversified
     * population rather than by raw distance.
     */
    private Map<String, Object> recommendDiverse(Map<String, Object> args) throws Exception
    {
        final String table = required(args, "catalog_table");
        final String embColumn = required(args, "emb_col");
        final double[] query = vector(required(args, "query_vec"));
        final int k = integer(args, "k", 3);
        final String idColumn = args.get("id_col") == null ? null : args.get("id_col").toString();

        final List<Object[]> rows = service.corpusRows(table, embColumn, idColumn, null);
        if (rows.isEmpty()) {
            throw new IllegalArgumentException(
                    "fractalsql: fractal_agent_recommend_diverse: no rows in " + table);
        }
        final int dim = ((double[]) rows.get(0)[0]).length;
        final double[] corpus = new double[rows.size() * dim];
        for (int i = 0; i < rows.size(); i++) {
            final double[] v = (double[]) rows.get(i)[0];
            System.arraycopy(v, 0, corpus, i * dim, Math.min(dim, v.length));
        }
        final String result = service.searchDocument(corpus, rows.size(), dim, query, k,
                "{\"population_size\":" + Math.max(k, 2) + ",\"iterations\":15,"
                        + "\"walk\":0,\"return_population\":true,\"bound_clipping\":true}");

        final Map<String, Object> doc = new LinkedHashMap<>();
        doc.put("result", result);
        doc.put("n_corpus", rows.size());
        // The items the population chose, each scored by its closeness
        // to the query: returned as a JSON array of
        // {item_id, score}.
        final List<Map<String, Object>> items = new ArrayList<>();
        for (Map<String, Object> picked : FractalSqlService.matchPopulation(result, rows)) {
            final Object id = picked.get("doc_id");
            double score = 0;
            for (Object[] row : rows) {
                if (row[1] != null && id != null && row[1].equals(id)) {
                    final double[] v = (double[]) row[0];
                    if (v.length == query.length) {
                        score = 1.0 - Native.cosineDistance(v, query);
                    }
                    break;
                }
            }
            final Map<String, Object> item = new LinkedHashMap<>();
            item.put("item_id", id);
            item.put("score", score);
            items.add(item);
        }
        doc.put("items", items);
        return doc;
    }

    /**
     * The outlier screen: every proposed session against the known
     * signatures.
     *
     * <p>The same computation as {@link #outlierIntercept}, run over
     * a whole table, so the result can be materialised and queried.
     */
    private Map<String, Object> outlierScreen(Map<String, Object> args) throws Exception
    {
        final String table = required(args, "proposed_table");
        final String stateColumn = required(args, "state_column");
        final String idColumn = args.get("id_column") == null ? null : args.get("id_column").toString();
        final String labelColumn = args.get("label_column") == null ? null : args.get("label_column").toString();
        final String historyTable = required(args, "history_table");
        final String embColumn = required(args, "emb_column");
        final double threshold = number(args, "threshold", 0.5);
        final String metric = args.get("metric") == null ? "cosine" : args.get("metric").toString();

        final String historyIdColumn = args.get("history_id_column") == null
                ? "id" : args.get("history_id_column").toString();
        final List<Object[]> history =
                service.corpusRows(historyTable, embColumn, historyIdColumn, null);
        if (history.isEmpty()) {
            throw new IllegalArgumentException(
                    "fractalsql: no history rows in " + historyTable);
        }
        final List<Object[]> proposed = service.corpusRows(
                table, stateColumn, idColumn == null ? null : idColumn, null);

        final List<Map<String, Object>> rows = new ArrayList<>();
        for (Object[] row : proposed) {
            final double[] state = (double[]) row[0];
            double nearest = Double.POSITIVE_INFINITY;
            Object nearestId = null;
            for (Object[] known : history) {
                final double[] v = (double[]) known[0];
                if (v.length != state.length) {
                    continue;
                }
                final double d = "l2".equalsIgnoreCase(metric)
                        ? Native.callFn(20, v, v.length, state, state.length, null, 0, 0, 0, 0, null)
                        : Native.cosineDistance(v, state);
                if (d < nearest) {
                    nearest = d;
                    nearestId = known[1];
                }
            }
            final Map<String, Object> out = new LinkedHashMap<>();
            if (idColumn != null) {
                out.put("id", row[1]);
            }
            if (labelColumn != null) {
                out.put("label", row[1]);
            }
            out.put("intercepted", nearest < threshold);
            out.put("metric", metric);
            out.put("distance", nearest);
            // The known signature the event matched, so a caller can
            // join back to the history.
            out.put("doc_id", nearestId);
            rows.add(out);
        }

        final Map<String, Object> doc = new LinkedHashMap<>();
        doc.put("rows", rows);
        doc.put("n_proposed", proposed.size());
        return doc;
    }

    // -- the universal agents -------------------------------------------

    /**
     * The loop detector: whether the agent's state log repeats.
     *
     * <p>The fingerprints are the state's own; the comparison is the
     * Hamming distance between them.
     */
    private Map<String, Object> detectLoop(Map<String, Object> args) throws Exception
    {
        final String agentId = required(args, "agent_id");
        final String stateLog = args.get("state_log") != null
                ? required(args, "state_log")
                : oneCell(required(args, "state_log_table"), required(args, "state_log_column"));
        final int dim = integer(args, "dim", 0);
        final int bits = integer(args, "n_bits", 64);
        final double[] series = vector(stateLog);
        if (dim <= 0) {
            throw new IllegalArgumentException("fractalsql: dim must be > 0");
        }
        if (bits <= 0 || bits > 33554424) {
            throw new IllegalArgumentException("fractalsql: n_bits must be between 1 and 33554424");
        }
        if (integer(args, "hamming_threshold", 3) < 0) {
            throw new IllegalArgumentException("fractalsql: hamming_threshold must be >= 0");
        }
        if (series.length % dim != 0) {
            throw new IllegalArgumentException("fractalsql: state_log length (" + series.length
                    + ") is not a multiple of dim (" + dim + ")");
        }
        if (series.length / dim < 2) {
            throw new IllegalArgumentException("fractalsql: state_log must contain at least 2 states");
        }
        if ((long) series.length * bits > 268435456L) {
            throw new IllegalArgumentException(
                    "fractalsql: state_log length x n_bits must not exceed 268435456");
        }

        // Each state is fingerprinted, and the fingerprint sequence is
        // walked with Brent's cycle detection: an actor that repeats
        // itself shows a cycle in the sequence, whether it repeats
        // exactly or only nearly.
        final List<double[]> fingerprints = new ArrayList<>();
        for (int i = 0; i + dim <= series.length; i += Math.max(dim, 1)) {
            final double[] row = new double[dim];
            System.arraycopy(series, i, row, 0, dim);
            fingerprints.add(fingerprint(row, bits));
        }
        int closest = Integer.MAX_VALUE;
        for (int i = 0; i < fingerprints.size(); i++) {
            for (int j = i + 1; j < fingerprints.size(); j++) {
                final int d = hamming(fingerprints.get(i), fingerprints.get(j));
                if (d < closest) {
                    closest = d;
                }
            }
        }
        final int threshold = integer(args, "hamming_threshold", 3);
        // The cycle itself is the CORE's detector -- the same one the
        // SQL surface and the other editions use. The extension used to
        // reimplement Brent's algorithm, and its second walk had no
        // bound: on a state log whose fingerprints never line up it
        // looped for ever, which showed up as an agent call that never
        // answered. The core's streaming detector terminates.
        final byte[][] packed = new byte[fingerprints.size()][];
        for (int i = 0; i < fingerprints.size(); i++) {
            packed[i] = pack(fingerprints.get(i));
        }
        final int[] cycle = coreCycle(packed, bits, threshold);
        // The DFA runs over each state's L2 norm across the log: a
        // continuous signal, where the raw flat values are not.
        final double[] norms = new double[fingerprints.size()];
        for (int i = 0; i < norms.length; i++) {
            double sumsq = 0.0;
            for (int j = 0; j < dim; j++) {
                final double x = series[i * dim + j];
                sumsq += x * x;
            }
            norms[i] = Math.sqrt(sumsq);
        }
        final double rawAlpha = dfa(norms);
        // A log too short or too flat for the DFA reports 0, as the SQL surface does.
        final double alpha = Double.isNaN(rawAlpha) ? 0.0 : rawAlpha;
        final boolean detected = cycle[2] == 1 || alpha > 0.9;

        final Map<String, Object> doc = new LinkedHashMap<>();
        doc.put("agent_id", agentId);
        doc.put("is_loop_detected", detected);
        doc.put("dfa_exponent", alpha);
        doc.put("cycle_length", cycle[1]);
        doc.put("min_hamming_distance", closest == Integer.MAX_VALUE ? null : (double) closest);
        doc.put("n_states", fingerprints.size());
        return doc;
    }

    /**
     * The fingerprint bytes, packed back into a byte array.
     *
     * <p>The fingerprint comes back from the core as one number per
     * byte; the core's cycle detector wants the bytes themselves.
     */
    private static byte[] pack(double[] fingerprint)
    {
        final byte[] out = new byte[fingerprint.length];
        for (int i = 0; i < fingerprint.length; i++) {
            out[i] = (byte) (int) fingerprint[i];
        }
        return out;
    }

    /**
     * The core's cycle verdict for a fingerprint sequence.
     *
     * @return {cycleStart, cycleLength}; a length of 0 or 1 means no
     *         cycle was found
     */
    private static int[] coreCycle(byte[][] fingerprints, int bits, int threshold)
    {
        if (fingerprints.length < 2) {
            return new int[]{0, fingerprints.length, 0};
        }
        NativeLoader.load();
        final String verdict = Native.cycleDetect(fingerprints, bits, threshold);
        if (verdict == null) {
            return new int[]{0, 1, 0};
        }
        try {
            final com.fasterxml.jackson.databind.JsonNode root =
                    new com.fasterxml.jackson.databind.ObjectMapper().readTree(verdict);
            final boolean detected = root.path("cycle_detected").asBoolean(false);
            final int length = root.path("cycle_length").asInt(0);
            final int start = root.path("cycle_start").asInt(0);
            return new int[]{detected ? start : 0, detected ? length : 1, detected ? 1 : 0};
        } catch (Exception e) {
            return new int[]{0, 1, 0};
        }
    }

    /**
     * The trajectory predictor: where the entity is heading.
     */
    private Map<String, Object> trajectoryPredict(Map<String, Object> args) throws Exception
    {
        final String table = required(args, "table");
        final String column = required(args, "col");
        final String id = required(args, "id");
        final int steps = integer(args, "steps", 8);

        final List<Object[]> rows = service.corpusRows(table, column, null, null);
        if (rows.isEmpty()) {
            throw new IllegalArgumentException(
                    "fractalsql: fractal_agent_trajectory_predict: no rows in " + table);
        }
        final int dim = ((double[]) rows.get(0)[0]).length;
        final double[] last = (double[]) rows.get(rows.size() - 1)[0];
        final double[] velocity = new double[dim];
        if (rows.size() >= 2) {
            final double[] prev = (double[]) rows.get(rows.size() - 2)[0];
            for (int i = 0; i < dim; i++) {
                velocity[i] = last[i] - prev[i];
            }
        }
        final double[] predicted = new double[dim];
        for (int i = 0; i < dim; i++) {
            predicted[i] = last[i] + steps * velocity[i];
        }

        final Map<String, Object> doc = new LinkedHashMap<>();
        doc.put("id", id);
        doc.put("current", last);
        doc.put("velocity", velocity);
        doc.put("predicted", predicted);
        doc.put("steps", steps);
        return doc;
    }

    /**
     * The planner: the branches to explore, with their scores.
     */
    private Map<String, Object> planExplore(Map<String, Object> args) throws Exception
    {
        final String state = required(args, "state");
        final String table = required(args, "table");
        final String column = required(args, "col");
        final int branches = integer(args, "branches", 3);

        final List<Object[]> rows = service.corpusRows(table, column, null, null);
        if (rows.isEmpty()) {
            throw new IllegalArgumentException(
                    "fractalsql: fractal_agent_plan_explore: no rows in " + table);
        }
        final double[] query = vector(state);
        // agent_use_index: the nearest rows through an index built over the rows' positions (no id column), so the ids it returns are the
        // positions the full scan reports. Every distance is exact. Null (off, no such index, or it cannot answer) scans every row below.
        final List<Object[]> viaIndex = topViaIndex(service, index, table, column, "", query, Math.max(branches, 1));
        if (viaIndex != null) {
            final List<Map<String, Object>> top = new ArrayList<>();
            for (Object[] h : viaIndex) {
                final Map<String, Object> m = new LinkedHashMap<>();
                m.put("idx", h[0]);
                m.put("dist", h[1]);
                top.add(m);
            }
            final Map<String, Object> found = new LinkedHashMap<>();
            found.put("top_k", top);
            final Map<String, Object> doc = new LinkedHashMap<>();
            doc.put("state", state);
            doc.put("branches", branches);
            doc.put("result", service.mapper().writeValueAsString(found));
            doc.put("used_index", true);
            return doc;
        }
        final int dim = ((double[]) rows.get(0)[0]).length;
        final double[] corpus = new double[rows.size() * dim];
        for (int i = 0; i < rows.size(); i++) {
            final double[] v = (double[]) rows.get(i)[0];
            System.arraycopy(v, 0, corpus, i * dim, Math.min(dim, v.length));
        }
        final String result = service.searchDocument(corpus, rows.size(), dim, query,
                Math.max(branches, 1),
                "{\"population_size\":" + Math.max(branches, 2) + ",\"iterations\":15,"
                        + "\"walk\":0,\"return_population\":true,\"bound_clipping\":true}");

        final Map<String, Object> doc = new LinkedHashMap<>();
        doc.put("state", state);
        doc.put("branches", branches);
        doc.put("result", result);
        doc.put("used_index", false);
        return doc;
    }

    /**
     * The data analyst: a question answered against the named tables.
     *
     * <p>The SQL is generated and validated against Druid's own parser
     * (with {@code EXPLAIN PLAN FOR}), so the statement that runs is
     * one Druid accepts.
     */
    private Map<String, Object> dataAnalyst(Map<String, Object> args) throws Exception
    {
        final String question = required(args, "question");
        final int retries = integer(args, "max_retries", 2);

        // The schema goes to the model WITH the question. Naming the
        // tables is not enough: a model that is not told what the
        // columns are invents a table of its own, and the statement
        // then fails to plan -- which is a retry of the same mistake,
        // because the retry sees the same prompt.
        final java.util.List<String> tableList = FractalSqlAgents3.tableNames(args);
        final String tables = tableList.isEmpty() ? "" : String.join(", ", tableList);
        final String schema = FractalSqlAgents3.schemaContext(service, tableList);

        String sql = null;
        String failure = null;
        for (int attempt = 0; attempt <= retries && sql == null; attempt++) {
            final String prompt = "Write a single Druid SQL SELECT statement that answers this "
                    + "question over these tables: " + tables + ". Use ONLY those tables, and "
                    + "only the columns they have. Question: " + question
                    + (failure == null ? "" : " The previous attempt failed: " + failure);
            final String generated = reasoning.reasonForStatement(prompt, schema);
            if (generated == null) {
                throw new IllegalStateException(
                        "fractalsql: no reasoning provider is configured, or the call failed");
            }
            final String candidate = extractSql(generated);
            if (candidate == null) {
                failure = "the answer did not contain a SQL statement";
                continue;
            }
            try {
                service.query("EXPLAIN PLAN FOR " + candidate);
                sql = candidate;
            } catch (Exception e) {
                // The retry sees its OWN rejected statement, not just
                // the planner's complaint: a model told only "it
                // failed" tends to write the same statement again.
                failure = "your statement was: " + candidate
                        + "\nIt failed because: " + e.getMessage();
            }
        }
        if (sql == null) {
            throw new IllegalStateException(
                    "fractalsql: fractal_agent_data_analyst: no valid statement after "
                            + (retries + 1) + " attempts: " + failure);
        }
        final List<Map<String, Object>> rows = service.query(sql);

        final Map<String, Object> doc = new LinkedHashMap<>();
        doc.put("question", question);
        doc.put("generated_sql", sql);
        doc.put("execution_status", "success");
        doc.put("result_rows", rows);
        doc.put("analysis", reasoning.reason(
                "Summarize this query result for the question: " + question,
                "{\"sql\":" + sql + ",\"rows\":" + service.mapper().writeValueAsString(rows) + "}"));
        return doc;
    }

    /**
     * The search agent: a question answered by searching a table's
     * embedding column.
     */
    private Map<String, Object> searchAgent(Map<String, Object> args) throws Exception
    {
        final String question = required(args, "query");
        final String table = required(args, "table");
        final String column = required(args, "col");
        final int population = integer(args, "population_size", 10);
        final int iterations = integer(args, "iterations", 5);

        final String metaFilter = args.get("meta_filter") == null
                ? null
                : structuredFilter(args.get("meta_filter").toString());
        final String idCol = args.get("id_col") == null ? null : args.get("id_col").toString();

        // agent_use_index: with no filter, the nearest rows come through the index that covers the column (the rows are not read)
        double[] early = null;
        if (metaFilter == null) {
            early = service.embedVector(question);
            if (early == null) {
                throw new IllegalStateException(
                        "fractalsql: no embedding provider is configured, or the call failed");
            }
            final List<Object[]> top = topViaIndex(service, index, table, column, idCol, early, Math.max(population, 1));
            if (top != null) {
                final Map<String, Object> doc = new LinkedHashMap<>();
                doc.put("question", question);
                doc.put("result", indexRetrieval(top));
                doc.put("n_corpus", null);
                doc.put("used_index", true);
                sourcesFromIndex(doc, top);
                return doc;
            }
        }

        final List<Object[]> rows = service.corpusRows(table, column, idCol, metaFilter);
        if (rows.isEmpty()) {
            throw new IllegalArgumentException(
                    "fractalsql: fractal_search_agent: no rows in " + table);
        }
        final double[] embedded = early != null ? early : service.embedVector(question);
        if (embedded == null) {
            throw new IllegalStateException(
                    "fractalsql: no embedding provider is configured, or the call failed");
        }
        final int dim = ((double[]) rows.get(0)[0]).length;
        final double[] corpus = new double[rows.size() * dim];
        for (int i = 0; i < rows.size(); i++) {
            final double[] v = (double[]) rows.get(i)[0];
            System.arraycopy(v, 0, corpus, i * dim, Math.min(dim, v.length));
        }
        final String result = service.searchDocument(corpus, rows.size(), dim, embedded,
                Math.max(population, 1),
                "{\"population_size\":" + Math.max(population, 2) + ",\"iterations\":" + iterations
                        + ",\"walk\":0,\"return_population\":true,\"bound_clipping\":true}");

        final Map<String, Object> doc = new LinkedHashMap<>();
        doc.put("question", question);
        doc.put("result", result);
        doc.put("n_corpus", rows.size());
        doc.put("used_index", false);
        sourcesFromScan(doc, result, rows);
        return doc;
    }

    /** A SQL identifier in double quotes, with any embedded double quote doubled. */
    static String quoteIdent(String name)
    {
        return "\"" + (name == null ? "" : name.replace("\"", "\"\"")) + "\"";
    }

    /** {@code "column" = 'value'}, both parts escaped. */
    static String equalsFilter(String column, String value)
    {
        return quoteIdent(column) + " = '" + (value == null ? "" : value.replace("'", "''")) + "'";
    }

    private static final java.util.regex.Pattern META_FILTER = java.util.regex.Pattern.compile(
            "\\s*(?:\"((?:[^\"]|\"\")+)\"|([A-Za-z_][A-Za-z0-9_]*))\\s*=\\s*'((?:[^']|'')*)'\\s*");

    /**
     * The metadata filter, which used to be spliced into the statement as a raw predicate. It is accepted only as
     * {@code column = 'literal'}, the column bare or in double quotes (the one form the agents document), and rebuilt from its parts; anything else, such as a
     * UNION or a comment, is refused.
     */
    static String structuredFilter(String raw)
    {
        final java.util.regex.Matcher m = META_FILTER.matcher(raw);
        if (!m.matches()) {
            throw new IllegalArgumentException(
                    "meta_filter must be of the form column = 'value' (a single equality test)");
        }
        final String column = m.group(1) != null ? m.group(1).replace("\"\"", "\"") : m.group(2);
        return equalsFilter(column, m.group(3).replace("''", "'"));
    }

    /**
     * The RAG agent: a question answered by retrieving from a table's
     * embedding column and reasoning over what came back.
     */
    private Map<String, Object> ragAgent(Map<String, Object> args) throws Exception
    {
        final String question = required(args, "query");
        final String table = required(args, "table");
        final String column = required(args, "col");
        final String metaFilter = args.get("meta_filter") == null
                ? null
                : structuredFilter(args.get("meta_filter").toString());

        final String idCol = args.get("id_col") == null ? null : args.get("id_col").toString();
        double[] early = null;
        if (metaFilter == null) {
            early = service.embedVector(question);
            if (early == null) {
                throw new IllegalStateException(
                        "fractalsql: no embedding provider is configured, or the call failed");
            }
            final List<Object[]> top = topViaIndex(service, index, table, column, idCol, early, 5);
            if (top != null) {
                final String retrieved = indexRetrieval(top);
                final Map<String, Object> doc = new LinkedHashMap<>();
                doc.put("question", question);
                doc.put("retrieval", retrieved);
                doc.put("answer", reasoning.reason(
                        "Answer the question from the retrieved documents: " + question,
                        "{\"retrieval\":" + retrieved + "}"));
                doc.put("used_index", true);
                sourcesFromIndex(doc, top);
                return doc;
            }
        }

        final List<Object[]> rows = service.corpusRows(table, column, idCol, metaFilter);
        if (rows.isEmpty()) {
            throw new IllegalArgumentException(
                    "fractalsql: fractal_rag_agent: no rows in " + table);
        }
        final double[] embedded = early != null ? early : service.embedVector(question);
        if (embedded == null) {
            throw new IllegalStateException(
                    "fractalsql: no embedding provider is configured, or the call failed");
        }
        final int dim = ((double[]) rows.get(0)[0]).length;
        final double[] corpus = new double[rows.size() * dim];
        for (int i = 0; i < rows.size(); i++) {
            final double[] v = (double[]) rows.get(i)[0];
            System.arraycopy(v, 0, corpus, i * dim, Math.min(dim, v.length));
        }
        final String result = service.searchDocument(corpus, rows.size(), dim, embedded, 5,
                "{\"population_size\":10,\"iterations\":15,\"walk\":0,"
                        + "\"return_population\":true,\"bound_clipping\":true}");

        final Map<String, Object> doc = new LinkedHashMap<>();
        doc.put("question", question);
        doc.put("retrieval", result);
        doc.put("answer", reasoning.reason(
                "Answer the question from the retrieved documents: " + question,
                "{\"retrieval\":" + result + "}"));
        doc.put("used_index", false);
        sourcesFromScan(doc, result, rows);
        return doc;
    }

    /**
     * source_row_ids for an answer that came through the index: the ids of the rows the index returned, best first (the
     * id column's values when the index was built with one, otherwise the row positions).
     */
    private static void sourcesFromIndex(Map<String, Object> doc, List<Object[]> top)
    {
        final List<Object> ids = new ArrayList<>();
        for (Object[] h : top) {
            ids.add(h[0]);
        }
        doc.put("source_row_ids", ids);
    }

    /**
     * source_row_ids for an answer that came from the scan: the rows' ids (the id column's values when id_col was given, otherwise their
     * positions in the corpus scan).
     */
    private void sourcesFromScan(Map<String, Object> doc, String result, List<Object[]> rows)
    {
        final List<Object> ids = new ArrayList<>();
        try {
            final com.fasterxml.jackson.databind.JsonNode top = service.mapper().readTree(result).get("top_k");
            if (top != null && top.isArray()) {
                for (com.fasterxml.jackson.databind.JsonNode n : top) {
                    final int idx = n.path("idx").asInt(-1);
                    if (idx < 0 || idx >= rows.size()) {
                        continue;
                    }
                    final Object id = rows.get(idx).length > 1 ? rows.get(idx)[1] : null;
                    ids.add(id == null ? (Object) idx : id);
                }
            }
        } catch (Exception e) {
            // no sources reported: the answer is unaffected
        }
        doc.put("source_row_ids", ids);
    }

    // -- the shared helpers ---------------------------------------------

    private static void alias(Map<String, Object> args, String from, String to)
    {
        if (args.get(to) == null && args.get(from) != null) {
            args.put(to, args.get(from));
        }
    }

    /** A required string argument. */
    private static String required(Map<String, Object> args, String name)
    {
        final Object value = args.get(name);
        if (value == null || value.toString().isEmpty()) {
            throw new IllegalArgumentException("fractalsql: the agent needs a \"" + name + "\"");
        }
        return value.toString();
    }

    /** An integer argument, or a fallback. */
    private static int integer(Map<String, Object> args, String name, int fallback)
    {
        final Object value = args.get(name);
        if (value instanceof Number) {
            return ((Number) value).intValue();
        }
        if (value != null) {
            try {
                return Integer.parseInt(value.toString().trim());
            } catch (NumberFormatException e) {
                return fallback;
            }
        }
        return fallback;
    }

    /** A row's numeric value, or a fallback. */
    private static double number(Object raw, double fallback)
    {
        if (raw instanceof Number) {
            return ((Number) raw).doubleValue();
        }
        if (raw != null) {
            try {
                return Double.parseDouble(raw.toString().trim());
            } catch (NumberFormatException e) {
                return fallback;
            }
        }
        return fallback;
    }

    /** A numeric argument, or a fallback. */
    private static double number(Map<String, Object> args, String name, double fallback)
    {
        final Object value = args.get(name);
        if (value instanceof Number) {
            return ((Number) value).doubleValue();
        }
        if (value != null) {
            try {
                return Double.parseDouble(value.toString().trim());
            } catch (NumberFormatException e) {
                return fallback;
            }
        }
        return fallback;
    }

    /** A vector argument, in the core's text form. */
    private static double[] vector(String text)
    {
        final double[] v = VectorText.parseVector(text);
        if (v == null) {
            throw new IllegalArgumentException(
                    "fractalsql: expected a CSV or bracketed-JSON vector, got: " + text);
        }
        return v;
    }

    /**
     * The entity's metric series, ordered by time.
     *
     * <p>The reference version read it with its own statement; here the
     * service asks Druid, which is the same query.
     */
    private double[] metricSeries(
            String table, String metricColumn, String timeColumn,
            String filterColumn, String filterValue) throws Exception
    {
        // Druid only lets a non-aggregating query order by __time, so a
        // time column that is not the row's timestamp is left in the
        // scan's order -- which is the order the rows were written in.
        final String order = "__time".equals(timeColumn)
                ? " ORDER BY \"__time\""
                : "";
        final String sql = "SELECT CAST(" + quoteIdent(metricColumn) + " AS DOUBLE) AS \"v\" FROM "
                + quoteIdent(table) + " WHERE " + equalsFilter(filterColumn, filterValue) + order;
        final List<Map<String, Object>> rows = service.query(sql);
        final List<Double> values = new ArrayList<>();
        for (Map<String, Object> row : rows) {
            final Object v = row.get("v");
            if (v instanceof Number) {
                values.add(((Number) v).doubleValue());
            }
        }
        final double[] out = new double[values.size()];
        for (int i = 0; i < out.length; i++) {
            out[i] = values.get(i);
        }
        return out;
    }

    /**
     * One cell of a one-row table: the text the caller stored there.
     */
    private String oneCell(String table, String column) throws Exception
    {
        final List<Map<String, Object>> rows = service.query(
                "SELECT \"" + column.replace("\"", "\"\"") + "\" AS \"v\" FROM \""
                        + table.replace("\"", "\"\"") + "\"");
        if (rows.isEmpty() || rows.get(0).get("v") == null) {
            throw new IllegalArgumentException(
                    "fractalsql: no value in " + table + "." + column);
        }
        return rows.get(0).get("v").toString();
    }

    /**
     * Each entity's profile: the mean, the variance and the DFA
     * exponent of its series.
     *
     * <p>One row per entity, in the order the datasource returns them.
     */
    private double[][] profile(String table, String column) throws Exception
    {
        return profile(table, column, "ent");
    }

    /**
     * Each entity's profile, with the entity column named by the caller.
     */
    private double[][] profile(String table, String column, String entityColumn) throws Exception
    {
        final String entity = entityColumn.replace("\"", "\"\"");
        final String sql = "SELECT \"" + entity + "\", AVG(\"v\") AS \"mean_v\", "
                + "AVG(\"v\" * \"v\") - AVG(\"v\") * AVG(\"v\") AS \"var_v\", "
                + "ARRAY_TO_STRING(ARRAY_AGG(CAST(\"v\" AS VARCHAR), 8192), ',') AS \"series\" "
                + "FROM (SELECT \"" + entity + "\", CAST(\"" + column + "\" AS DOUBLE) AS \"v\" "
                + "FROM \"" + table + "\") s "
                + "GROUP BY \"" + entity + "\"";
        final List<Map<String, Object>> rows = service.query(sql);
        final List<double[]> out = new ArrayList<>();
        for (Map<String, Object> row : rows) {
            final double mean = number(row.get("mean_v"), 0);
            final double variance = number(row.get("var_v"), 0);
            final double[] series = vector(String.valueOf(row.get("series")));
            out.add(new double[]{mean, variance, dfa(series)});
        }
        if (out.isEmpty()) {
            throw new IllegalArgumentException(
                    "fractalsql: fractal_agent_allocate: no rows in " + table);
        }
        return out.toArray(new double[0][]);
    }

    /** The core's DFA exponent for a series. */
    private static double dfa(double[] series)
    {
        NativeLoader.load();
        final double[] out = new double[FractalFn.OUT_SIZE];
        return Native.callFn(1, series, series.length, null, 0, null, 0, 0, 0, 0, out);
    }

    /** The core's regime-change drift for a series. */
    private static double drift(double[] series, int window)
    {
        NativeLoader.load();
        final double[] out = new double[FractalFn.OUT_SIZE];
        return Native.callFn(2, series, series.length, null, 0, null, 0,
                window, 0, 0, out);
    }

    /** The core's state fingerprint, as a bit vector. */
    private static double[] fingerprint(double[] state, int bits)
    {
        NativeLoader.load();
        final double[] out = new double[FractalFn.OUT_SIZE];
        final double[] packed = Native.callVec(10, state, state.length, null, 0, null, 0,
                bits, 0, 0);
        return packed == null ? new double[0] : packed;
    }

    /** The Hamming distance between two fingerprints, in bits (each element is one byte). */
    private static int hamming(double[] a, double[] b)
    {
        final int n = Math.min(a.length, b.length);
        int d = 0;
        for (int i = 0; i < n; i++) {
            d += Integer.bitCount(((int) a[i] ^ (int) b[i]) & 0xFF);
        }
        return d;
    }

    /** The optimizer's own result document. */
    private static String optimizeDocument(double sharpe, double[] cov, int cardinality, double[] out)
    {
        final StringBuilder json = new StringBuilder();
        json.append("{\"sharpe\":").append(sharpe);
        json.append(",\"weights\":[");
        final int n = (int) Math.round(Math.sqrt(cov.length));
        for (int i = 0; i < n && i + 1 < out.length; i++) {
            if (i > 0) {
                json.append(',');
            }
            json.append(out[i + 1]);
        }
        json.append("],\"cardinality\":").append(cardinality);
        json.append('}');
        return json.toString();
    }

    /** The SQL statement inside a model's answer, or null. */
    private static String extractSql(String answer)
    {
        if (answer == null) {
            return null;
        }
        final String trimmed = answer.trim();
        final int start = trimmed.toUpperCase(java.util.Locale.ROOT).indexOf("SELECT");
        if (start < 0) {
            return null;
        }
        int end = trimmed.indexOf(';', start);
        if (end < 0) {
            end = trimmed.length();
        }
        // A model that reaches for backticks is thinking of another
        // dialect; Druid quotes identifiers with double quotes. Without
        // this the statement is a lexical error, and the retry sees
        // the same prompt and writes the same backticks.
        return trimmed.substring(start, end).trim().replace("`", "\"");
    }
}
