-- Migration 005_catalog.sql
-- Catalog context: categories, brands, seasons, attribute_*, products, product_variants, 
--                  product_variant_barcodes, *_images, price_lists, variant_prices
-- Depends on: 001 (tenants), 003 (users)

-- ============================================================================
-- categories
-- ============================================================================

CREATE TABLE categories (
  id                            UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  tenant_id                     UUID NOT NULL REFERENCES tenants(id) ON DELETE RESTRICT,
  parent_id                     UUID REFERENCES categories(id) ON DELETE RESTRICT,

  code                          VARCHAR(50) NOT NULL,
  display_name                  VARCHAR(100) NOT NULL,
  description                   TEXT,

  level                         INT NOT NULL DEFAULT 0,
  CONSTRAINT chk_category_level CHECK (level >= 0 AND level <= 4),

  display_order                 INT NOT NULL DEFAULT 0,

  status                        VARCHAR(20) NOT NULL DEFAULT 'ACTIVE',
  CONSTRAINT chk_category_status CHECK (status IN ('ACTIVE','DISABLED','ARCHIVED')),

  metadata                      JSONB NOT NULL DEFAULT '{}'::jsonb,
  archived_at                   TIMESTAMPTZ,
  created_at                    TIMESTAMPTZ NOT NULL DEFAULT now(),
  updated_at                    TIMESTAMPTZ NOT NULL DEFAULT now(),

  CONSTRAINT chk_no_self_parent CHECK (id != parent_id)
);

CREATE UNIQUE INDEX idx_categories_tenant_code
  ON categories(tenant_id, code) WHERE status != 'ARCHIVED';
CREATE INDEX idx_categories_parent ON categories(parent_id);
CREATE INDEX idx_categories_tenant_status ON categories(tenant_id, status);

ALTER TABLE categories ENABLE ROW LEVEL SECURITY;
CREATE POLICY tenant_isolation_categories ON categories USING (tenant_id = current_tenant_id());

CREATE TRIGGER set_updated_at_categories
  BEFORE UPDATE ON categories FOR EACH ROW EXECUTE FUNCTION set_updated_at();

-- ============================================================================
-- brands
-- ============================================================================

