/*
 * SPDX-License-Identifier: Apache-2.0
 * Copyright 2026 Daniel Gardiner d/b/a FractalSQLabs
 */
package com.fractalsqlabs.fractalsql.druid;

import com.fasterxml.jackson.databind.ObjectMapper;
import com.google.inject.Inject;
import com.google.inject.Provider;
import com.google.inject.Singleton;

import java.util.ArrayList;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.Properties;

/**
 * The service tier: the operations that cannot be SQL functions.
 *
 * <p>A Druid SQL function cannot issue another query, so the functions
 * that need to — the agents, text-to-SQL, the schema context, the
 * vectorizer's backfill — cannot be SQL functions at all. They are HTTP
 * operations on the extension, which the demo suite's runner and the MCP
 * server call.
 *
 * <p>Where this belongs in production is {@code fractalsqld}, so that a
 * slow provider cannot occupy a broker's query thread. It is here because the
 * service tier has to be exercisable now.
 */
@Singleton
public class FractalSqlService {

    private final FractalSqlConfig config;
    private final ReasoningBridge reasoning;
    private final Properties properties;
    private final ObjectMapper mapper = new ObjectMapper();

    @Inject
    public FractalSqlService(
            FractalSqlConfig config,
            ReasoningBridge reasoning,
            Provider<Properties> properties)
    {
        this.config = config;
        this.reasoning = reasoning;
        this.properties = properties.get();
    }

    /**
     * The extension's state.
     *
     * <p>What a client needs before it calls anything: how many functions
     * are registered, whether a provider is configured, and what the
     * operator's configuration is. The credentials are redacted by
     * {@link FractalSqlConfig#describe()}.
     */
    public Map<String, Object> health()
    {
        final Map<String, Object> out = new LinkedHashMap<>();
        out.put("status", "ok");
        out.put("edition", "druid");
        out.put("functions", FractalFn.all().size());
        out.put("providerConfigured", reasoning.isConfigured());
        out.put("config", config.describe());
        return out;
    }

    /**
     * Ask the provider a question.
     *
     * @param query the question
     * @param context extra context, as text; may be null
     * @return the answer, or null if no provider is configured
     */
    public String reason(String query, String context)
    {
        return reasoning.reason(query, context);
    }

    /**
     * Embed a piece of text.
     *
     * @return the embedding, in the core's JSON text form, or null
     */
    public String embed(String text)
    {
        return reasoning.embed(text);
    }

    /** The mapper the resource uses for its bodies. */
    /** agent_use_index (druid.fractalsql.agent_use_index, off by default): the nearest-row agents search through a fractal_index. */
    public boolean agentUseIndex()
    {
        return config.agentUseIndexMode() != 0;
    }

    /** 0 off, 1 on, 2 auto (an index only when ready, calibrated and over agent_index_min_rows; otherwise scans exactly). */
    public int agentUseIndexMode()
    {
        return config.agentUseIndexMode();
    }

    public int agentIndexMinRows()
    {
        return config.operatorInt("agent_index_min_rows");
    }

    public ObjectMapper mapper()
    {
        return mapper;
    }

    /**
     * The node's configuration.
     *
     * <p>The resource consults it for the operator's own knobs -- the
     * text-to-SQL statement allowlist, for one -- so those knobs are
     * actually consulted rather than merely declared.
     */
    public FractalSqlConfig config()
    {
        return config;
    }

