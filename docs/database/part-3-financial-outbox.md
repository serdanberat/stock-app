# Part 3 — Party + FX + Financial + Cash Register + Outbox + Audit

> **Status:** Locked (Phase 2E)
> **Tables:** 26
> **Materialized views:** 5
> **Migration files:** `004_fx_data.sql`, `007_party.sql`, `008_financial.sql`, `009_cash_register.sql`, `013_outbox.sql`, `014_materialized_views.sql`

This is the financial heart of the system. `account_movements` and `cash_movements` are append-only ledgers parallel to `stock_movements`. `outbox_events` carries every cross-context state change to consumers. Materialized views power dashboards.

---

## 1. Party Context (3 tables)

| Table | Purpose |
|---|---|
| `parties` | Unified customers + suppliers + employees |
| `party_contacts` | Phones, emails, addresses |
| `party_documents` | Tax certificates, IDs, contracts (S3 references) |

### Unified party model

`party_types TEXT[]` — a single row may carry multiple roles. Example: a tenant's wholesale buyer might also work as an employee. CHECK constraint:

```sql
party_types <@ ARRAY['CUSTOMER','SUPPLIER','EMPLOYEE','OTHER']
```

Indexed via GIN for `WHERE 'CUSTOMER' = ANY(party_types)` queries.

### PII anonymization

`is_anonymized BOOLEAN` flag set during tenant ARCHIVED operation (ADR 009). After anonymization:

- `display_name = 'Anonymized Party'`
- `legal_name = NULL`
- `tax_id = NULL`
- `tax_office = NULL`
- `metadata = '{}'`
- `party_contacts` rows deleted entirely

Commercial records (sales, invoices, payments, account_movements) preserve the FK to the party row but never re-display the original identity.

### Indexes

- `idx_parties_tenant_code` — unique business code per tenant (when set)
- `idx_parties_types_gin` — role filtering
- `idx_parties_tax_id` — partial, excludes anonymized
- `idx_parties_name_trgm` — fuzzy search via pg_trgm
- `idx_pc_phone_lookup` — POS customer search by phone
- `idx_pc_email_lookup` — case-insensitive email via `lower()`
- `idx_pc_one_primary_per_type` — at most one primary per party per type

---

## 2. FX Context (4 tables)

| Table | Purpose | Append-only? |
|---|---|---|
| `currencies` | System-wide currency lookup | No (mutable: is_active flag) |
| `fx_rate_sources` | TCMB, HAREM, MANUAL, FOREKS, etc. | No |
| `fx_rates` | Time-stamped rate observations | **YES** |
| `fx_snapshots` | Immutable per-document snapshots | **YES (immutable)** |

### Currency configuration

Phase 1 decision: TRY, USD, EUR, GBP active in MVP. XAU/XAG/XAU22/XAU14/XAU_CEYREK defined but inactive (v2 jewelry context). Application enforces "TRY cannot be deactivated".

### Pluggable provider system

`fx_rate_sources.implementation_class VARCHAR(100)` names the backend module that fetches rates. Adding a new source = (1) implement provider class, (2) INSERT row into `fx_rate_sources`. Schema is provider-agnostic.

MVP active: TCMB (daily), HAREM (realtime, critical for boutiques), MANUAL.
Infrastructure-ready but inactive: FOREKS, GOLDISTANBUL, BIGPARA, DOVIZCOM.

### `fx_rates` — Append-Only

Every rate observation = one row. Source's update frequency determines volume (HAREM ~1440 rows/currency/day).

```sql
CONSTRAINT chk_fxr_buy_lte_sell CHECK (buy_rate <= sell_rate)
CONSTRAINT chk_fxr_not_future CHECK (effective_at_utc <= now() + interval '1 hour')
```

Append-only enforced via REVOKE + trigger. Roadmap v1.1+: monthly RANGE partitioning when row count > 5M.

### `fx_snapshots` — Immutable Document Anchor

Every non-TRY transaction (sale, return, purchase invoice, payment) references a snapshot. The snapshot captures all currency rates at the moment of the business event:

```json
{
  "schema_version": "v1",
  "rates": {
    "USD": { "buy": 39.40, "sell": 39.48 },
    "EUR": { "buy": 43.10, "sell": 43.25 }
  }
}
```

