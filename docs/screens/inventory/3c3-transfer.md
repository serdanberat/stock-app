# 3.C.3 — Stock Transfer

> **Status:** Locked (Phase 3.C)
> **Routes:**
> - `/inventory/transfers` — List view
> - `/inventory/transfers/new` — Create draft
> - `/inventory/transfers/{id}` — Detail view (state-dependent UI)

## Purpose

Move stock between stores. 3-step state machine accommodating real shipping reality (1-3 day transit window). Supports partial receive, discrepancy handling, and cancellation.

Most common boutique scenarios:
- Beyoğlu has 8 units of size M, Kadıköy has 0 → transfer 4
- End-of-season: consolidate from satellite stores to main store
- Damaged shipping: 10 sent, 8 arrived intact

## Aggregate ownership (explicit)

- **Writes** Transfer aggregate (state machine + lines)
- **Writes** `stock_movements` indirectly via outbox event consumers:
  - `TRANSFER_OUT` movements at DISPATCH (source debits)
  - `TRANSFER_IN` movements at RECEIVE (target credits, possibly partial)
  - `ADJUSTMENT_OUT` movements at RECEIVE if discrepancy (with `TRANSFER_DISCREPANCY` reason — distinct from regular ADJUSTMENT for analytics)
- **Reads** ProductVariant, stock_balances, stores

**Note**: TRANSFER_OUT writes happen at DISPATCH not at CREATE. Draft transfers do not affect stock until dispatched.

## State machine

```
    DRAFT
      │ dispatch()
      ↓
    DISPATCHED 
      │ ── confirmShipped() ──┐
      ↓                       │
    IN_TRANSIT                │ cancelBeforeShipped()
      │ receive(partial?)     ↓
      ↓                   CANCELLED (terminal)
    RECEIVED
    (terminal)
```

State transitions:
- `DRAFT → DISPATCHED`: source store loses stock atomically
- `DISPATCHED → IN_TRANSIT`: explicit "kargoya verildi" mark
- `IN_TRANSIT → RECEIVED`: target gains stock; discrepancies recorded
- `DISPATCHED → CANCELLED`: source stock restored (cheap reversal)
- `IN_TRANSIT → CANCELLED`: manager-only with LOSS marker (real loss)

### Why distinguish DISPATCHED vs IN_TRANSIT

- DISPATCHED = source verified, items packed, awaiting carrier
- IN_TRANSIT = carrier handed off, no human control

Practical: between DISPATCH and IN_TRANSIT cancellation is cheap (items still in source store). After IN_TRANSIT cancellation means real LOSS or recall coordination with carrier.

## Critical invariants

### Receive atomicity

**Entire receive is atomic — all lines commit OR none.** Half-received transfer is not allowed. If 3 lines: 2 succeed and 3rd fails (deadlock, network, validation), the whole receive transaction rolls back. User retries via idempotency key.

### Transfer line snapshot

Transfer line stores **both SKU snapshot AND display_name snapshot** at transfer creation time. Since SKU is editable post-sale (with manager permission), historical transfer must preserve operational identity at that moment.

### Over-receive protection

Receive UI enforces:
- `received_quantity <= dispatched_quantity` per line (no over-receive)
- Scanner auto-increment STOPS at expected count
- Loud warning if scan attempted beyond expected: "Beklenen miktar aşıldı"
- Server returns 422 if over-receive submitted

To handle excess: receive expected quantity, then create separate Stock Adjustment (3.C.5) at target with reason OTHER + explanation.

### Source/target same store

Rejected at DRAFT save with 422.

## Allowed mutations per state

| State | Allowed |
|---|---|
| DRAFT | add/remove lines; change quantities; change source/target store; delete (no audit); dispatch |
| DISPATCHED | ✗ line mutations LOCKED; confirm shipped; cancel (source stock restored) |
| IN_TRANSIT | ✗ line mutations LOCKED; receive with quantities; cancel (manager-only) |
| RECEIVED, CANCELLED | Terminal. No mutations. |

## Reads

- `GET /inventory/transfers/{id}`
- `POST /inventory/transfers/search` — Body: `{ status?, source_store?, target_store?, date_from/to?, q?, page, page_size }`
- `GET /inventory/stock-balances?store_id={sourceId}` — When building line
- `GET /stores`

## Writes

