-- Migration 001_foundation.sql
-- Foundation tables and shared utility functions.
-- Includes: current_tenant_id() and set_updated_at() — used everywhere.

-- ============================================================================
-- Shared utility functions (used by RLS policies and triggers)
-- ============================================================================

-- Returns the current tenant_id from session, or sentinel UUID if unset.
-- RLS-friendly fail-safe: queries return zero rows when context is missing.
CREATE OR REPLACE FUNCTION current_tenant_id()
RETURNS UUID AS $$
DECLARE
  raw_value TEXT;
BEGIN
  raw_value := current_setting('app.tenant_id', true);  -- missing_ok=true
  IF raw_value IS NULL OR raw_value = '' THEN
    RETURN '00000000-0000-0000-0000-000000000000'::uuid;
  END IF;
  RETURN raw_value::uuid;
EXCEPTION
  WHEN invalid_text_representation THEN
    RETURN '00000000-0000-0000-0000-000000000000'::uuid;
END;
$$ LANGUAGE plpgsql STABLE SECURITY DEFINER;

-- Auto-update of updated_at on mutable tables
CREATE OR REPLACE FUNCTION set_updated_at()
RETURNS TRIGGER AS $$
BEGIN
  NEW.updated_at = now();
  RETURN NEW;
END;
$$ LANGUAGE plpgsql;

-- ============================================================================
-- tenants — top of multi-tenancy hierarchy
-- ============================================================================

CREATE TABLE tenants (
  id                            UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  code                          VARCHAR(30) NOT NULL UNIQUE,
  display_name                  VARCHAR(200) NOT NULL,
  legal_name                    VARCHAR(200),
  tax_id                        VARCHAR(20),

  industry                      VARCHAR(50) NOT NULL,
  industries_additional         TEXT[] NOT NULL DEFAULT '{}',

  status                        VARCHAR(20) NOT NULL DEFAULT 'TRIAL',
  CONSTRAINT chk_tenant_status CHECK (status IN ('TRIAL','ACTIVE','SUSPENDED','CHURNED','ARCHIVED')),

  plan                          VARCHAR(50) NOT NULL DEFAULT 'BASIC',

  trial_started_at              TIMESTAMPTZ,
  trial_ends_at                 TIMESTAMPTZ,
  activated_at                  TIMESTAMPTZ,
  suspended_at                  TIMESTAMPTZ,
  suspended_reason              TEXT,
  churned_at                    TIMESTAMPTZ,
  archived_at                   TIMESTAMPTZ,
  anonymized_at                 TIMESTAMPTZ,

  anonymization_method          VARCHAR(50),
  CONSTRAINT chk_anon_method CHECK (
    anonymization_method IS NULL
    OR anonymization_method IN ('IRREVERSIBLE','REVERSIBLE_PSEUDONYMIZATION')
  ),
  anonymization_key_id          VARCHAR(100),
  cold_storage_path             TEXT,
  physical_purge_eligible_at    TIMESTAMPTZ,

  preferred_fx_source           VARCHAR(50) NOT NULL DEFAULT 'TCMB',
  preferred_timezone            VARCHAR(50) NOT NULL DEFAULT 'Europe/Istanbul',
  default_currency              VARCHAR(10) NOT NULL DEFAULT 'TRY',
  default_vat_rate              NUMERIC(5,2) NOT NULL DEFAULT 20.00,
  CONSTRAINT chk_tenant_vat_rate CHECK (default_vat_rate >= 0 AND default_vat_rate <= 100),

  feature_flags                 JSONB NOT NULL DEFAULT '{}'::jsonb,
  settings                      JSONB NOT NULL DEFAULT '{}'::jsonb,
  enabled_modules               TEXT[] NOT NULL DEFAULT '{}',

  created_at                    TIMESTAMPTZ NOT NULL DEFAULT now(),
  updated_at                    TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE INDEX idx_tenants_status ON tenants(status);
CREATE INDEX idx_tenants_industry ON tenants(industry);
CREATE INDEX idx_tenants_feature_flags_gin ON tenants USING gin(feature_flags);

CREATE TRIGGER set_updated_at_tenants
  BEFORE UPDATE ON tenants
  FOR EACH ROW EXECUTE FUNCTION set_updated_at();

-- Note: tenants table has NO RLS — it's the row that drives RLS for everyone else.
-- Access is restricted to super_admin role at the application/SQL grant level.

COMMENT ON TABLE tenants IS 
  'Top of multi-tenancy. Hard delete forbidden (ADR 007). '
  'Lifecycle: TRIAL → ACTIVE → SUSPENDED → CHURNED → ARCHIVED. '
  'anonymization_method=IRREVERSIBLE default (ADR 009).';
