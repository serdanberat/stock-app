# Saga and Process Manager Flows

> **Status:** Locked (Phase 2D)
> **Last updated:** 2026-05-15

Most state changes in the system happen inside a single atomic transaction (see [`transaction-boundaries.md`](./transaction-boundaries.md)). A small number of business operations span **multiple transactions or a long time window**. Those are coordinated by **process managers** (sometimes called sagas).

This document defines every multi-step flow, its triggers, its steps, what is and is not atomic, and how it recovers from failure.

---

## 1. Process-Manager Pattern

A process manager is a piece of code that:

1. Subscribes to outbox events that mark steps in the flow.
2. Maintains its own state (a `process_instances` row) keyed by a correlation identifier such as `exchange_group_id` or `transfer_id`.
3. Decides on the next step.
4. Either invokes a domain service (which runs its own atomic transaction) or schedules a delayed job.

Process managers are **idempotent**: replaying their inbound events produces the same end state.

Process managers are **not** allowed to:
- Hold cross-step database transactions.
- Block the publisher or any domain service.
- Bypass the standard idempotency contract.

---

## 2. Saga Catalog

The MVP set of process managers.

### 2.1 ExchangeProcess

**Purpose:** Coordinate an exchange (customer returns an item and takes another) as two sequential atomic transactions linked by `exchange_group_id`.

**Why not a single transaction?** Two reasons:
1. The user experience is naturally two-step (return first, then pick new item).
2. Recovery: if the second step (new sale) fails, the customer retains a credit balance — no compensation is needed.

**Flow:**

```
Trigger: cashier starts exchange UI flow
Allocate: exchange_group_id (UUID), persisted in a row in exchange_processes

Step 1: Return.complete()           [Transaction 1]
  - return.exchange_group_id = X
  - stock IN movements
  - AccountMovement CREDIT to customer balance (currency-scoped)
  - Outbox emits ReturnCompleted with exchange_group_id

Process manager observes ReturnCompleted with exchange_group_id:
  - Marks step 1 done in exchange_processes
  - Sets a soft timeout (e.g. 30 minutes) for step 2

Step 2: Sale.complete()             [Transaction 2]
  - sale.exchange_group_id = X
  - stock OUT movements
  - SalePayment with tender_type = CUSTOMER_BALANCE (drawing from credit)
  - AccountMovement DEBIT offsetting the credit
  - Outbox emits SaleCompleted with exchange_group_id

Process manager observes SaleCompleted:
  - Marks process complete
  - If net positive (customer owes): another payment is added at sale time
  - If net negative (we owe): customer balance retains the difference

Settlement: implicit — customer balance reflects net result
```

**Compensation policy:**

- If Step 2 is never executed (cashier walks away, system crashes): the Return remains COMPLETED, the customer has a credit balance equal to the refund amount. This is **not a failure**; it is the natural outcome.
- If Step 2 fails: same as above. The customer can be retried later, or the credit is consumed at a future visit.
- If the Return needs to be undone after Step 1 commits: administrative-reversal pathway (operational flags on the return), not a saga-level rollback.

**Idempotency:** Each step uses its own `idempotency_key`. The process manager's own state row uses `exchange_group_id` as the natural key.

---

### 2.2 TransferProcess

**Purpose:** Coordinate the physical transfer of stock between stores, which spans days or weeks of real-world time.

**Flow:**

```
Step 1: Transfer.create()           [Transaction 1]
  - status = DRAFT
  - transfer_items inserted
  - No stock movement yet
  - Outbox emits TransferCreated

Step 2: Transfer.dispatch()         [Transaction 2]     (minutes-hours later)
  - status = DRAFT → DISPATCHED
  - stock OUT from source store
  - stock IN to virtual IN_TRANSIT store
  - Outbox emits TransferDispatched

Step 3: long real-world wait (carrier transit)
  Process manager schedules a delayed check:
  - At T+7 days, if still DISPATCHED, emit TransferDelayed
  - At T+30 days, if still DISPATCHED, escalate to admin

Step 4: Transfer.receive()          [Transaction 3]     (days later)
  - status = DISPATCHED → RECEIVED
  - stock OUT from virtual IN_TRANSIT
  - stock IN to destination store
  - If received_qty < dispatched_qty: NEGATIVE_ADJUSTMENT in virtual store, with loss_reason
  - Outbox emits TransferReceived
```

