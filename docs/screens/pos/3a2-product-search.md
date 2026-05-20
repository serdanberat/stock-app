# 3.A.2 — Product Search Modal (F1)

> **Status:** Locked (Phase 3.A)
> **Trigger:** F1 from POS Main Sale (3.A.1)

## Purpose

Find a product when barcode scan is impossible: barcode worn off, item without barcode (jewelry pieces), or customer asks about an item not in hand.

## Reads

- `POST /catalog/variants/search`
  - Body: `{ q: text, store_id, in_stock_only: boolean, limit: 20 }`
  - Returns ProductVariants matching: code, name, brand, category, attribute values
  - Server-side trigram + ILIKE on generated `search_text` column

## Writes

On selection, triggers same flow as barcode scan:
1. If pre-cart: `POST /sales` (with `client_cart_id`)
2. Then `POST /sales/{id}/items`

## Optimistic UI

Inherits from 3.A.1 — item appears in cart optimistically. Modal closes immediately on selection.

## Locking

None.

## Keyboard flow

- On open: focus → search input (autofocus)
- Type query → debounced 250ms → search
- ↓/↑: Move highlight in result list
- Enter: Select highlighted (default first row)
- Tab: Move from search → filter chips → result list → close button
- Esc: Close modal, restore POS focus

### Code-talker shortcut

Typing numeric prefix like `123` then Enter, when result list has matching code prefix, jumps to & selects it.

## Barcode flow

**Scanner NEVER suspended.** When modal is open:
1. HID burst detected → preventDefault on keystroke events
2. Modal auto-closes
3. Barcode forwarded to add-item pipeline (same as if modal weren't open)

This matches real cashier behavior: F1 opened to search, then barcode appears in hand, scan immediately.

## Search infrastructure

### Backend index strategy (MVP)

- `citext` extension for case-insensitive
- `unaccent` extension for Turkish character normalization (siyah/SIYAH/Sıyah → same)
- `pg_trgm` extension for trigram fuzzy match
- Generated search column on products and product_variants:
  ```sql
  ALTER TABLE products ADD COLUMN search_text TEXT GENERATED ALWAYS AS (
      lower(unaccent(coalesce(display_name,'') || ' ' || coalesce(code,'')))
  ) STORED;
  CREATE INDEX idx_products_search_text 
      ON products USING GIN (search_text gin_trgm_ops);
  ```
- v1.1+: switch to `tsvector` full-text search if latency P95 > 200ms

### Stale response race protection

- TanStack Query `queryKey: ['products', 'search', query]` versions
- `AbortController` via `signal`: previous request aborted on new query
- `placeholderData: keepPreviousData`: show previous results while loading

### Stock freshness (hybrid pattern)

- Search list shows **approximate stock** from `stock_position_summary` mview (10min stale OK)
- **Fresh check at cart-add time**: server-side validation in `POST /sales/{id}/items`
- Conflict response: 409 with which variant + how much available
- UI graceful degradation: "3 eklendi, 2 eklenemedi" with notification

## Variant display strategy

**Flat list** — every variant is its own row. No expandable hierarchy.

```
T-shirt / Siyah / S          T-100-BLK-S    ₺99    Stok: 0   (greyed)
T-shirt / Siyah / M          T-100-BLK-M    ₺99    Stok: 5
T-shirt / Siyah / L          T-100-BLK-L    ₺99    Stok: 4
T-shirt / Beyaz / S          T-100-WHT-S    ₺99    Stok: 3
Kot Pantolon / Mavi / 30     J-450-BLU-30   ₺450   Stok: 2
```

Rationale: POS = minimum cognitive load + minimum keystrokes. Hierarchy works for catalog management (Phase 3.B); not for POS.

## Default filters

- **"Stokta var" filter ON by default** (sellable items only)
- Toggle OFF available via Tab
- Tenants with `allow_negative_stock=true` override default to OFF

## Speed budget

| Action | p95 target |
|---|---|
| Open modal | < 80ms |
| First search result | < 400ms |
| Subsequent queries | < 250ms |
| Select + close | < 150ms |

## Permissions

`sales.create` (inherited from POS access; modal not reachable otherwise).

## Edge cases

| # | Scenario | Behavior |
|---|---|---|
| 1 | No results | "Sonuç bulunamadı" + "Eksik ürün bildir" button (not "yeni ürün ekle") |
| 2 | Result limit exceeded | Show 20 max; "+ daha fazla" pagination via cursor |
| 3 | Out-of-stock variant selected when filter is ON | Cannot happen (filter excludes) |
| 4 | Network error during search | Inline retry banner, auto-retry every 5s |
| 5 | F1 pressed when modal open | No-op; focus restored to input |
| 6 | Scanner burst while modal open | Auto-close + forward to add-item pipeline |

## "Yeni ürün ekle" — REMOVED from MVP

Removed because:
- Wrong VAT / wrong cost on hasty creation cascades to accounting
- Wrong category breaks reporting forever
- Duplicate products bloat catalog

Replaced with **"Eksik ürün bildir"** (separate Phase 3.B feature):
- Modal: barcode + description text
- Backend: `POST /catalog/missing-item-requests` (separate table)
- Manager dashboard surfaces the request
- Catalog mutation still requires `catalog.products.create` from manager UI

## Layout

```
┌─ Modal (centered, ~70% screen) ─────────────────────────────────┐
│                                                                   │
│   ⌕ [Search input — autofocused — "Ürün ara..."]      [×] close │
│                                                                   │
│   Filters: ☑ Stokta var  [Kategori ▾]  [Marka ▾]  [Sezon ▾]    │
│                                                                   │
│   ┌─ Results (scrollable, virtualized) ──────────────────┐      │
│   │ ▶ T-shirt / Siyah / M    T-100-BLK-M  ₺99  Stok: 5   │      │
│   │   T-shirt / Siyah / L    T-100-BLK-L  ₺99  Stok: 4   │      │
│   │   T-shirt / Beyaz / S    T-100-WHT-S  ₺99  Stok: 3   │      │
│   │   Kot Pantolon Mavi/30   J-450-BLU-30 ₺450 Stok: 2   │      │
│   │   ... (max 20)                                        │      │
│   └──────────────────────────────────────────────────────┘      │
│                                                                   │
│   Bulunamadı?  [+ Eksik ürün bildir]                             │
│                                                                   │
│   [Esc Kapat]    [Enter Seç]    [↑↓ Gezin]                       │
│                                                                   │
└───────────────────────────────────────────────────────────────────┘
```

## Implementation notes

- Mantine Modal with `trapFocus` + `closeOnEscape`
- Search input: TextInput with leftIcon
- Debounce via `@mantine/hooks` `useDebouncedValue`
- Result list virtualized via TanStack Virtual
- Each result row is a button (a11y), keyboard navigable
- "Stokta var" filter uses `store_id` from current register session
