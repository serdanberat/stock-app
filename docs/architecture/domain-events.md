# Domain Events

> **Status:** Locked (Phase 2D)
> **Last updated:** 2026-05-15

This document defines the complete domain-event catalog, the envelope structure, schema-versioning rules and ordering guarantees. Consumer behaviour is documented separately in [`event-consumers.md`](./event-consumers.md); long-running flows in [`saga-processes.md`](./saga-processes.md).

---

## 1. Event Envelope

Every domain event published to the outbox uses the same envelope. This is the contract between producers and consumers.

```json
{
  "event_id": "uuid",
  "event_type": "SaleCompleted",
  "event_version": "v1",
  "aggregate_type": "SALE",
  "aggregate_id": "uuid",
  "aggregate_version": null,
  "tenant_id": "uuid",
  "occurred_at": "2026-05-15T14:32:00Z",
  "recorded_at": "2026-05-15T14:32:00.123Z",
  "ordering_keys": {
    "outbox_sequence": 12348567,
    "global_sequence": 98234712,
    "aggregate_sequence": null
  },
  "metadata": {
    "correlation_id": "uuid",
    "causation_id": "uuid",
    "actor_user_id": "uuid",
    "actor_role": "CASHIER",
    "source": "POS_TERMINAL_01",
    "ip": "192.168.1.5",
    "user_agent": "..."
  },
  "payload": {
    // event-specific
  }
}
```

### Field semantics

| Field | Meaning | Required |
|---|---|---|
| `event_id` | Globally unique event identifier (UUID/ULID). Used by consumers as the idempotency key. | Always |
| `event_type` | Stable string identifier (e.g. `SaleCompleted`). Renames require a new type. | Always |
| `event_version` | Schema version, starts at `v1`. See § 3. | Always |
| `aggregate_type` | The aggregate that produced the event (`SALE`, `RETURN`, `PAYMENT`, `STOCK_MOVEMENT`, …). | Always |
| `aggregate_id` | The aggregate's PK. Becomes the partition key for downstream brokers (see § 5). | Always |
| `aggregate_version` | Optimistic-concurrency version for mutable aggregates (Sale, Payment, Transfer). | Optional |
| `tenant_id` | Always present. Consumers must filter by this when relevant. | Always |
| `occurred_at` | When the business event actually happened (UTC). | Always |
| `recorded_at` | When the row was written to outbox (UTC). May differ slightly from `occurred_at`. | Always |
| `ordering_keys.outbox_sequence` | `outbox_events.id` (BIGSERIAL). Publish order within a publisher instance. | Always |
| `ordering_keys.global_sequence` | Per-tenant monotonic event sequence. Useful for gap detection. | Always |
| `ordering_keys.aggregate_sequence` | Monotonic within an aggregate. Populated for append-only ledger events (`StockMovementRecorded`, `AccountMovementRecorded`). | Conditional |
| `metadata.correlation_id` | Ties together all events for a single business operation. | Always |
| `metadata.causation_id` | The `event_id` that caused this event (chain of causation). | When applicable |
| `metadata.actor_*` | Who triggered the action. | Always (system for automatic) |
| `payload` | Event-specific data; see catalog below. | Always |

---

## 2. Event Catalog

Roughly 60 event types across 11 contexts. Naming convention: `<Aggregate><PastParticiple>`.

### 2.1 Identity Context

| Event | Triggering aggregate transition | Notable payload fields |
|---|---|---|
| `TenantCreated` | New tenant registered | `tenant_id`, `industry`, `plan`, `owner_user_id` |
| `TenantStatusChanged` | `TRIAL→ACTIVE`, `ACTIVE→SUSPENDED`, etc. | `old_status`, `new_status`, `reason` |
| `TenantArchived` | `CHURNED→ARCHIVED` (with anonymisation) | See § 6 (compliance metadata payload) |
| `UserCreated` | Admin invited user | `user_id`, `invited_by`, initial roles |
| `UserActivated` | Invitation accepted, password set | `user_id`, `activated_at` |
| `UserSuspended` | Admin suspended | `user_id`, `reason`, `actor_user_id` |
| `UserDeactivated` | Admin permanent deactivate | `user_id`, `reason`, `actor_user_id` |
| `RoleAssigned` / `RoleRevoked` | Permission management | `user_id`, `role_id`, `store_scope_ids` |
| `StoreCreated` / `StoreActivated` / `StoreDeactivated` / `StoreArchived` | Store lifecycle | `store_id`, `status`, `reason` |

