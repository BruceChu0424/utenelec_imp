-- Preserve existing append-only rows exactly. Historical review versions cannot be reconstructed.
ALTER TABLE production_daily_report_commands
    ADD COLUMN approval_protocol_version SMALLINT,
    ADD COLUMN reviewed_row_version BIGINT;

ALTER TABLE production_daily_report_commands
    ADD CONSTRAINT production_daily_report_approval_review_contract_chk CHECK (
        (approval_protocol_version IS NULL AND reviewed_row_version IS NULL)
        OR (
            approval_protocol_version IS NOT NULL
            AND command_kind = 'APPROVE'
            AND (
                (approval_protocol_version = 1 AND reviewed_row_version IS NULL)
                OR (approval_protocol_version = 2 AND reviewed_row_version IS NOT NULL AND reviewed_row_version >= 0)
            )
        )
    );

COMMENT ON COLUMN production_daily_report_commands.approval_protocol_version IS
    'Approval request contract: NULL retains historical unknown metadata; 1 is explicit unversioned compatibility; 2 binds reviewed_row_version. Never backfilled.';
COMMENT ON COLUMN production_daily_report_commands.reviewed_row_version IS
    'Exact version reviewed by a V2 approval, captured before confirmation. NULL never means version zero.';
