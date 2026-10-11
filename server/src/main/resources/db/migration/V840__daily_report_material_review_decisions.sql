-- V3 retains the reviewed balances and per-demand return intent on the existing
-- append-only approval command. Historical commands stay byte-for-byte unchanged.
ALTER TABLE production_daily_report_commands
    ADD COLUMN material_review_fingerprint CHAR(64),
    ADD COLUMN material_review_snapshot JSONB,
    ADD COLUMN material_decisions JSONB;

ALTER TABLE production_daily_report_commands
    DROP CONSTRAINT production_daily_report_approval_review_contract_chk,
    ADD CONSTRAINT production_daily_report_approval_review_contract_chk CHECK (
        (approval_protocol_version IS NULL AND reviewed_row_version IS NULL)
        OR (approval_protocol_version IS NOT NULL AND command_kind='APPROVE' AND (
            (approval_protocol_version=1 AND reviewed_row_version IS NULL)
            OR (approval_protocol_version IN(2,3) AND reviewed_row_version IS NOT NULL AND reviewed_row_version>=0)
        ))
    ),
    ADD CONSTRAINT production_daily_report_material_review_contract_chk CHECK (
        (approval_protocol_version IS DISTINCT FROM 3
         AND material_review_fingerprint IS NULL AND material_review_snapshot IS NULL AND material_decisions IS NULL)
        OR (approval_protocol_version IS NOT DISTINCT FROM 3 AND command_kind='APPROVE'
            AND material_review_fingerprint IS NOT NULL AND material_review_fingerprint ~ '^[0-9a-f]{64}$'
            AND material_review_snapshot IS NOT NULL AND jsonb_typeof(material_review_snapshot)='object'
            AND material_decisions IS NOT NULL AND jsonb_typeof(material_decisions)='array'
            AND material_review_snapshot ?& ARRAY['reportId','reportVersion','fingerprint','rows']
            AND jsonb_typeof(material_review_snapshot->'rows')='array'
            AND material_review_snapshot->>'reportId' IS NOT NULL
            AND material_review_snapshot->>'reportVersion' IS NOT NULL
            AND material_review_snapshot->>'fingerprint' IS NOT NULL
            AND material_review_snapshot->>'reportId'=report_id::text
            AND material_review_snapshot->>'reportVersion'=reviewed_row_version::text
            AND material_review_snapshot->>'fingerprint'=material_review_fingerprint
        )
    );

COMMENT ON COLUMN production_daily_report_commands.material_review_snapshot IS
    'V3 original pre-approval material balances and eligible returns; not a physical count or a warehouse receipt.';
COMMENT ON COLUMN production_daily_report_commands.material_decisions IS
    'V3 reviewed per-demand KEEP/RETURN intent. Immutable with the approval command, preserved by existing reset/archive rules.';
