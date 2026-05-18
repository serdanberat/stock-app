# ADR-012: Aggregate Ownership Rules

**Status:** Accepted
**Date:** 2026-05-16
**Phase:** 6.C

## Context

A modular monolith degrades into a god-application when modules begin mutating each other's aggregates directly. Schemas in this codebase already imply ownership (e.g. `stock_movements` belongs to inventory), but ownership rules were implicit, not enforced.

ERP projects without explicit boundaries reach a state where:

- `SaleService` opens `StockBalanceRepository` and mutates rows directly
- Reporting reaches into transactional tables and applies updates
- Refactoring becomes impossible because every change ripples

## Decision

Three sharp rules govern aggregate ownership:

### Rule 1 — One owner per aggregate

Each aggregate has exactly one owner module. Other modules can read views (through QueryService) and issue commands (through CommandService), but cannot mutate state directly.

| Aggregate (selected) | Owner module |
|---|---|
| `Sale`, `Return`, `ExchangeGroup` | sales |
| `StockMovement`, `StockBalance`, `Transfer`, `CountSession` | inventory |
| `Product`, `ProductVariant`, `VariantPrice` | catalog |
| `Party` (Customer + Supplier + Employee unified) | party |
| `AccountProfile`, `AccountMovement`, `Payment` | financial |
| `RegisterSession`, `CashMovement`, `ZReport` | cashregister |
| `PurchaseInvoice`, `PurchaseReturn` | purchasing |
| `FxRate`, `FxSnapshot`, `Currency` | fx |
| `User`, `Role`, `Tenant`, `Store` | identity |
| `OutboxEvent`, `ProcessInstance` | shared.outbox |
| `AuditEventLog`, `SecurityAuditLog` | shared.audit |

Full table in `docs/architecture/aggregates.md`.

### Rule 2 — Cross-module communication is API-based, never repository-based

**Forbidden:**

```java
// In sales module:
class SaleCompletionOrchestrator {
    @Autowired StockBalanceRepository stockBalanceRepo;  // ❌ another module's repo

    public void complete(...) {
        var balance = stockBalanceRepo.findByVariantAndStore(...);
        balance.setQuantity(balance.getQuantity() - 1);  // ❌ mutating another module's entity
    }
}
```

**Required:**

```java
class SaleCompletionOrchestrator {
    @Autowired InventoryCommandService inventoryCommand;  // ✅ public api of inventory

    public void complete(...) {
        inventoryCommand.recordSaleMovement(
            new RecordSaleMovementCommand(variantId, storeId, quantity, saleId)
        );
    }
}
```

Each module exposes a public API in `modules/<name>/api/`:

- `*CommandService` interfaces — intent-based mutations
- `*QueryService` interfaces — read-only views
- DTOs and event records

Implementations and entities stay in `modules/<name>/internal/`.

### Rule 3 — Append-only ledgers writeable only through dedicated services

The append-only ledgers (`stock_movements`, `account_movements`, `cash_movements`, `fx_rates`, `audit_event_log`, `security_audit_log`) have invariants that go beyond schema:

- `aggregate_sequence` must be allocated atomically
- direction × movement_type combinations must be consistent
- `reverses_movement_id` chain must not exceed depth 1
- projections (`stock_balances`, `account_balances`) must update in the same transaction

These invariants are enforced by `StockMovementService`, `AccountMovementService`, etc. Direct `Repository.save()` calls bypass them.

Even within the same module, direct repository write to an append-only table is forbidden.

## Enforcement

ArchUnit rules (in `ArchitectureTests`):

```java
@ArchTest
static final ArchRule modules_internal_packages_not_accessed_by_other_modules =
    classes().that().resideInAPackage("..modules.(*).internal..")
        .should().onlyBeAccessed().byClassesThat()
        .resideInAnyPackage("..modules.(*).internal..",
                            "..modules.(*).api..",
                            "..shared..",
                            "..StockAppApplication");

@ArchTest
static final ArchRule jpa_repositories_only_in_internal =
    classes().that().areAssignableTo(JpaRepository.class)
        .should().resideInAPackage("..modules.(*).internal.repository..");

@ArchTest
static final ArchRule append_only_repos_only_used_by_dedicated_services =
    classes().that().haveSimpleName("StockMovementRepository")
        .should().onlyBeAccessed().byClassesThat()
        .haveSimpleNameStartingWith("StockMovementService");
// (same pattern for AccountMovement, CashMovement, FxRate, AuditEventLog)
```

Spring Modulith `ApplicationModules.of(StockAppApplication.class).verify()` runs in CI as a build gate.

## Consequences

**Positive:**
- Module boundaries stay clean for 5+ years
- Refactoring to multi-module or even microservices is mechanical
- Tenant-level data corruption risk minimized (no module can sneak past another module's validators)
- ArchUnit rules document the architecture

**Negative:**
- More boilerplate (interfaces, command records)
- "Quick fix" path is closed — even small changes require following the contract
- New developers need onboarding to the pattern

**Trade-off accepted:** Boilerplate is a one-time cost; god-service prevention is a continuous benefit.
