-- V768: 已审批内料仓盘点的期初与账面修正, 不冒充领料或生产耗用。
DO $$ BEGIN
    IF EXISTS (SELECT 1 FROM stock_movements WHERE movement_type=23) THEN
        RAISE EXCEPTION 'V768 stock movement type 23 already used';
    END IF;
END $$;

CREATE TABLE workshop_material_count_adjustment_postings (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    request_id UUID NOT NULL REFERENCES stock_count_requests(id),
    line_id UUID NOT NULL UNIQUE REFERENCES stock_count_request_lines(id),
    approval_event_id UUID NOT NULL REFERENCES stock_count_request_events(id),
    period_id UUID NOT NULL REFERENCES workshop_material_periods(id),
    bin_warehouse_id UUID NOT NULL REFERENCES warehouses(id),
    goods_id UUID NOT NULL REFERENCES goods(id),
    color_id UUID REFERENCES colors(id),
    unit_id UUID NOT NULL REFERENCES units(id),
    kind TEXT NOT NULL CHECK (kind IN ('OPENING','ADJUSTMENT')),
    before_qty NUMERIC(18,4) NOT NULL,
    target_qty NUMERIC(18,4) NOT NULL CHECK (target_qty>=0),
    signed_qty NUMERIC(18,4) GENERATED ALWAYS AS (target_qty-before_qty) STORED,
    business_date DATE NOT NULL,
    movement_id UUID UNIQUE REFERENCES stock_movements(id) DEFERRABLE INITIALLY DEFERRED,
    created_by UUID NOT NULL REFERENCES users(id),
    created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    CHECK (kind<>'OPENING' OR (before_qty=0 AND target_qty>0))
);
CREATE INDEX idx_wm_count_adjustment_request ON workshop_material_count_adjustment_postings(request_id);
CREATE INDEX idx_wm_count_adjustment_approval ON workshop_material_count_adjustment_postings(approval_event_id);
CREATE INDEX idx_wm_count_adjustment_period ON workshop_material_count_adjustment_postings(period_id);
CREATE INDEX idx_wm_count_adjustment_bin_material ON workshop_material_count_adjustment_postings(bin_warehouse_id,goods_id,color_id);
CREATE UNIQUE INDEX uq_wm_count_opening_material ON workshop_material_count_adjustment_postings(bin_warehouse_id,goods_id,color_id)
    NULLS NOT DISTINCT WHERE kind='OPENING';
CREATE INDEX idx_wm_count_adjustment_goods ON workshop_material_count_adjustment_postings(goods_id);
CREATE INDEX idx_wm_count_adjustment_color ON workshop_material_count_adjustment_postings(color_id);
CREATE INDEX idx_wm_count_adjustment_unit ON workshop_material_count_adjustment_postings(unit_id);
CREATE INDEX idx_wm_count_adjustment_actor ON workshop_material_count_adjustment_postings(created_by);
COMMENT ON TABLE workshop_material_count_adjustment_postings IS
    '已审核盘点来源: OPENING 上线实物期初; ADJUSTMENT 后续账面修正。独立于仓库领料和生产耗用, 只追加';

DO $ledger$
DECLARE definition TEXT;
BEGIN
    definition := rtrim(pg_get_viewdef('v_workshop_material_bin_ledger'::regclass,true), E';\n ');
    IF definition IS NULL OR position('workshop_material_count_adjustment_postings' IN definition)>0 THEN
        RAISE EXCEPTION 'V768 ledger anchor changed';
    END IF;
    EXECUTE 'CREATE OR REPLACE VIEW v_workshop_material_bin_ledger AS ' || definition ||
        ' UNION ALL SELECT id,kind,bin_warehouse_id,goods_id,color_id,signed_qty,period_id,business_date,movement_id,FALSE'
        || ' FROM workshop_material_count_adjustment_postings';
END;
$ledger$;

CREATE FUNCTION fn_workshop_material_period_opening(p_period UUID,p_goods UUID,p_color UUID)
RETURNS NUMERIC LANGUAGE sql STABLE AS $$
    SELECT CASE WHEN period.period_no=1 THEN COALESCE((
        SELECT sum(posting.signed_qty) FROM workshop_material_count_adjustment_postings posting
        WHERE posting.period_id=period.id AND posting.goods_id=p_goods
          AND posting.color_id IS NOT DISTINCT FROM p_color AND posting.kind='OPENING'),0)
    ELSE COALESCE((SELECT line.closing_qty FROM workshop_material_periods previous
        JOIN workshop_material_period_lines line ON line.period_id=previous.id
        WHERE previous.bin_warehouse_id=period.bin_warehouse_id AND previous.period_no=period.period_no-1
          AND line.goods_id=p_goods AND line.color_id IS NOT DISTINCT FROM p_color),0) END
    FROM workshop_material_periods period WHERE period.id=p_period