> **Security events are NOT here.** `LoginSucceeded`, `LoginAttemptFailed`, `PasswordChanged`, `MFAChallenge`, `PermissionDenied`, `SessionExpired` are persisted to a separate `security_audit_log` table and never enter the outbox stream. See § 4.

### 2.2 Catalog Context

| Event | Trigger | Notable payload |
|---|---|---|
| `ProductCreated` | New product + initial variant matrix | `product_id`, `variants_count`, `category_id` |
| `ProductPublished` | `DRAFT→ACTIVE` | `product_id` |
| `ProductStatusChanged` | `ACTIVE↔INACTIVE`, `DISCONTINUED`, `ARCHIVED` | `old_status`, `new_status`, `inactive_sellable` (when relevant) |
| `VariantCreated` | New variant on existing product | `variant_id`, `product_id`, `attributes`, primary barcode |
| `VariantBarcodeAdded` | Additional barcode attached to variant | `variant_id`, `barcode`, `scope` |
| `PriceChanged` | `variant_prices` insert + previous row `valid_until` set | `variant_id`, `price_list_id`, `currency`, `old_price`, `new_price`, `effective_from`, `reason_code`, `reason_notes` |
| `CategoryCreated` / `CategoryMoved` / `CategoryArchived` | Category lifecycle | `category_id`, `parent_id` |

**`PriceChanged.reason_code` taxonomy:** `CAMPAIGN`, `INFLATION_UPDATE`, `COST_INCREASE`, `COST_DECREASE`, `MARGIN_ADJUSTMENT`, `COMPETITIVE_PRICING`, `MANUAL_CORRECTION`, `SEASON_END`, `NEW_SEASON`, `CLEARANCE`, `SUPPLIER_DEAL`, `OTHER` (free-text notes required).

### 2.3 Inventory Context

| Event | Trigger | Notable payload |
|---|---|---|
| `StockMovementRecorded` | Every movement (the workhorse) | `movement_id`, `variant_id`, `store_id`, `direction`, `quantity`, `movement_type`, `reference_type`, `reference_id`, `unit_cost_try`, `actor_user_id`, **`aggregate_sequence`** populated |
| `LowStockAlertTriggered` | Balance dropped below `min_level` | `variant_id`, `store_id`, `current_qty`, `min_level` |
| `StockoutOccurred` | Balance reached zero | `variant_id`, `store_id` |
| `TransferCreated` | Transfer DRAFT | `transfer_id`, `from_store`, `to_store`, items count |
| `TransferDispatched` | `DRAFT→DISPATCHED` | `transfer_id`, `dispatched_by`, items |
| `TransferReceived` | `DISPATCHED→RECEIVED` | `transfer_id`, `received_by`, `variance_items_count`, `loss_reasons` |
| `TransferDelayed` | DISPATCHED for 7+ days | `transfer_id`, `days_delayed` |
| `CountSessionStarted` | DRAFT | `session_id`, `store_id`, `scope` |
| `CountSessionCompleted` | Variance posted + sealed | `session_id`, `total_variance`, `items_with_variance`, `total_loss_value_try` |
| `StockAdjustmentRecorded` | Manual adjustment | `adjustment_id`, `variant_id`, `store_id`, `quantity`, `reason_code`, `actor_user_id` |

