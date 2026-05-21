# 3.C.2 — Stock Movement History

> **Status:** Locked (Phase 3.C)
> **Route:** `/inventory/movements`
> **Inventory Shell tab:** "Hareketler"

## Purpose

Append-only ledger of stock movements. Filterable by variant, store, date, movement type. Read-only.

This is the audit trail. Every stock change has exactly one movement row. Reconstruction of any past stock state is possible by replaying movements.

## Invariants (explicit)

- Movement rows are immutable
- `resulting_balance_at_movement` is a historical snapshot at that moment; NO retroactive recalculation when later movements arrive
- No edit/delete endpoints exist (enforced at DB trigger via Phase 2D `prevent_audit_mutation()`)

## Aggregate ownership (explicit)

- **Reads** `stock_movements` (Inventory aggregate, append-only ledger)
- **Reads** ProductVariant for display_name (Catalog ctx)
- NO write operations available from this screen

## Reads

- `POST /inventory/movements/search`
  - Body: `{ store_id?, variant_id?, movement_type?, correlation_id?, date_from?, date_to?, sort, page, page_size }`
  - Returns paginated movements:
    - id, occurred_at
    - variant_id, sku, display_name
    - store_id, store_name
    - movement_type (enum)
    - quantity (signed: positive=IN, negative=OUT)
    - resulting_balance_at_movement
    - **movement_wac_snapshot** (renamed from cost_at_movement for clarity — WAC at the time of movement)
    - reference: `{ type: 'SALE'|'PURCHASE'|'TRANSFER'|..., id, display_label }`
    - **correlation_id** (links related movements: transfer pair, sale completion, return reconciliation, count session)
    - actor_user_id, actor_user_name
    - reason_code (for ADJUSTMENT_* and COUNT_CORRECTION types)
    - free_text_reason (for OTHER adjustment reason)

## Writes

None. Append-only ledger; no mutations from this screen.

## Keyboard flow

| Key | Action |
|---|---|
| `/` or `Ctrl+K` | Focus search |
| `↓ / ↑` | Row navigation |
| `Enter` | Open movement detail panel |
| `Esc` | Close detail |

## Barcode flow

Scanner active. Scan → filter set to that variant_id automatically.

## Speed budget

| Action | p95 target |
|---|---|
| Initial render | < 300ms |
| Search query | < 400ms |
| Date-range query (90d) | < 600ms p95 |

## Permissions

| Permission | Default |
|---|---|
| `inventory.movements.view` | STORE_MANAGER+, ACCOUNTANT+, AUDITOR+ |
| `inventory.movements.view_cost` | STORE_MANAGER+, ACCOUNTANT+ |

## Movement type display

Color/icon per type for fast scanning:

| Type | Icon | Label | Sign |
|---|---|---|---|
| PURCHASE_IN | 🟢 | Alış | +qty (green) |
| SALE_OUT | 🔵 | Satış | -qty (blue) |
| TRANSFER_OUT | 🟠 | Transfer Çıkış | -qty (orange) |
| TRANSFER_IN | 🟠 | Transfer Giriş | +qty (orange) |
| ADJUSTMENT_IN | 🟡 | Düzeltme + | +qty (yellow) |
| ADJUSTMENT_OUT | 🟡 | Düzeltme - | -qty (yellow) |
| RETURN_IN | 🟣 | İade | +qty (purple) |
| COUNT_CORRECTION | 🔶 | Sayım Düzeltme | ±qty (orange-red) |

## Layout

```
┌─ Inventory Shell > Hareketler ────────────────────────────────────┐
│                                                                    │
│  ⌕ [SKU, barkod veya referans...]                                 │
│  Mağaza: [Beyoğlu ▾]   Tip: [Tümü ▾]                              │
│  Tarih: [Son 30 gün ▾]    [Filter ▾]   Correlation: [_______]    │
│                                                                    │
│  ┌─ Movements ledger ────────────────────────────────────────┐   │
│  │ Tarih        │ Varyant       │ Tip      │  Miktar │Kalan│ │   │
│  ├──────────────┼───────────────┼──────────┼─────────┼─────┤│   │
│  │ 16/05 14:32  │ T-100-BLK-S   │ 🔵 Satış │  -2     │ 3   ││   │
│  │ 16/05 14:32  │ J-450-BLU-32  │ 🔵 Satış │  -1     │ 7   ││   │
│  │ 16/05 11:08  │ T-100-WHT-S   │ 🟠 Trans →│  -5    │ 2   ││   │
│  │ 16/05 10:45  │ J-450-BLU-32  │ 🟢 Alış  │ +10     │ 18  ││   │
│  │ 15/05 17:21  │ T-100-RED-S   │ 🟡 Düz - │  -2     │ 0   ││   │
│  │              │               │ Sebep: DAMAGE                  ││   │
│  │ 15/05 09:00  │ T-100-BLK-S   │ 🔶 Sayım │  +1     │ 5   ││   │
│  │ 14/05 16:30  │ T-100-BLK-S   │ 🟣 İade  │  +1     │ 4   ││   │
│  └────────────────────────────────────────────────────────────┘   │
│                                                                    │
│  Showing 1-30 of 1248       [< Prev]  Page 1 of 42  [Next >]      │
│                                                                    │
└────────────────────────────────────────────────────────────────────┘
```

## Detail panel

```
┌─ Movement Detail ──────────────────────────────────────────────┐
│  Tarih:           16 Mayıs 2026, 14:32:18                       │
│  Tip:             🔵 Satış (SALE_OUT)                            │
│  Varyant:         T-100-BLK-S / T-shirt / Siyah / S             │
│  Mağaza:          Beyoğlu                                        │
│  Miktar:          -2 adet                                        │
│  Hareket sonrası: 3 adet                                         │
│  WAC snapshot:    ₺ 60,00 (movement anındaki)                    │
│                                                                  │
│  Referans:                                                       │
│  Satış #2026-1234                                                │
│  [Satışa Git →]                                                  │
│                                                                  │
│  Correlation ID:  TX-ab12-3f45...                                │
│  [Bu correlation'ı gör →]   (drills to all related events)      │
│                                                                  │
│  Aktör:           Ayşe Yılmaz (kasiyer)                          │
│                                                                  │
│  Movement ID: 8f3a... (audit)                                    │
│                                                                  │
└────────────────────────────────────────────────────────────────┘
```

## Edge cases

| # | Scenario | Behavior |
|---|---|---|
| 1 | Large date range query | Server caps at 10000 results; UI hint "daha dar tarih seç" |
| 2 | Variant deleted (impossible: soft only) | SKU and display_name preserved in movement row; "Pasif" badge |
| 3 | Reference resolution fails (e.g. sale was reversed) | Display "Referans: Satış #X (iptal edilmiş)" with link to reversal record |
| 4 | Movement reason includes free-text (OTHER) | Truncated inline; full in detail panel |
| 5 | Reconstruction request: "stock balance on date X?" | v1.1+ feature; replays movements up to date |
| 6 | Correlation_id click | Filters to all movements + audit events sharing same correlation |

## Implementation notes

- No deletion or editing endpoints (append-only enforced at DB)
- Sort: occurred_at DESC default
- Index on (store_id, occurred_at DESC) + (variant_id, occurred_at) + (correlation_id)
- Reference link clickable for navigation to source aggregate
- Detail panel: Mantine Drawer
- Export to CSV: v1.1+ (deferred; accountant request)
- correlation_id pattern: shared across transfer pairs, sale + payment + receipt, return + exchange + refund (see ADR-020)
