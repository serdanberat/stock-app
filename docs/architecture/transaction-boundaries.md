# Transaction Boundaries

> **Status:** Locked
> **Last updated:** 2026-05-15

This document declares which operations are atomic, which are eventually consistent, and what isolation/locking strategy applies.

---

## Atomicity Policy Per Operation

| Operation | Atomicity | Notes |
|---|---|---|
| **Sale completion** | **Atomic** | Sale + items + stock + cash + account + payments + document stub + outbox event — one transaction |
| **Return completion** | **Atomic** | Return + items + stock IN + cash/card/account + document stub + outbox event |
| **Exchange** | **Two separate transactions** | Return commits first; Sale follows. Linked by `exchange_group_id`. Recovery-friendly: if Sale fails, customer holds a credit |
| **Purchase invoice post** | **Atomic** | Invoice + items + stock IN + supplier debt + FX snapshot + document stub + outbox |
| **Purchase return post** | **Atomic** | Same pattern, opposite direction |
| **Transfer dispatch** | **Atomic** | Status + OUT (source) + IN (virtual in-transit) + outbox |
| **Transfer receive** | **Atomic** | Status + OUT (virtual in-transit) + IN (dest) + optional negative adjustment + outbox |
| **Count session complete** | **Atomic** | Status + all variance adjustment movements + outbox |
| **Stock adjustment** | **Atomic** | Movement + balance update + outbox |
| **Payment completion** | **Atomic** | Payment + allocations + account movement + cash movement (if CASH) + outbox |
| **Payment reversal (full or partial)** | **Atomic** | New reversal payment + reversal entries + original status update + balance recompute + outbox |
| **Register session close** | **Atomic** | Variance movement (if any) + Z report stub + status update + outbox |
| **Administrative sale/return reversal** | **Atomic** | Compensating movements + operational flags + outbox |
| **Reporting / dashboard updates** | **Eventually consistent** | Outbox-driven projector |
| **Audit log** | **Eventually consistent** | Outbox-driven, at-least-once |
| **PDF generation, e-document, printer, email/SMS** | **Eventually consistent** | Async workers after commit |

---

## Isolation Levels

| Operation | Isolation level | Locking |
|---|---|---|
| `Sale.complete()` | READ COMMITTED | `SELECT ... FOR UPDATE` on sale, stock balances, account profile, register session |
| `Payment.complete()` | READ COMMITTED | `SELECT ... FOR UPDATE` on payment, account profile, account balance, register session |
| `Return.complete()` | READ COMMITTED | `SELECT ... FOR UPDATE` on return, stock balances, account profile, register session |
| `Transfer.dispatch()` / `Transfer.receive()` | READ COMMITTED | `SELECT ... FOR UPDATE` on transfer, source/dest stock balances |
| `PurchaseInvoice.post()` | READ COMMITTED | `SELECT ... FOR UPDATE` on stock balances, supplier account profile |
| `CountSession.complete()` | **REPEATABLE READ** | + row locks on balances. REPEATABLE READ guarantees a consistent view across all variance computations |
| `RegisterSession.close()` | READ COMMITTED | `SELECT ... FOR UPDATE` on session, Z-report sequence row, register |
| Reporting / read queries | READ COMMITTED | None |
| Nightly reconciliation | REPEATABLE READ | None |

### Choice rationale
- **READ COMMITTED + pessimistic row locks** is PostgreSQL's default and works well for our patterns: lock the rows we care about explicitly, avoid serialisation failures, predictable behaviour.
- **REPEATABLE READ for CountSession** prevents phantom reads during the variance-formula computation, which scans `stock_movements` between snapshot and now and must be consistent.

### Failure handling
- `SerializationFailure` → retry with exponential backoff (3 attempts).
- `DeadlockDetected` → retry with backoff. Lock acquisition order is documented and consistent across services to minimise deadlocks.
- `InsufficientStockException` / `CreditLimitExceeded` / `BlockedPartyException` → rollback, bubble up to caller; manager override may allow retry with an override flag.

---

## Lock Acquisition Order (Deadlock Prevention)

A canonical order is enforced so concurrent transactions cannot deadlock:

1. Sale or Return (or PurchaseInvoice) row
2. RegisterSession row (if applicable)
3. AccountProfile rows (sorted by `(party_id, role, currency)`)
4. StockBalance rows (sorted by `(variant_id, store_id)`)
5. Z-report sequence row (close only)

Within step 3 and step 4, sort by the natural key to ensure deterministic ordering across all callers.

---

## Outbox Pattern (See ADR 004 for full detail)

**Rule:** Every cross-context or domain event must be written into `outbox_events` **inside the same transaction** as the domain change.

```
TRANSACTION BEGIN
  ... domain inserts/updates ...
  INSERT INTO outbox_events (event_type, aggregate_type, aggregate_id, payload, ...)
COMMIT
```

A background publisher worker reads pending rows, publishes to the event bus, marks as PUBLISHED. Retries with exponential backoff; after 5 failed attempts the row goes to a dead-letter status for manual review.

Guarantees: no lost events, at-least-once delivery, replay capability. Consumers must be idempotent (see `cross-cutting-rules.md`).

---

## What Happens If Async Steps Fail After Commit

After the atomic transaction commits, the domain change is durable. Subsequent async work can fail without invalidating the commit:

| Async step | Failure handling |
|---|---|
| PDF generation | Worker retries 3×; on persistent failure, mark `sale_documents.status = FAILED` and alert; user can re-trigger from UI |
| Receipt printer | Print queue retries; manual reprint available |
| e-Document submission | Provider retry policy; failed submissions go to manual review queue |
| Reporting projection | Idempotent projector replays from outbox |
| Notification (SMS/email) | Retried, falls back to in-app notification |
| Audit consumer | Idempotency-keyed, replays if missed |

The user-visible result (the sale) is never undone because an async step failed.

---

## What Is NOT Atomic With the Domain Transaction

- File uploads to S3 (must be pre-uploaded; transaction stores only the reference).
- External payment gateway calls (terminal_pending pattern; callback completes the sale).
- e-Document provider submissions.
- Email/SMS dispatch.
- Materialised view refresh.
- Audit log writes (outbox-driven).
- Notification fan-out.
