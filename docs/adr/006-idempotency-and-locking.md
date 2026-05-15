# ADR 006 — Idempotency Keys and Pessimistic Locking

> **Status:** Accepted
> **Date:** 2026-05-15

## Context

Two failure modes can corrupt financial and inventory state if not actively prevented:

1. **Duplicate operations** — network retries, double-tap on "Complete", terminal callback duplicates, POS crash and restart. Without idempotency, the same sale could be committed twice; the customer is charged twice.
2. **Concurrent conflicts** — two POS terminals selling the last unit of stock at the same instant; two payments allocating to the same outstanding movement; close-day racing with an in-flight sale. Without pessimistic locking, lost updates and inconsistent balances are inevitable.

Both must be prevented; neither can be patched later cheaply once the data is corrupt.

## Decision

### Idempotency keys

Every state-changing operation that has financial or inventory impact carries an `idempotency_key` (VARCHAR(64), unique per tenant). Mandatory on:

- `Sale.complete()`
- `Return.complete()`
- `Payment.complete()` (and reversals create new payments with new keys)
- `PurchaseInvoice.post()`
- `PurchaseReturn.post()`
- `Transfer.dispatch()` and `Transfer.receive()` (separate keys)
- `RegisterSession.close()`
- `CountSession.complete()`
- `StockAdjustment.create()`

#### Client behaviour
- Generates the key when the user initiates the action. Composition: `register_id + cashier_id + entity_id + timestamp + crypto_nonce`.
- Persists the key locally before the request leaves the client.
- On retry due to timeout, network error or app restart, sends **the same key**.

#### Server behaviour
- Looks up `(tenant_id, idempotency_key)` before processing.
- If found, returns the cached result. The operation is not re-executed.
- If not found, processes normally; the idempotency key is stored inside the same atomic transaction as the operation.

#### Lifecycle of a key
- Retention: 24 hours. A nightly job sets old `idempotency_key` to NULL on referenced entities (entity rows remain).
- Reuse: after the 24-hour window, a key may be reused for a different operation; in practice this is moot because keys carry random nonces.

#### Idempotency in consumers (outbox)
- Every consumer / projector also maintains its own `processed_events` row per `(consumer_name, event_id)` for replay safety (see ADR 004).

### Pessimistic locking

The standard pattern for the hot path: `BEGIN; SELECT ... FOR UPDATE on the rows we touch; do writes; COMMIT`.

| Operation | Rows locked |
|---|---|
| Sale.complete() | Sale, every affected StockBalance (per item, sorted), AccountProfile (if partial pay), RegisterSession |
| Return.complete() | Return, every affected StockBalance, AccountProfile (refund), RegisterSession |
| Payment.complete() | Payment, AccountProfile, AccountBalance, RegisterSession (if cash) |
| Payment.reverse() | Original Payment, reversal Payment (just inserted), AccountProfile, AccountBalance, RegisterSession |
| Transfer.dispatch() | Transfer, source StockBalance(s), virtual in-transit StockBalance(s) |
| Transfer.receive() | Transfer, virtual in-transit StockBalance(s), destination StockBalance(s) |
| PurchaseInvoice.post() | Invoice, StockBalance(s), supplier AccountProfile |
| CountSession.complete() | Session, every CountItem's StockBalance |
| RegisterSession.close() | Session, register, Z-report sequence row |

### Lock acquisition order (deadlock prevention)

A canonical order applies across all services:

1. The "top" aggregate row (Sale / Return / Payment / Transfer / Invoice / Session).
2. RegisterSession row (if applicable).
3. AccountProfile rows, sorted by `(party_id, role, currency)`.
4. StockBalance rows, sorted by `(variant_id, store_id)`.
5. Z-report sequence row (close only).

Within steps 3 and 4, deterministic sort prevents cross-transaction lock-order inversion.

### Isolation level

| Operation | Isolation |
|---|---|
| Hot-path POS operations | READ COMMITTED |
| `CountSession.complete()` | REPEATABLE READ (consistent view across variance computations) |
| Nightly reconciliation | REPEATABLE READ |
| Read-only reporting | READ COMMITTED |

### Conflict handling

- `SerializationFailure` → retry with exponential backoff, max 3 attempts.
- `DeadlockDetected` → retry with exponential backoff, max 3 attempts.
- After max retries → surface a clear error to the user.
- Insufficient stock / blocked party / credit limit → rollback, surface domain error; manager override may allow a retry with a flag.

## Rationale

- **Idempotency is non-negotiable** for retail. A duplicate sale is a customer-trust event with regulatory implications.
- **Pessimistic locking + READ COMMITTED** is the right default for our pattern: we know exactly which rows we touch; we hold them only for the milliseconds of the transaction; we avoid serialisation failure thrash.
- **REPEATABLE READ for count completion** prevents subtle bugs where a movement during variance computation flips the result.
- **Canonical lock order** prevents deadlocks that would otherwise appear under concurrent POS load.

## Consequences

**Positive:**
- No duplicate sales / payments / refunds, even under network retries.
- No lost stock updates under contention.
- Predictable performance: locks are held briefly, only on the rows in play.
- Clear failure semantics: a conflicting operation surfaces a domain error, not a corruption.

**Negative:**
- Slight latency in highly contended scenarios (two cashiers fighting over the last unit). Acceptable — the user sees a clear error.
- Implementation discipline: every service must use the canonical lock order. Mitigated by code review and integration tests that exercise concurrent scenarios.

## Alternatives Considered

- **Optimistic concurrency control** — rejected for the hot path. The contention shape (StockBalance, AccountProfile, RegisterSession) does not favour optimistic; retries would be common.
- **SERIALIZABLE isolation everywhere** — rejected. Higher serialisation-failure rate; retry overhead beats the lock-based approach for our workload.
- **No idempotency keys, rely on duplicate-detection heuristics** — rejected. Fragile and unsuitable for money.
