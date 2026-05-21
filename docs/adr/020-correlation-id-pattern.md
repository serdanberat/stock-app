# ADR-020 — Correlation ID Pattern for Cross-Aggregate Event Tracing

> **Status:** Accepted
> **Date:** 2026-05-21
> **Phase:** 3.C (locked during inventory design)

## Context

The system has many flows that span multiple aggregates and produce multiple events/movements within a single logical operation:

- **Sale completion**: Sale aggregate transitions → Cash movement + Stock movements (1-N) + Receipt document
- **Stock transfer**: Transfer aggregate → TRANSFER_OUT at source + TRANSFER_IN at target + possible ADJUSTMENT_OUT for discrepancy
- **Return + exchange**: Return aggregate → RETURN_IN stock movements + new SALE aggregate (exchange portion) + SALE_OUT movements + refund payment
- **Stock count session finalization**: CountSession → COUNT_CORRECTION movements (1-N)
- **Stock adjustment session**: Adjustment → ADJUSTMENT_IN/OUT movements (1-N)
- **Purchase invoice commit**: PurchaseInvoice → PURCHASE_IN movements + WAC updates + supplier debt account_movement
- **Cash register close**: CashRegisterSession → cash_movement CORRECTION + cash_movement CLOSING_DEPOSIT + Z report generation

Without a unifying identifier, reconstructing "what happened together" requires expensive multi-table joins:
- "Show all movements from transfer #T-2056"
- "Show full timeline of the exchange that happened at 14:32"
- "Reconcile the cash variance back to all sales in that session"
- "Audit: which sale created this RETURN_IN movement?"

Two patterns were considered:

1. **Foreign keys for each origin**: stock_movements.sale_id, stock_movements.transfer_id, stock_movements.return_id, ... — explosive column growth; mutually exclusive nullable FKs are awkward.

2. **Generic correlation_id**: single UUID column, shared across all rows produced from the same logical operation. Lightweight, query-friendly.

## Decision

Adopt a **correlation_id** pattern across all event-emitting aggregates and append-only ledgers.

### Rules

**Rule 1**: Every domain operation that produces ≥2 outputs (movements, events, account changes, documents) generates one `correlation_id` (UUIDv4) at the aggregate-method level.

**Rule 2**: All outputs from that operation carry the same `correlation_id`:
- `stock_movements.correlation_id`
- `cash_movements.correlation_id`
- `account_movements.correlation_id`
- `audit_event_log.correlation_id`
- `payment_attempts.correlation_id`
- Z report payload includes correlation references for source movements

**Rule 3**: The `correlation_id` is the originating aggregate's ID when natural:
- Transfer → `correlation_id = transfer.id` (UUID)
- Sale completion → `correlation_id = sale.id`
- Return → `correlation_id = return.id`
- Adjustment session → `correlation_id = adjustment.id`
- Count session finalize → `correlation_id = count_session.id`
- Purchase invoice commit → `correlation_id = purchase_invoice.id`
- Cash session close → `correlation_id = cash_register_session.id`

**Rule 4**: For exchange flows, both the original Return and the new exchange Sale share the same `correlation_id` (the Return's id), since they are logically one operation.

**Rule 5**: For chained operations across aggregate boundaries, correlation_id propagates with the originating intent. Example: when a Return creates a new Sale (exchange), the Sale's `correlation_id` is the Return's `id`, NOT a new id.

**Rule 6**: Idempotency keys (`X-Idempotency-Key` header) are SEPARATE from correlation_id. Idempotency key is request-scoped (deduplication of API calls); correlation_id is domain-scoped (logical operation linkage). Both columns exist; idempotency_keys row references its correlation_id for cross-reference.

### Indexing

All ledger tables (`stock_movements`, `cash_movements`, `account_movements`, `audit_event_log`) include:
```sql
CREATE INDEX idx_<table>_correlation_id ON <table>(tenant_id, correlation_id);
```

Composite with `tenant_id` first per Phase 1 multi-tenant pattern.

### UI / API surface

- Movement detail panels show correlation_id with "drill-down" affordance
- Audit log browser exposes correlation_id as primary filter
- Correlation timeline view in Audit Log Browser (3.E.6) renders chronological events sharing same correlation_id

## Consequences

### Positive

- **Single-query timeline** for any logical operation
- **Audit traceability** without complex joins
- **Debugging support** when a movement looks orphaned
- **Reconciliation** between source/target in transfers, and between sale/refund/exchange in returns
- **Future event sourcing**: correlation_id already aligned with event causation

### Negative

- One UUID column added to ~6 ledger tables (~16 bytes per row × event volume)
- Application code must remember to propagate correlation_id through service boundaries — enforced via aggregate method signatures (`commit(correlationId)` etc.)
- Migrating existing rows: backfill is `correlation_id = self.id` for single-row legacy data (no information loss; backfill safe)

### Neutral

- Correlation_id is NOT a security boundary. tenant_id is. Correlation_id MUST always be queried alongside tenant_id.

## Anti-patterns this rules out

- Per-aggregate foreign keys on ledger tables (sale_id, transfer_id, return_id, ...)
- Reconstructing logical operations via timestamp proximity (fragile)
- Storing operation context in audit_event_log payload JSON only (not queryable efficiently)

## Implementation notes

- Java side: `CorrelationIdHolder` ThreadLocal at aggregate command entry; propagated through outbox event payload
- All outbox events carry `correlationId` in their payload metadata
- DB-level CHECK constraints not required (UUID type sufficient validation)
- Backfill migration handled in 020_inventory_extensions for existing stock_movements

## Related

- ADR-001 Multi-tenancy pattern (tenant_id always paired)
- ADR-006 Outbox pattern (events carry correlation_id)
- ADR-019 Display name composition (Java-side composition pattern; audit summary follows same)
- Phase 3.C.2 Movement History (correlation_id filter + drill-down)
- Phase 3.E.6 Audit Log Browser (correlation_id timeline view)
