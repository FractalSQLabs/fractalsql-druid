/*
 * SPDX-License-Identifier: Apache-2.0
 * Copyright 2026 Daniel Gardiner d/b/a FractalSQLabs
 */
package com.fractalsqlabs.fractalsql.druid;

import com.google.inject.Inject;
import com.google.inject.Singleton;

import java.util.ArrayList;
import java.util.Arrays;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.regex.Pattern;

/**
 * The index tier: the native IVF index, and the datasource that holds it.
 *
 * <p>The index MATHS lives in the daemon (the core's IVF entry points); this
 * class owns the DATA, which is where Druid's architecture differs from the
 * other hosts:
 *
 * <ul>
 *   <li>Druid has no DDL and no DML: a Druid SQL query is read-only, and a
 *       value reaches a datasource through an MSQ INSERT task. So the
 *       index's CELLS live in a COMPANION DATASOURCE, written with an MSQ
 *       INSERT -- the same precedent the vectorizer's companion datasource
 *       sets.</li>
 *   <li>Druid has no cheap fetch by id: filtering on a BIGINT id scans
 *       segments. So the payload the rerank needs -- the row's vector -- is
 *       stored INSIDE the index, as an FP16 copy, next to the codes. The
 *       distances the search returns are therefore exact to FP16 precision,
 *       not FP32. (docs/api-discovery.md says so.)</li>
 * </ul>
 *
 * <p>The daemon is database-free, so every step that touches Druid happens
 * here: read the source rows, train, encode, write the cells, and -- at
 * query time -- probe the cells, read THOSE cells back, hand them to the
 * daemon and take the verified candidates.
 *
 * <p>One caveat, and it is the same one the service tier carries: reading a
 * datasource is a loopback query to this node's own SQL endpoint, so the
 * index's operations belong to the SERVICE tier (the extension's
 * /fractalsql/index endpoint), not inside a running query.
 */
@Singleton
public class FractalSqlIndex {

    private static final Pattern IDENTIFIER = Pattern.compile("[A-Za-z_][A-Za-z0-9_]*");

    /** The one message every index operation reports when the core has no IVF index. */
    public static final String NO_IVF =
            "fractalsql: this build of fractalsql-core does not carry the IVF index "
                    + "(rebuild the core and refresh include/<platform>)";

    /** The rows one training or encoding batch carries. */
    private static final int BATCH = 500;

    /** The format the index uses when the caller does not name one. */
    private static final String DEFAULT_FORMAT = "INT8";

    /** One registered index. */
    public static final class Entry {
        final String name;
        final String sourceTable;
        final String sourceColumn;
        final String idColumn;
        final String indexTable;
        final String idKind;
        final long generation;
        long createdAt;
        long rows;
        long maxId = -1;          /* the highest row id the cells cover (the watermark: later ids are the delta) */
        String model = "";
        /** what the metadata row stores for the model: the blob, or "chunked:N" when the parts were written (null until the first write) */
        String modelStored;
        /** the model (or its parts) is already in the datasource for this generation */
        boolean modelWritten;
        int dim;
        String format = DEFAULT_FORMAT;
        int nlist;
        int codeBytes;
        String state = "building";
        /* the last search of this index (fractal_index_info reports it): whether the index was used, and how much it read */
        /* the build's calibration: an ESTIMATE of the recall from a sample of the rows (JSON text; null when the index was not calibrated) */
        String calib;
        int nprobeDefault = 8;
        Boolean reachesTarget;
        boolean lastSet;
        boolean lastUsed;
        long lastScanned;
        long lastProbed;

        Entry(String name, String sourceTable, String sourceColumn, String idColumn,
              String indexTable, String idKind, long generation)
        {
            this.name = name;
            this.sourceTable = sourceTable;
            this.sourceColumn = sourceColumn;
            this.idColumn = idColumn;
            this.indexTable = indexTable;
            this.idKind = idKind;
            this.generation = generation;
            this.createdAt = System.currentTimeMillis();
        }

        /** The index, as a document. */
        Map<String, Object> describe()
        {
            final Map<String, Object> out = new LinkedHashMap<>();
            out.put("name", name);
            out.put("source_table", sourceTable);
            out.put("source_column", sourceColumn);
            out.put("id_column", idColumn);
            out.put("index_table", indexTable);
            out.put("id_kind", idKind);
            out.put("generation", generation);
            out.put("rows", rows);
            out.put("dim", dim);
            out.put("format", format);
            out.put("nlist", nlist);
            out.put("code_bytes", codeBytes);
            out.put("state", state);
            out.put("created_at", createdAt);
            out.put("nprobe_default", nprobeDefault);
            return out;
        }
    }

    private final FractalSqlService service;
    private final FractalSqlDaemon daemon;
    private final Map<String, Entry> registry = new LinkedHashMap<>();

    @Inject
    public FractalSqlIndex(FractalSqlService service, FractalSqlDaemon daemon)
    {
        this.service = service;
        this.daemon = daemon;
    }

    // ------------------------------------------------------------------
    // The registry is rebuilt from the datasources
    // ------------------------------------------------------------------

    /** The datasource that lists the indexes: one row per create, rebuild and drop (the latest row for a name wins). */
    static final String CATALOG = "fractalsql_index_catalog";

    /** How often a node re-reads the catalog, so an index made, rebuilt or dropped on another node shows up here. */
    static final long SYNC_MS = 15000L;

    /** The shortest wait before a name that is not known is looked for again. */
    private static final long MISS_MS = 2000L;

    /** Long enough for Druid to publish a catalog row this node just wrote; until then the catalog may still show the older state. */
    private static final long LOCAL_WINS_MS = 180000L;

    private long lastSync;

    /** The names this node created, rebuilt or dropped lately, and when: for those the node's own view wins over the catalog. */
    private final Map<String, Long> touched = new java.util.HashMap<>();

    /** Appends a row to the catalog: this index, its companion datasource and its state (active or dropped). */
    private void writeCatalog(Entry entry, String state) throws Exception
    {
        final Map<String, Object> doc = new LinkedHashMap<>();
        doc.put("index_name", entry.name);
        doc.put("index_table", entry.indexTable);
        doc.put("state", state);
        final String sql = "INSERT INTO \"" + CATALOG + "\" SELECT CURRENT_TIMESTAMP AS \"__time\", "
                + "FRACTAL_JSON_TEXT(t.j, '$.index_name') AS \"index_name\", "
                + "FRACTAL_JSON_TEXT(t.j, '$.index_table') AS \"index_table\", "
                + "FRACTAL_JSON_TEXT(t.j, '$.state') AS \"state\" "
                + "FROM UNNEST(ARRAY[" + jsonDocument(doc, null, 0) + "]) AS t(j) PARTITIONED BY ALL";
        service.submitWrite(sql, null);
    }

    /**
     * Brings the registry up to date with the datasources when it is time to (every SYNC_MS), or when {@code wanted} is a name this node
     * does not know (at most every MISS_MS). A failure to read the catalog (none written yet, the cluster busy) leaves the registry as it is.
     */
    private void sync(String wanted)
    {
        final long now = System.currentTimeMillis();
        final boolean due = now - lastSync >= SYNC_MS;
        final boolean miss = wanted != null && !registry.containsKey(wanted) && now - lastSync >= MISS_MS;
        if (!due && !miss) {
            return;
        }
        lastSync = now;
        try {
            load();
        } catch (Exception e) {
            // no catalog yet, or Druid could not answer: keep what this node has
        }
    }

    /** Reads the catalog and each active index's latest metadata row; adds, replaces and removes registry entries to match. */
    private void load() throws Exception
    {
        final Map<String, Map<String, Object>> latest = new LinkedHashMap<>();
        for (Map<String, Object> row : service.query("SELECT \"index_name\", \"index_table\", \"state\" FROM \"" + CATALOG
                + "\" ORDER BY \"__time\"")) {
            latest.put(String.valueOf(row.get("index_name")), row);   // oldest first: the last row for a name wins
        }
        for (Map.Entry<String, Map<String, Object>> e : latest.entrySet()) {
            final String name = e.getKey();
            final Long mine = touched.get(name);
            if (mine != null && System.currentTimeMillis() - mine < LOCAL_WINS_MS) {
                continue;
            }
            final String indexTable = String.valueOf(e.getValue().get("index_table"));
            if ("dropped".equals(String.valueOf(e.getValue().get("state")))) {
                registry.remove(name);
                continue;
            }
            try {
                final Entry loaded = readEntry(name, indexTable);
                final Entry have = registry.get(name);
                if (loaded == null) {
                    continue;                                          // the metadata is not visible yet: look again next time
                }
                if ("dropped".equals(loaded.state)) {
                    registry.remove(name);
                } else if (have == null || have.generation != loaded.generation || have.rows != loaded.rows || have.maxId != loaded.maxId) {
                    registry.put(name, loaded);
                }
            } catch (Exception ex) {
                // this index could not be read now; the others still load
            }
        }
    }

