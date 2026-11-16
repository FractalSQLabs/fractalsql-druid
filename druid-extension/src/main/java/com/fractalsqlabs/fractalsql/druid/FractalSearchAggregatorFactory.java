/*
 * SPDX-License-Identifier: Apache-2.0
 * Copyright 2026 Daniel Gardiner d/b/a FractalSQLabs
 */
package com.fractalsqlabs.fractalsql.druid;

import com.fasterxml.jackson.annotation.JsonCreator;
import com.fasterxml.jackson.annotation.JsonIgnore;
import com.fasterxml.jackson.annotation.JsonProperty;
import com.fasterxml.jackson.annotation.JsonTypeName;
import org.apache.druid.query.aggregation.Aggregator;
import org.apache.druid.query.aggregation.AggregateCombiner;
import org.apache.druid.query.aggregation.AggregatorFactory;
import org.apache.druid.query.aggregation.BufferAggregator;
import org.apache.druid.segment.ColumnSelectorFactory;
import org.apache.druid.segment.ColumnValueSelector;
import org.apache.druid.segment.column.ValueType;

import java.nio.ByteBuffer;
import java.nio.charset.StandardCharsets;
import java.util.Arrays;
import java.util.Comparator;
import java.util.List;
import java.util.Objects;

/**
 * The native Druid aggregator behind {@code fractal_search_distance(...)}.
 *
 * <p><b>What it computes.</b> The FractalSQL core's SFS optimizer
 * refines a query vector into a projection; the refined point is
 * <i>corpus-independent</i> (the core relies on exactly this). So the
 * refinement happens once, at
 * plan time, and this aggregator only has to score each row against the
 * refined point and keep the best score.
 *
 * <p>The per-row value is therefore identical to the reference extension's
 * {@code fractal_search_distance(vector, query)}: the cosine distance from the
 * row's vector to the refined query point. This is an aggregate rather
 * than a native expression because it has to scan the column as a
 * corpus; it reports the minimum of those distances over the group --
 * "how close does the best row in this group come to the query".
 *
 * <p><b>Why a DOUBLE intermediate.</b> The running minimum is a single
 * double, so the intermediate state is eight bytes, serializes as a
 * plain number, and merges with a {@code Math.min}. No corpus crosses
 * the wire.
 *
 * <p>{@link AggregatorFactory} is one of Druid's <i>documented</i>
 * extension points (the "Creating extensions" page lists Aggregators),
 * unlike the SQL bridge that fronts it.
 */
@JsonTypeName(FractalSearchAggregatorFactory.TYPE)
public class FractalSearchAggregatorFactory extends AggregatorFactory {



    /** The JSON subtype name Druid uses to deserialise this factory. */
    public static final String TYPE = "fractalSearch";

    // Druid's mapper serialises aggregator factories by FIELD, and
    // Druid's own factories annotate their fields with @JsonProperty --
    // so the fields are annotated here too, not just the getters and
    // the creator parameters. Without it the broker sends
    // {"type":"fractalSearch"} and the historical reads back a factory
    // with a null column name.
    @JsonProperty("name")
    private final String name;

    @JsonProperty("columnName")
    private final String columnName;

    @JsonProperty("refinedQuery")
    private final double[] refinedQuery;

    @JsonCreator
    public FractalSearchAggregatorFactory(
            @JsonProperty("name") String name,
            @JsonProperty("columnName") String columnName,
            @JsonProperty("refinedQuery") double[] refinedQuery)
    {
        // getName() must never be null: the broker serialises this
        // factory to the data nodes, and a null name makes the
        // historical fail to deserialise the whole query.
        this.name = (name == null || name.isEmpty()) ? "fractal_search_distance" : name;
        this.columnName = columnName;
        this.refinedQuery = refinedQuery;
    }

    @JsonProperty("name")
    public String getName()
    {
        return name;
    }

    @JsonProperty("columnName")
    public String getColumnName()
    {
        return columnName;
    }

    /** The SFS-refined query point this aggregator scores against. */
    @JsonProperty("refinedQuery")
    public double[] getRefinedQuery()
    {
        return refinedQuery;
    }

    @Override
    public Aggregator factorize(ColumnSelectorFactory columnSelectorFactory)
    {
        return new FractalSearchAggregator(
                columnSelectorFactory.makeColumnValueSelector(columnName), refinedQuery);
    }

    @Override
    public BufferAggregator factorizeBuffered(ColumnSelectorFactory columnSelectorFactory)
    {
        return new FractalSearchBufferAggregator(
                columnSelectorFactory.makeColumnValueSelector(columnName), refinedQuery);
    }

    @Override
    public Comparator getComparator()
    {
        return Comparator.naturalOrder();
    }

    @Override
    public Object combine(Object lhs, Object rhs)
    {
        final double a = ((Number) lhs).doubleValue();
        final double b = ((Number) rhs).doubleValue();
        return Math.min(a, b);
    }

