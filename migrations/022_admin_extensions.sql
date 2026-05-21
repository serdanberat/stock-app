-- ============================================================================
-- 022_admin_extensions.sql
-- Phase 3.E — Operational / Admin
--
-- Adds:
--   - cash_register_sessions enhancements (partial UNIQUE, force-close fields)
--   - z_reports table (immutable snapshot)
--   - cash_register_variance_log
--   - audit_event_log enhancements (GIN payload index, correlation_id index)
--   - tenant_settings_change_log
-- ============================================================================

BEGIN;

-- ---------------------------------------------------------------------------
-- 1. cash_register_sessions: force-close fields + partial UNIQUE invariant
-- ---------------------------------------------------------------------------

ALTER TABLE cash_register_sessions
    ADD COLUMN IF NOT EXISTS force_closed BOOLEAN NOT NULL DEFAULT FALSE,
    ADD COLUMN IF NOT EXISTS force_close_reconciliation_note TEXT,
    ADD COLUMN IF NOT EXISTS force_close_counted_cash NUMERIC(14, 2),
    ADD COLUMN IF NOT EXISTS force_close_reason VARCHAR(40),
    ADD COLUMN IF NOT EXISTS force_closed_by UUID REFERENCES users(id),
    ADD COLUMN IF NOT EXISTS force_closed_at TIMESTAMPTZ,
    ADD COLUMN IF NOT EXISTS correlation_id UUID;

-- Backfill correlation_id = id for existing rows
UPDATE cash_register_sessions SET correlation_id = id WHERE correlation_id IS NULL;
ALTER TABLE cash_register_sessions ALTER COLUMN correlation_id SET NOT NULL;

CREATE INDEX IF NOT EXISTS idx_cash_register_sessions_correlation_id
    ON cash_register_sessions(tenant_id, correlation_id);

-- Force-close reconciliation note minimum length when force-closed
ALTER TABLE cash_register_sessions
    DROP CONSTRAINT IF EXISTS cash_session_force_close_requires_note;

ALTER TABLE cash_register_sessions
    ADD CONSTRAINT cash_session_force_close_requires_note CHECK (
        force_closed = FALSE OR (
            force_close_reconciliation_note IS NOT NULL AND
            char_length(force_close_reconciliation_note) >= 20 AND
            force_close_counted_cash IS NOT NULL AND
            force_close_reason IS NOT NULL AND
            force_closed_by IS NOT NULL AND
            force_closed_at IS NOT NULL
        )
    );

-- Partial UNIQUE: one OPEN session per (tenant, store, register)
-- Drop existing UNIQUE if present (was on different columns or none)
DROP INDEX IF EXISTS uq_cash_register_sessions_open;

CREATE UNIQUE INDEX uq_cash_register_sessions_open
    ON cash_register_sessions (tenant_id, store_id, register_id)
    WHERE status = 'OPEN';

COMMENT ON INDEX uq_cash_register_sessions_open IS
    'Per 3.E.1 invariant: one OPEN session per (store, register) at any time. '
    'NOT per user — supports shift handover.';

-- ---------------------------------------------------------------------------
-- 2. z_reports table (immutable snapshot)
-- ---------------------------------------------------------------------------

CREATE TABLE z_reports (
    id                      UUID PRIMARY KEY,
    tenant_id               UUID NOT NULL,
    cash_register_session_id UUID NOT NULL REFERENCES cash_register_sessions(id),
    snapshot_payload        JSONB NOT NULL,
                            -- immutable; full tender breakdown, variance, totals
    pdf_storage_key         VARCHAR(256),
                            -- key in DocumentStorage (Phase 6.F); null until worker generates
    generation_status       VARCHAR(20) NOT NULL DEFAULT 'PENDING'
                            CHECK (generation_status IN ('PENDING', 'GENERATED', 'FAILED')),
    generation_attempts     INT NOT NULL DEFAULT 0,
    last_generation_error   TEXT,
    correlation_id          UUID NOT NULL,
                            -- per ADR-020; = cash_register_session_id
    generated_at            TIMESTAMPTZ,
    created_at              TIMESTAMPTZ NOT NULL DEFAULT now(),

    -- One z_report per session
    UNIQUE (tenant_id, cash_register_session_id)
);

ALTER TABLE z_reports ENABLE ROW LEVEL SECURITY;
CREATE POLICY z_reports_tenant_isolation ON z_reports
    USING (tenant_id = current_setting('app.tenant_id')::uuid);

CREATE INDEX idx_z_reports_session ON z_reports(tenant_id, cash_register_session_id);
CREATE INDEX idx_z_reports_generation_status ON z_reports(tenant_id, generation_status);
CREATE INDEX idx_z_reports_correlation_id ON z_reports(tenant_id, correlation_id);

COMMENT ON TABLE z_reports IS
    'Immutable Z report snapshot per 3.E.2. snapshot_payload is set once and '
    'never updated. Reprint renders this stored payload — does NOT regenerate '
    'from current data.';

