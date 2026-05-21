# Module: inventory

> **Status:** Locked (Phase 4)
> **Bounded context:** Inventory

## Position in dependency graph

```
identity (Q), catalog (Q)
   ↑
inventory
   ↑ (W)
sales, purchasing
   
inventory ← reporting (Q only)
```

Inventory write side is THE single authoritative source for stock state. Two upstream modules (sales, purchasing) write here. Reporting reads. No other writes.

## Aggregate roots

| Aggregate | Phase 2B ref | Lifecycle |
|---|---|---|
| `StockBalance` | §2.B.15 | Per (tenant_id, variant_id, store_id); upserted; never deleted |
| `StockMovement` | §2.B.16 | **Append-only**; immutable post-insert (DB trigger) |
| `Transfer` | §2.B.17 | DRAFT → DISPATCHED → IN_TRANSIT → RECEIVED/CANCELLED (§3.C.3) |
| `CountSession` | §2.B.18 | DRAFT → IN_PROGRESS → FINALIZED/CANCELLED (§3.C.4) |
| `Adjustment` | §2.B.19 | **Single-shot immutable** (§3.C.5) |

## Package structure

```
io.stockapp.inventory/
├── api/
│   ├── StockController.java                # /inventory/stock/*
│   ├── MovementController.java             # /inventory/movements/*
│   ├── TransferController.java             # /inventory/transfers/*
│   ├── CountController.java                # /inventory/counts/*
│   ├── AdjustmentController.java           # /inventory/adjustments/*
│   └── dto/
├── application/
│   ├── command/
│   │   ├── InventoryCommandService.java    # PUBLIC: applyMovements() — called from sales, purchasing
│   │   ├── TransferCommandService.java     # transfer lifecycle
│   │   ├── CountCommandService.java        # count session lifecycle
│   │   └── AdjustmentCommandService.java   # single-shot adjustments
│   └── query/
│       ├── StockBalanceQueryService.java   # per-store stock projection
│       ├── MovementQueryService.java       # ledger queries
│       └── TransferQueryService.java
├── domain/
│   ├── balance/
│   │   ├── StockBalance.java
│   │   ├── Quantity.java                   # module-owned VO
│   │   ├── WeightedAverageCost.java        # module-owned VO
│   │   └── StockBalanceRepository.java
│   ├── movement/
│   │   ├── StockMovement.java              # immutable
│   │   ├── MovementType.java               # enum
│   │   ├── MovementReason.java             # enum (extended in Phase 3.C)
│   │   └── StockMovementRepository.java    # write: append-only
│   ├── transfer/
│   │   ├── Transfer.java
│   │   ├── TransferLine.java               # has sku_snapshot + display_name_snapshot
│   │   ├── TransferStatus.java
│   │   └── TransferRepository.java
│   ├── count/
│   │   ├── CountSession.java
│   │   ├── CountSessionLine.java           # has snapshot_quantity (REPEATABLE READ MVCC)
│   │   └── CountSessionRepository.java
│   ├── adjustment/
│   │   ├── Adjustment.java                 # immutable post-creation
│   │   ├── AdjustmentLine.java
│   │   └── AdjustmentRepository.java
│   └── event/
│       ├── StockMovementCreatedEvent.java
│       ├── LowStockReachedEvent.java
│       ├── TransferDispatchedEvent.java
│       ├── TransferReceivedEvent.java
│       └── CountFinalizedEvent.java
└── infrastructure/
    └── persistence/                        # JPA write + JOOQ projection queries
```

## Transaction ownership

| Operation | Boundary | Propagation | Lock strategy |
|---|---|---|---|
| `InventoryCommandService.applyMovements()` | REQUIRED | Same TX as caller (sales/purchasing) | FOR UPDATE on stock_balances rows, canonical variant_id ASC |
| `TransferCommandService.dispatch()` | REQUIRES_NEW | New TX | FOR UPDATE on source stock_balances + transfer row |
| `TransferCommandService.receive()` | REQUIRES_NEW | New TX | FOR UPDATE on target stock_balances + transfer row; atomic per ADR-?+§3.C.3 |
| `CountCommandService.start()` | REQUIRES_NEW | REPEATABLE READ isolation; captures snapshot (NOT FOR UPDATE) |
| `CountCommandService.finalize()` | REQUIRES_NEW | FOR UPDATE on variance lines |
| `AdjustmentCommandService.create()` | REQUIRES_NEW | Single TX; FOR UPDATE on stock_balances |

