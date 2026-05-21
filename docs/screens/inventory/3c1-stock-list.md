# 3.C.1 — Stock List

> **Status:** Locked (Phase 3.C)
> **Route:** `/inventory/stock`
> **Inventory Shell tab:** "Stok Durumu" (default)

## Purpose

Authoritative answer to "Bu mağazada hangi variantımdan kaç tane var?" Read-only. Adjustments go through 3.C.5 (intentional friction).

This is the authoritative source. Other screens (3.B.1 Product List, POS) show projection of this data. UI must signal authority status.

## Aggregate ownership (explicit)

- **Reads** `stock_balances` (Inventory aggregate, authoritative)
- **Reads** ProductVariant for SKU/display_name (Catalog ctx; cached field)
- Does NOT compute aggregations across stores client-side (server-paged)

## Inventory Shell pattern

`/inventory/*` shell hosts:

```
├─ Stok Durumu          (3.C.1)  default
├─ Stok Hareketleri     (3.C.2)
├─ Transferler          (3.C.3)
├─ Sayım                (3.C.4)
└─ Düzeltme             (3.C.5)
```

## Granularity

Per (variant_id, store_id) row. Each row = one cell in the global stock matrix. Default filter: current logged-in user's primary store.

## Reads

- `POST /inventory/stock-balances/search`
  - Body: `{ store_id?, product_id?, variant_id?, q?, min_quantity?, max_quantity?, only_low_stock?, only_negative?, sort, page, page_size }`
  - Returns paginated rows:
    - variant_id, sku, display_name, barcode
    - store_id, store_name
    - quantity_on_hand
    - quantity_reserved (placeholder; v1.1+; always 0 MVP)
    - quantity_in_transit_inbound (sum of IN_TRANSIT transfers TO this store)
    - quantity_in_transit_outbound (sum of IN_TRANSIT transfers FROM this store)
    - quantity_available = on_hand - reserved
    - weighted_avg_cost
    - last_movement_at
    - low_stock_threshold
    - is_synthetic (true for zero-stock synthetic rows; useful for sorting/export)

## Writes

None. Read-only by design.

Navigation actions only:
- "Stok Düzeltmeye Git" → `/inventory/adjustments/new?prefill_variant={variantId}&prefill_store={storeId}`
- "Hareket Geçmişi" → `/inventory/movements?variant_id=&store_id=`
- "Transfer Başlat" → `/inventory/transfers/new?source_store_id=...&prefill_variant=...`

## Keyboard flow

| Key | Action |
|---|---|
| `/` or `Ctrl+K` | Focus search |
| `↓ / ↑` | Move row focus |
| `Enter` | Open row detail panel (slide-in) |
| `Ctrl+A` | Go to Adjustment with this variant prefilled |
| `Ctrl+H` | Go to Movement History filtered by row |
| `Ctrl+T` | Start Transfer with this variant + store |
| `PgDn / PgUp` | Pagination |
| `Esc` | Close detail panel |

## Barcode flow

Scanner ACTIVE for STORE_MANAGER and STOCK_CLERK.

- Scan resolves variant.barcode → highlight row in current store filter
- If variant not in current-filter store: scroll-to + display warning "Bu varyant {store_name} mağazasında bulunmuyor (filtreyi kaldır)"

## Speed budget

| Action | p95 target |
|---|---|
| Initial render | < 300ms |
| Search query | < 400ms |
| Page change | < 250ms |
| Row detail open | < 100ms (data already loaded) |

## Permissions

| Permission | Default role |
|---|---|
| `inventory.stock.view` | All roles except CASHIER |
| `inventory.stock.view_cost` | STORE_MANAGER+, ACCOUNTANT+ |
| `inventory.stock.view_all_stores` | SUPER_ADMIN; STORE_MANAGER limited to assigned stores |

CASHIER: no inventory route access; redirects to /pos.

## Edge cases

| # | Scenario | Behavior |
|---|---|---|
| 1 | Variant exists in catalog but never had stock movement | Server returns synthetic row with quantity=0 + `is_synthetic:true` flag |
| 2 | Variant deactivated but has stock | Row visible with greyed badge "Pasif Varyant"; stock visible for visibility |
| 3 | Store closed but has stock | Row visible; banner at top "Bu mağaza kapatıldı; stok burada kaldı; transfer veya adjustment gerekli" |
| 4 | Negative quantity (allow_negative_stock=true tenant) | Row shows red "-3" with warning icon; "only_negative" filter shows all for cleanup |
| 5 | Movement happened in another session during view | TanStack Query staleTime 30s; refetch on filter change; "Projection güncellemesi: 2 dk önce" indicator |
| 6 | Manager from Store X tries to view Store Y | Permission `inventory.stock.view_all_stores` absent; Store filter limited |

