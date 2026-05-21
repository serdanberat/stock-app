# 3.B.4 — Pricing Screen

> **Status:** Locked (Phase 3.B)
> **Route:** `/catalog/products/{productId}/pricing`

## Purpose

Answer: "Bu ürün şu mağazada kaçtan satılıyor?"

Set sale prices per variant. Optional per-store override. Display (NOT edit) cost for margin awareness.

**NOT for**: customer tiers, future scheduling, multi-currency, campaigns, wholesale/VIP. All deferred to v1.1+.

## Aggregate ownership (explicit)

- **Writes** Pricing aggregate (`variant_prices`)
- **Reads** (does NOT write):
  - Cost from `stock_balances.weighted_avg_cost` (Inventory) or fallback `purchase_invoice_lines` (Purchasing)
  - Product master for header

Cost field is read-only by design. Cost source disclosed via tooltip. Cost changes flow through Purchase invoice (3.D) or Stock adjustment (3.C).

## Reads

- `GET /catalog/products/{id}` — Header context
- `GET /catalog/products/{id}/variants` — Active variants
- `GET /pricing/products/{id}` — Per-variant pricing:
  - `variant_id, variant_sku, variant_display_name`
  - `base_price`
  - `store_overrides: [{ store_id, store_name, override_price }]`
  - `cost_snapshot: { source: 'WAC'|'LAST_PURCHASE'|'NONE', amount, captured_at }`
- `GET /stores` — Override picker

## Writes

| Endpoint | Purpose |
|---|---|
| `PATCH /pricing/variants/{variantId}` | Body: `{ base_price?, store_override?: {store_id, price} \| null }` |
| `POST /pricing/products/{id}/apply-base-to-all` | Bulk apply base to all variants; preserves overrides |
| `GET /pricing/variants/{variantId}/last-change` | Single-step history (tooltip) |

`effective_from = now()` implicit (no scheduling MVP).

## Optimistic UI

- Per-row base price edit: Yes (3-state visual feedback)
- Store override edit: Yes
- Bulk apply-base-to-all: NO (confirm modal, server roundtrip)

## Auto-commit visual feedback (3 states)

1. User types → "idle" state with "değişiklik var" badge
2. Blur or 400ms debounce passes → "Kaydediliyor..." with spinner
3. Server confirms → ✓ green flash 400ms, then idle
4. (Within 5sn after success): "↶ Geri al" inline link

## Inline "Geri Al" mini-action

- Appears after successful save, 5sn window
- Shows previous value
- Click → restores previous value via new PATCH
- Audit event: `variant_price_change_reverted`
- Client-side only; expires on page reload (no backend tracking)

## Locking

Optimistic version per `variant_price` row.

## Draft autosave

Per-row inline edit: server commit on blur (debounced 400ms). No explicit Save.

## Keyboard flow

| Key | Action |
|---|---|
| Tab | top-level base input → "Tümüne Uygula" → row 1 base → row 1 override → row 2 ... |
| `Enter` on base | Commit + move to next variant's base |
| `Esc` | Revert in-progress edit |
| `Ctrl+Enter` | Commit + move to override field |
| `/` | Focus search/filter |

## Barcode flow

Scanner ACTIVE. Scan → row highlight + scroll-to + focus base price input of that row.

Use case: manager walks floor with scanner, finds physical price tag mismatch, scans tag, updates price inline.

## Speed budget

| Action | p95 target |
|---|---|
| Initial render (20 variants) | < 400ms |
| Per-row price commit | < 400ms |
| Bulk apply-base-to-all | < 1s |
| Cost projection load | < 200ms |

## Permissions

| Permission | Default |
|---|---|
| `pricing.edit` | STORE_MANAGER+ |
| `pricing.view_cost` | STORE_MANAGER, ACCOUNTANT, SUPER_ADMIN |
| `pricing.set_store_override` | STORE_MANAGER (own store); SUPER_ADMIN (any) |

