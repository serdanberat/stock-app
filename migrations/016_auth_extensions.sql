-- ============================================================================
-- Migration 016: Auth extensions (Phase 6.D)
-- ============================================================================
-- Adds:
--   - user_sessions: DB-backed refresh tokens with HMAC-SHA256 pepper hash
--   - password_reset_tokens: short-lived password recovery tokens
--   - users.password_changed_at: last password change timestamp
--   - users.mfa_*: MFA infrastructure (schema only, MVP disabled)
--
-- Related ADRs: ADR-014, ADR-015
-- ============================================================================

-- ----------------------------------------------------------------------------
-- user_sessions
-- ----------------------------------------------------------------------------

CREATE TABLE user_sessions (
    id                          UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    tenant_id                   UUID NOT NULL REFERENCES tenants(id) ON DELETE CASCADE,
    user_id                     UUID NOT NULL REFERENCES users(id) ON DELETE CASCADE,

    refresh_token_jti           UUID NOT NULL,
    refresh_token_hash          VARCHAR(64) NOT NULL,    -- HEX of HMAC-SHA256(token, pepper)

    created_at                  TIMESTAMPTZ NOT NULL DEFAULT now(),
    expires_at                  TIMESTAMPTZ NOT NULL,
    last_used_at                TIMESTAMPTZ NOT NULL DEFAULT now(),

    revoked_at                  TIMESTAMPTZ,
    revoked_reason              VARCHAR(50)
        CHECK (revoked_reason IS NULL OR revoked_reason IN (
            'LOGOUT', 'PASSWORD_CHANGED', 'ADMIN_FORCED', 'TOKEN_ROTATED',
            'SECURITY_INCIDENT', 'EXPIRED_CLEANUP'
        )),

    ip                          INET,
    user_agent                  TEXT,
    device_label                VARCHAR(100),

    CONSTRAINT user_sessions_jti_unique UNIQUE (refresh_token_jti),
    CONSTRAINT user_sessions_revoked_consistency CHECK (
        (revoked_at IS NULL AND revoked_reason IS NULL) OR
        (revoked_at IS NOT NULL AND revoked_reason IS NOT NULL)
    )
);

CREATE INDEX idx_user_sessions_user
    ON user_sessions(tenant_id, user_id)
    WHERE revoked_at IS NULL;

CREATE INDEX idx_user_sessions_expires
    ON user_sessions(expires_at)
    WHERE revoked_at IS NULL;

CREATE INDEX idx_user_sessions_jti_lookup
    ON user_sessions(refresh_token_jti);

ALTER TABLE user_sessions ENABLE ROW LEVEL SECURITY;

CREATE POLICY user_sessions_tenant_isolation ON user_sessions
    USING (tenant_id = current_tenant_id())
    WITH CHECK (tenant_id = current_tenant_id());

COMMENT ON TABLE user_sessions IS
    'Refresh token sessions. refresh_token_hash = HEX(HMAC-SHA256(token, server_pepper)). '
    'Pepper from env (TOKEN_PEPPER). DB exfiltration alone yields no valid tokens.';
COMMENT ON COLUMN user_sessions.refresh_token_jti IS
    'JWT jti claim; primary lookup key during refresh';
COMMENT ON COLUMN user_sessions.refresh_token_hash IS
    'HEX of HMAC-SHA256(plaintext_token, server_pepper). Constant-time compared via MessageDigest.isEqual';

-- ----------------------------------------------------------------------------
-- password_reset_tokens
-- ----------------------------------------------------------------------------

CREATE TABLE password_reset_tokens (
    id                          UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    tenant_id                   UUID NOT NULL REFERENCES tenants(id) ON DELETE CASCADE,
    user_id                     UUID NOT NULL REFERENCES users(id) ON DELETE CASCADE,

    token_hash                  VARCHAR(64) NOT NULL,    -- HEX of HMAC-SHA256(token, pepper)

    created_at                  TIMESTAMPTZ NOT NULL DEFAULT now(),
    expires_at                  TIMESTAMPTZ NOT NULL,
    used_at                     TIMESTAMPTZ,

    ip_requested                INET,

    CONSTRAINT password_reset_token_hash_unique UNIQUE (token_hash),
    CONSTRAINT password_reset_used_must_be_within_expiry
        CHECK (used_at IS NULL OR used_at <= expires_at)
);

CREATE INDEX idx_password_reset_user
    ON password_reset_tokens(tenant_id, user_id, created_at DESC);

CREATE INDEX idx_password_reset_expires
    ON password_reset_tokens(expires_at)
    WHERE used_at IS NULL;

ALTER TABLE password_reset_tokens ENABLE ROW LEVEL SECURITY;

CREATE POLICY password_reset_tokens_tenant_isolation ON password_reset_tokens
    USING (tenant_id = current_tenant_id())
    WITH CHECK (tenant_id = current_tenant_id());

COMMENT ON TABLE password_reset_tokens IS
    'Short-lived password reset tokens. Single-use. '
    'token_hash = HEX(HMAC-SHA256(token, server_pepper)).';

-- ----------------------------------------------------------------------------
-- users additions
-- ----------------------------------------------------------------------------

ALTER TABLE users
    ADD COLUMN password_changed_at TIMESTAMPTZ,
    ADD COLUMN mfa_enabled BOOLEAN NOT NULL DEFAULT false,
    ADD COLUMN mfa_secret_encrypted TEXT,                -- AES-256-GCM ciphertext
    ADD COLUMN mfa_enrolled_at TIMESTAMPTZ,
    ADD COLUMN mfa_backup_codes_hash TEXT[];             -- HMAC-hashed backup codes

ALTER TABLE users
    ADD CONSTRAINT users_mfa_consistency CHECK (
        (mfa_enabled = false AND mfa_secret_encrypted IS NULL AND mfa_enrolled_at IS NULL) OR
        (mfa_enabled = true  AND mfa_secret_encrypted IS NOT NULL AND mfa_enrolled_at IS NOT NULL)
    );

COMMENT ON COLUMN users.password_changed_at IS
    'Timestamp of last password change; used for force-logout-since checks';
COMMENT ON COLUMN users.mfa_secret_encrypted IS
    'AES-256-GCM ciphertext of TOTP secret. Key from env (MFA_ENCRYPTION_KEY). MVP disabled, schema ready.';
COMMENT ON COLUMN users.mfa_backup_codes_hash IS
    'HEX(HMAC-SHA256(code, pepper)) array. Each code consumed once.';

-- ----------------------------------------------------------------------------
-- Triggers (set_updated_at omitted — no updated_at columns here)
-- ----------------------------------------------------------------------------
