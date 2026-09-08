-- Real output sources may have distinct, pre-registered receipt-material and normal-loss scopes.
ALTER TABLE subcontract_material_plan_items ADD COLUMN loss_replacement_qty_base NUMERIC(18,4) NOT NULL DEFAULT 0 CHECK(loss_replacement_qty_base>=0);
CREATE FUNCTION fn_check_subcontract_loss_allowance() RETURNS trigger LANGUAGE plpgsql AS $$
DECLARE expected NUMERIC;current_plan subcontract_material_plan_items%ROWTYPE;
BEGIN
    SELECT * INTO current_plan FROM subcontract_material_plan_items WHERE id=NEW.id;
    IF current_plan.flow_mode<>'DIRECT_OUTBOUND' THEN RETURN NULL; END IF;
    SELECT GREATEST(COALESCE(SUM((item.wasted_qty-COALESCE(item.compensated_qty,0))*COALESCE(item.unit_rate,1)),0),0)
      INTO expected FROM subcontract_material_issue_items item JOIN subcontract_material_issues issue ON issue.id=item.issue_id
      WHERE item.plan_item_id=NEW.id AND issue.status=1 AND NOT issue.is_deleted AND NOT item.is_deleted;
    IF current_plan.loss_replacement_qty_base<>expected THEN
        RAISE EXCEPTION 'additional subcontract loss authorization must match actual unresolved material losses' USING ERRCODE='23514';
    END IF;
    RETURN NULL;
END;
$$;
CREATE CONSTRAINT TRIGGER trg_subcontract_loss_allowance AFTER INSERT OR UPDATE ON subcontract_material_plan_items
    DEFERRABLE INITIALLY DEFERRED FOR EACH ROW EXECUTE FUNCTION fn_check_subcontract_loss_allowance();
ALTER TABLE subcontract_material_plan_items ENABLE ALWAYS TRIGGER trg_subcontract_loss_allowance;

CREATE FUNCTION fn_guard_classified_subcontract_loss_source() RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
    IF (NEW.qty,NEW.standard_qty,NEW.unit_id,NEW.unit_rate,NEW.material_issue_item_id,NEW.goods_id,NEW.color_id)
       IS DISTINCT FROM (OLD.qty,OLD.standard_qty,OLD.unit_id,OLD.unit_rate,OLD.material_issue_item_id,OLD.goods_id,OLD.color_id)
       AND EXISTS(SELECT 1 FROM subcontract_wastes waste WHERE waste.id=OLD.waste_id AND waste.status<>0) THEN
        RAISE EXCEPTION 'approved subcontract loss quantity, classification and source are immutable' USING ERRCODE='55000';
    END IF;
    RETURN NEW;
END;
$$;
CREATE TRIGGER trg_classified_subcontract_loss_source BEFORE UPDATE ON subcontract_waste_items
    FOR EACH ROW EXECUTE FUNCTION fn_guard_classified_subcontract_loss_source();
ALTER TABLE subcontract_waste_items ENABLE ALWAYS TRIGGER trg_classified_subcontract_loss_source;
ALTER TABLE stock_value_production_cost_objects DROP CONSTRAINT stock_value_production_cost_objects_source_kind_check;
ALTER TABLE stock_value_production_cost_objects ADD CONSTRAINT stock_value_cost_scope_kind_check
    CHECK(source_kind IN ('PRODUCTION_EXECUTION','SUBCONTRACT_RECEIPT_ITEM','SUBCONTRACT_ORDER_NORMAL_LOSS'));
ALTER TABLE stock_value_production_cost_shares DROP CONSTRAINT stock_value_production_cost_shares_output_source_node_id_fkey;
ALTER TABLE stock_value_production_cost_outputs DROP CONSTRAINT stock_value_production_cost_outputs_pkey;
ALTER TABLE stock_value_production_cost_outputs DROP CONSTRAINT stock_value_production_cost_outputs_movement_id_key;
ALTER TABLE stock_value_production_cost_outputs ADD PRIMARY KEY(execution_segment_id,source_node_id);
ALTER TABLE stock_value_production_cost_outputs ADD CONSTRAINT stock_value_cost_scope_movement_unique UNIQUE(execution_segment_id,movement_id);
ALTER TABLE stock_value_production_cost_shares ADD CONSTRAINT stock_value_cost_share_output_source_fk
    FOREIGN KEY(output_source_node_id) REFERENCES stock_value_nodes(id);

