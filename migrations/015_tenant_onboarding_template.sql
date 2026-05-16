-- Migration 015_tenant_onboarding_template.sql
--
-- TENANT ONBOARDING TEMPLATE
--
-- This file is NOT a migration to run at DB init.
-- It is a SQL TEMPLATE called by the application's tenant CREATE handler.
-- The application supplies the parameters ($tenant_code, $owner_email, etc.)
-- and executes this script inside a single transaction.
--
-- A real production deployment will encode this logic in application code
-- (TypeScript/Python/Go service method). This file documents the canonical
-- onboarding flow for reference and for manual provisioning during development.
--
-- USAGE EXAMPLE (psql with variables):
--   psql -v tenant_code='mağaza_x' \
--        -v tenant_name='Mağaza X' \
--        -v industry='clothing' \
--        -v owner_email='admin@mağaza-x.com' \
--        -v owner_display_name='Admin User' \
--        -v owner_password_hash='$2b$12$...' \
--        -f 015_tenant_onboarding_template.sql

BEGIN;

-- ============================================================================
-- Step 1: Create the tenant row
-- ============================================================================

WITH inserted_tenant AS (
  INSERT INTO tenants (
    code, display_name, industry, status,
    trial_started_at, trial_ends_at,
    preferred_fx_source, default_currency, default_vat_rate,
    feature_flags, settings
  ) VALUES (
    :'tenant_code',
    :'tenant_name',
    :'industry',
    'TRIAL',
    now(),
    now() + interval '30 days',
    'TCMB',
    'TRY',
    20.00,
    '{
      "allow_admin_register_reopen": false,
      "allow_admin_sale_reverse": false,
      "allow_admin_return_reverse": false,
      "allow_blind_return": false,
      "allow_negative_stock": false,
      "auto_block_on_overdue_days": null,
      "blind_return_max_amount_per_day": 5000,
      "blind_return_max_count_per_day": 10,
      "blind_return_manager_threshold": 1000,
      "blind_return_customer_frequency_limit": 3,
      "blind_return_excluded_categories": []
    }'::jsonb,
    '{
      "return_grace_days": 14,
      "return_manager_threshold": 1000,
      "product_code_template": "{CATEGORY}-{YEAR}-{SEQ:5}",
      "price_cipher_keyword": null,
      "tenant_prefix_for_barcodes": "20",
      "z_report_number_prefix": null
    }'::jsonb
  )
  RETURNING id
)
SELECT id AS new_tenant_id FROM inserted_tenant \gset

-- Application code will capture the new_tenant_id and supply it for the
-- remaining steps. In a real implementation this is a single transaction
-- variable, not psql gset.

-- For documentation purposes, the rest of the template uses placeholder UUIDs.
-- Application code replaces these with actual values.

-- ============================================================================
-- Step 2: Set the RLS session variable so subsequent INSERTs see this tenant
-- ============================================================================

-- SET LOCAL app.tenant_id = '<new_tenant_id>';

-- ============================================================================
-- Step 3: Create initial owner user
-- ============================================================================

-- INSERT INTO users (tenant_id, email, display_name, status, password_hash, email_verified_at)
-- VALUES (
--   '<new_tenant_id>',
--   :'owner_email',
--   :'owner_display_name',
--   'ACTIVE',
--   :'owner_password_hash',
--   now()
-- ) RETURNING id;
-- -- Capture as <owner_user_id>

-- ============================================================================
-- Step 4: Assign SUPER_ADMIN role to owner
-- ============================================================================

-- INSERT INTO user_role_assignments (tenant_id, user_id, role_id, store_scope_ids, assigned_by_user_id)
-- SELECT
--   '<new_tenant_id>',
--   '<owner_user_id>',
--   r.id,
--   NULL,
--   '<owner_user_id>'
-- FROM roles r
-- WHERE r.code = 'SUPER_ADMIN' AND r.is_system = true;