    /**
     * Run a query against this node's own SQL endpoint.
     *
     * <p>The service lives on the broker, so its SQL endpoint is the one
     * the query came in on. There is no in-process "run this query" API
     * on the extension surface — Druid's SqlEngine is a planner factory,
     * not a query runner — so the service asks its own node over
     * loopback.
     *
     * <p>A loopback call from a request thread is a bounded risk: the
     * broker's worker pool must have a spare thread. It is fine for the
     * service's own traffic and is another reason the production home
     * for this tier is the daemon rather than the broker.
     *
     * @return the rows, as a list of maps
     */
    @SuppressWarnings("unchecked")
    public java.util.List<Map<String, Object>> query(String sql) throws Exception
    {
        final Reply response = send("POST", localSqlUrl(),
                mapper.writeValueAsString(java.util.Map.of("query", sql, "resultFormat", "object")));
        if (response.status != 200) {
            throw new IllegalStateException(
                    "the SQL endpoint answered " + response.status + ": " + response.body);
        }
        final com.fasterxml.jackson.databind.JsonNode rows = mapper.readTree(response.body);
        final java.util.List<Map<String, Object>> out = new java.util.ArrayList<>();
        for (com.fasterxml.jackson.databind.JsonNode row : rows) {
            out.add(mapper.convertValue(row, Map.class));
        }
        return out;
    }

    /**
     * The schema context: a datasource's columns and the datasources
     * there are.
     *
     * <p>This is the Druid form of {@code fractal_schema_context()},
     * which walks
     * the catalog tables. On Druid the
     * same information lives in {@code INFORMATION_SCHEMA.COLUMNS} and
     * {@code sys.segments}.
     */
    public Map<String, Object> schemaContext(String datasource) throws Exception
    {
        final Map<String, Object> out = new LinkedHashMap<>();
        if (datasource == null || datasource.isEmpty()) {
            final java.util.List<Map<String, Object>> all = query(
                    "SELECT \"TABLE_NAME\" AS \"datasource\", COUNT(*) AS \"columns\" "
                            + "FROM INFORMATION_SCHEMA.COLUMNS WHERE \"TABLE_SCHEMA\" = 'druid' "
                            + "GROUP BY \"TABLE_NAME\" ORDER BY \"TABLE_NAME\"");
            out.put("datasources", all);
            return out;
        }
        final java.util.List<Map<String, Object>> columns = query(
                "SELECT \"COLUMN_NAME\" AS \"name\", \"DATA_TYPE\" AS \"type\", "
                        + "\"IS_NULLABLE\" AS \"nullable\", \"ORDINAL_POSITION\" AS \"position\" "
                        + "FROM INFORMATION_SCHEMA.COLUMNS "
                        + "WHERE \"TABLE_SCHEMA\" = 'druid' AND \"TABLE_NAME\" = '"
                        + datasource.replace("'", "''") + "' "
                        + "ORDER BY \"ORDINAL_POSITION\"");
        out.put("datasource", datasource);
        out.put("columns", columns);
        return out;
    }

    /** This node's own SQL endpoint. */
    private String localSqlUrl()
    {
        final String type = properties.getProperty("druid.node.type", "broker");
        final int fallback;
        switch (type) {
            case "coordinator":
                fallback = 8081;
                break;
            case "historical":
                fallback = 8083;
                break;
            case "router":
                fallback = 8888;
                break;
            case "middleManager":
                fallback = 8090;
                break;
            default:
                fallback = 8082;
        }
        final int port = Integer.parseInt(
                properties.getProperty("druid.server.http.port", Integer.toString(fallback)));
        return "http://127.0.0.1:" + port + "/druid/v2/sql";
    }

    // -- the corpus tier ------------------------------------------------
    //
    // The discovery functions that read a whole column: the SFS
    // converges over the corpus and then ranks it, so the corpus has to
    // be materialised somewhere. A Druid aggregate is the wrong home --
    // the per-group intermediate would have to hold the entire corpus,
    // and Druid caps that (the same guardrail that fails ARRAY_AGG past
    // 1024 bytes). The service already reaches SQL, so it reads the
    // column itself and calls the core.

