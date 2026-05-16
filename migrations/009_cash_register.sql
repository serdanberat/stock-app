-- Migration 009_cash_register.sql
-- Cash register context: cash_registers, register_sessions, cash_movements,
-- z_reports, z_report_number_sequence, z_report_sequence_audit
-- Depends on: previous migrations (tenants, stores, users, currencies, fx_snapshots, payments)

CREATE TABLE cash_registers (
  id                            UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  tenant_id                     UUID NOT NULL REFERENCES tenants(id) ON DELETE RESTRICT,
  store_id                      UUID NOT NULL REFERENCES stores(id) ON DELETE RESTRICT,

  code                          VARCHAR(20) NOT NULL,
  display_name                  VARCHAR(100) NOT NULL,
  terminal_id                   VARCHAR(100),

  default_currency              VARCHAR(10) NOT NULL DEFAULT 'TRY' REFERENCES currencies(code) ON DELETE RESTRICT,

  status                        VARCHAR(20) NOT NULL DEFAULT 'ACTIVE',
  CONSTRAINT chk_cr_status CHECK (status IN ('ACTIVE','INACTIVE','ARCHIVED')),

  created_at                    TIMESTAMPTZ NOT NULL DEFAULT now(),
  updated_at                    TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE UNIQUE INDEX idx_cr_store_code ON cash_registers(store_id, code);
CREATE INDEX idx_cr_status ON cash_registers(tenant_id, status);

ALTER TABLE cash_registers ENABLE ROW LEVEL SECURITY;
CREATE POLICY tenant_isolation_cr ON cash_registers USING (tenant_id = current_tenant_id());

CREATE TRIGGER set_updated_at_cr
  BEFORE UPDATE ON cash_registers FOR EACH ROW EXECUTE FUNCTION set_updated_at();


CREATE TABLE register_sessions (
  id                            UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  tenant_id                     UUID NOT NULL REFERENCES tenants(id) ON DELETE RESTRICT,
  store_id                      UUID NOT NULL REFERENCES stores(id) ON DELETE RESTRICT,
  cash_register_id              UUID NOT NULL REFERENCES cash_registers(id) ON DELETE RESTRICT,

  session_number                VARCHAR(50),

  status                        VARCHAR(20) NOT NULL DEFAULT 'OPEN',
  CONSTRAINT chk_rs_status CHECK (status IN ('OPEN','CLOSING','CLOSED')),

  opened_at                     TIMESTAMPTZ NOT NULL DEFAULT now(),
  opened_by_user_id             UUID NOT NULL REFERENCES users(id) ON DELETE RESTRICT,

  closing_started_at            TIMESTAMPTZ,
  closing_initiated_by_user_id  UUID REFERENCES users(id) ON DELETE SET NULL,

  closed_at                     TIMESTAMPTZ,
  closed_by_user_id             UUID REFERENCES users(id) ON DELETE SET NULL,

  reopened_at                   TIMESTAMPTZ,
  reopened_by_user_id           UUID REFERENCES users(id) ON DELETE SET NULL,
  reopen_reason                 TEXT,
  reopen_count                  INT NOT NULL DEFAULT 0,

  opening_float                 NUMERIC(15,4) NOT NULL DEFAULT 0,
  CONSTRAINT chk_rs_opening_float_nonneg CHECK (opening_float >= 0),
  expected_cash                 NUMERIC(15,4),
  counted_cash                  NUMERIC(15,4),
  cash_variance                 NUMERIC(15,4) GENERATED ALWAYS AS (counted_cash - expected_cash) STORED,

  total_sales                   NUMERIC(15,4) NOT NULL DEFAULT 0,
  total_returns                 NUMERIC(15,4) NOT NULL DEFAULT 0,
  total_cash_in                 NUMERIC(15,4) NOT NULL DEFAULT 0,
  total_cash_out                NUMERIC(15,4) NOT NULL DEFAULT 0,

  CONSTRAINT chk_rs_totals_nonneg CHECK (
    total_sales >= 0 AND total_returns >= 0 AND
    total_cash_in >= 0 AND total_cash_out >= 0
  ),

  tender_breakdown              JSONB,
  vat_breakdown                 JSONB,

  close_notes                   TEXT,
  variance_notes                TEXT,

  idempotency_key_close         VARCHAR(64),

  z_report_id                   UUID,

  created_at                    TIMESTAMPTZ NOT NULL DEFAULT now(),
  updated_at                    TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE UNIQUE INDEX idx_rs_one_open_per_register
  ON register_sessions(cash_register_id) WHERE status = 'OPEN';
CREATE UNIQUE INDEX idx_rs_tenant_number
  ON register_sessions(tenant_id, session_number) WHERE session_number IS NOT NULL;
CREATE UNIQUE INDEX idx_rs_idempotency_close
  ON register_sessions(tenant_id, idempotency_key_close) WHERE idempotency_key_close IS NOT NULL;

CREATE INDEX idx_rs_store ON register_sessions(store_id, opened_at DESC);
CREATE INDEX idx_rs_status ON register_sessions(tenant_id, status);
CREATE INDEX idx_rs_closing ON register_sessions(closing_started_at) WHERE status = 'CLOSING';

ALTER TABLE register_sessions ENABLE ROW LEVEL SECURITY;
CREATE POLICY tenant_isolation_rs ON register_sessions USING (tenant_id = current_tenant_id());

CREATE TRIGGER set_updated_at_rs
  BEFORE UPDATE ON register_sessions FOR EACH ROW EXECUTE FUNCTION set_updated_at();

-- Now add deferred FK from payments
ALTER TABLE payments
  ADD CONSTRAINT fk_payments_register_session
  FOREIGN KEY (register_session_id) REFERENCES register_sessions(id) ON DELETE RESTRICT;


CREATE TABLE cash_movements (
  id                            UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  tenant_id                     UUID NOT NULL REFERENCES tenants(id) ON DELETE RESTRICT,
  register_session_id           UUID NOT NULL REFERENCES register_sessions(id) ON DELETE RESTRICT,

  movement_type                 VARCHAR(50) NOT NULL,
  CONSTRAINT chk_cm_type CHECK (movement_type IN (
    'OPENING_FLOAT',
    'SALE_CASH_IN','SALE_CARD','SALE_TRANSFER',
    'REFUND_CASH','REFUND_CARD','CHANGE_GIVEN',
    'CASH_IN_OTHER','CASH_OUT_OTHER',
    'DEPOSIT_TO_BANK','OWNER_DRAW',
    'EXPENSE','CASH_COUNT_VARIANCE'
  )),

  amount                        NUMERIC(15,4) NOT NULL,
  CONSTRAINT chk_cm_amount_nonzero CHECK (amount != 0),

  tender_type                   VARCHAR(30) NOT NULL,
  CONSTRAINT chk_cm_tender CHECK (tender_type IN (
    'CASH','CARD','BANK_TRANSFER','CHECK','OTHER'
  )),

  currency                      VARCHAR(10) NOT NULL DEFAULT 'TRY' REFERENCES currencies(code) ON DELETE RESTRICT,
  amount_try                    NUMERIC(15,4) NOT NULL,
  CONSTRAINT chk_cm_amount_try_nonneg CHECK (amount_try >= 0),
  fx_snapshot_id                UUID REFERENCES fx_snapshots(id) ON DELETE RESTRICT,

  reference_type                VARCHAR(50),
  reference_id                  UUID,

  notes                         TEXT,
  actor_user_id                 UUID NOT NULL REFERENCES users(id) ON DELETE RESTRICT,
  occurred_at                   TIMESTAMPTZ NOT NULL DEFAULT now(),
  recorded_at                   TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE INDEX idx_cm_session_time ON cash_movements(register_session_id, occurred_at);
CREATE INDEX idx_cm_reference ON cash_movements(reference_type, reference_id)
  WHERE reference_type IS NOT NULL;
CREATE INDEX idx_cm_type ON cash_movements(register_session_id, movement_type);

ALTER TABLE cash_movements ENABLE ROW LEVEL SECURITY;
CREATE POLICY tenant_isolation_cm ON cash_movements USING (tenant_id = current_tenant_id());

REVOKE UPDATE, DELETE ON cash_movements FROM PUBLIC;

CREATE TRIGGER no_modify_cash_movements
  BEFORE UPDATE OR DELETE ON cash_movements
  FOR EACH ROW EXECUTE FUNCTION raise_append_only_violation();


CREATE TABLE z_report_number_sequence (
  tenant_id                     UUID NOT NULL REFERENCES tenants(id) ON DELETE RESTRICT,
  store_id                      UUID NOT NULL REFERENCES stores(id) ON DELETE RESTRICT,
  year                          INT NOT NULL,
  CONSTRAINT chk_zrns_year CHECK (year >= 2020 AND year <= 2100),

  last_number                   BIGINT NOT NULL DEFAULT 0,

  PRIMARY KEY (tenant_id, store_id, year)
);

ALTER TABLE z_report_number_sequence ENABLE ROW LEVEL SECURITY;
CREATE POLICY tenant_isolation_zrns ON z_report_number_sequence USING (tenant_id = current_tenant_id());


CREATE TABLE z_reports (
  id                            UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  tenant_id                     UUID NOT NULL REFERENCES tenants(id) ON DELETE RESTRICT,
  store_id                      UUID NOT NULL REFERENCES stores(id) ON DELETE RESTRICT,
  register_id                   UUID NOT NULL REFERENCES cash_registers(id) ON DELETE RESTRICT,
  session_id                    UUID NOT NULL REFERENCES register_sessions(id) ON DELETE RESTRICT,

  report_number                 VARCHAR(100) NOT NULL,
  sequence_year                 INT NOT NULL,
  sequence_value                BIGINT NOT NULL,

  opened_at                     TIMESTAMPTZ NOT NULL,
  closed_at                     TIMESTAMPTZ NOT NULL,
  opened_by_user_id             UUID REFERENCES users(id) ON DELETE SET NULL,
  closed_by_user_id             UUID REFERENCES users(id) ON DELETE SET NULL,

  opening_float                 NUMERIC(15,4) NOT NULL,
  expected_cash                 NUMERIC(15,4) NOT NULL,
  counted_cash                  NUMERIC(15,4) NOT NULL,
  variance                      NUMERIC(15,4) NOT NULL,

  total_sales_count             INT NOT NULL DEFAULT 0,
  total_sales_amount            NUMERIC(15,4) NOT NULL DEFAULT 0,
  total_returns_count           INT NOT NULL DEFAULT 0,
  total_returns_amount          NUMERIC(15,4) NOT NULL DEFAULT 0,

  CONSTRAINT chk_zr_totals_nonneg CHECK (
    total_sales_count >= 0 AND total_returns_count >= 0 AND
    total_sales_amount >= 0 AND total_returns_amount >= 0
  ),

  tender_breakdown              JSONB NOT NULL,
  vat_breakdown                 JSONB NOT NULL,

  pdf_path                      TEXT,
  CONSTRAINT chk_zr_pdf_nonempty CHECK (pdf_path IS NULL OR length(trim(pdf_path)) > 0),

  status                        VARCHAR(30) NOT NULL DEFAULT 'PENDING_GENERATION',
  CONSTRAINT chk_zr_status CHECK (status IN (
    'PENDING_GENERATION','GENERATING','RETRY_SCHEDULED','READY','FAILED','INVALIDATED'
  )),

  invalidated_at                TIMESTAMPTZ,
  invalidated_reason            TEXT,
  invalidated_by_user_id        UUID REFERENCES users(id) ON DELETE SET NULL,

  sealed_at                     TIMESTAMPTZ NOT NULL DEFAULT now(),

  generated_at                  TIMESTAMPTZ,
  attempt_count                 INT NOT NULL DEFAULT 0,
  next_attempt_at               TIMESTAMPTZ,
  last_error                    TEXT,

  created_at                    TIMESTAMPTZ NOT NULL DEFAULT now(),
  updated_at                    TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE UNIQUE INDEX idx_zr_unique_per_session ON z_reports(session_id);
CREATE UNIQUE INDEX idx_zr_unique_number
  ON z_reports(tenant_id, store_id, sequence_year, sequence_value);
CREATE UNIQUE INDEX idx_zr_report_number ON z_reports(tenant_id, report_number);

CREATE INDEX idx_zr_store_time ON z_reports(store_id, sealed_at DESC);
CREATE INDEX idx_zr_status ON z_reports(status)
  WHERE status IN ('PENDING_GENERATION','GENERATING','RETRY_SCHEDULED');
CREATE INDEX idx_zr_invalidated ON z_reports(tenant_id) WHERE invalidated_at IS NOT NULL;

ALTER TABLE z_reports ENABLE ROW LEVEL SECURITY;
CREATE POLICY tenant_isolation_zr ON z_reports USING (tenant_id = current_tenant_id());

REVOKE DELETE ON z_reports FROM PUBLIC;

CREATE OR REPLACE FUNCTION prevent_z_report_deletion()
RETURNS TRIGGER AS $$
BEGIN
  RAISE EXCEPTION 'z_reports cannot be deleted (regulatory requirement)';
END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER no_delete_z_reports
  BEFORE DELETE ON z_reports
  FOR EACH ROW EXECUTE FUNCTION prevent_z_report_deletion();

CREATE TRIGGER set_updated_at_zr
  BEFORE UPDATE ON z_reports FOR EACH ROW EXECUTE FUNCTION set_updated_at();

-- Now resolve the forward reference register_sessions.z_report_id
ALTER TABLE register_sessions
  ADD CONSTRAINT fk_rs_z_report
  FOREIGN KEY (z_report_id) REFERENCES z_reports(id) ON DELETE RESTRICT;


CREATE TABLE z_report_sequence_audit (
  id                            BIGSERIAL PRIMARY KEY,
  tenant_id                     UUID NOT NULL REFERENCES tenants(id) ON DELETE RESTRICT,
  store_id                      UUID NOT NULL REFERENCES stores(id) ON DELETE RESTRICT,
  sequence_year                 INT NOT NULL,
  allocated_number              BIGINT NOT NULL,
  allocated_at                  TIMESTAMPTZ NOT NULL DEFAULT now(),

  session_id                    UUID REFERENCES register_sessions(id) ON DELETE SET NULL,
  status                        VARCHAR(30) NOT NULL DEFAULT 'ALLOCATED',
  CONSTRAINT chk_zrsa_status CHECK (status IN ('ALLOCATED','COMMITTED','NO_SESSION_FOUND'))
);

CREATE INDEX idx_zrsa_lookup
  ON z_report_sequence_audit(tenant_id, store_id, sequence_year, allocated_number);
CREATE INDEX idx_zrsa_status ON z_report_sequence_audit(status) WHERE status != 'COMMITTED';

ALTER TABLE z_report_sequence_audit ENABLE ROW LEVEL SECURITY;
CREATE POLICY tenant_isolation_zrsa ON z_report_sequence_audit USING (tenant_id = current_tenant_id());
