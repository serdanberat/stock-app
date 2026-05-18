# ADR-015: Token Hashing with HMAC-SHA256 Pepper

**Status:** Accepted
**Date:** 2026-05-16
**Phase:** 6.D

## Context

Refresh tokens and password reset tokens are stored in the database. If the database is exfiltrated (SQL injection, backup leak, read-only replica compromise), plain SHA-256 hashes are vulnerable to offline brute force:

```
Attacker has user_sessions.refresh_token_hash = SHA256(plaintext)
↓
Brute-force candidate tokens (UUIDs, base64 strings)
↓
Compare SHA256(candidate) → on match, attacker holds a valid refresh token
↓
At GPU speeds, exhausting candidate spaces is feasible
```

The attack scenario assumes: attacker has DB access but not application secrets. This is realistic — DB and app secrets are usually stored separately (different services, different access controls).

## Decision

All persisted token hashes use keyed hashing (HMAC-SHA256) with a server-side pepper:

```
stored_hash = HMAC-SHA256(plaintext_token, server_pepper)
```

The `server_pepper` is at least 32 bytes, randomly generated, stored as environment variable, never persisted in the database.

### Applies to

| Token type | Storage location | Pepper source |
|---|---|---|
| Refresh token | `user_sessions.refresh_token_hash` | `TOKEN_PEPPER` env |
| Password reset token | `password_reset_tokens.token_hash` | `TOKEN_PEPPER` env |

### Implementation

```java
@Component
public class TokenHasher {
    private final byte[] serverPepper;

    public TokenHasher(@Value("${stockapp.security.token-pepper}") String pepperBase64) {
        this.serverPepper = Base64.getDecoder().decode(pepperBase64);
        if (serverPepper.length < 32) {
            throw new IllegalStateException("token-pepper must be at least 32 bytes");
        }
    }

    public String hash(String token) {
        try {
            var mac = Mac.getInstance("HmacSHA256");
            mac.init(new SecretKeySpec(serverPepper, "HmacSHA256"));
            return HexFormat.of().formatHex(mac.doFinal(token.getBytes(UTF_8)));
        } catch (Exception e) {
            throw new IllegalStateException("HMAC failure", e);
        }
    }
}
```

### Constant-time comparison

Hash comparison must use `MessageDigest.isEqual(...)`:

```java
return MessageDigest.isEqual(
    computed.getBytes(UTF_8),
    stored.getBytes(UTF_8)
);
```

`String.equals` is timing-vulnerable.

## Pepper rotation strategy

**MVP:** Single pepper, no rotation. Compromise scenario triggers force-logout-all-users (manual operational response).

**v1.1+:** Versioned peppers (`v1:hex(...)`, `v2:hex(...)`). Validation tries current version first, falls back to previous. Old version retired after all sessions naturally refresh.

## Consequences

**Positive:**
- DB exfiltration alone does not yield valid tokens
- Brute force requires both DB and app secrets — significant attack escalation
- No infrastructure change vs simpler hashing
- Same pattern reusable for any future tokens (API keys, invite codes)

**Negative:**
- Pepper compromise requires session invalidation (manual MVP)
- One more secret to manage at deploy time
- HMAC slightly slower than SHA256 (negligible: ~1µs per hash)

## Why not bcrypt/argon2 for token hashes?

Slow hashes (bcrypt, Argon2id) are designed for low-entropy inputs (passwords). Tokens are high-entropy (UUID v4 = 122 random bits). A fast keyed hash is appropriate — speed is not the vulnerability, lack of a secret key is.

## Why not encrypt instead of hash?

Encryption is reversible. We do not need to recover plaintext tokens; we only need to verify a presented token matches a stored fingerprint. Hashing is the correct primitive.