    /**
     * Read a datasource's vector column, with an optional identity
     * column beside it.
     *
     * @param datasource the datasource to read
     * @param vectorColumn the column holding the vectors
     * @param idColumn the column holding the row's identity, or null
     * @param filter an optional SQL predicate
     * @return the rows: each a vector, and its identity when asked for
     */
    public List<Object[]> corpusRows(
            String datasource,
            String vectorColumn,
            String idColumn,
            String filter) throws Exception
    {
        final StringBuilder sql = new StringBuilder("SELECT ");
        sql.append('"').append(vectorColumn.replace("\"", "\"\"")).append('"');
        if (idColumn != null && !idColumn.isEmpty()) {
            sql.append(", \"").append(idColumn.replace("\"", "\"\"")).append('"');
        }
        sql.append(" FROM \"").append(datasource.replace("\"", "\"\"")).append('"');
        if (filter != null && !filter.isEmpty()) {
            sql.append(" WHERE ").append(filter);
        }
        final List<Map<String, Object>> rows = query(sql.toString());
        final List<Object[]> out = new ArrayList<>();
        for (Map<String, Object> row : rows) {
            final Object vector = row.get(vectorColumn);
            final double[] parsed = VectorText.parseVector(
                    vector == null ? null : vector.toString());
            if (parsed == null) {
                continue;
            }
            final Object id = idColumn == null || idColumn.isEmpty() ? null : row.get(idColumn);
            out.add(new Object[]{parsed, id});
        }
        return out;
    }

    /**
     * The Scout result over a corpus: the SFS converges over the whole
     * corpus and reports the population it selected.
     *
     * @param params the SFS parameter document, or null for the defaults
     */
    public Map<String, Object> searchExplore(
            String datasource,
            String vectorColumn,
            String queryVector,
            int k,
            String params) throws Exception
    {
        return searchExplore(datasource, vectorColumn, null, queryVector, k, params);
    }

    /**
     * Scout's diversity-first search over a whole corpus.
     *
     * @param idColumn the column naming each row, so the population can
     *                 be matched back to the rows it came from
     */
    public Map<String, Object> searchExplore(
            String datasource,
            String vectorColumn,
            String idColumn,
            String queryVector,
            int k,
            String params) throws Exception
    {
        final List<Object[]> rows = corpusRows(datasource, vectorColumn, idColumn, null);
        if (rows.isEmpty()) {
            throw new IllegalArgumentException("the datasource has no vectors in " + vectorColumn);
        }
        final double[] query = VectorText.parseVector(queryVector);
        if (query == null) {
            throw new IllegalArgumentException("could not parse the query vector");
        }
        final int dim = ((double[]) rows.get(0)[0]).length;
        final double[] corpus = new double[rows.size() * dim];
        for (int i = 0; i < rows.size(); i++) {
            final double[] v = (double[]) rows.get(i)[0];
            System.arraycopy(v, 0, corpus, i * dim, Math.min(dim, v.length));
        }
        final String result = search(corpus, rows.size(), dim, query, query.length, k, params);
        final Map<String, Object> out = new LinkedHashMap<>();
        out.put("n_corpus", rows.size());
        out.put("dim", dim);
        out.put("result", result);
        // The population, matched back to the corpus rows it came from:
        // the core works in float32, so the match is by closeness.
        out.put("rows", matchPopulation(result, rows));
        return out;
    }

    /**
     * The population the search returned, matched back to the corpus
     * rows.
     *
     * <p>The core's population holds float32 vectors, so a population
     * vector is not bit-identical to the row it came from; the match is
     * by closeness, which is what the reference demo did by hand.
     */
    public static List<Map<String, Object>> matchPopulation(
            String result, List<Object[]> rows)
    {
        final List<Map<String, Object>> out = new ArrayList<>();
        final com.fasterxml.jackson.databind.JsonNode root;
        try {
            root = new com.fasterxml.jackson.databind.ObjectMapper().readTree(result);
        } catch (Exception e) {
            return out;
        }
        final com.fasterxml.jackson.databind.JsonNode population = root.get("population");
        if (population == null || !population.isArray()) {
            return out;
        }
        int ord = 0;
        for (com.fasterxml.jackson.databind.JsonNode vector : population) {
            final double[] wanted = new double[vector.size()];
            for (int i = 0; i < wanted.length; i++) {
                wanted[i] = vector.get(i).asDouble();
            }
            Object bestId = null;
            double bestDelta = Double.POSITIVE_INFINITY;
            for (Object[] row : rows) {
                final double[] v = (double[]) row[0];
                if (v.length != wanted.length) {
                    continue;
                }
                double delta = 0;
                for (int i = 0; i < v.length; i++) {
                    delta = Math.max(delta, Math.abs(v[i] - wanted[i]));
                }
                if (delta < bestDelta) {
                    bestDelta = delta;
                    bestId = row[1];
                }
            }
            final Map<String, Object> picked = new LinkedHashMap<>();
            picked.put("ord", ord);
            picked.put("doc_id", bestId == null ? (Object) ord : bestId);
            out.add(picked);
            ord++;
        }
        return out;
    }

