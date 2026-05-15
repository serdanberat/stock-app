# ADR 009 — Sagas, Eventual Consistency, Replay and Rebuild

> **Status:** Accepted
> **Date:** 2026-05-15
> **Builds on:** ADR 003 (Append-Only Ledgers), ADR 004 (Outbox), ADR 008 (Domain Events)

## Context

Phase 2D introduced the multi-transaction flows the system needs (Exchange, Transfer, DayEndClose, TenantLifecycle, SaleDocumentGeneration) and surfaced a subtle but high-impact question: **when a projection or consumer is rebuilt, where does the data come from — the outbox archive, or the source-of-truth tables?**

We also need a clear policy on what is and is not allowed to be eventually consistent, what reversibility means for archival, and how a saga recovers from a partial outcome.

## Decision

Five locked decisions.

### 1. Eventual consistency is allowed only outside the hot path

The atomic transactions (`Sale.complete()`, `Return.complete()`, `Payment.complete()`, `PurchaseInvoice.post()`, `RegisterSession.close()`, `Transfer.dispatch()/.receive()`, `CountSession.complete()`) write **all** of their consequences within a single COMMIT: domain entity, ledger movements, balances, register movements, account-profile updates, document stubs, outbox events.

Anything else may be eventually consistent: reporting projections, document PDFs, printer dispatch, e-document submission, notifications, marketplace sync, cache invalidation, audit fan-out.

This bright line keeps user-visible business outcomes (money, stock, receipts) strongly consistent and confines latency to side effects the user does not directly perceive.

### 2. Process managers, not distributed transactions

Multi-transaction flows are coordinated by **process managers** — see [`saga-processes.md`](../architecture/saga-processes.md). Each step is its own atomic transaction; the process manager observes outbox events and decides on the next step.

We **do not** use compensating transactions in the strict saga sense. Each multi-step flow is designed so that a stuck partial outcome is itself a valid business state:

- **ExchangeProcess** — if step 2 (new sale) is never executed, the customer simply retains a credit balance from step 1's return. The credit is consumed at a future visit; nothing needs to be undone.
- **TransferProcess** — if `receive()` is delayed, stock simply remains in the virtual IN_TRANSIT store. Operations dashboard surfaces the delay (`TransferDelayed` event); an administrative reversal can correct genuine losses.
- **DayEndClose** — partial CLOSING-state outcomes are recoverable: terminal-pending sales remain AWAITING_PAYMENT and are flagged `requires_manual_reconciliation`; non-pending sales become ABANDONED.

Where corrections are needed after a multi-step flow has committed, the administrative-reversal pathway (operational flags) is used — not a saga rollback.

This approach trades the rare elegance of automatic compensation for production reality: in retail, partial outcomes are usually preferable to "undo everything", and explicit human reversal is preferable to surprise rollbacks.

### 3. Projection rebuild source: append-only ledgers, not outbox archive

When a projection (`stock_balances`, `account_balances`, `account_aging`, `daily_sales_summary`, …) needs to be rebuilt — because of a bug fix, a new projection version, a recovery from drift — the rebuild reads directly from the **append-only source tables**, not from the outbox archive.

Rationale:

- `stock_movements` and `account_movements` are the actual source of truth. The outbox is a transient integration mechanism.
- This decouples projection correctness from outbox retention. We can prune `PUBLISHED` outbox rows aggressively (90 days default) without endangering rebuilds.
- A rebuild from source remains correct even when the outbox has lost or never recorded an event (which can happen if a producer bug emitted a malformed payload that went to DLQ, while the source row was still written correctly within the COMMIT).

Implementation: admin commands `rebuild_stock_balances`, `rebuild_account_balances`, `rebuild_reporting_views`, `rebuild_search_index`, each parameterised by tenant and optionally narrower scope.

Replay (rerunning an outbox event through a specific consumer) remains supported for cases where the outbox event itself carried analytical metadata the source row does not (e.g. correlation_id, causation_id for incident analysis). Replay window matches outbox retention.

### 4. Nightly reconciliation detects drift but does not auto-rebuild

A background job at 02:00 local time, per tenant, compares projections against the ledgers:

```
expected_qty = SUM(stock_movements active rows)  -- excluding reversed rows
actual_qty   = stock_balances.quantity
if expected != actual → emit ReconciliationDriftDetected
```

The job emits the `ReconciliationDriftDetected` event and stops. **It does not silently rebuild** because:

