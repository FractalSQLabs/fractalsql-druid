/*
 * SPDX-License-Identifier: Apache-2.0
 * Copyright 2026 Daniel Gardiner d/b/a FractalSQLabs
 */
package com.fractalsqlabs.fractalsql.druid;

import org.junit.jupiter.api.AfterEach;
import org.junit.jupiter.api.BeforeEach;
import org.junit.jupiter.api.Test;

import java.nio.file.Files;
import java.util.Properties;

import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertFalse;
import static org.junit.jupiter.api.Assertions.assertNotNull;
import static org.junit.jupiter.api.Assertions.assertNull;
import static org.junit.jupiter.api.Assertions.assertThrows;
import static org.junit.jupiter.api.Assertions.assertTrue;

/**
 * The extension's side of the enterprise tier, against a stand-in daemon that can answer anything: a count, a document that is
 * not one, NULL, a refusal from the core ("the library is not loaded") or from the protocol.
 */
public class EnterpriseTierTest {

    private FakeDaemon fake;
    private FractalSqlEnterprise ent;
    private Properties props;

    private void start(String... extra) throws Exception
    {
        fake = new FakeDaemon(Files.createTempDirectory("fsql-ent"));
        props = new Properties();
        props.setProperty("druid.fractalsql.daemon_socket", fake.socket.toString());
        props.setProperty("druid.fractalsql.daemon_hmac_key_file", fake.keyFile.toString());
        props.setProperty("druid.fractalsql.daemon_timeout_ms", "5000");
        // the destructive operations are off unless an operator enables them: these tests exercise them
        props.setProperty("druid.fractalsql.ledger.allow_destructive", "true");
        for (int i = 0; i + 1 < extra.length; i += 2) {
            props.setProperty(extra[i], extra[i + 1]);
        }
        final FractalSqlConfig config = new FractalSqlConfig(() -> props);
        ent = new FractalSqlEnterprise(config, new FractalSqlDaemon(config));
    }

    @BeforeEach
    void before() throws Exception
    {
        start();
    }

    @AfterEach
    void after() throws Exception
    {
        fake.close();
    }

    private static final double[] MU = {0.1, 0.2, 0.3};
    private static final double[] COV = {1, 0, 0, 0, 1, 0, 0, 0, 1};

    @Test
    void theCountsAndTheChain()
    {
        assertTrue(ent.loaded());
        fake.forcedInt = 7L;
        assertEquals(7, ent.truthCount());
        assertEquals(7, ent.shadowCount());
        assertEquals(14, ent.flush());
        assertEquals(14, ent.load());
        assertEquals(7, ent.resetSoft());
        assertEquals(14, ent.resetHard());

        fake.forcedInt = null;
        fake.forced = "{\"ok\":true,\"rows_verified\":12}";
        assertEquals(12, ent.recordCount(1));
        assertEquals(12, ent.compact());
        assertEquals(fake.forced, ent.verify());
        assertEquals(fake.forced, ent.verify(2));
        fake.forced = "{\"ok\":true}";
        assertEquals(0, ent.recordCount(1));
        fake.forced = "{\"ok\":true,\"rows_verified\":}";
        assertEquals(0, ent.recordCount(1));
        fake.forced = null;

        ent.auditLog("decision", "{\"a\":1}");
        ent.feedback(3, "click", 12.9);
        assertEquals("Community", ent.status().get("edition"));
        assertEquals(true, ent.status().get("loaded"));
        assertNotNull(ent.libraryPath());
        assertNotNull(ent.ledgerPath());
    }

    @Test
    void aNullAnswerFromTheCore()
    {
        fake.nullReply = true;
        assertThrows(IllegalStateException.class, () -> ent.auditUnpack(""));
        assertTrue(assertThrows(IllegalStateException.class, () -> ent.auditUnpack("   "))
                .getMessage().contains("no sealed blob"));
        assertTrue(assertThrows(IllegalStateException.class, () -> ent.auditUnpack("abc"))
                .getMessage().contains("could not be decoded"));
        assertThrows(IllegalArgumentException.class, () -> ent.auditUnpack(null));
        // the portfolio search answers NULL while the library IS loaded: that is a NULL result, not a dormant tier
        assertNull(ent.portfolioMultimodal(MU, COV, 2, 4, 0.1, 0.9, 1L));
        assertNull(ent.portfolioMultimodalEx(MU, COV, 2, 4, 0.1, 0.9, 1L, true, 1));
        assertNull(ent.portfolioMultimodalPareto(MU, COV, 2, 4, 2, 1L, false, 0));
        assertEquals("{\"ok\":false,\"first_failure_id\":0,\"reason\":\"the ledger could not be read\"}", ent.verify());
        assertNull(ent.libraryPath());
        assertNull(ent.status().get("library"));
    }