$$;

ALTER TABLE workshop_material_period_lines ADD COLUMN adjustment_qty NUMERIC(18,4) NOT NULL DEFAULT 0;
ALTER TABLE workshop_material_period_lines ALTER COLUMN actual_qty DROP EXPRESSION;
ALTER TABLE workshop_material_period_lines ADD CONSTRAINT wm_period_actual_with_adjustment_chk
    CHECK (actual_qty=opening_qty+transfer_in_qty-return_qty-other_issue_qty+adjustment_qty-closing_qty);
COMMENT ON COLUMN workshop_material_period_lines.adjustment_qty IS '本期已审批账面修正净额, 单列不作为领入或生产耗用';

-- 保持所有原守卫, 只增加新事实的派生与核对; 已结算历史记录不会被重写。
DO $period_formula$
DECLARE definition TEXT; anchor TEXT;
BEGIN
    definition := pg_get_functiondef('fn_guard_wm_period_line()'::regprocedure);
    anchor := E'BEGIN\n';
    IF (length(definition)-length(replace(definition,anchor,'')))/length(anchor)<>1 THEN
        RAISE EXCEPTION 'V768 period line guard anchor changed';
    END IF;
    definition := replace(definition,anchor,anchor || E'    IF TG_OP <> ''DELETE'' THEN\n'
        || E'        NEW.actual_qty := NEW.opening_qty+NEW.transfer_in_qty-NEW.return_qty-NEW.other_issue_qty+NEW.adjustment_qty-NEW.closing_qty;\n'
        || E'    END IF;\n');
    EXECUTE definition;
    definition := pg_get_functiondef('fn_assert_wm_period_line()'::regprocedure);
    anchor := 'IF line.opening_qty <> COALESCE(previous_closing, 0) THEN';
    IF position(anchor IN definition)=0 THEN RAISE EXCEPTION 'V768 opening assertion anchor changed'; END IF;
    definition := replace(definition,anchor,
        'IF line.opening_qty <> fn_workshop_material_period_opening(line.period_id,line.goods_id,line.color_id) THEN');
    anchor := '    SELECT COALESCE(sum(CASE posting.kind WHEN ''CONSUME''';
    IF position(anchor IN definition)=0 THEN RAISE EXCEPTION 'V768 adjustment assertion anchor changed'; END IF;
    definition := replace(definition,anchor,
        E'    IF line.adjustment_qty <> COALESCE((SELECT sum(posting.signed_qty)\n'
        || E'        FROM workshop_material_count_adjustment_postings posting WHERE posting.period_id=line.period_id\n'
        || E'          AND posting.goods_id=line.goods_id AND posting.color_id IS NOT DISTINCT FROM line.color_id\n'
        || E'          AND posting.kind=''ADJUSTMENT''),0) THEN\n'
        || E'        RAISE EXCEPTION ''期间账面修正与已批准盘点来源不一致'' USING ERRCODE=''23514'';\n'
        || E'    END IF;\n' || anchor);
    EXECUTE definition;
    definition := pg_get_functiondef('fn_workshop_material_bin_position(uuid)'::regprocedure);
    anchor := 'ledger.source_kind IN (''ISSUE'', ''RETURN'', ''OTHER_ISSUE'')';
    IF position(anchor IN definition)=0 THEN RAISE EXCEPTION 'V768 bin position anchor changed'; END IF;
    EXECUTE replace(definition,anchor,'ledger.source_kind IN (''ISSUE'', ''RETURN'', ''OTHER_ISSUE'', ''OPENING'', ''ADJUSTMENT'')');
    definition := pg_get_functiondef('fn_workshop_material_close_blockers(uuid)'::regprocedure);
    anchor := 'line.opening_qty + line.transfer_in_qty > 0';
    IF position(anchor IN definition)=0 THEN RAISE EXCEPTION 'V768 close source anchor changed'; END IF;
    EXECUTE replace(definition,anchor,'line.opening_qty + line.transfer_in_qty + GREATEST(line.adjustment_qty,0) > 0');
END;
$period_formula$;

