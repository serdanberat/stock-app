# Phase 6.C — Modular Monolith Discipline

> **Status:** Locked
> **Phase:** 6.C
> **Related ADRs:** ADR-012

## Decisions

| Concern | Decision |
|---|---|
| Module count | 10 modules + 3 cross-cutting |
| Maven structure | Single module + api/internal package split (MVP) |
| Multi-module migration | v1.1+ when boundaries are stable |
| Spring Modulith | Used for verification + documentation |
| Custom outbox | Yes — our schema, not Modulith's |
| `@ApplicationModuleListener` | Only for eventual-consistency internal flows |
| Cross-module sync | api `CommandService` / `QueryService` interfaces |
| Cross-module async | `OutboxPublisher` + dispatchers |
| Sales orchestration | Service family split (Lifecycle / Pricing / Payment / Completion / Void / Query) |
| Lifecycle → other modules | Forbidden (ArchUnit) |
| Aggregate ownership | One owner module per aggregate (ADR-012) |

## Module list

| Module | Owner of |
|---|---|
| **identity** | Tenant, User, Role, UserRoleAssignment, Store |
| **catalog** | Category, Brand, Season, AttributeType, AttributeValue, Product, ProductVariant, ProductVariantBarcode, PriceList, VariantPrice |
| **inventory** | StockMovement, StockBalance, ReorderLevel, Transfer, TransferItem, CountSession, CountItem, StockAdjustment |
| **party** | Party (Customer/Supplier/Employee unified), PartyContact, PartyDocument |
| **fx** | Currency, FxRateSource, FxRate, FxSnapshot |
| **financial** | AccountProfile, AccountMovement, AccountBalance, Payment, PaymentAllocation, AccountAging |
| **cashregister** | CashRegister, RegisterSession, CashMovement, ZReport |
| **sales** | Sale, SaleItem, SalePayment, PaymentAttempt, SaleDocument, Return, ReturnItem, ReturnDocument, ExchangeGroup |
| **purchasing** | PurchaseInvoice, PurchaseInvoiceItem, PurchaseInvoiceDocument, PurchaseReturn, PurchaseReturnItem |
| **reporting** | Read-only event consumers, materialized view orchestration |

### Cross-cutting (shared)

| Module | Purpose |
|---|---|
| **shared.audit** | AuditEventLog, SecurityAuditLog |
| **shared.outbox** | OutboxEvent, OutboxPublisher, OutboxDispatcher, ProcessInstance |
| **shared.common** | BaseEntity, Money, Currency, time/locale utilities |
| **shared.security** | TenantProvider, JWT plumbing, SecurityContext helpers |

## Package structure (canonical)

```
com.stockapp.modules.sales/
├── api/                      ← public to other modules
│   ├── SaleCommandService
│   ├── SaleQueryService
│   ├── command/
│   │   ├── CompleteSaleCommand
│   │   └── AddSaleItemCommand
│   ├── query/
│   │   ├── SaleSummaryView
│   │   └── SaleDetailView
│   ├── event/
│   │   ├── SaleCompletedV1
│   │   └── SaleVoidedV1
│   └── exception/
│       ├── SaleNotFoundException
│       └── InvalidSaleStateException
└── internal/                 ← module-only
    ├── domain/               ← JPA entities, value objects
    │   ├── Sale
    │   ├── SaleItem
    │   └── SaleStatus (enum)
    ├── repository/           ← Spring Data + JOOQ queries
    │   ├── SaleRepository
    │   └── SaleQueryDsl
    ├── service/
    │   ├── sale/
    │   │   ├── SaleLifecycleService
    │   │   ├── SalePricingService
    │   │   ├── SalePaymentService
    │   │   ├── SaleCompletionOrchestrator
    │   │   ├── SaleVoidService
    │   │   └── SaleQueryService (impl)
    │   ├── return/
    │   │   ├── ReturnLifecycleService
    │   │   ├── ReturnApprovalService
    │   │   └── ReturnCompletionOrchestrator
    │   └── exchange/
    │       ├── ExchangeGroupService
    │       └── ExchangeSagaCoordinator
    ├── projection/           ← async event handlers
    │   └── SaleProjector
    ├── web/                  ← REST controllers
    │   ├── SaleController
    │   ├── SaleRequest
    │   └── SaleResponse
    └── config/
        └── SalesModuleConfig
```

