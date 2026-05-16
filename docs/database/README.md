# Database Schema

> **Status:** Locked (Phase 2E)
> **Last updated:** 2026-05-15
> **Total:** 68 tables + 5 materialized views

This directory contains the complete database schema design for the stock_app retail ERP/POS system. The schema is partitioned into three documentation files (Part 1–3), accompanied by executable SQL migration files under `/migrations/`.

---

## Files

| File | Contents |
|---|---|
| [`conventions.md`](./conventions.md) | Naming, RLS pattern, ON DELETE policy, append-only enforcement, indexes, triggers |
| [`part-1-foundation.md`](./part-1-foundation.md) | Identity, Catalog, Inventory contexts (27 tables) |
| [`part-2-sales-purchasing.md`](./part-2-sales-purchasing.md) | Sales, Returns, Purchasing contexts (15 tables) |
| [`part-3-financial-outbox.md`](./part-3-financial-outbox.md) | Party, FX, Financial, Cash Register, Outbox, Audit contexts (26 tables) + 5 materialized views |
| [`seed-data.md`](./seed-data.md) | System seed data (currencies, FX sources, roles, reason codes) + tenant onboarding seed |

---

## Schema Totals

| Context | Tables |
|---|---|
| Identity | 5 |
| Catalog | 12 |
| Inventory | 10 |
| Sales | 5 |
| Returns | 4 |
| Purchasing | 5 |
| Shared (sales/purch) | 1 |
| Party | 3 |
| FX | 4 |
| Financial | 7 |
| Cash Register | 6 |
| Outbox & Cross-Cutting | 6 |
| **Total tables** | **68** |
| Materialized views | 5 |
| **Total objects** | **73** |

---

## Migration Order

The migration files in `/migrations/` are numbered in execution order. Key principle: **system seed data must be loaded before tables that FK-reference it.**

```
000_extensions.sql              -- uuid-ossp, pg_trgm, btree_gist, citext
001_foundation.sql              -- tenants (no domain dependencies)
002_system_seed_lookups.sql     -- currencies, fx_rate_sources, roles, reason_codes (tenant_id NULL)
                                -- MUST come before tables that FK-reference these
003_identity.sql                -- users, user_role_assignments, stores
004_fx_data.sql                 -- fx_rates, fx_snapshots
005_catalog.sql                 -- categories ... variant_prices
006_inventory.sql               -- stock_movements ... stock_adjustments
007_party.sql                   -- parties, party_contacts, party_documents
008_financial.sql               -- account_profiles ... account_aging
009_cash_register.sql           -- cash_registers ... z_reports
010_sales.sql                   -- sales ... document_sequences
011_returns.sql                 -- returns, exchange_groups
012_purchasing.sql              -- purchase_invoices ... purchase_return_items
013_outbox.sql                  -- outbox_events, processed_events, audit_*
014_materialized_views.sql      -- daily_sales_summary, ...
015_tenant_onboarding_template.sql  -- Template called by application on tenant CREATE
```

### Two-stage seed pattern

**Stage A — System seed (migration time, run once):**
- `currencies` (TRY active; USD, EUR, GBP active; XAU, XAG, etc. defined inactive)
- `fx_rate_sources` (TCMB, HAREM, MANUAL active; others defined inactive)
- `roles` (6 system roles with `tenant_id IS NULL`)
- `reason_codes` (system-wide entries with `tenant_id IS NULL`)

**Stage B — Tenant onboarding seed (application-driven, per new tenant):**
- VIRTUAL_IN_TRANSIT store (Phase 2A invariant)
- Tenant-specific attribute types (Color, Size, Material, Model, Gender)
- Default price list (DRAFT)
- Tenant settings JSONB defaults
- Initial owner user + SUPER_ADMIN role assignment

See [`seed-data.md`](./seed-data.md) for full details.

---

## Architectural Foundations Reflected

Every decision from Phases 1–2D is reflected in the schema:

| Phase decision | Schema reflection |
|---|---|
| Append-only stock + financial ledgers (ADR 003) | `stock_movements`, `account_movements`, `cash_movements`, `fx_rates` — REVOKE UPDATE/DELETE + immutability triggers |
| Cost snapshot immutable | `sale_items.unit_cost_try`, `return_items.unit_cost_try`, `purchase_invoice_items.unit_cost_try` — triggers prevent modification after parent commit |
| FX snapshot pattern | `fx_snapshots` table + `fx_snapshot_id` FK on sales, returns, purchase_invoices, payments, sale_payments, cash_movements |
| Multi-tenancy with RLS (ADR 007) | Every domain table has `tenant_id` + RLS policy using `current_tenant_id()` function |
| Outbox pattern (ADR 004, 008) | `outbox_events` with full envelope, DLQ states, partition_key |
| Domain events (Phase 2D) | ~60 event types, schema versioning, partition by `aggregate_id`, consumer idempotency via `processed_events` |
| Sagas (Phase 2D) | `process_instances` for stateful flows; `exchange_groups`, `transfers` retain their own state |
| Idempotency keys mandatory | `idempotency_key` columns on Sale, Return, PurchaseInvoice, Payment, RegisterSession.close, Transfer.dispatch/receive, CountSession.complete, StockAdjustment.create |
| Administrative reversal (Phase 2C) | Operational flag columns (`administratively_reversed_at`, `*_by_user_id`, `*_reason`) — not state machine transitions |
| Terminal-pending sales (Phase 2C) | `sales.terminal_pending` + `terminal_pending_metadata` JSONB |
| Variant uniqueness | `stock_balances` PK = `(tenant_id, variant_id, store_id)` |
| Gap-free Z report numbers | `z_report_number_sequence` UPDATE-based allocator with `z_report_sequence_audit` |
| Payment reversal (FULL + PARTIAL) | `payments.reversal_info` JSONB + `payment_allocations.is_reopened` flag |
| Security stream separation (ADR 008) | `security_audit_log` separate from `outbox_events` |

---

## Cross-References

- Conventions: [`conventions.md`](./conventions.md)
- ADR 002 (PostgreSQL + RLS + JSONB): [`../adr/002-postgresql-rls-jsonb.md`](../adr/002-postgresql-rls-jsonb.md)
- ADR 003 (Append-only ledgers): [`../adr/003-append-only-ledgers.md`](../adr/003-append-only-ledgers.md)
- ADR 007 (Multi-tenancy + RLS): [`../adr/007-multi-tenancy-shared-db-rls.md`](../adr/007-multi-tenancy-shared-db-rls.md)
- ADR 008 (Domain events + outbox): [`../adr/008-domain-events-and-outbox.md`](../adr/008-domain-events-and-outbox.md)

---

## Open Items (Roadmap)

- **v1.1+ partitioning**: `stock_movements`, `account_movements`, `fx_rates`, `outbox_events`, `processed_events` — migrate to RANGE partitioning when row counts exceed thresholds (5M / 10M).
- **v1.1+ Currency FK**: tighten `currency VARCHAR(10)` to `REFERENCES currencies(code)` system-wide.
- **v1.1+ Granular permissions**: migrate `roles.permissions TEXT[]` to `permissions` + `role_permission_grants` relational model.
- **v1.1+ Return approval reasons**: migrate `returns.approval_reasons TEXT[]` to lookup table.
- **v1.1+ `ingested_at` column**: add to append-only tables for offline POS sync support.
- **v1.1+ Sequence sharding**: address `document_sequences` hot-row contention if >50 commits/sec/store observed.
- **v2 Zone/bin counts**: extend `count_sessions` to support parallel zone-scoped counting for warehouses.
