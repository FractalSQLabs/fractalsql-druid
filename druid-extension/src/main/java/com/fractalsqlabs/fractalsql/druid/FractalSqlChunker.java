/*
 * SPDX-License-Identifier: Apache-2.0 AND BSD-2-Clause
 * SPDX-FileCopyrightText: 2026 Daniel Gardiner d/b/a FractalSQLabs
 */
package com.fractalsqlabs.fractalsql.druid;

import java.util.ArrayList;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;

/**
 * Splits text into chunks of at most {@code size} characters, as a list of {no, start, end, text}. Offsets are character (code point)
 * offsets, end exclusive, and text is the slice [start, end). The result is the same on every FractalSQL host: the algorithm below is
 * the specification, and each host's test pins it with the same inputs.
 *
 * <ul>
 * <li>{@code fixed}: one span, the whole text, split every size - overlap characters.
 * <li>{@code paragraph} (default): the text is cut into paragraphs at paragraph breaks (a run of whitespace -- space, tab, CR, LF -- that
 * contains at least two LF) and consecutive paragraphs are packed into a chunk while the chunk stays within size.
 * <li>{@code sentence}: the same with sentences: a sentence ends after a run of '.', '!' or '?' that is followed by whitespace or the
 * end of the text, and a paragraph break also ends one.
 * </ul>
 *
 * A unit (paragraph or sentence) never includes the whitespace around it, a chunk runs from the start of its first unit to the end of its
 * last (so it keeps the separators between them), and a unit longer than size is split like a fixed span, with overlap characters shared
 * between neighbours. Overlap applies only inside a split unit or in fixed mode.
 */
public final class FractalSqlChunker
{
    public static final int MAX_SIZE = 100000;
    public static final int MAX_CHUNKS = 100000;
    /** Characters a fixed or oversize-unit split may emit in all: size x chunks would otherwise reach gigabytes with a large overlap. */
    public static final long MAX_SPLIT_CHARS = 64L * 1024 * 1024;

    private FractalSqlChunker()
    {
    }

    private static boolean ws(int c)
    {
        return c == ' ' || c == '\t' || c == '\r' || c == '\n';
    }

    private static void emit(List<Map<String, Object>> out, int[] cp, int a, int b)
    {
        final Map<String, Object> m = new LinkedHashMap<>();
        m.put("no", out.size());
        m.put("start", a);
        m.put("end", b);
        m.put("text", new String(cp, a, b - a));
        out.add(m);
    }

    private static void split(List<Map<String, Object>> out, int[] cp, int a, int b, int size, int overlap, long[] budget)
    {
        int pos = a;
        while (true) {
            if (out.size() >= MAX_CHUNKS) {
                throw new IllegalArgumentException("fractal_chunk_text: more than 100000 chunks or 64 MiB of output (raise size or lower overlap)");
            }
            final int e = (int) Math.min((long) pos + size, b);
            budget[0] += e - pos;
            if (budget[0] > MAX_SPLIT_CHARS) {
                throw new IllegalArgumentException("fractal_chunk_text: the chunks would exceed 64 MiB (lower the overlap or raise size)");
            }
            emit(out, cp, pos, e);
            if (e >= b) {
                break;
            }
            pos = e - overlap;
        }
    }

    public static List<Map<String, Object>> chunk(String text, int size, int overlap, String mode)
    {
        if (size < 1 || size > MAX_SIZE) {
            throw new IllegalArgumentException("fractal_chunk_text: size must be 1..100000");
        }
        if (overlap < 0 || overlap >= size) {
            throw new IllegalArgumentException("fractal_chunk_text: overlap must be 0..size-1");
        }
        final String m = mode == null ? "paragraph" : mode;
        final int md = m.equals("fixed") ? 0 : m.equals("paragraph") ? 1 : m.equals("sentence") ? 2 : -1;
        if (md < 0) {
            throw new IllegalArgumentException("fractal_chunk_text: mode must be one of: fixed, paragraph, sentence");
        }
        final List<Map<String, Object>> out = new ArrayList<>();
        if (text == null) {
            return out;
        }
        final int[] cp = text.codePoints().toArray();
        final long[] budget = {0};
        final int n = cp.length;
        if (md == 0) {
            if (n > 0) {
                split(out, cp, 0, n, size, overlap, budget);
            }
            return out;
        }
        int curA = 0;
        int curB = 0;
        boolean have = false;
        int i = 0;
        while (i < n) {
            while (i < n && ws(cp[i])) {
                i++;
            }
            if (i >= n) {
                break;
            }
            final int ua = i;
            int ub;
            while (true) {
                if (i >= n) {
                    ub = n;
                    break;
                }
                final int ch = cp[i];
                if (ws(ch)) {
                    int j = i;
                    int lf = 0;
                    while (j < n && ws(cp[j])) {
                        if (cp[j] == '\n') {
                            lf++;
                        }
                        j++;
                    }
                    if (lf >= 2) {
                        ub = i;
                        i = j;
                        break;
                    }
                    i = j;
                    continue;
                }
                i++;
                if (md == 2 && (ch == '.' || ch == '!' || ch == '?')) {
                    while (i < n && (cp[i] == '.' || cp[i] == '!' || cp[i] == '?')) {
                        i++;
                    }
                    if (i >= n || ws(cp[i])) {
                        ub = i;
                        break;
                    }
                }
            }
            while (ub > ua && ws(cp[ub - 1])) {
                ub--;
            }
            if (ub == ua) {
                continue;
            }
            if (ub - ua > size) {
                if (have) {
                    emit(out, cp, curA, curB);
                    have = false;
                }
                split(out, cp, ua, ub, size, overlap, budget);
            }
            else if (!have) {
                curA = ua;
                curB = ub;
                have = true;
            }
            else if (ub - curA <= size) {
                curB = ub;
            }
            else {
                emit(out, cp, curA, curB);
                curA = ua;
                curB = ub;
            }
            if (out.size() >= MAX_CHUNKS) {
                throw new IllegalArgumentException("fractal_chunk_text: more than 100000 chunks or 64 MiB of output (raise size or lower overlap)");
            }
        }
        if (have) {
            emit(out, cp, curA, curB);
        }
        return out;
    }
}
