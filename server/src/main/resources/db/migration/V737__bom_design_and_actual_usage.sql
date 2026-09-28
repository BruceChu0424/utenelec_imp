-- ADR-129: BOM design usage (goods_bom_items.qty) and learned actual usage.
-- The actual usage of every in-house produced parent is learned from the
-- physical material ledger and exposed through one view; planning readers take
-- the calculated quantity from that view. V711's learning objects are rebuilt
-- here (the applied V711 bytes stay unchanged) and replayed from ledger facts.

-- ---------------------------------------------------------------------------
-- 1. Per-edge ownership history and the new columns.
-- ---------------------------------------------------------------------------
ALTER TABLE goods_bom_items ADD COLUMN learning_released_at TIMESTAMPTZ;
COMMENT ON COLUMN goods_bom_items.qty IS
    '设计使用数量：每个父件基本单位用多少组件基本单位；系统学习边由系统同步为真实使用数量';
COMMENT ON COLUMN goods_bom_items.learning_released_at IS
    '人工删除该组件边的时间；学习不再自动把该组件加回父件配方';

-- A report line's defective pieces (same unit as qty). Recorded only: good
-- output, stock, FQC, over-production and direct-transfer splits never read it.
-- An operator-entered batch keeps its defects on its first server slice.
ALTER TABLE production_daily_report_items
    ADD COLUMN defect_qty NUMERIC(18,4) NOT NULL DEFAULT 0 CHECK(defect_qty>=0),
    ADD CONSTRAINT daily_report_defect_needs_good_output
        CHECK(defect_qty=0 OR (execution_segment_id IS NOT NULL AND qty>0));
COMMENT ON COLUMN production_daily_report_items.defect_qty IS
    '报工不良数(与数量同单位)；只记录，不进良品数、库存、FQC、超产与分流；学习用它派生实产单耗与不良率';
CREATE FUNCTION fn_assert_daily_report_batch_defect() RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
    IF NEW.output_batch_id IS NOT NULL AND NEW.defect_qty>0 AND NOT NEW.is_deleted AND EXISTS(
        SELECT 1 FROM production_daily_report_items other
        WHERE other.output_batch_id=NEW.output_batch_id AND other.id<>NEW.id AND NOT other.is_deleted
          AND ((COALESCE(other.line_no,2147483647),other.id)<(COALESCE(NEW.line_no,2147483647),NEW.id)
               OR other.defect_qty>0)) THEN
        RAISE EXCEPTION 'Defects of a production batch belong to its first slice'
            USING ERRCODE='23514',CONSTRAINT='daily_report_defect_first_slice';
    END IF;
    RETURN NULL;
END;
$$;
CREATE CONSTRAINT TRIGGER trg_assert_daily_report_batch_defect
AFTER INSERT OR UPDATE OF defect_qty,output_batch_id,line_no,is_deleted ON production_daily_report_items
DEFERRABLE INITIALLY DEFERRED FOR EACH ROW
WHEN (NEW.defect_qty>0 AND NEW.output_batch_id IS NOT NULL AND NOT NEW.is_deleted)
EXECUTE FUNCTION fn_assert_daily_report_batch_defect();

-- V711 took a whole parent over on the first manual edit but left the edge
-- marked as learned. Such parents keep their manual values: the learned edges
-- become manual edges and the deleted ones are never automatically restored.
SELECT set_config('app.bom_learning_write','on',TRUE);
-- The learned-edge badge comes from learning_profile_goods_id, not a fixed
-- note. Cleared first, so edges converted to manual below lose it too.
UPDATE goods_bom_items SET summary=NULL
WHERE learning_profile_goods_id IS NOT NULL AND summary='按已完工实际净领用累计学习';
UPDATE goods_bom_items edge SET learning_profile_goods_id=NULL, learning_unit_id=NULL
FROM goods_bom_learning_profiles profile
WHERE profile.goods_id=edge.goods_id AND edge.learning_profile_goods_id=edge.goods_id
  AND NOT edge.is_deleted AND (NOT profile.enabled OR profile.blocked_reason='MANUAL_BOM');
UPDATE goods_bom_items edge SET learning_released_at=COALESCE(edge.deleted_at,now())
FROM goods_bom_learning_profiles profile
WHERE profile.goods_id=edge.goods_id AND edge.learning_profile_goods_id=edge.goods_id
  AND edge.is_deleted AND (NOT profile.enabled OR profile.blocked_reason='MANUAL_BOM');
SELECT set_config('app.bom_learning_write','',TRUE);

-- ---------------------------------------------------------------------------
-- 2. Retire V711 learning objects that are replaced below.
-- ---------------------------------------------------------------------------
DROP FUNCTION fn_touch_bom_learning() CASCADE;
DROP FUNCTION fn_drain_bom_learning_queue() CASCADE;
DROP FUNCTION fn_bom_learning_manual_ownership() CASCADE;
DROP FUNCTION fn_refresh_bom_learning(UUID);
DROP FUNCTION fn_publish_learned_bom(UUID);
DROP FUNCTION fn_enqueue_bom_learning(UUID);
DROP TABLE goods_bom_learning_material_totals;
TRUNCATE production_bom_learning_refresh_queue, production_bom_learning_samples;
ALTER TABLE goods_bom_learning_profiles DROP COLUMN enabled,
    ADD COLUMN total_defect_qty NUMERIC(30,10) NOT NULL DEFAULT 0 CHECK(total_defect_qty>=0);
UPDATE goods_bom_learning_profiles SET total_output_qty=0, sample_count=0, blocked_reason=NULL,
    revision=revision+1, updated_at=now();

-- One queue row per family per transaction. The family is serialized when the
-- queue drains, never by an uncommitted key of another transaction.
ALTER TABLE production_bom_learning_refresh_queue
    DROP CONSTRAINT production_bom_learning_refresh_queue_pkey,
    DROP CONSTRAINT production_bom_learning_refresh_queue_goods_id_fkey,
    ADD CONSTRAINT production_bom_learning_refresh_queue_pkey PRIMARY KEY(transaction_id,execution_root_id),
    ADD CONSTRAINT production_bom_learning_refresh_queue_goods_id_fkey FOREIGN KEY(goods_id) REFERENCES goods(id);
ALTER TABLE production_bom_learning_samples
    ADD COLUMN discovery BOOLEAN NOT NULL DEFAULT FALSE,
    ADD COLUMN fully_cleared BOOLEAN NOT NULL DEFAULT FALSE,
    ADD COLUMN entry_generations JSONB NOT NULL DEFAULT '{}'::jsonb,
    ADD COLUMN defect_qty NUMERIC(30,10) NOT NULL DEFAULT 0 CHECK(defect_qty>=0);
COMMENT ON COLUMN production_bom_learning_samples.entry_generations IS
    '每个(组件|单位)首次计入时的学习轮次；只增不删，重新学习前的族以后变动只移动基线';

-- ---------------------------------------------------------------------------
-- 3. Learned actual usage: one row per parent, component and component unit.
-- Colors of one material are one usage; exposure counts a family once.
-- ---------------------------------------------------------------------------
CREATE TABLE goods_bom_actual_usages (
    goods_id UUID NOT NULL REFERENCES goods(id),
    component_goods_id UUID NOT NULL REFERENCES goods(id),
    unit_id UUID NOT NULL REFERENCES units(id),
    output_unit_id UUID NOT NULL REFERENCES units(id),
    net_qty NUMERIC(30,10) NOT NULL DEFAULT 0 CHECK(net_qty>=0),
    exposure_output_qty NUMERIC(30,10) NOT NULL DEFAULT 0 CHECK(exposure_output_qty>=0),
    exposure_defect_qty NUMERIC(30,10) NOT NULL DEFAULT 0 CHECK(exposure_defect_qty>=0),
    sample_count BIGINT NOT NULL DEFAULT 0 CHECK(sample_count>=0),
    baseline_net_qty NUMERIC(30,10) NOT NULL DEFAULT 0 CHECK(baseline_net_qty>=0),
    baseline_exposure_output_qty NUMERIC(30,10) NOT NULL DEFAULT 0 CHECK(baseline_exposure_output_qty>=0),
    baseline_exposure_defect_qty NUMERIC(30,10) NOT NULL DEFAULT 0 CHECK(baseline_exposure_defect_qty>=0),
    baseline_sample_count BIGINT NOT NULL DEFAULT 0 CHECK(baseline_sample_count>=0),
    learning_generation INTEGER NOT NULL DEFAULT 0 CHECK(learning_generation>=0),
    relearned_at TIMESTAMPTZ,
    relearned_by UUID,
    actual_qty NUMERIC GENERATED ALWAYS AS (
        CASE WHEN exposure_output_qty-baseline_exposure_output_qty>0 AND net_qty-baseline_net_qty>0
             THEN (net_qty-baseline_net_qty)/(exposure_output_qty-baseline_exposure_output_qty) END) STORED,
    updated_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    PRIMARY KEY(goods_id,component_goods_id,unit_id),
    CHECK(net_qty>=baseline_net_qty AND exposure_output_qty>=baseline_exposure_output_qty
          AND exposure_defect_qty>=baseline_exposure_defect_qty AND sample_count>=baseline_sample_count)
);
CREATE INDEX idx_goods_bom_actual_usages_component ON goods_bom_actual_usages(component_goods_id);
COMMENT ON TABLE goods_bom_actual_usages IS
    '真实使用数量：本厂生产族核清后的实物净耗累计 / 用到该物料的族产量累计；重新学习以基线扣除旧数据';
