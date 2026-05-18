# Phase 6.D — Auth & Security

> **Status:** Locked
> **Phase:** 6.D
> **Related ADRs:** ADR-013, ADR-014, ADR-015, ADR-016

## Decisions

| Concern | Decision |
|---|---|
| Login form | Tenant code + email + password (MVP), subdomain v1.1+ |
| Tenant resolution | Tenant → User → Password verify; timing-attack-protected |
| Password hash | BCrypt cost=12 (MVP), Argon2id (v1.1+) |
| Token model | Stateless JWT HS256 |
| Access token | 15 minutes |
| Refresh token | 7 days |
| Token storage | Refresh token DB-backed (`user_sessions` table) |
| Token hash | HMAC-SHA256(token, server_pepper) |
| Constant-time compare | `MessageDigest.isEqual` |
| Access validation | DB-hit-free HMAC (15 min max exposure) |
| Sensitive endpoints | `@Sensitive` annotation → fresh DB check |
| Authorization | JWT carries roles + store scope; permissions resolved via Caffeine cache |
| Permission cache TTL | 5 min, explicit invalidation on changes |
| Permission match | Wildcard (`sales.*`) |
| Session listing | `GET /auth/sessions`, `DELETE /auth/sessions/{id}` |
| Force logout (admin) | Revoke all user_sessions; 15 min max delay |
| Password change | Revoke other sessions, keep current |
| Password reset | `password_reset_tokens` table, HMAC-hashed, 1h TTL |
| Password policy | Min 10 char, 3-of-4 complexity, no forced periodic change |
| MFA | Schema ready (TOTP); active v1.1+ |
| MFA encryption | AES-256-GCM, key from env (MVP), secret manager (v1.1+) |
| Rate limiting | Bucket4j in-memory (MVP), PostgreSQL bridge (v1.1+) |
| Login throttle | 10/IP/5min, 5/email/15min, 100/tenant/1min |
| Brute force detection | SQL query + admin email (MVP), auto-lock v1.1+ |
| CORS | Explicit allowed-origins, **allow-credentials: false** |
| CSRF | Disabled (JWT-only) |
| Security headers | HSTS, X-Frame-Options DENY, X-Content-Type-Options, Referrer-Policy, Permissions-Policy |
| Secrets | Env vars (MVP), Vault (v1.1+) |
| JWT secret rotation | Current + Previous overlap, manual MVP |
| Log masking | Passwords, tokens, MFA codes, card numbers |

## Schema additions

Migration 016 (post-Phase 2E):

```sql
-- user_sessions
CREATE TABLE user_sessions (
    id UUID PRIMARY KEY, tenant_id UUID, user_id UUID,
    refresh_token_jti UUID UNIQUE,
    refresh_token_hash VARCHAR(64),  -- HMAC-SHA256
    created_at, expires_at, last_used_at TIMESTAMPTZ,
    revoked_at TIMESTAMPTZ, revoked_reason VARCHAR(50),
    ip INET, user_agent TEXT, device_label VARCHAR(100)
);

-- password_reset_tokens
CREATE TABLE password_reset_tokens (
    id UUID PRIMARY KEY, tenant_id UUID, user_id UUID,
    token_hash VARCHAR(64),  -- HMAC-SHA256
    expires_at, used_at TIMESTAMPTZ,
    ip_requested INET
);

-- users additions
ALTER TABLE users ADD COLUMN password_changed_at TIMESTAMPTZ;
ALTER TABLE users ADD COLUMN mfa_enabled BOOLEAN NOT NULL DEFAULT false;
ALTER TABLE users ADD COLUMN mfa_secret_encrypted TEXT;
ALTER TABLE users ADD COLUMN mfa_enrolled_at TIMESTAMPTZ;
ALTER TABLE users ADD COLUMN mfa_backup_codes_hash TEXT[];
```

## Login flow

```
POST /api/v1/auth/login
{ tenant_code, email, password }
  │
  ▼
1. SELECT id FROM tenants WHERE code = $1 AND status IN ('TRIAL','ACTIVE')
   ⊥→ run BCrypt dummy compare, return 401 with generic message
  │
  ▼
2. SELECT * FROM users WHERE tenant_id = $tid AND email = $email AND status = 'ACTIVE'
   ⊥→ run BCrypt dummy compare, return 401
  │
  ▼
3. BCrypt.verify(password, password_hash)
   ⊥→ log to security_audit_log, return 401
  │
  ▼ (success)
4. INSERT user_sessions (jti, hash=HMAC(refresh_token, pepper), expires_at = now + 7d, ip, ua)
5. Issue access_token (15 min), return both tokens
```

