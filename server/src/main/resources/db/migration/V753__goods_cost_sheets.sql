-- Independent, versioned internal costing. Never writes goods/BOM/stock/financial amounts.
CREATE TABLE goods_cost_sheets (
    id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    sheet_no text NOT NULL UNIQUE,
    goods_id uuid NOT NULL REFERENCES goods(id) ON DELETE RESTRICT,
    client_id uuid REFERENCES clients(id) ON DELETE RESTRICT,
    name text NOT NULL CHECK (length(name) BETWEEN 1 AND 160),
    status text NOT NULL DEFAULT 'DRAFT' CHECK (status IN ('DRAFT','CONFIRMED')),
    row_version bigint NOT NULL DEFAULT 1 CHECK (row_version>0),
    input jsonb NOT NULL CHECK (jsonb_typeof(input)='object'),
    calculation jsonb NOT NULL CHECK (jsonb_typeof(calculation)='object'),
    confirmed_snapshot_id uuid,
    created_by uuid NOT NULL,
    updated_by uuid NOT NULL,
    created_at timestamptz NOT NULL DEFAULT now(),
    updated_at timestamptz NOT NULL DEFAULT now(),
    CHECK ((status='CONFIRMED')=(confirmed_snapshot_id IS NOT NULL))
);
CREATE INDEX idx_goods_cost_sheets_goods ON goods_cost_sheets(goods_id,updated_at DESC,id);
CREATE TABLE goods_cost_snapshots (
    id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    sheet_id uuid NOT NULL REFERENCES goods_cost_sheets(id) ON DELETE RESTRICT,
    sheet_version bigint NOT NULL CHECK(sheet_version>0),
    kind text NOT NULL CHECK(kind IN ('DRAFT_EXPORT','CONFIRMED')),
    payload jsonb NOT NULL CHECK(jsonb_typeof(payload)='object'),
    content_digest char(64) NOT NULL,
    created_by uuid NOT NULL,
    created_at timestamptz NOT NULL DEFAULT now(),
    UNIQUE(sheet_id,sheet_version,kind),
    UNIQUE(id,sheet_id)
);
ALTER TABLE goods_cost_sheets ADD CONSTRAINT goods_cost_confirmed_snapshot_fk
    FOREIGN KEY(confirmed_snapshot_id,id) REFERENCES goods_cost_snapshots(id,sheet_id)
    DEFERRABLE INITIALLY DEFERRED;
CREATE TABLE goods_cost_commands (
    actor_id uuid NOT NULL,
    idempotency_key varchar(128) NOT NULL,
    command_kind text NOT NULL,
    request_hash char(64) NOT NULL,
    result jsonb NOT NULL,
    created_at timestamptz NOT NULL DEFAULT now(),
    PRIMARY KEY(actor_id,idempotency_key)
);
CREATE TABLE goods_cost_templates (
    id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    name text NOT NULL CHECK(length(name) BETWEEN 1 AND 160),
    goods_id uuid REFERENCES goods(id) ON DELETE RESTRICT,
    client_id uuid REFERENCES clients(id) ON DELETE RESTRICT,
    row_version bigint NOT NULL DEFAULT 1 CHECK(row_version>0),
    input jsonb NOT NULL CHECK(jsonb_typeof(input)='object'),
    created_by uuid NOT NULL,
    updated_by uuid NOT NULL,
    created_at timestamptz NOT NULL DEFAULT now(),
    updated_at timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX idx_goods_cost_templates_scope ON goods_cost_templates(goods_id,client_id);
CREATE FUNCTION fn_guard_goods_cost_immutable() RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
    IF TG_TABLE_NAME IN ('goods_cost_snapshots','goods_cost_commands')
       OR OLD.status='CONFIRMED' THEN
        RAISE EXCEPTION 'Confirmed costing records and evidence snapshots are immutable' USING ERRCODE='23514';
    END IF;
    RETURN NEW;
END $$;
CREATE TRIGGER goods_cost_sheet_frozen BEFORE UPDATE OR DELETE ON goods_cost_sheets
    FOR EACH ROW EXECUTE FUNCTION fn_guard_goods_cost_immutable();
-- Separate function avoids accessing a nonexistent status field on the evidence record types.
CREATE FUNCTION fn_guard_goods_cost_evidence() RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
    RAISE EXCEPTION 'Cost evidence and command receipts are immutable' USING ERRCODE='23514';
END $$;
CREATE TRIGGER goods_cost_snapshot_frozen BEFORE UPDATE OR DELETE ON goods_cost_snapshots
    FOR EACH ROW EXECUTE FUNCTION fn_guard_goods_cost_evidence();
CREATE TRIGGER goods_cost_command_frozen BEFORE UPDATE OR DELETE ON goods_cost_commands
    FOR EACH ROW EXECUTE FUNCTION fn_guard_goods_cost_evidence();
SELECT fn_audit_track_table('goods_cost_sheets','FULL','data_change',false);
SELECT fn_audit_track_table('goods_cost_snapshots','FULL','data_change',false);
SELECT fn_audit_track_table('goods_cost_templates','FULL','data_change',false);
SELECT fn_audit_track_table('goods_cost_commands','NONE','data_change',false);

INSERT INTO permissions(code,name,module,category,sort_order,action_type,description,
                        grant_policy,sensitivity)
VALUES
 ('goods:cost:edit','编辑成本草稿','基础资料','货品资料',41,'EDIT','维护独立成本草稿及本单费用，不修改货品和库存',ARRAY['BULK_EXCLUDED'],'SENSITIVE_COMMERCIAL'),
 ('goods:cost:confirm','确认成本版本','基础资料','货品资料',42,'APPROVE','将完整成本草稿确认为不可变内部成本版本',ARRAY['BULK_EXCLUDED'],'SENSITIVE_COMMERCIAL'),
 ('goods:cost:export','下载成本资料','基础资料','货品资料',43,'EXPORT','下载已授权成本快照，领取和打印时再次验证',ARRAY['BULK_EXCLUDED'],'SENSITIVE_COMMERCIAL'),
 ('goods:cost:template','维护成本费用模板','基础资料','货品资料',44,'EDIT','维护跨成本单复用的客户产品费用模板；本单费用编辑不授予此权限',ARRAY['BULK_EXCLUDED'],'SENSITIVE_COMMERCIAL')
ON CONFLICT(code) DO NOTHING;
-- New mutation/export/template privileges require explicit assignment. In particular a
-- legacy cost viewer must not become an editor/confirmer through a migration.
-- Super administrators receive catalog authorities through the existing resolver.
DO $reset_policy$
DECLARE definition text; anchor text := '(''stock_movements'', ''CLEAR'')';
BEGIN
    SELECT pg_get_functiondef('business_data_reset()'::regprocedure) INTO definition;
    IF (length(definition)-length(replace(definition,anchor,'')))/length(anchor)<>1 THEN
        RAISE EXCEPTION 'V753 cannot extend reset policy safely';
    END IF;
    EXECUTE replace(definition,anchor,anchor
        || E',\n            (''goods_cost_sheets'', ''PRESERVE'')'
        || E',\n            (''goods_cost_snapshots'', ''PRESERVE'')'
        || E',\n            (''goods_cost_commands'', ''PRESERVE'')'
        || E',\n            (''goods_cost_templates'', ''PRESERVE'')');
END $reset_policy$;
