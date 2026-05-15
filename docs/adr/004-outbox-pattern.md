# ADR 004 — Transactional Outbox for Cross-Context Events

> **Status:** Accepted
> **Date:** 2026-05-15

## Context

The system needs to propagate state changes across contexts and to async consumers (reporting projections, audit consumer, notification dispatch, e-document submission, materialised view refresh, external integrations). At the same time:

- The hot path (Sale completion) must be atomic and fast.
- We cannot lose events; financial and inventory events are critical.
- We cannot block the domain transaction on an external event bus.
- Consumers may run on different cadences; replay and retry must be supported.
- "At-least-once delivery with idempotent consumers" is the practical industry standard.

A naïve `publish-to-Kafka-then-commit` pattern is broken: if the publish succeeds but the commit fails, the consumer sees an event that never happened. If the commit succeeds but the publish fails, the event is silently lost.

## Decision

We adopt the **transactional outbox pattern**:

1. Domain transactions write a row to `outbox_events` **inside the same transaction** as the domain change.
2. A separate background publisher reads PENDING rows in batches, publishes them to the event bus (or directly invokes in-process consumers in MVP), and marks them PUBLISHED.
3. Consumers are **idempotent** and maintain their own `processed_events` table per consumer name.

### `outbox_events` schema

```
outbox_events (
  id                UUID PK,
  tenant_id         UUID NOT NULL,
  aggregate_type    VARCHAR NOT NULL,    -- 'SALE', 'RETURN', 'PURCHASE_INVOICE', ...
  aggregate_id      UUID NOT NULL,
  event_type        VARCHAR NOT NULL,    -- 'SaleCompleted', 'ReturnCompleted', ...
  event_version     VARCHAR NOT NULL,    -- 'v1'
  payload           JSONB NOT NULL,
  metadata          JSONB NOT NULL,      -- correlation_id, causation_id, actor, IP
  created_at        TIMESTAMPTZ DEFAULT now(),
  published_at      TIMESTAMPTZ NULL,
  publish_attempts  INT DEFAULT 0,
  last_attempt_at   TIMESTAMPTZ NULL,
  last_error        TEXT NULL,
  status            ENUM('PENDING','PUBLISHED','FAILED') DEFAULT 'PENDING'
);

INDEX (status, created_at) WHERE status = 'PENDING';
INDEX (aggregate_type, aggregate_id);
INDEX (tenant_id, event_type, created_at);
```

### Publisher loop

```
while running:
  pending = SELECT * FROM outbox_events
            WHERE status = 'PENDING'
              AND (publish_attempts < 5
                   OR last_attempt_at < now() - interval '1 minute')
            ORDER BY created_at ASC
            LIMIT 100
            FOR UPDATE SKIP LOCKED;

  for event in pending:
    try:
      publish(event)
      UPDATE outbox_events SET status='PUBLISHED', published_at=now()
       WHERE id = event.id;
    except Exception as e:
      attempts = publish_attempts + 1
      next_status = 'FAILED' if attempts >= 5 else 'PENDING'
      UPDATE outbox_events SET publish_attempts=attempts, last_attempt_at=now(),
                                last_error=text(e), status=next_status
       WHERE id = event.id;

  sleep(100ms)
```

`FOR UPDATE SKIP LOCKED` lets multiple publisher instances coordinate without blocking on each other.

### Consumer idempotency

Every consumer maintains:
```
processed_events (
  consumer_name    VARCHAR,
  event_id         UUID,
  processed_at     TIMESTAMPTZ,
  result_status    ENUM('SUCCESS','IGNORED','FAILED'),
  PRIMARY KEY (consumer_name, event_id)
);
```

Consumer pattern:
```
if already in processed_events (consumer_name, event.id):
    skip
else:
    BEGIN TRANSACTION
        apply event to projection
        INSERT processed_events (...)
    COMMIT
```

The insert into `processed_events` is in the **same transaction** as the projection update — so the consumer cannot "process but forget to record".

### Event versioning

`event_version = "v1"` initially. Consumers tolerate forward-compatible schema evolution. Breaking schema changes get a new `event_type` (or `event_version`) and run alongside the old for a transition period.

### Replay capability

An admin command:
```
replay_events --consumer=SalesReporting --from=2026-01-01 --to=2026-01-31
```
- Deletes corresponding `processed_events` rows.
- Re-feeds events from the outbox (`PUBLISHED` rows are kept indefinitely or for a long retention window).
- Idempotent consumers re-apply with the same result.

### Outbox retention

- `PENDING` and `FAILED`: kept indefinitely; FAILED requires manual intervention.
- `PUBLISHED`: kept for 90 days (configurable). Older rows archived or pruned.

### Event bus choice (MVP)

In MVP, the "event bus" can be **in-process** (a publisher worker invokes consumer functions directly in the same Postgres-backed process). This is operationally simplest. The interface is abstracted so we can switch to Kafka / RabbitMQ / NATS later without changing producers or consumers.

## Rationale

- **No lost events** — outbox row + domain change commit atomically.
- **At-least-once delivery** with **idempotent consumers** — industry-proven robustness.
- **Replay** — a non-negotiable capability for backfilling new projections, recovering from a buggy consumer, etc.
- **Operational simplicity** — no message broker required in MVP; can be added later without changing semantics.
- **Auditability** — outbox rows themselves are an event log for forensic review.

## Consequences

**Positive:**
- Strong correctness guarantees on cross-context propagation.
- Late-binding to a message broker.
- Easy debugging — outbox rows are observable; failures are explicit.
- Replay enables many downstream improvements (new projections, analytics changes).

**Negative:**
- Adds a table to write per domain operation. Tiny overhead.
- Publisher worker must run continuously and be monitored.
- Consumers must be carefully designed for idempotency. Mitigated by the `processed_events` pattern.

## Alternatives Considered

- **Direct publish to event bus** — rejected. Cannot atomically pair with the domain transaction.
- **Change Data Capture (CDC) from Postgres WAL** — interesting but operationally heavier; defer until justified.
- **Synchronous in-process events only, no outbox** — rejected. We need persistence and replay; in-process events lose on crash.
