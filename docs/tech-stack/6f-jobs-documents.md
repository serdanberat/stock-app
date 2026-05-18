# Phase 6.F — Jobs & Document Generation

> **Status:** Locked
> **Phase:** 6.F
> **Related ADRs:** ADR-005, ADR-008, ADR-017

## Decisions

| Concern | Decision |
|---|---|
| Scheduler | Spring `@Scheduled` + ShedLock 6.x |
| ShedLock storage | `shedlock` table (migration 017) |
| ShedLock time source | `usingDbTime()` (PostgreSQL clock) |
| Tenant iteration | Single job iterates all tenants (MVP, ≤50 tenant) |
| Per-tenant parallel | v1.1+ (50+ tenant trigger) |
| Tenant context | `SystemTenantProvider.runAs()` |
| Scheduling style | `fixedDelay` for continuous, `cron` for daily batches |
| PDF generation | Gotenberg 8 sidecar container |
| HTML template | Thymeleaf |
| HTTP client | Spring `RestClient` (Spring Boot 4) |
| Gotenberg resource | 2 GB RAM, 2 vCPU |
| Document state machine | PENDING_GENERATION → GENERATING → READY / RETRY_SCHEDULED → FAILED |
| Retry policy | 5 attempts: 30s → 2m → 10m → 1h → FAILED |
| Exception taxonomy | Sealed: TransientException, PermanentException |
| Worker pattern | **TX1 claim → external I/O (no TX) → TX2 finalize** (ADR-017) |
| Worker structure | 3 beans: ClaimService, Generator, Finalizer |
| Document storage | `DocumentStorage` interface; LocalFS (MVP), R2/S3 (v1.1+) |
| Path scheme | `{type}/{tenant_id}/{year}/{month}/{doc_id}.pdf` |
| Download | App proxy endpoint (MVP), signed URL (v1.1+ S3) |
| Outbox dispatcher | `fixedDelay = 500ms`, batch 100 |
| Internal consumer dispatch | In TX (DB-only side effect) |
| External consumer dispatch | Outside TX (HTTP/email/webhook) |
| Consumer interface | `EventConsumer<T>` + `isInternal()` flag |
| Consumer idempotency | `processed_events` table check |
| Outbox DLQ scanner | Every 10 min, 5 attempts + 1h |
| Job observability | Micrometer `@Timed` + counters + last-success timestamp |
| Stuck detection | Every 15 min; GENERATING > 10 min reset, IN_PROGRESS > 2h alert |
| Worker scaling | MVP single instance, ShedLock multi-instance ready |
| Test strategy | Testcontainers (PostgreSQL + Gotenberg) |

## Scheduled jobs catalog

### Category A — Outbox dispatch

| Job | Schedule | Lock |
|---|---|---|
| Outbox dispatcher | `fixedDelay = 500ms` | `outbox-dispatcher`, 30s |
| Outbox DLQ scanner | `cron = "0 */10 * * * *"` | `outbox-dlq-scanner`, 5m |

### Category B — Document generation

| Job | Schedule | Lock |
|---|---|---|
| Sale document worker | `fixedDelay = 5s` | `sale-document-worker`, 2m |
| Return document worker | `fixedDelay = 5s` | `return-document-worker`, 2m |
| Purchase invoice doc worker | `fixedDelay = 5s` | `purchase-invoice-document-worker`, 2m |
| Z-report worker | `fixedDelay = 5s` | `z-report-worker`, 2m |

### Category C — Materialized view refresh

| View | Schedule |
|---|---|
| `daily_sales_summary` | every 5 min |
| `top_selling_variants` | every 30 min |
| `stock_position_summary` | every 10 min |
| `customer_aging_summary` | daily at 02:00 |
| `supplier_aging_summary` | daily at 02:00 |

### Category D — FX rate ingestion

| Provider | Schedule |
|---|---|
| TCMB | daily 15:30 (Europe/Istanbul) |
| HAREM | every 60 seconds |
| MANUAL | (no schedule, REST endpoint) |

### Category E — Cleanup & maintenance

| Job | Schedule |
|---|---|
| Expired user_sessions cleanup | hourly |
| Expired password_reset_tokens | hourly |
| Idle DRAFT sale abandonment | every 5 min (15-min idle → ABANDONED) |
| Idle AWAITING_PAYMENT timeout | every 5 min |
| Account aging computation | daily 03:00 (per tenant) |
| Reorder alert check | every 10 min |

### Category F — Saga step processors

| Job | Schedule |
|---|---|
| ExchangeGroup stall detection | every 10 min |
| Transfer auto-receive timeout | daily (when applicable) |
| Day-end close grace expirer | every 1 min |

### Category G — DLQ retry & poison detection

| Job | Schedule |
|---|---|
| DLQ candidate scanner | every 10 min |
| Stuck IN_PROGRESS process detector | hourly |
| Stuck document GENERATING reset | every 15 min |

**Total: ~20 scheduled tasks.**

## Document state machine

```
PENDING_GENERATION
       │ worker claims
       ▼
GENERATING
       │ ┌──────────────┐
       │ │ success      │ failure
       ▼ ▼              ▼
   READY          RETRY_SCHEDULED
       │                │ next_attempt_at <= now()
       │ user           ▼
       │ prints/        GENERATING (loop)
       │ submits           │ N attempts exhausted
       ▼                   ▼
PRINTED / SUBMITTED    FAILED (admin alert)
```

## Gotenberg integration

```yaml
# docker-compose (production)
gotenberg:
  image: gotenberg/gotenberg:8
  deploy:
    resources:
      limits:
        memory: 2G
        cpus: '2.0'
```

```java
@Component
class GotenbergClient {
    private final RestClient client;

    public byte[] htmlToPdf(String html, GotenbergOptions opts) {
        var body = new LinkedMultiValueMap<String, Object>();
        body.add("files", new InMemoryFile("index.html", html.getBytes(UTF_8)));
        body.add("paperWidth", opts.paperWidth());
        body.add("paperHeight", opts.paperHeight());
        body.add("marginTop", opts.marginTop());

        return client.post()
            .uri("/forms/chromium/convert/html")
            .contentType(MediaType.MULTIPART_FORM_DATA)
            .body(body)
            .retrieve()
            .body(byte[].class);
    }
}
```

## DocumentStorage abstraction

```java
public interface DocumentStorage {
    String upload(byte[] content, String relativePath);
    InputStream download(String path);
    void delete(String path);
}

@Component @Profile("local")
class LocalFileStorage implements DocumentStorage { /* writes to /var/lib/stockapp/documents */ }

@Component @Profile("r2 | s3")
class S3CompatibleStorage implements DocumentStorage { /* S3-compatible SDK */ }
```

## ShedLock table

Migration 017:

```sql
CREATE TABLE shedlock (
    name VARCHAR(64) PRIMARY KEY,
    lock_until TIMESTAMPTZ NOT NULL,
    locked_at TIMESTAMPTZ NOT NULL,
    locked_by VARCHAR(255) NOT NULL
);
```

System table; no RLS.

## Worker pattern reference

See `docs/architecture/worker-patterns.md` for the canonical three-phase template.

## Cross-references

- ADR-017 (external I/O outside transactions)
- `docs/architecture/worker-patterns.md`
- `docs/architecture/event-consumer-categories.md`