DO $report$
DECLARE definition TEXT;
BEGIN
    definition := rtrim(pg_get_viewdef('v_workshop_material_period_report'::regclass,true),E';\n ');
    EXECUTE 'CREATE OR REPLACE VIEW v_workshop_material_period_report AS SELECT original.*,line.adjustment_qty FROM ('
        || definition || ') original JOIN workshop_material_period_lines line ON line.id=original.period_line_id';
END;
$report$;

CREATE FUNCTION fn_guard_workshop_count_adjustment() RETURNS trigger LANGUAGE plpgsql AS $$
DECLARE approved RECORD; current_period RECORD;
BEGIN
    IF TG_OP='DELETE' THEN RAISE EXCEPTION '已批准盘点过账不能删除' USING ERRCODE='23514'; END IF;
    IF TG_OP='UPDATE' THEN
        IF (to_jsonb(NEW)-'movement_id'-'signed_qty') IS DISTINCT FROM (to_jsonb(OLD)-'movement_id'-'signed_qty')
           OR OLD.movement_id IS NOT NULL OR NEW.movement_id IS NULL THEN
            RAISE EXCEPTION '已批准盘点过账只能回填一次库存流水' USING ERRCODE='23514';
        END IF;
        RETURN NEW;
    END IF;
    SELECT request.warehouse_id,request.reviewed_by,line.goods_id,line.color_id,line.unit_id,
           line.expected_qty,line.target_qty INTO approved
    FROM stock_count_requests request JOIN stock_count_request_lines line ON line.request_id=request.id
    JOIN stock_count_request_events event ON event.id=request.approval_event_id
    WHERE request.id=NEW.request_id AND line.id=NEW.line_id AND request.status='APPROVED'
      AND request.review_route='WAREHOUSE' AND event.id=NEW.approval_event_id
      AND event.request_id=request.id AND event.action='APPROVE' AND event.actor_id=request.reviewed_by
      AND event.request_version=request.row_version;
    IF NOT FOUND OR (approved.warehouse_id,approved.reviewed_by,approved.goods_id,approved.color_id,
            approved.unit_id,approved.expected_qty,approved.target_qty)
        IS DISTINCT FROM (NEW.bin_warehouse_id,NEW.created_by,NEW.goods_id,NEW.color_id,NEW.unit_id,NEW.before_qty,NEW.target_qty) THEN
        RAISE EXCEPTION '内料仓盘点缺少同一申请的有效仓库审核来源' USING ERRCODE='23514';
    END IF;
    SELECT period.* INTO current_period FROM workshop_material_periods period
    JOIN workshop_material_settings settings ON settings.periodic_bin_warehouse_id=period.bin_warehouse_id AND settings.periodic_enabled
    WHERE period.id=NEW.period_id AND period.bin_warehouse_id=NEW.bin_warehouse_id AND period.status='OPEN';
    IF NOT FOUND OR NEW.business_date<current_period.start_date THEN
        RAISE EXCEPTION '批准盘点只能记入当前未盘点期间' USING ERRCODE='23514';
    END IF;
    IF NOT EXISTS (SELECT 1 FROM goods WHERE id=NEW.goods_id AND issue_method='PERIODIC' AND unit_id=NEW.unit_id AND NOT is_deleted) THEN
        RAISE EXCEPTION '材料用途或基本单位已变化, 不能按原申请过账' USING ERRCODE='23514';
    END IF;
    IF NEW.kind='OPENING' AND (current_period.period_no<>1 OR NEW.before_qty<>0 OR EXISTS (
        SELECT 1 FROM v_workshop_material_bin_ledger ledger WHERE ledger.bin_warehouse_id=NEW.bin_warehouse_id
          AND ledger.goods_id=NEW.goods_id AND ledger.color_id IS NOT DISTINCT FROM NEW.color_id)
        OR EXISTS (SELECT 1 FROM stock_movements movement WHERE movement.warehouse_id=NEW.bin_warehouse_id
          AND movement.goods_id=NEW.goods_id AND movement.color_id IS NOT DISTINCT FROM NEW.color_id)) THEN
        RAISE EXCEPTION '这种材料已有库存历史, 应记录账面修正而不是上线期初' USING ERRCODE='23514';
    END IF;
    RETURN NEW;
END;
$$;
CREATE TRIGGER trg_guard_workshop_count_adjustment BEFORE INSERT OR UPDATE OR DELETE
    ON workshop_material_count_adjustment_postings FOR EACH ROW EXECUTE FUNCTION fn_guard_workshop_count_adjustment();
