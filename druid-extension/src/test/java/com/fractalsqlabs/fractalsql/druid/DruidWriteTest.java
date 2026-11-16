/*
 * SPDX-License-Identifier: Apache-2.0
 * Copyright 2026 Daniel Gardiner d/b/a FractalSQLabs
 */
package com.fractalsqlabs.fractalsql.druid;

import com.sun.net.httpserver.HttpServer;
import org.junit.jupiter.api.AfterEach;
import org.junit.jupiter.api.BeforeEach;
import org.junit.jupiter.api.Test;

import java.io.OutputStream;
import java.net.InetSocketAddress;
import java.nio.charset.StandardCharsets;
import java.nio.file.Files;
import java.util.List;
import java.util.Map;
import java.util.Properties;
import java.util.concurrent.atomic.AtomicInteger;

import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertFalse;
import static org.junit.jupiter.api.Assertions.assertNotNull;
import static org.junit.jupiter.api.Assertions.assertThrows;
import static org.junit.jupiter.api.Assertions.assertTrue;

/**
 * Writes into Druid (an MSQ task, polled to its end) and the vectorizer that uses them, against a stand-in Druid that answers
 * the task endpoints, the task status and the SQL the vectorizer asks, in each way a real one can.
 */
public class DruidWriteTest {

    private HttpServer druid;
    private FakeDaemon fake;
    private FractalSqlService service;
    private FractalSqlVectorizer vectorizer;
    private Properties props;

    /** how the stand-in answers: the task submission, the status poll, and the SQL */
    private volatile String submit = "ok";
    private volatile String status = "success";
    private volatile String embedded = "none";
    private volatile String sqlMode = "ok";
    private final AtomicInteger polls = new AtomicInteger();
    private final AtomicInteger submissions = new AtomicInteger();

    private void reply(com.sun.net.httpserver.HttpExchange ex, int code, String body) throws java.io.IOException
    {
        final byte[] out = body.getBytes(StandardCharsets.UTF_8);
        ex.getResponseHeaders().add("Content-Type", "application/json");
        ex.sendResponseHeaders(code, out.length);
        try (OutputStream os = ex.getResponseBody()) {
            os.write(out);
        }
    }

    @BeforeEach
    void start() throws Exception
    {
        druid = HttpServer.create(new InetSocketAddress("127.0.0.1", 0), 0);
        druid.createContext("/", ex -> {
            try {
                final String path = ex.getRequestURI().getPath();
                final String body = new String(ex.getRequestBody().readAllBytes(), StandardCharsets.UTF_8);
                if (path.endsWith("/druid/v2/sql/task")) {
                    submissions.incrementAndGet();
                    switch (submit) {
                        case "noid":
                            reply(ex, 200, "{\"state\":\"x\"}");
                            return;
                        case "null":
                            reply(ex, 200, "null");
                            return;
                        case "error":
                            reply(ex, 500, "{\"errorMessage\":\"no\"}");
                            return;
                        default:
                            reply(ex, 200, "{\"taskId\":\"t1\"}");
                            return;
                    }
                }
                if (path.contains("/druid/indexer/v1/task/")) {
                    final int n = polls.incrementAndGet();
                    switch (status) {
                        case "failed":
                            reply(ex, 200, "{\"task\":\"t1\",\"status\":{\"status\":\"FAILED\",\"errorMsg\":\"boom\"}}");
                            return;
                        case "canceled":
                            reply(ex, 200, "{\"task\":\"t1\",\"status\":{\"statusCode\":\"CANCELED\"}}");
                            return;
                        case "running":
                            reply(ex, 200, n < 2 ? "{\"task\":\"t1\",\"status\":{\"status\":\"RUNNING\"}}"
                                    : "{\"task\":\"t1\",\"status\":{\"status\":\"SUCCESS\"}}");
                            return;
                        case "nostatus":
                            reply(ex, 200, n < 2 ? "{}" : "{\"task\":\"t1\",\"status\":\"SUCCESS\"}");
                            return;
                        default:
                            reply(ex, 200, "{\"task\":\"t1\",\"status\":{\"status\":\"SUCCESS\"}}");
                            return;
                    }
                }
                if ("error".equals(sqlMode)) {
                    reply(ex, 500, "{\"errorMessage\":\"down\"}");
                    return;
                }
                if (body.contains("INFORMATION_SCHEMA.COLUMNS")) {
                    if (body.contains("'missing'")) {
                        reply(ex, 200, "[]");
                    } else if (body.contains("'odd'")) {
                        reply(ex, 200, "[\"notamap\"]".replace("\"notamap\"", "{\"name\":\"id\"}"));
                    } else {
                        reply(ex, 200, "[{\"name\":\"id\"},{\"name\":\"txt\"},{\"name\":\"emb\"}]");
                    }
                    return;
                }
                if (body.contains("_embeddings")) {
                    reply(ex, 200, "present".equals(embedded) ? "[{\"id\":1},{\"id\":2.0}]" : "[]");
                    return;
                }
                reply(ex, 200, "[{\"id\":1,\"text\":\"a\"},{\"id\":2,\"text\":\"b\"},{\"id\":3,\"text\":\"\"},"
                        + "{\"id\":4,\"text\":null},{\"id\":5,\"text\":\"e\"},{\"id\":6,\"text\":\"f\"}]");
            } catch (java.io.IOException e) {
                ex.close();
            }
        });
        druid.start();

        fake = new FakeDaemon(Files.createTempDirectory("fsql-write"));
        props = new Properties();
        props.setProperty("druid.server.http.port", Integer.toString(druid.getAddress().getPort()));
        props.setProperty("druid.node.type", "broker");
        props.setProperty("druid.fractalsql.daemon_socket", fake.socket.toString());
        props.setProperty("druid.fractalsql.daemon_hmac_key_file", fake.keyFile.toString());
        props.setProperty("druid.fractalsql.daemon_timeout_ms", "5000");
        build();
    }

