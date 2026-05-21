# Module: catalog

> **Status:** Locked (Phase 4)
> **Bounded context:** Catalog

## Position in dependency graph

```
identity (Q)
   ↑
catalog
   ↑ (Q)
pricing, inventory, sales, purchasing, reporting
```

Depended-upon by 5 downstream modules (Q only). Catalog itself only queries identity.

## Aggregate roots

| Aggregate | Phase 2B ref | Lifecycle |
|---|---|---|
| `Product` | §2.B.6 | CREATED → PUBLISHED → ARCHIVED (soft delete) |
| `ProductVariant` | §2.B.7 | CREATED → ACTIVE → DEACTIVATED; **attributes immutable after first sale** |
| `Attribute` (system + tenant) | §2.B.8 | System (4): immutable IMMUTABLE; tenant: CRUD |
| `Brand` | §2.B.9 | CRUD |
| `Category` | §2.B.10 | Tree structure; soft delete |
| `MissingItemRequest` | §2.B.11 | PENDING → RESOLVED/REJECTED |

## Package structure

```
io.stockapp.catalog/
├── api/
│   ├── ProductController.java              # /catalog/products/*
│   ├── VariantController.java              # /catalog/variants/*
│   ├── AttributeController.java            # /catalog/attributes/*
│   ├── BrandController.java
│   ├── CategoryController.java
│   ├── MissingItemController.java
│   └── dto/
├── application/
│   ├── command/
│   │   ├── ProductCommandService.java
│   │   ├── VariantCommandService.java
│   │   ├── AttributeCommandService.java
│   │   ├── BrandCommandService.java
│   │   └── MissingItemCommandService.java
│   ├── query/
│   │   ├── ProductQueryService.java         # Product list, detail
│   │   ├── VariantQueryService.java         # Variant lookup by SKU/barcode/id
│   │   ├── AttributeQueryService.java       # Attribute catalog, system + tenant
│   │   ├── CategoryQueryService.java
│   │   └── BrandQueryService.java
│   └── support/
│       ├── BarcodeAllocator.java            # V{seq:0>10} global opaque (3.B.3)
│       └── DisplayNameComposer.java         # Java-side, per ADR-019
├── domain/
│   ├── product/
│   │   ├── Product.java
│   │   ├── ProductRepository.java
│   │   └── ProductSpecification.java        # filter criteria value object
│   ├── variant/
│   │   ├── ProductVariant.java
│   │   ├── VariantSku.java                  # value object (module-owned)
│   │   ├── VariantBarcode.java              # value object (module-owned)
│   │   ├── VariantAttributes.java           # attribute_id → value mapping
│   │   └── ProductVariantRepository.java
│   ├── attribute/
│   │   ├── Attribute.java
│   │   ├── AttributeValue.java
│   │   ├── AttributeSeed.java               # COLOR, SIZE, MATERIAL, FIT (system)
│   │   └── AttributeRepository.java
│   ├── brand/ + category/ + missingitem/
│   └── event/
│       ├── VariantCreatedEvent.java
│       ├── VariantDeactivatedEvent.java
│       ├── VariantAttributesLockedEvent.java
│       └── ProductPublishedEvent.java
└── infrastructure/
    ├── persistence/
    └── support/
        └── BarcodeSequenceAllocator.java    # JPA sequence-based, prevents race
```

## Transaction ownership

| Operation | Boundary | Propagation |
|---|---|---|
| `ProductCommandService.create()` | REQUIRED | New TX |
| `VariantCommandService.create()` | REQUIRED | Allocates barcode atomically via sequence |
| `VariantCommandService.update()` | REQUIRED | If variant has sale history: rejects attribute mutation (§3.B.3) |
| `AttributeCommandService.lockSeedSystemKey()` | REQUIRED | Per §3.B.5: system_key IMMUTABLE constraint at DB level |

## Outbox events emitted

| Event | When | Consumers |
|---|---|---|
| `VariantCreatedEvent` | New variant | inventory (creates synthetic 0-balance row on first stock movement) |
| `VariantDeactivatedEvent` | Variant deactivated | inventory, sales (allow continued sales for sale-through; reporting) |
| `VariantAttributesLockedEvent` | First sale (sale completion triggers this) | reporting (audit) |
| `ProductPublishedEvent` | Product moves CREATED→PUBLISHED | (none MVP) |

## Outbox events consumed

NONE. Catalog is upstream; doesn't react to other modules.

## ArchUnit rules

- `catalog_only_queries_identity` — catalog has no dep on downstream modules
- `catalog_to_identity_query_only` — only via identity.application.query
- `catalog_cannot_depend_on_pricing` — structure must not couple to commercial policy

## Cache invalidation hooks

| Cache key | Invalidated by |
|---|---|
| `variant-by-barcode:{tenant_id}:{barcode}` | VariantCreatedEvent, VariantDeactivatedEvent |
| `variant-by-sku:{tenant_id}:{sku}` | VariantCreatedEvent (SKU updates rare; manual eviction acceptable v1.1+) |
| `product-list:{tenant_id}` | ProductPublishedEvent, VariantCreatedEvent |
| `attributes-system` | NEVER (system seeds immutable) |
| `attributes-tenant:{tenant_id}` | tenant attribute CRUD |

## Key invariants

1. **Variant attributes immutable after first sale** (§3.B.3): once a sale references variant, attribute (color/size/material/fit) values frozen. SKU still editable with manager permission. Enforced in `VariantCommandService.update()` via `hasSaleHistory()` check.

2. **System attribute system_key IMMUTABLE** (§3.B.5 ADR-018-adjacent): COLOR, SIZE, MATERIAL, FIT seeded per tenant; system_key column has DB-level update prevention trigger.

3. **Barcode allocation atomic, opaque, global** (§3.B.3): format `V{seq:0>10}` (V prefix + 10-digit zero-padded sequence). Sequence allocator prevents duplicate barcodes across concurrent variant creates. Tenant-scoped sequence (each tenant gets its own series).

4. **Display name composed in Java, never in DB** (ADR-019): `DisplayNameComposer` in catalog.application.support. Audit log composer (reporting) follows same pattern.

5. **Brand optional** (§3.B.2): Product may have null brand. Code editable with permission.

## Public API surface (callable from other modules)

Other modules import ONLY from `io.stockapp.catalog.application.query`:

```java
public interface VariantQueryService {
    ProductVariant findById(VariantId id);
    Optional<ProductVariant> findByBarcode(String barcode);
    Optional<ProductVariant> findBySku(String sku);
    List<ProductVariantSummary> searchByQuery(String q, int limit);
    ProductVariantDisplayName composeDisplayName(VariantId id);  // for cross-module use
}

public interface ProductQueryService {
    Product findById(ProductId id);
    Page<ProductSummary> search(ProductSpecification spec, PageRequest page);
}

public interface CategoryQueryService {
    Category findById(CategoryId id);
    List<Category> getDescendants(CategoryId rootId);
}
```

Pricing, inventory, sales, purchasing, reporting all consume these. None can call command services.
