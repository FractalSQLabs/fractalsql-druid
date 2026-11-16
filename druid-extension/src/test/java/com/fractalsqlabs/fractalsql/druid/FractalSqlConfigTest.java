/*
 * SPDX-License-Identifier: Apache-2.0
 * Copyright 2026 Daniel Gardiner d/b/a FractalSQLabs
 */
package com.fractalsqlabs.fractalsql.druid;

import org.junit.jupiter.api.Test;

import java.util.HashMap;
import java.util.Map;
import java.util.Properties;

import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertFalse;
import static org.junit.jupiter.api.Assertions.assertThrows;
import static org.junit.jupiter.api.Assertions.assertTrue;

/** The extension's own settings: where the daemon is, the search budget, the node posture. */
public class FractalSqlConfigTest {

    private static FractalSqlConfig config(Properties p)
    {
        return new FractalSqlConfig(() -> p);
    }

    @Test
    public void daemonSettingsHaveDefaults()
    {
        final FractalSqlConfig c = config(new Properties());
        assertEquals("/run/fractalsql/fractalsqld.sock", c.operatorValue("daemon_socket"));
        assertEquals("/run/fractalsql/hmac.key", c.operatorValue("daemon_hmac_key_file"));
        assertEquals(300000L, c.operatorLong("daemon_timeout_ms"));
    }

    @Test
    public void anOperatorValueWins()
    {
        final Properties p = new Properties();
        p.setProperty("druid.fractalsql.daemon_socket", "/var/run/other.sock");
        assertEquals("/var/run/other.sock", config(p).operatorValue("daemon_socket"));
    }

    @Test
    public void aRequestCannotRepointTheDaemon()
    {
        final Properties p = new Properties();
        p.setProperty("druid.fractalsql.daemon_socket", "/run/fractalsql/fractalsqld.sock");
        final FractalSqlConfig c = config(p);
        final Map<String, String> context = new HashMap<>();
        context.put("druid.fractalsql.daemon_socket", "/tmp/evil.sock");
        context.put("fractalsql.daemon_hmac_key_file", "/tmp/evil.key");
        assertEquals("/run/fractalsql/fractalsqld.sock", c.effectiveValue("daemon_socket", context));
        assertEquals("/run/fractalsql/hmac.key", c.effectiveValue("daemon_hmac_key_file", context));
        assertTrue(c.refusedOverrides().contains("daemon_socket"));
        assertTrue(c.refusedOverrides().contains("daemon_hmac_key_file"));
    }

    @Test
    public void theSearchBudgetIsTheOperators()
    {
        final FractalSqlConfig c = config(new Properties());
        final Map<String, String> context = new HashMap<>();
        context.put("fractalsql.search.population_size", "100000");
        assertEquals("50", c.effectiveValue("search.population_size", context));
        assertTrue(c.refusedOverrides().contains("search.population_size"));
    }

    @Test
    public void everyKeyIsOperatorOnlyAndHasAReason()
    {
        assertTrue(FractalSqlConfig.requestOverridableKeys().isEmpty());
        for (FractalSqlConfig.Key k : FractalSqlConfig.keys().values()) {
            assertFalse(k.reason().isEmpty(), k.name());
        }
    }

    @Test
    public void theReasoningSettingsAreNotTheExtensions()
    {
        for (String gone : new String[] {"reasoning.url", "reasoning.token", "embed.url", "think.level",
            "text_to_sql.max_attempts", "enterprise_lib", "enterprise_ledger_key"}) {
            assertFalse(FractalSqlConfig.keys().containsKey(gone), gone);
            assertThrows(IllegalArgumentException.class, () -> config(new Properties()).operatorValue(gone));
        }
    }

    @Test
    public void searchParametersAreADocument()
    {
        final String json = config(new Properties()).searchParamsJson();
        assertTrue(json.contains("\"population_size\":50"));
        assertTrue(json.contains("\"max_generation\":30"));
    }

    @Test
    public void describeNamesTheSettingsInUse()
    {
        final Properties p = new Properties();
        p.setProperty("druid.fractalsql.daemon_socket", "/run/x.sock");
        final Map<String, String> described = config(p).describe();
        assertEquals("/run/x.sock", described.get("daemon_socket"));
    }
}
