# 3.D.1 — Purchase Invoice List

> **Status:** Locked (Phase 3.D)
> **Route:** `/finance/purchase-invoices`
> **Finance Shell tab:** "Alış Faturaları"

## Purpose

Audit and operational view of all purchase invoices. Supplier payments, stock receipt history, cost tracking.

## Aggregate ownership (explicit)

- **Reads** PurchaseInvoice aggregate (Purchasing ctx, authoritative)
- **Reads** Party (supplier role) for display name
- **Reads** supplier_accounts projection for balance reference

## Finance Shell pattern

```
Finance Shell  /finance/*
  ├─ Alış Faturaları         (3.D.1, 3.D.2)
  ├─ İade/Değişim            (3.D.3, 3.D.4)
  ├─ Müşteri Tahsilatları    (3.D.7)
  ├─ Tedarikçi Ödemeleri     (3.D.7)
  ├─ Müşteri Cari Hesaplar  (3.D.5)
  └─ Tedarikçi Cari Hesaplar (3.D.6)
```

## Reads

- `POST /finance/purchase-invoices/search`
  - Body: `{ status?, supplier_id?, store_id?, date_from/to?, q? (invoice_number search), page, page_size }`
  - Returns: id, internal_number, supplier_invoice_number, supplier_name, store_name, status, total_gross, total_vat, line_count, invoice_date, committed_at, created_by

## Writes (from this screen)

None directly. Navigation only.
- "Yeni Alış" → `/finance/purchase-invoices/new`
- Row click → `/finance/purchase-invoices/{id}`

## Status enum

| Status | Meaning |
|---|---|
| DRAFT | Manager editing; no stock/WAC/debt yet |
| COMMITTED | Atomic transaction applied; immutable |
| REVERSED | Reverse invoice created (mistake correction; audit) |

## Keyboard flow

| Key | Action |
|---|---|
| `/` or `Ctrl+K` | Search |
| `Ctrl+N` | New invoice (DRAFT) |
| `Enter` | Open row |

## Barcode flow

Scanner DISABLED (header-level screen, not row-action context).

## Speed budget

| Action | p95 target |
|---|---|
| List query | < 400ms |

## Permissions

| Permission | Default |
|---|---|
| `purchasing.invoices.view` | STORE_MANAGER+, ACCOUNTANT+, AUDITOR+ |
| `purchasing.invoices.create` | STORE_MANAGER+ |
| `purchasing.invoices.view_cost` | STORE_MANAGER+, ACCOUNTANT+ |

## Layout

```
┌─ Finance Shell > Alış Faturaları ─────────────────────────────────┐
│                                                                    │
│  ⌕ [Fatura no, tedarikçi...]      [+ Yeni Alış Faturası]          │
│  Durum: [Tümü ▾]   Tedarikçi: [Tümü ▾]   Tarih: [Son 90 gün ▾]   │
│                                                                    │
│  ┌─ Invoices ────────────────────────────────────────────────┐   │
│  │ İç No  │Ted. Fat. No│Tedarikçi │Tarih │Durum    │Toplam │   │
│  ├────────┼────────────┼──────────┼──────┼─────────┼───────┤│   │
│  │PI-2056 │A-12345     │XYZ Tekstil│16/05│DRAFT    │₺1.245 ││   │
│  │PI-2055 │B-7890      │ABC Giyim │14/05 │COMMITTED│₺3.450 ││   │
│  │PI-2054 │A-12344     │XYZ Tekstil│12/05│COMMITTED│₺890   ││   │
│  │PI-2053 │C-555       │KLM Boutique│10/05│REVERSED│₺1.100 ││   │
│  └────────────────────────────────────────────────────────────┘   │
│                                                                    │
└────────────────────────────────────────────────────────────────────┘
```

## Implementation notes

- Standard list pattern (consistent with 3.B.1, 3.C.1)
- Internal number monotonic per tenant (PI-NNNN)
- Supplier invoice number = supplier's own invoice ID
- Status badges color-coded: DRAFT yellow, COMMITTED green, REVERSED grey
