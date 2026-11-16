/*
 * SPDX-License-Identifier: Apache-2.0
 * Copyright 2026 Daniel Gardiner d/b/a FractalSQLabs
 */
package com.fractalsqlabs.fractalsql.druid;

import com.google.inject.Inject;

import javax.ws.rs.Consumes;
import javax.ws.rs.GET;
import javax.ws.rs.POST;
import javax.ws.rs.Path;
import javax.ws.rs.Produces;
import javax.ws.rs.core.MediaType;
import javax.ws.rs.core.Response;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;

/**
 * The extension's HTTP surface.
 *
 * <p>Registered with Druid's own Jersey binding
 * ({@code Jerseys.addResource(binder, FractalSqlResource.class)}), the
 * documented way for an extension to add an endpoint, and the one Druid's
 * own extensions use.
 *
 * <p>The operations here are the ones that cannot be SQL functions: they
 * need to issue queries, call a provider, or hold state. See
 * {@link FractalSqlService}.
 */
@Path("/fractalsql")
public class FractalSqlResource {

    private final FractalSqlService service;
    private final FractalSqlAgents agents;
    private final ReasoningBridge reasoning;
    private final FractalSqlVectorizer vectorizer;
    private final FractalSqlIndex index;
    private final FractalSqlEnterprise enterprise;
    private final FractalSqlSessions sessions;

    @Inject
    public FractalSqlResource(
            FractalSqlService service,
            FractalSqlAgents agents,
            ReasoningBridge reasoning,
            FractalSqlVectorizer vectorizer,
            FractalSqlIndex index,
            FractalSqlEnterprise enterprise,
            FractalSqlSessions sessions)
    {
        this.service = service;
        this.agents = agents;
        this.reasoning = reasoning;
        this.vectorizer = vectorizer;
        this.index = index;
        if (vectorizer != null) {
            vectorizer.setIndex(index);
        }
        this.enterprise = enterprise;
        this.sessions = sessions;
    }

    /**
     * The multimodal portfolio search: several diverse portfolios, or the Pareto front.
     *
     * <p>Body: {@code {"mode": "multimodal"|"ex"|"pareto", "mu": "...", "cov": "...", "k": 3,
     * "n_restarts": 8, "overlap_threshold": 0.15, "quality_frac": 0.9, "seed": 0,
     * "use_obl": 0, "diffusion_mode": "gaussian"|"levy", "max_front": 8}}.
     *
     * <p>Enterprise-gated: without the licensed core the call says the tier is not loaded.
     */
    @POST
    @Path("/portfolio")
    @Consumes(MediaType.APPLICATION_JSON)
    @Produces(MediaType.APPLICATION_JSON)
    public Response portfolio(String body)
    {
        try {
            @SuppressWarnings("unchecked")
            final Map<String, Object> args = service.mapper().readValue(body, Map.class);
            final String mode = args.get("mode") == null ? "multimodal" : args.get("mode").toString();
            final double[] mu = vector(args, "mu");
            final double[] cov = vector(args, "cov");
            final int k = integer(args, "k", 1);
            final int restarts = integer(args, "n_restarts", 8);
            final double overlap = args.get("overlap_threshold") instanceof Number
                    ? ((Number) args.get("overlap_threshold")).doubleValue() : 0.15;
            final double quality = args.get("quality_frac") instanceof Number
                    ? ((Number) args.get("quality_frac")).doubleValue() : 0.90;
            final long seed = args.get("seed") instanceof Number ? ((Number) args.get("seed")).longValue() : 0L;
            final boolean useObl = integer(args, "use_obl", 0) != 0;
            final int diffusion = "levy".equalsIgnoreCase(String.valueOf(args.get("diffusion_mode"))) ? 1 : 0;
            final String json;
            switch (mode) {
                case "ex":
                    json = enterprise.portfolioMultimodalEx(mu, cov, k, restarts, overlap, quality, seed, useObl, diffusion);
                    break;
                case "pareto":
                    json = enterprise.portfolioMultimodalPareto(mu, cov, k, restarts, integer(args, "max_front", 8),
                            seed, useObl, diffusion);
                    break;
                case "multimodal":
                    json = enterprise.portfolioMultimodal(mu, cov, k, restarts, overlap, quality, seed);
                    break;
                default:
                    return error(400, "no such portfolio mode: " + mode);
            }
            if (json == null) {
                return error(503, "the multimodal portfolio search is not available in this enterprise build");
            }
            return Response.ok(json).type(MediaType.APPLICATION_JSON).build();
        } catch (IllegalStateException e) {
            return error(503, e.getMessage());
        } catch (IllegalArgumentException e) {
            return error(400, e.getMessage());
        } catch (Exception e) {
            return error(500, "the portfolio search failed: " + e.getMessage());
        }
    }