CREATE TABLE brands (
  id                            UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  tenant_id                     UUID NOT NULL REFERENCES tenants(id) ON DELETE RESTRICT,
  code                          VARCHAR(50) NOT NULL,
  display_name                  VARCHAR(100) NOT NULL,
  description                   TEXT,
  logo_path                     TEXT,
  CONSTRAINT chk_brand_logo_nonempty CHECK (logo_path IS NULL OR length(trim(logo_path)) > 0),
  status                        VARCHAR(20) NOT NULL DEFAULT 'ACTIVE',
  CONSTRAINT chk_brand_status CHECK (status IN ('ACTIVE','INACTIVE','ARCHIVED')),
  metadata                      JSONB NOT NULL DEFAULT '{}'::jsonb,
  created_at                    TIMESTAMPTZ NOT NULL DEFAULT now(),
  updated_at                    TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE UNIQUE INDEX idx_brands_tenant_code ON brands(tenant_id, code);
ALTER TABLE brands ENABLE ROW LEVEL SECURITY;
CREATE POLICY tenant_isolation_brands ON brands USING (tenant_id = current_tenant_id());
CREATE TRIGGER set_updated_at_brands BEFORE UPDATE ON brands FOR EACH ROW EXECUTE FUNCTION set_updated_at();

-- ============================================================================
-- seasons
-- ============================================================================

CREATE TABLE seasons (
  id                            UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  tenant_id                     UUID NOT NULL REFERENCES tenants(id) ON DELETE RESTRICT,
  code                          VARCHAR(30) NOT NULL,
  display_name                  VARCHAR(100) NOT NULL,
  year                          INT,
  starts_at                     DATE,
  ends_at                       DATE,
  status                        VARCHAR(20) NOT NULL DEFAULT 'ACTIVE',
  CONSTRAINT chk_season_status CHECK (status IN ('ACTIVE','INACTIVE','ARCHIVED')),
  CONSTRAINT chk_season_dates CHECK (ends_at IS NULL OR starts_at IS NULL OR ends_at > starts_at),
  created_at                    TIMESTAMPTZ NOT NULL DEFAULT now(),
  updated_at                    TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE UNIQUE INDEX idx_seasons_tenant_code ON seasons(tenant_id, code);
ALTER TABLE seasons ENABLE ROW LEVEL SECURITY;
CREATE POLICY tenant_isolation_seasons ON seasons USING (tenant_id = current_tenant_id());
CREATE TRIGGER set_updated_at_seasons BEFORE UPDATE ON seasons FOR EACH ROW EXECUTE FUNCTION set_updated_at();

-- ============================================================================
-- attribute_types + attribute_values
-- ============================================================================

CREATE TABLE attribute_types (
  id                            UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  tenant_id                     UUID NOT NULL REFERENCES tenants(id) ON DELETE RESTRICT,
  code                          VARCHAR(30) NOT NULL,
  display_name                  VARCHAR(50) NOT NULL,
  is_system                     BOOLEAN NOT NULL DEFAULT false,

  display_type                  VARCHAR(20) NOT NULL DEFAULT 'TEXT',
  CONSTRAINT chk_display_type CHECK (display_type IN ('TEXT','COLOR_SWATCH','IMAGE','DROPDOWN')),

  display_order                 INT NOT NULL DEFAULT 0,

  status                        VARCHAR(20) NOT NULL DEFAULT 'ACTIVE',
  CONSTRAINT chk_attr_type_status CHECK (status IN ('ACTIVE','INACTIVE','ARCHIVED')),

  created_at                    TIMESTAMPTZ NOT NULL DEFAULT now(),
  updated_at                    TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE UNIQUE INDEX idx_attr_types_tenant_code ON attribute_types(tenant_id, code);
ALTER TABLE attribute_types ENABLE ROW LEVEL SECURITY;
CREATE POLICY tenant_isolation_attr_types ON attribute_types USING (tenant_id = current_tenant_id());
CREATE TRIGGER set_updated_at_attr_types BEFORE UPDATE ON attribute_types FOR EACH ROW EXECUTE FUNCTION set_updated_at();


CREATE TABLE attribute_values (
  id                            UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  tenant_id                     UUID NOT NULL REFERENCES tenants(id) ON DELETE RESTRICT,
  attribute_type_id             UUID NOT NULL REFERENCES attribute_types(id) ON DELETE RESTRICT,

  code                          VARCHAR(50) NOT NULL,
  display_name                  VARCHAR(100) NOT NULL,
  hex_color                     VARCHAR(7),
  image_path                    TEXT,
  CONSTRAINT chk_attr_val_image_nonempty CHECK (image_path IS NULL OR length(trim(image_path)) > 0),
  sort_order                    INT NOT NULL DEFAULT 0,

  status                        VARCHAR(20) NOT NULL DEFAULT 'ACTIVE',
  CONSTRAINT chk_attr_value_status CHECK (status IN ('ACTIVE','INACTIVE','ARCHIVED')),

  metadata                      JSONB NOT NULL DEFAULT '{}'::jsonb,
  archived_at                   TIMESTAMPTZ,
  created_at                    TIMESTAMPTZ NOT NULL DEFAULT now(),
  updated_at                    TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE UNIQUE INDEX idx_attr_values_unique
  ON attribute_values(tenant_id, attribute_type_id, code);
ALTER TABLE attribute_values ENABLE ROW LEVEL SECURITY;
CREATE POLICY tenant_isolation_attr_values ON attribute_values USING (tenant_id = current_tenant_id());
CREATE TRIGGER set_updated_at_attr_values BEFORE UPDATE ON attribute_values FOR EACH ROW EXECUTE FUNCTION set_updated_at();

-- ============================================================================
-- products
-- ============================================================================

CREATE TABLE products (
  id                            UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  tenant_id                     UUID NOT NULL REFERENCES tenants(id) ON DELETE RESTRICT,

  code                          VARCHAR(50) NOT NULL,
  display_name                  VARCHAR(200) NOT NULL,
  description                   TEXT,

  category_id                   UUID NOT NULL REFERENCES categories(id) ON DELETE RESTRICT,
  brand_id                      UUID REFERENCES brands(id) ON DELETE SET NULL,
  season_id                     UUID REFERENCES seasons(id) ON DELETE SET NULL,

  status                        VARCHAR(20) NOT NULL DEFAULT 'DRAFT',
  CONSTRAINT chk_product_status CHECK (status IN ('DRAFT','ACTIVE','INACTIVE','DISCONTINUED','ARCHIVED')),

  inactive_sellable             BOOLEAN NOT NULL DEFAULT false,

  default_vat_rate              NUMERIC(5,2) NOT NULL,
  CONSTRAINT chk_vat_rate CHECK (default_vat_rate >= 0 AND default_vat_rate <= 100),

  default_supplier_party_id     UUID,  -- FK added later when parties table exists

  metadata                      JSONB NOT NULL DEFAULT '{}'::jsonb,
  archived_at                   TIMESTAMPTZ,
  created_at                    TIMESTAMPTZ NOT NULL DEFAULT now(),
  updated_at                    TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE UNIQUE INDEX idx_products_tenant_code
  ON products(tenant_id, code) WHERE status != 'ARCHIVED';
CREATE INDEX idx_products_category ON products(tenant_id, category_id);
CREATE INDEX idx_products_brand ON products(tenant_id, brand_id) WHERE brand_id IS NOT NULL;
CREATE INDEX idx_products_season ON products(tenant_id, season_id) WHERE season_id IS NOT NULL;
CREATE INDEX idx_products_status ON products(tenant_id, status);
CREATE INDEX idx_products_metadata_gin ON products USING gin(metadata);
CREATE INDEX idx_products_name_trgm ON products USING gin(display_name gin_trgm_ops);

ALTER TABLE products ENABLE ROW LEVEL SECURITY;
CREATE POLICY tenant_isolation_products ON products USING (tenant_id = current_tenant_id());

CREATE TRIGGER set_updated_at_products
  BEFORE UPDATE ON products FOR EACH ROW EXECUTE FUNCTION set_updated_at();

-- ============================================================================
-- product_variants
-- ============================================================================

CREATE TABLE product_variants (
  id                            UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  tenant_id                     UUID NOT NULL REFERENCES tenants(id) ON DELETE RESTRICT,
  product_id                    UUID NOT NULL REFERENCES products(id) ON DELETE RESTRICT,

  sku                           VARCHAR(100) NOT NULL,

  color_id                      UUID REFERENCES attribute_values(id) ON DELETE RESTRICT,
  size_id                       UUID REFERENCES attribute_values(id) ON DELETE RESTRICT,
  attributes                    JSONB NOT NULL DEFAULT '{}'::jsonb,

  status                        VARCHAR(20) NOT NULL DEFAULT 'ACTIVE',
  CONSTRAINT chk_variant_status CHECK (status IN ('ACTIVE','INACTIVE','ARCHIVED')),

  metadata                      JSONB NOT NULL DEFAULT '{}'::jsonb,
  archived_at                   TIMESTAMPTZ,
  created_at                    TIMESTAMPTZ NOT NULL DEFAULT now(),
  updated_at                    TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE UNIQUE INDEX idx_variants_tenant_sku ON product_variants(tenant_id, sku);
CREATE INDEX idx_variants_product ON product_variants(product_id);
CREATE INDEX idx_variants_color ON product_variants(color_id) WHERE color_id IS NOT NULL;
CREATE INDEX idx_variants_size ON product_variants(size_id) WHERE size_id IS NOT NULL;
CREATE INDEX idx_variants_status ON product_variants(tenant_id, status);

CREATE UNIQUE INDEX idx_variants_product_attrs
  ON product_variants(
    product_id,
    COALESCE(color_id, '00000000-0000-0000-0000-000000000000'::uuid),
    COALESCE(size_id, '00000000-0000-0000-0000-000000000000'::uuid)
  )
  WHERE status != 'ARCHIVED';

CREATE INDEX idx_variants_attributes_gin ON product_variants USING gin(attributes);

ALTER TABLE product_variants ENABLE ROW LEVEL SECURITY;
CREATE POLICY tenant_isolation_variants ON product_variants USING (tenant_id = current_tenant_id());

CREATE TRIGGER set_updated_at_variants
  BEFORE UPDATE ON product_variants FOR EACH ROW EXECUTE FUNCTION set_updated_at();

-- ============================================================================
-- product_variant_barcodes
-- ============================================================================

CREATE TABLE product_variant_barcodes (
  id                            UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  tenant_id                     UUID NOT NULL REFERENCES tenants(id) ON DELETE RESTRICT,
  variant_id                    UUID NOT NULL REFERENCES product_variants(id) ON DELETE CASCADE,

  barcode                       VARCHAR(50) NOT NULL,
  CONSTRAINT chk_barcode_length CHECK (length(barcode) >= 4 AND length(barcode) <= 50),
  CONSTRAINT chk_barcode_no_whitespace CHECK (barcode !~ '\s'),
  CONSTRAINT chk_barcode_not_empty CHECK (length(trim(barcode)) > 0),

  barcode_scope                 VARCHAR(20) NOT NULL,
  CONSTRAINT chk_barcode_scope CHECK (barcode_scope IN ('INTERNAL','SUPPLIER','GS1_EAN')),

  CONSTRAINT chk_gs1_ean_format CHECK (
    barcode_scope != 'GS1_EAN'
    OR (length(barcode) = 13 AND barcode ~ '^[0-9]{13}$')
  ),
  CONSTRAINT chk_internal_format CHECK (
    barcode_scope != 'INTERNAL' OR barcode ~ '^[0-9A-Z\-]+$'
  ),

  is_primary                    BOOLEAN NOT NULL DEFAULT false,
  source                        VARCHAR(100),
  created_at                    TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE UNIQUE INDEX idx_barcodes_tenant_code
  ON product_variant_barcodes(tenant_id, barcode);
CREATE INDEX idx_barcodes_variant ON product_variant_barcodes(variant_id);
CREATE INDEX idx_barcodes_scope ON product_variant_barcodes(barcode_scope);
CREATE UNIQUE INDEX idx_one_primary_barcode_per_variant
  ON product_variant_barcodes(variant_id) WHERE is_primary = true;

ALTER TABLE product_variant_barcodes ENABLE ROW LEVEL SECURITY;
CREATE POLICY tenant_isolation_barcodes ON product_variant_barcodes USING (tenant_id = current_tenant_id());

-- ============================================================================
-- product_images, variant_images
-- ============================================================================

CREATE TABLE product_images (
  id                            UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  tenant_id                     UUID NOT NULL REFERENCES tenants(id) ON DELETE RESTRICT,
  product_id                    UUID NOT NULL REFERENCES products(id) ON DELETE CASCADE,

  storage_path                  TEXT NOT NULL,
  CONSTRAINT chk_prod_img_path CHECK (length(trim(storage_path)) > 0),
  thumbnail_path                TEXT,
  alt_text                      VARCHAR(200),
  display_order                 INT NOT NULL DEFAULT 0,
  is_primary                    BOOLEAN NOT NULL DEFAULT false,

  uploaded_at                   TIMESTAMPTZ NOT NULL DEFAULT now(),
  uploaded_by_user_id           UUID REFERENCES users(id) ON DELETE SET NULL
);

CREATE INDEX idx_product_images_product ON product_images(product_id, display_order);
CREATE UNIQUE INDEX idx_one_primary_image_per_product
  ON product_images(product_id) WHERE is_primary = true;

ALTER TABLE product_images ENABLE ROW LEVEL SECURITY;
CREATE POLICY tenant_isolation_product_images ON product_images USING (tenant_id = current_tenant_id());


CREATE TABLE variant_images (
  id                            UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  tenant_id                     UUID NOT NULL REFERENCES tenants(id) ON DELETE RESTRICT,
  variant_id                    UUID NOT NULL REFERENCES product_variants(id) ON DELETE CASCADE,

  storage_path                  TEXT NOT NULL,
  CONSTRAINT chk_var_img_path CHECK (length(trim(storage_path)) > 0),
  thumbnail_path                TEXT,
  alt_text                      VARCHAR(200),
  display_order                 INT NOT NULL DEFAULT 0,
  is_primary                    BOOLEAN NOT NULL DEFAULT false,

  uploaded_at                   TIMESTAMPTZ NOT NULL DEFAULT now(),
  uploaded_by_user_id           UUID REFERENCES users(id) ON DELETE SET NULL
);

CREATE INDEX idx_variant_images_variant ON variant_images(variant_id, display_order);
CREATE UNIQUE INDEX idx_one_primary_image_per_variant
  ON variant_images(variant_id) WHERE is_primary = true;

ALTER TABLE variant_images ENABLE ROW LEVEL SECURITY;
CREATE POLICY tenant_isolation_variant_images ON variant_images USING (tenant_id = current_tenant_id());

-- ============================================================================
-- price_lists + variant_prices
-- ============================================================================

CREATE TABLE price_lists (
  id                            UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  tenant_id                     UUID NOT NULL REFERENCES tenants(id) ON DELETE RESTRICT,

  code                          VARCHAR(50) NOT NULL,
  display_name                  VARCHAR(100) NOT NULL,
  description                   TEXT,

  is_default                    BOOLEAN NOT NULL DEFAULT false,
  currency                      VARCHAR(10) NOT NULL DEFAULT 'TRY',  -- FK tightened in v1.1
  customer_segment              VARCHAR(50),

  status                        VARCHAR(20) NOT NULL DEFAULT 'ACTIVE',
  CONSTRAINT chk_pricelist_status CHECK (status IN ('DRAFT','ACTIVE','SUSPENDED','EXPIRED','CANCELLED')),

  valid_from                    TIMESTAMPTZ NOT NULL DEFAULT now(),
  valid_until                   TIMESTAMPTZ,
  CONSTRAINT chk_pricelist_dates CHECK (valid_until IS NULL OR valid_until > valid_from),

  created_at                    TIMESTAMPTZ NOT NULL DEFAULT now(),
  updated_at                    TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE UNIQUE INDEX idx_pricelists_tenant_code ON price_lists(tenant_id, code);
CREATE UNIQUE INDEX idx_one_default_pricelist_per_tenant
  ON price_lists(tenant_id) WHERE is_default = true;

ALTER TABLE price_lists ENABLE ROW LEVEL SECURITY;
CREATE POLICY tenant_isolation_pricelists ON price_lists USING (tenant_id = current_tenant_id());

CREATE TRIGGER set_updated_at_pricelists
  BEFORE UPDATE ON price_lists FOR EACH ROW EXECUTE FUNCTION set_updated_at();


CREATE TABLE variant_prices (
  id                            UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  tenant_id                     UUID NOT NULL REFERENCES tenants(id) ON DELETE RESTRICT,
  variant_id                    UUID NOT NULL REFERENCES product_variants(id) ON DELETE RESTRICT,
  price_list_id                 UUID NOT NULL REFERENCES price_lists(id) ON DELETE RESTRICT,
  currency                      VARCHAR(10) NOT NULL,

  price                         NUMERIC(15,4) NOT NULL,
  CONSTRAINT chk_price_nonneg CHECK (price >= 0),

  reason_code                   VARCHAR(50),
  CONSTRAINT chk_price_reason CHECK (reason_code IS NULL OR reason_code IN (
    'CAMPAIGN','INFLATION_UPDATE','COST_INCREASE','COST_DECREASE',
    'MARGIN_ADJUSTMENT','COMPETITIVE_PRICING','MANUAL_CORRECTION',
    'SEASON_END','NEW_SEASON','CLEARANCE','SUPPLIER_DEAL','OTHER'
  )),
  reason_notes                  TEXT,
  CONSTRAINT chk_other_needs_notes CHECK (
    reason_code != 'OTHER' OR (reason_notes IS NOT NULL AND length(reason_notes) > 0)
  ),

  valid_from                    TIMESTAMPTZ NOT NULL DEFAULT now(),
  valid_until                   TIMESTAMPTZ,
  CONSTRAINT chk_price_dates CHECK (valid_until IS NULL OR valid_until > valid_from),

  created_at                    TIMESTAMPTZ NOT NULL DEFAULT now(),
  created_by_user_id            UUID REFERENCES users(id) ON DELETE SET NULL,

  -- ADR 003: non-overlapping intervals per (variant, list, currency)
  EXCLUDE USING gist (
    variant_id WITH =,
    price_list_id WITH =,
    currency WITH =,
    tstzrange(valid_from, valid_until, '[)') WITH &&
  )
);

CREATE INDEX idx_variant_prices_lookup
  ON variant_prices(variant_id, price_list_id, currency, valid_from DESC);
CREATE INDEX idx_variant_prices_active
  ON variant_prices(variant_id, price_list_id, currency)
  WHERE valid_until IS NULL;

ALTER TABLE variant_prices ENABLE ROW LEVEL SECURITY;
CREATE POLICY tenant_isolation_variant_prices ON variant_prices USING (tenant_id = current_tenant_id());

-- Only valid_until may be updated (closing of intervals)
CREATE OR REPLACE FUNCTION prevent_variant_price_modification()
RETURNS TRIGGER AS $$
BEGIN
  IF NEW.price IS DISTINCT FROM OLD.price
     OR NEW.currency IS DISTINCT FROM OLD.currency
     OR NEW.variant_id IS DISTINCT FROM OLD.variant_id
     OR NEW.price_list_id IS DISTINCT FROM OLD.price_list_id
     OR NEW.valid_from IS DISTINCT FROM OLD.valid_from THEN
    RAISE EXCEPTION 'variant_prices: only valid_until may be updated (interval closing)';
  END IF;
  RETURN NEW;
END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER protect_variant_price_immutable
  BEFORE UPDATE ON variant_prices
  FOR EACH ROW EXECUTE FUNCTION prevent_variant_price_modification();
