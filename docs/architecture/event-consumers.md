# Event Consumers

> **Status:** Locked (Phase 2D)
> **Last updated:** 2026-05-15

This document catalogues every consumer of the outbox stream, its responsibilities, the events it subscribes to, its idempotency strategy and its failure-handling behaviour.

The event catalog itself is in [`domain-events.md`](./domain-events.md); long-running orchestrations are in [`saga-processes.md`](./saga-processes.md).

---

## 1. General Consumer Contract

Every consumer must obey four rules.

### Rule 1 — Idempotency

Every consumer maintains its own row in `processed_events`:

```
processed_events (
  consumer_name      VARCHAR(100),
  event_id           UUID,
  processed_at       TIMESTAMPTZ,
  processing_duration_ms INT,
  result_status      ENUM('SUCCESS','IGNORED','FAILED','DEAD_LETTER'),
  PRIMARY KEY (consumer_name, event_id)
)
```

The consumer pattern is:

```
if exists in processed_events (consumer_name, event.id):
    skip
else:
    BEGIN TRANSACTION
        apply event side effects
        INSERT processed_events (...)
    COMMIT
```

The `INSERT processed_events` must be in the **same transaction** as the projection update. This is what makes idempotency robust against crashes mid-processing.

### Rule 2 — At-Least-Once Delivery

Consumers receive events **at least once**, possibly more. Duplicate delivery is normal and handled by Rule 1.

### Rule 3 — Eventually Consistent

Consumers operate after the producer's transaction has committed. Their projections may lag by milliseconds to seconds. Hot-path correctness never depends on consumer state being current.

### Rule 4 — Retry, then DLQ

A failed consumer call is retried with exponential backoff. After repeated failures it goes to the dead-letter queue (see § 7).

---

## 2. Consumer Catalog

The MVP set of consumers, by purpose.

### 2.1 Reporting Projector

**Purpose:** Maintain materialised views and projection tables that power dashboards and reports.

**Subscribes to:**

| Event | Side effect |
|---|---|
| `SaleCompleted` | Refresh `daily_sales_summary`, `top_selling_variants`, `sales_by_category`, `sales_by_cashier` |
| `SaleAdministrativelyReversed` | Apply compensating delta to the same projections |
| `ReturnCompleted` | Refresh `return_summary`, `refund_volume` |
| `StockMovementRecorded` | Refresh `stock_position`, `sell_through_rate`, `aging_inventory` |
| `PurchaseInvoicePosted` | Refresh `purchase_summary`, `supplier_volume` |
| `PaymentRecorded` | Refresh `cash_flow_summary` |
| `RegisterSessionClosed` | Refresh `daily_close_summary`, `register_performance` |
| `CountSessionCompleted` | Refresh `shrinkage_analysis` |
| `PriceChanged` | Refresh `price_change_log` analytical view |

**Idempotency:** Standard `processed_events` row. Many projections use upsert semantics (insert-or-update) so even without the idempotency table they would be safe; the table provides explicit safety + audit.

**Failure modes:** A failing projection update rolls back the transaction; the event remains PENDING in `processed_events` (no row inserted) and is retried.

**Replay strategy:** Prefer **rebuild from append-only source tables** (see ADR 009). The reporting projector does NOT depend on outbox archive history.

### 2.2 Audit Consumer

**Purpose:** Persist a durable audit trail of state-changing business events.

**Subscribes to:** All domain events EXCEPT high-frequency informational events that bring no audit value. Notable inclusions:

| Critical-severity events (alerting wired) | Routine business events (audited, no alert) |
|---|---|
| `SaleAdministrativelyReversed` | `SaleCompleted` |
| `ReturnAdministrativelyReversed` | `ReturnCompleted` |
| `PurchaseInvoiceAdministrativelyReversed` | `PaymentRecorded` |
| `RegisterSessionReopened` | `RegisterSessionOpened`/`Closed` |
| `BlindReturnApproved` | `BlindReturnCompleted` |
| `CreditLimitExceeded` (with override) | `CreditLimitApproaching` |
| `PartyBlocked` | `PartyCreated` |
| `FraudSignalDetected` (HIGH confidence) | `FraudSignalDetected` (LOW/MED confidence) |
| `AccountStatusChanged` (→ BLOCKED/CLOSED) | `AccountStatusChanged` (NORMAL/WATCH) |
| `OutboxEventDeadLettered` | `StockAdjustmentRecorded` (large quantities flagged) |

**Storage:** `audit_event_log` table — append-only, partitioned by month, indexed by `(tenant_id, occurred_at)` and `(actor_user_id, occurred_at)`.

**Idempotency:** `processed_events` row per event.

**Note:** Security-stream events (`LoginSucceeded` etc.) are persisted to `security_audit_log` by the security middleware directly, NOT through the outbox or this consumer.

### 2.3 Notification Consumer

**Purpose:** Send SMS, email, in-app notifications to users.

**Subscribes to:**

| Event | Notification |
|---|---|
| `SaleCompleted` | Customer SMS/email receipt link (if tenant configured + customer attached) |
| `LowStockAlertTriggered` | Store manager in-app notification |
| `CreditLimitApproaching` | Tenant owner in-app + email |
| `OverdueAccountDetected` | Accountant in-app |
| `CashDiscrepancyDetected` | Store manager in-app |
| `TransferDelayed` | Both stores' managers |
| `FraudSignalDetected` (HIGH confidence) | Tenant admin alert |
| `ReconciliationDriftDetected` | Tenant admin + Anthropic ops |

**Idempotency:** Standard. Notifications are deduplicated within a 24-h window per `(recipient, event_id)`.

**Failure mode:** Notification dispatch failures are best-effort. A failure to send SMS is logged and dropped after 5 attempts; in-app notification fallback is always attempted.

### 2.4 Document Generation Workers

Each worker is an independent consumer with its own `processed_events` namespace.

#### Receipt / Invoice PDF Worker
- **Subscribes:** `SaleCompleted`, `ReturnCompleted`, `PurchaseInvoicePosted` (when we issue the invoice).
- **Action:** Render PDF, upload to object storage, `UPDATE sale_documents SET pdf_path, status='READY'`.
- **Retry:** 3 attempts with exponential backoff. Persistent failure marks `status='FAILED'`; user can re-trigger from UI.

#### Z Report PDF Worker
- **Subscribes:** `ZReportGenerated`.
- **Action:** Render Z report PDF; emit `ZReportPDFReady`.

#### Receipt Printer Worker
- **Subscribes:** `SaleCompleted`, `ReturnCompleted`.
- **Action:** Dispatch print job to the store's configured printer.
- **Retry:** 5 attempts. After that, queued for manual reprint from UI.

#### e-Document Worker (v1.1+)
- **Subscribes:** `SaleCompleted` filtered to B2B (customer has `tax_id` and tenant has e-Arşiv/e-Fatura enabled).
- **Action:** Submit to provider; store returned UUID and status.
- **Retry:** Provider-specific policy. Failed submissions queued for manual reconciliation.

### 2.5 Cache Invalidator

**Purpose:** Invalidate in-memory or distributed cache entries when underlying data changes.

**Subscribes to:**

| Event | Cache invalidated |
|---|---|
| `PriceChanged` | `PricingService` cache for that `variant_id` |
| `ProductStatusChanged` | Catalog read cache |
| `VariantBarcodeAdded` | Barcode-to-variant lookup cache |
| `TenantStatusChanged` | Tenant settings cache |

**Idempotency:** Trivial — invalidations are idempotent by nature.

**Failure mode:** A failed invalidation results in stale reads for up to the cache TTL; not critical.

### 2.6 Anti-Fraud Engine (v1.1)

**Purpose:** Pattern detection on signal events, escalation to human review.

**Subscribes to:**