| Endpoint | Purpose |
|---|---|
| `POST /inventory/transfers` | Body: `{ source_store_id, target_store_id, note? }` — Creates DRAFT |
| `PATCH /inventory/transfers/{id}` | Body: `{ lines: [{variant_id, quantity}], note? }` — Replaces line set in DRAFT |
| `POST /inventory/transfers/{id}/dispatch` | Idempotency-Key required. Atomically: status=DISPATCHED; TRANSFER_OUT movements at source; FOR UPDATE on stock_balances; validates sufficient stock or `allow_negative_stock=true` |
| `POST /inventory/transfers/{id}/confirm-shipped` | status=IN_TRANSIT. No stock movements (already debited at dispatch) |
| `POST /inventory/transfers/{id}/receive` | Body: `{ lines: [{transfer_line_id, received_quantity, discrepancy_reason?}] }`. Idempotency-Key required. Atomically per line: TRANSFER_IN at target with received_quantity; if received < dispatched: ADJUSTMENT_OUT at target with `TRANSFER_DISCREPANCY` reason + sub-reason (LOSS/DAMAGE). **Entire receive is atomic.** Transfer.status=RECEIVED |
| `POST /inventory/transfers/{id}/cancel` | Body: `{ reason, free_text? }`. From DISPATCHED: cheap reversal (ADJUSTMENT_IN at source). From IN_TRANSIT: manager-only with mandatory `cancellation_reason` (LOSS/DAMAGE/RECALLED/OTHER) + mandatory free-text |

### Discrepancy reason — distinct from regular adjustment

When receive records discrepancy, the `ADJUSTMENT_OUT` movement uses reason `TRANSFER_DISCREPANCY` (not the generic adjustment reasons in 3.C.5). This separates analytics:
- "How much do we lose in transit?" → query TRANSFER_DISCREPANCY
- "How much do we damage in-store?" → query regular DAMAGE adjustments

Sub-reason captured for nuance: LOSS, DAMAGE.

### IN_TRANSIT cancellation rules

- Permission: STORE_MANAGER+
- Mandatory cancellation_reason from: `LOSS`, `DAMAGE`, `RECALLED`, `OTHER`
- Mandatory free-text note (min 20 chars)
- Audit event: `transfer_cancelled_in_transit` with full context
- Movements: ADJUSTMENT_IN at source with `LOSS` reason (real loss, not cheap reversal)

Late-arriving goods after cancellation → separate adjustment flow (no uncancel; 3.C.5 with reason OTHER + reference to cancelled transfer).

## Optimistic UI

- DRAFT line edits: yes
- State transitions: NO (must wait for atomic transaction confirmation)
- Receive: NO (server validates per-line, may partial accept)

## Locking

Pessimistic FOR UPDATE during dispatch:
- Transfer row
- All source stock_balances rows (sorted by variant_id ASC)

Same during receive on target stock_balances rows.

Canonical lock order prevents deadlocks per Phase 2D.

## Idempotency

`dispatch`, `receive`, `cancel`: X-Idempotency-Key header required. Retention 7 days in `idempotency_keys` table.

## Keyboard flow (LIST view)

| Key | Action |
|---|---|
| `/` or `Ctrl+K` | Focus search |
| `Ctrl+N` | New transfer (DRAFT) |
| `↓ / ↑` | Row navigation |
| `Enter` | Open transfer detail |

## Keyboard flow (DRAFT create/edit)

| Key | Action |
|---|---|
| Tab | source → target → line search → add → save |
| `Ctrl+S` | Save DRAFT |
| `Ctrl+Enter` | Save and dispatch |
| `Esc` | Discard with confirm if dirty |

## Keyboard flow (RECEIVE)

| Key | Action |
|---|---|
| Tab | Cycles through line quantity inputs |
| Enter on quantity field | Confirm and move to next line |
| Default | Each line's received_quantity = dispatched_quantity |
| `Ctrl+Enter` | Submit receive |

## Barcode flow

### DRAFT mode

Scanner adds line (or increments existing line by 1):
- Resolves barcode → variant_id
- If variant not in source stock_balances (quantity 0): warning toast "Bu varyant kaynak mağazada yok"
- If tenant `allow_negative_stock=true`: can still add

### RECEIVE mode

Scanner activates on quantity confirmation:
- Scan barcode → focus line, increment received_quantity by 1
- Visual: "Tarandı: 7/10 (3 kalan)"
- **Over-scan protection**: scanner refuses to auto-increment past `dispatched_quantity`; loud warning toast "Bu kalemin beklenen miktarı aşıldı"
- Used by stock_clerk at target store unboxing

## Speed budget