    /** The index's latest metadata row as an entry (null when no row is visible yet: a datasource that was just written takes a moment). */
    private Entry readEntry(String name, String indexTable) throws Exception
    {
        final String qn = name.replace("'", "''");
        final String q = "SELECT \"generation\", \"model\", \"dim\", \"format\", \"nlist\", \"code_bytes\", \"rows_count\", \"state\", "
                + "\"source_table\", \"source_column\", \"id_column\", \"id_kind\", \"created_at\", \"payload\" FROM \"" + indexTable.replace("\"", "\"\"")
                + "\" WHERE \"kind\" = 'meta' AND \"index_name\" = '" + qn + "' ORDER BY \"__time\" DESC LIMIT 1";
        List<Map<String, Object>> rows = service.query(q);
        for (int attempt = 0; rows.isEmpty() && attempt < 3; attempt++) {
            Thread.sleep(500L);
            rows = service.query(q);
        }
        if (rows.isEmpty()) {
            return null;
        }
        final Map<String, Object> m = rows.get(0);
        final String idColumn = m.get("id_column") == null ? "" : String.valueOf(m.get("id_column"));
        final Entry entry = new Entry(name, String.valueOf(m.get("source_table")), String.valueOf(m.get("source_column")), idColumn, indexTable,
                String.valueOf(m.get("id_kind")), (long) number(m.get("generation"), 1));
        entry.model = m.get("model") == null ? "" : String.valueOf(m.get("model"));
        if (entry.model.startsWith(MODEL_CHUNKED)) {
            final String whole = readModelParts(name, indexTable, (long) number(m.get("generation"), 1),
                    Integer.parseInt(entry.model.substring(MODEL_CHUNKED.length())));
            if (whole == null) {
                return null;                                      // the model's parts are not all visible yet: look again next time
            }
            entry.model = whole;
        }
        entry.modelWritten = true;
        entry.modelStored = m.get("model") == null ? "" : String.valueOf(m.get("model"));
        entry.dim = (int) number(m.get("dim"), 0);
        entry.format = String.valueOf(m.get("format"));
        entry.nlist = (int) number(m.get("nlist"), 0);
        entry.codeBytes = (int) number(m.get("code_bytes"), 0);
        entry.rows = (long) number(m.get("rows_count"), 0);
        entry.state = String.valueOf(m.get("state"));
        entry.createdAt = (long) number(m.get("created_at"), entry.createdAt);
        applyCalibration(entry, m.get("payload") == null ? null : String.valueOf(m.get("payload")));
        final List<Map<String, Object>> mx = service.query("SELECT MAX(CAST(\"row_id\" AS BIGINT)) AS \"m\" FROM \"" + indexTable.replace("\"", "\"\"")
                + "\" WHERE \"kind\" = 'cell' AND \"index_name\" = '" + qn + "' AND \"generation\" = " + entry.generation);
        if (!mx.isEmpty() && mx.get(0).get("m") != null) {
            entry.maxId = (long) number(mx.get(0).get("m"), -1);
        }
        return entry;
    }

    // ------------------------------------------------------------------
    // The daemon plumbing: one JSON request, one JSON response
    // ------------------------------------------------------------------

    /**
     * One call to the daemon's index maths.
     *
     * @return the response document
     * @throws IllegalStateException when the operation failed; the message is
     *         the daemon's own, so the "no IVF index" case reaches the user
     *         verbatim
     */
    private Map<String, Object> op(String request)
    {
        final String text;
        try {
            text = daemon.client().call("fractal_index_op", request).text();
        } catch (FsqClient.FsqException e) {
            final String message = e.getMessage() == null ? "" : e.getMessage();
            throw new IllegalStateException(
                    message.isEmpty() ? "the daemon refused the index operation" : message);
        }
        if (text == null || text.isEmpty()) {
            throw new IllegalStateException("the daemon returned nothing for the index operation");
        }
        final com.fasterxml.jackson.databind.JsonNode node;
        try {
            node = service.mapper().readTree(text);
        } catch (com.fasterxml.jackson.core.JsonProcessingException e) {
            throw new IllegalStateException("the daemon returned a document that is not JSON: " + text);
        }
        final Map<String, Object> out = new LinkedHashMap<>();
        final java.util.Iterator<String> names = node.fieldNames();
        while (names.hasNext()) {
            final String key = names.next();
            final com.fasterxml.jackson.databind.JsonNode value = node.get(key);
            out.put(key, value.isNumber() ? value.numberValue()
                    : value.isBoolean() ? (Object) value.booleanValue()
                    : value.isContainerNode() ? service.mapper().convertValue(value, Object.class) : value.asText());
        }
        final Object error = out.get("error");
        if (error != null) {
            throw new IllegalStateException(String.valueOf(error));
        }
        return out;
    }

    // ------------------------------------------------------------------
    // Options
    // ------------------------------------------------------------------

    private static Map<String, Object> options(String json)
    {
        final Map<String, Object> out = new LinkedHashMap<>();
        if (json == null || json.trim().isEmpty()) {
            return out;
        }
        try {
            final com.fasterxml.jackson.databind.JsonNode node =
                    new com.fasterxml.jackson.databind.ObjectMapper().readTree(json);
            final java.util.Iterator<String> names = node.fieldNames();
            while (names.hasNext()) {
                final String key = names.next();
                final com.fasterxml.jackson.databind.JsonNode value = node.get(key);
                out.put(key, value.isNumber() ? value.numberValue()
                        : value.isBoolean() ? (Object) value.booleanValue()
                        : value.isArray() ? value.toString() : value.asText());
            }
        } catch (com.fasterxml.jackson.core.JsonProcessingException | RuntimeException e) {
            throw new IllegalArgumentException("fractalsql: the options are not a JSON object: " + e.getMessage());
        }
        return out;
    }

    private static String optionString(Map<String, Object> options, String key, String dflt)
    {
        final Object v = options.get(key);
        if (v == null) {
            return dflt;
        }
        final String s = String.valueOf(v);
        return s.isEmpty() ? dflt : s;
    }

    private static int optionInt(Map<String, Object> options, String key, int dflt)
    {
        final Object v = options.get(key);
        if (v == null) {
            return dflt;
        }
        if (v instanceof Number) {
            return ((Number) v).intValue();
        }
        try {
            return Integer.parseInt(String.valueOf(v));
        } catch (NumberFormatException e) {
            return dflt;
        }
    }

    private static String identifier(String value, String what)
    {
        if (value == null || !IDENTIFIER.matcher(value).matches()) {
            throw new IllegalArgumentException(
                    "fractalsql: " + what + " must be an identifier (letters, digits and underscores)");
        }
        return value;
    }

    // ------------------------------------------------------------------
    // The vectors
    // ------------------------------------------------------------------

    /** The canonical vector text: the float32 values, printed so they round-trip. */
    private static String vectorText(double[] v)
    {
        final StringBuilder sb = new StringBuilder();
        for (int i = 0; i < v.length; i++) {
            if (i > 0) {
                sb.append(',');
            }
            sb.append(String.format(java.util.Locale.ROOT, "%.9g", (float) v[i]));
        }
        return sb.toString();
    }

    /**
     * The FP16 copy of a vector -- the rerank payload, stored inside the
     * index because Druid has no cheap fetch by id.
     *
     * <p>The conversion is IEEE 754 binary16 with round-to-nearest-even, the
     * same conversion the daemon widens back, so the distance the daemon
     * computes is the distance of exactly these values.
     */
    static byte[] toFp16(double[] v)
    {
        final byte[] out = new byte[v.length * 2];
        for (int i = 0; i < v.length; i++) {
            final short h = f32ToF16((float) v[i]);
            out[2 * i] = (byte) (h & 0xFF);
            out[2 * i + 1] = (byte) ((h >>> 8) & 0xFF);
        }
        return out;
    }

    private static short f32ToF16(float value)
    {
        final int x = Float.floatToRawIntBits(value);
        final int sign = (x >>> 16) & 0x8000;
        final int exponent = (x >>> 23) & 0xFF;
        int mantissa = x & 0x7FFFFF;
        if (exponent == 0xFF) {                       // infinity or NaN
            return (short) (sign | 0x7C00 | (mantissa != 0 ? 0x0200 : 0));
        }
        int e = exponent - 127 + 15;                  // the binary16 exponent
        if (e >= 0x1F) {                              // overflow
            return (short) (sign | 0x7C00);
        }
        if (e <= 0) {                                 // subnormal (or zero)
            if (e < -10) {
                return (short) sign;
            }
            mantissa |= 0x800000;
            final int shift = 14 - e;
            int half = mantissa >>> shift;
            final int remainder = mantissa & ((1 << shift) - 1);
            final int halfway = 1 << (shift - 1);
            if (remainder > halfway || (remainder == halfway && (half & 1) != 0)) {
                half++;
            }
            return (short) (sign | half);
        }
        int half = (e << 10) | (mantissa >>> 13);
        final int remainder = mantissa & 0x1FFF;
        if (remainder > 0x1000 || (remainder == 0x1000 && (half & 1) != 0)) {
            half++;
        }
        return (short) (sign | half);
    }

    // ------------------------------------------------------------------
    // The datasource
    // ------------------------------------------------------------------

    /** The source rows: the row's id and its vector. */
    private static final class Row {
        final long id;
        final double[] vector;

        Row(long id, double[] vector)
        {
            this.id = id;
            this.vector = vector;
        }
    }