COMMENT ON COLUMN goods_bom_actual_usages.actual_qty IS
    '每个父件基本单位的真实使用数量(组件基本单位)；没有有效样本时为空，计算回退到设计使用数量';
COMMENT ON COLUMN goods_bom_actual_usages.exposure_defect_qty IS
    '用到该物料的族报工不良数累计(父件基本单位)；真实使用数量仍按良品算，不良只派生实产单耗与不良率';
COMMENT ON COLUMN goods_bom_actual_usages.learning_generation IS
    '学习轮次：每次重新学习加一；更早轮次计入的族以后再变动时，累计与基线同步移动，窗口只含本轮数据';

-- ---------------------------------------------------------------------------
-- 4. The single definitions: one learned usage row, then one BOM edge.
-- ---------------------------------------------------------------------------
-- Status and window (total minus relearn baseline) of one learned usage row.
CREATE VIEW v_goods_bom_actual_usage AS
SELECT usage.goods_id,
       usage.component_goods_id,
       usage.unit_id,
       usage.output_unit_id,
       state.actual_status,
       CASE WHEN state.actual_status='ACTUAL' THEN usage.actual_qty END AS actual_qty,
       usage.net_qty-usage.baseline_net_qty AS net_qty,
       usage.exposure_output_qty-usage.baseline_exposure_output_qty AS exposure_output_qty,
       usage.sample_count-usage.baseline_sample_count AS sample_count,
       produced.defect_qty,
       CASE WHEN state.actual_status='ACTUAL'
            THEN (usage.net_qty-usage.baseline_net_qty)/produced.produced_qty END AS actual_per_produced_qty,
       CASE WHEN produced.produced_qty>0 THEN produced.defect_qty/produced.produced_qty END AS defect_rate,
       usage.updated_at,
       usage.relearned_at,
       usage.relearned_by
FROM goods_bom_actual_usages usage
JOIN goods parent ON parent.id=usage.goods_id
CROSS JOIN LATERAL (
    SELECT CASE
               WHEN usage.actual_qty IS NULL THEN 'NO_DATA'
               WHEN usage.output_unit_id IS DISTINCT FROM parent.unit_id THEN 'OUTPUT_UNIT_CHANGED'
               ELSE 'ACTUAL'
           END AS actual_status
) state
CROSS JOIN LATERAL (
    -- Produced = good + defective output of the exposed families in this window.
    SELECT usage.exposure_defect_qty-usage.baseline_exposure_defect_qty AS defect_qty,
           usage.exposure_output_qty-usage.baseline_exposure_output_qty
               +usage.exposure_defect_qty-usage.baseline_exposure_defect_qty AS produced_qty
) produced;
COMMENT ON VIEW v_goods_bom_actual_usage IS
    '一条真实使用数量的状态与本轮窗口(累计减重新学习基线)，以及不良数、实产单耗(净耗 / (良品+不良))与不良率；BOM 边视图、学习发布与学习记录都读它(ADR-129)';

-- How much per parent unit a BOM edge uses. Only a linear edge (per unit, or
-- per package with partial packages) can take the per-unit average.
CREATE VIEW v_goods_bom_item_usage AS
SELECT edge.id AS bom_item_id,
       edge.goods_id,
       edge.component_goods_id,
       edge.qty AS design_qty,
       basis.linear,
       CASE WHEN rule.actual_status='ACTUAL' THEN rule.actual_edge_qty END AS actual_qty,
       usage.actual_qty AS actual_per_unit_qty,
       rule.actual_status,
       round(ceil(COALESCE(CASE WHEN rule.actual_status='ACTUAL' THEN rule.actual_edge_qty END,edge.qty)*1000000)/1000000,6)
           AS effective_qty,
       CASE WHEN rule.actual_status='ACTUAL' THEN 'ACTUAL' ELSE 'DESIGN' END AS usage_basis,
       COALESCE(usage.net_qty,0) AS net_qty,
       COALESCE(usage.exposure_output_qty,0) AS exposure_output_qty,
       COALESCE(usage.sample_count,0) AS sample_count,
       usage.updated_at AS actual_updated_at,
       usage.relearned_at,
       edge.learning_profile_goods_id IS NOT NULL AS system_learned,
       COALESCE(usage.defect_qty,0) AS defect_qty,
       CASE WHEN rule.actual_status='ACTUAL'
            THEN usage.actual_per_produced_qty*CASE WHEN edge.consumption_basis='PER_UNIT' THEN 1 ELSE edge.basis_output_qty END
       END AS actual_per_produced_qty,
       usage.defect_rate
FROM goods_bom_items edge
JOIN goods component ON component.id=edge.component_goods_id
LEFT JOIN v_goods_bom_actual_usage usage
       ON usage.goods_id=edge.goods_id AND usage.component_goods_id=edge.component_goods_id
      AND usage.unit_id=component.unit_id
CROSS JOIN LATERAL (
    SELECT edge.consumption_basis='PER_UNIT'
        OR (edge.consumption_basis='PER_PACKAGE' AND edge.allow_partial_package) AS linear
) basis
CROSS JOIN LATERAL (
    SELECT CASE WHEN NOT basis.linear THEN 'NOT_LINEAR' ELSE COALESCE(usage.actual_status,'NO_DATA') END AS actual_status,
           usage.actual_qty*CASE WHEN edge.consumption_basis='PER_UNIT' THEN 1 ELSE edge.basis_output_qty END
               AS actual_edge_qty
) rule;
COMMENT ON VIEW v_goods_bom_item_usage IS
    'BOM 边的设计/真实使用数量与计算采用值(ADR-129)；委外单一子件发料的路线选择由物料分析按节点决定';

-- Material total cost of a parent from design quantities (Java recalcSourceE
-- and the learning publisher both call this one formula).
CREATE FUNCTION fn_goods_bom_material_cost(p_goods UUID) RETURNS NUMERIC LANGUAGE sql STABLE AS $$
    SELECT round(COALESCE(sum(edge.qty*CASE
                WHEN component.source_type='自制' OR EXISTS(
                    SELECT 1 FROM goods_bom_items child JOIN goods grandchild ON grandchild.id=child.component_goods_id
                    WHERE child.goods_id=component.id AND NOT child.is_deleted AND NOT grandchild.auto_created)
                THEN COALESCE(component.c_total,component.price) ELSE component.price END),0),2)
    FROM goods_bom_items edge
    JOIN goods parent ON parent.id=edge.goods_id
    JOIN goods component ON component.id=edge.component_goods_id
    WHERE edge.goods_id=p_goods AND NOT edge.is_deleted AND NOT parent.auto_created AND NOT component.auto_created
$$;

-- ---------------------------------------------------------------------------
-- 5. Manual BOM writes: per-edge ownership, no learning-state writes.
-- ---------------------------------------------------------------------------
CREATE FUNCTION fn_bom_learning_manual_ownership() RETURNS trigger LANGUAGE plpgsql AS $$
DECLARE component_id UUID; topology_change BOOLEAN;
BEGIN
    IF current_setting('app.bom_learning_write',TRUE)='on' OR TG_OP='DELETE' THEN RETURN COALESCE(NEW,OLD); END IF;
    IF TG_OP='UPDATE' AND (to_jsonb(NEW)-'updated_at'-'updated_by'-'audited_at'-'audited_by')
        IS NOT DISTINCT FROM (to_jsonb(OLD)-'updated_at'-'updated_by'-'audited_at'-'audited_by') THEN RETURN NEW; END IF;
    topology_change:=TG_OP='INSERT';
    IF TG_OP='UPDATE' THEN topology_change:=NOT NEW.is_deleted AND (OLD.is_deleted OR
        (NEW.goods_id,NEW.component_goods_id) IS DISTINCT FROM (OLD.goods_id,OLD.component_goods_id)); END IF;
    IF topology_change AND NOT NEW.is_deleted THEN
        -- Parent row, then the graph lock: the same order as the learning publisher.
        PERFORM id FROM goods WHERE id=NEW.goods_id FOR NO KEY UPDATE;
        PERFORM pg_advisory_xact_lock(hashtextextended('goods-bom-learning-graph',0));
        component_id:=NEW.component_goods_id;
        IF EXISTS(WITH RECURSIVE descendants(id) AS (
            SELECT component_id UNION SELECT edge.component_goods_id FROM descendants node
            JOIN goods_bom_items edge ON edge.goods_id=node.id AND NOT edge.is_deleted AND edge.id<>NEW.id
        ) SELECT 1 FROM descendants WHERE id=NEW.goods_id) THEN
            RAISE EXCEPTION 'BOM component would create a cycle' USING ERRCODE='23514';
        END IF;
    END IF;
    IF TG_OP='UPDATE' THEN
        IF NEW.is_deleted AND NOT OLD.is_deleted THEN
            -- A person removed this component: never add it back automatically.
            NEW.learning_released_at:=COALESCE(NEW.learning_released_at,now());
        ELSIF OLD.learning_profile_goods_id IS NOT NULL AND NOT NEW.is_deleted
            AND (NEW.goods_id,NEW.component_goods_id,NEW.color_id,NEW.qty,NEW.consumption_basis,NEW.basis_output_qty,
                 NEW.allow_partial_package,NEW.control_stage,NEW.hard_gate)
                IS DISTINCT FROM (OLD.goods_id,OLD.component_goods_id,OLD.color_id,OLD.qty,OLD.consumption_basis,
                 OLD.basis_output_qty,OLD.allow_partial_package,OLD.control_stage,OLD.hard_gate) THEN
            -- A person decided this edge's recipe: it becomes a manual edge.
            -- Its actual usage keeps accumulating in goods_bom_actual_usages.
            NEW.learning_profile_goods_id:=NULL;
            NEW.learning_unit_id:=NULL;
        END IF;
    END IF;
    RETURN NEW;