| Event | Analysis |
|---|---|
| `BlindReturnCompleted` | Customer-level frequency / amount patterns |
| `PaymentReversed` | Per-cashier reversal rate monitoring |
| `DiscountAppliedOverLimit` | Cashier behaviour anomaly detection |
| `FraudSignalDetected` | Aggregate signals to escalation queue |

**Output:** Writes to `fraud_investigation_queue` for human review. Does NOT emit "fraud confirmed" events — only humans confirm fraud (`AdminMarkedAsFraud`).

**Status:** Out of scope for MVP. Schema and event topology are MVP-ready so the engine can be added without producer changes.

### 2.7 External Integration Workers (v1.1+)

#### Accounting Export (Logo / Mikro)
- **Subscribes:** `SaleCompleted`, `PurchaseInvoicePosted`, `PaymentRecorded`, `ReturnCompleted`.
- **Action:** Translate from our business-oriented DEBIT/CREDIT semantics into formal double-entry; queue for export.

#### Marketplace Sync (Trendyol, etc.)
- **Subscribes:** `StockMovementRecorded` (filtered by tenant config), `PriceChanged`, `ProductPublished`.
- **Action:** Push updates to marketplace API.

#### Webhook Dispatcher
- **Subscribes:** Customer-configured event filters.
- **Action:** HTTP POST to tenant-configured webhook URL with signed payload; retry policy per tenant.

---

## 3. Consumer-Aware Event Routing

The publisher does not push events to specific consumers; it publishes once per event, and each consumer's filter decides whether to process. Filters are declared at consumer registration time:

```
ConsumerRegistration {
  name: "SalesReportingProjector",
  event_types: ["SaleCompleted", "SaleAdministrativelyReversed", "ReturnCompleted", ...],
  tenant_filter: null,    // process all tenants
  rate_limit: 1000/s,
  idempotency_table: "processed_events"
}
```

Cross-tenant isolation: consumer groups are keyed by `(tenant_id, consumer_name)` once we move to an external broker (v1.1+), preventing one noisy tenant from delaying another tenant's pipeline.

---

## 4. Schema Validation

Consumers validate events on receipt:

```
def handle(raw_event):
    schema = registry.get(raw_event.event_type, raw_event.event_version)
    payload = schema.parse(raw_event.payload)  # strict
    apply(payload)
```

On schema mismatch:
1. Event is moved to DLQ with `reason = SCHEMA_MISMATCH`.
2. `OutboxEventDeadLettered` event is emitted to the audit/notification streams.
3. The original event remains in the outbox for forensic review.

---

## 5. Replay and Rebuild

Two distinct operations.

### Replay (rerun a previously published event through a specific consumer)

```
$ replay_events --consumer=SalesReporting --from=2026-01-01 --to=2026-01-31
```

- Deletes corresponding rows from `processed_events` for that consumer.
- Re-feeds events from the outbox (or, where retention has elapsed, reconstructs from source tables — see Rebuild below).
- Idempotent consumer logic re-applies side effects with identical results.
- Used for: backfilling a new projection, recovering from a buggy consumer release, testing.

### Rebuild (recompute a projection from source-of-truth tables, ignoring the outbox)

```
$ rebuild_stock_balances --tenant=X [--store=Y] [--variant=Z]
$ rebuild_account_balances --tenant=X [--party=Y]
$ rebuild_reporting_views --tenant=X --view=daily_sales
```

This is the **preferred** rebuild path (see [ADR 009](../adr/009-saga-and-eventual-consistency.md)):

- For `stock_balances` / `account_balances` / `account_aging`: recompute from `stock_movements` / `account_movements` directly.
- For `daily_sales_summary` and similar: recompute from `sales` filtered to `status = COMPLETED AND administratively_reversed_at IS NULL`.
- Why preferred: append-only ledgers are the actual source of truth; outbox is a transient integration mechanism. Rebuilds remain correct even if outbox retention has expired.