CRITICAL: `applyMovements()` uses **REQUIRED** (joins caller's TX), so sales completion atomically commits both Sale aggregate AND stock decrement. All other commands use REQUIRES_NEW (own TX boundary).

## Outbox events emitted

| Event | When | Consumers |
|---|---|---|
| `StockMovementCreatedEvent` | Any movement (sale, purchase, transfer, adjustment, count correction) | reporting (mview refresh trigger v1.1+; MVP: scheduled refresh) |
| `LowStockReachedEvent` | Movement crosses tenant `low_stock_default_threshold` | reporting (alert surface) |
| `TransferDispatchedEvent` | DRAFT → DISPATCHED | reporting (audit), POS (cache invalidation: source store quantity_in_transit_outbound) |
| `TransferReceivedEvent` | IN_TRANSIT → RECEIVED | reporting, POS cache invalidation |
| `TransferCancelledInTransitEvent` | IN_TRANSIT → CANCELLED | reporting (LOSS audit surface; per §3.C.3 mandatory reason) |
| `CountFinalizedEvent` | Count session FINALIZED | reporting |
| `AdjustmentCreatedEvent` | Single-shot create | reporting (large-adjustment surface) |
| `NegativeStockOccurredEvent` | Movement results in balance < 0 (only if tenant.allow_negative_stock=true) | reporting (alerting) |

## Outbox events consumed

| Event | Source | Action |
|---|---|---|
| `VariantCreatedEvent` | catalog | (no action MVP — synthetic 0-balance row created lazily on first movement) |
| `VariantDeactivatedEvent` | catalog | (no action — variant deactivated remains queryable for cleanup) |

Inventory's consumer surface is minimal. It's primarily a write-recipient module.

## ArchUnit rules

- `inventory_to_catalog_query_only`
- `inventory_cannot_depend_on_pricing`
- Inventory never depends on sales/purchasing/finance/cashregister/reporting

## Cache invalidation hooks

| Cache key | Invalidated by |
|---|---|
| `stock-balance:{tenant_id}:{variant_id}:{store_id}` | StockMovementCreatedEvent (for affected variant+store), TransferReceivedEvent |
| `stock-list-projection:{tenant_id}:{store_id}` | StockMovementCreatedEvent (delayed; TTL 30s tolerable per §3.C.1 "Projection güncellemesi: 2dk önce") |

POS hot path (sale completion availability check) uses FRESH DB lookup, not cache, per §3.A.5.

## Key invariants

1. **Stock movements append-only** (ADR-002): `prevent_audit_mutation()` trigger blocks UPDATE/DELETE on stock_movements. No retroactive correction; reverse via new movement.

2. **resulting_balance_at_movement is historical snapshot** (§3.C.2): never retroactively recalculated when later movements arrive.

3. **WAC recomputation atomic with movement insert** (§3.D.2 + ADR-003): formula `((old_qty × old_WAC) + (received_qty × line_unit_cost)) / (old_qty + received_qty)`. Inside same TX as movement insert and balance update.

4. **Transfer receive atomicity** (§3.C.3): entire receive commits OR none. Per-line discrepancies use TRANSFER_DISCREPANCY reason (distinct from regular ADJUSTMENT for analytics).

5. **Count session rolling model** (§3.C.4): REPEATABLE READ snapshot at start; inventory operations NOT blocked during session. Variance computed against (snapshot + session_movements) at finalize.

6. **Adjustment single-shot immutable** (§3.C.5): no DRAFT state. Mistake correction = reverse adjustment.

7. **WAC propagation across transfer** (§3.C.3): source WAC snapshot inherited at target on receive.

8. **correlation_id on every movement** (ADR-020): shared with originating aggregate (transfer.id, sale.id, return.id, etc.). Enables audit log timeline.

## Public API surface

```java
public interface InventoryCommandService {
    /**
     * Single entry-point for cross-module stock writes.
     * Called by sales (SALE_OUT), purchasing (PURCHASE_IN), via REQUIRED propagation.
     * 
     * @param movements list of {variant_id, store_id, signed_quantity, reason_code, correlation_id}
     * @throws InsufficientStockException if would drive balance below 0 and tenant.allow_negative_stock=false
     * @throws StoreClosedException if target store is CLOSED
     */
    void applyMovements(List<MovementCommand> movements);
}

public interface StockBalanceQueryService {
    StockBalance getBalance(VariantId variantId, StoreId storeId);
    List<StockBalance> getBalancesForStore(StoreId storeId, StockListFilter filter, PageRequest page);
    /**
     * Fresh DB lookup, bypassing cache. Used by POS at sale completion for 
     * availability check (per §3.A.5).
     */
    StockBalance getBalanceFresh(VariantId variantId, StoreId storeId);
}

public interface MovementQueryService {
    Page<StockMovement> search(MovementSearchSpec spec, PageRequest page);
    List<StockMovement> findByCorrelationId(CorrelationId corrId);  // for timeline drill-down
}
```

Sales and purchasing call ONLY `InventoryCommandService.applyMovements()`. Both via REQUIRED propagation (same TX). Reporting calls query services only.
