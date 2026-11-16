/*
 * SPDX-License-Identifier: Apache-2.0
 * Copyright 2026 Daniel Gardiner d/b/a FractalSQLabs
 */
package com.fractalsqlabs.fractalsql.druid;

import org.apache.druid.query.aggregation.AggregateCombiner;
import org.apache.druid.query.aggregation.Aggregator;
import org.apache.druid.query.aggregation.BufferAggregator;
import org.apache.druid.segment.ColumnSelectorFactory;
import org.apache.druid.segment.ColumnValueSelector;
import org.junit.jupiter.api.Test;

import java.lang.reflect.Proxy;
import java.nio.ByteBuffer;
import java.util.List;
import java.util.concurrent.atomic.AtomicReference;

import static org.junit.jupiter.api.Assertions.assertArrayEquals;
import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertFalse;
import static org.junit.jupiter.api.Assertions.assertNotEquals;
import static org.junit.jupiter.api.Assertions.assertNotNull;
import static org.junit.jupiter.api.Assertions.assertNull;
import static org.junit.jupiter.api.Assertions.assertTrue;

/**
 * The per-row, buffered and combining behaviour of the
 * {@code fractal_search_distance} aggregate, driven directly.
 */
public class AggregatorBehaviourTest {

    private static final double[] Q = {1.0, 0.0, 0.0};

    /** A selector whose current value the test sets. */
    private static ColumnValueSelector<?> selector(AtomicReference<Object> current)
    {
        return (ColumnValueSelector<?>) Proxy.newProxyInstance(
                AggregatorBehaviourTest.class.getClassLoader(),
                new Class<?>[]{ColumnValueSelector.class},
                (proxy, method, args) -> {
                    switch (method.getName()) {
                        case "getObject":
                            return current.get();
                        case "getDouble":
                            return ((Number) current.get()).doubleValue();
                        case "isNull":
                            return current.get() == null;
                        case "hashCode":
                            return System.identityHashCode(proxy);
                        case "equals":
                            return proxy == args[0];
                        case "toString":
                            return "selector";
                        default:
                            return null;
                    }
                });
    }

    private static ColumnSelectorFactory factoryFor(ColumnValueSelector<?> sel)
    {
        return (ColumnSelectorFactory) Proxy.newProxyInstance(
                AggregatorBehaviourTest.class.getClassLoader(),
                new Class<?>[]{ColumnSelectorFactory.class},
                (proxy, method, args) -> "makeColumnValueSelector".equals(method.getName()) ? sel : null);
    }

    @Test
    void rowAggregatorKeepsTheBestDistanceAndSkipsUnusableRows()
    {
        final AtomicReference<Object> cur = new AtomicReference<>();
        final FractalSearchAggregatorFactory f = new FractalSearchAggregatorFactory("d", "emb", Q);
        final Aggregator agg = f.factorize(factoryFor(selector(cur)));

        assertTrue(agg.isNull(), "nothing aggregated yet");
        cur.set(null);
        agg.aggregate();
        cur.set(new Object[]{1.0, 2.0});            // wrong dimension
        agg.aggregate();
        cur.set(Integer.valueOf(7));                // not a vector
        agg.aggregate();
        assertTrue(agg.isNull());

        cur.set(new Object[]{0.0, 1.0, 0.0});       // orthogonal
        agg.aggregate();
        final double first = agg.getDouble();
        assertEquals(1.0, first, 1e-9);
        cur.set(new double[]{1.0, 0.0, 0.0});       // identical, better
        agg.aggregate();
        cur.set(new double[]{0.0, 1.0, 0.0});       // worse, must not replace
        agg.aggregate();

        assertEquals(0.0, agg.getDouble(), 1e-9);
        assertEquals(0.0f, agg.getFloat(), 1e-6);
        assertEquals(0L, agg.getLong());
        assertEquals(0.0, (Double) agg.get(), 1e-9);
        assertFalse(agg.isNull());
        agg.close();
    }