END $$;
CREATE TRIGGER trg_bom_learning_manual_ownership BEFORE INSERT OR UPDATE OR DELETE ON goods_bom_items
    FOR EACH ROW EXECUTE FUNCTION fn_bom_learning_manual_ownership();

-- ---------------------------------------------------------------------------
-- 6. Learning engine.
-- ---------------------------------------------------------------------------
CREATE FUNCTION fn_enqueue_bom_learning(p_segment UUID) RETURNS VOID LANGUAGE plpgsql AS $$
DECLARE root_id UUID; parent_id UUID;
BEGIN
    IF p_segment IS NULL THEN RETURN; END IF;
    root_id:=fn_production_execution_cost_scope(p_segment);
    IF root_id IS NULL THEN RETURN; END IF;
    SELECT product_goods_id INTO parent_id FROM production_execution_segments WHERE id=root_id;
    IF parent_id IS NULL THEN RETURN; END IF;
    INSERT INTO production_bom_learning_refresh_queue(transaction_id,execution_root_id,goods_id)
        VALUES(txid_current(),root_id,parent_id) ON CONFLICT DO NOTHING;
END $$;

-- Only system-owned edges are written. Structure changes (new learned edges)
-- need a fully cleared family and succeed for the whole recipe or not at all.
-- Callers hold the parent goods row (FOR NO KEY UPDATE) and the parent's
-- learning lock, so the usage rows, samples and live edges read here are stable.
CREATE FUNCTION fn_publish_learned_bom(p_goods UUID, p_create BOOLEAN) RETURNS VOID LANGUAGE plpgsql AS $$
DECLARE parent goods%ROWTYPE; profile goods_bom_learning_profiles%ROWTYPE; candidate RECORD; candidates JSONB;
    reason TEXT; changed BOOLEAN:=FALSE; created BOOLEAN:=FALSE; affected INTEGER; prior_mode TEXT;
    edge_id UUID; next_cost NUMERIC; target_qty NUMERIC;
BEGIN
    SELECT * INTO parent FROM goods WHERE id=p_goods;
    SELECT * INTO profile FROM goods_bom_learning_profiles WHERE goods_id=p_goods;
    IF parent.id IS NULL OR profile.goods_id IS NULL OR parent.is_deleted OR parent.auto_created THEN RETURN; END IF;
    prior_mode:=current_setting('app.bom_learning_write',TRUE);
    PERFORM set_config('app.bom_learning_write','on',TRUE);
    -- Both columns stay equal on learned edges. While the parent is currently
    -- subcontracted its design quantity is the frozen outbound contract basis.
    IF parent.source_type IS DISTINCT FROM '委外' THEN
        UPDATE goods_bom_items edge SET qty=target.qty, updated_at=now()
        FROM (SELECT learned.id, GREATEST(round(usage.actual_qty,5),0.00001) AS qty
              FROM goods_bom_items learned
              JOIN v_goods_bom_actual_usage usage ON usage.goods_id=learned.goods_id
                   AND usage.component_goods_id=learned.component_goods_id AND usage.unit_id=learned.learning_unit_id
              WHERE learned.goods_id=p_goods AND learned.learning_profile_goods_id=p_goods AND NOT learned.is_deleted
                AND learned.consumption_basis='PER_UNIT' AND usage.actual_status='ACTUAL'
                AND usage.actual_qty<10000000000000) target
        WHERE edge.id=target.id AND edge.qty IS DISTINCT FROM target.qty;
        GET DIAGNOSTICS affected=ROW_COUNT; changed:=affected>0;
    END IF;
    IF p_create AND NOT EXISTS(SELECT 1 FROM goods_bom_items WHERE goods_id=p_goods AND NOT is_deleted
            AND learning_profile_goods_id IS NULL) THEN
        -- The candidate recipe, built once: every usable learned material that is
        -- not in the live BOM and was never removed by a person.
        SELECT COALESCE(jsonb_agg(jsonb_build_object('component',usage.component_goods_id,'unit',usage.unit_id,
                   'qty',usage.actual_qty,'colors',COALESCE(used.colors,'[]'::jsonb))
                   ORDER BY usage.component_goods_id, usage.unit_id),'[]'::jsonb)
        INTO candidates
        FROM v_goods_bom_actual_usage usage
        LEFT JOIN LATERAL (
            SELECT jsonb_agg(DISTINCT color.key) AS colors
            FROM production_bom_learning_samples sample
            CROSS JOIN LATERAL jsonb_array_elements(sample.materials) entry
            CROSS JOIN LATERAL jsonb_each_text(entry->'colors') color
            WHERE sample.goods_id=p_goods AND entry->>'goodsId'=usage.component_goods_id::text
              AND entry->>'unitId'=usage.unit_id::text AND color.value::numeric>0
        ) used ON TRUE
        WHERE usage.goods_id=p_goods AND usage.actual_status='ACTUAL'
          AND NOT EXISTS(SELECT 1 FROM goods_bom_items live WHERE live.goods_id=p_goods
              AND live.component_goods_id=usage.component_goods_id AND NOT live.is_deleted)
          AND NOT EXISTS(SELECT 1 FROM goods_bom_items released WHERE released.goods_id=p_goods
              AND released.component_goods_id=usage.component_goods_id AND released.learning_released_at IS NOT NULL);
        IF jsonb_array_length(candidates)>0 THEN
            -- ADR-111 fence shared with GoodsRepository.lockForReference: a concurrent
            -- component delete or unit change finishes first and is seen below.
            PERFORM component.id FROM goods component
            WHERE component.id IN(SELECT (value->>'component')::uuid FROM jsonb_array_elements(candidates))
            ORDER BY component.id FOR KEY SHARE;
            PERFORM pg_advisory_xact_lock(hashtextextended('goods-bom-learning-graph',0));
            IF parent.unit_id IS DISTINCT FROM profile.output_unit_id THEN reason:='OUTPUT_IDENTITY_CHANGED'; END IF;
            FOR candidate IN
                SELECT (value->>'component')::uuid AS component_id, (value->>'qty')::numeric AS qty,
                       jsonb_array_length(value->'colors') AS color_count,
                       component.is_deleted OR component.auto_created
                           OR component.unit_id IS DISTINCT FROM (value->>'unit')::uuid AS identity_changed
                FROM jsonb_array_elements(candidates) JOIN goods component ON component.id=(value->>'component')::uuid
                ORDER BY value->>'component', value->>'unit'
            LOOP
                EXIT WHEN reason IS NOT NULL;
                IF candidate.identity_changed THEN
                    reason:='MATERIAL_IDENTITY_CHANGED';
                ELSIF candidate.qty>=10000000000000 THEN
                    reason:='BOM_QUANTITY_PRECISION';
                ELSIF candidate.color_count>1 THEN
                    reason:='MATERIAL_COLOR_OR_UNIT_CONFLICT';
                ELSIF EXISTS(WITH RECURSIVE descendants(id) AS (
                        SELECT candidate.component_id UNION
                        SELECT edge.component_goods_id FROM descendants node
                        JOIN goods_bom_items edge ON edge.goods_id=node.id AND NOT edge.is_deleted
                    ) SELECT 1 FROM descendants WHERE id=p_goods) THEN
                    reason:='BOM_CYCLE';
                END IF;
            END LOOP;
            IF reason IS NULL THEN
                FOR candidate IN
                    SELECT (value->>'component')::uuid AS component_id, (value->>'unit')::uuid AS unit_id,
                           (value->>'qty')::numeric AS qty, NULLIF(value->'colors'->>0,'')::uuid AS color_id
                    FROM jsonb_array_elements(candidates)
                    ORDER BY value->>'component', value->>'unit'
                LOOP
                    target_qty:=GREATEST(round(candidate.qty,5),0.00001);
                    -- A learned edge retired by V711 is restored with its identity.
                    SELECT id INTO edge_id FROM goods_bom_items
                    WHERE goods_id=p_goods AND component_goods_id=candidate.component_id
                      AND learning_profile_goods_id=p_goods AND is_deleted AND learning_released_at IS NULL
                    ORDER BY deleted_at DESC NULLS LAST LIMIT 1;
                    IF edge_id IS NOT NULL THEN
                        UPDATE goods_bom_items SET is_deleted=FALSE, deleted_at=NULL, qty=target_qty,
                            color_id=candidate.color_id, learning_unit_id=candidate.unit_id, updated_at=now()
                        WHERE id=edge_id;
                    ELSE
                        INSERT INTO goods_bom_items(goods_id,component_goods_id,color_id,qty,control_stage,consumption_basis,
                            basis_output_qty,hard_gate,allow_partial_package,sort_order,learning_profile_goods_id,learning_unit_id)
                        VALUES(p_goods,candidate.component_id,candidate.color_id,target_qty,'START','PER_UNIT',1,TRUE,TRUE,
                            (SELECT COALESCE(max(sort_order),0)+1 FROM goods_bom_items WHERE goods_id=p_goods),
                            p_goods,candidate.unit_id);
                    END IF;
                    created:=TRUE;
                END LOOP;
            END IF;
        END IF;
        UPDATE goods_bom_learning_profiles SET blocked_reason=reason, updated_at=now()
        WHERE goods_id=p_goods AND blocked_reason IS DISTINCT FROM reason;
    END IF;
    PERFORM set_config('app.bom_learning_write',COALESCE(prior_mode,''),TRUE);
    IF changed OR created THEN
        next_cost:=fn_goods_bom_material_cost(p_goods);
        UPDATE goods SET source_e=next_cost, version=version+1, updated_at=now()
        WHERE id=p_goods AND source_e IS DISTINCT FROM next_cost;
    END IF;
    IF created THEN
        edge_id:=gen_random_uuid();
        INSERT INTO business_outbox(id,event_type,aggregate_type,aggregate_id,payload,dedupe_key)
            VALUES(edge_id,'GOODS_BOM_UPDATED','GOODS_BOM',p_goods,'{}'::jsonb,'BOM_LEARNING:'||edge_id);
    END IF;
