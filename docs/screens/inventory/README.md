# Phase 3.C — Inventory Operations

> **Status:** Locked
> **Phase:** 3.C
> **Delivery date:** 2026-05-21

Inventory is the authoritative source for stock state. POS and Catalog screens display projections of this data; Inventory screens are where stock authoritatively lives and changes.

Phase 3.C establishes "friction is safety" as the inventory UX principle: no inline edit, navigation-only routes from listing screens to adjustment screens, scanner-first ergonomics for warehouse staff, append-only ledger discipline.

## Screens (5)

| # | Screen | Purpose | Key complexity |
|---|---|---|---|
| 3.C.1 | Stock List | Authoritative per-store stock view | Read-only; projection-vs-authority disclosure |
| 3.C.2 | Stock Movement History | Append-only ledger view, filterable | correlation_id drill-down; immutable rows |
| 3.C.3 | Stock Transfer | Multi-store transfer with 3-step lifecycle | DISPATCHED → IN_TRANSIT → RECEIVED; partial receive; cancellation semantics; WAC propagation |
| 3.C.4 | Stock Count Session | Manual count with variance computation | Rolling count model (no freeze); REPEATABLE READ snapshot; role split count vs finalize |
| 3.C.5 | Stock Adjustment | Manager-only direct stock correction | Single-shot immutable; 8 reason codes; large adjustment safeguard; reverse for mistakes |

## Inventory Shell pattern

```
Inventory Shell  /inventory/*
  ├─ Stok Durumu          (3.C.1)  default
  ├─ Stok Hareketleri     (3.C.2)
  ├─ Transferler          (3.C.3)
  ├─ Sayım                (3.C.4)
  └─ Düzeltme             (3.C.5)
```

Same bounded context. Same permission group. Same layout shell. Different views, different concerns. Consistent with Catalog Shell pattern.

## Locked decisions catalog

### Stock List (3.C.1)
- **Granularity**: per (variant_id, store_id) row
- **Default filter**: current logged-in user's primary store
- **Read-only**: NO inline edit; navigation-only "Stok Düzeltmeye Git"
- **Synthetic zero-stock rows**: server returns with `is_synthetic:true` flag
- **In-transit detail**: separate "Yolda Gelen" + "Yolda Giden" in detail panel
- **Authority wording**: "Projection güncellemesi: 2 dk önce" (precise; not "real-time")

### Movement History (3.C.2)
- **Append-only ledger**: rows immutable; no edit/delete endpoints
- **resulting_balance_at_movement**: historical snapshot; no retroactive recalc
- **movement_wac_snapshot**: renamed from cost_at_movement for clarity
- **correlation_id**: required in detail panel + filter (transfer pair, sale completion, reconciliation)
- **Movement type colors**: 8 types with consistent color/icon scheme

### Stock Transfer (3.C.3)
- **3-step state machine**: DRAFT → DISPATCHED → IN_TRANSIT → RECEIVED
- **No stock mutation before dispatch**
- **Receive atomicity**: entire receive is atomic; all lines commit OR none
- **Transfer line snapshot**: SKU + display_name preserved at creation time
- **Discrepancy reason**: TRANSFER_DISCREPANCY (distinct from regular ADJUSTMENT) with LOSS/DAMAGE sub-reason
- **Over-scan protection**: receive scanner stops auto-increment at expected count
- **WAC propagation**: source WAC snapshot inherited at target on receive
- **IN_TRANSIT cancel**: manager-only with mandatory reason + free-text (min 20 chars)
- **Late-arriving goods after cancel**: separate adjustment flow (no uncancel)
- **Source/target same store**: rejected at DRAFT
- **Multi-batch receive over time**: deferred v1.1+

### Stock Count Session (3.C.4)
- **MVP scope**: category-based + spot-check (not full-store)
- **Rolling count model**: inventory operations continue during session
- **Snapshot isolation**: REPEATABLE READ MVCC (NOT FOR UPDATE)
- **Variance computation**: counted - (snapshot + session_movements)
- **Role split**: STOCK_CLERK counts, STORE_MANAGER finalizes (multi-role for small boutique)
- **Movement-during-session disclosure**: line-level tooltip + finalize modal table
- **Aggressive completeness warning**: explicit acknowledgment for skipped lines
- **COUNT_CORRECTION movements**: correlation_id = session.id

