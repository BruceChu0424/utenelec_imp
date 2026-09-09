-- Qualified task-owned stock follows its actual physical warehouse. This is
-- not a public-stock or quarantine bypass: marked formal reservations need a
-- complete, same-physical-warehouse entitlement bridge at transaction end.
-- Direct MAKE_COMPONENT plans have no retired PREPLAN_MAKE_TASK action. Keep
-- their genuine child-plan anchor alongside (never fabricated as) old actions.
ALTER TABLE preplan_analysis_stock_exact_pegs
    ALTER COLUMN supply_action_allocation_id DROP NOT NULL,
    ADD COLUMN make_source_analysis_item_id UUID
        REFERENCES production_material_analysis_items(id) ON DELETE RESTRICT,
    ADD CONSTRAINT preplan_exact_peg_origin_anchor_chk CHECK (
        (supply_action_allocation_id IS NOT NULL) <> (make_source_analysis_item_id IS NOT NULL)),
    ADD CONSTRAINT preplan_exact_peg_direct_make_shape_chk CHECK (
        make_source_analysis_item_id IS NULL OR (
            source_receipt_type='MAKE' AND source_disposition_event_id IS NULL
            AND source_stock_document_id IS NOT NULL AND source_stock_document_item_id IS NOT NULL
            AND source_receipt_id=source_stock_document_id AND beneficiary_reason='ORIGIN_MAKE'));
CREATE UNIQUE INDEX uq_preplan_exact_direct_make_item
    ON preplan_analysis_stock_exact_pegs(make_source_analysis_item_id,source_stock_document_item_id)
    WHERE make_source_analysis_item_id IS NOT NULL;

ALTER TABLE stock_reservations
    ADD COLUMN requires_qualified_origin BOOLEAN NOT NULL DEFAULT FALSE,
    ADD CONSTRAINT stock_reservations_qualified_origin_shape CHECK (
        NOT requires_qualified_origin OR (
            owner_type='PRODUCTION_MATERIAL_DEMAND' AND purpose='PRODUCTION_MATERIAL'
            AND supply_type='STOCK_BALANCE' AND supply_id IS NOT NULL AND demand_id IS NOT NULL
            AND warehouse_id IS NOT NULL AND owner_id IS NOT NULL AND owner_id=demand_id
            AND (NOT is_deleted OR qty=released_qty)));

CREATE FUNCTION fn_preplan_reservation_has_qualified_origin(p_reservation UUID)
RETURNS BOOLEAN LANGUAGE sql STABLE STRICT AS $$
    SELECT EXISTS (
        SELECT 1
        FROM stock_reservations reservation
        JOIN preplan_analysis_stock_exact_pegs exact
          ON exact.stock_reservation_id=reservation.id
        JOIN preplan_stock_entitlement_events origin_event
          ON origin_event.stock_reservation_id=reservation.id
         AND origin_event.source_exact_peg_id=exact.id
         AND origin_event.event_type IN ('ORIGIN_IQC','ORIGIN_MAKE')
         AND origin_event.source_entitlement_event_id IS NULL
         AND origin_event.counter_event_id IS NULL
         AND origin_event.beneficiary_analysis_id=exact.origin_analysis_id
         AND origin_event.beneficiary_analysis_material_id=exact.origin_analysis_material_id
         AND origin_event.source_receipt_type=exact.source_receipt_type
         AND origin_event.source_receipt_id=exact.source_receipt_id
         AND origin_event.source_disposition_event_id IS NOT DISTINCT FROM exact.source_disposition_event_id
         AND origin_event.source_stock_document_id IS NOT DISTINCT FROM exact.source_stock_document_id
         AND origin_event.source_stock_document_item_id IS NOT DISTINCT FROM exact.source_stock_document_item_id
         AND origin_event.qty>0 AND origin_event.qty<=exact.qty
        WHERE reservation.id=p_reservation
          AND reservation.owner_type='PREPLAN_ANALYSIS'
          AND reservation.purpose='PREPLAN_MATERIAL'
          AND reservation.owner_id=exact.origin_analysis_id
          AND (
            (origin_event.event_type='ORIGIN_IQC'
             AND exact.source_receipt_type IN ('PURCHASE','SUBCONTRACT')
             AND reservation.source_doc_type=exact.source_receipt_type||'_RECEIPT'
             AND reservation.source_doc_id=exact.source_receipt_id
             AND EXISTS (
                 SELECT 1 FROM procurement_iqc_stock_in_batch_items stock_item
                 JOIN procurement_iqc_stock_in_batches batch ON batch.id=stock_item.batch_id
                 JOIN procurement_inspection_events pass_event ON pass_event.id=stock_item.pass_event_id
                 JOIN procurement_inspection_items inspection ON inspection.id=stock_item.inspection_item_id
                 JOIN stock_movements movement ON movement.id=stock_item.stock_movement_id
                 WHERE stock_item.id=origin_event.event_group_id
                   AND stock_item.pass_event_id=exact.source_disposition_event_id
                   AND pass_event.action='PASS' AND pass_event.inspection_item_id=inspection.id
                   AND inspection.receipt_type=exact.source_receipt_type
                   AND inspection.receipt_id=exact.source_receipt_id
                   AND batch.receipt_type=inspection.receipt_type AND batch.receipt_id=inspection.receipt_id
                   AND inspection.goods_id=reservation.goods_id
                   AND inspection.color_id IS NOT DISTINCT FROM reservation.color_id
                   AND stock_item.goods_id=reservation.goods_id
                   AND stock_item.color_id IS NOT DISTINCT FROM reservation.color_id
                   AND stock_item.warehouse_id=reservation.warehouse_id
                   AND inspection.warehouse_id=stock_item.warehouse_id
                   AND stock_item.base_qty>=exact.qty AND pass_event.base_qty>=stock_item.base_qty
                   AND (SELECT COALESCE(SUM(allocated.qty),0)
                        FROM preplan_stock_entitlement_events allocated
                        WHERE allocated.event_type='ORIGIN_IQC'
                          AND allocated.event_group_id=stock_item.id)<=stock_item.base_qty
                   AND movement.source_doc_type=reservation.source_doc_type
                   AND movement.source_doc_id=exact.source_receipt_id
                   AND movement.source_item_id=stock_item.id
                   AND movement.warehouse_id=stock_item.warehouse_id
                   AND movement.goods_id=stock_item.goods_id
                   AND movement.color_id IS NOT DISTINCT FROM stock_item.color_id
                   AND movement.direction=1 AND movement.qty=stock_item.base_qty
                   AND movement.movement_type=CASE exact.source_receipt_type WHEN 'PURCHASE' THEN 1 ELSE 17 END))
            OR
            (origin_event.event_type='ORIGIN_MAKE' AND exact.source_receipt_type='MAKE'
             AND reservation.source_doc_type='PRODUCTION_INBOUND'
             AND reservation.source_doc_id=exact.source_stock_document_id
             AND EXISTS (
                 SELECT 1 FROM stock_document_items stock_item
                 JOIN stock_documents document ON document.id=stock_item.doc_id
                 JOIN production_execution_segments segment ON segment.id=stock_item.execution_segment_id
                 JOIN production_plans plan ON plan.id=segment.plan_id
                 JOIN production_material_analysis_items make_source ON make_source.id=plan.material_analysis_item_id
                 JOIN stock_movements movement ON movement.source_doc_type='STOCK_DOC'
                   AND movement.source_doc_id=document.id AND movement.source_item_id=stock_item.id
                 JOIN production_fqc_release_commands command ON command.stock_document_item_id=stock_item.id
                 JOIN production_fqc_inspections inspection ON inspection.id=command.inspection_id
                 WHERE stock_item.id=exact.source_stock_document_item_id
                   AND stock_item.id=origin_event.event_group_id
                   AND document.id=exact.source_stock_document_id
                   AND document.doc_type='FINISHED_IN' AND stock_item.bill_type='FINISHED_IN'
                   AND make_source.source_type='MAKE_COMPONENT'
                   AND make_source.analysis_id=exact.origin_analysis_id
                   AND make_source.parent_analysis_material_id=exact.origin_analysis_material_id
                   AND (exact.make_source_analysis_item_id IS NULL OR exact.make_source_analysis_item_id=make_source.id)
                   AND stock_item.goods_id=reservation.goods_id
                   AND stock_item.color_id IS NOT DISTINCT FROM reservation.color_id
                   AND document.warehouse_id=reservation.warehouse_id
                   AND stock_item.base_qty>=exact.qty
                   AND movement.warehouse_id=reservation.warehouse_id
                   AND movement.goods_id=reservation.goods_id
                   AND movement.color_id IS NOT DISTINCT FROM reservation.color_id
                   AND movement.direction=1 AND movement.movement_type=13
                   AND movement.qty=stock_item.base_qty
                   AND command.source_report_item_id=stock_item.source_daily_report_item_id
                   AND inspection.source_report_id=document.source_daily_report_id
                   AND inspection.source_report_item_id=stock_item.source_daily_report_item_id
                   AND inspection.goods_id=stock_item.goods_id
                   AND inspection.color_id IS NOT DISTINCT FROM stock_item.color_id
                   AND inspection.unit_id=stock_item.unit_id
                   AND command.requested_qty*stock_item.unit_rate>=stock_item.base_qty
                   AND (SELECT COALESCE(SUM(allocation.qty),0)
                        FROM production_fqc_release_allocations allocation
                        JOIN production_fqc_decision_events decision ON decision.id=allocation.decision_event_id
                        WHERE allocation.release_command_id=command.id
                          AND allocation.inspection_id=inspection.id AND decision.inspection_id=inspection.id
                          AND decision.decision IN ('PASS','PARTIAL') AND decision.pass_qty>0
                          AND allocation.qty<=decision.pass_qty)=command.requested_qty))
          )
    )
