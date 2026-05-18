# ADR-017: External I/O Outside Database Transactions

**Status:** Accepted
**Date:** 2026-05-16
**Phase:** 6.F

## Context

Background workers call external systems: Gotenberg for PDF generation, object storage for upload, email SMTP, webhooks, FX provider APIs. The natural Spring Boot pattern is:

```java
@Transactional
public void processDocument(UUID docId) {
    markGenerating(docId);
    var pdf = gotenberg.render(html);     // external HTTP call
    var path = storage.upload(pdf);       // external storage call
    markReady(docId, path);
}
```

This pattern is **wrong** under load. The DB transaction holds a connection from HikariCP for the entire duration of the external calls. If Gotenberg takes 30 seconds (Chromium GC, network glitch, large document):

- Connection unavailable for 30 seconds
- POS requests queue, hit `connection-timeout: 30000ms`, fail
- Connection pool exhausts → application freezes
- RLS context (`SET LOCAL app.tenant_id`) held throughout
- PostgreSQL logs `idle in transaction` warnings, autovacuum stalls
- JVM crash mid-process leaves row in `GENERATING` state, retry confusion follows
- Network retry on same idempotency window may write the PDF twice (one orphaned)

## Decision

Worker patterns follow a strict three-phase template:

```
TX1 (claim)        Pure DB. Mark row IN_PROGRESS / GENERATING.
                   Use FOR UPDATE SKIP LOCKED + UPDATE ... RETURNING.
                   Allocate attempt counter.
                   Commit fast. Connection released.

External work      No transaction. HTTP, storage, email, etc.
                   May take seconds or minutes. Pool unaffected.

TX2 (finalize)     Pure DB. Mark row READY / FAILED / RETRY_SCHEDULED.
                   Emit outbox event in same TX (atomic with state change).
                   Commit fast. Connection released.
```

### Bean structure

To prevent Spring AOP self-invocation pitfalls (calling `@Transactional` from same bean bypasses proxy), workers split into three beans:

```
*ClaimService     → @Transactional method, TX1
*Generator        → No @Transactional, external I/O
*Finalizer        → @Transactional methods, TX2 (markReady, scheduleRetry, markFailed)
*Worker           → @Scheduled + @SchedulerLock, orchestrates the three
```

Reference implementations: `SaleDocumentWorker`, `ReturnDocumentWorker`, `PurchaseInvoiceDocumentWorker`, `ZReportWorker`.

### Outbox dispatcher special case

Outbox dispatcher distinguishes two consumer types:

| Consumer type | Side effect | Transaction |
|---|---|---|
| **Internal** | DB-only (projection update) | Run inside TX |
| **External** | HTTP/email/webhook | Run outside TX, post-success DB update |

Consumer interface declares its type:

```java
public interface EventConsumer<T> {
    String name();
    Class<T> eventType();
    boolean isInternal();
    void handle(T event, EventMetadata metadata);
}
```

Internal example: `DailySalesSummaryProjector` — pure SQL UPDATE.
External example: `EmailNotificationConsumer` — calls SMTP.

The dispatcher routes:

```java
if (consumer.isInternal()) {
    internalDispatcher.dispatch(consumer, event);   // TX-wrapped
} else {
    externalDispatcher.dispatch(consumer, event);   // No TX wrap
}
```

### Idempotency consequence

The external phase has no transactional guarantees. If JVM crashes between external success and TX2, the next worker run will re-execute. Therefore:

- External consumers must be idempotent. Webhooks include `event_id` for dedup.
- Storage uploads use deterministic paths (`{type}/{tenant}/{year}/{month}/{doc_id}.pdf`) so re-upload overwrites the same key.
- Database-marked `attempt_count` increments on every claim, giving observability of retries.

### At-least-once semantics

Exactly-once delivery is not provided. Consumers must tolerate duplicates. This is standard for distributed systems and reflects reality more than the alternative (lost messages).

## Enforcement

ArchUnit rule:

```java
@ArchTest
static final ArchRule transactional_methods_no_external_clients =
    methods().that().areAnnotatedWith(Transactional.class)
        .should().notBeDeclaredInClassesThat()
            .dependOnClassesThat().resideInAnyPackage(
                "..integrations.gotenberg..",
                "..integrations.storage.s3..",
                "..integrations.email..",
                "..integrations.webhook..",
                "..integrations.fxprovider.."
            );
```

This catches the common mistake of `@Transactional` on a class that injects an HTTP client. False negatives are possible (the dependency may not be invoked in the method), so code review remains the second line.

## Consequences

**Positive:**
- HikariCP stays healthy under external latency
- DB transactions remain short
- Failure modes well-defined and recoverable
- Multi-instance scaling natural (ShedLock + SKIP LOCKED handles concurrency)
- Performance scales linearly with worker count, not blocked by external latency

**Negative:**
- More beans per worker (3 vs 1)
- Stuck-in-GENERATING rows possible on JVM crash mid-process; mitigated by stuck-job detector (every 15 min, resets rows stuck > 10 min)
- Developers must internalize the pattern (counterintuitive at first)

## Cross-references

- Worker patterns: `docs/architecture/worker-patterns.md`
- Consumer categories: `docs/architecture/event-consumer-categories.md`
- Stuck job detection: `docs/tech-stack/6f-jobs-documents.md`