| Action | p95 target |
|---|---|
| DRAFT save | < 400ms |
| Dispatch (10 lines) | < 800ms |
| Dispatch (50 lines) | < 2s |
| Receive (10 lines) | < 800ms |
| List view query | < 400ms |

## Permissions

| Permission | Default |
|---|---|
| `inventory.transfers.view` | STORE_MANAGER+, STOCK_CLERK |
| `inventory.transfers.create_draft` | STORE_MANAGER+, STOCK_CLERK |
| `inventory.transfers.dispatch` | STORE_MANAGER+ (source store) |
| `inventory.transfers.confirm_shipped` | STORE_MANAGER+, STOCK_CLERK |
| `inventory.transfers.receive` | STORE_MANAGER+, STOCK_CLERK (target store) |
| `inventory.transfers.cancel_dispatched` | STORE_MANAGER+ |
| `inventory.transfers.cancel_in_transit` | STORE_MANAGER+ (with mandatory reason + free-text) |

## WAC propagation across transfer

Critical inventory-finance link:
- Source store WAC snapshot inherited at target on receive
- For each received line: target's `weighted_avg_cost` recomputed using source's WAC at moment of dispatch as the inbound cost
- Prevents WAC distortion when physical inventory moves between stores

```
new_target_WAC = ((target_old_qty × target_old_WAC) + (received_qty × source_WAC_at_dispatch))
                / (target_old_qty + received_qty)
```

## Audit events

- `transfer_created`
- `transfer_line_added` / `removed` / `quantity_changed`
- `transfer_dispatched` (with line snapshot including SKU + display_name)
- `transfer_shipped` (DISPATCHED → IN_TRANSIT)
- `transfer_received` (with per-line received_quantity + discrepancies)
- `transfer_partial_received` (when sum diff > 0)
- `transfer_cancelled_before_shipped`
- `transfer_cancelled_in_transit` (with mandatory reason + free-text)
- `transfer_line_discrepancy_recorded` (with TRANSFER_DISCREPANCY sub-reason)

## Correlation

All movements created from a single transfer share `correlation_id = transfer.id`. Per ADR-020 pattern. Enables:
- "Show me all movements from transfer X"
- Reconciliation across source/target ledgers
- Audit log browser correlation drill-down

## Edge cases

| # | Scenario | Behavior |
|---|---|---|
| 1 | Source store stock changes between DRAFT and dispatch | At dispatch: FOR UPDATE check; if insufficient: 409 "Source stock insufficient: variant X has N available"; UI offers reduce quantity or abandon DRAFT |
| 2 | Source store closes between DRAFT and dispatch | Transfer DRAFT orphaned; 409 at dispatch: "Source store closed"; manager deletes DRAFT |
| 3 | Target store closes between dispatch and receive | IN_TRANSIT to closed store; receive blocked: 409 "Target store closed; cancel or reroute" |
| 4 | Variant attributes changed mid-transit | Variant attributes immutable after sale; transfer line stores variant_id snapshot + display_name + SKU |
| 5 | Network drop during dispatch | Idempotency-Key prevents partial state; client retries → same response |
| 6 | Concurrent dispatch (two managers) | Pessimistic lock + idempotency; first wins; second 409 |
| 7 | Receive with all zero quantities | Allowed: "full loss"; all dispatched lines become ADJUSTMENT_OUT with TRANSFER_DISCREPANCY at target; UI warning "Hiç ürün teslim alınmıyor. Tamamı kayıp/hasarlı?" |
| 8 | Receive partial, come back later | Not supported single transfer; whole receive goes to RECEIVED immediately; partial-receive-over-time v1.1+ |
| 9 | Cancel IN_TRANSIT then items arrive | Separate ADJUSTMENT_IN at target with reason OTHER + reference to cancelled transfer |
| 10 | Source/target same store | Rejected with 422 at DRAFT save |

## Layout — LIST view