**Compensation policy:**

- A DISPATCHED transfer cannot be cancelled — stock has already moved. Mistakes are corrected by administrative reversal (operational flags + compensating movements).
- A DRAFT transfer can be cancelled freely (no movements yet).

**Recovery:** If the system crashes mid-`dispatch`, the transaction either committed or did not; there is no in-between. The process manager observes whichever outbox event eventually appears.

**Idempotency:** `transfers.idempotency_key_dispatch` and `transfers.idempotency_key_receive` are independent keys.

---

### 2.3 PaymentProcess

**Status:** Not a true saga — included here for completeness.

`Payment.complete()` is **single-transaction atomic**. It writes the payment, allocations, `account_movements` ledger entries, balance update, profile credit-used update, and (if cash) cash movement — all in one COMMIT.

The only multi-step aspect is **Payment Reversal**:

- `PaymentReversal.execute(original_payment_id, scope=FULL|PARTIAL)` is itself a single-transaction operation that writes the reversal payment and compensating entries.
- A reversal payment cannot itself be reversed (see [`cross-cutting-rules.md`](./cross-cutting-rules.md) and ADR 003).

Therefore no process manager exists for ordinary payments. The Payment aggregate carries the complexity inside itself.

---

### 2.4 SaleDocumentGeneration

**Purpose:** Produce the customer-visible artefacts of a completed sale — PDF receipt, printed receipt, e-document, customer notification — without blocking the POS UX.

**Flow:**

```
Trigger: SaleCompleted (outbox)

Parallel async workers (each a consumer with its own idempotency):

  Receipt PDF Worker
    - Render PDF → upload to object storage
    - UPDATE sale_documents SET pdf_path, status='READY'
    - Retry: 3 attempts, exponential backoff
    - On persistent failure: status='FAILED', user can retry from UI

  Receipt Printer Worker
    - Resolve store's printer configuration
    - Send print job
    - UPDATE sale_documents SET printed_at
    - Retry: 5 attempts; after that, queue for manual reprint

  e-Document Worker (v1.1+)
    - Determine if B2B (customer.tax_id present)
    - Submit to e-Arşiv / e-Fatura provider
    - Record returned UUID
    - Retry: provider-specific policy; manual reconciliation queue on persistent failure

  Notification Worker (best-effort)
    - SMS/email if customer contact and tenant settings allow
    - 5 attempts then drop
```

**There is no orchestration between these workers.** Each is independent and consumes the same `SaleCompleted` event from its own consumer-group offset. This is by design — failures are isolated, and the sale itself never depends on any of them.

The sale's `sale_documents` rows act as a coordination surface: each worker updates its own fields without conflict.

---

### 2.5 TenantLifecycle

**Purpose:** Background scheduler-driven progression of tenant status, including archival with PII anonymisation.

**Flow:**

```
Daily scheduler (per tenant):

  if status = TRIAL and trial_ends_at < now() and no successful payment:
    → status = CHURNED
    
  if status = ACTIVE and payment overdue > 7 days:
    → status = SUSPENDED
    Emit RegisterSessionForceFinalized for any open sessions (drain)

  if status = SUSPENDED for > 90 days:
    → status = CHURNED
    Open 30-day data-export window

  if status = CHURNED for > 30 days:
    → status = ARCHIVED
    Trigger anonymisation (see below)

  if status = ARCHIVED for > 10 years:
    → eligible for physical purge (manual Anthropic action)
```

**Archival operation (`CHURNED → ARCHIVED`):**

