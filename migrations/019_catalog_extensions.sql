-- ============================================================================
-- Migration 019: Catalog extensions (Phase 3.B)
-- ============================================================================
-- Adds schema for:
--   - products.track_inventory (hidden MVP, default true)
--   - product_variants.display_name (denormalized cached field; Java-composed)
--   - GIN trgm index on display_name for search
--   - internal_barcode_seq global opaque sequence
--   - product_variants.barcode global UNIQUE constraint
--   - variant_prices.below_cost_reason closed enum
--   - attribute_types.system_key (immutable platform identifier for seeds)
--   - attribute_types.is_system_seed + sort_order
--   - attributes.color_hex (COLOR type only, validated)
--   - attributes.sort_order + usage_count + short_code format CHECK
--
-- Phase 3.B locked decisions:
--   - ADR-018 Pricing Resolution Strategy (effective_price COALESCE)
--   - ADR-019 Display Name Composition Strategy (Java NOT PG function)
--
-- NOTE: No PostgreSQL functions are added by this migration.
-- Display name composition lives in Java (VariantDisplayNameComposer).
-- See ADR-019 for rationale.
-- ============================================================================

-- ----------------------------------------------------------------------------
-- 1. products: track_inventory (hidden field, default true)
-- ----------------------------------------------------------------------------

ALTER TABLE products
    ADD COLUMN track_inventory BOOLEAN NOT NULL DEFAULT true;

COMMENT ON COLUMN products.track_inventory IS
    'Default true MVP. Hidden in UI; surfaced v1.1+ when non-inventory items '
    '(gift cards, services) added. Future use: skip stock tracking for these.';

-- ----------------------------------------------------------------------------
-- 2. product_variants: display_name (denormalized cached field)
-- ----------------------------------------------------------------------------

ALTER TABLE product_variants
    ADD COLUMN display_name TEXT NOT NULL DEFAULT '';

CREATE INDEX idx_variants_display_name_trgm
    ON product_variants USING GIN (display_name gin_trgm_ops);

COMMENT ON COLUMN product_variants.display_name IS
    'Denormalized cached display name (e.g. "T-shirt Basic / Siyah / M"). '
    'Composed by Java VariantDisplayNameComposer service. '
    'Refreshed via outbox events (ProductDisplayNameChanged, AttributeDisplayNameChanged). '
    'Eventually consistent (~1-2s). See ADR-019.';

-- ----------------------------------------------------------------------------
-- 3. Internal barcode sequence (global opaque allocator)
-- ----------------------------------------------------------------------------

CREATE SEQUENCE internal_barcode_seq START 10000000 INCREMENT 1;

COMMENT ON SEQUENCE internal_barcode_seq IS
    'Global opaque barcode allocator. Format: V{seq:0>10} e.g. V0000004721. '
    'No tenant prefix (prevents operational leak on exported/screenshot barcodes). '
    'Allocated via Phase 6.B sequence-allocator pattern (SERIALIZABLE isolation).';

-- ----------------------------------------------------------------------------
-- 4. product_variants.barcode global UNIQUE
-- ----------------------------------------------------------------------------

ALTER TABLE product_variants
    ADD CONSTRAINT product_variants_barcode_unique UNIQUE (barcode);

COMMENT ON CONSTRAINT product_variants_barcode_unique ON product_variants IS
    'Global cross-tenant uniqueness. Defensive layer above sequence allocator. '
    'Enables future flexibility: cross-tenant fraud detection, marketplace transfer (v1.1+).';

-- ----------------------------------------------------------------------------
-- 5. variant_prices.below_cost_reason
-- ----------------------------------------------------------------------------

ALTER TABLE variant_prices
    ADD COLUMN below_cost_reason TEXT
        CHECK (below_cost_reason IS NULL OR below_cost_reason IN (
            'CLEARANCE',
            'DAMAGED',
            'PROMOTION',
            'PRICE_MATCH',
            'MANUAL_OVERRIDE'
        ));

COMMENT ON COLUMN variant_prices.below_cost_reason IS
    'Required only when price < cost at write time. Captured for revenue impact analysis. '
    'NULL when price >= cost or cost is unknown.';

-- ----------------------------------------------------------------------------
-- 6. attribute_types: system_key + is_system_seed + sort_order
-- ----------------------------------------------------------------------------

ALTER TABLE attribute_types
    ADD COLUMN system_key TEXT,
    ADD COLUMN is_system_seed BOOLEAN NOT NULL DEFAULT false,
    ADD COLUMN sort_order INTEGER NOT NULL DEFAULT 0;

-- system_key is unique per tenant for system-seed rows
CREATE UNIQUE INDEX idx_attribute_types_system_key
    ON attribute_types(tenant_id, system_key)
    WHERE system_key IS NOT NULL;

-- system-seed system_keys are immutable (enforced by application; no DB trigger MVP)

COMMENT ON COLUMN attribute_types.system_key IS
    'Immutable platform-semantic identifier (COLOR, SIZE, MATERIAL, FIT). '
    'NULL for custom tenant-created types. Allows cross-tenant analytics on standardized types '
    'while letting tenants rename display_name freely. Immutability enforced in application layer.';

COMMENT ON COLUMN attribute_types.is_system_seed IS
    'True for the 4 default types created on tenant signup. Cannot be hard-deleted (soft only). '
    'display_name editable (i18n). system_key immutable.';

-- ----------------------------------------------------------------------------
-- 7. attributes: color_hex + sort_order + usage_count + short_code CHECK
-- ----------------------------------------------------------------------------

ALTER TABLE attributes
    ADD COLUMN color_hex TEXT
        CHECK (color_hex IS NULL OR color_hex ~ '^#[0-9A-Fa-f]{6}$'),
    ADD COLUMN sort_order INTEGER NOT NULL DEFAULT 0,
    ADD COLUMN usage_count INTEGER NOT NULL DEFAULT 0,
    ADD CONSTRAINT attributes_short_code_format
        CHECK (short_code ~ '^[A-Z0-9]{1,8}$');

COMMENT ON COLUMN attributes.color_hex IS
    'Optional, COLOR type only. Hex RGB format. Used in catalog UI chips/swatches. '
    'Server enforces: must be NULL for non-COLOR attributes.';

COMMENT ON COLUMN attributes.usage_count IS
    'Denormalized count of active variants using this attribute. '
    'Refreshed via event-driven outbox listeners (no nightly job MVP). '
    'Eventually consistent. Drift reconciliation tool v1.1+.';

COMMENT ON CONSTRAINT attributes_short_code_format ON attributes IS
    'Uppercase alphanumeric, max 8 chars. Application normalizes input before insert.';

-- ============================================================================
-- End migration 019
-- ============================================================================
