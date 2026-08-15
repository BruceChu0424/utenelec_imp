-- V255: fail-closed attachment intake and object lifecycle.
--
-- Existing rows are deliberately classified as LEGACY_UNVERIFIED. They are not
-- silently treated as malware-scanned objects; an operator must reconcile their
-- exact object versions before they can be made downloadable again.

ALTER TABLE attachments
    ADD COLUMN lifecycle_state VARCHAR(32) NOT NULL DEFAULT 'LEGACY_UNVERIFIED',
    ADD COLUMN scan_engine VARCHAR(64),
    ADD COLUMN scan_signature VARCHAR(255),
    ADD COLUMN scanned_at TIMESTAMPTZ,
    ADD COLUMN promoted_at TIMESTAMPTZ,
    ADD COLUMN delete_requested_at TIMESTAMPTZ,
    ADD COLUMN delete_requested_by UUID,
    ADD COLUMN delete_failure VARCHAR(255),
    ADD CONSTRAINT attachments_lifecycle_state_chk CHECK (
        lifecycle_state IN (
            'LEGACY_UNVERIFIED', 'CLEAN', 'DELETE_PENDING',
            'DELETE_FAILED', 'DELETED'
        )
    ),
    ADD CONSTRAINT attachments_clean_scan_chk CHECK (
        lifecycle_state = 'LEGACY_UNVERIFIED'
        OR lifecycle_state IN ('DELETE_PENDING', 'DELETE_FAILED', 'DELETED')
        OR (lifecycle_state = 'CLEAN'
            AND scan_engine IS NOT NULL
            AND scanned_at IS NOT NULL
            AND promoted_at IS NOT NULL)
    );

CREATE INDEX attachments_owner_visible_idx
    ON attachments (owner_type, owner_id, created_at)
    WHERE lifecycle_state = 'CLEAN';
CREATE INDEX attachments_delete_queue_idx
    ON attachments (lifecycle_state, delete_requested_at)
    WHERE lifecycle_state IN ('DELETE_PENDING', 'DELETE_FAILED');

COMMENT ON COLUMN attachments.lifecycle_state IS
    'Only CLEAN objects are listable/downloadable; legacy and deletion states fail closed';

CREATE TABLE attachment_upload_sessions (
    id                  UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    storage_key         VARCHAR(255) NOT NULL UNIQUE,
    owner_type          VARCHAR(64) NOT NULL,
    owner_id            UUID NOT NULL,
    user_id             UUID NOT NULL,
    original_name       VARCHAR(255) NOT NULL,
    content_type        VARCHAR(255) NOT NULL,
    expected_size_bytes BIGINT NOT NULL,
    expires_at          TIMESTAMPTZ NOT NULL,
    status              VARCHAR(32) NOT NULL DEFAULT 'PENDING',
    staging_version     VARCHAR(255),
    staging_etag        VARCHAR(255),
    sha256              VARCHAR(64),
    final_version       VARCHAR(255),
    final_etag          VARCHAR(255),
    scan_engine         VARCHAR(64),
    scan_signature      VARCHAR(255),
    last_failure_code   VARCHAR(64),
    created_at          TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_at          TIMESTAMPTZ NOT NULL DEFAULT now(),
    completed_at        TIMESTAMPTZ,
    CONSTRAINT attachment_upload_sessions_size_chk
        CHECK (expected_size_bytes > 0),
    CONSTRAINT attachment_upload_sessions_key_chk
        CHECK (storage_key ~ '^[A-Za-z0-9._-]+$'),
    CONSTRAINT attachment_upload_sessions_status_chk CHECK (
        status IN ('PENDING', 'SCANNING', 'REJECTED', 'PROMOTED', 'EXPIRED')
    )
);

CREATE INDEX attachment_upload_sessions_user_quota_idx
    ON attachment_upload_sessions (user_id, status, expires_at);
CREATE INDEX attachment_upload_sessions_owner_quota_idx
    ON attachment_upload_sessions (owner_type, owner_id, status, expires_at);
CREATE INDEX attachment_upload_sessions_expiry_idx
    ON attachment_upload_sessions (expires_at)
    WHERE status IN ('PENDING', 'SCANNING');

