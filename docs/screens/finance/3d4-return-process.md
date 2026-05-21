# 3.D.4 — Return / Exchange Process

> **Status:** Locked (Phase 3.D)
> **Route:** `/finance/returns/{id}`

## Purpose

Process the actual return: select lines, set quantities, attach exchange items (optional), choose refund tender, complete.

This is where the financial state is committed: stock back-in, refund posted, account movements created.

## Aggregate ownership (explicit)

- **Writes** Return aggregate (lifecycle)
- Indirectly via outbox event consumers at finalize:
  - `stock_movements` with RETURN_IN per returned line
  - `stock_balances` FOR UPDATE; quantity_on_hand += returned_qty
  - `account_movements` (refund tender, customer/supplier account)
  - `cash_movements` (if CASH refund)
  - `payment_attempts` (if CARD_REFUND — stub MVP)
  - If exchange: new SALE aggregate created in COMPLETED state with same correlation_id

## State machine

```
    DRAFT
      │ finalize()
      ↓
    COMPLETED
    (terminal; immutable; reverse via separate reverse-return)
```

DRAFT → CANCELLED also possible (abandoned without finalize).

## Allowed mutations per state

| State | Allowed |
|---|---|
| DRAFT | add/remove return lines (subject to remaining quantities); add exchange lines; apply discount on exchange lines (rare); set refund tender + amount; change customer attachment; finalize → COMPLETED; cancel → CANCELLED |
| COMPLETED, CANCELLED | Terminal |

## Exchange semantics (CRITICAL)

Exchange = return lines + new sale lines + settlement.

Three explicit financial components — no "magic exchange total":

1. `returned_total` = sum of returned line values (gross)
2. `new_sale_total` = sum of new line values (gross, incl VAT)
3. `settlement_delta = new_sale_total - returned_total`

Cases:
- `settlement_delta > 0` — Customer owes (collect via refund tenders INVERSED, i.e. payment INTO store)
- `settlement_delta = 0` — Even exchange; no money moves
- `settlement_delta < 0` — Store owes; refund `|delta|` to customer

Atomically at finalize:
- For return lines: RETURN_IN stock movements
- For new sale lines: new Sale aggregate in COMPLETED state, generating SALE_OUT stock movements
- Settlement: appropriate tender movement(s)
- All within single TX with idempotency key

## Refund tender allowlist

