-- Preserve historical consumption projections. New receipts retain their exact issued sources.
-- A single warehouse confirmation may carry several original material generations.
ALTER TABLE procurement_iqc_stock_in_batch_items ADD COLUMN stock_sequence BIGINT GENERATED ALWAYS AS IDENTITY;
ALTER TABLE procurement_iqc_stock_in_batch_items DROP CONSTRAINT procurement_iqc_stock_in_item_batch_event_uk;
CREATE UNIQUE INDEX uq_iqc_stock_item_sequence ON procurement_iqc_stock_in_batch_items(stock_sequence);
DO $stock_predecessors$
DECLARE definition TEXT;needle TEXT:='v_event.base_qty - (v_event_confirmed - NEW.base_qty)';
BEGIN
    SELECT pg_get_functiondef('fn_validate_procurement_iqc_stock_in_item()'::regprocedure) INTO definition;
    IF position(needle IN definition)=0 THEN RAISE EXCEPTION 'V522 stock predecessor guard changed'; END IF;
    EXECUTE replace(definition,needle,'v_event.base_qty - (SELECT COALESCE(SUM(prior.base_qty),0)
        FROM procurement_iqc_stock_in_batch_items prior
        WHERE prior.pass_event_id=NEW.pass_event_id AND prior.stock_sequence<NEW.stock_sequence)');
END;
$stock_predecessors$;

CREATE TABLE subcontract_receipt_material_consumptions (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    receipt_item_id UUID NOT NULL REFERENCES subcontract_receipt_items(id),
    issue_item_id UUID NOT NULL REFERENCES subcontract_material_issue_items(id),
    qty_doc NUMERIC(18,4) NOT NULL CHECK(qty_doc>0),
    qty_base NUMERIC(18,4) NOT NULL CHECK(qty_base>0),
    consumption_basis TEXT NOT NULL CHECK(consumption_basis IN ('DIRECT_TARGET','FROZEN_BOM_ESTIMATE')),
    reversal_of UUID UNIQUE REFERENCES subcontract_receipt_material_consumptions(id),
    created_by UUID NOT NULL REFERENCES users(id),
    created_at TIMESTAMPTZ NOT NULL DEFAULT clock_timestamp()
);
CREATE UNIQUE INDEX uq_subcontract_receipt_material_consumption
    ON subcontract_receipt_material_consumptions(receipt_item_id,issue_item_id) WHERE reversal_of IS NULL;
CREATE INDEX idx_subcontract_receipt_material_consumption_issue ON subcontract_receipt_material_consumptions(issue_item_id);

CREATE FUNCTION fn_guard_subcontract_receipt_material_consumption() RETURNS trigger LANGUAGE plpgsql AS $$
DECLARE receipt subcontract_receipt_items%ROWTYPE;issue subcontract_material_issue_items%ROWTYPE;
    original subcontract_receipt_material_consumptions%ROWTYPE;direct_target BOOLEAN;
BEGIN
    IF TG_OP<>'INSERT' THEN RAISE EXCEPTION 'subcontract material consumption sources are immutable' USING ERRCODE='55000'; END IF;
    SELECT * INTO receipt FROM subcontract_receipt_items WHERE id=NEW.receipt_item_id;
    SELECT * INTO issue FROM subcontract_material_issue_items WHERE id=NEW.issue_item_id FOR UPDATE;
    IF receipt.id IS NULL OR issue.id IS NULL OR receipt.order_item_id IS DISTINCT FROM issue.order_item_id
       OR NEW.qty_base<>NEW.qty_doc*COALESCE(issue.unit_rate,1) THEN
        RAISE EXCEPTION 'subcontract consumption must use the exact order and issued material base quantity' USING ERRCODE='23514';
    END IF;
    SELECT COALESCE(EXISTS(SELECT 1 FROM subcontract_material_plan_items plan WHERE plan.id=issue.plan_item_id
        AND plan.flow_mode<>'LEGACY_BOM_COMPONENT' AND issue.goods_id=receipt.goods_id
        AND issue.color_id IS NOT DISTINCT FROM receipt.color_id
        AND issue.frozen_unit_qty*COALESCE(issue.unit_rate,1)=COALESCE(receipt.unit_rate,1)),FALSE) INTO direct_target;
    IF (NEW.consumption_basis='DIRECT_TARGET') IS DISTINCT FROM direct_target THEN
        RAISE EXCEPTION 'legacy BOM estimates cannot be asserted as confirmed direct target consumption' USING ERRCODE='23514';
    END IF;
    IF NEW.reversal_of IS NOT NULL THEN
        SELECT * INTO original FROM subcontract_receipt_material_consumptions WHERE id=NEW.reversal_of;
        IF original.id IS NULL OR original.reversal_of IS NOT NULL OR original.receipt_item_id<>NEW.receipt_item_id
           OR original.issue_item_id<>NEW.issue_item_id OR original.qty_doc<>NEW.qty_doc OR original.qty_base<>NEW.qty_base
           OR original.consumption_basis<>NEW.consumption_basis THEN
            RAISE EXCEPTION 'subcontract receipt reversal must restore the same complete original consumption slice' USING ERRCODE='23514';
        END IF;
    END IF;
    RETURN NEW;
