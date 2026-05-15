# Aggregates, Roots & Invariants

> **Status:** Locked (Phase 2B)
> **Last updated:** 2026-05-15

This document lists every aggregate, identifies the aggregate root, declares its critical invariants and notes who is authorised to write.

---

## Identity & Tenancy

### Tenant (Aggregate Root)
**Children:** TenantSettings, EnabledModules, SubscriptionPlan, BillingInfo.

**Invariants:**
- At least one super-admin user must exist (cannot be deleted).
- `industry` is set at creation; it may only **expand** (add additional industries), never replace.
- Trial expiry triggers automatic SUSPENDED.
- Hard deletion is **forbidden** (see ADR 007). Tenant data goes through `CHURNED → ARCHIVED (anonymised + cold storage)` and is only physically purged after 10 years (VUK-compliant).

**Owner / writer:** Tenant owner; Anthropic admin for status changes.

### User (Aggregate Root)
**Children:** UserProfile, UserStoreAccess[], UserRoleAssignment[].
**Not part of the aggregate (auth infrastructure):** `UserSession`, tokens, password hash, MFA — stored separately, may live in Redis or a dedicated auth schema.

**Invariants:**
- Must have at least one role.
- Must have access to at least one store.
- The last remaining super-admin user cannot be deactivated.
- DEACTIVATED users cannot authenticate but their historical references (sale.cashier_user_id, etc.) remain intact.

**Owner / writer:** Tenant admins (`users.create/suspend/deactivate`); user self-service for own profile fields.

### Role (Aggregate Root)
**Children:** RolePermissions[], RoleStoreScope.

**Invariants:**
- The 6 system roles (SUPER_ADMIN, STORE_MANAGER, CASHIER, STOCK_CLERK, ACCOUNTANT, AUDITOR) cannot be deleted or modified — only cloned.
- Custom roles can be soft-archived but never hard-deleted while assigned.
- Permission strings must match the `module.action` format.

**Owner / writer:** `roles.manage` permission holders.

### Store (Aggregate Root)
**Children:** StoreSettings, StoreAddress.

**Invariants:**
- Virtual `IN_TRANSIT` store is auto-created per tenant; cannot be deleted, archived or deactivated.
- A store with non-zero stock cannot be ARCHIVED.
- A store with an open `RegisterSession` cannot be deactivated.
- Each tenant must always have at least one active non-virtual store.

**Owner / writer:** `stores.*` permission holders.

---

## Catalog

### Product (Aggregate Root)
**Children:** ProductVariant[] (each with VariantAttributes[], VariantBarcodes[], VariantImages[]), ProductImages[], ProductMetadata (JSONB).

**Invariants:**
- ACTIVE product must have at least one ACTIVE variant.
- Variant SKU is auto-generated from `{model_code}-{color_short}-{size}` but may be overridden.
- Variant attribute combinations must be unique within a product (e.g. Black/M can exist only once).
- A variant with any historical stock movement cannot be hard-deleted; it can only be deactivated.
- Variant limits: soft 200, hard 500, configurable per tenant — enforced in application code, not DB CHECK.
- `inactive_sellable` flag controls whether INACTIVE products may still be sold by barcode (default false).

**Owner / writer:** Catalog editors (Store Manager, Super Admin).

### Category (Aggregate Root)
**Children:** ParentCategoryId (self-reference for hierarchy).

**Invariants:**
- Cyclic references forbidden.
- Maximum hierarchy depth: 5 levels (application-enforced).
- A category with active products cannot be deleted or disabled.
- Soft-archive only — terminology aligned with the rest of the system: `ARCHIVED`, never `DELETED`.

### PricingPolicy → PriceList (Aggregate Root)
**Children:** VariantPrice[] (append-only).

