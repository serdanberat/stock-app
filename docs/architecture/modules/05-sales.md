# Module: sales

> **Status:** Locked (Phase 4)
> **Bounded context:** Sales (POS) + Returns & Exchanges (sub-package; Phase 4 decision)
> **Why returns inside sales:** Return aggregate shares correlation_id with Sale, creates new Sale (exchange), shares aggregate lifecycle. Ayrı modül cyclic dependency yaratırdı.

## Position in dependency graph

```
identity (Q), catalog (Q), pricing (Q)
   ↑
sales (originating orchestrator)
   ↓ (W)
inventory, cashregister, finance
```

Sales is **the largest orchestrator module**. POS sale completion + return finalization both originate here and write to inventory + cashregister + finance in same TX.

## Aggregate roots

| Aggregate | Phase 2B ref | Lifecycle |
|---|---|---|
| `Sale` | §2.B.20 | DRAFT → AWAITING_PAYMENT → COMPLETED / DRAFT → CANCELLED / COMPLETED → ADMINISTRATIVELY_REVERSED |
| `SaleLine` | §2.B.21 | Child of Sale; immutable after sale.complete() |
| `Payment` (Sale-scoped) | §2.B.22 | Per-tender attempt; CARD has retry semantics per §3.A.6 |
| `Return` | §2.B.23 | DRAFT → COMPLETED / CANCELLED (§3.D.4) |
| `ReturnLine`, `ExchangeLine` | §2.B.24 | Children of Return |
| `Receipt` | §2.B.25 | Generated at sale completion (worker, async) |

## Package structure

```
io.stockapp.sales/
├── api/
│   ├── PosController.java                  # /pos/* (sale lifecycle)
│   ├── SaleController.java                 # /sales/* (admin queries)
│   ├── ReturnController.java               # /finance/returns/* (sub-package routing)
│   └── dto/
├── application/
│   ├── command/
│   │   ├── SaleCommandService.java         # DRAFT lifecycle, line add/remove
│   │   ├── SaleCompletionService.java      # CRITICAL ORCHESTRATOR (see below)
│   │   ├── ReturnCommandService.java
│   │   └── ReturnFinalizationService.java  # ORCHESTRATOR for return/exchange
│   └── query/
│       ├── SaleQueryService.java
│       └── ReturnQueryService.java
├── domain/
│   ├── sale/
│   │   ├── Sale.java                       # aggregate root
│   │   ├── SaleLine.java
│   │   ├── SaleStatus.java
│   │   ├── DiscountCommand.java            # value object (line / cart / manager-override)
│   │   ├── ManagerOverrideToken.java       # value object (token + audit trace)
│   │   └── SaleRepository.java
│   ├── payment/
│   │   ├── Payment.java
│   │   ├── PaymentAttempt.java             # for CARD retry semantics
│   │   ├── TenderType.java                 # enum: CASH, CARD, CUSTOMER_ACCOUNT
│   │   └── PaymentRepository.java
│   ├── returns/                            # sub-package (NOT separate module)
│   │   ├── Return.java                     # aggregate root
│   │   ├── ReturnLine.java
│   │   ├── ExchangeLine.java
│   │   ├── ReturnMode.java                 # enum: REFERENCED / WITHOUT_REFERENCE
│   │   ├── RefundTender.java               # value object with allowlist enforcement
│   │   └── ReturnRepository.java
│   ├── receipt/
│   │   ├── Receipt.java                    # snapshot model
│   │   └── ReceiptRepository.java
│   └── event/
│       ├── SaleCompletedEvent.java
│       ├── SaleAdministrativelyReversedEvent.java
│       ├── ReturnFinalizedEvent.java
│       ├── DiscountOverriddenEvent.java
│       └── PaymentAttemptFailedEvent.java
└── infrastructure/
    ├── persistence/
    └── client/
        └── PaymentTerminalClient.java      # stub MVP; v1.1+ real
```

## Transaction ownership — SaleCompletionService (CRITICAL)

This is the most complex orchestration in the system. Per §3.A.5 + Kategori C ArchUnit rule, **all cross-module writes orchestrated EXPLICITLY here**.

```java
@Service
public class SaleCompletionService {
    
    @Transactional(propagation = Propagation.REQUIRED)  // outermost TX
    public CompletedSale complete(SaleId saleId, X-IdempotencyKey idemKey) {
        // 1. Load + lock Sale (FOR UPDATE)
        Sale sale = saleRepo.lockById(saleId);
        sale.validateReadyForCompletion();
        
        // 2. Validate stock (fresh DB lookup via inventory query)
        inventoryQuery.getBalanceFresh(...).validateSufficient(...);
        
        // 3. Validate credit (if CUSTOMER_ACCOUNT tender; fresh DB lookup via finance query)
        if (sale.hasCustomerAccountTender()) {
            financeQuery.getAccountSummary(sale.customerId(), fresh=true).validateWithinLimit();
        }
        
        // 4. EXPLICIT cross-module writes — all visible at this call site:
        inventoryCommand.applyMovements(sale.toMovements());           // → SALE_OUT movements
        cashregisterCommand.recordSaleCashFlow(sale.toCashFlow());     // → SALE_CASH_IN, CHANGE_OUT
        if (sale.hasCustomerAccountTender()) {
            financeCommand.recordCustomerDebt(sale.toDebtEntry());     // → CUSTOMER_ACCOUNT account_movement
        }
        
        // 5. Update Sale aggregate state
        sale.complete();
        saleRepo.save(sale);
        
        // 6. Emit outbox event (consumed by reporting + receipt worker)
        outbox.publish(new SaleCompletedEvent(sale.id(), sale.toEventPayload()));
        
        return sale.toCompletedView();
    }
}
```

