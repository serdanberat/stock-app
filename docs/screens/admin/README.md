# Phase 3.E — Operational / Admin

> **Status:** Locked
> **Phase:** 3.E
> **Delivery date:** 2026-05-21

Operational and admin surfaces. Cash register lifecycle, user/role management, tenant configuration, reports, audit log browser.

Phase 3.E completes Phase 3. After this, all 31 screens of the production POS/ERP MVP are designed and locked.

## Screens (6)

| # | Screen | Purpose | Key complexity |
|---|---|---|---|
| 3.E.1 | Cash Register Open | Gün başı kasa açılışı | Partial UNIQUE index on (store, register) WHERE status=OPEN; orphan recovery flow |
| 3.E.2 | Cash Register Close + Z Report | Gün sonu sayım | Immutable Z report snapshot; variance reason codes; large variance manager PIN |
| 3.E.3 | User & Role Admin | User CRUD, role + store assignment | Effective permission preview; manager PIN reset audit; last SUPER_ADMIN guard |
| 3.E.4 | Tenant Feature Flags | Tenant-level config | Two-tier (operational vs dangerous); typed confirmation for dangerous flags |
| 3.E.5 | Basic Reports | 5 essential reports | Markup wording (not Margin); snapshot timestamp disclosure; CSV export |
| 3.E.6 | Audit Log Browser | Searchable audit history | Human summary + raw JSON; correlation_id drill-down timeline |

## Locked decisions catalog

### Cash Register Open (3.E.1)
- **One OPEN session per `(store_id, register_id)`**, NOT per user (shift handover supported)
- **Partial UNIQUE index** at DB level: `(tenant_id, store_id, register_id) WHERE status='OPEN'`
- **Orphan recovery flow**: STORE_MANAGER+ can force-close with manager PIN + reconciliation_note (min 20 chars) + counted_cash_count
- **Force-close cash variance**: creates `cash_movement` CORRECTION; audit captures reason

### Cash Register Close + Z Report (3.E.2)
- **Immutable Z report snapshot**: `z_reports` table with `snapshot_payload` JSONB
- **Reprint renders SAME stored payload**, not regenerated
- **Variance tolerance**: `cash_variance_tolerance` default ₺5; above requires reason from closed set
- **Large variance**: `cash_variance_large_threshold` default ₺100 requires manager PIN override
- **Variance reasons**: SHORT_CASHIER_ERROR, SHORT_UNKNOWN, OVER_CASHIER_ERROR, OVER_UNKNOWN, MISCOUNT, SUSPECTED_THEFT (closed set)
- **CLOSING_DEPOSIT** cash movement if bank deposit removed

### User & Role Admin (3.E.3)
- **User CRUD + multi-role + multi-store**
- **Effective permission preview**: merged permissions with origin role per permission
- **Session authorization**: changes effective at next token refresh (~15min) MVP; force-logout v1.1+
- **Self-deactivation blocked**: 403 server enforcement
- **Last SUPER_ADMIN deactivation blocked**: 422 server enforcement
- **Manager PIN force reset**: clears hash; audit event `manager_pin_force_reset`
- **Initial password**: 12 chars mixed; emailed; forced rotation on first login

### Tenant Feature Flags (3.E.4)
- **Two-tier categorization**: OPERATIONAL vs DANGEROUS
- **Operational flags**: edit_operational permission (STORE_MANAGER subset, SUPER_ADMIN full)
- **Dangerous flags**: `allow_negative_stock`, `allow_force_create_duplicate_customer` (v1.1+), `allow_below_cost_pricing`
- **Dangerous flag UX**: typed confirmation phrase per flag (e.g. "negatif stok onaylıyorum")
- **Edit_dangerous**: SUPER_ADMIN only
- **JSONB schema validation server-side**

### Basic Reports (3.E.5)
- **5 reports**: Sales Summary, Stock Valuation, Top Selling Variants, Customer Aging, **Markup Analysis** (NOT "Margin")
- **Snapshot timestamp disclosure** on each report (mview staleness)
- **CSV export** via document worker pattern (Phase 6.F); UTF-8 BOM for Excel
- **No PDF/Excel MVP**: CSV sufficient for accountant Excel import
- **Cache 5min Caffeine**