    /**
     * The ground-truth nearest rows: the exact cosine distance from the
     * query to every row, best first.
     */
    public Map<String, Object> searchTelemetry(
            String datasource,
            String vectorColumn,
            String idColumn,
            String queryVector,
            int k) throws Exception
    {
        return searchTelemetry(datasource, vectorColumn, idColumn, queryVector, k, null, null);
    }

    /**
     * The table-backed search, optionally restricted to a cohort.
     *
     * @param cohort the identities the search may return, or null for all
     */
    /**
     * The table-backed search, over a subset and within a cohort.
     */
    public Map<String, Object> searchTelemetry(
            String datasource,
            String vectorColumn,
            String idColumn,
            String queryVector,
            int k,
            java.util.Set<String> cohort,
            String filter) throws Exception
    {
        final List<Object[]> rows = corpusRows(datasource, vectorColumn, idColumn, filter);
        final double[] query = VectorText.parseVector(queryVector);
        if (query == null) {
            throw new IllegalArgumentException("could not parse the query vector");
        }
        final List<double[]> scored = new ArrayList<>();
        final List<Object> ids = new ArrayList<>();
        for (Object[] row : rows) {
            final double[] v = (double[]) row[0];
            if (v.length != query.length) {
                continue;
            }
            if (cohort != null && !cohort.isEmpty()) {
                final Object id = row[1];
                if (id == null || !inCohort(id, cohort)) {
                    continue;
                }
            }
            scored.add(new double[]{Native.cosineDistance(v, query)});
            ids.add(row[1]);
        }
        final Integer[] order = new Integer[scored.size()];
        for (int i = 0; i < order.length; i++) {
            order[i] = i;
        }
        java.util.Arrays.sort(order, (a, b) -> Double.compare(scored.get(a)[0], scored.get(b)[0]));
        final int limit = k > 0 ? Math.min(k, order.length) : order.length;
        final List<Map<String, Object>> hits = new ArrayList<>();
        for (int i = 0; i < limit; i++) {
            final int idx = order[i];
            final Map<String, Object> hit = new LinkedHashMap<>();
            hit.put("doc_id", ids.get(idx) == null ? (Object) idx : ids.get(idx));
            hit.put("scan_pos", idx);
            hit.put("distance", scored.get(idx)[0]);
            hits.add(hit);
        }
        final Map<String, Object> out = new LinkedHashMap<>();
        out.put("n_corpus", rows.size());
        out.put("hits", hits);
        out.put("rows", hits);
        return out;
    }