```
BEGIN TRANSACTION
  - UPDATE users SET email='anon_<uuid>@example.local', display_name='Anonymized User',
                     phone=NULL, is_anonymized=true, anonymized_at=now() WHERE tenant_id=X
  - UPDATE parties SET display_name='Anonymized Party', tax_id=NULL, is_anonymized=true WHERE tenant_id=X
  - DELETE FROM party_contacts WHERE tenant_id=X
  - Scrub PII from free-text fields (notes, addresses) with column-level UPDATE
  - UPDATE tenants SET status='ARCHIVED', archived_at=now(), anonymized_at=now()
  - INSERT outbox: TenantArchived (with full compliance metadata, see domain-events.md § 6)
COMMIT

Then async:
  - Export tenant's commercial records to encrypted cold storage (S3 Glacier)
  - Record cold_storage_path in tenant row
```

**Compensation policy:**

- Anonymisation is **irreversible by default** (Type B, see [ADR 009](../adr/009-saga-and-eventual-consistency.md)).
- For tenants on an opt-in reversible-pseudonymisation contract addendum, the PII fields are encrypted with a tenant-specific key kept in a separate vault; reversal requires a court order and HSM access.
- Commercial records (Sale, Invoice, Payment, `account_movements`, `stock_movements`, `Z_Report`, `FxSnapshot`) are preserved through the entire 10-year retention window. Hard deletion before that window is forbidden.

---

### 2.6 DayEndClose

**Purpose:** Coordinate the multi-phase register day-end close.

**Flow:**

```
Phase 1 — Initiate close          [Transaction 1]
  Trigger: cashier clicks "Close Day"
  - register_session.status = OPEN → CLOSING
  - closing_started_at = now()
  - Schedule force_finalize_close job at now() + 10 minutes
  - Outbox: RegisterSessionClosing

Phase 2 — Grace period (10 minutes, no DB transaction)
  UI behaviour:
  - New sale creation blocked
  - Existing DRAFT and AWAITING_PAYMENT sales may complete
  - Cash counting UI active
  - Terminal-pending sales tracked separately

Phase 3 — Finalise close           [Transaction 2]
  Trigger: cashier confirms "Counted cash = X" 
        OR background job at T + 10 minutes
  - Re-validate session.status = 'CLOSING'
  - Compute expected_cash
  - Compare with counted_cash; if variance ≠ 0, require permission or write variance movement
  - Generate Z report number (UPDATE-based per-tenant-per-store-per-year sequence; no gaps)
  - INSERT z_report row (status=PENDING_GENERATION, pdf_path=NULL)
  - For any DRAFT/AWAITING_PAYMENT sales remaining at this point:
      - If terminal_pending = false → mark ABANDONED
      - If terminal_pending = true  → flag requires_manual_reconciliation, leave AWAITING_PAYMENT
  - register_session.status = CLOSING → CLOSED
  - Outbox: RegisterSessionClosed, ZReportGenerated
  - Outbox: RegisterSessionForceFinalized (if Phase 3 triggered by timeout)
  - Outbox: CashDiscrepancyDetected (if variance ≠ 0)

Phase 4 — Async after commit
  Consumed by:
    Z Report PDF Worker → render + upload + emit ZReportPDFReady
    Notification Consumer → owner email (if configured)
    Reporting Projector → daily_close_summary
    Audit Consumer → critical-severity audit row
```

**Compensation policy:**

- A closed session is sealed. The only way back is the administrative `RegisterSessionReopened` pathway (feature-flag gated, super-admin only, co-signature required, no subsequent session may exist, audit ticket required — see ADR 009).
- Z report numbers are gap-free because allocation happens **inside** the close transaction; a rollback un-increments the per-store sequence row.

**Why the 10-minute grace?** Real POS reality: a customer may be at the counter when the close button is pressed. We do not strand them. The grace period gives them time to complete payment; the system does not abandon them silently.

---

### 2.7 OutboxRecovery (Operational, not user-facing)

**Purpose:** A control-plane process that monitors outbox health and triggers DLQ promotion, alerts and manual interventions.

**Flow:**