END;
$$;
CREATE TRIGGER trg_subcontract_receipt_material_consumption BEFORE INSERT OR UPDATE OR DELETE
    ON subcontract_receipt_material_consumptions FOR EACH ROW EXECUTE FUNCTION fn_guard_subcontract_receipt_material_consumption();
ALTER TABLE subcontract_receipt_material_consumptions ENABLE ALWAYS TRIGGER trg_subcontract_receipt_material_consumption;
CREATE TRIGGER trg_audit_subcontract_receipt_material_consumption AFTER INSERT OR UPDATE OR DELETE
    ON subcontract_receipt_material_consumptions FOR EACH ROW EXECUTE FUNCTION fn_audit();
ALTER TABLE subcontract_receipt_material_consumptions ENABLE ALWAYS TRIGGER trg_audit_subcontract_receipt_material_consumption;

-- The existing UUID key is retained for compatibility; source_kind defines its actual business identity.
ALTER TABLE stock_value_production_cost_objects ADD COLUMN source_kind TEXT NOT NULL DEFAULT 'PRODUCTION_EXECUTION'
    CHECK(source_kind IN ('PRODUCTION_EXECUTION','SUBCONTRACT_RECEIPT_ITEM'));
CREATE FUNCTION fn_guard_inventory_cost_scope_source() RETURNS trigger LANGUAGE plpgsql AS $$
DECLARE target_goods UUID;target_color UUID;
BEGIN
    IF NEW.source_kind='PRODUCTION_EXECUTION' THEN
        SELECT product_goods_id,product_color_id INTO target_goods,target_color
            FROM production_execution_segments WHERE id=NEW.execution_segment_id;
    ELSE
        SELECT goods_id,color_id INTO target_goods,target_color
            FROM subcontract_receipt_items WHERE id=NEW.execution_segment_id;
    END IF;
    IF target_goods IS NULL OR NOT EXISTS(SELECT 1 FROM stock_value_pools p WHERE p.id=NEW.product_pool_id
            AND p.goods_id=target_goods AND p.color_id IS NOT DISTINCT FROM target_color) THEN
        RAISE EXCEPTION 'cost scope must identify its real typed business source and product' USING ERRCODE='23514';
    END IF;
    RETURN NEW;
END;
$$;
CREATE TRIGGER trg_inventory_cost_scope_source BEFORE INSERT ON stock_value_production_cost_objects
    FOR EACH ROW EXECUTE FUNCTION fn_guard_inventory_cost_scope_source();
ALTER TABLE stock_value_production_cost_objects ENABLE ALWAYS TRIGGER trg_inventory_cost_scope_source;

CREATE FUNCTION fn_check_subcontract_cost_scope_facts() RETURNS trigger LANGUAGE plpgsql AS $$
DECLARE object stock_value_production_cost_objects%ROWTYPE;expected_qty NUMERIC;
BEGIN
    SELECT * INTO object FROM stock_value_production_cost_objects WHERE execution_segment_id=NEW.execution_segment_id;
    IF object.source_kind<>'SUBCONTRACT_RECEIPT_ITEM' THEN RETURN NULL; END IF;
    IF TG_TABLE_NAME='stock_value_production_cost_revisions' THEN
        SELECT COALESCE(SUM(base_qty),0) INTO expected_qty FROM procurement_receipt_consideration_parts
            WHERE receipt_type='SUBCONTRACT' AND receipt_item_id=object.execution_segment_id AND billing_mode='STANDARD';
        IF NEW.target_qty_base<>expected_qty THEN
            RAISE EXCEPTION 'subcontract cost denominator must equal the original receipt material batch quantity' USING ERRCODE='23514';
        END IF;
        IF NEW.scope_complete AND (
            expected_qty<=0 OR expected_qty<>(SELECT COALESCE(SUM(c.qty_base),0) FROM subcontract_receipt_material_consumptions c
                WHERE c.receipt_item_id=object.execution_segment_id AND c.reversal_of IS NULL
                  AND NOT EXISTS(SELECT 1 FROM subcontract_receipt_material_consumptions reversed WHERE reversed.reversal_of=c.id))
            OR EXISTS(SELECT 1 FROM subcontract_receipt_material_consumptions c WHERE c.receipt_item_id=object.execution_segment_id
                AND c.reversal_of IS NULL AND c.consumption_basis<>'DIRECT_TARGET')
            OR EXISTS(SELECT 1 FROM subcontract_material_issue_items issue JOIN subcontract_receipt_items receipt ON receipt.order_item_id=issue.order_item_id
                WHERE receipt.id=object.execution_segment_id AND COALESCE(issue.wasted_qty,0)>0)) THEN
            RAISE EXCEPTION 'subcontract cost cannot be final before exact material consumption and loss classification are complete' USING ERRCODE='23514';
        END IF;
    ELSE
        IF NOT EXISTS(SELECT 1 FROM procurement_iqc_stock_in_batch_items item
            JOIN procurement_iqc_stock_consideration_parts stocked ON stocked.stock_in_item_id=item.id
            JOIN procurement_iqc_quality_consideration_parts quality ON quality.id=stocked.quality_part_id
            JOIN procurement_receipt_consideration_parts part ON part.id=quality.consideration_part_id
            LEFT JOIN procurement_iqc_funding_slices funding ON funding.id=part.funding_slice_id
            WHERE item.stock_movement_id=NEW.movement_id AND part.receipt_type='SUBCONTRACT'
              AND CASE WHEN part.billing_mode='STANDARD' THEN part.receipt_item_id ELSE funding.root_receipt_item_id END=object.execution_segment_id)
        OR EXISTS(SELECT 1 FROM procurement_iqc_stock_in_batch_items item
            JOIN procurement_iqc_stock_consideration_parts stocked ON stocked.stock_in_item_id=item.id
            JOIN procurement_iqc_quality_consideration_parts quality ON quality.id=stocked.quality_part_id
            JOIN procurement_receipt_consideration_parts part ON part.id=quality.consideration_part_id
            LEFT JOIN procurement_iqc_funding_slices funding ON funding.id=part.funding_slice_id
            WHERE item.stock_movement_id=NEW.movement_id
              AND CASE WHEN part.billing_mode='STANDARD' THEN part.receipt_item_id ELSE funding.root_receipt_item_id END IS DISTINCT FROM object.execution_segment_id) THEN
            RAISE EXCEPTION 'subcontract output must retain its exact original receipt material generation' USING ERRCODE='23514';
        END IF;
    END IF;
    RETURN NULL;