    /**
     * The box-counting dimension of a point cloud.
     *
     * <p>The points come from a datasource's two columns, grouped by an
     * entity column. The count is computed <i>once per group</i> here:
     * as a SQL expression the same computation would run once per row,
     * which for a few hundred points is minutes of core time in the
     * data node.
     *
     * @param datasource the datasource holding the points
     * @param entityColumn the column naming the cloud, or null for one cloud
     * @param xColumn the first coordinate column
     * @param yColumn the second coordinate column
     * @param dim the dimension of the cloud
     * @return one row per cloud: the entity and its dimension
     */
    public List<Map<String, Object>> boxcount(
            String datasource,
            String entityColumn,
            String xColumn,
            String yColumn,
            int dim) throws Exception
    {
        final StringBuilder sql = new StringBuilder("SELECT ");
        if (entityColumn != null && !entityColumn.isEmpty()) {
            sql.append('"').append(entityColumn.replace("\"", "\"\"")).append("\" AS \"entity\", ");
        }
        sql.append("FRACTAL_DIMENSION_BOXCOUNT(ARRAY_TO_STRING(ARRAY_AGG(")
                .append("CAST(\"").append(xColumn.replace("\"", "\"\"")).append("\" AS VARCHAR)")
                .append(" || ',' || CAST(\"").append(yColumn.replace("\"", "\"\""))
                .append("\" AS VARCHAR), 65536), ','), ").append(dim).append(") AS \"dim\"");
        sql.append(" FROM \"").append(datasource.replace("\"", "\"\"")).append("\"");
        if (entityColumn != null && !entityColumn.isEmpty()) {
            sql.append(" GROUP BY \"").append(entityColumn.replace("\"", "\"\"")).append("\"");
        }
        final List<Map<String, Object>> rows = query(sql.toString());
        final List<Map<String, Object>> out = new ArrayList<>();
        for (Map<String, Object> row : rows) {
            final Map<String, Object> one = new LinkedHashMap<>();
            if (entityColumn != null && !entityColumn.isEmpty()) {
                one.put("entity", row.get("entity"));
            }
            final Object dim2 = row.get("dim");
            one.put("dim", dim2 instanceof Number ? ((Number) dim2).doubleValue() : null);
            out.add(one);
        }
        return out;
    }

    /**
     * Whether a row's identity is in the cohort.
     *
     * <p>The cohort's identities arrive as text and the rows' as
     * whatever the column holds -- a JSON number reads back as a
     * double, so "2" and "2.0" are the same identity.
     */
    private static boolean inCohort(Object id, java.util.Set<String> cohort)
    {
        final String text = id.toString();
        if (cohort.contains(text)) {
            return true;
        }
        try {
            final double number = Double.parseDouble(text);
            if (number == Math.rint(number) && !Double.isInfinite(number)) {
                return cohort.contains(Long.toString((long) number));
            }
        } catch (NumberFormatException e) {
            // Not a number: the text form is all there is.
        }
        return false;
    }

    /** POST a JSON body and read the JSON answer. */
    private com.fasterxml.jackson.databind.JsonNode postJson(
            String url, Map<String, Object> body) throws Exception
    {
        final Reply response = send("POST", url, mapper.writeValueAsString(body));
        if (response.status / 100 != 2) {
            throw new IllegalStateException(url + " answered " + response.status + ": " + response.body);
        }
        return mapper.readTree(response.body);
    }

    /** GET a URL and read the JSON answer, or null. */
    private com.fasterxml.jackson.databind.JsonNode getJson(String url)
    {
        try {
            final Reply response = send("GET", url, null);
            if (response.status / 100 != 2) {
                return null;
            }
            return mapper.readTree(response.body);
        } catch (Exception e) {
            return null;
        }
    }

    /** An HTTP answer: the status and the body. */
    private static final class Reply
    {
        final int status;
        final String body;

        Reply(int status, String body)
        {
            this.status = status;
            this.body = body;
        }
    }

