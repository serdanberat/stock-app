# 3.D.7 — Payment Collection (Customer Tahsilat / Supplier Ödeme)

> **Status:** Locked (Phase 3.D)
> **Routes (semantic, separate URLs)**:
> - `/finance/customer-payments/new?party_id={id}` — Customer collection
> - `/finance/supplier-payments/new?party_id={id}` — Supplier payment
> - `/finance/customer-payments` — Customer payment list
> - `/finance/supplier-payments` — Supplier payment list

## Purpose

Generic payment workflow for both customer collection (incoming money) and supplier payment (outgoing money). Same component, route semantic distinguishes direction.

## Why separate routes (not query param)

Audit/export/logging clarity. Per ADR-020 correlation pattern: semantic resource separation makes audit log queries cleaner ("show all customer payments today" vs filtering by direction).

## Aggregate ownership (explicit)

- **Writes** Payment aggregate
- Indirectly via outbox event consumers:
  - `account_movements` (DEBT_DECREASE for both directions, but on different party)
  - `cash_movements` if CASH
  - `payment_attempts` if CARD

## Reads

- `GET /finance/accounts/{partyId}` — Current balance + aging
- `POST /parties/search` — Party picker if missing

## Writes

- `POST /finance/payments`
  - Body:
    ```
    {
      party_id,
      direction: 'COLLECT_FROM_CUSTOMER' | 'PAY_TO_SUPPLIER',
      amount,
      tender_type: 'CASH' | 'CARD' | 'BANK_TRANSFER' | 'STORE_CREDIT_REDEMPTION',
      store_id,                       // for cash drawer affiliation
      bank_transfer_reference?,       // required if tender_type = BANK_TRANSFER
      note?,
      idempotency_key
    }
    ```
  - Atomically posts movement + account update

## Tender types per direction

### COLLECT_FROM_CUSTOMER
- ✓ CASH
- ✓ CARD
- ✓ BANK_TRANSFER (manual entry; reference number required)
- ✓ STORE_CREDIT_REDEMPTION (uses customer's store credit balance)

### PAY_TO_SUPPLIER
- ✓ CASH
- ✓ BANK_TRANSFER
- ✗ CARD (we don't pay suppliers with cards typically; v1.1+)
- ✗ STORE_CREDIT_REDEMPTION (n/a)

## Optimistic UI

NO. Financial transaction; await server confirmation.

## Locking

Pessimistic FOR UPDATE on:
- `account_profiles` (party)
- `cash_register_sessions` if CASH
- `store_credit_balance` if STORE_CREDIT_REDEMPTION

## Idempotency

X-Idempotency-Key required.

## Keyboard flow

| Key | Action |
|---|---|
| Tab | party (if not prefilled) → amount → tender → save |
| `Ctrl+S` | Submit payment |
| `Esc` | Cancel |

## Barcode flow

Scanner disabled (no item context).

## Speed budget

| Action | p95 target |
|---|---|
| Submit | < 800ms |
| Account refresh | < 400ms |

## Permissions

| Permission | Default |
|---|---|
| `finance.collect_customer_payment` | CASHIER+, STORE_MANAGER+ |
| `finance.pay_supplier` | STORE_MANAGER+, ACCOUNTANT+ |
| `finance.collect_via_bank_transfer` | STORE_MANAGER+ (reference number verification) |

## Layout — Customer collection

```
┌─ Tahsilat Al — Ahmet Yılmaz ──────────────────────────────────────┐
│                                                                    │
│  Mevcut borç:        ₺ 450,00                                      │
│  Vade geçmiş:        ₺ 120,00 (60-90 gün)                          │
│  Store credit:       ₺ 50,00                                       │
│                                                                    │
│  Tahsilat tutarı:    [₺ 250,00]                                    │
│  Bakiye sonrası:     ₺ 200,00                                      │
│                                                                    │
│  Tender:                                                           │
│  ◉ Nakit                                                           │
│  ◯ Kart                                                            │
│  ◯ Banka havalesi (referans no gerekli)                            │
│  ◯ Store credit'ten düş (max ₺ 50,00)                              │
│                                                                    │
│  Mağaza: [Beyoğlu ▾]   (kasa için)                                 │
│  Not: [_______________________________]                            │
│                                                                    │
│  [Esc İptal]                              [Kaydet (Ctrl+S)]       │
│                                                                    │
└────────────────────────────────────────────────────────────────────┘
```

## Layout — Supplier payment

Similar layout, "Ödeme Yap" CTA, supplier-appropriate tenders. Bank transfer requires reference number for audit (account number, transaction date, etc.)

## Edge cases

| # | Scenario | Behavior |
|---|---|---|
| 1 | Amount > current debt (overpayment) | Allowed: customer balance goes negative (store credit-like); warning "Bu tahsilat borcu aşıyor. Fazla tutar müşteri lehine kalır." |
| 2 | STORE_CREDIT_REDEMPTION exceeds available | Server 422 with available amount; UI hint "Mevcut store credit: ₺50,00" |
| 3 | Cash payment when register session closed | 422 "Kasa kapalı; nakit tahsilat yapılamaz"; suggest opening register or alternative tender |
| 4 | Concurrent payment (two cashiers same customer) | Optimistic version on account_profile + idempotency; first wins; second reload |
| 5 | Bank transfer reference number duplicate | UNIQUE per tenant on `bank_transfer_reference` for current year; 409 with existing payment_id |

## Audit events

- `customer_payment_received` (with tender + amount + party)
- `supplier_payment_made`
- `overpayment_warning`
- `store_credit_redeemed`
- `cash_drawer_opened` (if CASH tender)

## Implementation notes

- Same React component `PaymentCollectionForm` with `direction` prop
- Tender list filtered by direction + party type
- i18n strings keyed by direction
- Bank transfer reference becomes part of audit trail
- Store credit redemption decrements `store_credit_balance` atomically
- Semantic routes preserve audit clarity (separate from query param)
