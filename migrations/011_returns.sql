-- Migration 011_returns.sql
-- Returns context: returns, return_items, return_documents, exchange_groups

CREATE TABLE exchange_groups (
  id                            UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  tenant_id                     UUID NOT NULL REFERENCES tenants(id) ON DELETE RESTRICT,
  store_id                      UUID NOT NULL REFERENCES stores(id) ON DELETE RESTRICT,

  return_id                     UUID,  -- FK added after returns table created (deferred)
  sale_id                       UUID,  -- FK added after... (already exists)

  status                        VARCHAR(30) NOT NULL DEFAULT 'AWAITING_RETURN',
  CONSTRAINT chk_eg_status CHECK (status IN (
    'AWAITING_RETURN','AWAITING_SALE','COMPLETED','STALLED','CANCELLED'
  )),

  difference_amount             NUMERIC(15,4),
  difference_direction          VARCHAR(20),
  CONSTRAINT chk_eg_diff_dir CHECK (difference_direction IS NULL OR difference_direction IN (
    'CUSTOMER_PAYS_MORE','CUSTOMER_GETS_REFUND','EQUAL'
  )),

  initiated_at                  TIMESTAMPTZ NOT NULL DEFAULT now(),
  initiated_by_user_id          UUID NOT NULL REFERENCES users(id) ON DELETE RESTRICT,
  completed_at                  TIMESTAMPTZ,
  stalled_at                    TIMESTAMPTZ,
  stall_reason                  TEXT,
  cancelled_at                  TIMESTAMPTZ,
  cancelled_reason              TEXT,

  notes                         TEXT,
  metadata                      JSONB DEFAULT '{}'::jsonb,

  created_at                    TIMESTAMPTZ NOT NULL DEFAULT now(),
  updated_at                    TIMESTAMPTZ NOT NULL DEFAULT now()
);

-- Critical: at most one exchange per return, at most one exchange per sale
CREATE UNIQUE INDEX idx_eg_return_unique ON exchange_groups(return_id) WHERE return_id IS NOT NULL;
CREATE UNIQUE INDEX idx_eg_sale_unique ON exchange_groups(sale_id) WHERE sale_id IS NOT NULL;
CREATE INDEX idx_eg_tenant_status ON exchange_groups(tenant_id, status);
CREATE INDEX idx_eg_stalled ON exchange_groups(tenant_id, stalled_at)
  WHERE status = 'STALLED';

ALTER TABLE exchange_groups ENABLE ROW LEVEL SECURITY;
CREATE POLICY tenant_isolation_eg ON exchange_groups USING (tenant_id = current_tenant_id());

CREATE TRIGGER set_updated_at_eg
  BEFORE UPDATE ON exchange_groups FOR EACH ROW EXECUTE FUNCTION set_updated_at();

-- Resolve forward reference: sales.exchange_group_id (defined in 010_sales.sql)
ALTER TABLE sales
  ADD CONSTRAINT fk_sales_exchange_group
  FOREIGN KEY (exchange_group_id) REFERENCES exchange_groups(id) ON DELETE SET NULL;

-- Resolve self-reference: exchange_groups.sale_id
ALTER TABLE exchange_groups
  ADD CONSTRAINT fk_eg_sale
  FOREIGN KEY (sale_id) REFERENCES sales(id) ON DELETE SET NULL;


