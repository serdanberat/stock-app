# Module: identity

> **Status:** Locked (Phase 4)
> **Bounded context:** Identity & Access + Tenant Management

## Position in dependency graph

Root module. Depends on nothing else. Every other module depends on identity (Q only).

## Aggregate roots

| Aggregate | Phase 2B ref | Lifecycle |
|---|---|---|
| `Tenant` | §2.B.1 | CREATED → ACTIVE → SUSPENDED (admin action) |
| `User` | §2.B.2 | CREATED → ACTIVE → DEACTIVATED (soft) |
| `Role` | §2.B.3 | STATIC — seeded; not mutable post-MVP |
| `Store` | §2.B.4 | CREATED → ACTIVE → CLOSED (soft) |
| `Session` | §2.B.5 | Session lifecycle: ACTIVE → EXPIRED |

Tenant lives in `identity.tenant` sub-package (not a separate module per Phase 4 lean scope).

## Package structure

```
io.stockapp.identity/
├── api/
│   ├── AuthController.java                 # /auth/login, /auth/refresh
│   ├── UserAdminController.java            # /admin/users/*
│   ├── TenantAdminController.java          # /admin/settings/*
│   └── dto/
├── application/
│   ├── command/
│   │   ├── AuthCommandService.java         # login, refresh, logout
│   │   ├── UserCommandService.java         # create, deactivate, role assign
│   │   └── TenantCommandService.java       # settings update
│   └── query/
│       ├── UserQueryService.java           # who is current user, permissions
│       ├── TenantQueryService.java         # tenant config, settings snapshot
│       └── StoreQueryService.java          # user's accessible stores
├── domain/
│   ├── tenant/
│   │   ├── Tenant.java
│   │   ├── TenantSettings.java
│   │   └── TenantRepository.java
│   ├── user/
│   │   ├── User.java
│   │   ├── ManagerPin.java                 # value object (BCrypt hash)
│   │   ├── UserRoleAssignment.java
│   │   ├── UserStoreAssignment.java
│   │   └── UserRepository.java
│   ├── role/
│   │   ├── Role.java
│   │   ├── Permission.java                 # enum
│   │   └── RoleRepository.java
│   ├── store/
│   │   ├── Store.java
│   │   └── StoreRepository.java
│   ├── session/
│   │   ├── Session.java
│   │   └── SessionRepository.java
│   └── event/
│       ├── UserDeactivatedEvent.java
│       ├── UserRoleChangedEvent.java
│       └── ManagerPinResetEvent.java
└── infrastructure/
    ├── persistence/                        # JPA entities + JOOQ projections
    ├── security/
    │   ├── BCryptPasswordEncoder.java
    │   ├── JwtTokenIssuer.java
    │   ├── CredentialHasher.java           # shared for password + manager PIN
    │   └── TenantContextFilter.java        # extracts tenant from JWT, sets RLS
    └── client/
        └── EmailClient.java                # password reset emails (via outbox)
```

## Transaction ownership

| Operation | Boundary | Propagation |
|---|---|---|
| `AuthCommandService.login()` | REQUIRED | New TX; emits SessionStartedEvent |
| `UserCommandService.create()` | REQUIRED | New TX; outbox UserCreatedEvent |
| `UserCommandService.deactivate()` | REQUIRED | New TX; checks last-SUPER_ADMIN guard at DB trigger |
| `UserCommandService.resetManagerPin()` | REQUIRED | Audit event ManagerPinForceResetEvent |
| `TenantCommandService.updateSettings()` | REQUIRED | Validates JSONB schema; emits TenantSettingChangedEvent |

All write operations use `TenantAwareTransactionManager` (Phase 6.B) which sets `SET LOCAL app.tenant_id` before TX body.

## Outbox events emitted

| Event | When | Consumers |
|---|---|---|
| `UserCreatedEvent` | User created | (none MVP; reserved for v1.1+ welcome email) |
| `UserDeactivatedEvent` | User deactivated | (none MVP) |
| `UserRoleChangedEvent` | Role assigned/removed | (none MVP; reserved for cache invalidation v1.1+) |
| `ManagerPinForceResetEvent` | Admin PIN reset | reporting (audit log surface) |
| `TenantSettingChangedEvent` | Settings updated | reporting |
| `DangerousFlagToggledEvent` | Dangerous flag changed | reporting (separate event for SIEM filtering) |
| `SessionStartedEvent` | Login | reporting |

## Outbox events consumed

NONE. Identity is root; consumes nothing.

## ArchUnit rules (relevant from Kategori A)

- `identity_depends_on_nothing` — no outgoing dependencies to other modules

## Cache invalidation hooks

| Cache key | Invalidated by |
|---|---|
| `user-permissions:{tenant_id}:{user_id}` | UserRoleChangedEvent, UserDeactivatedEvent |
| `tenant-settings:{tenant_id}` | TenantSettingChangedEvent |
| `tenant-stores:{tenant_id}` | StoreCreatedEvent, StoreClosedEvent |

Cache layer: Caffeine (Phase 6.C). TTL 5min default; explicit eviction on listed events.

## Key invariants

1. **Tenant isolation via RLS** (ADR-007): every TX sets `SET LOCAL app.tenant_id` before any query. TenantAwareTransactionManager enforces; ArchUnit rule prevents bypass.

2. **Last SUPER_ADMIN deactivation forbidden** (3.E.3 + migration 022): DB trigger `prevent_last_super_admin_deactivation` is the safety net; service layer also checks for clearer error message.

3. **Manager PIN hash uses CredentialHasher shared with password** (3.A.4): single BCrypt cost factor (12), single pepper application path. Prevents accidental weaker PIN hashing.

4. **Session 15min refresh window** (3.E.3 3.F.3): role/permission changes effective at next token refresh. No force-logout MVP.

5. **Multi-role union semantics** (3.F.3): `effective_permissions = UNION(role_permissions)`. No deny rules MVP.

## Public API surface (callable from other modules)

Other modules import ONLY from `io.stockapp.identity.application.query`:

```java
public interface UserQueryService {
    CurrentUser getCurrentUser();
    Set<Permission> getEffectivePermissions(UserId userId);
    boolean hasPermission(UserId userId, String permissionCode);
}

public interface TenantQueryService {
    TenantSettings getCurrentTenantSettings();
    BigDecimal getOperationalSetting(String key, BigDecimal defaultValue);
    boolean isDangerousFlagEnabled(String key);
}

public interface StoreQueryService {
    List<Store> getAccessibleStores(UserId userId);
    boolean canUserAccessStore(UserId userId, StoreId storeId);
}
```

Internal services (`io.stockapp.identity.application.command.*`) are NOT exposed cross-module — only callable from identity's own controllers.
