-- Migration 002_system_seed_lookups.sql
-- System-wide lookup tables + their seed data.
-- These MUST be loaded before tables that FK-reference them (roles, currencies, etc.).
--
-- All seed rows have tenant_id IS NULL = system-wide.

-- ============================================================================
-- currencies
-- ============================================================================

CREATE TABLE currencies (
  code                          VARCHAR(10) PRIMARY KEY,
  display_name                  VARCHAR(50) NOT NULL,
  symbol                        VARCHAR(10) NOT NULL,
  decimals                      INT NOT NULL DEFAULT 2,
  CONSTRAINT chk_curr_decimals CHECK (decimals >= 0 AND decimals <= 6),

  currency_type                 VARCHAR(20) NOT NULL DEFAULT 'FIAT',
  CONSTRAINT chk_curr_type CHECK (currency_type IN ('FIAT','METAL','CRYPTO')),

  is_active                     BOOLEAN NOT NULL DEFAULT false,
  display_order                 INT NOT NULL DEFAULT 0,
  metadata                      JSONB NOT NULL DEFAULT '{}'::jsonb,

  created_at                    TIMESTAMPTZ NOT NULL DEFAULT now(),
  updated_at                    TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE INDEX idx_currencies_active ON currencies(is_active) WHERE is_active = true;

CREATE TRIGGER set_updated_at_currencies
  BEFORE UPDATE ON currencies FOR EACH ROW EXECUTE FUNCTION set_updated_at();

-- Seed currencies
INSERT INTO currencies (code, display_name, symbol, decimals, currency_type, is_active, display_order) VALUES
  ('TRY', 'Türk Lirası', '₺', 2, 'FIAT', true, 1),
  ('USD', 'US Dollar', '$', 2, 'FIAT', true, 2),
  ('EUR', 'Euro', '€', 2, 'FIAT', true, 3),
  ('GBP', 'British Pound', '£', 2, 'FIAT', true, 4),
  ('XAU', 'Gold (gram)', 'gr', 4, 'METAL', false, 10),
  ('XAG', 'Silver (gram)', 'gr', 4, 'METAL', false, 11),
  ('XAU22', 'Gold 22K (gram)', 'gr', 4, 'METAL', false, 12),
  ('XAU14', 'Gold 14K (gram)', 'gr', 4, 'METAL', false, 13)
ON CONFLICT (code) DO NOTHING;

-- ============================================================================
-- fx_rate_sources
-- ============================================================================

CREATE TABLE fx_rate_sources (
  id                            UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  code                          VARCHAR(50) NOT NULL UNIQUE,
  display_name                  VARCHAR(100) NOT NULL,

  source_type                   VARCHAR(20) NOT NULL,
  CONSTRAINT chk_frs_type CHECK (source_type IN ('DAILY','REALTIME','MANUAL')),

  update_frequency_sec          INT,
  CONSTRAINT chk_frs_frequency CHECK (update_frequency_sec IS NULL OR update_frequency_sec > 0),

  api_config                    JSONB,
  implementation_class          VARCHAR(100),
  is_active                     BOOLEAN NOT NULL DEFAULT false,
  tenant_id                     UUID,  -- NULL = system-wide

  last_successful_fetch_at      TIMESTAMPTZ,
  consecutive_failures          INT NOT NULL DEFAULT 0,

  created_at                    TIMESTAMPTZ NOT NULL DEFAULT now(),
  updated_at                    TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE INDEX idx_frs_active ON fx_rate_sources(is_active) WHERE is_active = true;
CREATE INDEX idx_frs_tenant ON fx_rate_sources(tenant_id) WHERE tenant_id IS NOT NULL;

CREATE TRIGGER set_updated_at_frs
  BEFORE UPDATE ON fx_rate_sources FOR EACH ROW EXECUTE FUNCTION set_updated_at();

-- FK to tenants will be added in a later migration after tenants exists with rows;
-- for now allow NULL.
ALTER TABLE fx_rate_sources
  ADD CONSTRAINT fk_frs_tenant FOREIGN KEY (tenant_id) REFERENCES tenants(id) ON DELETE RESTRICT;

-- Seed FX sources
INSERT INTO fx_rate_sources (code, display_name, source_type, update_frequency_sec, is_active, implementation_class) VALUES
  ('TCMB', 'Türkiye Cumhuriyet Merkez Bankası', 'DAILY', 86400, true, 'TcmbProvider'),
  ('HAREM', 'Harem Altın & Döviz', 'REALTIME', 60, true, 'HaremProvider'),
  ('MANUAL', 'Manual Entry', 'MANUAL', NULL, true, 'ManualProvider'),
  ('FOREKS', 'Foreks', 'REALTIME', 30, false, 'ForeksProvider'),
  ('GOLDISTANBUL', 'Goldistanbul', 'REALTIME', 30, false, 'GoldIstanbulProvider'),
  ('BIGPARA', 'Bigpara', 'REALTIME', 60, false, 'BigparaProvider'),
  ('DOVIZCOM', 'Doviz.com', 'REALTIME', 60, false, 'DovizComProvider')
ON CONFLICT (code) DO NOTHING;

-- ============================================================================
-- roles (system + tenant-specific)
-- ============================================================================

CREATE TABLE roles (
  id                            UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  tenant_id                     UUID REFERENCES tenants(id) ON DELETE RESTRICT,  -- NULL = system
  code                          VARCHAR(50) NOT NULL,
  display_name                  VARCHAR(100) NOT NULL,
  description                   TEXT,

  is_system                     BOOLEAN NOT NULL DEFAULT false,
  permissions                   TEXT[] NOT NULL DEFAULT '{}',

  status                        VARCHAR(20) NOT NULL DEFAULT 'ACTIVE',
  CONSTRAINT chk_role_status CHECK (status IN ('ACTIVE','DISABLED','ARCHIVED')),

  created_at                    TIMESTAMPTZ NOT NULL DEFAULT now(),
  updated_at                    TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE UNIQUE INDEX idx_roles_tenant_code
  ON roles(COALESCE(tenant_id, '00000000-0000-0000-0000-000000000000'::uuid), code);
CREATE INDEX idx_roles_system ON roles(is_system) WHERE is_system = true;
CREATE INDEX idx_roles_permissions_gin ON roles USING gin(permissions);

-- Protect system roles from modification/deletion
CREATE OR REPLACE FUNCTION protect_system_roles()
RETURNS TRIGGER AS $$
BEGIN
  IF (TG_OP = 'UPDATE' AND OLD.is_system = true)
     OR (TG_OP = 'DELETE' AND OLD.is_system = true) THEN
    RAISE EXCEPTION 'System roles cannot be modified or deleted. Clone them into your tenant scope instead.';
  END IF;
  RETURN COALESCE(NEW, OLD);
END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER protect_system_roles_trg
  BEFORE UPDATE OR DELETE ON roles
  FOR EACH ROW EXECUTE FUNCTION protect_system_roles();

CREATE TRIGGER set_updated_at_roles
  BEFORE UPDATE ON roles FOR EACH ROW EXECUTE FUNCTION set_updated_at();

-- Seed 6 system roles (tenant_id IS NULL)
INSERT INTO roles (tenant_id, code, display_name, is_system, permissions) VALUES
  (NULL, 'SUPER_ADMIN', 'Süper Admin', true, ARRAY['*']),
  (NULL, 'STORE_MANAGER', 'Mağaza Müdürü', true, ARRAY[
    'sales.*', 'returns.*', 'inventory.*', 'parties.*',
    'reports.*', 'register.*', 'stock_adjustment.create',
    'sales.return.approve', 'sales.credit_limit.override'
  ]),
  (NULL, 'CASHIER', 'Kasiyer', true, ARRAY[
    'sales.create', 'sales.complete', 'sales.modify_cart',
    'sales.return.create', 'register.open', 'register.close.initiate'
  ]),
  (NULL, 'STOCK_CLERK', 'Stok Personeli', true, ARRAY[
    'inventory.transfer.*', 'inventory.count.*', 'inventory.adjust.create',
    'purchases.create', 'purchases.post'
  ]),
  (NULL, 'ACCOUNTANT', 'Muhasebeci', true, ARRAY[
    'financial.read', 'reports.read', 'payments.create', 'payments.complete'
  ]),
  (NULL, 'AUDITOR', 'Denetçi', true, ARRAY[
    '*.read', 'audit.*'
  ])
ON CONFLICT (COALESCE(tenant_id, '00000000-0000-0000-0000-000000000000'::uuid), code) DO NOTHING;

-- ============================================================================
-- reason_codes
-- ============================================================================

CREATE TABLE reason_codes (
  id                            UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  tenant_id                     UUID REFERENCES tenants(id) ON DELETE RESTRICT,  -- NULL = system

  domain                        VARCHAR(50) NOT NULL,
  CONSTRAINT chk_reason_domain CHECK (domain IN (
    'STOCK_ADJUSTMENT','TRANSFER_LOSS','COUNT_VARIANCE','RETURN_REASON','VOID_REASON'
  )),

  code                          VARCHAR(50) NOT NULL,
  display_name                  VARCHAR(100) NOT NULL,
  description                   TEXT,

  requires_manager_approval     BOOLEAN NOT NULL DEFAULT false,
  requires_notes                BOOLEAN NOT NULL DEFAULT false,
  is_system                     BOOLEAN NOT NULL DEFAULT false,
  display_order                 INT NOT NULL DEFAULT 0,

  created_at                    TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE UNIQUE INDEX idx_reason_codes_unique
  ON reason_codes(COALESCE(tenant_id, '00000000-0000-0000-0000-000000000000'::uuid), domain, code);

ALTER TABLE reason_codes ENABLE ROW LEVEL SECURITY;
CREATE POLICY tenant_isolation_reason_codes ON reason_codes
  USING (tenant_id IS NULL OR tenant_id = current_tenant_id());

-- Seed STOCK_ADJUSTMENT reasons
INSERT INTO reason_codes (tenant_id, domain, code, display_name, is_system, requires_notes, display_order) VALUES
  (NULL, 'STOCK_ADJUSTMENT', 'HASAR', 'Hasar', true, false, 1),
  (NULL, 'STOCK_ADJUSTMENT', 'HIRSIZLIK', 'Hırsızlık', true, true, 2),
  (NULL, 'STOCK_ADJUSTMENT', 'HEDIYE', 'Hediye/Promosyon', true, false, 3),
  (NULL, 'STOCK_ADJUSTMENT', 'NUMUNE', 'Numune', true, false, 4),
  (NULL, 'STOCK_ADJUSTMENT', 'DEMODE', 'Demode/Sezon Sonu', true, false, 5),
  (NULL, 'STOCK_ADJUSTMENT', 'SISTEM_HATA', 'Sistem Hatası Düzeltme', true, true, 6),
  (NULL, 'STOCK_ADJUSTMENT', 'DIGER', 'Diğer', true, true, 99)
ON CONFLICT DO NOTHING;

-- Seed TRANSFER_LOSS reasons (Phase 2D taxonomy)
INSERT INTO reason_codes (tenant_id, domain, code, display_name, is_system, requires_manager_approval, requires_notes, display_order) VALUES
  (NULL, 'TRANSFER_LOSS', 'LOST_IN_TRANSIT', 'Kargoda Kayıp', true, false, true, 1),
  (NULL, 'TRANSFER_LOSS', 'DAMAGED_IN_TRANSIT', 'Kargoda Hasar', true, false, true, 2),
  (NULL, 'TRANSFER_LOSS', 'RECEIVED_SHORT', 'Eksik Geldi', true, false, true, 3),
  (NULL, 'TRANSFER_LOSS', 'PROVIDER_ERROR', 'Kargo Şirketi Hatası', true, false, false, 4),
  (NULL, 'TRANSFER_LOSS', 'INTERNAL_PILFERAGE', 'İç Hırsızlık Şüphesi', true, true, true, 5)
ON CONFLICT DO NOTHING;
