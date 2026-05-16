# Part 2 — Sales + Returns + Purchasing

> **Status:** Locked (Phase 2E)
> **Tables:** 15
> **Migration files:** `010_sales.sql`, `011_returns.sql`, `012_purchasing.sql`

These tables are the POS hot path. Atomic transactions tie them to the stock and financial ledgers in Parts 1 and 3.

For SQL, see the migration files. This document explains the design and decisions.

---

## 1. Sales Context (5 tables + 1 shared)

| Table | Purpose | Key state |
|---|---|---|
| `sales` | Sale aggregate root | `status IN (DRAFT, AWAITING_PAYMENT, COMPLETED, VOIDED, ABANDONED)` |
| `sale_items` | Sale line items | Immutable after `sales.status = COMPLETED` |
| `sale_payments` | Tender records (denormalized for fast POS) | Immutable; references `payments` in Financial context |
| `payment_attempts` | Audit trail across DRAFT↔AWAITING_PAYMENT cycles | Append-only after `outcome` set |
| `sale_documents` | Receipt/invoice/e-document stubs (async generation) | State machine with retry support |
| `document_sequences` (shared) | Gap-free sequence allocator | Used by sales + returns + purchasing |

### `sales` — POS Heart

The DRAFT/AWAITING_PAYMENT/COMPLETED state machine is enforced by application service. The schema captures:

- **Monetary totals**: subtotal, cart_discount, vat_total, total (in sale currency), total_try (TRY equivalent for projections)
- **Currency + FX**: `fx_snapshot_id` mandatory when `currency != 'TRY'` (CHECK constraint)
- **Sale number**: assigned at completion via `document_sequences` UPDATE allocator — gap-free, transactional
- **Customer + cashier**: `cashier_user_id` mandatory operational actor (NOT NULL + RESTRICT)
- **Register session**: `register_session_id` ties sale to cash register; sessions force-finalize all linked sales on close

### Administrative reversal (Phase 2C)

A COMPLETED sale's state **never changes**. To "undo" a sale that should not have happened, operational flag columns are set:

```sql
administratively_reversed_at        TIMESTAMPTZ,
administratively_reversed_by_user_id UUID REFERENCES users(id) ON DELETE SET NULL,
administrative_reversal_reason      TEXT,
administrative_reversal_ticket_id   UUID
```

The reversal additionally writes compensating stock and account movements via the reversal pattern. Projections (`stock_balances`, `account_balances`, `daily_sales_summary`) filter on `administratively_reversed_at IS NULL`.

This is **not** a state transition. The sale row still says `status = 'COMPLETED'`, preserving audit truth: "this sale happened, and was later administratively reversed."

### Terminal pending (Phase 2C)

Card payments may take seconds or minutes for the terminal to acknowledge. The schema models this:

```sql
terminal_pending              BOOLEAN NOT NULL DEFAULT false,
terminal_pending_since        TIMESTAMPTZ,
terminal_pending_metadata     JSONB,
requires_manual_reconciliation BOOLEAN NOT NULL DEFAULT false
```

`terminal_pending_metadata` carries:

```json
{
  "terminal_id": "POS-IST01-T01",
  "terminal_provider": "INGENICO_MOVE5000",
  "terminal_transaction_id": "TXN-9234-8821",
  "tender_amount": 480.00,
  "tender_currency": "TRY",
  "card_masked": "**** **** **** 1234",
  "expected_callback_by": "2026-05-15T14:35:00Z"
}
```

