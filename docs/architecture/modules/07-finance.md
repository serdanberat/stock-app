# Module: finance

> **Status:** Locked (Phase 4)
> **Bounded context:** Finance

## Position in dependency graph

```
identity (Q), catalog (Q)
   ↑
finance (receives W from sales+purchasing; originates W to cashregister via payments)
   ↓ (W)
cashregister  (only when finance.PaymentCommandService is entry point — customer payment)
```

Finance is a **mid-layer module**: receives debt writes from sales (customer CUSTOMER_ACCOUNT tender) and purchasing (supplier debt at commit). Originates writes to cashregister when customer payment is the entry point (3.D.7 cash tender).

## Aggregate roots

| Aggregate | Phase 2B ref | Lifecycle |
|---|---|---|
| `AccountProfile` | §2.B.28 | Per (party_id); upserted; never deleted |
| `AccountMovement` | §2.B.29 | **Append-only**; immutable post-insert (DB trigger) |
| `StoreCreditBalance` | §2.B.30 | Per (party_id); NON-NEGATIVE balance; upserted |
| `Payment` | §2.B.31 | Append-only; PAY-NNNN monotonic |

## Package structure

```
io.stockapp.finance/
├── api/
│   ├── PartyAccountController.java         # /finance/customer-accounts/*, /finance/supplier-accounts/*
│   ├── PaymentController.java              # /finance/customer-payments/*, /finance/supplier-payments/*
│   └── dto/
├── application/
│   ├── command/
│   │   ├── AccountMovementCommandService.java  # PUBLIC: recordCustomerDebt(), recordSupplierDebt()
│   │   ├── PaymentCommandService.java          # PUBLIC for OWN module + sales? NO — only OWN
│   │   ├── PaymentOrchestrationService.java    # ORCHESTRATOR for payment workflow
│   │   └── StoreCreditCommandService.java
│   └── query/
│       ├── AccountQueryService.java
│       ├── PaymentQueryService.java
│       └── StoreCreditQueryService.java
├── domain/
│   ├── account/
│   │   ├── AccountProfile.java
│   │   ├── AccountMovement.java            # immutable
│   │   ├── AccountMovementType.java        # enum (extended Phase 3.D)
│   │   ├── AgingBucket.java                # value object
│   │   └── AccountRepository.java
│   ├── payment/
│   │   ├── Payment.java
│   │   ├── PaymentDirection.java           # enum
│   │   ├── PaymentTender.java              # enum
│   │   ├── BankTransferReference.java      # value object
│   │   └── PaymentRepository.java
│   ├── storecredit/
│   │   ├── StoreCreditBalance.java
│   │   └── StoreCreditRepository.java
│   └── event/
│       ├── CustomerPaymentReceivedEvent.java
│       ├── SupplierPaymentMadeEvent.java
│       ├── StoreCreditIssuedEvent.java
│       ├── StoreCreditRedeemedEvent.java
│       ├── DebtIncreasedEvent.java
│       └── OverpaymentRecordedEvent.java
└── infrastructure/
    └── persistence/
```

## Transaction ownership

| Operation | Boundary | Propagation | Notes |
|---|---|---|---|
| `AccountMovementCommandService.recordCustomerDebt()` | REQUIRED | Same TX as caller (sales completion) | FOR UPDATE on account_profile row |
| `AccountMovementCommandService.recordSupplierDebt()` | REQUIRED | Same TX as caller (purchasing commit) | FOR UPDATE on account_profile row |
| `AccountMovementCommandService.recordRefundCredit()` | REQUIRED | Same TX as caller (sales return finalize) | FOR UPDATE; possibly creates StoreCreditBalance |
| `PaymentOrchestrationService.collectFromCustomer()` | REQUIRES_NEW | New TX | Customer payment (3.D.7); writes cashregister IF tender=CASH |
| `PaymentOrchestrationService.payToSupplier()` | REQUIRES_NEW | New TX | Supplier payment |
| `StoreCreditCommandService.issue()` | REQUIRED | Same TX as caller (return finalize w/ STORE_CREDIT) |
| `StoreCreditCommandService.redeem()` | REQUIRES_NEW | Used during payment (STORE_CREDIT_REDEMPTION tender) |

### PaymentOrchestrationService.collectFromCustomer (CRITICAL ORCHESTRATOR)

```java
@Service
public class PaymentOrchestrationService {
    
    @Transactional(propagation = Propagation.REQUIRES_NEW)
    public Payment collectFromCustomer(CollectCommand cmd, X-IdempotencyKey idemKey) {
        // 1. Lock account
        AccountProfile account = accountRepo.lockByPartyId(cmd.partyId());
        
        // 2. Tender-specific validation
        if (cmd.tender() == STORE_CREDIT_REDEMPTION) {
            storeCreditQuery.validateAvailable(cmd.partyId(), cmd.amount());
        }
        
        // 3. Create payment
        Payment payment = Payment.collect(cmd);
        paymentRepo.save(payment);
        
        // 4. Account movement
        AccountMovement movement = AccountMovement.paymentReceived(payment);
        accountRepo.appendMovement(movement);
        
        // 5. Tender-specific cross-module write (EXPLICIT)
        if (cmd.tender() == CASH) {
            // Finance is originator → cashregister W (matrix allowed)
            cashregisterCommand.recordCustomerPaymentCash(payment.toCashFlow());
        }
        if (cmd.tender() == STORE_CREDIT_REDEMPTION) {
            storeCreditCommand.redeem(cmd.partyId(), cmd.amount());
        }
        
        // 6. Outbox event
        outbox.publish(new CustomerPaymentReceivedEvent(payment.id(), payment.toPayload()));
        
        return payment;
    }
}
```