All failure paths have identical timing (BCrypt dummy compare on miss) and identical error message.

## Token validation flow

```
Each API request:
  Authorization: Bearer <access_token>
  │
  ▼
JwtAuthenticationFilter:
  1. Verify HMAC signature with current secret (fallback to previous)
  2. Check exp claim
  3. Build StockAppPrincipal from claims
  4. SecurityContextHolder.setAuthentication(...)
  
No DB hit.

Refresh:
POST /auth/refresh { refresh_token }
  │
  ▼
1. Verify HMAC signature
2. Extract jti, sub, tid
3. SELECT * FROM user_sessions WHERE refresh_token_jti = $jti
4. Check revoked_at IS NULL AND expires_at > now()
5. MessageDigest.isEqual(HMAC(refresh_token, pepper), stored_hash)
6. Issue new access_token + rotate jti in user_sessions
```

## Spring Security config (skeleton)

```java
@Configuration
@EnableWebSecurity
@EnableMethodSecurity
public class SecurityConfig {

    @Bean
    public SecurityFilterChain apiFilterChain(HttpSecurity http) throws Exception {
        return http
            .securityMatcher("/api/**")
            .authorizeHttpRequests(auth -> auth
                .requestMatchers("/api/v1/auth/**").permitAll()
                .requestMatchers("/api/v1/health").permitAll()
                .anyRequest().authenticated()
            )
            .sessionManagement(s -> s.sessionCreationPolicy(SessionCreationPolicy.STATELESS))
            .csrf(AbstractHttpConfigurer::disable)
            .cors(Customizer.withDefaults())
            .addFilterBefore(jwtAuthenticationFilter, UsernamePasswordAuthenticationFilter.class)
            .addFilterAfter(mdcContextFilter, JwtAuthenticationFilter.class)
            .exceptionHandling(ex -> ex
                .authenticationEntryPoint(jwtAuthEntryPoint)
                .accessDeniedHandler(forbiddenHandler)
            )
            .build();
    }

    @Bean
    @Order(1)
    public SecurityFilterChain actuatorFilterChain(HttpSecurity http) throws Exception {
        return http
            .securityMatcher("/actuator/**")
            .authorizeHttpRequests(auth -> auth
                .requestMatchers("/actuator/health/liveness", "/actuator/health/readiness").permitAll()
                .anyRequest().hasAuthority("ROLE_ACTUATOR")
            )
            .httpBasic(Customizer.withDefaults())
            .csrf(AbstractHttpConfigurer::disable)
            .build();
    }

    @Bean
    public PasswordEncoder passwordEncoder() {
        var encoders = Map.of(
            "bcrypt", new BCryptPasswordEncoder(12)
            // "argon2", new Argon2PasswordEncoder(...) — v1.1+
        );
        return new DelegatingPasswordEncoder("bcrypt", encoders);
    }
}
```

## CORS (MVP)

```yaml
stockapp.security.cors:
  allowed-origins:
    - https://app.stockapp.com.tr     # production
    - http://localhost:5173            # local dev
  allowed-methods: [GET, POST, PUT, PATCH, DELETE, OPTIONS]
  allowed-headers: [Authorization, Content-Type, X-Idempotency-Key]
  exposed-headers: [X-Total-Count, X-Trace-Id, Retry-After]
  allow-credentials: false             # JWT-only
  max-age: 3600
```

## Rate limiting

```java
@Component
class LoginRateLimiter {
    private final Cache<String, Bucket> ipBuckets = Caffeine.newBuilder()
        .expireAfterAccess(10, TimeUnit.MINUTES).build();
    private final Cache<String, Bucket> emailBuckets = Caffeine.newBuilder()
        .expireAfterAccess(30, TimeUnit.MINUTES).build();

    public void checkAndConsume(String ip, String email) {
        if (!ipBucket(ip).tryConsume(1)) {
            throw new RateLimitedException("ip");
        }
        if (!emailBucket(email).tryConsume(1)) {
            throw new RateLimitedException("email");
        }
    }

    private Bucket ipBucket(String ip) {
        return ipBuckets.get(ip, k -> Bucket.builder()
            .addLimit(Bandwidth.classic(10, Refill.intervally(10, Duration.ofMinutes(5))))
            .build());
    }
    // ...
}
```

## Cross-references

- ADR-013 (tenant resolution)
- ADR-014 (JWT + refresh tokens)
- ADR-015 (HMAC token hashing)
- ADR-016 (permission caching)
- Tenant flow: `docs/architecture/tenant-context-flow.md`