**Transfer loss reason codes (used in `TransferReceived.loss_reasons` per item):** `LOST_IN_TRANSIT`, `DAMAGED_IN_TRANSIT`, `RECEIVED_SHORT`, `PROVIDER_ERROR`, `INTERNAL_PILFERAGE`.

### 2.4 Sales Context

| Event | Trigger | Notable payload |
|---|---|---|
| `SaleStarted` | DRAFT opened | `sale_id`, `store_id`, `register_id`, `cashier_id` |
| `SaleCompleted` | `AWAITING_PAYMENT→COMPLETED` (atomic) | `sale_id`, `total`, `currency`, `total_try`, `items_count`, `payment_methods`, `customer_id`, `salesperson_ids`, `exchange_group_id` (if any) |
| `SaleCancelled` | DRAFT or AWAITING_PAYMENT → VOIDED, cashier action | `sale_id`, `reason`, `cancelled_by` |
| `SaleAbandoned` | Automatic timeout (4 h idle in DRAFT, 15 min in AWAITING_PAYMENT) | `sale_id`, `last_activity_at`, `idle_phase` |
| `SaleAdministrativelyReversed` | Admin tool sets operational flags on COMPLETED | `sale_id`, `reversed_by`, `reason`, `ticket_id` |
| `PaymentAttemptStarted` | Tender entry began | `attempt_id`, `sale_id`, `attempt_number` |
| `PaymentAttemptFailed` | Card decline / terminal timeout | `attempt_id`, `sale_id`, `reason`, `tender_attempts` |
| `TerminalPendingTimeoutExceeded` | Card terminal callback never arrived | `sale_id`, `store_id`, `register_id`, `terminal_id`, `terminal_provider`, `terminal_transaction_id`, `terminal_amount`, `terminal_card_masked`, `pending_started_at`, `expected_callback_by`, `exceeded_at`, `waited_for_seconds`, `recommended_action` |
| `DiscountAppliedOverLimit` | Manager override on discount % | `sale_id`, `discount_pct`, `approver_user_id` |
| `ReturnStarted` | Return DRAFT | `return_id`, `mode` (RECEIPTED/BLIND), `original_sale_id` |
| `ReturnApprovalRequested` | `DRAFT→AWAITING_APPROVAL` | `return_id`, `approval_reasons`, threshold details |
| `ReturnApproved` | Manager approved | `return_id`, `approver_user_id` |
| `ReturnCompleted` | COMPLETED | `return_id`, `total_refunded`, `refund_methods`, `items_count`, `exchange_group_id` (if any) |
| `ReturnCancelled` | DRAFT/AWAITING_APPROVAL → VOIDED | `return_id`, `reason`, `cancelled_by` |
| `BlindReturnCompleted` | BLIND mode return finished | `return_id`, `customer_id`, `total_refunded` |
| `BlindReturnApproved` | BLIND + manager threshold | `return_id`, `approver`, threshold reasons |
| `ReturnAdministrativelyReversed` | Admin tool on COMPLETED return | `return_id`, `reversed_by`, `reason` |
| `FraudSignalDetected` | Heuristic flag (replaces former `PotentialFraudDetected`) | `signal_type`, `confidence`, `subject_type`, `subject_id`, `evidence` |

**`SaleVoided` does not exist.** Use `SaleCancelled` for cashier-driven cancellation in DRAFT/AWAITING_PAYMENT, `SaleAbandoned` for automatic timeout, `SaleAdministrativelyReversed` for the operational-flag pathway on a COMPLETED sale.

**`FraudSignalDetected.signal_type`:** `CUSTOMER_BLIND_RETURN_FREQUENCY`, `CASHIER_DISCOUNT_PATTERN`, `PAYMENT_REVERSAL_FREQUENCY`, `STOCK_ADJUSTMENT_PATTERN`, `REGISTER_VARIANCE_PATTERN`.

The system emits *signals* only; legal "fraud" determinations are human decisions recorded by a separate `AdminMarkedAsFraud` event after manual review.

### 2.5 Purchasing Context