    /**
     * One HTTP request to a Druid service.
     *
     * <p>This is {@code HttpURLConnection} rather than the JDK's {@code HttpClient}: a Druid broker ends its chunked
     * answers with an {@code X-Druid-Response-Complete} trailer, which the Java 25 {@code HttpClient} rejects
     * ("CR expected") and {@code HttpURLConnection} reads without trouble, on every Java Druid runs on.
     */
    private static Reply send(String method, String url, String body) throws java.io.IOException
    {
        final java.net.HttpURLConnection c = (java.net.HttpURLConnection) java.net.URI.create(url).toURL().openConnection();
        try {
            c.setRequestMethod(method);
            c.setConnectTimeout(10_000);
            c.setReadTimeout(0);
            if (body != null) {
                c.setDoOutput(true);
                c.setRequestProperty("Content-Type", "application/json");
                try (java.io.OutputStream out = c.getOutputStream()) {
                    out.write(body.getBytes(java.nio.charset.StandardCharsets.UTF_8));
                }
            }
            final int status = c.getResponseCode();
            try (java.io.InputStream in = status >= 400 ? c.getErrorStream() : c.getInputStream()) {
                return new Reply(status, in == null ? ""
                        : new String(in.readAllBytes(), java.nio.charset.StandardCharsets.UTF_8));
            }
        } finally {
            c.disconnect();
        }
    }

    /**
     * Submit an MSQ write and wait for it.
     *
     * <p>The write is the only way a value reaches a Druid datasource:
     * Druid's SQL has no DML, and an MSQ write's SELECT can only read
     * tables. So a value the extension computed travels in the query
     * text -- as a JSON document in an inline array, the same way the
     * demo runner writes a fixture -- and the write projects it into
     * columns.
     *
     * @return the task's id
     */
    public String submitWrite(String sql, String contextJson) throws Exception
    {
        final Map<String, Object> payload = new LinkedHashMap<>();
        payload.put("query", sql);
        if (contextJson != null && !contextJson.trim().isEmpty()) {
            payload.put("context", contextJson);
        }
        final com.fasterxml.jackson.databind.JsonNode response = postJson(
                localSqlTaskUrl(), payload);
        if (response == null || !response.has("taskId")) {
            throw new IllegalStateException(
                    "the write was not accepted: " + (response == null ? "(no answer)" : response.toString()));
        }
        final String taskId = response.get("taskId").asText();
        final long deadline = System.currentTimeMillis() + 600000L;
        boolean everRead = false;
        while (System.currentTimeMillis() < deadline) {
            final com.fasterxml.jackson.databind.JsonNode status = getJson(
                    localTaskStatusUrl(taskId));
            if (status != null && status.has("status")) {
                everRead = true;
                final String state = taskState(status);
                if ("SUCCESS".equals(state)) {
                    return taskId;
                }
                if ("FAILED".equals(state) || "CANCELED".equals(state)) {
                    final String error = taskError(status);
                    throw new IllegalStateException("the write failed: " + error);
                }
            }
            Thread.sleep(500L);
        }
        // A poll that NEVER read the task's status is a different
        // fault from a write that ran too long, and the difference is
        // the difference between "the write is stuck" and "the write
        // finished ten minutes ago and nobody could see it".
        throw new IllegalStateException(
                everRead
                        ? "the write did not finish in time"
                        : "the write's status could not be read at " + localTaskStatusUrl(taskId)
                                + " -- the task belongs to the coordinator, so "
                                + "druid.fractalsql.coordinator_url must name it");
    }

    /**
     * A task's state, from Druid's task-status document.
     *
     * <p>Druid NESTS the state: the document is
     * {@code {"task": "<id>", "status": {"status": "SUCCESS", ...}}}, so
     * the state is two levels down. Reading one level gets an object,
     * whose text form is the empty string -- so a one-level read never
     * matches "SUCCESS" and the poll runs to its deadline over a write
     * that finished in seconds.
     */
    private static String taskState(com.fasterxml.jackson.databind.JsonNode document)
    {
        com.fasterxml.jackson.databind.JsonNode inner = document.get("status");
        if (inner != null && inner.isObject()) {
            final com.fasterxml.jackson.databind.JsonNode state = inner.get("status");
            if (state != null && state.isTextual()) {
                return state.asText();
            }
            final com.fasterxml.jackson.databind.JsonNode code = inner.get("statusCode");
            if (code != null && code.isTextual()) {
                return code.asText();
            }
            return "";
        }
        return inner != null && inner.isTextual() ? inner.asText() : "";
    }