$$;
COMMENT ON FUNCTION fn_preplan_reservation_has_qualified_origin(UUID) IS
    'Immutable quality/actual-warehouse provenance only; effective entitlement quantity and physical availability remain separate mandatory checks. Legacy PASS-as-stock aliases are not this proof.';

CREATE FUNCTION fn_assert_preplan_direct_make_exact_peg(p_exact UUID)
RETURNS VOID LANGUAGE plpgsql AS $$
DECLARE exact preplan_analysis_stock_exact_pegs%ROWTYPE; child production_material_analysis_items%ROWTYPE;
        material production_material_analysis_materials%ROWTYPE; attributed NUMERIC; received NUMERIC;
BEGIN
    SELECT * INTO exact FROM preplan_analysis_stock_exact_pegs WHERE id=p_exact;
    SELECT * INTO child FROM production_material_analysis_items
    WHERE id=exact.make_source_analysis_item_id FOR UPDATE;
    SELECT * INTO material FROM production_material_analysis_materials
    WHERE id=exact.origin_analysis_material_id FOR UPDATE;
    IF child.id IS NULL OR child.source_type IS DISTINCT FROM 'MAKE_COMPONENT' OR child.is_deleted
       OR child.analysis_id IS DISTINCT FROM exact.origin_analysis_id
       OR child.parent_analysis_material_id IS DISTINCT FROM material.id
       OR material.id IS NULL OR material.analysis_id IS DISTINCT FROM child.analysis_id
       OR material.goods_id IS DISTINCT FROM child.goods_id
       OR material.color_id IS DISTINCT FROM child.color_id OR material.unit_id IS DISTINCT FROM child.unit_id
       OR exact.beneficiary_analysis_id IS DISTINCT FROM exact.origin_analysis_id
       OR exact.beneficiary_analysis_material_id IS DISTINCT FROM material.id
       OR exact.supply_action_allocation_id IS NOT NULL
       OR NOT EXISTS (
            SELECT 1 FROM stock_reservations reservation
            JOIN stock_document_items item ON item.id=exact.source_stock_document_item_id
            JOIN stock_documents document ON document.id=item.doc_id
            JOIN production_execution_segments segment ON segment.id=item.execution_segment_id
            JOIN production_plan_items plan_item ON plan_item.id=segment.source_plan_item_id
            JOIN production_plans plan ON plan.id=plan_item.plan_id
            WHERE reservation.id=exact.stock_reservation_id AND NOT reservation.is_deleted
              AND reservation.owner_type='PREPLAN_ANALYSIS' AND reservation.owner_id=child.analysis_id
              AND reservation.purpose='PREPLAN_MATERIAL' AND reservation.qty=exact.qty
              AND reservation.consumed_qty=0 AND reservation.supply_type='PRODUCTION_PLAN_ITEM'
              AND reservation.supply_id=plan_item.id AND reservation.source_doc_type='PRODUCTION_INBOUND'
              AND reservation.source_doc_id=document.id AND reservation.warehouse_id=document.warehouse_id
              AND reservation.goods_id=material.goods_id AND reservation.color_id IS NOT DISTINCT FROM material.color_id
              AND document.id=exact.source_stock_document_id AND document.doc_type='FINISHED_IN'
              AND document.status=1 AND NOT document.is_deleted AND item.bill_type='FINISHED_IN' AND NOT item.is_deleted
              AND item.goods_id=material.goods_id AND item.color_id IS NOT DISTINCT FROM material.color_id
              AND item.unit_id=material.unit_id AND item.base_qty>=exact.qty
              AND plan.id=segment.plan_id AND plan.material_analysis_id=child.analysis_id
              AND plan.material_analysis_item_id=child.id AND NOT plan.is_deleted
              AND fn_preplan_reservation_has_qualified_origin(reservation.id)) THEN
        RAISE EXCEPTION 'direct MAKE exact origin requires its completed MAKE_COMPONENT plan and qualified finished-in item'
            USING ERRCODE='23514',CONSTRAINT='preplan_direct_make_exact_origin';
    END IF;
    SELECT base_qty INTO received FROM stock_document_items
    WHERE id=exact.source_stock_document_item_id FOR UPDATE;
    SELECT COALESCE(SUM(qty),0) INTO attributed FROM preplan_analysis_stock_exact_pegs
    WHERE source_stock_document_item_id=exact.source_stock_document_item_id;
    IF attributed>received THEN
        RAISE EXCEPTION 'MAKE exact origins exceed their actual finished-in item quantity'
            USING ERRCODE='23514',CONSTRAINT='preplan_direct_make_item_capacity';
    END IF;
    SELECT COALESCE(SUM(peg.qty),0) INTO attributed
    FROM preplan_analysis_stock_exact_pegs peg
    JOIN stock_document_items item ON item.id=peg.source_stock_document_item_id
    JOIN stock_documents document ON document.id=item.doc_id AND document.status=1 AND NOT document.is_deleted
    JOIN production_execution_segments segment ON segment.id=item.execution_segment_id
    JOIN production_plans plan ON plan.id=segment.plan_id
    WHERE plan.material_analysis_item_id=child.id;
    IF attributed>LEAST(child.requested_qty,material.required_qty) THEN
        RAISE EXCEPTION 'direct MAKE exact origins exceed their child and parent material quantity'
            USING ERRCODE='23514',CONSTRAINT='preplan_direct_make_child_capacity';
    END IF;
