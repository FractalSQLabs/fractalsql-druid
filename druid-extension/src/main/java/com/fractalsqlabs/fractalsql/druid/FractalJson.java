/*
 * SPDX-License-Identifier: Apache-2.0
 * Copyright 2026 Daniel Gardiner d/b/a FractalSQLabs
 */
package com.fractalsqlabs.fractalsql.druid;

/**
 * A minimal JSON writer.
 *
 * <p>The reference extension returned JSON text for the functions whose result
 * is a document rather than a number; this builds the same documents on
 * the Druid side, so a query written against one reads the same against
 * the other.
 *
 * <p>Not a general JSON library -- it writes flat objects of numbers,
 * strings and numeric arrays, which is what the functions need.
 */
public final class FractalJson {

    private final StringBuilder sb = new StringBuilder("{");
    private boolean empty = true;

    /**
     * Read a field out of a JSON document.
     *
     * <p>The functions answer with a JSON document. Druid's own
     * {@code JSON_VALUE} reads a COMPLEX column, not a JSON string, so the
     * extension needs its own accessor for the documents it produces.
     *
     * <p>The path is the {@code $.a.b} form.
     *
     * @return the node, or null if the document or the path is not
     *         readable
     */
    public static com.fasterxml.jackson.databind.JsonNode read(String document, String path)
    {
        if (document == null || document.isEmpty() || path == null) {
            return null;
        }
        try {
            final com.fasterxml.jackson.databind.JsonNode root =
                    new com.fasterxml.jackson.databind.ObjectMapper().readTree(document);
            com.fasterxml.jackson.databind.JsonNode node = root;
            for (String part : path.split("\\.")) {
                if (node == null) {
                    return null;
                }
                final String key = part.startsWith("$") ? part.substring(1) : part;
                if (key.isEmpty()) {
                    continue;
                }
                // A segment may carry an array index: "frames[3]".
                final int bracket = key.indexOf('[');
                if (bracket > 0 && key.endsWith("]")) {
                    final String name = key.substring(0, bracket);
                    final int index = Integer.parseInt(key.substring(bracket + 1, key.length() - 1));
                    node = node.get(name);
                    node = node == null ? null : node.get(index);
                } else if (bracket == 0 && key.endsWith("]")) {
                    // The segment is an index into the current node
                    // itself: "$[0]" reads the first element of an
                    // array -- the form a vector's text needs.
                    final int index = Integer.parseInt(key.substring(1, key.length() - 1));
                    node = node == null ? null : node.get(index);
                } else {
                    node = node.get(key);
                }
            }
            return node;
        } catch (Exception e) {
            return null;
        }
    }

    /** Start a new object. */
    public FractalJson()
    {
    }

    private void sep()
    {
        if (!empty) {
            sb.append(',');
        }
        empty = false;
    }

    private void key(String key)
    {
        sep();
        sb.append('"').append(escape(key)).append("\":");
    }

    /** Add a numeric field. */
    public FractalJson num(String key, double value)
    {
        key(key);
        if (Double.isNaN(value) || Double.isInfinite(value)) {
            sb.append("null");
        } else {
            sb.append(value);
        }
        return this;
    }

    /** Add an integral field. */
    public FractalJson num(String key, long value)
    {
        key(key);
        sb.append(value);
        return this;
    }

    /** Add a string field. */
    public FractalJson str(String key, String value)
    {
        key(key);
        if (value == null) {
            sb.append("null");
        } else {
            sb.append('"').append(escape(value)).append('"');
        }
        return this;
    }

    /** Add an array field of numbers. */
    public FractalJson arr(String key, double[] values, int count)
    {
        return arrFrom(key, values, count, 0);
    }

    /** Add an array field of numbers, starting at {@code from}. */
    public FractalJson arrFrom(String key, double[] values, int count, int from)
    {
        key(key);
        sb.append('[');
        final int n = Math.min(count, Math.max(0, values.length - from));
        for (int i = 0; i < n; i++) {
            if (i > 0) {
                sb.append(',');
            }
            final double v = values[from + i];
            if (Double.isNaN(v) || Double.isInfinite(v)) {
                sb.append("null");
            } else {
                sb.append(v);
            }
        }
        sb.append(']');
        return this;
    }

    /** Add a raw JSON fragment as a field's value. */
    public FractalJson raw(String key, String json)
    {
        key(key);
        sb.append(json == null ? "null" : json);
        return this;
    }

    /** Finish the object. */
    public String build()
    {
        return sb.append('}').toString();
    }

    private static String escape(String s)
    {
        final StringBuilder out = new StringBuilder(s.length() + 8);
        for (int i = 0; i < s.length(); i++) {
            final char c = s.charAt(i);
            switch (c) {
                case '"':
                    out.append("\\\"");
                    break;
                case '\\':
                    out.append("\\\\");
                    break;
                case '\n':
                    out.append("\\n");
                    break;
                case '\r':
                    out.append("\\r");
                    break;
                case '\t':
                    out.append("\\t");
                    break;
                default:
                    if (c < 0x20) {
                        out.append(String.format("\\u%04x", (int) c));
                    } else {
                        out.append(c);
                    }
            }
        }
        return out.toString();
    }
}
