-- Learn only from a finished, reconciled physical production family. The
-- authoritative issue/return/report ledgers remain unchanged; this is a
-- reversible projection. No historical work is enrolled by this migration.
CREATE TABLE goods_bom_learning_profiles (
    goods_id UUID PRIMARY KEY REFERENCES goods(id),
    output_unit_id UUID NOT NULL REFERENCES units(id),
    enabled BOOLEAN NOT NULL DEFAULT TRUE,
    total_output_qty NUMERIC(30,10) NOT NULL DEFAULT 0 CHECK(total_output_qty>=0),
    sample_count BIGINT NOT NULL DEFAULT 0 CHECK(sample_count>=0),
    blocked_reason TEXT,
    revision BIGINT NOT NULL DEFAULT 0,
    created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_at TIMESTAMPTZ NOT NULL DEFAULT now()
);
CREATE TABLE production_bom_learning_samples (
    execution_root_id UUID PRIMARY KEY REFERENCES production_execution_segments(id),
    goods_id UUID NOT NULL REFERENCES goods_bom_learning_profiles(goods_id),
    output_qty NUMERIC(30,10) NOT NULL DEFAULT 0 CHECK(output_qty>=0),
    materials JSONB NOT NULL DEFAULT '[]'::jsonb CHECK(jsonb_typeof(materials)='array'),
    state TEXT NOT NULL,
    revision BIGINT NOT NULL DEFAULT 0,
    updated_at TIMESTAMPTZ NOT NULL DEFAULT now()
);
CREATE INDEX idx_bom_learning_samples_goods ON production_bom_learning_samples(goods_id,execution_root_id);
CREATE TABLE goods_bom_learning_material_totals (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    goods_id UUID NOT NULL REFERENCES goods_bom_learning_profiles(goods_id),
    component_goods_id UUID NOT NULL REFERENCES goods(id),
    color_id UUID REFERENCES colors(id),
    unit_id UUID NOT NULL REFERENCES units(id),
    net_qty NUMERIC(30,10) NOT NULL DEFAULT 0 CHECK(net_qty>=0),
    bom_item_id UUID REFERENCES goods_bom_items(id),
    updated_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    UNIQUE NULLS NOT DISTINCT(goods_id,component_goods_id,color_id,unit_id)
);
-- One entry per family per transaction, irrespective of the number of report
-- lines or posting rows. The deferred drain sees the final transaction state.
CREATE TABLE production_bom_learning_refresh_queue (
    execution_root_id UUID PRIMARY KEY REFERENCES production_execution_segments(id),
    goods_id UUID NOT NULL REFERENCES goods_bom_learning_profiles(goods_id),
    transaction_id BIGINT NOT NULL DEFAULT txid_current(),
    created_at TIMESTAMPTZ NOT NULL DEFAULT now()
);
CREATE INDEX idx_bom_learning_queue_transaction ON production_bom_learning_refresh_queue(transaction_id,goods_id,execution_root_id);
-- Includes retired demands with genuine postings; the operational index is
-- partial on NOT is_deleted and cannot serve that historical-family lookup.
CREATE INDEX idx_bom_learning_demand_family ON production_material_demands(execution_segment_id)
    WHERE execution_segment_id IS NOT NULL;
ALTER TABLE goods_bom_items ADD COLUMN learning_profile_goods_id UUID REFERENCES goods_bom_learning_profiles(goods_id),
    ADD COLUMN learning_unit_id UUID REFERENCES units(id);