CREATE TABLE attachment_object_outbox (
    id                  UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    attachment_id       UUID REFERENCES attachments(id) ON DELETE RESTRICT,
    upload_session_id   UUID REFERENCES attachment_upload_sessions(id) ON DELETE RESTRICT,
    operation           VARCHAR(32) NOT NULL,
    storage_key         VARCHAR(255) NOT NULL,
    storage_version     VARCHAR(255),
    dedupe_key          VARCHAR(640) NOT NULL UNIQUE,
    status              VARCHAR(16) NOT NULL DEFAULT 'PENDING',
    attempts            INTEGER NOT NULL DEFAULT 0,
    available_at        TIMESTAMPTZ NOT NULL DEFAULT now(),
    locked_at           TIMESTAMPTZ,
    completed_at        TIMESTAMPTZ,
    last_error          VARCHAR(255),
    created_at          TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_at          TIMESTAMPTZ NOT NULL DEFAULT now(),
    CONSTRAINT attachment_object_outbox_operation_chk
        CHECK (operation IN ('DELETE_STAGING', 'DELETE_FINAL')),
    CONSTRAINT attachment_object_outbox_status_chk
        CHECK (status IN ('PENDING', 'PROCESSING', 'SUCCEEDED', 'FAILED')),
    CONSTRAINT attachment_object_outbox_attempts_chk CHECK (attempts >= 0),
    CONSTRAINT attachment_object_outbox_key_chk
        CHECK (storage_key ~ '^[A-Za-z0-9._-]+$')
);

CREATE INDEX attachment_object_outbox_ready_idx
    ON attachment_object_outbox (available_at, created_at)
    WHERE status IN ('PENDING', 'FAILED');

CREATE TABLE attachment_reconciliation_findings (
    id                  UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    object_location     VARCHAR(16) NOT NULL,
    storage_key         VARCHAR(255) NOT NULL,
    storage_version     VARCHAR(255),
    size_bytes          BIGINT NOT NULL,
    observed_modified_at TIMESTAMPTZ,
    finding_state       VARCHAR(24) NOT NULL DEFAULT 'OBSERVED',
    observation_count   INTEGER NOT NULL DEFAULT 1,
    first_seen_at       TIMESTAMPTZ NOT NULL DEFAULT now(),
    last_seen_at        TIMESTAMPTZ NOT NULL DEFAULT now(),
    approved_at         TIMESTAMPTZ,
    approved_by         UUID,
    approval_reference  VARCHAR(255),
    resolved_at         TIMESTAMPTZ,
    evidence_sha256     VARCHAR(64) NOT NULL,
    created_at          TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_at          TIMESTAMPTZ NOT NULL DEFAULT now(),
    CONSTRAINT attachment_reconciliation_location_chk
        CHECK (object_location IN ('STAGING', 'FINAL')),
    CONSTRAINT attachment_reconciliation_state_chk
        CHECK (finding_state IN ('OBSERVED', 'APPROVED', 'QUEUED', 'RESOLVED', 'IGNORED')),
    CONSTRAINT attachment_reconciliation_size_chk CHECK (size_bytes >= 0),
    CONSTRAINT attachment_reconciliation_observation_chk CHECK (observation_count >= 1),
    CONSTRAINT attachment_reconciliation_key_chk
        CHECK (storage_key ~ '^[A-Za-z0-9._-]+$'),
    CONSTRAINT attachment_reconciliation_evidence_chk
        CHECK (evidence_sha256 ~ '^[0-9a-f]{64}$'),
    CONSTRAINT attachment_reconciliation_approval_chk CHECK (
        finding_state = 'OBSERVED'
        OR finding_state = 'IGNORED'
        OR (approved_at IS NOT NULL
            AND approved_by IS NOT NULL
            AND approval_reference IS NOT NULL)
    )
);

CREATE UNIQUE INDEX attachment_reconciliation_object_uq
    ON attachment_reconciliation_findings (
        object_location, storage_key, COALESCE(storage_version, '')
    );
CREATE INDEX attachment_reconciliation_open_idx
    ON attachment_reconciliation_findings (finding_state, first_seen_at)
    WHERE finding_state IN ('OBSERVED', 'APPROVED', 'QUEUED');

CREATE TRIGGER trg_audit_attachment_upload_sessions
    AFTER INSERT OR UPDATE OR DELETE ON attachment_upload_sessions
    FOR EACH ROW EXECUTE FUNCTION fn_audit();
CREATE TRIGGER trg_audit_attachment_object_outbox
    AFTER INSERT OR UPDATE OR DELETE ON attachment_object_outbox
    FOR EACH ROW EXECUTE FUNCTION fn_audit();
CREATE TRIGGER trg_audit_attachment_reconciliation_findings
    AFTER INSERT OR UPDATE OR DELETE ON attachment_reconciliation_findings
    FOR EACH ROW EXECUTE FUNCTION fn_audit();

INSERT INTO permissions (code, name, module, category, sort_order)
VALUES ('attachment:reconcile', '附件孤儿对象对账审批', '人事行政', '附件', 233)
ON CONFLICT (code) DO UPDATE
SET name = EXCLUDED.name,
    module = EXCLUDED.module,
    category = EXCLUDED.category,
    sort_order = EXCLUDED.sort_order;

-- Fail closed over the complete public business-table set after the new
-- attachment ledgers exist. The explicit triggers above make the intended
-- coverage reviewable; this sweep also detects malformed/duplicate/disabled
-- triggers anywhere else before V255 can be accepted.
DO $$
DECLARE
    table_record RECORD;
    prefixed_trigger_count INTEGER;
    valid_trigger_count INTEGER;
    missing_tables TEXT;
