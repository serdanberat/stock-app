-- ============================================================================
-- 020_inventory_extensions.sql
-- Phase 3.C — Inventory Operations
--
-- Adds:
--   - stock_movements.correlation_id (ADR-020)
--   - stock_movements.movement_wac_snapshot (rename from cost_at_movement)
--   - stock_movements reason CHECK extended (TRANSFER_DISCREPANCY, LOSS, EXPIRED,
--     INTERNAL_USE, GIFT, TRANSFER_CANCELLED)
--   - transfer_lines.sku_snapshot + display_name_snapshot
--   - count_sessions table
--   - count_session_lines table
--   - adjustments table
--   - adjustment_lines table
--   - correlation_id indexes
-- ============================================================================

BEGIN;

-- ---------------------------------------------------------------------------
-- 1. stock_movements: correlation_id + rename cost field + reason enum extend
-- ---------------------------------------------------------------------------

ALTER TABLE stock_movements
    ADD COLUMN correlation_id UUID;

-- Backfill correlation_id from existing reference columns where possible
UPDATE stock_movements
SET correlation_id = COALESCE(
    sale_id,
    transfer_id,
    return_id,
    adjustment_id,
    count_session_id,
    purchase_invoice_id,
    id  -- ultimate fallback: self.id (single-row operations)
)
WHERE correlation_id IS NULL;

ALTER TABLE stock_movements
    ALTER COLUMN correlation_id SET NOT NULL;

CREATE INDEX idx_stock_movements_correlation_id
    ON stock_movements(tenant_id, correlation_id);

-- Rename cost_at_movement → movement_wac_snapshot
ALTER TABLE stock_movements
    RENAME COLUMN cost_at_movement TO movement_wac_snapshot;

COMMENT ON COLUMN stock_movements.movement_wac_snapshot IS
    'WAC at the time of this movement. Historical snapshot; not retroactively updated.';

COMMENT ON COLUMN stock_movements.correlation_id IS
    'Per ADR-020: shared UUID across all outputs of the same domain operation. '
    'For transfers, returns, sales, adjustments, count sessions, etc.';

-- Extend reason CHECK constraint to include new enums
ALTER TABLE stock_movements
    DROP CONSTRAINT IF EXISTS stock_movements_reason_check;

ALTER TABLE stock_movements
    ADD CONSTRAINT stock_movements_reason_check CHECK (
        reason_code IS NULL OR reason_code IN (
            -- Adjustment reasons (3.C.5)
            'DAMAGE',
            'LOSS',                  -- renamed from THEFT (ambiguity-tolerant)
            'COUNT_CORRECTION',      -- system-generated from count session
            'SUPPLIER_RETURN',
            'EXPIRED',
            'INTERNAL_USE',
            'GIFT',
            'TRANSFER_CANCELLED',    -- system-generated from IN_TRANSIT cancel
            'OTHER',
            -- Transfer discrepancy (3.C.3)
            'TRANSFER_DISCREPANCY',
            -- Cash variance corrections
            'CASH_OVER',
            'CASH_SHORT'
        )
    );

-- ---------------------------------------------------------------------------
-- 2. transfer_lines: SKU + display_name snapshots
-- ---------------------------------------------------------------------------

ALTER TABLE transfer_lines
    ADD COLUMN sku_snapshot VARCHAR(64),
    ADD COLUMN display_name_snapshot VARCHAR(512);

-- Backfill from current variant data for legacy rows
UPDATE transfer_lines tl
SET sku_snapshot = v.sku,
    display_name_snapshot = v.display_name
FROM product_variants v
WHERE v.id = tl.variant_id
  AND tl.sku_snapshot IS NULL;

ALTER TABLE transfer_lines
    ALTER COLUMN sku_snapshot SET NOT NULL,
    ALTER COLUMN display_name_snapshot SET NOT NULL;

COMMENT ON COLUMN transfer_lines.sku_snapshot IS
    'SKU at the time of transfer creation. Preserved for historical accuracy '
    'since SKU is editable post-creation with manager permission.';

-- ---------------------------------------------------------------------------
-- 3. count_sessions table (3.C.4)
-- ---------------------------------------------------------------------------

