# Worker Patterns: TX1 / External / TX2

> **Status:** Locked (Phase 6.F)
> **Related ADRs:** ADR-017

Canonical pattern for background workers that combine database operations with external I/O.

## The problem

A naïve worker wraps everything in one transaction:

```java
@Transactional   // ❌ Wrong
public void processDocument(UUID docId) {
    markGenerating(docId);          // DB
    var pdf = gotenberg.render(...); // External HTTP — may take 30s
    var path = storage.upload(pdf);  // External storage — may take 10s
    markReady(docId, path);          // DB
}
```

Holding a HikariCP connection for 40 seconds breaks the connection pool under load. See ADR-017 for full failure analysis.

## The pattern

Three phases, three separate beans:

```
┌─────────────────────────────────────────────┐
│ Phase 1 — TX1 (claim)                       │
│ Pure DB. Mark row IN_PROGRESS.              │
│ Allocate attempt counter.                   │
│ Commit fast. Connection released.           │
└──────────────────┬──────────────────────────┘
                   │
                   ▼
┌─────────────────────────────────────────────┐
│ Phase 2 — External work                     │
│ NO transaction. HTTP, storage, email, etc.  │
│ Variable duration. Pool unaffected.         │
└──────────────────┬──────────────────────────┘
                   │
                   ▼
┌─────────────────────────────────────────────┐
│ Phase 3 — TX2 (finalize)                    │
│ Pure DB. Mark row READY / FAILED.           │
│ Emit outbox event in same TX.               │
│ Commit fast. Connection released.           │
└─────────────────────────────────────────────┘
```

## Reference implementation

```java
@Component
public class SaleDocumentWorker {

    private final SaleDocumentClaimService claim;
    private final SaleDocumentGenerator generator;
    private final SaleDocumentFinalizer finalizer;

    @Scheduled(fixedDelay = 5_000)
    @SchedulerLock(name = "sale-document-worker", lockAtMostFor = "2m")
    public void processBatch() {
        var claimedIds = claim.claimBatch(20);  // TX1

        for (var id : claimedIds) {
            try {
                var artifact = generator.generate(id);     // External I/O
                finalizer.markReady(id, artifact.path());  // TX2
            } catch (TransientException e) {
                finalizer.scheduleRetry(id, e);            // TX2
            } catch (PermanentException e) {
                finalizer.markFailed(id, e);               // TX2
            } catch (Exception e) {
                log.error("Unexpected error processing document {}", id, e);
                finalizer.scheduleRetry(id, new TransientException("Unexpected", e));
            }
        }
    }
}
```

### Phase 1: Claim service

```java
@Component
public class SaleDocumentClaimService {

    private final DSLContext jooq;

    @Transactional
    public List<UUID> claimBatch(int limit) {
        return jooq.update(SALE_DOCUMENTS)
            .set(SALE_DOCUMENTS.STATUS, "GENERATING")
            .set(SALE_DOCUMENTS.ATTEMPT_COUNT, SALE_DOCUMENTS.ATTEMPT_COUNT.plus(1))
            .set(SALE_DOCUMENTS.LAST_ATTEMPT_AT, currentTimestamp())
            .where(SALE_DOCUMENTS.ID.in(
                jooq.select(SALE_DOCUMENTS.ID)
                    .from(SALE_DOCUMENTS)
                    .where(
                        SALE_DOCUMENTS.STATUS.eq("PENDING_GENERATION")
                            .or(SALE_DOCUMENTS.STATUS.eq("RETRY_SCHEDULED")
                                .and(SALE_DOCUMENTS.NEXT_ATTEMPT_AT.le(currentTimestamp())))
                    )
                    .orderBy(SALE_DOCUMENTS.CREATED_AT.asc())
                    .limit(limit)
                    .forUpdate()
                    .skipLocked()
            ))
            .returning(SALE_DOCUMENTS.ID)
            .fetch()
            .map(r -> r.get(SALE_DOCUMENTS.ID));
    }
}
```

Key SQL primitives:
- `FOR UPDATE SKIP LOCKED` — other workers don't wait for this row, they grab the next
- `UPDATE ... RETURNING` — atomic claim, no race between claim and update
- `attempt_count` increment — bound retry tracking

### Phase 2: Generator

```java
@Component
public class SaleDocumentGenerator {

    private final SaleDocumentDataLoader loader;
    private final TemplateEngine thymeleaf;
    private final GotenbergClient gotenberg;
    private final DocumentStorage storage;

    // NO @Transactional — external I/O
    public DocumentArtifact generate(UUID docId) {
        var data = loader.load(docId);                    // Brief DB read OK
        var html = renderHtml(data);
        var pdf = gotenberg.htmlToPdf(html, options(data));
        var path = storage.upload(pdf, computePath(data));
        return new DocumentArtifact(path, pdf.length);
    }
}
```

External calls have **no transaction wrapping**. If they fail, exceptions propagate to the worker.

### Phase 3: Finalizer

