-- Controlled PGP re-encryption changes no business value, historical audit row or HMAC.
CREATE TABLE pii_key_rotation_runs (
    id UUID PRIMARY KEY,
    target_version VARCHAR(64) NOT NULL CHECK (target_version ~ '^[A-Za-z0-9._-]{1,64}$'),
    catalog_version VARCHAR(32) NOT NULL,
    target_index INTEGER NOT NULL DEFAULT 0 CHECK (target_index >= 0),
    cursor_key TEXT NOT NULL DEFAULT '' CHECK (length(cursor_key) <= 100),
    batch_sequence BIGINT NOT NULL DEFAULT 0 CHECK (batch_sequence >= 0),
    verified_rows BIGINT NOT NULL DEFAULT 0 CHECK (verified_rows >= 0),
    rewrapped_cells BIGINT NOT NULL DEFAULT 0 CHECK (rewrapped_cells >= 0),
    status VARCHAR(24) NOT NULL DEFAULT 'RUNNING' CHECK (status IN ('RUNNING','SCANNED','RESCAN_REQUIRED')),
    started_by UUID NOT NULL REFERENCES users(id),
    updated_by UUID NOT NULL REFERENCES users(id),
    created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_at TIMESTAMPTZ NOT NULL DEFAULT now()
);
COMMENT ON TABLE pii_key_rotation_runs IS
    'Resumable local PGP maintenance checkpoints only: no keys, plaintext, ciphertext or HMAC. NONE row audit; each committed batch has an explicit audit event. SCANNED never authorizes retiring backup keys.';

INSERT INTO permissions(code,name,module,category,sort_order,action_type,description,grant_policy,baseline)
VALUES ('pii_key_rotation:manage','维护 PII 加密密钥','系统管理','安全维护',901,'EXECUTE',
        '仅本地显式启用后由超管本人再认证办理小批次重加密；不允许删除旧密钥',ARRAY['SUPERADMIN_ONLY'],FALSE)
ON CONFLICT(code) DO UPDATE SET name=EXCLUDED.name,module=EXCLUDED.module,category=EXCLUDED.category,
    sort_order=EXCLUDED.sort_order,action_type=EXCLUDED.action_type,description=EXCLUDED.description,
    grant_policy=EXCLUDED.grant_policy,baseline=EXCLUDED.baseline;

DO $reset_policy$
DECLARE
    definition TEXT;
    anchor TEXT := '(''employee_reconcile_applies'', ''PRESERVE''),';
BEGIN
    SELECT replace(pg_get_functiondef('business_data_reset()'::regprocedure),chr(13),'') INTO definition;
    IF (length(definition)-length(replace(definition,anchor,'')))/length(anchor) <> 1
       OR position('pii_key_rotation_runs' IN definition)>0 THEN
        RAISE EXCEPTION 'V827 cannot extend business reset preservation policy';
    END IF;
    EXECUTE replace(definition,anchor,anchor || E'\n            (''pii_key_rotation_runs'', ''PRESERVE''),');
END;
$reset_policy$;
