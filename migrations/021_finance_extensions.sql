-- ============================================================================
-- 021_finance_extensions.sql
-- Phase 3.D — Financial Flows
--
-- Adds:
--   - purchase_invoices table (DRAFT → COMMITTED → REVERSED)
--   - purchase_invoice_lines
--   - returns table (mode, manager_override_token, reason_code, correlation_id)
--   - return_lines
--   - exchange_lines (new sale items within return)
--   - account_movement types: STORE_CREDIT_ISSUED, STORE_CREDIT_REDEEMED
--   - store_credit_balances per (party_id)
--   - payments table (direction, tender, bank_transfer_reference)
-- ============================================================================

BEGIN;

-- ---------------------------------------------------------------------------
-- 1. purchase_invoices
-- ---------------------------------------------------------------------------

CREATE TABLE purchase_invoices (
    id                          UUID PRIMARY KEY,
    tenant_id                   UUID NOT NULL,
    internal_number             VARCHAR(32) NOT NULL,
                                -- PI-NNNN, monotonic per tenant
    supplier_id                 UUID NOT NULL REFERENCES parties(id),
    store_id                    UUID NOT NULL REFERENCES stores(id),
    supplier_invoice_number     VARCHAR(64) NOT NULL,
                                -- supplier's own invoice ID
    status                      VARCHAR(20) NOT NULL DEFAULT 'DRAFT'
                                CHECK (status IN ('DRAFT', 'COMMITTED', 'REVERSED')),
    is_reverse_invoice          BOOLEAN NOT NULL DEFAULT FALSE,
                                -- true if this invoice was created via reverse() of another
    reverses_invoice_id         UUID REFERENCES purchase_invoices(id),
    reverse_reason              TEXT,
    invoice_date                DATE NOT NULL,
    due_date                    DATE,
    currency_code               VARCHAR(3) NOT NULL DEFAULT 'TRY',
    -- Header totals (computed at commit; stored snapshot)
    subtotal_gross              NUMERIC(14, 2),
    freight_total               NUMERIC(14, 2) DEFAULT 0,
    header_discount             NUMERIC(14, 2) DEFAULT 0,
    net_goods                   NUMERIC(14, 2),
    vat_total                   NUMERIC(14, 2),
    grand_total                 NUMERIC(14, 2),
    note                        TEXT,
    correlation_id              UUID,
                                -- per ADR-020
    created_by                  UUID NOT NULL REFERENCES users(id),
    created_at                  TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_at                  TIMESTAMPTZ NOT NULL DEFAULT now(),
    committed_at                TIMESTAMPTZ,
    committed_by                UUID REFERENCES users(id),

    -- Supplier invoice number uniqueness within tenant + supplier
    UNIQUE (tenant_id, supplier_id, supplier_invoice_number),

    -- Internal number uniqueness within tenant
    UNIQUE (tenant_id, internal_number)
);

ALTER TABLE purchase_invoices ENABLE ROW LEVEL SECURITY;
CREATE POLICY purchase_invoices_tenant_isolation ON purchase_invoices
    USING (tenant_id = current_setting('app.tenant_id')::uuid);

CREATE INDEX idx_purchase_invoices_supplier ON purchase_invoices(tenant_id, supplier_id);
CREATE INDEX idx_purchase_invoices_store ON purchase_invoices(tenant_id, store_id);
CREATE INDEX idx_purchase_invoices_status ON purchase_invoices(tenant_id, status);
CREATE INDEX idx_purchase_invoices_invoice_date ON purchase_invoices(tenant_id, invoice_date DESC);
CREATE INDEX idx_purchase_invoices_correlation_id ON purchase_invoices(tenant_id, correlation_id);

COMMENT ON TABLE purchase_invoices IS
    'Supplier invoices per 3.D.2. DRAFT lifecycle creates no side effects; '
    'commit atomically applies PURCHASE_IN movements, WAC updates, supplier debt.';

COMMENT ON COLUMN purchase_invoices.is_reverse_invoice IS
    'True when this invoice was created as a reverse of another. Lines have negative signs.';

-- ---------------------------------------------------------------------------
-- 2. purchase_invoice_lines
-- ---------------------------------------------------------------------------

