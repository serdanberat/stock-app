-- Migration 007_party.sql
-- Party context: parties, party_contacts, party_documents

CREATE TABLE parties (
  id                            UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  tenant_id                     UUID NOT NULL REFERENCES tenants(id) ON DELETE RESTRICT,

  code                          VARCHAR(50),

  party_types                   TEXT[] NOT NULL,
  CONSTRAINT chk_party_types_nonempty CHECK (array_length(party_types, 1) >= 1),
  CONSTRAINT chk_party_types_valid CHECK (
    party_types <@ ARRAY['CUSTOMER','SUPPLIER','EMPLOYEE','OTHER']::TEXT[]
  ),

  party_kind                    VARCHAR(20) NOT NULL DEFAULT 'INDIVIDUAL',
  CONSTRAINT chk_party_kind CHECK (party_kind IN ('INDIVIDUAL','COMPANY')),

  display_name                  VARCHAR(200) NOT NULL,
  legal_name                    VARCHAR(200),
  tax_id                        VARCHAR(20),
  tax_office                    VARCHAR(100),

  status                        VARCHAR(20) NOT NULL DEFAULT 'ACTIVE',
  CONSTRAINT chk_party_status CHECK (status IN ('ACTIVE','INACTIVE','BLOCKED')),
  block_reason                  TEXT,
  blocked_at                    TIMESTAMPTZ,
  blocked_by_user_id            UUID REFERENCES users(id) ON DELETE SET NULL,

  is_anonymized                 BOOLEAN NOT NULL DEFAULT false,
  anonymized_at                 TIMESTAMPTZ,

  metadata                      JSONB NOT NULL DEFAULT '{}'::jsonb,
  notes                         TEXT,

  created_at                    TIMESTAMPTZ NOT NULL DEFAULT now(),
  created_by_user_id            UUID REFERENCES users(id) ON DELETE SET NULL,
  updated_at                    TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE UNIQUE INDEX idx_parties_tenant_code
  ON parties(tenant_id, code) WHERE code IS NOT NULL;
CREATE INDEX idx_parties_status ON parties(tenant_id, status);
CREATE INDEX idx_parties_types_gin ON parties USING gin(party_types);
CREATE INDEX idx_parties_tax_id ON parties(tenant_id, tax_id)
  WHERE tax_id IS NOT NULL AND is_anonymized = false;
CREATE INDEX idx_parties_name_trgm ON parties USING gin(display_name gin_trgm_ops);
CREATE INDEX idx_parties_metadata_gin ON parties USING gin(metadata);

ALTER TABLE parties ENABLE ROW LEVEL SECURITY;
CREATE POLICY tenant_isolation_parties ON parties USING (tenant_id = current_tenant_id());

CREATE TRIGGER set_updated_at_parties
  BEFORE UPDATE ON parties FOR EACH ROW EXECUTE FUNCTION set_updated_at();

-- Add deferred FK from products.default_supplier_party_id
ALTER TABLE products
  ADD CONSTRAINT fk_products_default_supplier
  FOREIGN KEY (default_supplier_party_id) REFERENCES parties(id) ON DELETE SET NULL;


CREATE TABLE party_contacts (
  id                            UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  tenant_id                     UUID NOT NULL REFERENCES tenants(id) ON DELETE RESTRICT,
  party_id                      UUID NOT NULL REFERENCES parties(id) ON DELETE CASCADE,

  contact_type                  VARCHAR(20) NOT NULL,
  CONSTRAINT chk_pc_type CHECK (contact_type IN ('PHONE','EMAIL','ADDRESS','OTHER')),

  contact_value                 VARCHAR(500) NOT NULL,
  CONSTRAINT chk_pc_value_nonempty CHECK (length(trim(contact_value)) > 0),

  is_primary                    BOOLEAN NOT NULL DEFAULT false,
  label                         VARCHAR(50),

  created_at                    TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE INDEX idx_pc_party ON party_contacts(party_id);
CREATE INDEX idx_pc_phone_lookup
  ON party_contacts(tenant_id, contact_value)
  WHERE contact_type = 'PHONE';
CREATE INDEX idx_pc_email_lookup
  ON party_contacts(tenant_id, lower(contact_value))
  WHERE contact_type = 'EMAIL';
CREATE UNIQUE INDEX idx_pc_one_primary_per_type
  ON party_contacts(party_id, contact_type) WHERE is_primary = true;

ALTER TABLE party_contacts ENABLE ROW LEVEL SECURITY;
CREATE POLICY tenant_isolation_pc ON party_contacts USING (tenant_id = current_tenant_id());


CREATE TABLE party_documents (
  id                            UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  tenant_id                     UUID NOT NULL REFERENCES tenants(id) ON DELETE RESTRICT,
  party_id                      UUID NOT NULL REFERENCES parties(id) ON DELETE CASCADE,

  document_type                 VARCHAR(50) NOT NULL,
  CONSTRAINT chk_pd_type CHECK (document_type IN (
    'TAX_CERTIFICATE','ID_CARD','SIGNATURE_CIRCULAR','TRADE_REGISTRY',
    'BANK_LETTER','CONTRACT','OTHER'
  )),

  storage_path                  TEXT NOT NULL,
  CONSTRAINT chk_pd_storage_path CHECK (length(trim(storage_path)) > 0),
  original_filename             VARCHAR(255),
  mime_type                     VARCHAR(100),
  file_size_bytes               BIGINT,

  uploaded_at                   TIMESTAMPTZ NOT NULL DEFAULT now(),
  uploaded_by_user_id           UUID REFERENCES users(id) ON DELETE SET NULL,
  notes                         TEXT
);

CREATE INDEX idx_pd_party ON party_documents(party_id);
CREATE INDEX idx_pd_type ON party_documents(party_id, document_type);

ALTER TABLE party_documents ENABLE ROW LEVEL SECURITY;
CREATE POLICY tenant_isolation_pd ON party_documents USING (tenant_id = current_tenant_id());