COMMENT ON COLUMN z_reports.snapshot_payload IS
    'Frozen at session close: tender_breakdown, expected_cash, counted_cash, '
    'variance, variance_reason, sale_count, refund_count, etc. JSONB schema '
    'validated server-side.';

-- snapshot_payload immutability: trigger prevents UPDATE of this column
CREATE OR REPLACE FUNCTION prevent_z_report_payload_mutation()
RETURNS TRIGGER AS $$
BEGIN
    IF OLD.snapshot_payload IS DISTINCT FROM NEW.snapshot_payload THEN
        RAISE EXCEPTION 'z_reports.snapshot_payload is immutable';
    END IF;
    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER trg_z_reports_payload_immutable
    BEFORE UPDATE ON z_reports
    FOR EACH ROW EXECUTE FUNCTION prevent_z_report_payload_mutation();

-- ---------------------------------------------------------------------------
-- 3. cash_register_variance_log
-- ---------------------------------------------------------------------------

CREATE TABLE cash_register_variance_log (
    id                      UUID PRIMARY KEY,
    tenant_id               UUID NOT NULL,
    cash_register_session_id UUID NOT NULL REFERENCES cash_register_sessions(id),
    variance_amount         NUMERIC(14, 2) NOT NULL,
                            -- signed: + = OVER, - = SHORT
    variance_reason         VARCHAR(40) NOT NULL CHECK (variance_reason IN (
                                'SHORT_CASHIER_ERROR',
                                'SHORT_UNKNOWN',
                                'OVER_CASHIER_ERROR',
                                'OVER_UNKNOWN',
                                'MISCOUNT',
                                'SUSPECTED_THEFT'
                            )),
    variance_note           TEXT,
    is_large_variance       BOOLEAN NOT NULL DEFAULT FALSE,
                            -- exceeded tenant.cash_variance_large_threshold
    manager_override_token  UUID,
                            -- present when is_large_variance = true
    correlation_id          UUID NOT NULL,
    created_by              UUID NOT NULL REFERENCES users(id),
    created_at              TIMESTAMPTZ NOT NULL DEFAULT now(),

    CONSTRAINT variance_log_suspected_theft_requires_note CHECK (
        variance_reason != 'SUSPECTED_THEFT' OR (
            variance_note IS NOT NULL AND char_length(variance_note) >= 10
        )
    ),

    CONSTRAINT variance_log_large_requires_override CHECK (
        is_large_variance = FALSE OR manager_override_token IS NOT NULL
    )
);

ALTER TABLE cash_register_variance_log ENABLE ROW LEVEL SECURITY;
CREATE POLICY cash_register_variance_log_tenant_isolation ON cash_register_variance_log
    USING (tenant_id = current_setting('app.tenant_id')::uuid);

CREATE INDEX idx_variance_log_session ON cash_register_variance_log(tenant_id, cash_register_session_id);
CREATE INDEX idx_variance_log_correlation_id ON cash_register_variance_log(tenant_id, correlation_id);

-- Append-only
CREATE TRIGGER trg_variance_log_prevent_mutation
    BEFORE UPDATE OR DELETE ON cash_register_variance_log
    FOR EACH ROW EXECUTE FUNCTION prevent_audit_mutation();

-- ---------------------------------------------------------------------------
-- 4. audit_event_log enhancements
-- ---------------------------------------------------------------------------

-- correlation_id index (already present if Phase 2D shipped it; ensure)
CREATE INDEX IF NOT EXISTS idx_audit_event_log_correlation_id
    ON audit_event_log(tenant_id, correlation_id);

-- GIN index for free-text search on payload
CREATE INDEX IF NOT EXISTS idx_audit_event_log_payload_gin
    ON audit_event_log USING gin (payload jsonb_path_ops);

-- occurred_at index for date range queries
CREATE INDEX IF NOT EXISTS idx_audit_event_log_occurred_at
    ON audit_event_log(tenant_id, occurred_at DESC);

-- actor + tenant index
CREATE INDEX IF NOT EXISTS idx_audit_event_log_actor
    ON audit_event_log(tenant_id, actor_user_id);

-- event_type + tenant index
CREATE INDEX IF NOT EXISTS idx_audit_event_log_event_type
    ON audit_event_log(tenant_id, event_type);

-- ---------------------------------------------------------------------------
-- 5. tenant_settings_change_log
-- ---------------------------------------------------------------------------

CREATE TABLE tenant_settings_change_log (
    id                          UUID PRIMARY KEY,
    tenant_id                   UUID NOT NULL,
    setting_key                 VARCHAR(80) NOT NULL,
    old_value                   JSONB,
    new_value                   JSONB NOT NULL,
    is_dangerous_flag           BOOLEAN NOT NULL DEFAULT FALSE,
    confirmation_phrase_typed   TEXT,
                                -- when dangerous, the typed confirmation
    changed_by                  UUID NOT NULL REFERENCES users(id),
    changed_at                  TIMESTAMPTZ NOT NULL DEFAULT now(),

    -- Dangerous flag requires typed confirmation
    CONSTRAINT tenant_settings_dangerous_requires_phrase CHECK (
        is_dangerous_flag = FALSE OR (
            confirmation_phrase_typed IS NOT NULL AND
            char_length(confirmation_phrase_typed) >= 5
        )
    )
);