### Stock Adjustment (3.C.5)
- **Single-shot**: no DRAFT lifecycle
- **Immutable after commit**: mistake correction via reverse adjustment
- **8 reason codes**: DAMAGE, LOSS (renamed from THEFT), COUNT_CORRECTION (system), SUPPLIER_RETURN, EXPIRED, INTERNAL_USE, GIFT, TRANSFER_CANCELLED (system), OTHER
- **Large adjustment safeguard**: tenant threshold (default 50 units) requires second confirm
- **Scanner default**: sign = -1 with immediate negative styling
- **Duplicate line merge**: same reason summed; different reasons rejected
- **Manager-only**: CASHIER and STOCK_CLERK no access

## Architectural decisions

- **ADR-020 — Correlation ID Pattern**: correlation_id shared across related movements (transfer pair, sale completion, return reconciliation, count session). Drives audit log drill-down and movement reconciliation.

## Schema additions (Migration 020)

- `transfer_lines.sku_snapshot`, `transfer_lines.display_name_snapshot`
- `count_sessions` table with snapshot_quantity capture fields
- `count_session_lines` with counted_quantity, note
- `adjustments` table with reason CHECK constraint (8 reasons)
- `stock_movements.correlation_id` (UUID, indexed)
- `stock_movements.movement_wac_snapshot` (renamed from cost_at_movement)
- Stock movement reason enum extended: TRANSFER_DISCREPANCY, LOSS (not THEFT), EXPIRED, INTERNAL_USE, GIFT, TRANSFER_CANCELLED

See `migrations/020_inventory_extensions.sql`.

## Audit event catalog (Phase 3.C additions)

### Transfer
| Event | Triggered by |
|---|---|
| transfer_created | New DRAFT |
| transfer_line_added / removed / quantity_changed | DRAFT edit |
| transfer_dispatched | DISPATCHED transition |
| transfer_shipped | IN_TRANSIT transition |
| transfer_received | RECEIVED with line detail |
| transfer_partial_received | When discrepancy sum > 0 |
| transfer_cancelled_before_shipped | DISPATCHED → CANCELLED |
| transfer_cancelled_in_transit | IN_TRANSIT → CANCELLED (manager-only) |
| transfer_line_discrepancy_recorded | Per-line LOSS/DAMAGE |

### Count
| Event | Triggered by |
|---|---|
| count_session_created | New DRAFT |
| count_session_started | IN_PROGRESS with snapshot |
| count_session_line_counted | Per-line entry |
| count_session_finalized | FINALIZED with variance summary |
| count_session_cancelled | CANCELLED |
| count_correction_applied | Per discrepancy movement |

### Adjustment
| Event | Triggered by |
|---|---|
| adjustment_created | Single-shot commit |
| adjustment_large_confirmed | Over threshold confirm |
| adjustment_negative_stock_warned | Negative balance triggered |

## API endpoints (Phase 3.C additions)

| Endpoint | Purpose |
|---|---|
| POST /inventory/stock-balances/search | Stock list query |
| POST /inventory/movements/search | Movement ledger query |
| POST /inventory/transfers | Create DRAFT |
| PATCH /inventory/transfers/{id} | Edit DRAFT |
| POST /inventory/transfers/{id}/dispatch | DRAFT → DISPATCHED |
| POST /inventory/transfers/{id}/confirm-shipped | DISPATCHED → IN_TRANSIT |
| POST /inventory/transfers/{id}/receive | IN_TRANSIT → RECEIVED |
| POST /inventory/transfers/{id}/cancel | → CANCELLED |
| POST /inventory/counts | Create DRAFT |
| PATCH /inventory/counts/{id} | Edit DRAFT |
| POST /inventory/counts/{id}/start | DRAFT → IN_PROGRESS |
| PATCH /inventory/counts/{id}/lines/{lineId} | Set counted_quantity |
| POST /inventory/counts/{id}/finalize | IN_PROGRESS → FINALIZED |
| POST /inventory/counts/{id}/cancel | → CANCELLED |
| GET /inventory/counts/{id}/movements-during-session | Variance explanation |
| POST /inventory/adjustments | Single-shot create |
| POST /inventory/adjustments/search | List query |

## What's NOT in Phase 3.C scope

- Full-store count (freeze-window required) — v1.1+
- Multi-batch receive over time — v1.1+
- Real-time stock reservation for online orders — v1.1+
- Bulk adjustment CSV import — v1.1+
- Reconstruction view ("stock balance on date X") — v1.1+
- Stock valuation by FIFO/LIFO — never (WAC-only philosophy)
- CSV export of movement ledger — v1.1+
