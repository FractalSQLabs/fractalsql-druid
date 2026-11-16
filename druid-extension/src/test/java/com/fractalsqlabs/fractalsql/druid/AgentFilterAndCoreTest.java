/*
 * SPDX-License-Identifier: Apache-2.0
 * Copyright 2026 Daniel Gardiner d/b/a FractalSQLabs
 */
package com.fractalsqlabs.fractalsql.druid;

import org.junit.jupiter.api.Test;

import java.util.ArrayList;
import java.util.List;
import java.util.concurrent.atomic.AtomicInteger;

import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertThrows;
import static org.junit.jupiter.api.Assertions.assertTrue;

/** SECURITY_AUDIT.md 3.5 (identifiers and the metadata filter in the agent tier) and 3.4 (the shared core context). */
public class AgentFilterAndCoreTest {

    @Test
    void identifiersAreQuotedWithEmbeddedQuotesDoubled()
    {
        assertEquals("\"t\"", FractalSqlAgents.quoteIdent("t"));
        assertEquals("\"a\"\"b\"", FractalSqlAgents.quoteIdent("a\"b"));
        assertEquals("\"x\"\" FROM secrets --\"", FractalSqlAgents.quoteIdent("x\" FROM secrets --"));
    }

    @Test
    void equalityFilterEscapesBothParts()
    {
        assertEquals("\"region\" = 'eu'", FractalSqlAgents.equalsFilter("region", "eu"));
        assertEquals("\"c\"\"d\" = 'it''s'", FractalSqlAgents.equalsFilter("c\"d", "it's"));
    }

    @Test
    void metaFilterAcceptsOnlyOneEqualityTest()
    {
        assertEquals("\"region\" = 'eu'", FractalSqlAgents.structuredFilter("region = 'eu'"));
        assertEquals("\"region\" = 'eu'", FractalSqlAgents.structuredFilter("\"region\" = 'eu'"));
        assertEquals("\"r\" = 'a''b'", FractalSqlAgents.structuredFilter("r='a''b'"));
        for (String attack : new String[]{
                "1=1 UNION SELECT password FROM sys.credentials --",
                "region = 'eu' OR 1=1",
                "region = 'eu'; DROP TABLE t",
                "region = 'eu' --",
                "region = 'a' UNION SELECT 1",
                "region = 'x' /* c */",
                "region",
                "",
                "\"a\" = 'x' AND \"b\" = 'y'"}) {
            assertThrows(IllegalArgumentException.class, () -> FractalSqlAgents.structuredFilter(attack), attack);
        }
    }

    @Test
    void concurrentContextCallsAreSerialised()
    {
        final FractalSqlCore core = new FractalSqlCore();
        final AtomicInteger inside = new AtomicInteger();
        final AtomicInteger worst = new AtomicInteger();
        final List<Thread> threads = new ArrayList<>();
        for (int t = 0; t < 8; t++) {
            final Thread th = new Thread(() -> {
                for (int i = 0; i < 200; i++) {
                    core.locked(h -> {
                        final int now = inside.incrementAndGet();
                        worst.accumulateAndGet(now, Math::max);
                        Thread.yield();
                        inside.decrementAndGet();
                        return h;
                    });
                }
            });
            threads.add(th);
            th.start();
        }
        threads.forEach(th -> {
            try {
                th.join();
            } catch (InterruptedException e) {
                throw new IllegalStateException(e);
            }
        });
        assertEquals(1, worst.get(), "two threads were inside the core context at once");
        assertTrue(core.handle() != 0);
    }

    @Test
    void sessionIdsAreStableDistinctAndNeverTheNodes()
    {
        assertEquals(FractalSqlDaemon.sessionId("alpha"), FractalSqlDaemon.sessionId("alpha"));
        // "Aa" and "BB" share String.hashCode(); they must not share an id (SECURITY_AUDIT.md 3.23)
        assertEquals("Aa".hashCode(), "BB".hashCode());
        assertTrue(FractalSqlDaemon.sessionId("Aa") != FractalSqlDaemon.sessionId("BB"));
        final java.util.Set<Long> seen = new java.util.HashSet<>();
        for (int i = 0; i < 100000; i++) {
            final long id = FractalSqlDaemon.sessionId("session-" + i);
            assertTrue(id >= 2, "a named session never takes the node's ids");
            assertTrue(seen.add(id), "collision at " + i);
        }
    }

    @Test
    void keyFilePathsAreSecrets()
    {
        assertTrue(FractalSqlConfig.isSecret("druid.fractalsql.daemon_hmac_key_file"));
        assertTrue(FractalSqlConfig.isSecret("hmac_key_file"));
        assertTrue(FractalSqlConfig.isSecret("enterprise_ledger_key"));
        assertTrue(!FractalSqlConfig.isSecret("daemon_socket"));
    }
}