## Effective price invariant (domain rule, explicit)

```
effective_price(variant_id, store_id, T) =
    COALESCE(
        store_override_price(variant_id, store_id, T),
        base_price(variant_id, T)
    )
```

- When store_override removed: fallback to base_price
- When base_price changes: variants WITHOUT override automatically inherit; variants WITH override remain at override price
- Override removal is explicit (DELETE), not "set to base" (preserves auditability)

See ADR-018 — Pricing Resolution Strategy.

## Cost source disclosure (read-only with ℹ tooltip)

### WAC source

> "Bu maliyet, ağırlıklı ortalama maliyet (WAC) yöntemiyle hesaplanmıştır. Son güncelleme: {timestamp}. Maliyet, alış işlemleri ve stok ayarlamalarına göre otomatik güncellenir."

### LAST_PURCHASE source

> "Bu maliyet, son alış faturasından alınmıştır. Fatura: {invoice_no}, Tarih: {date}. WAC henüz hesaplanmamış (yeni ürün)."

### NONE source

> "Bu varyant için henüz alış kaydı yok. Maliyet bilinmiyor."

## Markup display (when cost known + permission)

Shown next to base price: **"Markup: ₺X (%Y)"**

Calculation: `(price - cost) / cost × 100`

Color hint:
- < 10% red (warning)
- 10-30% amber
- \> 30% green

Tooltip:
> "Markup = (Satış - Maliyet) / Maliyet. KDV hariç maliyete göre hesaplanır."

## Below-cost protection

Price < cost on commit:
1. UI shows warning banner: "Bu fiyat maliyetin altında. Sebep gerekli:"
2. Reason dropdown (closed set, mandatory):
   - `CLEARANCE` — Stok tasfiyesi
   - `DAMAGED` — Hasarlı
   - `PROMOTION` — Promosyon
   - `PRICE_MATCH` — Rakip eşleştirme
   - `MANUAL_OVERRIDE` — Manuel
3. Server stores `variant_prices.below_cost_reason` field
4. Audit event `price_set_below_cost` with reason

No hard block. Manager can sell at loss intentionally (clearance).

## Layout — main view

```
┌─ Catalog Shell > Product Edit > Pricing ──────────────────────────┐
│  [← Geri to Product]    T-shirt Basic / Fiyatlandırma             │
│  Sub-nav: [Varyantlar] [Fiyatlandırma]                            │
├───────────────────────────────────────────────────────────────────┤
│                                                                    │
│  ┌─ Top-level base price ───────────────────────────────────┐    │
│  │ Tüm varyantlar için temel fiyat:                          │    │
│  │ [₺ 99,00]    [Tüm Varyantlara Uygula]                    │    │
│  │                                                            │    │
│  │ Uygulayınca: mevcut mağaza-özel fiyatlar korunur.         │    │
│  └────────────────────────────────────────────────────────────┘    │
│                                                                    │
│  ⌕ [Variant ara]              Mağaza override: [Tüm Mağazalar ▾] │
│                                                                    │
│  ┌─ Variants pricing table ──────────────────────────────────┐   │
│  │ SKU       │ Renk/Beden │ Maliyet*│ Satış      │ Markup   │   │
│  ├───────────┼────────────┼─────────┼────────────┼──────────┤   │
│  │T-100-BLK-S│ Siyah / S  │ ℹ₺60    │ [₺ 99,00]  │ ₺39 (%65)│   │
│  │           │            │         │ Toplu       │          │   │
│  ├───────────┼────────────┼─────────┼────────────┼──────────┤   │
│  │T-100-BLK-M│ Siyah / M  │ ℹ₺60    │ [₺ 99,00]  │ ₺39 (%65)│   │
│  │           │            │         │ Toplu       │          │   │
│  ├───────────┼────────────┼─────────┼────────────┼──────────┤   │
│  │T-100-XXL  │ Siyah / XXL│ ℹ₺65    │ [₺ 110,00] │ ₺45 (%69)│   │
│  │           │            │         │ Özel        │          │   │
│  ├───────────┼────────────┼─────────┼────────────┼──────────┤   │
│  │T-100-WHT-S│ Beyaz / S  │ ℹ Yok   │ [₺ 99,00]  │ —        │   │
│  │           │            │         │ Toplu       │          │   │
│  └───────────────────────────────────────────────────────────┘   │
│                                                                    │
│  * Maliyet read-only. Hesaplama kaynağı için ℹ üzerine gel.       │
│                                                                    │
│  ┌─ Store overrides (collapsed by default) ──────────────────┐   │
│  │ ▶ Mağaza-özel fiyatlar (2 varyantta override var)         │   │
│  └────────────────────────────────────────────────────────────┘   │
│                                                                    │
└────────────────────────────────────────────────────────────────────┘
```