END $$;

-- Preserve every legacy IQC/MAKE allocation check. Only the explicit alternative
-- anchor enters the new validator, after FINISHED_IN reaches its committed state.
DO $direct_make$
DECLARE definition TEXT; body_start INTEGER;
BEGIN
    SELECT pg_get_functiondef('fn_check_preplan_analysis_stock_exact_peg()'::regprocedure) INTO definition;
    body_start:=strpos(definition,E'BEGIN\n');
    IF body_start=0 THEN RAISE EXCEPTION 'V535 exact-origin guard source mismatch'; END IF;
    definition:=overlay(definition placing E'BEGIN\n    IF NEW.make_source_analysis_item_id IS NOT NULL THEN\n        PERFORM fn_assert_preplan_direct_make_exact_peg(NEW.id);\n        RETURN NEW;\n    END IF;\n' from body_start for 6);
    EXECUTE definition;
END $direct_make$;

CREATE FUNCTION fn_guard_preplan_direct_make_source_identity()
RETURNS TRIGGER LANGUAGE plpgsql AS $$
BEGIN
    IF ROW(NEW.analysis_id,NEW.source_type,NEW.parent_analysis_material_id,NEW.goods_id,NEW.color_id,NEW.unit_id)
       IS DISTINCT FROM ROW(OLD.analysis_id,OLD.source_type,OLD.parent_analysis_material_id,OLD.goods_id,OLD.color_id,OLD.unit_id)
       AND EXISTS(SELECT 1 FROM preplan_analysis_stock_exact_pegs WHERE make_source_analysis_item_id=OLD.id) THEN
        RAISE EXCEPTION 'direct MAKE source child identity is immutable after exact finished-in attribution'
            USING ERRCODE='23514',CONSTRAINT='preplan_direct_make_source_identity';
    END IF;
    RETURN NEW;
END $$;
CREATE TRIGGER trg_guard_preplan_direct_make_source_identity
    BEFORE UPDATE ON production_material_analysis_items FOR EACH ROW
    EXECUTE FUNCTION fn_guard_preplan_direct_make_source_identity();
COMMENT ON COLUMN preplan_analysis_stock_exact_pegs.make_source_analysis_item_id IS
    'Direct MAKE_COMPONENT child plan source, mutually exclusive with old action allocation. SUBCONTRACT_MAKE is preparation for a later subcontract stage and cannot satisfy this origin.';

-- A PASS may be stocked in several physical batches. Serialize allocations on
-- their immutable real stock-in item, so concurrent origins cannot each spend
-- the full PASS quantity against the same smaller physical batch.
CREATE FUNCTION fn_check_qualified_iqc_origin_capacity()
RETURNS TRIGGER LANGUAGE plpgsql AS $$
DECLARE received NUMERIC; attributed NUMERIC;
BEGIN
    SELECT base_qty INTO received FROM procurement_iqc_stock_in_batch_items
    WHERE id=NEW.event_group_id FOR UPDATE;
    IF NOT FOUND THEN RETURN NULL; END IF; -- Historical PASS-as-group shape is not qualified proof.
    SELECT COALESCE(SUM(qty),0) INTO attributed FROM preplan_stock_entitlement_events
    WHERE event_type='ORIGIN_IQC' AND event_group_id=NEW.event_group_id;
    IF attributed>received THEN
        RAISE EXCEPTION 'qualified origins exceed their actual IQC stock-in batch quantity'
            USING ERRCODE='23514',CONSTRAINT='qualified_origin_iqc_capacity';
    END IF;
    RETURN NULL;
END $$;
CREATE CONSTRAINT TRIGGER trg_qualified_iqc_origin_capacity
    AFTER INSERT ON preplan_stock_entitlement_events
    DEFERRABLE INITIALLY DEFERRED FOR EACH ROW WHEN (NEW.event_type='ORIGIN_IQC')
    EXECUTE FUNCTION fn_check_qualified_iqc_origin_capacity();

CREATE OR REPLACE VIEW v_preplan_exact_peg_warehouse_mismatches AS
SELECT exact.id AS exact_peg_id,exact.stock_reservation_id,
       exact.origin_analysis_id,exact.beneficiary_analysis_id,
       action.id AS source_action_id,
       reservation.warehouse_id AS reservation_warehouse_id,
       action.warehouse_id AS action_warehouse_id,
       origin_analysis.warehouse_id AS origin_analysis_warehouse_id,
       beneficiary_analysis.warehouse_id AS beneficiary_analysis_warehouse_id
FROM preplan_analysis_stock_exact_pegs exact
JOIN stock_reservations reservation ON reservation.id=exact.stock_reservation_id
LEFT JOIN preplan_supply_action_allocations allocation ON allocation.id=exact.supply_action_allocation_id
LEFT JOIN preplan_supply_actions action ON action.id=allocation.action_id
JOIN production_material_analyses origin_analysis ON origin_analysis.id=exact.origin_analysis_id
JOIN production_material_analyses beneficiary_analysis ON beneficiary_analysis.id=exact.beneficiary_analysis_id
WHERE (NOT fn_warehouse_same_main(reservation.warehouse_id,action.warehouse_id)
    OR NOT fn_warehouse_same_main(reservation.warehouse_id,origin_analysis.warehouse_id)
    OR NOT fn_warehouse_same_main(reservation.warehouse_id,beneficiary_analysis.warehouse_id))
  AND NOT fn_preplan_reservation_has_qualified_origin(reservation.id);

