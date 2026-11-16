/*
 * SPDX-License-Identifier: Apache-2.0
 * Copyright 2026 Daniel Gardiner d/b/a FractalSQLabs
 */
package com.fractalsqlabs.fractalsql.druid;

import org.junit.jupiter.api.Test;

import java.util.List;
import java.util.Map;

import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertThrows;
import static org.junit.jupiter.api.Assertions.assertTrue;

/** fractal_chunk_text: the pinned cases every FractalSQL host must reproduce. */
public class FractalSqlChunkerTest {

    private static String show(List<Map<String, Object>> c)
    {
        final StringBuilder b = new StringBuilder();
        for (Map<String, Object> m : c) {
            b.append(b.length() == 0 ? "" : "|").append(m.get("start")).append('-').append(m.get("end")).append(':').append(m.get("text"));
        }
        return b.toString();
    }

    @Test
    public void fixedSizeFourOverlapOne()
    {
        assertEquals("0-4:abcd|3-7:defg|6-10:ghij", show(FractalSqlChunker.chunk("abcdefghij", 4, 1, "fixed")));
    }

    @Test
    public void sentencePackingWithALongSentenceSplit()
    {
        assertEquals("0-19:One. Two sentences!|20-39:Is this three? Yes.|41-71:Four is a long one that keeps |66-90:eeps on going and going.",
                show(FractalSqlChunker.chunk("One. Two sentences! Is this three? Yes.  Four is a long one that keeps on going and going.", 30, 5, "sentence")));
    }

    @Test
    public void emptyTextIsEmpty()
    {
        assertTrue(FractalSqlChunker.chunk("", 10, 0, null).isEmpty());
    }

    @Test
    public void aParagraphBreakNeedsTwoLineFeeds()
    {
        assertEquals(13, FractalSqlChunker.chunk("one\ntwo\nthree", 100, 0, null).get(0).get("end"));
        assertEquals(2, FractalSqlChunker.chunk("one\n\ntwo", 5, 0, "paragraph").size());
    }

    @Test
    public void badArgumentsAreRefused()
    {
        assertThrows(IllegalArgumentException.class, () -> FractalSqlChunker.chunk("x", 5, 5, null));
        assertThrows(IllegalArgumentException.class, () -> FractalSqlChunker.chunk("x", 0, 0, null));
        assertThrows(IllegalArgumentException.class, () -> FractalSqlChunker.chunk("x", 5, 0, "word"));
    }

    private static final String[] UNICODE = {
        "Cr\u00e8me br\u00fbl\u00e9e \u00e0 la fa\u00e7on de S\u00e3o Paulo, na\u00efve caf\u00e9, \u00c5ngstr\u00f6m, stra\u00dfe",
        "\u65e5\u672c\u8a9e\u306e\u30c6\u30ad\u30b9\u30c8\u3068\u4e2d\u6587\u6c49\u5b57\u3001\ud55c\uad6d\uc5b4 \ubb38\uc7a5\uc785\ub2c8\ub2e4",
        "\u0645\u0631\u062d\u0628\u0627 \u0628\u0627\u0644\u0639\u0627\u0644\u0645 \u05e9\u05dc\u05d5\u05dd \u05e2\u05d5\u05dc\u05dd",
        "\ud83d\ude00\ud83d\udc4d\ud83c\udffd\ud83c\uddef\ud83c\uddf5 \ud83d\udc68\u200d\ud83d\udc69\u200d\ud83d\udc67\u200d\ud83d\udc66 ok \ud83e\uddea",
        "e\u0301 n\u0303 a\u0308\u0323 end",
        "quote \" backslash \\ tab\t newline\n ctrl \u0001\u001f slash / <tag> &amp; \u2028 \u2029",
    };

    /** Offsets and sizes are counted in characters (code points), as on every other host: an emoji is one character, not two. */
    @Test
    public void unicodeOffsetsAreCodePointOffsets()
    {
        for (String text : UNICODE) {
            final int[] cps = text.codePoints().toArray();
            final List<Map<String, Object>> whole = FractalSqlChunker.chunk(text, 100000, 0, "fixed");
            assertEquals(1, whole.size());
            assertEquals(text, whole.get(0).get("text"));
            assertEquals(cps.length, ((Number) whole.get(0).get("end")).intValue());
            for (int[] so : new int[][]{{5, 0}, {7, 3}, {1, 0}}) {
                final StringBuilder joined = new StringBuilder();
                for (Map<String, Object> m : FractalSqlChunker.chunk(text, so[0], so[1], "fixed")) {
                    final int a = ((Number) m.get("start")).intValue(), b = ((Number) m.get("end")).intValue();
                    final String t = (String) m.get("text");
                    assertEquals(new String(cps, a, b - a), t);
                    assertTrue(t.codePointCount(0, t.length()) <= so[0]);
                    if (so[1] == 0) {
                        joined.append(t);
                    }
                }
                if (so[1] == 0) {
                    assertEquals(text, joined.toString());
                }
            }
        }
    }
}