-- ============================================================================
-- Step 5: Create VIRTUAL_IN_TRANSIT store (Phase 2A invariant - mandatory)
-- ============================================================================

-- INSERT INTO stores (tenant_id, code, display_name, store_type, status)
-- VALUES ('<new_tenant_id>', 'VIRTUAL_TRANSIT', 'Transfer Aracında', 'VIRTUAL_IN_TRANSIT', 'ACTIVE');

-- ============================================================================
-- Step 6: Create tenant-specific attribute types
-- (5 standard types, system-flagged, per-tenant for customization)
-- ============================================================================

-- INSERT INTO attribute_types (tenant_id, code, display_name, is_system, display_type, display_order, status) VALUES
--   ('<new_tenant_id>', 'COLOR', 'Renk', true, 'COLOR_SWATCH', 1, 'ACTIVE'),
--   ('<new_tenant_id>', 'SIZE', 'Beden', true, 'DROPDOWN', 2, 'ACTIVE'),
--   ('<new_tenant_id>', 'MATERIAL', 'Materyal', true, 'TEXT', 3, 'ACTIVE'),
--   ('<new_tenant_id>', 'MODEL', 'Model', true, 'TEXT', 4, 'ACTIVE'),
--   ('<new_tenant_id>', 'GENDER', 'Cinsiyet', true, 'DROPDOWN', 5, 'ACTIVE');

-- ============================================================================
-- Step 7: Create default price list
-- ============================================================================

-- INSERT INTO price_lists (tenant_id, code, display_name, is_default, currency, status, valid_from)
-- VALUES ('<new_tenant_id>', 'DEFAULT', 'Standart Fiyat Listesi', true, 'TRY', 'ACTIVE', now());

-- ============================================================================
-- Step 8: Initialize outbox global sequence
-- ============================================================================

-- INSERT INTO outbox_global_sequences (tenant_id, next_sequence)
-- VALUES ('<new_tenant_id>', 1)
-- ON CONFLICT (tenant_id) DO NOTHING;

-- ============================================================================
-- Step 9: Emit TENANT_CREATED domain event to outbox
-- ============================================================================

-- INSERT INTO outbox_events (
--   event_id, tenant_id, aggregate_type, aggregate_id, aggregate_version,
--   event_type, event_version, partition_key, payload, metadata
-- ) VALUES (
--   gen_random_uuid(),
--   '<new_tenant_id>',
--   'Tenant',
--   '<new_tenant_id>',
--   1,
--   'tenant.created.v1',
--   1,
--   '<new_tenant_id>'::text,
--   jsonb_build_object(
--     'tenant_id', '<new_tenant_id>',
--     'tenant_code', :'tenant_code',
--     'industry', :'industry',
--     'plan', 'BASIC',
--     'trial_ends_at', (now() + interval '30 days')::text
--   ),
--   jsonb_build_object('source', 'tenant_onboarding')
-- );

-- ============================================================================
-- Step 10: Audit event
-- ============================================================================

-- INSERT INTO audit_event_log (
--   tenant_id, event_type, aggregate_type, aggregate_id,
--   actor_user_id, severity, description, details
-- ) VALUES (
--   '<new_tenant_id>',
--   'TENANT_CREATED',
--   'Tenant',
--   '<new_tenant_id>',
--   '<owner_user_id>',
--   'INFO',
--   'Tenant created via onboarding flow',
--   jsonb_build_object('industry', :'industry', 'plan', 'BASIC')
-- );

COMMIT;

-- ============================================================================
-- POST-ONBOARDING (handled separately, may run async or be deferred to first use)
-- ============================================================================
--
-- - cash_registers           — tenant configures from UI per store
-- - categories               — tenant defines based on their product line
-- - brands, seasons          — domain-specific
-- - attribute_values         — defined per attribute_type as tenant adds products
-- - document_sequences       — created lazily on first sale
-- - account_movement_sequences — created lazily per account_profile
-- - account_profiles         — created on first business relationship per (party, role, currency)
