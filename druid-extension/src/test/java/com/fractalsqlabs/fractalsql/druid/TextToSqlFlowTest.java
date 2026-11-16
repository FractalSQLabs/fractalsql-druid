/*
 * SPDX-License-Identifier: Apache-2.0
 * Copyright 2026 Daniel Gardiner d/b/a FractalSQLabs
 */
package com.fractalsqlabs.fractalsql.druid;

import com.fasterxml.jackson.databind.JsonNode;
import com.fasterxml.jackson.databind.ObjectMapper;
import com.sun.net.httpserver.HttpServer;
import org.junit.jupiter.api.AfterEach;
import org.junit.jupiter.api.BeforeEach;
import org.junit.jupiter.api.Test;

import javax.ws.rs.core.Response;

import java.io.OutputStream;
import java.net.InetSocketAddress;
import java.nio.charset.StandardCharsets;
import java.nio.file.Files;
import java.util.Properties;

import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertFalse;
import static org.junit.jupiter.api.Assertions.assertTrue;

/**
 * Text to SQL, the review and the embedding endpoints, with the daemon (and Druid's parser) answering in each way they can:
 * the statement is not SQL, is not allowed, is rejected by the review or by Druid, or the call itself fails.
 */
public class TextToSqlFlowTest {

    private static final ObjectMapper MAPPER = new ObjectMapper();

    private HttpServer druid;
    private FakeDaemon fake;
    private FractalSqlResource resource;
    private volatile int explainStatus = 200;

    @BeforeEach
    void start() throws Exception
    {
        druid = HttpServer.create(new InetSocketAddress("127.0.0.1", 0), 0);
        druid.createContext("/", ex -> {
            try {
                final String body = new String(ex.getRequestBody().readAllBytes(), StandardCharsets.UTF_8);
                final boolean explain = body.contains("EXPLAIN PLAN");
                final int code = explain ? explainStatus : 200;
                final byte[] out = (code == 200 ? "[{\"v\":1,\"name\":\"id\"}]" : "{\"errorMessage\":\"not valid\"}")
                        .getBytes(StandardCharsets.UTF_8);
                ex.getResponseHeaders().add("Content-Type", "application/json");
                ex.sendResponseHeaders(code, out.length);
                try (OutputStream os = ex.getResponseBody()) {
                    os.write(out);
                }
            } catch (java.io.IOException e) {
                ex.close();
            }
        });
        druid.start();

        fake = new FakeDaemon(Files.createTempDirectory("fsql-t2s"));
        final Properties props = new Properties();
        props.setProperty("druid.server.http.port", Integer.toString(druid.getAddress().getPort()));
        props.setProperty("druid.node.type", "broker");
        props.setProperty("druid.fractalsql.daemon_socket", fake.socket.toString());
        props.setProperty("druid.fractalsql.daemon_hmac_key_file", fake.keyFile.toString());
        props.setProperty("druid.fractalsql.daemon_timeout_ms", "5000");
        final FractalSqlConfig config = new FractalSqlConfig(() -> props);
        final FractalSqlDaemon daemon = new FractalSqlDaemon(config);
        final ReasoningBridge bridge = new ReasoningBridge(daemon);
        final FractalSqlService service = new FractalSqlService(config, bridge, () -> props);
        final FractalSqlEnterprise enterprise = new FractalSqlEnterprise(config, daemon);
        resource = new FractalSqlResource(service, new FractalSqlAgents(service, bridge, enterprise), bridge,
                new FractalSqlVectorizer(service, bridge), new FractalSqlIndex(service, daemon),
                enterprise, new FractalSqlSessions());
    }

    @AfterEach
    void stop() throws Exception
    {
        druid.stop(0);
        fake.close();
    }

    private JsonNode ok(Response r) throws Exception
    {
        assertEquals(200, r.getStatus(), String.valueOf(r.getEntity()));
        return MAPPER.readTree(String.valueOf(r.getEntity()));
    }

    private static String q(String question)
    {
        return "{\"question\":\"" + question + "\"}";
    }

    private void config(String allowed, boolean review, int attempts)
    {
        fake.answers.put("fractal_t2s_config", "{\"allowed_statements\":\"" + allowed + "\",\"use_review\":" + review
                + ",\"max_attempts\":" + attempts + "}");
    }

    @Test
    void aGoodStatementIsValidated() throws Exception
    {
        fake.answers.put("fractal_t2s_generate", "Here you go: `SELECT COUNT(*) FROM `t`;` enjoy");
        final JsonNode r = ok(resource.textToSql("{\"question\":\"how many\",\"tables\":[\"t\"],\"session\":\"s1\"}"));
        assertTrue(r.get("valid").asBoolean());
        assertEquals(1, r.get("attempts").asInt());
        assertTrue(r.get("generated_sql").asText().startsWith("SELECT"));
        assertFalse(r.get("generated_sql").asText().contains("`"));
        ok(resource.textToSql("{\"question\":\"how many\",\"tables\":\"t\"}"));
    }