After the document references the snapshot, **the snapshot is immutable** (REVOKE UPDATE/DELETE + trigger). This is the ADR-003 invariant for FX: a sale completed at rate 39.48 stays at 39.48 forever, even if rates change five minutes later.

---

## 3. Financial Context (7 tables) — The Mali Heart

| Table | Purpose | Append-only? |
|---|---|---|
| `account_profiles` | Party's account profile per (role, currency) | No (mutable: credit_used, account_status) |
| `account_movements` | The financial ledger | **YES** |
| `account_movement_sequences` | Per-profile aggregate_sequence allocator | No |
| `account_balances` | Projection: total_debit, total_credit, net_balance | Atomic update by application |
| `payments` | Payment aggregate (received + made + reversal) | No (status transitions allowed pre-COMPLETED) |
| `payment_allocations` | Payment ↔ account_movement link | No (can be reopened by reversal) |
| `account_aging` | Nightly-computed aging buckets | Refreshed by job |

### `account_profiles` — Where credit terms live (Phase 2A refinement)

Originally, credit terms (limit, payment_terms_days) were on `parties`. Phase 2A moved them here because:

- A party may be both customer and supplier with different credit terms
- Multi-currency: a customer with TRY credit limit also has separate USD credit limit
- Unique key: `(tenant_id, party_id, party_role, currency)` enforced

`credit_used` is denormalized (synced atomically with `account_balances`) for fast credit-limit checks on Sale.complete.

State machine: `NORMAL → WATCH → BLOCKED → CLOSED`. Auto-block triggers via `auto_block_on_overdue_days` (nullable; opt-in per profile).

### `account_movements` — Append-Only Ledger

Operational ERP terminology — not formal accounting journal. DEBIT/CREDIT are business-oriented:

```
DEBIT  = "party owes us" (we are receivable)
CREDIT = "we owe party" (we are payable)
```

Per Phase 2D refinement, the table comment makes this explicit so DDD purists and accounting purists don't conflate it with formal double-entry.

### Direction ↔ movement_type consistency

CHECK constraint enforces:

```
DEBIT types:
  SALE_DEBIT, RETURN_CREDIT_USED, PURCHASE_REFUND,
  PAYMENT_MADE, MANUAL_DEBIT, OPENING_BALANCE_DEBIT

CREDIT types:
  SALE_REFUND, PAYMENT_RECEIVED, PURCHASE_DEBIT,
  MANUAL_CREDIT, OPENING_BALANCE_CREDIT
```

### `aggregate_sequence`

Per-`account_profile_id` monotonic counter via `account_movement_sequences` UPDATE allocator. Same pattern as `stock_movements`.

### Append-only + reversal pattern + reversal-of-reversal forbidden

Same triggers as `stock_movements`:

```sql
REVOKE UPDATE, DELETE ON account_movements FROM PUBLIC;
CREATE TRIGGER no_modify_account_movements ...
CREATE TRIGGER check_account_reversal_of_reversal ...
```

### `account_balances` — Projection

Atomic transactional update by application service:

```sql
total_debit, total_credit          -- in account_profile currency
net_balance GENERATED AS (debit - credit)
total_debit_try, total_credit_try  -- TRY equivalents for reporting
overdue_amount, oldest_overdue_date -- denormalized for fast dashboard
```

Net balance:
- Positive → party owes us (receivable)
- Negative → we owe party (payable / customer credit)

### `payments` aggregate

Three payment types:

```
RECEIVED  — from customer (post-credit-sale or pre-purchase deposit)
MADE      — to supplier (settling purchase invoice)
REVERSAL  — undoing a previous payment (FULL or PARTIAL)
```

State machine: `DRAFT → COMPLETED` or `→ REVERSED` or `→ PARTIALLY_REVERSED` or `→ FAILED` or `→ CANCELLED`.

### Payment reversal (Phase 2C — FULL + PARTIAL)

When reversing a payment:

- Original payment retained with status `REVERSED` (full) or `PARTIALLY_REVERSED` (partial)
- New reversal payment row created with `payment_type = 'REVERSAL'`
- `reversal_info JSONB` on the reversal records: original_payment_id, reversal_type (FULL/PARTIAL), reversed allocation IDs, reason category, approver
- `reversed_by_payment_id` on original points to reversal payment
- Compensating account_movements created (reverses_movement_id on each)
- `payment_allocations.is_reopened = true` for partially or fully reversed allocations
- **Reversal of reversal forbidden** — application + DB level

