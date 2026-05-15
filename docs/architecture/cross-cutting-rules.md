# Cross-Cutting Rules

> **Status:** Locked
> **Last updated:** 2026-05-15

Rules that apply across all bounded contexts. Every implementation must respect them.

---

## 1. Append-Only Ledgers

Two ledger tables are append-only:
- `stock_movements`
- `account_movements`

**Enforcement:**
- `REVOKE UPDATE, DELETE` on the table from the application role.
- A guard trigger raises an exception on any UPDATE / DELETE attempt (defence in depth).
- Triggers contain no business logic — only immutability enforcement.

**Reversal pattern:**
- A new movement row is INSERTed with `reverses_movement_id` pointing at the original.
- The original is **never** modified.
- **Reversal of a reversal is forbidden**; create a new clean corrective movement instead.

**Cost behaviour at sale time:**
- IN movements carry `unit_cost_try` set by the writer (purchase, return, etc.).
- OUT movements snapshot the current WAC at the moment of write.
- For sales, `sale_items.unit_cost_try` records this snapshot — historical margins never change later.

---

## 2. Idempotency

Mandatory `idempotency_key` (VARCHAR(64), UNIQUE per tenant) on these operations:

| Operation | Idempotency key field |
|---|---|
| `Sale.complete()` | `sales.idempotency_key` |
| `Return.complete()` | `returns.idempotency_key` |
| `Payment.complete()` | `payments.idempotency_key` |
| `PaymentReversal.execute()` | `payments.idempotency_key` (new payment) |
| `PurchaseInvoice.post()` | `purchase_invoices.idempotency_key` |
| `PurchaseReturn.post()` | `purchase_returns.idempotency_key` |
| `Transfer.dispatch()` | `transfers.idempotency_key_dispatch` |
| `Transfer.receive()` | `transfers.idempotency_key_receive` |
| `RegisterSession.close()` | `register_sessions.idempotency_key_close` |
| `CountSession.complete()` | `count_sessions.idempotency_key_complete` |
| `StockAdjustment.create()` | `stock_adjustments.idempotency_key` |

**Client behaviour:**
- Generate a unique key for the operation (composition: `register_id + cashier_id + entity_id + timestamp + nonce`).
- Persist locally before sending.
- On retry, send the **same** key.

**Server behaviour:**
- Before processing, check existence by `(tenant_id, idempotency_key)`.
- If found, return the cached result; do not process again.
- If not found, process normally; the key is committed inside the same transaction.

**Retention:** 24 hours. A background job sets old `idempotency_key` to NULL afterwards (the entity itself remains).

**Consumer idempotency (outbox):**
- Every projector / consumer maintains a `processed_events` row per `(consumer_name, event_id)`.
- Idempotency check happens inside the same transaction as the projection update.

---

## 3. Outbox Pattern

See ADR 004 for the full design. Summary:

```
outbox_events (
  id UUID PK,
  tenant_id, aggregate_type, aggregate_id,
  event_type, event_version, payload JSONB, metadata JSONB,
  created_at, published_at NULL,
  publish_attempts, last_attempt_at, last_error,
  status ENUM('PENDING', 'PUBLISHED', 'FAILED')
)
```

- INSERT happens inside the same transaction as the domain change.
- Background publisher loads PENDING rows in batches, publishes to the bus, marks PUBLISHED.
- Retry policy: exponential backoff, max 5 attempts, then FAILED → manual review.
- Event versioning: `event_version = "v1"` initially; consumers must tolerate forward-compatible schema evolution.

---

## 4. Concurrency / Locking

- Default isolation: `READ COMMITTED`.
- Use **pessimistic** `SELECT ... FOR UPDATE` on critical rows.
- Acquire locks in a **canonical order** (see `transaction-boundaries.md`) to avoid deadlocks.
- Retry on `SerializationFailure` and `DeadlockDetected` with exponential backoff (max 3 attempts).
- `CountSession.complete()` uses `REPEATABLE READ` for variance computation consistency.

---

## 5. Async Document Generation

See ADR 005 for the full design. Summary:

| Step | Where it happens |
|---|---|
| Sale/Return/Invoice document **stub** (metadata row, status PENDING_GENERATION) | Inside the atomic transaction |
| PDF generation | Async worker, after commit |
| Upload to object storage | Async worker |
| e-Arşiv / e-Fatura submission (v1.1+) | Async worker |
| Receipt printer dispatch | Async worker |

The user-visible result completes as soon as the atomic transaction commits; documents arrive moments later.

---

## 6. PII and Anonymisation