END $$;

-- One current contribution per production family (splits and actual-output
-- supplements included). Only a finished family teaches; a material teaches
-- once every one of its demands is physically cleared. Old contributions stay
-- until disproven. Nothing is locked or written for an unfinished family that
-- never contributed. Every entry keeps the learning generation it was first
-- counted in: a later change of an entry from before a relearn moves the
-- baseline together with the total, so the window only holds new data.
CREATE FUNCTION fn_refresh_bom_learning(p_root UUID, p_publish BOOLEAN) RETURNS VOID LANGUAGE plpgsql AS $$
DECLARE root production_execution_segments%ROWTYPE; parent goods%ROWTYPE; profile goods_bom_learning_profiles%ROWTYPE;
    old_sample production_bom_learning_samples%ROWTYPE; family UUID[]; output_qty NUMERIC:=0;
    family_state TEXT:='READY'; pending_state TEXT; facts JSONB; fact JSONB; fact_key TEXT; old_entry JSONB;
    old_entries JSONB:='{}'::jsonb; entries JSONB:='[]'::jsonb; fully_cleared BOOLEAN:=TRUE;
    sample_output NUMERIC; old_output NUMERIC; delta RECORD; generations JSONB:='{}'::jsonb;
    usage_generations JSONB:='{}'::jsonb; usage_created BOOLEAN;
    family_defect NUMERIC:=0; sample_defect NUMERIC; old_defect NUMERIC;