-- Manual edits take ownership of the whole parent recipe. Audit marks alone
-- are not recipe edits. This also covers bulk delete and paste/import paths.
CREATE FUNCTION fn_bom_learning_manual_ownership() RETURNS trigger LANGUAGE plpgsql AS $$
DECLARE parent_id UUID; component_id UUID; topology_change BOOLEAN;
BEGIN
    IF current_setting('app.bom_learning_write',TRUE)='on' THEN RETURN COALESCE(NEW,OLD); END IF;
    IF TG_OP='UPDATE' AND (to_jsonb(NEW)-'updated_at'-'updated_by'-'audited_at'-'audited_by')
        IS NOT DISTINCT FROM (to_jsonb(OLD)-'updated_at'-'updated_by'-'audited_at'-'audited_by') THEN RETURN NEW; END IF;
    parent_id:=CASE WHEN TG_OP='DELETE' THEN OLD.goods_id ELSE NEW.goods_id END;
    -- Parent -> profile -> publication is the same order as the deferred
    -- learner. In particular a manual graph edit cannot hold the graph lock
    -- while waiting on a profile held by a learner waiting for that graph.
    PERFORM id FROM goods WHERE id=parent_id FOR NO KEY UPDATE;
    topology_change:=TG_OP='INSERT';
    IF TG_OP='UPDATE' THEN topology_change:=NOT NEW.is_deleted AND (OLD.is_deleted OR
        (NEW.goods_id,NEW.component_goods_id) IS DISTINCT FROM (OLD.goods_id,OLD.component_goods_id)); END IF;
    IF topology_change AND NOT NEW.is_deleted THEN
        PERFORM pg_advisory_xact_lock(hashtextextended('goods-bom-learning-graph',0));
        component_id:=NEW.component_goods_id;
        IF EXISTS(WITH RECURSIVE descendants(id) AS (
            SELECT component_id UNION SELECT edge.component_goods_id FROM descendants node
            JOIN goods_bom_items edge ON edge.goods_id=node.id AND NOT edge.is_deleted AND edge.id<>NEW.id
        ) SELECT 1 FROM descendants WHERE id=parent_id) THEN
            RAISE EXCEPTION 'BOM component would create a cycle' USING ERRCODE='23514';
        END IF;
    END IF;
    UPDATE goods_bom_learning_profiles SET enabled=FALSE,blocked_reason='MANUAL_BOM',updated_at=now()
        WHERE goods_id=parent_id AND enabled;
    RETURN COALESCE(NEW,OLD);
END $$;
CREATE TRIGGER trg_bom_learning_manual_ownership BEFORE INSERT OR UPDATE OR DELETE ON goods_bom_items
    FOR EACH ROW EXECUTE FUNCTION fn_bom_learning_manual_ownership();

CREATE FUNCTION fn_enqueue_bom_learning(p_segment UUID) RETURNS VOID LANGUAGE plpgsql AS $$
DECLARE root_id UUID; parent_id UUID; base_unit UUID;
BEGIN
    SELECT segment.product_goods_id,goods.unit_id INTO parent_id,base_unit
      FROM production_execution_segments segment JOIN goods ON goods.id=segment.product_goods_id
      WHERE segment.id=p_segment;
    IF parent_id IS NULL OR base_unit IS NULL THEN RETURN; END IF;
    IF EXISTS(SELECT 1 FROM production_execution_segments WHERE id=p_segment AND material_discovery_required) THEN
        INSERT INTO goods_bom_learning_profiles(goods_id,output_unit_id,enabled,blocked_reason)
        SELECT parent_id,base_unit,NOT EXISTS(SELECT 1 FROM goods_bom_items WHERE goods_id=parent_id AND NOT is_deleted),
            CASE WHEN EXISTS(SELECT 1 FROM goods_bom_items WHERE goods_id=parent_id AND NOT is_deleted) THEN 'MANUAL_BOM' END
        ON CONFLICT(goods_id) DO NOTHING;
    END IF;
    IF NOT EXISTS(SELECT 1 FROM goods_bom_learning_profiles WHERE goods_id=parent_id) THEN RETURN; END IF;
    root_id:=fn_production_execution_cost_scope(p_segment);
    IF root_id IS NULL THEN RETURN; END IF;
    INSERT INTO production_bom_learning_refresh_queue(execution_root_id,goods_id)
        VALUES(root_id,parent_id) ON CONFLICT(execution_root_id) DO NOTHING;
END $$;

-- Publish only system-owned edges, in the existing BOM quantity precision.
-- All compatibility checks run before any edge changes: a recipe is atomic.
CREATE FUNCTION fn_publish_learned_bom(p_goods UUID) RETURNS VOID LANGUAGE plpgsql AS $$
DECLARE profile goods_bom_learning_profiles%ROWTYPE; material RECORD; edge_id UUID;
    reason TEXT; changed BOOLEAN:=FALSE; affected INTEGER; prior_mode TEXT; event_id UUID;
