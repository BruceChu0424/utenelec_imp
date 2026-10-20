-- First assignment of a missing basic unit through an explicitly confirmed engineering task.
-- Existing non-null units and every non-BOM quantity reference remain immutable (V675/ADR-106).
-- The existing rd_tasks audit trail records selected unit, old legacy identity and human evidence;
-- no quantity, conversion rate, stock ledger, source allocation or historical document is rewritten.
ALTER TABLE rd_tasks ADD COLUMN initial_unit_id UUID REFERENCES units(id),
    ADD COLUMN initial_unit_evidence TEXT,
    ADD COLUMN initial_unit_actor_id UUID,
    ADD COLUMN initial_unit_legacy_id INTEGER,
    ADD COLUMN initial_unit_applied_at TIMESTAMPTZ;
ALTER TABLE rd_tasks ADD CONSTRAINT rd_tasks_initial_unit_receipt_complete CHECK (
    (initial_unit_id IS NULL AND initial_unit_evidence IS NULL AND initial_unit_actor_id IS NULL
        AND initial_unit_applied_at IS NULL AND initial_unit_legacy_id IS NULL)
    OR (initial_unit_id IS NOT NULL AND initial_unit_evidence IS NOT NULL
        AND char_length(btrim(initial_unit_evidence)) BETWEEN 2 AND 1000
        AND initial_unit_actor_id IS NOT NULL AND initial_unit_applied_at IS NOT NULL));
CREATE FUNCTION fn_rd_initial_unit_receipt_immutable() RETURNS trigger LANGUAGE plpgsql AS $receipt$
BEGIN
    IF OLD.initial_unit_id IS NOT NULL AND ROW(NEW.initial_unit_id,NEW.initial_unit_evidence,
            NEW.initial_unit_actor_id,NEW.initial_unit_legacy_id,NEW.initial_unit_applied_at)
        IS DISTINCT FROM ROW(OLD.initial_unit_id,OLD.initial_unit_evidence,OLD.initial_unit_actor_id,
            OLD.initial_unit_legacy_id,OLD.initial_unit_applied_at) THEN
        RAISE EXCEPTION USING ERRCODE='23514',MESSAGE='首次基本单位核对回执只能保留，不能修改或清空';
    END IF;
    RETURN NEW;
END;
$receipt$;
CREATE TRIGGER trg_rd_initial_unit_receipt_immutable BEFORE UPDATE ON rd_tasks
    FOR EACH ROW WHEN (OLD.initial_unit_id IS NOT NULL) EXECUTE FUNCTION fn_rd_initial_unit_receipt_immutable();

CREATE FUNCTION fn_rd_master_issue_resolved(p_goods UUID) RETURNS BOOLEAN LANGUAGE sql STABLE AS $master$
    SELECT EXISTS(SELECT 1 FROM goods g JOIN units u ON u.id=g.unit_id AND NOT u.is_deleted
        WHERE g.id=p_goods AND NOT g.is_deleted
          AND ((g.color_id IS NOT NULL AND EXISTS(SELECT 1 FROM colors c WHERE c.id=g.color_id AND NOT c.is_deleted))
               OR (g.color_id IS NULL AND NULLIF(g.color_legacy_id,0) IS NULL)));
$master$;

CREATE FUNCTION fn_goods_non_bom_quantity_in_use(p_goods_id UUID)
RETURNS BOOLEAN LANGUAGE plpgsql VOLATILE AS $body$
DECLARE source RECORD; column_name TEXT; goods_match TEXT; probe_sql TEXT := ''; used BOOLEAN;
BEGIN
    FOR source IN SELECT * FROM fn_goods_quantity_reference_sources()
                  WHERE relation_name <> 'goods_bom_items' ORDER BY relation_name LOOP
        goods_match := '';
        FOREACH column_name IN ARRAY source.goods_columns LOOP
            goods_match := goods_match || CASE WHEN goods_match='' THEN '' ELSE ' OR ' END
                || format('n.%I=$1',column_name);
        END LOOP;
        probe_sql := probe_sql || CASE WHEN probe_sql='' THEN '' ELSE ' UNION ALL ' END
            || format('SELECT 1 FROM %I n WHERE (%s) AND (%s)',source.relation_name,goods_match,source.row_predicate);
    END LOOP;
    EXECUTE 'SELECT EXISTS (' || probe_sql || ')' INTO used USING p_goods_id;
    RETURN used;
