/*
 * SPDX-License-Identifier: Apache-2.0
 * Copyright 2026 Daniel Gardiner d/b/a FractalSQLabs
 */
package com.fractalsqlabs.fractalsql.druid;

import java.util.ArrayList;
import java.util.List;

/**
 * Text helpers for the vector surface.
 *
 * <p>Two formats are accepted, matching the ones the core's text-form
 * search takes:
 * <ul>
 *   <li>CSV -- {@code "1.0,0.5,-0.25"}</li>
 *   <li>bracketed JSON -- {@code "[1.0,0.5,-0.25]"}</li>
 * </ul>
 *
 * <p>The SQL surface takes the query vector as a VARCHAR literal in
 * either form, because a VARCHAR literal is unambiguous to extract from
 * the planner's expression tree -- a SQL {@code ARRAY[...]} literal is
 * not.
 */
public final class VectorText {

    private VectorText() {
    }

    /**
     * Parse a vector from its text form.
     *
     * @return the parsed vector, or null if the text is not a well-formed
     *         vector (empty, non-numeric, or mismatched brackets)
     */
    public static double[] parseVector(String text) {
        if (text == null) {
            return null;
        }
        String s = text.trim();
        if (s.isEmpty()) {
            return null;
        }
        // Bracketed JSON: strip the outer [ ] and any nested quotes.
        if (s.charAt(0) == '[') {
            if (s.charAt(s.length() - 1) != ']') {
                return null;
            }
            s = s.substring(1, s.length() - 1).trim();
            if (s.isEmpty()) {
                return null;
            }
        }
        // Split on commas (and tolerate whitespace between them).
        List<Double> out = new ArrayList<>();
        int start = 0;
        int len = s.length();
        for (int i = 0; i <= len; i++) {
            if (i == len || s.charAt(i) == ',') {
                String piece = s.substring(start, i).trim();
                if (piece.isEmpty()) {
                    return null;
                }
                // Strip surrounding double quotes, which the JSON form
                // may carry around a number.
                if (piece.length() >= 2 && piece.charAt(0) == '"'
                        && piece.charAt(piece.length() - 1) == '"') {
                    piece = piece.substring(1, piece.length() - 1).trim();
                }
                double d;
                try {
                    d = Double.parseDouble(piece);
                } catch (NumberFormatException e) {
                    return null;
                }
                if (!Double.isFinite(d)) {
                    return null;
                }
                out.add(d);
                start = i + 1;
            }
        }
        if (out.isEmpty()) {
            return null;
        }
        double[] v = new double[out.size()];
        for (int i = 0; i < v.length; i++) {
            v[i] = out.get(i);
        }
        return v;
    }

    /**
     * Pull the {@code best_point} array out of the core's search-result
     * JSON.
     *
     * <p>The core's result shape is
     * {@code {"dim":N,"n_corpus":N,"best_fit":D,"best_point":[d1,...],...}},
     * so this scans for the key and reads the numeric array that follows.
     * It returns null if the key is absent or malformed.
     *
     * @param maxDim the largest number of components to accept
     */
    public static double[] extractBestPoint(byte[] resultJson, int maxDim) {
        if (resultJson == null || resultJson.length == 0) {
            return null;
        }
        String json = new String(resultJson, java.nio.charset.StandardCharsets.UTF_8);
        int key = json.indexOf("\"best_point\"");
        if (key < 0) {
            return null;
        }
        int open = json.indexOf('[', key);
        if (open < 0) {
            return null;
        }
        int close = json.indexOf(']', open);
        if (close < 0) {
            return null;
        }
        String body = json.substring(open + 1, close).trim();
        if (body.isEmpty()) {
            return null;
        }
        List<Double> out = new ArrayList<>();
        int start = 0;
        for (int i = 0; i <= body.length(); i++) {
            if (i == body.length() || body.charAt(i) == ',') {
                String piece = body.substring(start, i).trim();
                if (piece.isEmpty()) {
                    return null;
                }
                try {
                    out.add(Double.parseDouble(piece));
                } catch (NumberFormatException e) {
                    return null;
                }
                start = i + 1;
                if (out.size() > maxDim) {
                    return null;
                }
            }
        }
        double[] v = new double[out.size()];
        for (int i = 0; i < v.length; i++) {
            v[i] = out.get(i);
        }
        return v;
    }
}
