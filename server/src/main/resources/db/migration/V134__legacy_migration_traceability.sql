-- V134: make every legacy import reproducible and reconcilable.
--
-- A shell exit code only proves that PostgreSQL accepted the statements. It
-- does not prove that the export was coherent or that every source row was
-- mapped. These tables retain the immutable input identity and structured
-- reconciliation evidence without storing credentials or raw PII.

ALTER TABLE legacy_migration_runs
    ADD COLUMN migration_mode TEXT NOT NULL DEFAULT 'BOOTSTRAP',
    ADD COLUMN export_manifest_sha256 CHAR(64),
    ADD COLUMN checksum_manifest_sha256 CHAR(64),
    ADD COLUMN migration_repository_commit VARCHAR(64),
    ADD COLUMN migration_script_sha256 CHAR(64),
    ADD COLUMN mapping_version VARCHAR(64) NOT NULL DEFAULT 'bootstrap-v1',
    ADD COLUMN reconciliation_status TEXT NOT NULL DEFAULT 'NOT_RUN',
    ADD COLUMN reconciliation_summary JSONB NOT NULL DEFAULT '{}'::JSONB,
    ADD COLUMN rejected_count BIGINT NOT NULL DEFAULT 0;

ALTER TABLE legacy_migration_runs
    ADD CONSTRAINT legacy_migration_runs_mode_chk
        CHECK (migration_mode IN ('BOOTSTRAP', 'INCREMENTAL', 'DRY_RUN')),
    ADD CONSTRAINT legacy_migration_runs_export_hash_chk
        CHECK (
            export_manifest_sha256 IS NULL
            OR export_manifest_sha256 ~ '^[0-9a-f]{64}$'
        ),
    ADD CONSTRAINT legacy_migration_runs_checksum_hash_chk
        CHECK (
            checksum_manifest_sha256 IS NULL
            OR checksum_manifest_sha256 ~ '^[0-9a-f]{64}$'
        ),
    ADD CONSTRAINT legacy_migration_runs_script_hash_chk
        CHECK (
            migration_script_sha256 IS NULL
            OR migration_script_sha256 ~ '^[0-9a-f]{64}$'
        ),
    ADD CONSTRAINT legacy_migration_runs_reconciliation_status_chk
        CHECK (
            reconciliation_status IN (
                'NOT_RUN',
                'RUNNING',
                'PASSED',
                'FAILED',
                'WAIVED'
            )
        ),
    ADD CONSTRAINT legacy_migration_runs_rejected_count_chk
        CHECK (rejected_count >= 0);

CREATE TABLE legacy_migration_run_files (
    run_id       UUID NOT NULL
                 REFERENCES legacy_migration_runs(run_id) ON DELETE CASCADE,
    file_name    TEXT NOT NULL,
    sha256       CHAR(64) NOT NULL,
    byte_size    BIGINT NOT NULL,
    verified_at  TIMESTAMPTZ NOT NULL DEFAULT CURRENT_TIMESTAMP,
    PRIMARY KEY (run_id, file_name),
    CONSTRAINT legacy_migration_run_files_name_chk
        CHECK (file_name ~ '^[A-Za-z0-9][A-Za-z0-9_.-]*$'),
    CONSTRAINT legacy_migration_run_files_hash_chk
        CHECK (sha256 ~ '^[0-9a-f]{64}$'),
    CONSTRAINT legacy_migration_run_files_size_chk
        CHECK (byte_size > 0)
);

CREATE INDEX idx_legacy_migration_run_files_hash
    ON legacy_migration_run_files (sha256);

CREATE TABLE legacy_migration_reconciliation_items (
    id             BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    run_id         UUID NOT NULL
                   REFERENCES legacy_migration_runs(run_id) ON DELETE CASCADE,
    source_entity  TEXT NOT NULL,
    target_entity  TEXT NOT NULL,
    metric         TEXT NOT NULL,
    expected_value BIGINT,
    actual_value   BIGINT,
    passed         BOOLEAN NOT NULL,
    detail         TEXT,
    checked_at     TIMESTAMPTZ NOT NULL DEFAULT CURRENT_TIMESTAMP,
    CONSTRAINT legacy_migration_reconciliation_item_uk
        UNIQUE (run_id, source_entity, target_entity, metric),
    CONSTRAINT legacy_migration_reconciliation_detail_len_chk
        CHECK (detail IS NULL OR char_length(detail) <= 2000)
);

CREATE INDEX idx_legacy_migration_reconciliation_failed
    ON legacy_migration_reconciliation_items (run_id, checked_at)
    WHERE passed = FALSE;

CREATE TABLE legacy_migration_rejects (
    id                 BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    run_id             UUID NOT NULL
                       REFERENCES legacy_migration_runs(run_id) ON DELETE CASCADE,
    source_entity      TEXT NOT NULL,
    source_identifier  TEXT NOT NULL,
    reason_code        TEXT NOT NULL,
    reason_detail      TEXT,
    source_payload_sha256 CHAR(64),
    created_at         TIMESTAMPTZ NOT NULL DEFAULT CURRENT_TIMESTAMP,
    CONSTRAINT legacy_migration_rejects_reason_len_chk
        CHECK (char_length(reason_code) BETWEEN 1 AND 100),
    CONSTRAINT legacy_migration_rejects_detail_len_chk
        CHECK (reason_detail IS NULL OR char_length(reason_detail) <= 2000),
    CONSTRAINT legacy_migration_rejects_payload_hash_chk
        CHECK (
            source_payload_sha256 IS NULL
            OR source_payload_sha256 ~ '^[0-9a-f]{64}$'
        )
);

CREATE INDEX idx_legacy_migration_rejects_run_reason
    ON legacy_migration_rejects (run_id, reason_code, created_at);

-- This is an infrastructure table, not proof that incremental loaders already
-- exist. A loader may advance a checkpoint only after its transaction and
-- reconciliation have both succeeded.
CREATE TABLE legacy_migration_checkpoints (
    target             TEXT NOT NULL,
    source_entity      TEXT NOT NULL,
    checkpoint_value   TEXT NOT NULL,
    checkpoint_time    TIMESTAMPTZ,
    last_success_run_id UUID NOT NULL
                        REFERENCES legacy_migration_runs(run_id),
    updated_at         TIMESTAMPTZ NOT NULL DEFAULT CURRENT_TIMESTAMP,
    PRIMARY KEY (target, source_entity)
);

REVOKE ALL ON legacy_migration_runs FROM PUBLIC;
REVOKE ALL ON legacy_migration_run_files FROM PUBLIC;
REVOKE ALL ON legacy_migration_reconciliation_items FROM PUBLIC;
REVOKE ALL ON legacy_migration_rejects FROM PUBLIC;
REVOKE ALL ON legacy_migration_checkpoints FROM PUBLIC;

COMMENT ON COLUMN legacy_migration_runs.reconciliation_status IS
    'SUCCESS means the loader exited cleanly; PASSED means structured reconciliation also passed.';
COMMENT ON TABLE legacy_migration_run_files IS
    'Exact verified CSV inputs consumed by one migration run.';
COMMENT ON TABLE legacy_migration_reconciliation_items IS
    'Per-entity row counts, sums and invariant checks used as cutover evidence.';
COMMENT ON TABLE legacy_migration_rejects IS
    'Rows not imported and their non-sensitive reason; raw PII is deliberately not retained.';
COMMENT ON TABLE legacy_migration_checkpoints IS
    'Durable cursor storage for future incremental loaders; bootstrap scripts never advance it.';