| Event | Trigger | Payload |
|---|---|---|
| `PurchaseInvoiceCreated` | DRAFT | `invoice_id`, `supplier_id`, `currency` |
| `PurchaseInvoicePosted` | `DRAFT→POSTED` | `invoice_id`, `supplier_id`, `total`, `total_try`, `items_count`, `fx_snapshot_id` |
| `PurchaseInvoiceAdministrativelyReversed` | Admin tool | `invoice_id`, `reversed_by`, `reason` |
| `PurchaseReturnPosted` | `DRAFT→POSTED` | `return_id`, `original_invoice_id`, `total`, `items_count` |

### 2.6 Party Context

| Event | Trigger | Payload |
|---|---|---|
| `PartyCreated` | New customer/supplier/employee | `party_id`, `party_types`, `tax_id_masked` |
| `PartyUpdated` | Significant fields changed | `party_id`, `fields_changed[]` |
| `PartyBlocked` | `ACTIVE→BLOCKED` | `party_id`, `reason`, `actor` |
| `PartyUnblocked` | `BLOCKED→ACTIVE` | `party_id`, `reason`, `approver` |

### 2.7 Financial Context

| Event | Trigger | Payload |
|---|---|---|
| `AccountProfileCreated` | Party event consumer or manual | `profile_id`, `party_id`, `role`, `currency` |
| `AccountStatusChanged` | `NORMAL ↔ WATCH ↔ BLOCKED ↔ CLOSED` | `profile_id`, `old_status`, `new_status`, `reason` |
| `AccountMovementRecorded` | Every journal entry | `movement_id`, `profile_id`, `direction`, `amount`, `currency`, `movement_type`, `reference_type`, `reference_id`, **`aggregate_sequence`** populated |
| `CreditLimitExceeded` | Sale completion with override | `profile_id`, `current_balance`, `attempted_amount`, `limit`, `override_by_user_id` |
| `CreditLimitApproaching` | Crossed 80 % of limit | `profile_id`, `current_balance`, `limit`, `usage_pct` |
| `OverdueAccountDetected` | Due date passed | `profile_id`, `overdue_amount`, `days_overdue` |
| `AccountBlockedAutomatically` | `auto_block_on_overdue_days` triggered | `profile_id`, `days_overdue` |
| `PaymentRecorded` | `Payment.complete()` | `payment_id`, `party_id`, `amount`, `currency`, `tender_type` |
| `PaymentReversed` | Full or partial reversal | `original_payment_id`, `reversal_payment_id`, `amount`, `type` (FULL/PARTIAL), `reason` |
| `PaymentFailed` | Terminal or network failure | `payment_id`, `reason` |

### 2.8 Cash Register Context

| Event | Trigger | Payload |
|---|---|---|
| `RegisterSessionOpened` | `OPEN` | `session_id`, `register_id`, `opened_by`, `opening_float` |
| `RegisterSessionClosing` | `OPEN→CLOSING` | `session_id`, `closing_started_at`, `pending_sales_count` |
| `RegisterSessionForceFinalized` | Grace period elapsed | `session_id`, `abandoned_sales_count`, `terminal_pending_sales_count` |
| `RegisterSessionClosed` | `CLOSING→CLOSED` | `session_id`, `expected_cash`, `counted_cash`, `variance`, `tender_breakdown` |
| `RegisterSessionReopened` | `CLOSED→OPEN` (admin, very rare) | `session_id`, `reason`, `reopened_by`, `co_signers[]` |
| `ZReportGenerated` | Z report stub written at close commit | `report_id`, `session_id`, `z_number` |
| `ZReportPDFReady` | Async PDF worker finished | `report_id`, `pdf_path` |
| `ZReportInvalidated` | Session reopened | `report_id`, `invalidated_by`, `reason` |
| `CashDiscrepancyDetected` | Variance ≠ 0 at close | `session_id`, `variance_amount` |
| `CashMovementRecorded` | Every cash movement | `movement_id`, `session_id`, `type`, `amount`, `tender_type` |