    private List<Row> sourceRows(String table, String idColumn, String vectorColumn) throws Exception
    {
        final StringBuilder sql = new StringBuilder("SELECT ");
        if (idColumn != null && !idColumn.isEmpty()) {
            sql.append('"').append(idColumn.replace("\"", "\"\"")).append("\" AS \"__id\", ");
        }
        sql.append('"').append(vectorColumn.replace("\"", "\"\"")).append("\" AS \"__vec\" FROM \"")
                .append(table.replace("\"", "\"\"")).append('"');
        final List<Map<String, Object>> rows = service.query(sql.toString());
        final List<Row> out = new ArrayList<>();
        int position = 0;
        for (Map<String, Object> row : rows) {
            final Object raw = row.get("__vec");
            if (raw == null) {
                position++;
                continue;
            }
            final double[] vector = VectorText.parseVector(raw.toString());
            if (vector == null || vector.length == 0) {
                position++;
                continue;
            }
            long id = position;
            if (idColumn != null && !idColumn.isEmpty()) {
                final Object rawId = row.get("__id");
                if (rawId != null) {
                    try {
                        id = Long.parseLong(rawId.toString().trim());
                    } catch (NumberFormatException e) {
                        // Druid returns a numeric column ingested as double as "1.0": a whole number is the id
                        try {
                            final double d = Double.parseDouble(rawId.toString().trim());
                            id = d == Math.rint(d) ? (long) d : position;
                        } catch (NumberFormatException e2) {
                            id = position;
                        }
                    }
                }
            }
            out.add(new Row(id, vector));
            position++;
        }
        return out;
    }

    /** The cells of the index, as they are written: the cell, the row id, the codes and the payload. */
    private static final class CellRow {
        final int cell;
        final long rowId;
        final String codes;
        final String payload;

        CellRow(int cell, long rowId, String codes, String payload)
        {
            this.cell = cell;
            this.rowId = rowId;
            this.codes = codes;
            this.payload = payload;
        }
    }

    /**
     * Writes the index's cells into the companion datasource, with an MSQ
     * INSERT -- the same shape the vectorizer's companion datasource uses.
     */
    private void writeCells(String indexTable, String name, long generation, List<CellRow> rows)
            throws Exception
    {
        if (rows.isEmpty()) {
            return;
        }
        final List<String> documents = new ArrayList<>();
        for (CellRow row : rows) {
            documents.add(jsonDocument(row, name, generation));
        }
        final String sql = "INSERT INTO \"" + indexTable + "\" SELECT CURRENT_TIMESTAMP AS \"__time\", "
                + "FRACTAL_JSON_TEXT(t.j, '$.kind') AS \"kind\", "
                + "FRACTAL_JSON_TEXT(t.j, '$.index_name') AS \"index_name\", "
                + "CAST(FRACTAL_JSON_VALUE(t.j, '$.generation') AS BIGINT) AS \"generation\", "
                + "CAST(FRACTAL_JSON_VALUE(t.j, '$.cell') AS BIGINT) AS \"cell\", "
                + "FRACTAL_JSON_TEXT(t.j, '$.row_id') AS \"row_id\", "
                + "FRACTAL_JSON_TEXT(t.j, '$.codes') AS \"codes\", "
                + "FRACTAL_JSON_TEXT(t.j, '$.payload') AS \"payload\", "
                + "CAST(NULL AS VARCHAR) AS \"model\", "
                + "CAST(NULL AS BIGINT) AS \"dim\", "
                + "CAST(NULL AS VARCHAR) AS \"format\", "
                + "CAST(NULL AS BIGINT) AS \"nlist\", "
                + "CAST(NULL AS BIGINT) AS \"code_bytes\", "
                + "CAST(NULL AS BIGINT) AS \"rows_count\", "
                + "CAST(NULL AS VARCHAR) AS \"state\", "
                + "CAST(NULL AS VARCHAR) AS \"source_table\", "
                + "CAST(NULL AS VARCHAR) AS \"source_column\", "
                + "CAST(NULL AS VARCHAR) AS \"id_column\", "
                + "CAST(NULL AS VARCHAR) AS \"id_kind\", "
                + "CAST(NULL AS BIGINT) AS \"created_at\" "
                + "FROM UNNEST(ARRAY[" + String.join(", ", documents) + "]) AS t(j) PARTITIONED BY ALL";
        service.submitWrite(sql, null);
    }

    /**
     * A model blob larger than this many hex characters is stored as several "model" rows, and the metadata row carries "chunked:N".
     * A Druid MSQ write cannot carry a row over 1,000,000 bytes, and the model of a wide vector (a PCA basis for 768 dimensions) is
     * over a megabyte as hex.
     */
    static final int MODEL_CHUNK = 400000;
    static final String MODEL_CHUNKED = "chunked:";

    /** The model's parts, in order, joined; null when fewer than {@code parts} distinct parts are visible. */
    private String readModelParts(String name, String indexTable, long generation, int parts) throws Exception
    {
        final String q = "SELECT \"cell\", \"model\" FROM \"" + indexTable.replace("\"", "\"\"") + "\" WHERE \"kind\" = 'model' AND \"index_name\" = '"
                + name.replace("'", "''") + "' AND \"generation\" = " + generation;   // no ORDER BY: Druid cannot order a table scan by a non-time column; the parts are sorted below
        List<Map<String, Object>> rows = service.query(q);
        for (int attempt = 0; attempt < 3 && distinctParts(rows) < parts; attempt++) {
            Thread.sleep(500L);
            rows = service.query(q);
        }
        final Map<Integer, String> byPart = new java.util.TreeMap<>();
        for (Map<String, Object> row : rows) {
            byPart.putIfAbsent((int) number(row.get("cell"), -1), String.valueOf(row.get("model")));
        }
        if (byPart.size() < parts) {
            return null;
        }
        final StringBuilder sb = new StringBuilder();
        for (int i = 0; i < parts; i++) {
            final String piece = byPart.get(i);
            if (piece == null) {
                return null;
            }
            sb.append(piece);
        }
        return sb.toString();
    }

    private static int distinctParts(List<Map<String, Object>> rows)
    {
        final java.util.Set<Integer> seen = new java.util.HashSet<>();
        for (Map<String, Object> row : rows) {
            seen.add((int) number(row.get("cell"), -1));
        }
        return seen.size();
    }

    /** Writes the model as parts when it is too large for one row. Returns the value the metadata row stores in "model". */
    private String writeModelParts(Entry entry) throws Exception
    {
        if (entry.model.length() <= MODEL_CHUNK) {
            return entry.model;
        }
        final int parts = (entry.model.length() + MODEL_CHUNK - 1) / MODEL_CHUNK;
        final List<String> docs = new ArrayList<>();
        for (int i = 0; i < parts; i++) {
            final Map<String, Object> d = new LinkedHashMap<>();
            d.put("kind", "model");
            d.put("index_name", entry.name);
            d.put("generation", entry.generation);
            d.put("cell", i);
            d.put("model", entry.model.substring(i * MODEL_CHUNK, Math.min(entry.model.length(), (i + 1) * MODEL_CHUNK)));
            docs.add(jsonDocument(d, null, 0));
        }
        // one write per part: a single ARRAY literal of every part would itself be one row over the limit
        for (String d : docs) {
            service.submitWrite(modelPartSql(entry, d), null);
        }
        return MODEL_CHUNKED + parts;
    }

    private static String modelPartSql(Entry entry, String doc)
    {
        return "INSERT INTO \"" + entry.indexTable + "\" SELECT CURRENT_TIMESTAMP AS \"__time\", "
                + "FRACTAL_JSON_TEXT(t.j, '$.kind') AS \"kind\", "
                + "FRACTAL_JSON_TEXT(t.j, '$.index_name') AS \"index_name\", "
                + "CAST(FRACTAL_JSON_VALUE(t.j, '$.generation') AS BIGINT) AS \"generation\", "
                + "CAST(FRACTAL_JSON_VALUE(t.j, '$.cell') AS BIGINT) AS \"cell\", "
                + "CAST(NULL AS VARCHAR) AS \"row_id\", "
                + "CAST(NULL AS VARCHAR) AS \"codes\", "
                + "CAST(NULL AS VARCHAR) AS \"payload\", "
                + "FRACTAL_JSON_TEXT(t.j, '$.model') AS \"model\", "
                + "CAST(NULL AS BIGINT) AS \"dim\", "
                + "CAST(NULL AS VARCHAR) AS \"format\", "
                + "CAST(NULL AS BIGINT) AS \"nlist\", "
                + "CAST(NULL AS BIGINT) AS \"code_bytes\", "
                + "CAST(NULL AS BIGINT) AS \"rows_count\", "
                + "CAST(NULL AS VARCHAR) AS \"state\", "
                + "CAST(NULL AS VARCHAR) AS \"source_table\", "
                + "CAST(NULL AS VARCHAR) AS \"source_column\", "
                + "CAST(NULL AS VARCHAR) AS \"id_column\", "
                + "CAST(NULL AS VARCHAR) AS \"id_kind\", "
                + "CAST(NULL AS BIGINT) AS \"created_at\" "
                + "FROM UNNEST(ARRAY[" + doc + "]) AS t(j) PARTITIONED BY ALL";
    }