ALTER TABLE tenant_settings_change_log ENABLE ROW LEVEL SECURITY;
CREATE POLICY tenant_settings_change_log_tenant_isolation ON tenant_settings_change_log
    USING (tenant_id = current_setting('app.tenant_id')::uuid);

CREATE INDEX idx_tenant_settings_change_log_key ON tenant_settings_change_log(tenant_id, setting_key);
CREATE INDEX idx_tenant_settings_change_log_changed_at ON tenant_settings_change_log(tenant_id, changed_at DESC);
CREATE INDEX idx_tenant_settings_change_log_dangerous ON tenant_settings_change_log(tenant_id, is_dangerous_flag) WHERE is_dangerous_flag = TRUE;

-- Append-only
CREATE TRIGGER trg_tenant_settings_change_log_prevent_mutation
    BEFORE UPDATE OR DELETE ON tenant_settings_change_log
    FOR EACH ROW EXECUTE FUNCTION prevent_audit_mutation();

COMMENT ON TABLE tenant_settings_change_log IS
    'History of tenant settings changes per 3.E.4. Dangerous flags require '
    'typed confirmation phrase stored here for audit.';

-- ---------------------------------------------------------------------------
-- 6. user_password_reset_log (audit-grade reset history)
-- ---------------------------------------------------------------------------

CREATE TABLE user_password_reset_log (
    id                      UUID PRIMARY KEY,
    tenant_id               UUID NOT NULL,
    target_user_id          UUID NOT NULL REFERENCES users(id),
    reset_type              VARCHAR(40) NOT NULL CHECK (reset_type IN (
                                'PASSWORD_RESET',
                                'MANAGER_PIN_RESET'
                            )),
    initiated_by            UUID NOT NULL REFERENCES users(id),
    initiated_at            TIMESTAMPTZ NOT NULL DEFAULT now(),
    note                    TEXT
);

ALTER TABLE user_password_reset_log ENABLE ROW LEVEL SECURITY;
CREATE POLICY user_password_reset_log_tenant_isolation ON user_password_reset_log
    USING (tenant_id = current_setting('app.tenant_id')::uuid);

CREATE INDEX idx_user_password_reset_log_target ON user_password_reset_log(tenant_id, target_user_id);
CREATE INDEX idx_user_password_reset_log_initiator ON user_password_reset_log(tenant_id, initiated_by);

CREATE TRIGGER trg_user_password_reset_log_prevent_mutation
    BEFORE UPDATE OR DELETE ON user_password_reset_log
    FOR EACH ROW EXECUTE FUNCTION prevent_audit_mutation();

-- ---------------------------------------------------------------------------
-- 7. Last SUPER_ADMIN deactivation guard (DB-level safety net)
-- ---------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION prevent_last_super_admin_deactivation()
RETURNS TRIGGER AS $$
DECLARE
    super_admin_count INT;
BEGIN
    IF NEW.is_active = FALSE AND OLD.is_active = TRUE THEN
        -- Check if target user has SUPER_ADMIN role
        IF EXISTS (
            SELECT 1 FROM user_role_assignments ura
            JOIN roles r ON r.id = ura.role_id
            WHERE ura.user_id = NEW.id
              AND r.code = 'SUPER_ADMIN'
              AND ura.tenant_id = NEW.tenant_id
        ) THEN
            -- Count remaining active SUPER_ADMINs
            SELECT COUNT(DISTINCT u.id) INTO super_admin_count
            FROM users u
            JOIN user_role_assignments ura ON ura.user_id = u.id
            JOIN roles r ON r.id = ura.role_id
            WHERE u.tenant_id = NEW.tenant_id
              AND u.is_active = TRUE
              AND u.id != NEW.id
              AND r.code = 'SUPER_ADMIN';

            IF super_admin_count = 0 THEN
                RAISE EXCEPTION 'Cannot deactivate the last active SUPER_ADMIN for tenant %', NEW.tenant_id
                    USING ERRCODE = 'P0001';
            END IF;
        END IF;
    END IF;
    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

DROP TRIGGER IF EXISTS trg_users_prevent_last_super_admin ON users;
CREATE TRIGGER trg_users_prevent_last_super_admin
    BEFORE UPDATE ON users
    FOR EACH ROW EXECUTE FUNCTION prevent_last_super_admin_deactivation();

COMMENT ON FUNCTION prevent_last_super_admin_deactivation IS
    'Per 3.E.3 invariant: at least one active SUPER_ADMIN must exist per tenant. '
    'Application enforces in service layer; this trigger is a DB-level safety net.';

COMMIT;
