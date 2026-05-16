-- Migration 006_inventory.sql
-- Inventory context: stock_movements (append-only), stock_balances (projection),
-- reorder_levels, transfers, count_sessions, stock_adjustments
-- Depends on: 001 (tenants), 002 (reason_codes), 003 (users, stores), 005 (product_variants)

-- ============================================================================
-- stock_movements (append-only ledger — the heart)
-- ============================================================================

CREATE TABLE stock_movements (
  id                            UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  tenant_id                     UUID NOT NULL REFERENCES tenants(id) ON DELETE RESTRICT,
  variant_id                    UUID NOT NULL REFERENCES product_variants(id) ON DELETE RESTRICT,
  store_id                      UUID NOT NULL REFERENCES stores(id) ON DELETE RESTRICT,

  direction                     VARCHAR(10) NOT NULL,
  CONSTRAINT chk_sm_direction CHECK (direction IN ('IN','OUT')),

  quantity                      NUMERIC(15,4) NOT NULL,
  CONSTRAINT chk_sm_quantity CHECK (quantity > 0),

  movement_type                 VARCHAR(50) NOT NULL,
  CONSTRAINT chk_sm_type_direction CHECK (
    (direction = 'IN' AND movement_type IN (
      'PURCHASE_RECEIPT','SALES_RETURN_IN','TRANSFER_IN',
      'COUNT_ADJUST_IN','POSITIVE_ADJUSTMENT','OPENING_BALANCE_IN'
    ))
    OR
    (direction = 'OUT' AND movement_type IN (
      'SALE','PURCHASE_RETURN_OUT','TRANSFER_OUT',
      'COUNT_ADJUST_OUT','NEGATIVE_ADJUSTMENT','WRITE_OFF'
    ))
  ),

  unit_cost_try                 NUMERIC(15,4) NOT NULL,
  CONSTRAINT chk_sm_cost_nonneg CHECK (unit_cost_try >= 0),

  unit_cost_original            NUMERIC(15,4),
  original_currency             VARCHAR(10),
  fx_snapshot_id                UUID REFERENCES fx_snapshots(id) ON DELETE RESTRICT,

  reference_type                VARCHAR(50) NOT NULL,
  CONSTRAINT chk_sm_reference_type CHECK (reference_type IN (
    'SALE','RETURN','PURCHASE_INVOICE','PURCHASE_RETURN',
    'TRANSFER','COUNT_SESSION','STOCK_ADJUSTMENT','OPENING_BALANCE'
  )),
  reference_id                  UUID NOT NULL,
  reference_line_id             UUID,

  reverses_movement_id          UUID REFERENCES stock_movements(id) ON DELETE RESTRICT,
  reversal_reason               TEXT,

  reason_code_id                UUID REFERENCES reason_codes(id) ON DELETE RESTRICT,
  notes                         TEXT,

  aggregate_sequence            BIGINT NOT NULL,

  occurred_at                   TIMESTAMPTZ NOT NULL DEFAULT now(),
  CONSTRAINT chk_sm_not_future CHECK (occurred_at <= now() + interval '1 minute'),
  recorded_at                   TIMESTAMPTZ NOT NULL DEFAULT now(),
  actor_user_id                 UUID NOT NULL REFERENCES users(id) ON DELETE RESTRICT
);

CREATE INDEX idx_sm_variant_store_time
  ON stock_movements(variant_id, store_id, occurred_at DESC);
CREATE INDEX idx_sm_reference ON stock_movements(reference_type, reference_id);
CREATE INDEX idx_sm_reverses ON stock_movements(reverses_movement_id)
  WHERE reverses_movement_id IS NOT NULL;
CREATE INDEX idx_sm_tenant_time ON stock_movements(tenant_id, occurred_at DESC);
CREATE INDEX idx_sm_aggregate_seq
  ON stock_movements(variant_id, store_id, aggregate_sequence DESC);

ALTER TABLE stock_movements ENABLE ROW LEVEL SECURITY;
CREATE POLICY tenant_isolation_sm ON stock_movements USING (tenant_id = current_tenant_id());

REVOKE UPDATE, DELETE ON stock_movements FROM PUBLIC;

CREATE TRIGGER no_modify_stock_movements
  BEFORE UPDATE OR DELETE ON stock_movements
  FOR EACH ROW EXECUTE FUNCTION raise_append_only_violation();