    /** Writes the index's metadata row: the model blob and the index's shape. */
    private void writeMeta(Entry entry) throws Exception
    {
        final Map<String, Object> doc = new LinkedHashMap<>();
        doc.put("kind", "meta");
        doc.put("index_name", entry.name);
        doc.put("generation", entry.generation);
        // a model over MODEL_CHUNK hex characters is written as parts, once per generation (a refresh or a drop rewrites only this row)
        if (!entry.modelWritten) {
            entry.modelStored = writeModelParts(entry);
            entry.modelWritten = true;
        }
        doc.put("model", entry.modelStored != null ? entry.modelStored : entry.model);
        doc.put("dim", entry.dim);
        doc.put("format", entry.format);
        doc.put("nlist", entry.nlist);
        doc.put("code_bytes", entry.codeBytes);
        doc.put("rows_count", entry.rows);
        doc.put("state", entry.state);
        doc.put("source_table", entry.sourceTable);
        doc.put("source_column", entry.sourceColumn);
        doc.put("id_column", entry.idColumn);
        doc.put("id_kind", entry.idKind);
        doc.put("created_at", entry.createdAt);
        // hex: the document travels inside a quoted SQL string and a JSON string, so raw JSON text (quotes) would break it
        doc.put("calib", entry.calib == null ? "" : hex(entry.calib.getBytes(java.nio.charset.StandardCharsets.UTF_8)));
        final String sql = "INSERT INTO \"" + entry.indexTable + "\" SELECT CURRENT_TIMESTAMP AS \"__time\", "
                + "FRACTAL_JSON_TEXT(t.j, '$.kind') AS \"kind\", "
                + "FRACTAL_JSON_TEXT(t.j, '$.index_name') AS \"index_name\", "
                + "CAST(FRACTAL_JSON_VALUE(t.j, '$.generation') AS BIGINT) AS \"generation\", "
                + "CAST(NULL AS BIGINT) AS \"cell\", "
                + "CAST(NULL AS VARCHAR) AS \"row_id\", "
                + "CAST(NULL AS VARCHAR) AS \"codes\", "
                + "FRACTAL_JSON_TEXT(t.j, '$.calib') AS \"payload\", "
                + "FRACTAL_JSON_TEXT(t.j, '$.model') AS \"model\", "
                + "CAST(FRACTAL_JSON_VALUE(t.j, '$.dim') AS BIGINT) AS \"dim\", "
                + "FRACTAL_JSON_TEXT(t.j, '$.format') AS \"format\", "
                + "CAST(FRACTAL_JSON_VALUE(t.j, '$.nlist') AS BIGINT) AS \"nlist\", "
                + "CAST(FRACTAL_JSON_VALUE(t.j, '$.code_bytes') AS BIGINT) AS \"code_bytes\", "
                + "CAST(FRACTAL_JSON_VALUE(t.j, '$.rows_count') AS BIGINT) AS \"rows_count\", "
                + "FRACTAL_JSON_TEXT(t.j, '$.state') AS \"state\", "
                + "FRACTAL_JSON_TEXT(t.j, '$.source_table') AS \"source_table\", "
                + "FRACTAL_JSON_TEXT(t.j, '$.source_column') AS \"source_column\", "
                + "FRACTAL_JSON_TEXT(t.j, '$.id_column') AS \"id_column\", "
                + "FRACTAL_JSON_TEXT(t.j, '$.id_kind') AS \"id_kind\", "
                + "CAST(FRACTAL_JSON_VALUE(t.j, '$.created_at') AS BIGINT) AS \"created_at\" "
                + "FROM UNNEST(ARRAY[" + jsonDocument(doc, null, 0) + "]) AS t(j) PARTITIONED BY ALL";
        service.submitWrite(sql, null);
    }

    /** A row, as the JSON document the write carries. */
    private static String jsonDocument(Object row, String indexName, long generation)
    {
        final StringBuilder sb = new StringBuilder("{");
        if (row instanceof CellRow) {
            final CellRow cell = (CellRow) row;
            sb.append("\"kind\":\"cell\"");
            sb.append(",\"index_name\":\"").append(indexName).append('"');
            sb.append(",\"generation\":").append(generation);
            sb.append(",\"cell\":").append(cell.cell);
            sb.append(",\"row_id\":\"").append(cell.rowId).append('"');
            sb.append(",\"codes\":\"").append(cell.codes).append('"');
            sb.append(",\"payload\":\"").append(cell.payload).append('"');
        } else {
            final java.util.Iterator<Map.Entry<String, Object>> it =
                    ((Map<String, Object>) row).entrySet().iterator();
            boolean first = true;
            while (it.hasNext()) {
                final Map.Entry<String, Object> e = it.next();
                if (!first) {
                    sb.append(',');
                }
                first = false;
                sb.append('"').append(e.getKey()).append("\":");
                final Object v = e.getValue();
                if (v instanceof Number || v instanceof Boolean) {
                    sb.append(String.valueOf(v));
                } else {
                    sb.append('"').append(String.valueOf(v).replace("\\", "\\\\")).append('"');
                }
            }
        }
        sb.append('}');
        return "'" + sb.toString().replace("'", "''") + "'";
    }

    /** The index's cells, read back from the companion datasource. */
    private List<Map<String, Object>> readCells(Entry entry, List<Integer> cells) throws Exception
    {
        if (cells.isEmpty()) {
            return new ArrayList<>();
        }
        final StringBuilder in = new StringBuilder();
        for (Integer cell : cells) {
            if (in.length() > 0) {
                in.append(',');
            }
            in.append(cell);
        }
        final String sql = "SELECT \"cell\", \"row_id\", \"codes\", \"payload\" FROM \""
                + entry.indexTable.replace("\"", "\"\"") + "\" WHERE \"kind\" = 'cell' "
                + "AND \"index_name\" = '" + entry.name.replace("'", "''") + "' "
                + "AND \"generation\" = " + entry.generation + " "
                + "AND \"cell\" IN (" + in + ")";
        // a datasource that was built into more than once (Druid cannot rewrite one) can hold a row twice: one entry per (cell, row)
        final Map<String, Map<String, Object>> distinct = new LinkedHashMap<>();
        for (Map<String, Object> row : service.query(sql)) {
            distinct.putIfAbsent(row.get("cell") + "/" + row.get("row_id"), row);
        }
        return new ArrayList<>(distinct.values());
    }

    // ------------------------------------------------------------------
    // The operations
    // ------------------------------------------------------------------

    /**
     * Builds an index over a datasource's vector column.
     *
     * <p>Two passes over the rows: a sample pass that trains the model, then
     * an encode pass that assigns each row to a cell. The cells are written
     * into the companion datasource with an MSQ INSERT.
     */
    public synchronized Map<String, Object> create(String table, String column, String optionsJson)
            throws Exception
    {
        final Map<String, Object> opts = options(optionsJson);
        identifier(table, "the table");
        identifier(column, "the vector column");
        final String name = optionString(opts, "name", table + "_" + column + "_index");
        identifier(name, "the index name");
        final String idColumn = optionString(opts, "id_col", "");
        final String indexTable = optionString(opts, "index_table", name + "_cells");
        identifier(indexTable, "the index datasource");
        final String format = optionString(opts, "vector_format", DEFAULT_FORMAT).toUpperCase(java.util.Locale.ROOT);
        final int nlist = optionInt(opts, "nlist", 0);
        final int pcaDim = optionInt(opts, "pca_dim", 0);
        final int iters = optionInt(opts, "iters", 0);
        final int sample = optionInt(opts, "sample", 0);
        final int seed = optionInt(opts, "seed", 1);

        // a rebuild (see rebuild()) names the generation it writes: the old cells stay in the datasource, ignored from then on
        final long generation = Math.max(1L, (long) number(opts.get("_generation"), 1));
        sync(name);
        if (generation == 1L && registry.containsKey(name)) {
            throw new IllegalStateException(
                    "fractalsql: an index named '" + name + "' already exists; rebuild it or drop it");
        }

        final List<Row> rows = sourceRows(table, idColumn, column);
        if (rows.isEmpty()) {
            throw new IllegalStateException("fractalsql: the datasource holds no rows with a vector");
        }
        final int dim = rows.get(0).vector.length;

        final Entry entry = new Entry(name, table, column, idColumn, indexTable,
                idColumn.isEmpty() ? "position" : "column", generation);

        // ---- pass one: train
        final Map<String, Object> begin = op("{\"op\":\"train_begin\",\"format\":\"" + format
                + "\",\"dim\":" + dim + ",\"nlist\":" + nlist + ",\"pca_dim\":" + pcaDim
                + ",\"iters\":" + iters + ",\"sample\":" + sample + ",\"seed\":" + seed + "}");
        final String trainer = String.valueOf(begin.get("token"));
        for (int i = 0; i < rows.size(); i += BATCH) {
            final List<Row> batch = rows.subList(i, Math.min(i + BATCH, rows.size()));
            op("{\"op\":\"train_add\",\"token\":\"" + trainer + "\",\"corpus\":"
                    + jsonString(corpusText(batch)) + "}");
        }
        final Map<String, Object> trained = op("{\"op\":\"train_end\",\"token\":\"" + trainer + "\"}");
        final String model = String.valueOf(trained.get("model"));
        final String modelToken = String.valueOf(trained.get("token"));
        entry.model = model;
        entry.dim = (int) number(trained.get("dim"), dim);
        entry.format = String.valueOf(trained.get("format"));
        entry.nlist = (int) number(trained.get("nlist"), 0);
        entry.codeBytes = (int) number(trained.get("code_bytes"), 0);
        entry.rows = rows.size();
        for (Row r : rows) {
            entry.maxId = Math.max(entry.maxId, r.id);
        }

        // ---- pass two: encode, and write the cells
        final List<CellRow> cells = new ArrayList<>();
        for (int i = 0; i < rows.size(); i += BATCH) {
            final List<Row> batch = rows.subList(i, Math.min(i + BATCH, rows.size()));
            final Map<String, Object> encoded = op("{\"op\":\"encode\",\"token\":\"" + modelToken
                    + "\",\"corpus\":" + jsonString(corpusText(batch)) + "}");
            final List<?> cellList = (List<?>) encoded.get("cells");
            final List<?> codeList = (List<?>) encoded.get("codes");
            if (cellList == null || codeList == null || cellList.size() != batch.size()) {
                throw new IllegalStateException("fractalsql: the encode pass did not answer for every row");
            }
            for (int r = 0; r < batch.size(); r++) {
                final Row row = batch.get(r);
                cells.add(new CellRow((int) number(cellList.get(r), 0), row.id,
                        String.valueOf(codeList.get(r)), hex(toFp16(row.vector))));
            }
            writeCells(indexTable, name, entry.generation, cells.subList(cells.size() - batch.size(), cells.size()));
        }

        calibrate(entry, rows, modelToken, optionInt(opts, "calibration_samples", 200),
                number(opts.get("target_recall"), 0.95), seed);

        entry.state = "ready";
        writeMeta(entry);
        writeCatalog(entry, "active");
        registry.put(name, entry);
        touched.put(name, System.currentTimeMillis());

        final Map<String, Object> out = new LinkedHashMap<>();
        out.put("index", name);
        out.put("index_table", indexTable);
        out.put("rows", entry.rows);
        out.put("dim", entry.dim);
        out.put("format", entry.format);
        out.put("nlist", entry.nlist);
        out.put("code_bytes", entry.codeBytes);
        out.put("id_kind", entry.idKind);
        out.put("state", entry.state);
        out.put("nprobe_default", entry.nprobeDefault);
        out.put("calibration", calibrationDoc(entry));
        return out;
    }

