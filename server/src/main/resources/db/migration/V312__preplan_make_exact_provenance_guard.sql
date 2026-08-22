-- V312: extend the immutable V307 exact-peg identity check to MAKE output.
-- Purchase/subcontract keep IQC PASS provenance; MAKE uses an approved
-- FINISHED_IN item and the PREPLAN_MAKE_TASK allocation chain.

CREATE OR REPLACE FUNCTION fn_check_preplan_analysis_stock_exact_peg()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
DECLARE
    reservation stock_reservations%ROWTYPE;
    allocation preplan_supply_action_allocations%ROWTYPE;
    origin_material production_material_analysis_materials%ROWTYPE;
    beneficiary_material production_material_analysis_materials%ROWTYPE;
    disposition procurement_inspection_events%ROWTYPE;
    inspection procurement_inspection_items%ROWTYPE;
    stock_document stock_documents%ROWTYPE;
    stock_item stock_document_items%ROWTYPE;
    segment production_execution_segments%ROWTYPE;
    plan_item production_plan_items%ROWTYPE;
    production_plan production_plans%ROWTYPE;
    child_item production_material_analysis_items%ROWTYPE;
    allocated_total NUMERIC(18,4);
    source_total NUMERIC(18,4);
BEGIN
    SELECT * INTO reservation
    FROM stock_reservations WHERE id = NEW.stock_reservation_id;
    SELECT * INTO allocation
    FROM preplan_supply_action_allocations
    WHERE id = NEW.supply_action_allocation_id;
    SELECT * INTO origin_material
    FROM production_material_analysis_materials
    WHERE id = NEW.origin_analysis_material_id;
    SELECT * INTO beneficiary_material
    FROM production_material_analysis_materials
    WHERE id = NEW.beneficiary_analysis_material_id;

    IF reservation.id IS NULL
       OR allocation.id IS NULL
       OR origin_material.id IS NULL
       OR beneficiary_material.id IS NULL
       OR reservation.owner_type <> 'PREPLAN_ANALYSIS'
       OR reservation.purpose <> 'PREPLAN_MATERIAL'
       OR reservation.is_deleted IS DISTINCT FROM FALSE
       OR reservation.status <> 0
       OR reservation.consumed_qty <> 0
       OR reservation.released_qty <> 0
       OR reservation.owner_id <> NEW.origin_analysis_id
       OR reservation.qty IS DISTINCT FROM NEW.qty
       OR allocation.analysis_id <> NEW.origin_analysis_id
       OR allocation.analysis_material_id <> NEW.origin_analysis_material_id
       OR origin_material.analysis_id <> NEW.origin_analysis_id
       OR beneficiary_material.analysis_id <> NEW.beneficiary_analysis_id
       OR origin_material.goods_id <> reservation.goods_id
       OR origin_material.color_id IS DISTINCT FROM reservation.color_id
       OR beneficiary_material.goods_id <> origin_material.goods_id
       OR beneficiary_material.color_id IS DISTINCT FROM origin_material.color_id
       OR beneficiary_material.unit_id <> origin_material.unit_id THEN
        RAISE EXCEPTION 'invalid preplan exact stock peg identity or dimension'
            USING ERRCODE = '23514',
                  CONSTRAINT = 'preplan_exact_peg_identity_guard';
    END IF;

    IF NEW.source_receipt_type IN ('PURCHASE', 'SUBCONTRACT') THEN
        SELECT * INTO disposition
        FROM procurement_inspection_events
        WHERE id = NEW.source_disposition_event_id;
        SELECT * INTO inspection
        FROM procurement_inspection_items
        WHERE id = disposition.inspection_item_id;
        IF disposition.id IS NULL
           OR inspection.id IS NULL
           OR reservation.source_doc_type
                <> NEW.source_receipt_type || '_RECEIPT'
           OR reservation.source_doc_id <> NEW.source_receipt_id
           OR reservation.supply_id IS DISTINCT FROM allocation.external_item_id
           OR (NEW.source_receipt_type = 'PURCHASE'
               AND reservation.supply_type <> 'PURCHASE_REQUEST_ITEM')
           OR (NEW.source_receipt_type = 'SUBCONTRACT'
               AND reservation.supply_type <> 'SUBCONTRACT_APPLICATION_ITEM')
           OR disposition.action <> 'PASS'
           OR disposition.base_qty < NEW.qty
           OR inspection.receipt_type <> NEW.source_receipt_type
           OR inspection.receipt_id <> NEW.source_receipt_id
           OR inspection.warehouse_id <> reservation.warehouse_id
           OR inspection.goods_id <> reservation.goods_id
           OR inspection.color_id IS DISTINCT FROM reservation.color_id
           OR inspection.unit_id <> origin_material.unit_id THEN
            RAISE EXCEPTION 'invalid IQC preplan exact stock peg provenance'
                USING ERRCODE = '23514',
                      CONSTRAINT = 'preplan_exact_peg_iqc_guard';
        END IF;
        SELECT COALESCE(SUM(exact.qty), 0)
        INTO source_total
        FROM preplan_analysis_stock_exact_pegs exact
        WHERE exact.source_disposition_event_id = NEW.source_disposition_event_id
          AND exact.id <> NEW.id;
        IF source_total + NEW.qty > disposition.base_qty THEN
            RAISE EXCEPTION 'preplan exact stock pegs exceed IQC PASS event quantity'
                USING ERRCODE = '23514';
        END IF;
    ELSIF NEW.source_receipt_type = 'MAKE' THEN
        SELECT * INTO stock_document
        FROM stock_documents WHERE id = NEW.source_stock_document_id;
        SELECT * INTO stock_item
        FROM stock_document_items WHERE id = NEW.source_stock_document_item_id;
        SELECT * INTO segment
        FROM production_execution_segments WHERE id = stock_item.execution_segment_id;
        SELECT * INTO plan_item
        FROM production_plan_items WHERE id = segment.source_plan_item_id;
        SELECT * INTO production_plan
        FROM production_plans WHERE id = plan_item.plan_id;
        SELECT * INTO child_item
        FROM production_material_analysis_items
        WHERE id = production_plan.material_analysis_item_id;
        IF stock_document.id IS NULL
           OR stock_item.id IS NULL
           OR segment.id IS NULL
           OR plan_item.id IS NULL
           OR production_plan.id IS NULL
           OR child_item.id IS NULL
           OR stock_document.doc_type <> 'FINISHED_IN'
           OR stock_document.status <> 1
           OR stock_document.is_deleted IS DISTINCT FROM FALSE
           OR stock_document.warehouse_id <> reservation.warehouse_id
           OR stock_item.doc_id <> stock_document.id
           OR stock_item.bill_type <> 'FINISHED_IN'
           OR stock_item.is_deleted IS DISTINCT FROM FALSE
           OR stock_item.goods_id <> reservation.goods_id
           OR stock_item.color_id IS DISTINCT FROM reservation.color_id
           OR stock_item.unit_id <> origin_material.unit_id
           OR COALESCE(stock_item.base_qty, 0) < NEW.qty
           OR reservation.source_doc_type <> 'PRODUCTION_INBOUND'
           OR reservation.source_doc_id <> stock_document.id
           OR reservation.supply_type <> 'PRODUCTION_PLAN_ITEM'
           OR reservation.supply_id <> plan_item.id
           OR production_plan.is_deleted IS DISTINCT FROM FALSE
           OR production_plan.material_analysis_id <> NEW.origin_analysis_id
           OR child_item.analysis_id <> NEW.origin_analysis_id
           OR child_item.source_type <> 'MAKE_COMPONENT'
           OR child_item.parent_analysis_material_id
                <> NEW.origin_analysis_material_id
           OR allocation.external_item_id <> child_item.id THEN
            RAISE EXCEPTION 'invalid MAKE preplan exact stock peg provenance'
                USING ERRCODE = '23514',
                      CONSTRAINT = 'preplan_exact_peg_make_guard';
        END IF;
        SELECT COALESCE(SUM(exact.qty), 0)
        INTO source_total
        FROM preplan_analysis_stock_exact_pegs exact
        WHERE exact.source_stock_document_item_id
                = NEW.source_stock_document_item_id
          AND exact.id <> NEW.id;
        IF source_total + NEW.qty > COALESCE(stock_item.base_qty, 0) THEN
            RAISE EXCEPTION 'preplan exact stock pegs exceed finished-in item quantity'
                USING ERRCODE = '23514';
        END IF;
    ELSE
        RAISE EXCEPTION 'unsupported preplan exact stock peg source type'
            USING ERRCODE = '23514';
    END IF;

    IF TG_OP = 'INSERT'
       AND (
           NEW.beneficiary_analysis_id <> NEW.origin_analysis_id
           OR NEW.beneficiary_analysis_material_id
                <> NEW.origin_analysis_material_id
           OR (
               NEW.source_receipt_type IN ('PURCHASE', 'SUBCONTRACT')
               AND NEW.beneficiary_reason <> 'ORIGIN_RECEIPT'
           )
           OR (
               NEW.source_receipt_type = 'MAKE'
               AND NEW.beneficiary_reason <> 'ORIGIN_MAKE'
           )
       ) THEN
        RAISE EXCEPTION 'new preplan exact stock peg must start at its origin material'
            USING ERRCODE = '23514';
    END IF;

    SELECT COALESCE(SUM(exact.qty), 0)
    INTO allocated_total
    FROM preplan_analysis_stock_exact_pegs exact
    LEFT JOIN procurement_inspection_events exact_disposition
      ON exact_disposition.id = exact.source_disposition_event_id
    LEFT JOIN procurement_inspection_items exact_inspection
      ON exact_inspection.id = exact_disposition.inspection_item_id
    LEFT JOIN stock_documents exact_stock_document
      ON exact_stock_document.id = exact.source_stock_document_id
    WHERE exact.supply_action_allocation_id = NEW.supply_action_allocation_id
      AND exact.id <> NEW.id
      AND (
          (
              exact.source_receipt_type IN ('PURCHASE', 'SUBCONTRACT')
              AND exact_disposition.id IS NOT NULL
              AND exact_inspection.id IS NOT NULL
              AND exact_inspection.status <> 'REVERSED'
          )
          OR
          (
              exact.source_receipt_type = 'MAKE'
              AND exact_stock_document.id IS NOT NULL
              AND exact_stock_document.status = 1
              AND exact_stock_document.is_deleted = FALSE
          )
      );
    IF allocated_total + GREATEST(
            reservation.qty - reservation.consumed_qty
                - reservation.released_qty, 0) > allocation.allocated_qty THEN
        RAISE EXCEPTION 'preplan exact stock peg exceeds supply allocation capacity'
            USING ERRCODE = '23514';
    END IF;
    RETURN NEW;
END;
$$;