CREATE OR REPLACE FUNCTION fn_guard_inventory_cost_scope_source() RETURNS trigger LANGUAGE plpgsql AS $$
DECLARE target_goods UUID;target_color UUID;
BEGIN
    IF NEW.source_kind='PRODUCTION_EXECUTION' THEN
        SELECT product_goods_id,product_color_id INTO target_goods,target_color FROM production_execution_segments WHERE id=NEW.execution_segment_id;
    ELSIF NEW.source_kind='SUBCONTRACT_RECEIPT_ITEM' THEN
        SELECT goods_id,color_id INTO target_goods,target_color FROM subcontract_receipt_items WHERE id=NEW.execution_segment_id;
    ELSE
        SELECT goods_id,color_id INTO target_goods,target_color FROM subcontract_order_items WHERE id=NEW.execution_segment_id;
    END IF;
    IF target_goods IS NULL OR NOT EXISTS(SELECT 1 FROM stock_value_pools p WHERE p.id=NEW.product_pool_id
        AND p.goods_id=target_goods AND p.color_id IS NOT DISTINCT FROM target_color) THEN
        RAISE EXCEPTION 'cost scope must identify its real typed business source and product' USING ERRCODE='23514';
    END IF;
    RETURN NEW;
END;
$$;

-- Bounds are a disposable numerical cache. Publish a finite book projection only when both ends agree;
-- the value node and its original source/quantity shares remain the monetary authority.
CREATE FUNCTION fn_inventory_value_book_projection(p_node UUID) RETURNS NUMERIC LANGUAGE sql STABLE AS $$
    WITH value_node AS (SELECT * FROM stock_value_nodes WHERE id=p_node), portions AS (
        SELECT source.pending_parents,source.bound_revision=source.revision valid,
            source.bound_lower*transfer.range_from/transfer.quantity_basis::numeric(100,40) low_from,
            source.bound_upper*transfer.range_from/transfer.quantity_basis::numeric(100,40) high_from,
            source.bound_lower*transfer.range_to/transfer.quantity_basis::numeric(100,40) low_to,
            source.bound_upper*transfer.range_to/transfer.quantity_basis::numeric(100,40) high_to
        FROM stock_value_position_transfers transfer JOIN stock_value_nodes source ON source.id=transfer.source_node_id
        WHERE transfer.target_node_id=p_node
    )
    SELECT CASE WHEN n.pending_parents<>0 THEN NULL
        WHEN EXISTS(SELECT 1 FROM portions) THEN (SELECT CASE WHEN BOOL_AND(pending_parents=0 AND valid
            AND low_from IS NOT NULL AND ROUND(low_from,30)=ROUND(high_from,30) AND ROUND(low_to,30)=ROUND(high_to,30))
            THEN SUM(ROUND(low_to,30)-ROUND(low_from,30)) END FROM portions)
        WHEN n.bound_revision=n.revision AND n.bound_lower IS NOT NULL AND ROUND(n.bound_lower,30)=ROUND(n.bound_upper,30)
            THEN ROUND(n.bound_lower,30) END FROM value_node n;
$$;

CREATE VIEW v_subcontract_waste_actual_value AS
SELECT item.id waste_item_id,issue.order_item_id,item.qty actual_qty,
       LEAST(item.qty,COALESCE(item.standard_qty,0)) normal_qty,
       item.qty-LEAST(item.qty,COALESCE(item.standard_qty,0)) excess_qty,
       normal.result_node_id normal_value_node_id,excess.result_node_id excess_value_node_id,
       CASE WHEN LEAST(item.qty,COALESCE(item.standard_qty,0))=0 THEN 0 ELSE fn_inventory_value_book_projection(normal.result_node_id) END normal_value_local,
       CASE WHEN item.qty=LEAST(item.qty,COALESCE(item.standard_qty,0)) THEN 0 ELSE fn_inventory_value_book_projection(excess.result_node_id) END excess_value_local,
       (LEAST(item.qty,COALESCE(item.standard_qty,0))=0 OR fn_inventory_value_book_projection(normal.result_node_id) IS NOT NULL)
        AND (item.qty=LEAST(item.qty,COALESCE(item.standard_qty,0)) OR fn_inventory_value_book_projection(excess.result_node_id) IS NOT NULL)
        AND NOT EXISTS(SELECT 1 FROM stock_value_jobs WHERE status='PENDING') complete,
       (LEAST(item.qty,COALESCE(item.standard_qty,0))=0 OR normal.result_node_id IS NOT NULL)
        AND (item.qty=LEAST(item.qty,COALESCE(item.standard_qty,0)) OR excess.result_node_id IS NOT NULL) classified
