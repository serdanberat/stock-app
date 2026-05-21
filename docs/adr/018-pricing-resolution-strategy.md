# ADR-018 — Pricing Resolution Strategy

**Status:** Accepted
**Date:** 2026-05-16
**Phase:** 3.B.4

## Context

The Pricing aggregate (`variant_prices`) holds two types of price information per variant:
- **base_price**: default price across all stores
- **store_overrides**: optional per-store price that supersedes base

Multiple consumers need to compute the "effective" sale price for a variant at a given store and time:
- POS Main Sale (3.A.1) when adding item
- POS Payment Screen (3.A.5) when computing totals
- Reports (Phase 3.J) for revenue analysis
- Stock valuation views

These consumers must reach identical decisions to prevent reconciliation drift.

## Decision

The effective price is computed via a single resolution rule:

```
effective_price(variant_id, store_id, T) =
    COALESCE(
        store_override_price(variant_id, store_id, T),
        base_price(variant_id, T)
    )
```

### Invariants

1. **Fallback chain is two levels deep, not more**: override → base. No cascading from store group → region → tenant. Stack expansion (campaigns, tiers) deferred to v1.1+.

2. **Removal is explicit**: when a store override is removed, the user takes an explicit DELETE action. Setting override to equal base price is allowed but warned against (semantically meaningful: "this store explicitly matches base"). This preserves auditability of override lifecycle.

3. **Base change inherits**: when `base_price` changes on a variant, all stores WITHOUT an override automatically receive the new effective price. Stores WITH overrides remain unchanged.

4. **No temporal scheduling MVP**: `effective_from = now()` implicit on every mutation. Future-effective prices are v1.1+ feature.

### Service interface

A single `PricingResolutionService` interface in the Pricing module:

```java
public interface PricingResolutionService {
    Money resolveEffectivePrice(UUID variantId, UUID storeId, Instant at);
    Map<UUID, Money> resolveEffectivePrices(Collection<UUID> variantIds, UUID storeId, Instant at);
}
```

All consumers (POS, Reports, Inventory valuation) call this service. Direct SQL queries on `variant_prices` from outside the Pricing module are forbidden by ArchUnit.

### Caching

Eligible for Caffeine cache:
- Key: `(variant_id, store_id)`
- TTL: 60 seconds
- Eviction on outbox events: `VariantBasePriceChangedV1`, `VariantStoreOverrideChangedV1`, `VariantStoreOverrideRemovedV1`

POS Main Sale uses fresh resolution at cart-add time (not cached). Reports tolerate 60s staleness.

## Consequences

### Positive

- **Single source of truth**: One resolution algorithm, exercised through one service.
- **Testable**: Resolution can be unit-tested deterministically with various override configurations.
- **Refactorable**: When v1.1+ adds customer tier pricing, the service interface extends without breaking call sites (just adds optional `customerId` parameter to query path).
- **Auditable**: Service can emit `effective_price_resolved` events for fraud analysis (not enabled MVP).

### Negative

- **Slight indirection**: Code that "just needs the price" goes through service instead of direct field access.
- **Cache invalidation surface**: Outbox event consumers must trigger invalidation; missing one = stale price.

### Neutral

- v1.1+ extensions (customer tiers, campaigns, time-windows) layer on top without breaking MVP consumers.

## Alternatives considered

### A. Direct query at each call site

Each consumer (POS, Reports, etc.) writes its own query against `variant_prices`. Pros: no indirection. Cons: resolution algorithm duplicated; bug-prone; refactor expensive.

Rejected because pricing is fraud-sensitive: drift between consumers leads to "POS says ₺99, report says ₺95" production incidents.

### B. Embed effective price in `product_variants.current_effective_price`

Denormalize the effective price onto the variant itself. Pros: fast read. Cons: store-specific overrides break the model (one variant has N effective prices, one per store).

Rejected because it doesn't generalize to per-store override.

### C. Materialized view of effective prices

`mview_variant_effective_prices(variant_id, store_id, price)` refreshed by triggers. Pros: fast read. Cons: materialization complexity; eventually consistent without obvious staleness window; refresh strategy unclear.

Rejected as over-engineered for MVP scale. Consider v1.1+ if `PricingResolutionService` becomes hot.

## Implementation note

Resolution function in Java side, not PostgreSQL function. Pricing module composes computation; DB stores raw values. This is consistent with ADR-019 (Display Name Composition).
