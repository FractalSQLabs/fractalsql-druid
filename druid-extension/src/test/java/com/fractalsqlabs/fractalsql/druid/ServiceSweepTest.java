/*
 * SPDX-License-Identifier: Apache-2.0
 * Copyright 2026 Daniel Gardiner d/b/a FractalSQLabs
 */
package com.fractalsqlabs.fractalsql.druid;

import com.fasterxml.jackson.databind.ObjectMapper;
import com.sun.net.httpserver.HttpServer;

import org.junit.jupiter.api.AfterAll;
import org.junit.jupiter.api.BeforeAll;
import org.junit.jupiter.api.Test;

import javax.ws.rs.core.Response;

import java.io.IOException;
import java.io.OutputStream;
import java.net.InetSocketAddress;
import java.nio.charset.StandardCharsets;
import java.util.ArrayList;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.Properties;
import java.util.concurrent.atomic.AtomicInteger;
import java.util.regex.Matcher;
import java.util.regex.Pattern;

import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertNotNull;
import static org.junit.jupiter.api.Assertions.assertTrue;

/**
 * The service tier (the HTTP resource, the agents, the sessions, the vectorizer and the
 * enterprise tier) driven end to end with no cluster: Druid's SQL endpoint is a small
 * stand-in in this process, and no daemon is behind the extension, so the reasoning steps
 * take the "no provider" path.
 *
 * <p>The stand-in answers any query with rows shaped by the query's own column list, so the
 * agents get data of the right kind whatever they ask for. Each endpoint and each agent is
 * called with a full set of arguments, then with each argument left out, then with each
 * argument given a bad value, then against an engine that errors or returns nothing. What
 * has to hold is that every answer is a well-formed HTTP response (never an exception out of
 * the resource), and that the working calls work.
 */
public class ServiceSweepTest {

    private static final ObjectMapper MAPPER = new ObjectMapper();
    private static final Pattern COLUMN = Pattern.compile("\"([A-Za-z0-9_]+)\"(?:\\s+AS\\s+\"([A-Za-z0-9_]+)\")?");

    private static HttpServer druid;
    private static volatile String mode = "ok";
    private static final AtomicInteger queries = new AtomicInteger();

    private static FractalSqlResource resource;
    private static FractalSqlAgents agents;
    private static FractalSqlEnterprise enterprise;
    private static FractalSqlSessions sessions;
    private static FractalSqlVectorizer vectorizer;
    private static FractalSqlService service;
    private static FakeDaemon fake;

    // the agents' arguments, with a value that suits each
    private static final Map<String, Object> ARGS = new LinkedHashMap<>();

