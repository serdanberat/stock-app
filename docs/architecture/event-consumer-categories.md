# Event Consumer Categories

> **Status:** Locked (Phase 6.F)
> **Related ADRs:** ADR-008, ADR-017

Outbox dispatcher distinguishes two consumer types because each requires a different transactional model.

## The two categories

### Internal consumers

**Side effect**: DB write only (projection update, derived table refresh, audit log).

**Transaction model**: Run inside a database transaction. Consumer success and `processed_events` row INSERT commit atomically.

**Failure model**: Transaction rollback. Next dispatcher pass retries.

**Example consumers**:

- `DailySalesSummaryProjector` — updates `daily_sales_summary` materialized view incrementally
- `StockPositionProjector` — updates `stock_position_summary` projection
- `CustomerAgingProjector` — refreshes per-customer aging bucket
- `AuditEventLogProjector` — writes derived audit entries

### External consumers

**Side effect**: HTTP call, email, webhook, file system, third-party API.

**Transaction model**: Run **outside** a database transaction. After external call succeeds, a separate (short) transaction inserts the `processed_events` row.

**Failure model**: At-least-once delivery. Consumer crashes between external success and DB write → re-dispatch executes external call again. Consumer must be idempotent.

**Example consumers**:

- `EmailNotificationConsumer` — sends transactional email
- `WebhookDeliveryConsumer` — POSTs to tenant-configured webhook URL
- `SmsNotificationConsumer` (v1.1+) — sends SMS via provider
- `EBelgeSubmissionConsumer` (v1.1+) — submits e-Arşiv/e-Fatura to GİB
- `AccountingExportConsumer` (v1.1+) — pushes CSV to Logo/Mikro

## Consumer interface

```java
public interface EventConsumer<T> {
    String name();              // unique, used in processed_events
    Class<T> eventType();        // type discriminator
    boolean isInternal();        // routing flag
    int eventVersion();          // schema version handled
    void handle(T event, EventMetadata metadata);
}
```

## Dispatcher routing

```java
@Component
class EventDispatcher {

    private final InternalEventDispatcher internal;
    private final ExternalEventDispatcher external;

    public DispatchResult dispatch(OutboxEvent event) {
        var consumers = registry.consumersFor(event.eventType());
        var results = new ArrayList<ConsumerResult>();

        for (var consumer : consumers) {
            if (processedEventsService.alreadyProcessed(consumer.name(), event.eventId())) {
                results.add(ConsumerResult.skipped(consumer.name()));
                continue;
            }

            try {
                if (consumer.isInternal()) {
                    internal.dispatch(consumer, event);
                } else {
                    external.dispatch(consumer, event);
                }
                results.add(ConsumerResult.success(consumer.name()));
            } catch (Exception e) {
                results.add(ConsumerResult.failed(consumer.name(), e));
            }
        }

        return DispatchResult.of(results);
    }
}
```

## Internal dispatcher

```java
@Component
class InternalEventDispatcher {

    private final ProcessedEventsService processedEventsService;

    @Transactional
    public <T> void dispatch(EventConsumer<T> consumer, OutboxEvent event) {
        @SuppressWarnings("unchecked")
        var typed = (T) deserialize(event, consumer.eventType());
        consumer.handle(typed, event.metadata());
        processedEventsService.markSuccess(consumer.name(), event.eventId());
    }
}
```

The whole thing — projection update + `processed_events` INSERT — commits atomically. If the consumer throws, both roll back.

## External dispatcher

```java
@Component
class ExternalEventDispatcher {

    private final ProcessedEventsService processedEventsService;

    // No @Transactional on this method
    public <T> void dispatch(EventConsumer<T> consumer, OutboxEvent event) {
        @SuppressWarnings("unchecked")
        var typed = (T) deserialize(event, consumer.eventType());

        try {
            consumer.handle(typed, event.metadata());  // External call

            // External succeeded; record in a separate, short TX
            processedEventsService.markSuccess(consumer.name(), event.eventId());
        } catch (Exception e) {
            processedEventsService.markFailed(consumer.name(), event.eventId(), e);
            throw e;
        }
    }
}
```

`processedEventsService.markSuccess(...)` is its own `@Transactional` method.

## At-least-once semantics

The external path has a crash window between "external call succeeded" and "DB row inserted". If the JVM crashes during that window:

- External system has the side effect (email sent, webhook delivered)
- `processed_events` does not have the row
- Next dispatcher pass re-runs the consumer
- External call happens again

This is **at-least-once delivery**. Exactly-once is not provided.

### Consumer idempotency requirements

External consumers must absorb duplicates:

- Webhook payloads include `event_id` so downstream can dedupe
- Email senders use `Message-ID` derived from `event_id`
- Accounting exports use `event_id` as the source identifier
- Idempotent by retry: if the consumer's outcome depends on prior state, that state must be checked

## Why not "transactional outbox at the consumer"?

A common pattern is for the consumer to also use an outbox table for downstream calls. This is theoretically more robust but:

- Doubles infrastructure complexity (consumer-side outbox tables, separate workers)
- Most consumers are simple (one email, one HTTP call)
- The cost-benefit doesn't justify the added moving parts for MVP

If a specific consumer needs stronger guarantees (e.g. GİB e-Belge submission with multi-step state), it can implement its own state machine. The pattern is opt-in per consumer.

## Failure handling

| Outcome | `processed_events.result_status` | Outbox event status |
|---|---|---|
| Consumer succeeds | `SUCCESS` | unchanged (other consumers may pending) |
| Consumer transient fail | `FAILED` (will retry) | unchanged |
| Consumer permanent fail | `POISONED` (skip) | DLQ if all consumers fail or skip |
| Consumer absent | (no row) | unchanged |

A consumer that consistently fails (e.g. 5+ times) is marked `POISONED` for that event. The dispatcher skips it on subsequent passes; alerts notify operators.

## Registration

Consumers are discovered as Spring beans:

```java
@Component
class DailySalesSummaryProjector implements EventConsumer<SaleCompletedV1> {

    public String name() { return "daily-sales-summary"; }
    public Class<SaleCompletedV1> eventType() { return SaleCompletedV1.class; }
    public boolean isInternal() { return true; }
    public int eventVersion() { return 1; }

    @Override
    public void handle(SaleCompletedV1 event, EventMetadata meta) {
        // Update daily_sales_summary
    }
}
```

The dispatcher's `consumerRegistry` injects `List<EventConsumer<?>>` and indexes by event type.

## Anti-patterns

```java
// ❌ External call in internal consumer
@Component
class BadConsumer implements EventConsumer<SaleCompletedV1> {
    public boolean isInternal() { return true; }  // Lies
    
    public void handle(SaleCompletedV1 e, EventMetadata m) {
        emailService.send(...);  // External! Will run in TX, block pool
    }
}

// ❌ Multiple side effects in external consumer (no atomicity)
@Component
class WrongConsumer implements EventConsumer<SaleCompletedV1> {
    public boolean isInternal() { return false; }
    
    public void handle(SaleCompletedV1 e, EventMetadata m) {
        emailService.send(...);    // ok
        webhookService.post(...);  // if this fails, email already sent + redelivery
        smsService.send(...);      // worse
    }
}
```

For multiple external side effects, split into multiple consumers. Each is independently idempotent and retried.
