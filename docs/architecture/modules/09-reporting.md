# Module: reporting

> **Status:** Locked (Phase 4)
> **Bounded context:** Reporting & Audit

## Position in dependency graph

```
identity, catalog, pricing, inventory, sales, purchasing, finance, cashregister
                                ↑ (Q)
                            reporting
```

Reporting depends on **all** other modules but **only via query services**. Reads, never writes. Strictly read-only consumer.

## What reporting is

Two responsibilities merged into one module per Phase 4 decision:

1. **Reports**: 5 essential MVP reports (Sales Summary, Stock Valuation, Top Selling, Customer Aging, Markup Analysis) per §3.E.5
2. **Audit Log Browser**: searchable interface over `audit_event_log` per §3.E.6

Both are read-only operational visibility surfaces. Same patterns (filters, CSV export, dashboard cards). Same audience (managers, accountants, auditors).

## NOT in reporting

- **NOT a projection-builder**: Phase 4 decision (§Phase 4.2 reporting scheduled refresh): reporting does NOT consume domain events to maintain its own projection tables. Materialized views refreshed on schedule (Phase 6.G ShedLock).
- **NOT event-driven**: no eventconsumer/ folder. Read-only Q from upstream + mview reads.
- **NOT authoritative**: stock valuation report ≠ inventory truth. Always carries "snapshot at HH:MM" timestamp.

## Aggregate roots

NONE. Reporting has no domain aggregates; it's a read-only consumer module. Only query services.

## Package structure

```
io.stockapp.reporting/
├── api/
│   ├── ReportController.java                # /reports/* (5 reports + index)
│   ├── AuditLogController.java              # /admin/audit-log/*
│   └── dto/
├── application/
│   └── query/                               # NO command/, NO orchestrator/
│       ├── SalesReportService.java
│       ├── StockValuationReportService.java
│       ├── TopSellingReportService.java
│       ├── CustomerAgingReportService.java
│       ├── MarkupAnalysisReportService.java
│       ├── AuditLogSearchService.java
│       ├── AuditEventSummaryComposer.java   # Java-side, per ADR-019 + 3.F.8
│       └── CsvExportService.java            # delegates to document worker
├── domain/                                  # value objects only; no aggregates
│   ├── report/
│   │   ├── ReportPeriod.java                # value object
│   │   ├── SalesSummary.java                # response model (DTO-shaped)
│   │   ├── StockValuationRow.java
│   │   └── ...
│   └── audit/
│       └── AuditEventView.java              # composed view (summary + payload)
└── infrastructure/
    └── persistence/                         # JOOQ queries against mviews
        ├── projection/                      # mview accessors
        │   ├── DailySalesProjectionDao.java
        │   ├── StockValuationProjectionDao.java
        │   ├── CustomerAgingProjectionDao.java
        │   ├── TopSellingProjectionDao.java
        │   └── MarkupAnalysisProjectionDao.java
        └── audit/
            └── AuditEventLogDao.java
```

## Transaction ownership

ALL operations `@Transactional(readOnly = true)`. No write semantics anywhere.

| Operation | Boundary |
|---|---|
| Any report query | READ_ONLY |
| Audit log search | READ_ONLY |
| CSV export trigger | READ_ONLY (delegates to document worker via outbox) |

## Outbox events emitted

| Event | When | Consumers |
|---|---|---|
| `CsvExportRequestedEvent` | User clicks [CSV İndir] | document worker (Phase 6.F) |

Only one outbound event. No domain events.

## Outbox events consumed

**NONE** per Phase 4 decision (reporting scheduled refresh model, not event-driven).

Scheduled jobs (Phase 6.G ShedLock):
- `RefreshSalesSummaryProjection` — runs every 5 min
- `RefreshStockValuationProjection` — runs every 10 min
- `RefreshCustomerAgingProjection` — runs every 30 min
- `RefreshTopSellingProjection` — runs every 1 hr
- `RefreshMarkupAnalysisProjection` — runs every 1 hr

`MATERIALIZED VIEW REFRESH CONCURRENTLY` per view; no read blocking.

## ArchUnit rules

- `reporting_never_uses_command_services` (no @Service from `*.application.command`)
- `reporting_uses_query_services_not_repositories` (no direct repository/JPA imports)

## Cache invalidation hooks

| Cache key | Invalidated by | Bypass |
|---|---|---|
| `report:{type}:{tenant_id}:{period}` | Scheduled (Caffeine TTL 5min) | `[⟳ Yenile]` button sends `Cache-Control: no-cache` per §3.F.5 |
| `audit-log-page:{tenant_id}:{filter-hash}` | Auto-expire (Caffeine TTL 1min for recent pages) | Per-request |

## Key invariants

1. **Read-only — never writes** (Kategori A ArchUnit): no @Service in `*.application.command`. Compile-time enforcement.

2. **No repository injection** (Kategori D shared kernel discipline + reporting-specific rule): repositories live in module infra; reporting uses query services or projection DAOs. ArchUnit blocks repository injection antipattern.

3. **Projections NON-authoritative** (§Phase 4.2 user requirement): every report header shows snapshot timestamp ("Veriler: 14:32'de yenilendi"). Stock valuation specifically: "Stok değeri projection'dan alınmıştır. Anlık tutarsızlık ~1-2dk."

4. **Audit summary composed Java-side** (ADR-019 + §3.F.8): `AuditEventSummaryComposer` per event_type. NOT a DB function.

5. **PII masking for non-AUDITOR** (§3.F.8): `AuditEventSummaryComposer` and raw-JSON expansion both apply masking transform based on viewer's effective permissions. AUDITOR/SUPER_ADMIN see full PII.

6. **5-year audit retention** (§3.F.6): no deletion endpoint; no purge MVP. Turkish VUK compliance.

7. **Markup wording, not Margin** (§3.E.5 + §3.F.6): formula `(price - WAC) / WAC × 100`. Service named `MarkupAnalysisReportService`, never `MarginAnalysisReportService`.

8. **CSV export via document worker** (Phase 6.F): UTF-8 BOM for Excel compatibility (Türkçe karakterler). Filename `report-{type}-{period}-{generated_at}.csv`.

9. **Refresh button bypasses Caffeine cache** (§3.F.5): `Cache-Control: no-cache` header or `?fresh=true` param.

## Public API surface

NONE outbound. Reporting is a leaf consumer. Other modules don't depend on reporting; reporting only exposes API to users (via /reports/*, /admin/audit-log/*).

## Why no eventconsumer/ folder

Phase 4.2 decision: event-driven reporting projection adds complexity (replay, lag, ordering, poison events, rebuild tooling) that MVP doesn't need. Scheduled refresh is simpler and sufficient.

v1.1+: if real-time dashboards needed, event-consume model can be added without disrupting other modules — just adds new folder + listeners to reporting.