-- The exact row precedes its immutable ORIGIN event in the same transaction.
DROP TRIGGER trg_check_preplan_exact_peg_warehouse_v474 ON preplan_analysis_stock_exact_pegs;
CREATE CONSTRAINT TRIGGER trg_check_preplan_exact_peg_warehouse_v474
    AFTER INSERT ON preplan_analysis_stock_exact_pegs
    DEFERRABLE INITIALLY DEFERRED FOR EACH ROW
    EXECUTE FUNCTION fn_check_preplan_exact_peg_warehouse_v474();

CREATE FUNCTION fn_guard_qualified_origin_reservation_identity()
RETURNS TRIGGER LANGUAGE plpgsql AS $$
DECLARE positive_change BOOLEAN;
BEGIN
    IF TG_OP='UPDATE' AND NEW.requires_qualified_origin IS DISTINCT FROM OLD.requires_qualified_origin THEN
        RAISE EXCEPTION 'qualified-origin requirement is immutable after reservation creation'
            USING ERRCODE='23514',CONSTRAINT='qualified_origin_reservation_identity';
    END IF;
    IF TG_OP='UPDATE'
       AND ROW(NEW.owner_type,NEW.owner_id,NEW.purpose,NEW.supply_type,NEW.supply_id,
               NEW.source_doc_type,NEW.source_doc_id,NEW.goods_id,NEW.color_id,NEW.warehouse_id,NEW.qty)
           IS DISTINCT FROM
           ROW(OLD.owner_type,OLD.owner_id,OLD.purpose,OLD.supply_type,OLD.supply_id,
               OLD.source_doc_type,OLD.source_doc_id,OLD.goods_id,OLD.color_id,OLD.warehouse_id,OLD.qty)
       AND EXISTS(SELECT 1 FROM preplan_analysis_stock_exact_pegs WHERE stock_reservation_id=OLD.id) THEN
        RAISE EXCEPTION 'exact source reservation identity and original quantity are immutable'
            USING ERRCODE='23514',CONSTRAINT='qualified_origin_source_identity';
    END IF;
    IF NEW.owner_type IS DISTINCT FROM 'PRODUCTION_MATERIAL_DEMAND' THEN RETURN NEW; END IF;
    positive_change:=TG_OP='INSERT';
    IF TG_OP='UPDATE' THEN
        positive_change:=NEW.qty-NEW.released_qty>OLD.qty-OLD.released_qty OR NEW.consumed_qty>OLD.consumed_qty;
    END IF;
    IF positive_change AND NOT NEW.requires_qualified_origin
       AND EXISTS(SELECT 1 FROM warehouses WHERE id=NEW.warehouse_id AND is_defective=TRUE) THEN
        RAISE EXCEPTION 'defective-labelled warehouse allocation requires qualified task origin'
            USING ERRCODE='23514',CONSTRAINT='qualified_origin_warehouse_required';
    END IF;
    RETURN NEW;
END $$;
CREATE TRIGGER trg_guard_qualified_origin_reservation_identity
    BEFORE INSERT OR UPDATE ON stock_reservations FOR EACH ROW
    EXECUTE FUNCTION fn_guard_qualified_origin_reservation_identity();

-- Retain V154's complete demand and physical-stock conservation guard. Existing
-- historical releases/reversals may reduce commitments without gaining access.
DO $patch$
DECLARE definition TEXT; patched TEXT;
BEGIN
    SELECT pg_get_functiondef('fn_guard_production_stock_allocation()'::regprocedure) INTO definition;
    patched:=replace(definition,
        'NOT fn_warehouse_same_main(v_demand.warehouse_id,NEW.warehouse_id)',
        '(NOT fn_warehouse_same_main(v_demand.warehouse_id,NEW.warehouse_id) AND NOT NEW.requires_qualified_origin AND NOT (TG_OP = ''UPDATE'' AND NEW.qty-NEW.released_qty <= OLD.qty-OLD.released_qty AND NEW.consumed_qty <= OLD.consumed_qty))');
    IF patched=definition THEN RAISE EXCEPTION 'V535 production allocation guard source mismatch'; END IF;
    EXECUTE patched;
    SELECT pg_get_functiondef('fn_check_preplan_stock_entitlement_event()'::regprocedure) INTO definition;
    patched:=replace(definition,
        'NOT fn_warehouse_same_main(demand.warehouse_id,reservation.warehouse_id)',
        '(NOT fn_warehouse_same_main(demand.warehouse_id,reservation.warehouse_id) AND NOT target_reservation.requires_qualified_origin)');
    IF patched=definition THEN RAISE EXCEPTION 'V535 formalization guard source mismatch'; END IF;
    EXECUTE patched;
END $patch$;

