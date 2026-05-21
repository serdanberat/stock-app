-- ============================================================================
-- 023_phase_3f_refinements.sql
-- Phase 3.F — Refinement patches applied at Phase 4 kickoff
--
-- Applies:
--   - 3.F.1 cash_movements: CLOSING_DEPOSIT semantics clarified
--     (no schema change; documentation in comment)
--   - 3.F.4 operation-start snapshot columns:
--     - sales: discount_threshold_snapshot, cart_discount_limit_snapshot,
--              line_discount_limit_snapshot
--     - returns: window_snapshot
--     - adjustments: large_threshold_snapshot
--     - cash_register_sessions: variance_tolerance_snapshot,
--              variance_large_threshold_snapshot
--
-- 3.F.2 (Z report PDF byte-determinism), 3.F.3 (role union semantics),
-- 3.F.5 (refresh cache bypass), 3.F.6 (5-year retention), 3.F.7
-- (STORE_MANAGER edit allowlist), 3.F.8 (PII masking) are implementation/
-- documentation-level concerns with no schema changes.
-- ============================================================================

BEGIN;

-- ---------------------------------------------------------------------------
-- 1. sales: discount policy snapshots
-- ---------------------------------------------------------------------------

ALTER TABLE sales
    ADD COLUMN IF NOT EXISTS discount_threshold_snapshot NUMERIC(5, 2),
                            -- snapshot of tenant.requires_reason_above_pct at DRAFT creation
    ADD COLUMN IF NOT EXISTS cart_discount_limit_snapshot NUMERIC(5, 2),
                            -- snapshot of tenant.max_cart_discount_pct_default
    ADD COLUMN IF NOT EXISTS line_discount_limit_snapshot NUMERIC(5, 2);
                            -- snapshot of tenant.max_line_discount_pct_default

COMMENT ON COLUMN sales.discount_threshold_snapshot IS
    '3.F.4 operation-start snapshot. Captures tenant.requires_reason_above_pct '
    'at Sale DRAFT creation. Mid-sale policy changes do not affect this draft.';

COMMENT ON COLUMN sales.cart_discount_limit_snapshot IS
    '3.F.4 operation-start snapshot. Captures tenant.max_cart_discount_pct_default '
    'at DRAFT creation.';

COMMENT ON COLUMN sales.line_discount_limit_snapshot IS
    '3.F.4 operation-start snapshot. Captures tenant.max_line_discount_pct_default '
    'at DRAFT creation.';

-- Backfill existing DRAFT sales with current tenant settings (best effort)
-- COMMITTED sales: no need to backfill (operation already complete)
UPDATE sales s
SET discount_threshold_snapshot = COALESCE(
        (SELECT (settings->>'requires_reason_above_pct')::NUMERIC
         FROM tenants WHERE id = s.tenant_id),
        10.00
    ),
    cart_discount_limit_snapshot = COALESCE(
        (SELECT (settings->>'max_cart_discount_pct_default')::NUMERIC
         FROM tenants WHERE id = s.tenant_id),
        30.00
    ),
    line_discount_limit_snapshot = COALESCE(
        (SELECT (settings->>'max_line_discount_pct_default')::NUMERIC
         FROM tenants WHERE id = s.tenant_id),
        30.00
    )
WHERE s.status = 'DRAFT'
  AND s.discount_threshold_snapshot IS NULL;

-- ---------------------------------------------------------------------------
-- 2. returns: window snapshot
-- ---------------------------------------------------------------------------

ALTER TABLE returns
    ADD COLUMN IF NOT EXISTS window_snapshot INT;
                            -- snapshot of tenant.return_window_days at initiate()

COMMENT ON COLUMN returns.window_snapshot IS
    '3.F.4 operation-start snapshot. Captures tenant.return_window_days at '
    'Return.initiate(). Determines whether outside-window override is needed.';

-- Backfill: existing DRAFT returns get current tenant setting
UPDATE returns r
SET window_snapshot = COALESCE(
        (SELECT (settings->>'return_window_days')::INT
         FROM tenants WHERE id = r.tenant_id),
        30
    )
WHERE r.status = 'DRAFT'
  AND r.window_snapshot IS NULL;

