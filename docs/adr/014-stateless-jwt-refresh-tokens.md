# ADR-014: Stateless JWT with DB-backed Refresh Tokens

**Status:** Accepted
**Date:** 2026-05-16
**Phase:** 6.D

## Context

Authentication tokens have two competing requirements:

1. **Performance**: every API request validates the token. DB-backed sessions add a DB round-trip per request.
2. **Revocation**: admin must be able to force a user offline (compromised credentials, fired employee, suspicious activity).

A purely stateless JWT model offers performance but no revocation. A purely stateful session model offers revocation but no performance.

## Decision

A two-token model:

| Token | Lifetime | Validation | Revocable |
|---|---|---|---|
| **Access token** | 15 minutes | HMAC-SHA256 only (no DB hit) | No (waits for expiry) |
| **Refresh token** | 7 days | DB lookup via `user_sessions` table | Yes (immediate) |

Both are stateless JWTs (HS256). The difference is operational:

- Access token: high-frequency, performance-critical, accepts 15-min revocation latency
- Refresh token: low-frequency (once per access token cycle), can afford DB lookup

### Access token claims

```json
{
  "sub": "user_uuid",
  "tid": "tenant_uuid",
  "tcd": "tenant_code",
  "rol": ["STORE_MANAGER", "CASHIER"],
  "stp": ["store_uuid_1", "store_uuid_2"],
  "ssn": "session_uuid",
  "iat": 1715800000,
  "exp": 1715800900,
  "iss": "stockapp",
  "aud": "stockapp-api"
}
```

Roles and store scope are embedded. Permissions are **not** embedded — they change too frequently and would inflate the token.

### Refresh token claims

```json
{
  "sub": "user_uuid",
  "tid": "tenant_uuid",
  "ssn": "session_uuid",
  "jti": "uuid_v4",
  "typ": "refresh",
  "iat": 1715800000,
  "exp": 1716404800
}
```

The `jti` claim is the primary key of the `user_sessions` row. Refresh validation:

```
1. JWT signature valid?
2. SELECT * FROM user_sessions WHERE refresh_token_jti = $jti
3. revoked_at IS NULL AND expires_at > now()?
4. HMAC-SHA256(token, pepper) == row.refresh_token_hash? (constant-time)
5. Issue new access token + refresh token; rotate jti; update last_used_at
```

### user_sessions table

Added in migration 016 (post-Phase 2E):

```sql
CREATE TABLE user_sessions (
    id, tenant_id, user_id,
    refresh_token_jti UNIQUE,
    refresh_token_hash,        -- HMAC-SHA256(token, pepper)
    created_at, expires_at, last_used_at,
    revoked_at, revoked_reason,
    ip, user_agent, device_label
);
```

### Sensitive endpoints

Some endpoints (admin actions, password change, settings update) require fresh validation, not waiting for 15-min access token expiry. These are marked `@Sensitive`:

```java
@Sensitive
@PostMapping("/admin/users/{id}/force-logout")
public void forceLogout(@PathVariable UUID id) { ... }
```

A pre-handler interceptor checks `user_sessions.revoked_at` for the current session. One extra DB hit, only on these endpoints.

## Consequences

**Positive:**
- 99% of requests have zero DB hit for auth
- Force-logout works within 15 minutes (one access token cycle)
- Multi-device session listing and selective revocation supported
- Refresh tokens hashed with pepper, no offline brute force on DB leak

**Negative:**
- 15-minute revocation latency (acceptable trade-off)
- Two-token complexity vs single-token simple JWT
- `user_sessions` table grows; needs cleanup job (in scheduled jobs list)

## Cross-references

- Token hash strategy: ADR-015
- Permission caching: ADR-016
- Schema: `migrations/016_auth_extensions.sql`