CREATE FUNCTION fn_assert_qualified_origin_formal_reservation(p_target UUID)
RETURNS VOID LANGUAGE plpgsql AS $$
DECLARE target stock_reservations%ROWTYPE; covered NUMERIC; invalid_bridges INTEGER;
BEGIN
    SELECT * INTO target FROM stock_reservations WHERE id=p_target;
    IF NOT FOUND OR NOT target.requires_qualified_origin THEN RETURN; END IF;
    WITH bridge AS (
        SELECT formalize.*,formalize.qty-COALESCE((
            SELECT SUM(restored.qty) FROM preplan_stock_entitlement_events restored
            WHERE restored.event_type='RESTORE' AND restored.counter_event_id=formalize.id),0) AS net_qty
        FROM preplan_stock_entitlement_events formalize
        WHERE formalize.event_type='FORMALIZE' AND formalize.target_stock_reservation_id=p_target
    )
    SELECT COALESCE(SUM(bridge.net_qty),0),COUNT(*) FILTER(WHERE bridge.net_qty<0 OR bridge.net_qty>0 AND (
        source.id IS NULL OR source.owner_type<>'PREPLAN_ANALYSIS'
        OR source.warehouse_id IS DISTINCT FROM target.warehouse_id
        OR source.goods_id IS DISTINCT FROM target.goods_id
        OR source.color_id IS DISTINCT FROM target.color_id
        OR NOT fn_preplan_reservation_has_qualified_origin(source.id)
        OR positive.id IS NULL OR positive.stock_reservation_id IS DISTINCT FROM source.id
        OR positive.beneficiary_analysis_id IS DISTINCT FROM bridge.beneficiary_analysis_id
        OR positive.beneficiary_analysis_material_id IS DISTINCT FROM bridge.beneficiary_analysis_material_id
        OR demand.id IS NULL OR bridge.target_demand_id IS DISTINCT FROM target.demand_id
        OR bridge.target_package_id IS DISTINCT FROM demand.package_id
        OR demand.goods_id IS DISTINCT FROM target.goods_id OR demand.color_id IS DISTINCT FROM target.color_id
        OR plan.id IS NULL OR plan.material_analysis_id IS DISTINCT FROM bridge.beneficiary_analysis_id
        OR material.id IS NULL OR material.analysis_id IS DISTINCT FROM bridge.beneficiary_analysis_id
        OR material.goods_id IS DISTINCT FROM target.goods_id OR material.color_id IS DISTINCT FROM target.color_id
        OR material.unit_id IS DISTINCT FROM demand.unit_id))
    INTO covered,invalid_bridges
    FROM bridge
    LEFT JOIN stock_reservations source ON source.id=bridge.stock_reservation_id
    LEFT JOIN preplan_stock_entitlement_events positive ON positive.id=bridge.source_entitlement_event_id
    LEFT JOIN production_material_demands demand ON demand.id=target.demand_id
    LEFT JOIN production_plans plan ON plan.id=demand.plan_id
    LEFT JOIN production_material_analysis_materials material ON material.id=bridge.beneficiary_analysis_material_id;
    IF invalid_bridges<>0 OR covered IS DISTINCT FROM target.qty-target.released_qty THEN
        RAISE EXCEPTION 'qualified target reservation requires complete same-warehouse formal provenance'
            USING ERRCODE='23514',CONSTRAINT='qualified_origin_formal_coverage';
    END IF;
END $$;

CREATE FUNCTION fn_check_qualified_origin_formal_coverage()
RETURNS TRIGGER LANGUAGE plpgsql AS $$
DECLARE target_id UUID;
BEGIN
    IF TG_TABLE_NAME='stock_reservations' THEN target_id:=NEW.id;
    ELSIF NEW.event_type='FORMALIZE' THEN target_id:=NEW.target_stock_reservation_id;
    ELSIF NEW.event_type='RESTORE' THEN
        SELECT target_stock_reservation_id INTO target_id FROM preplan_stock_entitlement_events
        WHERE id=NEW.counter_event_id AND event_type='FORMALIZE';
    END IF;
    IF target_id IS NOT NULL THEN PERFORM fn_assert_qualified_origin_formal_reservation(target_id); END IF;
    RETURN NULL;
END $$;
CREATE CONSTRAINT TRIGGER trg_qualified_origin_target_coverage
    AFTER INSERT OR UPDATE ON stock_reservations
    DEFERRABLE INITIALLY DEFERRED FOR EACH ROW WHEN (NEW.requires_qualified_origin)
    EXECUTE FUNCTION fn_check_qualified_origin_formal_coverage();
CREATE CONSTRAINT TRIGGER trg_qualified_origin_event_coverage
    AFTER INSERT ON preplan_stock_entitlement_events
    DEFERRABLE INITIALLY DEFERRED FOR EACH ROW WHEN (NEW.event_type IN ('FORMALIZE','RESTORE'))
    EXECUTE FUNCTION fn_check_qualified_origin_formal_coverage();

COMMENT ON COLUMN stock_reservations.requires_qualified_origin IS
    'Special actual warehouse allocation. Immutable marker; qty-released (including consumed) must be fully covered by qualified FORMALIZE minus RESTORE facts. Never certifies public stock.';
COMMENT ON VIEW v_preplan_exact_peg_warehouse_mismatches IS
    'Cross-plan warehouse exceptions lacking immutable qualified physical-source proof; valid historical reversals retain their original quality proof.';

-- SUBCONTRACT_MAKE is an intermediate, exclusively held product. Its physical
-- warehouse may differ from the planning warehouse, but it never becomes an
-- ORIGIN_MAKE final component merely because its internal assembly passed FQC.
DO $sc_order_holder$
DECLARE constraint_name TEXT; definition TEXT; extra TEXT;
BEGIN
    FOREACH constraint_name IN ARRAY ARRAY['stock_reservations_owner_type_chk','stock_reservations_purpose_chk','stock_reservations_owner_shape_chk'] LOOP
        SELECT pg_get_expr(conbin,conrelid) INTO definition FROM pg_constraint
        WHERE conrelid='stock_reservations'::regclass AND conname=constraint_name;
        IF definition IS NULL THEN RAISE EXCEPTION 'V535 reservation owner contract missing: %',constraint_name; END IF;
        extra:=CASE constraint_name
            WHEN 'stock_reservations_owner_type_chk' THEN 'owner_type=''SUBCONTRACT_ORDER_PREPARATION'''
            WHEN 'stock_reservations_purpose_chk' THEN 'purpose=''SUBCONTRACT_ORDER_PREPARATION'''
            ELSE 'owner_type=''SUBCONTRACT_ORDER_PREPARATION'' AND purpose=''SUBCONTRACT_ORDER_PREPARATION''
                AND owner_id IS NOT NULL AND order_item_id IS NULL AND demand_id IS NULL AND warehouse_id IS NOT NULL
                AND consumed_qty=0
                AND (status=0 OR released_qty=qty) AND (NOT is_deleted OR released_qty=qty)
                AND supply_type=''PRODUCTION_FINISHED_IN'' AND supply_id IS NOT NULL
                AND source_doc_type=''PRODUCTION_INBOUND'' AND source_doc_id IS NOT NULL AND idempotency_key IS NOT NULL' END;
        EXECUTE format('ALTER TABLE stock_reservations DROP CONSTRAINT %I, ADD CONSTRAINT %I CHECK ((%s) OR (%s))',
            constraint_name,constraint_name,definition,extra);
    END LOOP;
    SELECT pg_get_functiondef('fn_assert_subcontract_prepared_source_capacity(uuid)'::regprocedure) INTO definition;
    extra:=replace(definition,'''SUBCONTRACT_PREPARE_TASK'',''SUBCONTRACT_OUTBOUND''',
        '''SUBCONTRACT_PREPARE_TASK'',''SUBCONTRACT_OUTBOUND'',''SUBCONTRACT_ORDER_PREPARATION''');
    IF extra=definition THEN RAISE EXCEPTION 'V535 direct order holder cannot extend V496 capacity'; END IF;
    EXECUTE extra;
END $sc_order_holder$;
CREATE INDEX idx_subcontract_order_preparation_reservation
    ON stock_reservations(owner_id,warehouse_id,supply_id)
    WHERE owner_type='SUBCONTRACT_ORDER_PREPARATION' AND NOT is_deleted;