BEGIN
    SELECT * INTO profile FROM goods_bom_learning_profiles WHERE goods_id=p_goods FOR UPDATE;
    IF NOT FOUND OR NOT profile.enabled THEN RETURN; END IF;
    -- Same shared quantity-basis fence as ordinary BOM writers. Different
    -- products using the same plastic still proceed concurrently; unit edits
    -- take FOR UPDATE and must wait before changing that basis.
    PERFORM component.id FROM goods component WHERE component.id IN(
        SELECT component_goods_id FROM goods_bom_learning_material_totals WHERE goods_id=p_goods AND net_qty>0)
        ORDER BY component.id FOR KEY SHARE;
    -- Quantity-only refinement never takes the graph-wide topology lock.
    IF EXISTS(SELECT 1 FROM goods_bom_learning_material_totals total LEFT JOIN goods_bom_items edge ON edge.id=total.bom_item_id
        WHERE total.goods_id=p_goods AND total.net_qty>0 AND (edge.id IS NULL OR edge.is_deleted)) THEN
        PERFORM pg_advisory_xact_lock(hashtextextended('goods-bom-learning-graph',0));
    END IF;
    IF EXISTS(SELECT 1 FROM goods WHERE id=p_goods AND (is_deleted OR auto_created OR unit_id IS DISTINCT FROM profile.output_unit_id)) THEN
        reason:='OUTPUT_IDENTITY_CHANGED';
    ELSIF EXISTS(SELECT 1 FROM goods_bom_items WHERE goods_id=p_goods AND NOT is_deleted AND learning_profile_goods_id IS DISTINCT FROM p_goods) THEN
        reason:='MANUAL_BOM';
    ELSIF EXISTS(SELECT 1 FROM goods_bom_learning_material_totals total JOIN goods component ON component.id=total.component_goods_id
        WHERE total.goods_id=p_goods AND total.net_qty>0 AND
          (component.is_deleted OR component.auto_created OR component.unit_id IS DISTINCT FROM total.unit_id)) THEN
        reason:='MATERIAL_IDENTITY_CHANGED';
    ELSIF EXISTS(SELECT component_goods_id FROM goods_bom_learning_material_totals WHERE goods_id=p_goods AND net_qty>0
        GROUP BY component_goods_id HAVING count(*)>1) THEN reason:='MATERIAL_COLOR_OR_UNIT_CONFLICT';
    ELSIF profile.total_output_qty>0 AND EXISTS(SELECT 1 FROM goods_bom_learning_material_totals WHERE goods_id=p_goods AND net_qty>0
        AND (round(net_qty/profile.total_output_qty,5)<=0 OR net_qty/profile.total_output_qty>=10000000000000)) THEN
        reason:='BOM_QUANTITY_PRECISION';
    END IF;
    IF reason IS NULL THEN
        FOR material IN SELECT total.* FROM goods_bom_learning_material_totals total LEFT JOIN goods_bom_items edge ON edge.id=total.bom_item_id
            WHERE total.goods_id=p_goods AND total.net_qty>0 AND (edge.id IS NULL OR edge.is_deleted) ORDER BY total.component_goods_id LOOP
            IF EXISTS(WITH RECURSIVE descendants(id) AS (
                SELECT material.component_goods_id UNION
                SELECT edge.component_goods_id FROM descendants node JOIN goods_bom_items edge ON edge.goods_id=node.id AND NOT edge.is_deleted
            ) SELECT 1 FROM descendants WHERE id=p_goods) THEN reason:='BOM_CYCLE'; EXIT; END IF;
        END LOOP;
    END IF;
    UPDATE goods_bom_learning_profiles SET blocked_reason=reason,updated_at=now()
        WHERE goods_id=p_goods AND blocked_reason IS DISTINCT FROM reason;
    IF reason IS NOT NULL THEN RETURN; END IF;
    prior_mode:=current_setting('app.bom_learning_write',TRUE);
    PERFORM set_config('app.bom_learning_write','on',TRUE);
    UPDATE goods_bom_items edge SET is_deleted=TRUE,deleted_at=now(),updated_at=now(),audited_at=NULL,audited_by=NULL
      WHERE edge.goods_id=p_goods AND edge.learning_profile_goods_id=p_goods AND NOT edge.is_deleted
        AND (profile.total_output_qty=0 OR NOT EXISTS(SELECT 1 FROM goods_bom_learning_material_totals total
            WHERE total.goods_id=p_goods AND total.bom_item_id=edge.id AND total.net_qty>0));
    GET DIAGNOSTICS affected=ROW_COUNT; changed:=affected>0;
    IF profile.total_output_qty>0 THEN
        FOR material IN SELECT * FROM goods_bom_learning_material_totals WHERE goods_id=p_goods AND net_qty>0 ORDER BY component_goods_id LOOP
            IF material.bom_item_id IS NULL THEN
                edge_id:=gen_random_uuid();
                INSERT INTO goods_bom_items(id,goods_id,component_goods_id,color_id,qty,control_stage,consumption_basis,basis_output_qty,
                    hard_gate,allow_partial_package,summary,sort_order,learning_profile_goods_id,learning_unit_id)
                VALUES(edge_id,p_goods,material.component_goods_id,material.color_id,round(material.net_qty/profile.total_output_qty,5),
                    'START','PER_UNIT',1,TRUE,TRUE,'按已完工实际净领用累计学习',
                    (SELECT COALESCE(max(sort_order),0)+1 FROM goods_bom_items WHERE goods_id=p_goods),p_goods,material.unit_id);
                UPDATE goods_bom_learning_material_totals SET bom_item_id=edge_id WHERE id=material.id;
                changed:=TRUE;
            ELSE
                UPDATE goods_bom_items SET qty=round(material.net_qty/profile.total_output_qty,5),is_deleted=FALSE,deleted_at=NULL,
                    updated_at=now(),audited_at=NULL,audited_by=NULL
                  WHERE id=material.bom_item_id AND learning_profile_goods_id=p_goods
                    AND (is_deleted OR qty IS DISTINCT FROM round(material.net_qty/profile.total_output_qty,5));
                GET DIAGNOSTICS affected=ROW_COUNT; changed:=changed OR affected>0;
            END IF;
        END LOOP;
    END IF;
    PERFORM set_config('app.bom_learning_write',COALESCE(prior_mode,''),TRUE);
    IF changed THEN
        UPDATE goods SET source_e=(SELECT round(COALESCE(sum(edge.qty*CASE WHEN component.source_type='自制'
                    OR EXISTS(SELECT 1 FROM goods_bom_items child WHERE child.goods_id=component.id AND NOT child.is_deleted)
                    THEN COALESCE(component.c_total,component.price) ELSE component.price END),0),2)
                FROM goods_bom_items edge JOIN goods component ON component.id=edge.component_goods_id
                WHERE edge.goods_id=p_goods AND NOT edge.is_deleted AND NOT component.is_deleted AND NOT component.auto_created),
            updated_at=now() WHERE id=p_goods;
        event_id:=gen_random_uuid();
        INSERT INTO business_outbox(id,event_type,aggregate_type,aggregate_id,payload,dedupe_key)
            VALUES(event_id,'GOODS_BOM_UPDATED','GOODS_BOM',p_goods,'{}'::jsonb,'BOM_LEARNING:'||event_id);
    END IF;
