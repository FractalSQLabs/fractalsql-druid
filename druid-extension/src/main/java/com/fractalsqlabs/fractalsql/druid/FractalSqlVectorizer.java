/*
 * SPDX-License-Identifier: Apache-2.0
 * Copyright 2026 Daniel Gardiner d/b/a FractalSQLabs
 */
package com.fractalsqlabs.fractalsql.druid;

import com.google.inject.Inject;
import com.google.inject.Singleton;

import java.util.ArrayList;
import java.util.HashSet;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.Set;
import java.util.concurrent.atomic.AtomicInteger;
import java.util.regex.Pattern;

/**
 * The vectorizer tier.
 *
 * <p>A vectorizer watches a datasource's text column and keeps an embedding for
 * each row in a companion datasource. Druid has no triggers and no TEMP tables,
 * and its segments are immutable, so the sync is pull-based: {@code process_queue}
 * finds the rows that have no embedding yet, embeds a batch of them, and appends
 * the embeddings to the companion datasource with an MSQ {@code INSERT}.
 *
 * <p>The registry lives in the extension, per node: a vectorizer outlives a
 * query, not a node restart. Rate capping, failure tracking and status are kept
 * with it.
 */
@Singleton
public class FractalSqlVectorizer {

    private static final Pattern IDENTIFIER = Pattern.compile("[A-Za-z_][A-Za-z0-9_]*");
    private static final int DEFAULT_BATCH = 100;
    private static final long DEFAULT_WINDOW_SECS = 3600;

    /** One registered vectorizer. */
    public static final class Entry {
        final int id;
        final String sourceTable;
        final String sourceColumn;
        final String embeddingColumn;
        final String idColumn;
        final String embeddingsTable;
        final long maxEmbedsPerWindow;
        final long rateWindowSecs;
        boolean paused;
        long windowStartMs;
        long windowAttempts;
        long done;
        final Set<String> written = new HashSet<>();
        long failed;
        String lastError;
        long lastFailureMs;

        Entry(int id, String sourceTable, String sourceColumn, String embeddingColumn, String idColumn,
                String embeddingsTable, long maxEmbedsPerWindow, long rateWindowSecs)
        {
            this.id = id;
            this.sourceTable = sourceTable;
            this.sourceColumn = sourceColumn;
            this.embeddingColumn = embeddingColumn;
            this.idColumn = idColumn;
            this.embeddingsTable = embeddingsTable;
            this.maxEmbedsPerWindow = maxEmbedsPerWindow;
            this.rateWindowSecs = rateWindowSecs;
        }
    }

    private final FractalSqlService service;
    private final ReasoningBridge reasoning;
    private final Map<Integer, Entry> registry = new LinkedHashMap<>();
    private final AtomicInteger nextId = new AtomicInteger(1);

    @Inject
    public FractalSqlVectorizer(FractalSqlService service, ReasoningBridge reasoning)
    {
        this.service = service;
        this.reasoning = reasoning;
    }

    private static String identifier(String value, String what)
    {
        if (value == null || !IDENTIFIER.matcher(value).matches()) {
            throw new IllegalArgumentException(
                    "fractalsql: " + what + " must be an identifier (letters, digits and underscores)");
        }
        return value;
    }

    /** Refuses a column that is not in the source datasource, instead of failing later in process_queue. */
    private void requireColumns(String table, String... columns)
    {
        final Set<String> have = new HashSet<>();
        try {
            final Object cols = service.schemaContext(table).get("columns");
            if (cols instanceof List) {
                for (Object one : (List<?>) cols) {
                    if (one instanceof Map) {
                        have.add(String.valueOf(((Map<?, ?>) one).get("name")));
                    }
                }
            }
        } catch (Exception e) {
            throw new IllegalArgumentException("fractal_vectorizer_create: table \"" + table
                    + "\" could not be read: " + e.getMessage());
        }
        if (have.isEmpty()) {
            throw new IllegalArgumentException("fractal_vectorizer_create: table \"" + table + "\" does not exist");
        }
        for (String column : columns) {
            if (!have.contains(column)) {
                throw new IllegalArgumentException("fractal_vectorizer_create: column \"" + column
                        + "\" does not exist in table \"" + table + "\"");
            }
        }
    }

    private static long longOption(Map<String, Object> options, String key, long fallback)
    {
        final Object v = options == null ? null : options.get(key);
        if (v == null) {
            return fallback;
        }
        try {
            final long n = v instanceof Number ? ((Number) v).longValue() : Long.parseLong(v.toString().trim());
            if (n < 0) {
                throw new IllegalArgumentException("fractalsql: " + key + " must not be negative");
            }
            return n;
        } catch (NumberFormatException e) {
            throw new IllegalArgumentException("fractalsql: " + key + " must be a whole number");
        }
    }