    private static final int CALIB_MIN_ROWS = 12;
    private static final int CALIB_MAX_ROWS = 5000;

    /**
     * The build's calibration: an ESTIMATE of the recall from a sample of the rows (the daemon builds a temporary index over the sample
     * with the trained model and measures each sample row against the exact top-k of the sample). It chooses the smallest nprobe that
     * reaches the target and is stored with the index. A failure leaves the index uncalibrated; it does not fail the build.
     */
    private void calibrate(Entry entry, List<Row> rows, String modelToken, int samples, double target, int seed)
    {
        if (samples <= 0 || target <= 0 || rows.size() < CALIB_MIN_ROWS) {
            return;
        }
        try {
            final List<Row> pool = new ArrayList<>(rows);
            java.util.Collections.shuffle(pool, new java.util.Random(seed));
            final List<Row> sample = pool.subList(0, Math.min(CALIB_MAX_ROWS, pool.size()));
            final Map<String, Object> res = op("{\"op\":\"calibrate\",\"token\":\"" + modelToken + "\",\"corpus\":"
                    + jsonString(corpusText(sample)) + ",\"samples\":" + Math.min(2000, samples) + ",\"target\":" + target
                    + ",\"seed\":" + seed + "}");
            if (res.get("recommended_nprobe") == null) {
                return;
            }
            applyCalibration(entry, service.mapper().writeValueAsString(res));
        } catch (Exception e) {
            // uncalibrated: auto will scan exactly
        }
    }

    /** Reads a stored calibration (JSON text) into the entry. */
    private void applyCalibration(Entry entry, String json)
    {
        entry.calib = null;
        entry.reachesTarget = null;
        entry.nprobeDefault = 8;
        if (json == null || json.isEmpty() || "null".equals(json)) {
            return;
        }
        try {
            if (!json.startsWith("{")) {                      // stored as hex (see writeMeta)
                final byte[] raw = new byte[json.length() / 2];
                for (int i = 0; i < raw.length; i++) {
                    raw[i] = (byte) Integer.parseInt(json.substring(2 * i, 2 * i + 2), 16);
                }
                json = new String(raw, java.nio.charset.StandardCharsets.UTF_8);
            }
            final com.fasterxml.jackson.databind.JsonNode n = service.mapper().readTree(json);
            if (n == null || !n.has("recommended_nprobe")) {
                return;
            }
            entry.calib = json;
            entry.nprobeDefault = Math.max(1, n.get("recommended_nprobe").asInt(8));
            entry.reachesTarget = n.has("reaches_target") ? n.get("reaches_target").asBoolean(false) : null;
        } catch (Exception e) {
            // an unreadable calibration is no calibration
        }
    }

    /** The calibration as a document for fractal_index_info (a note when there is none). */
    private Object calibrationDoc(Entry entry)
    {
        if (entry.calib == null) {
            final Map<String, Object> none = new LinkedHashMap<>();
            none.put("skipped", "the index was built without a calibration; the default nprobe applies");
            return none;
        }
        try {
            return service.mapper().readValue(entry.calib, Object.class);
        } catch (Exception e) {
            return new LinkedHashMap<String, Object>();
        }
    }

    /** Rebuilds an index: the same build, over the source's rows as they are now. */
    public synchronized Map<String, Object> rebuild(String name, String optionsJson) throws Exception
    {
        sync(name);
        final Entry entry = registry.get(name);
        if (entry == null) {
            throw new IllegalStateException("fractalsql: no index named '" + name + "'");
        }
        final Map<String, Object> opts = options(optionsJson);
        opts.put("name", name);
        opts.put("id_col", entry.idColumn);
        opts.put("index_table", entry.indexTable);
        opts.put("_generation", entry.generation + 1);
        // a rebuild keeps the options the index was built with unless the caller gives new ones, so the index's format
        // does not change behind the caller's back
        opts.putIfAbsent("vector_format", entry.format);
        if (entry.nlist > 0) {
            opts.putIfAbsent("nlist", entry.nlist);
        }
        // the same name, the next generation: the new entry replaces the old one when the build succeeds
        return create(entry.sourceTable, entry.sourceColumn,
                new com.fasterxml.jackson.databind.ObjectMapper().writeValueAsString(opts));
    }

    /**
     * Drops an index.
     *
     * <p>Druid's datasources are immutable and there is no DELETE, so the
     * index's cells stay in the companion datasource; the index is dropped by
     * writing a metadata row that says so, and the cells are ignored from
     * then on. The operator replaces the datasource when they want the space
     * back.
     */
    public synchronized Map<String, Object> drop(String name) throws Exception
    {
        sync(name);
        final Entry entry = registry.get(name);
        if (entry == null) {
            throw new IllegalStateException("fractalsql: no index named '" + name + "'");
        }
        entry.state = "dropped";
        writeMeta(entry);
        writeCatalog(entry, "dropped");
        registry.remove(name);
        touched.put(name, System.currentTimeMillis());
        final Map<String, Object> out = new LinkedHashMap<>();
        out.put("index", name);
        out.put("state", "dropped");
        out.put("note", "the cells stay in the companion datasource; a Druid datasource cannot be rewritten");
        return out;
    }

    /** The most that may be added before a rebuild is advised over a refresh, and the most that may be deleted. */
    private static final double REFRESH_MAX_FRAC = 0.25;
    private static final double DELETED_MAX_FRAC = 0.20;

    /** What the source holds now, against what the index covers. */
    private static final class Health {
        long now = -1;
        long added;
        long deleted;
        boolean missing;
        String note;
        String status = "ready";
        final List<String> advice = new ArrayList<>();
    }

    private Health health(Entry entry)
    {
        final Health h = new Health();
        final double den = Math.max(1L, entry.rows);
        try {
            final List<Row> rows = sourceRows(entry.sourceTable, entry.idColumn, entry.sourceColumn);
            h.now = rows.size();
            for (Row r : rows) {
                if (r.id > entry.maxId) {
                    h.added++;
                }
            }
            h.deleted = Math.max(0L, entry.rows - (h.now - h.added));
        } catch (Exception e) {
            final String m = String.valueOf(e.getMessage()).toLowerCase(java.util.Locale.ROOT);
            h.missing = m.contains("not found") || m.contains("does not exist") || m.contains("unknown");
            h.note = "the source datasource could not be read: " + e.getMessage();
            h.status = h.missing ? "orphaned" : "unknown";
            if (h.missing) {
                h.advice.add("the datasource " + entry.sourceTable + " or its column no longer exists; "
                        + "fractal_index_drop removes the index");
            }
            return h;
        }
        if (h.now == 0) {
            h.status = "empty";
            h.advice.add("the datasource has no vectors; load rows and build the index again");
            return h;
        }
        if (h.added > 0 || h.deleted / den > DELETED_MAX_FRAC) {
            h.status = "stale";
        }
        if (h.added > 0 && h.added / den > REFRESH_MAX_FRAC) {
            h.advice.add(String.format("rebuild: %.0f%% of the rows (%d) were added since the build, more than the cells were trained for",
                    100.0 * h.added / den, h.added));
        } else if (h.added > 0) {
            h.advice.add(String.format("refresh: %d rows (%.0f%% of the index) were added since the build; fractal_index_refresh folds them in",
                    h.added, 100.0 * h.added / den));
        }
        if (h.deleted / den > DELETED_MAX_FRAC) {
            h.advice.add(String.format("rebuild: %d rows (%.0f%%) were deleted since the build; they are still held in the cells",
                    h.deleted, 100.0 * h.deleted / den));
        }
        return h;
    }

