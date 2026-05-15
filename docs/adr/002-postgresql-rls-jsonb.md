# ADR 002 — PostgreSQL with Row-Level Security and JSONB

> **Status:** Accepted
> **Date:** 2026-05-15

## Context

The system is multi-tenant, multi-currency, append-only-ledger-heavy, has flexible sectoral metadata, and serves real retail operations under transactional load. We need a database that supports:

- Strong consistency for atomic sale/return/payment completion.
- Row-level isolation between tenants in a shared database.
- Append-only history (immutable ledgers).
- Flexible per-tenant / per-sector metadata without polluting the core schema.
- Time-range exclusion constraints (for non-overlapping price intervals).
- Materialised views for reporting.
- Partial indexes (for scoped uniqueness like internal vs. GS1 barcodes).
- Predictable performance and operational maturity.

## Decision

We will use **PostgreSQL (latest stable LTS at project start)** as the primary database.

We will rely on the following PostgreSQL-specific features by design:
- **Row-Level Security (RLS)** for tenant isolation.
- **JSONB** for tenant/sectoral metadata (`products.metadata`, `parties.metadata`, `tenant_settings.feature_flags`, FX snapshot `rates`, etc.).
- **`EXCLUDE USING gist`** with `tstzrange` for non-overlapping price intervals.
- **Partial unique indexes** (e.g. scoping by `WHERE barcode_scope = 'INTERNAL'`).
- **Materialised views** for reporting projections.
- **Declarative table partitioning** for append-only ledgers (`stock_movements`, `account_movements`, `fx_rates`, `outbox_events`) — see ADR 003.
- **Generated columns** for simple denormalised values.
- **`pg_audit` or row-history triggers** on critical tables for compliance audit.

## Rationale

- **RLS** lets us enforce tenant isolation at the database level. A bug in application code cannot leak rows across tenants if RLS policies are correctly set. The application sets `app.tenant_id` per session; policies filter on it.
- **JSONB** carries the variable parts (sectoral metadata, feature flags, FX snapshot payload, audit metadata) without forcing schema migrations every time a new attribute appears. Indexes on JSONB paths give us query performance where it matters.
- **`EXCLUDE` constraints** are the cleanest way to guarantee non-overlapping validity intervals on `variant_prices`. Application-level checks would be racy under concurrent writes.
- **Partial indexes** give us nuanced uniqueness: e.g. internal barcodes unique per tenant; GS1 barcodes potentially globally unique if needed.
- **Materialised views + outbox-driven refresh** make reporting fast without burdening the transactional path.
- **Declarative partitioning** keeps the append-only ledgers manageable as they grow.
- **Operational maturity:** PostgreSQL is broadly deployable, both as managed (AWS RDS, Azure, GCP, Supabase) and on-premise.

## Consequences

**Positive:**
- A single technology backs every cross-cutting need; we avoid polyglot persistence in MVP.
- Tenant isolation is enforced at the storage layer.
- Schema evolution for sectoral expansion (jewellery, cafe) does not force core schema rewrites — metadata JSONB absorbs it.
- Strong transactional guarantees for the hot path (POS).
- Operationally well-understood.

**Negative:**
- We are bound to PostgreSQL. Switching engines later would be costly. Acceptable trade-off given the feature set we rely on.
- RLS policies require care; they can be a footgun if misconfigured. Mitigated by integration tests that exercise tenant boundary scenarios.
- JSONB-heavy schemas can hide structure; we will validate JSONB payloads at the application layer using strict schemas (e.g. Zod / Pydantic).

## Alternatives Considered

- **MySQL / MariaDB** — rejected. No native RLS; JSONB-equivalent (JSON) is less ergonomic; no EXCLUDE constraints.
- **SQL Server** — rejected. Licensing cost and on-premise distribution friction; less common in our deployment target.
- **MongoDB / document store** — rejected. We need strict transactional guarantees for sale completion across multiple tables; relational with selective JSONB is the right tool.
- **CockroachDB / distributed SQL** — rejected for MVP. Operational complexity not justified; can be revisited if a tenant needs multi-region distribution.

## Revisit Criteria

- A single tenant exceeds a comfortable PostgreSQL operational scale (millions of stock movements per day per tenant) and partitioning is not sufficient.
- We discover a hard requirement that PostgreSQL cannot satisfy (unlikely for our domain).