FROM subcontract_waste_items item JOIN subcontract_material_issue_items issue ON issue.id=item.material_issue_item_id
LEFT JOIN stock_value_events normal ON normal.source_doc_type='SUBCONTRACT_NORMAL_LOSS' AND normal.source_item_id=item.id
LEFT JOIN stock_value_events excess ON excess.source_doc_type='SUBCONTRACT_EXCESS_LOSS' AND excess.source_item_id=item.id;

CREATE FUNCTION fn_check_subcontract_loss_position_fact() RETURNS trigger LANGUAGE plpgsql AS $$
DECLARE item subcontract_waste_items%ROWTYPE;issue subcontract_material_issue_items%ROWTYPE;
    target stock_value_nodes%ROWTYPE;original UUID;expected_qty NUMERIC;is_normal BOOLEAN;is_reverse BOOLEAN;
BEGIN
    IF NEW.source_doc_type NOT IN ('SUBCONTRACT_WASTE_VALUE','SUBCONTRACT_NORMAL_LOSS','SUBCONTRACT_EXCESS_LOSS',
        'SUBCONTRACT_NORMAL_LOSS_REVERSE','SUBCONTRACT_EXCESS_LOSS_REVERSE') THEN RETURN NULL; END IF;
    SELECT * INTO item FROM subcontract_waste_items WHERE id=NEW.source_item_id;
    SELECT * INTO issue FROM subcontract_material_issue_items WHERE id=item.material_issue_item_id;
    SELECT * INTO target FROM stock_value_nodes WHERE id=NEW.result_node_id;
    is_normal:=NEW.source_doc_type LIKE 'SUBCONTRACT_NORMAL%';is_reverse:=NEW.source_doc_type LIKE '%REVERSE';
    expected_qty:=CASE WHEN NEW.source_doc_type='SUBCONTRACT_WASTE_VALUE' THEN item.qty
        WHEN is_normal THEN LEAST(item.qty,COALESCE(item.standard_qty,0))
        ELSE item.qty-LEAST(item.qty,COALESCE(item.standard_qty,0)) END*COALESCE(item.unit_rate,1);
    IF item.id IS NULL OR issue.id IS NULL OR NEW.source_doc_id<>item.waste_id OR NEW.qty_base<>expected_qty
       OR target.quantity_basis<>expected_qty OR NOT EXISTS(SELECT 1 FROM stock_value_pools p WHERE p.id=target.pool_id
            AND p.goods_id=item.goods_id AND p.color_id IS NOT DISTINCT FROM item.color_id)
       OR target.owner_kind IS DISTINCT FROM (CASE WHEN is_reverse OR NEW.source_doc_type='SUBCONTRACT_WASTE_VALUE' THEN 'SUBCONTRACT_WIP'
            WHEN is_normal THEN 'COST_WIP' ELSE 'LOSS' END)
       OR target.owner_id IS DISTINCT FROM (CASE WHEN is_reverse THEN issue.id WHEN is_normal THEN issue.order_item_id ELSE item.id END) THEN
        RAISE EXCEPTION 'subcontract loss classification must retain the exact issued identity and physical interval' USING ERRCODE='23514';
    END IF;
    IF NEW.source_doc_type='SUBCONTRACT_WASTE_VALUE' THEN
        IF EXISTS(SELECT 1 FROM stock_value_position_transfers transfer JOIN stock_value_nodes source ON source.id=transfer.source_node_id
            WHERE transfer.event_id=NEW.id AND (source.owner_kind<>'SUBCONTRACT_WIP' OR source.owner_id<>issue.id)) THEN
            RAISE EXCEPTION 'subcontract loss cannot borrow another issue material source' USING ERRCODE='23514';
        END IF;
    ELSE
        SELECT result_node_id INTO original FROM stock_value_events WHERE source_item_id=item.id
            AND source_doc_type=CASE WHEN NOT is_reverse THEN 'SUBCONTRACT_WASTE_VALUE'
                WHEN is_normal THEN 'SUBCONTRACT_NORMAL_LOSS' ELSE 'SUBCONTRACT_EXCESS_LOSS' END;
        IF original IS NULL OR (is_reverse AND is_normal AND NEW.source_node_id IS DISTINCT FROM original)
           OR (NOT(is_reverse AND is_normal) AND NOT EXISTS(SELECT 1 FROM stock_value_position_transfers transfer
                WHERE transfer.event_id=NEW.id AND transfer.source_root_id=original AND transfer.qty_base=expected_qty)) THEN
            RAISE EXCEPTION 'normal and excess loss must use their own original material interval' USING ERRCODE='23514';
        END IF;
    END IF;
    RETURN NULL;
