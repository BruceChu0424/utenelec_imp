-- V409: idempotent production-daily-report creation and monotonic draft CAS.
--
-- Existing reports are valid version-0 facts. New create commands bind one
-- authenticated user + client key + canonical request hash to exactly one
-- report UUID. The command ledger is append-only; retries replay the bound
-- report and cannot create an orphan or a second report.

ALTER TABLE production_daily_reports
    ADD COLUMN row_version BIGINT NOT NULL DEFAULT 0,
    ADD CONSTRAINT production_daily_reports_row_version_chk
        CHECK (row_version >= 0);

CREATE TABLE production_daily_report_commands (
    id                UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    actor_user_id     UUID NOT NULL REFERENCES users(id) ON DELETE RESTRICT,
    idempotency_key   VARCHAR(128) NOT NULL,
    request_hash      CHAR(64) NOT NULL,
    report_id         UUID NOT NULL REFERENCES production_daily_reports(id)
        ON DELETE RESTRICT,
    created_by        UUID NOT NULL REFERENCES users(id) ON DELETE RESTRICT,
    created_at        TIMESTAMPTZ NOT NULL DEFAULT now(),
    CONSTRAINT production_daily_report_command_key_chk CHECK (
        idempotency_key = btrim(idempotency_key)
        AND length(idempotency_key) BETWEEN 8 AND 128
    ),
    CONSTRAINT production_daily_report_command_hash_chk CHECK (
        request_hash ~ '^[0-9a-f]{64}$'
    ),
    CONSTRAINT uq_production_daily_report_command_actor_key
        UNIQUE (actor_user_id, idempotency_key),
    CONSTRAINT uq_production_daily_report_command_report
        UNIQUE (report_id)
);

CREATE INDEX idx_production_daily_report_command_created
    ON production_daily_report_commands(created_at, id);

CREATE OR REPLACE FUNCTION fn_guard_production_daily_report_command()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
BEGIN
    RAISE EXCEPTION 'production daily report commands are append-only'
        USING ERRCODE = '55000',
              CONSTRAINT = 'production_daily_report_command_append_only_guard';
END;
$$;

CREATE TRIGGER trg_guard_production_daily_report_command
    BEFORE UPDATE OR DELETE ON production_daily_report_commands
    FOR EACH ROW EXECUTE FUNCTION fn_guard_production_daily_report_command();

ALTER TABLE production_daily_report_commands
    ENABLE ALWAYS TRIGGER trg_guard_production_daily_report_command;

CREATE TRIGGER trg_audit_production_daily_report_commands
    AFTER INSERT OR UPDATE OR DELETE ON production_daily_report_commands
    FOR EACH ROW EXECUTE FUNCTION fn_audit();

-- Every accepted header mutation, including edit, approval, reversal and soft
-- delete, advances exactly once. This closes native-SQL or future service paths
-- that would otherwise bypass the JPA @Version contract.
CREATE OR REPLACE FUNCTION fn_guard_production_daily_report_row_version()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
BEGIN
    IF NEW.row_version IS DISTINCT FROM OLD.row_version + 1 THEN
        RAISE EXCEPTION 'production daily report row_version must advance by exactly one'
            USING ERRCODE = '23514',
                  CONSTRAINT = 'production_daily_report_row_version_guard';
    END IF;
    RETURN NEW;
END;
$$;

CREATE TRIGGER trg_guard_production_daily_report_row_version
    BEFORE UPDATE ON production_daily_reports
    FOR EACH ROW EXECUTE FUNCTION fn_guard_production_daily_report_row_version();

ALTER TABLE production_daily_reports
    ENABLE ALWAYS TRIGGER trg_guard_production_daily_report_row_version;

COMMENT ON COLUMN production_daily_reports.row_version IS
    'Monotonic optimistic-lock version; every accepted report-header mutation advances exactly once.';
COMMENT ON TABLE production_daily_report_commands IS
    'Append-only create-command ledger. One actor/key/hash binds permanently to one production daily report.';
COMMENT ON COLUMN production_daily_report_commands.idempotency_key IS
    'Opaque client retry key, unique within the authenticated user.';
COMMENT ON COLUMN production_daily_report_commands.request_hash IS
    'Canonical SHA-256 of the authoritative create payload, excluding the retry key and server-owned bill number.';
