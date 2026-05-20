-- ============================================================================
-- Migration 018: POS extensions (Phase 3.A)
-- ============================================================================
-- Adds schema for:
--   - client-generated cart IDs (idempotent replay, crash recovery)
--   - parked sales (F4 hold feature)
--   - sale_items capture (original price + override + price source)
--   - manager PIN infrastructure (separate from user password)
--   - pos_scan_attempts audit (every barcode scan tracked)
--   - manager_pin_attempts audit (lockout source of truth)
--   - extended tender cancellation states (CANCELLED_BY_CASHIER/MANAGER)
--   - extended cash movement types (SALE_CASH_IN, SALE_CHANGE_OUT, etc.)
--
-- Related Phase 3.A locks: 3.A.1 through 3.A.7
-- Related ADRs: ADR-003 (append-only), ADR-006 (idempotency), ADR-014 (auth)
-- ============================================================================

-- ----------------------------------------------------------------------------
-- 1. Sales: client_cart_id + parked_at
-- ----------------------------------------------------------------------------

ALTER TABLE sales
    ADD COLUMN client_cart_id UUID,
    ADD COLUMN parked_at TIMESTAMPTZ;

CREATE UNIQUE INDEX idx_sales_client_cart_id
    ON sales(tenant_id, client_cart_id)
    WHERE client_cart_id IS NOT NULL;

CREATE INDEX idx_sales_parked
    ON sales(tenant_id, store_id, parked_at DESC)
    WHERE parked_at IS NOT NULL AND status = 'DRAFT';

COMMENT ON COLUMN sales.client_cart_id IS
    'Frontend-generated UUID. Unique per tenant. Enables idempotent POST /sales replay '
    'after network failures and crash recovery via localStorage.';

COMMENT ON COLUMN sales.parked_at IS
    'Set when cashier holds (F4) a DRAFT sale to start another. Recall via F5. '
    'Auto-abandoned after 24h by background job.';

-- ----------------------------------------------------------------------------
-- 2. Sale items: original price capture + override + price source
-- ----------------------------------------------------------------------------

ALTER TABLE sale_items
    ADD COLUMN original_unit_price_gross NUMERIC(15,4),
    ADD COLUMN manual_price_override BOOLEAN NOT NULL DEFAULT false,
    ADD COLUMN price_source TEXT NOT NULL DEFAULT 'BASE_PRICE_LIST'
        CHECK (price_source IN (
            'BASE_PRICE_LIST',
            'CUSTOMER_TIER',
            'MANUAL_OVERRIDE',
            'PROMOTION',
            'EMPLOYEE',
            'PRICE_MATCH'
        ));

-- Backfill defensive (no existing rows in MVP)
UPDATE sale_items
    SET original_unit_price_gross = unit_price_gross
    WHERE original_unit_price_gross IS NULL;

ALTER TABLE sale_items
    ALTER COLUMN original_unit_price_gross SET NOT NULL;

COMMENT ON COLUMN sale_items.original_unit_price_gross IS
    'Captured at line-add time. Persists even if admin changes price_list afterward. '
    'Enables retroactive analysis: discount vs markdown attribution.';

COMMENT ON COLUMN sale_items.manual_price_override IS
    'True if cashier (with sales.override_price permission) used "Fiyat Sabitle" flow. '
    'Distinguishes manual repricing from discount in reporting.';

COMMENT ON COLUMN sale_items.price_source IS
    'Why this price was applied. BASE_PRICE_LIST default; others reflect specific overrides. '
    'CUSTOMER_TIER and PROMOTION reserved for v1.1+.';

-- ----------------------------------------------------------------------------
-- 3. Users: manager PIN columns (separate from password auth)
-- ----------------------------------------------------------------------------

ALTER TABLE users
    ADD COLUMN manager_pin_hash TEXT,
    ADD COLUMN manager_pin_set_at TIMESTAMPTZ;

COMMENT ON COLUMN users.manager_pin_hash IS
    'BCrypt hash (via shared CredentialHasher) of 6-digit numeric PIN. '
    'Used for inline manager override during POS operations.';

-- ----------------------------------------------------------------------------
-- 4. pos_scan_attempts (append-only audit of every scan)
-- ----------------------------------------------------------------------------

