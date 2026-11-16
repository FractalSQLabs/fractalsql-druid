-- demo/enterprise-stress.sql
--
-- Enterprise Tier -- the QTL Ledger under stress, and its tamper-evidence.
--
-- Companion to enterprise-qtl-audit.sql (which walks the surface one
-- call at a time). This kit hammers the same surface: it fills the
-- truth and shadow ledgers to their capacity bound (64 each, 128
-- events in all), round-trips them through the QTL encode -> chain
-- -> decode path, churns flush/load cycles at capacity, and walks the
-- append-only chain.
--
-- Prerequisites:
--   * the extension is loaded on the Druid cluster;
--   * the FractalSQL Enterprise core is installed on the node
--     (druid.fractalsql.enterprise_lib) with its .sig sidecar beside
--     it. Without it the tier is dormant and the gated calls below
--     report that the tier is not loaded.
--
-- Run:
--   python3 demo/run_demo.py --file demo/enterprise-stress.sql
--
-- ===========================================================================
-- Notes on how this runs on Druid
-- ===========================================================================
--
--   * The events are generated in ONE statement each, not one
--     statement per event: Druid has no procedural loop, so the
--     64 events of a batch come from an explicit array unnested into
--     the function. Note the absence of a CAST -- Druid 38's planner
--     rewrites a one-argument CAST into a broken two-argument form
--     ("Function[cast] requires 2 arguments"), so the array's
--     elements are used as they are.
--   * The chain is the extension's file-backed chain, not a table in a
--     database: the tamper-evidence probes that need to corrupt the
--     persisted bytes are therefore not SQL, and they live in the
--     gate suite (build_test.sh's gate 16), which can reach the
--     node's file. What this kit can show from SQL is the same
--     tamper-evidence the chain is built on: the audit log decodes
--     exactly what was sealed, and the full-chain walk verifies.
--   * The ledger is per node. In production the real ledger is in
--     the daemon, one file per daemon; this is the same shape and
--     the same guarantees, one node.
--
-- Safe to re-run: the ledger is reset at the start of the run.

-- ---------------------------------------------------------------------------
-- 0. Sanity check, and a clean slate.
-- ---------------------------------------------------------------------------
SELECT fractal_edition(), fractal_version();
-- @call ledger {"action": "status"};

SELECT fractal_ledger_reset_hard() AS "dropped";

-- The documented precondition for engagement recording.
SELECT fractal_diversify_enable();

-- ---------------------------------------------------------------------------
-- 1. Fill the ledgers to their capacity bound.
-- ---------------------------------------------------------------------------
-- 64 truth events (positive reinforcement) and 64 shadow events
-- (explicit rejection). The doc_ids are disjoint so nothing is
-- resolved between the two ledgers.
SELECT fractal_feedback_report(g, 'positive', 500) AS "event"
  FROM UNNEST(ARRAY[1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16, 17, 18, 19, 20, 21, 22, 23, 24, 25, 26, 27, 28, 29, 30, 31, 32, 33, 34, 35, 36, 37, 38, 39, 40, 41, 42, 43, 44, 45, 46, 47, 48, 49, 50, 51, 52, 53, 54, 55, 56, 57, 58, 59, 60, 61, 62, 63, 64]) AS t(g);
SELECT fractal_feedback_report(g, 'negative', 0) AS "event"
  FROM UNNEST(ARRAY[1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16, 17, 18, 19, 20, 21, 22, 23, 24, 25, 26, 27, 28, 29, 30, 31, 32, 33, 34, 35, 36, 37, 38, 39, 40, 41, 42, 43, 44, 45, 46, 47, 48, 49, 50, 51, 52, 53, 54, 55, 56, 57, 58, 59, 60, 61, 62, 63, 64]) AS t(g);

-- 64 + 64 = 128 events in all.
SELECT fractal_ledger_truth_count() AS "truth_count",
       fractal_ledger_shadow_count() AS "shadow_count";

-- ---------------------------------------------------------------------------
-- 2. The churn: seal, rehydrate, compact.
-- ---------------------------------------------------------------------------
-- Each flush writes ONE record -- the enterprise core encodes the
-- union of the truth and the shadow ledgers into a single QTL blob --
-- so the chain grows by one record per flush however many events the
-- blob holds.
SELECT fractal_ledger_flush() AS "sealed";
SELECT fractal_ledger_load() AS "loaded";
SELECT fractal_ledger_compact() AS "records";

-- The chain verifies: every MAC matches, and every record carries the
-- hash of the record before it. This one is not gated -- it reads the extension's own chain file, so it answers on a Community deployment too.
SELECT fractal_ledger_verify() AS "verified";

-- ---------------------------------------------------------------------------
-- 3. The audit log holds every event that was sealed.
-- ---------------------------------------------------------------------------
-- The enterprise core's own decoder, over the blob the flush wrote.
SELECT fractal_audit_unpack('') AS "audit_log";

-- ---------------------------------------------------------------------------
-- 4. The resets.
-- ---------------------------------------------------------------------------
-- Soft: the Shadow goes, the Truth stays.
SELECT fractal_ledger_reset_soft() AS "dropped";
SELECT fractal_ledger_truth_count() AS "truth_count",
       fractal_ledger_shadow_count() AS "shadow_count";

-- Hard: both go.
SELECT fractal_ledger_reset_hard() AS "dropped";
SELECT fractal_ledger_truth_count() AS "truth_count",
       fractal_ledger_shadow_count() AS "shadow_count";

-- ---------------------------------------------------------------------------
-- The headline.
-- ---------------------------------------------------------------------------
-- The kit passes when the chain verified and the audit log still
-- decodes to the 128 events the flush sealed.
-- ---------------------------------------------------------------------------
SELECT CASE
           WHEN fractal_ledger_verify() LIKE '%"ok":true%'
            AND LENGTH(fractal_audit_unpack('')) > 1000
            THEN 'HEADLINE kit=enterprise-stress ok'
            ELSE 'HEADLINE kit=enterprise-stress FAILED'
       END AS "headline";
