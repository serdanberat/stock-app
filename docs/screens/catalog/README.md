# Phase 3.B — Catalog Management

> **Status:** Locked
> **Phase:** 3.B
> **Delivery date:** 2026-05-16

Catalog management is the second major workflow in Phase 3. Products, variants, pricing, and the attribute palette that drives variant generation.

Phase 3.B establishes patterns that recur across the remaining Phase 3 sub-phases: tab-within-shell navigation, projection-vs-authority disclosure, aggregate ownership enforcement at the UI layer, and Java-side composition over DB functions.

## Screens (5)

| # | Screen | Purpose | Key complexity |
|---|---|---|---|
| 3.B.1 | Product List | Catalog entry; search/filter/scan to find products | Projection-sourced stock disclosure |
| 3.B.2 | Product Create/Edit | Master form for catalog identity | Code editability after sale; manager permission |
| 3.B.3 | Variant Matrix Builder | 2-axis Color × Size bulk generation | Immutable attributes after sale; global barcode allocator |
| 3.B.4 | Pricing Screen | Per-variant pricing + store override | Server authoritative; below-cost reason codes |
| 3.B.5 | Attribute Configuration | Color/size/material palette management | Tenant-owned with system_key identity preservation |

Plus secondary tab in shell:

| # | Screen | Purpose |
|---|---|---|
| 3.B.6 | Missing Item Requests | Manager-side intake queue from POS reports |

## Catalog Shell pattern

This phase establishes the **tab-within-shell** navigation pattern reused in subsequent Phase 3 sub-phases:

```
Catalog Shell  /catalog/*
  ├─ Ürünler            /catalog/products
  ├─ Eksik Bildirimler  /catalog/missing-items
  └─ Özellikler         /catalog/attributes
```

Same bounded context. Same permission group. Same layout shell. Different views, different concerns.

## Locked decisions catalog

### Product (3.B.1, 3.B.2)

- **Stock display label**: "Toplam Stok" (not "Stok") with tooltip about projection nature
- **Bulk actions**: None MVP; per-row only
- **Price column**: NOT in product list (lives in 3.B.4)
- **Product code editability after sale**: Manager permission `catalog.products.change_code_after_sale`
- **Brand**: Optional; "Markasız" label for empty
- **Brand normalization**: trim + collapse whitespace + lowercase + strip ®™
- **Similar brand detection**: Warning only (no auto-merge MVP)
- **Photo pipeline**: Client pre-shrink + server authoritative transform
- **track_inventory field**: Default true, hidden MVP, surfaced v1.1+
- **Scanner active on Product List**: Yes (for managers/stock_clerks); permission-restricted

### Variants (3.B.3)

- **Matrix**: 2-axis Color × Size MVP only (N-axis v1.1+)
- **Schema**: Generic attributes (N-axis ready); UI restricted
- **Barcode format**: `V{seq:0>10}`, global opaque allocator
- **Barcode UNIQUE**: Global (cross-tenant) via Phase 6.B sequence-allocator pattern
- **SKU pattern**: `{code}-{color}-{size}` default; user-customizable
- **Variant attributes after sale**: Immutable (no permission override)
- **completed_sales_count**: Lazy query MVP (no materialized counter)
- **Workflow for attribute fix**: Create new variant + deactivate old
- **Skip reasons in preview**: 5 explicit enum values
- **variant.display_name**: Denormalized cached field; eager update via outbox; Java-composed (NOT DB function)
- **GIN trgm index** on display_name for search

### Pricing (3.B.4)

- **MVP scope**: Base sale price + optional store override
- **Excluded MVP**: Customer tiers, future scheduling, multi-currency, campaigns, wholesale
- **Cost**: Read-only display, info icon with source disclosure (WAC | LAST_PURCHASE | NONE)
- **Auto-commit feedback**: 3-state UX (idle → "Kaydediliyor..." → ✓ flash)
- **Inline "Geri Al"**: Client-side, 5sn window, expires on reload
- **Below-cost reason**: Closed enum (CLEARANCE, DAMAGED, PROMOTION, PRICE_MATCH, MANUAL_OVERRIDE)
- **Effective price invariant**: `COALESCE(store_override, base_price)`
- **Margin wording**: "Markup" with formula `(price - cost) / cost × 100`
- **Cost projection**: MVP direct query; materialize v1.1+
- **Last-change tooltip**: Single-step history (previous price + when + by whom)

### Attributes (3.B.5)

- **Scope**: Tenant-owned; system-seed 4 default types (COLOR, SIZE, MATERIAL, FIT)
- **system_key**: Immutable platform-semantic identifier; nullable for custom types
- **display_name**: Editable with warning if in use; preview before rename
- **Attribute type change**: Immutable (`attribute_type_id` cannot change)
- **Deletion**: Soft only; deactivate retains FK references
- **Type deactivation**: UI hidden only; no "type-less" semantics
- **color_hex**: Optional, COLOR-type only
- **short_code**: Normalized to uppercase; alphanumeric format CHECK
- **usage_count**: Event-driven refresh (no nightly job)
- **Layout**: Vertical sol nav for type list

