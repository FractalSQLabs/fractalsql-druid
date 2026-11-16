-- demo/enterprise-qtl-audit.sql
--
-- The enterprise tier: the QTL ledger and the CISO audit.
--
--   1. Report real engagement events into the core's Truth/Shadow
--      ledgers.
--   2. Seal them into the chain, read the audit log back, verify the
--      chain, and reset the ledgers.
--
-- Prerequisites:
--   * the extension is loaded on the Druid cluster;
--   * the FractalSQL Enterprise core is installed on the node
--     (druid.fractalsql.enterprise_lib) and its .sig sidecar sits
--     beside it. Without it the tier is dormant and the gated calls
--     below report that the tier is not loaded.
--
-- The ledger itself does not need a reasoning provider.
--
-- Run:
--   python3 demo/run_demo.py --file demo/enterprise-qtl-audit.sql
--
-- ===========================================================================
-- Notes on how this runs on Druid
-- ===========================================================================
--
--   * The ledger is the ENTERPRISE CORE's, not the extension's. The
--     core's archive carries no ledger symbols at all -- they are
--     enterprise-gated -- so the tier is the separately licensed
--     FractalSQL Enterprise core, loaded at run time after its
--     detached Ed25519 signature has been verified against a fixed
--     FractalSQLabs public key. This is the same drop-in mechanism
--     the other FractalSQL engines use.
--   * The chain is the node's own file and its own hash
--     chain: each record carries the epoch, the document, the signal
--     and a MAC over the record and the one before it, so an edited
--     or removed record breaks every MAC after it. The core owns the
--     QTL blob (the truth/shadow encoding) and the semantics; the
--     port owns the persistence, the chain and the verification.
--   * The audit log is decoded by the CORE: fractal_audit_unpack
--     calls the enterprise core's own unpacker over the blob the
--     flush wrote. An empty argument means "the last thing the
--     ledger sealed".
--   * fractal_ledger_verify is NOT gated. It reads the extension's own
--     chain file rather than the core's, so an auditor can check the
--     chain on a Community deployment too.
--   * The ledger is per NODE here. In production the real ledger is
--     in the daemon, one file per daemon; this is the same shape and
--     the same guarantees, one node. The calls below run on the
--     broker.
--
-- Safe to re-run: the ledger is reset at the start of the run.

-- ---------------------------------------------------------------------------
-- 0. Is the enterprise tier live?
-- ---------------------------------------------------------------------------
-- fractal_edition is the core the extension LINKS -- the community
-- archive. The tier's own state is the service endpoint below: which
-- library it loaded, and the chain file it writes.
SELECT fractal_edition(), fractal_version();
-- @call ledger {"action": "status"};

-- ---------------------------------------------------------------------------
-- 1. Seed real engagement events into the Truth/Shadow ledgers.
-- ---------------------------------------------------------------------------
-- fractal_feedback_report records search engagement (dwell / positive
-- -> Truth, negative -> Shadow) into the core's ledgers. Those are
-- what the flush seals, so an event that never reaches the core can
-- never be in the chain.
--
-- Start from a clean ledger.
SELECT fractal_ledger_reset_hard() AS "dropped";

-- Enable the diversify/repulsion path, so the documented precondition
-- for engagement recording is met.
SELECT fractal_diversify_enable();

-- Two Truth events (positive + dwell) and two Shadow events (negative).
-- The first argument is the corpus row the event refers to.
SELECT fractal_feedback_report(1, 'positive', 500);
SELECT fractal_feedback_report(2, 'dwell', 1200);
SELECT fractal_feedback_report(3, 'negative', 0);
SELECT fractal_feedback_report(4, 'negative', 0);

-- What the core holds, before it is sealed.
SELECT fractal_ledger_truth_count() AS "truth_count",
       fractal_ledger_shadow_count() AS "shadow_count";

-- ---------------------------------------------------------------------------
-- 2. The ledger + the CISO audit.
-- ---------------------------------------------------------------------------
-- Phase A: flush -- the engagement events are sealed into the chain as
-- one QTL blob, and the chain grows by one record.
SELECT fractal_ledger_flush() AS "sealed";

-- Phase B: the audit -- the blob, decoded by the enterprise core into
-- its CISO event log: one {"epoch","doc_id","signal"} object per
-- entry, the truth entries first.
SELECT fractal_audit_unpack('') AS "audit_log";

-- Phase C: load -- rehydrate the ledgers from the persisted chain.
SELECT fractal_ledger_load() AS "loaded";

-- Phase D: compact -- re-pack the chain.
SELECT fractal_ledger_compact() AS "records";

-- Phase E: reset_soft -- the Shadow goes, the Truth stays.
SELECT fractal_ledger_reset_soft() AS "dropped";
SELECT fractal_ledger_truth_count() AS "truth_count",
       fractal_ledger_shadow_count() AS "shadow_count";

-- The chain verifies: every MAC matches, and every record carries the
-- hash of the record before it. This one is not gated -- it reads the extension's own chain file, so it answers on a Community deployment too.
SELECT fractal_ledger_verify() AS "verified";

-- Phase F: reset_hard -- both go.
SELECT fractal_ledger_reset_hard() AS "dropped";
SELECT fractal_ledger_truth_count() AS "truth_count",
       fractal_ledger_shadow_count() AS "shadow_count";

-- ---------------------------------------------------------------------------
-- The headline.
-- ---------------------------------------------------------------------------
-- The kit passes when the chain verifies AND the enterprise core's own
-- decoder still reads back the blob the flush wrote, with both a
-- truth and a shadow entry in it. The audit log is re-read here
-- rather than captured earlier, because it is decoded from the
-- chain's latest record -- and the resets above clear the core's
-- in-memory ledgers, not the chain.
-- ---------------------------------------------------------------------------
SELECT CASE
           WHEN fractal_ledger_verify() LIKE '%"ok":true%'
            AND fractal_audit_unpack('') LIKE '%"signal":"truth"%'
            AND fractal_audit_unpack('') LIKE '%"signal":"shadow"%'
            THEN 'HEADLINE kit=enterprise-qtl-audit ok'
            ELSE 'HEADLINE kit=enterprise-qtl-audit FAILED'
       END AS "headline";
