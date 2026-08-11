-- V163: close purchase-receipt provenance gaps in the V154 transition.
--
-- V154 already owns the one-for-one peg/reservation conservation and the
-- issued-material reversal guard.  This migration does not duplicate either
-- rule.  It makes every EFFECTIVE receipt allocation prove that its receipt,
-- receipt line, purchase-order line, demand, reservation and DRAW mapping
-- still describe the same material in the same warehouse and execution
-- segment.  All reverse checks are deferred so the authoritative unwind can
-- update every fact atomically in one transaction.

CREATE INDEX idx_prod_purchase_receipt_alloc_order_peg_active
    ON production_material_receipt_allocations(order_peg_id)
    WHERE status = 'EFFECTIVE';

CREATE INDEX idx_prod_purchase_receipt_alloc_draw_item_active
    ON production_material_receipt_allocations(draw_item_id)
    WHERE status = 'EFFECTIVE';

CREATE INDEX idx_prod_purchase_receipt_alloc_demand_active
    ON production_material_receipt_allocations(demand_id)
    WHERE status = 'EFFECTIVE';

CREATE OR REPLACE FUNCTION fn_assert_purchase_receipt_allocation(
    p_allocation_id UUID
) RETURNS void
LANGUAGE plpgsql
AS $$
BEGIN
    IF EXISTS (
        SELECT 1
        FROM production_material_receipt_allocations allocation
        WHERE allocation.id = p_allocation_id
          AND allocation.status = 'EFFECTIVE'
    )
    AND NOT EXISTS (
        SELECT 1
        FROM production_material_receipt_allocations allocation
        JOIN purchase_receipt_items receipt_item
          ON receipt_item.id = allocation.receipt_item_id
        JOIN purchase_receipts receipt
          ON receipt.id = allocation.receipt_id
        JOIN production_material_supply_pegs order_peg
          ON order_peg.id = allocation.order_peg_id
        JOIN purchase_order_items order_item
          ON order_item.id = order_peg.supply_item_id
        JOIN production_material_demands demand
          ON demand.id = allocation.demand_id
        JOIN stock_reservations reservation
          ON reservation.id = allocation.reservation_id
        JOIN stock_document_items draw_item
          ON draw_item.id = allocation.draw_item_id
        JOIN stock_documents draw
          ON draw.id = allocation.draw_id
        WHERE allocation.id = p_allocation_id
          AND allocation.status = 'EFFECTIVE'
          AND receipt_item.receipt_id = allocation.receipt_id
          AND receipt_item.order_item_id = order_item.id
          AND receipt_item.is_deleted = FALSE
          AND receipt_item.goods_id = demand.goods_id
          AND receipt_item.color_id IS NOT DISTINCT FROM demand.color_id
          AND order_item.is_deleted = FALSE
          AND order_item.goods_id = demand.goods_id
          AND order_item.color_id IS NOT DISTINCT FROM demand.color_id
          AND order_item.goods_id = receipt_item.goods_id
          AND order_item.color_id
                IS NOT DISTINCT FROM receipt_item.color_id
          AND receipt.is_deleted = FALSE
          AND receipt.status <> -1
          AND receipt.warehouse_id = demand.warehouse_id
          AND order_peg.supply_type = 'PURCHASE_ORDER_ITEM'
          AND order_peg.supply_item_id = receipt_item.order_item_id
          AND order_peg.demand_id = allocation.demand_id
          AND order_peg.status <> 'REVERSED'
          AND demand.package_id = allocation.package_id
          AND demand.supply_route = 'BUY'
          AND demand.is_deleted = FALSE
          AND demand.status NOT IN ('RELEASED', 'REVERSED')
          AND reservation.demand_id = allocation.demand_id
          AND reservation.owner_type =
                'PRODUCTION_MATERIAL_DEMAND'
          AND reservation.owner_id = allocation.demand_id
          AND reservation.purpose = 'PRODUCTION_MATERIAL'
          AND reservation.goods_id = demand.goods_id
          AND reservation.color_id IS NOT DISTINCT FROM demand.color_id
          AND reservation.warehouse_id = demand.warehouse_id
          AND reservation.is_deleted = FALSE
          AND reservation.status = 0
          AND draw_item.doc_id = allocation.draw_id
          AND draw_item.goods_id = demand.goods_id
          AND draw_item.color_id IS NOT DISTINCT FROM demand.color_id
          AND COALESCE(
                draw_item.base_qty,
                draw_item.qty * COALESCE(draw_item.unit_rate, 1)
              ) = allocation.allocated_qty
          AND draw_item.is_deleted = FALSE
          AND draw.warehouse_id = demand.warehouse_id
          AND draw.doc_type = 'DRAW'
          AND draw.is_deleted = FALSE
          AND draw.status <> -1
          AND EXISTS (
              SELECT 1
              FROM plan_draw_links plan_link
              WHERE plan_link.plan_id = demand.plan_id
                AND plan_link.draw_id = allocation.draw_id
                AND plan_link.is_deleted = FALSE
          )
          AND EXISTS (
              SELECT 1
              FROM production_planning_package_documents package_document
              WHERE package_document.package_id = allocation.package_id
                AND package_document.document_type = 'DRAW'
                AND package_document.document_id = allocation.draw_id
                AND package_document.execution_segment_id
                      IS NOT DISTINCT FROM demand.execution_segment_id
          )
          AND EXISTS (
              SELECT 1
              FROM production_planning_package_document_items package_item
              WHERE package_item.package_id = allocation.package_id
                AND package_item.demand_id = allocation.demand_id
                AND package_item.document_type = 'DRAW'
                AND package_item.document_id = allocation.draw_id
                AND package_item.document_item_id =
                      allocation.draw_item_id
          )
    ) THEN
        RAISE EXCEPTION
            'purchase receipt allocation provenance is inconsistent'
            USING ERRCODE = '23514',
                  CONSTRAINT =
                    'production_receipt_allocation_provenance_guard';
    END IF;