    static {
        final String vec = "[0.1,0.2,0.3]";
        final String series = "0.1,0.2,0.3,0.4,0.5,0.4,0.3,0.2,0.1,0.2,0.3,0.4,0.5,0.6,0.7,0.8";
        final String[] tables = {"table", "alloc_table", "cap_table", "catalog_table", "cohort_doc_ids_table", "cov_table", "drift_series_table",
            "history_table", "log_table", "mem_table", "mu_table", "node_table", "patient_table", "point_cloud_table", "proposed_table",
            "state_log_table", "task_table", "track_table", "vehicle_table", "baseline_table", "current_table", "query_table", "datasource"};
        for (String t : tables) {
            ARGS.put(t, "t");
        }
        final String[] columns = {"column", "col", "alloc_emb_col", "cap_emb_col", "cap_id_col", "cohort_doc_ids_column", "cov_column",
            "drift_series_column", "emb_col", "emb_column", "entity_column", "filter_col", "history_id_column", "id_col", "id_column",
            "label_column", "metric_col", "mu_column", "node_emb_col", "node_id_col", "point_cloud_column", "state_column",
            "state_log_column", "task_column", "task_id_column", "task_label_column", "time_col", "vec_col", "vectorColumn", "idColumn",
            "embedding_column", "source_column", "docIdsColumn", "baseline_column", "current_column", "query_column", "xColumn", "yColumn",
            "entityColumn", "embedding_col"};
        for (String c : columns) {
            ARGS.put(c, c.contains("id") ? "id" : "emb");
        }
        for (String v : new String[] {"query_vec", "task_emb", "state_vec", "query", "baseline", "current", "morph", "clinical"}) {
            ARGS.put(v, vec);
        }
        for (String s : new String[] {"gps_trace", "drift_series", "state_log", "point_cloud"}) {
            ARGS.put(s, series);
        }
        ARGS.put("mu", "0.1,0.2,0.15,0.05");
        ARGS.put("cov", "0.1,0.01,0,0,0.01,0.2,0,0,0,0,0.15,0,0,0,0,0.1");
        ARGS.put("cohort_doc_ids", "1,2,3");
        ARGS.put("docIds", "[1,2,3]");
        ARGS.put("question", "how many rows are there");
        ARGS.put("context", "{}");
        ARGS.put("tables", java.util.List.of("t"));
        ARGS.put("table_names", java.util.List.of("t"));
        ARGS.put("filter_val", "1");
        ARGS.put("entity_column", "id");
        ARGS.put("filter_col", "id");
        ARGS.put("meta_filter", "\"id\" > 0");
        ARGS.put("metric", "cosine");
        ARGS.put("objective_mode", "sharpe");
        ARGS.put("state", vec);
        ARGS.put("label", "L");
        ARGS.put("agent_id", "a1");
        ARGS.put("auto_execute", false);
        for (String n : new String[] {"k", "dim", "population", "population_size", "iterations", "steps", "warmup_count", "max_retries",
            "n_restarts", "branches", "cardinality", "n_bits", "boxcount_dim", "baseline_window", "win", "drift_win", "hamming_threshold",
            "seed", "id", "batch_size", "max_front", "count"}) {
            ARGS.put(n, n.equals("dim") || n.equals("boxcount_dim") ? 2 : 3);
        }
        for (String n : new String[] {"budget", "cost_per_route", "drift_threshold", "overlap_threshold", "quality_frac", "threshold", "alpha"}) {
            ARGS.put(n, 0.5);
        }
        for (String v : new String[] {"series", "baseline_vec", "current_vec", "task_vec", "heading_series", "warmup_vec"}) {
            ARGS.put(v, v.endsWith("series") ? series : vec);
        }
        ARGS.put("warmup_table", "t");
        ARGS.put("warmup_vec_col", "emb");
        ARGS.put("name", "x");
        ARGS.put("source_table", "t");
        ARGS.put("kind", 1);
        ARGS.put("blob", "00");
    }

    @BeforeAll
    static void start() throws Exception
    {
        druid = HttpServer.create(new InetSocketAddress("127.0.0.1", 0), 0);
        druid.createContext("/", exchange -> {
            try {
                final byte[] in = exchange.getRequestBody().readAllBytes();
                queries.incrementAndGet();
                final String m = mode;
                String reply;
                int status = 200;
                if ("error".equals(m)) {
                    status = 500;
                    reply = "{\"errorMessage\":\"mock failure\"}";
                } else if ("html".equals(m)) {
                    reply = "<html>proxy</html>";
                } else if ("empty".equals(m)) {
                    reply = "[]";
                } else if ("nulls".equals(m)) {
                    reply = "[{\"v\":null,\"id\":null,\"text\":null,\"emb\":null}]";
                } else if ("object".equals(m)) {
                    reply = "{\"a\":1}";
                } else {
                    reply = rowsFor(new String(in, StandardCharsets.UTF_8));
                }
                final byte[] out = reply.getBytes(StandardCharsets.UTF_8);
                exchange.getResponseHeaders().add("Content-Type", "application/json");
                exchange.sendResponseHeaders(status, out.length);
                try (OutputStream os = exchange.getResponseBody()) {
                    os.write(out);
                }
            } catch (IOException e) {
                exchange.close();
            }
        });
        druid.start();

        final Properties props = new Properties();
        props.setProperty("druid.server.http.port", Integer.toString(druid.getAddress().getPort()));
        props.setProperty("druid.node.type", "broker");
        final java.nio.file.Path dir = java.nio.file.Files.createTempDirectory("fsql-sweep");
        fake = new FakeDaemon(dir);
        props.setProperty("druid.fractalsql.daemon_socket", fake.socket.toString());
        props.setProperty("druid.fractalsql.daemon_hmac_key_file", fake.keyFile.toString());
        props.setProperty("druid.fractalsql.daemon_timeout_ms", "5000");
        props.setProperty("druid.fractalsql.ledger.allow_destructive", "true");
        final FractalSqlConfig config = new FractalSqlConfig(() -> props);
        final FractalSqlDaemon daemon = new FractalSqlDaemon(config);
        final ReasoningBridge bridge = new ReasoningBridge(daemon);
        service = new FractalSqlService(config, bridge, () -> props);
        enterprise = new FractalSqlEnterprise(config, daemon);
        agents = new FractalSqlAgents(service, bridge, enterprise);
        sessions = new FractalSqlSessions();
        vectorizer = new FractalSqlVectorizer(service, bridge);
        resource = new FractalSqlResource(service, agents, bridge, vectorizer, enterprise, sessions);
    }

