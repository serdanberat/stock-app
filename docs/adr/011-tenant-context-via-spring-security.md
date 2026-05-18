# ADR-011: Tenant Context via Spring Security Principal

**Status:** Accepted
**Date:** 2026-05-16
**Phase:** 6.B

## Context

Multi-tenancy is enforced by PostgreSQL Row Level Security (ADR-007). RLS policies query `current_tenant_id()`, which reads `current_setting('app.tenant_id', true)`.

The application must reliably populate `app.tenant_id` for every database transaction. The tenant identifier must come from a tamper-resistant source, propagate naturally through Spring's threading model, and remain testable.

Three options were evaluated:

1. **ThreadLocal<UUID>** — classic, but Loom/virtual-thread incompatible and async-unfriendly
2. **ScopedValue<UUID>** (Java 21+ preview) — modern, structured-concurrency-friendly, but preview
3. **Spring Security Principal** — uses existing JWT authentication, naturally propagates through `SecurityContextHolder`

## Decision

Tenant identifier flows through Spring Security's `Authentication.getPrincipal()`:

```
HTTP request → JWT filter → StockAppPrincipal in SecurityContext
                                 ↓
                          SecurityTenantProvider.currentTenantId()
                                 ↓
                          TenantAwareTransactionManager.doBegin()
                                 ↓
                          SET LOCAL app.tenant_id = '<uuid>'
                                 ↓
                          PostgreSQL RLS evaluates current_tenant_id()
```

### Abstraction layer

A `TenantProvider` interface decouples consumers from the source mechanism:

```java
public interface TenantProvider {
    UUID currentTenantId();
    boolean isAuthenticated();
}
```

Three implementations:

| Implementation | Use case |
|---|---|
| `SecurityTenantProvider` | Production runtime — reads from `SecurityContextHolder` |
| `SystemTenantProvider` | Background jobs — explicit `runAs(tenantId, callable)` API |
| `TestTenantProvider` | Tests — fixed UUID via test profile |

### Background jobs

Scheduled tasks have no HTTP request and thus no `SecurityContext`. The `SystemTenantProvider` provides an explicit API:

```java
systemTenantProvider.runAs(tenantId, () -> {
    reorderAlertService.checkAll();
    return null;
});
```

A thread-local override inside `SystemTenantProvider` allows nested calls.

## Consequences

**Positive:**
- Single source of truth: JWT claim
- No risk of forgotten tenant context (RLS plus sentinel UUID is the safety net)
- Tests can swap implementations cleanly via profile
- Spring Security already propagates context across async boundaries

**Negative:**
- Background jobs need explicit `runAs(...)` (boilerplate)
- Loom virtual threads currently propagate `SecurityContext` via `InheritableThreadLocal`; needs verification when enabled in v1.0.x

**Trade-off accepted:** Spring Security propagation is good enough today; `ScopedValue` migration is on the roadmap for when Java 25 + virtual threads are enabled in production.

## Failure mode

If `SecurityContextHolder` is empty (unauthenticated request reaches business logic by mistake):

- `SecurityTenantProvider.currentTenantId()` throws `TenantContextMissingException`
- Application returns 500 (not 403 — distinct semantics)
- RLS sentinel UUID (`00000000-0000-0000-0000-000000000000`) ensures even a query that bypassed the application layer returns zero rows
