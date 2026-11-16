/*
 * SPDX-License-Identifier: Apache-2.0
 * Copyright 2026 Daniel Gardiner d/b/a FractalSQLabs
 */
package com.fractalsqlabs.fractalsql.druid;

import com.fasterxml.jackson.annotation.JsonAutoDetect;
import com.fasterxml.jackson.annotation.PropertyAccessor;
import com.fasterxml.jackson.databind.ObjectMapper;
import com.fasterxml.jackson.databind.jsontype.NamedType;
import com.fasterxml.jackson.databind.module.SimpleModule;
import org.junit.jupiter.api.Test;

import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertNotNull;
import static org.junit.jupiter.api.Assertions.assertTrue;

/**
 * The aggregator factory has to survive the trip from the broker to the
 * data nodes: the broker serialises it into the native query and the
 * historical deserialises it back.
 *
 * <p>That round trip is easy to get wrong in ways that only show up as a
 * confusing failure on the historical ("Cannot construct instance of
 * TopNQuery"), so it is tested directly here.
 */
public class AggregatorFactoryJsonTest {

    /**
     * Druid's own mapper, plus our extension module.
     *
     * <p>Using {@code DefaultObjectMapper} rather than a hand-built
     * {@code ObjectMapper} matters: Druid's mapper serialises by FIELD
     * with getter visibility switched off, and it applies the
     * {@code AggregatorFactoryMixin} that supplies the polymorphic
     * "type" discriminator. Reconstructing that configuration by hand
     * proved nothing -- the first version of this test passed while the
     * real round trip failed -- so the ground truth is used here.
     */
    private static ObjectMapper mapper()
    {
        // INSTANCE.copy() rather than new DefaultObjectMapper(): the
        // shared INSTANCE is the mapper Druid actually injects, with all
        // of its modules and mixins applied. copy() so registering our
        // module does not mutate global state.
        final ObjectMapper mapper = org.apache.druid.jackson.DefaultObjectMapper.INSTANCE.copy();
        final SimpleModule module = new SimpleModule("fractalsql-druid")
                .registerSubtypes(new NamedType(
                        FractalSearchAggregatorFactory.class,
                        FractalSearchAggregatorFactory.TYPE));
        mapper.registerModule(module);
        return mapper;
    }

    @Test
    void factoryRoundTripsThroughJson()
            throws Exception
    {
        final double[] refined = {0.5, 0.25, -0.75};
        final FractalSearchAggregatorFactory original =
                new FractalSearchAggregatorFactory("d", "emb", refined);

        final String json = mapper().writeValueAsString(original);
        System.out.println("aggregator factory JSON: " + json);

        final FractalSearchAggregatorFactory back =
                mapper().readValue(json, FractalSearchAggregatorFactory.class);

        assertNotNull(back.getName(), "the name must survive the round trip");
        assertEquals("d", back.getName());
        assertNotNull(back.getColumnName(), "the column name must survive the round trip");
        assertEquals("emb", back.getColumnName());
        assertNotNull(back.getRefinedQuery(), "the refined query must survive the round trip");
        assertEquals(3, back.getRefinedQuery().length);
        assertEquals(0.5, back.getRefinedQuery()[0], 1e-12);
        assertEquals(-0.75, back.getRefinedQuery()[2], 1e-12);
        assertEquals(original, back);
    }

    @Test
    void aNullNameNeverEscapes()
            throws Exception
    {
        // A null name makes the historical fail to deserialise the whole
        // query, so the constructor has to substitute one.
        final FractalSearchAggregatorFactory factory =
                new FractalSearchAggregatorFactory(null, "emb", new double[]{1.0});
        assertNotNull(factory.getName());
        assertTrue(!factory.getName().isEmpty());
    }
}
