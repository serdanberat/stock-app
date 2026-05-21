# Module: cashregister

> **Status:** Locked (Phase 4)
> **Bounded context:** Cash Register

## Position in dependency graph

```
identity (Q)
   ↑
cashregister (receives W from sales+finance; originates nothing cross-module)
```

Cashregister is **leaf module**: nobody depends on it (except reporting Q). Receives writes from sales (sale completion cash flow) and finance (customer payment cash). Reads identity only.

## Aggregate roots

| Aggregate | Phase 2B ref | Lifecycle |
|---|---|---|
| `CashRegisterSession` | §2.B.32 | OPEN → CLOSED (§3.E.1, 3.E.2); orphan recovery via force-close |
| `CashMovement` | §2.B.33 | **Append-only**; immutable post-insert |
| `ZReport` | §2.B.34 | Snapshot at session close; immutable; PDF byte-deterministic per §3.F.2 |
| `CashRegisterVarianceLog` | §2.B.35 | Append-only audit |

## Package structure

```
io.stockapp.cashregister/
├── api/
│   ├── CashRegisterController.java         # /cash-register/*
│   └── dto/
├── application/
│   ├── command/
│   │   ├── CashRegisterCommandService.java # PUBLIC: recordSaleCashFlow(), recordCustomerPaymentCash()
│   │   ├── SessionLifecycleService.java    # open, close, force-close
│   │   └── ZReportGenerationService.java   # called by document worker after close
│   └── query/
│       ├── SessionQueryService.java
│       ├── CashMovementQueryService.java
│       ├── ZReportQueryService.java         # reads snapshot_payload + renders PDF
│       └── SessionSummaryService.java       # pre-close expected_cash compute
├── domain/
│   ├── session/
│   │   ├── CashRegisterSession.java
│   │   ├── SessionStatus.java
│   │   ├── OpeningFloat.java                # value object
│   │   ├── RemainingFloat.java              # value object (per §3.F.1)
│   │   └── CashRegisterSessionRepository.java
│   ├── movement/
│   │   ├── CashMovement.java                # immutable
│   │   ├── CashMovementType.java            # enum: OPENING_FLOAT, SALE_CASH_IN, CHANGE_OUT, CUSTOMER_PAYMENT_CASH, REFUND_CASH, CLOSING_DEPOSIT, CORRECTION
│   │   └── CashMovementRepository.java
│   ├── zreport/
│   │   ├── ZReport.java
│   │   ├── ZReportPayload.java              # JSONB immutable snapshot
│   │   ├── ZReportPdfRenderer.java          # deterministic; see §3.F.2
│   │   └── ZReportRepository.java
│   ├── variance/
│   │   ├── VarianceLog.java
│   │   ├── VarianceReason.java              # closed enum
│   │   └── VarianceLogRepository.java
│   └── event/
│       ├── SessionOpenedEvent.java
│       ├── SessionClosedEvent.java
│       ├── SessionForceClosedOrphanEvent.java
│       ├── SessionClosedWithVarianceEvent.java
│       ├── ZReportGeneratedEvent.java
│       └── CashMovementCreatedEvent.java
└── infrastructure/
    └── persistence/
```

## Transaction ownership

| Operation | Boundary | Propagation | Notes |
|---|---|---|---|
| `CashRegisterCommandService.recordSaleCashFlow()` | REQUIRED | Same TX as sales completion | FOR UPDATE on session; appends 1-2 movements (CASH_IN, optional CHANGE_OUT) |
| `CashRegisterCommandService.recordCustomerPaymentCash()` | REQUIRED | Same TX as finance.PaymentOrchestrationService | FOR UPDATE on session; appends CUSTOMER_PAYMENT_CASH movement |
| `SessionLifecycleService.open()` | REQUIRES_NEW | New TX | Partial UNIQUE constraint enforces single OPEN per (store, register) |
| `SessionLifecycleService.close()` | REQUIRES_NEW | Atomic: status=CLOSED, variance log, CLOSING_DEPOSIT movement, ZReport row PENDING |
| `SessionLifecycleService.forceCloseOrphan()` | REQUIRES_NEW | Manager PIN + reconciliation_note min 20 chars |
| `ZReportGenerationService.generate()` | NOT_SUPPORTED | Async worker; reads snapshot, calls renderer, stores PDF |

## Outbox events emitted

