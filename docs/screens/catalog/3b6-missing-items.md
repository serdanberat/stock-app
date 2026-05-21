# 3.B.6 — Missing Item Requests

> **Status:** Locked (Phase 3.B)
> **Route:** `/catalog/missing-items`
> **Catalog Shell tab:** "Eksik Bildirimler"

## Purpose

Manager-side intake queue for "ürün bulunamadı" reports submitted from POS (Phase 3.A.2).

Cashier reports missing items from POS; manager reviews, decides:
- Create new product (transitions to 3.B.2 with prefill)
- Dismiss as not needed
- Mark resolved manually

## Aggregate ownership (explicit)

- **Reads** MissingItemRequest aggregate
- **Writes** request status (RESOLVED, DISMISSED)
- On "Create as product": navigates to 3.B.2 with `prefill_from_missing_request={req_id}`; that screen resolves the request upon successful product creation

## Reads

- `POST /catalog/missing-item-requests/search`
  - Body: `{ status?, store_id?, q?, page, page_size }`
  - Returns: id, barcode, description, reported_by_user_name, store_name, created_at, status, resolved_at

## Writes

| Endpoint | Purpose |
|---|---|
| `POST /catalog/missing-item-requests/{id}/dismiss` | Body: `{ dismissal_reason }`; status → DISMISSED |
| `POST /catalog/missing-item-requests/{id}/resolve` | Body: `{ resolution: 'PRODUCT_CREATED' \| 'PRODUCT_EXISTS', product_id? }`; status → RESOLVED |

Auto-resolved when product created via 3.B.2 prefill flow.

## Optimistic UI

- Dismiss: yes (row disappears immediately; rollback if 409)
- Resolve manually: yes

## Locking

None (status changes idempotent via simple state machine).

## Draft autosave

N/A.

## Keyboard flow

| Key | Action |
|---|---|
| `/` | Focus search |
| `↓ / ↑` | Row navigation |
| `Enter` | Open detail (modal or expand) |
| `Ctrl+P` | Create as product (focused row) |
| `Ctrl+X` | Dismiss (focused row, confirm) |

## Barcode flow

Scanner ACTIVE. Scan a barcode:
- If matches existing product → toast "Bu barkod {product} ürününde mevcut" + offer "Bu isteği ilgili ürün olarak işaretle"
- If matches another open request → highlight that row
- If unknown → no action (this isn't a creation screen)

## Speed budget

| Action | p95 target |
|---|---|
| Initial render | < 300ms |
| Status update | < 400ms |
| Navigate to 3.B.2 prefill | < 200ms |

## Permissions

| Permission | Default |
|---|---|
| `catalog.missing_items.view` | STORE_MANAGER+ |
| `catalog.missing_items.resolve` | STORE_MANAGER+ |
| `catalog.missing_items.dismiss` | STORE_MANAGER+ |
| `catalog.products.create` | Required to "Create as product" (separate permission) |

## Status state machine

```
OPEN
  → RESOLVED (via product creation OR manual mark)
  → DISMISSED (not worth creating)
```

No reverse transitions. Reopening v1.1+ if needed.

## Layout

```
┌─ Catalog Shell ───────────────────────────────────────────────────┐
│  [Ürünler]  [Eksik Bildirimler (3)]  [Özellikler]                 │
├───────────────────────────────────────────────────────────────────┤
│                                                                    │
│  ⌕ [Search description or barcode]    Filter: [Açık ▾]            │
│  Show: [Tüm Mağazalar ▾]                                           │
│                                                                    │
│  ┌─ Requests table ───────────────────────────────────────────┐  │
│  │ Bildiren  │ Mağaza   │ Barkod        │ Açıklama       │     │  │
│  ├───────────┼──────────┼───────────────┼────────────────┼────┤  │
│  │ Ayşe Y.   │ Beyoğlu  │ 8690123456789 │ Yeni gelen     │ ⋯ │  │
│  │ 2 saat    │          │               │ jean kahverengi│    │  │
│  ├───────────┼──────────┼───────────────┼────────────────┼────┤  │
│  │ Mehmet K. │ Kadıköy  │ (yok)         │ Kırmızı eşarp  │ ⋯ │  │
│  │ 1 gün     │          │               │ M boy          │    │  │
│  ├───────────┼──────────┼───────────────┼────────────────┼────┤  │
│  │ Selin Ç.  │ Beyoğlu  │ 8690987654321 │ Çocuk T-shirt  │ ⋯ │  │
│  │ 3 gün     │          │               │                │    │  │
│  └─────────────────────────────────────────────────────────────┘  │
│                                                                    │
│  Showing 1-3 of 3 open requests                                    │
│                                                                    │
└────────────────────────────────────────────────────────────────────┘
```

## Row context menu (⋯)

```
┌─ Aksiyon ────────────────────────┐
│ ➕ Yeni ürün olarak oluştur       │
│ ✓  Mevcut ürün olarak işaretle  │
│ ✗  Reddet (uygun değil)          │
└──────────────────────────────────┘
```

## "Yeni ürün olarak oluştur" flow

1. Navigation to `/catalog/products/new?prefill_from_missing_request={req_id}`
2. 3.B.2 opens with:
   - Banner: "Bu ürün şu eksik bildirimden oluşturuluyor: {description}"
   - `code` field empty (suggest button available)
   - `description` field prefilled from request
   - Barcode (if request had one) suggested as base for variant SKU generation
3. On product save success: `POST /catalog/missing-item-requests/{req_id}/resolve` with `{ resolution: 'PRODUCT_CREATED', product_id }`
4. Tab badge count decrements

## "Mevcut ürün olarak işaretle" flow

1. Modal opens with search: "Hangi ürün?"
2. Manager picks existing product
3. `POST /catalog/missing-item-requests/{id}/resolve` with `{ resolution: 'PRODUCT_EXISTS', product_id }`
4. Reasoning: maybe cashier missed it in POS search; product exists but variant barcode was different

## "Reddet" flow

1. Confirm modal: "Bu bildirimi reddet?"
2. Reason dropdown (optional):
   - `DUPLICATE_REQUEST`
   - `NOT_RELEVANT`
   - `WAITING_FOR_SUPPLIER`
3. `POST /catalog/missing-item-requests/{id}/dismiss`

## Edge cases

| # | Scenario | Behavior |
|---|---|---|
| 1 | Cashier reports same barcode twice | Two separate rows; manager may dismiss one as DUPLICATE_REQUEST |
| 2 | Manager creates product, cancels mid-flow in 3.B.2 | Request stays OPEN; banner persists on next visit |
| 3 | Barcode matches existing product | "Mevcut ürün olarak işaretle" flow appropriate |
| 4 | Network error during action | Toast + retry; row stays |
| 5 | Multiple managers acting simultaneously | First action wins; second sees 409 + refresh |

## Audit events

- `missing_item_request_created` — From POS (Phase 3.A.2)
- `missing_item_request_resolved` — With resolution type
- `missing_item_request_dismissed` — With reason

## Implementation notes

- Mantine Table with row context menu
- Tab badge count updates via TanStack Query (refetch on status changes)
- Search uses citext + unaccent + pg_trgm (consistent with Product List)
- Barcode scanner active for matching to existing products
- Banner in 3.B.2 prefill mode visually distinct (yellow background)
