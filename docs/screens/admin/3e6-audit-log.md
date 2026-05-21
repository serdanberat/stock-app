# 3.E.6 — Audit Log Browser

> **Status:** Locked (Phase 3.E)
> **Route:** `/admin/audit-log`

## Purpose

Searchable browser over `audit_event_log`. Compliance, fraud investigation, dispute resolution.

## Aggregate ownership (explicit)

- **Reads** `audit_event_log` (append-only ledger)
- No writes from this screen

## Reads

- `POST /admin/audit-log/search`
  - Body:
    ```
    {
      event_type?, actor_user_id?, party_id?,
      correlation_id?,                       // CRITICAL
      store_id?, date_from/to?, sale_id?,
      q? (free text in event payload),
      page, page_size
    }
    ```
  - Returns: events with summary + raw payload

## Display format (NOT raw JSON only)

Each row shows human-readable summary:

```
┌─ Audit Row ─────────────────────────────────────────────────────┐
│ 16/05 14:32  RETURN_FINALIZED                                    │
│ Ayşe Yılmaz (Beyoğlu)                                           │
│ İade: ₺250 nakit · Müşteri: Ahmet Yılmaz                        │
│ Correlation: TX-ab12...                                          │
│ [Ham veriyi göster ▾]                                            │
└──────────────────────────────────────────────────────────────────┘
```

Expand → raw payload (JSON):
```json
{
  "event_id": "...",
  "event_type": "RETURN_FINALIZED",
  "tenant_id": "...",
  "actor_user_id": "...",
  "actor_user_name": "Ayşe Yılmaz",
  "store_id": "...",
  "sale_id": "...",
  "return_id": "...",
  "correlation_id": "TX-ab12-...",
  "amount": "250.00",
  "tender_type": "CASH",
  "party_id": "...",
  "occurred_at": "2026-05-16T14:32:18Z"
}
```

## Correlation drill-down

Click `correlation_id` → loads all events sharing same correlation:
- Transfer (DISPATCHED + IN_TRANSIT + RECEIVED + movements)
- Return + new sale + refund payment
- Sale completion (sale + tender + movements + receipt)

Chronological timeline UI for related events:

```
┌─ Correlation: TX-ab12... ───────────────────────────────────────┐
│  14:32:14  RETURN_LINE_ADDED                                     │
│  14:32:16  EXCHANGE_LINE_ADDED                                   │
│  14:32:18  RETURN_FINALIZED         ← anchor                    │
│  14:32:18  STOCK_RETURN_IN                                       │
│  14:32:18  STOCK_SALE_OUT (exchange)                             │
│  14:32:18  CASH_MOVEMENT_OUT (refund)                            │
│  14:32:18  CASH_MOVEMENT_IN (settlement)                         │
│  14:32:19  SALE_COMPLETED (exchange)                             │
└──────────────────────────────────────────────────────────────────┘
```

## CSV export

[CSV İndir] button on search results.

Includes summary columns + JSON payload (escaped) for compliance.

## Optimistic UI

N/A (read-only).

## Permissions

| Permission | Default |
|---|---|
| `audit.view` | AUDITOR, SUPER_ADMIN (default) |
| `audit.view` (optional grant) | STORE_MANAGER for own store events (tenant config) |
| `audit.export_csv` | AUDITOR, SUPER_ADMIN |

## Layout

```
┌─ Admin Shell > Audit Log ─────────────────────────────────────────┐
│                                                                    │
│  ⌕ [Olay tipi, aktör, party, sale id, correlation...]             │
│  Tip: [Tümü ▾]   Aktör: [Tümü ▾]   Mağaza: [Tümü ▾]              │
│  Tarih: [Son 30 gün ▾]    Correlation: [_______]                  │
│                                                                    │
│  [CSV İndir]                                                       │
│                                                                    │
│  ┌─ Events ─────────────────────────────────────────────────┐    │
│  │ Tarih   │ Olay              │ Aktör   │ Özet              │    │
│  ├─────────┼───────────────────┼─────────┼───────────────────┤    │
│  │16/05    │RETURN_FINALIZED   │Ayşe Y.  │₺250 nakit iade    │    │
│  │14:32:18 │                   │         │Ahmet Yılmaz       │    │
│  │         │                   │         │TX-ab12 [aç ▾]     │    │
│  ├─────────┼───────────────────┼─────────┼───────────────────┤    │
│  │16/05    │SALE_COMPLETED     │Ayşe Y.  │₺700 nakit+kart    │    │
│  │14:28:01 │                   │         │PI-2026-1234       │    │
│  ├─────────┼───────────────────┼─────────┼───────────────────┤    │
│  │16/05    │DISCOUNT_OVERRIDE  │Mehmet K.│Manager %30 onayı  │    │
│  │13:15:44 │                   │         │PROMO              │    │
│  └────────────────────────────────────────────────────────────┘   │
│                                                                    │
│  Showing 1-30 of 8,247                                             │
│                                                                    │
└────────────────────────────────────────────────────────────────────┘
```

## Implementation notes

- Audit summary composed Java-side from event payload (per ADR-019 pattern; no DB function)
- `AuditEventSummaryComposer` per `event_type`
- Correlation drill-down is critical pattern; used widely
- Raw JSON via expandable accordion
- Search index: GIN on payload JSONB + `tenant_id` + `occurred_at`
- CSV export via worker pattern; large queries throttled
