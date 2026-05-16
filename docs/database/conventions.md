# Database Conventions

> **Status:** Locked (Phase 2E)
> **Last updated:** 2026-05-15

This document defines the conventions every table in the schema obeys. New migrations must follow these rules; CI enforces them where mechanically possible.

---

## 1. Naming

| Object | Convention | Example |
|---|---|---|
| Tables | `snake_case`, plural | `stock_movements`, `account_movements`, `product_variants` |
| Columns | `snake_case` | `created_at`, `unit_cost_try`, `tenant_id` |
| Enum values | `UPPER_SNAKE_CASE` (TEXT) | `'COMPLETED'`, `'IN_PROGRESS'`, `'BLIND'` |
| Indexes | `idx_<table>_<purpose>` | `idx_sales_status`, `idx_sm_variant_store_time` |
| Foreign keys | `fk_<table>_<ref>` (when named explicitly) | `fk_sale_items_variant` |
| Check constraints | `chk_<table>_<rule>` | `chk_sale_amounts_nonneg` |
| Unique constraints | `uniq_<table>_<columns>` | `uniq_users_tenant_email` |
| Triggers | `set_updated_at_<table>`, `protect_<table>_*`, `no_modify_<table>` | |
| Functions | `verb_noun_*` | `current_tenant_id`, `prevent_stock_movement_modification` |
| Materialized views | `<noun>_summary` or `<noun>_position` | `daily_sales_summary`, `stock_position_summary` |

Short prefixes (e.g. `sm` for `stock_movements`, `pi` for `purchase_invoices`) are used inside index names where the full table name would be excessively long.

---

## 2. Standard Columns

Every **domain table** carries these columns:

```sql
id            UUID PRIMARY KEY DEFAULT gen_random_uuid(),
tenant_id     UUID NOT NULL REFERENCES tenants(id) ON DELETE RESTRICT,
created_at    TIMESTAMPTZ NOT NULL DEFAULT now(),
updated_at    TIMESTAMPTZ NOT NULL DEFAULT now()
```

Mutable tables also get the `set_updated_at_<table>` trigger.

Append-only tables additionally carry:

```sql
occurred_at   TIMESTAMPTZ NOT NULL DEFAULT now(),
recorded_at   TIMESTAMPTZ NOT NULL DEFAULT now()
```

`occurred_at` = when the business event actually happened (may be backdated).
`recorded_at` = when the row was inserted into the database (always `now()`).
The pair allows replay analysis and is required by the ADR-003 ledger pattern.

System-wide lookup tables (currencies, fx_rate_sources, roles, reason_codes) may carry `tenant_id NULL` to mean "system-wide".

---

## 3. Row-Level Security (RLS)

### The `current_tenant_id()` function

All RLS policies use a single shared function that fails safely if the session variable is missing:

```sql
CREATE OR REPLACE FUNCTION current_tenant_id()
RETURNS UUID AS $$
DECLARE
  raw_value TEXT;
BEGIN
  raw_value := current_setting('app.tenant_id', true);  -- missing_ok=true

  IF raw_value IS NULL OR raw_value = '' THEN
    -- Sentinel UUID; no real tenant matches this
    -- Result: queries return zero rows when context not set
    RETURN '00000000-0000-0000-0000-000000000000'::uuid;
  END IF;

  RETURN raw_value::uuid;
EXCEPTION
  WHEN invalid_text_representation THEN
    -- Garbage session var; same fail-safe
    RETURN '00000000-0000-0000-0000-000000000000'::uuid;
END;
$$ LANGUAGE plpgsql STABLE SECURITY DEFINER;
```

The `STABLE` marker lets PostgreSQL cache the value within a transaction. `SECURITY DEFINER` ensures the function runs with elevated rights regardless of the calling role.

### RLS policy template

Every domain table gets:

```sql
ALTER TABLE <table> ENABLE ROW LEVEL SECURITY;

CREATE POLICY tenant_isolation_<table> ON <table>
  USING (tenant_id = current_tenant_id());
```

### Application discipline

Three enforcement layers protect against tenant leakage:

```
Layer 1 — Application middleware
  Refuses unauthenticated requests; requires tenant_id from JWT/session

Layer 2 — Connection wrapper
  SET LOCAL app.tenant_id = '<uuid>' before yielding to repository code
  SET LOCAL scopes the setting to the current transaction
  (cleared on COMMIT, prevents leakage between requests on pooled connections)

Layer 3 — PostgreSQL RLS policy
  Uses current_tenant_id() — returns sentinel UUID if missing
  Result: query returns ZERO rows, not an error
  Fails safely without crashing the application
```

### Verification

A nightly audit job runs:

```sql
-- For each domain table, count rows that would be visible
-- in a transaction with no app.tenant_id set:
RESET app.tenant_id;  -- ensure unset
SELECT count(*) FROM <domain_table>;  -- MUST return 0 (sentinel UUID matches nothing)
```

A non-zero result means an RLS policy is missing or misconfigured. Alert fires.

### Tables WITHOUT RLS

- `tenants` itself — the row that drives RLS
- `currencies`, `fx_rate_sources` — system-wide lookups
- `processed_events` — consumer state, no tenant column (event_id implicitly scopes)
- `outbox_global_sequences` — has RLS (tenant_id present)
- `z_report_sequence_audit`, `z_report_number_sequence`, `outbox_global_sequences`, `account_movement_sequences`, `stock_movement_sequences` — have RLS

When a tenant column is technically present but a table is read by the database itself (sequence allocators, processed_events), RLS may still be enabled defensively; the SET LOCAL is performed by the application transaction.

---

## 4. ON DELETE Policy

Explicit ON DELETE clauses on every FK. No defaults relied upon.

| Relationship | Policy | Example |
|---|---|---|
| `tenant_id` FK | `RESTRICT` (tenant hard-delete forbidden by ADR 007) | `tenant_id UUID NOT NULL REFERENCES tenants(id) ON DELETE RESTRICT` |
| Aggregate root → child (composition) | `CASCADE` | `sale_items.sale_id → sales(id) ON DELETE CASCADE` |
| Reference to master data | `RESTRICT` | `sales.store_id → stores(id) ON DELETE RESTRICT` |
| Reference to immutable ledger row | `RESTRICT` | `sale_items.stock_movement_id → stock_movements(id) ON DELETE RESTRICT` |
| Mandatory actor (operational) | `NOT NULL` + `RESTRICT` | `sales.cashier_user_id`, `stock_adjustments.actor_user_id` |
| Conditional actor (filled during lifecycle) | nullable + `RESTRICT` + CHECK | `purchase_invoices.posted_by_user_id` (NULL until POSTED) |
| Audit-only actor (always optional) | nullable + `SET NULL` | `voided_by_user_id`, `approver_user_id`, `created_by_user_id` |
| Optional master FK | nullable + `SET NULL` | `products.brand_id`, `products.season_id` |

### Why this matters

The previous draft of Part 1/2 contained the pattern `NOT NULL REFERENCES users(id) ON DELETE SET NULL` — a contradiction. SET NULL would set the column to NULL on parent delete, violating NOT NULL. PostgreSQL would raise an error mid-transaction.

The corrected rules above resolve this:
- **Operational actors must always be known** — RESTRICT prevents deleting the actor while their work is referenced.
- **Audit-only actors may be lost** — SET NULL allows their record to go away while preserving the business row.

Since users are never hard-deleted (only `status = 'DEACTIVATED'`, per ADR 007), the RESTRICT clause is mostly defence-in-depth, not a frequent obstacle.

---

## 5. Append-Only Tables

The following tables are immutable after INSERT:

- `stock_movements`
- `account_movements`
- `cash_movements`
- `fx_rates`
- `fx_snapshots`
- `audit_event_log`
- `security_audit_log`