    @Test
    void bufferAggregatorHandlesVectorsAndPrecomputedDistances()
    {
        final AtomicReference<Object> cur = new AtomicReference<>();
        final FractalSearchAggregatorFactory f = new FractalSearchAggregatorFactory("d", "emb", Q);
        final BufferAggregator agg = f.factorizeBuffered(factoryFor(selector(cur)));
        final ByteBuffer buf = ByteBuffer.allocate(16);

        agg.init(buf, 8);
        assertTrue(agg.isNull(buf, 8));

        cur.set(null);
        agg.aggregate(buf, 8);
        cur.set("1,2");                              // text vector, wrong dim
        agg.aggregate(buf, 8);
        assertTrue(agg.isNull(buf, 8));

        cur.set(Double.valueOf(0.75));               // the combining path
        agg.aggregate(buf, 8);
        assertEquals(0.75, agg.getDouble(buf, 8), 1e-12);
        cur.set(Double.valueOf(0.9));                // worse: ignored
        agg.aggregate(buf, 8);
        assertEquals(0.75, agg.getDouble(buf, 8), 1e-12);

        cur.set("[1.0, 0.0, 0.0]");                  // a text vector, best
        agg.aggregate(buf, 8);
        assertEquals(0.0, agg.getDouble(buf, 8), 1e-9);
        cur.set(new Object[]{0.0, 1.0, 0.0});        // worse vector: ignored
        agg.aggregate(buf, 8);

        assertEquals(0.0, (Double) agg.get(buf, 8), 1e-9);
        assertEquals(0.0f, agg.getFloat(buf, 8), 1e-6);
        assertEquals(0L, agg.getLong(buf, 8));
        assertFalse(agg.isNull(buf, 8));
        agg.close();
    }

    @Test
    void combinerFoldsToTheMinimum()
    {
        final AtomicReference<Object> cur = new AtomicReference<>();
        final ColumnValueSelector<?> sel = selector(cur);
        final AggregateCombiner<Double> c =
                new FractalSearchAggregatorFactory("d", "emb", Q).makeAggregateCombiner();

        assertTrue(c.isNull());
        cur.set(0.6);
        c.reset(sel);
        assertFalse(c.isNull());
        cur.set(0.2);
        c.fold(sel);
        cur.set(0.9);
        c.fold(sel);

        assertEquals(0.2, c.getDouble(), 1e-12);
        assertEquals(0.2f, c.getFloat(), 1e-6f);
        assertEquals(0L, c.getLong());
        assertEquals(0.2, c.getObject(), 1e-12);
        assertEquals(Double.class, c.classOfObject());
    }

    @Test
    void factoryMetadata()
    {
        final FractalSearchAggregatorFactory f = new FractalSearchAggregatorFactory(null, "emb", Q);
        assertEquals("fractal_search_distance", f.getName());
        assertEquals("fractal_search_distance",
                new FractalSearchAggregatorFactory("", "emb", Q).getName());
        assertEquals(List.of("emb"), f.requiredFields());
        assertEquals(Double.BYTES, f.getMaxIntermediateSize());
        assertNotNull(f.getType());
        assertNotNull(f.getFinalizedType());
        assertEquals(f, f.getCombiningFactory());
        assertEquals(0.5, f.combine(0.5, 0.7));
        assertEquals(0.4, f.combine(0.9, 0.4));
        assertEquals(0.3, f.deserialize(0.3));
        assertEquals(0.3, f.finalizeComputation(0.3));
        assertEquals(0, f.getComparator().compare(1.0, 1.0));
        assertTrue(f.toString().contains("dim=3"));
        assertTrue(new FractalSearchAggregatorFactory("n", "c", null).toString().contains("dim=0"));

        assertArrayEquals(f.getCacheKey(), f.getCombiningFactory().getCacheKey());
        assertNotEquals(f, new FractalSearchAggregatorFactory("n2", "emb", Q));
        assertNotEquals(f, new FractalSearchAggregatorFactory(null, "other", Q));
        assertNotEquals(f, new FractalSearchAggregatorFactory(null, "emb", new double[]{1, 1, 1}));
        assertNotEquals(f, null);
        assertNotEquals(f, "text");
        assertEquals(f, f);
        assertEquals(f.hashCode(), new FractalSearchAggregatorFactory(null, "emb", Q).hashCode());
    }

    @Test
    void toDoublesCoercions()
    {
        assertArrayEquals(Q, FractalSearchAggregatorFactory.toDoubles(Q));
        assertArrayEquals(new double[]{1, 2.5, 3},
                FractalSearchAggregatorFactory.toDoubles(new Object[]{1, 2.5f, "3"}), 1e-9);
        assertNull(FractalSearchAggregatorFactory.toDoubles(new Object[]{1, null}));
        assertNull(FractalSearchAggregatorFactory.toDoubles(new Object[]{1, "x"}));
        assertArrayEquals(new double[]{1, 2}, FractalSearchAggregatorFactory.toDoubles("1,2"), 1e-9);
        assertNull(FractalSearchAggregatorFactory.toDoubles(42));
        assertNull(FractalSearchAggregatorFactory.toDoubles(null));
    }
}
