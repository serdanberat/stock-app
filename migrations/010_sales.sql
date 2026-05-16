-- Migration 010_sales.sql
-- Sales context: sales, sale_items, sale_payments, payment_attempts, sale_documents,
-- document_sequences

CREATE TABLE document_sequences (
  tenant_id                     UUID NOT NULL REFERENCES tenants(id) ON DELETE RESTRICT,
  store_id                      UUID NOT NULL REFERENCES stores(id) ON DELETE RESTRICT,
  document_type                 VARCHAR(30) NOT NULL,
  year                          INT NOT NULL,
  CONSTRAINT chk_ds_year CHECK (year >= 2020 AND year <= 2100),
  last_number                   BIGINT NOT NULL DEFAULT 0,
  PRIMARY KEY (tenant_id, store_id, document_type, year)
);

ALTER TABLE document_sequences ENABLE ROW LEVEL SECURITY;
CREATE POLICY tenant_isolation_ds ON document_sequences USING (tenant_id = current_tenant_id());

COMMENT ON TABLE document_sequences IS
  'Gap-free sequence allocator per (tenant, store, document_type, year). '
  'UPDATE-based allocation: rollback undoes increment, no gaps. '
  'CAVEAT: hot row under high concurrency (>50 commits/sec/store). '
  'MVP acceptable for ~100 sales/min/store. '
  'ROADMAP v1.1+: sharding strategies if contention measured.';


