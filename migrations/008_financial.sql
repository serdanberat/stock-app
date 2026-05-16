-- Migration 008_financial.sql
-- Financial context: account_profiles, account_movements (append-only),
-- account_balances, payments, payment_allocations, account_aging

CREATE TABLE account_profiles (
  id                            UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  tenant_id                     UUID NOT NULL REFERENCES tenants(id) ON DELETE RESTRICT,
  party_id                      UUID NOT NULL REFERENCES parties(id) ON DELETE RESTRICT,
  party_role                    VARCHAR(20) NOT NULL,
  CONSTRAINT chk_ap_role CHECK (party_role IN ('CUSTOMER','SUPPLIER')),
  currency                      VARCHAR(10) NOT NULL REFERENCES currencies(code) ON DELETE RESTRICT,

  credit_limit                  NUMERIC(15,4),
  CONSTRAINT chk_ap_credit_limit CHECK (credit_limit IS NULL OR credit_limit >= 0),
  credit_used                   NUMERIC(15,4) NOT NULL DEFAULT 0,
  CONSTRAINT chk_ap_credit_used_nonneg CHECK (credit_used >= 0),

  payment_terms_days            INT,
  CONSTRAINT chk_ap_payment_terms CHECK (payment_terms_days IS NULL OR payment_terms_days >= 0),
  payment_terms_notes           TEXT,

  account_status                VARCHAR(20) NOT NULL DEFAULT 'NORMAL',
  CONSTRAINT chk_ap_status CHECK (account_status IN ('NORMAL','WATCH','BLOCKED','CLOSED')),

  last_status_change_at         TIMESTAMPTZ,
  last_status_change_by_user_id UUID REFERENCES users(id) ON DELETE SET NULL,
  last_status_change_reason     TEXT,

  default_payment_method        VARCHAR(20),
  CONSTRAINT chk_ap_default_pm CHECK (default_payment_method IS NULL OR default_payment_method IN (
    'CASH','BANK_TRANSFER','CARD','CHECK','PROMISSORY_NOTE'
  )),
  default_bank_account_info     JSONB,

  credit_score                  INT,
  CONSTRAINT chk_ap_credit_score CHECK (credit_score IS NULL OR (credit_score >= 0 AND credit_score <= 100)),
  auto_block_on_overdue_days    INT,
  CONSTRAINT chk_ap_auto_block CHECK (auto_block_on_overdue_days IS NULL OR auto_block_on_overdue_days > 0),

  managed_by_user_id            UUID REFERENCES users(id) ON DELETE SET NULL,
  notes                         TEXT,

  created_at                    TIMESTAMPTZ NOT NULL DEFAULT now(),
  updated_at                    TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE UNIQUE INDEX idx_ap_unique
  ON account_profiles(tenant_id, party_id, party_role, currency);
CREATE INDEX idx_ap_status ON account_profiles(tenant_id, account_status);
CREATE INDEX idx_ap_party ON account_profiles(party_id);
CREATE INDEX idx_ap_blocked ON account_profiles(tenant_id) WHERE account_status = 'BLOCKED';

ALTER TABLE account_profiles ENABLE ROW LEVEL SECURITY;
CREATE POLICY tenant_isolation_ap ON account_profiles USING (tenant_id = current_tenant_id());

CREATE TRIGGER set_updated_at_ap
  BEFORE UPDATE ON account_profiles FOR EACH ROW EXECUTE FUNCTION set_updated_at();


-- ============================================================================
-- account_movements (append-only ledger — financial heart)
-- ============================================================================

CREATE TABLE account_movements (
  id                            UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  tenant_id                     UUID NOT NULL REFERENCES tenants(id) ON DELETE RESTRICT,

  account_profile_id            UUID NOT NULL REFERENCES account_profiles(id) ON DELETE RESTRICT,

  party_id                      UUID NOT NULL REFERENCES parties(id) ON DELETE RESTRICT,
  party_role                    VARCHAR(20) NOT NULL,
  currency                      VARCHAR(10) NOT NULL,

  direction                     VARCHAR(10) NOT NULL,
  CONSTRAINT chk_am_direction CHECK (direction IN ('DEBIT','CREDIT')),

  amount                        NUMERIC(15,4) NOT NULL,
  CONSTRAINT chk_am_amount_positive CHECK (amount > 0),

  amount_try                    NUMERIC(15,4) NOT NULL,
  CONSTRAINT chk_am_amount_try_nonneg CHECK (amount_try >= 0),
  fx_snapshot_id                UUID REFERENCES fx_snapshots(id) ON DELETE RESTRICT,

  movement_type                 VARCHAR(50) NOT NULL,
  CONSTRAINT chk_am_type_direction CHECK (
    (direction = 'DEBIT' AND movement_type IN (
      'SALE_DEBIT','RETURN_CREDIT_USED','PURCHASE_REFUND',
      'PAYMENT_MADE','MANUAL_DEBIT','OPENING_BALANCE_DEBIT'
    ))
    OR
    (direction = 'CREDIT' AND movement_type IN (
      'SALE_REFUND','PAYMENT_RECEIVED','PURCHASE_DEBIT',
      'MANUAL_CREDIT','OPENING_BALANCE_CREDIT'
    ))
  ),

  reference_type                VARCHAR(50) NOT NULL,
  CONSTRAINT chk_am_reference_type CHECK (reference_type IN (
    'SALE','RETURN','PURCHASE_INVOICE','PURCHASE_RETURN',
    'PAYMENT','MANUAL_ADJUSTMENT','OPENING_BALANCE'
  )),
  reference_id                  UUID NOT NULL,

  reverses_movement_id          UUID REFERENCES account_movements(id) ON DELETE RESTRICT,
  reversal_reason               TEXT,

  aggregate_sequence            BIGINT NOT NULL,
  due_date                      DATE,
  notes                         TEXT,

  actor_user_id                 UUID NOT NULL REFERENCES users(id) ON DELETE RESTRICT,
  occurred_at                   TIMESTAMPTZ NOT NULL DEFAULT now(),
  CONSTRAINT chk_am_not_future CHECK (occurred_at <= now() + interval '1 minute'),
  recorded_at                   TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE INDEX idx_am_profile_time ON account_movements(account_profile_id, occurred_at DESC);
CREATE INDEX idx_am_party_role_currency
  ON account_movements(tenant_id, party_id, party_role, currency, occurred_at DESC);
CREATE INDEX idx_am_reference ON account_movements(reference_type, reference_id);
CREATE INDEX idx_am_reverses ON account_movements(reverses_movement_id) WHERE reverses_movement_id IS NOT NULL;
CREATE INDEX idx_am_due_date ON account_movements(tenant_id, due_date) WHERE due_date IS NOT NULL;
CREATE INDEX idx_am_aggregate_seq ON account_movements(account_profile_id, aggregate_sequence DESC);

ALTER TABLE account_movements ENABLE ROW LEVEL SECURITY;
CREATE POLICY tenant_isolation_am ON account_movements USING (tenant_id = current_tenant_id());

REVOKE UPDATE, DELETE ON account_movements FROM PUBLIC;

CREATE TRIGGER no_modify_account_movements
  BEFORE UPDATE OR DELETE ON account_movements
  FOR EACH ROW EXECUTE FUNCTION raise_append_only_violation();

CREATE OR REPLACE FUNCTION prevent_account_reversal_of_reversal()
RETURNS TRIGGER AS $$
BEGIN
  IF NEW.reverses_movement_id IS NOT NULL THEN
    IF EXISTS (
      SELECT 1 FROM account_movements
      WHERE id = NEW.reverses_movement_id
        AND reverses_movement_id IS NOT NULL
    ) THEN
      RAISE EXCEPTION 'Cannot reverse a reversal. Create a new corrective movement.';
    END IF;
  END IF;
  RETURN NEW;
END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER check_account_reversal_of_reversal
  BEFORE INSERT ON account_movements
  FOR EACH ROW EXECUTE FUNCTION prevent_account_reversal_of_reversal();

COMMENT ON TABLE account_movements IS
  'Append-only financial ledger. ERP-style operational terminology, NOT formal '
  'accounting double-entry. DEBIT=party owes us, CREDIT=we owe party. '
  'ROADMAP v1.1+: RANGE partition by occurred_at when row count > 10M.';


CREATE TABLE account_movement_sequences (
  account_profile_id            UUID PRIMARY KEY REFERENCES account_profiles(id) ON DELETE RESTRICT,
  tenant_id                     UUID NOT NULL REFERENCES tenants(id) ON DELETE RESTRICT,
  next_sequence                 BIGINT NOT NULL DEFAULT 1
);

ALTER TABLE account_movement_sequences ENABLE ROW LEVEL SECURITY;
CREATE POLICY tenant_isolation_ams ON account_movement_sequences USING (tenant_id = current_tenant_id());


CREATE TABLE account_balances (
  tenant_id                     UUID NOT NULL REFERENCES tenants(id) ON DELETE RESTRICT,
  account_profile_id            UUID NOT NULL REFERENCES account_profiles(id) ON DELETE RESTRICT,
  party_id                      UUID NOT NULL REFERENCES parties(id) ON DELETE RESTRICT,
  party_role                    VARCHAR(20) NOT NULL,
  currency                      VARCHAR(10) NOT NULL REFERENCES currencies(code) ON DELETE RESTRICT,

  total_debit                   NUMERIC(15,4) NOT NULL DEFAULT 0,
  total_credit                  NUMERIC(15,4) NOT NULL DEFAULT 0,
  net_balance                   NUMERIC(15,4) GENERATED ALWAYS AS (total_debit - total_credit) STORED,

  total_debit_try               NUMERIC(15,4) NOT NULL DEFAULT 0,
  total_credit_try              NUMERIC(15,4) NOT NULL DEFAULT 0,

  last_movement_id              UUID,
  last_movement_at              TIMESTAMPTZ,
  last_reconciled_at            TIMESTAMPTZ,

  overdue_amount                NUMERIC(15,4) NOT NULL DEFAULT 0,
  oldest_overdue_date           DATE,

  updated_at                    TIMESTAMPTZ NOT NULL DEFAULT now(),

  PRIMARY KEY (account_profile_id),
  CONSTRAINT chk_ab_totals_nonneg CHECK (
    total_debit >= 0 AND total_credit >= 0 AND
    total_debit_try >= 0 AND total_credit_try >= 0 AND
    overdue_amount >= 0
  )
);

CREATE INDEX idx_ab_party_role_currency
  ON account_balances(tenant_id, party_id, party_role, currency);
CREATE INDEX idx_ab_net_positive
  ON account_balances(tenant_id, party_role, net_balance) WHERE net_balance > 0;
CREATE INDEX idx_ab_overdue
  ON account_balances(tenant_id, overdue_amount DESC) WHERE overdue_amount > 0;

ALTER TABLE account_balances ENABLE ROW LEVEL SECURITY;
CREATE POLICY tenant_isolation_ab ON account_balances USING (tenant_id = current_tenant_id());

CREATE TRIGGER set_updated_at_ab
  BEFORE UPDATE ON account_balances FOR EACH ROW EXECUTE FUNCTION set_updated_at();


-- ============================================================================
-- payments + payment_allocations
-- (register_session FK added later in 009_cash_register.sql via ALTER)
-- ============================================================================

CREATE TABLE payments (
  id                            UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  tenant_id                     UUID NOT NULL REFERENCES tenants(id) ON DELETE RESTRICT,
  store_id                      UUID REFERENCES stores(id) ON DELETE RESTRICT,

  payment_number                VARCHAR(50),

  payment_type                  VARCHAR(20) NOT NULL,
  CONSTRAINT chk_pay_type CHECK (payment_type IN ('RECEIVED','MADE','REVERSAL')),

  party_id                      UUID NOT NULL REFERENCES parties(id) ON DELETE RESTRICT,
  party_role                    VARCHAR(20) NOT NULL,
  CONSTRAINT chk_pay_role CHECK (party_role IN ('CUSTOMER','SUPPLIER')),

  currency                      VARCHAR(10) NOT NULL REFERENCES currencies(code) ON DELETE RESTRICT,
  fx_snapshot_id                UUID REFERENCES fx_snapshots(id) ON DELETE RESTRICT,
  CONSTRAINT chk_pay_fx_required CHECK (currency = 'TRY' OR fx_snapshot_id IS NOT NULL),

  amount                        NUMERIC(15,4) NOT NULL,
  CONSTRAINT chk_pay_amount_positive CHECK (amount > 0),
  amount_try                    NUMERIC(15,4) NOT NULL,
  CONSTRAINT chk_pay_amount_try_nonneg CHECK (amount_try >= 0),

  tender_type                   VARCHAR(30) NOT NULL,
  CONSTRAINT chk_pay_tender CHECK (tender_type IN (
    'CASH','BANK_TRANSFER','CARD','CHECK','PROMISSORY_NOTE',
    'CUSTOMER_BALANCE','GIFT_CARD'
  )),

  register_session_id           UUID,  -- FK added in 009_cash_register.sql
  CONSTRAINT chk_pay_cash_register CHECK (
    tender_type != 'CASH' OR register_session_id IS NOT NULL
  ),

  bank_account_id               UUID,
  reference                     VARCHAR(100),
  tender_metadata               JSONB DEFAULT '{}'::jsonb,

  status                        VARCHAR(30) NOT NULL DEFAULT 'DRAFT',
  CONSTRAINT chk_pay_status CHECK (status IN (
    'DRAFT','COMPLETED','REVERSED','PARTIALLY_REVERSED','FAILED','CANCELLED'
  )),
  failure_reason                TEXT,

  reversal_info                 JSONB,
  reversed_by_payment_id        UUID REFERENCES payments(id) ON DELETE RESTRICT,

  idempotency_key               VARCHAR(64),

  notes                         TEXT,
  received_by_user_id           UUID NOT NULL REFERENCES users(id) ON DELETE RESTRICT,
  occurred_at                   TIMESTAMPTZ NOT NULL DEFAULT now(),
  recorded_at                   TIMESTAMPTZ NOT NULL DEFAULT now(),
  created_at                    TIMESTAMPTZ NOT NULL DEFAULT now(),
  updated_at                    TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE UNIQUE INDEX idx_pay_tenant_number
  ON payments(tenant_id, payment_number) WHERE payment_number IS NOT NULL;
CREATE UNIQUE INDEX idx_pay_idempotency
  ON payments(tenant_id, idempotency_key) WHERE idempotency_key IS NOT NULL;
CREATE INDEX idx_pay_party ON payments(party_id, occurred_at DESC);
CREATE INDEX idx_pay_status ON payments(tenant_id, status);
CREATE INDEX idx_pay_register_session ON payments(register_session_id)
  WHERE register_session_id IS NOT NULL;
CREATE INDEX idx_pay_reversed_by ON payments(reversed_by_payment_id)
  WHERE reversed_by_payment_id IS NOT NULL;
CREATE INDEX idx_pay_reversal_original
  ON payments((reversal_info->>'original_payment_id'))
  WHERE reversal_info IS NOT NULL;

ALTER TABLE payments ENABLE ROW LEVEL SECURITY;
CREATE POLICY tenant_isolation_pay ON payments USING (tenant_id = current_tenant_id());

CREATE TRIGGER set_updated_at_pay
  BEFORE UPDATE ON payments FOR EACH ROW EXECUTE FUNCTION set_updated_at();


CREATE TABLE payment_allocations (
  id                            UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  tenant_id                     UUID NOT NULL REFERENCES tenants(id) ON DELETE RESTRICT,
  payment_id                    UUID NOT NULL REFERENCES payments(id) ON DELETE CASCADE,
  account_movement_id           UUID NOT NULL REFERENCES account_movements(id) ON DELETE RESTRICT,

  allocated_amount              NUMERIC(15,4) NOT NULL,
  CONSTRAINT chk_pa_amount_positive CHECK (allocated_amount > 0),

  is_reopened                   BOOLEAN NOT NULL DEFAULT false,
  reopened_by_reversal_id       UUID REFERENCES payments(id) ON DELETE RESTRICT,

  allocated_at                  TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE INDEX idx_pa_payment ON payment_allocations(payment_id);
CREATE INDEX idx_pa_movement ON payment_allocations(account_movement_id);

ALTER TABLE payment_allocations ENABLE ROW LEVEL SECURITY;
CREATE POLICY tenant_isolation_pa_alloc ON payment_allocations USING (tenant_id = current_tenant_id());


CREATE TABLE account_aging (
  tenant_id                     UUID NOT NULL REFERENCES tenants(id) ON DELETE RESTRICT,
  account_profile_id            UUID NOT NULL REFERENCES account_profiles(id) ON DELETE RESTRICT,
  party_id                      UUID NOT NULL REFERENCES parties(id) ON DELETE RESTRICT,
  party_role                    VARCHAR(20) NOT NULL,
  currency                      VARCHAR(10) NOT NULL,

  current_amount                NUMERIC(15,4) NOT NULL DEFAULT 0,
  overdue_30_60                 NUMERIC(15,4) NOT NULL DEFAULT 0,
  overdue_60_90                 NUMERIC(15,4) NOT NULL DEFAULT 0,
  overdue_90_plus               NUMERIC(15,4) NOT NULL DEFAULT 0,
  total                         NUMERIC(15,4) GENERATED ALWAYS AS
    (current_amount + overdue_30_60 + overdue_60_90 + overdue_90_plus) STORED,

  CONSTRAINT chk_aa_nonneg CHECK (
    current_amount >= 0 AND overdue_30_60 >= 0 AND
    overdue_60_90 >= 0 AND overdue_90_plus >= 0
  ),

  computed_at                   TIMESTAMPTZ NOT NULL DEFAULT now(),

  PRIMARY KEY (account_profile_id)
);

CREATE INDEX idx_aa_overdue_90
  ON account_aging(tenant_id, overdue_90_plus DESC) WHERE overdue_90_plus > 0;
CREATE INDEX idx_aa_party ON account_aging(party_id, party_role);

ALTER TABLE account_aging ENABLE ROW LEVEL SECURITY;
CREATE POLICY tenant_isolation_aa ON account_aging USING (tenant_id = current_tenant_id());