    /** What the index is: its shape, its freshness, a status and the advice that goes with it. */
    public synchronized Map<String, Object> info(String name) throws Exception
    {
        sync(name);
        final Entry entry = registry.get(name);
        if (entry == null) {
            throw new IllegalStateException("fractalsql: no index named '" + name + "'");
        }
        final Map<String, Object> out = new LinkedHashMap<>(entry.describe());
        final Health h = health(entry);
        out.put("source_rows", h.now < 0 ? null : h.now);
        out.put("stale", h.now < 0 || h.now != entry.rows || h.added > 0);
        out.put("delta_rows", h.added);
        out.put("rows_added_since_build", h.added);
        out.put("rows_deleted_since_build", h.deleted);
        if (Boolean.FALSE.equals(entry.reachesTarget) && "ready".equals(h.status)) {
            h.status = "degraded";
            h.advice.add("the build's calibration (an estimate from a sample) did not reach its target recall even at the best nprobe; "
                    + "rebuild with more cells or another vector_format");
        }
        out.put("calibration", calibrationDoc(entry));
        out.put("status", h.status);
        out.put("advice", h.advice);
        if (h.note != null) {
            out.put("note", h.note);
        }
        if (entry.lastSet) {
            final Map<String, Object> last = new LinkedHashMap<>();
            last.put("used_index", entry.lastUsed);
            last.put("rows_scanned", entry.lastScanned);
            last.put("cells_probed", entry.lastProbed);
            out.put("last_search", last);
        }
        return out;
    }

    /** The registered indexes, each with its status. */
    public synchronized List<Map<String, Object>> list()
    {
        sync(null);
        final List<Map<String, Object>> out = new ArrayList<>();
        for (Entry entry : registry.values()) {
            final Map<String, Object> d = new LinkedHashMap<>(entry.describe());
            final Health h = health(entry);
            d.put("rows_now", h.now < 0 ? null : h.now);
            d.put("stale", h.now < 0 || h.now != entry.rows || h.added > 0);
            d.put("status", h.status);
            out.add(d);
        }
        return out;
    }

    /**
     * Folds the rows added since the build (an id above the watermark) into the cells, without retraining: each is
     * encoded with the index's model and appended to the index's datasource as cell rows. The cells are one row per
     * indexed row, so the append is the whole refresh and the generation stays. A deleted row is dropped by the
     * verify step; a changed vector needs {@link #rebuild}.
     */
    public synchronized Map<String, Object> refresh(String name) throws Exception
    {
        sync(name);
        final Entry entry = registry.get(name);
        if (entry == null) {
            throw new IllegalStateException("fractalsql: no index named '" + name + "'");
        }
        final List<Row> delta = new ArrayList<>();
        for (Row r : sourceRows(entry.sourceTable, entry.idColumn, entry.sourceColumn)) {
            if (r.id > entry.maxId) {
                delta.add(r);
            }
        }
        final Map<String, Object> out = new LinkedHashMap<>();
        out.put("name", name);
        if (delta.isEmpty()) {
            out.put("added", 0);
            out.put("rows", entry.rows);
            out.put("generation", entry.generation);
            out.put("refreshed", false);
            return out;
        }
        final Map<String, Object> opened = op("{\"op\":\"open\",\"model\":\"" + entry.model + "\"}");
        final String token = String.valueOf(opened.get("token"));
        long maxId = entry.maxId;
        try {
            for (int i = 0; i < delta.size(); i += BATCH) {
                final List<Row> batch = delta.subList(i, Math.min(i + BATCH, delta.size()));
                final Map<String, Object> encoded = op("{\"op\":\"encode\",\"token\":\"" + token
                        + "\",\"corpus\":" + jsonString(corpusText(batch)) + "}");
                final List<?> cellList = (List<?>) encoded.get("cells");
                final List<?> codeList = (List<?>) encoded.get("codes");
                if (cellList == null || codeList == null || cellList.size() != batch.size()) {
                    throw new IllegalStateException("fractalsql: the encode pass did not answer for every row");
                }
                final List<CellRow> cells = new ArrayList<>();
                for (int r = 0; r < batch.size(); r++) {
                    final Row row = batch.get(r);
                    cells.add(new CellRow((int) number(cellList.get(r), 0), row.id,
                            String.valueOf(codeList.get(r)), hex(toFp16(row.vector))));
                    maxId = Math.max(maxId, row.id);
                }
                writeCells(entry.indexTable, entry.name, entry.generation, cells);
            }
        } finally {
            try {
                op("{\"op\":\"close\",\"token\":\"" + token + "\"}");
            } catch (RuntimeException e) {
                // closing must not mask the result
            }
        }
        entry.maxId = maxId;
        entry.rows += delta.size();
        writeMeta(entry);
        touched.put(entry.name, System.currentTimeMillis());
        out.put("added", delta.size());
        out.put("rows", entry.rows);
        out.put("generation", entry.generation);
        out.put("refreshed", true);
        return out;
    }

    /** An ids option: a JSON array of row ids (null when absent). */
    private static java.util.Set<Long> idSet(Map<String, Object> opts)
    {
        final Object raw = opts.get("ids");
        if (raw == null) {
            return null;
        }
        final java.util.Set<Long> out = new java.util.TreeSet<>();
        try {
            final com.fasterxml.jackson.databind.JsonNode node =
                    new com.fasterxml.jackson.databind.ObjectMapper().readTree(String.valueOf(raw));
            if (!node.isArray()) {
                throw new IllegalArgumentException("x");
            }
            for (com.fasterxml.jackson.databind.JsonNode n : node) {
                if (!n.isIntegralNumber()) {
                    throw new IllegalArgumentException("x");
                }
                out.add(n.longValue());
            }
        } catch (com.fasterxml.jackson.core.JsonProcessingException | RuntimeException e) {
            throw new IllegalArgumentException("fractalsql: ids must be a JSON array of integers");
        }
        return out;
    }

    /** Scores source rows against the query with the daemon's exact cosine, nearest first. */
    private List<Map<String, Object>> exactScore(List<Row> rows, double[] query, int k) throws Exception
    {
        final List<Map<String, Object>> hits = new ArrayList<>();
        for (int i = 0; i < rows.size(); i += BATCH) {
            final List<Row> batch = rows.subList(i, Math.min(i + BATCH, rows.size()));
            final StringBuilder ids = new StringBuilder();
            for (Row r : batch) {
                if (ids.length() > 0) {
                    ids.append(',');
                }
                ids.append(r.id);
            }
            final Map<String, Object> v = op("{\"op\":\"verify\",\"query\":" + jsonString(vectorText(query))
                    + ",\"ids\":\"" + ids + "\",\"corpus\":" + jsonString(corpusText(batch)) + "}");
            final List<?> dists = (List<?>) v.get("distances");
            for (int r = 0; dists != null && r < batch.size() && r < dists.size(); r++) {
                final Map<String, Object> hit = new LinkedHashMap<>();
                hit.put("doc_id", batch.get(r).id);
                hit.put("distance", ((Number) dists.get(r)).doubleValue());
                hits.add(hit);
            }
        }
        hits.sort((a, b) -> {
            final int c = Double.compare(((Number) a.get("distance")).doubleValue(), ((Number) b.get("distance")).doubleValue());
            return c != 0 ? c : Long.compare(((Number) a.get("doc_id")).longValue(), ((Number) b.get("doc_id")).longValue());
        });
        return hits.size() > k ? new ArrayList<>(hits.subList(0, k)) : hits;
    }