    @Test
    void theRequestAndTheServiceCanBeWrong() throws Exception
    {
        assertEquals(400, resource.textToSql(q("")).getStatus());
        assertEquals(400, resource.textToSql("{}").getStatus());
        assertEquals(500, resource.textToSql("not json").getStatus());
        // no provider: the daemon answers NULL
        fake.nullReply = true;
        assertEquals(503, resource.textToSql(q("how many")).getStatus());
        fake.nullReply = false;
        fake.fail = true;
        assertEquals(503, resource.textToSql(q("how many")).getStatus());
        fake.fail = false;
    }

    @Test
    void anAnswerWithNoStatementIsRetriedThenReported() throws Exception
    {
        config("select", false, 3);
        fake.answers.put("fractal_t2s_generate", "I cannot help with that.");
        final JsonNode r = ok(resource.textToSql(q("how many")));
        assertFalse(r.get("valid").asBoolean());
        assertEquals(3, r.get("attempts").asInt());
        assertTrue(r.get("error").asText().contains("did not contain"));
    }

    @Test
    void theAllowListDecides() throws Exception
    {
        fake.answers.put("fractal_t2s_generate", "SELECT 1; (drop)");
        config("select", false, 1);
        // only SELECT is extracted from an answer, so the verb is always select: an empty allowlist refuses even that
        config("", false, 2);
        final JsonNode refused = ok(resource.textToSql(q("how many")));
        assertFalse(refused.get("valid").asBoolean());
        assertTrue(refused.get("error").asText().contains("allowlist"));
        config("delete, select", false, 1);
        assertTrue(ok(resource.textToSql(q("how many"))).get("valid").asBoolean());
    }

    @Test
    void theReviewCanRejectOrFail() throws Exception
    {
        fake.answers.put("fractal_t2s_generate", "SELECT 1");
        config("select", true, 2);
        fake.answers.put("fractal_t2s_review", "PASS fine");
        final JsonNode passed = ok(resource.textToSql(q("how many")));
        assertTrue(passed.get("valid").asBoolean());
        assertEquals("PASS fine", passed.get("review").asText());

        fake.answers.put("fractal_t2s_review", "FAIL: wrong table");
        final JsonNode rejected = ok(resource.textToSql(q("how many")));
        assertFalse(rejected.get("valid").asBoolean());
        assertEquals(2, rejected.get("attempts").asInt());
        assertTrue(rejected.get("error").asText().contains("review"));

        // the review call itself fails: the daemon is gone, so there is nothing to critique the candidate
        fake.answers.remove("fractal_t2s_review");
        fake.failing.add("fractal_t2s_review");
        final JsonNode r = ok(resource.textToSql(q("how many")));
        assertFalse(r.get("valid").asBoolean());
        assertTrue(r.get("error").asText().contains("review call failed"));
    }

    @Test
    void druidCanRejectTheStatement() throws Exception
    {
        fake.answers.put("fractal_t2s_generate", "SELECT nope FROM t");
        config("select", false, 2);
        explainStatus = 400;
        final JsonNode r = ok(resource.textToSql(q("how many")));
        assertFalse(r.get("valid").asBoolean());
        assertEquals(2, r.get("attempts").asInt());
        assertTrue(r.get("error").asText().contains("400") || r.get("error").asText().contains("not valid"));
    }

    @Test
    void reviewEndpoint() throws Exception
    {
        assertEquals(400, resource.review("{\"sql\":\"SELECT 1\"}").getStatus());
        assertEquals(400, resource.review("{\"question\":\"q\"}").getStatus());
        assertEquals(400, resource.review("{\"question\":\"\",\"sql\":\"x\"}").getStatus());
        assertEquals(400, resource.review("not json").getStatus());
        fake.answers.put("fractal_t2s_review", "PASS");
        assertTrue(ok(resource.review("{\"question\":\"q\",\"sql\":\"SELECT 1\"}")).get("passed").asBoolean());
        fake.answers.put("fractal_t2s_review", "FAIL: no");
        assertFalse(ok(resource.review("{\"question\":\"q\",\"sql\":\"SELECT 1\"}")).get("passed").asBoolean());
        fake.answers.remove("fractal_t2s_review");
        fake.fail = true;
        assertEquals(503, resource.review("{\"question\":\"q\",\"sql\":\"SELECT 1\"}").getStatus());
    }

    @Test
    void embedEndpoint() throws Exception
    {
        assertTrue(ok(resource.embed("{\"text\":\"hello\"}")).has("embedding"));
        assertEquals(400, resource.embed("{\"text\":\"\"}").getStatus());
        assertEquals(400, resource.embed("{}").getStatus());
        assertEquals(400, resource.embed("bad").getStatus());
        fake.fail = true;
        assertEquals(503, resource.embed("{\"text\":\"hello\"}").getStatus());
    }
}