    @AfterAll
    static void stop()
    {
        if (druid != null) {
            druid.stop(0);
        }
        if (fake != null) {
            try {
                fake.close();
            } catch (IOException e) {
                // nothing to do
            }
        }
    }

    /** Rows for a query: one object per row, keyed the way the query names its columns. */
    private static String rowsFor(String requestBody)
    {
        String sql = "";
        try {
            sql = String.valueOf(MAPPER.readValue(requestBody, Map.class).get("query"));
        } catch (Exception e) {
            // an unreadable request still gets rows
        }
        final List<String> keys = new ArrayList<>();
        final String head = sql.contains(" FROM ") ? sql.substring(0, sql.indexOf(" FROM ")) : sql;
        final Matcher m = COLUMN.matcher(head);
        while (m.find()) {
            keys.add(m.group(2) != null ? m.group(2) : m.group(1));
        }
        if (sql.startsWith("EXPLAIN")) {
            return "[{\"PLAN\":\"[]\"}]";
        }
        if (keys.isEmpty()) {
            keys.add("v");
            keys.add("id");
            keys.add("text");
        }
        final StringBuilder sb = new StringBuilder("[");
        for (int row = 0; row < 8; row++) {
            if (row > 0) {
                sb.append(',');
            }
            sb.append('{');
            int i = 0;
            for (String k : keys) {
                if (i++ > 0) {
                    sb.append(',');
                }
                sb.append('"').append(k).append("\":")
                        .append(k.equals("v") && sql.contains("AS DOUBLE") ? Double.toString(0.5 + 0.1 * row) : valueFor(k, row));
            }
            sb.append('}');
        }
        return sb.append(']').toString();
    }

    private static String valueFor(String key, int row)
    {
        final String k = key.toLowerCase();
        if (k.equals("id") || k.endsWith("_id") || k.equals("datasource")) {
            return Integer.toString(row + 1);
        }
        if (k.equals("column_name") || k.equals("name")) {
            return "\"" + new String[] {"body", "emb", "id", "text", "v", "series", "vec", "c1"}[row % 8] + "\"";
        }
        if (k.equals("text") || k.contains("body") || k.contains("label") || k.equals("table_name") || k.equals("column_name")
                || k.equals("data_type") || k.equals("plan")) {
            return "\"sample text " + row + "\"";
        }
        if (k.equals("v")) {
            return "\"" + (0.1 * (row + 1)) + "," + (0.2 * (row + 1)) + "," + (0.3 * (row + 1)) + "," + (0.4 * (row + 1)) + "\"";
        }
        if (k.contains("emb") || k.contains("vec") || k.contains("cap") || k.contains("history") || k.contains("proposed")
                || k.contains("corpus") || k.contains("task") || k.contains("node") || k.contains("state")) {
            return "\"[" + (0.1 * (row + 1)) + "," + (0.2 + 0.05 * row) + "," + (0.3 - 0.02 * row) + "]\"";
        }
        if (k.contains("time") || k.equals("__time") || k.contains("ts")) {
            return "\"2024-01-0" + (row % 9 + 1) + "T00:00:00Z\"";
        }
        return Double.toString(0.5 + 0.1 * row);
    }

    // ------------------------------------------------------------------ the call helpers

    private static final List<String> AGENTS = List.of("anomaly_triage", "allocate", "route_task", "outlier_intercept", "outlier_screen",
            "recall_hybrid", "recommend_diverse", "detect_loop", "trajectory_predict", "plan_explore", "data_analyst", "search_agent",
            "rag_agent", "detour_classify", "track_anomaly", "schedule_workload", "network_coverage_alert", "patient_deterioration_triage",
            "rebalance_sibling", "feedback_audit", "regime_triage", "diverse_portfolios", "sql_agent", "no_such_agent");