-- Reversal-of-reversal prevention
CREATE OR REPLACE FUNCTION prevent_stock_reversal_of_reversal()
RETURNS TRIGGER AS $$
BEGIN
  IF NEW.reverses_movement_id IS NOT NULL THEN
    IF EXISTS (
      SELECT 1 FROM stock_movements
      WHERE id = NEW.reverses_movement_id
        AND reverses_movement_id IS NOT NULL
    ) THEN
      RAISE EXCEPTION 'Cannot reverse a reversal. Create a new corrective movement.';
    END IF;
  END IF;
  RETURN NEW;
END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER check_stock_reversal_of_reversal
  BEFORE INSERT ON stock_movements
  FOR EACH ROW EXECUTE FUNCTION prevent_stock_reversal_of_reversal();

COMMENT ON TABLE stock_movements IS
  'Append-only stock ledger. Single source of truth for inventory. '
  'ROADMAP v1.1+: RANGE partition by occurred_at when row count > 5M. '
  'Reversal pattern: INSERT new row with reverses_movement_id. '
  'Reversal-of-reversal forbidden — create corrective movement instead.';

-- ============================================================================
-- stock_movement_sequences (per-aggregate sequence allocator)
-- ============================================================================

CREATE TABLE stock_movement_sequences (
  tenant_id                     UUID NOT NULL REFERENCES tenants(id) ON DELETE RESTRICT,
  variant_id                    UUID NOT NULL REFERENCES product_variants(id) ON DELETE RESTRICT,
  store_id                      UUID NOT NULL REFERENCES stores(id) ON DELETE RESTRICT,
  next_sequence                 BIGINT NOT NULL DEFAULT 1,
  PRIMARY KEY (tenant_id, variant_id, store_id)
);

ALTER TABLE stock_movement_sequences ENABLE ROW LEVEL SECURITY;
CREATE POLICY tenant_isolation_sms ON stock_movement_sequences USING (tenant_id = current_tenant_id());

-- ============================================================================
-- stock_balances (projection)
-- ============================================================================

CREATE TABLE stock_balances (
  tenant_id                     UUID NOT NULL REFERENCES tenants(id) ON DELETE RESTRICT,
  variant_id                    UUID NOT NULL REFERENCES product_variants(id) ON DELETE RESTRICT,
  store_id                      UUID NOT NULL REFERENCES stores(id) ON DELETE RESTRICT,

  quantity                      NUMERIC(15,4) NOT NULL DEFAULT 0,
  average_cost_try              NUMERIC(15,4) NOT NULL DEFAULT 0,
  CONSTRAINT chk_sb_cost_nonneg CHECK (average_cost_try >= 0),

  total_cost_try                NUMERIC(15,4) GENERATED ALWAYS AS (quantity * average_cost_try) STORED,

  last_movement_id              UUID,
  last_movement_at              TIMESTAMPTZ,
  last_reconciled_at            TIMESTAMPTZ,

  updated_at                    TIMESTAMPTZ NOT NULL DEFAULT now(),

  PRIMARY KEY (tenant_id, variant_id, store_id)
);

CREATE INDEX idx_sb_variant ON stock_balances(variant_id, store_id);
CREATE INDEX idx_sb_store_qty ON stock_balances(store_id, quantity) WHERE quantity > 0;
CREATE INDEX idx_sb_low_stock ON stock_balances(tenant_id, store_id, variant_id, quantity)
  WHERE quantity < 10;
CREATE INDEX idx_sb_negative ON stock_balances(tenant_id, store_id, variant_id)
  WHERE quantity < 0;

ALTER TABLE stock_balances ENABLE ROW LEVEL SECURITY;
CREATE POLICY tenant_isolation_sb ON stock_balances USING (tenant_id = current_tenant_id());

CREATE TRIGGER set_updated_at_sb
  BEFORE UPDATE ON stock_balances FOR EACH ROW EXECUTE FUNCTION set_updated_at();

-- ============================================================================
-- reorder_levels
-- ============================================================================