```
┌─ Inventory Shell > Transferler ───────────────────────────────────┐
│                                                                    │
│  ⌕ [Transfer no, kaynak/hedef mağaza...]      [+ Yeni Transfer]  │
│  Durum: [Tümü ▾]   Kaynak: [Tümü ▾]   Hedef: [Tümü ▾]            │
│  Tarih: [Son 30 gün ▾]                                            │
│                                                                    │
│  ┌─ Transfers table ─────────────────────────────────────────┐   │
│  │ No       │ Durum     │ Kaynak │ Hedef    │ Kalem │Tarih │ │   │
│  ├──────────┼───────────┼────────┼──────────┼───────┼──────┤│   │
│  │ T-2056   │ DRAFT     │Beyoğlu │ Kadıköy  │ 4     │ Bugün││   │
│  │ T-2055   │ DISPATCH  │Beyoğlu │ Beşiktaş │ 12    │ Bugün││   │
│  │ T-2054   │ IN_TRANS. │Kadıköy │ Beyoğlu  │ 8     │ Dün  ││   │
│  │ T-2053   │ RECEIVED  │Beyoğlu │ Kadıköy  │ 10⚠   │ 15/05││   │
│  │ T-2052   │ CANCELLED │Beşiktaş│ Beyoğlu  │ 6     │ 14/05││   │
│  └────────────────────────────────────────────────────────────┘   │
│  ⚠ = discrepancy recorded                                          │
│                                                                    │
└────────────────────────────────────────────────────────────────────┘
```

## Layout — DRAFT create/edit

```
┌─ Yeni Transfer / DRAFT ────────────────────────────────────────────┐
│                                                                     │
│  Kaynak Mağaza:   [Beyoğlu ▾]    Hedef Mağaza: [Kadıköy ▾]        │
│  Not:             [_______________________________]                 │
│                                                                     │
│  ⌕ [SKU veya barkod tara]                                          │
│                                                                     │
│  ┌─ Transfer lines ──────────────────────────────────────────┐    │
│  │ Varyant            │ Kaynak Stok │ Transfer Miktar │       │    │
│  ├────────────────────┼─────────────┼─────────────────┼───────┤    │
│  │ T-100-BLK-S        │ 5 (Beyoğlu) │ [2]             │ [Sil] │    │
│  │ T-shirt/Siyah/S    │             │                 │       │    │
│  ├────────────────────┼─────────────┼─────────────────┼───────┤    │
│  │ T-100-BLK-M        │ 8           │ [3]             │ [Sil] │    │
│  ├────────────────────┼─────────────┼─────────────────┼───────┤    │
│  │ J-450-BLU-32       │ 12          │ [5]             │ [Sil] │    │
│  └────────────────────────────────────────────────────────────┘    │
│                                                                     │
│  Toplam: 3 farklı varyant, 10 adet                                  │
│                                                                     │
│  [Esc İptal]                  [Ctrl+S Kaydet]                       │
│                              [Kaydet ve Sevk Et (Ctrl+Enter)]      │
│                                                                     │
└─────────────────────────────────────────────────────────────────────┘
```

## Layout — RECEIVE mode

```
┌─ Transfer #T-2054 / Teslim Al ─────────────────────────────────────┐
│                                                                     │
│  Durum: IN_TRANSIT                                                  │
│  Kaynak: Kadıköy → Hedef: Beyoğlu                                  │
│  Sevk: 14/05  Beklenen: 16/05                                       │
│                                                                     │
│  ⌕ [Barkod tara → otomatik sayım]                                  │
│  Toplam taranan: 7 / 10                                             │
│                                                                     │
│  ┌─ Lines to receive ────────────────────────────────────────┐    │
│  │ Varyant       │Sevk│Teslim│ Fark │Sebep                  │    │
│  ├───────────────┼────┼──────┼──────┼───────────────────────┤    │
│  │T-100-BLK-S    │ 2  │ [2]  │  0   │ —                     │    │
│  │T-100-BLK-M    │ 3  │ [3]  │  0   │ —                     │    │
│  │J-450-BLU-32   │ 5  │ [3]  │ -2 ⚠ │[LOSS ▾]              │    │
│  └────────────────────────────────────────────────────────────┘    │
│                                                                     │
│  Toplam sevk: 10  Teslim: 8  Eksik: 2 (TRANSFER_DISCREPANCY)      │
│                                                                     │
│  [Esc Kaydetme]                  [Teslim Almayı Tamamla (Enter)]   │
│                                                                     │
└─────────────────────────────────────────────────────────────────────┘
```

## Implementation notes

- State machine enforced via aggregate guard methods
- Idempotency keys via X-Idempotency-Key header (Phase 6.B pattern)
- All state transitions emit outbox events with `correlation_id = transfer.id`
- Receive mode default = full receive (received = dispatched per line)
- Discrepancy reason dropdown appears only when received < dispatched
- Partial-batch-receive (multiple receives per transfer) v1.1+ feature
- "Sevk Et" button confirm modal: "Bu kalemler kaynak stoktan düşürülecek. Devam et?"
- WAC propagation in receive transaction (target WAC recomputed from source's snapshot)
- IN_TRANSIT cancel UI: explicit two-step confirm (modal + retype confirmation)