The outbox `PUBLISHED` retention can therefore be aggressive (90 days default). `DEAD_LETTER` rows are kept until manually resolved.

---

## 6. Failure Handling Matrix

| Failure | What happens |
|---|---|
| Consumer raises an exception | Transaction rolls back, no `processed_events` row, retry in next publisher tick |
| Consumer times out | Same as above; publisher's per-attempt timeout enforces this |
| Consumer panics (process death) | Event remains PENDING; another publisher instance / next restart picks it up |
| Repeated transient failure | Exponential backoff, configurable max attempts |
| Schema mismatch | Immediate DLQ with `SCHEMA_MISMATCH` |
| Poison event (malformed payload, unsatisfiable invariant) | DLQ with `POISON_EVENT` after detection |
| Tenant ARCHIVED mid-flight | Consumer skips, marks `IGNORED` |
| Consumer permanently broken | Operator marks consumer disabled; outbox accumulates; events re-flow on re-enable |

---

## 7. Dead Letter Queue

A row moves to DLQ status when:

| Trigger | `dead_letter_reason` |
|---|---|
| Publisher: 10 failed attempts within 24 hours | `MAX_ATTEMPTS_EXCEEDED` |
| Producer/consumer: schema validation failure | `SCHEMA_MISMATCH` |
| Consumer: invariant violation (malformed event) | `POISON_EVENT` |
| Consumer permanently broken / deregistered | `CONSUMER_PERMANENT_FAILURE` |
| Operator marks event poison | `MANUAL_DLQ` |
| Target tenant ARCHIVED before processing | `TENANT_ARCHIVED` |

### DLQ schema (extension of `outbox_events`)

```
ALTER TABLE outbox_events ADD COLUMN dead_letter_at TIMESTAMPTZ;
ALTER TABLE outbox_events ADD COLUMN dead_letter_reason VARCHAR(50);

-- status enum extended:
-- 'PENDING', 'PUBLISHED', 'FAILED', 'DEAD_LETTER'
```

### DLQ operations

```
$ list_dlq --consumer=<name>           # browse DLQ
$ replay_dlq_event <event_id>          # retry once
$ bulk_replay_dlq --consumer=<name> --from=<ts> --to=<ts>
$ discard_dlq_event <event_id> --reason="…"   # audit-logged
```

### DLQ monitoring thresholds

- DLQ size > 100 → warning.
- DLQ size > 1000 → critical alert.
- Any event in DLQ longer than 24 hours → review needed.
- `OutboxEventDeadLettered` events emitted on transition into DLQ; consumed by the notification consumer.

---

## 8. MVP vs Post-MVP Consumer Set

| Consumer | MVP? | Notes |
|---|---|---|
| Reporting Projector | ✓ | Core dashboards |
| Audit Consumer | ✓ | Compliance baseline |
| Notification Consumer | ✓ | In-app + email at minimum; SMS optional |
| Receipt / Invoice PDF Worker | ✓ | Required for POS UX |
| Z Report PDF Worker | ✓ | Required for end-of-day |
| Receipt Printer Worker | ✓ | Required for physical receipts |
| Cache Invalidator | ✓ | Required for price/catalog correctness |
| e-Document Worker | v1.1 | Schema ready; provider integration deferred |
| Anti-Fraud Engine | v1.1 | Signals emitted in MVP; analysis layer added later |
| Accounting Export | v1.1 | Logo / Mikro |
| Marketplace Sync | v1.1+ | Per integration |
| Webhook Dispatcher | v1.1+ | Tenant-facing |

---

## 9. Open Items

- **TODO** — Sprint 0: scaffold a placeholder publisher and a no-op consumer to exercise the outbox plumbing end-to-end. Tracked in roadmap.
- **TODO** — Sprint 8: first real Reporting Projector consumer brought online.
- **TODO** — Phase 6: pick the event-bus implementation (Kafka / Redis Streams / RabbitMQ) for v1.1+; until then, MVP uses an in-process publisher worker.