CREATE TABLE reorder_levels (
  id                            UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  tenant_id                     UUID NOT NULL REFERENCES tenants(id) ON DELETE RESTRICT,
  variant_id                    UUID NOT NULL REFERENCES product_variants(id) ON DELETE CASCADE,
  store_id                      UUID NOT NULL REFERENCES stores(id) ON DELETE RESTRICT,

  min_level                     NUMERIC(15,4) NOT NULL DEFAULT 0,
  max_level                     NUMERIC(15,4),
  reorder_quantity              NUMERIC(15,4),

  alert_enabled                 BOOLEAN NOT NULL DEFAULT true,

  CONSTRAINT chk_rl_max_gte_min CHECK (max_level IS NULL OR max_level >= min_level),
  CONSTRAINT chk_rl_min_nonneg CHECK (min_level >= 0),
  CONSTRAINT chk_rl_reorder_nonneg CHECK (reorder_quantity IS NULL OR reorder_quantity >= 0),

  created_at                    TIMESTAMPTZ NOT NULL DEFAULT now(),
  updated_at                    TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE UNIQUE INDEX idx_rl_unique ON reorder_levels(variant_id, store_id);
ALTER TABLE reorder_levels ENABLE ROW LEVEL SECURITY;
CREATE POLICY tenant_isolation_rl ON reorder_levels USING (tenant_id = current_tenant_id());

CREATE TRIGGER set_updated_at_rl
  BEFORE UPDATE ON reorder_levels FOR EACH ROW EXECUTE FUNCTION set_updated_at();

-- ============================================================================
-- transfers + transfer_items
-- ============================================================================

CREATE TABLE transfers (
  id                            UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  tenant_id                     UUID NOT NULL REFERENCES tenants(id) ON DELETE RESTRICT,

  transfer_number               VARCHAR(50),
  from_store_id                 UUID NOT NULL REFERENCES stores(id) ON DELETE RESTRICT,
  to_store_id                   UUID NOT NULL REFERENCES stores(id) ON DELETE RESTRICT,

  status                        VARCHAR(20) NOT NULL DEFAULT 'DRAFT',
  CONSTRAINT chk_transfer_status CHECK (status IN ('DRAFT','DISPATCHED','RECEIVED','CANCELLED')),

  notes                         TEXT,

  dispatched_at                 TIMESTAMPTZ,
  dispatched_by_user_id         UUID REFERENCES users(id) ON DELETE RESTRICT,
  received_at                   TIMESTAMPTZ,
  received_by_user_id           UUID REFERENCES users(id) ON DELETE RESTRICT,
  cancelled_at                  TIMESTAMPTZ,
  cancelled_by_user_id          UUID REFERENCES users(id) ON DELETE SET NULL,

  idempotency_key_dispatch      VARCHAR(64),
  idempotency_key_receive       VARCHAR(64),

  administratively_reversed_at         TIMESTAMPTZ,
  administratively_reversed_by_user_id UUID REFERENCES users(id) ON DELETE SET NULL,
  administrative_reversal_reason       TEXT,

  created_at                    TIMESTAMPTZ NOT NULL DEFAULT now(),
  updated_at                    TIMESTAMPTZ NOT NULL DEFAULT now(),

  CONSTRAINT chk_transfer_different_stores CHECK (from_store_id != to_store_id),
  CONSTRAINT chk_transfer_dispatch_actor CHECK (
    (status NOT IN ('DISPATCHED','RECEIVED') AND dispatched_by_user_id IS NULL)
    OR (status IN ('DISPATCHED','RECEIVED') AND dispatched_by_user_id IS NOT NULL)
  ),
  CONSTRAINT chk_transfer_receive_actor CHECK (
    (status != 'RECEIVED' AND received_by_user_id IS NULL)
    OR (status = 'RECEIVED' AND received_by_user_id IS NOT NULL)
  )
);

CREATE UNIQUE INDEX idx_transfers_tenant_number
  ON transfers(tenant_id, transfer_number) WHERE transfer_number IS NOT NULL;
CREATE UNIQUE INDEX idx_transfers_idem_dispatch
  ON transfers(tenant_id, idempotency_key_dispatch) WHERE idempotency_key_dispatch IS NOT NULL;
CREATE UNIQUE INDEX idx_transfers_idem_receive
  ON transfers(tenant_id, idempotency_key_receive) WHERE idempotency_key_receive IS NOT NULL;

CREATE INDEX idx_transfers_status ON transfers(tenant_id, status);
CREATE INDEX idx_transfers_from_store ON transfers(from_store_id, status);
CREATE INDEX idx_transfers_to_store ON transfers(to_store_id, status);
CREATE INDEX idx_transfers_pending ON transfers(dispatched_at) WHERE status = 'DISPATCHED';

ALTER TABLE transfers ENABLE ROW LEVEL SECURITY;
CREATE POLICY tenant_isolation_transfers ON transfers USING (tenant_id = current_tenant_id());

CREATE TRIGGER set_updated_at_transfers
  BEFORE UPDATE ON transfers FOR EACH ROW EXECUTE FUNCTION set_updated_at();


CREATE TABLE transfer_items (
  id                            UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  tenant_id                     UUID NOT NULL REFERENCES tenants(id) ON DELETE RESTRICT,
  transfer_id                   UUID NOT NULL REFERENCES transfers(id) ON DELETE CASCADE,
  variant_id                    UUID NOT NULL REFERENCES product_variants(id) ON DELETE RESTRICT,

  dispatched_quantity           NUMERIC(15,4) NOT NULL,
  CONSTRAINT chk_ti_dispatched_pos CHECK (dispatched_quantity > 0),

  received_quantity             NUMERIC(15,4),
  CONSTRAINT chk_ti_received_nonneg CHECK (received_quantity IS NULL OR received_quantity >= 0),
  CONSTRAINT chk_ti_received_lte_dispatched CHECK (
    received_quantity IS NULL OR received_quantity <= dispatched_quantity
  ),

  loss_reason_code              VARCHAR(50),
  CONSTRAINT chk_ti_loss_reason CHECK (loss_reason_code IS NULL OR loss_reason_code IN (
    'LOST_IN_TRANSIT','DAMAGED_IN_TRANSIT','RECEIVED_SHORT',
    'PROVIDER_ERROR','INTERNAL_PILFERAGE'
  )),
  loss_notes                    TEXT,

  CONSTRAINT chk_ti_pilferage_notes CHECK (
    loss_reason_code != 'INTERNAL_PILFERAGE'
    OR (loss_notes IS NOT NULL AND length(loss_notes) > 0)
  ),

  notes                         TEXT,
  created_at                    TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE INDEX idx_ti_transfer ON transfer_items(transfer_id);
CREATE INDEX idx_ti_variant ON transfer_items(variant_id);

ALTER TABLE transfer_items ENABLE ROW LEVEL SECURITY;
CREATE POLICY tenant_isolation_ti ON transfer_items USING (tenant_id = current_tenant_id());

-- ============================================================================
-- count_sessions + count_items
-- ============================================================================

CREATE TABLE count_sessions (
  id                            UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  tenant_id                     UUID NOT NULL REFERENCES tenants(id) ON DELETE RESTRICT,
  store_id                      UUID NOT NULL REFERENCES stores(id) ON DELETE RESTRICT,

  session_number                VARCHAR(50),

  status                        VARCHAR(20) NOT NULL DEFAULT 'DRAFT',
  CONSTRAINT chk_count_status CHECK (status IN ('DRAFT','IN_PROGRESS','COMPLETED','CANCELLED')),

  scope_filter                  JSONB,

  total_items_counted           INT NOT NULL DEFAULT 0,
  total_items_with_variance     INT NOT NULL DEFAULT 0,
  total_variance_value_try      NUMERIC(15,4) NOT NULL DEFAULT 0,

  started_at                    TIMESTAMPTZ,
  started_by_user_id            UUID REFERENCES users(id) ON DELETE RESTRICT,
  completed_at                  TIMESTAMPTZ,
  completed_by_user_id          UUID REFERENCES users(id) ON DELETE SET NULL,
  cancelled_at                  TIMESTAMPTZ,

  idempotency_key_complete      VARCHAR(64),

  notes                         TEXT,
  created_at                    TIMESTAMPTZ NOT NULL DEFAULT now(),
  updated_at                    TIMESTAMPTZ NOT NULL DEFAULT now(),

  CONSTRAINT chk_cs_started_actor CHECK (
    (status = 'DRAFT' AND started_by_user_id IS NULL)
    OR (status != 'DRAFT' AND started_by_user_id IS NOT NULL)
  )
);

CREATE UNIQUE INDEX idx_cs_one_in_progress_per_store
  ON count_sessions(store_id) WHERE status = 'IN_PROGRESS';
CREATE UNIQUE INDEX idx_cs_idempotency
  ON count_sessions(tenant_id, idempotency_key_complete) WHERE idempotency_key_complete IS NOT NULL;
CREATE UNIQUE INDEX idx_cs_tenant_number
  ON count_sessions(tenant_id, session_number) WHERE session_number IS NOT NULL;
CREATE INDEX idx_cs_status ON count_sessions(tenant_id, status);

ALTER TABLE count_sessions ENABLE ROW LEVEL SECURITY;
CREATE POLICY tenant_isolation_cs ON count_sessions USING (tenant_id = current_tenant_id());

CREATE TRIGGER set_updated_at_cs
  BEFORE UPDATE ON count_sessions FOR EACH ROW EXECUTE FUNCTION set_updated_at();

COMMENT ON TABLE count_sessions IS
  'Stock count session aggregate. MVP: one IN_PROGRESS per store at a time. '
  'ROADMAP v2: zone/bin/location scoped parallel counts for large warehouses '
  '(5000m²+, 12+ personnel concurrent). Will introduce storage_zones table '
  'and count_sessions.zone_scope field. Lock granularity changes to (variant × zone).';


CREATE TABLE count_items (
  id                            UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  tenant_id                     UUID NOT NULL REFERENCES tenants(id) ON DELETE RESTRICT,
  count_session_id              UUID NOT NULL REFERENCES count_sessions(id) ON DELETE CASCADE,
  variant_id                    UUID NOT NULL REFERENCES product_variants(id) ON DELETE RESTRICT,

  snapshot_quantity             NUMERIC(15,4) NOT NULL,
  snapshot_taken_at             TIMESTAMPTZ NOT NULL,

  counted_quantity              NUMERIC(15,4),
  CONSTRAINT chk_ci_counted_nonneg CHECK (counted_quantity IS NULL OR counted_quantity >= 0),

  expected_at_count_time        NUMERIC(15,4),
  variance                      NUMERIC(15,4),

  reason_code_id                UUID REFERENCES reason_codes(id) ON DELETE RESTRICT,
  notes                         TEXT,

  counted_at                    TIMESTAMPTZ,
  counted_by_user_id            UUID REFERENCES users(id) ON DELETE SET NULL,

  created_at                    TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE UNIQUE INDEX idx_ci_session_variant ON count_items(count_session_id, variant_id);
CREATE INDEX idx_ci_variance ON count_items(count_session_id)
  WHERE variance IS NOT NULL AND variance != 0;

ALTER TABLE count_items ENABLE ROW LEVEL SECURITY;
CREATE POLICY tenant_isolation_ci ON count_items USING (tenant_id = current_tenant_id());

-- ============================================================================
-- stock_adjustments (single-shot)
-- ============================================================================

CREATE TABLE stock_adjustments (
  id                            UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  tenant_id                     UUID NOT NULL REFERENCES tenants(id) ON DELETE RESTRICT,
  variant_id                    UUID NOT NULL REFERENCES product_variants(id) ON DELETE RESTRICT,
  store_id                      UUID NOT NULL REFERENCES stores(id) ON DELETE RESTRICT,

  direction                     VARCHAR(10) NOT NULL,
  CONSTRAINT chk_sa_direction CHECK (direction IN ('IN','OUT')),

  quantity                      NUMERIC(15,4) NOT NULL,
  CONSTRAINT chk_sa_qty_pos CHECK (quantity > 0),

  reason_code_id                UUID NOT NULL REFERENCES reason_codes(id) ON DELETE RESTRICT,
  notes                         TEXT,

  movement_id                   UUID NOT NULL REFERENCES stock_movements(id) ON DELETE RESTRICT,

  idempotency_key               VARCHAR(64),

  actor_user_id                 UUID NOT NULL REFERENCES users(id) ON DELETE RESTRICT,
  occurred_at                   TIMESTAMPTZ NOT NULL DEFAULT now(),
  created_at                    TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE UNIQUE INDEX idx_sa_idempotency
  ON stock_adjustments(tenant_id, idempotency_key) WHERE idempotency_key IS NOT NULL;
CREATE UNIQUE INDEX idx_sa_movement ON stock_adjustments(movement_id);
CREATE INDEX idx_sa_variant_store ON stock_adjustments(variant_id, store_id, occurred_at DESC);
CREATE INDEX idx_sa_reason ON stock_adjustments(reason_code_id);

ALTER TABLE stock_adjustments ENABLE ROW LEVEL SECURITY;
CREATE POLICY tenant_isolation_sa ON stock_adjustments USING (tenant_id = current_tenant_id());

REVOKE UPDATE, DELETE ON stock_adjustments FROM PUBLIC;