CREATE TABLE returns (
  id                            UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  tenant_id                     UUID NOT NULL REFERENCES tenants(id) ON DELETE RESTRICT,
  store_id                      UUID NOT NULL REFERENCES stores(id) ON DELETE RESTRICT,
  register_session_id           UUID REFERENCES register_sessions(id) ON DELETE RESTRICT,

  return_number                 VARCHAR(50),

  status                        VARCHAR(20) NOT NULL DEFAULT 'DRAFT',
  CONSTRAINT chk_return_status CHECK (status IN ('DRAFT','AWAITING_APPROVAL','COMPLETED','VOIDED')),

  mode                          VARCHAR(20) NOT NULL,
  CONSTRAINT chk_return_mode CHECK (mode IN ('RECEIPTED','BLIND')),

  original_sale_id              UUID REFERENCES sales(id) ON DELETE RESTRICT,
  CONSTRAINT chk_return_mode_sale CHECK (
    (mode = 'RECEIPTED' AND original_sale_id IS NOT NULL)
    OR (mode = 'BLIND' AND original_sale_id IS NULL)
  ),

  cashier_user_id               UUID NOT NULL REFERENCES users(id) ON DELETE RESTRICT,
  customer_id                   UUID REFERENCES parties(id) ON DELETE RESTRICT,

  currency                      VARCHAR(10) NOT NULL DEFAULT 'TRY',
  fx_snapshot_id                UUID REFERENCES fx_snapshots(id) ON DELETE RESTRICT,
  CONSTRAINT chk_return_fx_required CHECK (currency = 'TRY' OR fx_snapshot_id IS NOT NULL),

  subtotal                      NUMERIC(15,4) NOT NULL DEFAULT 0,
  vat_total                     NUMERIC(15,4) NOT NULL DEFAULT 0,
  total                         NUMERIC(15,4) NOT NULL DEFAULT 0,
  total_try                     NUMERIC(15,4) NOT NULL DEFAULT 0,

  CONSTRAINT chk_return_amounts_nonneg CHECK (
    subtotal >= 0 AND vat_total >= 0 AND total >= 0 AND total_try >= 0
  ),

  refund_cash                   NUMERIC(15,4) NOT NULL DEFAULT 0,
  refund_card_reversal          NUMERIC(15,4) NOT NULL DEFAULT 0,
  refund_customer_balance       NUMERIC(15,4) NOT NULL DEFAULT 0,
  refund_debt_reduction         NUMERIC(15,4) NOT NULL DEFAULT 0,
  CONSTRAINT chk_return_refund_nonneg CHECK (
    refund_cash >= 0 AND refund_card_reversal >= 0 AND
    refund_customer_balance >= 0 AND refund_debt_reduction >= 0
  ),

  approval_reasons              TEXT[],
  approver_user_id              UUID REFERENCES users(id) ON DELETE SET NULL,
  approved_at                   TIMESTAMPTZ,
  approval_notes                TEXT,

  administratively_reversed_at         TIMESTAMPTZ,
  administratively_reversed_by_user_id UUID REFERENCES users(id) ON DELETE SET NULL,
  administrative_reversal_reason       TEXT,

  exchange_group_id             UUID REFERENCES exchange_groups(id) ON DELETE SET NULL,

  idempotency_key               VARCHAR(64),

  notes                         TEXT,
  metadata                      JSONB DEFAULT '{}'::jsonb,

  completed_at                  TIMESTAMPTZ,
  completed_by_user_id          UUID REFERENCES users(id) ON DELETE SET NULL,
  voided_at                     TIMESTAMPTZ,
  voided_by_user_id             UUID REFERENCES users(id) ON DELETE SET NULL,

  created_at                    TIMESTAMPTZ NOT NULL DEFAULT now(),
  updated_at                    TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE UNIQUE INDEX idx_returns_tenant_number
  ON returns(tenant_id, return_number) WHERE return_number IS NOT NULL;
CREATE UNIQUE INDEX idx_returns_idempotency
  ON returns(tenant_id, idempotency_key) WHERE idempotency_key IS NOT NULL;
CREATE UNIQUE INDEX idx_returns_exchange_group_unique
  ON returns(exchange_group_id) WHERE exchange_group_id IS NOT NULL;

CREATE INDEX idx_returns_status ON returns(tenant_id, status);
CREATE INDEX idx_returns_original_sale ON returns(original_sale_id) WHERE original_sale_id IS NOT NULL;
CREATE INDEX idx_returns_mode ON returns(tenant_id, mode);
CREATE INDEX idx_returns_customer ON returns(customer_id, completed_at DESC) WHERE customer_id IS NOT NULL;
CREATE INDEX idx_returns_awaiting_approval ON returns(tenant_id, created_at DESC)
  WHERE status = 'AWAITING_APPROVAL';

ALTER TABLE returns ENABLE ROW LEVEL SECURITY;
CREATE POLICY tenant_isolation_returns ON returns USING (tenant_id = current_tenant_id());

CREATE TRIGGER set_updated_at_returns
  BEFORE UPDATE ON returns FOR EACH ROW EXECUTE FUNCTION set_updated_at();

-- Resolve forward reference: exchange_groups.return_id
ALTER TABLE exchange_groups
  ADD CONSTRAINT fk_eg_return
  FOREIGN KEY (return_id) REFERENCES returns(id) ON DELETE SET NULL;


CREATE TABLE return_items (
  id                            UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  tenant_id                     UUID NOT NULL REFERENCES tenants(id) ON DELETE RESTRICT,
  return_id                     UUID NOT NULL REFERENCES returns(id) ON DELETE CASCADE,
  line_number                   INT NOT NULL,

  variant_id                    UUID NOT NULL REFERENCES product_variants(id) ON DELETE RESTRICT,
  variant_sku                   VARCHAR(100) NOT NULL,
  variant_display_name          VARCHAR(300) NOT NULL,

  original_sale_item_id         UUID REFERENCES sale_items(id) ON DELETE RESTRICT,

  quantity                      NUMERIC(15,4) NOT NULL,
  CONSTRAINT chk_ri_qty_pos CHECK (quantity > 0),

  unit_price                    NUMERIC(15,4) NOT NULL,
  CONSTRAINT chk_ri_price_nonneg CHECK (unit_price >= 0),
  vat_rate                      NUMERIC(5,2) NOT NULL,
  CONSTRAINT chk_ri_vat_rate CHECK (vat_rate >= 0 AND vat_rate <= 100),
  vat_amount                    NUMERIC(15,4) NOT NULL DEFAULT 0,
  CONSTRAINT chk_ri_vat_amount_nonneg CHECK (vat_amount >= 0),

  unit_cost_try                 NUMERIC(15,4) NOT NULL,
  CONSTRAINT chk_ri_cost_nonneg CHECK (unit_cost_try >= 0),

  line_total                    NUMERIC(15,4) GENERATED ALWAYS AS (quantity * unit_price) STORED,

  condition                     VARCHAR(20) NOT NULL DEFAULT 'NEW',
  CONSTRAINT chk_ri_condition CHECK (condition IN ('NEW','USED','DAMAGED','DEFECTIVE')),

  return_reason_code_id         UUID REFERENCES reason_codes(id) ON DELETE RESTRICT,
  return_reason_notes           TEXT,

  stock_movement_id             UUID REFERENCES stock_movements(id) ON DELETE RESTRICT,

  notes                         TEXT,
  created_at                    TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE UNIQUE INDEX idx_ri_return_line ON return_items(return_id, line_number);
CREATE INDEX idx_ri_variant ON return_items(variant_id);
CREATE INDEX idx_ri_original_sale_item ON return_items(original_sale_item_id) WHERE original_sale_item_id IS NOT NULL;
CREATE INDEX idx_ri_movement ON return_items(stock_movement_id) WHERE stock_movement_id IS NOT NULL;

ALTER TABLE return_items ENABLE ROW LEVEL SECURITY;
CREATE POLICY tenant_isolation_ri ON return_items USING (tenant_id = current_tenant_id());

CREATE OR REPLACE FUNCTION prevent_return_item_modification_after_complete()
RETURNS TRIGGER AS $$
DECLARE
  return_status VARCHAR(20);
BEGIN
  SELECT status INTO return_status FROM returns WHERE id = NEW.return_id;
  IF return_status = 'COMPLETED' THEN
    IF NEW.quantity IS DISTINCT FROM OLD.quantity
       OR NEW.unit_price IS DISTINCT FROM OLD.unit_price
       OR NEW.vat_rate IS DISTINCT FROM OLD.vat_rate
       OR NEW.vat_amount IS DISTINCT FROM OLD.vat_amount
       OR NEW.unit_cost_try IS DISTINCT FROM OLD.unit_cost_try
       OR NEW.variant_id IS DISTINCT FROM OLD.variant_id THEN
      RAISE EXCEPTION 'return_items: cannot modify monetary/variant fields after return.status = COMPLETED';
    END IF;
  END IF;
  RETURN NEW;
END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER protect_completed_return_items
  BEFORE UPDATE ON return_items
  FOR EACH ROW EXECUTE FUNCTION prevent_return_item_modification_after_complete();


CREATE TABLE return_documents (
  id                            UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  tenant_id                     UUID NOT NULL REFERENCES tenants(id) ON DELETE RESTRICT,
  return_id                     UUID NOT NULL REFERENCES returns(id) ON DELETE CASCADE,

  document_type                 VARCHAR(30) NOT NULL,
  CONSTRAINT chk_rd_type CHECK (document_type IN (
    'RETURN_RECEIPT','REFUND_VOUCHER','CREDIT_NOTE','E_ARSIV_IADE'
  )),

  document_number               VARCHAR(50),

  status                        VARCHAR(30) NOT NULL DEFAULT 'PENDING_GENERATION',
  CONSTRAINT chk_rd_status CHECK (status IN (
    'PENDING_GENERATION','GENERATING','RETRY_SCHEDULED','READY','FAILED','PRINTED','SUBMITTED'
  )),

  pdf_path                      TEXT,
  CONSTRAINT chk_rd_pdf_path_nonempty CHECK (pdf_path IS NULL OR length(trim(pdf_path)) > 0),
  thumbnail_path                TEXT,

  e_document_uuid               VARCHAR(100),
  e_document_status             VARCHAR(50),
  e_document_provider           VARCHAR(50),
  e_document_response           JSONB,

  printed_at                    TIMESTAMPTZ,
  printer_id                    VARCHAR(100),

  generated_at                  TIMESTAMPTZ,
  attempt_count                 INT NOT NULL DEFAULT 0,
  next_attempt_at               TIMESTAMPTZ,
  last_error                    TEXT,
  last_attempt_at               TIMESTAMPTZ,

  created_at                    TIMESTAMPTZ NOT NULL DEFAULT now(),
  updated_at                    TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE UNIQUE INDEX idx_rd_tenant_number
  ON return_documents(tenant_id, document_type, document_number) WHERE document_number IS NOT NULL;
CREATE INDEX idx_rd_return ON return_documents(return_id);
CREATE INDEX idx_rd_status ON return_documents(status)
  WHERE status IN ('PENDING_GENERATION','GENERATING','FAILED','RETRY_SCHEDULED');
CREATE INDEX idx_rd_retry_due ON return_documents(next_attempt_at)
  WHERE status = 'RETRY_SCHEDULED' AND next_attempt_at IS NOT NULL;

ALTER TABLE return_documents ENABLE ROW LEVEL SECURITY;
CREATE POLICY tenant_isolation_rd ON return_documents USING (tenant_id = current_tenant_id());

CREATE TRIGGER set_updated_at_rd
  BEFORE UPDATE ON return_documents FOR EACH ROW EXECUTE FUNCTION set_updated_at();