    /**
     * The combiner that folds a group's rows into the group's value.
     *
     * <p>Druid's GroupBy engine computes one value per input row (into
     * that row's slot in the aggregator buffer) and then folds the rows
     * of each group together. Without a combiner there is nothing to do
     * that fold, and the group comes back with the value its slot was
     * initialised to -- Infinity, for this factory.
     *
     * <p>This mirrors Druid's own {@code DoubleMinAggregateCombiner}:
     * {@code reset} takes the first row's value, {@code fold} keeps the
     * minimum.
     */
    @Override
    public AggregateCombiner<Double> makeAggregateCombiner()
    {
        return new AggregateCombiner<Double>()
        {
            private double value = Double.POSITIVE_INFINITY;
            private boolean initialized = false;

            @Override
            public void reset(ColumnValueSelector selector)
            {
                value = selector.getDouble();
                initialized = true;
            }

            @Override
            public void fold(ColumnValueSelector selector)
            {
                value = Math.min(value, selector.getDouble());
            }

            @Override
            public boolean isNull()
            {
                return !initialized;
            }

            @Override
            public double getDouble()
            {
                return value;
            }

            @Override
            public float getFloat()
            {
                return (float) value;
            }

            @Override
            public long getLong()
            {
                return (long) value;
            }

            @Override
            public Double getObject()
            {
                return value;
            }

            @Override
            public Class<? extends Double> classOfObject()
            {
                return Double.class;
            }
        };
    }

    /**
     * The factory that merges this one's partial states.
     *
     * <p>A NEW instance, matching Druid's own factories -- Druid's
     * {@code SimpleAggregatorFactory} returns a fresh one, and the
     * group-merge phase asks the COMBINING factory for its combiner, so
     * the combining factory has to be a usable aggregator in its own
     * right.
     *
     * <p>{@code @JsonIgnore} is load-bearing. The broker serialises
     * this factory into the native query it sends to the data nodes, and
     * the historical deserialises it back. Without the annotation Jackson
     * follows {@code getCombiningFactory()} -- which returns an
     * equivalent factory -- and recurses forever, failing with "Document
     * nesting depth (1001) exceeds the maximum allowed (1000)". Druid's
     * built-in factories do not need it because their combining factory
     * is not reachable as a bean property.
     */
    @JsonIgnore
    @Override
    public AggregatorFactory getCombiningFactory()
    {
        return new FractalSearchAggregatorFactory(name, columnName, refinedQuery);
    }

    @Override
    public Object deserialize(Object object)
    {
        return object;
    }

    @Override
    public Object finalizeComputation(Object object)
    {
        return object;
    }

    @Override
    public List<String> requiredFields()
    {
        return List.of(columnName);
    }

    @Override
    public ValueType getType()
    {
        return ValueType.DOUBLE;
    }

    @Override
    public ValueType getFinalizedType()
    {
        return ValueType.DOUBLE;
    }

    @Override
    public int getMaxIntermediateSize()
    {
        return Double.BYTES;
    }

    @Override
    public byte[] getCacheKey()
    {
        return (name + "|" + columnName + "|" + Arrays.hashCode(refinedQuery))
                .getBytes(StandardCharsets.UTF_8);
    }

    @Override
    public boolean equals(Object o)
    {
        if (this == o) {
            return true;
        }
        if (o == null || getClass() != o.getClass()) {
            return false;
        }
        FractalSearchAggregatorFactory that = (FractalSearchAggregatorFactory) o;
        return Objects.equals(name, that.name)
                && Objects.equals(columnName, that.columnName)
                && Arrays.equals(refinedQuery, that.refinedQuery);
    }

    @Override
    public int hashCode()
    {
        return Objects.hash(name, columnName, Arrays.hashCode(refinedQuery));
    }

    @Override
    public String toString()
    {
        return "FractalSearchAggregatorFactory{name='" + name
                + "', columnName='" + columnName
                + "', dim=" + (refinedQuery == null ? 0 : refinedQuery.length) + "}";
    }

    /**
     * The per-row aggregator: reads the vector column, scores each row
     * against the refined query point, and keeps the best score.
     */
    static class FractalSearchAggregator implements Aggregator {
        private final ColumnValueSelector<?> selector;
        private final double[] refinedQuery;
        private double best = Double.POSITIVE_INFINITY;

        FractalSearchAggregator(ColumnValueSelector<?> selector, double[] refinedQuery)
        {
            this.selector = selector;
            this.refinedQuery = refinedQuery;
        }