BEGIN
    SELECT * INTO root FROM production_execution_segments WHERE id=p_root;
    IF NOT FOUND OR root.product_goods_id IS NULL THEN RETURN; END IF;
    SELECT * INTO parent FROM goods WHERE id=root.product_goods_id;
    SELECT array_agg(segment_id ORDER BY segment_id) INTO family FROM fn_production_execution_cost_members(p_root);
    -- Good output is the denominator; reported defects only travel along for the
    -- per-produced usage and the defect rate.
    SELECT COALESCE(sum(item.qty*item.unit_rate),0), COALESCE(sum(item.defect_qty*item.unit_rate),0)
      INTO output_qty, family_defect
      FROM production_daily_report_items item JOIN production_daily_reports report ON report.id=item.report_id
      WHERE item.execution_segment_id=ANY(family) AND report.status=1 AND NOT report.is_deleted AND NOT item.is_deleted
        AND item.fqc_recovery_authorization_id IS NULL;
    IF EXISTS(SELECT 1 FROM production_daily_report_items item JOIN production_daily_reports report ON report.id=item.report_id
        WHERE item.execution_segment_id=ANY(family) AND report.status=0 AND NOT report.is_deleted AND NOT item.is_deleted) THEN
        pending_state:='PENDING_REPORT';
    ELSIF EXISTS(SELECT 1 FROM production_actual_output_supplement_requests
        WHERE source_execution_segment_id=ANY(family) AND status='DRAFT') THEN
        pending_state:='PENDING_SUPPLEMENT';
    END IF;
    IF output_qty<=0 THEN family_state:='NO_APPROVED_OUTPUT';
    ELSIF parent.id IS NULL OR parent.is_deleted OR parent.auto_created OR parent.unit_id IS NULL
        OR EXISTS(SELECT 1 FROM production_execution_segments WHERE id=ANY(family) AND product_goods_id<>root.product_goods_id)
        OR EXISTS(SELECT 1 FROM goods_bom_learning_profiles WHERE goods_id=root.product_goods_id
            AND output_unit_id IS DISTINCT FROM parent.unit_id) THEN
        family_state:='OUTPUT_IDENTITY_CHANGED';
    ELSIF EXISTS(SELECT 1 FROM production_execution_segments segment WHERE segment.id=ANY(family)
        AND NOT segment.is_deleted AND segment.status NOT IN('CANCELLED','REVERSED')
        AND NOT EXISTS(SELECT 1 FROM production_execution_segment_splits split WHERE split.source_segment_id=segment.id)
        AND NOT EXISTS(SELECT 1 FROM production_daily_report_items item JOIN production_daily_reports report ON report.id=item.report_id
            WHERE item.execution_segment_id=segment.id AND report.status=1 AND NOT report.is_deleted AND NOT item.is_deleted AND item.is_final)
        AND COALESCE((SELECT sum(item.qty) FROM production_daily_report_items item JOIN production_daily_reports report ON report.id=item.report_id
            WHERE item.execution_segment_id=segment.id AND report.status=1 AND NOT report.is_deleted AND NOT item.is_deleted
              AND item.fqc_recovery_authorization_id IS NULL),0)<segment.planned_qty) THEN
        family_state:='PRODUCTION_OPEN';
    END IF;
    IF pending_state IS NOT NULL AND family_state IN('READY','PRODUCTION_OPEN') THEN family_state:=pending_state; END IF;
    -- An empty sample is only ever written by this family's own refresh (the
    -- family lock is held), so this unlocked read is safe for the early exit.
    SELECT * INTO old_sample FROM production_bom_learning_samples WHERE execution_root_id=p_root;
    IF family_state<>'READY' AND COALESCE(jsonb_array_length(old_sample.materials),0)=0 THEN
        IF old_sample.execution_root_id IS NOT NULL AND old_sample.state IS DISTINCT FROM family_state THEN
            UPDATE production_bom_learning_samples SET state=family_state, revision=revision+1, updated_at=now()
            WHERE execution_root_id=p_root;
        END IF;
        RETURN;
    END IF;

    -- Only this family's indexed demand and posting ranges are read.
    WITH demand_facts AS (
        SELECT demand.goods_id, demand.unit_id, demand.color_id,
               (component.is_deleted OR component.auto_created OR demand.unit_id IS DISTINCT FROM component.unit_id) AS identity_changed,
               COALESCE(stock.issued,0) AS issued, COALESCE(stock.returned,0) AS returned,
               COALESCE(settled.consumed,0) AS consumed, COALESCE(settled.loss,0) AS loss, COALESCE(settled.wip,0) AS wip,
               EXISTS(SELECT 1 FROM production_material_stock_postings posting WHERE posting.demand_id=demand.id
                   AND posting.posting_type='ISSUE' AND fn_material_issue_pending_return(posting.id,NULL)>0) AS pending_return
        FROM production_material_demands demand JOIN goods component ON component.id=demand.goods_id
        LEFT JOIN LATERAL(SELECT sum(CASE posting_type WHEN 'ISSUE' THEN qty_base WHEN 'ISSUE_REVERSE' THEN -qty_base ELSE 0 END) AS issued,
            sum(CASE posting_type WHEN 'GOOD_RETURN' THEN qty_base WHEN 'GOOD_RETURN_REVERSE' THEN -qty_base ELSE 0 END) AS returned
            FROM production_material_stock_postings WHERE demand_id=demand.id) stock ON TRUE
        LEFT JOIN LATERAL(SELECT
                sum(CASE WHEN posting.settlement_type='CONSUMED' THEN CASE event.event_type WHEN 'POST' THEN posting.qty_base ELSE -posting.qty_base END ELSE 0 END) AS consumed,
                sum(CASE WHEN posting.settlement_type='APPROVED_LOSS' THEN CASE event.event_type WHEN 'POST' THEN posting.qty_base ELSE -posting.qty_base END ELSE 0 END) AS loss,
                sum(CASE WHEN posting.settlement_type='LEGAL_WIP' THEN CASE event.event_type WHEN 'POST' THEN posting.qty_base ELSE -posting.qty_base END ELSE 0 END) AS wip
            FROM production_material_settlement_postings posting
            JOIN production_material_settlement_events event ON event.id=posting.event_id
            WHERE posting.demand_id=demand.id) settled ON TRUE
        WHERE demand.execution_segment_id=ANY(family)
          AND (NOT demand.is_deleted OR EXISTS(SELECT 1 FROM production_material_stock_postings WHERE demand_id=demand.id))
    ), color_facts AS (
        SELECT goods_id, unit_id, color_id,
               bool_or(identity_changed) AS identity_changed, bool_or(pending_return) AS pending_return,
               bool_and(wip=0 AND issued>=returned AND consumed>=0 AND loss>=0 AND issued-returned=consumed+loss) AS balanced,
               sum(issued-returned) AS net, sum(GREATEST(LEAST(issued-returned,consumed+loss),0)) AS proven
        FROM demand_facts GROUP BY goods_id, unit_id, color_id
    )
    SELECT COALESCE(jsonb_object_agg(material.goods_id::text||'|'||material.unit_id::text, jsonb_build_object(
               'goodsId',material.goods_id,'unitId',material.unit_id,'identityChanged',material.identity_changed,
               'pendingReturn',material.pending_return,'balanced',material.balanced,'net',material.net,
               'proven',material.proven,'colors',material.colors)),'{}'::jsonb)
    INTO facts
    FROM (SELECT goods_id, unit_id, bool_or(identity_changed) AS identity_changed, bool_or(pending_return) AS pending_return,
                 bool_and(balanced) AS balanced, sum(net) AS net, sum(proven) AS proven,
                 COALESCE(jsonb_object_agg(COALESCE(color_id::text,''),net) FILTER (WHERE net>0),'{}'::jsonb) AS colors
          FROM color_facts GROUP BY goods_id, unit_id) material;

    -- One parent at a time from here on: its samples, usage rows and profile
    -- (relearn takes the same lock). The sample is read again under the lock,
    -- because another family of this parent may have back-filled it.
    PERFORM pg_advisory_xact_lock(hashtextextended('bom-learning-parent:'||root.product_goods_id::text,0));
    SELECT * INTO old_sample FROM production_bom_learning_samples WHERE execution_root_id=p_root;
    old_output:=COALESCE(old_sample.output_qty,0);
    old_defect:=COALESCE(old_sample.defect_qty,0);
    generations:=COALESCE(old_sample.entry_generations,'{}'::jsonb);
    SELECT COALESCE(jsonb_object_agg(value->>'goodsId'||'|'||(value->>'unitId'),value),'{}'::jsonb) INTO old_entries
    FROM jsonb_array_elements(COALESCE(old_sample.materials,'[]'::jsonb));
    SELECT COALESCE(jsonb_object_agg(component_goods_id::text||'|'||unit_id::text,learning_generation),'{}'::jsonb)
    INTO usage_generations FROM goods_bom_actual_usages WHERE goods_id=root.product_goods_id;

    IF family_state='READY' THEN
        FOR fact_key, fact IN SELECT key, value FROM jsonb_each(facts) ORDER BY key LOOP
            old_entry:=old_entries->fact_key;
            IF (fact->>'identityChanged')::boolean THEN fully_cleared:=FALSE; CONTINUE; END IF;
            IF (fact->>'balanced')::boolean AND NOT (fact->>'pendingReturn')::boolean THEN
                entries:=entries||jsonb_build_array(jsonb_build_object('goodsId',fact->'goodsId','unitId',fact->'unitId',
                    'qty',fact->'net','exposure',output_qty,'defect',family_defect,'colors',fact->'colors',
                    'generation',COALESCE((old_entry->>'generation')::int,(generations->>fact_key)::int,
                        (usage_generations->>fact_key)::int,0)));
            ELSE
                fully_cleared:=FALSE;
                IF old_entry IS NOT NULL AND output_qty>=old_output
                   AND (old_entry->>'qty')::numeric<=(fact->>'proven')::numeric THEN
                    entries:=entries||jsonb_build_array(old_entry);
                END IF;
            END IF;
        END LOOP;
        -- On-site discovery has no frozen recipe: every material known for the
        -- parent competes for the same output, even if unused this time. A
        -- material that becomes known later is back-filled below.
        IF root.material_discovery_required THEN
            entries:=entries||COALESCE((SELECT jsonb_agg(jsonb_build_object('goodsId',usage.component_goods_id,
                    'unitId',usage.unit_id,'qty',0,'exposure',output_qty,'defect',family_defect,'colors','{}'::jsonb,
                    'generation',COALESCE((old_entries->(usage.component_goods_id::text||'|'||usage.unit_id::text)->>'generation')::int,
                        (generations->>(usage.component_goods_id::text||'|'||usage.unit_id::text))::int,usage.learning_generation))
                    ORDER BY usage.component_goods_id, usage.unit_id)
                FROM goods_bom_actual_usages usage
                WHERE usage.goods_id=root.product_goods_id AND usage.output_unit_id=parent.unit_id
                  AND NOT facts ? (usage.component_goods_id::text||'|'||usage.unit_id::text)),'[]'::jsonb);
        END IF;
    ELSE
        fully_cleared:=FALSE;
        FOR fact_key, old_entry IN SELECT key, value FROM jsonb_each(old_entries) ORDER BY key LOOP
            fact:=facts->fact_key;
            IF output_qty>=old_output AND family_state NOT IN('OUTPUT_IDENTITY_CHANGED','NO_APPROVED_OUTPUT')
               AND NOT COALESCE((fact->>'identityChanged')::boolean,FALSE)
               AND (old_entry->>'qty')::numeric<=COALESCE((fact->>'proven')::numeric,0) THEN
                entries:=entries||jsonb_build_array(old_entry);
            END IF;
        END LOOP;
    END IF;
    SELECT COALESCE(jsonb_agg(value ORDER BY value->>'goodsId', value->>'unitId'),'[]'::jsonb) INTO entries
    FROM jsonb_array_elements(entries);
    sample_output:=CASE WHEN jsonb_array_length(entries)=0 THEN 0
                        WHEN family_state='READY' THEN output_qty ELSE old_output END;
    sample_defect:=CASE WHEN jsonb_array_length(entries)=0 THEN 0
                        WHEN family_state='READY' THEN family_defect ELSE old_defect END;
    IF old_sample.execution_root_id IS NULL AND jsonb_array_length(entries)=0 THEN RETURN; END IF;
    -- Nothing learned changed: no writes, unless the family has just become
    -- fully cleared (that alone may allow creating the learned recipe).
    IF old_sample.execution_root_id IS NOT NULL AND old_sample.materials=entries AND old_output=sample_output
       AND old_defect=sample_defect
       AND old_sample.state=family_state AND (old_sample.fully_cleared OR NOT fully_cleared) THEN RETURN; END IF;
    -- The first generation of every entry is remembered, even after it drops out.
    SELECT (SELECT COALESCE(jsonb_object_agg(value->>'goodsId'||'|'||(value->>'unitId'),(value->>'generation')::int),'{}'::jsonb)
            FROM jsonb_array_elements(entries))||generations INTO generations;

    -- A first sample only exists for a READY family, whose parent unit is valid.
    IF old_sample.execution_root_id IS NULL THEN
        INSERT INTO goods_bom_learning_profiles(goods_id,output_unit_id) VALUES(root.product_goods_id,parent.unit_id)
            ON CONFLICT(goods_id) DO NOTHING;
    END IF;
    SELECT * INTO profile FROM goods_bom_learning_profiles WHERE goods_id=root.product_goods_id;
    IF old_sample.materials IS DISTINCT FROM entries THEN
        FOR delta IN
            WITH old_e AS (
                SELECT (value->>'goodsId')::uuid AS goods_id, (value->>'unitId')::uuid AS unit_id,
                       (value->>'qty')::numeric AS qty, COALESCE((value->>'exposure')::numeric,old_output) AS exposure,
                       COALESCE((value->>'defect')::numeric,0) AS defect,
                       (value->>'generation')::int AS generation
                FROM jsonb_array_elements(COALESCE(old_sample.materials,'[]'::jsonb))
            ), new_e AS (
                SELECT (value->>'goodsId')::uuid AS goods_id, (value->>'unitId')::uuid AS unit_id,
                       (value->>'qty')::numeric AS qty, (value->>'exposure')::numeric AS exposure,
                       COALESCE((value->>'defect')::numeric,0) AS defect,
                       (value->>'generation')::int AS generation
                FROM jsonb_array_elements(entries)
            )
            SELECT COALESCE(new_e.goods_id,old_e.goods_id) AS goods_id, COALESCE(new_e.unit_id,old_e.unit_id) AS unit_id,
                   COALESCE(new_e.qty,0)-COALESCE(old_e.qty,0) AS qty,
                   COALESCE(new_e.exposure,0)-COALESCE(old_e.exposure,0) AS exposure,
                   COALESCE(new_e.defect,0)-COALESCE(old_e.defect,0) AS defect,
                   (new_e.goods_id IS NOT NULL)::int-(old_e.goods_id IS NOT NULL)::int AS samples,
                   COALESCE(new_e.generation,old_e.generation,0) AS generation
            FROM new_e FULL JOIN old_e ON old_e.goods_id=new_e.goods_id AND old_e.unit_id=new_e.unit_id
            ORDER BY 1, 2
        LOOP
            IF delta.qty=0 AND delta.exposure=0 AND delta.defect=0 AND delta.samples=0 THEN CONTINUE; END IF;
            -- An entry from an earlier generation is already inside the baseline:
            -- its change moves the baseline too. Totals never drop below zero and
            -- the baseline never exceeds the total.
            INSERT INTO goods_bom_actual_usages AS usage
                (goods_id,component_goods_id,unit_id,output_unit_id,net_qty,exposure_output_qty,exposure_defect_qty,sample_count)
            VALUES(root.product_goods_id,delta.goods_id,delta.unit_id,profile.output_unit_id,
                   GREATEST(delta.qty,0),GREATEST(delta.exposure,0),GREATEST(delta.defect,0),GREATEST(delta.samples,0))
            ON CONFLICT(goods_id,component_goods_id,unit_id) DO UPDATE SET
                net_qty=GREATEST(usage.net_qty+delta.qty,0),
                exposure_output_qty=GREATEST(usage.exposure_output_qty+delta.exposure,0),
                exposure_defect_qty=GREATEST(usage.exposure_defect_qty+delta.defect,0),
                sample_count=GREATEST(usage.sample_count+delta.samples,0),
                baseline_net_qty=LEAST(GREATEST(usage.baseline_net_qty
                    +CASE WHEN delta.generation<usage.learning_generation THEN delta.qty ELSE 0 END,0),
                    GREATEST(usage.net_qty+delta.qty,0)),
                baseline_exposure_output_qty=LEAST(GREATEST(usage.baseline_exposure_output_qty
                    +CASE WHEN delta.generation<usage.learning_generation THEN delta.exposure ELSE 0 END,0),
                    GREATEST(usage.exposure_output_qty+delta.exposure,0)),
                baseline_exposure_defect_qty=LEAST(GREATEST(usage.baseline_exposure_defect_qty
                    +CASE WHEN delta.generation<usage.learning_generation THEN delta.defect ELSE 0 END,0),
                    GREATEST(usage.exposure_defect_qty+delta.defect,0)),
                baseline_sample_count=LEAST(GREATEST(usage.baseline_sample_count
                    +CASE WHEN delta.generation<usage.learning_generation THEN delta.samples ELSE 0 END,0),
                    GREATEST(usage.sample_count+delta.samples,0)),
                updated_at=now()
            RETURNING (usage.xmax=0) INTO usage_created;
            IF usage_created THEN
                -- A newly known material: every other finished on-site family of
                -- this parent was exposed to it too, whatever order they finished in.
                WITH backfill AS (
                    UPDATE production_bom_learning_samples sample
                    SET materials=(SELECT jsonb_agg(value ORDER BY value->>'goodsId', value->>'unitId')
                                   FROM jsonb_array_elements(sample.materials||jsonb_build_array(jsonb_build_object(
                                       'goodsId',delta.goods_id,'unitId',delta.unit_id,'qty',0,'exposure',sample.output_qty,
                                       'defect',sample.defect_qty,
                                       'colors','{}'::jsonb,'generation',0)))),
                        entry_generations=jsonb_build_object(delta.goods_id::text||'|'||delta.unit_id::text,0)
                            ||sample.entry_generations,
                        revision=sample.revision+1, updated_at=now()
                    WHERE sample.goods_id=root.product_goods_id AND sample.execution_root_id<>p_root
                      AND sample.discovery AND sample.state='READY' AND sample.output_qty>0
                      AND NOT EXISTS(SELECT 1 FROM jsonb_array_elements(sample.materials) known
                          WHERE known->>'goodsId'=delta.goods_id::text AND known->>'unitId'=delta.unit_id::text)
                    RETURNING sample.output_qty AS backfilled_output, sample.defect_qty AS backfilled_defect
                )
                UPDATE goods_bom_actual_usages usage
                SET exposure_output_qty=usage.exposure_output_qty+exposed.backfilled_output,
                    exposure_defect_qty=usage.exposure_defect_qty+exposed.backfilled_defect,
                    sample_count=usage.sample_count+exposed.samples, updated_at=now()
                FROM (SELECT COALESCE(sum(backfilled_output),0) AS backfilled_output,
                             COALESCE(sum(backfilled_defect),0) AS backfilled_defect, count(*) AS samples FROM backfill) exposed
                WHERE usage.goods_id=root.product_goods_id AND usage.component_goods_id=delta.goods_id
                  AND usage.unit_id=delta.unit_id AND exposed.samples>0;
            END IF;
        END LOOP;
    END IF;
    UPDATE goods_bom_learning_profiles
    SET total_output_qty=GREATEST(total_output_qty+sample_output-old_output,0),
        total_defect_qty=GREATEST(total_defect_qty+sample_defect-old_defect,0),
        sample_count=GREATEST(sample_count+(sample_output>0)::int-(old_output>0)::int,0),
        revision=revision+1, updated_at=now()
    WHERE goods_id=root.product_goods_id;
    INSERT INTO production_bom_learning_samples(execution_root_id,goods_id,output_qty,defect_qty,materials,state,discovery,
        fully_cleared,entry_generations,revision)
    VALUES(p_root,root.product_goods_id,sample_output,sample_defect,entries,family_state,root.material_discovery_required,
        fully_cleared,generations,1)
    ON CONFLICT(execution_root_id) DO UPDATE SET output_qty=EXCLUDED.output_qty, defect_qty=EXCLUDED.defect_qty,
        materials=EXCLUDED.materials,
        state=EXCLUDED.state, discovery=EXCLUDED.discovery, fully_cleared=EXCLUDED.fully_cleared,
        entry_generations=EXCLUDED.entry_generations,
        revision=production_bom_learning_samples.revision+1, updated_at=now();
    IF p_publish THEN
        PERFORM fn_publish_learned_bom(root.product_goods_id, family_state='READY' AND fully_cleared);
    END IF;