| Event | When | Consumers |
|---|---|---|
| `SessionOpenedEvent` | OPEN | reporting |
| `SessionClosedEvent` | CLOSED | reporting; document worker (triggers Z report generation) |
| `SessionClosedWithVarianceEvent` | CLOSED with variance > tolerance | reporting (fraud surface) |
| `SessionForceClosedOrphanEvent` | Force close | reporting (audit) |
| `ZReportGeneratedEvent` | After PDF generation success | reporting |
| `CashMovementCreatedEvent` | Any cash movement | reporting (cash flow analysis) |

## Outbox events consumed

NONE. Cashregister is leaf.

(NOT consuming `SaleCompletedEvent` — sale → cashregister is direct W via REQUIRED propagation, not event-driven.)

## ArchUnit rules

- `cashregister_does_not_depend_on_others`
- `cashregister_command_service_callers_restricted` (sales + finance only)

## Cache invalidation hooks

| Cache key | Invalidated by |
|---|---|
| `current-session:{tenant_id}:{store_id}:{register_id}` | SessionOpenedEvent, SessionClosedEvent, SessionForceClosedOrphanEvent |
| `session-summary:{session_id}` | CashMovementCreatedEvent (during OPEN), SessionClosedEvent |

## Key invariants

1. **One OPEN session per (store, register)** (§3.E.1 + migration 022): partial UNIQUE index `(tenant_id, store_id, register_id) WHERE status='OPEN'`. NOT per user — shift handover supported.

2. **Cash movements append-only** (ADR-002): no UPDATE/DELETE on cash_movements.

3. **Z report PDF byte-deterministic** (§3.F.2): renderer consumes ONLY `snapshot_payload` JSONB. No `now()` timestamps, no render IDs, no library version strings. CI test for SHA256 equality on reprint.

4. **Z report snapshot immutable** (§3.E.2): `snapshot_payload` write-once; DB trigger prevents UPDATE. Reprint renders SAME payload.

5. **Variance reason from closed set** (§3.E.2): SHORT_CASHIER_ERROR, SHORT_UNKNOWN, OVER_CASHIER_ERROR, OVER_UNKNOWN, MISCOUNT, SUSPECTED_THEFT. SUSPECTED_THEFT requires variance_note min 10 chars.

6. **Large variance threshold requires manager PIN** (§3.E.2): tenant `cash_variance_large_threshold` snapshotted at session open per §3.F.4.

7. **Variance tolerance + large threshold snapshotted at session open** (§3.F.4): mid-session tenant policy change does NOT affect open session.

8. **Force-close orphan requires reconciliation_note min 20 chars + manager PIN** (§3.E.1): DB constraint enforces note length.

9. **Cashier mental model: "kasada bırakılacak nakit"** (§3.F.1): API body field `remaining_float_amount`. System computes `cash_removed = expected_cash - remaining_float`. CLOSING_DEPOSIT movement for removed delta.

10. **Cross-module write entry points fixed** (matrix): only sales.SaleCompletionService and finance.PaymentOrchestrationService call into cashregister. ArchUnit Kategori A enforces.

## Public API surface

```java
public interface CashRegisterCommandService {
    /**
     * Called by sales.SaleCompletionService.complete().
     * REQUIRED propagation — same TX as sale completion.
     * Appends 1-2 cash movements: SALE_CASH_IN (always), CHANGE_OUT (if change due).
     */
    void recordSaleCashFlow(SaleCashFlowCommand cmd);
    
    /**
     * Called by finance.PaymentOrchestrationService.collectFromCustomer().
     * REQUIRED propagation — same TX as payment.
     * Appends CUSTOMER_PAYMENT_CASH movement.
     */
    void recordCustomerPaymentCash(CustomerPaymentCashCommand cmd);
    
    /**
     * Called by sales.ReturnFinalizationService for CASH refund tender.
     * REQUIRED propagation.
     */
    void recordRefundCash(RefundCashCommand cmd);
}

public interface SessionQueryService {
    Optional<CashRegisterSession> getCurrentSession(StoreId storeId, RegisterId registerId);
    CashRegisterSession findById(SessionId id);
    boolean isOrphan(SessionId id);  // last opened more than N days ago
}

public interface SessionSummaryService {
    SessionSummary computePreCloseSummary(SessionId id);  // expected_cash + tender breakdown
}

public interface ZReportQueryService {
    ZReport findBySessionId(SessionId id);
    byte[] renderPdfFromSnapshot(ZReportId id);  // deterministic; renders cached snapshot
}
```

Sales depends on `CashRegisterCommandService.recordSaleCashFlow()` + `recordRefundCash()`. Finance depends on `recordCustomerPaymentCash()`. Reporting depends on query services.