ArchUnit Kategori C check: `PaymentOrchestrationService` is in `..finance.application.command..`. It calls `cashregister.application.command..` — matrix-allowed (finance → cashregister W). No nested chain (PaymentCommandService doesn't call cashregister; only PaymentOrchestrationService does).

## Outbox events emitted

| Event | When | Consumers |
|---|---|---|
| `CustomerPaymentReceivedEvent` | Customer payment | reporting (aging mview), sales (cache invalidation: customer credit) |
| `SupplierPaymentMadeEvent` | Supplier payment | reporting |
| `StoreCreditIssuedEvent` | Return with STORE_CREDIT tender | reporting |
| `StoreCreditRedeemedEvent` | Payment with STORE_CREDIT_REDEMPTION | reporting |
| `DebtIncreasedEvent` | Customer debt (from sales) or supplier debt (from purchasing) | reporting |
| `OverpaymentRecordedEvent` | Amount > current debt | reporting (analyst signal) |

## Outbox events consumed

| Event | Source | Action |
|---|---|---|
| `SaleAdministrativelyReversedEvent` | sales | Reverse customer debt; create CORRECTING account_movement |

This is the only inbound event consumer. Async; eventual. Not in same TX.

## ArchUnit rules

- `sales_to_finance_query_or_command`
- `purchasing_to_finance_query_or_command`
- `finance_command_service_callers_restricted` (only sales + purchasing for AccountMovementCommandService writes)
- `finance_command_does_not_call_cashregister_command` — EXCEPT via PaymentOrchestrationService (matrix-explicit)
- `finance_cannot_write_inventory`

**Subtle rule needed**: `PaymentOrchestrationService → cashregister.command` IS allowed (matrix-explicit), but `AccountMovementCommandService → cashregister` is NOT (would be nested chain via sales). Two separate finance command classes, two different permissions. Kategori C rule applies precisely.

## Cache invalidation hooks

| Cache key | Invalidated by |
|---|---|
| `account-summary:{tenant_id}:{party_id}` | DebtIncreasedEvent, CustomerPaymentReceivedEvent, StoreCreditIssuedEvent, StoreCreditRedeemedEvent |
| `customer-aging:{tenant_id}` | Same above (mview refresh trigger; scheduled per Phase 6.G) |

POS hot path uses fresh DB lookup (`?fresh=true`), not cache, per §3.A.5.

## Key invariants

1. **Account movements append-only** (ADR-002): no UPDATE/DELETE; DB trigger blocks.

2. **Atomic debt write same TX as originating operation** (matrix W rule): sales completion → CustomerAccount debt entry in SAME TX. Purchase commit → SupplierAccount debt entry in SAME TX. NO async event-driven write for these.

3. **STORE_CREDIT is real monetary liability** (§3.D.4): not loyalty points. Aging tracking, redemption rules, customer-side account_movement.

4. **Bank transfer reference UNIQUE per tenant per year** (§3.D.7): UNIQUE(tenant_id, payment_year, bank_transfer_reference) WHERE tender_type='BANK_TRANSFER'.

5. **Overpayment allowed; results in negative balance** (§3.D.7): customer balance goes negative (customer has credit at store). UI shows warning; not blocked.

6. **STORE_CREDIT_REDEMPTION cannot exceed available** (§3.D.7): server-validated at redeem; 422 with available amount if exceeded.

7. **Customer payment CASH tender writes cashregister atomically** (§3.D.7): orchestrator pattern; PaymentOrchestrationService is the only path; ArchUnit-enforced.

8. **CARD refund MVP is stub** (§3.D.4): returns success; real terminal reversal v1.1+. Finance creates account_movement but no real card-side state change.

## Public API surface

```java
public interface AccountMovementCommandService {
    /**
     * Sales calls this in SaleCompletionService for CUSTOMER_ACCOUNT tender.
     * REQUIRED propagation; joins caller TX.
     */
    void recordCustomerDebt(CustomerDebtCommand cmd);
    
    /**
     * Purchasing calls this in PurchaseInvoiceCommitService at commit.
     */
    void recordSupplierDebt(SupplierDebtCommand cmd);
    
    /**
     * Sales calls this in ReturnFinalizationService for refund credit.
     */
    void recordRefundCredit(RefundCreditCommand cmd);
}

public interface PaymentOrchestrationService {
    /**
     * Customer payment workflow (3.D.7). Called from finance controllers only.
     * NOT exposed to sales/purchasing.
     */
    Payment collectFromCustomer(CollectCommand cmd, IdempotencyKey idem);
    Payment payToSupplier(PayCommand cmd, IdempotencyKey idem);
}

public interface AccountQueryService {
    AccountSummary getAccountSummary(PartyId partyId);
    
    /**
     * Fresh DB lookup, bypassing cache. Used by sales at completion for 
     * credit limit check (per §3.A.5).
     */
    AccountSummary getAccountSummaryFresh(PartyId partyId);
    
    Page<AccountMovement> searchMovements(MovementSearchSpec spec, PageRequest page);
}

public interface StoreCreditQueryService {
    StoreCreditBalance getBalance(PartyId partyId);
    void validateAvailable(PartyId partyId, Money amount);
}
```

Sales depends on `AccountQueryService` + `AccountMovementCommandService`. Purchasing depends on `AccountMovementCommandService` + `AccountQueryService`. Reporting depends on all query services.