END $$;

CREATE FUNCTION fn_refresh_bom_learning(p_root UUID) RETURNS VOID LANGUAGE plpgsql AS $$
DECLARE root production_execution_segments%ROWTYPE; profile goods_bom_learning_profiles%ROWTYPE;
    old_sample production_bom_learning_samples%ROWTYPE; family UUID[]; output_qty NUMERIC:=0;
    materials JSONB:='[]'::jsonb; settled_materials JSONB:='[]'::jsonb;
    sample_state TEXT:='READY'; material_state TEXT:='READY'; pending_state TEXT; row_data RECORD; entry JSONB;
BEGIN
    SELECT * INTO root FROM production_execution_segments WHERE id=p_root;
    IF NOT FOUND THEN RETURN; END IF;
    SELECT * INTO profile FROM goods_bom_learning_profiles WHERE goods_id=root.product_goods_id FOR UPDATE;
    IF NOT FOUND THEN RETURN; END IF;
    SELECT * INTO old_sample FROM production_bom_learning_samples WHERE execution_root_id=p_root FOR UPDATE;
    SELECT array_agg(segment_id ORDER BY segment_id) INTO family FROM fn_production_execution_cost_members(p_root);
    SELECT COALESCE(sum(item.qty*item.unit_rate),0) INTO output_qty
      FROM production_daily_report_items item JOIN production_daily_reports report ON report.id=item.report_id
      WHERE item.execution_segment_id=ANY(family) AND report.status=1 AND NOT report.is_deleted AND NOT item.is_deleted
        AND item.fqc_recovery_authorization_id IS NULL;
    IF EXISTS(SELECT 1 FROM production_daily_report_items item JOIN production_daily_reports report ON report.id=item.report_id
        WHERE item.execution_segment_id=ANY(family) AND report.status=0 AND NOT report.is_deleted AND NOT item.is_deleted) THEN
        pending_state:='PENDING_REPORT';
    ELSIF EXISTS(SELECT 1 FROM production_actual_output_supplement_requests WHERE source_execution_segment_id=ANY(family) AND status='DRAFT') THEN
        pending_state:='PENDING_SUPPLEMENT';
    END IF;
    IF output_qty<=0 THEN sample_state:='NO_APPROVED_OUTPUT';
    ELSIF EXISTS(SELECT 1 FROM goods WHERE id=root.product_goods_id AND (is_deleted OR auto_created OR unit_id IS DISTINCT FROM profile.output_unit_id))
        OR EXISTS(SELECT 1 FROM production_execution_segments WHERE id=ANY(family) AND product_goods_id<>root.product_goods_id) THEN
        sample_state:='OUTPUT_IDENTITY_CHANGED';
    ELSIF EXISTS(SELECT 1 FROM production_execution_segments segment WHERE segment.id=ANY(family)
        AND NOT segment.is_deleted AND segment.status NOT IN('CANCELLED','REVERSED')
        AND NOT EXISTS(SELECT 1 FROM production_execution_segment_splits split WHERE split.source_segment_id=segment.id)
        AND NOT EXISTS(SELECT 1 FROM production_daily_report_items item JOIN production_daily_reports report ON report.id=item.report_id
            WHERE item.execution_segment_id=segment.id AND report.status=1 AND NOT report.is_deleted AND NOT item.is_deleted AND item.is_final)
        AND COALESCE((SELECT sum(item.qty) FROM production_daily_report_items item JOIN production_daily_reports report ON report.id=item.report_id
            WHERE item.execution_segment_id=segment.id AND report.status=1 AND NOT report.is_deleted AND NOT item.is_deleted
              AND item.fqc_recovery_authorization_id IS NULL),0)<segment.planned_qty) THEN
        sample_state:='PRODUCTION_OPEN';
    END IF;
    -- Demand predicates are applied BEFORE ledger aggregation. Never use a
    -- global SUM view here: only this family's indexed posting ranges are read.
    IF sample_state IN('READY','PRODUCTION_OPEN') THEN
        FOR row_data IN
            SELECT demand.id,demand.goods_id,demand.color_id,demand.unit_id,component.unit_id AS current_unit,
                component.is_deleted AS component_deleted,component.auto_created,
                COALESCE(stock.issued,0) AS issued,COALESCE(stock.returned,0) AS returned,
                COALESCE(settled.consumed,0) AS consumed,COALESCE(settled.loss,0) AS loss,COALESCE(settled.wip,0) AS wip,
                EXISTS(SELECT 1 FROM production_material_stock_postings posting WHERE posting.demand_id=demand.id
                    AND posting.posting_type='ISSUE' AND fn_material_issue_pending_return(posting.id,NULL)>0) AS pending_return
            FROM production_material_demands demand JOIN goods component ON component.id=demand.goods_id
            LEFT JOIN LATERAL(SELECT sum(CASE posting_type WHEN 'ISSUE' THEN qty_base WHEN 'ISSUE_REVERSE' THEN -qty_base ELSE 0 END) AS issued,
                sum(CASE posting_type WHEN 'GOOD_RETURN' THEN qty_base WHEN 'GOOD_RETURN_REVERSE' THEN -qty_base ELSE 0 END) AS returned
                FROM production_material_stock_postings WHERE demand_id=demand.id) stock ON TRUE
            LEFT JOIN LATERAL(SELECT sum(CASE WHEN posting.settlement_type='CONSUMED' THEN CASE event.event_type WHEN 'POST' THEN posting.qty_base ELSE -posting.qty_base END ELSE 0 END) AS consumed,
                sum(CASE WHEN posting.settlement_type='APPROVED_LOSS' THEN CASE event.event_type WHEN 'POST' THEN posting.qty_base ELSE -posting.qty_base END ELSE 0 END) AS loss,
                sum(CASE WHEN posting.settlement_type='LEGAL_WIP' THEN CASE event.event_type WHEN 'POST' THEN posting.qty_base ELSE -posting.qty_base END ELSE 0 END) AS wip
                FROM production_material_settlement_postings posting JOIN production_material_settlement_events event ON event.id=posting.event_id
                WHERE posting.demand_id=demand.id) settled ON TRUE
            WHERE demand.execution_segment_id=ANY(family)
              AND (NOT demand.is_deleted OR EXISTS(SELECT 1 FROM production_material_stock_postings WHERE demand_id=demand.id))
            ORDER BY demand.goods_id,demand.color_id,demand.unit_id,demand.id
        LOOP
            IF row_data.issued=0 AND row_data.returned=0 AND row_data.consumed=0 AND row_data.loss=0 AND row_data.wip=0 THEN CONTINUE; END IF;
            IF row_data.component_deleted OR row_data.auto_created OR row_data.unit_id IS DISTINCT FROM row_data.current_unit THEN
                material_state:='MATERIAL_IDENTITY_CHANGED';
            ELSIF row_data.pending_return AND material_state='READY' THEN material_state:='PENDING_RETURN';
            ELSIF row_data.wip<>0 OR row_data.issued-row_data.returned<>row_data.consumed+row_data.loss
                OR row_data.issued<row_data.returned OR row_data.consumed<0 OR row_data.loss<0 THEN
                IF material_state='READY' THEN material_state:='MATERIAL_NOT_CLEARED'; END IF;
            END IF;
            -- Previously completed use remains valid when fresh material is
            -- issued for the next batch. Prove it from still-posted use/loss
            -- and real net issue, never from unconsumed custody.
            settled_materials:=settled_materials||jsonb_build_array(jsonb_build_object('goodsId',row_data.goods_id,'colorId',row_data.color_id,
                'unitId',row_data.unit_id,'qty',LEAST(row_data.issued-row_data.returned,row_data.consumed+row_data.loss)));
            IF row_data.issued-row_data.returned>0 THEN
                materials:=materials||jsonb_build_array(jsonb_build_object('goodsId',row_data.goods_id,'colorId',row_data.color_id,
                    'unitId',row_data.unit_id,'qty',row_data.issued-row_data.returned));
            END IF;
        END LOOP;
        IF material_state<>'READY' THEN sample_state:=material_state;
        ELSIF jsonb_array_length(materials)=0 THEN sample_state:='NO_NET_MATERIAL'; END IF;
    END IF;
    SELECT COALESCE(jsonb_agg(jsonb_build_object('goodsId',goods_id,'colorId',color_id,'unitId',unit_id,'qty',qty)
        ORDER BY goods_id,color_id,unit_id),'[]'::jsonb) INTO materials
    FROM (SELECT value->>'goodsId' goods_id,value->>'colorId' color_id,value->>'unitId' unit_id,sum((value->>'qty')::numeric) qty
        FROM jsonb_array_elements(materials) GROUP BY value->>'goodsId',value->>'colorId',value->>'unitId') grouped;
    IF pending_state IS NOT NULL AND sample_state IN('READY','PRODUCTION_OPEN') THEN
        sample_state:=pending_state;
    END IF;
    IF sample_state<>'READY' THEN
        -- Drafts and fresh open work cannot erase completed knowledge. Actual
        -- output/use reversal or a confirmed return reducing the old exact
        -- contribution fails this proof and is withdrawn immediately.
        IF old_sample.output_qty>0 AND output_qty>=old_sample.output_qty
            AND sample_state NOT IN('OUTPUT_IDENTITY_CHANGED','MATERIAL_IDENTITY_CHANGED','NO_APPROVED_OUTPUT')
            AND NOT EXISTS(SELECT 1 FROM jsonb_array_elements(old_sample.materials) prior
                WHERE (prior->>'qty')::numeric>COALESCE((SELECT sum((actual->>'qty')::numeric)
                    FROM jsonb_array_elements(settled_materials) actual WHERE actual->>'goodsId'=prior->>'goodsId'
                        AND actual->>'colorId' IS NOT DISTINCT FROM prior->>'colorId' AND actual->>'unitId'=prior->>'unitId'),0)) THEN
            RETURN;
        END IF;
        output_qty:=0; materials:='[]'::jsonb;
    END IF;
    IF old_sample.execution_root_id IS NOT NULL AND old_sample.output_qty=output_qty
        AND old_sample.materials=materials AND old_sample.state=sample_state THEN RETURN; END IF;
    IF old_sample.execution_root_id IS NOT NULL THEN
        FOR entry IN SELECT value FROM jsonb_array_elements(old_sample.materials) LOOP
            UPDATE goods_bom_learning_material_totals SET net_qty=net_qty-(entry->>'qty')::numeric,updated_at=now()
              WHERE goods_id=root.product_goods_id AND component_goods_id=(entry->>'goodsId')::uuid
                AND color_id IS NOT DISTINCT FROM (entry->>'colorId')::uuid AND unit_id=(entry->>'unitId')::uuid;
        END LOOP;
    END IF;
    FOR entry IN SELECT value FROM jsonb_array_elements(materials) LOOP
        INSERT INTO goods_bom_learning_material_totals(goods_id,component_goods_id,color_id,unit_id,net_qty)
        VALUES(root.product_goods_id,(entry->>'goodsId')::uuid,(entry->>'colorId')::uuid,(entry->>'unitId')::uuid,(entry->>'qty')::numeric)
        ON CONFLICT(goods_id,component_goods_id,color_id,unit_id) DO UPDATE
            SET net_qty=goods_bom_learning_material_totals.net_qty+EXCLUDED.net_qty,updated_at=now();
    END LOOP;
    UPDATE goods_bom_learning_profiles SET total_output_qty=total_output_qty+output_qty-COALESCE(old_sample.output_qty,0),
        sample_count=sample_count+CASE WHEN output_qty>0 THEN 1 ELSE 0 END-CASE WHEN COALESCE(old_sample.output_qty,0)>0 THEN 1 ELSE 0 END,
        revision=revision+1,updated_at=now() WHERE goods_id=root.product_goods_id;
    INSERT INTO production_bom_learning_samples(execution_root_id,goods_id,output_qty,materials,state,revision)
        VALUES(p_root,root.product_goods_id,output_qty,materials,sample_state,1)
    ON CONFLICT(execution_root_id) DO UPDATE SET output_qty=EXCLUDED.output_qty,materials=EXCLUDED.materials,state=EXCLUDED.state,
        revision=production_bom_learning_samples.revision+1,updated_at=now();
    PERFORM fn_publish_learned_bom(root.product_goods_id);