DROP INDEX idx_subcontract_prepared_receipt_capacity;
CREATE INDEX idx_subcontract_prepared_receipt_capacity
    ON stock_reservations(supply_id,source_doc_id) INCLUDE(qty,released_qty)
    WHERE supply_type='PRODUCTION_FINISHED_IN' AND NOT is_deleted
      AND owner_type IN ('SUBCONTRACT_PREPARE_TASK','SUBCONTRACT_OUTBOUND','SUBCONTRACT_ORDER_PREPARATION');

CREATE FUNCTION fn_subcontract_preparation_reservation_has_qualified_origin(p_reservation UUID)
RETURNS BOOLEAN LANGUAGE sql STABLE STRICT AS $$
    SELECT EXISTS (
        SELECT 1 FROM stock_reservations reservation
        JOIN stock_document_items item ON item.id=reservation.supply_id AND item.doc_id=reservation.source_doc_id
        JOIN stock_documents document ON document.id=item.doc_id
        JOIN production_plan_items production_item ON production_item.id=item.upstream_item_id
        JOIN production_plans plan ON plan.id=production_item.plan_id
        JOIN production_material_analysis_items child ON child.id=plan.material_analysis_item_id
          AND child.analysis_id=plan.material_analysis_id
        JOIN stock_movements movement ON movement.source_doc_type='STOCK_DOC'
          AND movement.source_doc_id=document.id AND movement.source_item_id=item.id
        JOIN production_fqc_release_commands command ON command.stock_document_item_id=item.id
        JOIN production_fqc_inspections inspection ON inspection.id=command.inspection_id
        WHERE reservation.id=p_reservation AND reservation.source_doc_type='PRODUCTION_INBOUND'
          AND reservation.supply_type='PRODUCTION_FINISHED_IN'
          AND reservation.owner_type=reservation.purpose
          AND document.doc_type='FINISHED_IN' AND item.bill_type='FINISHED_IN'
          AND reservation.warehouse_id=document.warehouse_id AND movement.warehouse_id=document.warehouse_id
          AND reservation.goods_id=item.goods_id AND production_item.goods_id=item.goods_id AND child.goods_id=item.goods_id
          AND reservation.color_id IS NOT DISTINCT FROM item.color_id
          AND production_item.color_id IS NOT DISTINCT FROM item.color_id AND child.color_id IS NOT DISTINCT FROM item.color_id
          AND item.unit_id=production_item.unit_id AND child.unit_id=item.unit_id
          AND COALESCE(item.unit_rate,1)=1 AND COALESCE(production_item.unit_rate,1)=1
          AND reservation.qty<=item.base_qty AND movement.qty=item.base_qty
          AND movement.direction=1 AND movement.movement_type=13 AND movement.goods_id=item.goods_id
          AND movement.color_id IS NOT DISTINCT FROM item.color_id
          AND command.source_report_item_id=item.source_daily_report_item_id
          AND inspection.source_report_item_id=item.source_daily_report_item_id
          AND inspection.source_report_id=document.source_daily_report_id
          AND inspection.goods_id=item.goods_id AND inspection.color_id IS NOT DISTINCT FROM item.color_id
          AND inspection.unit_id=item.unit_id AND command.requested_qty*item.unit_rate>=item.base_qty
          AND (SELECT COALESCE(SUM(allocation.qty),0)
               FROM production_fqc_release_allocations allocation
               JOIN production_fqc_decision_events decision ON decision.id=allocation.decision_event_id
               WHERE allocation.release_command_id=command.id AND allocation.inspection_id=inspection.id
                 AND decision.inspection_id=inspection.id AND decision.decision IN ('PASS','PARTIAL')
                 AND decision.pass_qty>0 AND allocation.qty<=decision.pass_qty)=command.requested_qty
          AND (
            (reservation.owner_type='SUBCONTRACT_ORDER_PREPARATION' AND child.source_type='SUBCONTRACT_PREPARATION'
             AND (child.subcontract_order_item_id=reservation.owner_id
                  OR child.subcontract_order_item_id IS NULL AND EXISTS(
                      SELECT 1 FROM subcontract_material_plan_items original
                      WHERE original.order_item_id=reservation.owner_id AND original.preparation_analysis_item_id=child.id
                        AND child.source_ref='SC-PREP:'||original.order_item_id::text)))
            OR
            (reservation.owner_type='SUBCONTRACT_PREPARE_TASK' AND child.source_type='SUBCONTRACT_MAKE'
             AND EXISTS(SELECT 1 FROM preplan_subcontract_make_tasks task
                 WHERE task.id=reservation.owner_id AND task.analysis_id=child.analysis_id
                   AND task.preparation_item_id=child.id AND task.analysis_material_id=child.parent_analysis_material_id
                   AND task.goods_id=item.goods_id AND task.color_id IS NOT DISTINCT FROM item.color_id AND task.unit_id=item.unit_id))
            OR
            (reservation.owner_type='SUBCONTRACT_OUTBOUND'
             AND EXISTS(SELECT 1 FROM subcontract_material_plan_items target
                 WHERE target.id=reservation.owner_id AND target.preparation_analysis_id=child.analysis_id
                   AND target.preparation_analysis_item_id=child.id AND target.goods_id=item.goods_id
                   AND target.color_id IS NOT DISTINCT FROM item.color_id AND target.unit_id=item.unit_id
                   AND (
                     (target.flow_mode='PREPARED_OUTBOUND' AND child.source_type='SUBCONTRACT_MAKE'
                      AND EXISTS(SELECT 1 FROM subcontract_order_item_sources order_source
                          JOIN preplan_subcontract_make_task_batches batch ON batch.application_item_id=order_source.application_item_id
                          JOIN preplan_subcontract_make_tasks task ON task.id=batch.task_id
                          WHERE order_source.order_item_id=target.order_item_id AND order_source.alloc_qty>0
                            AND task.analysis_id=child.analysis_id AND task.preparation_item_id=child.id))
                     OR (target.flow_mode IN ('MAKE_THEN_OUTBOUND','PREPARED_OUTBOUND') AND child.source_type='SUBCONTRACT_PREPARATION'
                         AND (child.subcontract_order_item_id=target.order_item_id
                              OR child.subcontract_order_item_id IS NULL AND EXISTS(
                                  SELECT 1 FROM subcontract_material_plan_items original
                                  WHERE original.order_item_id=target.order_item_id AND original.preparation_analysis_item_id=child.id
                                    AND child.source_ref='SC-PREP:'||original.order_item_id::text)))
                   )))
          )
    )
$$;
COMMENT ON FUNCTION fn_subcontract_preparation_reservation_has_qualified_origin(UUID) IS
    'Original SC task/target ownership and actual qualified FG warehouse only. Does not certify final subcontract completion or make any quantity public.';