### 2.9 FX Context

| Event | Trigger | Payload |
|---|---|---|
| `FxRateUpdated` | New rate from a source | `source_id`, `currency`, `buy_rate`, `sell_rate`, `effective_at_utc` |
| `FxSourceFailedFetch` | Provider down | `source_id`, `attempts`, `last_error` |
| `FxSnapshotCreated` | Snapshot locked to a document | `snapshot_id`, `source_id`, `rates_count` |

### 2.10 Cross-Cutting Events

| Event | Trigger | Payload |
|---|---|---|
| `OutboxPublishFailed` | Publisher exceeded retry budget | `event_id`, `aggregate_type`, `aggregate_id`, `last_error`, `attempts` |
| `OutboxEventDeadLettered` | Event moved to DEAD_LETTER status | `event_id`, `aggregate_type`, `aggregate_id`, `reason` (POISON_EVENT / SCHEMA_MISMATCH / CONSUMER_PERMANENT_FAILURE / MAX_ATTEMPTS_EXCEEDED / MANUAL_DLQ) |
| `ReconciliationDriftDetected` | Nightly balance-vs-ledger mismatch | `tenant_id`, `drift_type`, `magnitude`, target (variant+store / party+role+currency) |
| `BackupCompleted` / `BackupFailed` | Backup operation | `tenant_id`, `size`, `duration` |

---

## 3. Schema Versioning

`event_version` starts at `v1`.

**Forward-compatible change (no version bump):**
- Add a new optional field to `payload` or `metadata`.
- Add a new optional metadata field.
- Expand an enum (consumers must tolerate unknown values).

**Breaking change (new version, e.g. `v2`):**
- Rename a field.
- Change a field's type.
- Make a field required.
- Remove a field.
- Tighten an enum (remove values).

**Migration policy:**
1. Producer starts publishing both `v1` and `v2` (parallel emission).
2. Consumers migrate one by one.
3. Once all consumers consume `v2`, the producer stops emitting `v1`.
4. Old `v1` rows in the outbox archive are tagged `superseded`.

Schemas are validated at **producer time** (before INSERT into outbox) and at **consumer time** (before applying). A schema mismatch on consumer side moves the event to DLQ with `reason = SCHEMA_MISMATCH`.

---

## 4. Streams: Domain vs Security

Two parallel append streams exist:

| Stream | Storage | Use case |
|---|---|---|
| **Domain events** | `outbox_events` table | Business state changes (sales, returns, payments, stock, financial), cross-context propagation, projection updates, audit of business actions |
| **Security audit** | `security_audit_log` table | Authentication, authorisation, session, MFA, password, IP-level signals |

Security events are kept out of the outbox to prevent:
- Flooding the bus with high-frequency noise.
- Outbox bloat.
- Mixing concerns (a single retention/replay policy does not fit both).

Equivalents kept out of the outbox by the same rationale:
- Page-view / feature-click analytics (deferred to a separate analytics pipeline in v1.1+).
- Cache invalidation notifications.
- Background job lifecycle (`JobStarted`, `JobCompleted`) — `job_log` table only.

---

## 5. Ordering Guarantees

| Scope | Guarantee | How |
|---|---|---|
| **Per aggregate** | Strict ordering | `outbox_events.created_at ASC` read order; per-aggregate publish is single-threaded inside a publisher; partition key = `aggregate_id` |
| **Within a tenant** | Best-effort by `global_sequence` | Useful for gap detection but not strict |
| **Across aggregates** | No guarantee | Consumers must tolerate out-of-order events between different aggregates |
| **Across tenants** | No relation | Consumer groups are per `(tenant_id, consumer_name)` |

### Partition-key choice

- **Primary key: `aggregate_id`** — strongest per-aggregate ordering.
- **Trade-off:** hot aggregates (top-selling variant) create hot partitions; operationally manageable.
- **Alternative considered, rejected:** `(tenant_id, aggregate_type)` — better distribution but only same-aggregate-type ordering.