CREATE TABLE purchase_invoice_lines (
    id                      UUID PRIMARY KEY,
    tenant_id               UUID NOT NULL,
    purchase_invoice_id     UUID NOT NULL REFERENCES purchase_invoices(id) ON DELETE CASCADE,
    line_no                 INT NOT NULL,
    variant_id              UUID NOT NULL REFERENCES product_variants(id),
    quantity                NUMERIC(12, 3) NOT NULL CHECK (quantity != 0),
                            -- negative on reverse invoices
    unit_cost               NUMERIC(14, 4) NOT NULL,
                            -- 4 decimals for accuracy in WAC compute
    line_discount           NUMERIC(14, 2) DEFAULT 0,
    vat_rate                NUMERIC(5, 2) NOT NULL DEFAULT 20.00,
                            -- as percentage; e.g. 20.00 = %20 KDV
    line_total_pre_vat      NUMERIC(14, 2),
    line_vat                NUMERIC(14, 2),
    line_total              NUMERIC(14, 2),
    -- Effective unit cost after line discount + allocated freight (set at commit)
    effective_unit_cost     NUMERIC(14, 4),
    created_at              TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_at              TIMESTAMPTZ NOT NULL DEFAULT now(),
    UNIQUE (purchase_invoice_id, line_no)
);

ALTER TABLE purchase_invoice_lines ENABLE ROW LEVEL SECURITY;
CREATE POLICY purchase_invoice_lines_tenant_isolation ON purchase_invoice_lines
    USING (tenant_id = current_setting('app.tenant_id')::uuid);

CREATE INDEX idx_pi_lines_invoice ON purchase_invoice_lines(purchase_invoice_id);
CREATE INDEX idx_pi_lines_variant ON purchase_invoice_lines(tenant_id, variant_id);

COMMENT ON COLUMN purchase_invoice_lines.effective_unit_cost IS
    'Unit cost after line discount + prorated freight allocation. Used in WAC formula at commit.';

-- ---------------------------------------------------------------------------
-- 3. returns table
-- ---------------------------------------------------------------------------

CREATE TABLE returns (
    id                              UUID PRIMARY KEY,
    tenant_id                       UUID NOT NULL,
    internal_number                 VARCHAR(32) NOT NULL,
                                    -- RET-NNNN monotonic per tenant
    mode                            VARCHAR(20) NOT NULL CHECK (mode IN ('REFERENCED', 'WITHOUT_REFERENCE')),
    original_sale_id                UUID,   -- nullable; null for WITHOUT_REFERENCE
    customer_party_id               UUID REFERENCES parties(id),
                                    -- required for WITHOUT_REFERENCE with store_credit/customer_account refund
    store_id                        UUID NOT NULL REFERENCES stores(id),
    status                          VARCHAR(20) NOT NULL DEFAULT 'DRAFT'
                                    CHECK (status IN ('DRAFT', 'COMPLETED', 'CANCELLED')),

    -- WITHOUT_REFERENCE specific
    reason_code                     VARCHAR(40),
                                    -- NO_RECEIPT_KEPT, RECEIPT_LOST, GIFT_NO_RECEIPT, RECEIPT_FROM_ANOTHER_STORE
    manager_override_token          UUID,
                                    -- references override_tokens table (3.A.4 pattern)
    initiator_note                  TEXT,
                                    -- min 10 chars for WITHOUT_REFERENCE

    -- Refund tender (committed at finalize)
    refund_tender_type              VARCHAR(40),
                                    -- CASH, CARD_REFUND, STORE_CREDIT, CUSTOMER_ACCOUNT
    refund_amount                   NUMERIC(14, 2),

    -- Exchange settlement
    returned_total                  NUMERIC(14, 2) NOT NULL DEFAULT 0,
    new_sale_total                  NUMERIC(14, 2) NOT NULL DEFAULT 0,
    settlement_delta                NUMERIC(14, 2) NOT NULL DEFAULT 0,
                                    -- = new_sale_total - returned_total

    -- Linkage when exchange creates a new Sale
    exchange_sale_id                UUID,
                                    -- nullable; populated when finalize creates new Sale

    correlation_id                  UUID NOT NULL,
                                    -- per ADR-020; typically = returns.id; exchange Sale carries same
    created_by                      UUID NOT NULL REFERENCES users(id),
    created_at                      TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_at                      TIMESTAMPTZ NOT NULL DEFAULT now(),
    completed_at                    TIMESTAMPTZ,
    cancelled_at                    TIMESTAMPTZ,

    UNIQUE (tenant_id, internal_number),

    -- WITHOUT_REFERENCE requires reason + override + customer for non-cash refund
    CONSTRAINT return_without_ref_requires_reason CHECK (
        mode != 'WITHOUT_REFERENCE' OR (
            reason_code IS NOT NULL AND
            manager_override_token IS NOT NULL AND
            initiator_note IS NOT NULL AND char_length(initiator_note) >= 10
        )
    ),

    -- WITHOUT_REFERENCE cannot use CASH or CARD_REFUND tender
    CONSTRAINT return_without_ref_tender_allowlist CHECK (
        mode != 'WITHOUT_REFERENCE' OR
        refund_tender_type IS NULL OR
        refund_tender_type IN ('STORE_CREDIT', 'CUSTOMER_ACCOUNT')
    )
);