END $$;

-- Lock order for every learning transaction: publishable parent goods rows
-- (sorted), then one family at a time, then the parent's learning lock, then
-- (creating learned edges only) the candidate components KEY SHARE and the BOM
-- graph lock. Manual BOM writers lock all parent rows up front, then the graph.
CREATE FUNCTION fn_drain_bom_learning_queue() RETURNS trigger LANGUAGE plpgsql AS $$
DECLARE queued RECORD; publishable UUID[]:='{}';
BEGIN
    IF NOT EXISTS(SELECT 1 FROM production_bom_learning_refresh_queue WHERE transaction_id=txid_current()) THEN
        RETURN NULL;
    END IF;
    FOR queued IN
        SELECT goods.id FROM goods
        WHERE goods.id IN(SELECT goods_id FROM production_bom_learning_refresh_queue WHERE transaction_id=txid_current())
          AND (EXISTS(SELECT 1 FROM goods_bom_items edge WHERE edge.goods_id=goods.id AND NOT edge.is_deleted
                      AND edge.learning_profile_goods_id=goods.id)
               OR NOT EXISTS(SELECT 1 FROM goods_bom_items edge WHERE edge.goods_id=goods.id AND NOT edge.is_deleted
                      AND edge.learning_profile_goods_id IS NULL))
        ORDER BY goods.id FOR NO KEY UPDATE
    LOOP
        publishable:=publishable||queued.id;
    END LOOP;
    FOR queued IN SELECT goods_id, execution_root_id FROM production_bom_learning_refresh_queue
        WHERE transaction_id=txid_current() ORDER BY goods_id, execution_root_id LOOP
        DELETE FROM production_bom_learning_refresh_queue
        WHERE transaction_id=txid_current() AND execution_root_id=queued.execution_root_id;
        PERFORM pg_advisory_xact_lock(hashtextextended('bom-learning-family:'||queued.execution_root_id::text,0));
        PERFORM fn_refresh_bom_learning(queued.execution_root_id, queued.goods_id=ANY(publishable));
    END LOOP;
    RETURN NULL;
END $$;
CREATE CONSTRAINT TRIGGER trg_drain_bom_learning_queue AFTER INSERT ON production_bom_learning_refresh_queue
    DEFERRABLE INITIALLY DEFERRED FOR EACH ROW EXECUTE FUNCTION fn_drain_bom_learning_queue();