    /** What the extension is and what it is configured with. */
    @GET
    @Path("/health")
    @Produces(MediaType.APPLICATION_JSON)
    public Response health()
    {
        try {
            return Response.ok(service.mapper().writeValueAsString(service.health()))
                    .type(MediaType.APPLICATION_JSON)
                    .build();
        } catch (Exception e) {
            return error(500, "could not write the response: " + e.getMessage());
        }
    }

    /**
     * Ask the provider a question.
     *
     * <p>Body: {@code {"query": "...", "context": "..."}}.
     */
    @POST
    @Path("/reason")
    @Consumes(MediaType.APPLICATION_JSON)
    @Produces(MediaType.APPLICATION_JSON)
    public Response reason(String body)
    {
        try {
            @SuppressWarnings("unchecked")
            final Map<String, Object> args = service.mapper().readValue(body, Map.class);
            final String query = args == null ? null : (String) args.get("query");
            final String context = args == null ? null : (String) args.get("context");
            if (query == null || query.isEmpty()) {
                return error(400, "the request needs a \"query\"");
            }
            final String answer = service.reason(query, context);
            if (answer == null) {
                return error(503, "no reasoning provider is configured, or the call failed");
            }
            return Response.ok(service.mapper().writeValueAsString(Map.of("answer", answer)))
                    .type(MediaType.APPLICATION_JSON)
                    .build();
        } catch (Exception e) {
            return error(400, "could not read the request: " + e.getMessage());
        }
    }

    /**
     * The review tier: a candidate judged against the request that
     * produced it.
     *
     * <p>Body: {@code {"question": "...", "sql": "..."}}. The answer is
     * a critique whose first line is the verdict: PASS or FAIL, then an
     * explanation.
     *
     * <p>This is a separate endpoint from {@code /reason} because the
     * review runs on the review CONTEXT, whose response mode is text --
     * hardcoded, and not the operator's choice. A code- or json-mode
     * answer would not begin with a verdict a caller could read.
     */
    @POST
    @Path("/review")
    @Consumes(MediaType.APPLICATION_JSON)
    @Produces(MediaType.APPLICATION_JSON)
    public Response review(String body)
    {
        try {
            @SuppressWarnings("unchecked")
            final Map<String, Object> args = service.mapper().readValue(body, Map.class);
            final String question = args == null ? null : (String) args.get("question");
            final String sql = args == null ? null : (String) args.get("sql");
            if (question == null || question.isEmpty()) {
                return error(400, "the request needs a \"question\"");
            }
            if (sql == null || sql.isEmpty()) {
                return error(400, "the request needs a \"sql\"");
            }
            final String critique = reasoning.review(question, sql);
            if (critique == null) {
                return error(503, "no reasoning provider is configured, or the call failed");
            }
            final Map<String, Object> result = new LinkedHashMap<>();
            result.put("question", question);
            result.put("sql", sql);
            result.put("review", critique);
            result.put("passed", reviewPassed(critique));
            return Response.ok(service.mapper().writeValueAsString(result))
                    .type(MediaType.APPLICATION_JSON)
                    .build();
        } catch (Exception e) {
            return error(400, "could not read the request: " + e.getMessage());
        }
    }

    /**
     * Embed a piece of text.
     *
     * <p>Body: {@code {"text": "..."}}.
     */
    @POST
    @Path("/embed")
    @Consumes(MediaType.APPLICATION_JSON)
    @Produces(MediaType.APPLICATION_JSON)
    public Response embed(String body)
    {
        try {
            @SuppressWarnings("unchecked")
            final Map<String, Object> args = service.mapper().readValue(body, Map.class);
            final String text = args == null ? null : (String) args.get("text");
            if (text == null || text.isEmpty()) {
                return error(400, "the request needs a \"text\"");
            }
            final String vector = service.embed(text);
            if (vector == null) {
                return error(503, "no embedding provider is configured, or the call failed");
            }
            return Response.ok(service.mapper().writeValueAsString(Map.of("embedding", vector)))
                    .type(MediaType.APPLICATION_JSON)
                    .build();
        } catch (Exception e) {
            return error(400, "could not read the request: " + e.getMessage());
        }
    }

    /**
     * The schema context: a datasource's columns, or the datasource
     * inventory when no datasource is named.
     *
     * <p>This is the Druid form of
     * {@code fractal_schema_context()}: the information, read from
     * {@code INFORMATION_SCHEMA} from the catalog.
     */
    @GET
    @Path("/schema-context")
    @Produces(MediaType.APPLICATION_JSON)
    public Response schemaContext(@javax.ws.rs.QueryParam("datasource") String datasource)
    {
        try {
            return Response.ok(service.mapper().writeValueAsString(service.schemaContext(datasource)))
                    .type(MediaType.APPLICATION_JSON)
                    .build();
        } catch (Exception e) {
            return error(500, "could not read the schema: " + e.getMessage());
        }
    }