```java
@Component
public class SaleDocumentFinalizer {

    private final SaleDocumentRepository repo;
    private final OutboxPublisher outbox;
    private final RetryPolicy retryPolicy;
    private final AdminAlerter adminAlerter;

    @Transactional
    public void markReady(UUID docId, String pdfPath) {
        var doc = repo.findById(docId).orElseThrow();
        doc.markReady(pdfPath, Instant.now());
        repo.save(doc);

        // Outbox event in same TX as state change
        outbox.publish(
            doc.tenantId(),
            new SaleDocumentReadyV1(doc.id(), doc.saleId(), pdfPath)
        );
    }

    @Transactional
    public void scheduleRetry(UUID docId, Exception cause) {
        var doc = repo.findById(docId).orElseThrow();
        if (doc.attemptCount() >= retryPolicy.maxAttempts()) {
            doc.markFailed("Max attempts exceeded: " + cause.getMessage());
            adminAlerter.notifyDocumentFailed(doc);
        } else {
            var nextDelay = retryPolicy.nextDelay(doc.attemptCount());
            doc.scheduleRetry(Instant.now().plus(nextDelay), cause.getMessage());
        }
        repo.save(doc);
    }

    @Transactional
    public void markFailed(UUID docId, Exception cause) {
        var doc = repo.findById(docId).orElseThrow();
        doc.markFailed(cause.getMessage());
        repo.save(doc);
        adminAlerter.notifyDocumentFailed(doc);
    }
}
```

## Exception taxonomy

```java
public sealed interface DocumentGenerationException 
    permits TransientException, PermanentException {}

public class TransientException extends DocumentGenerationException {
    // Retry
}

public class PermanentException extends DocumentGenerationException {
    // Mark FAILED, no retry
}

// Subtypes:
class GotenbergUnavailableException extends TransientException {}
class StorageUploadException extends TransientException {}
class NetworkTimeoutException extends TransientException {}

class TemplateRenderException extends PermanentException {}
class MissingDataException extends PermanentException {}
class OutputSizeExceededException extends PermanentException {}
```

The worker dispatches based on the sealed hierarchy.

## Retry policy

```java
@Component
public class DocumentRetryPolicy implements RetryPolicy {
    public Duration nextDelay(int attemptCount) {
        return switch (attemptCount) {
            case 1 -> Duration.ofSeconds(30);
            case 2 -> Duration.ofMinutes(2);
            case 3 -> Duration.ofMinutes(10);
            case 4 -> Duration.ofHours(1);
            default -> Duration.ZERO;  // exhausted
        };
    }
    
    public int maxAttempts() { return 5; }
}
```

## Idempotency

The external phase has no transactional guarantees. If JVM crashes between external success and TX2:

- Storage paths are **deterministic** (`{type}/{tenant}/{year}/{month}/{doc_id}.pdf`). Re-upload overwrites the same key — no orphaned duplicates.
- Webhooks (when added) include `event_id` for downstream dedup.
- Database `attempt_count` increments on every claim → observable.

## Stuck job detection

If JVM crashes mid-process, a row stays in `GENERATING` indefinitely. The stuck job detector resets:

```java
@Scheduled(cron = "0 */15 * * * *")  // every 15 min
@SchedulerLock(name = "stuck-job-detector", lockAtMostFor = "5m")
public void detectStuck() {
    var stuckDocs = repo.findStuckInGenerating(Duration.ofMinutes(10));
    for (var doc : stuckDocs) {
        log.warn("Document {} stuck > 10min, resetting to RETRY_SCHEDULED", doc.id());
        doc.scheduleRetry(Instant.now().plus(30, SECONDS));
        repo.save(doc);
    }
}
```

## Workers using this pattern

| Worker | Phase 1 | Phase 2 | Phase 3 |
|---|---|---|---|
| `SaleDocumentWorker` | Claim `sale_documents` | Render + upload PDF | Update status, emit event |
| `ReturnDocumentWorker` | Claim `return_documents` | Render + upload PDF | Update status, emit event |
| `PurchaseInvoiceDocumentWorker` | Claim `purchase_invoice_documents` | Render + upload PDF | Update status |
| `ZReportWorker` | Claim `z_reports` | Render + upload PDF | Update status |
| `OutboxDispatcher` | Claim `outbox_events` batch | Dispatch to consumers | Mark PUBLISHED / FAILED |
| `FxRateIngester` | No claim (poll cron) | Fetch from FX provider | INSERT fx_rates |

## Anti-patterns

```java
// ❌ Single transaction with external I/O
@Transactional
public void processDocument(UUID docId) {
    markGenerating(docId);
    var pdf = gotenberg.render(...);
    markReady(docId, pdf);
}

// ❌ Self-invocation of @Transactional from same bean
@Component
class BadWorker {
    public void processBatch() {
        var ids = this.claimBatch();  // @Transactional bypassed
        ...
    }
    @Transactional public List<UUID> claimBatch() { ... }
}

// ❌ Long-running operations inside @Transactional
@Transactional
public void importLargeFile(MultipartFile file) {
    for (var row : file.parse()) {
        // 30 seconds processing
        saveRow(row);
    }
}
```

ArchUnit catches the most common variant (external client in @Transactional class) via the rule in ADR-017.