DO $sc_physical_source$
DECLARE definition TEXT; patched TEXT;
BEGIN
    SELECT pg_get_functiondef('fn_assert_subcontract_preparation_finished_source(uuid)'::regprocedure) INTO definition;
    patched:=replace(definition,'AND reservation.warehouse_id = plan_item.preparation_warehouse_id',
        'AND (reservation.warehouse_id = plan_item.preparation_warehouse_id OR fn_subcontract_preparation_reservation_has_qualified_origin(reservation.id))');
    IF patched=definition OR strpos(patched,'fn_assert_subcontract_prepared_source_capacity')=0 THEN
        RAISE EXCEPTION 'V535 subcontract source guard does not retain V496 capacity';
    END IF;
    EXECUTE patched;
END $sc_physical_source$;

CREATE FUNCTION fn_guard_subcontract_preparation_reservation_identity()
RETURNS TRIGGER LANGUAGE plpgsql AS $$
BEGIN
    IF TG_OP='DELETE' THEN
        IF OLD.owner_type IN ('SUBCONTRACT_PREPARE_TASK','SUBCONTRACT_OUTBOUND','SUBCONTRACT_ORDER_PREPARATION')
           AND OLD.supply_type='PRODUCTION_FINISHED_IN' THEN
            RAISE EXCEPTION 'subcontract preparation reservation history must be released, not deleted'
                USING ERRCODE='23514',CONSTRAINT='subcontract_preparation_reservation_identity';
        END IF;
        RETURN OLD;
    END IF;
    IF OLD.owner_type IN ('SUBCONTRACT_PREPARE_TASK','SUBCONTRACT_OUTBOUND','SUBCONTRACT_ORDER_PREPARATION') AND OLD.supply_type='PRODUCTION_FINISHED_IN'
       AND ROW(NEW.owner_type,NEW.owner_id,NEW.purpose,NEW.supply_type,NEW.supply_id,NEW.source_doc_type,
               NEW.source_doc_id,NEW.goods_id,NEW.color_id,NEW.warehouse_id,NEW.qty)
           IS DISTINCT FROM ROW(OLD.owner_type,OLD.owner_id,OLD.purpose,OLD.supply_type,OLD.supply_id,OLD.source_doc_type,
               OLD.source_doc_id,OLD.goods_id,OLD.color_id,OLD.warehouse_id,OLD.qty) THEN
        RAISE EXCEPTION 'subcontract preparation reservation source identity is immutable; transfer with same-source slices'
            USING ERRCODE='23514',CONSTRAINT='subcontract_preparation_reservation_identity';
    END IF;
    RETURN NEW;
END $$;
CREATE TRIGGER trg_guard_subcontract_preparation_reservation_identity
    BEFORE UPDATE OR DELETE ON stock_reservations FOR EACH ROW
    EXECUTE FUNCTION fn_guard_subcontract_preparation_reservation_identity();

ALTER FUNCTION fn_assert_subcontract_preparation_source(UUID) RENAME TO fn_assert_subcontract_preparation_source_before_v535;
CREATE FUNCTION fn_assert_subcontract_preparation_source(p_plan_item_id UUID)
RETURNS VOID LANGUAGE plpgsql AS $$
DECLARE target subcontract_material_plan_items%ROWTYPE; child production_material_analysis_items%ROWTYPE;
        covered NUMERIC; expected NUMERIC;
BEGIN
    SELECT * INTO target FROM subcontract_material_plan_items WHERE id=p_plan_item_id;
    SELECT * INTO child FROM production_material_analysis_items WHERE id=target.preparation_analysis_item_id;
    IF target.flow_mode='PREPARED_OUTBOUND' AND child.source_type='SUBCONTRACT_PREPARATION' THEN
        IF child.analysis_id IS DISTINCT FROM target.preparation_analysis_id
           OR child.goods_id IS DISTINCT FROM target.goods_id OR child.color_id IS DISTINCT FROM target.color_id
           OR child.unit_id IS DISTINCT FROM target.unit_id OR child.requested_qty<target.planned_qty
           OR (child.subcontract_order_item_id=target.order_item_id
               OR child.subcontract_order_item_id IS NULL AND child.source_ref='SC-PREP:'||target.order_item_id::text) IS NOT TRUE THEN
            RAISE EXCEPTION 'prepared outbound must retain its original direct or legacy subcontract order preparation'
                USING ERRCODE='23514',CONSTRAINT='subcontract_direct_prepared_lineage';
        END IF;
        SELECT COALESCE(SUM(qty-released_qty),0) INTO covered FROM stock_reservations
        WHERE owner_type='SUBCONTRACT_OUTBOUND' AND owner_id=target.id AND supply_type='PRODUCTION_FINISHED_IN' AND NOT is_deleted;
        expected:=CASE WHEN target.is_deleted OR target.preparation_status='CANCELLED' THEN target.issued_qty ELSE target.planned_qty END;
        IF covered IS DISTINCT FROM expected THEN
            RAISE EXCEPTION 'direct prepared outbound requires complete original finished-source coverage'
                USING ERRCODE='23514',CONSTRAINT='subcontract_direct_prepared_coverage';
        END IF;
        RETURN;
    END IF;
    PERFORM fn_assert_subcontract_preparation_source_before_v535(p_plan_item_id);
END $$;

CREATE FUNCTION fn_assert_subcontract_finished_item_custody(p_item UUID)
RETURNS VOID LANGUAGE plpgsql AS $$
DECLARE document_id UUID; expected NUMERIC; committed NUMERIC; hidden INTEGER;
BEGIN
    SELECT document.id,CASE WHEN document.status=1 AND NOT document.is_deleted AND NOT item.is_deleted THEN item.base_qty ELSE 0 END
    INTO document_id,expected
    FROM stock_document_items item JOIN stock_documents document ON document.id=item.doc_id
    JOIN production_plan_items production_item ON production_item.id=item.upstream_item_id
    JOIN production_plans plan ON plan.id=production_item.plan_id
    JOIN production_material_analysis_items child ON child.id=plan.material_analysis_item_id
    WHERE item.id=p_item AND document.doc_type='FINISHED_IN' AND item.bill_type='FINISHED_IN'
      AND (child.source_type='SUBCONTRACT_MAKE' AND EXISTS(
            SELECT 1 FROM preplan_subcontract_make_tasks task WHERE task.preparation_item_id=child.id AND task.analysis_id=child.analysis_id)
        OR child.source_type='SUBCONTRACT_PREPARATION' AND (child.subcontract_order_item_id IS NOT NULL OR EXISTS(
            SELECT 1 FROM subcontract_material_plan_items original
            WHERE original.preparation_analysis_item_id=child.id AND child.source_ref='SC-PREP:'||original.order_item_id::text)));
    IF NOT FOUND THEN RETURN; END IF;
    SELECT COALESCE(SUM(qty-released_qty) FILTER(WHERE NOT is_deleted),0),
        COUNT(*) FILTER(WHERE qty>released_qty AND (is_deleted OR status<>0 AND qty>consumed_qty+released_qty))
    INTO committed,hidden FROM stock_reservations
    WHERE supply_type='PRODUCTION_FINISHED_IN' AND supply_id=p_item AND source_doc_id=document_id
      AND owner_type IN ('SUBCONTRACT_PREPARE_TASK','SUBCONTRACT_OUTBOUND','SUBCONTRACT_ORDER_PREPARATION');
    IF committed IS DISTINCT FROM expected OR hidden<>0 THEN
        RAISE EXCEPTION 'subcontract unfinished output must remain completely held by its original preparation or outbound source'
            USING ERRCODE='23514',CONSTRAINT='subcontract_preparation_full_custody';
    END IF;