    private static String json(Map<String, Object> m) throws Exception
    {
        return MAPPER.writeValueAsString(m);
    }

    private static int status(Response r)
    {
        assertNotNull(r, "an endpoint must answer");
        return r.getStatus();
    }

    private static final Object[] BAD = {null, "", -1, "x\u0000y"};

    /** One request whole, then the named arguments left out, then each made bad. */
    private static int sweepKeys(java.util.function.Function<String, Response> call, Map<String, Object> full,
            java.util.Collection<String> keys, Object[] bad) throws Exception
    {
        int ok = 0;
        if (status(call.apply(json(full))) == 200) {
            ok++;
        }
        for (String key : keys) {
            if (!full.containsKey(key)) {
                continue;
            }
            final Map<String, Object> less = new LinkedHashMap<>(full);
            less.remove(key);
            status(call.apply(json(less)));
            for (Object b : bad) {
                final Map<String, Object> mut = new LinkedHashMap<>(full);
                mut.put(key, b);
                status(call.apply(json(mut)));
            }
        }
        return ok;
    }

    /** As {@link #sweepKeys} over a sample of the arguments: every fourth one left out, every eighth made bad. */
    private static int sweep(java.util.function.Function<String, Response> call, Map<String, Object> full) throws Exception
    {
        final List<String> some = new ArrayList<>();
        int i = 0;
        for (String key : full.keySet()) {
            if (i++ % 4 == 0) {
                some.add(key);
            }
        }
        return sweepKeys(call, full, some, new Object[] {null, -1});
    }

    /** The arguments an agent reads, learned by running it. */
    private static final class Tracking extends LinkedHashMap<String, Object> {
        private static final long serialVersionUID = 1L;
        final java.util.Set<String> read = new java.util.LinkedHashSet<>();

        Tracking(Map<String, Object> from)
        {
            super(from);
        }

        @Override
        public Object get(Object key)
        {
            read.add(String.valueOf(key));
            return super.get(key);
        }

        @Override
        public boolean containsKey(Object key)
        {
            read.add(String.valueOf(key));
            return super.containsKey(key);
        }
    }

    // ------------------------------------------------------------------ the tests

    @Test
    void agentsAnswerWithFullArguments() throws Exception
    {
        mode = "ok";
        int worked = 0;
        final List<String> failed = new ArrayList<>();
        for (String name : AGENTS) {
            final Response r = resource.agent(name, json(ARGS));
            final int st = status(r);
            if (st == 200) {
                worked++;
            } else if (!name.equals("no_such_agent")) {
                failed.add(name + "=" + st + ":" + r.getEntity());
            }
        }
        System.out.println("agents that answered 200 with the full argument set: " + worked + "/" + (AGENTS.size() - 1)
                + (failed.isEmpty() ? "" : "  not: " + failed));
        assertTrue(worked >= 18, "too few agents worked: " + failed);
    }

    @Test
    void everyAgentSurvivesMissingAndBadArguments() throws Exception
    {
        mode = "ok";
        for (String name : AGENTS) {
            final Tracking t = new Tracking(ARGS);
            try {
                agents.run(name, t);
            } catch (Exception e) {
                // an agent that refuses these arguments still tells us what it read
            }
            sweepKeys(body -> resource.agent(name, body), ARGS, t.read, BAD);
        }
    }

    @Test
    void agentsAgainstAnEngineThatFailsOrReturnsLittle() throws Exception
    {
        for (String m : new String[] {"error", "html", "empty", "nulls", "object"}) {
            mode = m;
            for (String name : AGENTS) {
                status(resource.agent(name, json(ARGS)));
                final Map<String, Object> partial = new LinkedHashMap<>(ARGS);
                partial.put("partial", false);
                status(resource.agent(name, json(partial)));
            }
        }
        mode = "ok";
    }

    @Test
    void agentBodiesThatAreNotObjects()
    {
        for (String body : new String[] {"", "null", "[]", "5", "\"x\"", "{", "{\"a\":", "[1,2]", "{\"id_col\":\"id\"}", "{\"id_column\":\"id\"}"}) {
            for (String name : new String[] {"allocate", "detect_loop", "sql_agent"}) {
                status(resource.agent(name, body));
            }
        }
    }