    /**
     * Register a vectorizer.
     *
     * @param sourceTable the datasource whose text column is embedded
     * @param sourceColumn the text column
     * @param embeddingColumn the column the embeddings are stored in
     * @param idColumn the column naming each row; required, it is how an embedding finds its row
     * @param options {@code max_embeds_per_window}, {@code rate_window_secs} and
     *                {@code embeddings_table} (default {@code <source>_embeddings}); may be null
     */
    public synchronized Map<String, Object> create(
            String sourceTable, String sourceColumn, String embeddingColumn, String idColumn,
            Map<String, Object> options)
    {
        identifier(sourceTable, "source_table");
        identifier(sourceColumn, "source_column");
        identifier(embeddingColumn, "embedding_column");
        identifier(idColumn, "id_column");
        requireColumns(sourceTable, sourceColumn, idColumn);
        final Object named = options == null ? null : options.get("embeddings_table");
        final String target = named == null ? sourceTable + "_embeddings" : identifier(named.toString(), "embeddings_table");
        for (Entry e : registry.values()) {
            if (e.sourceTable.equals(sourceTable) && e.sourceColumn.equals(sourceColumn)
                    && e.embeddingColumn.equals(embeddingColumn)) {
                throw new IllegalArgumentException("fractalsql: a vectorizer for " + sourceTable + "."
                        + sourceColumn + " -> " + embeddingColumn + " already exists (id " + e.id + ")");
            }
        }
        final Entry entry = new Entry(nextId.getAndIncrement(), sourceTable, sourceColumn, embeddingColumn,
                idColumn, target, longOption(options, "max_embeds_per_window", 0),
                Math.max(1, longOption(options, "rate_window_secs", DEFAULT_WINDOW_SECS)));
        registry.put(entry.id, entry);
        return describe(entry);
    }

    /** Forget a vectorizer. */
    public synchronized boolean drop(int id)
    {
        return registry.remove(id) != null;
    }

    private synchronized Entry require(int id)
    {
        final Entry entry = registry.get(id);
        if (entry == null) {
            throw new IllegalArgumentException("fractalsql: no vectorizer with id " + id);
        }
        return entry;
    }

    /** Stop a vectorizer without forgetting it. Idempotent. */
    public synchronized boolean pause(int id)
    {
        require(id).paused = true;
        return true;
    }

    /** Start a vectorizer again. Idempotent. */
    public synchronized boolean resume(int id)
    {
        require(id).paused = false;
        return true;
    }

    /** The registered vectorizers. */
    public synchronized List<Map<String, Object>> list()
    {
        final List<Map<String, Object>> out = new ArrayList<>();
        for (Entry entry : registry.values()) {
            out.add(describe(entry));
        }
        return out;
    }

    /** The ids that already have an embedding. A companion datasource that does not exist yet holds none. */
    private Set<String> embeddedIds(Entry entry)
    {
        final Set<String> out = new HashSet<>();
        try {
            for (Map<String, Object> row : service.query(
                    "SELECT \"id\" FROM \"" + entry.embeddingsTable + "\"")) {
                out.add(idKey(row.get("id")));
            }
        } catch (Exception e) {
            // The companion datasource has not been written yet.
        }
        // Rows this node has written may not be ingested yet; they still count as done.
        synchronized (this) {
            out.addAll(entry.written);
        }
        return out;
    }

    /** A row id as a stable key: 1 and 1.0 are the same row. */
    private static String idKey(Object id)
    {
        if (id instanceof Number) {
            final double d = ((Number) id).doubleValue();
            if (d == Math.rint(d) && Math.abs(d) < 9.0e15) {
                return Long.toString((long) d);
            }
        }
        return String.valueOf(id);
    }

    /** One vectorizer's progress: embedded, failed and still pending rows. */
    public Map<String, Object> status(int id) throws Exception
    {
        final Entry entry = require(id);
        final Set<String> have = embeddedIds(entry);
        long pending = 0;
        for (Map<String, Object> row : service.textRows(entry.sourceTable, entry.sourceColumn, entry.idColumn)) {
            if (row.get("text") != null && !have.contains(idKey(row.get("id")))) {
                pending++;
            }
        }
        final Map<String, Object> out = describe(entry);
        synchronized (this) {
            out.put("done", have.size());
            out.put("failed", entry.failed);
            out.put("pending", pending);
            out.put("last_error", entry.lastError);
            out.put("last_failure_at", entry.lastFailureMs == 0 ? null : java.time.Instant.ofEpochMilli(entry.lastFailureMs).toString());
        }
        return out;
    }

    /** Whether the vectorizer may make another embedding call in its current rate window. */
    private static boolean admit(Entry entry, long now)
    {
        if (entry.maxEmbedsPerWindow <= 0) {
            return true;
        }
        if (now - entry.windowStartMs >= entry.rateWindowSecs * 1000L) {
            entry.windowStartMs = now;
            entry.windowAttempts = 0;
        }
        if (entry.windowAttempts >= entry.maxEmbedsPerWindow) {
            return false;
        }
        // The cap holds attempts, not just successes.
        entry.windowAttempts++;
        return true;
    }