Enforcement is two-layered:

```sql
-- Layer 1: revoke DML
REVOKE UPDATE, DELETE ON <table> FROM PUBLIC;

-- Layer 2: trigger that raises if UPDATE/DELETE is attempted
CREATE OR REPLACE FUNCTION prevent_<table>_modification()
RETURNS TRIGGER AS $$
BEGIN
  RAISE EXCEPTION '<table> is append-only';
END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER no_modify_<table>
  BEFORE UPDATE OR DELETE ON <table>
  FOR EACH ROW EXECUTE FUNCTION prevent_<table>_modification();
```

### Conditional immutability

`sale_items`, `return_items`, `purchase_invoice_items`, `payment_attempts` are mutable while the parent aggregate is DRAFT, but immutable once the parent transitions to COMPLETED/POSTED/finalized. The trigger pattern:

```sql
CREATE OR REPLACE FUNCTION prevent_X_modification_after_complete()
RETURNS TRIGGER AS $$
DECLARE
  parent_status VARCHAR(30);
BEGIN
  SELECT status INTO parent_status FROM <parent_table> WHERE id = NEW.<parent_id>;
  IF parent_status = '<terminal_status>' THEN
    -- Allow only audit-irrelevant fields (notes, metadata) to change
    IF NEW.<monetary_field> IS DISTINCT FROM OLD.<monetary_field> THEN
      RAISE EXCEPTION 'X: cannot modify monetary fields after parent is finalized';
    END IF;
  END IF;
  RETURN NEW;
END;
$$ LANGUAGE plpgsql;
```

`payment_attempts` uses a slightly different rule: the row is mutable while `outcome IS NULL` and immutable once outcome is set (no JSONB append after finalization).

### Reversal pattern, not in-place modification

To "undo" an append-only row, INSERT a new row with `reverses_movement_id = <original_id>` and a compensating direction. Reversal-of-reversal is forbidden by trigger:

```sql
CREATE OR REPLACE FUNCTION prevent_reversal_of_reversal()
RETURNS TRIGGER AS $$
BEGIN
  IF NEW.reverses_movement_id IS NOT NULL THEN
    IF EXISTS (
      SELECT 1 FROM <table>
      WHERE id = NEW.reverses_movement_id
        AND reverses_movement_id IS NOT NULL
    ) THEN
      RAISE EXCEPTION 'Cannot reverse a reversal. Create a new corrective movement.';
    END IF;
  END IF;
  RETURN NEW;
END;
$$ LANGUAGE plpgsql;
```

Applied to `stock_movements` and `account_movements`.

---

## 6. Money & Quantity Conventions

| Concept | Type | Examples |
|---|---|---|
| Monetary amounts | `NUMERIC(15,4)` | `unit_price`, `total`, `amount_try`, `vat_amount` |
| Quantities | `NUMERIC(15,4)` | `quantity`, `dispatched_quantity` |
| FX rates | `NUMERIC(15,6)` | `buy_rate`, `sell_rate` |
| Percentages | `NUMERIC(5,2)` | `vat_rate`, `cart_discount_pct` (range 0–100) |
| Decimals per currency | INT | `currencies.decimals` (TRY=2, XAU=4) |

### Non-negativity checks

Every monetary column carries an explicit CHECK:

```sql
CONSTRAINT chk_<table>_<column>_nonneg CHECK (<column> >= 0)
```

`amount` columns on transactions use `> 0` (strictly positive); aggregated totals and balances may be zero.

### Cost snapshot

`*_items.unit_cost_try` is set at sale/return/post commit time and **never** updated after the parent reaches its terminal state. This is the ADR-003 invariant that makes margin reporting historically stable.

`stock_balances.average_cost_try` is the WAC rolling average; it changes with every IN movement but is a projection, not a snapshot.

---