        @Override
        public void aggregate()
        {
            final Object raw = selector.getObject();
            if (raw == null) {
                return;
            }
            final double[] row = toDoubles(raw);
            if (row == null || row.length != refinedQuery.length) {
                // A dimension mismatch is not an error here: it means this
                // row is not comparable to the query, so it cannot be the
                // best match. Skip it.
                return;
            }
            final double d = Native.cosineDistance(row, refinedQuery);
            if (d < best) {
                best = d;
            }
        }

        @Override
        public Object get()
        {
            return best;
        }

        @Override
        public float getFloat()
        {
            return (float) best;
        }

        @Override
        public long getLong()
        {
            return (long) best;
        }

        @Override
        public double getDouble()
        {
            return best;
        }

        @Override
        public boolean isNull()
        {
            return Double.isInfinite(best);
        }

        @Override
        public void close()
        {
            // Druid 38's ColumnValueSelector is not Closeable, so there
            // is nothing to release here.
        }
    }

    /**
     * The buffered aggregator: the path Druid's GroupBy actually uses.
     *
     * <p>The intermediate state is a single double -- the best (smallest)
     * distance seen so far -- held in the aggregator's off-heap buffer at
     * the given position. That keeps the intermediate eight bytes, which
     * is what {@code getMaxIntermediateSize()} promises.
     */
    static class FractalSearchBufferAggregator implements BufferAggregator {
        private final ColumnValueSelector<?> selector;
        private final double[] refinedQuery;

        FractalSearchBufferAggregator(ColumnValueSelector<?> selector, double[] refinedQuery)
        {
            this.selector = selector;
            this.refinedQuery = refinedQuery;
        }

        @Override
        public void init(ByteBuffer buffer, int position)
        {
            buffer.putDouble(position, Double.POSITIVE_INFINITY);
        }

        @Override
        public void aggregate(ByteBuffer buffer, int position)
        {
            final Object raw = selector.getObject();
            if (raw == null) {
                return;
            }

            // Two different selectors reach this method.
            //
            // The ROW aggregator is factorized against the vector column
            // and sees the embedding itself.
            //
            // The COMBINING aggregator -- the one Druid uses to fold a
            // group's rows together -- is factorized against the row and
            // sees the row's ALREADY-COMPUTED DISTANCE, a plain number.
            // Treating that number as a one-element vector made the
            // dimension check fail, so a group of more than one row came
            // back with the value its slot was initialised to.
            if (raw instanceof Number) {
                final double alreadyComputed = ((Number) raw).doubleValue();
                if (alreadyComputed < buffer.getDouble(position)) {
                    buffer.putDouble(position, alreadyComputed);
                }
                return;
            }

            final double[] row = toDoubles(raw);
            if (row == null || row.length != refinedQuery.length) {
                return;
            }
            final double d = Native.cosineDistance(row, refinedQuery);
            if (d < buffer.getDouble(position)) {
                buffer.putDouble(position, d);
            }
        }

        @Override
        public Object get(ByteBuffer buffer, int position)
        {
            return buffer.getDouble(position);
        }

        @Override
        public float getFloat(ByteBuffer buffer, int position)
        {
            return (float) buffer.getDouble(position);
        }

        @Override
        public long getLong(ByteBuffer buffer, int position)
        {
            return (long) buffer.getDouble(position);
        }

        @Override
        public double getDouble(ByteBuffer buffer, int position)
        {
            return buffer.getDouble(position);
        }

        @Override
        public boolean isNull(ByteBuffer buffer, int position)
        {
            return Double.isInfinite(buffer.getDouble(position));
        }

        @Override
        public void close()
        {
            // Druid 38's ColumnValueSelector is not Closeable.
        }
    }

    /**
     * Coerce a column value to a double vector.
     *
     * <p>Druid's ARRAY columns surface as {@code Object[]} of boxed
     * numbers; a native {@code double[]} is accepted too, because that
     * is what a JSON-typed column's array elements can carry.
     *
     * <p>A VARCHAR column is accepted as well: the vector's <i>text</i>
     * form -- CSV or bracketed JSON -- is the interchange format the
     * core's own vector API uses, and it is the form a column that
     * holds a vector as text carries. This is the shape of a
     * {@code fractal_search_distance(vector, query)} call over a text vector.
     */
    static double[] toDoubles(Object raw)
    {
        if (raw instanceof double[]) {
            return (double[]) raw;
        }
        if (raw instanceof Object[]) {
            final Object[] arr = (Object[]) raw;
            final double[] out = new double[arr.length];
            for (int i = 0; i < arr.length; i++) {
                final Object o = arr[i];
                if (o instanceof Number) {
                    out[i] = ((Number) o).doubleValue();
                } else if (o == null) {
                    return null;
                } else {
                    try {
                        out[i] = Double.parseDouble(o.toString());
                    } catch (NumberFormatException e) {
                        return null;
                    }
                }
            }
            return out;
        }
        if (raw instanceof String) {
            return VectorText.parseVector((String) raw);
        }
        return null;
    }
}