When `RegisterSession.close()` runs and `terminal_pending = true`, the sale is NOT abandoned (would lose the customer's money). Instead `requires_manual_reconciliation = true` and the sale remains AWAITING_PAYMENT for an operator to resolve.

### Idempotency

`sales.idempotency_key` (partial UNIQUE) protects against double Sale.complete calls from network retries.

### `sale_items` immutability

Trigger `protect_completed_sale_items` raises if `sales.status = 'COMPLETED'` and the item's monetary or variant fields change. `notes` and `metadata` may still be edited.

```sql
CREATE TRIGGER protect_completed_sale_items
  BEFORE UPDATE ON sale_items
  FOR EACH ROW EXECUTE FUNCTION prevent_sale_item_modification_after_complete();
```

The trigger reads `sales.status` per UPDATE — one extra SELECT. Acceptable for MVP (INSERTs do not hit this trigger). Performance alternatives noted in `conventions.md` §12.

### `sale_items.unit_cost_try` — Cost Snapshot (ADR 003)

Set at sale completion using the WAC from `stock_balances`. **Never** modified afterward. This is the invariant that makes margin reporting historically stable.

A reporting query joining `sale_items` to `stock_movements` to recompute COGS uses `sale_items.unit_cost_try` — not a fresh balance calculation. Two months later when prices and balances have moved on, the historical margin remains unchanged.

### `payment_attempts` — The "Don't Lose Cashier's Work" Pattern

Phase 2C refinement: when AWAITING_PAYMENT times out (15 min idle) and the sale rolls back to DRAFT, the cashier's entered tender attempts (card decline, partial cash, terminal timeout) MUST be preserved for audit.

Each entry/exit into AWAITING_PAYMENT creates a new `payment_attempts` row with `attempt_number`. Within that attempt, `tender_attempts JSONB` is appended (one element per tender try). Once `outcome` is set (COMPLETED, ABANDONED_TIMEOUT, CANCELLED_BY_CASHIER, FAILED, ROLLED_BACK_TO_DRAFT), the row becomes immutable.

```
Sale lifecycle:
  DRAFT
    → AWAITING_PAYMENT [Attempt #1]
      ↳ card swipe → terminal timeout (recorded in tender_attempts JSONB)
      ↳ idle 15 min → outcome='ABANDONED_TIMEOUT'
    → DRAFT (rolled back)
    → AWAITING_PAYMENT [Attempt #2]
      ↳ cash 200 + card 280 → COMPLETED
  → COMPLETED
```

Forensic query: "show all tender attempts for sale X" reveals the full history.

### `sale_documents` — Async Generation Pattern (ADR 005)

At sale commit, a STUB row is INSERTed with `status = 'PENDING_GENERATION'` and `pdf_path = NULL`. Background workers pick up stubs from this table.

Status enum:

- `PENDING_GENERATION` — initial, worker queue
- `GENERATING` — worker actively processing
- `RETRY_SCHEDULED` — transient failure, retry per `next_attempt_at`
- `READY` — PDF generated, `pdf_path` set
- `FAILED` — exceeded retry budget, manual intervention
- `PRINTED` — successfully sent to printer
- `SUBMITTED` — e-document accepted by provider

`next_attempt_at` indexes retry-due rows efficiently. Worker polling pattern uses `FOR UPDATE SKIP LOCKED`.

---

## 2. Returns Context (4 tables)

| Table | Purpose | Key state |
|---|---|---|
| `returns` | Return aggregate root | `status IN (DRAFT, AWAITING_APPROVAL, COMPLETED, VOIDED)` |
| `return_items` | Return line items | Immutable after `returns.status = COMPLETED` |
| `return_documents` | Return receipt / refund voucher / credit note (async) | Same pattern as `sale_documents` |
| `exchange_groups` | Saga state for two-step Return + new Sale | Phase 2D saga aggregate |

### Two return modes

```sql
mode VARCHAR(20) NOT NULL CHECK (mode IN ('RECEIPTED','BLIND'))
```

- **RECEIPTED**: customer brings receipt; `original_sale_id` mandatory; cost snapshot copied from original `sale_items.unit_cost_try` (ADR 003).
- **BLIND**: no receipt; `original_sale_id IS NULL`; `unit_cost_try` set to current WAC at completion time. Carries anti-fraud guardrails:
  - `feature_flags.allow_blind_return` must be true
  - Tenant-configured caps: `blind_return_max_amount_per_day`, `blind_return_max_count_per_day`
  - Manager approval threshold: `blind_return_manager_threshold`
  - Customer frequency limit: `blind_return_customer_frequency_limit` (max BLIND returns per customer per N days)

CHECK constraint: `(mode = 'RECEIPTED' AND original_sale_id IS NOT NULL) OR (mode = 'BLIND' AND original_sale_id IS NULL)`.

### Approval workflow

`status = 'AWAITING_APPROVAL'` when one or more thresholds tripped. `approval_reasons TEXT[]` records which:

- `AMOUNT_THRESHOLD` — total exceeds `return_manager_threshold`
- `GRACE_PERIOD_EXCEEDED` — outside `return_grace_days` window
- `USED_CONDITION` — any line item has `condition != 'NEW'`
- `BLIND_AMOUNT_THRESHOLD` — BLIND mode amount tripped manager threshold
- `CUSTOMER_FREQUENCY` — customer's BLIND return frequency exceeded

Roadmap v1.1: migrate to `return_approval_reasons` lookup table for per-store/per-category custom rules.

### Refund method breakdown

Four refund channels, summing to `total`:

```sql
refund_cash, refund_card_reversal, refund_customer_balance, refund_debt_reduction
```

`refund_debt_reduction` is used when the customer had outstanding debt that the return clears. The matching credit goes to `account_movements` in the Financial context.

### `exchange_groups` — Saga Aggregate

Coordinates Return + new Sale as two atomic transactions linked by `exchange_group_id`. The schema:

```sql
status VARCHAR(30) NOT NULL CHECK (status IN (
  'AWAITING_RETURN',     -- Step 1 not yet committed
  'AWAITING_SALE',       -- Step 1 done, step 2 pending
  'COMPLETED',           -- Both steps done
  'STALLED',             -- Step 2 timeout, customer has credit balance
  'CANCELLED'            -- Cashier cancelled before step 1
))
```

**Critical UNIQUE constraints** (Part 2 review fix):

```sql
CREATE UNIQUE INDEX idx_eg_return_unique ON exchange_groups(return_id) WHERE return_id IS NOT NULL;
CREATE UNIQUE INDEX idx_eg_sale_unique ON exchange_groups(sale_id) WHERE sale_id IS NOT NULL;

-- Defence in depth on sales/returns tables:
CREATE UNIQUE INDEX idx_sales_exchange_group_unique ON sales(exchange_group_id) WHERE exchange_group_id IS NOT NULL;
CREATE UNIQUE INDEX idx_returns_exchange_group_unique ON returns(exchange_group_id) WHERE exchange_group_id IS NOT NULL;
```

A return can be used in **at most one** exchange. If step 2 fails or the customer leaves, the return becomes a credit balance — they cannot start a new exchange with the same return.

**No FAILED state**: per Phase 2D, partial outcomes are valid business states. STALLED means "customer retains credit, recoverable later".

---

## 3. Purchasing Context (5 tables)

| Table | Purpose | Key state |
|---|---|---|
| `purchase_invoices` | Supplier invoice aggregate | `status IN (DRAFT, POSTED, CANCELLED)` |
| `purchase_invoice_items` | Invoice line items with original-currency cost | Immutable after POSTED |
| `purchase_invoice_documents` | Supplier invoice scan PDF + attachments | Pre-uploaded before commit |
| `purchase_returns` | Supplier return aggregate | DRAFT → POSTED |
| `purchase_return_items` | Return line items | |

### Multi-currency cost capture

Cost is recorded in both original currency and TRY:

```sql
unit_cost_original  NUMERIC(15,4) NOT NULL,  -- in invoice currency
original_currency   VARCHAR(10),
unit_cost_try       NUMERIC(15,4) NOT NULL,  -- computed via fx_snapshot
fx_snapshot_id      UUID REFERENCES fx_snapshots(id) ON DELETE RESTRICT
```

CHECK constraint: `currency = 'TRY' OR fx_snapshot_id IS NOT NULL` — FX snapshot mandatory for non-TRY invoices.

The FX snapshot is captured at the time of posting and never updated, so cost in TRY is historically stable.

### Duplicate prevention (enterprise-grade)

```sql
CREATE UNIQUE INDEX idx_pi_supplier_invoice_unique
  ON purchase_invoices(supplier_id, supplier_invoice_number)
  WHERE supplier_invoice_number IS NOT NULL AND status = 'POSTED';
```

Same supplier cannot have two POSTED invoices with the same `supplier_invoice_number`. DRAFTs may share numbers (corrections), only POSTED is locked.

Real-world value: an accidentally double-entered supplier invoice (common in busy stockrooms) is rejected by the database.

### Pre-uploaded documents

`purchase_invoice_documents` references S3 paths uploaded BEFORE the invoice transaction commits. The atomic post operation references already-uploaded files; if the transaction rolls back, the files become orphans (cleaned by a nightly job).

`purchase_invoice_documents.storage_path` has `CHECK (length(trim(storage_path)) > 0)` — defence against empty strings (Part 2 review fix).

### Purchase returns

Symmetric to customer returns but for supplier-returned goods:

- `original_invoice_id` mandatory (always receipted)
- `original_pi_item_id` per line item — for cost copy and traceability
- Cost copied from original invoice item (`unit_cost_original`, `unit_cost_try`)
- Stock OUT to supplier, account_movement CREDIT to supplier balance

---

## 4. Shared: `document_sequences`

Gap-free sequence allocator used by sales, returns, and purchase invoices:

```sql
CREATE TABLE document_sequences (
  tenant_id      UUID NOT NULL,
  store_id       UUID NOT NULL,
  document_type  VARCHAR(30) NOT NULL,
  year           INT NOT NULL,
  last_number    BIGINT NOT NULL DEFAULT 0,
  PRIMARY KEY (tenant_id, store_id, document_type, year)
);
```

Allocation pattern:

```sql
INSERT INTO document_sequences (...) VALUES (..., 0) ON CONFLICT DO NOTHING;
UPDATE document_sequences SET last_number = last_number + 1 WHERE ... RETURNING last_number;
```

Transaction rollback undoes the increment. Hot-row contention acknowledged in conventions.md §17 with v1.1+ sharding roadmap.

---

## Cross-Cutting Disciplines Reflected

| Discipline | Where applied in Part 2 |
|---|---|
| Atomic transactions | `Sale.complete()` writes sales + sale_items + sale_payments + stock_movements + account_movements + sale_documents (STUB) + outbox in ONE COMMIT |
| Idempotency keys | `sales`, `returns`, `purchase_invoices`, `purchase_returns` |
| Cost snapshot immutable | `sale_items.unit_cost_try`, `return_items.unit_cost_try`, `purchase_invoice_items.unit_cost_try` — protected by triggers |
| FX snapshot mandatory | CHECK constraints on sales, returns, purchase_invoices |
| Administrative reversal | Operational flags, not state changes |
| Stock movement back-references | `sale_items.stock_movement_id`, `return_items.stock_movement_id`, `pi_items.stock_movement_id`, `pri_items.stock_movement_id` |
| Document stub + async generation | `sale_documents`, `return_documents` with RETRY_SCHEDULED + next_attempt_at |
| Mandatory operational actors | `cashier_user_id` NOT NULL + RESTRICT; `posted_by_user_id` nullable + RESTRICT + CHECK conditional on POSTED |
| Audit-only actors | `voided_by_user_id`, `approver_user_id`, `cancelled_by_user_id` all SET NULL |
| Storage path safety | CHECK length > 0 on all *_path columns |
| TRY amount safety | CHECK >= 0 on all *_try, *_amount, *_total columns |

---

## Open Items (Roadmap)

- **v1.1+** — `return_approval_reasons` lookup table replacing TEXT[].
- **v1.1+** — e-Belge integration on `sale_documents.e_document_*` fields (provider TBD).
- **v1.1+** — `document_sequences` sharding strategies under high concurrency.
- **v1.1+** — Trigger performance: denormalized `parent_status` flag on items if measured contention emerges.
- **v2** — Multi-currency cash register (currently single-currency per session).
