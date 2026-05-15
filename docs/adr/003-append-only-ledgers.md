# ADR 003 — Append-Only Ledgers for Stock and Finance

> **Status:** Accepted
> **Date:** 2026-05-15

## Context

Retail ERP systems require trustworthy historical records:

- Tax authorities and external auditors expect that posted records cannot be retroactively edited.
- Margin reports must remain stable: the profit on a sale completed three months ago must not change because today's average cost has shifted.
- Disputes (customer credit, supplier reconciliation, stock discrepancies) need a verifiable trail.
- Errors must be correctable without losing the original record.

A naïve design that stores current stock and current balance as mutable columns cannot meet these requirements without parallel audit tables — and even then, mutation invites subtle bugs (lost updates, partial corrections, drift between the "live" state and the "history" state).

## Decision

Two ledger tables are **append-only**:

| Table | Purpose |
|---|---|
| `stock_movements` | Every IN/OUT of physical stock |
| `account_movements` | Every DEBIT/CREDIT on a current account |

Their projections (`stock_balances`, `account_balances`, `account_aging`) are maintained by the application service inside the same transaction as the ledger insert.

### Append-only enforcement

- `REVOKE UPDATE, DELETE` on these tables from the application role.
- A guard trigger raises an exception on any UPDATE/DELETE attempt (defence in depth — even if a DBA accidentally grants privileges).
- The trigger contains no business logic, only the immutability check.

### Reversal pattern

To correct an error:
1. INSERT a new movement with `reverses_movement_id` pointing at the original.
2. The new row carries the **opposite direction** and the **same quantity/amount**.
3. The original row is **never** modified.
4. **Reversal of a reversal is forbidden.** Create a new clean corrective movement instead.

The system computes "is this movement still active?" with a subquery:
```sql
NOT EXISTS (SELECT 1 FROM stock_movements WHERE reverses_movement_id = original.id)
```

### Cost snapshot at sale

When an OUT movement is recorded for a sale:
- `InventoryService` looks up the current WAC for that `(variant, store)` pair.
- That value is written into the movement AND copied into `sale_items.unit_cost_try`.
- This snapshot makes historical margin reporting trivial and stable.

### Projection update rule

`stock_balances` and `account_balances` are maintained:
1. **Primary** — by the application service inside the same transaction as the ledger insert, with `SELECT ... FOR UPDATE` on the projection row.
2. **Safety net** — a nightly reconciliation job verifies that the projection equals the sum of the ledger; alerts on drift.
3. **Recovery** — an admin command `rebuild_*_balances(...)` recomputes the projection from the ledger for disaster recovery.

Triggers do not maintain projections (see ADR 002 / cross-cutting trigger policy): keeping business logic in the application service makes it testable, visible, versionable.

### Partitioning roadmap

As ledgers grow, they will be partitioned by `occurred_at` (monthly partitions). Retention policy keeps recent partitions hot, older partitions warm, and very old partitions in compressed cold storage. Trigger for migration: total rows > 5M or disk pressure.

## Rationale

- **Auditability** — the ledger *is* the audit log for the domain that matters most (stock, money).
- **Stable history** — historical margins do not move when cost methods or current prices change.
- **Corrections are explicit** — a reversal is visible in the ledger; nothing happens silently.
- **Time-travel queries** — "what was the stock at 14:32 yesterday?" is a sum-up-to-timestamp; no separate audit table needed.
- **Aligns with regulatory expectations** — Turkish tax law and similar regimes require that posted commercial records are not editable.

## Consequences

**Positive:**
- Strong guarantee of historical truth.
- Single source of truth for stock and finance; projections are derivable.
- Easy disaster recovery (replay ledger to rebuild projections).
- Compatible with future event sourcing of specific contexts if desired.

**Negative:**
- More care required in implementation: every change must go through the appropriate service.
- Projections must stay in sync; we mitigate with transactional updates + nightly reconciliation + rebuild command.
- Slightly more storage; cheap for the value delivered.
- Reporting queries on the ledger directly can be slow at scale; mitigated by partitioning, materialised views, and a read replica (v1.1+).

## Alternatives Considered

- **Mutable current-state tables with audit log** — rejected. Two sources of truth that can drift; audit gets bypassed by direct UPDATE.
- **Full event sourcing for all contexts** — rejected for MVP. Heavier ergonomic cost; we get most of the value with append-only ledgers + outbox.
- **Soft-delete only, no reversal pattern** — rejected. Soft-delete on a financial transaction is semantically wrong; the transaction happened.