END;
$$;

CREATE OR REPLACE FUNCTION fn_assert_purchase_receipt_item_capacity(
    p_receipt_item_id UUID
) RETURNS void
LANGUAGE plpgsql
AS $$
DECLARE
    v_capacity numeric;
    v_allocated numeric;
BEGIN
    SELECT qty * COALESCE(unit_rate, 1)
    INTO v_capacity
    FROM purchase_receipt_items
    WHERE id = p_receipt_item_id
      AND is_deleted = FALSE;

    SELECT COALESCE(SUM(allocated_qty), 0)
    INTO v_allocated
    FROM production_material_receipt_allocations
    WHERE receipt_item_id = p_receipt_item_id
      AND status = 'EFFECTIVE';

    IF v_allocated > COALESCE(v_capacity, 0) THEN
        RAISE EXCEPTION
            'purchase receipt item is over-allocated to production'
            USING ERRCODE = '23514',
                  CONSTRAINT =
                    'production_purchase_receipt_item_capacity_guard';
    END IF;
END;
$$;

CREATE OR REPLACE FUNCTION
    fn_check_purchase_receipt_allocation_provenance()
RETURNS trigger
LANGUAGE plpgsql
AS $$
BEGIN
    IF TG_OP <> 'INSERT' THEN
        PERFORM fn_assert_purchase_receipt_item_capacity(
            OLD.receipt_item_id);
        PERFORM fn_assert_purchase_receipt_allocation(OLD.id);
    END IF;
    IF TG_OP <> 'DELETE' THEN
        PERFORM fn_assert_purchase_receipt_item_capacity(
            NEW.receipt_item_id);
        PERFORM fn_assert_purchase_receipt_allocation(NEW.id);
    END IF;
    RETURN NULL;
END;
$$;

CREATE CONSTRAINT TRIGGER
    trg_purchase_receipt_allocation_provenance_v163
    AFTER INSERT OR UPDATE OR DELETE
    ON production_material_receipt_allocations
    DEFERRABLE INITIALLY DEFERRED
    FOR EACH ROW EXECUTE FUNCTION
        fn_check_purchase_receipt_allocation_provenance();

-- Revalidate both the OLD and NEW relationship identities.  This matters when
-- direct SQL changes a foreign key or mapping key: checking only NEW would
-- leave the allocation attached to a now-invalid OLD source without a trigger.
CREATE OR REPLACE FUNCTION
    fn_check_purchase_receipt_provenance_source()