END;
$$;
CREATE CONSTRAINT TRIGGER trg_subcontract_loss_position_fact AFTER INSERT ON stock_value_events
    DEFERRABLE INITIALLY DEFERRED FOR EACH ROW EXECUTE FUNCTION fn_check_subcontract_loss_position_fact();
ALTER TABLE stock_value_events ENABLE ALWAYS TRIGGER trg_subcontract_loss_position_fact;

CREATE FUNCTION fn_check_subcontract_normal_cost_input() RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
    IF EXISTS(SELECT 1 FROM stock_value_production_cost_objects object WHERE object.execution_segment_id=NEW.execution_segment_id
        AND object.source_kind='SUBCONTRACT_ORDER_NORMAL_LOSS') AND (
        NEW.input_kind<>'NORMAL_LOSS' OR NOT EXISTS(SELECT 1 FROM stock_value_events event
            JOIN subcontract_waste_items waste ON waste.id=event.source_item_id
            JOIN subcontract_material_issue_items issue ON issue.id=waste.material_issue_item_id
            WHERE event.source_doc_type='SUBCONTRACT_NORMAL_LOSS' AND event.result_node_id=NEW.input_node_id
                AND waste.id=NEW.approved_posting_id AND issue.order_item_id=NEW.execution_segment_id)) THEN
        RAISE EXCEPTION 'normal-loss cost input requires the exact approved waste interval and order scope' USING ERRCODE='23514';
    END IF;
    RETURN NULL;
END;
$$;
CREATE CONSTRAINT TRIGGER trg_subcontract_normal_cost_input AFTER INSERT ON stock_value_production_cost_inputs
    DEFERRABLE INITIALLY DEFERRED FOR EACH ROW EXECUTE FUNCTION fn_check_subcontract_normal_cost_input();
ALTER TABLE stock_value_production_cost_inputs ENABLE ALWAYS TRIGGER trg_subcontract_normal_cost_input;

CREATE VIEW v_subcontract_normal_loss_basis AS
SELECT item.id order_item_id,
       approved.id approval_case_id,
       COALESCE(pending.old_qty,item.qty)*COALESCE(item.unit_rate,1) target_qty_base,
       header.status=1 AND approved.id IS NOT NULL AND NOT EXISTS(
           SELECT 1 FROM subcontract_waste_items waste JOIN subcontract_wastes document ON document.id=waste.waste_id
           JOIN subcontract_material_issue_items issue ON issue.id=waste.material_issue_item_id
           LEFT JOIN v_subcontract_waste_actual_value value ON value.waste_item_id=waste.id
           WHERE issue.order_item_id=item.id AND document.status=1 AND NOT document.is_deleted AND NOT waste.is_deleted
             AND value.classified IS DISTINCT FROM TRUE) classification_complete
