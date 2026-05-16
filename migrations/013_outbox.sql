-- Migration 013_outbox.sql
-- Outbox + cross-cutting: outbox_events, outbox_global_sequences, processed_events,
-- audit_event_log, security_audit_log, process_instances

CREATE TABLE outbox_global_sequences (
  tenant_id                     UUID PRIMARY KEY REFERENCES tenants(id) ON DELETE RESTRICT,
  next_sequence                 BIGINT NOT NULL DEFAULT 1
);

ALTER TABLE outbox_global_sequences ENABLE ROW LEVEL SECURITY;
CREATE POLICY tenant_isolation_ogs ON outbox_global_sequences USING (tenant_id = current_tenant_id());


CREATE TABLE outbox_events (
  outbox_sequence               BIGSERIAL PRIMARY KEY,
  event_id                      UUID NOT NULL UNIQUE,

  tenant_id                     UUID NOT NULL REFERENCES tenants(id) ON DELETE RESTRICT,

  aggregate_type                VARCHAR(50) NOT NULL,
  aggregate_id                  UUID NOT NULL,
  aggregate_version             BIGINT,
  aggregate_sequence            BIGINT,
  global_sequence               BIGINT,

  event_type                    VARCHAR(100) NOT NULL,
  event_version                 INT NOT NULL DEFAULT 1,
  CONSTRAINT chk_oe_event_version CHECK (event_version >= 1),

  partition_key                 VARCHAR(255) NOT NULL,

  payload                       JSONB NOT NULL,
  metadata                      JSONB NOT NULL DEFAULT '{}'::jsonb,

  occurred_at                   TIMESTAMPTZ NOT NULL DEFAULT now(),
  recorded_at                   TIMESTAMPTZ NOT NULL DEFAULT now(),

  status                        VARCHAR(20) NOT NULL DEFAULT 'PENDING',
  CONSTRAINT chk_oe_status CHECK (status IN ('PENDING','PUBLISHED','FAILED','DEAD_LETTER')),

  published_at                  TIMESTAMPTZ,
  publish_attempts              INT NOT NULL DEFAULT 0,
  last_attempt_at               TIMESTAMPTZ,
  last_error                    TEXT,

  dead_letter_at                TIMESTAMPTZ,
  dead_letter_reason            VARCHAR(50),
  CONSTRAINT chk_oe_dlq_reason CHECK (dead_letter_reason IS NULL OR dead_letter_reason IN (
    'MAX_ATTEMPTS_EXCEEDED','SCHEMA_MISMATCH','POISON_EVENT',
    'CONSUMER_PERMANENT_FAILURE','MANUAL_DLQ','TENANT_ARCHIVED'
  )),
  CONSTRAINT chk_oe_dlq_consistency CHECK (
    (status = 'DEAD_LETTER' AND dead_letter_at IS NOT NULL AND dead_letter_reason IS NOT NULL)
    OR (status != 'DEAD_LETTER' AND dead_letter_at IS NULL)
  )
);

CREATE INDEX idx_outbox_pending ON outbox_events(recorded_at)
  WHERE status = 'PENDING';
CREATE INDEX idx_outbox_failed_retry ON outbox_events(last_attempt_at)
  WHERE status = 'FAILED';
CREATE INDEX idx_outbox_dlq ON outbox_events(tenant_id, dead_letter_at DESC)
  WHERE status = 'DEAD_LETTER';
CREATE INDEX idx_outbox_aggregate ON outbox_events(aggregate_type, aggregate_id, recorded_at DESC);
CREATE INDEX idx_outbox_tenant_time ON outbox_events(tenant_id, recorded_at DESC);
CREATE INDEX idx_outbox_event_type ON outbox_events(event_type, recorded_at DESC);
CREATE INDEX idx_outbox_partition_key ON outbox_events(partition_key, recorded_at);
CREATE UNIQUE INDEX idx_outbox_tenant_global_seq
  ON outbox_events(tenant_id, global_sequence) WHERE global_sequence IS NOT NULL;

ALTER TABLE outbox_events ENABLE ROW LEVEL SECURITY;
CREATE POLICY tenant_isolation_oe ON outbox_events USING (tenant_id = current_tenant_id());