ALTER TABLE returns ENABLE ROW LEVEL SECURITY;
CREATE POLICY returns_tenant_isolation ON returns
    USING (tenant_id = current_setting('app.tenant_id')::uuid);

CREATE INDEX idx_returns_sale_ref ON returns(tenant_id, original_sale_id);
CREATE INDEX idx_returns_customer ON returns(tenant_id, customer_party_id);
CREATE INDEX idx_returns_correlation_id ON returns(tenant_id, correlation_id);
CREATE INDEX idx_returns_status ON returns(tenant_id, status);
CREATE INDEX idx_returns_created_at ON returns(tenant_id, created_at DESC);

COMMENT ON TABLE returns IS
    'Return + exchange aggregate per 3.D.3 + 3.D.4. Three-component financial '
    'decomposition: returned_total, new_sale_total, settlement_delta.';

-- ---------------------------------------------------------------------------
-- 4. return_lines (original sale items being returned)
-- ---------------------------------------------------------------------------

CREATE TABLE return_lines (
    id                      UUID PRIMARY KEY,
    tenant_id               UUID NOT NULL,
    return_id               UUID NOT NULL REFERENCES returns(id) ON DELETE CASCADE,
    line_no                 INT NOT NULL,
    variant_id              UUID NOT NULL REFERENCES product_variants(id),
    quantity                NUMERIC(12, 3) NOT NULL CHECK (quantity > 0),
    unit_price_gross        NUMERIC(14, 2) NOT NULL,
                            -- per-unit price including VAT, snapshot from original sale
    line_total              NUMERIC(14, 2) NOT NULL,
    -- Optional reference to original sale line (when REFERENCED)
    original_sale_line_id   UUID,
    created_at              TIMESTAMPTZ NOT NULL DEFAULT now(),
    UNIQUE (return_id, line_no)
);

ALTER TABLE return_lines ENABLE ROW LEVEL SECURITY;
CREATE POLICY return_lines_tenant_isolation ON return_lines
    USING (tenant_id = current_setting('app.tenant_id')::uuid);

CREATE INDEX idx_return_lines_return ON return_lines(return_id);
CREATE INDEX idx_return_lines_variant ON return_lines(tenant_id, variant_id);

-- ---------------------------------------------------------------------------
-- 5. exchange_lines (new sale items within return)
-- ---------------------------------------------------------------------------

CREATE TABLE exchange_lines (
    id                      UUID PRIMARY KEY,
    tenant_id               UUID NOT NULL,
    return_id               UUID NOT NULL REFERENCES returns(id) ON DELETE CASCADE,
    line_no                 INT NOT NULL,
    variant_id              UUID NOT NULL REFERENCES product_variants(id),
    quantity                NUMERIC(12, 3) NOT NULL CHECK (quantity > 0),
    unit_price_gross        NUMERIC(14, 2) NOT NULL,
                            -- snapshot of current resolved price at exchange line add time
    line_discount           NUMERIC(14, 2) DEFAULT 0,
    line_total              NUMERIC(14, 2) NOT NULL,
    created_at              TIMESTAMPTZ NOT NULL DEFAULT now(),
    UNIQUE (return_id, line_no)
);