    /**
     * The Scout result over a datasource's vector column.
     *
     * <p>Body: {@code {"datasource": "...", "vectorColumn": "...",
     * "idColumn": "...", "query": "[...]", "k": 5, "params": "{...}"}}.
     *
     * <p>This is the corpus tier: the SFS converges over the whole
     * column and then ranks it, so the corpus has to be materialised
     * somewhere. It is not a Druid aggregate -- the per-group
     * intermediate would have to hold the entire corpus, and Druid caps
     * that -- so the service reads the column and calls the core.
     */
    @POST
    @Path("/search/explore")
    @Consumes(MediaType.APPLICATION_JSON)
    @Produces(MediaType.APPLICATION_JSON)
    public Response searchExplore(String body)
    {
        try {
            @SuppressWarnings("unchecked")
            final Map<String, Object> args = service.mapper().readValue(body, Map.class);
            final String datasource = either(args, "datasource", "table");
            final String column = either(args, "vectorColumn", "column");
            if (datasource == null || column == null) {
                return error(400, "the request needs a \"datasource\" and a \"vectorColumn\"");
            }
            // Scout's shape: the walk off and the final population
            // returned, so the picks can be matched back to the rows.
            String params = string(args, "params");
            if (params == null || params.trim().isEmpty()) {
                params = "{}";
            }
            params = params.trim();
            if (params.startsWith("{")) {
                params = params.substring(1, params.length() - 1).trim();
            }
            if (!params.isEmpty()) {
                params = "," + params;
            }
            params = "{\"walk\":0,\"return_population\":true,\"bound_clipping\":true" + params + "}";
            final Object result = service.searchExplore(
                    datasource,
                    column,
                    either(args, "idColumn", "id_column"),
                    string(args, "query"),
                    integer(args, "k", 5),
                    params);
            return Response.ok(service.mapper().writeValueAsString(result))
                    .type(MediaType.APPLICATION_JSON)
                    .build();
        } catch (Exception e) {
            return error(400, "could not run the search: " + e.getMessage());
        }
    }

    /**
     * The ground-truth nearest rows of a datasource's vector column.
     *
     * <p>Body: {@code {"datasource": "...", "vectorColumn": "...",
     * "idColumn": "...", "query": "[...]", "k": 5}}.
     */
    @POST
    @Path("/search/telemetry")
    @Consumes(MediaType.APPLICATION_JSON)
    @Produces(MediaType.APPLICATION_JSON)
    public Response searchTelemetry(String body)
    {
        try {
            @SuppressWarnings("unchecked")
            final Map<String, Object> args = service.mapper().readValue(body, Map.class);
            final String datasource = either(args, "datasource", "table");
            final String column = either(args, "vectorColumn", "column");
            if (datasource == null || column == null) {
                return error(400, "the request needs a \"datasource\" and a \"vectorColumn\"");
            }
            final String queryVector = args.get("query") != null
                    ? string(args, "query")
                    : cell(args, "query_table", "query_column");
            final Object result = service.searchTelemetry(
                    datasource,
                    column,
                    either(args, "idColumn", "id_column"),
                    queryVector,
                    integer(args, "k", 5));
            return Response.ok(service.mapper().writeValueAsString(result))
                    .type(MediaType.APPLICATION_JSON)
                    .build();
        } catch (Exception e) {
            return error(400, "could not run the search: " + e.getMessage());
        }
    }

    /**
     * The index tier: the native IVF index and the indexed search.
     *
     * <p>Body: {@code {"action": "create"|"rebuild"|"refresh"|"ensure"|"drop"|"info"|
     * "list"|"candidates"|"search", ...}}.
     *
     * <p>These are the honest home of the index's operations on this host:
     * they read a datasource and (for a build) write one, and a Druid SQL
     * function cannot issue the queries and the MSQ writes they need.
     */
    @POST
    @Path("/index")
    @Consumes(MediaType.APPLICATION_JSON)
    @Produces(MediaType.APPLICATION_JSON)
    public Response index(String body)
    {
        try {
            @SuppressWarnings("unchecked")
            final Map<String, Object> args = service.mapper().readValue(body, Map.class);
            final String action = string(args, "action");
            if (action == null) {
                return error(400, "the request needs an \"action\"");
            }
            // the options arrive as a JSON object (the demo kits and the MCP send one); the index tier reads them as JSON text
            final Object rawOptions = args.get("options");
            final String options = rawOptions == null ? null
                    : rawOptions instanceof String ? (String) rawOptions : service.mapper().writeValueAsString(rawOptions);
            switch (action) {
                case "create":
                    return ok(index.create(
                            string(args, "table"),
                            string(args, "column"),
                            options));
                case "rebuild":
                    return ok(index.rebuild(string(args, "name"), options));
                case "refresh":
                    return ok(index.refresh(string(args, "name")));
                case "ensure":
                    return ok(index.ensure(
                            string(args, "table"),
                            string(args, "column"),
                            options));
                case "drop":
                    return ok(index.drop(string(args, "name")));
                case "info":
                    return ok(index.info(string(args, "name")));
                case "list":
                    return ok(Map.of("indexes", index.list()));
                case "candidates":
                    return ok(index.candidates(
                            string(args, "table"),
                            string(args, "column"),
                            string(args, "query"),
                            options));
                case "search":
                    return ok(index.search(
                            string(args, "table"),
                            string(args, "column"),
                            string(args, "query"),
                            integer(args, "k", 10),
                            options));
                default:
                    return error(400, "no such index action: " + action);
            }
        } catch (IllegalArgumentException e) {
            return error(400, e.getMessage());
        } catch (IllegalStateException e) {
            // the "no IVF index in this core" case, and every other refusal
            // the daemon reports, reaches the caller verbatim
            return error(400, e.getMessage());
        } catch (Exception e) {
            return error(500, "the index operation failed: " + e.getMessage());
        }
    }