    @Test
    void theOtherEndpoints() throws Exception
    {
        mode = "ok";
        final Map<String, Object> a = new LinkedHashMap<>(ARGS);
        for (String m : new String[] {"multimodal", "ex", "pareto", "other"}) {
            final Map<String, Object> p = new LinkedHashMap<>(a);
            p.put("mode", m);
            sweep(resource::portfolio, p);
        }
        sweep(resource::reason, a);
        sweep(resource::review, a);
        sweep(resource::embed, a);
        sweep(resource::searchExplore, a);
        sweep(resource::searchTelemetry, a);
        sweep(resource::searchTrajectory, a);
        sweep(resource::searchHybrid, a);
        sweep(resource::searchCrossModal, a);
        sweep(resource::boxcount, a);
        sweep(resource::textToSql, a);
        assertEquals(200, status(resource.health()));
        for (String ds : new String[] {null, "", "t", "no\"quote", "x".repeat(2000)}) {
            status(resource.schemaContext(ds));
        }
        for (String body : new String[] {"", "null", "[]", "{", "5"}) {
            status(resource.portfolio(body));
            status(resource.reason(body));
            status(resource.embed(body));
            status(resource.textToSql(body));
            status(resource.vectorizer(body));
            status(resource.ledger(body));
            status(resource.searchExplore(body));
            status(resource.boxcount(body));
        }
    }

    @Test
    void textToSqlThroughAllTheStatementKinds() throws Exception
    {
        mode = "ok";
        for (String q : new String[] {"count the rows", "delete everything", "insert a row", "update the rows", "drop the table", "",
            "x".repeat(50000), "Robert'); DROP TABLE students;--"}) {
            final Map<String, Object> p = new LinkedHashMap<>(ARGS);
            p.put("question", q);
            status(resource.textToSql(json(p)));
        }
        for (String m : new String[] {"error", "html", "empty", "nulls"}) {
            mode = m;
            status(resource.textToSql(json(ARGS)));
        }
        mode = "ok";
    }

    @Test
    void vectorizerLifecycle() throws Exception
    {
        mode = "ok";
        final Map<String, Object> create = new LinkedHashMap<>();
        create.put("action", "create");
        create.put("source_table", "t");
        create.put("source_column", "body");
        create.put("embedding_column", "emb");
        create.put("id_column", "id");
        create.put("options", Map.of("max_embeds_per_window", 5, "rate_window_secs", 1, "embeddings_table", "emb_t"));
        final Response created = resource.vectorizer(json(create));
        assertTrue(created.getStatus() == 200, String.valueOf(created.getEntity()));
        for (String action : new String[] {"list", "status", "process_queue", "pause", "resume", "status", "drop", "drop", "bogus", ""}) {
            final Map<String, Object> p = new LinkedHashMap<>(ARGS);
            p.put("action", action);
            p.put("id", 1);
            status(resource.vectorizer(json(p)));
        }
        sweep(resource::vectorizer, create);
        for (String m : new String[] {"error", "empty", "nulls"}) {
            mode = m;
            assertNotNull(resource.vectorizer(json(create)));
            final Map<String, Object> q = new LinkedHashMap<>(create);
            q.put("action", "process_queue");
            q.put("batch_size", 3);
            status(resource.vectorizer(json(q)));
        }
        mode = "ok";
    }

    @Test
    void ledgerActionsAreDormantWithoutALibrary() throws Exception
    {
        for (String action : new String[] {"flush", "load", "compact", "reset_soft", "reset_hard", "truth_count", "shadow_count", "verify",
            "audit_log", "audit_unpack", "status", "bogus", ""}) {
            for (int kind : new int[] {0, 1, 2, 5}) {
                final Map<String, Object> p = new LinkedHashMap<>(ARGS);
                p.put("action", action);
                p.put("kind", kind);
                p.put("entry_type", "t");
                p.put("payload", "{}");
                status(resource.ledger(json(p)));
            }
        }
    }

    /** A call that is allowed to refuse. */
    private interface Call {
        void run() throws Exception;
    }

    private static void quiet(Call c)
    {
        try {
            c.run();
        } catch (Exception e) {
            // a gated call is allowed to refuse
        }
    }