```json
{
  "original_payment_id": "uuid",
  "reversal_type": "FULL" | "PARTIAL",
  "reversed_allocation_ids": [...],
  "reason_category": "CHARGEBACK" | "BOUNCED" | "MISTAKE",
  "approved_by_user_id": "uuid"
}
```

### Cash payment validation

CHECK: `tender_type != 'CASH' OR register_session_id IS NOT NULL`. A cash payment must belong to an open register session — otherwise no audit trail exists for the cash entering/leaving the till.

### `account_aging`

Nightly job computes aging buckets:

```sql
current_amount       -- 0-30 days
overdue_30_60
overdue_60_90
overdue_90_plus
total GENERATED AS (current + 30_60 + 60_90 + 90_plus)
```

Refreshed atomically per tenant by a scheduled job. Backed by partial index on `overdue_90_plus > 0` for collection dashboards.

---

## 4. Cash Register Context (6 tables)

| Table | Purpose | Append-only? |
|---|---|---|
| `cash_registers` | Physical registers (POS terminals) | No |
| `register_sessions` | Daily session (open → cashier work → close) | No (state machine: OPEN → CLOSING → CLOSED) |
| `cash_movements` | Every cash flow within a session | **YES** |
| `z_reports` | Sealed end-of-day report | Effectively immutable (no DELETE allowed) |
| `z_report_number_sequence` | Gap-free Z number allocator (regulatory) | UPDATE-based |
| `z_report_sequence_audit` | Audit trail of sequence allocations | Append-only |

### Session state machine (Phase 2C)

```
OPEN → CLOSING → CLOSED
       (10 min grace period for in-flight sales)

CLOSED → OPEN: extremely rare, requires feature_flags.allow_admin_register_reopen,
              super_admin role, co-signature, audit ticket.
              reopen_count incremented; reopen_reason recorded.
```

UNIQUE constraint: at most one OPEN session per register (`WHERE status = 'OPEN'`).

### Grace period close (Phase 2C)

When cashier presses "Close Day":
1. Status: OPEN → CLOSING
2. UI blocks new sale creation
3. Existing DRAFT/AWAITING_PAYMENT sales may complete for 10 minutes
4. After grace period (or cashier confirms):
   - DRAFT/AWAITING_PAYMENT sales with `terminal_pending = false` → ABANDONED
   - DRAFT/AWAITING_PAYMENT sales with `terminal_pending = true` → flag `requires_manual_reconciliation`, retained as AWAITING_PAYMENT
5. Z report number allocated (gap-free)
6. Status: CLOSING → CLOSED

### `cash_movements` — Append-Only

Every till transaction:

```
movement_type: OPENING_FLOAT | SALE_CASH_IN | SALE_CARD | SALE_TRANSFER
             | REFUND_CASH | REFUND_CARD | CHANGE_GIVEN
             | CASH_IN_OTHER | CASH_OUT_OTHER
             | DEPOSIT_TO_BANK | OWNER_DRAW | EXPENSE | CASH_COUNT_VARIANCE
```

Signed `amount`: positive for IN, negative for OUT. Append-only enforced.

### `z_reports` — Regulatory Compliance

```sql
report_number    VARCHAR(100) NOT NULL  -- Composed: "Z-{TENANT_PREFIX}-{STORE_CODE}-2026-000123"
sequence_year    INT NOT NULL
sequence_value   BIGINT NOT NULL        -- Allocated atomically from z_report_number_sequence
```

**Gap-free allocation** (regulatory requirement):

```sql
INSERT INTO z_report_number_sequence (...) VALUES (..., 0) ON CONFLICT DO NOTHING;
UPDATE z_report_number_sequence SET last_number = last_number + 1
  WHERE ... RETURNING last_number;
-- Rollback undoes increment → no gaps
```

Z reports cannot be deleted (REVOKE DELETE + trigger). Can be `INVALIDATED` (if session reopened) — flag set, original row retained.

Status: PENDING_GENERATION → GENERATING → READY (with PDF) or RETRY_SCHEDULED → FAILED. PDF rendered async by Z Report Worker (ADR 005).

### `z_report_sequence_audit`

Tracks each allocation for forensic verification:

```sql
status: 'ALLOCATED' (incremented but not yet committed)
      | 'COMMITTED' (Z report row exists)
      | 'NO_SESSION_FOUND' (orphaned allocation — should never happen, alert)
```