    /**
     * Split text into chunks (no model): body {@code {"text": ..., "chunk_size": n, "chunk_overlap": n, "chunk_mode":
     * "paragraph"|"sentence"|"fixed"}}. Returns {@code {"chunks": [{no, start, end, text}]}}, the same chunks every FractalSQL host returns.
     */
    @POST
    @Path("/chunk")
    @Consumes(MediaType.APPLICATION_JSON)
    @Produces(MediaType.APPLICATION_JSON)
    public Response chunk(String body)
    {
        try {
            @SuppressWarnings("unchecked")
            final Map<String, Object> args = service.mapper().readValue(body, Map.class);
            final String text = string(args, "text");
            if (text == null) {
                return error(400, "the request needs a \"text\"");
            }
            return ok(Map.of("chunks", FractalSqlChunker.chunk(
                    text,
                    integer(args, "chunk_size", 800),
                    integer(args, "chunk_overlap", 0),
                    string(args, "chunk_mode"))));
        } catch (IllegalArgumentException e) {
            return error(400, e.getMessage());
        } catch (Exception e) {
            return error(500, "the chunking failed: " + e.getMessage());
        }
    }

    /**
     * The vectorizer tier.
     *
     * <p>Body: {@code {"action": "create"|"drop"|"pause"|"resume"|
     * "process_queue"|"status"|"list", ...}}.
     */
    @POST
    @Path("/vectorizer")
    @Consumes(MediaType.APPLICATION_JSON)
    @Produces(MediaType.APPLICATION_JSON)
    public Response vectorizer(String body)
    {
        try {
            @SuppressWarnings("unchecked")
            final Map<String, Object> args = service.mapper().readValue(body, Map.class);
            final String action = string(args, "action");
            if (action == null) {
                return error(400, "the request needs an \"action\"");
            }
            switch (action) {
                case "create": {
                    @SuppressWarnings("unchecked")
                    final Map<String, Object> options = args.get("options") instanceof Map
                            ? (Map<String, Object>) args.get("options") : null;
                    return ok(vectorizer.create(
                            string(args, "source_table"),
                            string(args, "source_column"),
                            string(args, "embedding_column"),
                            either(args, "id_column", "idColumn"),
                            options));
                }
                case "drop":
                    return ok(Map.of("dropped", vectorizer.drop(integer(args, "id", 0))));
                case "pause":
                    return ok(Map.of("paused", vectorizer.pause(integer(args, "id", 0))));
                case "resume":
                    return ok(Map.of("resumed", vectorizer.resume(integer(args, "id", 0))));
                case "list":
                    return ok(Map.of("vectorizers", vectorizer.list()));
                case "status":
                    return ok(vectorizer.status(integer(args, "id", 0)));
                case "process_queue":
                    return ok(vectorizer.processQueue(integer(args, "batch_size", 0)));
                default:
                    return error(400, "no such vectorizer action: " + action);
            }
        } catch (IllegalArgumentException e) {
            return error(400, e.getMessage());
        } catch (Exception e) {
            return error(500, "the vectorizer failed: " + e.getMessage());
        }
    }