-- ---------------------------------------------------------------------------
-- 3. adjustments: large threshold snapshot
-- ---------------------------------------------------------------------------

ALTER TABLE adjustments
    ADD COLUMN IF NOT EXISTS large_threshold_snapshot NUMERIC(12, 3);
                            -- snapshot of tenant.adjustment_large_threshold at create()

COMMENT ON COLUMN adjustments.large_threshold_snapshot IS
    '3.F.4 operation-start snapshot. Captures tenant.adjustment_large_threshold '
    'at Adjustment.create(). is_large_adjustment flag is computed against this snapshot.';

-- Adjustments are single-shot immutable; no DRAFT backfill needed
-- For existing rows, snapshot from creation-time tenant setting (best effort:
-- current value if no historical lookup)
UPDATE adjustments a
SET large_threshold_snapshot = COALESCE(
        (SELECT (settings->>'adjustment_large_threshold')::NUMERIC
         FROM tenants WHERE id = a.tenant_id),
        50
    )
WHERE a.large_threshold_snapshot IS NULL;

-- ---------------------------------------------------------------------------
-- 4. cash_register_sessions: variance threshold snapshots
-- ---------------------------------------------------------------------------

ALTER TABLE cash_register_sessions
    ADD COLUMN IF NOT EXISTS variance_tolerance_snapshot NUMERIC(14, 2),
                            -- snapshot of tenant.cash_variance_tolerance at open()
    ADD COLUMN IF NOT EXISTS variance_large_threshold_snapshot NUMERIC(14, 2);
                            -- snapshot of tenant.cash_variance_large_threshold at open()

COMMENT ON COLUMN cash_register_sessions.variance_tolerance_snapshot IS
    '3.F.4 operation-start snapshot. Captures tenant.cash_variance_tolerance at '
    'session.open(). Used at close() to determine if variance reason is required.';

COMMENT ON COLUMN cash_register_sessions.variance_large_threshold_snapshot IS
    '3.F.4 operation-start snapshot. Captures tenant.cash_variance_large_threshold '
    'at session.open(). Used at close() to determine if manager PIN override needed.';

-- Backfill OPEN sessions with current tenant settings
UPDATE cash_register_sessions s
SET variance_tolerance_snapshot = COALESCE(
        (SELECT (settings->>'cash_variance_tolerance')::NUMERIC
         FROM tenants WHERE id = s.tenant_id),
        5.00
    ),
    variance_large_threshold_snapshot = COALESCE(
        (SELECT (settings->>'cash_variance_large_threshold')::NUMERIC
         FROM tenants WHERE id = s.tenant_id),
        100.00
    )
WHERE s.status = 'OPEN'
  AND s.variance_tolerance_snapshot IS NULL;

-- For CLOSED sessions, backfill with current tenant settings as a best-effort
-- historical reference (these snapshots are now mandatory for new sessions)
UPDATE cash_register_sessions s
SET variance_tolerance_snapshot = COALESCE(
        (SELECT (settings->>'cash_variance_tolerance')::NUMERIC
         FROM tenants WHERE id = s.tenant_id),
        5.00
    ),
    variance_large_threshold_snapshot = COALESCE(
        (SELECT (settings->>'cash_variance_large_threshold')::NUMERIC
         FROM tenants WHERE id = s.tenant_id),
        100.00
    )
WHERE s.status = 'CLOSED'
  AND s.variance_tolerance_snapshot IS NULL;

-- ---------------------------------------------------------------------------
-- 5. cash_movements: CLOSING_DEPOSIT documentation update
-- ---------------------------------------------------------------------------
-- 3.F.1: cashier-facing semantics is "remaining_float_amount" (kasada bırakılacak).
-- System derives cash_removed = expected_cash - remaining_float and creates
-- CLOSING_DEPOSIT cash_movement for the removed delta.
-- No schema change required; comment update only.

COMMENT ON CONSTRAINT cash_movements_movement_type_check ON cash_movements IS
    'Cash movement types. CLOSING_DEPOSIT = cash removed from drawer at session close. '
    'Per 3.F.1: derived from (expected_cash - remaining_float_amount). Cashier enters '
    'remaining_float (what stays), system computes deposit (what leaves).';

COMMIT;