CREATE FUNCTION fn_touch_bom_learning() RETURNS trigger LANGUAGE plpgsql AS $$
DECLARE segment_id UUID; payload JSONB; old_payload JSONB;
BEGIN
    payload:=CASE WHEN TG_OP='DELETE' THEN to_jsonb(OLD) ELSE to_jsonb(NEW) END;
    IF TG_TABLE_NAME='production_execution_segments' THEN PERFORM fn_enqueue_bom_learning((payload->>'id')::uuid);
    ELSIF TG_TABLE_NAME='production_daily_reports' THEN
        FOR segment_id IN SELECT DISTINCT execution_segment_id FROM production_daily_report_items
            WHERE report_id=(payload->>'id')::uuid AND execution_segment_id IS NOT NULL ORDER BY 1 LOOP
            PERFORM fn_enqueue_bom_learning(segment_id);
        END LOOP;
    ELSIF TG_TABLE_NAME IN('production_material_stock_postings','production_material_settlement_postings') THEN
        PERFORM fn_enqueue_bom_learning((SELECT execution_segment_id FROM production_material_demands WHERE id=(payload->>'demand_id')::uuid));
    ELSIF TG_TABLE_NAME='production_actual_output_supplement_reversals' THEN
        PERFORM fn_enqueue_bom_learning((SELECT source_execution_segment_id FROM production_actual_output_supplement_proofs
            WHERE id=(payload->>'proof_id')::uuid));
    ELSIF TG_TABLE_NAME='production_material_return_request_cancellations' THEN
        PERFORM fn_enqueue_bom_learning((SELECT execution_segment_id FROM production_material_return_requests
            WHERE id=(payload->>'request_id')::uuid));
    ELSIF TG_TABLE_NAME IN('production_actual_output_supplement_proofs','production_actual_output_supplement_requests') THEN
        PERFORM fn_enqueue_bom_learning((payload->>'source_execution_segment_id')::uuid);
    ELSIF TG_TABLE_NAME='production_execution_segment_splits' THEN
        PERFORM fn_enqueue_bom_learning((payload->>'source_segment_id')::uuid);
    ELSE
        PERFORM fn_enqueue_bom_learning((payload->>'execution_segment_id')::uuid);
        IF TG_OP='UPDATE' THEN
            old_payload:=to_jsonb(OLD);
            IF old_payload->>'execution_segment_id' IS DISTINCT FROM payload->>'execution_segment_id' THEN
                PERFORM fn_enqueue_bom_learning((old_payload->>'execution_segment_id')::uuid);
            END IF;
        END IF;
    END IF;
    RETURN NULL;
END $$;
-- Row triggers start only when a column that can change a family's facts
-- really changed (ADR-106). A new demand without postings teaches nothing.
CREATE TRIGGER trg_learn_bom_segment AFTER INSERT ON production_execution_segments
    FOR EACH ROW EXECUTE FUNCTION fn_touch_bom_learning();
CREATE TRIGGER trg_learn_bom_segment_upd AFTER UPDATE ON production_execution_segments FOR EACH ROW
    WHEN ((OLD.status,OLD.is_deleted,OLD.planned_qty,OLD.material_discovery_required,OLD.material_requirement_mode,
           OLD.source_segment_id,OLD.split_root_segment_id)
          IS DISTINCT FROM (NEW.status,NEW.is_deleted,NEW.planned_qty,NEW.material_discovery_required,
           NEW.material_requirement_mode,NEW.source_segment_id,NEW.split_root_segment_id))
    EXECUTE FUNCTION fn_touch_bom_learning();
CREATE TRIGGER trg_learn_bom_report_upd AFTER UPDATE ON production_daily_reports FOR EACH ROW
    WHEN ((OLD.status,OLD.is_deleted) IS DISTINCT FROM (NEW.status,NEW.is_deleted))
    EXECUTE FUNCTION fn_touch_bom_learning();
CREATE TRIGGER trg_learn_bom_report_item AFTER INSERT OR DELETE ON production_daily_report_items
    FOR EACH ROW EXECUTE FUNCTION fn_touch_bom_learning();
CREATE TRIGGER trg_learn_bom_report_item_upd AFTER UPDATE ON production_daily_report_items FOR EACH ROW
    WHEN ((OLD.execution_segment_id,OLD.qty,OLD.defect_qty,OLD.unit_rate,OLD.is_final,OLD.is_deleted,OLD.fqc_recovery_authorization_id)
          IS DISTINCT FROM (NEW.execution_segment_id,NEW.qty,NEW.defect_qty,NEW.unit_rate,NEW.is_final,NEW.is_deleted,
                            NEW.fqc_recovery_authorization_id))
    EXECUTE FUNCTION fn_touch_bom_learning();
CREATE TRIGGER trg_learn_bom_issue AFTER INSERT ON production_material_stock_postings
    FOR EACH ROW EXECUTE FUNCTION fn_touch_bom_learning();
CREATE TRIGGER trg_learn_bom_settlement AFTER INSERT ON production_material_settlement_postings
    FOR EACH ROW EXECUTE FUNCTION fn_touch_bom_learning();
CREATE TRIGGER trg_learn_bom_demand_upd AFTER UPDATE ON production_material_demands FOR EACH ROW
    WHEN ((OLD.execution_segment_id,OLD.is_deleted,OLD.goods_id,OLD.unit_id)
          IS DISTINCT FROM (NEW.execution_segment_id,NEW.is_deleted,NEW.goods_id,NEW.unit_id))
    EXECUTE FUNCTION fn_touch_bom_learning();
CREATE TRIGGER trg_learn_bom_return_request AFTER INSERT ON production_material_return_requests
    FOR EACH ROW EXECUTE FUNCTION fn_touch_bom_learning();
CREATE TRIGGER trg_learn_bom_return_cancel AFTER INSERT ON production_material_return_request_cancellations
    FOR EACH ROW EXECUTE FUNCTION fn_touch_bom_learning();
CREATE TRIGGER trg_learn_bom_supplement AFTER INSERT ON production_actual_output_supplement_proofs
    FOR EACH ROW EXECUTE FUNCTION fn_touch_bom_learning();
CREATE TRIGGER trg_learn_bom_supplement_request AFTER INSERT ON production_actual_output_supplement_requests
    FOR EACH ROW EXECUTE FUNCTION fn_touch_bom_learning();
CREATE TRIGGER trg_learn_bom_supplement_request_upd AFTER UPDATE ON production_actual_output_supplement_requests
    FOR EACH ROW WHEN (OLD.status IS DISTINCT FROM NEW.status) EXECUTE FUNCTION fn_touch_bom_learning();
CREATE TRIGGER trg_learn_bom_supplement_reverse AFTER INSERT ON production_actual_output_supplement_reversals
    FOR EACH ROW EXECUTE FUNCTION fn_touch_bom_learning();
CREATE TRIGGER trg_learn_bom_split AFTER INSERT ON production_execution_segment_splits
    FOR EACH ROW EXECUTE FUNCTION fn_touch_bom_learning();

-- "Relearn from now on": the current totals become the baseline and a new
-- generation starts; entries counted before keep moving the baseline only.
-- Serialized with the learner by the parent's learning lock.
CREATE FUNCTION fn_relearn_bom_actual_usage(p_goods UUID, p_component UUID, p_actor UUID) RETURNS INTEGER
LANGUAGE plpgsql AS $$
DECLARE affected INTEGER;
BEGIN
    PERFORM pg_advisory_xact_lock(hashtextextended('bom-learning-parent:'||p_goods::text,0));
    UPDATE goods_bom_actual_usages
    SET baseline_net_qty=net_qty, baseline_exposure_output_qty=exposure_output_qty,
        baseline_exposure_defect_qty=exposure_defect_qty,
        baseline_sample_count=sample_count, learning_generation=learning_generation+1,
        relearned_at=now(), relearned_by=p_actor, updated_at=now()
    WHERE goods_id=p_goods AND component_goods_id=p_component;
    GET DIAGNOSTICS affected=ROW_COUNT;
    RETURN affected;
END $$;

-- ---------------------------------------------------------------------------
-- 7. Material analysis snapshots record which usage each node adopted.
-- ---------------------------------------------------------------------------
ALTER TABLE production_material_analysis_materials
    ADD COLUMN design_bom_qty NUMERIC(18,6) CHECK(design_bom_qty IS NULL OR design_bom_qty>0),
    ADD COLUMN actual_bom_qty NUMERIC(18,6) CHECK(actual_bom_qty IS NULL OR actual_bom_qty>0),
    ADD COLUMN usage_basis TEXT NOT NULL DEFAULT 'DESIGN' CHECK(usage_basis IN('DESIGN','ACTUAL')),
    ADD COLUMN usage_reason TEXT CHECK(usage_reason IS NULL
        OR usage_reason IN('NO_DATA','NOT_LINEAR','OUTPUT_UNIT_CHANGED','SUBCONTRACT_OUTBOUND')),
    ADD COLUMN usage_sample_count BIGINT CHECK(usage_sample_count IS NULL OR usage_sample_count>=0),
    ADD COLUMN usage_defect_rate NUMERIC(9,6) CHECK(usage_defect_rate IS NULL OR usage_defect_rate BETWEEN 0 AND 1);
UPDATE production_material_analysis_materials SET design_bom_qty=bom_qty, usage_reason='NO_DATA'
WHERE node_role='BOM_COMPONENT' AND design_bom_qty IS NULL;
COMMENT ON COLUMN production_material_analysis_materials.bom_qty IS
    '本节点计算采用的每父件用量(真实或设计)，分析新建或人工刷新时采用，其余重算沿用';
COMMENT ON COLUMN production_material_analysis_materials.design_bom_qty IS '采用时的设计使用数量';
COMMENT ON COLUMN production_material_analysis_materials.actual_bom_qty IS '采用时的真实使用数量(该边计量口径)';
COMMENT ON COLUMN production_material_analysis_materials.usage_defect_rate IS '采用时用到该物料的批次的报工不良率(6 位)，只作说明';

-- ---------------------------------------------------------------------------
-- 8. Counted close-out: the physically counted leftover of the last report.
-- ---------------------------------------------------------------------------
ALTER TABLE production_daily_report_material_usages ADD COLUMN counted_leftover_qty NUMERIC(18,4)
    CHECK(counted_leftover_qty IS NULL OR counted_leftover_qty>=0);
