# 3.B.1 — Product List

> **Status:** Locked (Phase 3.B)
> **Route:** `/catalog/products`
> **Catalog Shell tab:** "Ürünler" (default)

## Purpose

Catalog management entry point. Search, browse, filter products. Quick "ürün hala stoklu mu, hangi mağazada var?" answers.

NOT for inventory operations. Stock numbers shown are read-only projection references; actual stock management lives in Inventory shell (3.C).

## Aggregate ownership (explicit)

- **Reads** Product aggregate (catalog identity)
- **Reads** variant_count from ProductVariant aggregate
- **Reads** total stock from `stock_position_summary` mview (Inventory ctx — projection, 10min stale)
- **Does NOT read** prices here (Pricing ctx — accessed via 3.B.4)

UI must NOT collapse these. Product row shows: identity, taxonomy, variant count, total stock, is_active. NOT price.

## Reads

- `POST /catalog/products/search`
  - Body: `{ q, category_id?, brand_id?, season_id?, is_active?, has_low_stock?, sort, page, page_size }`
  - Returns paginated list: id, code, display_name, brand_name, category_name, variant_count, total_stock_across_stores, low_stock_variant_count, is_active, discontinued_at, photo_url, created_at, updated_at
- `GET /catalog/brands`, `GET /catalog/categories`, `GET /catalog/seasons` — filter dropdowns; Caffeine cached 5min

## Writes

- `POST /catalog/products/{id}/deactivate`
  - Sets `is_active=false`, `discontinued_at=now()`
  - Server validates: no pending orders, no DRAFT sales referencing
  - Stock unaffected; existing units remain sellable
- `POST /catalog/products/{id}/reactivate`

No bulk actions MVP. Per-row only.

## Optimistic UI

- Deactivate / reactivate: yes (row badge updates immediately, rollback on failure)
- Search / filter: no (data-driven, awaits server)

## Locking

None on read.

## Draft autosave

N/A (read-only screen).

## Keyboard flow

| Key | Action |
|---|---|
| `/` | Focus search input |
| `Ctrl+K` | Focus search input |
| `Ctrl+N` | New product (→ 3.B.2 blank form) |
| `↓ / ↑` | Move row focus |
| `Enter` | Open focused product (→ 3.B.2 edit) |
| `Ctrl+E` | Edit focused product |
| `Ctrl+D` | Deactivate focused (confirm modal) |
| `Esc` | Clear search if focused |
| `PgDn / PgUp` | Page through results |

## Barcode flow

Scanner ACTIVE for STORE_MANAGER and STOCK_CLERK roles.

- User scans → server resolves via variant.barcode → product_id
- Auto-navigates to `/catalog/products/{id}/edit` (3.B.2)
- If not found: toast "Barkod bulunamadı"
- CASHIER cannot access this route at all (redirects to /pos)

Use case: manager walks floor with scanner, finds physical item, instantly opens catalog entry.

## Speed budget

| Action | p95 target |
|---|---|
| Initial render | < 300ms |
| Search/filter query | < 400ms |
| Row open (route transition) | < 200ms |
| Deactivate confirm | < 300ms |

## Permissions

| Permission | Default role |
|---|---|
| `catalog.products.view` | All except CASHIER |
| `catalog.products.create` | STORE_MANAGER and above |
| `catalog.products.edit` | STORE_MANAGER and above |
| `catalog.products.deactivate` | STORE_MANAGER and above |

CASHIER role redirects to /pos on this route.

## Edge cases

| # | Scenario | Behavior |
|---|---|---|
| 1 | Empty catalog (new tenant) | Empty state with `[+ İlk Ürünü Ekle]` CTA |
| 2 | Search yields zero results | "Sonuç bulunamadı"; suggest filter clear; "+ Yeni Ürün Ekle" inline |
| 3 | Product has variants, zero stock | Row shows "Stok: 0"; remains active; "Stokta yok" filter excludes |
| 4 | Product deactivated with stock | Greyed row + "Pasif" badge; existing units still sellable |
| 5 | Concurrent edit by another user | Stale list until refresh; TanStack staleTime 30s; filter triggers refetch |
| 6 | Scanner barcode under deactivated product | Navigation succeeds; 3.B.2 opens with prominent "Pasif" badge + reactivate option |

