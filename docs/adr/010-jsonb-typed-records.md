# ADR-010: JSONB Typed Records for Core Domain

**Status:** Accepted
**Date:** 2026-05-16
**Phase:** 6.B

## Context

The schema uses JSONB columns in many places: `tenants.feature_flags`, `product_variants.attributes`, `fx_snapshots.rates`, `outbox_events.payload`, `payment_attempts.tender_attempts`, etc.

Two representation strategies exist on the Java side:

1. **Raw `Map<String, Object>`** — flexible, no schema enforcement, easy to refactor wrong
2. **Typed records (POJOs)** — compile-time safety, IDE completion, refactor-friendly

A typed record forces a schema; a Map permits anything.

ERP systems that start with raw Maps systematically degrade: typos in field names cause silent bugs, schema drift accumulates, refactoring becomes impossible, runtime cast exceptions appear in production.

## Decision

Three-tier rule for JSONB representation:

| Layer | Rule | Examples |
|---|---|---|
| **Core domain** | Typed record **mandatory** | `tenants.feature_flags` → `FeatureFlags` record |
| **External integration payload** | `Map<String, Object>` permitted | Webhook bodies, third-party API responses |
| **Audit / raw snapshot** | `JsonNode` permitted | `audit_event_log.details`, debug snapshots |

### Core domain typed records (initial set)

| Table.Column | Record |
|---|---|
| `tenants.feature_flags` | `FeatureFlags` |
| `tenants.settings` | `TenantSettings` |
| `product_variants.attributes` | `VariantAttributes` |
| `fx_snapshots.rates` | `FxSnapshotPayload` |
| `outbox_events.payload` | One record per event type (`SaleCompletedV1`, etc.) |
| `outbox_events.metadata` | `EventMetadata` |
| `payment_attempts.tender_attempts` | `List<TenderAttempt>` |
| `sales.terminal_pending_metadata` | `TerminalPendingMetadata` |

### Exceptions

`parties.metadata` permits `Map<String, Object>` because users can define custom fields ("birthday", "preferred size") not known at compile time.

`audit_event_log.details` permits `JsonNode` because audit details are forensic-only, schema-free.

## Implementation

- JPA: `@JdbcTypeCode(SqlTypes.JSON)` (Hibernate 6.6+ native, no third-party library)
- JOOQ: `org.jooq.JSONB` + Jackson custom binding
- Records use Java records (`public record FeatureFlags(...)`), immutable
- Schema versioning inside each record (e.g. `schema_version: "v1"` field)

## Enforcement

ArchUnit rule:

```java
@ArchTest
static final ArchRule core_domain_jsonb_must_be_typed =
    fields().that().areAnnotatedWith(JdbcTypeCode.class)
        .and().areDeclaredInClassesThat()
            .resideInAPackage("..modules.(catalog|inventory|sales|financial).internal.domain..")
        .should().notHaveRawType(Map.class)
        .andShould().notHaveRawType(JsonNode.class);
```

## Consequences

**Positive:**
- Compile-time safety on critical domain JSONB
- IDE autocomplete for field access
- Refactor-friendly (rename field → compile errors guide updates)
- Schema versioning trackable per record

**Negative:**
- Schema changes require code change (intentional)
- Slightly more boilerplate vs raw Map

**Mitigations:**
- Records reduce boilerplate vs traditional POJOs
- JsonNode escape hatch for genuinely schemaless data