- Drift is usually a symptom of a bug or operational anomaly; we want a human to look at it.
- Automatic rebuild could mask repeated drift caused by an ongoing bug.

An operator triggers `rebuild_stock_balances` (or the equivalent) after triage.

### 5. PII anonymisation is irreversible by default; reversible pseudonymisation is opt-in

`TenantArchived` runs irreversible anonymisation by default. The PII fields on `users` and `parties` are overwritten with synthetic values. Original values are destroyed.

Commercial records (Sale, Invoice, Payment, `account_movements`, `stock_movements`, `z_reports`, `fx_snapshots`) are preserved through the 10-year VUK-aligned retention floor. Hard deletion before that floor is forbidden.

For the rare tenant on a special contract addendum (regulatory edge case where reversibility may be required), reversible pseudonymisation is available. PII is encrypted with a tenant-specific key kept in a separate vault / HSM. Reversal requires both a court order and HSM access. This is an explicit opt-in, billed separately, and tenant settings carry the `anonymization_method` flag (`IRREVERSIBLE` | `REVERSIBLE_PSEUDONYMIZATION`).

`TenantArchived` event payload records the chosen method so downstream consumers know what they observed.

## Rationale

### Why projection-from-source rather than projection-from-outbox?

The append-only ledgers are designed as source of truth. They survive every kind of integration failure: a publisher bug, a consumer outage, an outbox-retention pruning policy, a DLQ entry. Building projections from them is the simplest, most robust path. The outbox carries the *narrative* of events (with metadata); the ledgers carry the *facts*. For rebuilds, facts are what matters.

If a projection were rebuilt from outbox archive, we would have to commit to indefinite outbox retention (storage cost) and to never having any consumer race with the producer (semantic complexity). Both are avoidable.

### Why process managers and not "real" sagas with automatic compensation?

In retail operations, partial outcomes usually reflect partial real-world states. Stock in transit that has not arrived is **actually in transit** — undoing the dispatch automatically would be wrong; the carrier still has the goods. A customer who returned an item and then walked away truly does have a credit. The system models reality; reality is not transactional.

For the rare case where a multi-step outcome is genuinely wrong, the administrative-reversal pathway provides a human-driven, audit-logged path that emits compensating movements. That is a more honest representation of how stores actually handle mistakes.

### Why irreversible anonymisation by default?

It is the only configuration that satisfies GDPR's right-to-be-forgotten without ambiguity. Reversible pseudonymisation, while occasionally needed, leaves a re-identification surface — its presence in default would be a privacy regression.

VUK retention obliges us to keep commercial records for at least 10 years. The data we may delete (PII) is delete-able; the data we may not delete (commercial records) is anonymised at the references and preserved.

## Consequences

**Positive:**
- Hot-path correctness is bulletproof; eventual consistency lives only where it cannot harm the user.
- Rebuilds are correct, simple and robust to outbox failure modes.
- Operational maturity (drift detection without surprise auto-fix) is built in.
- Compliance posture is defensible: PII is anonymised, commercial records preserved, retention floor explicit.
- Sagas do not require a complex compensation framework.

**Negative:**
- Each multi-step flow needs careful design to make partial outcomes safe. Mitigated by the saga catalogue and by review.
- Drift detection requires human triage on each event. Mitigated by the fact that drift should be rare and worth investigating.
- Reversible pseudonymisation is an extra-cost feature; some tenants may request it without understanding its limitations. Mitigated by documentation and contractual gating.

## Alternatives Considered

- **Strict sagas with compensation.** Rejected: production retail systems get more value from honest partial outcomes than from automated rollbacks of physical-world events.
- **Projection rebuild from outbox archive.** Rejected: forces indefinite outbox retention, doubles the cost of integration storage, conflates "audit log" with "source of truth".
- **Auto-rebuild on drift detection.** Rejected: masks bugs and operational issues we should see.
- **No default PII anonymisation, opt-in only.** Rejected: weakens GDPR posture; would force every tenant to opt in.
- **Hard delete after CHURNED, no archival.** Rejected: violates VUK retention; exposes tenants and us to audit risk.

## Open Items

- **TODO** — Drift detection thresholds (acceptable rounding error vs. actionable drift). To be calibrated during Sprint 10 hardening with real workloads.
- **TODO** — Documentation page for reversible-pseudonymisation tenants (key vault setup, court-order process). Drafted alongside first such contract.