FROM subcontract_order_items item JOIN subcontract_orders header ON header.id=item.order_id
LEFT JOIN LATERAL(SELECT id,decided_at FROM procurement_order_approval_cases approval
    WHERE approval.order_type='SUBCONTRACT' AND approval.order_id=header.id AND approval.status='APPROVED'
    ORDER BY approval.decided_at DESC,approval.attempt DESC LIMIT 1) approved ON TRUE
LEFT JOIN LATERAL(SELECT change.old_qty FROM procurement_order_qty_change_logs change
    WHERE change.order_type='SUBCONTRACT' AND change.order_item_id=item.id AND change.changed_at>approved.decided_at
    ORDER BY change.changed_at,change.id LIMIT 1) pending ON TRUE;

CREATE OR REPLACE FUNCTION fn_check_subcontract_cost_scope_facts() RETURNS trigger LANGUAGE plpgsql AS $$
DECLARE object stock_value_production_cost_objects%ROWTYPE;expected_qty NUMERIC;complete BOOLEAN;approval UUID;
BEGIN
    SELECT * INTO object FROM stock_value_production_cost_objects WHERE execution_segment_id=NEW.execution_segment_id;
    IF object.source_kind='PRODUCTION_EXECUTION' THEN
        IF TG_TABLE_NAME='stock_value_production_cost_outputs' AND NOT EXISTS(
            SELECT 1 FROM stock_movements movement JOIN stock_document_items item ON item.id=movement.source_item_id
            JOIN stock_documents document ON document.id=item.doc_id AND document.id=movement.source_doc_id
            WHERE movement.id=NEW.movement_id AND movement.source_doc_type='STOCK_DOC' AND document.doc_type='FINISHED_IN'
                AND item.execution_segment_id=NEW.execution_segment_id) THEN
            RAISE EXCEPTION 'production output scope must match its actual finished-in document execution source' USING ERRCODE='23514';
        END IF;
        RETURN NULL;
    END IF;
    IF TG_TABLE_NAME='stock_value_production_cost_revisions' THEN
        IF object.source_kind='SUBCONTRACT_ORDER_NORMAL_LOSS' THEN
            SELECT target_qty_base,classification_complete,approval_case_id INTO expected_qty,complete,approval FROM v_subcontract_normal_loss_basis WHERE order_item_id=object.execution_segment_id;
            IF approval IS NOT NULL AND NEW.approval_evidence_id<>approval THEN
                RAISE EXCEPTION 'normal-loss allocation must identify the current financial target approval' USING ERRCODE='23514';
            END IF;
        ELSE
            SELECT COALESCE(SUM(base_qty),0) INTO expected_qty FROM procurement_receipt_consideration_parts
                WHERE receipt_type='SUBCONTRACT' AND receipt_item_id=object.execution_segment_id AND billing_mode='STANDARD';
            SELECT expected_qty>0 AND expected_qty=(SELECT COALESCE(SUM(qty_base),0) FROM subcontract_receipt_material_consumptions c
                WHERE c.receipt_item_id=object.execution_segment_id AND c.reversal_of IS NULL
                  AND NOT EXISTS(SELECT 1 FROM subcontract_receipt_material_consumptions reversed WHERE reversed.reversal_of=c.id))
                AND NOT EXISTS(SELECT 1 FROM subcontract_receipt_material_consumptions c WHERE c.receipt_item_id=object.execution_segment_id
                    AND c.reversal_of IS NULL AND c.consumption_basis<>'DIRECT_TARGET') INTO complete;
        END IF;
        IF expected_qty IS NULL OR NEW.target_qty_base<>expected_qty OR (NEW.scope_complete AND complete IS DISTINCT FROM TRUE) THEN
            RAISE EXCEPTION 'subcontract cost basis must use approved target quantity and explicitly classified original materials' USING ERRCODE='23514';
        END IF;
    ELSE
        IF NOT EXISTS(SELECT 1 FROM procurement_iqc_stock_in_batch_items item
            JOIN procurement_iqc_stock_consideration_parts stocked ON stocked.stock_in_item_id=item.id
            JOIN procurement_iqc_quality_consideration_parts quality ON quality.id=stocked.quality_part_id
            JOIN procurement_receipt_consideration_parts part ON part.id=quality.consideration_part_id
            LEFT JOIN procurement_iqc_funding_slices funding ON funding.id=part.funding_slice_id
            JOIN subcontract_receipt_items original ON original.id=CASE WHEN part.billing_mode='STANDARD' THEN part.receipt_item_id ELSE funding.root_receipt_item_id END
            WHERE item.stock_movement_id=NEW.movement_id AND part.receipt_type='SUBCONTRACT'
              AND CASE WHEN object.source_kind='SUBCONTRACT_ORDER_NORMAL_LOSS' THEN original.order_item_id ELSE original.id END=object.execution_segment_id)
        OR EXISTS(SELECT 1 FROM procurement_iqc_stock_in_batch_items item
            JOIN procurement_iqc_stock_consideration_parts stocked ON stocked.stock_in_item_id=item.id
            JOIN procurement_iqc_quality_consideration_parts quality ON quality.id=stocked.quality_part_id
            JOIN procurement_receipt_consideration_parts part ON part.id=quality.consideration_part_id
            LEFT JOIN procurement_iqc_funding_slices funding ON funding.id=part.funding_slice_id
            JOIN subcontract_receipt_items original ON original.id=CASE WHEN part.billing_mode='STANDARD' THEN part.receipt_item_id ELSE funding.root_receipt_item_id END
            WHERE item.stock_movement_id=NEW.movement_id
              AND CASE WHEN object.source_kind='SUBCONTRACT_ORDER_NORMAL_LOSS' THEN original.order_item_id ELSE original.id END IS DISTINCT FROM object.execution_segment_id) THEN
            RAISE EXCEPTION 'subcontract output must retain the exact original receipt and normal-loss order scopes' USING ERRCODE='23514';
        END IF;
    END IF;
    RETURN NULL;
