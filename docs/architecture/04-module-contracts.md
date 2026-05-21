# Phase 4 — Module Contracts

> **Status:** Locked (Phase 4)
> **Scope:** LEAN per Phase 3 closure decision
> **Last updated:** 2026-05-21

This is the **module boundary lock** for the modular monolith. Phase 3 specified what each screen does; Phase 4 specifies how modules relate, what they expose, and what ArchUnit will enforce.

This document is the central reference for code review during Phase 7 implementation. Every ArchUnit rule maps back to a row in the dependency matrix below.

---

## Module list

10 modules. 9 are Spring Modulith modules; `shared` is a value-object kernel (not a Modulith module).

| # | Module | Bounded context | Phase 2A ref |
|---|---|---|---|
| 1 | `identity` | Identity & Access + Tenant Management (sub-package) | §2.A.1 + §2.A.2 |
| 2 | `catalog` | Catalog | §2.A.3 |
| 3 | `pricing` | Pricing | §2.A.4 |
| 4 | `inventory` | Inventory | §2.A.5 |
| 5 | `sales` | Sales (POS) + Returns & Exchanges (sub-package) | §2.A.6 + §2.A.8 |
| 6 | `purchasing` | Purchasing | §2.A.7 |
| 7 | `finance` | Finance | §2.A.9 |
| 8 | `cashregister` | Cash Register | §2.A.10 |
| 9 | `reporting` | Reporting & Audit (sub-package) | §2.A.11 |
| 10 | `shared` | (kernel; not a BC) | — |

### Sub-package decisions (Phase 4)

| Sub-package | Parent module | Rationale |
|---|---|---|
| `identity.tenant` | `identity` | Tenant aggregate small; separate module overhead unjustified |
| `sales.returns` | `sales` | Return shares correlation_id with Sale, creates new Sale (exchange). Separate module would create cyclic dep |
| `reporting.audit` | `reporting` | Both are read-only operational visibility surfaces |

### Package prefix

Current prefix: `io.stockapp` (placeholder until brand decision in Phase 7).

ArchUnit rule patterns use double-dot wildcards (`..identity..`) instead of fully-qualified paths. Future package rename requires only:
1. Maven/Gradle parent groupId change
2. Source directory move (IDE refactor)
3. NO ArchUnit rule changes

Module names (`identity`, `catalog`, `pricing`, ...) are stable identifiers. Brand prefix is replaceable.

---

## Module dependency matrix (CENTRAL ARTIFACT)

```
LEGEND:
  W = Write (sync service call, same transaction)
  Q = Query (read-only)
  ✗ = Forbidden (ArchUnit-enforced)
  — = Self
```

| ⬇ depends on → | identity | catalog | pricing | inventory | sales | purchasing | finance | cashregister | reporting |
|---|---|---|---|---|---|---|---|---|---|
| **identity** | — | ✗ | ✗ | ✗ | ✗ | ✗ | ✗ | ✗ | ✗ |
| **catalog** | Q | — | ✗ | ✗ | ✗ | ✗ | ✗ | ✗ | ✗ |
| **pricing** | Q | Q | — | ✗ | ✗ | ✗ | ✗ | ✗ | ✗ |
| **inventory** | Q | Q | ✗ | — | ✗ | ✗ | ✗ | ✗ | ✗ |
| **sales** | Q | Q | Q | **W** | — | ✗ | **Q+W** | **W** | ✗ |
| **purchasing** | Q | Q | ✗ | **W** | ✗ | — | **W** | ✗ | ✗ |
| **finance** | Q | Q | ✗ | ✗ | ✗ | ✗ | — | **W** | ✗ |
| **cashregister** | Q | ✗ | ✗ | ✗ | ✗ | ✗ | ✗ | — | ✗ |
| **reporting** | Q | Q | Q | Q | Q | Q | Q | Q | — |

### Reading the matrix

Cell `(row, column)` = "Does **row** module depend on **column** module?"

Examples:
- `sales → inventory: W` — Sales writes to inventory (SALE_OUT movements at sale completion). Same TX.
- `sales → finance: Q+W` — Sales queries finance (credit check) AND writes (debt entry for CUSTOMER_ACCOUNT tender). Both in same TX as sale completion.
- `catalog → pricing: ✗` — Catalog never depends on pricing (structure must not couple to commercial policy).
- `reporting → all: Q` — Reporting reads everything via query services. Writes nothing.

### Why `Q+W` notation is preserved

Per Phase 4.2 user decision: `sales → finance` carries TWO contracts:
1. **Q**: credit summary lookup at sale completion
2. **W**: debt creation for CUSTOMER_ACCOUNT tender

Collapsing to `W` would lose intent visibility during code review. ArchUnit rules also distinguish (`finance.query` allowed; `finance.application.command` allowed; `finance.domain` forbidden).

### Why event consumption is not on this matrix

