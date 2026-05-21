# Phase 3.D — Financial Flows

> **Status:** Locked
> **Phase:** 3.D
> **Delivery date:** 2026-05-21

Financial flows are where POS, Inventory, and Catalog converge into accounting reality. Phase 3.D handles purchase invoices, returns/exchanges, customer and supplier accounts, and payment collection.

The dominant pattern across Phase 3.D: **commit atomicity**. DRAFT lifecycle preserves intent without side effects; commit transitions atomically apply stock movements, account changes, and ledger entries in a single transaction.

## Screens (7)

| # | Screen | Purpose | Key complexity |
|---|---|---|---|
| 3.D.1 | Purchase Invoice List | Audit/operational view; supplier filter | Status-based filter (DRAFT/COMMITTED/REVERSED) |
| 3.D.2 | Purchase Invoice Create/Edit | Largest financial operation; stock IN + WAC + supplier debt | Atomic commit; supplier invoice uniqueness; freight prorate |
| 3.D.3 | Return/Exchange Initiate | Entry point with reference-based or reference-less | Manager PIN for fishless return; refund tender allowlist |
| 3.D.4 | Return/Exchange Process | Lines + refund tender + exchange settlement | Three-component decomposition; store credit as real liability |
| 3.D.5 | Customer Account Detail | Balance, aging, movements (customer side) | Shared component with 3.D.6 |
| 3.D.6 | Supplier Account Detail | Balance, aging, payments (supplier side) | Same component, role-aware |
| 3.D.7 | Payment Collection | Generic customer/supplier payment | Direction param + tender allowlist + bank reference UNIQUE |

## Finance Shell pattern

```
Finance Shell  /finance/*
  ├─ Alış Faturaları         (3.D.1, 3.D.2)
  ├─ İade/Değişim            (3.D.3, 3.D.4)
  ├─ Müşteri Tahsilatları    (3.D.7)
  ├─ Tedarikçi Ödemeleri     (3.D.7)
  ├─ Müşteri Cari Hesaplar   (3.D.5)
  └─ Tedarikçi Cari Hesaplar (3.D.6)
```

## Locked decisions catalog

### Purchase Invoice (3.D.1, 3.D.2)
- **DRAFT → COMMITTED state machine**; reverse creates new REVERSE invoice
- **CRITICAL INVARIANT**: DRAFT creates NO stock movement, NO WAC update, NO supplier debt
- **Store-level WAC**: per (variant, store), not tenant-level
- **WAC formula**: `((old_qty × old_WAC) + (received_qty × line_unit_cost)) / (old_qty + received_qty)`
- **Freight allocation**: prorated proportional to line gross
- **Supplier invoice uniqueness**: `UNIQUE(tenant_id, supplier_id, supplier_invoice_number)`; cross-supplier dups allowed
- **Reverse**: creates new REVERSE invoice with inverted signs; original marked REVERSED (audit preserved)
- **Pessimistic FOR UPDATE canonical**: invoice → stock_balances → supplier_accounts
- **X-Idempotency-Key required** on commit and reverse

### Return / Exchange (3.D.3, 3.D.4)
- **Two modes**: REFERENCED (sale lookup) vs WITHOUT_REFERENCE (manager PIN + reason + free-text)
- **Reference window**: `return_window_days` (default 30); outside requires manager override
- **Refund tender allowlist**:
  - REFERENCED: CASH, CARD_REFUND, STORE_CREDIT, CUSTOMER_ACCOUNT
  - WITHOUT_REFERENCE: only STORE_CREDIT, CUSTOMER_ACCOUNT (no cash, no card_refund — server enforces)
- **Exchange decomposition**: three explicit components (returned_total, new_sale_total, settlement_delta); no "magic exchange total"
- **STORE_CREDIT is real monetary liability**: account_movement on customer; aging visible; NOT loyalty points
- **Card refund MVP**: stub returns success; real terminal reversal v1.1+
- **No QUARANTINE_RETURN**: manager judgment + audit (quarantine v1.1+ if fraud patterns)
- **Stock back-in policy**: WITHOUT_REFERENCE shows warning, audit confirms
- **Customer required for WITHOUT_REFERENCE refund tenders** (store credit needs party attachment)

### Account Detail (3.D.5, 3.D.6)
- **Shared component AccountDetailView** with role prop
- **Separate semantic routes**: `/finance/customer-accounts/{id}` vs `/finance/supplier-accounts/{id}` (NOT query param — audit/export clarity)
- **Role-aware terminology**:
  - Customer: Borç / Tahsilat / Store credit
  - Supplier: Borç / Ödeme (no credit limit, no store credit)
- **Aging breakdown**: 0-30 / 30-60 / 60-90 / 90+
- **Customer balance >0**: owes us; <0: store credit
- **Supplier balance >0**: we owe

