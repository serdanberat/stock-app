# Isolation Levels

> **Status:** Locked (Phase 6.B)
> **Related ADRs:** ADR-006

PostgreSQL transaction isolation level by operation.

## Default

`READ COMMITTED` for all `@Transactional` methods unless explicitly elevated.

This is PostgreSQL's default. It is sufficient for the vast majority of operations.

## SERIALIZABLE — narrow whitelist

`SERIALIZABLE` is expensive (transactions serialize, throughput collapses). It is permitted **only** for gap-free sequence allocators:

| Operation | Why SERIALIZABLE |
|---|---|
| `document_sequences` UPDATE (sale_number, return_number, invoice_number) | Gap-free regulatory requirement |
| `z_report_number_sequence` UPDATE | Gap-free regulatory requirement (tax authority compliance) |
| `outbox_global_sequences` UPDATE | Strict ordering for replay determinism |
| `stock_movement_sequences` UPDATE | Per-aggregate sequence integrity |
| `account_movement_sequences` UPDATE | Per-aggregate sequence integrity |

Implementation pattern:

```java
@Transactional(isolation = Isolation.SERIALIZABLE)
public Long allocateSaleNumber(UUID tenantId, UUID storeId, int year) {
    // INSERT ... ON CONFLICT DO NOTHING
    // UPDATE ... SET last_number = last_number + 1 RETURNING last_number
}
```

These are very short transactions (one INSERT + one UPDATE), so the throughput cost is bounded.

## Forbidden: SERIALIZABLE in hot paths

```java
// ❌ DO NOT:
@Transactional(isolation = Isolation.SERIALIZABLE)
public void completeSale(...) { ... }
```

`Sale.complete()` involves stock balance reads, account movement writes, multiple subordinate calls. Under SERIALIZABLE, two concurrent sales for **unrelated** variants will serialize, killing POS throughput.

The correct pattern for hot path:

```java
@Transactional(isolation = Isolation.READ_COMMITTED)
public void completeSale(...) {
    // Pessimistic row-level lock on the actual contended row:
    var balance = stockBalanceRepo.findByVariantAndStoreForUpdate(variantId, storeId);
    if (balance.quantity() < requestedQty) {
        throw new InsufficientStockException(...);
    }
    balance.decrement(requestedQty);
    // ...
}
```

`SELECT FOR UPDATE` locks only the specific `(variant, store)` row. Two concurrent sales of different variants do not contend. Two concurrent sales of the same variant correctly serialize at the row level.

## Operation matrix

| Operation | Isolation | Locking |
|---|---|---|
| Sale.complete | READ COMMITTED | `SELECT FOR UPDATE` on `stock_balances`, on `cash_register_sessions` |
| Return.complete | READ COMMITTED | `SELECT FOR UPDATE` on `stock_balances` |
| PurchaseInvoice.post | READ COMMITTED | `SELECT FOR UPDATE` on `stock_balances` |
| Payment.complete | READ COMMITTED | `SELECT FOR UPDATE` on `account_profiles.credit_used`, `account_balances` |
| Payment.reverse | READ COMMITTED | `SELECT FOR UPDATE` on `payment_allocations`, `account_balances` |
| Transfer.dispatch | READ COMMITTED | `SELECT FOR UPDATE` on source `stock_balances` |
| Transfer.receive | READ COMMITTED | `SELECT FOR UPDATE` on destination `stock_balances` |
| RegisterSession.open | READ COMMITTED | Unique partial index enforces single open session |
| RegisterSession.close | READ COMMITTED | `SELECT FOR UPDATE` on `register_sessions.id` |
| ZReport allocation | **SERIALIZABLE** | `z_report_number_sequence` UPDATE |
| Sale number allocation | **SERIALIZABLE** | `document_sequences` UPDATE |
| Outbox INSERT | READ COMMITTED | None (append) |
| Outbox global_sequence | **SERIALIZABLE** | `outbox_global_sequences` UPDATE |
| Stock movement INSERT | READ COMMITTED | None (append) |
| Stock movement aggregate_sequence | **SERIALIZABLE** | `stock_movement_sequences` UPDATE |
| Account movement INSERT | READ COMMITTED | None (append) |
| Account movement aggregate_sequence | **SERIALIZABLE** | `account_movement_sequences` UPDATE |
| MView refresh | READ COMMITTED | None |
| Reporting queries | READ COMMITTED (or REPEATABLE READ for consistency) | None |
| Cleanup jobs (delete expired) | READ COMMITTED | None |

## Locking semantics

Two distinct locking patterns are used:

### Pessimistic row lock (`SELECT FOR UPDATE`)

```java
// JPA
@Lock(LockModeType.PESSIMISTIC_WRITE)
@Query("SELECT b FROM StockBalance b WHERE b.variantId = :v AND b.storeId = :s")
Optional<StockBalance> findForUpdate(@Param("v") UUID v, @Param("s") UUID s);
```

Other transactions reading the same row block until this one commits. Used in hot paths (POS sale completion).

### Advisory lock (`pg_advisory_xact_lock`)

For coarser-grained coordination (e.g. "only one CountSession may run per store at a time"). Schema also uses partial unique indexes for this.

### Optimistic locking (`@Version`)

Used on aggregate roots where conflict is rare and rollback acceptable:

```java
@Entity
public class Sale {
    @Version
    private long version;
    // ...
}
```

On conflict, JPA throws `OptimisticLockException`; the application retries.

## Application discipline

Default isolation is set via `@Transactional` defaults. The application configuration:

```yaml
spring:
  jpa:
    properties:
      hibernate:
        connection:
          isolation: 2  # READ_COMMITTED
```

Explicit elevation requires `@Transactional(isolation = Isolation.SERIALIZABLE)` and is reserved for the sequence allocator services. Code review must reject any other use.

## Why not REPEATABLE READ globally?

`REPEATABLE READ` (PostgreSQL's snapshot isolation) is appealing for consistency, but:

- Heavier than READ COMMITTED (snapshot retention)
- Long transactions may abort with serialization failures
- Most application logic doesn't need snapshot semantics

Use REPEATABLE READ for specific reporting queries when needed:

```java
@Transactional(isolation = Isolation.REPEATABLE_READ, readOnly = true)
public DailyReport generateDailyReport(LocalDate date) { ... }
```

Pattern: opt in at the reporting service layer, not as a default.