## Service family pattern

Sales orchestration is split to prevent god services:

| Service | Responsibility | Cross-module calls? |
|---|---|---|
| `SaleLifecycleService` | DRAFT state mutations (create, addItem, removeItem, applyCartDiscount) | **No** |
| `SalePricingService` | Line price resolution, discount, VAT calculation | Yes (Catalog QueryService) |
| `SalePaymentService` | Tender collection, payment_attempts logging, terminal_pending state | Yes (CashRegister) |
| `SaleCompletionOrchestrator` | Atomic complete TX (Inventory, Financial, CashRegister commands) | **Yes** (orchestration) |
| `SaleVoidService` | Void, abandonment, timeout handling | Yes (compensating) |
| `SaleQueryService` (impl) | Read-only views | No |

Each ≤ 400-800 LOC. Orchestrator has ≤ 5 public methods (ArchUnit enforced).

## ArchUnit rules (Phase 6.C)

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
static final ArchRule api_packages_have_no_jpa_entities =
    noClasses().that().resideInAPackage("..modules.(*).api..")
        .should().beAnnotatedWith(jakarta.persistence.Entity.class);

@ArchTest
static final ArchRule controllers_only_in_internal_web =
    classes().that().areAnnotatedWith(RestController.class)
        .should().resideInAPackage("..modules.(*).internal.web..");

@ArchTest
static final ArchRule jpa_repositories_only_in_internal =
    classes().that().areAssignableTo(JpaRepository.class)
        .should().resideInAPackage("..modules.(*).internal.repository..");

@ArchTest
static final ArchRule lifecycle_services_dont_call_other_modules =
    noClasses().that().haveSimpleNameEndingWith("LifecycleService")
        .should().dependOnClassesThat().resideInAPackage("..modules.(*).api..")
        .allowEmptyShould(true);

@ArchTest
static final ArchRule completion_orchestrator_public_api_thin =
    classes().that().haveSimpleNameEndingWith("CompletionOrchestrator")
        .should(havePublicMethodsAtMost(5));

@ArchTest
static final ArchRule append_only_repos_only_used_by_dedicated_services =
    classes().that().haveSimpleName("StockMovementRepository")
        .should().onlyBeAccessed().byClassesThat()
        .haveSimpleNameStartingWith("StockMovementService");

@Test
void verifies_module_structure() {
    ApplicationModules.of(StockAppApplication.class).verify();
}
```

## OutboxPublisher (canonical)

```java
@Service
class OutboxPublisherImpl implements OutboxPublisher {

    private final OutboxEventRepository repo;
    private final ObjectMapper json;
    private final OutboxGlobalSequenceAllocator sequenceAllocator;

    @Transactional(propagation = Propagation.MANDATORY)
    public void publish(UUID tenantId, DomainEvent event, String partitionKey) {
        var entity = new OutboxEvent();
        entity.setEventId(UUID.randomUUID());
        entity.setTenantId(tenantId);
        entity.setAggregateType(event.aggregateType());
        entity.setAggregateId(event.aggregateId());
        entity.setAggregateVersion(event.aggregateVersion());
        entity.setEventType(event.type());
        entity.setEventVersion(event.version());
        entity.setPartitionKey(partitionKey);
        entity.setPayload(json.valueToTree(event));
        entity.setMetadata(EventMetadata.current().asJson());
        entity.setStatus(OutboxStatus.PENDING);
        entity.setGlobalSequence(sequenceAllocator.next(tenantId));
        entity.setRecordedAt(Instant.now());
        repo.save(entity);
    }
}
```

`@Transactional(propagation = MANDATORY)` ensures the publisher runs inside an existing business transaction. Bare calls fail.

## Cross-references

- Aggregates: `docs/architecture/aggregates.md`
- Bounded contexts: `docs/architecture/bounded-contexts.md`
- Transaction boundaries: `docs/architecture/transaction-boundaries.md`
- Worker patterns: `docs/architecture/worker-patterns.md`
- Event consumer categories: `docs/architecture/event-consumer-categories.md`
