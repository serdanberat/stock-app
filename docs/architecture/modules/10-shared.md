# Module: shared (kernel)

> **Status:** Locked (Phase 4)
> **NOT a Spring Modulith module:** common value objects + cross-cutting abstractions only.

## Purpose

Shared kernel: value objects, identifiers, base exceptions, abstractions that ALL modules need. Strictly bounded by ArchUnit allowlist to prevent "junk drawer" drift.

## Position in dependency graph

```
shared (no dependencies on any module)
   ↑ (every module imports from here)
identity, catalog, pricing, inventory, sales, purchasing, finance, cashregister, reporting
```

Shared depends on **nothing** module-specific. Pure Java + Jakarta validation + jspecify nullness annotations.

## Package structure

```
io.stockapp.shared/
├── money/
│   ├── Money.java                          # immutable; BigDecimal + Currency
│   ├── Percentage.java                     # 0.00–100.00 BigDecimal wrapper
│   └── Currency.java                       # enum (TRY-only MVP)
├── identity/
│   ├── TenantId.java                       # UUID wrapper
│   ├── UserId.java
│   ├── StoreId.java
│   ├── PartyId.java
│   └── ... (other identifier types)
├── correlation/
│   ├── CorrelationId.java                  # ADR-020
│   └── CorrelationIdHolder.java            # ThreadLocal helper
├── idempotency/
│   ├── IdempotencyKey.java
│   └── IdempotencyKeyValidator.java        # format validation
├── contact/
│   ├── EmailAddress.java                   # value object with validation
│   └── PhoneNumber.java                    # value object (Turkish format aware)
├── error/
│   ├── ErrorCode.java                      # enum: VALIDATION_FAILED, NOT_FOUND, etc.
│   ├── DomainException.java                # base; all module exceptions extend
│   ├── ConflictException.java
│   ├── NotFoundException.java
│   └── UnauthorizedException.java
├── clock/
│   ├── SystemClock.java                    # interface
│   └── DefaultSystemClock.java             # default impl; testable
└── pagination/                             # isolated sub-package per Phase 4 decision
    ├── PageRequest.java
    ├── PageResponse.java
    ├── SortDirection.java                  # enum
    └── SortField.java                      # value object
```

## What goes in shared kernel — ALLOWED

Per ArchUnit Kategori D rule:

| Category | Examples |
|---|---|
| Money primitives | Money, Percentage, Currency |
| Identifiers (cross-cutting) | TenantId, CorrelationId, IdempotencyKey, UserId, StoreId, PartyId |
| Contact value objects | EmailAddress, PhoneNumber |
| Error model | ErrorCode (enum), DomainException + subtypes |
| Pure abstractions | SystemClock (interface) |
| Pagination (isolated) | `shared.pagination.*` |
| Structural primitives | Enums, interfaces |

## What does NOT go in shared kernel — FORBIDDEN

ArchUnit-enforced. Adding any of these requires explicit ADR justification + ArchUnit rule update.

| Category | Why forbidden |
|---|---|
| Repositories | Module-owned; would create cross-module write coupling |
| @Service classes | Domain/application logic — must live in owning module |
| @Entity classes | Persistence concern; module-owned |
| Module DTOs | Each module has its own api/dto |
| Concrete service implementations | Belong in module infrastructure |

## ArchUnit rules

- `shared_kernel_has_no_repositories`
- `shared_kernel_has_no_services`
- `shared_kernel_has_no_entities`
- `shared_kernel_classes_are_value_objects_or_abstractions` (allowlist enforced)
- `pagination_is_isolated_sub_package`

## Why pagination is isolated

User requirement (§Phase 4.2): pagination is REST/query/admin UI concern, not a true domain primitive. Putting `PageRequest` next to `Money` would semantically muddle. Putting it in a separate sub-package (`shared.pagination.*`) keeps it visible to all modules but signals "this is a transport concern".

## Why no `Sku`, `Barcode`, `Quantity` in shared

These are module-owned per Phase 4 decision (§Phase 4.2 user correction):

- **Sku**: catalog-owned. `io.stockapp.catalog.domain.variant.VariantSku`
- **Barcode**: catalog-owned. Has inventory semantics, supplier-barcode v1.1+, GS1 future rules. Shared kernel would couple too many concerns.
- **Quantity**: inventory-owned. `io.stockapp.inventory.domain.balance.Quantity`. Has decimal-scale concerns inventory-specific.

Cross-module references use module's public API types (e.g., `ProductVariant` returned by `VariantQueryService.findById()`).

## Key invariants

1. **Allowlist enforced by ArchUnit** (Kategori D): adding new shared class requires ArchUnit rule update + ADR justification.

2. **No module dependency**: shared has no `..identity..`, `..catalog..`, etc. imports. Pure Java/Jakarta.

3. **Value objects immutable**: Money, Percentage, PhoneNumber, EmailAddress — all immutable. Records preferred (Java 21).

4. **Identifier types are nominal**: `TenantId.of(uuid)` vs `UserId.of(uuid)` — different types even though both wrap UUID. Prevents accidental cross-type assignment.

5. **Clock injectable**: never `LocalDateTime.now()` or `Instant.now()` in domain code. Always `clock.now()` for testability.

6. **DomainException as base**: every module's exception extends `DomainException`. Centralized error handling in shared exception handlers (Phase 6.D).

7. **Pagination decoupled from JPA Pageable**: `PageRequest` and `PageResponse` are framework-agnostic; modules' infrastructure layer maps to Spring Data `Pageable` if needed.

## No public API surface

Shared has no services, controllers, or APIs. Just value objects, exceptions, enums. Every module imports what it needs.

## Drift prevention

Quarterly review of shared kernel size:
- Total class count: target < 30
- New additions in last quarter: target < 3
- Any new class requires PR review + ADR if from a junior contributor

If shared kernel exceeds 50 classes or grows by > 5/quarter, treat as design smell — review for hidden module bleed.
