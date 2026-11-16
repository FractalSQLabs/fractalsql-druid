/*
 * SPDX-License-Identifier: Apache-2.0
 * Copyright 2026 Daniel Gardiner d/b/a FractalSQLabs
 */
package com.fractalsqlabs.fractalsql.druid;

import org.junit.jupiter.api.Test;

import java.util.Properties;

import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertFalse;
import static org.junit.jupiter.api.Assertions.assertNull;
import static org.junit.jupiter.api.Assertions.assertTrue;

/** agent_use_index: off by default, an operator key, and the exact scan whenever no index can answer. */
public class AgentUseIndexTest {

    private static FractalSqlService service(String value) throws Exception
    {
        final Properties props = new Properties();
        if (value != null) {
            props.setProperty("druid.fractalsql.agent_use_index", value);
        }
        final FractalSqlConfig config = new FractalSqlConfig(() -> props);
        return new FractalSqlService(config, new ReasoningBridge(new FractalSqlDaemon(config)), () -> props);
    }

    @Test
    public void theKeyIsOffByDefault() throws Exception
    {
        assertFalse(service(null).agentUseIndex());
        assertEquals("off", new FractalSqlConfig(Properties::new).operatorValue("agent_use_index"));
    }

    @Test
    public void theOperatorCanTurnItOn() throws Exception
    {
        assertTrue(service("true").agentUseIndex());
        assertFalse(service("false").agentUseIndex());
    }

    @Test
    public void theKeyTakesOffOnAndAuto() throws Exception
    {
        assertEquals(0, service("off").agentUseIndexMode());
        assertEquals(1, service("on").agentUseIndexMode());
        assertEquals(2, service("auto").agentUseIndexMode());
        assertEquals(1, service("true").agentUseIndexMode());
        assertEquals(0, service("false").agentUseIndexMode());
        assertEquals(10000, service(null).agentIndexMinRows());
    }

    @Test
    public void autoNeverUsesAnIndexThatDoesNotExist() throws Exception
    {
        final FractalSqlService s = service("auto");
        assertFalse(new FractalSqlIndex(s, null).readyForAuto("caps", "emb", 5));
        assertNull(FractalSqlAgents.nearestViaIndex(s, new FractalSqlIndex(s, null), "caps", "emb", "id", new double[]{1, 0}));
    }

    @Test
    public void aRequestCannotTurnItOn()
    {
        assertFalse(FractalSqlConfig.keys().get("agent_use_index").isRequestOverridable());
    }

    @Test
    public void withTheSettingOffTheAgentsNeverUseAnIndex() throws Exception
    {
        final FractalSqlService s = service(null);
        assertNull(FractalSqlAgents.nearestViaIndex(s, new FractalSqlIndex(s, null), "caps", "emb", "id", new double[]{1, 0}));
    }

    @Test
    public void withTheSettingOnAndNoIndexTheAgentsScanExactly() throws Exception
    {
        final FractalSqlService s = service("true");
        assertNull(FractalSqlAgents.nearestViaIndex(s, new FractalSqlIndex(s, null), "caps", "emb", "id", new double[]{1, 0}));
        assertNull(FractalSqlAgents.nearestViaIndex(s, null, "caps", "emb", "id", new double[]{1, 0}));
    }

    @Test
    public void theTopKPathAnswersNullWithoutAnIndexInEveryMode() throws Exception
    {
        for (String mode : new String[]{null, "on", "auto"}) {
            final FractalSqlService s = service(mode);
            assertNull(FractalSqlAgents.topViaIndex(s, new FractalSqlIndex(s, null), "caps", "emb", null, new double[]{1, 0}, 5));
            assertNull(FractalSqlAgents.topViaIndex(s, null, "caps", "emb", null, new double[]{1, 0}, 5));
        }
    }

    /** The calibration a build stores (an estimate from a sample) is read back into the entry and decides nprobe and the auto gate. */
    @Test
    public void aStoredCalibrationSetsTheDefaultNprobeAndTheTargetFlag() throws Exception
    {
        final FractalSqlService s = service("auto");
        final FractalSqlIndex ix = new FractalSqlIndex(s, null);
        final java.lang.reflect.Method apply = FractalSqlIndex.class.getDeclaredMethod("applyCalibration", FractalSqlIndex.Entry.class, String.class);
        apply.setAccessible(true);
        final FractalSqlIndex.Entry e = new FractalSqlIndex.Entry("n", "t", "c", "id", "n_cells", "column", 1L);
        apply.invoke(ix, e, "{\"samples\":200,\"k\":10,\"target\":0.95,\"estimates\":[],\"recommended_nprobe\":6,\"reaches_target\":true}");
        assertEquals(6, e.nprobeDefault);
        assertEquals(Boolean.TRUE, e.reachesTarget);
        apply.invoke(ix, e, "{\"recommended_nprobe\":16,\"reaches_target\":false}");
        assertEquals(16, e.nprobeDefault);
        assertEquals(Boolean.FALSE, e.reachesTarget);
        // the hex form the meta row stores
        final String hexed = String.format("%x", new java.math.BigInteger(1, "{\"recommended_nprobe\":5,\"reaches_target\":true}".getBytes(java.nio.charset.StandardCharsets.UTF_8)));
        apply.invoke(ix, e, hexed);
        assertEquals(5, e.nprobeDefault);
        assertEquals(Boolean.TRUE, e.reachesTarget);
        for (String none : new String[]{null, "", "null", "{}", "not json"}) {
            apply.invoke(ix, e, none);
            assertEquals(8, e.nprobeDefault);
            assertNull(e.reachesTarget);
            assertNull(e.calib);
        }
    }
}
