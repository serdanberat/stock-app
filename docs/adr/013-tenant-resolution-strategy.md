# ADR-013: Tenant Resolution Strategy

**Status:** Accepted
**Date:** 2026-05-16
**Phase:** 6.D

## Context

The application is multi-tenant with thousands of potential tenants. Users belong to exactly one tenant. On login, the system must associate the user with their tenant.

Three resolution strategies were considered:

1. **Email globally unique across tenants** — simple UX, but breaks B2B SaaS (a person cannot be admin of multiple tenants)
2. **Subdomain-based** (`tenant-x.stockapp.com.tr/login`) — industry standard, but requires DNS setup, wildcard SSL, subdomain routing
3. **Form-based** (tenant code + email + password) — three-input form, single domain

## Decision

**MVP:** Form-based with tenant code + email + password.

```
POST /api/v1/auth/login
Body: { tenant_code, email, password }
```

Frontend remembers last used tenant code in `localStorage`.

**v1.1+:** Add subdomain support (`tenant-x.stockapp.com.tr`) while keeping form-based as fallback.

### Resolution order

```
1. tenant_code → SELECT id FROM tenants WHERE code = $1 AND status IN ('TRIAL','ACTIVE')
   - Not found → return 401 with generic message
2. (tenant_id, email) → SELECT * FROM users WHERE tenant_id = $1 AND email = $2 AND status = 'ACTIVE'
   - Not found → BCrypt dummy comparison (constant time), return 401
3. BCrypt.verify(password, password_hash)
   - Match → issue JWT
   - Mismatch → log to security_audit_log, return 401
```

All three failure paths return identical timing and identical error message. This prevents enumeration attacks ("does tenant X exist?" / "does user Y exist?").

## Email uniqueness

Email is unique **within a tenant**, not globally:

```sql
CREATE UNIQUE INDEX idx_users_tenant_email
    ON users(tenant_id, email)
    WHERE is_anonymized = false;
```

The same email can be used in different tenants (a consultant working for multiple stores).

## Consequences

**Positive:**
- B2B multi-tenant model supported
- No DNS/SSL setup overhead in MVP
- Single deployable, single SSL certificate
- Schema already supports this via composite unique key

**Negative:**
- UX has three inputs instead of two
- Users must remember tenant code
- Frontend `localStorage` cache mitigates daily friction

**Mitigation for friction:**
- Tenant code is short (5-10 chars), human-friendly slug
- Frontend pre-fills last used tenant
- Magic link / SSO can hide the tenant input in v2

## Future state (v1.1+)

When wildcard SSL is configured:

```
tenant-x.stockapp.com.tr/login → tenant code resolved from subdomain
                                 user enters email + password only
app.stockapp.com.tr/login      → form-based fallback (tenant code + email + password)
```

Backend reads `Host` header; if it matches `<tenant_code>.stockapp.com.tr`, the tenant is pre-resolved before the login form is processed.