    /**
     * The ledger tier.
     *
     * <p>Body: {@code {"action": "flush"|"load"|"compact"|"reset_soft"|
     * "reset_hard"|"truth_count"|"shadow_count"|"verify"|"audit_unpack"|
     * "status", "blob": "..."}}.
     *
     * <p>The mutating actions are enterprise-gated: without the
     * enterprise core loaded they report that the tier is not loaded.
     * {@code verify} and {@code status} are not -- they read the
     * port's own chain file, so an auditor can use them on a Community
     * deployment too.
     */
    @POST
    @Path("/ledger")
    @Consumes(MediaType.APPLICATION_JSON)
    @Produces(MediaType.APPLICATION_JSON)
    public Response ledger(String body)
    {
        try {
            @SuppressWarnings("unchecked")
            final Map<String, Object> args = service.mapper().readValue(body, Map.class);
            final String action = string(args, "action");
            if (action == null) {
                return error(400, "the request needs an \"action\"");
            }
            switch (action) {
                case "flush":
                    return ok(Map.of("sealed", enterprise.flush()));
                case "load":
                    return ok(Map.of("loaded", enterprise.load()));
                case "compact":
                    return ok(Map.of("records", enterprise.compact()));
                case "reset_soft":
                    return ok(Map.of("dropped", enterprise.resetSoft()));
                case "reset_hard":
                    return ok(Map.of("dropped", enterprise.resetHard()));
                case "truth_count":
                    return ok(Map.of("count", enterprise.truthCount()));
                case "shadow_count":
                    return ok(Map.of("count", enterprise.shadowCount()));
                case "verify":
                    return ok(Map.of("verify", enterprise.verify(integer(args, "kind", 1))));
                case "audit_unpack":
                    return ok(Map.of("audit_log", enterprise.auditUnpack(string(args, "blob"))));
                case "status":
                    return ok(enterprise.status());
                default:
                    return error(400, "no such ledger action: " + action);
            }
        } catch (IllegalArgumentException e) {
            return error(400, e.getMessage());
        } catch (IllegalStateException e) {
            // The dormancy message and the core's own errors carry
            // their own text; a 503 says the tier is not available
            // rather than the endpoint being broken.
            return error(503, e.getMessage());
        } catch (Exception e) {
            return error(500, "the ledger failed: " + e.getMessage());
        }
    }

    /**
     * The cognition tier: a question becomes a validated statement.
     *
     * <p>Body: {@code {"question": "...", "tables": ["..."]}}. The
     * candidate is validated against Druid's own parser with
     * {@code EXPLAIN PLAN FOR} before it is returned, so a statement
     * that Druid cannot run never reaches the caller.
     */
    @POST
    @Path("/text-to-sql")
    @Consumes(MediaType.APPLICATION_JSON)
    @Produces(MediaType.APPLICATION_JSON)
    public Response textToSql(String body)
    {
        try {
            @SuppressWarnings("unchecked")
            final Map<String, Object> args = service.mapper().readValue(body, Map.class);
            final String question = string(args, "question");
            if (question == null || question.isEmpty()) {
                return error(400, "the request needs a \"question\"");
            }
            // The schema the model is given: the named datasources' columns,
            // or every datasource in the catalog when none are named.
            final java.util.List<String> tableList = FractalSqlAgents3.tableNames(args);
            final String tables = tableList.isEmpty() ? "(the whole catalog)" : String.join(", ", tableList);
            final String schema = FractalSqlAgents3.schemaContext(service, tableList);
            final String session = string(args, "session");
            final String allowed = reasoning.t2sAllowedStatements(session);
            final boolean review = reasoning.t2sUseReview(session);
            final int attempts = Math.max(1, reasoning.t2sMaxAttempts(session));

            // Each attempt generates a statement on the text-to-SQL context
            // (mode code: the statement arrives without the prose around it),
            // then checks it three ways: the operator's allowlist, the
            // optional review on the review context, and Druid's own parser
            // through EXPLAIN PLAN FOR. A failed check is fed back into the
            // next attempt.
            final Map<String, Object> result = new LinkedHashMap<>();
            result.put("question", question);
            String feedback = null;
            for (int attempt = 1; attempt <= attempts; attempt++) {
                result.put("attempts", attempt);
                result.remove("error");
                result.remove("review");
                final String answer = reasoning.reasonForStatement(session,
                        "Write a single Druid SQL SELECT statement that answers this question "
                                + "over these tables: " + tables + ". Question: " + question
                                + (feedback == null ? ""
                                        : "\nYour previous attempt was rejected: " + feedback
                                                + "\nWrite a different statement."),
                        schema);
                if (answer == null) {
                    return error(503, "the reasoning service is not reachable, or the call failed");
                }
                final String sql = extractSql(answer);
                if (sql == null) {
                    feedback = "the answer did not contain a SQL statement";
                    result.put("valid", Boolean.FALSE);
                    result.put("error", feedback);
                    continue;
                }
                // Druid quotes identifiers with double quotes; a model that
                // reaches for backticks is thinking of another dialect.
                final String druidSql = sql.replace("`", "\"");
                result.put("generated_sql", druidSql);

                final String verb = leadingKeyword(druidSql);
                if (!isAllowed(allowed, verb)) {
                    feedback = "the statement is a " + verb.toUpperCase()
                            + " statement, and the operator's allowlist (" + allowed + ") does not permit it";
                    result.put("valid", Boolean.FALSE);
                    result.put("error", feedback);
                    continue;
                }
                if (review) {
                    final String critique = reasoning.review(session, question, druidSql);
                    if (critique == null) {
                        result.put("valid", Boolean.FALSE);
                        result.put("error", "the review call failed");
                        return ok(result);
                    }
                    result.put("review", critique);
                    if (!reviewPassed(critique)) {
                        feedback = "the review said: " + critique;
                        result.put("valid", Boolean.FALSE);
                        result.put("error", "the model's own review rejected the candidate");
                        continue;
                    }
                }
                try {
                    service.query("EXPLAIN PLAN FOR " + druidSql);
                    result.put("valid", Boolean.TRUE);
                    return ok(result);
                } catch (Exception e) {
                    feedback = e.getMessage();
                    result.put("valid", Boolean.FALSE);
                    result.put("error", e.getMessage());
                }
            }
            return ok(result);
        } catch (IllegalArgumentException e) {
            return error(400, e.getMessage());
        } catch (Exception e) {
            return error(500, "the statement could not be generated: " + e.getMessage());
        }
    }

