-- Disabled materials leave every current recipe, while historical execution
-- snapshots and the retired edge identities remain available for traceability.
-- Statement-level retirement also supports disabling parent and child together.

ALTER TABLE goods_bom_items ADD COLUMN retirement_reason TEXT;
ALTER TABLE goods_bom_items ADD COLUMN retirement_resolved_at TIMESTAMPTZ;
ALTER TABLE goods_bom_items ADD CONSTRAINT ck_goods_bom_retirement_reason
    CHECK (retirement_reason IS NULL OR retirement_reason='COMPONENT_DISABLED');
COMMENT ON COLUMN goods_bom_items.retirement_reason IS
    'Why the recipe edge was retired; COMPONENT_DISABLED prevents an accidental material-free production route.';
COMMENT ON COLUMN goods_bom_items.retirement_resolved_at IS
    'A usable production recipe remained or was subsequently established; retain the original retirement reason.';

CREATE FUNCTION fn_resolve_disabled_bom_retirements(p_parents UUID[]) RETURNS VOID LANGUAGE sql AS $$
    UPDATE goods_bom_items retired SET retirement_resolved_at=clock_timestamp()
    WHERE retired.goods_id=ANY(p_parents) AND retired.is_deleted
      AND retired.retirement_reason='COMPONENT_DISABLED' AND retired.retirement_resolved_at IS NULL
      AND EXISTS(SELECT 1 FROM goods_bom_items live JOIN goods material ON material.id=live.component_goods_id
          WHERE live.goods_id=retired.goods_id AND NOT live.is_deleted AND live.qty>0 AND live.hard_gate
            AND live.control_stage IN('START','ASSEMBLY','FINISH')
            AND material.issue_method='ORDER' AND NOT material.is_deleted AND NOT material.auto_created
            AND material.status IS DISTINCT FROM '禁用')
$$;

CREATE FUNCTION fn_resolve_disabled_bom_after_write() RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
    PERFORM fn_resolve_disabled_bom_retirements(ARRAY[NEW.goods_id]);
    RETURN NULL;
END $$;
CREATE TRIGGER trg_resolve_disabled_bom_retirements AFTER INSERT OR UPDATE ON goods_bom_items
    FOR EACH ROW WHEN (NOT NEW.is_deleted AND NEW.hard_gate
        AND NEW.control_stage IN('START','ASSEMBLY','FINISH'))
    EXECUTE FUNCTION fn_resolve_disabled_bom_after_write();

CREATE FUNCTION fn_retire_disabled_goods_bom(p_components UUID[]) RETURNS VOID LANGUAGE plpgsql AS $$
DECLARE parents UUID[]; parent_id UUID; event_id UUID;
BEGIN
    IF COALESCE(cardinality(p_components),0)=0 THEN RETURN; END IF;
    -- KEY SHARE (used by existing import/learning paths) does not conflict with
    -- a status-only UPDATE. Upgrade explicitly before inspecting incoming edges.
    -- Fail promptly on contention instead of introducing parent/component waits.
    PERFORM id FROM goods WHERE id=ANY(p_components) AND status='禁用'
        ORDER BY id FOR UPDATE NOWAIT;
    SELECT array_agg(DISTINCT edge.goods_id ORDER BY edge.goods_id) INTO parents
    FROM goods_bom_items edge JOIN goods component ON component.id=edge.component_goods_id
    WHERE edge.component_goods_id=ANY(p_components) AND component.status='禁用' AND NOT edge.is_deleted;
    IF parents IS NULL THEN RETURN; END IF;
    PERFORM id FROM goods WHERE id=ANY(parents) ORDER BY id FOR NO KEY UPDATE NOWAIT;

    UPDATE goods_bom_items edge
    SET is_deleted=TRUE, deleted_at=clock_timestamp(), updated_at=clock_timestamp(),
        updated_by=COALESCE(NULLIF(current_setting('app.actor_id',TRUE),'')::uuid,edge.updated_by),
        learning_released_at=COALESCE(edge.learning_released_at,clock_timestamp()),
        retirement_reason='COMPONENT_DISABLED', retirement_resolved_at=NULL
    FROM goods component
    WHERE component.id=edge.component_goods_id AND component.id=ANY(p_components)
      AND component.status='禁用' AND NOT edge.is_deleted;

    -- A partial retirement with other production materials is already a usable
    -- recipe. Only an actually emptied recipe stays pending after refresh.
    PERFORM fn_resolve_disabled_bom_retirements(parents);

    -- Always advance the recipe version, including zero-price removals. A stale
    -- import token or an open editor must not overwrite the new composition.
    UPDATE goods SET source_e=fn_goods_bom_material_cost(id), version=version+1,
        updated_at=clock_timestamp(),
        updated_by=COALESCE(NULLIF(current_setting('app.actor_id',TRUE),'')::uuid,updated_by)
    WHERE id=ANY(parents);
    FOREACH parent_id IN ARRAY parents LOOP
        event_id:=gen_random_uuid();
        INSERT INTO business_outbox(id,event_type,aggregate_type,aggregate_id,payload,dedupe_key)
        VALUES(event_id,'GOODS_BOM_UPDATED','GOODS_BOM',parent_id,
            jsonb_build_object('reason','COMPONENT_DISABLED'),'BOM_DISABLED:'||event_id);
    END LOOP;
