# Tenant Context Flow

> **Status:** Locked (Phase 6.B)
> **Related ADRs:** ADR-007, ADR-011

End-to-end flow of how a request's tenant identity reaches the PostgreSQL Row-Level Security policy.

## The pipeline

```
┌────────────────┐
│ HTTP request   │ Authorization: Bearer <access_token>
└────────┬───────┘
         │
         ▼
┌────────────────────────────┐
│ JwtAuthenticationFilter    │  Validates HMAC signature
│ (Spring Security)          │  Decodes claims (sub, tid, rol, stp, ssn)
└────────┬───────────────────┘  Builds StockAppPrincipal
         │                       Calls SecurityContextHolder.setAuthentication(...)
         ▼
┌────────────────────────────┐
│ MdcContextFilter           │  Populates MDC:
│                            │    tenant_id, user_id, tenant_code, trace_id
└────────┬───────────────────┘
         │
         ▼
┌────────────────────────────┐
│ Controller method          │  @PreAuthorize("@authz.has('sales.complete')")
│                            │     ↓
│                            │  AuthorizationService.has(...)
│                            │     ↓
│                            │  SecurityTenantProvider.currentTenantId()
│                            │     ↓
│                            │  Returns UUID from SecurityContextHolder principal
└────────┬───────────────────┘
         │
         ▼
┌────────────────────────────┐
│ @Transactional method      │  TenantAwareTransactionManager.doBegin(...)
│                            │     ↓
│                            │  EntityManager.createNativeQuery(
│                            │      "SET LOCAL app.tenant_id = :tid")
│                            │     .setParameter("tid", currentTenantId().toString())
│                            │     .executeUpdate()
└────────┬───────────────────┘
         │
         ▼
┌────────────────────────────┐
│ Repository query           │  jpaRepo.findById(...) → SQL execution
│  or JOOQ query             │
└────────┬───────────────────┘
         │
         ▼
┌────────────────────────────┐
│ PostgreSQL                 │  RLS policy evaluation:
│                            │    USING (tenant_id = current_tenant_id())
│                            │     ↓
│                            │  current_tenant_id() reads
│                            │    current_setting('app.tenant_id', true)
│                            │     ↓
│                            │  Compares to row.tenant_id
│                            │     ↓
│                            │  Returns matching rows only
└────────────────────────────┘
```

## Background jobs path

Scheduled jobs have no HTTP request and no SecurityContext. The flow diverges:

```
┌────────────────────────────┐
│ @Scheduled method          │  systemTenantProvider.runAs(tenantId, () -> {
└────────┬───────────────────┘     ...
         │                       });
         ▼
┌────────────────────────────┐
│ SystemTenantProvider       │  Sets ThreadLocal<UUID> override
│ .runAs()                   │
└────────┬───────────────────┘
         │
         ▼
┌────────────────────────────┐
│ Business service           │  TenantProvider.currentTenantId()
│  @Transactional            │    ↓
│                            │  SystemTenantProvider returns override
│                            │    ↓
│                            │  TenantAwareTransactionManager.doBegin(...)
│                            │    ↓ (same SET LOCAL flow)
└────────────────────────────┘
```

The two flows converge at `TenantAwareTransactionManager`.

## Fail-safe behavior

If something goes wrong (forgot `runAs`, missing JWT filter, etc.):

```
SecurityTenantProvider.currentTenantId()
  → TenantContextMissingException
  → HTTP 500 (fail-fast at application layer)

If the application bypasses the provider check (bug):
  → SET LOCAL is never set
  → PostgreSQL current_tenant_id() returns sentinel
     ('00000000-0000-0000-0000-000000000000')
  → RLS policy returns ZERO rows
  → No tenant data leakage; correct empty result
```

Three defense layers: application middleware, connection-level SET LOCAL, RLS sentinel.

## Verification

Nightly RLS leakage detector:

```sql
-- Run with no app.tenant_id set
RESET app.tenant_id;
SELECT count(*) FROM sales;       -- MUST return 0
SELECT count(*) FROM stock_movements;  -- MUST return 0
-- ... 45+ tenant-scoped tables
```

Any non-zero result alerts. This is the canary for missing RLS policy or misconfiguration.

## Anti-patterns (forbidden)

- Hibernate `@Filter` / `@FilterDef` for tenant filtering — duplicates RLS, drifts on native queries
- Hibernate `@Where(clause = "tenant_id = ...")` — same problem
- Application-level `WHERE tenant_id = ?` injection — RLS is the source of truth
- Bypassing `TenantProvider` and reading session var directly — couples to plumbing

ArchUnit enforces these via:

```java
@ArchTest
static final ArchRule no_hibernate_tenant_filter_annotations =
    noClasses().should().beAnnotatedWith(FilterDef.class)
        .orShould().beAnnotatedWith(Filter.class);
```

## Test profile

Integration tests use `TestTenantProvider` configured via Spring `@Profile("test")`:

```java
@Bean @Profile("test")
public TenantProvider testTenantProvider() {
    return new TestTenantProvider(TEST_TENANT_ID);
}
```

Test fixtures set `SecurityContextHolder` with a synthetic principal; the rest of the pipeline runs unchanged.