## 7. Identifiers, Numbers, Idempotency

### Internal IDs

`id UUID PRIMARY KEY DEFAULT gen_random_uuid()` everywhere. Never auto-increment integers for domain IDs (multi-tenant, replication, offline-sync friendliness).

### Human-readable numbers

`sale_number`, `return_number`, `invoice_number`, `report_number` are assigned at **commit** time via UPDATE-based gap-free sequence allocators (`document_sequences`, `z_report_number_sequence`). Format is composed in the application layer:

```
S-{TENANT_PREFIX}-{YEAR}-{STORE_CODE}-{NUMBER:6}
```

Sequence allocation pattern:

```sql
INSERT INTO <sequence_table> (tenant_id, store_id, document_type, year, last_number)
VALUES (...)
ON CONFLICT DO NOTHING;

UPDATE <sequence_table>
SET last_number = last_number + 1
WHERE ...
RETURNING last_number;
-- Transaction rollback undoes the increment → no gaps
```

Hot-row contention under high concurrency is acknowledged; see ADR / roadmap for v1.1 sharding strategies.

### Idempotency keys

`idempotency_key VARCHAR(64)` columns appear on every state-changing entrypoint that is exposed to retries:

| Table | Key columns |
|---|---|
| `sales` | `idempotency_key` (Sale.complete) |
| `returns` | `idempotency_key` (Return.complete) |
| `purchase_invoices` | `idempotency_key` (PurchaseInvoice.post) |
| `purchase_returns` | `idempotency_key` |
| `payments` | `idempotency_key` (Payment.complete, PaymentReversal.execute) |
| `register_sessions` | `idempotency_key_close` |
| `transfers` | `idempotency_key_dispatch`, `idempotency_key_receive` |
| `count_sessions` | `idempotency_key_complete` |
| `stock_adjustments` | `idempotency_key` |

Each is a partial UNIQUE index (NULLs do not collide):

```sql
CREATE UNIQUE INDEX idx_<table>_idempotency
  ON <table>(tenant_id, idempotency_key)
  WHERE idempotency_key IS NOT NULL;
```

Consumers use their own `processed_events` table (separate from idempotency keys, which protect producers).

---

## 8. Sequence Numbers for Audit

Append-only ledger events carry `aggregate_sequence BIGINT` — a per-aggregate monotonic counter populated at INSERT via UPDATE-based sequence rows:

- `stock_movement_sequences` keyed by `(tenant_id, variant_id, store_id)` → populates `stock_movements.aggregate_sequence`
- `account_movement_sequences` keyed by `account_profile_id` → populates `account_movements.aggregate_sequence`
- `outbox_global_sequences` keyed by `tenant_id` → populates `outbox_events.global_sequence`

This enables gap detection on replay/debug ("which movements am I missing for variant X in store Y?").

---

## 9. Indexes

Every table gets:

- **Primary key** (UUID, default)
- **Tenant + status** composite for RLS-friendly filtering
- **Foreign key indexes** for join performance
- **Time-based DESC** indexes for chronological queries
- **Partial indexes** for hot-path queries (`WHERE status = 'OPEN'`, `WHERE quantity < min_level`)
- **GIN indexes** on JSONB columns when queried (`metadata`, `permissions`, `feature_flags`)
- **GIN trigram** indexes on text search columns (`display_name`)

Index count target: 3–8 per table. Excessive indexing inflates write cost.

### Partial unique indexes

Used for "at most one active X per parent" patterns:

```sql
-- One primary barcode per variant
CREATE UNIQUE INDEX idx_one_primary_barcode_per_variant
  ON product_variant_barcodes(variant_id)
  WHERE is_primary = true;

-- One default price list per tenant
CREATE UNIQUE INDEX idx_one_default_pricelist_per_tenant
  ON price_lists(tenant_id) WHERE is_default = true;

-- One OPEN register session per register
CREATE UNIQUE INDEX idx_rs_one_open_per_register
  ON register_sessions(cash_register_id) WHERE status = 'OPEN';

-- One IN_PROGRESS count session per store
CREATE UNIQUE INDEX idx_cs_one_in_progress_per_store
  ON count_sessions(store_id) WHERE status = 'IN_PROGRESS';
```

