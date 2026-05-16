-- Migration 003_identity.sql
-- users, user_role_assignments, stores
-- Depends on: 001_foundation (tenants), 002_system_seed_lookups (roles)

-- ============================================================================
-- users
-- ============================================================================

CREATE TABLE users (
  id                            UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  tenant_id                     UUID NOT NULL REFERENCES tenants(id) ON DELETE RESTRICT,

  email                         CITEXT NOT NULL,
  display_name                  VARCHAR(200) NOT NULL,
  phone                         VARCHAR(30),

  status                        VARCHAR(20) NOT NULL DEFAULT 'INVITED',
  CONSTRAINT chk_user_status CHECK (status IN ('INVITED','ACTIVE','SUSPENDED','DEACTIVATED')),

  password_hash                 VARCHAR(255),
  email_verified_at             TIMESTAMPTZ,
  last_login_at                 TIMESTAMPTZ,

  invited_by_user_id            UUID REFERENCES users(id) ON DELETE SET NULL,
  invitation_token              VARCHAR(255),
  invitation_expires_at         TIMESTAMPTZ,

  is_anonymized                 BOOLEAN NOT NULL DEFAULT false,
  anonymized_at                 TIMESTAMPTZ,

  preferences                   JSONB NOT NULL DEFAULT '{}'::jsonb,

  created_at                    TIMESTAMPTZ NOT NULL DEFAULT now(),
  updated_at                    TIMESTAMPTZ NOT NULL DEFAULT now()
);

-- CITEXT makes the comparison case-insensitive automatically
CREATE UNIQUE INDEX idx_users_tenant_email
  ON users(tenant_id, email)
  WHERE is_anonymized = false;

CREATE INDEX idx_users_tenant_status ON users(tenant_id, status);
CREATE INDEX idx_users_phone ON users(tenant_id, phone) WHERE phone IS NOT NULL;

ALTER TABLE users ENABLE ROW LEVEL SECURITY;
CREATE POLICY tenant_isolation_users ON users USING (tenant_id = current_tenant_id());

CREATE TRIGGER set_updated_at_users
  BEFORE UPDATE ON users FOR EACH ROW EXECUTE FUNCTION set_updated_at();

-- ============================================================================
-- user_role_assignments
-- ============================================================================

CREATE TABLE user_role_assignments (
  id                            UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  tenant_id                     UUID NOT NULL REFERENCES tenants(id) ON DELETE RESTRICT,
  user_id                       UUID NOT NULL REFERENCES users(id) ON DELETE RESTRICT,
  role_id                       UUID NOT NULL REFERENCES roles(id) ON DELETE RESTRICT,

  store_scope_ids               UUID[],  -- NULL = all stores; otherwise array of store ids

  assigned_at                   TIMESTAMPTZ NOT NULL DEFAULT now(),
  assigned_by_user_id           UUID REFERENCES users(id) ON DELETE SET NULL,
  revoked_at                    TIMESTAMPTZ,
  revoked_by_user_id            UUID REFERENCES users(id) ON DELETE SET NULL,
  revocation_reason             TEXT
);

CREATE UNIQUE INDEX idx_ura_active
  ON user_role_assignments(user_id, role_id)
  WHERE revoked_at IS NULL;

CREATE INDEX idx_ura_user ON user_role_assignments(user_id, revoked_at);
CREATE INDEX idx_ura_role ON user_role_assignments(role_id);

ALTER TABLE user_role_assignments ENABLE ROW LEVEL SECURITY;
CREATE POLICY tenant_isolation_ura ON user_role_assignments USING (tenant_id = current_tenant_id());

-- ============================================================================
-- stores
-- ============================================================================

CREATE TABLE stores (
  id                            UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  tenant_id                     UUID NOT NULL REFERENCES tenants(id) ON DELETE RESTRICT,
  code                          VARCHAR(20) NOT NULL,
  display_name                  VARCHAR(100) NOT NULL,

  store_type                    VARCHAR(30) NOT NULL DEFAULT 'PHYSICAL',
  CONSTRAINT chk_store_type CHECK (store_type IN ('PHYSICAL','VIRTUAL_IN_TRANSIT','WAREHOUSE','ONLINE')),

  status                        VARCHAR(20) NOT NULL DEFAULT 'ACTIVE',
  CONSTRAINT chk_store_status CHECK (status IN ('ACTIVE','INACTIVE','ARCHIVED')),

  address                       JSONB,
  contact_info                  JSONB,
  timezone                      VARCHAR(50) NOT NULL DEFAULT 'Europe/Istanbul',

  CONSTRAINT chk_virtual_always_active CHECK (
    store_type != 'VIRTUAL_IN_TRANSIT' OR status = 'ACTIVE'
  ),

  archived_at                   TIMESTAMPTZ,
  created_at                    TIMESTAMPTZ NOT NULL DEFAULT now(),
  updated_at                    TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE UNIQUE INDEX idx_stores_tenant_code ON stores(tenant_id, code);
CREATE UNIQUE INDEX idx_one_virtual_in_transit
  ON stores(tenant_id)
  WHERE store_type = 'VIRTUAL_IN_TRANSIT';
CREATE INDEX idx_stores_status ON stores(tenant_id, status);

ALTER TABLE stores ENABLE ROW LEVEL SECURITY;
CREATE POLICY tenant_isolation_stores ON stores USING (tenant_id = current_tenant_id());

CREATE TRIGGER set_updated_at_stores
  BEFORE UPDATE ON stores FOR EACH ROW EXECUTE FUNCTION set_updated_at();