### Payment Collection (3.D.7)
- **Generic component** with direction prop
- **Semantic routes**: `/finance/customer-payments/new` vs `/finance/supplier-payments/new`
- **Tender per direction**:
  - COLLECT_FROM_CUSTOMER: CASH, CARD, BANK_TRANSFER, STORE_CREDIT_REDEMPTION
  - PAY_TO_SUPPLIER: CASH, BANK_TRANSFER (no card MVP)
- **Bank transfer**: reference number required, UNIQUE per tenant for current year
- **Overpayment allowed**: customer balance negative (store credit-like)
- **Pessimistic FOR UPDATE**: account_profiles + cash_register_sessions + store_credit_balance

## Schema additions (Migration 021)

- `purchase_invoices` with status enum + supplier_invoice_number + freight_total + header_discount + atomic commit fields + `UNIQUE(tenant_id, supplier_id, supplier_invoice_number)`
- `purchase_invoice_lines` with unit_cost + line_discount + vat_rate + computed total
- `returns` table with mode + manager_override_token + reason_code + correlation_id
- `return_lines` with quantity + reason
- `exchange_lines` (new sale items in return)
- `account_movements` types extended: STORE_CREDIT_ISSUED, STORE_CREDIT_REDEEMED
- `store_credit_balances` table per (party_id) with aging
- `payments` table with direction + tender + bank_transfer_reference (UNIQUE per tenant per year)

See `migrations/021_finance_extensions.sql`.

## Audit event catalog (Phase 3.D additions)

### Purchase Invoice
| Event | Triggered by |
|---|---|
| purchase_invoice_created | New DRAFT |
| purchase_invoice_line_added/removed/changed | DRAFT edit |
| purchase_invoice_committed | DRAFT → COMMITTED with detail |
| purchase_invoice_reversed | Reverse invoice created |
| supplier_invoice_number_duplicate_detected | UNIQUE violation |

### Return / Exchange
| Event | Triggered by |
|---|---|
| return_initiated_with_reference | Mode A initiate |
| return_initiated_without_reference | Mode B with manager PIN + reason |
| return_outside_window_overridden | Outside `return_window_days` |
| return_line_added/removed | DRAFT edit |
| exchange_line_added/removed | DRAFT edit |
| refund_tender_set | Tender selection |
| return_finalized | DRAFT → COMPLETED |
| return_without_sale_stock_warning_confirmed | Stock back-in for WITHOUT_REFERENCE |
| exchange_negative_delta_collected | Customer paid in |
| exchange_positive_delta_refunded | Store paid out |
| store_credit_issued | STORE_CREDIT tender used |

### Payment Collection
| Event | Triggered by |
|---|---|
| customer_payment_received | Tahsilat completed |
| supplier_payment_made | Ödeme completed |
| overpayment_warning | Amount > current debt |
| store_credit_redeemed | STORE_CREDIT_REDEMPTION tender |
| cash_drawer_opened | CASH tender used |

## API endpoints (Phase 3.D additions)

| Endpoint | Purpose |
|---|---|
| POST /finance/purchase-invoices/search | Invoice list |
| POST /finance/purchase-invoices | Create DRAFT |
| PATCH /finance/purchase-invoices/{id} | Edit DRAFT |
| PATCH /finance/purchase-invoices/{id}/lines | Replace lines |
| POST /finance/purchase-invoices/{id}/commit | DRAFT → COMMITTED |
| POST /finance/purchase-invoices/{id}/reverse | Create REVERSE |
| POST /finance/returns | Create DRAFT |
| PATCH /finance/returns/{id}/return-lines | Set return lines |
| PATCH /finance/returns/{id}/exchange-lines | Set exchange lines |
| PATCH /finance/returns/{id}/refund-tender | Set tender |
| POST /finance/returns/{id}/finalize | DRAFT → COMPLETED |
| POST /finance/returns/{id}/cancel | → CANCELLED |
| GET /finance/accounts/{partyId} | Account detail |
| POST /finance/accounts/{partyId}/movements/search | Movement history |
| POST /finance/payments | Generic payment |

## What's NOT in Phase 3.D scope

- e-Belge / e-Arşiv Fatura integration — v1.1+
- Card refund real terminal reversal — v1.1+ (stub MVP)
- Quarantine return state — v1.1+
- Partial-receive-over-time on purchase — v1.1+
- Multi-currency invoices — v1.1+ (TRY-only MVP)
- Supplier credit notes — v1.1+ (manual adjustment fallback)
- Bulk purchase import (CSV) — v1.1+
- Customer/supplier party merge tool — v1.1+
- Loyalty points / promotional credit — never (store credit is liability, not loyalty)
- Layby / installment plans — v1.1+