BEGIN
    FOR table_record IN
        SELECT c.oid, c.relname
        FROM pg_class c
        JOIN pg_namespace n ON n.oid = c.relnamespace
        WHERE n.nspname = 'public'
          AND c.relkind IN ('r', 'p')
          AND NOT c.relispartition
          AND c.relname NOT IN (
              'audit_log', 'audit_log_archive', 'flyway_schema_history', 'spatial_ref_sys',
              'authorization_state', 'doc_number_sequences', 'master_code_sequences',
              'report_materialized_view_refresh_state', 'password_history',
              'refresh_tokens', 'visitor_refresh_tokens', 'visitor_sms_codes')
          AND c.relname NOT LIKE 'legacy_migration_%'
        ORDER BY c.relname
    LOOP
        SELECT
            count(*),
            count(*) FILTER (WHERE
                audit_trigger.tgenabled IN ('O', 'A')
                AND (audit_trigger.tgtype::INTEGER & 1) = 1
                AND (audit_trigger.tgtype::INTEGER & 2) = 0
                AND (audit_trigger.tgtype::INTEGER & 4) = 4
                AND (audit_trigger.tgtype::INTEGER & 8) = 8
                AND (audit_trigger.tgtype::INTEGER & 16) = 16
                AND function_schema.nspname = 'public'
                AND audit_function.proname IN ('fn_audit', 'fn_audit_redacted'))
            INTO prefixed_trigger_count, valid_trigger_count
        FROM pg_trigger audit_trigger
        JOIN pg_proc audit_function ON audit_function.oid = audit_trigger.tgfoid
        JOIN pg_namespace function_schema
          ON function_schema.oid = audit_function.pronamespace
        WHERE audit_trigger.tgrelid = table_record.oid
          AND NOT audit_trigger.tgisinternal
          AND audit_trigger.tgname LIKE 'trg_audit%';

        IF prefixed_trigger_count = 1 AND valid_trigger_count = 1 THEN
            CONTINUE;
        END IF;

        IF prefixed_trigger_count > 0 THEN
            RAISE EXCEPTION
                'public.% has % trg_audit* triggers but exactly one valid enabled AFTER ROW INSERT/UPDATE/DELETE audit trigger is required (valid=%)',
                table_record.relname, prefixed_trigger_count, valid_trigger_count
                USING ERRCODE = '55000';
        END IF;

        EXECUTE format(
            'CREATE TRIGGER trg_audit_%1$I AFTER INSERT OR UPDATE OR DELETE ON %1$I '
            'FOR EACH ROW EXECUTE FUNCTION fn_audit()',
            table_record.relname);
    END LOOP;

    SELECT string_agg(c.relname, ', ' ORDER BY c.relname)
    INTO missing_tables
    FROM pg_class c
    JOIN pg_namespace n ON n.oid = c.relnamespace
    WHERE n.nspname = 'public'
      AND c.relkind IN ('r', 'p')
      AND NOT c.relispartition
      AND c.relname NOT IN (
          'audit_log', 'audit_log_archive', 'flyway_schema_history', 'spatial_ref_sys',
          'authorization_state', 'doc_number_sequences', 'master_code_sequences',
          'report_materialized_view_refresh_state', 'password_history',
          'refresh_tokens', 'visitor_refresh_tokens', 'visitor_sms_codes')
      AND c.relname NOT LIKE 'legacy_migration_%'
      AND (
          (SELECT count(*)
           FROM pg_trigger audit_trigger
           WHERE audit_trigger.tgrelid = c.oid
             AND NOT audit_trigger.tgisinternal
             AND audit_trigger.tgname LIKE 'trg_audit%') <> 1
          OR
          (SELECT count(*)
           FROM pg_trigger audit_trigger
           JOIN pg_proc audit_function ON audit_function.oid = audit_trigger.tgfoid
           JOIN pg_namespace function_schema
             ON function_schema.oid = audit_function.pronamespace
           WHERE audit_trigger.tgrelid = c.oid
             AND NOT audit_trigger.tgisinternal
             AND audit_trigger.tgname LIKE 'trg_audit%'
             AND audit_trigger.tgenabled IN ('O', 'A')
             AND (audit_trigger.tgtype::INTEGER & 1) = 1
             AND (audit_trigger.tgtype::INTEGER & 2) = 0
             AND (audit_trigger.tgtype::INTEGER & 4) = 4
             AND (audit_trigger.tgtype::INTEGER & 8) = 8
             AND (audit_trigger.tgtype::INTEGER & 16) = 16
             AND function_schema.nspname = 'public'
             AND audit_function.proname IN ('fn_audit', 'fn_audit_redacted')) <> 1);

    IF missing_tables IS NOT NULL THEN
        RAISE EXCEPTION 'Audit trigger coverage remains invalid for: %', missing_tables
            USING ERRCODE = '55000';
    END IF;
END $$;