## Store override expanded view

```
┌─ Mağaza-özel fiyatlar ────────────────────────────────────────────┐
│                                                                     │
│  Variant: T-100-BLK-S                                                │
│  Temel fiyat: ₺ 99,00                                                │
│                                                                     │
│  Mağaza     │ Fiyat        │ Aksiyon                                │
│  Beyoğlu    │ [₺ 99,00]    │ (toplu — override yok)                │
│  Kadıköy    │ [₺ 105,00]   │ [Override Kaldır]                     │
│  Beşiktaş   │ [₺ —]        │ [+ Override Ekle]                     │
│                                                                     │
└─────────────────────────────────────────────────────────────────────┘
```

## Last-change tooltip (single-step history MVP)

On info icon hover over price field:

```
ℹ Son güncelleme
  2 gün önce, Ayşe Yılmaz tarafından
  Önceki fiyat: ₺95,00
```

API: `GET /pricing/variants/{variantId}/last-change` → `{ previous_price, changed_at, changed_by_user_name }`

Full audit log surface UI v1.1+.

## Edge cases

| # | Scenario | Behavior |
|---|---|---|
| 1 | Variant 0 cost (no purchase history) | Markup column "—"; cost cell tooltip "Alış kaydı yok" |
| 2 | Price < cost | Warning toast + reason dropdown mandatory; audit event with reason |
| 3 | Bulk "Tüm Varyantlara Uygula" with existing overrides | Confirm modal explains: overrides preserved |
| 4 | Negative price input | Client blocks (NumberInput min=0); server 422 |
| 5 | Override price == base price | Allowed; warning "Bu override temel fiyatla aynı, anlamlı mı?"; suggests remove |
| 6 | Variant deactivated mid-edit | Greyed row; edit succeeds (affects future reactivation) |
| 7 | Currency mismatch (multi-currency v1.1+) | MVP: TRY only; no picker |
| 8 | Search deactivated variant | Excluded default; "Pasif varyantlar dahil" checkbox |
| 9 | Concurrent base price edit | 409; "Başka kullanıcı güncelledi. Yenile?" |
| 10 | Cross-store override permission | Manager from Store X cannot edit Store Y override; UI hidden |

## Audit events

- `variant_base_price_changed`
- `variant_store_override_added`
- `variant_store_override_changed`
- `variant_store_override_removed`
- `variant_price_change_reverted` ("Geri Al" used)
- `bulk_base_price_applied` (product_id, new_price, affected_count)
- `price_set_below_cost` (variant_id, price, cost, reason_code)

## Implementation notes

- Inline editing via Mantine NumberInput in cell
- Currency display: `Intl.NumberFormat('tr-TR', { style: 'currency', currency: 'TRY' })`
- Markup calculation via Dinero.js (precise decimal)
- Cost reads from `stock_position_summary` mview for WAC; fallback direct query on `purchase_invoice_lines` if no WAC yet
- "Toplu" vs "Özel" badge: simple text label
- Store override section collapsed by default
- Bulk apply confirm modal lists affected count
- Resolution algorithm reusable across Phase 3.C/D: see ADR-018