A nightly job scans for `status != 'COMMITTED'` rows and alerts.

---

## 5. Outbox & Cross-Cutting (6 tables)

| Table | Purpose | Append-only? |
|---|---|---|
| `outbox_events` | Cross-context event publisher (Phase 2D core) | Mutable (status transitions) |
| `outbox_global_sequences` | Per-tenant global_sequence allocator | No |
| `processed_events` | Consumer idempotency table | No |
| `audit_event_log` | Business-critical events audit | **YES** |
| `security_audit_log` | Auth/security events (separate stream) | **YES** |
| `process_instances` | Saga state for Exchange, Transfer, DayEndClose, TenantLifecycle | No |

### `outbox_events` — Full Phase 2D Envelope

The table embodies the envelope contract from `domain-events.md`:

```sql
outbox_sequence       BIGSERIAL PRIMARY KEY        -- publisher read order
event_id              UUID UNIQUE                   -- consumer idempotency key
tenant_id             UUID NOT NULL                 -- RLS
aggregate_type, aggregate_id, aggregate_version
aggregate_sequence    BIGINT                        -- per-aggregate ordering (ledger events)
global_sequence       BIGINT                        -- per-tenant gap detection
event_type, event_version
partition_key         VARCHAR(255)                  -- aggregate_id (ADR 008)
payload, metadata     JSONB
occurred_at, recorded_at
status                'PENDING'|'PUBLISHED'|'FAILED'|'DEAD_LETTER'
publish_attempts      INT
dead_letter_at, dead_letter_reason
```

`dead_letter_reason` CHECK enum (Phase 2D):

- `MAX_ATTEMPTS_EXCEEDED`
- `SCHEMA_MISMATCH`
- `POISON_EVENT`
- `CONSUMER_PERMANENT_FAILURE`
- `MANUAL_DLQ`
- `TENANT_ARCHIVED`

### Indexes

- `idx_outbox_pending(recorded_at) WHERE status = 'PENDING'` — publisher polling
- `idx_outbox_dlq(tenant_id, dead_letter_at DESC) WHERE status = 'DEAD_LETTER'` — DLQ browsing
- `idx_outbox_aggregate(aggregate_type, aggregate_id, recorded_at DESC)` — per-aggregate queries
- `idx_outbox_tenant_global_seq(tenant_id, global_sequence) UNIQUE` — gap detection

### Publisher worker pattern

```sql
SELECT * FROM outbox_events
WHERE status = 'PENDING'
ORDER BY recorded_at ASC, outbox_sequence ASC
LIMIT 100
FOR UPDATE SKIP LOCKED;

-- Process each event, publish to consumer(s)
-- On success:
UPDATE outbox_events SET status = 'PUBLISHED', published_at = now() WHERE id = ...;

-- On failure:
UPDATE outbox_events
SET status = 'FAILED', publish_attempts = publish_attempts + 1,
    last_attempt_at = now(), last_error = ?
WHERE id = ...;

-- After N attempts within 24h:
UPDATE outbox_events
SET status = 'DEAD_LETTER', dead_letter_at = now(),
    dead_letter_reason = 'MAX_ATTEMPTS_EXCEEDED'
WHERE id = ...;
```

### `processed_events` — Consumer Idempotency

Composite PK: `(consumer_name, event_id)`. Every consumer writes one row per event it processes, **in the same transaction as its projection update**:

```python
def handle(event):
    if exists in processed_events(consumer_name=self.name, event_id=event.id):
        return  # already processed
    with transaction:
        apply_projection_update(event)
        INSERT INTO processed_events (consumer_name=self.name, event_id=event.id,
                                       result_status='SUCCESS', ...)
```

Crash mid-processing? Rollback. Next attempt re-applies idempotently.

**Roadmap**: monthly partitioning when row count > 10M.

### `audit_event_log` vs `security_audit_log` — Two Streams

The separation is ADR 008's decision:

- `audit_event_log` — domain events of business significance (administrative reversals, BLIND return approvals, credit limit overrides, party blocks, etc.). Severity: INFO / WARN / CRITICAL.
- `security_audit_log` — auth, MFA, password, session, IP-level signals. High frequency, different retention/replay semantics.

Both append-only. Both have IP/user_agent for forensic value.