END;
$body$;

CREATE OR REPLACE FUNCTION fn_guard_goods_quantity_unit() RETURNS trigger
LANGUAGE plpgsql AS $guard$
DECLARE task_text TEXT := current_setting('app.goods_unit_reconcile_task',true);
BEGIN
    PERFORM 1 FROM goods WHERE id=OLD.id FOR UPDATE;
    IF OLD.unit_id IS NULL AND NEW.unit_id IS NOT NULL
       AND NULLIF(task_text,'') IS NOT NULL
       AND EXISTS(SELECT 1 FROM rd_tasks t WHERE t.id::text=task_text AND t.goods_id=OLD.id
           AND t.source_doc_type='MATERIAL_ANALYSIS_MASTER_ISSUE' AND t.category='OTHER'
           AND t.status IN ('OPEN','IN_PROGRESS') AND NOT t.is_deleted AND t.initial_unit_id=NEW.unit_id)
       AND EXISTS(SELECT 1 FROM units u WHERE u.id=NEW.unit_id AND NOT u.is_deleted AND u.status='使用')
       AND NOT fn_goods_non_bom_quantity_in_use(OLD.id) THEN
        RETURN NEW;
    END IF;
    IF fn_goods_quantity_unit_in_use(OLD.id) THEN
        IF OLD.unit_id IS NULL THEN
            RAISE EXCEPTION USING ERRCODE='23514',CONSTRAINT='goods_quantity_unit_immutable',
                MESSAGE='该货品已有数量记录，但历史基本单位尚未核对，不能在普通编辑中补选或改写单位。请先由管理员按原始单据受控核对。';
        END IF;
        RAISE EXCEPTION USING ERRCODE='23514',CONSTRAINT='goods_quantity_unit_immutable',
            MESSAGE='该货品已有数量记录或组装引用，基本单位不能再改。请保留原单位；不同计量规格请新建货品。';
    END IF;
    RETURN NEW;
END;
$guard$;

CREATE FUNCTION fn_reconcile_goods_initial_basic_unit(
    p_task UUID,p_expected_version BIGINT,p_unit UUID,p_evidence TEXT,p_actor UUID)
RETURNS INTEGER LANGUAGE plpgsql AS $repair$
DECLARE task rd_tasks%ROWTYPE; master goods%ROWTYPE; selected units%ROWTYPE;
        legacy_bridge UUID; decision TEXT; previous_task TEXT; other_problem BOOLEAN;
