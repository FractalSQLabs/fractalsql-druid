/*
 * SPDX-License-Identifier: Apache-2.0
 * Copyright 2026 Daniel Gardiner d/b/a FractalSQLabs
 */
package com.fractalsqlabs.fractalsql.druid;

import com.fasterxml.jackson.databind.JsonNode;
import com.fasterxml.jackson.databind.ObjectMapper;
import com.google.inject.Inject;
import com.google.inject.Singleton;

/**
 * The reasoning tier: the model provider, reached through fractalsqld.
 *
 * <p>Reasoning runs through four independent contexts in the daemon. Each has
 * its own response mode, because the mode is a property of what a call is for:
 *
 * <table>
 *   <caption>The four contexts</caption>
 *   <tr><th>Context</th><th>Response mode</th><th>Used for</th></tr>
 *   <tr><td>chat</td><td>text by default; the operator may choose code or json</td>
 *       <td>{@link #reason}</td></tr>
 *   <tr><td>text-to-SQL</td><td>code, fixed</td><td>{@link #reasonForStatement}</td></tr>
 *   <tr><td>review</td><td>text, fixed</td><td>{@link #review}</td></tr>
 *   <tr><td>embed</td><td>embedding, fixed</td><td>{@link #embed}</td></tr>
 * </table>
 *
 * <p>The chat mode is set where the daemon starts, through
 * {@code FSQL_REASONING_HTTP_RESPONSE_MODE}. The provider, its credentials and
 * the models are the daemon's configuration, not this node's.
 */
@Singleton
public class ReasoningBridge {

    /** The dialect tag the text-to-SQL context is given. */
    static final String SQL_DIALECT = "Apache Druid SQL";

    private static final ObjectMapper MAPPER = new ObjectMapper();

    private final FractalSqlDaemon daemon;

    @Inject
    public ReasoningBridge(FractalSqlDaemon daemon)
    {
        this.daemon = daemon;
    }

    /**
     * Ask the model a question, in the chat context.
     *
     * @param contextJson the context, as JSON; may be null
     * @return the answer, or null if the daemon is unreachable or the call failed
     */
    public String reason(String query, String contextJson)
    {
        return reason(null, query, contextJson);
    }

    /** As {@link #reason(String, String)}, in a named session. */
    public String reason(String session, String query, String contextJson)
    {
        if (query == null || query.isEmpty()) {
            return null;
        }
        final long id = FractalSqlDaemon.sessionId(session);
        return contextJson == null || contextJson.isEmpty()
                ? daemon.textOrNull("fractal_reason", id, query)
                : daemon.textOrNull("fractal_reason", id, query, contextJson);
    }

    /**
     * Ask the model for a statement, in the text-to-SQL context.
     *
     * <p>The context's mode is code, so the answer is the statement itself,
     * not prose with a statement inside it.
     *
     * @return the statement, or null if the call failed or the answer was not a single block
     */
    public String reasonForStatement(String query, String contextText)
    {
        return reasonForStatement(null, query, contextText);
    }

    /** As {@link #reasonForStatement(String, String)}, in a named session. */
    public String reasonForStatement(String session, String query, String contextText)
    {
        if (query == null || query.isEmpty()) {
            return null;
        }
        return daemon.textOrNull("fractal_t2s_generate", FractalSqlDaemon.sessionId(session), query,
                contextText == null ? "" : contextText, SQL_DIALECT);
    }

    /**
     * Ask the model to judge a candidate, in the review context.
     *
     * @return {@code PASS} when the candidate is accepted, otherwise the model's critique, which begins
     *         with {@code FAIL}; null if the call failed
     */
    public String review(String question, String candidateSql)
    {
        return review(null, question, candidateSql);
    }

    /** As {@link #review(String, String)}, in a named session. */
    public String review(String session, String question, String candidateSql)
    {
        try {
            final FsqClient.Result r = daemon.client().call("fractal_t2s_review",
                    FractalSqlDaemon.sessionId(session), question, candidateSql);
            return r.isNull() ? "PASS" : r.text();
        } catch (FsqClient.FsqException e) {
            return null;
        }
    }

    /**
     * Embed a piece of text, in the embedding context.
     *
     * @return the embedding as a JSON array, or null
     */
    public String embed(String text)
    {
        if (text == null || text.isEmpty()) {
            return null;
        }
        return daemon.textOrNull("fractal_embed", FractalSqlDaemon.NODE_SESSION, text);
    }

    /** Whether the daemon is reachable. */
    public boolean isConfigured()
    {
        return daemon.available();
    }

    // -- the text-to-SQL settings, which the daemon owns ----------------------

    private JsonNode t2sConfig(String session)
    {
        final String json = daemon.textOrNull("fractal_t2s_config", FractalSqlDaemon.sessionId(session));
        if (json == null) {
            return null;
        }
        try {
            return MAPPER.readTree(json);
        } catch (java.io.IOException e) {
            return null;
        }
    }

    /** The statements text-to-SQL may produce: {@code select} unless the operator widened it. */
    public String t2sAllowedStatements(String session)
    {
        final JsonNode c = t2sConfig(session);
        return c == null ? "select" : c.path("allowed_statements").asText("select");
    }

    /** Whether the review pass runs after a statement is generated. */
    public boolean t2sUseReview(String session)
    {
        final JsonNode c = t2sConfig(session);
        return c != null && c.path("use_review").asBoolean(false);
    }

    /** How many times a generated statement is attempted. */
    public int t2sMaxAttempts(String session)
    {
        final JsonNode c = t2sConfig(session);
        return c == null ? 2 : c.path("max_attempts").asInt(2);
    }
}