    /**
     * The indexed search.
     *
     * <p>Probe the cells, read THOSE cells back from the companion datasource,
     * hand them to the daemon, and take the verified candidates: every
     * distance is recomputed by the daemon from the FP16 payload the index
     * carries, so no unverified distance is ever returned.
     */
    public synchronized Map<String, Object> search(
            String table, String column, String query, int k, String optionsJson) throws Exception
    {
        final Map<String, Object> opts = options(optionsJson);
        final Entry entry = find(table, column, opts);
        final int nprobe = Math.max(1, optionInt(opts, "nprobe", entry.nprobeDefault));
        final int shortlist = Math.max(k, optionInt(opts, "rerank", Math.max(k, 30)));
        final double[] queryVector = VectorText.parseVector(query);
        if (queryVector == null || queryVector.length == 0) {
            throw new IllegalArgumentException("fractalsql: the query vector is empty or malformed");
        }
        if (queryVector.length != entry.dim) {
            throw new IllegalStateException("fractalsql: the query dimension " + queryVector.length
                    + " does not match the index dimension " + entry.dim);
        }

        // ids: restrict the search to a set of row ids. At most 4096 ids is an exact scan of just those rows.
        final java.util.Set<Long> ids = idSet(opts);
        if (ids != null && ids.size() <= IDS_EXACT_MAX) {
            return exactOverIds(entry, ids, queryVector, k);
        }

        final Map<String, Object> opened = op("{\"op\":\"open\",\"model\":\"" + entry.model + "\"}");
        final String token = String.valueOf(opened.get("token"));
        try {
            final Map<String, Object> probed = op("{\"op\":\"probe\",\"token\":\"" + token + "\",\"query\":"
                    + jsonString(vectorText(queryVector)) + ",\"nprobe\":" + nprobe + "}");
            final List<?> cellList = (List<?>) probed.get("cells");
            final List<Integer> cells = new ArrayList<>();
            if (cellList != null) {
                for (Object o : cellList) {
                    cells.add((int) number(o, 0));
                }
            }
            loadCells(entry, token, cells);

            final Map<String, Object> found = op("{\"op\":\"search\",\"token\":\"" + token + "\",\"query\":"
                    + jsonString(vectorText(queryVector)) + ",\"nprobe\":" + nprobe
                    + ",\"shortlist\":" + shortlist + "}");
            final List<?> candidates = (List<?>) found.get("candidates");
            final List<Map<String, Object>> hits = new ArrayList<>();
            if (candidates != null) {
                for (Object o : candidates) {
                    if (!(o instanceof Map)) {
                        continue;
                    }
                    final Map<?, ?> cand = (Map<?, ?>) o;
                    if (ids != null && !ids.contains(((Number) number2(cand.get("doc_id"))).longValue())) {
                        continue;
                    }
                    final Map<String, Object> hit = new LinkedHashMap<>();
                    hit.put("doc_id", cand.get("doc_id"));
                    hit.put("distance", cand.get("distance"));
                    hits.add(hit);
                }
            }
            // the rows added after the build are not in the cells: scan them exactly
            long scanned = (long) number(found.get("rows_scanned"), 0);
            final List<Row> delta = new ArrayList<>();
            for (Row r : sourceRows(entry.sourceTable, entry.idColumn, entry.sourceColumn)) {
                if (r.id > entry.maxId && (ids == null || ids.contains(r.id))) {
                    delta.add(r);
                }
            }
            if (!delta.isEmpty()) {
                hits.addAll(exactScore(delta, queryVector, k));
                scanned += delta.size();
                hits.sort((a, b) -> {
                    final int c = Double.compare(((Number) a.get("distance")).doubleValue(),
                            ((Number) b.get("distance")).doubleValue());
                    return c != 0 ? c : Long.compare(((Number) number2(a.get("doc_id"))).longValue(),
                            ((Number) number2(b.get("doc_id"))).longValue());
                });
            }
            while (hits.size() > k) {
                hits.remove(hits.size() - 1);
            }
            if (ids != null && hits.size() < Math.min(k, ids.size())) {
                // the index shortlist left too few rows of the set: scan the set exactly
                return exactOverIds(entry, ids, queryVector, k);
            }
            final Map<String, Object> out = new LinkedHashMap<>();
            out.put("index", entry.name);
            out.put("candidates", hits);
            out.put("rows_scanned", scanned);
            out.put("cells_probed", found.get("cells_probed"));
            out.put("verified", found.get("verified"));
            out.put("precision", found.get("precision"));
            out.put("indexed_rows", entry.rows);
            entry.lastSet = true; entry.lastUsed = true; entry.lastScanned = scanned;
            entry.lastProbed = (long) number(found.get("cells_probed"), 0);
            return out;
        } finally {
            try {
                op("{\"op\":\"close\",\"token\":\"" + token + "\"}");
            } catch (RuntimeException e) {
                // the index is dropped with the daemon's own state; a failure here must not mask the result
            }
        }
    }

    /** An ids set up to this size is scanned exactly. */
    private static final int IDS_EXACT_MAX = 4096;

    private static Object number2(Object o)
    {
        return o instanceof Number ? o : (Object) Long.valueOf(String.valueOf(o).trim());
    }

    /** The exact scan of just the rows in {@code ids}, nearest first. */
    private Map<String, Object> exactOverIds(Entry entry, java.util.Set<Long> ids, double[] query, int k) throws Exception
    {
        final List<Row> rows = new ArrayList<>();
        if (!ids.isEmpty()) {
            for (Row r : sourceRows(entry.sourceTable, entry.idColumn, entry.sourceColumn)) {
                if (ids.contains(r.id)) {
                    rows.add(r);
                }
            }
        }
        final Map<String, Object> out = new LinkedHashMap<>();
        out.put("index", entry.name);
        out.put("candidates", rows.isEmpty() ? new ArrayList<Map<String, Object>>() : exactScore(rows, query, k));
        out.put("rows_scanned", rows.size());
        out.put("cells_probed", 0);
        out.put("used_index", false);
        out.put("indexed_rows", entry.rows);
        entry.lastSet = true; entry.lastUsed = false; entry.lastScanned = rows.size(); entry.lastProbed = 0;
        return out;
    }

    /**
     * The candidate row ids for Scout: the nearest cells in full, plus
     * {@code per_cell} representatives from every other cell, plus the rows
     * that are newer than the index.
     */
    public synchronized Map<String, Object> candidates(
            String table, String column, String query, String optionsJson) throws Exception
    {
        final Map<String, Object> opts = options(optionsJson);
        final Entry entry = find(table, column, opts);
        final int nprobe = Math.max(1, optionInt(opts, "nprobe", entry.nprobeDefault));
        final int perCell = Math.max(0, optionInt(opts, "per_cell", 1));
        final double[] queryVector = VectorText.parseVector(query);
        if (queryVector == null || queryVector.length == 0) {
            throw new IllegalArgumentException("fractalsql: the query vector is empty or malformed");
        }
        final Map<String, Object> opened = op("{\"op\":\"open\",\"model\":\"" + entry.model + "\"}");
        final String token = String.valueOf(opened.get("token"));
        try {
            final Map<String, Object> probed = op("{\"op\":\"probe\",\"token\":\"" + token + "\",\"query\":"
                    + jsonString(vectorText(queryVector)) + ",\"nprobe\":" + nprobe + "}");
            final List<?> cellList = (List<?>) probed.get("cells");
            final List<Integer> cells = new ArrayList<>();
            if (cellList != null) {
                for (Object o : cellList) {
                    cells.add((int) number(o, 0));
                }
            }
            final List<Map<String, Object>> near = loadCells(entry, token, cells);

            // every OTHER cell, with per_cell representatives
            final List<Map<String, Object>> others = new ArrayList<>();
            final List<Integer> allCells = allCells(entry);
            for (Integer cell : allCells) {
                if (cells.contains(cell)) {
                    continue;
                }
                final List<Map<String, Object>> rows = loadCells(entry, token, java.util.Collections.singletonList(cell));
                int taken = 0;
                for (Map<String, Object> row : rows) {
                    if (taken++ >= perCell) {
                        break;
                    }
                    others.add(row);
                }
            }
            final Map<String, Object> out = new LinkedHashMap<>();
            out.put("index", entry.name);
            out.put("cells", cells);
            out.put("near", near);
            out.put("others", others);
            out.put("delta_rows", 0);
            out.put("note", "the rows newer than the index are not in the index's cells; "
                    + "fractal_index_info reports the delta");
            return out;
        } finally {
            try {
                op("{\"op\":\"close\",\"token\":\"" + token + "\"}");
            } catch (RuntimeException e) {
                // closing must not mask the result
            }
        }
    }

    // ------------------------------------------------------------------
    // Helpers
    // ------------------------------------------------------------------

    /** The id column of the index covering table.column, or null when none does (agent_use_index looks the index up this way). */
    public synchronized String idColumnFor(String table, String column)
    {
        sync(null);
        for (Entry entry : registry.values()) {
            if (entry.sourceTable.equals(table) && entry.sourceColumn.equals(column)) {
                return entry.idColumn;
            }
        }
        return null;
    }

    /**
     * agent_use_index auto: an index is used only when it is ready, was calibrated to its target recall (an estimate from a sample, made at
     * build time) and the datasource holds at least {@code minRows} rows. Otherwise the agents scan exactly, as in off.
     */
    public synchronized boolean readyForAuto(String table, String column, long minRows)
    {
        for (Entry entry : registry.values()) {
            if (entry.sourceTable.equals(table) && entry.sourceColumn.equals(column)) {
                if (!Boolean.TRUE.equals(entry.reachesTarget)) {
                    return false;
                }
                final Health h = health(entry);
                return "ready".equals(h.status) && h.now >= minRows;
            }
        }
        return false;
    }

