# ADR-019 — Display Name Composition Strategy

**Status:** Accepted
**Date:** 2026-05-16
**Phase:** 3.B.3, 3.B.5

## Context

`ProductVariant` requires a human-readable display name for:
- POS Main Sale screen (3.A.1) cart line text
- POS Product Search results (3.A.2)
- Sale receipt rendering (3.A.7)
- Variant Matrix LIST mode (3.B.3)
- Reports (Phase 3.J)
- Customer-facing email receipts (Phase 3.G)
- Future B2B exports, marketplace integrations

The composition rule today:
```
"{product.display_name} / {color.display_name} / {size.display_name}"
e.g. "T-shirt Basic / Siyah / M"
```

This requires reading from 3 aggregates:
1. ProductVariant (Catalog ctx)
2. Product (Catalog ctx)
3. Attribute values per attribute_type (Catalog ctx)

If computed at every read, this is a 3-table JOIN per variant lookup. Multiple variants in POS cart = N×3 reads.

## Decision

The composed `display_name` is **denormalized** onto `product_variants.display_name` as a cached STRING column. Composition logic lives in Java, not DB.

### Composer interface

```java
public interface VariantDisplayNameComposer {
    String compose(VariantDisplayContext ctx);
}

public record VariantDisplayContext(
    String productName,
    Map<AttributeTypeRef, String> attributesByType,  // ordered by attribute_type.sort_order
    Locale locale,
    DisplayFormat format  // FULL | SHORT | RECEIPT | EXPORT
) {}
```

### Refresh strategy: event-driven eager update

Triggered by outbox events:
- `ProductDisplayNameChangedV1` → refresh all variants of the product
- `AttributeDisplayNameChangedV1` → refresh all variants using that attribute
- `VariantCreatedV1` → compute on creation
- `AttributeAttachedToVariantV1` → compute on attach (rare; mostly at creation)

Application module listener:
```java
@ApplicationModuleListener
void onAttributeRenamed(AttributeRenamedV1 event) {
    var variantIds = variantRepo.findIdsUsingAttribute(event.attributeId());
    for (var batch : Lists.partition(variantIds, 100)) {
        var newNames = batch.stream()
            .collect(toMap(id -> id, id -> composer.compose(buildContext(id))));
        variantRepo.bulkUpdateDisplayNames(newNames);
    }
}
```

Eventually consistent: ~1-2 seconds after attribute change.

### DB responsibility

- Storage column: `product_variants.display_name TEXT NOT NULL DEFAULT ''`
- Search index: `CREATE INDEX ... USING GIN (display_name gin_trgm_ops)`
- NO compute logic in DB (no stored procedures, no functions)

### Alternative formats

The `DisplayFormat` enum lets one Java composer produce multiple presentations:
- `FULL`: "T-shirt Basic / Siyah / M"
- `SHORT`: "T-shirt BLK/M"
- `RECEIPT`: "T-shirt Siyah M" (no slashes; printer-friendly)
- `EXPORT`: "T-shirt-Basic|Siyah|M" (data export with delimiters)

MVP renders `FULL` to the persisted `display_name` column. Other formats computed on-demand at the call site (no separate storage).

## Why Java composition, NOT PG function

This decision deserves explicit explanation because it was reconsidered mid-design.

A PG function `compute_variant_display_name(variant_id)` was initially proposed for performance (single SQL call). It was rejected because:

1. **Domain logic doesn't belong in the database**. The composition rule is a Catalog domain concern, not a persistence concern. PostgreSQL function couples our domain to PL/pgSQL and makes refactoring expensive.

2. **Locale and format variation needs Java code**. PostgreSQL supports basic locale via `unaccent` and `lower`, but real locale-aware composition (Turkish dotted-i normalization, RTL rendering for Arabic export) requires application-layer code with proper ICU library access.

3. **Testing is harder**. Unit testing a PG function requires PostgreSQL fixtures + pgTAP or similar. Java composer is trivially unit-testable.

4. **Hot path is denormalized read, not compute**. The PG function would only run on refresh events (rare). Display reads hit the cached column, which is just a SELECT. There's no performance benefit to having the compute be SQL.

5. **Refactor cost**. Adding a new display format (RECEIPT vs EXPORT) in a PG function = ALTER FUNCTION migration. In Java = new method, hot reload in dev.

6. **Project discipline**. This codebase has consistently kept business logic out of the database. Breaking that pattern in one place opens the door to others.

### When PG functions ARE appropriate

This ADR does not prohibit PG functions universally. They are appropriate for:
- Aggregations that benefit from set-based processing (count, sum, ranking)
- Index expressions (e.g., `lower(unaccent(name))` in generated columns)
- Trigger-based integrity constraints (e.g., append-only enforcement via `prevent_audit_mutation()`)

The rule is: **PG functions for persistence-layer concerns; Java for domain composition.**

## Consequences

### Positive

- **Composition rule centralized in one Java service**: single source of truth.
- **Localization-ready**: `Locale` parameter on composer; tenants can request `tr-TR` or `en-US` outputs.
- **Format flexibility**: same data renders differently for POS vs receipt vs export.
- **Testable**: composer is a pure function; trivial unit tests.
- **Refactorable**: new formats added without schema changes.

### Negative

- **Eventual consistency window**: attribute rename takes ~1-2s to propagate to variant display names. During this window, POS could display old name briefly.
- **Outbox event consumer must be correct**: missing or buggy listener = stale display_names indefinitely.
- **Bulk operations cost**: renaming a frequently-used attribute (e.g., "Siyah" used in 1000 variants) triggers 1000 row updates. Acceptable for boutique scale (maximum few thousand variants per tenant).

### Neutral

- Migration removes the previously-considered `compute_variant_display_name()` PG function from the schema.

## Implementation notes

- `VariantDisplayNameComposer` interface defined in catalog-api module
- Default implementation in catalog-domain module
- Bulk refresh uses `variantRepo.bulkUpdateDisplayNames(Map<UUID, String>)` to batch updates
- Outbox event consumers in catalog-consumers module
- GIN trgm index on `display_name` for fast LIKE search (POS product search 3.A.2)

## Pattern for future Phase work

This ADR establishes a reusable pattern for similar denormalized computed fields:

1. **Identify a denormalization candidate**: derived value that's read often, computed from multiple aggregates
2. **Store on the most-read aggregate** as a cached column
3. **Compute in Java service** (composer or computer interface)
4. **Refresh via outbox event listeners** on source aggregate mutations
5. **Eventually consistent**; document the staleness window

Examples for future phases:
- Customer aggregate's `lifetime_value` (Phase 3.G)
- Product's `total_units_sold_30d` (Phase 3.J)
- Store's `current_stock_value` (Phase 3.J)

DO NOT use this pattern for:
- Real-time financial state (use authoritative read)
- Pricing decisions (see ADR-018 for service-based resolution)
- Inventory quantities at point-of-sale (use stock_balances with FOR UPDATE)