### Audit Log Browser (3.E.6)
- **Filters**: event_type, actor, party, **correlation_id (CRITICAL)**, store, date, sale_id, free-text
- **Human-readable summary + expandable raw JSON**
- **Correlation drill-down**: loads chronological timeline of related events
- **CSV export** via worker
- **Search index**: GIN on payload JSONB + tenant_id + occurred_at
- **AuditEventSummaryComposer** Java-side (per ADR-019: business logic in Java, not DB function)
- **Default permission**: AUDITOR + SUPER_ADMIN

## Schema additions (Migration 022)

- `cash_register_sessions` with `status`, partial UNIQUE index, `force_close_orphan_reconciliation_note` field
- `z_reports` table: `snapshot_payload` JSONB immutable, `pdf_storage_key`, `generated_at`
- `cash_register_variance_log` with reason codes
- `audit_event_log` enhancements: GIN index on payload, correlation_id indexed, occurred_at indexed
- `tenant_settings_log` for change history (already in Phase 2D base; ensure typed_confirmation_phrase field)

See `migrations/022_admin_extensions.sql`.

## Audit event catalog (Phase 3.E additions)

### Cash Register
| Event | Triggered by |
|---|---|
| cash_session_opened | OPEN with opening_float |
| cash_session_force_closed_orphan | Manager force-close of orphaned session |
| cash_session_open_blocked_orphan_exists | Open attempt when orphan present |
| cash_session_closed | CLOSED |
| cash_session_closed_with_variance | Variance > tolerance |
| cash_session_closed_large_variance_override | Variance > large_threshold |
| z_report_generated | Async after close |
| z_report_reprinted | Reprint of stored snapshot |

### User Admin
| Event | Triggered by |
|---|---|
| user_created | Admin create |
| user_updated | Admin edit |
| user_deactivated / user_reactivated | is_active toggle |
| user_role_assigned / user_role_removed | Role change |
| user_store_assigned / user_store_removed | Store change |
| user_password_reset | Admin reset |
| manager_pin_force_reset | Admin PIN reset |

### Tenant Settings
| Event | Triggered by |
|---|---|
| tenant_setting_changed | Any flag change |
| dangerous_flag_toggled | Dangerous flag change (separate for SIEM filtering) |

## API endpoints (Phase 3.E additions)

| Endpoint | Purpose |
|---|---|
| POST /cash-register/open | Open session |
| GET /cash-register/current | Get open session for store/register |
| GET /cash-register/sessions/{id}/summary | Pre-close summary |
| POST /cash-register/sessions/{id}/close | Close with reconciliation |
| POST /cash-register/sessions/{id}/force-close | Orphan recovery |
| GET /cash-register/sessions/{id}/z-report | View/reprint stored snapshot |
| POST /admin/users/search | User list |
| POST /admin/users | Create user |
| PATCH /admin/users/{id} | Edit user |
| GET /admin/users/{id}/effective-permissions | Effective permission preview |
| POST /admin/users/{id}/reset-password | Admin password reset |
| POST /admin/users/{id}/reset-manager-pin | PIN force reset |
| GET /admin/settings | Get tenant settings |
| PATCH /admin/settings | Update settings (with confirmation phrase for dangerous) |
| GET /reports/{type} | Report data (5 types) |
| POST /reports/{type}/export | CSV export request (async) |
| POST /admin/audit-log/search | Audit log search |
| POST /admin/audit-log/export | Audit CSV export |

## What's NOT in Phase 3.E scope

- Force-logout for permission changes — v1.1+ (MVP: token refresh ~15min)
- Excel/PDF report export — v1.1+ (CSV only MVP)
- Custom report builder — v1.1+
- Real-time dashboards — v1.1+
- Audit log alerting/SIEM integration — v1.1+ (events emitted, alerting external)
- Role customization (define new roles) — v1.1+ (fixed roles MVP)
- Per-permission denial rules — v1.1+ (additive-only MVP)
- Multi-tenant SUPER_ADMIN cross-tenant view — never (tenant isolation)
- Subscription / billing administration — v1.1+
