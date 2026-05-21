# Module: purchasing

> **Status:** Locked (Phase 4)
> **Bounded context:** Purchasing

## Position in dependency graph

```
identity (Q), catalog (Q)
   ↑
purchasing (originating orchestrator)
   ↓ (W)
inventory, finance
```

Purchasing originates purchase invoice commit operations. Writes to inventory (PURCHASE_IN) and finance (supplier debt) in same TX.

## Aggregate roots

| Aggregate | Phase 2B ref | Lifecycle |
|---|---|---|
| `PurchaseInvoice` | §2.B.26 | DRAFT → COMMITTED → REVERSED (§3.D.2) |
| `PurchaseInvoiceLine` | §2.B.27 | Child of PurchaseInvoice |

## Package structure

```
io.stockapp.purchasing/
├── api/
│   ├── PurchaseInvoiceController.java     # /finance/purchase-invoices/*
│   └── dto/
├── application/
│   ├── command/
│   │   ├── PurchaseInvoiceCommandService.java
│   │   └── PurchaseInvoiceCommitService.java  # ORCHESTRATOR
│   └── query/
│       └── PurchaseInvoiceQueryService.java
├── domain/
│   ├── invoice/
│   │   ├── PurchaseInvoice.java
│   │   ├── PurchaseInvoiceLine.java
│   │   ├── PurchaseInvoiceStatus.java
│   │   ├── InvoiceNumber.java              # value object (PI-NNNN)
│   │   ├── SupplierInvoiceNumber.java      # value object (supplier's own)
│   │   ├── FreightAllocation.java          # value object: prorate logic
│   │   └── PurchaseInvoiceRepository.java
│   └── event/
│       ├── PurchaseInvoiceCommittedEvent.java
│       └── PurchaseInvoiceReversedEvent.java
└── infrastructure/
    └── persistence/
```

## Transaction ownership — PurchaseInvoiceCommitService

```java
@Service
public class PurchaseInvoiceCommitService {
    
    @Transactional(propagation = Propagation.REQUIRED)
    public void commit(PurchaseInvoiceId id, X-IdempotencyKey idemKey) {
        // 1. Load + lock invoice (FOR UPDATE)
        PurchaseInvoice invoice = invoiceRepo.lockById(id);
        invoice.validateReadyForCommit();
        
        // 2. Allocate freight across lines (proportional to line gross)
        invoice.allocateFreight();
        
        // 3. EXPLICIT cross-module writes:
        //    - inventory.applyMovements() → PURCHASE_IN per line, WAC recompute per (variant, store)
        inventoryCommand.applyMovements(invoice.toPurchaseInMovements());
        
        //    - finance.recordSupplierDebt() → account_movement DEBT_INCREASE for net total
        financeCommand.recordSupplierDebt(invoice.toSupplierDebtEntry());
        
        // 4. Update invoice state
        invoice.commit();
        invoiceRepo.save(invoice);
        
        // 5. Outbox event
        outbox.publish(new PurchaseInvoiceCommittedEvent(invoice.id(), invoice.toEventPayload()));
    }
    
    @Transactional(propagation = Propagation.REQUIRED)
    public void reverse(PurchaseInvoiceId originalId, ReverseReason reason, X-IdempotencyKey idemKey) {
        PurchaseInvoice original = invoiceRepo.lockById(originalId);
        original.validateReadyForReverse();
        
        // Create new REVERSE invoice with inverted signs
        PurchaseInvoice reverseInv = original.toReverse(reason);
        invoiceRepo.save(reverseInv);
        
        // Cross-module writes (inverted)
        inventoryCommand.applyMovements(reverseInv.toPurchaseInMovements());  // negative quantities
        financeCommand.recordSupplierDebt(reverseInv.toSupplierDebtEntry());  // debit decrease
        
        // Mark original as REVERSED
        original.markReversed(reverseInv.id());
        invoiceRepo.save(original);
        
        outbox.publish(new PurchaseInvoiceReversedEvent(...));
    }
}
```

Same explicit orchestration pattern as Sales. ArchUnit Kategori C enforces no nested chain.

## Outbox events emitted

| Event | When | Consumers |
|---|---|---|
| `PurchaseInvoiceCommittedEvent` | COMMITTED | reporting (stock valuation, top selling), finance (cache invalidation: supplier aging) |
| `PurchaseInvoiceReversedEvent` | REVERSED | reporting |
| `SupplierInvoiceNumberDuplicateDetectedEvent` | Duplicate detected at validation | reporting (fraud signal) |

## Outbox events consumed

NONE.

## ArchUnit rules

- `purchasing_to_catalog_query_only`
- `purchasing_to_finance_query_or_command`
- `sales_cannot_depend_on_purchasing` (and reverse)
- `cross_module_writes_only_from_orchestrator`

## Cache invalidation hooks

Purchasing doesn't own caches. Cross-module writes invalidate downstream caches via their consumers.

## Key invariants

1. **DRAFT creates NO side effects** (§3.D.2 + invariant): stock movement, WAC update, supplier debt — all 4 happen atomically at commit(). DRAFT can be edited, deleted (hard), abandoned.

2. **Atomic commit** (§3.D.2): inventory + finance + invoice state — all in single TX.

3. **WAC recomputation** (§3.D.2 + ADR-003): formula at line-level effective_unit_cost (after freight + line discount). Inside inventory.applyMovements() TX.

4. **Supplier invoice UNIQUE per tenant + supplier** (§3.D.2): UNIQUE(tenant_id, supplier_id, supplier_invoice_number). Cross-supplier duplicates allowed.

5. **Reverse creates new REVERSE invoice** (§3.D.2): original NOT mutated structurally; both visible for audit.

6. **Freight allocation proportional to line gross**: not flat-per-line; not per-quantity. Proportional.

7. **Idempotency on commit and reverse**: X-Idempotency-Key required.

## Public API surface

```java
public interface PurchaseInvoiceQueryService {
    PurchaseInvoice findById(PurchaseInvoiceId id);
    Page<PurchaseInvoiceSummary> search(PurchaseInvoiceSearchSpec spec, PageRequest page);
}
```

Reporting consumes. No other module depends on purchasing.