CREATE TABLE count_sessions (
    id                      UUID PRIMARY KEY,
    tenant_id               UUID NOT NULL,
    store_id                UUID NOT NULL REFERENCES stores(id),
    scope_type              VARCHAR(20) NOT NULL CHECK (scope_type IN ('CATEGORY', 'VARIANTS')),
    scope_category_id       UUID,        -- when scope_type=CATEGORY
    scope_variant_ids       UUID[],      -- when scope_type=VARIANTS
    status                  VARCHAR(20) NOT NULL DEFAULT 'DRAFT'
                            CHECK (status IN ('DRAFT', 'IN_PROGRESS', 'FINALIZED', 'CANCELLED')),
    note                    TEXT,
    started_at              TIMESTAMPTZ,
    finalized_at            TIMESTAMPTZ,
    cancelled_at            TIMESTAMPTZ,
    cancelled_reason        VARCHAR(200),
    created_by              UUID NOT NULL REFERENCES users(id),
    created_at              TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_at              TIMESTAMPTZ NOT NULL DEFAULT now()
);

ALTER TABLE count_sessions ENABLE ROW LEVEL SECURITY;
CREATE POLICY count_sessions_tenant_isolation ON count_sessions
    USING (tenant_id = current_setting('app.tenant_id')::uuid);

CREATE INDEX idx_count_sessions_tenant_store ON count_sessions(tenant_id, store_id);
CREATE INDEX idx_count_sessions_status ON count_sessions(tenant_id, status);
CREATE INDEX idx_count_sessions_started_at ON count_sessions(tenant_id, started_at DESC);

COMMENT ON TABLE count_sessions IS
    'Stock count sessions per 3.C.4. Rolling count model: REPEATABLE READ snapshot '
    'at start; inventory operations not blocked during session. Variance computed '
    'against (snapshot + session_movements) at finalize.';

-- ---------------------------------------------------------------------------
-- 4. count_session_lines
-- ---------------------------------------------------------------------------

CREATE TABLE count_session_lines (
    id                      UUID PRIMARY KEY,
    tenant_id               UUID NOT NULL,
    count_session_id        UUID NOT NULL REFERENCES count_sessions(id) ON DELETE CASCADE,
    variant_id              UUID NOT NULL REFERENCES product_variants(id),
    snapshot_quantity       NUMERIC(12, 3) NOT NULL,        -- captured at start()
    counted_quantity        NUMERIC(12, 3),                 -- nullable until counted
    note                    TEXT,
    counted_by              UUID REFERENCES users(id),
    counted_at              TIMESTAMPTZ,
    created_at              TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_at              TIMESTAMPTZ NOT NULL DEFAULT now(),
    UNIQUE (count_session_id, variant_id)
);

ALTER TABLE count_session_lines ENABLE ROW LEVEL SECURITY;
CREATE POLICY count_session_lines_tenant_isolation ON count_session_lines
    USING (tenant_id = current_setting('app.tenant_id')::uuid);

CREATE INDEX idx_count_session_lines_session ON count_session_lines(count_session_id);
CREATE INDEX idx_count_session_lines_variant ON count_session_lines(tenant_id, variant_id);

COMMENT ON COLUMN count_session_lines.snapshot_quantity IS
    'Stock balance at session start (REPEATABLE READ snapshot). '
    'Expected at finalize = snapshot + sum(session-window movements).';

-- ---------------------------------------------------------------------------
-- 5. adjustments table (3.C.5)
-- ---------------------------------------------------------------------------

CREATE TABLE adjustments (
    id                      UUID PRIMARY KEY,
    tenant_id               UUID NOT NULL,
    store_id                UUID NOT NULL REFERENCES stores(id),
    note                    TEXT,
    total_quantity_abs      NUMERIC(12, 3) NOT NULL DEFAULT 0,
                            -- sum of |quantity_delta| across lines; for large-adjustment check
    is_large_adjustment     BOOLEAN NOT NULL DEFAULT FALSE,
                            -- snapshot of "exceeded tenant.adjustment_large_threshold"
    is_negative_stock_warned BOOLEAN NOT NULL DEFAULT FALSE,
    created_by              UUID NOT NULL REFERENCES users(id),
    created_at              TIMESTAMPTZ NOT NULL DEFAULT now()
    -- Single-shot: no status; no updated_at; immutable after creation
);