    /** A task's error message, from Druid's task-status document. */
    private static String taskError(com.fasterxml.jackson.databind.JsonNode document)
    {
        com.fasterxml.jackson.databind.JsonNode inner = document.get("status");
        if (inner != null && inner.isObject()) {
            final com.fasterxml.jackson.databind.JsonNode message = inner.get("errorMsg");
            if (message != null && !message.isNull()) {
                return message.asText();
            }
        }
        return "";
    }

    /** The node's own MSQ task endpoint -- the broker forwards it to the overlord. */
    private String localSqlTaskUrl()
    {
        return localSqlUrl().replace("/druid/v2/sql", "/druid/v2/sql/task");
    }

    /**
     * The status of a task.
     *
     * <p>The task belongs to the OVERLORD, not to the node that
     * submitted it. A broker forwards an MSQ task submission to the
     * overlord -- so the write works from any node -- but the broker
     * does not serve the task's status: it answers 404 for a task it
     * does not own, and the poll then never resolves and the write
     * times out after ten minutes having actually succeeded.
     *
     * <p>So the status is read from the coordinator, whose address the
     * operator names in {@code druid.fractalsql.coordinator_url}. When
     * it is not set, the node's own port is used, which is right for a
     * single-process deployment and for an extension hosted on the
     * coordinator itself.
     */
    private String localTaskStatusUrl(String taskId)
    {
        final String coordinator = config.operatorValue("coordinator_url");
        final String base;
        if (coordinator != null && !coordinator.trim().isEmpty()) {
            base = coordinator.trim().replaceAll("/+$", "");
        } else {
            final int port = Integer.parseInt(
                    properties.getProperty("druid.server.http.port", "8081"));
            base = "http://127.0.0.1:" + port;
        }
        return base + "/druid/indexer/v1/task/" + taskId + "/status";
    }

    /**
     * A table's text column, with each row's identity.
     *
     * @return one map per row: "id" and "text"
     */
    public List<Map<String, Object>> textRows(
            String datasource, String textColumn, String idColumn) throws Exception
    {
        final StringBuilder sql = new StringBuilder("SELECT ");
        if (idColumn != null && !idColumn.isEmpty()) {
            sql.append('"').append(idColumn.replace("\"", "\"\"")).append("\" AS \"id\", ");
        }
        sql.append('"').append(textColumn.replace("\"", "\"\"")).append("\" AS \"text\" FROM \"")
                .append(datasource.replace("\"", "\"\"")).append('"');
        return query(sql.toString());
    }

    /**
     * One cell of a one-row datasource: the text the caller stored
     * there.
     *
     * <p>This is how a computed argument reaches an agent or a search:
     * the demo writes the value into a datasource and names the table
     * and the column.
     */
    public String cell(String table, String column) throws Exception
    {
        final List<Map<String, Object>> rows = query(
                "SELECT \"" + column.replace("\"", "\"\"") + "\" AS \"v\" FROM \""
                        + table.replace("\"", "\"\"") + "\"");
        if (rows.isEmpty() || rows.get(0).get("v") == null) {
            throw new IllegalArgumentException("no value in " + table + "." + column);
        }
        return rows.get(0).get("v").toString();
    }

    /**
     * Every value in a column, in the scan's order, joined by commas.
     *
     * <p>This is what a SERIES argument needs. {@link #cell} returns the
     * first row's value only, which is right for a one-row table -- a
     * computed baseline vector, a cohort's id list -- and wrong for a
     * column of readings: a heading walk handed over as a table and a
     * column would arrive as a single point, and the exponent computed
     * from it would be meaningless.
     *
     * <p>A one-row table holding a CSV text gives that text back
     * unchanged, so the same call serves both shapes.
     */
    public String cells(String table, String column) throws Exception
    {
        final List<Map<String, Object>> rows = query(
                "SELECT \"" + column.replace("\"", "\"\"") + "\" AS \"v\" FROM \""
                        + table.replace("\"", "\"\"") + "\"");
        final StringBuilder sb = new StringBuilder();
        for (Map<String, Object> row : rows) {
            final Object v = row.get("v");
            if (v == null) {
                continue;
            }
            if (sb.length() > 0) {
                sb.append(',');
            }
            sb.append(v.toString());
        }
        if (sb.length() == 0) {
            throw new IllegalArgumentException("no value in " + table + "." + column);
        }
        return sb.toString();
    }