CREATE TABLE pos_scan_attempts (
    id                      UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    tenant_id               UUID NOT NULL REFERENCES tenants(id),
    store_id                UUID NOT NULL REFERENCES stores(id),
    register_session_id     UUID NOT NULL REFERENCES register_sessions(id),
    sale_id                 UUID REFERENCES sales(id),
    client_cart_id          UUID,
    cashier_user_id         UUID NOT NULL REFERENCES users(id),
    barcode                 TEXT NOT NULL,
    outcome                 TEXT NOT NULL CHECK (outcome IN (
        'ADDED',
        'UNKNOWN_BARCODE',
        'OUT_OF_STOCK_BLOCKED',
        'OUT_OF_STOCK_OVERRIDE',
        'HID_BURST_IGNORED',
        'PERMISSION_DENIED',
        'ERROR'
    )),
    created_at              TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE INDEX idx_scan_attempts_cashier_recent
    ON pos_scan_attempts(tenant_id, cashier_user_id, created_at DESC);

CREATE INDEX idx_scan_attempts_sale
    ON pos_scan_attempts(sale_id)
    WHERE sale_id IS NOT NULL;

CREATE INDEX idx_scan_attempts_cart
    ON pos_scan_attempts(client_cart_id)
    WHERE client_cart_id IS NOT NULL;

ALTER TABLE pos_scan_attempts ENABLE ROW LEVEL SECURITY;

CREATE POLICY pos_scan_attempts_tenant_isolation ON pos_scan_attempts
    USING (tenant_id = current_tenant_id())
    WITH CHECK (tenant_id = current_tenant_id());

REVOKE UPDATE, DELETE ON pos_scan_attempts FROM PUBLIC;

-- Reuses generic append-only guard function (assumed defined in earlier migration)
-- If not present, define here:
CREATE OR REPLACE FUNCTION prevent_audit_mutation()
RETURNS TRIGGER AS $$
BEGIN
    RAISE EXCEPTION '% is append-only; UPDATE/DELETE forbidden', TG_TABLE_NAME;
END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER pos_scan_attempts_no_mutation
    BEFORE UPDATE OR DELETE ON pos_scan_attempts
    FOR EACH ROW EXECUTE FUNCTION prevent_audit_mutation();

COMMENT ON TABLE pos_scan_attempts IS
    'Append-only audit of every barcode scan attempt on POS screens. '
    'Pre-cart scans logged with sale_id NULL. '
    'Retention: indefinite MVP; monthly partitioning v1.1+.';

-- ----------------------------------------------------------------------------
-- 5. manager_pin_attempts (append-only; source of truth for lockout)
-- ----------------------------------------------------------------------------

CREATE TABLE manager_pin_attempts (
    id                          UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    tenant_id                   UUID NOT NULL REFERENCES tenants(id),
    register_session_id         UUID NOT NULL REFERENCES register_sessions(id),
    attempted_manager_user_id   UUID REFERENCES users(id),  -- nullable: USER_NOT_FOUND
    cashier_user_id             UUID NOT NULL REFERENCES users(id),
    outcome                     TEXT NOT NULL CHECK (outcome IN (
        'SUCCESS',
        'WRONG_PIN',
        'USER_NOT_FOUND',
        'LOCKED'
    )),
    attempted_at                TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE INDEX idx_pin_attempts_session_recent
    ON manager_pin_attempts(tenant_id, register_session_id, attempted_at DESC);

ALTER TABLE manager_pin_attempts ENABLE ROW LEVEL SECURITY;

CREATE POLICY pin_attempts_tenant_isolation ON manager_pin_attempts
    USING (tenant_id = current_tenant_id())
    WITH CHECK (tenant_id = current_tenant_id());

REVOKE UPDATE, DELETE ON manager_pin_attempts FROM PUBLIC;

CREATE TRIGGER manager_pin_attempts_no_mutation
    BEFORE UPDATE OR DELETE ON manager_pin_attempts
    FOR EACH ROW EXECUTE FUNCTION prevent_audit_mutation();

COMMENT ON TABLE manager_pin_attempts IS
    'Append-only audit of manager PIN attempts on POS screens. '
    'Source of truth for register-session-scoped lockout. '
    'Lockout: >=3 non-success outcomes in last 5min on same (tenant_id, register_session_id). '
    'USER_NOT_FOUND and WRONG_PIN both count (prevents cashier enumeration).';

-- ----------------------------------------------------------------------------
-- 6. payment_attempts: extended tender cancellation states
-- ----------------------------------------------------------------------------
-- Note: assumes existing payment_attempts has status column with CHECK constraint.
-- Drop and re-add with extended values.

ALTER TABLE payment_attempts
    DROP CONSTRAINT IF EXISTS payment_attempts_status_check;

ALTER TABLE payment_attempts
    ADD CONSTRAINT payment_attempts_status_check
        CHECK (status IN (
            'DRAFT',
            'AWAITING_TERMINAL',
            'APPROVED',
            'DECLINED',
            'TIMEOUT',
            'CANCELLED_BY_CASHIER',
            'CANCELLED_BY_MANAGER'
        ));

-- Add reconciliation fields for late callback handling
ALTER TABLE payment_attempts
    ADD COLUMN IF NOT EXISTS late_callback_received_at TIMESTAMPTZ,
    ADD COLUMN IF NOT EXISTS late_callback_outcome TEXT,
    ADD COLUMN IF NOT EXISTS reconciliation_flag BOOLEAN NOT NULL DEFAULT false;

COMMENT ON COLUMN payment_attempts.late_callback_outcome IS
    'When terminal callback arrives after CANCELLED_BY_* or TIMEOUT, record what the terminal reported. '
    'Do NOT flip payment_attempts.status; emit SaleReconciliationRequired event instead.';

COMMENT ON COLUMN payment_attempts.reconciliation_flag IS
    'True when this tender requires manual reconciliation. Set by SaleReconciliationRequired event.';

-- ----------------------------------------------------------------------------
-- 7. cash_movements: extended movement types
-- ----------------------------------------------------------------------------

ALTER TABLE cash_movements
    DROP CONSTRAINT IF EXISTS cash_movements_movement_type_check;

ALTER TABLE cash_movements
    ADD CONSTRAINT cash_movements_movement_type_check
        CHECK (movement_type IN (
            'SALE_CASH_IN',
            'SALE_CHANGE_OUT',
            'REFUND_CASH_OUT',
            'OPENING_FLOAT',
            'CLOSING_DEPOSIT',
            'MANAGER_TOPUP',
            'MANAGER_WITHDRAW',
            'CORRECTION'
        ));

COMMENT ON COLUMN cash_movements.movement_type IS
    'SALE_CASH_IN: gross cash received from customer (before change). '
    'SALE_CHANGE_OUT: change given back. Two movements per overpaid sale. '
    'REFUND_CASH_OUT: cash refund to customer. '
    'Other types: register lifecycle and manual operations.';

-- ----------------------------------------------------------------------------
-- 8. Missing item requests (referenced by 3.A.2)
-- ----------------------------------------------------------------------------

CREATE TABLE missing_item_requests (
    id                      UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    tenant_id               UUID NOT NULL REFERENCES tenants(id),
    store_id                UUID NOT NULL REFERENCES stores(id),
    reported_by_user_id     UUID NOT NULL REFERENCES users(id),
    barcode                 TEXT,
    description             TEXT,
    status                  TEXT NOT NULL DEFAULT 'OPEN'
                                CHECK (status IN ('OPEN', 'RESOLVED', 'DISMISSED')),
    resolved_at             TIMESTAMPTZ,
    resolved_by_user_id     UUID REFERENCES users(id),
    created_at              TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE INDEX idx_missing_items_open
    ON missing_item_requests(tenant_id, store_id, created_at DESC)
    WHERE status = 'OPEN';

ALTER TABLE missing_item_requests ENABLE ROW LEVEL SECURITY;

CREATE POLICY missing_items_tenant_isolation ON missing_item_requests
    USING (tenant_id = current_tenant_id())
    WITH CHECK (tenant_id = current_tenant_id());

COMMENT ON TABLE missing_item_requests IS
    'Reported by cashier from POS when product not found via barcode/search. '
    'Manager triages and resolves via catalog management (Phase 3.B). '
    'Catalog mutation NOT happens automatically; manual review.';

-- ============================================================================
-- End migration 018
-- ============================================================================