```
Every minute, the OutboxMonitor:
  - Counts PENDING events older than 5 minutes (publisher lag)
  - Counts FAILED events
  - Counts DEAD_LETTER additions in last hour

On thresholds:
  - PENDING age > 60 seconds → emit warning alert
  - FAILED total > 100 → emit critical alert
  - DEAD_LETTER additions > 10/hour → emit critical alert

For events meeting DLQ criteria:
  - publish_attempts ≥ 10 within 24 hours → status = DEAD_LETTER, reason = MAX_ATTEMPTS_EXCEEDED
  - schema_mismatch → status = DEAD_LETTER, reason = SCHEMA_MISMATCH
  - Emit OutboxEventDeadLettered to the audit + notification streams
```

This is operational plumbing, not a domain saga — included here so the full multi-step landscape is visible.

---

## 3. Saga State Tables

A minimal process-instance state table is enough for MVP:

```
process_instances (
  id                  UUID PRIMARY KEY,
  tenant_id           UUID NOT NULL,
  process_type        VARCHAR(50) NOT NULL,    -- 'EXCHANGE', 'TRANSFER', 'DAY_END_CLOSE', ...
  correlation_key     VARCHAR(100) NOT NULL,   -- exchange_group_id / transfer_id / session_id
  status              VARCHAR(20) NOT NULL,    -- 'IN_PROGRESS', 'COMPLETED', 'FAILED', 'CANCELLED'
  current_step        VARCHAR(50),
  state_data          JSONB,
  started_at          TIMESTAMPTZ DEFAULT now(),
  updated_at          TIMESTAMPTZ DEFAULT now(),
  completed_at        TIMESTAMPTZ
);

CREATE UNIQUE INDEX idx_process_correlation 
  ON process_instances(tenant_id, process_type, correlation_key);
```

For MVP, many sagas (e.g. SaleDocumentGeneration) don't need a process_instances row because each consumer is independent and their coordination surface is the domain entity itself (`sale_documents`).

`process_instances` is mandatory for:
- `ExchangeProcess` (need to time-out step 2)
- `TransferProcess` (need to monitor delay)
- `TenantLifecycle` (driven by daily scheduler — could use this table or a separate job log)

---

## 4. Ordering & Eventual Consistency Boundaries

| Within | Consistency |
|---|---|
| A single transaction (e.g. `Sale.complete()`) | Strictly consistent |
| A single aggregate's events over time | Strictly ordered |
| Across aggregates within a saga | Eventually consistent, ordered by the saga itself |
| Across consumers of the same event | Independent, may diverge in latency |
| Across tenants | No relation |

Sagas explicitly **embrace** eventual consistency between their steps. The system never claims that "after Sale.complete(), the reporting dashboard is instantly updated" — only that "the reporting dashboard will reflect this sale within seconds, idempotently, with replayability if needed".

---

## 5. Failure Recovery Summary

| Saga | If step N fails | Recovery |
|---|---|---|
| ExchangeProcess | Step 2 (new sale) fails | Customer retains credit; no compensation |
| TransferProcess | Step 4 (receive) fails | Stock remains in virtual IN_TRANSIT; admin investigates |
| SaleDocumentGeneration | Any worker fails | Retry; UI surfaces manual retry option |
| TenantLifecycle | Archive transaction fails | Stays CHURNED; alert; manual retry |
| DayEndClose | Phase 3 fails | Stays CLOSING; cashier retries or admin investigates |
| OutboxRecovery | Itself fails | Manual operator intervention; alerts wired |

No saga uses automatic compensating transactions. Either the business operation is genuinely two-step (Exchange, Transfer) where the partial outcome is acceptable, or the recovery is human-initiated administrative reversal.

---

## 6. Open Items

- **TODO** — Sprint 6: implement `ExchangeProcess` state machine; `process_instances` table introduced.
- **TODO** — Sprint 7: implement `TransferProcess` delay monitoring (`TransferDelayed` emission).
- **TODO** — Sprint 8: bring up `SaleDocumentGeneration` workers in their final form.
- **TODO** — Sprint 9: schedule + audit `TenantLifecycle` background job.