ALTER TABLE exchange_lines ENABLE ROW LEVEL SECURITY;
CREATE POLICY exchange_lines_tenant_isolation ON exchange_lines
    USING (tenant_id = current_setting('app.tenant_id')::uuid);

CREATE INDEX idx_exchange_lines_return ON exchange_lines(return_id);
CREATE INDEX idx_exchange_lines_variant ON exchange_lines(tenant_id, variant_id);

-- ---------------------------------------------------------------------------
-- 6. store_credit_balances per (tenant, party)
-- ---------------------------------------------------------------------------

CREATE TABLE store_credit_balances (
    tenant_id               UUID NOT NULL,
    party_id                UUID NOT NULL REFERENCES parties(id),
    balance                 NUMERIC(14, 2) NOT NULL DEFAULT 0 CHECK (balance >= 0),
                            -- non-negative; redemption decrements
    last_issued_at          TIMESTAMPTZ,
    last_redeemed_at        TIMESTAMPTZ,
    updated_at              TIMESTAMPTZ NOT NULL DEFAULT now(),
    PRIMARY KEY (tenant_id, party_id)
);

ALTER TABLE store_credit_balances ENABLE ROW LEVEL SECURITY;
CREATE POLICY store_credit_balances_tenant_isolation ON store_credit_balances
    USING (tenant_id = current_setting('app.tenant_id')::uuid);

COMMENT ON TABLE store_credit_balances IS
    'Store credit per customer. Real monetary liability (not loyalty points). '
    'Issued by returns (3.D.4 STORE_CREDIT refund tender), redeemed by payments '
    '(3.D.7 STORE_CREDIT_REDEMPTION tender).';

-- ---------------------------------------------------------------------------
-- 7. account_movements: extend type CHECK
-- ---------------------------------------------------------------------------

ALTER TABLE account_movements
    DROP CONSTRAINT IF EXISTS account_movements_movement_type_check;

ALTER TABLE account_movements
    ADD CONSTRAINT account_movements_movement_type_check CHECK (
        movement_type IN (
            -- Existing
            'SALE_DEBT',                  -- customer owes after credit sale
            'PURCHASE_DEBT',              -- we owe supplier
            'PAYMENT_RECEIVED',           -- customer paid
            'PAYMENT_MADE',               -- we paid supplier
            'RETURN_CREDIT',              -- customer credit from return
            'RETURN_TO_SUPPLIER',         -- credit from supplier-side return
            'OPENING_BALANCE',
            'ADJUSTMENT',
            -- Phase 3.D additions
            'STORE_CREDIT_ISSUED',        -- store credit balance increased (we owe)
            'STORE_CREDIT_REDEEMED'       -- store credit applied to payment
        )
    );

-- ---------------------------------------------------------------------------
-- 8. account_movements: correlation_id
-- ---------------------------------------------------------------------------

ALTER TABLE account_movements
    ADD COLUMN IF NOT EXISTS correlation_id UUID;

UPDATE account_movements
SET correlation_id = COALESCE(
    sale_id,
    purchase_invoice_id,
    payment_id,
    return_id,
    id
)
WHERE correlation_id IS NULL;

ALTER TABLE account_movements
    ALTER COLUMN correlation_id SET NOT NULL;

CREATE INDEX idx_account_movements_correlation_id
    ON account_movements(tenant_id, correlation_id);

-- ---------------------------------------------------------------------------
-- 9. payments table
-- ---------------------------------------------------------------------------