    /**
     * Embed the rows that have no embedding yet, up to a batch, and append them to the companion datasource.
     *
     * <p>The embedding is stored in the core's text form (a bracketed JSON array), the interchange format
     * every vector function reads. A row whose embedding fails is counted and left pending for the next run.
     *
     * @param batchSize at most this many rows per vectorizer per call
     */
    public Map<String, Object> processQueue(int batchSize) throws Exception
    {
        final int batch = batchSize <= 0 ? DEFAULT_BATCH : batchSize;
        final List<Map<String, Object>> rows = new ArrayList<>();
        final Map<String, List<Map<String, Object>>> byTarget = new LinkedHashMap<>();
        int embedded = 0;
        int failed = 0;
        int throttled = 0;
        final List<Entry> entries;
        synchronized (this) {
            entries = new ArrayList<>(registry.values());
        }
        for (Entry entry : entries) {
            if (entry.paused) {
                continue;
            }
            final Set<String> have = embeddedIds(entry);
            int taken = 0;
            for (Map<String, Object> row : service.textRows(entry.sourceTable, entry.sourceColumn, entry.idColumn)) {
                if (taken >= batch) {
                    break;
                }
                final Object text = row.get("text");
                if (text == null || text.toString().isEmpty() || have.contains(idKey(row.get("id")))) {
                    continue;
                }
                boolean allowed;
                synchronized (this) {
                    allowed = admit(entry, System.currentTimeMillis());
                }
                if (!allowed) {
                    throttled++;
                    break;
                }
                taken++;
                final String vector = reasoning.embed(text.toString());
                if (vector == null) {
                    synchronized (this) {
                        entry.failed++;
                        entry.lastError = "the embedding call failed";
                        entry.lastFailureMs = System.currentTimeMillis();
                    }
                    failed++;
                    continue;
                }
                synchronized (this) {
                    entry.done++;
                    entry.written.add(idKey(row.get("id")));
                }
                final Map<String, Object> out = new LinkedHashMap<>();
                out.put("vectorizer_id", entry.id);
                out.put("id", row.get("id"));
                out.put("embedding", vector);
                rows.add(out);
                byTarget.computeIfAbsent(entry.embeddingsTable + "\u0000" + entry.embeddingColumn,
                        k -> new ArrayList<>()).add(out);
                embedded++;
            }
        }
        final Map<String, Object> doc = new LinkedHashMap<>();
        doc.put("embedded", embedded);
        doc.put("failed", failed);
        doc.put("throttled", throttled);
        doc.put("rows", rows);
        final List<String> written = new ArrayList<>();
        for (Map.Entry<String, List<Map<String, Object>>> group : byTarget.entrySet()) {
            final String[] key = group.getKey().split("\u0000");
            final List<String> documents = new ArrayList<>();
            for (Map<String, Object> row : group.getValue()) {
                documents.add(jsonDocument(row));
            }
            final String sql = "INSERT INTO \"" + key[0] + "\" SELECT CURRENT_TIMESTAMP AS \"__time\", "
                    + "CAST(FRACTAL_JSON_VALUE(t.j, '$.id') AS BIGINT) AS \"id\", "
                    + "FRACTAL_JSON_VALUE(t.j, '$.embedding') AS \"" + key[1] + "\" FROM UNNEST(ARRAY["
                    + String.join(", ", documents) + "]) AS t(j) PARTITIONED BY ALL";
            service.submitWrite(sql, null);
            written.add(key[0]);
        }
        doc.put("written", written);
        return doc;
    }

    /**
     * A row, as the JSON document the write carries.
     *
     * <p>The document is a SQL string literal: Druid's parser has no array-of-objects literal, so the
     * columns are projected out of the string with FRACTAL_JSON_VALUE.
     */
    private static String jsonDocument(Map<String, Object> row)
    {
        final StringBuilder sb = new StringBuilder("{");
        sb.append("\"id\":").append(String.valueOf(row.get("id")));
        sb.append(",\"embedding\":\"").append(String.valueOf(row.get("embedding")).replace("\\", "\\\\")).append("\"");
        sb.append("}");
        return "'" + sb.toString().replace("'", "''") + "'";
    }

    /** A vectorizer, as a document. */
    private static Map<String, Object> describe(Entry entry)
    {
        final Map<String, Object> out = new LinkedHashMap<>();
        out.put("id", entry.id);
        out.put("source_table", entry.sourceTable);
        out.put("source_column", entry.sourceColumn);
        out.put("embedding_column", entry.embeddingColumn);
        out.put("id_column", entry.idColumn);
        out.put("embeddings_table", entry.embeddingsTable);
        out.put("paused", entry.paused);
        out.put("max_embeds_per_window", entry.maxEmbedsPerWindow);
        out.put("rate_window_secs", entry.rateWindowSecs);
        return out;
    }
}
