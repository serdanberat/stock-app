-- ============================================================================
-- Migration 017: Jobs extensions (Phase 6.F)
-- ============================================================================
-- Adds:
--   - shedlock: scheduler distributed lock table
--
-- ShedLock 6.x with usingDbTime() configuration uses PostgreSQL clock,
-- not JVM clock. Critical for multi-instance correctness.
--
-- System-level table (no tenant scope, no RLS).
-- ============================================================================

CREATE TABLE shedlock (
    name        VARCHAR(64) PRIMARY KEY,
    lock_until  TIMESTAMPTZ NOT NULL,
    locked_at   TIMESTAMPTZ NOT NULL,
    locked_by   VARCHAR(255) NOT NULL
);

COMMENT ON TABLE shedlock IS
    'ShedLock distributed scheduler locks. System-level, no tenant scope, no RLS. '
    'One row per scheduled task. lock_until controls timeout; locked_by identifies the holder.';
COMMENT ON COLUMN shedlock.name IS
    'Unique scheduler task name. Examples: outbox-dispatcher, sale-document-worker, '
    'fx-tcmb-ingestion, stuck-job-detector.';