    /**
     * The statement's leading keyword, lowercased.
     *
     * <p>Whitespace and an opening parenthesis are skipped, so a
     * statement that opens with one still reports the verb that
     * follows.
     */
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

    /**
     * Whether a review's verdict is a pass.
     *
     * <p>The review context's prompt asks for PASS or FAIL on the first
     * line, and this reads that line. A leading "PASS" is a pass; a
     * leading "FAIL" is not; anything else is not a pass either, since
     * a verdict that cannot be read is not a verdict.
     */
    private static boolean reviewPassed(String critique)
    {
        if (critique == null) {
            return false;
        }
        String trimmed = critique.trim();
        // The verdict is on the first line, but a model that put a
        // markdown heading or a bullet in front of it is still
        // answering the question; look a little way in.
        final int newline = trimmed.indexOf('\n');
        final String firstLine = newline < 0 ? trimmed : trimmed.substring(0, newline);
        final String head = firstLine.trim().toLowerCase(java.util.Locale.ROOT);
        return head.startsWith("pass");
    }

    /**
     * Whether a statement's verb is on the operator's allowlist.
     *
     * <p>The list is comma-separated and case-insensitive. An empty
     * list permits nothing, which is the safe reading of a knob that
     * exists to stop a model from writing a statement the operator did
     * not ask for.
     */
    private static boolean isAllowed(String allowed, String verb)
    {
        if (allowed == null) {
            return false;
        }
        for (String one : allowed.split(",")) {
            final String trimmed = one.trim().toLowerCase(java.util.Locale.ROOT);
            if (!trimmed.isEmpty() && trimmed.equals(verb)) {
                return true;
            }
        }
        return false;
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
        return trimmed.substring(start, end).trim();
    }

    /**
     * The agency tier: one composite agent.
     *
     * <p>Body: the agent's arguments, by name -- the same names as the
     * SQL agent function's arguments, so a demo's call reads the same
     * either way:
     *
     * <pre>
     *   {"log_table": "ops_logs", "metric_col": "value", ...}
     * </pre>
     *
     * <p>The result is the agent's decision document.
     */
    @POST
    @Path("/agent/{name}")
    @Consumes(MediaType.APPLICATION_JSON)
    @Produces(MediaType.APPLICATION_JSON)
    public Response agent(@javax.ws.rs.PathParam("name") String name, String body)
    {
        try {
            @SuppressWarnings("unchecked")
            final Map<String, Object> request = service.mapper().readValue(body, Map.class);
            final Map<String, Object> args = new LinkedHashMap<>(request == null ? Map.of() : request);
            // The standard spelling of the identity column is id_col; the
            // service reads id_column. Either is accepted.
            if (args.get("id_col") != null && args.get("id_column") == null) {
                args.put("id_column", args.get("id_col"));
            }
            final boolean partial = !Boolean.FALSE.equals(args.remove("partial"));
            final Map<String, Object> result = agents.run(name, args);
            // Partial-result honesty: an agent that computes a result and then
            // reasons over it returns the computed half plus
            // "reasoning_step_failed" when the model call fails, instead of
            // raising -- unless the caller sent "partial": false.
            for (String key : new String[] {"rationale", "triage_summary", "analysis", "answer"}) {
                // A model that spends its whole budget thinking can answer with nothing at all: a blank reply is
                // a failed reasoning step, the same as no reply.
                final Object reply = result.get(key);
                if (result.containsKey(key)
                        && (reply == null || (reply instanceof String && ((String) reply).trim().isEmpty()))) {
                    if (!partial) {
                        return error(502, "the reasoning call failed after the data step");
                    }
                    result.put("reasoning_step_failed",
                            "the reasoning service did not answer, or the call failed");
                    break;
                }
            }
            return Response.ok(service.mapper().writeValueAsString(result))
                    .type(MediaType.APPLICATION_JSON)
                    .build();
        } catch (IllegalArgumentException e) {
            return error(400, e.getMessage());
        } catch (Exception e) {
            return error(500, "the agent failed: " + e.getMessage());
        }
    }