BEGIN
    IF p_expected_version IS NULL OR p_expected_version<1 OR p_actor IS NULL THEN
        RAISE EXCEPTION USING ERRCODE='23514',MESSAGE='任务版本或操作人无效，请重新加载任务';
    END IF;
    SELECT * INTO task FROM rd_tasks WHERE id=p_task AND NOT is_deleted FOR UPDATE;
    IF NOT FOUND OR task.source_doc_type IS DISTINCT FROM 'MATERIAL_ANALYSIS_MASTER_ISSUE'
       OR task.category IS DISTINCT FROM 'OTHER' OR task.goods_id IS NULL THEN
        RAISE EXCEPTION USING ERRCODE='23514',MESSAGE='该任务不支持首次基本单位核对';
    END IF;
    IF char_length(btrim(COALESCE(p_evidence,''))) NOT BETWEEN 2 AND 1000 THEN
        RAISE EXCEPTION USING ERRCODE='23514',MESSAGE='请填写原始资料和人工核对依据(2-1000字)';
    END IF;
    SELECT * INTO master FROM goods WHERE id=task.goods_id AND NOT is_deleted FOR UPDATE;
    IF NOT FOUND THEN RAISE EXCEPTION USING ERRCODE='23514',MESSAGE='货品已变化，请重新加载任务'; END IF;
    -- Receipt identity is independent of subsequent unit renames, retirement, forwarding or task edits.
    IF task.initial_unit_id=p_unit AND master.unit_id=p_unit
       AND task.initial_unit_evidence=btrim(p_evidence) AND task.initial_unit_actor_id=p_actor THEN RETURN 0; END IF;
    SELECT * INTO selected FROM units WHERE id=p_unit AND NOT is_deleted AND status='使用' FOR SHARE;
    IF NOT FOUND THEN RAISE EXCEPTION USING ERRCODE='23514',MESSAGE='请选择有效且使用中的基本单位'; END IF;
    decision := '首次基本单位核对：' || COALESCE(selected.name,selected.code,p_unit::text) || '(' || p_unit || ')；原历史单位='
        || COALESCE(master.unit_legacy_id::text,'无') || '；依据：' || btrim(p_evidence);
    IF task.status NOT IN ('OPEN','IN_PROGRESS') OR task.row_version<>p_expected_version THEN
        RAISE EXCEPTION USING ERRCODE='23514',MESSAGE='任务已变化，请重新加载后核对';
    END IF;
    IF master.unit_id IS NOT NULL THEN
        RAISE EXCEPTION USING ERRCODE='23514',MESSAGE='已有基本单位不能通过首次核对更换';
    END IF;
    IF fn_goods_non_bom_quantity_in_use(master.id) THEN
        RAISE EXCEPTION USING ERRCODE='23514',MESSAGE='货品已有BOM以外的数量事实，不能猜补历史基本单位；请按原始单据受控核对或修正BOM货品映射';
    END IF;
    -- A surviving UUID bridge is authoritative. An unmapped historical number is retained in the evidence;
    -- the engineer must explicitly select a unit and describe the original source, with no default guess.
    IF NULLIF(master.unit_legacy_id,0) IS NOT NULL THEN
        SELECT id INTO legacy_bridge FROM units WHERE legacy_id=master.unit_legacy_id FOR SHARE;
        IF legacy_bridge IS NOT NULL AND legacy_bridge<>p_unit THEN
            RAISE EXCEPTION USING ERRCODE='23514',MESSAGE='所选单位与原历史单位桥接不一致，请核对原始资料';
        END IF;
    END IF;
    previous_task := current_setting('app.goods_unit_reconcile_task',true);
    UPDATE rd_tasks SET initial_unit_id=p_unit,initial_unit_evidence=btrim(p_evidence),
        initial_unit_actor_id=p_actor,initial_unit_legacy_id=master.unit_legacy_id,initial_unit_applied_at=clock_timestamp()
        WHERE id=p_task;
    PERFORM set_config('app.goods_unit_reconcile_task',p_task::text,true);
    -- Keep unit_legacy_id as original evidence. Runtime identity uses the selected authoritative UUID.
    UPDATE goods SET unit_id=p_unit,version=version+1,updated_at=now(),updated_by=p_actor WHERE id=master.id;
    PERFORM set_config('app.goods_unit_reconcile_task',COALESCE(previous_task,''),true);
    -- A target task can also contain a missing legacy color or a deleted main color.
    -- Assigning a unit must not falsely close those independent master-data findings.
    other_problem := NOT fn_rd_master_issue_resolved(master.id);
    UPDATE rd_tasks SET status=CASE WHEN other_problem THEN 'IN_PROGRESS' ELSE 'DONE' END,
        completed_at=CASE WHEN other_problem THEN NULL ELSE now() END,close_note=decision,
        row_version=row_version+1,updated_at=now(),updated_by=p_actor WHERE id=p_task;
    RETURN CASE WHEN other_problem THEN 2 ELSE 1 END;
END;
$repair$;