**Invariants:**
- For a given (variant_id, price_list_id, currency), only **one** active price interval at any moment.
- Enforced by PostgreSQL `EXCLUDE USING gist` constraint over `tstzrange(valid_from, valid_until)`.
- Price rows are never UPDATEd; a new row is inserted and the previous row's `valid_until` is set.
- `price >= 0` (zero allowed for promos).
- `valid_until > valid_from`.
- MVP: a single default price list `DEFAULT_RETAIL`; `is_default = true` only on one list system-wide per tenant.

**Owner / writer:** Catalog editors. Sales context **only reads via `PricingService.getEffectivePrice()`**, never direct SELECT.

---

## Inventory

### StockMovement (Aggregate Root, append-only)
**Children:** None (each movement is a stand-alone immutable record).

**Invariants:**
- **Append-only.** DB-level `REVOKE UPDATE, DELETE`. No business logic in triggers; triggers only enforce immutability and basic integrity.
- `quantity > 0` always; the `direction` field carries the sign.
- `movement_type`, `direction` and `reference_type` are mutually consistent (CHECK constraint).
- OUT movements check available stock under `SELECT ... FOR UPDATE` lock; insufficient stock raises `InsufficientStockException` unless caller has `stock.allow_negative` permission.
- IN movements require `unit_cost_try`; OUT movements snapshot the current WAC.
- `occurred_at` cannot be in the future.
- Reversal pattern: a wrong movement is corrected by inserting a **new** movement with `reverses_movement_id` pointing at the original. **Reversal of a reversal is forbidden**; create a new clean movement instead.
- The original record is never modified by the reversal.

**Owner / writer:** Only `InventoryService.recordMovement(...)`. Sales, Purchasing, Returns, Transfers, Counts and Adjustments all funnel through this single API.

### StockBalance (Projection, not an aggregate)
**Update strategy:** Maintained transactionally by `InventoryService.recordMovement()` (application service, not DB trigger). Defence in depth:

1. **Primary:** `InventoryService.recordMovement()` writes movement + balance in the same transaction under `SELECT ... FOR UPDATE`.
2. **Safety net:** Nightly reconciliation job compares balance vs. ledger sum.
3. **Recovery:** `rebuild_stock_balances(tenant_id, store_id)` admin command for disaster recovery.

### Transfer (Aggregate Root)
**Children:** TransferItem[], related_movement_ids[].

**Invariants:**
- `from_store_id != to_store_id`.
- Each item: `dispatched_quantity > 0`, `received_quantity <= dispatched_quantity`.
- DISPATCHED transfer cannot be cancelled (OUT movement exists; only reversal can undo it).
- RECEIVED transfer is sealed.
- Reason codes for missing/damaged goods are explicit: `LOST_IN_TRANSIT`, `DAMAGED_IN_TRANSIT`, `RECEIVED_SHORT`, `PROVIDER_ERROR`, `INTERNAL_PILFERAGE` (manager-only).

### CountSession (Aggregate Root)
**Children:** CountItem[], related_adjustment_movement_ids[].

**Invariants:**
- Only one `IN_PROGRESS` count session per store at a time (MVP).
- Variance with reason: `reason_code_id` required when `variance != 0`.
- COMPLETED session is sealed.
- **Variance formula** uses movements between snapshot and now, not raw difference:
  ```
  expected_at_count_time = snapshot_quantity
                        + movements_in_between (IN)
                        - movements_in_between (OUT)
  variance = counted_quantity - expected_at_count_time
  ```
- Computation runs under `REPEATABLE READ` isolation.

**Roadmap note (v2):** Zone/bin-scoped parallel counts for large warehouses.

### StockAdjustment (Aggregate Root)
**Invariants:**
- `reason_code_id` required.
- Quantity limit may be enforced per role (e.g. cashier max 5, manager unlimited).
- Single-shot: no DRAFT, goes directly to POSTED.

---

## Sales

### Sale (Aggregate Root)
**Children:** SaleItem[], SalePayment[], PaymentAttempt[], SaleDocument.

