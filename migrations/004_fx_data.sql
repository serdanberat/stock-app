-- Migration 004_fx_data.sql
-- fx_rates (append-only) + fx_snapshots (immutable)
-- Depends on: 001_foundation (tenants), 002_system_seed_lookups (currencies, fx_rate_sources)

-- ============================================================================
-- Shared append-only enforcement function (reused by many tables)
-- ============================================================================

CREATE OR REPLACE FUNCTION raise_append_only_violation()
RETURNS TRIGGER AS $$
BEGIN
  RAISE EXCEPTION '% is append-only', TG_TABLE_NAME;
END;
$$ LANGUAGE plpgsql;

-- ============================================================================
-- fx_rates (append-only)
-- ============================================================================

CREATE TABLE fx_rates (
  id                            UUID PRIMARY KEY DEFAULT gen_random_uuid(),

  currency_code                 VARCHAR(10) NOT NULL REFERENCES currencies(code) ON DELETE RESTRICT,
  base_currency_code            VARCHAR(10) NOT NULL DEFAULT 'TRY' REFERENCES currencies(code) ON DELETE RESTRICT,
  source_id                     UUID NOT NULL REFERENCES fx_rate_sources(id) ON DELETE RESTRICT,

  buy_rate                      NUMERIC(15,6) NOT NULL,
  sell_rate                     NUMERIC(15,6) NOT NULL,

  CONSTRAINT chk_fxr_buy_positive CHECK (buy_rate > 0),
  CONSTRAINT chk_fxr_sell_positive CHECK (sell_rate > 0),
  CONSTRAINT chk_fxr_buy_lte_sell CHECK (buy_rate <= sell_rate),

  effective_at_utc              TIMESTAMPTZ NOT NULL,
  CONSTRAINT chk_fxr_not_future CHECK (effective_at_utc <= now() + interval '1 hour'),

  recorded_at                   TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE INDEX idx_fxr_lookup ON fx_rates(currency_code, source_id, effective_at_utc DESC);
CREATE INDEX idx_fxr_recent ON fx_rates(source_id, effective_at_utc DESC);

REVOKE UPDATE, DELETE ON fx_rates FROM PUBLIC;

CREATE TRIGGER no_modify_fx_rates
  BEFORE UPDATE OR DELETE ON fx_rates
  FOR EACH ROW EXECUTE FUNCTION raise_append_only_violation();

COMMENT ON TABLE fx_rates IS
  'Append-only FX rate observations. ROADMAP v1.1+: RANGE partition by month '
  'when row count > 5M (HAREM ~1440 rows/currency/day).';

-- ============================================================================
-- fx_snapshots (immutable, referenced by sales/returns/purchase_invoices/payments)
-- ============================================================================

CREATE TABLE fx_snapshots (
  id                            UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  tenant_id                     UUID NOT NULL REFERENCES tenants(id) ON DELETE RESTRICT,
  source_id                     UUID NOT NULL REFERENCES fx_rate_sources(id) ON DELETE RESTRICT,
  source_code                   VARCHAR(50) NOT NULL,
  source_version                VARCHAR(20) NOT NULL,

  rates                         JSONB NOT NULL,
  CONSTRAINT chk_fxs_rates_schema CHECK (rates ? 'schema_version' AND rates ? 'rates'),

  effective_at_utc              TIMESTAMPTZ NOT NULL,
  tenant_timezone               VARCHAR(50) NOT NULL,

  created_at_utc                TIMESTAMPTZ NOT NULL DEFAULT now(),
  created_by_user_id            UUID REFERENCES users(id) ON DELETE SET NULL
);

CREATE INDEX idx_fxs_tenant_time ON fx_snapshots(tenant_id, effective_at_utc DESC);
CREATE INDEX idx_fxs_source ON fx_snapshots(source_id, effective_at_utc DESC);

ALTER TABLE fx_snapshots ENABLE ROW LEVEL SECURITY;
CREATE POLICY tenant_isolation_fxs ON fx_snapshots USING (tenant_id = current_tenant_id());

REVOKE UPDATE, DELETE ON fx_snapshots FROM PUBLIC;

CREATE TRIGGER no_modify_fx_snapshots
  BEFORE UPDATE OR DELETE ON fx_snapshots
  FOR EACH ROW EXECUTE FUNCTION raise_append_only_violation();