    private void build()
    {
        final FractalSqlConfig config = new FractalSqlConfig(() -> props);
        final ReasoningBridge bridge = new ReasoningBridge(new FractalSqlDaemon(config));
        service = new FractalSqlService(config, bridge, () -> props);
        vectorizer = new FractalSqlVectorizer(service, bridge);
    }

    @AfterEach
    void stop() throws Exception
    {
        druid.stop(0);
        fake.close();
    }

    // -- the write ----------------------------------------------------------------------------------

    @Test
    void aWriteIsSubmittedAndPolledToItsEnd() throws Exception
    {
        assertEquals("t1", service.submitWrite("INSERT INTO x SELECT 1", null));
        assertEquals("t1", service.submitWrite("INSERT INTO x SELECT 1", "   "));
        assertEquals("t1", service.submitWrite("INSERT INTO x SELECT 1", "{\"a\":1}"));

        status = "running";
        polls.set(0);
        assertEquals("t1", service.submitWrite("INSERT INTO x SELECT 1", null));
        assertTrue(polls.get() >= 2, "a running task is polled again");

        status = "nostatus";
        polls.set(0);
        assertEquals("t1", service.submitWrite("INSERT INTO x SELECT 1", null));
    }

    @Test
    void aWriteThatFailsOrIsNotAccepted()
    {
        status = "failed";
        assertTrue(assertThrows(IllegalStateException.class, () -> service.submitWrite("q", null)).getMessage().contains("boom"));
        status = "canceled";
        assertTrue(assertThrows(IllegalStateException.class, () -> service.submitWrite("q", null)).getMessage().contains("the write failed"));
        submit = "noid";
        assertTrue(assertThrows(IllegalStateException.class, () -> service.submitWrite("q", null)).getMessage().contains("not accepted"));
        submit = "null";
        assertThrows(IllegalStateException.class, () -> service.submitWrite("q", null));
        submit = "error";
        assertThrows(Exception.class, () -> service.submitWrite("q", null));
    }

    @Test
    void theStatusIsReadFromTheCoordinatorWhenOneIsNamed() throws Exception
    {
        props.setProperty("druid.fractalsql.coordinator_url", "http://127.0.0.1:" + druid.getAddress().getPort() + "///");
        build();
        assertEquals("t1", service.submitWrite("q", null));
    }

    // -- the vectorizer ---------------------------------------------------------------------------------

