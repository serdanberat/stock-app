# 3.D.2 — Purchase Invoice Create / Edit

> **Status:** Locked (Phase 3.D)
> **Routes:**
> - `/finance/purchase-invoices/new` — Create
> - `/finance/purchase-invoices/{id}` — Edit/view

## Purpose

Enter supplier invoices. Commit atomically applies: stock IN, WAC update, supplier debt entry. Largest financial operation in Purchasing context.

## Aggregate ownership (explicit)

- **Writes** PurchaseInvoice aggregate
- On commit, indirectly via outbox event consumers:
  - `stock_movements` with PURCHASE_IN per line
  - `stock_balances` FOR UPDATE; quantity_on_hand += line.quantity; weighted_avg_cost recomputed via WAC formula
  - `account_movements` at supplier (debt INCREASE for net total)
  - `supplier_accounts` projection updated

## WAC formula (store-level, per variant)

```
new_WAC = ((old_qty × old_WAC) + (received_qty × line_unit_cost))
          / (old_qty + received_qty)
```

Special cases:
- `old_qty = 0`: `new_WAC = line_unit_cost`
- `line_unit_cost` includes line-level discount + freight allocation (if header has `freight_total`, prorated proportional to line gross)
- Currency: always tenant base TRY MVP

## State machine

```
    DRAFT
      │ commit()
      ↓
    COMMITTED
      │ reverse()  (creates a separate REVERSE invoice; this one stays immutable)
      ↓
    REVERSED
    (terminal; row preserved for audit)
```

## Critical invariant

**DRAFT invoice creates NO**:
- stock movement
- WAC update
- supplier debt

All four happen atomically at `commit()` in a single DB transaction.

## Allowed mutations per state

| State | Allowed |
|---|---|
| DRAFT | add/remove lines; change quantities, unit cost, line discount; change supplier, store, dates; change supplier_invoice_number (with uniqueness check); change freight_total, header discount; delete (hard; no audit); commit |
| COMMITTED | ✗ All field edits LOCKED; reverse; link payment (3.D.7) |
| REVERSED | Terminal. Row visible for audit. |

## Reads

- `GET /finance/purchase-invoices/{id}`
- `POST /catalog/variants/search` — Line picker
- `POST /parties/search?role=SUPPLIER` — Supplier dropdown
- `GET /stores` — Target store
- `GET /catalog/vat-rates`

## Writes

| Endpoint | Purpose |
|---|---|
| `POST /finance/purchase-invoices` | Body: `{ supplier_id, store_id, supplier_invoice_number, invoice_date, due_date?, currency, note? }` — Creates DRAFT, allocates internal_number |
| `PATCH /finance/purchase-invoices/{id}` | Body: `{ supplier_id?, store_id?, supplier_invoice_number?, invoice_date?, due_date?, freight_total?, header_discount?, note? }` |
| `PATCH /finance/purchase-invoices/{id}/lines` | Body: `{ lines: [{ variant_id, quantity, unit_cost, line_discount?, vat_rate }] }` — Replaces line set |
| `POST /finance/purchase-invoices/{id}/commit` | X-Idempotency-Key required. Atomically: status=COMMITTED; PURCHASE_IN movements; WAC updates; supplier debt; committed_at=now() |
| `POST /finance/purchase-invoices/{id}/reverse` | X-Idempotency-Key required. Body: `{ reason }`. Creates new REVERSE-type invoice with inverted signs; marks original as REVERSED |

## Supplier invoice number uniqueness

`UNIQUE` constraint: `(tenant_id, supplier_id, supplier_invoice_number)`. Cross-supplier duplicates allowed.

Validation:
- On blur (debounce 400ms): server lookup
- 409 with `existing_invoice_id` if duplicate
- Inline error "Bu fatura no bu tedarikçide kayıtlı (PI-X)"

## Optimistic UI

- DRAFT line/header edits: yes (debounce 400ms)
- Commit: NO (atomic operation, server-authoritative)
- Reverse: NO

## Locking

Commit: pessimistic FOR UPDATE on:
- PurchaseInvoice row
- stock_balances rows for each line (canonical variant_id ASC)
- supplier_accounts row

Per Phase 2D canonical lock order.

## Idempotency

Commit, reverse: X-Idempotency-Key mandatory.

## Keyboard flow

| Key | Action |
|---|---|
| Tab | supplier → invoice_no → date → store → freight → lines |
| ⌕ | Scanner adds line |
| `Ctrl+S` | Save DRAFT |
| `Ctrl+Enter` | Commit (after confirm modal) |
| `Esc` | Discard with confirm if dirty |

## Barcode flow

Scanner ACTIVE in DRAFT:
- Scan resolves barcode → variant_id
- If line exists: focus row, increment quantity by 1
- If line doesn't exist: add new line with quantity=1, unit_cost prefilled from last purchase of same variant (or 0)
- Variant not in catalog: toast "Variant bulunamadı"

Scanner DISABLED in COMMITTED state.

## Speed budget