CREATE TABLE sales (
  id                            UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  tenant_id                     UUID NOT NULL REFERENCES tenants(id) ON DELETE RESTRICT,
  store_id                      UUID NOT NULL REFERENCES stores(id) ON DELETE RESTRICT,
  register_session_id           UUID REFERENCES register_sessions(id) ON DELETE RESTRICT,

  sale_number                   VARCHAR(50),

  status                        VARCHAR(20) NOT NULL DEFAULT 'DRAFT',
  CONSTRAINT chk_sale_status CHECK (status IN (
    'DRAFT','AWAITING_PAYMENT','COMPLETED','VOIDED','ABANDONED'
  )),

  cashier_user_id               UUID NOT NULL REFERENCES users(id) ON DELETE RESTRICT,
  customer_id                   UUID REFERENCES parties(id) ON DELETE RESTRICT,

  currency                      VARCHAR(10) NOT NULL DEFAULT 'TRY',
  fx_snapshot_id                UUID REFERENCES fx_snapshots(id) ON DELETE RESTRICT,

  subtotal                      NUMERIC(15,4) NOT NULL DEFAULT 0,
  cart_discount                 NUMERIC(15,4) NOT NULL DEFAULT 0,
  cart_discount_pct             NUMERIC(5,2),
  vat_total                     NUMERIC(15,4) NOT NULL DEFAULT 0,
  total                         NUMERIC(15,4) NOT NULL DEFAULT 0,
  total_try                     NUMERIC(15,4) NOT NULL DEFAULT 0,

  CONSTRAINT chk_sale_amounts_nonneg CHECK (
    subtotal >= 0 AND cart_discount >= 0 AND vat_total >= 0 AND total >= 0 AND total_try >= 0
  ),
  CONSTRAINT chk_sale_discount_pct CHECK (
    cart_discount_pct IS NULL OR (cart_discount_pct >= 0 AND cart_discount_pct <= 100)
  ),
  CONSTRAINT chk_sale_fx_required CHECK (
    currency = 'TRY' OR fx_snapshot_id IS NOT NULL
  ),

  administratively_reversed_at         TIMESTAMPTZ,
  administratively_reversed_by_user_id UUID REFERENCES users(id) ON DELETE SET NULL,
  administrative_reversal_reason       TEXT,
  administrative_reversal_ticket_id    UUID,

  terminal_pending                BOOLEAN NOT NULL DEFAULT false,
  terminal_pending_since          TIMESTAMPTZ,
  terminal_pending_metadata       JSONB,
  requires_manual_reconciliation  BOOLEAN NOT NULL DEFAULT false,

  idempotency_key               VARCHAR(64),

  exchange_group_id             UUID,

  notes                         TEXT,
  metadata                      JSONB NOT NULL DEFAULT '{}'::jsonb,

  last_activity_at              TIMESTAMPTZ NOT NULL DEFAULT now(),
  completed_at                  TIMESTAMPTZ,
  completed_by_user_id          UUID REFERENCES users(id) ON DELETE SET NULL,
  voided_at                     TIMESTAMPTZ,
  voided_by_user_id             UUID REFERENCES users(id) ON DELETE SET NULL,
  void_reason                   TEXT,
  abandoned_at                  TIMESTAMPTZ,

  created_at                    TIMESTAMPTZ NOT NULL DEFAULT now(),
  updated_at                    TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE UNIQUE INDEX idx_sales_tenant_number
  ON sales(tenant_id, sale_number) WHERE sale_number IS NOT NULL;
CREATE UNIQUE INDEX idx_sales_idempotency
  ON sales(tenant_id, idempotency_key) WHERE idempotency_key IS NOT NULL;
CREATE UNIQUE INDEX idx_sales_exchange_group_unique
  ON sales(exchange_group_id) WHERE exchange_group_id IS NOT NULL;

CREATE INDEX idx_sales_status ON sales(tenant_id, status);
CREATE INDEX idx_sales_register_session ON sales(register_session_id, status)
  WHERE register_session_id IS NOT NULL;
CREATE INDEX idx_sales_customer ON sales(customer_id, completed_at DESC)
  WHERE customer_id IS NOT NULL;
CREATE INDEX idx_sales_completed_at ON sales(tenant_id, completed_at DESC)
  WHERE status = 'COMPLETED';
CREATE INDEX idx_sales_terminal_pending ON sales(tenant_id, terminal_pending_since)
  WHERE terminal_pending = true;
CREATE INDEX idx_sales_manual_recon ON sales(tenant_id)
  WHERE requires_manual_reconciliation = true;
CREATE INDEX idx_sales_idle ON sales(last_activity_at)
  WHERE status IN ('DRAFT','AWAITING_PAYMENT');
CREATE INDEX idx_sales_admin_reversed ON sales(tenant_id, administratively_reversed_at DESC)
  WHERE administratively_reversed_at IS NOT NULL;

ALTER TABLE sales ENABLE ROW LEVEL SECURITY;
CREATE POLICY tenant_isolation_sales ON sales USING (tenant_id = current_tenant_id());

CREATE TRIGGER set_updated_at_sales
  BEFORE UPDATE ON sales FOR EACH ROW EXECUTE FUNCTION set_updated_at();


CREATE TABLE sale_items (
  id                            UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  tenant_id                     UUID NOT NULL REFERENCES tenants(id) ON DELETE RESTRICT,
  sale_id                       UUID NOT NULL REFERENCES sales(id) ON DELETE CASCADE,

  line_number                   INT NOT NULL,
  variant_id                    UUID NOT NULL REFERENCES product_variants(id) ON DELETE RESTRICT,

  variant_sku                   VARCHAR(100) NOT NULL,
  variant_display_name          VARCHAR(300) NOT NULL,

  quantity                      NUMERIC(15,4) NOT NULL,
  CONSTRAINT chk_si_qty_pos CHECK (quantity > 0),

  unit_price                    NUMERIC(15,4) NOT NULL,
  CONSTRAINT chk_si_price_nonneg CHECK (unit_price >= 0),

  line_discount                 NUMERIC(15,4) NOT NULL DEFAULT 0,
  line_discount_pct             NUMERIC(5,2),
  CONSTRAINT chk_si_discount_nonneg CHECK (line_discount >= 0),
  CONSTRAINT chk_si_discount_pct CHECK (
    line_discount_pct IS NULL OR (line_discount_pct >= 0 AND line_discount_pct <= 100)
  ),

  vat_rate                      NUMERIC(5,2) NOT NULL,
  CONSTRAINT chk_si_vat_rate CHECK (vat_rate >= 0 AND vat_rate <= 100),
  vat_amount                    NUMERIC(15,4) NOT NULL DEFAULT 0,
  CONSTRAINT chk_si_vat_amount_nonneg CHECK (vat_amount >= 0),

  unit_cost_try                 NUMERIC(15,4) NOT NULL,
  CONSTRAINT chk_si_cost_nonneg CHECK (unit_cost_try >= 0),

  line_total                    NUMERIC(15,4) GENERATED ALWAYS AS
    (quantity * unit_price - line_discount) STORED,

  salesperson_user_id           UUID REFERENCES users(id) ON DELETE SET NULL,

  stock_movement_id             UUID REFERENCES stock_movements(id) ON DELETE RESTRICT,

  notes                         TEXT,
  metadata                      JSONB DEFAULT '{}'::jsonb,
  created_at                    TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE UNIQUE INDEX idx_si_sale_line ON sale_items(sale_id, line_number);
CREATE INDEX idx_si_variant ON sale_items(variant_id);
CREATE INDEX idx_si_salesperson ON sale_items(salesperson_user_id)
  WHERE salesperson_user_id IS NOT NULL;
CREATE INDEX idx_si_movement ON sale_items(stock_movement_id) WHERE stock_movement_id IS NOT NULL;

ALTER TABLE sale_items ENABLE ROW LEVEL SECURITY;
CREATE POLICY tenant_isolation_si ON sale_items USING (tenant_id = current_tenant_id());

CREATE OR REPLACE FUNCTION prevent_sale_item_modification_after_complete()
RETURNS TRIGGER AS $$
DECLARE
  sale_status VARCHAR(20);
BEGIN
  SELECT status INTO sale_status FROM sales WHERE id = NEW.sale_id;
  IF sale_status = 'COMPLETED' THEN
    IF NEW.quantity IS DISTINCT FROM OLD.quantity
       OR NEW.unit_price IS DISTINCT FROM OLD.unit_price
       OR NEW.line_discount IS DISTINCT FROM OLD.line_discount
       OR NEW.vat_rate IS DISTINCT FROM OLD.vat_rate
       OR NEW.vat_amount IS DISTINCT FROM OLD.vat_amount
       OR NEW.unit_cost_try IS DISTINCT FROM OLD.unit_cost_try
       OR NEW.variant_id IS DISTINCT FROM OLD.variant_id THEN
      RAISE EXCEPTION 'sale_items: cannot modify monetary/variant fields after sale.status = COMPLETED';
    END IF;
  END IF;
  RETURN NEW;
END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER protect_completed_sale_items
  BEFORE UPDATE ON sale_items
  FOR EACH ROW EXECUTE FUNCTION prevent_sale_item_modification_after_complete();


CREATE TABLE sale_payments (
  id                            UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  tenant_id                     UUID NOT NULL REFERENCES tenants(id) ON DELETE RESTRICT,
  sale_id                       UUID NOT NULL REFERENCES sales(id) ON DELETE CASCADE,

  payment_id                    UUID REFERENCES payments(id) ON DELETE RESTRICT,

  tender_type                   VARCHAR(30) NOT NULL,
  CONSTRAINT chk_sp_tender CHECK (tender_type IN (
    'CASH','BANK_TRANSFER','CARD','CHECK','PROMISSORY_NOTE',
    'CUSTOMER_BALANCE','GIFT_CARD','LOYALTY_POINTS'
  )),

  amount                        NUMERIC(15,4) NOT NULL,
  CONSTRAINT chk_sp_amount_pos CHECK (amount > 0),

  currency                      VARCHAR(10) NOT NULL,
  amount_try                    NUMERIC(15,4) NOT NULL,
  CONSTRAINT chk_sp_amount_try_nonneg CHECK (amount_try >= 0),
  fx_snapshot_id                UUID REFERENCES fx_snapshots(id) ON DELETE RESTRICT,

  reference                     VARCHAR(100),
  tender_metadata               JSONB DEFAULT '{}'::jsonb,
  bank_account_id               UUID,

  recorded_at                   TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE INDEX idx_sp_sale ON sale_payments(sale_id);
CREATE INDEX idx_sp_payment ON sale_payments(payment_id) WHERE payment_id IS NOT NULL;
CREATE INDEX idx_sp_tender ON sale_payments(tender_type);

ALTER TABLE sale_payments ENABLE ROW LEVEL SECURITY;
CREATE POLICY tenant_isolation_sp ON sale_payments USING (tenant_id = current_tenant_id());


CREATE TABLE payment_attempts (
  id                            UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  tenant_id                     UUID NOT NULL REFERENCES tenants(id) ON DELETE RESTRICT,
  sale_id                       UUID NOT NULL REFERENCES sales(id) ON DELETE CASCADE,
  attempt_number                INT NOT NULL,

  started_at                    TIMESTAMPTZ NOT NULL DEFAULT now(),
  ended_at                      TIMESTAMPTZ,

  outcome                       VARCHAR(30),
  CONSTRAINT chk_pa_outcome CHECK (outcome IS NULL OR outcome IN (
    'ABANDONED_TIMEOUT','CANCELLED_BY_CASHIER','COMPLETED','FAILED','ROLLED_BACK_TO_DRAFT'
  )),

  tender_attempts               JSONB NOT NULL DEFAULT '[]'::jsonb,

  abandonment_reason            TEXT,
  failure_reason                TEXT,

  audit_metadata                JSONB DEFAULT '{}'::jsonb,
  created_at                    TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE UNIQUE INDEX idx_pa_sale_attempt ON payment_attempts(sale_id, attempt_number);
CREATE INDEX idx_pa_outcome ON payment_attempts(outcome) WHERE outcome IS NOT NULL;
CREATE INDEX idx_pa_failed_time ON payment_attempts(tenant_id, started_at DESC)
  WHERE outcome IN ('FAILED','ABANDONED_TIMEOUT');

ALTER TABLE payment_attempts ENABLE ROW LEVEL SECURITY;
CREATE POLICY tenant_isolation_pa_att ON payment_attempts USING (tenant_id = current_tenant_id());

CREATE OR REPLACE FUNCTION prevent_payment_attempt_modification_after_outcome()
RETURNS TRIGGER AS $$
BEGIN
  IF OLD.outcome IS NOT NULL THEN
    RAISE EXCEPTION 'payment_attempts: cannot modify after outcome is set';
  END IF;
  RETURN NEW;
END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER protect_completed_payment_attempts
  BEFORE UPDATE ON payment_attempts
  FOR EACH ROW EXECUTE FUNCTION prevent_payment_attempt_modification_after_outcome();


CREATE TABLE sale_documents (
  id                            UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  tenant_id                     UUID NOT NULL REFERENCES tenants(id) ON DELETE RESTRICT,
  sale_id                       UUID NOT NULL REFERENCES sales(id) ON DELETE CASCADE,

  document_type                 VARCHAR(30) NOT NULL,
  CONSTRAINT chk_sd_type CHECK (document_type IN ('RECEIPT','INVOICE','E_ARSIV','E_FATURA')),

  document_number               VARCHAR(50),

  status                        VARCHAR(30) NOT NULL DEFAULT 'PENDING_GENERATION',
  CONSTRAINT chk_sd_status CHECK (status IN (
    'PENDING_GENERATION','GENERATING','RETRY_SCHEDULED','READY','FAILED','PRINTED','SUBMITTED'
  )),

  pdf_path                      TEXT,
  CONSTRAINT chk_sd_pdf_path_nonempty CHECK (pdf_path IS NULL OR length(trim(pdf_path)) > 0),
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

CREATE UNIQUE INDEX idx_sd_tenant_number
  ON sale_documents(tenant_id, document_type, document_number) WHERE document_number IS NOT NULL;
CREATE INDEX idx_sd_sale ON sale_documents(sale_id);
CREATE INDEX idx_sd_status ON sale_documents(status)
  WHERE status IN ('PENDING_GENERATION','GENERATING','FAILED','RETRY_SCHEDULED');
CREATE INDEX idx_sd_pending_workers ON sale_documents(created_at) WHERE status = 'PENDING_GENERATION';
CREATE INDEX idx_sd_retry_due ON sale_documents(next_attempt_at)
  WHERE status = 'RETRY_SCHEDULED' AND next_attempt_at IS NOT NULL;

ALTER TABLE sale_documents ENABLE ROW LEVEL SECURITY;
CREATE POLICY tenant_isolation_sd ON sale_documents USING (tenant_id = current_tenant_id());

CREATE TRIGGER set_updated_at_sd
  BEFORE UPDATE ON sale_documents FOR EACH ROW EXECUTE FUNCTION set_updated_at();