END $$;

CREATE FUNCTION fn_retire_disabled_goods_bom(p_component UUID) RETURNS VOID LANGUAGE sql AS $$
    SELECT fn_retire_disabled_goods_bom(ARRAY[p_component])
$$;

CREATE FUNCTION fn_fence_goods_bom_disabling() RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
    PERFORM id FROM goods WHERE id=NEW.id FOR UPDATE NOWAIT;
    RETURN NEW;
END $$;
CREATE TRIGGER trg_goods_bom_disable_fence BEFORE UPDATE OF status ON goods
    FOR EACH ROW WHEN (NEW.status='禁用' AND OLD.status IS DISTINCT FROM NEW.status)
    EXECUTE FUNCTION fn_fence_goods_bom_disabling();

CREATE FUNCTION fn_retire_goods_bom_after_status() RETURNS trigger LANGUAGE plpgsql AS $$
DECLARE components UUID[];
BEGIN
    SELECT array_agg(changed.id ORDER BY changed.id) INTO components
    FROM new_goods_status changed JOIN old_goods_status previous USING(id)
    WHERE changed.status='禁用' AND previous.status IS DISTINCT FROM changed.status;
    PERFORM fn_retire_disabled_goods_bom(components);
    RETURN NULL;
END $$;
CREATE TRIGGER trg_goods_bom_disabled_retirement AFTER UPDATE ON goods
    REFERENCING OLD TABLE AS old_goods_status NEW TABLE AS new_goods_status
    FOR EACH STATEMENT EXECUTE FUNCTION fn_retire_goods_bom_after_status();

-- Cover every BOM write path, including import, operation replay, restore and
-- future callers. A disabled parent may retain its own recipe for later review.
CREATE OR REPLACE FUNCTION guard_goods_bom_operational_goods() RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
    IF NOT NEW.is_deleted THEN
        PERFORM id FROM goods WHERE id=NEW.component_goods_id FOR SHARE NOWAIT;
        IF EXISTS(SELECT 1 FROM goods g WHERE g.id IN(NEW.goods_id,NEW.component_goods_id)
                    AND (g.auto_created OR g.is_deleted)) THEN
            RAISE EXCEPTION 'active BOM parent/component must be a non-placeholder active goods record'
                USING ERRCODE='23514';
        END IF;
        IF EXISTS(SELECT 1 FROM goods WHERE id=NEW.component_goods_id AND status='禁用') THEN
            RAISE EXCEPTION '组件货品已停用，不能加入或恢复组装信息，请启用货品后重新核对配方'
                USING ERRCODE='23514',CONSTRAINT='goods_bom_component_enabled';
        END IF;
    END IF;
    RETURN NEW;
END $$;