END;
$$;

DO $empty_normal_scope$
DECLARE definition TEXT;needle TEXT:='r.scope_complete AND jsonb_array_length(r.input_snapshot)>0 AND jsonb_array_length(r.output_snapshot)>0';
BEGIN
    SELECT pg_get_functiondef('fn_check_stock_value_cost_object()'::regprocedure) INTO definition;
    IF position(needle IN definition)=0 THEN RAISE EXCEPTION 'normal loss scope completion anchor changed'; END IF;
    EXECUTE replace(definition,needle,'r.scope_complete AND (jsonb_array_length(r.input_snapshot)>0 OR current_object.source_kind=''SUBCONTRACT_ORDER_NORMAL_LOSS'') AND jsonb_array_length(r.output_snapshot)>0');
END;
$empty_normal_scope$;

-- Preserve the V524 output, actual settlement and final-report sources; add exact subcontract loss and financial approvals.
CREATE OR REPLACE FUNCTION fn_guard_cost_business_refresh_source() RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
    IF NEW.business_refresh_event_id IS NULL AND NEW.business_refresh_actor_id IS NULL AND NOT NEW.business_refresh_pending THEN RETURN NEW; END IF;
    IF NEW.business_refresh_event_id IS NULL OR NEW.business_refresh_actor_id IS NULL OR NOT (
        EXISTS(SELECT 1 FROM stock_value_production_cost_outputs output JOIN stock_value_events event ON event.movement_id=output.movement_id
            WHERE output.execution_segment_id=NEW.execution_segment_id AND output.movement_id=NEW.business_refresh_event_id
                AND event.actor_user_id=NEW.business_refresh_actor_id)
        OR EXISTS(SELECT 1 FROM production_material_settlement_events event JOIN production_material_settlement_postings posting ON posting.event_id=event.id
            JOIN production_material_demands demand ON demand.id=posting.demand_id WHERE event.id=NEW.business_refresh_event_id
                AND event.created_by=NEW.business_refresh_actor_id AND demand.execution_segment_id=NEW.execution_segment_id)
        OR EXISTS(SELECT 1 FROM production_daily_reports report JOIN production_daily_report_items item ON item.report_id=report.id
            WHERE report.id=NEW.business_refresh_event_id AND report.status IN(1,-1) AND NOT report.is_deleted
                AND report.updated_by=NEW.business_refresh_actor_id AND item.execution_segment_id=NEW.execution_segment_id AND item.is_final AND NOT item.is_deleted)
        OR (NEW.source_kind='SUBCONTRACT_ORDER_NORMAL_LOSS' AND (
            EXISTS(SELECT 1 FROM stock_value_events event JOIN subcontract_waste_items item ON item.id=event.source_item_id
                JOIN subcontract_material_issue_items issue ON issue.id=item.material_issue_item_id
                WHERE event.id=NEW.business_refresh_event_id AND issue.order_item_id=NEW.execution_segment_id
                    AND event.actor_user_id=NEW.business_refresh_actor_id AND event.source_doc_type IN (
                        'SUBCONTRACT_NORMAL_LOSS','SUBCONTRACT_EXCESS_LOSS','SUBCONTRACT_NORMAL_LOSS_REVERSE','SUBCONTRACT_EXCESS_LOSS_REVERSE'))
            OR
            EXISTS(SELECT 1 FROM subcontract_wastes waste JOIN subcontract_waste_items item ON item.waste_id=waste.id
                JOIN subcontract_material_issue_items issue ON issue.id=item.material_issue_item_id
                WHERE waste.id=NEW.business_refresh_event_id AND issue.order_item_id=NEW.execution_segment_id
                    AND waste.status IN(1,-1) AND waste.updated_by=NEW.business_refresh_actor_id)
            OR EXISTS(SELECT 1 FROM procurement_order_approval_cases approval JOIN subcontract_order_items item ON item.order_id=approval.order_id
                WHERE approval.id=NEW.business_refresh_event_id AND approval.status='APPROVED' AND approval.order_type='SUBCONTRACT'
                    AND item.id=NEW.execution_segment_id AND approval.decided_by_user_id=NEW.business_refresh_actor_id)))) THEN
        RAISE EXCEPTION 'cost refresh requires the real same-scope output, settlement, report, loss or financial approval source' USING ERRCODE='23514';
    END IF;
    RETURN NEW;