    @Test
    void creatingAndManagingVectorizers()
    {
        assertThrows(IllegalArgumentException.class, () -> vectorizer.create("bad name", "txt", "emb", "id", null));
        assertThrows(IllegalArgumentException.class, () -> vectorizer.create("src", null, "emb", "id", null));
        assertThrows(IllegalArgumentException.class, () -> vectorizer.create("src", "txt", "emb;", "id", null));
        assertTrue(assertThrows(IllegalArgumentException.class, () -> vectorizer.create("missing", "txt", "emb", "id", null))
                .getMessage().contains("does not exist"));
        assertTrue(assertThrows(IllegalArgumentException.class, () -> vectorizer.create("src", "nope", "emb", "id", null))
                .getMessage().contains("does not exist in table"));
        assertTrue(assertThrows(IllegalArgumentException.class, () -> vectorizer.create("src", "txt", "emb", "nope", null))
                .getMessage().contains("nope"));
        assertThrows(IllegalArgumentException.class,
                () -> vectorizer.create("src", "txt", "emb", "id", Map.of("embeddings_table", "bad name")));
        assertTrue(assertThrows(IllegalArgumentException.class,
                () -> vectorizer.create("src", "txt", "emb", "id", Map.of("max_embeds_per_window", -1)))
                .getMessage().contains("negative"));
        assertTrue(assertThrows(IllegalArgumentException.class,
                () -> vectorizer.create("src", "txt", "emb", "id", Map.of("rate_window_secs", "ten")))
                .getMessage().contains("whole number"));

        final Map<String, Object> made = vectorizer.create("src", "txt", "emb", "id", Map.of("rate_window_secs", " 5 "));
        assertEquals("src_embeddings", made.get("embeddings_table"));
        final int id = (Integer) made.get("id");
        assertTrue(assertThrows(IllegalArgumentException.class, () -> vectorizer.create("src", "txt", "emb", "id", null))
                .getMessage().contains("already exists"));
        final Map<String, Object> named = vectorizer.create("src", "txt", "emb2", "id",
                Map.of("embeddings_table", "my_vecs", "max_embeds_per_window", 2L));
        assertEquals("my_vecs", named.get("embeddings_table"));
        assertEquals(2, vectorizer.list().size());

        assertTrue(vectorizer.pause(id));
        assertTrue(vectorizer.pause(id));
        assertTrue(vectorizer.resume(id));
        assertThrows(IllegalArgumentException.class, () -> vectorizer.pause(999));
        assertThrows(IllegalArgumentException.class, () -> vectorizer.resume(999));
        assertTrue(vectorizer.drop((Integer) named.get("id")));
        assertFalse(vectorizer.drop(999));
        assertEquals(1, vectorizer.list().size());
    }

    @Test
    void columnsThatCannotBeRead()
    {
        sqlMode = "error";
        assertTrue(assertThrows(IllegalArgumentException.class, () -> vectorizer.create("src", "txt", "emb", "id", null))
                .getMessage().contains("could not be read"));
    }

    @Test
    void statusCountsWhatIsDoneAndWhatIsPending() throws Exception
    {
        final int id = (Integer) vectorizer.create("src", "txt", "emb", "id", null).get("id");
        Map<String, Object> st = vectorizer.status(id);
        assertEquals(0, st.get("done"));
        assertEquals(5L, st.get("pending"));          // rows 1, 2, 3, 5, 6 have text; row 4 has none
        assertEquals(null, st.get("last_failure_at"));

        embedded = "present";
        st = vectorizer.status(id);
        assertEquals(2, st.get("done"));
        assertThrows(IllegalArgumentException.class, () -> vectorizer.status(999));
    }

    @Test
    void processingTheQueue() throws Exception
    {
        final int id = (Integer) vectorizer.create("src", "txt", "emb", "id", null).get("id");

        // nothing to do while paused
        vectorizer.pause(id);
        assertEquals(0, vectorizer.processQueue(0).get("embedded"));
        vectorizer.resume(id);

        // a batch of two, the daemon answers
        Map<String, Object> out = vectorizer.processQueue(2);
        assertEquals(2, out.get("embedded"));
        assertEquals(List.of("src_embeddings"), out.get("written"));
        assertEquals(1, submissions.get());

        // rows this node has written count as done; the default batch takes the rest (empty and NULL text are skipped)
        out = vectorizer.processQueue(0);
        assertEquals(2, out.get("embedded"));

        // an embedding that fails is counted and left pending
        final int flaky = (Integer) vectorizer.create("src", "txt", "emb3", "id", Map.of("embeddings_table", "flaky_embeddings")).get("id");
        fake.fail = true;
        out = vectorizer.processQueue(3);
        assertTrue((Integer) out.get("failed") > 0);
        fake.fail = false;
        final Map<String, Object> st = vectorizer.status(flaky);
        assertNotNull(st.get("last_error"));
        assertNotNull(st.get("last_failure_at"));
        assertTrue((Long) st.get("failed") > 0);
    }

    @Test
    void theRateCapThrottles() throws Exception
    {
        vectorizer.create("src", "txt", "emb", "id", Map.of("max_embeds_per_window", 1, "rate_window_secs", 60));
        final Map<String, Object> out = vectorizer.processQueue(5);
        assertEquals(1, out.get("embedded"));
        assertEquals(1, out.get("throttled"));
        // still inside the window: nothing more is admitted
        assertEquals(0, vectorizer.processQueue(5).get("embedded"));
    }

    @Test
    void aWriteThatFailsFailsTheRun() throws Exception
    {
        vectorizer.create("src", "txt", "emb", "id", null);
        status = "failed";
        assertThrows(IllegalStateException.class, () -> vectorizer.processQueue(2));
    }

    @Test
    void anEmbeddingsTableThatCannotBeRead() throws Exception
    {
        final int id = (Integer) vectorizer.create("src", "txt", "emb", "id", null).get("id");
        assertEquals(5L, vectorizer.status(id).get("pending"));
    }
}
