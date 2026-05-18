# JSONB Typing Rules

> **Status:** Locked (Phase 6.B)
> **Related ADRs:** ADR-010

Rules governing how JSONB columns are represented in Java.

## The three tiers

| Tier | Rule | Examples |
|---|---|---|
| **Core domain** | Typed record **mandatory** | Catalog, inventory, sales, financial JSONB |
| **External integration** | `Map<String, Object>` permitted | Webhook bodies, third-party API responses |
| **Audit / raw snapshot** | `JsonNode` permitted | `audit_event_log.details` |

## Core domain typed records

These records are mandatory. Field renames cause compile errors that guide refactoring.

### `FeatureFlags` (tenants.feature_flags)

```java
public record FeatureFlags(
    @JsonProperty("schema_version") String schemaVersion,
    @JsonProperty("allow_admin_register_reopen") boolean allowAdminRegisterReopen,
    @JsonProperty("allow_admin_sale_reverse") boolean allowAdminSaleReverse,
    @JsonProperty("allow_admin_return_reverse") boolean allowAdminReturnReverse,
    @JsonProperty("allow_blind_return") boolean allowBlindReturn,
    @JsonProperty("allow_negative_stock") boolean allowNegativeStock,
    @JsonProperty("auto_block_on_overdue_days") Integer autoBlockOnOverdueDays,
    @JsonProperty("blind_return_max_amount_per_day") BigDecimal blindReturnMaxAmountPerDay,
    @JsonProperty("blind_return_max_count_per_day") Integer blindReturnMaxCountPerDay,
    @JsonProperty("blind_return_manager_threshold") BigDecimal blindReturnManagerThreshold,
    @JsonProperty("blind_return_customer_frequency_limit") Integer blindReturnCustomerFrequencyLimit,
    @JsonProperty("blind_return_excluded_categories") List<UUID> blindReturnExcludedCategories
) {
    public static FeatureFlags defaultFlags() {
        return new FeatureFlags("v1", false, false, false, false, false,
                                null, new BigDecimal("5000"), 10, new BigDecimal("1000"),
                                3, List.of());
    }
}
```

### `TenantSettings` (tenants.settings)

```java
public record TenantSettings(
    @JsonProperty("schema_version") String schemaVersion,
    @JsonProperty("return_grace_days") int returnGraceDays,
    @JsonProperty("return_manager_threshold") BigDecimal returnManagerThreshold,
    @JsonProperty("product_code_template") String productCodeTemplate,
    @JsonProperty("price_cipher_keyword") String priceCipherKeyword,
    @JsonProperty("tenant_prefix_for_barcodes") String tenantPrefixForBarcodes,
    @JsonProperty("z_report_number_prefix") String zReportNumberPrefix
) {}
```

### `VariantAttributes` (product_variants.attributes)

Holds non-discriminator attributes (material, model, gender, etc. — color/size are FK columns).

```java
public record VariantAttributes(
    @JsonProperty("schema_version") String schemaVersion,
    @JsonProperty("attribute_values") List<AttributeValueRef> attributeValues
) {}

public record AttributeValueRef(
    @JsonProperty("type_code") String typeCode,      // "MATERIAL"
    @JsonProperty("value_id") UUID valueId,           // FK to attribute_values
    @JsonProperty("value_code") String valueCode      // denormalized for read
) {}
```

### `FxSnapshotPayload` (fx_snapshots.rates)

```java
public record FxSnapshotPayload(
    @JsonProperty("schema_version") String schemaVersion,
    @JsonProperty("rates") Map<String, FxRatePair> rates
) {}

public record FxRatePair(
    @JsonProperty("buy") BigDecimal buy,
    @JsonProperty("sell") BigDecimal sell
) {}
```

### `EventMetadata` (outbox_events.metadata)

```java
public record EventMetadata(
    @JsonProperty("source_module") String sourceModule,
    @JsonProperty("source_user_id") UUID sourceUserId,
    @JsonProperty("correlation_id") String correlationId,
    @JsonProperty("causation_id") UUID causationId,
    @JsonProperty("trace_id") String traceId,
    @JsonProperty("ip") String ip
) {}
```

### `TenderAttempt` (payment_attempts.tender_attempts)

Each entry in the JSONB array.

```java
public record TenderAttempt(
    @JsonProperty("attempt_index") int attemptIndex,
    @JsonProperty("tender_type") String tenderType,
    @JsonProperty("amount") BigDecimal amount,
    @JsonProperty("currency") String currency,
    @JsonProperty("outcome") String outcome,                 // APPROVED | DECLINED | TIMEOUT | CANCELLED
    @JsonProperty("terminal_response_code") String terminalResponseCode,
    @JsonProperty("recorded_at") Instant recordedAt
) {}
```

### `TerminalPendingMetadata` (sales.terminal_pending_metadata)

```java
public record TerminalPendingMetadata(
    @JsonProperty("terminal_id") String terminalId,
    @JsonProperty("terminal_provider") String terminalProvider,
    @JsonProperty("terminal_transaction_id") String terminalTransactionId,
    @JsonProperty("tender_amount") BigDecimal tenderAmount,
    @JsonProperty("tender_currency") String tenderCurrency,
    @JsonProperty("card_masked") String cardMasked,
    @JsonProperty("expected_callback_by") Instant expectedCallbackBy
) {}
```

### Outbox event payloads (one record per type)

Each event type is a record. Examples:

```java
public record SaleCompletedV1(
    @JsonProperty("schema_version") String schemaVersion,
    @JsonProperty("sale_id") UUID saleId,
    @JsonProperty("sale_number") String saleNumber,
    @JsonProperty("store_id") UUID storeId,
    @JsonProperty("customer_id") UUID customerId,
    @JsonProperty("total_try") BigDecimal totalTry,
    @JsonProperty("item_count") int itemCount,
    @JsonProperty("completed_at") Instant completedAt
) implements DomainEvent {}
```

The pattern: one record per `event_type.v{N}`. Versioning is explicit in the type name.

## Exceptions (Map / JsonNode permitted)

### `parties.metadata`

Tenants define custom fields not known at compile time. Example:

```json
{
  "loyalty_tier": "GOLD",
  "birthday": "1985-03-12",
  "preferred_size": "M",
  "notes": "Çiçekçi yan komşu"
}
```

Java representation: `Map<String, Object>`.

### `audit_event_log.details`

Forensic data is intentionally schema-free. Java representation: `JsonNode`.

### External webhook payloads (when added v1.1+)

Inbound webhook bodies from third parties (Stripe, e-Belge provider responses). Java representation: `Map<String, Object>` or provider-specific record if their schema is documented.

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

Modules outside the core domain (audit, outbox, integrations) are exempt.

## Schema versioning convention

Every core record includes `schema_version: "v1"`. Migration to v2:

1. Add new record `FeatureFlagsV2` (or evolve `FeatureFlags` if backward-compatible)
2. Deserializer detects `schema_version` and upgrades old structures in-flight
3. Background job rewrites JSONB columns when convenient
4. After all rows are v2, remove v1 handling

Versioning is forward-compatible by design: missing fields default, extra fields ignored.