END;
$$;
CREATE CONSTRAINT TRIGGER trg_subcontract_cost_scope_output AFTER INSERT ON stock_value_production_cost_outputs
    DEFERRABLE INITIALLY DEFERRED FOR EACH ROW EXECUTE FUNCTION fn_check_subcontract_cost_scope_facts();
CREATE CONSTRAINT TRIGGER trg_subcontract_cost_scope_revision AFTER INSERT ON stock_value_production_cost_revisions
    DEFERRABLE INITIALLY DEFERRED FOR EACH ROW EXECUTE FUNCTION fn_check_subcontract_cost_scope_facts();
ALTER TABLE stock_value_production_cost_outputs ENABLE ALWAYS TRIGGER trg_subcontract_cost_scope_output;
ALTER TABLE stock_value_production_cost_revisions ENABLE ALWAYS TRIGGER trg_subcontract_cost_scope_revision;

CREATE OR REPLACE FUNCTION fn_guard_cost_business_refresh_source() RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
    IF NEW.business_refresh_event_id IS NULL AND NEW.business_refresh_actor_id IS NULL AND NOT NEW.business_refresh_pending THEN RETURN NEW; END IF;
    IF NEW.business_refresh_event_id IS NULL OR NEW.business_refresh_actor_id IS NULL OR NOT (
        EXISTS(SELECT 1 FROM stock_value_production_cost_outputs output JOIN stock_value_events event ON event.movement_id=output.movement_id
            WHERE output.execution_segment_id=NEW.execution_segment_id AND output.movement_id=NEW.business_refresh_event_id
                AND event.actor_user_id=NEW.business_refresh_actor_id)
        OR EXISTS(SELECT 1 FROM production_material_settlement_events event JOIN production_material_settlement_postings posting ON posting.event_id=event.id
            JOIN production_material_demands demand ON demand.id=posting.demand_id
            WHERE event.id=NEW.business_refresh_event_id AND event.created_by=NEW.business_refresh_actor_id AND demand.execution_segment_id=NEW.execution_segment_id)
        OR (NEW.source_kind='SUBCONTRACT_RECEIPT_ITEM' AND EXISTS(
            SELECT 1 FROM stock_value_events event JOIN subcontract_waste_items waste ON waste.id=event.source_item_id
            JOIN subcontract_material_issue_items issue ON issue.id=waste.material_issue_item_id
            JOIN subcontract_receipt_items receipt ON receipt.order_item_id=issue.order_item_id
            WHERE event.id=NEW.business_refresh_event_id AND event.actor_user_id=NEW.business_refresh_actor_id
                AND receipt.id=NEW.execution_segment_id AND event.source_doc_id=waste.waste_id
                AND event.source_doc_type IN ('SUBCONTRACT_WASTE_VALUE','SUBCONTRACT_WASTE_VALUE_REVERSE')))) THEN
        RAISE EXCEPTION 'cost refresh requires the real same-scope output, settlement or subcontract material classification event' USING ERRCODE='23514';
    END IF;
    RETURN NEW;
END;
$$;

DO $reset$
DECLARE definition TEXT;anchor TEXT:='(''stock_value_postings'', ''CLEAR'')';
BEGIN
    SELECT pg_get_functiondef('business_data_reset()'::regprocedure) INTO definition;
    IF length(definition)-length(replace(definition,anchor,''))<>length(anchor) THEN RAISE EXCEPTION 'V522 reset anchor mismatch'; END IF;
    EXECUTE replace(definition,anchor,anchor||', (''subcontract_receipt_material_consumptions'', ''CLEAR'')');
END;
$reset$;