RETURNS trigger
LANGUAGE plpgsql
AS $$
DECLARE
    v_old_identity uuid;
    v_new_identity uuid;
    v_allocation_id uuid;
BEGIN
    IF TG_OP <> 'INSERT' THEN
        v_old_identity := CASE
            WHEN TG_TABLE_NAME = 'plan_draw_links'
                THEN (to_jsonb(OLD) ->> 'draw_id')::uuid
            WHEN TG_TABLE_NAME =
                    'production_planning_package_documents'
                THEN (to_jsonb(OLD) ->> 'document_id')::uuid
            WHEN TG_TABLE_NAME =
                    'production_planning_package_document_items'
                THEN (to_jsonb(OLD) ->> 'document_item_id')::uuid
            ELSE (to_jsonb(OLD) ->> 'id')::uuid
        END;
    END IF;
    IF TG_OP <> 'DELETE' THEN
        v_new_identity := CASE
            WHEN TG_TABLE_NAME = 'plan_draw_links'
                THEN (to_jsonb(NEW) ->> 'draw_id')::uuid
            WHEN TG_TABLE_NAME =
                    'production_planning_package_documents'
                THEN (to_jsonb(NEW) ->> 'document_id')::uuid
            WHEN TG_TABLE_NAME =
                    'production_planning_package_document_items'
                THEN (to_jsonb(NEW) ->> 'document_item_id')::uuid
            ELSE (to_jsonb(NEW) ->> 'id')::uuid
        END;
    END IF;

    IF TG_TABLE_NAME = 'purchase_receipt_items' THEN
        IF v_old_identity IS NOT NULL THEN
            PERFORM fn_assert_purchase_receipt_item_capacity(
                v_old_identity);
        END IF;
        IF v_new_identity IS NOT NULL
           AND v_new_identity IS DISTINCT FROM v_old_identity THEN
            PERFORM fn_assert_purchase_receipt_item_capacity(
                v_new_identity);
        END IF;
    END IF;

    FOR v_allocation_id IN
        SELECT allocation.id
        FROM production_material_receipt_allocations allocation
        WHERE allocation.status = 'EFFECTIVE'
          AND (
              (
                  TG_TABLE_NAME = 'purchase_receipts'
                  AND (
                      allocation.receipt_id = v_old_identity
                      OR allocation.receipt_id = v_new_identity
                  )
              )
              OR (
                  TG_TABLE_NAME = 'purchase_receipt_items'
                  AND (
                      allocation.receipt_item_id = v_old_identity
                      OR allocation.receipt_item_id = v_new_identity
                  )
              )
              OR (
                  TG_TABLE_NAME = 'purchase_order_items'
                  AND EXISTS (
                      SELECT 1
                      FROM purchase_receipt_items receipt_item
                      WHERE receipt_item.id = allocation.receipt_item_id
                        AND (
                            receipt_item.order_item_id = v_old_identity
                            OR receipt_item.order_item_id = v_new_identity
                            OR allocation.order_peg_id IN (
                                SELECT peg.id
                                FROM production_material_supply_pegs peg
                                WHERE peg.supply_item_id IN (
                                    v_old_identity, v_new_identity
                                )
                            )
                        )
                  )
              )
              OR (
                  TG_TABLE_NAME = 'production_material_demands'
                  AND (
                      allocation.demand_id = v_old_identity
                      OR allocation.demand_id = v_new_identity
                  )
              )
              OR (
                  TG_TABLE_NAME = 'production_material_supply_pegs'
                  AND (
                      allocation.order_peg_id = v_old_identity
                      OR allocation.order_peg_id = v_new_identity
                  )
              )
              OR (
                  TG_TABLE_NAME = 'stock_reservations'
                  AND (
                      allocation.reservation_id = v_old_identity
                      OR allocation.reservation_id = v_new_identity
                  )
              )
              OR (
                  TG_TABLE_NAME IN (
                      'stock_documents', 'plan_draw_links',
                      'production_planning_package_documents'
                  )
                  AND (
                      allocation.draw_id = v_old_identity
                      OR allocation.draw_id = v_new_identity
                  )
              )
              OR (
                  TG_TABLE_NAME IN (
                      'stock_document_items',
                      'production_planning_package_document_items'
                  )
                  AND (
                      allocation.draw_item_id = v_old_identity
                      OR allocation.draw_item_id = v_new_identity
                  )
              )
          )
    LOOP
        PERFORM fn_assert_purchase_receipt_allocation(
            v_allocation_id);
    END LOOP;
    RETURN NULL;