**Key points**:
- ONE @Transactional boundary. Outermost.
- Three cross-module writes visible side-by-side. No nested chain.
- ArchUnit Kategori C rule prevents finance/inventory/cashregister command services from calling each other.
- Receipt PDF generation is async via outbox + DocumentWorker; NOT in this TX.

## Outbox events emitted

| Event | When | Consumers |
|---|---|---|
| `SaleCompletedEvent` | COMPLETED | reporting, receipt worker (PDF generation) |
| `SaleAdministrativelyReversedEvent` | COMPLETED → ADMINISTRATIVELY_REVERSED | reporting, finance (reverse customer debt) — Phase 5 detail |
| `ReturnFinalizedEvent` | Return COMPLETED | reporting |
| `DiscountOverriddenEvent` | Manager-override applied to discount | reporting (fraud surface) |
| `PaymentAttemptFailedEvent` | CARD terminal failure | reporting; sales itself (3.A.6 recovery state) |
| `StoreCreditIssuedEvent` | Return refund tender = STORE_CREDIT | reporting, finance (cache invalidation: customer aging) |

## Outbox events consumed

NONE. Sales is an originating orchestrator; downstream of nothing.

(Sales does NOT consume catalog's VariantDeactivatedEvent — sale-through is allowed.)

## ArchUnit rules

- `sales_to_pricing_query_only`
- `sales_to_finance_query_or_command`
- `sales_cannot_depend_on_purchasing`
- `cross_module_writes_only_from_orchestrator` (Kategori C critical)

## Cache invalidation hooks

| Cache key | Invalidated by |
|---|---|
| Sales doesn't own caches | Cross-module writes invalidate downstream caches (inventory, finance) via their respective event consumers |

## Key invariants

1. **Two-phase persistence: Zustand DRAFT → server COMPLETED** (§3.A.1): client-side state synced to server DRAFT on every meaningful action. Server is source of truth.

2. **Pricing frozen at add-to-cart** (§3.A.1 + ADR-018): line.unit_price_gross snapshot. Mid-sale price changes don't affect open drafts.

3. **Cart + line discount mutex** (§3.A.4): EXISTS one of {line discount on any line, cart-level discount}. Never both simultaneously. Enforced in Sale aggregate.

4. **Manager PIN BCrypt shared with password** (§3.A.4): same CredentialHasher; 3-fail lockout per (tenant_id, register_session_id). NOT per user globally.

5. **Server-authoritative pricing**: client computed total NEVER trusted at completion. Server recomputes from line snapshots.

6. **Cash overpayment creates 2 movements** (§3.A.5): SALE_CASH_IN (full tender amount) + CHANGE_OUT (change due). Cash drawer ledger reflects both directions.

7. **Idempotency key on completion** (X-Idempotency-Key, 7-day retention): double-click/network-retry safe.

8. **Discount threshold + cart/line discount limits snapshotted at DRAFT creation** (§3.F.4): tenant-policy change mid-sale doesn't break open drafts.

9. **Return refund tender allowlist enforced server-side** (§3.D.4): REFERENCED allows CASH/CARD_REFUND/STORE_CREDIT/CUSTOMER_ACCOUNT; WITHOUT_REFERENCE allows only STORE_CREDIT/CUSTOMER_ACCOUNT. UI hides but server validates.

10. **Exchange decomposition** (§3.D.4): returned_total + new_sale_total + settlement_delta. No "magic exchange total". When exchange triggers new sale, both Sale and Return share correlation_id.

11. **No QUARANTINE_RETURN MVP** (§3.D.4): manager judgment + audit trail. v1.1+ adds quarantine state if fraud patterns observed.

## Public API surface

```java
public interface SaleQueryService {
    Sale findById(SaleId id);
    Page<SaleSummary> search(SaleSearchSpec spec, PageRequest page);
    List<SaleSummary> findByCustomer(PartyId customerId, PageRequest page);  // for return lookup
}

public interface ReturnQueryService {
    Return findById(ReturnId id);
    Page<ReturnSummary> search(ReturnSearchSpec spec, PageRequest page);
}
```

Reporting consumes both query services. No other module depends on sales.application.command (Kategori A enforcement).