CREATE TABLE payments (
    id                          UUID PRIMARY KEY,
    tenant_id                   UUID NOT NULL,
    internal_number             VARCHAR(32) NOT NULL,
                                -- PAY-NNNN monotonic per tenant
    direction                   VARCHAR(40) NOT NULL CHECK (direction IN (
                                    'COLLECT_FROM_CUSTOMER',
                                    'PAY_TO_SUPPLIER'
                                )),
    party_id                    UUID NOT NULL REFERENCES parties(id),
    amount                      NUMERIC(14, 2) NOT NULL CHECK (amount > 0),
    tender_type                 VARCHAR(40) NOT NULL CHECK (tender_type IN (
                                    'CASH', 'CARD', 'BANK_TRANSFER',
                                    'STORE_CREDIT_REDEMPTION'
                                )),
    store_id                    UUID NOT NULL REFERENCES stores(id),
                                -- for cash drawer affiliation
    bank_transfer_reference     VARCHAR(64),
                                -- required if tender_type = BANK_TRANSFER
    payment_year                INT NOT NULL,
                                -- denormalized from created_at for UNIQUE constraint scoping
    overpayment_amount          NUMERIC(14, 2) DEFAULT 0,
                                -- amount > current debt
    note                        TEXT,
    correlation_id              UUID NOT NULL,
                                -- per ADR-020; = payments.id by default
    created_by                  UUID NOT NULL REFERENCES users(id),
    created_at                  TIMESTAMPTZ NOT NULL DEFAULT now(),

    UNIQUE (tenant_id, internal_number),

    -- BANK_TRANSFER requires reference number, UNIQUE per tenant per year
    CONSTRAINT payments_bank_transfer_requires_ref CHECK (
        tender_type != 'BANK_TRANSFER' OR (
            bank_transfer_reference IS NOT NULL AND char_length(bank_transfer_reference) >= 1
        )
    )
);

ALTER TABLE payments ENABLE ROW LEVEL SECURITY;
CREATE POLICY payments_tenant_isolation ON payments
    USING (tenant_id = current_setting('app.tenant_id')::uuid);

-- Bank transfer reference UNIQUE per (tenant, year)
CREATE UNIQUE INDEX uq_payments_bank_transfer_ref
    ON payments (tenant_id, payment_year, bank_transfer_reference)
    WHERE tender_type = 'BANK_TRANSFER';

CREATE INDEX idx_payments_party ON payments(tenant_id, party_id);
CREATE INDEX idx_payments_direction ON payments(tenant_id, direction);
CREATE INDEX idx_payments_correlation_id ON payments(tenant_id, correlation_id);
CREATE INDEX idx_payments_created_at ON payments(tenant_id, created_at DESC);

COMMENT ON TABLE payments IS
    'Payment aggregate per 3.D.7. Generic with direction param. Bank transfer '
    'reference UNIQUE per tenant per year for audit/dedup.';

-- ---------------------------------------------------------------------------
-- 10. updated_at triggers
-- ---------------------------------------------------------------------------

CREATE TRIGGER trg_purchase_invoices_updated
    BEFORE UPDATE ON purchase_invoices
    FOR EACH ROW EXECUTE FUNCTION set_updated_at();

CREATE TRIGGER trg_purchase_invoice_lines_updated
    BEFORE UPDATE ON purchase_invoice_lines
    FOR EACH ROW EXECUTE FUNCTION set_updated_at();

CREATE TRIGGER trg_returns_updated
    BEFORE UPDATE ON returns
    FOR EACH ROW EXECUTE FUNCTION set_updated_at();

CREATE TRIGGER trg_store_credit_balances_updated
    BEFORE UPDATE ON store_credit_balances
    FOR EACH ROW EXECUTE FUNCTION set_updated_at();

-- payments and return_lines: NO updated_at trigger (append-only after creation)

-- ---------------------------------------------------------------------------
-- 11. Mutation prevention on append-only
-- ---------------------------------------------------------------------------

CREATE TRIGGER trg_payments_prevent_mutation
    BEFORE UPDATE OR DELETE ON payments
    FOR EACH ROW EXECUTE FUNCTION prevent_audit_mutation();

CREATE TRIGGER trg_return_lines_prevent_mutation
    BEFORE UPDATE OR DELETE ON return_lines
    FOR EACH ROW EXECUTE FUNCTION prevent_audit_mutation();

CREATE TRIGGER trg_exchange_lines_prevent_mutation
    BEFORE UPDATE OR DELETE ON exchange_lines
    FOR EACH ROW EXECUTE FUNCTION prevent_audit_mutation();

COMMIT;