-- Learning must skip retired materials without failing unrelated production
-- settlement or resurrecting a recipe when the goods is enabled again.
DO $publisher$
DECLARE definition TEXT; anchors TEXT[]; replacements TEXT[]; i INTEGER;
BEGIN
    definition:=replace(pg_get_functiondef('fn_publish_learned_bom(uuid,boolean)'::regprocedure),chr(13),'');
    anchors:=ARRAY[
        'OR parent.is_deleted OR parent.auto_created THEN RETURN;',
        'AND material.issue_method=''ORDER'')',
        'component.is_deleted OR component.auto_created OR component.issue_method<>''ORDER''',
        'ORDER BY component.id FOR KEY SHARE;'
    ];
    replacements:=ARRAY[
        'OR parent.is_deleted OR parent.auto_created OR parent.status=''禁用'' THEN RETURN;',
        'AND material.issue_method=''ORDER'' AND material.status IS DISTINCT FROM ''禁用'')',
        'component.is_deleted OR component.auto_created OR component.status=''禁用'' OR component.issue_method<>''ORDER''',
        'ORDER BY component.id FOR SHARE;'
    ];
    FOR i IN 1..cardinality(anchors) LOOP
        IF position(anchors[i] IN definition)=0 THEN
            RAISE EXCEPTION 'V903 learned BOM publisher anchor % changed',i;
        END IF;
        definition:=replace(definition,anchors[i],replacements[i]);
    END LOOP;
    EXECUTE definition;
END
$publisher$;

-- V871 stores complete row tokens. Old snapshots predate these two nullable
-- columns: compare them with their schema defaults, without rewriting retained
-- before/after evidence or accepting any changed non-null retirement metadata.
CREATE FUNCTION fn_goods_bom_history_schema(p_row JSONB,p_table TEXT) RETURNS JSONB
LANGUAGE sql IMMUTABLE AS $$
    SELECT CASE WHEN p_row IS NULL THEN NULL
        WHEN p_table='goods_bom_items' THEN
            jsonb_build_object('retirement_reason',NULL,'retirement_resolved_at',NULL)||p_row
        ELSE p_row END
$$;
DO $history$
DECLARE definition TEXT; anchors TEXT[]; replacements TEXT[]; i INTEGER;
BEGIN
    definition:=replace(pg_get_functiondef('fn_replay_goods_operation(uuid,uuid,bigint,boolean)'::regprocedure),chr(13),'');
    anchors:=ARRAY[
        'IF actual IS DISTINCT FROM r.expected_row THEN',
        'SELECT *,CASE WHEN p_undo THEN before_row ELSE after_row END AS target_row',
        'token:=CASE WHEN p_undo THEN r.before_token ELSE r.after_token END;',
        'expected_row=token', 'before_token=token', 'after_token=token'
    ];
    replacements:=ARRAY[
        'IF actual IS DISTINCT FROM fn_goods_bom_history_schema(r.expected_row,r.table_name) THEN',
        'SELECT *,fn_goods_bom_history_schema(CASE WHEN p_undo THEN before_row ELSE after_row END,table_name) AS target_row',
        'token:=fn_goods_bom_history_schema(CASE WHEN p_undo THEN r.before_token ELSE r.after_token END,r.table_name);',
        'fn_goods_bom_history_schema(expected_row,table_name)=token',
        'fn_goods_bom_history_schema(before_token,table_name)=token',
        'fn_goods_bom_history_schema(after_token,table_name)=token'
    ];
    FOR i IN 1..cardinality(anchors) LOOP
        IF position(anchors[i] IN definition)=0 THEN
            RAISE EXCEPTION 'V903 goods history schema anchor % changed',i;
        END IF;
        definition:=replace(definition,anchors[i],replacements[i]);
    END LOOP;
    EXECUTE definition;
END
$history$;

-- One forward repair of existing live references; no production, purchase,
-- warehouse, inventory or historical actual-consumption rows are rewritten.
SELECT fn_retire_disabled_goods_bom(array_agg(id ORDER BY id)) FROM goods WHERE status='禁用';