## Layout

```
┌─ Catalog Shell ───────────────────────────────────────────────────┐
│  [Ürünler]  [Eksik Bildirimler (3)]  [Özellikler]    ← tab nav    │
├───────────────────────────────────────────────────────────────────┤
│                                                                    │
│  Top bar:                                                          │
│  ⌕ [Search: ad, kod, barkod...]    [Filter ▾]      [+ Yeni Ürün] │
│                                                                    │
│  Active filters: [Kategori: T-shirt ×]  [Marka: Polo ×]  [Aktif ×]│
│                                                                    │
│  ┌─ Table ─────────────────────────────────────────────────────┐ │
│  │ Foto │ Kod    │ Ad           │ Marka │ Kategori │Vary│TplStk│ │
│  ├──────┼────────┼──────────────┼───────┼──────────┼────┼──────┤│
│  │ [📷] │ T-100  │ T-shirt Basic│ Polo  │ T-shirt  │ 8  │ 24 ℹ │ │
│  │ [📷] │ J-450  │ Kot Pantolon │ Mavi  │ Pantolon │ 12 │ 38 ℹ │ │
│  │ [📷] │ S-200  │ Sweater Long │ Polo  │ Sweater  │ 6  │  0 ⚠ │ │
│  │ [📷] │ A-090  │ Bilezik 2024 │ Bizou │ Aksesuar │ 1  │ 12 ℹ │ │
│  └────────────────────────────────────────────────────────────────┘│
│                                                                    │
│  Showing 1-20 of 87       [< Prev]  [Page 1 of 5]  [Next >]       │
│                                                                    │
│  Per page: [20 ▾]                                                  │
│                                                                    │
└────────────────────────────────────────────────────────────────────┘
```

### Column behaviors

| Column | Behavior |
|---|---|
| Foto | 32×32 thumbnail or placeholder icon |
| Kod | Product code (monospace, scanner-friendly) |
| Ad | display_name; ellipsis if too long |
| Marka | brand_name or "Markasız"; clickable filter chip |
| Kategori | category_name; clickable filter chip |
| Vary | variant_count; click → 3.B.3 directly |
| **Toplam Stok** | Sum across stores; red ⚠ if low; ℹ tooltip explains projection nature |

### Tooltip on "Toplam Stok" column header

```
Tüm mağazalardaki toplam yaklaşık stok.
Gerçek mağaza-bazlı stok için Stok ekranına gidin.
```

## Filter modal

```
┌─ Filtrele ──────────────────────────────────┐
│  Aktif:        [Evet ▾]                      │
│  Kategori:     [Tümü ▾]                      │
│  Marka:        [Tümü ▾]                      │
│  Sezon:        [Tümü ▾]                      │
│  Düşük stok:   ☐                             │
│  Stok > 0:     ☐                             │
│                                                │
│  [Sıfırla]  [Kapat]  [Uygula]                │
└────────────────────────────────────────────────┘
```

## Row interactions

- Click anywhere on row → 3.B.2 edit
- Right-click row → context menu: Edit / Deactivate / Copy ID
- Hover row → highlight, show actions on right

## Implementation notes

- Mantine Table or DataTable; not virtualized at 20/page
- URL query params reflect filters (deeplink + back/forward navigation)
- TanStack Query keyed by `[products, search, filters, page]`
- Barcode scanner via global `useBarcodeScanner` hook (scoped to /catalog/products route)
- Deactivate confirm: "Bu ürünü pasife al? Stok kalırsa satılmaya devam edebilir."
- Projection-vs-authority disclosure applies to all stock-related columns across Phase 3
