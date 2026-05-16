-- Migration 012_purchasing.sql
-- Purchasing context: purchase_invoices, purchase_invoice_items, purchase_invoice_documents,
-- purchase_returns, purchase_return_items

CREATE TABLE purchase_invoices (
  id                            UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  tenant_id                     UUID NOT NULL REFERENCES tenants(id) ON DELETE RESTRICT,
  store_id                      UUID NOT NULL REFERENCES stores(id) ON DELETE RESTRICT,

  invoice_number                VARCHAR(50),
  supplier_invoice_number       VARCHAR(50),

  status                        VARCHAR(20) NOT NULL DEFAULT 'DRAFT',
  CONSTRAINT chk_pi_status CHECK (status IN ('DRAFT','POSTED','CANCELLED')),

  supplier_id                   UUID NOT NULL REFERENCES parties(id) ON DELETE RESTRICT,

  invoice_date                  DATE NOT NULL,
  due_date                      DATE,
  CONSTRAINT chk_pi_due_date CHECK (due_date IS NULL OR due_date >= invoice_date),

  currency                      VARCHAR(10) NOT NULL DEFAULT 'TRY',
  fx_snapshot_id                UUID REFERENCES fx_snapshots(id) ON DELETE RESTRICT,
  CONSTRAINT chk_pi_fx_required CHECK (currency = 'TRY' OR fx_snapshot_id IS NOT NULL),

  subtotal                      NUMERIC(15,4) NOT NULL DEFAULT 0,
  vat_total                     NUMERIC(15,4) NOT NULL DEFAULT 0,
  total                         NUMERIC(15,4) NOT NULL DEFAULT 0,
  total_try                     NUMERIC(15,4) NOT NULL DEFAULT 0,
  CONSTRAINT chk_pi_amounts_nonneg CHECK (
    subtotal >= 0 AND vat_total >= 0 AND total >= 0 AND total_try >= 0
  ),

  posted_at                     TIMESTAMPTZ,
  posted_by_user_id             UUID REFERENCES users(id) ON DELETE RESTRICT,
  CONSTRAINT chk_pi_posted_consistency CHECK (
    (status != 'POSTED' AND posted_by_user_id IS NULL AND posted_at IS NULL)
    OR (status = 'POSTED' AND posted_by_user_id IS NOT NULL AND posted_at IS NOT NULL)
  ),

  cancelled_at                  TIMESTAMPTZ,
  cancelled_by_user_id          UUID REFERENCES users(id) ON DELETE SET NULL,
  cancellation_reason           TEXT,

  administratively_reversed_at         TIMESTAMPTZ,
  administratively_reversed_by_user_id UUID REFERENCES users(id) ON DELETE SET NULL,
  administrative_reversal_reason       TEXT,

  idempotency_key               VARCHAR(64),
  notes                         TEXT,
  metadata                      JSONB DEFAULT '{}'::jsonb,

  created_at                    TIMESTAMPTZ NOT NULL DEFAULT now(),
  created_by_user_id            UUID NOT NULL REFERENCES users(id) ON DELETE RESTRICT,
  updated_at                    TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE UNIQUE INDEX idx_pi_tenant_number
  ON purchase_invoices(tenant_id, invoice_number) WHERE invoice_number IS NOT NULL;
CREATE UNIQUE INDEX idx_pi_idempotency
  ON purchase_invoices(tenant_id, idempotency_key) WHERE idempotency_key IS NOT NULL;

-- Enterprise-grade duplicate prevention: same supplier cannot have two POSTED
-- invoices with the same supplier_invoice_number
CREATE UNIQUE INDEX idx_pi_supplier_invoice_unique
  ON purchase_invoices(supplier_id, supplier_invoice_number)
  WHERE supplier_invoice_number IS NOT NULL AND status = 'POSTED';

CREATE INDEX idx_pi_supplier ON purchase_invoices(supplier_id, invoice_date DESC);
CREATE INDEX idx_pi_status ON purchase_invoices(tenant_id, status);
CREATE INDEX idx_pi_due_date ON purchase_invoices(tenant_id, due_date)
  WHERE due_date IS NOT NULL AND status = 'POSTED';

ALTER TABLE purchase_invoices ENABLE ROW LEVEL SECURITY;
CREATE POLICY tenant_isolation_pi ON purchase_invoices USING (tenant_id = current_tenant_id());

CREATE TRIGGER set_updated_at_pi
  BEFORE UPDATE ON purchase_invoices FOR EACH ROW EXECUTE FUNCTION set_updated_at();


CREATE TABLE purchase_invoice_items (
  id                            UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  tenant_id                     UUID NOT NULL REFERENCES tenants(id) ON DELETE RESTRICT,
  purchase_invoice_id           UUID NOT NULL REFERENCES purchase_invoices(id) ON DELETE CASCADE,
  line_number                   INT NOT NULL,

  variant_id                    UUID NOT NULL REFERENCES product_variants(id) ON DELETE RESTRICT,
  variant_sku                   VARCHAR(100) NOT NULL,
  variant_display_name          VARCHAR(300) NOT NULL,

  quantity                      NUMERIC(15,4) NOT NULL,
  CONSTRAINT chk_pii_qty_pos CHECK (quantity > 0),

  unit_cost_original            NUMERIC(15,4) NOT NULL,
  CONSTRAINT chk_pii_cost_orig_nonneg CHECK (unit_cost_original >= 0),
  original_currency             VARCHAR(10),
  unit_cost_try                 NUMERIC(15,4) NOT NULL,
  CONSTRAINT chk_pii_cost_try_nonneg CHECK (unit_cost_try >= 0),
  fx_snapshot_id                UUID REFERENCES fx_snapshots(id) ON DELETE RESTRICT,

  line_discount                 NUMERIC(15,4) NOT NULL DEFAULT 0,
  CONSTRAINT chk_pii_discount_nonneg CHECK (line_discount >= 0),

  vat_rate                      NUMERIC(5,2) NOT NULL,
  CONSTRAINT chk_pii_vat_rate CHECK (vat_rate >= 0 AND vat_rate <= 100),
  vat_amount                    NUMERIC(15,4) NOT NULL DEFAULT 0,
  CONSTRAINT chk_pii_vat_amount_nonneg CHECK (vat_amount >= 0),

  line_total_original           NUMERIC(15,4) GENERATED ALWAYS AS
    (quantity * unit_cost_original - line_discount) STORED,
  line_total_try                NUMERIC(15,4) GENERATED ALWAYS AS
    (quantity * unit_cost_try) STORED,

  stock_movement_id             UUID REFERENCES stock_movements(id) ON DELETE RESTRICT,

  notes                         TEXT,
  created_at                    TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE UNIQUE INDEX idx_pii_invoice_line ON purchase_invoice_items(purchase_invoice_id, line_number);
CREATE INDEX idx_pii_variant ON purchase_invoice_items(variant_id);
CREATE INDEX idx_pii_movement ON purchase_invoice_items(stock_movement_id)
  WHERE stock_movement_id IS NOT NULL;

ALTER TABLE purchase_invoice_items ENABLE ROW LEVEL SECURITY;
CREATE POLICY tenant_isolation_pii ON purchase_invoice_items USING (tenant_id = current_tenant_id());

CREATE OR REPLACE FUNCTION prevent_pi_item_modification_after_post()
RETURNS TRIGGER AS $$
DECLARE
  pi_status VARCHAR(20);
BEGIN
  SELECT status INTO pi_status FROM purchase_invoices WHERE id = NEW.purchase_invoice_id;
  IF pi_status = 'POSTED' THEN
    IF NEW.quantity IS DISTINCT FROM OLD.quantity
       OR NEW.unit_cost_original IS DISTINCT FROM OLD.unit_cost_original
       OR NEW.unit_cost_try IS DISTINCT FROM OLD.unit_cost_try
       OR NEW.vat_rate IS DISTINCT FROM OLD.vat_rate
       OR NEW.vat_amount IS DISTINCT FROM OLD.vat_amount
       OR NEW.line_discount IS DISTINCT FROM OLD.line_discount
       OR NEW.variant_id IS DISTINCT FROM OLD.variant_id THEN
      RAISE EXCEPTION 'purchase_invoice_items: cannot modify monetary/variant fields after invoice.status = POSTED';
    END IF;
  END IF;
  RETURN NEW;
END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER protect_posted_pi_items
  BEFORE UPDATE ON purchase_invoice_items
  FOR EACH ROW EXECUTE FUNCTION prevent_pi_item_modification_after_post();


CREATE TABLE purchase_invoice_documents (
  id                            UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  tenant_id                     UUID NOT NULL REFERENCES tenants(id) ON DELETE RESTRICT,
  purchase_invoice_id           UUID NOT NULL REFERENCES purchase_invoices(id) ON DELETE CASCADE,

  document_type                 VARCHAR(30) NOT NULL,
  CONSTRAINT chk_pid_type CHECK (document_type IN (
    'SUPPLIER_INVOICE_PDF','WAYBILL','PACKING_SLIP','CUSTOMS_DOCUMENT','OTHER'
  )),

  storage_path                  TEXT NOT NULL,
  CONSTRAINT chk_pid_storage_path CHECK (length(trim(storage_path)) > 0),
  original_filename             VARCHAR(255),
  mime_type                     VARCHAR(100),
  file_size_bytes               BIGINT,

  uploaded_at                   TIMESTAMPTZ NOT NULL DEFAULT now(),
  uploaded_by_user_id           UUID REFERENCES users(id) ON DELETE SET NULL,
  notes                         TEXT
);

CREATE INDEX idx_pid_invoice ON purchase_invoice_documents(purchase_invoice_id);

ALTER TABLE purchase_invoice_documents ENABLE ROW LEVEL SECURITY;
CREATE POLICY tenant_isolation_pid ON purchase_invoice_documents USING (tenant_id = current_tenant_id());


CREATE TABLE purchase_returns (
  id                            UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  tenant_id                     UUID NOT NULL REFERENCES tenants(id) ON DELETE RESTRICT,
  store_id                      UUID NOT NULL REFERENCES stores(id) ON DELETE RESTRICT,

  return_number                 VARCHAR(50),

  original_invoice_id           UUID NOT NULL REFERENCES purchase_invoices(id) ON DELETE RESTRICT,
  supplier_id                   UUID NOT NULL REFERENCES parties(id) ON DELETE RESTRICT,

  status                        VARCHAR(20) NOT NULL DEFAULT 'DRAFT',
  CONSTRAINT chk_pr_status CHECK (status IN ('DRAFT','POSTED','CANCELLED')),

  return_date                   DATE NOT NULL DEFAULT CURRENT_DATE,

  currency                      VARCHAR(10) NOT NULL DEFAULT 'TRY',
  fx_snapshot_id                UUID REFERENCES fx_snapshots(id) ON DELETE RESTRICT,
  CONSTRAINT chk_pr_fx_required CHECK (currency = 'TRY' OR fx_snapshot_id IS NOT NULL),

  subtotal                      NUMERIC(15,4) NOT NULL DEFAULT 0,
  vat_total                     NUMERIC(15,4) NOT NULL DEFAULT 0,
  total                         NUMERIC(15,4) NOT NULL DEFAULT 0,
  total_try                     NUMERIC(15,4) NOT NULL DEFAULT 0,
  CONSTRAINT chk_pr_amounts_nonneg CHECK (
    subtotal >= 0 AND vat_total >= 0 AND total >= 0 AND total_try >= 0
  ),

  reason_code                   VARCHAR(50),
  reason_notes                  TEXT,

  posted_at                     TIMESTAMPTZ,
  posted_by_user_id             UUID REFERENCES users(id) ON DELETE RESTRICT,
  CONSTRAINT chk_pr_posted_consistency CHECK (
    (status != 'POSTED' AND posted_by_user_id IS NULL AND posted_at IS NULL)
    OR (status = 'POSTED' AND posted_by_user_id IS NOT NULL AND posted_at IS NOT NULL)
  ),

  cancelled_at                  TIMESTAMPTZ,
  cancelled_by_user_id          UUID REFERENCES users(id) ON DELETE SET NULL,

  idempotency_key               VARCHAR(64),
  notes                         TEXT,
  metadata                      JSONB DEFAULT '{}'::jsonb,

  created_at                    TIMESTAMPTZ NOT NULL DEFAULT now(),
  created_by_user_id            UUID NOT NULL REFERENCES users(id) ON DELETE RESTRICT,
  updated_at                    TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE UNIQUE INDEX idx_pr_tenant_number
  ON purchase_returns(tenant_id, return_number) WHERE return_number IS NOT NULL;
CREATE UNIQUE INDEX idx_pr_idempotency
  ON purchase_returns(tenant_id, idempotency_key) WHERE idempotency_key IS NOT NULL;
CREATE INDEX idx_pr_original_invoice ON purchase_returns(original_invoice_id);
CREATE INDEX idx_pr_supplier ON purchase_returns(supplier_id, return_date DESC);
CREATE INDEX idx_pr_status ON purchase_returns(tenant_id, status);

ALTER TABLE purchase_returns ENABLE ROW LEVEL SECURITY;
CREATE POLICY tenant_isolation_pr ON purchase_returns USING (tenant_id = current_tenant_id());

CREATE TRIGGER set_updated_at_pr
  BEFORE UPDATE ON purchase_returns FOR EACH ROW EXECUTE FUNCTION set_updated_at();


CREATE TABLE purchase_return_items (
  id                            UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  tenant_id                     UUID NOT NULL REFERENCES tenants(id) ON DELETE RESTRICT,
  purchase_return_id            UUID NOT NULL REFERENCES purchase_returns(id) ON DELETE CASCADE,
  line_number                   INT NOT NULL,

  variant_id                    UUID NOT NULL REFERENCES product_variants(id) ON DELETE RESTRICT,
  variant_sku                   VARCHAR(100) NOT NULL,
  variant_display_name          VARCHAR(300) NOT NULL,

  original_pi_item_id           UUID NOT NULL REFERENCES purchase_invoice_items(id) ON DELETE RESTRICT,

  quantity                      NUMERIC(15,4) NOT NULL,
  CONSTRAINT chk_pri_qty_pos CHECK (quantity > 0),

  unit_cost_original            NUMERIC(15,4) NOT NULL,
  CONSTRAINT chk_pri_cost_orig_nonneg CHECK (unit_cost_original >= 0),
  original_currency             VARCHAR(10),
  unit_cost_try                 NUMERIC(15,4) NOT NULL,
  CONSTRAINT chk_pri_cost_try_nonneg CHECK (unit_cost_try >= 0),

  vat_rate                      NUMERIC(5,2) NOT NULL,
  CONSTRAINT chk_pri_vat_rate CHECK (vat_rate >= 0 AND vat_rate <= 100),
  vat_amount                    NUMERIC(15,4) NOT NULL DEFAULT 0,
  CONSTRAINT chk_pri_vat_amount_nonneg CHECK (vat_amount >= 0),

  line_total_try                NUMERIC(15,4) GENERATED ALWAYS AS (quantity * unit_cost_try) STORED,

  stock_movement_id             UUID REFERENCES stock_movements(id) ON DELETE RESTRICT,

  notes                         TEXT,
  created_at                    TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE UNIQUE INDEX idx_pri_return_line ON purchase_return_items(purchase_return_id, line_number);
CREATE INDEX idx_pri_variant ON purchase_return_items(variant_id);
CREATE INDEX idx_pri_original_item ON purchase_return_items(original_pi_item_id);
CREATE INDEX idx_pri_movement ON purchase_return_items(stock_movement_id) WHERE stock_movement_id IS NOT NULL;

ALTER TABLE purchase_return_items ENABLE ROW LEVEL SECURITY;
CREATE POLICY tenant_isolation_pri ON purchase_return_items USING (tenant_id = current_tenant_id());