    @Test
    void aDormantTier()
    {
        fake.replyStatus = FsqClient.ERR_CORE;
        assertFalse(ent.loaded());
        for (java.util.concurrent.Callable<Object> c : new java.util.concurrent.Callable[]{
            () -> ent.flush(), () -> ent.load(), () -> ent.compact(), () -> ent.resetSoft(), () -> ent.resetHard(),
            () -> ent.truthCount(), () -> ent.shadowCount(), () -> ent.auditUnpack("abc"),
            () -> ent.portfolioMultimodal(MU, COV, 2, 4, 0.1, 0.9, 1L),
            () -> ent.portfolioMultimodalEx(MU, COV, 2, 4, 0.1, 0.9, 1L, false, 0),
            () -> ent.portfolioMultimodalPareto(MU, COV, 2, 4, 2, 1L, true, 1)}) {
            final IllegalStateException e = assertThrows(IllegalStateException.class, c::call);
            assertTrue(e.getMessage().contains("enterprise") || e.getMessage().contains("not loaded")
                    || e.getMessage().contains("not available"), e.getMessage());
        }
        assertEquals(false, ent.status().get("loaded"));
        // the posture latch holds even when the daemon refuses the latch call
        assertTrue(ent.lockDestructive());
        assertFalse(ent.lockDestructive());
        assertTrue(ent.destructiveLocked());
    }

    @Test
    void aRefusedCall()
    {
        fake.replyStatus = FsqClient.ERR_ARGS;
        final IllegalStateException e = assertThrows(IllegalStateException.class, () -> ent.truthCount());
        assertTrue(e.getMessage().contains("failed"), e.getMessage());
        assertThrows(IllegalStateException.class, () -> ent.auditLog("t", "{}"));
        assertThrows(IllegalStateException.class, () -> ent.feedback(1, "k", 1));
        fake.replyStatus = FsqClient.ERR_BUSY;
        assertThrows(IllegalStateException.class, () -> ent.truthCount());
    }

    @Test
    void theLatchRefusesTheDestructiveCalls()
    {
        assertTrue(ent.lockDestructive());
        for (java.util.concurrent.Callable<Object> c : new java.util.concurrent.Callable[]{
            () -> ent.flush(), () -> ent.compact(), () -> ent.resetSoft(), () -> ent.resetHard(),
            () -> {
                ent.auditLog("t", "{}");
                return null;
            }}) {
            assertTrue(assertThrows(IllegalStateException.class, c::call).getMessage().contains("locked"));
        }
        // the read paths still work
        fake.forcedInt = 1L;
        assertEquals(1, ent.truthCount());
        assertEquals(2, ent.load());
    }

    @Test
    void theReadOnlyPostureLatchesOnFirstUse() throws Exception
    {
        fake.close();
        start("druid.fractalsql.ledger.read_only", "true");
        assertFalse(ent.destructiveLocked());
        assertThrows(IllegalStateException.class, () -> ent.flush());
        assertTrue(ent.destructiveLocked());
    }

    @Test
    void aDaemonThatIsGone()
    {
        fake.fail = true;
        assertFalse(ent.loaded());
        assertThrows(IllegalStateException.class, () -> ent.truthCount());
        assertEquals("{\"ok\":false,\"first_failure_id\":0,\"reason\":\"the ledger could not be read\"}", ent.verify());
    }

    @Test
    void destructiveOperationsAreOffUnlessAnOperatorEnablesThem() throws Exception
    {
        start("druid.fractalsql.ledger.allow_destructive", "false");
        for (java.util.concurrent.Callable<Object> c : new java.util.concurrent.Callable[]{
            () -> ent.compact(), () -> ent.resetSoft(), () -> ent.resetHard()}) {
            final IllegalStateException e = assertThrows(IllegalStateException.class, c::call);
            assertTrue(e.getMessage().contains("allow_destructive"), e.getMessage());
        }
        // refused before the daemon was asked anything
    }

    @Test
    void theDefaultIsOff() throws Exception
    {
        start();
        props.remove("druid.fractalsql.ledger.allow_destructive");
        final FractalSqlConfig config = new FractalSqlConfig(() -> props);
        final FractalSqlEnterprise fresh = new FractalSqlEnterprise(config, new FractalSqlDaemon(config));
        assertThrows(IllegalStateException.class, fresh::resetHard);
    }
}
