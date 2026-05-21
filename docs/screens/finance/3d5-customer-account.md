# 3.D.5 — Customer Account Detail

> **Status:** Locked (Phase 3.D)
> **Route:** `/finance/customer-accounts/{partyId}`

## Purpose

View customer's financial state: balance, aging, movements, store credit. Customer-side of the shared AccountDetailView component.

## Aggregate ownership (explicit)

- **Reads** Party + AccountProfile + account_movements (Finance ctx)
- **Reads** aging projections (`customer_aging_summary` mview or fresh DB)
- NO writes from this screen; "Tahsilat Al" / "Store Credit Kullan" buttons navigate to 3.D.7

## Shared component note

This screen and 3.D.6 (Supplier Account Detail) share a single React component `AccountDetailView` with a `role` prop. Same component, role-aware terminology.

Separate semantic routes (NOT a query param) for audit/export/logging clarity per ADR-020 correlation pattern.

## Customer-side terminology

| Concept | Customer side |
|---|---|
| Balance >0 | Customer borçlu (owes us) |
| Balance <0 | Mağaza müşteriye borçlu (store credit balance) |
| Primary action | "Tahsilat Al" |
| Sub-action | "Store Credit Kullan" |

## Reads

- `GET /finance/accounts/{partyId}`
  - Returns: party identity, account profile, balance, credit_limit, credit_used, store_credit_balance, aging breakdown {0-30, 30-60, 60-90, 90+}
- `POST /finance/accounts/{partyId}/movements/search`
  - Body: `{ date_from/to?, type?, page, page_size }`
  - Returns movements: SALE_DEBT, RETURN_CREDIT, PAYMENT_RECEIVED, STORE_CREDIT_ISSUED, STORE_CREDIT_REDEEMED, etc.

## Writes

None (read-only). Action buttons navigate to other screens.

## Permissions

| Permission | Default |
|---|---|
| `finance.accounts.view` | STORE_MANAGER+, ACCOUNTANT+, AUDITOR+ |
| `finance.accounts.view_full_aging` | ACCOUNTANT+ (default); STORE_MANAGER (tenant config) |
| `finance.collect_customer_payment` | CASHIER+, STORE_MANAGER+ |

## Layout

```
┌─ Finance Shell > Müşteri Hesabı: Ahmet Yılmaz ────────────────────┐
│  Tel: 0532 *** 1234   [Göster]      Müşteri No: P-3421            │
├───────────────────────────────────────────────────────────────────┤
│                                                                    │
│  ┌─ Özet ──────────────────────────────────────────────────┐    │
│  │ Borç bakiyesi:        ₺ 450,00                            │    │
│  │ Kredi limiti:         ₺ 1.000,00                          │    │
│  │ Müsait kredi:         ₺ 550,00                            │    │
│  │ Store credit:         ₺ 50,00                             │    │
│  │                                                            │    │
│  │ Yaşlandırma:                                              │    │
│  │   0-30 gün:    ₺ 330,00                                   │    │
│  │   30-60 gün:   ₺ 0                                        │    │
│  │   60-90 gün:   ₺ 120,00                                   │    │
│  │   90+ gün:     ₺ 0                                        │    │
│  └────────────────────────────────────────────────────────────┘    │
│                                                                    │
│  [Tahsilat Al] [Store Credit Kullan] [İletişim Bilgileri]        │
│                                                                    │
│  ┌─ Hareketler ─────────────────────────────────────────────┐    │
│  │ Tarih   │ Tip                │ Açıklama  │ Tutar │ Bakiye │   │
│  ├─────────┼────────────────────┼───────────┼───────┼────────┤   │
│  │ 16/05   │ SALE_DEBT          │ PI-2026-X │+₺200  │ ₺450   │   │
│  │ 15/05   │ PAYMENT_RECEIVED   │ Nakit     │-₺100  │ ₺250   │   │
│  │ 14/05   │ STORE_CREDIT_ISSUED│ RET-1234  │+₺50*  │ —      │   │
│  │ 12/05   │ SALE_DEBT          │ PI-2026-Y │+₺350  │ ₺350   │   │
│  │ *store credit ledger separate                                │   │
│  └────────────────────────────────────────────────────────────┘   │
│                                                                    │
└────────────────────────────────────────────────────────────────────┘
```

## Implementation notes

- Single React component `AccountDetailView` with `role` prop
- i18n strings keyed by role
- Phone masking same as 3.A.3 (`parties.view_full_phone` permission)
- Aging from `customer_aging_summary` mview (10 min stale OK for view; fresh DB for credit decisions in 3.A.5 payment)
- Store credit displayed separately to distinguish from debt
- "Tahsilat Al" navigates to `/finance/customer-payments/new?party_id={id}`