Event consumption is loose coupling (outbox-driven, async, eventual). Per-module specs (modules/) list `Outbox events consumed` separately. This matrix shows **synchronous coupling** that requires same-TX guarantees.

Notable event consumption (NOT in matrix because async):
- `finance` consumes `SaleAdministrativelyReversedEvent` from `sales`

---

## Cross-module orchestration discipline (CRITICAL INVARIANT)

### Rule

**Cross-module writes must be orchestrated at the ORIGINATING module's application service.** Nested orchestration through intermediate modules is forbidden.

### Pattern allowed (explicit orchestration)

```
sales.SaleCompletionService.complete()
├─ inventory.InventoryCommandService.applyMovements(...)
├─ finance.AccountMovementCommandService.recordCustomerDebt(...)
└─ cashregister.CashRegisterCommandService.recordSaleCashFlow(...)
```

All three calls visible from one place. Same TX. Easy to audit.

### Pattern forbidden (hidden orchestration)

```
sales.SaleCompletionService.complete()
└─ finance.AccountMovementCommandService.recordCustomerDebt(...)
     └─ cashregister.CashRegisterCommandService.recordCashIn(...) ✗
```

Sales indirectly mutates cashregister. Not visible at sales call site.

### Why this is the most fragile invariant

Easy to break under deadline pressure:
- *"Let me just call cashregister from finance, sales doesn't need to know"*
- *"Adding one cross-call inside finance is simpler than refactoring sales"*

The ArchUnit rule catches it at PR time, but reviewers must also flag intent ("why is this call here?") to keep architecture honest.

### How to identify which module is "originator"

The originator is the module whose domain operation triggered the cross-module effect:

| Operation | Originator | Cross-module writes |
|---|---|---|
| POS sale completion | `sales` | inventory + finance + cashregister |
| Customer payment collection | `finance` | cashregister (if CASH tender) |
| Purchase invoice commit | `purchasing` | inventory + finance |
| Stock transfer dispatch/receive | `inventory` | (within own module only) |
| Cash session close | `cashregister` | (within own module only) |

Never the receiving module (which is downstream and write-receiving).

### Two finance command services — important distinction

Finance has TWO command service classes with different cross-module rules:

| Service | Cross-module W allowed? | Used from |
|---|---|---|
| `AccountMovementCommandService` | NO — never calls another module's command | sales, purchasing (called externally) |
| `PaymentOrchestrationService` | YES — calls cashregister (matrix-allowed) | finance's own controllers |

This split prevents "sales → finance.AccountMovementCommandService → cashregister" hidden chain while allowing legitimate "finance.PaymentOrchestrationService → cashregister" payment workflow.

---

## ArchUnit rule categories

23 rules total. Five categories.

### Kategori A — Module dependency matrix enforcement (~12 rules)

Every `✗` in matrix becomes one ArchUnit rule. Every `Q` cell maps to a `query`-package-only constraint. Every `W` cell maps to an `application.command`-package-only constraint.

Full rule code in modules' individual specs and in `tests/architecture/ModuleDependencyMatrixTest.java` (Phase 7).

Key rules per module: see `modules/01-identity.md` ... `modules/10-shared.md`.

### Kategori B — Hexagonal layering (4 rules)

Per-module layering:

```
api → application → domain ← infrastructure
```

| Rule | Constraint |
|---|---|
| `domain_does_not_depend_on_application` | Domain is innermost |
| `domain_does_not_depend_on_infrastructure` | Domain is pure |
| `application_does_not_depend_on_infrastructure` | Application defines ports; infrastructure implements |
| `api_only_depends_on_application_command_or_query` | Web layer talks to application services only |

### Kategori C — Transitive orchestration prevention (2 rules)

Implements the CRITICAL INVARIANT above. The key rule:

```java
@ArchTest
static final ArchRule cross_module_writes_only_from_orchestrator =
    classes().that().resideInAPackage("..*.application.command..")
        .and().haveSimpleNameEndingWith("CommandService")
        .should().onlyHaveDependentClassesThat().resideInAnyPackage(
            "..*.application..",  // own module's application layer
            "..*.api..",          // own module's API layer
            "..*.eventconsumer.." // outbox event consumers (cross-module via events)
        )
        .because("Cross-module orchestration is EXPLICIT at the originating " +
                "module's application service. No nested command-to-command chains.");
```

This rule + the matrix together prevent both direct illegal deps AND indirect chain-through-intermediate.

### Kategori D — Shared kernel discipline (4 rules)

Allowlist enforcement; junk-drawer prevention. Full rule list in `modules/10-shared.md`.

| Rule | Constraint |
|---|---|
| `shared_kernel_has_no_repositories` | No @Repository in shared |
| `shared_kernel_has_no_services` | No @Service in shared |
| `shared_kernel_has_no_entities` | No @Entity in shared |
| `shared_kernel_classes_are_value_objects_or_abstractions` | Class name allowlist |
| `pagination_is_isolated_sub_package` | Pagination sub-package only |