- All timestamps stored as **UTC**; tenant timezone applied for display only.
- Tenant lifecycle ends in **ARCHIVED + PII anonymisation + encrypted cold storage**, never hard deletion (see ADR 007 for tenancy + data retention).
- Sensitive fields on archived entities: `email`, `phone`, `tax_id`, `address`, `display_name` are anonymised; commercial records (Sale, Invoice, Payment) are retained.

---

## 7. Audit Capture (Three Layers)

Domain code has **zero** audit dependencies. Audit is captured externally:

1. **HTTP middleware** records every API call (actor, IP, endpoint, status, duration).
2. **Domain event listener** subscribes to outbox events and writes audit rows.
3. **Database CDC** triggers on critical tables (sales, payments, account_movements, cash_registers, register_sessions, users, roles).

Critical operations (administrative reversals, register re-opens, blind returns over threshold, credit-limit overrides) emit dedicated audit events with full context.

---

## 8. Trigger Usage Policy

**Allowed in triggers:**
- Immutability enforcement (REVOKE UPDATE/DELETE side hook).
- `updated_at` timestamps.
- Tenant-id integrity check.
- Simple computed/generated fields (e.g. `line_total = quantity * unit_price`).

**Forbidden in triggers:**
- Business logic ("on X, do Y").
- Cross-aggregate side effects (e.g. updating inventory on sale completion).
- Domain event publication.
- External service calls.
- State transitions.

> Domain logic lives in the application service. Triggers are infrastructure only.

---

## 9. Multi-Tenancy and RLS

See ADR 002 and ADR 007 for the full design. Summary:
- Every domain row carries `tenant_id`.
- PostgreSQL Row-Level Security (RLS) is enabled on every domain table.
- The application sets `app.tenant_id` per session; RLS policies filter on this.
- Background workers use a dedicated role with explicit `tenant_id` scoping.

---

## 10. Currency Discipline

- Multi-currency current accounts are tracked **per currency**, not auto-converted to TRY.
- Every monetary line item involving a non-TRY currency carries an `fx_snapshot_id`.
- TRY equivalent is stored as a denormalised column (`amount_try`) for reporting; the source of truth is the original-currency amount + snapshot.
- Live FX feeds are pluggable; `MANUAL` source is always available as an override.

---

## 11. DEBIT/CREDIT Semantics (Documentation)

In this system, `DEBIT` and `CREDIT` refer to the **business's** perspective on the party:

- `DEBIT` = "party owes us" (we are receivable).
- `CREDIT` = "we owe party" (we are payable).

This is **business-oriented terminology**, not double-entry accounting terminology. Helper functions `party_owes_us(amount, currency)` and `we_owe_party(amount, currency)` are provided at the service layer to avoid confusion.

When exporting to accounting software (Logo, Mikro), an explicit translation happens at the export boundary.

---

## 12. Terminal-Pending Pattern (POS Payment)

`sales.terminal_pending = true` indicates that a card terminal or bank transfer callback is awaited.

- Set when an async payment is initiated.
- The abandoned-cart cleanup job **must not** mark a sale ABANDONED while `terminal_pending = true`.
- A callback timeout (configurable, default 5 + 10 min grace) flags the sale for **manual reconciliation** instead of automatic action.
- Manager dashboard surfaces all pending terminal operations.

---

## 13. Variance Formula (Stock Count)

The correct formula accounts for movements during the count window:

```
expected_at_count_time = snapshot_quantity
                       + sum(IN movements between snapshot and count time)
                       - sum(OUT movements between snapshot and count time)

variance = counted_quantity - expected_at_count_time
```

Without this, sales executed during the count would be wrongly attributed as shrinkage.

---

## 14. Smart Code and Pricing Cipher

- Product `code` template is configurable per tenant or per category.
- Components: `{MENSEI}`, `{YIL}`, `{KATEGORI}`, `{SIRA:N}`, `{FIYAT_KODU}`, `{SEZON}`, `{SABIT:"X"}`.
- Optional price cipher uses a 10-distinct-letter keyword to encode purchase prices into a readable code, hiding cost from the end customer while keeping it on the label for staff. Tenant configures the keyword in settings.

---

## 15. Documentation Conventions

- Tables are named in `snake_case`, plural (e.g. `account_movements`).
- Append-only tables carry a header comment in the migration:
  > "Append-only operational ERP ledger. INSERT only. No UPDATE/DELETE. Reversal via new row with `reverses_movement_id`."
- Enum values are `UPPER_SNAKE_CASE`.
- Every aggregate root has a separate file in `/src/domain/<context>/<aggregate>/` (target implementation layout — TBD in Phase 6).