Brute-force detection uses `security_audit_log`:

```sql
CREATE INDEX idx_sec_brute_force
  ON security_audit_log(ip, occurred_at DESC)
  WHERE outcome = 'FAILED' AND event_type = 'LOGIN_FAILED';
```

### `process_instances` — Saga State

```sql
process_type     'EXCHANGE' | 'TRANSFER' | 'DAY_END_CLOSE' |
                 'TENANT_LIFECYCLE' | 'SALE_DOCUMENT_GENERATION'
correlation_key  VARCHAR(100)         -- exchange_group_id, transfer_id, session_id, ...
status           'IN_PROGRESS' | 'COMPLETED' | 'STALLED' | 'FAILED' | 'CANCELLED'
current_step     VARCHAR(50)
state_data       JSONB
deadline_at      TIMESTAMPTZ          -- For stuck-process detection
```

Some sagas (Exchange, Transfer) duplicate state in their own aggregate (`exchange_groups`, `transfers`). `process_instances` is the catch-all for those without a dedicated aggregate (DayEndClose, TenantLifecycle).

---

## 6. Materialized Views (5)

| View | Purpose | Refresh |
|---|---|---|
| `daily_sales_summary` | Per-store-per-day totals, COGS, gross profit | Every 5 min |
| `top_selling_variants` | Per-month top sellers with revenue, COGS, margin | Every 30 min |
| `stock_position_summary` | Current stock by variant with LOW/HIGH/NORMAL classification | Every 10 min |
| `customer_aging_summary` | Per-customer aging joined with credit_limit | Nightly 02:00 |
| `supplier_aging_summary` | Per-supplier aging | Nightly 02:00 |

All views are based on append-only source tables (NOT on outbox). ADR 009: projections can be rebuilt from source-of-truth tables.

All views have `UNIQUE INDEX` to enable `REFRESH MATERIALIZED VIEW CONCURRENTLY` — non-blocking for reads.

### Critical: filters on administrative reversal

`daily_sales_summary` excludes administratively-reversed sales:

```sql
WHERE s.status = 'COMPLETED'
  AND s.administratively_reversed_at IS NULL
```

This ensures dashboards reflect the canonical business reality, not raw row counts.

---

## Cross-Cutting Disciplines Reflected

| Discipline | Where applied in Part 3 |
|---|---|
| Three append-only ledgers | `stock_movements` (Part 1), `account_movements`, `cash_movements`, `fx_rates`, `fx_snapshots`, `audit_event_log`, `security_audit_log` |
| Reversal pattern | `account_movements.reverses_movement_id`; reversal-of-reversal forbidden via trigger |
| Idempotency keys | `payments.idempotency_key`, `register_sessions.idempotency_key_close` |
| Gap-free sequence allocators | `z_report_number_sequence`, `outbox_global_sequences`, `account_movement_sequences` |
| RLS via `current_tenant_id()` | Every domain table |
| Stream separation | Domain events → `outbox_events`; auth/security → `security_audit_log` |
| Partition key default | `outbox_events.partition_key = aggregate_id` |
| PII anonymization | `parties.is_anonymized` flag; tenant-level archival irreversible by default |
| FX snapshot immutability | `fx_snapshots` REVOKE UPDATE/DELETE + trigger |
| Generated columns | `account_balances.net_balance`, `register_sessions.cash_variance`, `account_aging.total` |
| Mandatory operational actors | `payments.received_by_user_id` NOT NULL + RESTRICT; `register_sessions.opened_by_user_id` NOT NULL + RESTRICT |
| Audit-only actors | `payments` no extra audit actors; `register_sessions.closed_by_user_id` nullable + SET NULL |

---

## Open Items (Roadmap)

- **v1.1+** — Partition `account_movements`, `outbox_events`, `processed_events` by month.
- **v1.1+** — Currency code FK constraint tightening on `account_profiles.currency`, `account_movements.currency`, `payments.currency`.
- **v1.1+** — Move materialized view refresh to event-driven incremental updates (Reporting Projector consumer).
- **v1.1+** — Reversible pseudonymization key vault for the opt-in tenants.
- **v1.1+** — Distinct accounting export consumer (Logo, Mikro) — schema unchanged, new consumer registered.
- **v2** — Multi-currency cash registers (one session, multiple currencies tracked separately).
- **v2** — Custom report builder backed by user-defined materialized views.
