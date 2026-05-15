# ADR 008 — Domain Events and Outbox Implementation

> **Status:** Accepted
> **Date:** 2026-05-15
> **Builds on:** ADR 004 (Outbox Pattern)

## Context

ADR 004 fixed the **outbox-pattern** decision at the foundation level: every cross-context state change is durably recorded inside the same transaction as the domain change, and a background publisher hands it off to consumers. Phase 2D pushed this further by:

1. Cataloguing the actual ~60 events the system will produce.
2. Settling the envelope shape (event id, version, ordering keys, metadata).
3. Locking the schema-versioning policy.
4. Separating high-frequency security events from domain events.
5. Specifying the dead-letter queue.
6. Confirming a partitioning strategy that is stable across schema migrations.

ADR 008 records those Phase 2D decisions so that implementation can proceed without re-derivation.

## Decision

The outbox pattern in ADR 004 is implemented with the following additional commitments.

### 1. Event envelope

Every event uses a single envelope shape — `event_id`, `event_type`, `event_version`, `aggregate_type`, `aggregate_id`, `aggregate_version`, `tenant_id`, `occurred_at`, `recorded_at`, `ordering_keys`, `metadata`, `payload`. See [`domain-events.md`](../architecture/domain-events.md) § 1 for the exact contract. This envelope is a stable wire format; only the `payload` varies by event type.

### 2. Three monotonic sequences accompany every event

- `outbox_sequence` — global outbox BIGSERIAL, the publisher read order.
- `global_sequence` — per-tenant monotonic counter, allows gap detection across a whole tenant.
- `aggregate_sequence` — per-aggregate monotonic counter, populated for append-only ledger events (`StockMovementRecorded`, `AccountMovementRecorded`) where `(variant_id, store_id)` and `(profile_id)` act as the "aggregate".

For mutable aggregates (Sale, Payment, Transfer), `aggregate_version` plays the equivalent role of `aggregate_sequence`.

### 3. Schema versioning

`event_version = "v1"` initially. Forward-compatible changes (add optional fields, expand enums) keep the same version. Breaking changes (rename, type change, required field, enum tightening) get a new version. The producer runs both versions in parallel during migration; consumers move one by one; the old version is retired after all consumers are migrated.

Validation is performed at producer time (before outbox INSERT) and consumer time (before applying). A consumer-side schema mismatch routes the event to DLQ with `reason = SCHEMA_MISMATCH`.

### 4. Two parallel streams

| Stream | Storage | Use |
|---|---|---|
| Domain events | `outbox_events` table | Business state changes |
| Security audit | `security_audit_log` table | Authentication, MFA, password, session, IP signals |

Login, logout, MFA, password, page-view and similar high-frequency events are **NOT** in the outbox. They would flood the bus with non-domain noise and inflate retention. They are persisted directly by the security middleware to their own append table.

### 5. Partition key = `aggregate_id`

When the system migrates from the in-process publisher to an external broker (Kafka, Redis Streams, RabbitMQ) in v1.1+, events route to partitions by `aggregate_id`. This guarantees strict per-aggregate ordering at the cost of occasional hot partitions for very busy aggregates (top-selling variants). The trade-off is acceptable; brokers handle this load and we prefer correctness over perfect distribution.

The partition key is decided at outbox INSERT time and never changes for a given event. It survives `event_version` migrations.

Consumer groups, when on an external broker, are keyed by `(tenant_id, consumer_name)` so that a noisy tenant cannot affect another tenant's consumer lag.

### 6. Dead letter queue (DLQ)

The outbox `status` column carries an additional `DEAD_LETTER` state. A row transitions to DLQ when:

- 10 publish attempts within 24 hours → `MAX_ATTEMPTS_EXCEEDED`
- Schema validation fails (producer or consumer side) → `SCHEMA_MISMATCH`
- Consumer raises an unsatisfiable-invariant exception → `POISON_EVENT`
- Consumer is permanently broken / deregistered → `CONSUMER_PERMANENT_FAILURE`
- Operator explicitly poisons the event → `MANUAL_DLQ`
- Target tenant is ARCHIVED before processing → `TENANT_ARCHIVED`

`dead_letter_at` and `dead_letter_reason` columns record the transition. An `OutboxEventDeadLettered` domain event is emitted on transition for the audit and notification consumers.

Operations are available: `list_dlq`, `replay_dlq_event`, `bulk_replay_dlq`, `discard_dlq_event` (each discard is audit-logged).

Monitoring thresholds: DLQ size > 100 → warning; > 1000 → critical; any event in DLQ longer than 24 hours → review needed.

### 7. PII safeguards in payloads

- Events reference parties and users by ID, never by raw email / phone / tax_id.
- Card data is masked (`**** **** **** 1234`) where surfacing is necessary for operational debugging.
- Secrets (tokens, hashes, keys) never appear in payloads.
- Free-text fields (e.g. notes) are summarised or omitted when they could carry PII; full text remains in the source row.

### 8. Compliance-grade `TenantArchived` payload

The only event whose payload formally records compliance metadata. Carries `anonymization_method`, `anonymization_scope`, `preserved_data`, `cold_storage_path`, `physical_purge_eligible_at` and `compliance_basis` (GDPR + VUK references). See [`domain-events.md`](../architecture/domain-events.md) § 6.

## Rationale

These commitments turn ADR 004's "outbox pattern" from a principle into an implementable spec. Each one resolves a question that would otherwise be answered ad-hoc per consumer:

- The envelope contract prevents schema drift across producers.
- The three sequences make replay-and-debug practical.
- Schema versioning supports long-running consumers without lock-step deployments.
- The two-stream split protects the outbox from non-domain noise.
- The partition key choice de-risks the future broker migration.
- The DLQ keeps operational maturity within reach without bespoke per-consumer error handling.

## Consequences

**Positive:**
- Producers and consumers share a single envelope shape; tooling (schema validation, replay) generalises trivially.
- Per-aggregate ordering survives the move from in-process to broker.
- Failed events are visible, diagnosable, replayable.
- High-frequency security events do not dilute domain analytics.
- Compliance-relevant operations (`TenantArchived`) leave a self-describing audit trail.

**Negative:**
- The envelope has a few "rarely populated" fields (`aggregate_sequence`, `aggregate_version`). Producers must know which apply. Mitigated by schema definitions and code review.
- DLQ requires monitoring and an operator process. We accept this as the cost of an at-least-once system at scale.

## Alternatives Considered

- **Per-context envelope shapes.** Rejected: every cross-cutting tool (audit, reporting, replay) would need per-context adapters.
- **Single sequence (`outbox_sequence` only).** Rejected: insufficient for per-aggregate debugging during replay.
- **Mix security events into outbox.** Rejected: floods the domain stream; different retention/replay semantics; no analytical benefit.
- **Routing by `tenant_id` instead of `aggregate_id`.** Rejected: weakens per-aggregate ordering, which is the property we most need.
- **Fail-on-first attempt DLQ.** Rejected: too aggressive for transient failures (network blips, restarts).

## Open Items

- **TODO (Phase 6)** — Concrete event-bus implementation for v1.1+. The abstraction is fixed by this ADR; the implementation choice is downstream.
- **TODO (Sprint 0)** — JSON schema files for each event type under `/docs/schemas/events/<EventType>.v1.json`.