    /**
     * The trajectory search: which rows are nearest to the movement
     * from a baseline state to a current one.
     *
     * <p>Body: {@code {"table": "...", "column": "...",
     * "baseline": "...", "current": "...", "k": 5}}.
     */
    @POST
    @Path("/search/trajectory")
    @Consumes(MediaType.APPLICATION_JSON)
    @Produces(MediaType.APPLICATION_JSON)
    public Response searchTrajectory(String body)
    {
        try {
            @SuppressWarnings("unchecked")
            final Map<String, Object> args = service.mapper().readValue(body, Map.class);
            // The two vectors may be given as text, or taken from a
            // one-row datasource the caller computed.
            final double[] baseline = args.get("baseline") != null
                    ? vector(args, "baseline")
                    : parseVector(cell(args, "baseline_table", "baseline_column"));
            final double[] current = args.get("current") != null
                    ? vector(args, "current")
                    : parseVector(cell(args, "current_table", "current_column"));
            if (baseline.length != current.length) {
                return error(400, "the baseline and the current vector must have the same dimension");
            }
            final double[] delta = new double[baseline.length];
            for (int i = 0; i < delta.length; i++) {
                delta[i] = current[i] - baseline[i];
            }
            final Map<String, Object> result = service.searchTelemetry(
                    either(args, "table", "datasource"), either(args, "column", "vectorColumn"),
                    either(args, "id_column", "idColumn"),
                    java.util.Arrays.toString(delta), integer(args, "k", 5));
            return ok(result);
        } catch (IllegalArgumentException e) {
            return error(400, e.getMessage());
        } catch (Exception e) {
            return error(500, "the trajectory search failed: " + e.getMessage());
        }
    }

    /**
     * The hybrid clinical search: the nearest rows, restricted to a
     * cohort of identities.
     *
     * <p>Body: {@code {"table": "...", "column": "...", "query": "...",
     * "docIds": [1,2,3], "k": 5}}.
     */
    @POST
    @Path("/search/hybrid")
    @Consumes(MediaType.APPLICATION_JSON)
    @Produces(MediaType.APPLICATION_JSON)
    public Response searchHybrid(String body)
    {
        try {
            @SuppressWarnings("unchecked")
            final Map<String, Object> args = service.mapper().readValue(body, Map.class);
            final java.util.Set<String> cohort = new java.util.LinkedHashSet<>();
            final Object ids = args.get("docIds");
            if (ids instanceof java.util.List) {
                for (Object id : (java.util.List<?>) ids) {
                    cohort.add(String.valueOf(id));
                }
            } else if (args.get("docIdsTable") != null) {
                // The cohort the caller computed, written into a
                // one-row datasource.
                final String text = cell(args, "docIdsTable", "docIdsColumn");
                for (String id : text.split(",")) {
                    final String trimmed = id.trim();
                    if (!trimmed.isEmpty()) {
                        cohort.add(trimmed);
                    }
                }
            }
            final Map<String, Object> result = service.searchTelemetry(
                    either(args, "table", "datasource"), either(args, "column", "vectorColumn"),
                    either(args, "id_column", "idColumn"),
                    string(args, "query"), integer(args, "k", 5), cohort, null);
            return ok(result);
        } catch (IllegalArgumentException e) {
            return error(400, e.getMessage());
        } catch (Exception e) {
            return error(500, "the hybrid search failed: " + e.getMessage());
        }
    }

    /**
     * The cross-modal search: a query that blends a morphological and a
     * clinical vector.
     *
     * <p>Body: {@code {"table": "...", "column": "...", "morph": "...",
     * "clinical": "...", "alpha": 0.5, "k": 3}}.
     */
    @POST
    @Path("/search/cross-modal")
    @Consumes(MediaType.APPLICATION_JSON)
    @Produces(MediaType.APPLICATION_JSON)
    public Response searchCrossModal(String body)
    {
        try {
            @SuppressWarnings("unchecked")
            final Map<String, Object> args = service.mapper().readValue(body, Map.class);
            final double[] morph = vector(args, "morph");
            final double[] clinical = vector(args, "clinical");
            if (morph.length != clinical.length) {
                return error(400, "the two vectors must have the same dimension");
            }
            final double alpha = number(args, "alpha", 0.5);
            final double[] blended = new double[morph.length];
            for (int i = 0; i < blended.length; i++) {
                blended[i] = alpha * morph[i] + (1.0 - alpha) * clinical[i];
            }
            final Map<String, Object> result = service.searchTelemetry(
                    either(args, "table", "datasource"), either(args, "column", "vectorColumn"),
                    either(args, "id_column", "idColumn"),
                    java.util.Arrays.toString(blended), integer(args, "k", 3));
            return ok(result);
        } catch (IllegalArgumentException e) {
            return error(400, e.getMessage());
        } catch (Exception e) {
            return error(500, "the cross-modal search failed: " + e.getMessage());
        }
    }