END $$;

CREATE FUNCTION fn_drain_bom_learning_queue() RETURNS trigger LANGUAGE plpgsql AS $$
DECLARE queued RECORD;
BEGIN
    -- Match master-data writers' parent-before-profile order and sort every
    -- parent touched by this transaction before publishing any one of them.
    PERFORM goods.id FROM goods WHERE id IN(SELECT goods_id FROM production_bom_learning_refresh_queue WHERE transaction_id=txid_current())
        ORDER BY goods.id FOR NO KEY UPDATE;
    FOR queued IN SELECT execution_root_id FROM production_bom_learning_refresh_queue WHERE transaction_id=txid_current()
        ORDER BY goods_id,execution_root_id LOOP
        DELETE FROM production_bom_learning_refresh_queue WHERE execution_root_id=queued.execution_root_id AND transaction_id=txid_current();
        PERFORM fn_refresh_bom_learning(queued.execution_root_id);
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
        FOR segment_id IN SELECT DISTINCT execution_segment_id FROM production_daily_report_items WHERE report_id=(payload->>'id')::uuid LOOP
            PERFORM fn_enqueue_bom_learning(segment_id);
        END LOOP;
    ELSIF TG_TABLE_NAME IN('production_material_stock_postings','production_material_settlement_postings') THEN
        PERFORM fn_enqueue_bom_learning((SELECT execution_segment_id FROM production_material_demands WHERE id=(payload->>'demand_id')::uuid));
    ELSIF TG_TABLE_NAME='production_actual_output_supplement_reversals' THEN
        PERFORM fn_enqueue_bom_learning((SELECT source_execution_segment_id FROM production_actual_output_supplement_proofs WHERE id=(payload->>'proof_id')::uuid));
    ELSIF TG_TABLE_NAME='production_material_return_request_cancellations' THEN
        PERFORM fn_enqueue_bom_learning((SELECT execution_segment_id FROM production_material_return_requests WHERE id=(payload->>'request_id')::uuid));
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
CREATE TRIGGER trg_learn_bom_segment AFTER INSERT OR UPDATE OF status,is_deleted,planned_qty,material_discovery_required,material_requirement_mode,
    source_segment_id,split_root_segment_id,product_goods_id,product_unit_id,product_unit_rate ON production_execution_segments
    FOR EACH ROW EXECUTE FUNCTION fn_touch_bom_learning();