**Invariants:**
- `total = sum(items.line_total) - cart_discount`.
- `SaleItem.quantity > 0`; negative quantities live in the Return aggregate, never on Sale.
- COMPLETED status is permanent; administrative reversal is recorded as **operational flags** (`administratively_reversed_at`, `administratively_reversed_by_user_id`, `administrative_reversal_reason`), not a state change.
- `sale_item.unit_cost_try` is snapshotted at completion and is immutable thereafter.
- One **active** sale per `(store_id, register_id)` slot (not per cashier — supports vardiya devri).
- `idempotency_key` is mandatory on `Sale.complete()` (unique per tenant).
- When `terminal_pending = true`, the abandoned-cart cleanup job must not abandon the sale.

**Owner / writer:** Sales context (`SalesService.complete()` etc.).

### Return (Aggregate Root)
**Children:** ReturnItem[], ReturnRefundDetail.

**Invariants:**
- `RECEIPTED` mode requires `original_sale_id` referencing a COMPLETED sale; quantity per item ≤ (sold − previously returned).
- `BLIND` mode allowed only when tenant-level `allow_blind_return = true` and caller has `sales.return.blind.create`. Subject to anti-fraud guardrails (per-day amount, per-customer frequency, excluded categories, manager threshold).
- Cost snapshot rules:
  - RECEIPTED: copy `unit_cost_try` from the original `sale_item`.
  - BLIND: use current WAC; mark `blind_return_flag = true` for reporting.
- Refund total = sum of `cash_refund + card_reversal + customer_balance_credit + debt_reduction`.
- `idempotency_key` mandatory on `Return.complete()`.
- Operational reversal via flags, identical to Sale.

### Exchange (not an aggregate)
**Pattern:** Return + new Sale, linked by `exchange_group_id`. Executed as **two separate transactions** (Return commits first; Sale follows, drawing on customer balance). If Sale fails, Return stays committed and the customer is left with a credit — no harm done.

---

## Purchasing

### PurchaseInvoice (Aggregate Root)
**Children:** PurchaseInvoiceItem[], PurchaseInvoiceDocument.

**Invariants:**
- DRAFT → POSTED requires: `items.length > 0`, `total > 0`, `supplier_id` valid, `fx_snapshot_id` set if currency ≠ TRY.
- POSTED is sealed; administrative reversal via operational flags.
- Item cost stored in both original currency and TRY equivalent (FX snapshot).
- Supplier debt recorded in invoice currency, **not** auto-converted to TRY.
- `idempotency_key` mandatory on `post()`.
- Document upload is **pre-uploaded** before transaction; the transaction only stores the reference.

### PurchaseReturn (Aggregate Root)
**Children:** PurchaseReturnItem[].

**Invariants:**
- Cost snapshot taken from the **original purchase invoice item**, not current WAC.
- Stock OUT (`PURCHASE_RETURN_OUT`) + supplier DEBIT (we are owed).
- `idempotency_key` mandatory.

---

## Party

### Party (Aggregate Root)
**Children:** PartyContact[], PartyDocument[], PartyTag[] [v1.1], PartyMetadata (JSONB).

**Invariants:**
- `party_types[]` must contain at least one value.
- Same physical party may be both CUSTOMER and SUPPLIER (`party_types = ['CUSTOMER', 'SUPPLIER']`); financial data is segregated by role in `AccountProfile`.
- `tax_id`, when set, must pass format validation (TCKN for individuals, 10-digit VKN for companies).
- `credit_limit` and `payment_terms_days` are **NOT** on Party (moved to `AccountProfile` in Financial context).
- BLOCKED parties cannot be selected in new transactions; historical references preserved.

---

## Financial

### AccountProfile (Aggregate Root)
**Children:** None directly; `account_movements` are journal entries owned by other aggregates' transactions.

**Invariants:**
- `UNIQUE(tenant_id, party_id, party_role, currency)`.
- Status transitions (`NORMAL → WATCH → BLOCKED → CLOSED`) require reason; audited.
- BLOCKED: new DEBITs forbidden; CREDITs (payments received) allowed.
- CLOSED: no new entries at all.
- `credit_limit` enforced at Sale completion; manager override allowed but audited (`CreditLimitExceeded` event).