| Action | p95 target |
|---|---|
| DRAFT save | < 500ms |
| Commit (10 lines) | < 1s |
| Commit (50 lines) | < 3s |
| Cost projection | < 200ms |

## Permissions

| Permission | Default |
|---|---|
| `purchasing.invoices.create` | STORE_MANAGER+ |
| `purchasing.invoices.edit_draft` | STORE_MANAGER+ |
| `purchasing.invoices.commit` | STORE_MANAGER+ |
| `purchasing.invoices.reverse` | STORE_MANAGER+ with reason |

## Layout — DRAFT create/edit

```
┌─ Yeni Alış Faturası / DRAFT ──────────────────────────────────────┐
│                                                                    │
│  Tedarikçi:        [XYZ Tekstil ▾]   [+ Yeni Tedarikçi]           │
│  Mağaza:           [Beyoğlu ▾]                                    │
│  Tedarikçi Fat. No: [A-12345]                                      │
│  İç No:             PI-2056 (otomatik)                             │
│  Fatura Tarihi:     [16/05/2026]                                   │
│  Vade Tarihi:       [16/06/2026]                                   │
│                                                                    │
│  ⌕ [SKU veya barkod tara]                                          │
│                                                                    │
│  ┌─ Lines ──────────────────────────────────────────────────┐    │
│  │ Variant       │Miktar│Birim Maliyet│İndirim│KDV │Toplam│   │   │
│  ├───────────────┼──────┼─────────────┼───────┼────┼──────┤   │   │
│  │T-100-BLK-S    │ [10] │ [₺ 50,00]   │[0]    │%20 │₺600  │[Sil] │
│  │T-100-BLK-M    │ [10] │ [₺ 50,00]   │[0]    │%20 │₺600  │[Sil] │
│  │J-450-BLU-32   │ [5]  │ [₺ 200,00]  │[0]    │%20 │₺1200 │[Sil] │
│  └────────────────────────────────────────────────────────────┘    │
│                                                                    │
│  Ara toplam:           ₺ 2.000,00                                  │
│  Kargo:                [₺ 50,00]                                   │
│  Başlık iskonto:       [₺ 100,00]                                  │
│  Net mal bedeli:       ₺ 1.950,00                                  │
│  KDV (%20):            ₺ 390,00                                    │
│  ────────────────────────────────                                  │
│  Genel toplam:         ₺ 2.340,00                                  │
│                                                                    │
│  Not: [_______________________________]                            │
│                                                                    │
│  [Esc İptal]                  [Ctrl+S Kaydet]                      │
│                              [Onayla ve Kaydet (Ctrl+Enter)]      │
│                                                                    │
└────────────────────────────────────────────────────────────────────┘
```

## Commit confirm modal

```
┌─ Faturayı Onayla ───────────────────────────────────────────────┐
│                                                                   │
│  Bu faturayı onaylamak şunları yapacak:                          │
│  - Stok girişi (25 adet, 3 varyant)                              │
│  - WAC güncelleme (her varyant için)                             │
│  - Tedarikçi borç kaydı: ₺ 2.340,00 (XYZ Tekstil)               │
│                                                                   │
│  Onaylandıktan sonra düzenleme yapılamaz.                        │
│  Hata varsa "Ters fatura" oluşturmak gerekir.                    │
│                                                                   │
│  [İptal]                              [Onayla]                    │
│                                                                   │
└───────────────────────────────────────────────────────────────────┘
```

## Edge cases

| # | Scenario | Behavior |
|---|---|---|
| 1 | Commit with variant deactivated | Allowed; warning "Bu varyant pasif. Stok eklenecek ama satılamaz." |
| 2 | Commit with negative unit_cost or quantity | Server 422; client blocks at NumberInput |
| 3 | Commit twice via double-click | Idempotency-Key prevents double application |
| 4 | Reverse a COMMITTED invoice | Modal "Bu faturayı tersine çevir?"; reason mandatory; creates new invoice with inverted lines; both visible in list |
| 5 | Edit DRAFT after long abandonment | DRAFT persists indefinitely; no auto-commit; list shows "created N days ago" |
| 6 | Mid-commit network drop | Atomic TX rollback or commit; idempotency key for retry |
| 7 | WAC update with existing stock at lower cost | Formula handles correctly; UI tooltip shows new WAC after commit |
| 8 | Duplicate supplier_invoice_number | 409 with existing_invoice_id; inline error |

## Audit events

- `purchase_invoice_created`
- `purchase_invoice_line_added` / removed / changed
- `purchase_invoice_committed` (with line + WAC + supplier debt detail)
- `purchase_invoice_reversed`
- `supplier_invoice_number_duplicate_detected`

## Implementation notes

- DRAFT save persists immediately (debounced 400ms)
- Number allocator for internal_number: sequence-allocator (Phase 6.B)
- WAC computation: server-side, Java math, BigDecimal
- Money math via Dinero.js on client (preview only); server authoritative
- Three-component header: invoice line totals + freight + header discount