END;
$$;
CREATE FUNCTION fn_queue_subcontract_normal_cost_approval() RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
    IF NEW.order_type='SUBCONTRACT' AND NEW.status='APPROVED' AND OLD.status IS DISTINCT FROM NEW.status THEN
        UPDATE stock_value_production_cost_objects object SET business_refresh_pending=TRUE,
            business_refresh_event_id=NEW.id,business_refresh_actor_id=NEW.decided_by_user_id
        FROM subcontract_order_items item WHERE item.id=object.execution_segment_id AND item.order_id=NEW.order_id
            AND object.source_kind='SUBCONTRACT_ORDER_NORMAL_LOSS';
    END IF;
    RETURN NULL;
END;
$$;
CREATE TRIGGER trg_subcontract_normal_cost_approved AFTER UPDATE OF status ON procurement_order_approval_cases
    FOR EACH ROW EXECUTE FUNCTION fn_queue_subcontract_normal_cost_approval();
ALTER TABLE procurement_order_approval_cases ENABLE ALWAYS TRIGGER trg_subcontract_normal_cost_approved;

DO $loss_money$
DECLARE targets JSONB;
BEGIN
    SELECT jsonb_agg(jsonb_build_object('table',t,'column',c,'kind',CASE WHEN c IN ('price','amount_original','total_original') THEN 'actual' ELSE 'book' END)) INTO targets FROM (VALUES
        ('stock_document_items','price'),('stock_document_items','amount_original'),('stock_document_items','amount_local'),
        ('stock_documents','total_original'),('stock_documents','total_local'),
        ('subcontract_loss_cases','loss_book_value_local'),('subcontract_loss_cases','claim_amount_local'),('subcontract_loss_cases','suggested_claim_amount_local'),
        ('subcontract_loss_case_lines','unit_book_value_local'),('subcontract_loss_case_lines','loss_book_value_local'),('subcontract_loss_resolutions','amount_local'),
        ('supplier_claim_receivables','amount_original'),('supplier_claim_receivables','amount_local'),
        ('supplier_claim_receivables','settled_original'),('supplier_claim_receivables','settled_local'),
        ('supplier_claim_receivables','balance_original'),('supplier_claim_receivables','balance_local')) source(t,c);
    PERFORM fn_migrate_financial_amount_columns(targets);