CREATE TRIGGER trg_learn_bom_report AFTER UPDATE OF status,is_deleted ON production_daily_reports FOR EACH ROW EXECUTE FUNCTION fn_touch_bom_learning();
CREATE TRIGGER trg_learn_bom_report_item AFTER INSERT OR UPDATE OF execution_segment_id,qty,unit_rate,is_final,is_deleted,fqc_recovery_authorization_id
    OR DELETE ON production_daily_report_items FOR EACH ROW EXECUTE FUNCTION fn_touch_bom_learning();
CREATE TRIGGER trg_learn_bom_issue AFTER INSERT ON production_material_stock_postings FOR EACH ROW EXECUTE FUNCTION fn_touch_bom_learning();
CREATE TRIGGER trg_learn_bom_settlement AFTER INSERT ON production_material_settlement_postings FOR EACH ROW EXECUTE FUNCTION fn_touch_bom_learning();
CREATE TRIGGER trg_learn_bom_demand AFTER INSERT OR UPDATE ON production_material_demands FOR EACH ROW EXECUTE FUNCTION fn_touch_bom_learning();
CREATE TRIGGER trg_learn_bom_return_request AFTER INSERT ON production_material_return_requests FOR EACH ROW EXECUTE FUNCTION fn_touch_bom_learning();
CREATE TRIGGER trg_learn_bom_return_cancel AFTER INSERT ON production_material_return_request_cancellations FOR EACH ROW EXECUTE FUNCTION fn_touch_bom_learning();
CREATE TRIGGER trg_learn_bom_supplement AFTER INSERT ON production_actual_output_supplement_proofs FOR EACH ROW EXECUTE FUNCTION fn_touch_bom_learning();
CREATE TRIGGER trg_learn_bom_supplement_request AFTER INSERT OR UPDATE ON production_actual_output_supplement_requests FOR EACH ROW EXECUTE FUNCTION fn_touch_bom_learning();
CREATE TRIGGER trg_learn_bom_supplement_reverse AFTER INSERT ON production_actual_output_supplement_reversals FOR EACH ROW EXECUTE FUNCTION fn_touch_bom_learning();
CREATE TRIGGER trg_learn_bom_split AFTER INSERT ON production_execution_segment_splits FOR EACH ROW EXECUTE FUNCTION fn_touch_bom_learning();