### REFERENCED return
- ✓ CASH
- ✓ CARD_REFUND (terminal reversal; stub MVP returns success)
- ✓ STORE_CREDIT (issued to customer's account_profile)
- ✓ CUSTOMER_ACCOUNT (if customer has debt; reduces it)

### WITHOUT_REFERENCE return
- ✗ CASH
- ✗ CARD_REFUND
- ✓ STORE_CREDIT
- ✓ CUSTOMER_ACCOUNT

### STORE_CREDIT — real monetary liability

- Creates `account_movement` on customer's account_profile
- Direction: credit (we owe customer)
- Aging visible alongside debt
- NOT loyalty points; NOT promotional

## Reads

- `GET /finance/returns/{id}`
- `POST /catalog/variants/search` — Exchange lines
- `GET /pricing/variants/{id}` — Exchange line pricing
- `GET /parties/{id}/account-summary?fresh=true` — Refund decision

## Writes

| Endpoint | Purpose |
|---|---|
| `PATCH /finance/returns/{id}/return-lines` | Set return lines |
| `PATCH /finance/returns/{id}/exchange-lines` | Set new sale lines |
| `PATCH /finance/returns/{id}/refund-tender` | Body: `{ type, amount, reason? }`. Server validates against allowlist + remaining settlement |
| `POST /finance/returns/{id}/finalize` | X-Idempotency-Key required |
| `POST /finance/returns/{id}/cancel` | DRAFT → CANCELLED |

## Optimistic UI

- Line additions: yes
- Refund tender selection: NO (server validates)
- Finalize: NO

## Locking

Pessimistic FOR UPDATE during finalize:
- Return row
- stock_balances rows (returned + exchange lines, canonical order)
- cash_register_sessions (if CASH refund)
- account_profiles (customer/supplier)

## Idempotency

Finalize: mandatory.

## Keyboard flow

| Key | Action |
|---|---|
| Tab | return lines section → exchange lines → refund → finalize |
| ⌕ | Scanner adds exchange lines (mode-aware) |
| `Ctrl+F` | Finalize (after confirm) |
| `Esc` | Discard (cancel DRAFT) |

## Barcode flow

DRAFT mode: scanner adds to exchange lines (not return lines; return is from original sale lookup).

COMPLETED: scanner disabled.

## Speed budget

| Action | p95 target |
|---|---|
| Line edits | < 400ms |
| Finalize (mixed) | < 1s |

## Permissions

| Permission | Default |
|---|---|
| `returns.process` | STORE_MANAGER+, CASHIER |
| `returns.refund_cash` | STORE_MANAGER+, CASHIER |
| `returns.refund_card` | STORE_MANAGER+ (terminal access) |
| `returns.exchange` | STORE_MANAGER+, CASHIER |

## Stock back-in policy

- REFERENCED return: stock goes back to `store_id` from return header
- WITHOUT_REFERENCE return: stock back-in BUT manager warning shown:
  ```
  "Bu fişsiz iade. Ürün gerçekten bu mağazadan mı?"
  Confirm + audit event return_without_sale_stock_warning_confirmed
  ```

No QUARANTINE_RETURN intermediate state MVP. Manager judgment + audit trail are the safeguard. Quarantine v1.1+ if fraud patterns observed.

## Layout — DRAFT pure return

```
┌─ İade #RET-1234 / DRAFT ──────────────────────────────────────────┐
│                                                                    │
│  Müşteri: Ahmet Yılmaz                                             │
│  Orjinal satış: PI-2026-1234 (12/05/2026)                          │
│  Mağaza: Beyoğlu                                                   │
│                                                                    │
│  ┌─ İade Kalemleri (orjinal satıştan) ──────────────────────┐    │
│  │ Variant       │Satılan│Kalan│İade │Birim Fiyat│Toplam   │   │
│  ├───────────────┼───────┼─────┼─────┼───────────┼─────────┤    │
│  │T-shirt BLK/M  │   2   │  2  │ [1] │ ₺99,00    │₺99,00   │    │
│  │Jeans BLU/32   │   1   │  1  │ [0] │ ₺450,00   │₺0       │    │
│  └────────────────────────────────────────────────────────────┘   │
│                                                                    │
│  İade toplamı:        ₺ 99,00 (KDV dahil)                          │
│                                                                    │
│  ┌─ Yeni Satış (Değişim için) ─────────────────────────────┐    │
│  │ (boş - sadece iade)                                       │    │
│  │ ⌕ Variant tara veya ara: [+ Ekle]                          │    │
│  └──────────────────────────────────────────────────────────┘    │
│                                                                    │
│  Yeni satış toplamı:  ₺ 0,00                                       │
│  ──────────────────────────                                        │
│  Settlement delta:    -₺ 99,00 (mağaza müşteriye borçlu)          │
│                                                                    │
│  ┌─ İade Ödeme ─────────────────────────────────────────────┐    │
│  │ Tip: [NAKİT ▾]   Tutar: [₺ 99,00]                          │    │
│  └──────────────────────────────────────────────────────────┘    │
│                                                                    │
│  [Esc İptal]                              [Tamamla (Ctrl+F)]      │
│                                                                    │
└────────────────────────────────────────────────────────────────────┘
```

## Layout — Exchange (positive delta)

Same layout, exchange section has lines:

```
┌─ Yeni Satış (Değişim için) ─────────────────────────────┐
│ T-shirt BLK/L × 1  ₺99,00  (resmi fiyat)               │
│ Sweater RED/L × 1  ₺250,00                              │
│ Yeni satış toplamı: ₺349,00                              │
└──────────────────────────────────────────────────────────┘

Settlement delta: +₺250,00 (müşteri mağazaya borçlu)

┌─ Müşteriden Tahsilat ──────────────────────────────┐
│ Tip: [NAKİT ▾]   Tutar: [₺ 250,00]                  │
└─────────────────────────────────────────────────────┘
```

## Layout — Without-reference return

```
Banner: "⚠ FİŞSİZ İADE — sadece store credit veya cari hesap iade"
Refund tender dropdown limited to [STORE_CREDIT, CUSTOMER_ACCOUNT]
Customer attachment required (cannot proceed without)
```

## Finalize confirm modal

```
┌─ İade'yi Tamamla ─────────────────────────────────────────────────┐
│                                                                    │
│  Bu işlem şunları yapacak:                                         │
│  - Stok girişi: T-shirt BLK/M × 1                                 │
│  - Yeni satış: Sweater RED/L × 1                                  │
│  - Müşteriden tahsilat: ₺ 151,00 nakit                            │
│  - Kasa girişi: ₺ 151,00                                          │
│                                                                    │
│  Onaylandıktan sonra geri alınamaz.                                │
│  Hata varsa: ters iade veya manager intervention.                  │
│                                                                    │
│  [İptal]                              [Onayla ve Tamamla]          │
│                                                                    │
└────────────────────────────────────────────────────────────────────┘
```

## Audit events

- `return_line_added` / removed
- `exchange_line_added` / removed
- `refund_tender_set`
- `return_finalized` (with line + tender + settlement detail)
- `return_without_sale_stock_warning_confirmed`
- `exchange_negative_delta_collected`
- `exchange_positive_delta_refunded`
- `store_credit_issued` (when STORE_CREDIT refund tender used)

## Implementation notes

- Three-component financial display (returned / new_sale / delta) prevents single-total confusion
- Refund tender dropdown filtered by mode (reference vs without)
- STORE_CREDIT issuance creates account_movement on customer profile (debt direction: store owes customer)
- Exchange new sale creates Sale aggregate sharing correlation_id with Return aggregate (audit traceability)
- Card refund MVP: stub returns success; real terminal reversal v1.1+
- Correlation_id pattern enables audit log browser drill-down (per ADR-020)
