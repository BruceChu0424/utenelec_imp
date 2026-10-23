-- A confirmed material identity with an unknown consumption quantity is master
-- evidence, not a recipe. No quantity, issue-method, demand, stock, learning or
-- costing fact is created by this table or by its read projection.
CREATE TABLE goods_material_identity_evidence (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    product_goods_id UUID NOT NULL REFERENCES goods(id) ON DELETE RESTRICT,
    material_goods_id UUID NOT NULL REFERENCES goods(id) ON DELETE RESTRICT,
    material_color_id UUID REFERENCES colors(id) ON DELETE RESTRICT,
    source_kind TEXT NOT NULL CHECK (source_kind IN ('LEGACY_MATERIAL_TEXT','USER_CONFIRMED')),
    status TEXT NOT NULL DEFAULT 'PENDING_QUANTITY' CHECK (status='PENDING_QUANTITY'),
    provenance JSONB NOT NULL CHECK (jsonb_typeof(provenance)='object' AND provenance<>'{}'::jsonb),
    import_run_id UUID REFERENCES legacy_migration_runs(run_id) ON DELETE RESTRICT,
    created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    created_by UUID,
    updated_by UUID,
    is_deleted BOOLEAN NOT NULL DEFAULT FALSE,
    deleted_at TIMESTAMPTZ,
    CONSTRAINT goods_material_identity_no_self_chk CHECK (product_goods_id<>material_goods_id),
    CONSTRAINT goods_material_identity_import_source_chk CHECK (
        source_kind<>'LEGACY_MATERIAL_TEXT' OR import_run_id IS NOT NULL)
);
CREATE UNIQUE INDEX uq_goods_material_identity_active
    ON goods_material_identity_evidence(product_goods_id,material_goods_id,material_color_id)
    NULLS NOT DISTINCT WHERE NOT is_deleted;
CREATE INDEX idx_goods_material_identity_product ON goods_material_identity_evidence(product_goods_id);
CREATE INDEX idx_goods_material_identity_material ON goods_material_identity_evidence(material_goods_id);
CREATE INDEX idx_goods_material_identity_color ON goods_material_identity_evidence(material_color_id)
    WHERE material_color_id IS NOT NULL;
CREATE INDEX idx_goods_material_identity_run ON goods_material_identity_evidence(import_run_id)
    WHERE import_run_id IS NOT NULL;
COMMENT ON TABLE goods_material_identity_evidence IS
    '原料身份已确认、单耗待核的主档证据；不是活动 BOM，不参与 MRP、领料、库存、成本或用量学习。';
COMMENT ON COLUMN goods_material_identity_evidence.provenance IS
    '来源文件、行号、哈希与身份判断依据；不作为业务数量或单耗证据。';

CREATE FUNCTION fn_guard_goods_material_identity_evidence() RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
    IF NOT NEW.is_deleted THEN
        PERFORM id FROM goods WHERE id IN(NEW.product_goods_id,NEW.material_goods_id) ORDER BY id FOR SHARE;
    END IF;
    IF NOT NEW.is_deleted AND EXISTS (
        SELECT 1 FROM goods g WHERE g.id IN(NEW.product_goods_id,NEW.material_goods_id)
        AND (g.is_deleted OR g.auto_created)) THEN
        RAISE EXCEPTION 'material identity evidence requires real, non-deleted goods identities'
            USING ERRCODE='23514',CONSTRAINT='goods_material_identity_real_goods';
    END IF;
    IF NOT NEW.is_deleted AND EXISTS (
        SELECT 1 FROM goods material WHERE material.id=NEW.material_goods_id AND material.status='禁用') THEN
        RAISE EXCEPTION 'disabled materials cannot enter current material identity evidence'
            USING ERRCODE='23514',CONSTRAINT='goods_material_identity_material_enabled';
    END IF;
    RETURN NEW;
END $$;
CREATE TRIGGER trg_guard_goods_material_identity_evidence
    BEFORE INSERT OR UPDATE ON goods_material_identity_evidence
    FOR EACH ROW EXECUTE FUNCTION fn_guard_goods_material_identity_evidence();

SELECT fn_audit_track_table('goods_material_identity_evidence','FULL','data_change',false);
DO $reset_policy$
DECLARE definition TEXT; anchor TEXT := '(''goods'', ''PRESERVE'')';
BEGIN
    SELECT pg_get_functiondef('business_data_reset()'::regprocedure) INTO definition;
    IF (length(definition)-length(replace(definition,anchor,'')))/length(anchor)<>1 THEN
        RAISE EXCEPTION 'V904 cannot extend material identity reset policy safely';
    END IF;
    EXECUTE replace(definition,anchor,anchor||E',\n    (''goods_material_identity_evidence'', ''PRESERVE'')');
END
$reset_policy$;