## Architectural decisions (ADRs)

- **ADR-018 — Pricing Resolution Strategy**: Effective price computed as `COALESCE(store_override, base_price)`; explicit service interface
- **ADR-019 — Display Name Composition Strategy**: Composition in Java (`VariantDisplayNameComposer`), NOT DB function; outbox event-driven refresh; DB pure storage

## Schema additions (Migration 019)

- `products.track_inventory` boolean
- `product_variants.display_name` text + GIN trgm index
- `internal_barcode_seq` sequence
- `product_variants.barcode` UNIQUE constraint (global)
- `variant_prices.below_cost_reason` enum
- `attribute_types.system_key` + `is_system_seed` + `sort_order`
- `attributes.color_hex` + `sort_order` + `usage_count` + short_code format CHECK

See `migrations/019_catalog_extensions.sql`.

## Audit event catalog (Phase 3.B additions)

| Event | Triggered by |
|---|---|
| product_created | New product saved |
| product_updated | Master field changed |
| product_code_changed_after_sale | Manager override on code |
| product_deactivated | Soft delete |
| product_reactivated | Reactivation |
| variant_matrix_generated | Bulk generate commit |
| variant_created | Single variant added |
| variant_attributes_change_blocked | Server rejected change due to sales history |
| variant_sku_changed_after_sale | Manager override on SKU |
| variant_barcode_changed_after_sale | Manager override on barcode |
| variant_deactivated | Soft delete |
| variant_base_price_changed | Pricing mutation |
| variant_store_override_added | Store-specific price added |
| variant_store_override_changed | |
| variant_store_override_removed | |
| variant_price_change_reverted | "Geri Al" used |
| bulk_base_price_applied | "Tümüne uygula" |
| price_set_below_cost | Price < cost with reason captured |
| attribute_type_created | Custom type |
| attribute_type_renamed | Display name changed |
| attribute_type_deactivated | UI hidden |
| attribute_created | New attribute value |
| attribute_renamed | Triggers variant display refresh |
| attribute_color_hex_changed | |
| attribute_deactivated | |
| attribute_reactivated | |
| missing_item_request_created | From POS (Phase 3.A.2) |
| missing_item_request_resolved | Manager created product from request |
| missing_item_request_dismissed | Manager rejected |

## API endpoints (Phase 3.B additions)

| Endpoint | Purpose |
|---|---|
| POST /catalog/products/search | Product list query |
| POST /catalog/products | Create |
| GET /catalog/products/{id} | Read |
| PATCH /catalog/products/{id} | Update |
| POST /catalog/products/{id}/deactivate | Soft delete |
| POST /catalog/products/{id}/reactivate | |
| POST /catalog/products/{id}/photo | Upload photo |
| DELETE /catalog/products/{id}/photo | Remove photo |
| GET /catalog/products/suggest-code | Auto-generate code |
| GET /catalog/products/{id}/variants | Variant list |
| POST /catalog/products/{id}/variants/preview-generate | Matrix preview |
| POST /catalog/products/{id}/variants/commit-generate | Matrix commit |
| PATCH /catalog/variants/{id} | Per-variant edit |
| POST /catalog/variants/{id}/deactivate | |
| GET /pricing/products/{id} | Per-variant pricing data |
| PATCH /pricing/variants/{id} | Set base or store override |
| POST /pricing/products/{id}/apply-base-to-all | Bulk apply |
| GET /pricing/variants/{id}/last-change | Single-step history |
| GET /catalog/attribute-types | Type list |
| POST /catalog/attribute-types | Create custom type |
| PATCH /catalog/attribute-types/{id} | Rename / sort / deactivate |
| GET /catalog/attributes | Values per type |
| POST /catalog/attributes | Create value |
| PATCH /catalog/attributes/{id} | Rename / color_hex / sort |
| GET /catalog/attributes/{id}/usage | Usage count + sample variants |
| POST /catalog/missing-item-requests/{id}/resolve | After product created |
| POST /catalog/missing-item-requests/{id}/dismiss | Manager rejected |

## What's NOT in Phase 3.B scope

- Bulk CSV/Excel import — v1.1+
- N-axis variant matrix builder — v1.1+
- Customer tier pricing — v1.1+
- Future-effective price scheduling — v1.1+
- Multi-currency price lists — v1.1+
- Campaign/promotion rule engine — v1.1+
- Wholesale/VIP price lists — v1.1+
- Cross-product attribute merge tool — v1.1+
- Attribute name i18n — v1.1+
- PDF/photo gallery, crop, reorder — v1.1+
- Bulk delete UI — never (soft delete philosophy)