### Payment (Aggregate Root)
**Children:** PaymentAllocation[], PaymentReversalInfo.

**Invariants:**
- `amount > 0`.
- `sum(allocations.allocated_amount) <= payment.amount`.
- At least one allocation.
- CASH payments require an open `RegisterSession`.
- Reversals: a single FULL reversal OR multiple PARTIAL reversals whose total ≤ `original.amount`.
- `idempotency_key` mandatory.
- FAILED is **terminal**. Retry creates a new payment with a new idempotency key.
- Reversal of reversal forbidden.

### AccountMovement (Entity, **not an aggregate root**)
**Table:** `account_movements` (append-only financial ledger; operational ERP terminology rather than formal accounting journal terminology).

**Invariants:**
- Append-only — no UPDATE, no DELETE.
- `amount > 0`; `direction` carries the sign.
- `direction` and `movement_type` consistent (CHECK constraint).
- Currency matches the owning `AccountProfile.currency`.
- BLOCKED profile: new DEBIT forbidden (except reversal).
- CLOSED profile: no new entries.
- Reversal pattern via `reverses_movement_id`; reversal of reversal forbidden.

**Owner / writer:** Always a side effect of a containing aggregate transaction (Payment.complete(), Sale.complete(), PurchaseInvoice.post(), Return.complete(), or admin tools). Never written stand-alone.

### Naming note
The table name `account_movements` follows operational ERP terminology rather than formal accounting journal terminology. DDD purists might call this a "ledger entry" or "journal entry"; this name aligns with the ubiquitous language used by store operators and Turkish accountants.

---

## Cash Register

### CashRegister (Aggregate Root)
**Invariants:**
- One active OPEN session at a time.
- Cannot be deactivated while a session is open.
- ARCHIVED is one-way.

### RegisterSession (Aggregate Root)
**Children:** CashMovement[], ZReport (1-to-1).

**Invariants:**
- `OPEN → CLOSING → CLOSED` is one-directional in normal flow.
- During CLOSING: new sales forbidden; existing AWAITING_PAYMENT sales may complete; grace period 10 minutes; after that, force-finalise (open sales → ABANDONED, except `terminal_pending`).
- CLOSED is sealed.
- `expected_cash = opening_float + cash_in − cash_out − refunds + sales_cash`.
- Variance ≠ 0 requires explicit acceptance (permission `register.close.accept_variance`).
- Z report number is allocated **only on successful commit** (no sequence gaps).
- Number format: `Z-{TENANT_PREFIX}-{YEAR}-{STORE_CODE}-{SEQUENCE:6}`.
- `CLOSED → OPEN` re-open: feature-flag-gated, super-admin only, co-signature required, no subsequent session may exist, mandatory reason ≥ 100 chars, audit ticket required.

---

## FX

### Currency (Aggregate Root)
**Invariants:**
- TRY always ACTIVE.
- INACTIVE means "not usable for new operations"; historical records remain accessible.
- Currency is never deleted, only toggled.

### FxRateSource (Aggregate Root)
**Invariants:**
- `MANUAL` source is always active and cannot be removed.
- Active sources are eligible for selection as `tenant.preferred_fx_source`.

### FxRate (Aggregate Root, append-only)
**Invariants:**
- INSERT-only.
- Each row is a `(currency, source, effective_at_utc)` triple with `buy_rate` and `sell_rate`.
- All timestamps stored as UTC.
- **Roadmap (v1.1):** monthly partitioning by `effective_at_utc` and retention policy (hot 90 days, warm to 2 years, cold archive thereafter).

### FxSnapshot (Aggregate Root, append-only)
**Invariants:**
- Immutable; `REVOKE UPDATE, DELETE`.
- `effective_at_utc` required.
- `source_version` required (records the provider implementation version).
- `tenant_timezone` snapshotted for display correctness.
- JSONB `rates` carries a `schema_version` for forward-compatible parsing.
- Never deleted — referenced by Sales and PurchaseInvoice rows.