COMMENT ON COLUMN production_daily_report_material_usages.counted_leftover_qty IS
    '最后一次报工实物清点的剩余量(基本单位)；审核时本次用料=账面可用-实际剩余，退仓按实际剩余';

-- ---------------------------------------------------------------------------
-- 9. Allowed over-production: structural default and remembered human choices.
-- ---------------------------------------------------------------------------
ALTER TABLE production_plan_items ADD COLUMN allowed_overproduction_rate_source TEXT NOT NULL DEFAULT 'DEFAULT'
    CHECK(allowed_overproduction_rate_source IN('DEFAULT','EXPLICIT'));
COMMENT ON COLUMN production_plan_items.allowed_overproduction_rate_source IS
    'DEFAULT=系统按货品默认填写；EXPLICIT=有人确认过该比例(只有它会被记住)';

-- A child is a manufacturing stage when it is made or subcontracted or has its
-- own production BOM. Undecided raw materials (on-site learned ones) are not.
CREATE FUNCTION fn_goods_structural_overproduction_rate(p_goods UUID) RETURNS NUMERIC LANGUAGE sql STABLE AS $$
    SELECT CASE
        WHEN g.source_type IN('采购','委外') THEN 0::numeric
        WHEN EXISTS(SELECT 1 FROM goods_bom_items bom JOIN goods component ON component.id=bom.component_goods_id
            WHERE bom.goods_id=g.id AND NOT bom.is_deleted AND bom.control_stage NOT IN('SHIP','REFERENCE')
              AND (component.source_type IN('自制','委外') OR EXISTS(SELECT 1 FROM goods_bom_items child
                   WHERE child.goods_id=component.id AND NOT child.is_deleted AND child.control_stage NOT IN('SHIP','REFERENCE'))))
        THEN 0::numeric
        ELSE 0.10 END
    FROM goods g WHERE g.id=p_goods AND NOT g.is_deleted
$$;
CREATE OR REPLACE FUNCTION fn_goods_default_overproduction_rate(p_goods UUID)
RETURNS NUMERIC LANGUAGE sql STABLE AS $$
    SELECT COALESCE(g.production_overproduction_rate, fn_goods_structural_overproduction_rate(g.id))
    FROM goods g WHERE g.id=p_goods AND NOT g.is_deleted
$$;
CREATE FUNCTION fn_remember_overproduction_rate(p_goods UUID, p_rate NUMERIC) RETURNS VOID LANGUAGE sql AS $$
    UPDATE goods SET production_overproduction_rate=p_rate
    WHERE id=p_goods AND NOT is_deleted AND p_rate IS NOT NULL AND production_overproduction_rate IS DISTINCT FROM p_rate
$$;
-- A plan line's confirmed rate, unless the plan only supplements actual output.
-- The plan service (new or changed lines) and the update trigger both use it.
CREATE FUNCTION fn_remember_plan_line_overproduction_rate(p_plan UUID, p_goods UUID, p_rate NUMERIC)
RETURNS VOID LANGUAGE sql AS $$
    SELECT fn_remember_overproduction_rate(p_goods,p_rate)
    WHERE NOT EXISTS(SELECT 1 FROM production_plans WHERE id=p_plan AND actual_output_supplement_request_id IS NOT NULL)
$$;
CREATE OR REPLACE FUNCTION fn_remember_plan_overproduction_rate()
RETURNS TRIGGER LANGUAGE plpgsql AS $$
BEGIN
    -- Only a rate a person confirmed becomes the goods' next default.
    IF NOT NEW.is_deleted AND NEW.allowed_overproduction_rate_source='EXPLICIT' THEN
        PERFORM fn_remember_plan_line_overproduction_rate(NEW.plan_id,NEW.goods_id,NEW.allowed_overproduction_rate);
    END IF;
    RETURN NEW;
END;
$$;
-- A draft re-save deletes and re-inserts its lines, so an insert is not a new
-- confirmation: the plan service remembers new or changed confirmed lines
-- (ProductionOverproductionAllowance.remember); in-place changes use this trigger.
DROP TRIGGER trg_remember_plan_overproduction_rate ON production_plan_items;
CREATE TRIGGER trg_remember_plan_overproduction_rate_upd AFTER UPDATE ON production_plan_items FOR EACH ROW
    WHEN (NEW.allowed_overproduction_rate_source='EXPLICIT'
          AND (OLD.allowed_overproduction_rate,OLD.allowed_overproduction_rate_source,OLD.is_deleted)
              IS DISTINCT FROM (NEW.allowed_overproduction_rate,NEW.allowed_overproduction_rate_source,NEW.is_deleted))
    EXECUTE FUNCTION fn_remember_plan_overproduction_rate();
CREATE OR REPLACE FUNCTION fn_remember_approved_overproduction_rate()
RETURNS TRIGGER LANGUAGE plpgsql AS $$
BEGIN
    PERFORM fn_remember_overproduction_rate(NEW.product_goods_id,NEW.allowed_overproduction_rate);
    RETURN NEW;
END;
$$;
DROP TRIGGER trg_remember_approved_overproduction_rate ON production_execution_segments;
CREATE TRIGGER trg_remember_approved_overproduction_rate
AFTER UPDATE OF allowed_overproduction_rate ON production_execution_segments FOR EACH ROW
    WHEN (OLD.allowed_overproduction_rate IS DISTINCT FROM NEW.allowed_overproduction_rate)
    EXECUTE FUNCTION fn_remember_approved_overproduction_rate();

-- V709 remembered every inserted default. Keep only approved human decisions.
UPDATE goods SET production_overproduction_rate=NULL WHERE production_overproduction_rate IS NOT NULL;
UPDATE goods SET production_overproduction_rate=latest.rate
FROM (SELECT DISTINCT ON (segment.product_goods_id) segment.product_goods_id AS goods_id, request.requested_rate AS rate
      FROM production_overproduction_rate_decisions decision
      JOIN production_overproduction_rate_requests request ON request.id=decision.request_id
      JOIN production_execution_segments segment ON segment.id=request.execution_segment_id
      WHERE decision.decision='APPROVED'
      ORDER BY segment.product_goods_id, decision.decided_at DESC, decision.id DESC) latest
WHERE goods.id=latest.goods_id AND NOT goods.is_deleted;

-- ---------------------------------------------------------------------------
-- 10. Audit and business reset policy.
-- ---------------------------------------------------------------------------
-- Recomputed projections: no row audit (every family completion rewrites them).
SELECT fn_audit_track_table('goods_bom_actual_usages','NONE','data_change',false);
SELECT fn_audit_track_table('goods_bom_learning_profiles','NONE','data_change',false);
SELECT fn_audit_track_table('production_bom_learning_samples','NONE','data_change',false);
DO $reset_policy$
DECLARE definition TEXT; anchor TEXT:='(''goods_bom_learning_material_totals'', ''PRESERVE'')';
BEGIN
    SELECT pg_get_functiondef('business_data_reset()'::regprocedure) INTO definition;
    IF (length(definition)-length(replace(definition,anchor,'')))/length(anchor)<>1 THEN
        RAISE EXCEPTION 'V737 cannot extend business-data reset policy safely';
    END IF;
    EXECUTE replace(definition,anchor,'(''goods_bom_actual_usages'', ''PRESERVE'')');
END;
$reset_policy$;

-- ---------------------------------------------------------------------------
-- 11. Replay every production family from its ledger facts (no BOM writes).
-- ---------------------------------------------------------------------------
DO $replay$
DECLARE root_id UUID;
BEGIN
    FOR root_id IN
        SELECT DISTINCT fn_production_execution_cost_scope(segment.id) FROM production_execution_segments segment ORDER BY 1
    LOOP
        IF root_id IS NOT NULL THEN
            PERFORM pg_advisory_xact_lock(hashtextextended('bom-learning-family:'||root_id::text,0));
            PERFORM fn_refresh_bom_learning(root_id,FALSE);
        END IF;
    END LOOP;
END;
$replay$;
-- Before V737 a finished family returned its book leftover, not a counted one,
-- so its net use echoes the planned usage (ADR-129 §1.2). The replayed samples
-- stay (later corrections of those families still subtract exactly), but the
-- real average starts from counted close-outs: V737 is a relearn point, and
-- every calculation keeps its design quantity until new data arrives.
UPDATE goods_bom_actual_usages
SET baseline_net_qty=net_qty, baseline_exposure_output_qty=exposure_output_qty,
    baseline_exposure_defect_qty=exposure_defect_qty,
    baseline_sample_count=sample_count, learning_generation=learning_generation+1,
    relearned_at=now(), updated_at=now();

COMMENT ON TABLE goods_bom_learning_profiles IS
    '生产父件学习档案：累计产量与样本数(展示)，以及新建系统学习边被阻止的原因';
COMMENT ON TABLE production_bom_learning_samples IS
    '按生产族一份当前贡献：(组件,单位)的实物净耗、暴露产量与学习轮次；未完成/未核清不贡献，推翻按差额撤回；现场登记新发现的物料回补其它已完工现场族的暴露产量';