---

## 10. EXCLUDE Constraints (`variant_prices`)

`variant_prices` uses GiST + EXCLUDE for non-overlapping time intervals per `(variant, price_list, currency)`:

```sql
EXCLUDE USING gist (
  variant_id WITH =,
  price_list_id WITH =,
  currency WITH =,
  tstzrange(valid_from, valid_until, '[)') WITH &&
)
```

Two price rows for the same combination cannot have overlapping validity windows. The `[)` brackets mean inclusive `valid_from`, exclusive `valid_until`.

The `btree_gist` extension is required for this.

---

## 11. JSONB Cross-Tenant Reference Discipline

Several tables use JSONB to store flexible references to other tables (e.g. `product_variants.attributes`). When JSONB carries UUIDs that reference other tables, the application MUST validate that all such references belong to the same tenant as the owning row.

Examples:

- `product_variants.attributes` → references `attribute_values.id` — must be same tenant
- `products.metadata` → may contain references, validate case by case
- `tenant.feature_flags` → no cross-tenant refs allowed
- `fx_snapshots.rates` → no FK references, snapshot data only

Enforcement:

1. Application validators run on every INSERT/UPDATE.
2. RLS does **NOT** protect JSONB-embedded UUIDs (RLS works on row-level only).
3. Integration test must include "cross-tenant reference attempt → reject".
4. Optional DB-level trigger as defence in depth — evaluated for v1.1.

---

## 12. Triggers (Discipline)

Triggers carry **no business logic**. They exist only for:

- `updated_at` auto-update on mutable tables
- Append-only enforcement (raise on UPDATE/DELETE)
- Reversal-of-reversal prevention on ledgers
- Conditional immutability after parent finalization
- System-role protection (`roles.is_system = true` cannot be modified)

Application service code owns all behaviour. Triggers are integrity safety nets.

Performance implications:
- Conditional-immutability triggers execute one extra SELECT per UPDATE on `*_items` tables. UPDATEs on these tables are uncommon in the hot path (POS commits are pure INSERT). Acceptable for MVP.
- See roadmap for performance alternatives (denormalized parent_status flag, app-only enforcement) when measured contention occurs.

---

## 13. CHECK Constraints (Patterns)

Every constraint named `chk_<table>_<rule>`. Common patterns:

```sql
-- Non-negativity for monetary columns
CHECK (amount_try >= 0)

-- Strict positivity for transaction amounts
CHECK (amount > 0)

-- Enum-as-text
CHECK (status IN ('DRAFT','POSTED','CANCELLED'))

-- Date order
CHECK (valid_until IS NULL OR valid_until > valid_from)
CHECK (due_date IS NULL OR due_date >= invoice_date)

-- Conditional NULL/NOT NULL by status
CHECK (
  (status != 'POSTED' AND posted_by_user_id IS NULL) OR
  (status = 'POSTED' AND posted_by_user_id IS NOT NULL)
)

-- Length and format
CHECK (length(trim(barcode)) > 0)
CHECK (length(barcode) >= 4 AND length(barcode) <= 50)
CHECK (barcode_scope != 'GS1_EAN' OR (length(barcode) = 13 AND barcode ~ '^[0-9]{13}$'))

-- Direction/type consistency on ledgers
CHECK (
  (direction = 'IN' AND movement_type IN (...))
  OR (direction = 'OUT' AND movement_type IN (...))
)

-- FX snapshot mandatory for non-TRY
CHECK (currency = 'TRY' OR fx_snapshot_id IS NOT NULL)

-- No future-dating
CHECK (occurred_at <= now() + interval '1 minute')
```