ALTER TABLE workshop_material_count_adjustment_postings ENABLE ALWAYS TRIGGER trg_guard_workshop_count_adjustment;

CREATE FUNCTION fn_assert_workshop_count_adjustment() RETURNS trigger LANGUAGE plpgsql AS $$
DECLARE posting workshop_material_count_adjustment_postings%ROWTYPE;
BEGIN
    SELECT * INTO posting FROM workshop_material_count_adjustment_postings WHERE id=NEW.id;
    IF posting.signed_qty=0 THEN
        IF posting.movement_id IS NOT NULL THEN RAISE EXCEPTION '零数量变化不能生成库存数量流水' USING ERRCODE='23514'; END IF;
    ELSIF NOT EXISTS (SELECT 1 FROM stock_movements movement WHERE movement.id=posting.movement_id
        AND movement.source_doc_type='STOCK_COUNT_REQUEST' AND movement.source_doc_id=posting.request_id
        AND movement.source_item_id=posting.line_id AND movement.movement_type=23
        AND movement.warehouse_id=posting.bin_warehouse_id AND movement.goods_id=posting.goods_id
        AND movement.unit_id=posting.unit_id AND movement.unit_rate=1
        AND movement.color_id IS NOT DISTINCT FROM posting.color_id AND movement.qty=abs(posting.signed_qty)
        AND movement.direction=CASE WHEN posting.signed_qty>0 THEN 1 ELSE -1 END) THEN
        RAISE EXCEPTION '批准盘点与实际库存流水不一致' USING ERRCODE='23514';
    END IF;
    RETURN NULL;
END;
$$;
CREATE CONSTRAINT TRIGGER trg_assert_workshop_count_adjustment AFTER INSERT OR UPDATE
    ON workshop_material_count_adjustment_postings DEFERRABLE INITIALLY DEFERRED
    FOR EACH ROW EXECUTE FUNCTION fn_assert_workshop_count_adjustment();
ALTER TABLE workshop_material_count_adjustment_postings ENABLE ALWAYS TRIGGER trg_assert_workshop_count_adjustment;

ALTER FUNCTION fn_workshop_material_bin_movement_authorized(TEXT,UUID,UUID,UUID,UUID,UUID,UUID,NUMERIC)
    RENAME TO fn_workshop_material_bin_movement_authorized_before_approved_count;
CREATE FUNCTION fn_workshop_material_bin_movement_authorized(
    p_kind TEXT,p_source UUID,p_doc UUID,p_item UUID,p_warehouse UUID,p_goods UUID,p_color UUID,p_qty NUMERIC)
RETURNS BOOLEAN LANGUAGE sql STABLE AS $$
    SELECT CASE WHEN p_kind IN ('COUNT_OPENING','COUNT_ADJUSTMENT_IN','COUNT_ADJUSTMENT_OUT') THEN EXISTS (
        SELECT 1 FROM workshop_material_count_adjustment_postings posting
        WHERE posting.id=p_source AND posting.xmin=pg_current_xact_id()::xid AND posting.movement_id IS NULL
          AND posting.request_id=p_doc AND posting.line_id=p_item AND posting.bin_warehouse_id=p_warehouse
          AND posting.goods_id=p_goods AND posting.color_id IS NOT DISTINCT FROM p_color
          AND abs(posting.signed_qty)=p_qty AND p_qty>0
          AND CASE p_kind WHEN 'COUNT_OPENING' THEN posting.kind='OPENING' AND posting.signed_qty>0
              WHEN 'COUNT_ADJUSTMENT_IN' THEN posting.kind='ADJUSTMENT' AND posting.signed_qty>0
              ELSE posting.kind='ADJUSTMENT' AND posting.signed_qty<0 END)
    ELSE fn_workshop_material_bin_movement_authorized_before_approved_count(p_kind,p_source,p_doc,p_item,p_warehouse,p_goods,p_color,p_qty) END
$$;

SELECT fn_audit_track_table('workshop_material_count_adjustment_postings','FULL','data_change',false);
DO $reset$
DECLARE definition TEXT; anchor TEXT := '(''stock_movements'', ''CLEAR'')';
BEGIN
    definition := pg_get_functiondef('business_data_reset()'::regprocedure);
    IF (length(definition)-length(replace(definition,anchor,'')))/length(anchor)<>1 THEN
        RAISE EXCEPTION 'V768 reset policy anchor changed';
    END IF;
    EXECUTE replace(definition,anchor,anchor || E',\n            (''workshop_material_count_adjustment_postings'', ''CLEAR'')');
END;
$reset$;