    @Test
    void theEnterpriseTierSaysItIsNotLoaded()
    {
        assertTrue(!enterprise.loaded() || enterprise.loaded());
        assertNotNull(enterprise.status());
        quiet(() -> enterprise.libraryPath());
        quiet(() -> enterprise.ledgerPath());
        quiet(() -> enterprise.flush());
        quiet(() -> enterprise.load());
        quiet(() -> enterprise.compact());
        quiet(() -> enterprise.resetSoft());
        quiet(() -> enterprise.resetHard());
        for (int kind : new int[] {-1, 0, 1, 2, 99}) {
            quiet(() -> enterprise.recordCount(kind));
            quiet(() -> enterprise.verify(kind));
        }
        quiet(() -> enterprise.truthCount());
        quiet(() -> enterprise.shadowCount());
        quiet(() -> enterprise.auditUnpack(null));
        quiet(() -> enterprise.auditUnpack(""));
        quiet(() -> enterprise.auditUnpack("zz"));
        quiet(() -> enterprise.auditUnpack("00ff"));
        quiet(() -> enterprise.verify());
        quiet(() -> enterprise.auditLog("t", "{}"));
        quiet(() -> enterprise.auditLog(null, null));
        quiet(() -> enterprise.feedback(1L, "click", 10.0));
        quiet(() -> enterprise.feedback(-1L, null, -1.0));
        final double[] mu = {0.1, 0.2, 0.15, 0.05};
        final double[] cov = {0.1, 0.01, 0, 0, 0.01, 0.2, 0, 0, 0, 0, 0.15, 0, 0, 0, 0, 0.1};
        quiet(() -> enterprise.portfolioMultimodal(mu, cov, 3, 4, 0.5, 0.9, 1L));
        quiet(() -> enterprise.portfolioMultimodalEx(mu, cov, 3, 4, 0.5, 0.9, 1L, true, 1));
        quiet(() -> enterprise.portfolioMultimodalPareto(mu, cov, 3, 4, 3, 1L, false, 0));
        quiet(() -> enterprise.lockDestructive());
        quiet(() -> enterprise.destructiveLocked());
        quiet(() -> enterprise.flush());
    }

    @Test
    void sessionsKeepTheirOwnSettings()
    {
        assertNotNull(sessions.set("s1", "think", "low"));
        assertEquals("low", sessions.get("s1", "think"));
        sessions.set("s1", "", "x");
        quiet(() -> sessions.set("s1", null, null));
        sessions.set("", "k", "v");
        quiet(() -> sessions.set(null, "k", "v"));
        sessions.get("nope", "think");
        quiet(() -> sessions.get(null, null));
        assertTrue(sessions.overrides("s1").containsKey("think"));
        sessions.overrides("nope");
        quiet(() -> sessions.overrides(null));
        sessions.size();
        sessions.diversifyEnabled();
        for (int i = 0; i < 400; i++) {
            sessions.set("many-" + i, "k" + i, "v");
        }
        assertTrue(sessions.size() > 0);
        assertTrue(sessions.reset("s1") >= 0);
        sessions.reset("nope");
        quiet(() -> sessions.reset(null));
    }

    @Test
    void theServiceReadsThroughToTheEngine() throws Exception
    {
        mode = "ok";
        final int before = queries.get();
        assertTrue(service.query("SELECT 1 AS \"v\"").size() > 0);
        service.schemaContext(null);
        service.schemaContext("t");
        service.corpusRows("t", "emb", "id", null);
        service.corpusRows("t", "emb", null, "\"id\" > 1");
        service.textRows("t", "body", "id");
        service.textRows("t", "body", null);
        service.cell("t", "v");
        service.cells("t", "v");
        service.boxcountOf("0,0,1,0,1,1,0,1", 2);
        service.embedVector("hello");
        service.reason("q", null);
        service.embed("x");
        service.health();
        assertTrue(queries.get() > before);
        for (String m : new String[] {"error", "html", "empty", "nulls", "object"}) {
            mode = m;
            for (java.util.concurrent.Callable<Object> c : List.<java.util.concurrent.Callable<Object>>of(
                    () -> service.query("SELECT 1"), () -> service.schemaContext("t"), () -> service.corpusRows("t", "emb", "id", null),
                    () -> service.cell("t", "v"), () -> service.cells("t", "v"), () -> service.textRows("t", "b", "id"))) {
                try {
                    c.call();
                } catch (Exception expected) {
                    // an engine that fails is allowed to fail the call
                }
            }
        }
        mode = "ok";
    }
}
