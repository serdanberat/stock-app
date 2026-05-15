# ADR 007 — Multi-Tenancy: Shared Database with Row-Level Security

> **Status:** Accepted
> **Date:** 2026-05-15

## Context

The product is offered as SaaS to many tenants (clothing/boutique stores), with on-premise installation also supported. Multi-tenant data isolation models range from "schema per tenant" or "database per tenant" (strong isolation, expensive) to "shared DB with tenant_id column" (cheap, requires discipline).

Each tenant has:
- Variable scale (one shop or a 20-store chain).
- Sensitive commercial data (sales, customers, prices).
- Tax-record retention obligations (10 years in Turkey).
- An expectation that no other tenant can ever see their data.

## Decision

We use a **shared database** with:

1. **`tenant_id` on every domain table.**
2. **PostgreSQL Row-Level Security (RLS)** policies on every domain table.
3. **Session-scoped `app.tenant_id`** set by the application on every request.
4. **A dedicated background-worker role** with explicit `tenant_id` scoping per job.
5. **PII anonymisation, encrypted cold storage, and a 10-year retention floor**, with hard deletion forbidden for commercial records (see retention section below).

### `tenant_id` propagation

- Every domain table carries `tenant_id` as a NOT NULL column with a foreign key to `tenants(id)`.
- API request flow:
  1. Authentication resolves user → tenant.
  2. The HTTP middleware sets `SET LOCAL app.tenant_id = '<uuid>'` for the duration of the request transaction.
  3. RLS policies reference `current_setting('app.tenant_id')::uuid`.
- Background workers set the tenant scope explicitly per job (no implicit context).

### RLS policy shape

A representative policy:
```sql
ALTER TABLE sales ENABLE ROW LEVEL SECURITY;
CREATE POLICY tenant_isolation_sales ON sales
  USING (tenant_id = current_setting('app.tenant_id')::uuid);
```

The same shape applies to every domain table. Schema migrations enforce: any new table must declare `tenant_id` and an RLS policy.

### Tenant lifecycle and data retention

```
TRIAL → ACTIVE → SUSPENDED → CHURNED → ARCHIVED → (physical purge only after 10 years)
```

- **TRIAL** — 30 days from sign-up.
- **ACTIVE** — paid; full access.
- **SUSPENDED** — auto on payment delay (7+ days), or manual policy violation. Read-only; no new operations; existing register sessions may complete the day. Tenant can reactivate by clearing the balance.
- **CHURNED** — 90 days suspended without recovery. Login still available for data export (30-day grace). All operational features off.
- **ARCHIVED** — 30 days after CHURNED. PII is anonymised (`users.email`, `users.name`, `parties.display_name`, `parties.tax_id`, `parties.contacts` masked or removed). **Commercial records (Sale, Invoice, Payment, AccountMovement, StockMovement, FxSnapshot) are retained.** Data is moved to encrypted cold storage.
- **PHYSICAL PURGE** — only after 10 years, by Anthropic admin, with a compliance archive of raw data left behind. Aligned with Turkish VUK retention requirements (5–10 years for tax records).

### What is never hard-deleted

- Sales, Returns, Invoices, Payments, AccountMovements, StockMovements, ZReports, FxSnapshots — these are commercial records.
- Audit logs.

### What is anonymised on ARCHIVED

- PII fields on `users` and `parties`.
- `party_contacts`.
- Free-text notes that may contain personal data.
- Customer-facing references on commercial records are rewritten to point at anonymised stub identities.

### On-premise deployments

For on-premise installations:
- Single-tenant deployments still set `app.tenant_id` for code uniformity.
- Cross-tenant queries are impossible by configuration (only one tenant exists).
- Backup/restore is the tenant's responsibility; the system provides a one-click export.

## Rationale

- **Cheapest scalable model.** A single database handles thousands of tenants comfortably.
- **Defence in depth.** Application code mistakes cannot leak cross-tenant data; RLS enforces at the storage layer.
- **Operational simplicity.** One DB to back up, monitor, upgrade, partition.
- **Migration simplicity.** Schema changes apply globally; no fan-out across N databases.
- **On-premise compatible.** Same code, same migrations, runs single-tenant.

### On retention specifically

Hard-deleting a tenant's commercial records would expose us and the tenant to legal risk:
- Tax authority audits years after the fact.
- Customer disputes.
- Anti-fraud or compliance investigations.

The ARCHIVED + anonymisation + cold-storage model gives us a defensible position: PII is purged (privacy obligation), commercial records are preserved (tax obligation), data is moved off the hot path (cost).

## Consequences

**Positive:**
- Strong tenant isolation enforced at multiple layers.
- Compliant data retention out of the box.
- Affordable to operate.
- Schema migrations are simple.

**Negative:**
- A noisy-neighbour tenant could affect performance. Mitigated by per-tenant rate limits, monitoring, and the ability to migrate a tenant to a dedicated DB if needed.
- A single DB outage affects all tenants. Mitigated by HA replicas and read replicas (v1.1+).
- A bug in RLS policy is critical. Mitigated by:
  - A test suite that connects as a tenant role and verifies it cannot see other tenants' data on every table.
  - Schema-migration linting that fails CI if a new table lacks `tenant_id` or an RLS policy.

## Alternatives Considered

- **Schema per tenant** — rejected for MVP. Higher operational complexity for migrations and connection pooling; harder reporting across the fleet (for our own analytics).
- **Database per tenant** — rejected for SaaS. Strongest isolation but high infrastructure and operational cost. Reserved as an option for enterprise tenants that demand it (revisit when concrete demand appears).
- **No RLS, application-only tenant_id filtering** — rejected. One missing `WHERE tenant_id = ?` is a catastrophic data leak.

## Revisit Criteria

- Enterprise tenant requires dedicated infrastructure (move to DB-per-tenant for that tenant only).
- Performance contention from a noisy tenant cannot be solved by tuning; isolate that tenant.
- Regulatory regime in a new country requires data residency that our shared DB cannot meet.