    /**
     * The box-counting dimension of a point cloud given as text.
     *
     * <p>The points arrive in the core's text form -- {@code x,y,x,y,...}
     * -- one flat list of {@code dim}-sized points.
     */
    public double boxcountOf(String points, int dim) throws Exception
    {
        final double[] flat = VectorText.parseVector(points);
        if (flat == null || dim <= 0 || flat.length % dim != 0) {
            throw new IllegalArgumentException("could not read the point cloud");
        }
        NativeLoader.load();
        final long ctx = Native.newSovereign();
        try {
            final double[] out = new double[FractalFn.OUT_SIZE];
            return Native.callFn(3, flat, flat.length, null, 0, null, 0, dim, 0, 0, out);
        } finally {
            Native.free(ctx);
        }
    }

    /**
     * The provider's embedding, as a vector.
     *
     * @return the embedding, or null if no provider is configured
     */
    public double[] embedVector(String text)
    {
        final String vector = embed(text);
        return vector == null ? null : VectorText.parseVector(vector);
    }

    /**
     * Run the core's SFS over a corpus and return its result document.
     *
     * <p>The parameters are the core's own JSON document, so a caller
     * can ask for the population (Scout) or the plain best point.
     */
    public String searchDocument(
            double[] corpus,
            int nRows,
            int dim,
            double[] query,
            int k,
            String params)
    {
        try {
            return search(corpus, nRows, dim, query, query.length, k, params);
        } catch (Exception e) {
            throw new IllegalStateException("fractalsql: the search failed: " + e.getMessage(), e);
        }
    }

    /** Run the core's SFS over a corpus and return its result document. */
    private String search(
            double[] corpus,
            int nRows,
            int dim,
            double[] query,
            int queryDim,
            int k,
            String params) throws Exception
    {
        final long ctx = Native.newSovereign();
        if (ctx == 0) {
            throw new IllegalStateException("fractalsql: could not create a core context");
        }
        try {
            return searchOn(ctx, corpus, nRows, dim, query, queryDim, k, params);
        } finally {
            Native.free(ctx);
        }
    }

    /**
     * Run the core's SFS over a corpus on a GIVEN context.
     *
     * <p>The context matters. The divergence monitor lives on a
     * context, so a search run on a throwaway one is invisible to it —
     * and the feedback audit needs the monitor to SEE its warm-up
     * searches, because the measurement it reads back is the monitor's.
     * A caller that wants the monitor warmed keeps one context, enables
     * the monitor on it, and reads the measurement from it.
     *
     * <p>The context must not be shared across threads: a core context
     * is not thread-safe.
     */
    public String searchOn(
            long ctx,
            double[] corpus,
            int nRows,
            int dim,
            double[] query,
            int queryDim,
            int k,
            String params) throws Exception
    {
        if (ctx == 0) {
            throw new IllegalStateException("fractalsql: could not create a core context");
        }
        final byte[] paramBytes = params == null || params.isEmpty()
                ? null
                : params.getBytes(java.nio.charset.StandardCharsets.UTF_8);
        final byte[] result = Native.searchPtr(
                ctx, corpus, nRows, dim, query, queryDim, Math.max(k, 1), paramBytes);
        if (result == null) {
            final String err = Native.lastError(ctx);
            throw new IllegalStateException(
                    "fractalsql: the search failed: "
                            + (err == null || err.isEmpty() ? "(no detail)" : err));
        }
        return new String(result, java.nio.charset.StandardCharsets.UTF_8);
    }
}