### Kategori E — Canonical structure (1 rule)

Validates every @Service is in command/query/orchestrator/domain.service package. If a service doesn't fit, the modeling is wrong.

---

## Mandatory package structure (every module)

```
io.stockapp.<module>/
├── api/                       # REST controllers, request/response DTOs
├── application/
│   ├── command/               # @Transactional write services
│   │   └── <Aggregate>CommandService.java
│   ├── query/                 # @Transactional(readOnly=true) read services
│   │   └── <Aggregate>QueryService.java
│   └── orchestrator/          # cross-module write orchestrators (optional)
├── domain/
│   ├── <aggregate>/           # aggregate root + entities + value objects
│   │   ├── <Aggregate>.java
│   │   └── <Aggregate>Repository.java   # interface (port)
│   └── event/                 # outbox event types
├── eventconsumer/             # listeners for OTHER modules' outbox events (optional)
│   └── <Source>EventListener.java
└── infrastructure/
    ├── persistence/           # JPA + JOOQ implementations
    └── client/                # external HTTP/SMTP adapters (optional)
```

ArchUnit `every_module_has_canonical_package_structure` validates compliance.

---

## Per-module specs

Each module has a ~1-page detailed spec in `modules/`:

| Module | Spec |
|---|---|
| identity | [modules/01-identity.md](modules/01-identity.md) |
| catalog | [modules/02-catalog.md](modules/02-catalog.md) |
| pricing | [modules/03-pricing.md](modules/03-pricing.md) |
| inventory | [modules/04-inventory.md](modules/04-inventory.md) |
| sales (incl. returns) | [modules/05-sales.md](modules/05-sales.md) |
| purchasing | [modules/06-purchasing.md](modules/06-purchasing.md) |
| finance | [modules/07-finance.md](modules/07-finance.md) |
| cashregister | [modules/08-cashregister.md](modules/08-cashregister.md) |
| reporting (incl. audit) | [modules/09-reporting.md](modules/09-reporting.md) |
| shared | [modules/10-shared.md](modules/10-shared.md) |

Each spec includes:
- Position in dependency graph
- Aggregate roots
- Package structure
- Transaction ownership table
- Outbox events emitted/consumed
- ArchUnit rules
- Cache invalidation hooks
- Key invariants (3-5 critical ones referencing Phase 2B/2C)
- Public API surface (for cross-module consumers)

---

## Cross-cutting infrastructure (overview)

Detailed in Phase 6 docs; summary here:

### Transaction management

`TenantAwareTransactionManager` (Phase 6.B) sets `SET LOCAL app.tenant_id = ...` before every TX body. RLS policies on every tenant-scoped table use `current_setting('app.tenant_id')::uuid`. ArchUnit prevents bypass.

### Outbox dispatcher

In-process outbox dispatcher polls `outbox_events` table every 500ms with `FOR UPDATE SKIP LOCKED`. Per ADR-005. Each module emits events; consumers listen via `@Component` event listeners in `eventconsumer/` package.

### Caching

Caffeine in-memory cache (Phase 6.C). Eviction is event-driven per module's "Cache invalidation hooks" section.

### Authentication

JWT HS256 + BCrypt 12 (ADR-013). Manager PIN uses shared CredentialHasher.

### Idempotency

X-Idempotency-Key on every consequential write. 7-day retention in `idempotency_keys` table. Phase 6.B detail.

### Scheduled jobs

Spring @Scheduled + ShedLock (Phase 6.G). Used by reporting (mview refresh), outbox cleanup, document worker triggers.

### Document generation

Async document worker (Phase 6.F): receipts, Z reports, CSV exports. Gotenberg 8 for PDFs.

---

## What Phase 4 is NOT

- **Not aggregate root implementation code** — Phase 7
- **Not full service method signatures** — Phase 7
- **Not database query implementations** — Phase 7
- **Not detailed DTO field definitions** — Phase 5
- **Not OpenAPI spec** — Phase 5
- **Not sprint planning** — Phase 7

Phase 4 is the boundary lock. Implementation comes next.

---

## What's next

| Phase | Deliverable |
|---|---|
| **5** | Endpoint catalogue + OpenAPI skeleton |
| **7** | Implementation sprints (Claude Code) |

After Phase 5, Phase 7 implementation begins. Sprint order follows the dependency hierarchy bottom-up:

1. `shared` kernel (no deps)
2. `identity` (root)
3. `catalog`
4. `pricing` + `inventory` (parallel; both depend only on identity + catalog)
5. `purchasing`
6. `sales` (largest; orchestrates)
7. `finance` + `cashregister`
8. `reporting` (read-only; last)

Spring Modulith integration tests verify module boundaries hold throughout.
