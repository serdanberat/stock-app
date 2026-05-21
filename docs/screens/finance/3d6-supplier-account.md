# 3.D.6 — Supplier Account Detail

> **Status:** Locked (Phase 3.D)
> **Route:** `/finance/supplier-accounts/{partyId}`

## Purpose

View supplier's financial state: balance, aging, payment history. Supplier-side of the shared AccountDetailView component.

## Aggregate ownership (explicit)

- **Reads** Party (supplier role) + AccountProfile + account_movements
- **Reads** aging projections
- NO writes; "Ödeme Yap" button navigates to 3.D.7

## Shared component note

Same React component as 3.D.5 (`AccountDetailView`) with `role='SUPPLIER'`. Terminology adapted.

## Supplier-side terminology

| Concept | Supplier side |
|---|---|
| Balance >0 | Mağaza tedarikçiye borçlu (we owe them) |
| Balance <0 | Tedarikçi mağazaya borçlu (rare; advance payment) |
| Primary action | "Ödeme Yap" |
| Sub-action | (none — no store credit for suppliers) |

## Reads

- `GET /finance/accounts/{partyId}` — Same endpoint as 3.D.5, supplier-role response
- `POST /finance/accounts/{partyId}/movements/search` — Movement types include: PURCHASE_DEBT, PAYMENT_MADE, RETURN_TO_SUPPLIER

## Permissions

| Permission | Default |
|---|---|
| `finance.accounts.view` | STORE_MANAGER+, ACCOUNTANT+, AUDITOR+ |
| `finance.pay_supplier` | STORE_MANAGER+, ACCOUNTANT+ |

## Layout

```
┌─ Finance Shell > Tedarikçi Hesabı: XYZ Tekstil ───────────────────┐
│  Tel: 0212 *** 5678   [Göster]      Tedarikçi No: P-1024          │
├───────────────────────────────────────────────────────────────────┤
│                                                                    │
│  ┌─ Özet ──────────────────────────────────────────────────┐    │
│  │ Ödenecek bakiye:      ₺ 8.450,00                          │    │
│  │ Vade geçmiş:          ₺ 1.200,00 (60-90 gün)             │    │
│  │                                                            │    │
│  │ Yaşlandırma:                                              │    │
│  │   0-30 gün:    ₺ 5.500,00                                 │    │
│  │   30-60 gün:   ₺ 1.750,00                                 │    │
│  │   60-90 gün:   ₺ 1.200,00                                 │    │
│  │   90+ gün:     ₺ 0                                        │    │
│  └────────────────────────────────────────────────────────────┘    │
│                                                                    │
│  [Ödeme Yap] [İletişim Bilgileri]                                 │
│                                                                    │
│  ┌─ Hareketler ─────────────────────────────────────────────┐    │
│  │ Tarih   │ Tip                │ Açıklama  │ Tutar │ Bakiye │   │
│  ├─────────┼────────────────────┼───────────┼───────┼────────┤   │
│  │ 16/05   │ PURCHASE_DEBT      │ PI-2056   │+₺2.340│ ₺8.450 │   │
│  │ 15/05   │ PAYMENT_MADE       │ Havale    │-₺1.500│ ₺6.110 │   │
│  │ 12/05   │ PURCHASE_DEBT      │ PI-2055   │+₺3.450│ ₺7.610 │   │
│  │ 10/05   │ PURCHASE_DEBT      │ PI-2054   │+₺890  │ ₺4.160 │   │
│  └────────────────────────────────────────────────────────────┘   │
│                                                                    │
└────────────────────────────────────────────────────────────────────┘
```

## Implementation notes

- Single React component `AccountDetailView` with `role='SUPPLIER'` prop
- i18n strings keyed by role
- "Store credit" row hidden (not applicable)
- "Kredi limiti" hidden (not applicable to suppliers)
- "Ödeme Yap" navigates to `/finance/supplier-payments/new?party_id={id}`
- Aging from `supplier_aging_summary` mview
