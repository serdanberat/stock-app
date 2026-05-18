# ADR-016: Permission Caching Strategy

**Status:** Accepted
**Date:** 2026-05-16
**Phase:** 6.D

## Context

Authorization decisions happen on virtually every API request:

```java
@PreAuthorize("@authz.has('sales.complete')")
@PostMapping("/sales/{id}/complete")
```

A naïve implementation queries the database every time:

```sql
SELECT permissions FROM roles WHERE id IN (user's role ids);
```

At 1000 requests/min across active users, this is unacceptable load on a small Hetzner instance.

Three options were considered:

1. **Embed permissions in JWT** — zero DB hit, but permission changes have ≤15min latency and JWT bloats
2. **Per-request DB query** — accurate but expensive
3. **Application-level cache with invalidation** — balanced

## Decision

Permissions are cached in a Caffeine in-memory cache keyed by `role_id`, with a 5-minute TTL and explicit invalidation on permission changes.

### Why not in JWT

JWT contains `roleIds` (small, immutable per session) but not `permissions` (potentially dozens of strings, mutable). Embedding permissions in JWT means:

- Token size inflates (~2KB → ~8KB)
- Permission grant/revoke takes effect only after token refresh (up to 15min)
- Every role permission change requires forcing user logout

### Cache configuration

```java
@Bean
public Cache<UUID, Set<String>> rolePermissionCache() {
    return Caffeine.newBuilder()
        .maximumSize(10_000)            // 10K roles cached
        .expireAfterWrite(5, MINUTES)   // bounded staleness
        .recordStats()
        .build();
}
```

### Resolution flow

```java
public boolean has(StockAppPrincipal user, String permission) {
    for (var roleId : user.roleIds()) {
        var perms = rolePermissionCache.get(roleId, this::loadFromDb);
        if (matchesAny(perms, permission)) return true;
    }
    return false;
}

private boolean matchesAny(Set<String> rolePermissions, String requested) {
    for (var perm : rolePermissions) {
        if (perm.equals("*")) return true;
        if (perm.equals(requested)) return true;
        if (perm.endsWith(".*") && requested.startsWith(perm.substring(0, perm.length()-1))) return true;
    }
    return false;
}
```

### Explicit invalidation

When a role's permissions change, an internal `@ApplicationModuleListener` invalidates the cache:

```java
@ApplicationModuleListener
void onRolePermissionsChanged(RolePermissionsChangedEvent event) {
    rolePermissionCache.invalidate(event.roleId());
}
```

Permission changes take effect immediately on the local JVM. Multi-instance v1.1+ needs distributed invalidation (Redis pub-sub or DB-trigger-based).

### Sensitive operations bypass cache

Operations marked `@SensitivePermissionCheck` skip the cache and re-query DB:

- User role grant / revoke
- Tenant-level role modifications
- Critical financial operations (admin reversal)

Adds one DB hit on a low-frequency path; ensures these never run on stale permissions.

## Consequences

**Positive:**
- Authorization adds ~1µs per request (cache hit)
- Permission changes propagate within ms (local JVM)
- DB load on `roles` table minimal
- Cache stats exposed via Actuator for tuning

**Negative:**
- 5-minute maximum staleness on cache miss across instances (mitigated for sensitive ops)
- Multi-instance requires distributed invalidation v1.1+
- Memory cost: 10K roles × ~500 bytes = 5 MB (acceptable)

**Trade-off accepted:** 5-minute staleness is acceptable for non-sensitive operations. Sensitive ops have an opt-in bypass.

## Distributed invalidation (v1.1+)

When multi-instance is enabled:

```
Option A: Redis pub-sub
  - Permission change → publish "invalidate:role:<uuid>" → all instances subscribe
  - Requires Redis (currently not in stack)

Option B: PostgreSQL LISTEN/NOTIFY
  - Permission change → trigger → NOTIFY channel → instances listening
  - No new infrastructure
  - Recommended approach

Option C: Database-backed cache with version column
  - Cache stores (permissions, version) per role
  - Every cache hit also reads version (fast lookup-only query)
  - Stale → reload
  - One extra DB hit per request but very cheap
```

Decision deferred to multi-instance time. Option B (LISTEN/NOTIFY) is the current preference because no new infrastructure is needed.