    /**
     * One cell of a one-row datasource: the text the caller stored
     * there.
     */
    private String cell(Map<String, Object> args, String tableKey, String columnKey)
            throws Exception
    {
        final String table = string(args, tableKey);
        final String column = string(args, columnKey);
        if (table == null || column == null) {
            throw new IllegalArgumentException("the request needs a \"" + tableKey + "\" and a \"" + columnKey + "\"");
        }
        final List<Map<String, Object>> rows = service.query(
                "SELECT \"" + column.replace("\"", "\"\"") + "\" AS \"v\" FROM \""
                        + table.replace("\"", "\"\"") + "\"");
        if (rows.isEmpty() || rows.get(0).get("v") == null) {
            throw new IllegalArgumentException("no value in " + table + "." + column);
        }
        return rows.get(0).get("v").toString();
    }

    /** A vector argument, as the core's text form. */
    private static double[] vector(Map<String, Object> args, String key)
    {
        final String text = string(args, key);
        final double[] v = VectorText.parseVector(text);
        if (v == null) {
            throw new IllegalArgumentException("could not parse the \"" + key + "\" vector");
        }
        return v;
    }

    /** A vector, from its text form. */
    private static double[] parseVector(String text)
    {
        final double[] v = VectorText.parseVector(text);
        if (v == null) {
            throw new IllegalArgumentException("could not parse the vector");
        }
        return v;
    }

    /** A numeric argument, or a fallback. */
    private static double number(Map<String, Object> args, String key, double fallback)
    {
        final Object value = args.get(key);
        if (value instanceof Number) {
            return ((Number) value).doubleValue();
        }
        return fallback;
    }

    /** A JSON response for a result document. */
    private Response ok(Map<String, Object> result) throws Exception
    {
        return Response.ok(service.mapper().writeValueAsString(result))
                .type(MediaType.APPLICATION_JSON)
                .build();
    }

    /**
     * The box-counting dimension of a point cloud.
     *
     * <p>Body: {@code {"datasource": "...", "entityColumn": "...",
     * "xColumn": "...", "yColumn": "...", "dim": 2}}.
     *
     * <p>A service operation rather than a SQL function because the
     * count is over a whole cloud: as an expression it would run once
     * per row of the group.
     */
    @POST
    @Path("/boxcount")
    @Consumes(MediaType.APPLICATION_JSON)
    @Produces(MediaType.APPLICATION_JSON)
    public Response boxcount(String body)
    {
        try {
            @SuppressWarnings("unchecked")
            final Map<String, Object> args = service.mapper().readValue(body, Map.class);
            final String datasource = string(args, "datasource");
            final String xColumn = string(args, "xColumn");
            final String yColumn = string(args, "yColumn");
            if (datasource == null || xColumn == null || yColumn == null) {
                return error(400, "the request needs a \"datasource\", an \"xColumn\" and a \"yColumn\"");
            }
            final int dim = integer(args, "dim", 2);
            final Map<String, Object> result = new LinkedHashMap<>();
            result.put("rows", service.boxcount(
                    datasource, string(args, "entityColumn"), xColumn, yColumn, dim));
            return Response.ok(service.mapper().writeValueAsString(result))
                    .type(MediaType.APPLICATION_JSON)
                    .build();
        } catch (IllegalArgumentException e) {
            return error(400, e.getMessage());
        } catch (Exception e) {
            return error(500, "could not count the boxes: " + e.getMessage());
        }
    }

    /**
     * A named argument, under either of two names:
     * the corpus endpoints say "datasource" and "vectorColumn", the
     * SQL agent functions say "table" and "col".
     */
    private static String either(Map<String, Object> args, String... keys)
    {
        for (String key : keys) {
            final String value = string(args, key);
            if (value != null && !value.isEmpty()) {
                return value;
            }
        }
        return null;
    }

    private static String string(Map<String, Object> args, String key)
    {
        final Object value = args == null ? null : args.get(key);
        return value == null ? null : value.toString();
    }

    private static int integer(Map<String, Object> args, String key, int fallback)
    {
        final Object value = args == null ? null : args.get(key);
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

    private static Response error(int status, String message)
    {
        return Response.status(status)
                .entity(Map.of("error", message))
                .type(MediaType.APPLICATION_JSON)
                .build();
    }
}