    /**
     * fractal_index_ensure: leave the index on table.column fit to use. Builds it when there is none (created), folds in the added rows
     * when that is all that is needed (refreshed), rebuilds after more than a quarter of the rows were added or a fifth deleted (rebuilt),
     * and otherwise changes nothing (unchanged). A degraded index is rebuilt only when new options are given. Returns
     * {name, action, status, generation, rows}.
     */
    public synchronized Map<String, Object> ensure(String table, String column, String optionsJson) throws Exception
    {
        sync(null);
        Entry existing = null;
        for (Entry entry : registry.values()) {
            if (entry.sourceTable.equals(table) && entry.sourceColumn.equals(column)) {
                existing = entry;
                break;
            }
        }
        String action = "unchanged";
        String name;
        final boolean haveOptions = optionsJson != null && !optionsJson.trim().isEmpty() && !optionsJson.trim().equals("{}");
        if (existing == null) {
            final Map<String, Object> made = create(table, column, optionsJson);
            name = String.valueOf(made.get("name"));
            action = "created";
        } else {
            name = existing.name;
            final Map<String, Object> info = info(name);
            final String status = String.valueOf(info.get("status"));
            final double rows = Math.max(1.0, existing.rows);
            final double added = ((Number) info.get("rows_added_since_build")).doubleValue();
            final double deleted = ((Number) info.get("rows_deleted_since_build")).doubleValue();
            if ("degraded".equals(status)) {
                if (haveOptions) {
                    rebuild(name, optionsJson);
                    action = "rebuilt";
                }
            } else if ("stale".equals(status)) {
                if (added / rows > 0.25 || deleted / rows > 0.20) {
                    rebuild(name, haveOptions ? optionsJson : null);
                    action = "rebuilt";
                } else if (added > 0) {
                    refresh(name);
                    action = "refreshed";
                }
            }
        }
        final Map<String, Object> after = info(name);
        final Map<String, Object> out = new LinkedHashMap<>();
        out.put("name", name);
        out.put("action", action);
        out.put("status", after.get("status"));
        out.put("generation", after.get("generation"));
        out.put("rows", after.get("rows"));
        return out;
    }

    private Entry find(String table, String column, Map<String, Object> opts)
    {
        final String name = optionString(opts, "index", "");
        sync(name.isEmpty() ? null : name);
        if (!name.isEmpty()) {
            final Entry entry = registry.get(name);
            if (entry == null) {
                throw new IllegalStateException("fractalsql: no index named '" + name + "'");
            }
            return entry;
        }
        for (Entry entry : registry.values()) {
            if (entry.sourceTable.equals(table) && entry.sourceColumn.equals(column)) {
                return entry;
            }
        }
        throw new IllegalStateException("fractalsql: no index covers " + table + "." + column
                + "; build one with fractal_index_create");
    }

    /** Hands the daemon the cells it needs: the ids, the codes and the payload. */
    private List<Map<String, Object>> loadCells(Entry entry, String token, List<Integer> cells)
            throws Exception
    {
        final List<Map<String, Object>> out = new ArrayList<>();
        if (cells.isEmpty()) {
            return out;
        }
        final List<Map<String, Object>> rows = readCells(entry, cells);
        final Map<Integer, List<Map<String, Object>>> byCell = new LinkedHashMap<>();
        for (Map<String, Object> row : rows) {
            final int cell = (int) number(row.get("cell"), 0);
            byCell.computeIfAbsent(cell, k -> new ArrayList<>()).add(row);
        }
        for (Integer cell : cells) {
            final List<Map<String, Object>> cellRows = byCell.get(cell);
            if (cellRows == null || cellRows.isEmpty()) {
                continue;
            }
            final StringBuilder ids = new StringBuilder();
            final StringBuilder codes = new StringBuilder();
            final StringBuilder payload = new StringBuilder();
            for (Map<String, Object> row : cellRows) {
                if (ids.length() > 0) {
                    ids.append(',');
                }
                ids.append(row.get("row_id"));
                codes.append(String.valueOf(row.get("codes")));
                payload.append(String.valueOf(row.get("payload")));
            }
            op("{\"op\":\"load_cell\",\"token\":\"" + token + "\",\"cell\":" + cell
                    + ",\"ids\":\"" + ids + "\",\"codes\":\"" + codes + "\",\"payload\":\"" + payload + "\"}");
            for (Map<String, Object> row : cellRows) {
                final Map<String, Object> one = new LinkedHashMap<>();
                one.put("cell", row.get("cell"));
                one.put("doc_id", row.get("row_id"));
                out.add(one);
            }
        }
        return out;
    }

    private List<Integer> allCells(Entry entry) throws Exception
    {
        final String sql = "SELECT DISTINCT \"cell\" FROM \"" + entry.indexTable.replace("\"", "\"\"")
                + "\" WHERE \"kind\" = 'cell' AND \"index_name\" = '" + entry.name.replace("'", "''")
                + "' AND \"generation\" = " + entry.generation;
        final List<Map<String, Object>> rows = service.query(sql);
        final List<Integer> out = new ArrayList<>();
        for (Map<String, Object> row : rows) {
            out.add((int) number(row.get("cell"), 0));
        }
        return out;
    }

    private static String corpusText(List<Row> batch)
    {
        // one row per ';', the values of a row separated by ',': the text form the daemon's corpus parser reads
        final StringBuilder sb = new StringBuilder();
        for (int i = 0; i < batch.size(); i++) {
            if (i > 0) {
                sb.append(';');
            }
            sb.append(vectorText(batch.get(i).vector));
        }
        return sb.toString();
    }

    // ------------------------------------------------------------------
    // The named feature store
    // ------------------------------------------------------------------

    /** The datasource of the feature store: one row per write, the newest row of a doc_id is its vector. */
    static final String FEATURE_STORE = "fractalsql_feature_store";

    /** Upserts a feature vector against a doc_id: an MSQ INSERT of one row (Druid keeps the older rows; the newest wins on read). */
    public synchronized String storeFeature(long docId, String vector) throws Exception
    {
        if (docId < 0) {
            throw new IllegalArgumentException("fractalsql: doc_id must be >= 0");
        }
        final double[] v = vector == null ? null : VectorText.parseVector(vector);
        if (v == null || v.length == 0) {
            throw new IllegalArgumentException(
                    "fractalsql: invalid feature_array (expect CSV/JSON text of numbers)");
        }
        final String sql = "INSERT INTO \"" + FEATURE_STORE + "\" SELECT CURRENT_TIMESTAMP AS \"__time\", "
                + "CAST(" + docId + " AS BIGINT) AS \"doc_id\", '" + vectorText(v).replace("'", "''") + "' AS \"features\" "
                + "FROM UNNEST(ARRAY[1]) AS t(x) PARTITIONED BY ALL";
        service.submitWrite(sql, null);
        return "ok";
    }

    /** The k stored vectors nearest the query, by true Euclidean distance, nearest first; a vector of another dimension is skipped. */
    public synchronized List<Map<String, Object>> mineFeatures(String vector, int k) throws Exception
    {
        if (k <= 0) {
            throw new IllegalArgumentException("fractalsql: k must be > 0");
        }
        final double[] q = vector == null ? null : VectorText.parseVector(vector);
        if (q == null || q.length == 0) {
            throw new IllegalArgumentException(
                    "fractalsql: invalid surrogate_vector (expect CSV/JSON text of numbers)");
        }
        final List<Map<String, Object>> rows;
        try {
            rows = service.query("SELECT \"__time\" AS \"t\", \"doc_id\", \"features\" FROM \"" + FEATURE_STORE + "\"");
        } catch (Exception e) {
            final String m = String.valueOf(e.getMessage()).toLowerCase(java.util.Locale.ROOT);
            if (m.contains("not found") || m.contains("object '")) {
                return new ArrayList<>();   // nothing has been stored yet
            }
            throw e;
        }
        final Map<Long, String> newestAt = new java.util.HashMap<>();
        final Map<Long, String> newest = new java.util.HashMap<>();
        for (Map<String, Object> row : rows) {
            if (row.get("doc_id") == null || row.get("features") == null) {
                continue;
            }
            final long id = ((Number) number2(row.get("doc_id"))).longValue();
            final String at = String.valueOf(row.get("t"));
            final String seen = newestAt.get(id);
            if (seen == null || at.compareTo(seen) >= 0) {
                newestAt.put(id, at);
                newest.put(id, String.valueOf(row.get("features")));
            }
        }
        final List<Map<String, Object>> hits = new ArrayList<>();
        for (Map.Entry<Long, String> e : newest.entrySet()) {
            final double[] f = VectorText.parseVector(e.getValue());
            if (f == null || f.length != q.length) {
                continue;
            }
            double sum = 0;
            for (int i = 0; i < f.length; i++) {
                final double d = f[i] - q[i];
                sum += d * d;
            }
            final Map<String, Object> hit = new LinkedHashMap<>();
            hit.put("doc_id", e.getKey());
            hit.put("distance", Math.sqrt(sum));
            hits.add(hit);
        }
        hits.sort((a, b) -> {
            final int c = Double.compare(((Number) a.get("distance")).doubleValue(), ((Number) b.get("distance")).doubleValue());
            return c != 0 ? c : Long.compare(((Number) a.get("doc_id")).longValue(), ((Number) b.get("doc_id")).longValue());
        });
        return hits.size() > k ? new ArrayList<>(hits.subList(0, k)) : hits;
    }

    private static String jsonString(String s)
    {
        return "\"" + s.replace("\\", "\\\\").replace("\"", "\\\"") + "\"";
    }

    private static String hex(byte[] bytes)
    {
        final StringBuilder sb = new StringBuilder(bytes.length * 2);
        for (byte b : bytes) {
            sb.append(Character.forDigit((b >> 4) & 0xF, 16));
            sb.append(Character.forDigit(b & 0xF, 16));
        }
        return sb.toString();
    }

    private static double number(Object value, double dflt)
    {
        if (value instanceof Number) {
            return ((Number) value).doubleValue();
        }
        if (value == null) {
            return dflt;
        }
        try {
            return Double.parseDouble(String.valueOf(value));
        } catch (NumberFormatException e) {
            return dflt;
        }
    }
}