ALTER TABLE adjustments ENABLE ROW LEVEL SECURITY;
CREATE POLICY adjustments_tenant_isolation ON adjustments
    USING (tenant_id = current_setting('app.tenant_id')::uuid);

CREATE INDEX idx_adjustments_tenant_store ON adjustments(tenant_id, store_id);
CREATE INDEX idx_adjustments_created_at ON adjustments(tenant_id, created_at DESC);
CREATE INDEX idx_adjustments_created_by ON adjustments(tenant_id, created_by);

COMMENT ON TABLE adjustments IS
    'Manager-only direct stock corrections per 3.C.5. Single-shot semantics: '
    'no DRAFT, immutable after creation. Mistake correction via reverse adjustment.';

-- ---------------------------------------------------------------------------
-- 6. adjustment_lines
-- ---------------------------------------------------------------------------

CREATE TABLE adjustment_lines (
    id                      UUID PRIMARY KEY,
    tenant_id               UUID NOT NULL,
    adjustment_id           UUID NOT NULL REFERENCES adjustments(id) ON DELETE CASCADE,
    variant_id              UUID NOT NULL REFERENCES product_variants(id),
    quantity_delta          NUMERIC(12, 3) NOT NULL CHECK (quantity_delta != 0),
                            -- signed: + = ADJUSTMENT_IN, - = ADJUSTMENT_OUT
    reason_code             VARCHAR(40) NOT NULL CHECK (reason_code IN (
                                'DAMAGE',
                                'LOSS',
                                'SUPPLIER_RETURN',
                                'EXPIRED',
                                'INTERNAL_USE',
                                'GIFT',
                                'OTHER'
                                -- COUNT_CORRECTION and TRANSFER_CANCELLED are system-generated
                                -- and NOT selectable in adjustments UI
                            )),
    free_text_reason        TEXT,   -- required when reason_code = OTHER
    created_at              TIMESTAMPTZ NOT NULL DEFAULT now(),

    -- Same variant cannot appear twice with different reasons (3.C.5 invariant)
    UNIQUE (adjustment_id, variant_id),

    -- OTHER reason requires free_text
    CONSTRAINT adjustment_line_other_requires_text CHECK (
        reason_code != 'OTHER' OR (free_text_reason IS NOT NULL AND char_length(free_text_reason) >= 1)
    )
);

ALTER TABLE adjustment_lines ENABLE ROW LEVEL SECURITY;
CREATE POLICY adjustment_lines_tenant_isolation ON adjustment_lines
    USING (tenant_id = current_setting('app.tenant_id')::uuid);

CREATE INDEX idx_adjustment_lines_adjustment ON adjustment_lines(adjustment_id);
CREATE INDEX idx_adjustment_lines_variant ON adjustment_lines(tenant_id, variant_id);

-- ---------------------------------------------------------------------------
-- 7. updated_at triggers
-- ---------------------------------------------------------------------------

CREATE TRIGGER trg_count_sessions_updated
    BEFORE UPDATE ON count_sessions
    FOR EACH ROW EXECUTE FUNCTION set_updated_at();

CREATE TRIGGER trg_count_session_lines_updated
    BEFORE UPDATE ON count_session_lines
    FOR EACH ROW EXECUTE FUNCTION set_updated_at();

-- adjustments and adjustment_lines: NO updated_at trigger (immutable post-creation)

-- ---------------------------------------------------------------------------
-- 8. Audit mutation prevention on append-only tables
-- ---------------------------------------------------------------------------

CREATE TRIGGER trg_adjustments_prevent_mutation
    BEFORE UPDATE OR DELETE ON adjustments
    FOR EACH ROW EXECUTE FUNCTION prevent_audit_mutation();

CREATE TRIGGER trg_adjustment_lines_prevent_mutation
    BEFORE UPDATE OR DELETE ON adjustment_lines
    FOR EACH ROW EXECUTE FUNCTION prevent_audit_mutation();

COMMIT;