END;
$$;

CREATE CONSTRAINT TRIGGER trg_purchase_receipt_header_provenance
    AFTER INSERT OR UPDATE OR DELETE ON purchase_receipts
    DEFERRABLE INITIALLY DEFERRED
    FOR EACH ROW EXECUTE FUNCTION
        fn_check_purchase_receipt_provenance_source();

CREATE CONSTRAINT TRIGGER trg_purchase_receipt_item_provenance
    AFTER INSERT OR UPDATE OR DELETE ON purchase_receipt_items
    DEFERRABLE INITIALLY DEFERRED
    FOR EACH ROW EXECUTE FUNCTION
        fn_check_purchase_receipt_provenance_source();

CREATE CONSTRAINT TRIGGER trg_purchase_order_item_receipt_provenance
    AFTER INSERT OR UPDATE OR DELETE ON purchase_order_items
    DEFERRABLE INITIALLY DEFERRED
    FOR EACH ROW EXECUTE FUNCTION
        fn_check_purchase_receipt_provenance_source();

CREATE CONSTRAINT TRIGGER trg_purchase_demand_receipt_provenance
    AFTER INSERT OR UPDATE OR DELETE ON production_material_demands
    DEFERRABLE INITIALLY DEFERRED
    FOR EACH ROW EXECUTE FUNCTION
        fn_check_purchase_receipt_provenance_source();

CREATE CONSTRAINT TRIGGER trg_purchase_order_peg_receipt_provenance
    AFTER INSERT OR UPDATE OR DELETE ON production_material_supply_pegs
    DEFERRABLE INITIALLY DEFERRED
    FOR EACH ROW EXECUTE FUNCTION
        fn_check_purchase_receipt_provenance_source();

CREATE CONSTRAINT TRIGGER trg_purchase_reservation_receipt_provenance
    AFTER INSERT OR UPDATE OR DELETE ON stock_reservations
    DEFERRABLE INITIALLY DEFERRED
    FOR EACH ROW EXECUTE FUNCTION
        fn_check_purchase_receipt_provenance_source();

CREATE CONSTRAINT TRIGGER trg_purchase_draw_receipt_provenance
    AFTER INSERT OR UPDATE OR DELETE ON stock_documents
    DEFERRABLE INITIALLY DEFERRED
    FOR EACH ROW EXECUTE FUNCTION
        fn_check_purchase_receipt_provenance_source();

CREATE CONSTRAINT TRIGGER trg_purchase_draw_item_receipt_provenance
    AFTER INSERT OR UPDATE OR DELETE ON stock_document_items
    DEFERRABLE INITIALLY DEFERRED
    FOR EACH ROW EXECUTE FUNCTION
        fn_check_purchase_receipt_provenance_source();

CREATE CONSTRAINT TRIGGER trg_purchase_plan_draw_receipt_provenance
    AFTER INSERT OR UPDATE OR DELETE ON plan_draw_links
    DEFERRABLE INITIALLY DEFERRED
    FOR EACH ROW EXECUTE FUNCTION
        fn_check_purchase_receipt_provenance_source();

CREATE CONSTRAINT TRIGGER trg_purchase_package_draw_provenance
    AFTER INSERT OR UPDATE OR DELETE
    ON production_planning_package_documents
    DEFERRABLE INITIALLY DEFERRED
    FOR EACH ROW EXECUTE FUNCTION
        fn_check_purchase_receipt_provenance_source();

CREATE CONSTRAINT TRIGGER trg_purchase_package_draw_item_provenance
    AFTER INSERT OR UPDATE OR DELETE
    ON production_planning_package_document_items
    DEFERRABLE INITIALLY DEFERRED
    FOR EACH ROW EXECUTE FUNCTION
        fn_check_purchase_receipt_provenance_source();

COMMENT ON FUNCTION fn_assert_purchase_receipt_allocation(UUID) IS
    'Validates the live purchase receipt to demand/reservation/DRAW provenance.';