---

## 14. Generated Columns

Used where denormalized computation is cheap and frequently read:

```sql
-- stock_balances
total_cost_try NUMERIC(15,4) GENERATED ALWAYS AS (quantity * average_cost_try) STORED

-- sale_items / return_items / pi_items
line_total NUMERIC(15,4) GENERATED ALWAYS AS (quantity * unit_price - line_discount) STORED

-- account_balances
net_balance NUMERIC(15,4) GENERATED ALWAYS AS (total_debit - total_credit) STORED

-- register_sessions
cash_variance NUMERIC(15,4) GENERATED ALWAYS AS (counted_cash - expected_cash) STORED

-- account_aging
total NUMERIC(15,4) GENERATED ALWAYS AS (current_amount + overdue_30_60 + overdue_60_90 + overdue_90_plus) STORED
```

`STORED` (not `VIRTUAL`) is used for indexability and predictable read performance.

---

## 15. Materialized Views Refresh Strategy

MVP: scheduled `REFRESH MATERIALIZED VIEW CONCURRENTLY` per view.

- `daily_sales_summary` — every 5 minutes
- `top_selling_variants` — every 30 minutes
- `stock_position_summary` — every 10 minutes (LOW status alerts time-critical)
- `customer_aging_summary` — nightly at 02:00
- `supplier_aging_summary` — nightly at 02:00

CONCURRENTLY requires UNIQUE INDEX (all views have one). Refresh is non-blocking for reads.

v1.1+ migration to event-driven incremental projection updates via outbox consumer (Reporting Projector — see [`event-consumers.md`](../architecture/event-consumers.md)).

---

## 16. Migration File Authoring Rules

- One concern per file. No mixing of contexts.
- Migrations are **idempotent** wherever possible (CREATE IF NOT EXISTS, INSERT ON CONFLICT DO NOTHING).
- Tables created in dependency order; FKs validated as the file runs.
- Triggers defined immediately after the table they protect.
- RLS policies defined in the same file as the table.
- Comments in SQL: `-- Phase 2X reference:` and `-- ADR XYZ reference:` where relevant, so the schema is self-documenting.
- CI runs every migration on an empty database and on a target-state copy, asserting no drift.

---

## 17. Sequence Hotspot Acknowledgement

Several allocators use UPDATE-based gap-free sequences:

- `document_sequences` (sale_number, return_number, invoice_number)
- `z_report_number_sequence` (regulatory gap-free Z reports)
- `outbox_global_sequences` (per-tenant outbox sequence)
- `stock_movement_sequences`, `account_movement_sequences` (aggregate_sequence per ledger)

These serialize concurrent transactions on a single row per scope. MVP performance acceptable for ~100 sales/min/store.

Roadmap v1.1+: high-throughput allocator strategies if contention is observed:

- Pre-allocated batches (gap risk acceptable for sale_number)
- Sharded allocators per register (number format includes register code)
- UUID-internal + lazy human-readable allocation

NOT acceptable for Z report numbers (regulatory). For those, hot-row contention remains the cost.

---

## 18. Forbidden Practices

The CI lint pipeline must reject:

- Any new table without `tenant_id` (unless explicitly system-wide lookup)
- Any new table without `created_at` and `updated_at` (unless append-only with `recorded_at`/`occurred_at`)
- Any new domain table without `ENABLE ROW LEVEL SECURITY` and a policy
- Any FK without an explicit `ON DELETE` clause
- Any `NOT NULL` + `ON DELETE SET NULL` contradiction (the bug Part 2 caught)
- Any monetary column without a `>= 0` CHECK
- Any `enum`-typed PostgreSQL enum (we prefer `VARCHAR + CHECK`; easier to extend)
- Any business logic inside a trigger (triggers are integrity-only)
- Any password hash, raw card number, or API key columns in domain tables
- Any append-only table without REVOKE UPDATE/DELETE + immutability trigger