END $$;

CREATE FUNCTION fn_check_subcontract_finished_custody_activation()
RETURNS TRIGGER LANGUAGE plpgsql AS $$
DECLARE item_id UUID;
BEGIN
    -- Existing approved historical documents are not silently reclassified by
    -- metadata/cost refresh. New approvals and actual reversals must conserve custody.
    IF TG_OP='UPDATE' AND NEW.status IS NOT DISTINCT FROM OLD.status THEN RETURN NULL; END IF;
    FOR item_id IN SELECT id FROM stock_document_items WHERE doc_id=NEW.id LOOP
        PERFORM fn_assert_subcontract_finished_item_custody(item_id);
    END LOOP;
    RETURN NULL;
END $$;
CREATE CONSTRAINT TRIGGER trg_subcontract_finished_custody_activation
    AFTER INSERT OR UPDATE ON stock_documents DEFERRABLE INITIALLY DEFERRED
    FOR EACH ROW WHEN (NEW.doc_type='FINISHED_IN' AND NEW.status IN (1,-1))
    EXECUTE FUNCTION fn_check_subcontract_finished_custody_activation();

CREATE FUNCTION fn_check_subcontract_qualified_preparation_reservation()
RETURNS TRIGGER LANGUAGE plpgsql AS $$
BEGIN
    IF NEW.owner_type NOT IN ('SUBCONTRACT_PREPARE_TASK','SUBCONTRACT_OUTBOUND','SUBCONTRACT_ORDER_PREPARATION')
       OR NEW.supply_type IS DISTINCT FROM 'PRODUCTION_FINISHED_IN' THEN RETURN NULL; END IF;
    PERFORM fn_assert_subcontract_prepared_source_capacity(NEW.id);
    PERFORM fn_assert_subcontract_finished_item_custody(NEW.supply_id);
    IF NEW.owner_type='SUBCONTRACT_OUTBOUND' THEN PERFORM fn_assert_subcontract_preparation_source(NEW.owner_id); END IF;
    IF NEW.is_deleted OR NEW.qty=NEW.released_qty THEN RETURN NULL; END IF;
    IF TG_OP='UPDATE' AND NEW.qty-NEW.released_qty<=OLD.qty-OLD.released_qty
       AND NEW.consumed_qty<=OLD.consumed_qty THEN RETURN NULL; END IF;
    IF NOT fn_subcontract_preparation_reservation_has_qualified_origin(NEW.id)
       OR NOT EXISTS(SELECT 1 FROM stock_documents WHERE id=NEW.source_doc_id AND status=1 AND NOT is_deleted) THEN
        RAISE EXCEPTION 'subcontract preparation reservation requires its own qualified finished-in source in the actual warehouse'
            USING ERRCODE='23514',CONSTRAINT='subcontract_qualified_preparation_origin';
    END IF;
    RETURN NULL;
END $$;
CREATE CONSTRAINT TRIGGER trg_subcontract_qualified_preparation_origin
    AFTER INSERT OR UPDATE ON stock_reservations DEFERRABLE INITIALLY DEFERRED FOR EACH ROW
    EXECUTE FUNCTION fn_check_subcontract_qualified_preparation_reservation();

CREATE FUNCTION fn_guard_subcontract_qualified_source_identity()
RETURNS TRIGGER LANGUAGE plpgsql AS $$
DECLARE before_identity JSONB; after_identity JSONB; child_id UUID;
BEGIN
    SELECT jsonb_object_agg(key,value) INTO before_identity FROM jsonb_each(to_jsonb(OLD))
    WHERE key IN ('analysis_id','goods_id','color_id','unit_id','source_type','source_ref',
        'parent_analysis_material_id','subcontract_order_item_id','preparation_item_id','analysis_material_id','supply_action_id');
    SELECT jsonb_object_agg(key,value) INTO after_identity FROM jsonb_each(to_jsonb(NEW))
    WHERE key IN ('analysis_id','goods_id','color_id','unit_id','source_type','source_ref',
        'parent_analysis_material_id','subcontract_order_item_id','preparation_item_id','analysis_material_id','supply_action_id');
    IF before_identity IS NOT DISTINCT FROM after_identity THEN RETURN NEW; END IF;
    child_id:=CASE WHEN TG_TABLE_NAME='preplan_subcontract_make_tasks'
        THEN (to_jsonb(OLD)->>'preparation_item_id')::uuid ELSE OLD.id END;
    IF EXISTS(SELECT 1 FROM stock_reservations reservation
        JOIN stock_document_items item ON item.id=reservation.supply_id
        JOIN production_plan_items production_item ON production_item.id=item.upstream_item_id
        JOIN production_plans plan ON plan.id=production_item.plan_id
        WHERE reservation.owner_type IN ('SUBCONTRACT_PREPARE_TASK','SUBCONTRACT_OUTBOUND','SUBCONTRACT_ORDER_PREPARATION')
          AND reservation.supply_type='PRODUCTION_FINISHED_IN' AND plan.material_analysis_item_id=child_id) THEN
        RAISE EXCEPTION 'subcontract preparation task and analysis source identity are immutable after finished-in attribution'
            USING ERRCODE='23514',CONSTRAINT='subcontract_qualified_source_identity';
    END IF;
    RETURN NEW;
END $$;
CREATE TRIGGER trg_guard_subcontract_qualified_task_identity
    BEFORE UPDATE ON preplan_subcontract_make_tasks FOR EACH ROW
    EXECUTE FUNCTION fn_guard_subcontract_qualified_source_identity();
CREATE TRIGGER trg_guard_subcontract_qualified_child_identity
    BEFORE UPDATE ON production_material_analysis_items FOR EACH ROW
    EXECUTE FUNCTION fn_guard_subcontract_qualified_source_identity();