This choice is stable across `event_version` migrations: the partition key is decided at event INSERT time and never changes for a given event.

---

## 6. PII and Compliance (TenantArchived)

`TenantArchived` is the only event carrying compliance-grade lifecycle metadata. The payload makes the policy explicit:

```json
{
  "event_type": "TenantArchived",
  "payload": {
    "tenant_id": "uuid",
    "archived_at": "2026-05-15T00:00:00Z",
    "anonymization_method": "IRREVERSIBLE",
    "anonymization_scope": [
      "USER_EMAIL", "USER_NAME", "USER_PHONE",
      "PARTY_DISPLAY_NAME", "PARTY_TAX_ID", "PARTY_CONTACTS",
      "FREE_TEXT_NOTES_WITH_PII"
    ],
    "preserved_data": [
      "SALES_RECORDS", "INVOICES", "PAYMENTS",
      "ACCOUNT_MOVEMENTS", "STOCK_MOVEMENTS",
      "Z_REPORTS", "FX_SNAPSHOTS"
    ],
    "anonymization_key_id": null,
    "cold_storage_path": "s3://.../tenants/<uuid>/archive.tar.gz.enc",
    "physical_purge_eligible_at": "2036-05-15T00:00:00Z",
    "compliance_basis": {
      "gdpr_article": "Article 17 (Right to erasure)",
      "vuk_article": "Article 253 (Retention obligation)",
      "retention_minimum_years": 10
    }
  }
}
```

- Default is **IRREVERSIBLE** anonymisation.
- Reversible pseudonymisation (`REVERSIBLE_PSEUDONYMIZATION`) is opt-in for tenants on a special contract addendum (rare regulatory cases), requires a key vault and is permission-gated.
- Physical purge becomes eligible only 10 years after archival.

---

## 7. Producer Discipline

A few rules every producer must follow:

1. **Outbox INSERT is inside the same domain transaction** as the state change (see ADR 004).
2. **`event_id` is generated server-side** as a UUID/ULID; never trust client-supplied IDs as the event identity.
3. **`correlation_id` is propagated** from the originating request (HTTP header or job context).
4. **`causation_id` chains events**: when event B is created as a consequence of consuming event A, B's `causation_id = A.event_id`.
5. **Payloads validate against a JSON schema** before INSERT.
6. **No PII leaks**: `tax_id`, raw email and phone are never in `payload` — references only (e.g. `customer_id`).
7. **No secrets**: keys, tokens, password hashes, card PANs are forbidden in events. Use masked or tokenised values where needed (`terminal_card_masked: "**** **** **** 1234"`).

---

## 8. Sequence Numbers

Three monotonic counters are maintained alongside each event:

| Counter | Scope | Source | Purpose |
|---|---|---|---|
| `outbox_sequence` | Global outbox | `outbox_events.id` BIGSERIAL | Publisher reads in this order |
| `global_sequence` | Per tenant | Per-tenant BIGSERIAL | Gap detection across the whole tenant |
| `aggregate_sequence` | Per aggregate | Computed on insert (UPDATE-based sequence or window function) | Detect missed events for a specific aggregate during replay/debug |

`aggregate_sequence` is populated for append-only ledger events (`StockMovementRecorded`, `AccountMovementRecorded`) where the "aggregate" is the `(variant_id, store_id)` or `(profile_id)` tuple. For mutable aggregates (Sale, Payment), `aggregate_version` plays the equivalent role.

---

## 9. Open Items

- **TODO** — Final choice of event bus implementation for v1.1+ (Kafka / Redis Streams / RabbitMQ). See [ADR 008](../adr/008-domain-events-and-outbox.md) for the abstraction layer; the concrete choice is deferred to Phase 6.
- **TODO** — JSON schema files (`/docs/schemas/events/<EventType>.v1.json`) to be generated during Sprint 0 once the backend stack is chosen.