COMMENT ON TABLE outbox_events IS
  'Transactional outbox per Phase 2D. partition_key=aggregate_id by default. '
  'ROADMAP v1.1+: monthly partition by recorded_at when row count > 10M. '
  'DLQ reasons: MAX_ATTEMPTS_EXCEEDED|SCHEMA_MISMATCH|POISON_EVENT|'
  'CONSUMER_PERMANENT_FAILURE|MANUAL_DLQ|TENANT_ARCHIVED.';


CREATE TABLE processed_events (
  consumer_name                 VARCHAR(100) NOT NULL,
  event_id                      UUID NOT NULL,
  processed_at                  TIMESTAMPTZ NOT NULL DEFAULT now(),

  result_status                 VARCHAR(20) NOT NULL DEFAULT 'SUCCESS',
  CONSTRAINT chk_pe_status CHECK (result_status IN ('SUCCESS','FAILED','SKIPPED','POISONED')),

  error_message                 TEXT,
  retry_count                   INT NOT NULL DEFAULT 0,

  PRIMARY KEY (consumer_name, event_id)
);

CREATE INDEX idx_pe_event_id ON processed_events(event_id);
CREATE INDEX idx_pe_failed ON processed_events(consumer_name, processed_at DESC)
  WHERE result_status IN ('FAILED','POISONED');

COMMENT ON TABLE processed_events IS
  'Consumer idempotency. Insert row in same tx as projection update. '
  'No tenant_id needed: event_id is globally unique. '
  'ROADMAP v1.1+: monthly partition when row count > 10M.';


