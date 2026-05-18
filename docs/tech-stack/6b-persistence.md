# Phase 6.B — Persistence Layer

> **Status:** Locked
> **Phase:** 6.B
> **Related ADRs:** ADR-007, ADR-010, ADR-011

## Decisions

| Concern | Decision |
|---|---|
| RLS integration | `TenantAwareTransactionManager` + `SET LOCAL app.tenant_id` |
| Hibernate Filter / @Where | Forbidden (ArchUnit) |
| Tenant abstraction | `TenantProvider` interface |
| Tenant impls | `SecurityTenantProvider`, `SystemTenantProvider`, `TestTenantProvider` |
| Tenant context source | JWT → Spring Security Principal → SecurityTenantProvider |
| Background jobs | `SystemTenantProvider.runAs(tenantId, callable)` |
| Tenant missing behavior | Fail-fast (`TenantContextMissingException`) + RLS sentinel as defense |
| ScopedValue | Roadmap (Java 25 + virtual threads era) |
| JSONB (JPA) | Hibernate native `@JdbcTypeCode(SqlTypes.JSON)` |
| JSONB (JOOQ) | `org.jooq.JSONB` + Jackson custom binding |
| JSONB core domain | Typed records mandatory |
| JSONB external/audit | `Map<String, Object>` or `JsonNode` permitted |
| JPA role | Aggregate state mutations |
| JOOQ role | Reporting, batch, complex queries |
| Same-aggregate mixing | Forbidden (separate beans) |
| Connection pool | HikariCP (default), max 20 |
| HikariCP timeouts | 30s connection, 30min lifetime, 60s leak detection |
| Default isolation | READ COMMITTED |
| Stock critical path | READ COMMITTED + SELECT FOR UPDATE on stock_balances |
| Sequence allocators | SERIALIZABLE (only) |

## Key implementations

### TenantAwareTransactionManager

```java
@Component
public class TenantAwareTransactionManager extends JpaTransactionManager {

    private final TenantProvider tenantProvider;

    @Override
    protected void doBegin(Object transaction, TransactionDefinition definition) {
        super.doBegin(transaction, definition);

        if (tenantProvider.isAuthenticated()) {
            var emHolder = (EntityManagerHolder) 
                TransactionSynchronizationManager.getResource(getEntityManagerFactory());

            emHolder.getEntityManager()
                .createNativeQuery("SET LOCAL app.tenant_id = :tid")
                .setParameter("tid", tenantProvider.currentTenantId().toString())
                .executeUpdate();
        }
    }
}
```

### TenantProvider interface

```java
public interface TenantProvider {
    UUID currentTenantId();
    boolean isAuthenticated();
}

@Component @Primary
public class SecurityTenantProvider implements TenantProvider {
    @Override
    public UUID currentTenantId() {
        var auth = SecurityContextHolder.getContext().getAuthentication();
        if (auth == null || !auth.isAuthenticated()) {
            throw new TenantContextMissingException();
        }
        return ((StockAppPrincipal) auth.getPrincipal()).tenantId();
    }
    // ...
}

@Component
public class SystemTenantProvider implements TenantProvider {
    private final ThreadLocal<UUID> override = new ThreadLocal<>();
    
    public <T> T runAs(UUID tenantId, Callable<T> task) throws Exception {
        var previous = override.get();
        try {
            override.set(tenantId);
            return task.call();
        } finally {
            if (previous == null) override.remove();
            else override.set(previous);
        }
    }
    // ...
}
```

### HikariCP configuration

```yaml
spring:
  datasource:
    hikari:
      maximum-pool-size: 20
      minimum-idle: 5
      connection-timeout: 30000
      idle-timeout: 600000
      max-lifetime: 1800000
      leak-detection-threshold: 60000
```

### JSONB JPA mapping

```java
@Entity
public class Tenant {
    @JdbcTypeCode(SqlTypes.JSON)
    @Column(columnDefinition = "jsonb")
    private FeatureFlags featureFlags;
}
```

## Forbidden patterns

```java
// ❌ Hibernate filter for tenant
@FilterDef(name = "tenantFilter", ...)
@Filter(name = "tenantFilter", condition = "tenant_id = :tenantId")
@Entity public class Sale { ... }

// ❌ @Where for tenant
@Where(clause = "tenant_id = current_tenant()")
@Entity public class Sale { ... }

// ❌ Manual SET LOCAL in services
@Service class BadService {
    public Sale find(UUID id) {
        jdbc.execute("SET LOCAL app.tenant_id = ?", tenantId);  // wrong layer
        return saleRepo.findById(id);
    }
}

// ❌ Map<String, Object> for core domain JSONB
@JdbcTypeCode(SqlTypes.JSON)
private Map<String, Object> featureFlags;  // should be FeatureFlags record
```

## Cross-references

- Tenant flow: `docs/architecture/tenant-context-flow.md`
- JSONB rules: `docs/architecture/jsonb-typing-rules.md`
- Isolation levels: `docs/architecture/isolation-levels.md`