## Layout

```
┌─ Inventory Shell ─────────────────────────────────────────────────┐
│  [Stok Durumu]  [Hareketler]  [Transferler]  [Sayım]  [Düzeltme] │
├───────────────────────────────────────────────────────────────────┤
│                                                                    │
│  ⌕ [SKU, ad veya barkod...]                                       │
│  Mağaza: [Beyoğlu ▾]   Ürün: [Tümü ▾]   [Filter ▾]               │
│  Active: [Düşük Stok ×]                                            │
│                                                                    │
│  Projection güncellemesi: 2 dk önce                  [⟳ Yenile]   │
│                                                                    │
│  ┌─ Stock Balances Table ────────────────────────────────────┐   │
│  │ SKU         │ Varyant         │ Mağaza  │ El │Yolda│Müsait│   │
│  ├─────────────┼─────────────────┼─────────┼────┼─────┼──────┤   │
│  │T-100-BLK-S  │T-shirt/Siyah/S  │Beyoğlu  │  5 │  0  │  5   │   │
│  │T-100-BLK-M  │T-shirt/Siyah/M  │Beyoğlu  │  8 │  3  │  8 ⓘ │   │
│  │T-100-BLK-L  │T-shirt/Siyah/L  │Beyoğlu  │  4 │  0  │  4   │   │
│  │T-100-RED-S  │T-shirt/Kırmızı/S│Beyoğlu  │  0 │  5  │  0 ⚠ │   │
│  │J-450-BLU-32 │Jean/Mavi/32     │Beyoğlu  │ -3 │  0  │ -3 ❗│   │
│  └────────────────────────────────────────────────────────────┘   │
│                                                                    │
│  Legend: ⓘ Yoldaki dahil değil   ⚠ Düşük stok   ❗ Negatif         │
│                                                                    │
│  Showing 1-20 of 87       [< Prev]  Page 1 of 5  [Next >]          │
│                                                                    │
└────────────────────────────────────────────────────────────────────┘
```

### Column behaviors

| Column | Behavior |
|---|---|
| SKU | Monospace; scanner-friendly |
| Varyant | display_name (cached); ellipsis if long |
| Mağaza | store_name; filterable |
| El (on_hand) | Quantity physically in store; authoritative |
| Yolda | quantity_in_transit_inbound (sum of IN_TRANSIT TO this store) |
| Müsait | = on_hand - reserved (MVP: reserved=0 always); color: red if ≤ low_stock_threshold; bold red if < 0 |

## Detail panel (row click)

```
┌─ Detail Panel ─────────────────────────────────────────────────┐
│  T-100-BLK-S  /  T-shirt / Siyah / S                            │
│  Mağaza: Beyoğlu                                                 │
│  ──────────────────                                              │
│  El (on hand):       5 adet                                      │
│  Müsait:             5 adet                                      │
│  Yolda Gelen:        0 adet                                      │
│  Yolda Giden:        2 adet (→ Kadıköy)                         │
│                                                                  │
│  Ortalama maliyet:   ₺ 60,00 (WAC)                               │
│  Toplam değer:       ₺ 300,00                                    │
│                                                                  │
│  Son hareket:        2 gün önce, satış                           │
│  Düşük stok eşiği:   3                                           │
│                                                                  │
│  Aksiyonlar:                                                     │
│  [Hareket Geçmişi]  [Stok Düzeltmeye Git]  [Transfer Başlat]   │
│                                                                  │
└────────────────────────────────────────────────────────────────┘
```

## Authority disclosure

Top of screen, persistent badge:

```
"Projection güncellemesi: 2 dk önce"
```

This screen reads the authoritative `stock_balances` table but the table itself is projection-backed (outbox event consumers update from movements). MVP staleness window ~1-2s under normal load. "Projection güncellemesi" wording is precise: not "authoritative real-time" but "authoritative projection".

## Implementation notes

- Mantine Table; not virtualized at 20/page
- URL params reflect filters (deeplinkable)
- TanStack Query staleTime 30s for stock_balances
- Auto-refetch on window focus
- "Last updated" timestamp from query.dataUpdatedAt
- Detail panel: Mantine Drawer (right slide-in)
- Inline edit DISABLED at every level (no quantity input field)
- "Stok Düzeltmeye Git" button navigates with variant prefilled, NOT inline edit
- Store filter limited to user's accessible stores via permissions
- Synthetic rows flagged for analytics/export consumers (sorting deterministic)