COMMENT ON TABLE goods_bom_learning_profiles IS '原叶自制件累计学习身份；仅影响未来BOM，人工维护后停止自动发布';
COMMENT ON TABLE production_bom_learning_samples IS '按真实物料成本族单次贡献；分批/追加共用，草稿、在制、待退料不贡献，反向按差额撤回';
COMMENT ON TABLE goods_bom_learning_material_totals IS '精确货品/颜色/基础单位净耗累计；平均值为净耗累计除以父件全部有效样本实际产出累计';

SELECT fn_audit_track_table('goods_bom_learning_profiles','FULL','data_change',false);
SELECT fn_audit_track_table('goods_bom_learning_material_totals','FULL','data_change',false);
SELECT fn_audit_track_table('production_bom_learning_samples','FULL','data_change',false);
SELECT fn_audit_track_table('production_bom_learning_refresh_queue','NONE','data_change',false);
-- Business reset preserves learned master knowledge (the existing recipe and
-- cumulative numerator/denominator). Removed source samples become a fixed
-- historical baseline; future valid batches append normally. There is no
-- reversal of reset-away source documents and no silent reweighting to zero.
DO $reset_policy$
DECLARE definition TEXT; anchor TEXT:='(''stock_movements'', ''CLEAR'')';
BEGIN
    SELECT pg_get_functiondef('business_data_reset()'::regprocedure) INTO definition;
    IF (length(definition)-length(replace(definition,anchor,'')))/length(anchor)<>1 THEN
        RAISE EXCEPTION 'V711 cannot extend business-data reset policy safely';
    END IF;
    EXECUTE replace(definition,anchor,anchor||E',\n            (''production_bom_learning_samples'', ''CLEAR''),\n            (''production_bom_learning_refresh_queue'', ''CLEAR''),\n            (''goods_bom_learning_profiles'', ''PRESERVE''),\n            (''goods_bom_learning_material_totals'', ''PRESERVE'')');
END;
$reset_policy$;