END;
$loss_money$;
ALTER TABLE subcontract_loss_cases ALTER COLUMN loss_book_value_local DROP NOT NULL;
ALTER TABLE subcontract_loss_case_lines ALTER COLUMN loss_book_value_local DROP NOT NULL;
ALTER TABLE subcontract_loss_case_lines ALTER COLUMN unit_book_value_local DROP NOT NULL;
ALTER TABLE subcontract_loss_case_lines ADD COLUMN normal_value_node_id UUID REFERENCES stock_value_nodes(id);
ALTER TABLE subcontract_loss_case_lines ADD COLUMN excess_value_node_id UUID REFERENCES stock_value_nodes(id);
ALTER TABLE supplier_claim_receivables DROP CONSTRAINT supplier_claim_receivables_amount_identity_chk;
ALTER TABLE supplier_claim_receivables ADD CONSTRAINT supplier_claim_receivables_exact_amount_identity CHECK(
    amount_local=amount_original*exchange_rate AND balance_original=amount_original-settled_original
    AND balance_local=amount_local-settled_local) NOT VALID;
CREATE VIEW v_subcontract_loss_case_value AS
SELECT line.case_id,CASE WHEN BOOL_AND(actual.excess_value_local IS NOT NULL) THEN SUM(actual.excess_value_local) END loss_book_value_local,
    BOOL_AND(actual.excess_value_local IS NOT NULL AND (actual.complete OR actual.excess_qty=0)) complete
FROM subcontract_loss_case_lines line JOIN v_subcontract_waste_actual_value actual ON actual.waste_item_id=line.waste_item_id GROUP BY line.case_id;

CREATE FUNCTION fn_check_subcontract_loss_value_identity() RETURNS trigger LANGUAGE plpgsql AS $$
DECLARE actual RECORD;
BEGIN
    SELECT * INTO actual FROM v_subcontract_waste_actual_value WHERE waste_item_id=NEW.waste_item_id;
    IF actual.waste_item_id IS NULL OR NEW.normal_value_node_id IS DISTINCT FROM actual.normal_value_node_id
       OR NEW.excess_value_node_id IS DISTINCT FROM actual.excess_value_node_id OR NEW.order_item_id<>actual.order_item_id
       OR NEW.actual_loss_qty<>actual.actual_qty OR NEW.allowed_loss_qty<>actual.normal_qty OR NEW.excess_loss_qty<>actual.excess_qty
       OR NEW.loss_book_value_local IS DISTINCT FROM actual.excess_value_local
       OR (NEW.valuation_status='VALUED' AND (actual.normal_value_local IS NULL OR actual.excess_value_local IS NULL)) THEN
        RAISE EXCEPTION 'loss book value must reference the exact original normal and excess material intervals' USING ERRCODE='23514';
    END IF;
    RETURN NULL;
END;
$$;
CREATE CONSTRAINT TRIGGER trg_subcontract_loss_value_identity AFTER INSERT ON subcontract_loss_case_lines
    DEFERRABLE INITIALLY DEFERRED FOR EACH ROW EXECUTE FUNCTION fn_check_subcontract_loss_value_identity();
ALTER TABLE subcontract_loss_case_lines ENABLE ALWAYS TRIGGER trg_subcontract_loss_value_identity;

CREATE FUNCTION fn_guard_subcontract_loss_value_reference() RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
    IF NEW.normal_value_node_id IS DISTINCT FROM OLD.normal_value_node_id OR NEW.excess_value_node_id IS DISTINCT FROM OLD.excess_value_node_id THEN
        RAISE EXCEPTION 'original subcontract loss value references are immutable' USING ERRCODE='55000';
    END IF;
    RETURN NEW;
END;
$$;
CREATE TRIGGER trg_subcontract_loss_value_reference BEFORE UPDATE ON subcontract_loss_case_lines
    FOR EACH ROW EXECUTE FUNCTION fn_guard_subcontract_loss_value_reference();
ALTER TABLE subcontract_loss_case_lines ENABLE ALWAYS TRIGGER trg_subcontract_loss_value_reference;