CREATE TABLE audit_event_log (
  id                            BIGSERIAL PRIMARY KEY,
  tenant_id                     UUID NOT NULL REFERENCES tenants(id) ON DELETE RESTRICT,

  event_type                    VARCHAR(100) NOT NULL,
  aggregate_type                VARCHAR(50),
  aggregate_id                  UUID,

  actor_user_id                 UUID REFERENCES users(id) ON DELETE SET NULL,
  actor_role                    VARCHAR(50),

  severity                      VARCHAR(20) NOT NULL DEFAULT 'INFO',
  CONSTRAINT chk_ael_severity CHECK (severity IN ('INFO','WARN','CRITICAL')),

  description                   TEXT NOT NULL,
  details                       JSONB NOT NULL DEFAULT '{}'::jsonb,

  ip_address                    INET,
  user_agent                    TEXT,

  occurred_at                   TIMESTAMPTZ NOT NULL DEFAULT now(),
  recorded_at                   TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE INDEX idx_ael_tenant_time ON audit_event_log(tenant_id, occurred_at DESC);
CREATE INDEX idx_ael_event_type ON audit_event_log(event_type, occurred_at DESC);
CREATE INDEX idx_ael_actor ON audit_event_log(actor_user_id, occurred_at DESC)
  WHERE actor_user_id IS NOT NULL;
CREATE INDEX idx_ael_aggregate ON audit_event_log(aggregate_type, aggregate_id)
  WHERE aggregate_id IS NOT NULL;
CREATE INDEX idx_ael_severity ON audit_event_log(tenant_id, severity, occurred_at DESC)
  WHERE severity IN ('WARN','CRITICAL');
CREATE INDEX idx_ael_details_gin ON audit_event_log USING gin(details);

ALTER TABLE audit_event_log ENABLE ROW LEVEL SECURITY;
CREATE POLICY tenant_isolation_ael ON audit_event_log USING (tenant_id = current_tenant_id());

REVOKE UPDATE, DELETE ON audit_event_log FROM PUBLIC;

CREATE TRIGGER no_modify_audit_event_log
  BEFORE UPDATE OR DELETE ON audit_event_log
  FOR EACH ROW EXECUTE FUNCTION raise_append_only_violation();


CREATE TABLE security_audit_log (
  id                            BIGSERIAL PRIMARY KEY,
  tenant_id                     UUID REFERENCES tenants(id) ON DELETE RESTRICT,

  event_type                    VARCHAR(100) NOT NULL,
  outcome                       VARCHAR(20) NOT NULL,
  CONSTRAINT chk_sal_outcome CHECK (outcome IN ('SUCCESS','FAILED','BLOCKED','SUSPICIOUS')),

  user_id                       UUID REFERENCES users(id) ON DELETE SET NULL,
  email_attempted               CITEXT,

  ip                            INET,
  user_agent                    TEXT,
  geo_country                   VARCHAR(2),
  geo_city                      VARCHAR(100),

  details                       JSONB NOT NULL DEFAULT '{}'::jsonb,

  session_id                    VARCHAR(100),
  api_key_id                    UUID,

  occurred_at                   TIMESTAMPTZ NOT NULL DEFAULT now(),
  recorded_at                   TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE INDEX idx_sal_user ON security_audit_log(user_id, occurred_at DESC)
  WHERE user_id IS NOT NULL;
CREATE INDEX idx_sal_event_type ON security_audit_log(event_type, occurred_at DESC);
CREATE INDEX idx_sal_outcome ON security_audit_log(outcome, occurred_at DESC);
CREATE INDEX idx_sal_brute_force ON security_audit_log(ip, occurred_at DESC)
  WHERE outcome = 'FAILED' AND event_type = 'LOGIN_FAILED';
CREATE INDEX idx_sal_tenant_time ON security_audit_log(tenant_id, occurred_at DESC)
  WHERE tenant_id IS NOT NULL;

ALTER TABLE security_audit_log ENABLE ROW LEVEL SECURITY;
CREATE POLICY tenant_isolation_sal ON security_audit_log
  USING (tenant_id IS NULL OR tenant_id = current_tenant_id());

REVOKE UPDATE, DELETE ON security_audit_log FROM PUBLIC;

CREATE TRIGGER no_modify_security_audit_log
  BEFORE UPDATE OR DELETE ON security_audit_log
  FOR EACH ROW EXECUTE FUNCTION raise_append_only_violation();

COMMENT ON TABLE security_audit_log IS
  'Separate stream from audit_event_log per ADR 008. Auth/MFA/IP-level. '
  'High frequency, different retention. tenant_id NULLABLE for events '
  '(login attempt against unknown email).';


CREATE TABLE process_instances (
  id                            UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  tenant_id                     UUID NOT NULL REFERENCES tenants(id) ON DELETE RESTRICT,

  process_type                  VARCHAR(50) NOT NULL,
  CONSTRAINT chk_pri_type CHECK (process_type IN (
    'EXCHANGE','TRANSFER','DAY_END_CLOSE','TENANT_LIFECYCLE','SALE_DOCUMENT_GENERATION'
  )),

  correlation_key               VARCHAR(100) NOT NULL,

  status                        VARCHAR(20) NOT NULL DEFAULT 'IN_PROGRESS',
  CONSTRAINT chk_pri_status CHECK (status IN ('IN_PROGRESS','COMPLETED','STALLED','FAILED','CANCELLED')),

  current_step                  VARCHAR(50),
  state_data                    JSONB NOT NULL DEFAULT '{}'::jsonb,

  started_at                    TIMESTAMPTZ NOT NULL DEFAULT now(),
  deadline_at                   TIMESTAMPTZ,
  completed_at                  TIMESTAMPTZ,
  stalled_at                    TIMESTAMPTZ,
  failed_at                     TIMESTAMPTZ,
  failure_reason                TEXT,

  initiated_by_user_id          UUID REFERENCES users(id) ON DELETE SET NULL,

  created_at                    TIMESTAMPTZ NOT NULL DEFAULT now(),
  updated_at                    TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE UNIQUE INDEX idx_pri_correlation ON process_instances(tenant_id, process_type, correlation_key);
CREATE INDEX idx_pri_status ON process_instances(tenant_id, status);
CREATE INDEX idx_pri_deadline ON process_instances(deadline_at)
  WHERE status = 'IN_PROGRESS' AND deadline_at IS NOT NULL;
CREATE INDEX idx_pri_stalled ON process_instances(tenant_id, stalled_at)
  WHERE status = 'STALLED';

ALTER TABLE process_instances ENABLE ROW LEVEL SECURITY;
CREATE POLICY tenant_isolation_pri_inst ON process_instances USING (tenant_id = current_tenant_id());

CREATE TRIGGER set_updated_at_pri_inst
  BEFORE UPDATE ON process_instances FOR EACH ROW EXECUTE FUNCTION set_updated_at();
