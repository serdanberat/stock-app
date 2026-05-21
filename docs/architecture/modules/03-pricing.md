# Module: pricing

> **Status:** Locked (Phase 4)
> **Bounded context:** Pricing
> **Why separate from catalog:** §3.B.4 + ADR-018. Catalog = structure ("what is this variant?"); Pricing = commercial policy ("at what price does this variant sell?"). Future expansion (promotions, customer tier pricing, time windows) lands in pricing without touching catalog.

## Position in dependency graph

```
catalog (Q)
   ↑
pricing
   ↑ (Q)
sales, reporting
```

Reads catalog query only. Reverse direction (catalog → pricing) is forbidden by ArchUnit. Sales reads pricing.query for line resolution. Pricing never mutates anything else.

## Aggregate roots

| Aggregate | Phase 2B ref | Lifecycle |
|---|---|---|
| `PriceList` | §2.B.12 | DRAFT → ACTIVE → ARCHIVED |
| `PriceListEntry` | §2.B.13 | Child of PriceList; (variant_id, price) tuple |
| `StorePriceOverride` | §2.B.14 | Per (variant_id, store_id, price); explicit override layer |

## Package structure

```
io.stockapp.pricing/
├── api/
│   ├── PricingAdminController.java         # /pricing/lists/*, /pricing/overrides/*
│   └── dto/
├── application/
│   ├── command/
│   │   ├── PriceListCommandService.java    # CRUD on price lists
│   │   ├── PriceListEntryCommandService.java
│   │   └── StoreOverrideCommandService.java  # Auto-commit 3-state per §3.B.4
│   └── query/
│       ├── PricingResolutionService.java   # CRITICAL — per ADR-018
│       ├── PriceListQueryService.java
│       └── StoreOverrideQueryService.java
├── domain/
│   ├── pricelist/
│   │   ├── PriceList.java
│   │   ├── PriceListEntry.java
│   │   └── PriceListRepository.java
│   ├── override/
│   │   ├── StorePriceOverride.java
│   │   └── StorePriceOverrideRepository.java
│   ├── resolution/
│   │   ├── PricingPolicy.java               # value object: how to resolve
│   │   ├── ResolvedPrice.java               # value object: (amount, source)
│   │   └── PricingSource.java               # enum: BASE_LIST / STORE_OVERRIDE
│   └── event/
│       ├── PriceListActivatedEvent.java
│       ├── PriceChangedEvent.java
│       └── StoreOverrideAppliedEvent.java
└── infrastructure/
    └── persistence/
```

## Transaction ownership

| Operation | Boundary | Propagation |
|---|---|---|
| `PriceListCommandService.activate()` | REQUIRED | Emits PriceListActivatedEvent |
| `PriceListEntryCommandService.upsert()` | REQUIRED | Per-variant price set/update |
| `StoreOverrideCommandService.commit()` | REQUIRED | 3-state auto-commit per §3.B.4 (DRAFT → COMMITTED, "Geri Al" 5s window) |
| `PricingResolutionService.resolve()` | READ_ONLY | Stateless lookup; heavily cached |

## Outbox events emitted

| Event | When | Consumers |
|---|---|---|
| `PriceListActivatedEvent` | Price list activated | (cache invalidation: pricing's own cache) |
| `PriceChangedEvent` | Entry upsert | (cache invalidation only) |
| `StoreOverrideAppliedEvent` | Override commit | (cache invalidation only) |
| `BelowCostPriceSetEvent` | Price set below WAC at commit time | reporting (markup analysis surface) |

## Outbox events consumed

NONE.

## ArchUnit rules

- `pricing_query_only_to_catalog`
- `catalog_cannot_depend_on_pricing` (reverse forbidden)
- `inventory_cannot_depend_on_pricing` (downstream isolation)

## Cache invalidation hooks

CRITICAL: pricing's cache must be very aggressive because every POS line resolution hits it.

| Cache key | Invalidated by |
|---|---|
| `resolved-price:{tenant_id}:{variant_id}:{store_id}` | PriceChangedEvent, StoreOverrideAppliedEvent (for affected variant_id), PriceListActivatedEvent (entire list invalidation) |
| `price-list-active:{tenant_id}` | PriceListActivatedEvent |
| `store-overrides:{tenant_id}:{store_id}` | StoreOverrideAppliedEvent |

Cache layer: Caffeine; TTL 10min default. Sale flow (3.A.5) bypasses cache when needed via `?fresh=true`.

## Key invariants

1. **Resolution priority** (ADR-018): `StorePriceOverride > active PriceListEntry > error`. PricingResolutionService is the single authoritative path. Direct DB query forbidden.

2. **Price snapshot frozen at add-to-cart** (§3.A.1): line.unit_price_gross frozen at scan time; pricing changes mid-sale do NOT affect open drafts.

3. **Below-cost requires reason at commit time** (§3.B.4 + ADR-018): closed enum `below_cost_reason`. Emits `BelowCostPriceSetEvent` for audit.

4. **Markup wording, not Margin** (§3.B.4 + 3.F.6): formula `(price - cost) / cost`. Pricing module exposes `computeMarkup()`, never `computeMargin()`.

5. **Auto-commit 3-state UX** (§3.B.4): editing → debounced commit → "Geri Al 5sn" undo window. Domain doesn't know about UX, but command service supports `revertLastCommit(operationId)` within 5s grace.

## Public API surface

```java
public interface PricingResolutionService {
    /**
     * Single authoritative path for "what does this variant cost in this store?"
     * Used by sales (POS line resolution), reporting (markup analysis), 
     * exchange flow (new sale lines).
     */
    ResolvedPrice resolve(VariantId variantId, StoreId storeId);
    
    /**
     * Batch resolution; preferred for multi-line POS scenarios.
     * Single query path; avoids N+1.
     */
    Map<VariantId, ResolvedPrice> resolveBatch(Set<VariantId> variantIds, StoreId storeId);
}

public interface PriceListQueryService {
    PriceList findActive();
    List<PriceListEntry> getEntries(PriceListId listId, PageRequest page);
}
```

Sales depends on `PricingResolutionService.resolve()` for every POS scan. Reporting uses both query services for markup analysis.
