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

## Retention policy

**Audit events retained minimum 5 years per tenant.** No deletion endpoint. No automatic purge MVP.

**Rationale**: Turkish tax authority (VUK — Vergi Usul Kanunu) and commercial code require 5-year retention for accounting records. Audit log feeds compliance investigation and dispute resolution. Setting retention policy now (even without active purge) locks the contract; adding retention later requires backfill and is error-prone.

**Storage projection**:
- ~1-5 MB/store/year audit events at typical retail volume
- 5-year × 100 stores = 500MB-2.5GB per tenant
- Negligible at PostgreSQL TOAST efficiency for JSONB payloads
- Indexes (GIN payload + correlation_id + occurred_at) add ~20% overhead

**v1.1+ consideration**: archival tier (Neon → S3 Glacier-equivalent) for events > 2 years old. MVP keeps everything hot.

**No retention configuration UI MVP**: tenants cannot opt-in to shorter retention (compliance reasons).

## PII masking for non-AUDITOR viewers

`AUDITOR` and `SUPER_ADMIN` roles see full PII (these roles by definition have full data access scope).

When `audit.view` granted to `STORE_MANAGER` (tenant config option), PII fields in event payload are masked unless user also has the corresponding party-side permissions (`parties.view_full_phone`, `parties.view_full_email`).

**Masking patterns** (consistent with 3.A.3 customer modal):

| PII field | Masked form | Example |
|---|---|---|
| Phone | First 4 + asterisks + last 4 | `0532 *** 1234` |
| Email | First char + asterisks + last char of local-part + full domain | `a***t@example.com` |
| Full name | NOT masked (operational necessity) | "Ayşe Yılmaz" |
| Customer/supplier ID (internal) | Visible | `P-3421` |
| Sale internal number | Visible | `PI-2026-1234` |
| Amounts (TRY) | Visible | `₺250,00` |

**Implementation**: `AuditEventSummaryComposer` and raw-JSON expansion both apply masking transform based on viewer's effective permissions. Masking applied at composition time (Java), NOT at storage time — raw audit_event_log payload keeps full PII.

**Rationale**: defense-in-depth. Audit screen shows sensitive event payloads; STORE_MANAGER browsing own-store events doesn't need plain-text customer phones. Tenant data exposure scope follows least-privilege.

**Edge case**: when audit event payload includes nested party objects (e.g. customer name + phone in return payload), masking applies recursively through known PII paths. Composer maintains an allowlist of "PII paths" per event type.
