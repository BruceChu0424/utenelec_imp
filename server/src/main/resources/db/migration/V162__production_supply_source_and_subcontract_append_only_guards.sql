-- V162: fail-closed guards for production-owned purchase/subcontract sources.
--
-- Source documents remain owned by their business modules. Once a live
-- production supply peg references one of their lines, generic CRUD must not
-- replace, delete or change the material identity/quantity behind that peg.
-- Constraint triggers are deferred so the authoritative planning-package
-- reversal can release the peg and close its generated document atomically.

CREATE OR REPLACE FUNCTION fn_has_protected_production_supply_peg(
    p_supply_type TEXT,
    p_supply_item_id UUID
) RETURNS boolean
LANGUAGE sql
STABLE
AS $$
    SELECT EXISTS (
        SELECT 1
        FROM production_material_supply_pegs peg
        WHERE peg.supply_type = p_supply_type
          AND peg.supply_item_id = p_supply_item_id
    );
$$;

CREATE INDEX idx_production_supply_peg_source_lifecycle
    ON production_material_supply_pegs(
        supply_type, supply_item_id, status);

CREATE INDEX
    idx_prod_sub_receipt_alloc_peg_active
    ON production_material_subcontract_receipt_allocations(order_peg_id)
    WHERE status = 'EFFECTIVE';

CREATE INDEX
    idx_prod_sub_receipt_alloc_reservation_active
    ON production_material_subcontract_receipt_allocations(reservation_id)
    WHERE status = 'EFFECTIVE';

CREATE INDEX idx_prod_sub_receipt_alloc_draw_item_active
    ON production_material_subcontract_receipt_allocations(draw_item_id)
    WHERE status = 'EFFECTIVE';

CREATE OR REPLACE FUNCTION fn_guard_production_supply_source_item()
RETURNS trigger
LANGUAGE plpgsql
AS $$
DECLARE
    v_supply_type text;
    v_constraint text;
BEGIN
    IF TG_TABLE_NAME = 'purchase_request_items' THEN
        v_supply_type := 'PURCHASE_REQUEST_ITEM';
        v_constraint :=
            'production_purchase_request_item_supply_guard';
    ELSIF TG_TABLE_NAME = 'subcontract_application_items' THEN
        v_supply_type := 'SUBCONTRACT_APPLICATION_ITEM';
        v_constraint :=
            'production_subcontract_application_item_supply_guard';
    ELSIF TG_TABLE_NAME = 'purchase_order_items' THEN
        v_supply_type := 'PURCHASE_ORDER_ITEM';
        v_constraint :=
            'production_purchase_order_item_supply_guard';
    ELSIF TG_TABLE_NAME = 'subcontract_order_items' THEN
        v_supply_type := 'SUBCONTRACT_ORDER_ITEM';
        v_constraint :=
            'production_subcontract_order_item_supply_guard';
    ELSE
        RAISE EXCEPTION 'unsupported production supply source table'
            USING ERRCODE = '23514',
                  CONSTRAINT =
                      'production_supply_source_table_guard';
    END IF;

    IF fn_has_protected_production_supply_peg(
            v_supply_type, OLD.id) THEN
        RAISE EXCEPTION
            'production-linked supply source item cannot be changed or deleted'
            USING ERRCODE = '23514',
                  CONSTRAINT = v_constraint;
    END IF;
    IF TG_OP = 'DELETE' THEN
        RETURN OLD;
    END IF;
    RETURN NEW;
END;
$$;

CREATE CONSTRAINT TRIGGER
    trg_guard_production_purchase_request_item_update
    AFTER UPDATE OF
        id, request_id, goods_id, color_id, unit_id,
        unit_rate, qty, is_deleted
    ON purchase_request_items
    DEFERRABLE INITIALLY DEFERRED
    FOR EACH ROW EXECUTE FUNCTION
        fn_guard_production_supply_source_item();

CREATE CONSTRAINT TRIGGER
    trg_guard_production_purchase_request_item_delete
    AFTER DELETE ON purchase_request_items
    DEFERRABLE INITIALLY DEFERRED
    FOR EACH ROW EXECUTE FUNCTION
        fn_guard_production_supply_source_item();

CREATE CONSTRAINT TRIGGER
    trg_guard_production_subcontract_application_item_update
    AFTER UPDATE OF
        id, application_id, goods_id, color_id, unit_id,
        unit_rate, qty, is_deleted
    ON subcontract_application_items
    DEFERRABLE INITIALLY DEFERRED
    FOR EACH ROW EXECUTE FUNCTION
        fn_guard_production_supply_source_item();

CREATE CONSTRAINT TRIGGER
    trg_guard_production_subcontract_application_item_delete
    AFTER DELETE ON subcontract_application_items
    DEFERRABLE INITIALLY DEFERRED
    FOR EACH ROW EXECUTE FUNCTION
        fn_guard_production_supply_source_item();

CREATE CONSTRAINT TRIGGER
    trg_guard_production_purchase_order_item_update
    AFTER UPDATE OF
        id, order_id, request_item_id, goods_id, color_id,
        unit_id, unit_rate, qty, is_deleted
    ON purchase_order_items
    DEFERRABLE INITIALLY DEFERRED
    FOR EACH ROW EXECUTE FUNCTION
        fn_guard_production_supply_source_item();

CREATE CONSTRAINT TRIGGER
    trg_guard_production_purchase_order_item_delete
    AFTER DELETE ON purchase_order_items
    DEFERRABLE INITIALLY DEFERRED
    FOR EACH ROW EXECUTE FUNCTION
        fn_guard_production_supply_source_item();

CREATE CONSTRAINT TRIGGER
    trg_guard_production_subcontract_order_item_update
    AFTER UPDATE OF
        id, order_id, application_item_id, goods_id, color_id,
        unit_id, unit_rate, qty, is_deleted
    ON subcontract_order_items
    DEFERRABLE INITIALLY DEFERRED
    FOR EACH ROW EXECUTE FUNCTION
        fn_guard_production_supply_source_item();

CREATE CONSTRAINT TRIGGER
    trg_guard_production_subcontract_order_item_delete
    AFTER DELETE ON subcontract_order_items
    DEFERRABLE INITIALLY DEFERRED
    FOR EACH ROW EXECUTE FUNCTION
        fn_guard_production_supply_source_item();

CREATE OR REPLACE FUNCTION fn_reject_production_supply_peg_delete()
RETURNS trigger
LANGUAGE plpgsql
AS $$
BEGIN
    RAISE EXCEPTION
        'production material supply peg is append-only'
        USING ERRCODE = '23514',
              CONSTRAINT =
                'production_material_supply_peg_append_only_guard';
END;
$$;

CREATE TRIGGER trg_reject_production_supply_peg_delete
    BEFORE DELETE ON production_material_supply_pegs
    FOR EACH ROW EXECUTE FUNCTION
        fn_reject_production_supply_peg_delete();

CREATE OR REPLACE FUNCTION fn_guard_production_demand_identity()
RETURNS trigger
LANGUAGE plpgsql
AS $$
BEGIN
    IF NEW.package_id IS DISTINCT FROM OLD.package_id
       OR NEW.plan_id IS DISTINCT FROM OLD.plan_id
       OR NEW.execution_segment_id
            IS DISTINCT FROM OLD.execution_segment_id THEN
        RAISE EXCEPTION
            'production material demand ownership is immutable'
            USING ERRCODE = '23514',
                  CONSTRAINT =
                    'production_material_demand_identity_guard';
    END IF;
    RETURN NEW;
END;
$$;

CREATE TRIGGER trg_guard_production_demand_identity
    BEFORE UPDATE OF package_id, plan_id, execution_segment_id
    ON production_material_demands
    FOR EACH ROW EXECUTE FUNCTION
        fn_guard_production_demand_identity();

CREATE OR REPLACE FUNCTION fn_guard_production_supply_source_header()
RETURNS trigger
LANGUAGE plpgsql
AS $$
DECLARE
    v_has_live boolean;
    v_has_history boolean;
    v_constraint text;
BEGIN
    IF TG_OP = 'UPDATE'
       AND (
           (OLD.status = -1 AND NEW.status <> -1)
           OR (
               COALESCE(OLD.is_deleted, FALSE) = TRUE
               AND COALESCE(NEW.is_deleted, FALSE) = FALSE
           )
       ) THEN
        IF TG_TABLE_NAME = 'purchase_requests' THEN
            SELECT EXISTS (
                SELECT 1
                FROM purchase_request_items item
                JOIN production_material_supply_pegs peg
                  ON peg.supply_type = 'PURCHASE_REQUEST_ITEM'
                 AND peg.supply_item_id = item.id
                WHERE item.request_id = OLD.id
            ) INTO v_has_history;
            v_constraint :=
                'production_purchase_request_lifecycle_guard';
        ELSE
            SELECT EXISTS (
                SELECT 1
                FROM subcontract_application_items item
                JOIN production_material_supply_pegs peg
                  ON peg.supply_type =
                        'SUBCONTRACT_APPLICATION_ITEM'
                 AND peg.supply_item_id = item.id
                WHERE item.application_id = OLD.id
            ) INTO v_has_history;
            v_constraint :=
                'production_subcontract_application_lifecycle_guard';
        END IF;
        IF v_has_history THEN
            RAISE EXCEPTION
                'production-linked source document cannot be reactivated'
                USING ERRCODE = '23514',
                      CONSTRAINT = v_constraint;
        END IF;
    END IF;

    IF TG_OP <> 'DELETE'
       AND COALESCE(NEW.is_deleted, FALSE) = FALSE
       AND NEW.status <> -1
       AND NEW.warehouse_id IS NOT DISTINCT FROM OLD.warehouse_id
       AND NEW.need_date IS NOT DISTINCT FROM OLD.need_date
    THEN
        RETURN NEW;
    END IF;

    IF TG_TABLE_NAME = 'purchase_requests' THEN
        SELECT EXISTS (
            SELECT 1
            FROM purchase_request_items item
            JOIN production_material_supply_pegs peg
              ON peg.supply_type = 'PURCHASE_REQUEST_ITEM'
             AND peg.supply_item_id = item.id
             AND (
                 peg.status NOT IN ('RELEASED', 'REVERSED')
                 OR EXISTS (
                     SELECT 1
                     FROM production_material_peg_transfers transfer
                     WHERE transfer.from_peg_id = peg.id
                       AND transfer.status = 'EFFECTIVE'
                 )
             )
            WHERE item.request_id = OLD.id
        ) INTO v_has_live;
        v_constraint := 'production_purchase_request_supply_guard';
    ELSIF TG_TABLE_NAME = 'subcontract_applications' THEN
        SELECT EXISTS (
            SELECT 1
            FROM subcontract_application_items item
            JOIN production_material_supply_pegs peg
              ON peg.supply_type =
                    'SUBCONTRACT_APPLICATION_ITEM'
             AND peg.supply_item_id = item.id
             AND (
                 peg.status NOT IN ('RELEASED', 'REVERSED')
                 OR EXISTS (
                     SELECT 1
                     FROM
                       production_material_subcontract_peg_transfers transfer
                     WHERE transfer.from_peg_id = peg.id
                       AND transfer.status = 'EFFECTIVE'
                 )
             )
            WHERE item.application_id = OLD.id
        ) INTO v_has_live;
        v_constraint :=
            'production_subcontract_application_supply_guard';
    ELSE
        RAISE EXCEPTION 'unsupported production supply source header'
            USING ERRCODE = '23514',
                  CONSTRAINT =
                      'production_supply_source_header_table_guard';
    END IF;

    IF v_has_live THEN
        RAISE EXCEPTION
            'production-linked supply source must be released before close'
            USING ERRCODE = '23514',
                  CONSTRAINT = v_constraint;
    END IF;
    IF TG_OP = 'DELETE' THEN
        RETURN OLD;
    END IF;
    RETURN NEW;
END;
$$;

CREATE CONSTRAINT TRIGGER
    trg_guard_production_purchase_request_terminal
    AFTER UPDATE OF status, is_deleted, warehouse_id, need_date
    ON purchase_requests
    DEFERRABLE INITIALLY DEFERRED
    FOR EACH ROW EXECUTE FUNCTION
        fn_guard_production_supply_source_header();

CREATE CONSTRAINT TRIGGER
    trg_guard_production_purchase_request_delete
    AFTER DELETE ON purchase_requests
    DEFERRABLE INITIALLY DEFERRED
    FOR EACH ROW EXECUTE FUNCTION
        fn_guard_production_supply_source_header();

CREATE CONSTRAINT TRIGGER
    trg_guard_production_subcontract_application_terminal
    AFTER UPDATE OF status, is_deleted, warehouse_id, need_date
    ON subcontract_applications
    DEFERRABLE INITIALLY DEFERRED
    FOR EACH ROW EXECUTE FUNCTION
        fn_guard_production_supply_source_header();

CREATE CONSTRAINT TRIGGER
    trg_guard_production_subcontract_application_delete
    AFTER DELETE ON subcontract_applications
    DEFERRABLE INITIALLY DEFERRED
    FOR EACH ROW EXECUTE FUNCTION
        fn_guard_production_supply_source_header();

-- V158 provenance rows are ledger facts: identities are already immutable,
-- V162 additionally forbids physical deletion and status resurrection.
CREATE OR REPLACE FUNCTION
    fn_guard_subcontract_production_mapping_lifecycle()
RETURNS trigger
LANGUAGE plpgsql
AS $$
DECLARE
    v_mapping_name text;
    v_constraint text;
BEGIN
    IF TG_TABLE_NAME =
            'production_material_subcontract_peg_transfers' THEN
        v_mapping_name := 'subcontract supply transfer';
        v_constraint :=
            CASE WHEN TG_OP = 'DELETE'
                THEN 'production_subcontract_transfer_append_only_guard'
                ELSE 'production_subcontract_transfer_lifecycle_guard'
            END;
    ELSE
        v_mapping_name := 'subcontract receipt allocation';
        v_constraint :=
            CASE WHEN TG_OP = 'DELETE'
                THEN
                    'production_subcontract_receipt_append_only_guard'
                ELSE
                    'production_subcontract_receipt_lifecycle_guard'
            END;
    END IF;

    IF TG_OP = 'DELETE' THEN
        RAISE EXCEPTION '% is append-only', v_mapping_name
            USING ERRCODE = '23514',
                  CONSTRAINT = v_constraint;
    END IF;
    IF OLD.status = 'REVERSED'
       AND NEW.status IS DISTINCT FROM 'REVERSED' THEN
        RAISE EXCEPTION '% cannot be reactivated', v_mapping_name
            USING ERRCODE = '23514',
                  CONSTRAINT = v_constraint;
    END IF;
    RETURN NEW;
END;
$$;

CREATE TRIGGER trg_guard_subcontract_transfer_no_delete
    BEFORE DELETE
    ON production_material_subcontract_peg_transfers
    FOR EACH ROW EXECUTE FUNCTION
        fn_guard_subcontract_production_mapping_lifecycle();

CREATE TRIGGER trg_guard_subcontract_transfer_status_lifecycle
    BEFORE UPDATE OF status
    ON production_material_subcontract_peg_transfers
    FOR EACH ROW EXECUTE FUNCTION
        fn_guard_subcontract_production_mapping_lifecycle();

CREATE TRIGGER trg_guard_subcontract_receipt_no_delete
    BEFORE DELETE
    ON production_material_subcontract_receipt_allocations
    FOR EACH ROW EXECUTE FUNCTION
        fn_guard_subcontract_production_mapping_lifecycle();

CREATE TRIGGER trg_guard_subcontract_receipt_status_lifecycle
    BEFORE UPDATE OF status
    ON production_material_subcontract_receipt_allocations
    FOR EACH ROW EXECUTE FUNCTION
        fn_guard_subcontract_production_mapping_lifecycle();

CREATE OR REPLACE FUNCTION
    fn_guard_subcontract_receipt_allocation_reversal()
RETURNS trigger
LANGUAGE plpgsql
AS $$
DECLARE
    v_issued numeric;
BEGIN
    IF OLD.status = 'EFFECTIVE'
       AND NEW.status = 'REVERSED' THEN
        SELECT GREATEST(
                   COALESCE(item.issued_qty, 0),
                   COALESCE((
                       SELECT SUM(CASE posting_type
                           WHEN 'ISSUE' THEN qty_base
                           WHEN 'ISSUE_REVERSE' THEN -qty_base
                           ELSE 0 END)
                       FROM production_material_stock_postings
                       WHERE stock_document_item_id = item.id
                         AND posting_type IN (
                             'ISSUE', 'ISSUE_REVERSE')
                   ), 0)
               )
        INTO v_issued
        FROM stock_document_items item
        WHERE item.id = OLD.draw_item_id
        FOR UPDATE;

        IF COALESCE(v_issued, 0) > 0 THEN
            RAISE EXCEPTION
                'subcontract receipt material has already been issued'
                USING ERRCODE = '23514',
                      CONSTRAINT =
                        'production_subcontract_receipt_issued_draw_guard';
        END IF;
    END IF;
    RETURN NEW;
END;
$$;

CREATE TRIGGER
    trg_guard_subcontract_receipt_allocation_reversal
    BEFORE UPDATE OF status
    ON production_material_subcontract_receipt_allocations
    FOR EACH ROW EXECUTE FUNCTION
        fn_guard_subcontract_receipt_allocation_reversal();

-- Exact transfer conservation. These checks deliberately run on both the
-- mapping row and the peg: direct peg updates cannot bypass provenance.
CREATE OR REPLACE FUNCTION
    fn_assert_subcontract_peg_transfer_coverage(p_peg_id UUID)
RETURNS void
LANGUAGE plpgsql
AS $$
DECLARE
    v_type       text;
    v_allocated  numeric;
    v_consumed   numeric;
    v_released   numeric;
    v_status     text;
    v_active     numeric;
    v_has_link   boolean;
BEGIN
    SELECT supply_type, allocated_qty, consumed_qty,
           released_qty, status
    INTO v_type, v_allocated, v_consumed,
         v_released, v_status
    FROM production_material_supply_pegs
    WHERE id = p_peg_id;

    IF NOT FOUND THEN
        RETURN;
    END IF;

    IF v_type = 'SUBCONTRACT_APPLICATION_ITEM' THEN
        SELECT COALESCE(SUM(transferred_qty), 0)
        INTO v_active
        FROM production_material_subcontract_peg_transfers
        WHERE from_peg_id = p_peg_id
          AND status = 'EFFECTIVE';

        IF v_active > v_released THEN
            RAISE EXCEPTION
                'active subcontract transfers exceed application peg release'
                USING ERRCODE = '23514',
                      CONSTRAINT =
                        'production_subcontract_transfer_source_guard';
        END IF;
        RETURN;
    END IF;

    IF v_type <> 'SUBCONTRACT_ORDER_ITEM' THEN
        RETURN;
    END IF;

    SELECT EXISTS (
               SELECT 1
               FROM production_material_subcontract_peg_transfers
               WHERE to_peg_id = p_peg_id
           ),
           COALESCE(SUM(transferred_qty)
               FILTER (WHERE status = 'EFFECTIVE'), 0)
    INTO v_has_link, v_active
    FROM production_material_subcontract_peg_transfers
    WHERE to_peg_id = p_peg_id;

    IF NOT v_has_link THEN
        RETURN;
    END IF;

    IF v_status = 'REVERSED' THEN
        IF v_active <> 0
           OR v_consumed <> 0
           OR v_released <> v_allocated THEN
            RAISE EXCEPTION
                'reversed subcontract order peg is not fully unwound'
                USING ERRCODE = '23514',
                      CONSTRAINT =
                        'production_subcontract_transfer_target_guard';
        END IF;
    ELSIF v_active <> v_allocated THEN
        RAISE EXCEPTION
            'subcontract order peg is not exactly covered by active transfer'
            USING ERRCODE = '23514',
                  CONSTRAINT =
                    'production_subcontract_transfer_target_guard';
    END IF;
END;
$$;

CREATE OR REPLACE FUNCTION
    fn_assert_subcontract_peg_receipt_coverage(p_peg_id UUID)
RETURNS void
LANGUAGE plpgsql
AS $$
DECLARE
    v_type       text;
    v_consumed   numeric;
    v_mapped     numeric;
BEGIN
    SELECT supply_type, consumed_qty
    INTO v_type, v_consumed
    FROM production_material_supply_pegs
    WHERE id = p_peg_id;

    IF NOT FOUND THEN
        RETURN;
    END IF;

    IF v_type = 'SUBCONTRACT_APPLICATION_ITEM'
       AND v_consumed <> 0 THEN
        RAISE EXCEPTION
            'subcontract application supply cannot be consumed'
            USING ERRCODE = '23514',
                  CONSTRAINT =
                    'production_subcontract_application_peg_consumption_guard';
    END IF;

    IF v_type <> 'SUBCONTRACT_ORDER_ITEM' THEN
        RETURN;
    END IF;

    SELECT COALESCE(SUM(allocated_qty), 0)
    INTO v_mapped
    FROM production_material_subcontract_receipt_allocations
    WHERE order_peg_id = p_peg_id
      AND status = 'EFFECTIVE';

    IF v_mapped <> v_consumed THEN
        RAISE EXCEPTION
            'subcontract order peg consumption lacks exact receipt allocation'
            USING ERRCODE = '23514',
                  CONSTRAINT =
                    'production_subcontract_peg_receipt_coverage_guard';
    END IF;
END;
$$;

-- An EFFECTIVE receipt allocation must point to the exact target-warehouse
-- reservation and DRAW line. Reversed facts remain queryable after the
-- operational reservation/DRAW has been soft-deleted.
CREATE OR REPLACE FUNCTION fn_assert_subcontract_receipt_allocation(
    p_allocation_id UUID
) RETURNS void
LANGUAGE plpgsql
AS $$
BEGIN
    IF EXISTS (
        SELECT 1
        FROM production_material_subcontract_receipt_allocations a
        WHERE a.id = p_allocation_id
          AND a.status = 'EFFECTIVE'
    )
    AND NOT EXISTS (
        SELECT 1
        FROM production_material_subcontract_receipt_allocations a
        JOIN subcontract_receipt_items receipt_item
          ON receipt_item.id = a.receipt_item_id
        JOIN subcontract_receipts receipt
          ON receipt.id = a.receipt_id
        JOIN production_material_supply_pegs peg
          ON peg.id = a.order_peg_id
        JOIN production_material_demands demand
          ON demand.id = a.demand_id
        JOIN stock_reservations reservation
          ON reservation.id = a.reservation_id
        JOIN stock_document_items draw_item
          ON draw_item.id = a.draw_item_id
        JOIN stock_documents draw
          ON draw.id = a.draw_id
        WHERE a.id = p_allocation_id
          AND a.status = 'EFFECTIVE'
          AND receipt_item.receipt_id = a.receipt_id
          AND receipt_item.is_deleted = FALSE
          AND receipt_item.goods_id = demand.goods_id
          AND receipt_item.color_id
                IS NOT DISTINCT FROM demand.color_id
          AND receipt_item.order_item_id = peg.supply_item_id
          AND peg.supply_type = 'SUBCONTRACT_ORDER_ITEM'
          AND peg.demand_id = a.demand_id
          AND demand.package_id = a.package_id
          AND reservation.demand_id = a.demand_id
          AND reservation.owner_type =
                'PRODUCTION_MATERIAL_DEMAND'
          AND reservation.purpose = 'PRODUCTION_MATERIAL'
          AND reservation.goods_id = demand.goods_id
          AND reservation.color_id IS NOT DISTINCT FROM demand.color_id
          AND reservation.warehouse_id = demand.warehouse_id
          AND reservation.is_deleted = FALSE
          AND reservation.status = 0
          AND receipt.warehouse_id = demand.warehouse_id
          AND receipt.is_deleted = FALSE
          AND receipt.status <> -1
          AND draw_item.doc_id = a.draw_id
          AND draw_item.goods_id = demand.goods_id
          AND draw_item.color_id IS NOT DISTINCT FROM demand.color_id
          AND COALESCE(
                draw_item.base_qty,
                draw_item.qty * COALESCE(draw_item.unit_rate, 1)
              ) = a.allocated_qty
          AND draw_item.is_deleted = FALSE
          AND draw.warehouse_id = demand.warehouse_id
          AND draw.doc_type = 'DRAW'
          AND draw.is_deleted = FALSE
          AND draw.status <> -1
          AND EXISTS (
              SELECT 1
              FROM plan_draw_links draw_link
              WHERE draw_link.plan_id = demand.plan_id
                AND draw_link.draw_id = a.draw_id
                AND draw_link.is_deleted = FALSE
          )
          AND EXISTS (
              SELECT 1
              FROM production_planning_package_documents mapped_document
              WHERE mapped_document.package_id = a.package_id
                AND mapped_document.document_type = 'DRAW'
                AND mapped_document.document_id = a.draw_id
                AND mapped_document.execution_segment_id
                      IS NOT DISTINCT FROM demand.execution_segment_id
          )
          AND EXISTS (
              SELECT 1
              FROM production_planning_package_document_items mapped_item
              WHERE mapped_item.package_id = a.package_id
                AND mapped_item.demand_id = a.demand_id
                AND mapped_item.document_type = 'DRAW'
                AND mapped_item.document_id = a.draw_id
                AND mapped_item.document_item_id = a.draw_item_id
          )
    ) THEN
        RAISE EXCEPTION
            'subcontract receipt allocation provenance is inconsistent'
            USING ERRCODE = '23514',
                  CONSTRAINT =
                    'production_subcontract_receipt_provenance_guard';
    END IF;
END;
$$;

CREATE OR REPLACE FUNCTION
    fn_assert_subcontract_receipt_reservation_coverage(
        p_reservation_id UUID
    ) RETURNS void
LANGUAGE plpgsql
AS $$
DECLARE
    v_committed numeric;
    v_mapped numeric;
    v_allocation_id uuid;
BEGIN
    SELECT CASE WHEN is_deleted
                THEN 0 ELSE qty - released_qty END
    INTO v_committed
    FROM stock_reservations
    WHERE id = p_reservation_id
      AND owner_type = 'PRODUCTION_MATERIAL_DEMAND';

    SELECT COALESCE(SUM(allocated_qty), 0)
    INTO v_mapped
    FROM production_material_subcontract_receipt_allocations
    WHERE reservation_id = p_reservation_id
      AND status = 'EFFECTIVE';

    IF v_mapped > COALESCE(v_committed, 0) THEN
        RAISE EXCEPTION
            'subcontract receipt allocations exceed reservation'
            USING ERRCODE = '23514',
                  CONSTRAINT =
                    'production_subcontract_receipt_reservation_capacity_guard';
    END IF;

    FOR v_allocation_id IN
        SELECT id
        FROM production_material_subcontract_receipt_allocations
        WHERE reservation_id = p_reservation_id
          AND status = 'EFFECTIVE'
    LOOP
        PERFORM fn_assert_subcontract_receipt_allocation(
            v_allocation_id);
    END LOOP;
END;
$$;

CREATE OR REPLACE FUNCTION
    fn_assert_subcontract_receipt_item_capacity(
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
    FROM subcontract_receipt_items
    WHERE id = p_receipt_item_id
      AND is_deleted = FALSE;

    SELECT COALESCE(SUM(allocated_qty), 0)
    INTO v_allocated
    FROM production_material_subcontract_receipt_allocations
    WHERE receipt_item_id = p_receipt_item_id
      AND status = 'EFFECTIVE';

    IF v_allocated > COALESCE(v_capacity, 0) THEN
        RAISE EXCEPTION
            'subcontract receipt item is over-allocated to production'
            USING ERRCODE = '23514',
                  CONSTRAINT =
                    'production_subcontract_receipt_item_capacity_guard';
    END IF;
END;
$$;

CREATE OR REPLACE FUNCTION
    fn_check_subcontract_supply_conservation()
RETURNS trigger
LANGUAGE plpgsql
AS $$
BEGIN
    IF TG_TABLE_NAME = 'production_material_supply_pegs' THEN
        IF TG_OP <> 'INSERT' THEN
            PERFORM fn_assert_subcontract_peg_transfer_coverage(OLD.id);
            PERFORM fn_assert_subcontract_peg_receipt_coverage(OLD.id);
        END IF;
        IF TG_OP <> 'DELETE' THEN
            PERFORM fn_assert_subcontract_peg_transfer_coverage(NEW.id);
            PERFORM fn_assert_subcontract_peg_receipt_coverage(NEW.id);
        END IF;
    ELSIF TG_TABLE_NAME =
            'production_material_subcontract_peg_transfers' THEN
        IF TG_OP <> 'INSERT' THEN
            PERFORM fn_assert_subcontract_peg_transfer_coverage(
                OLD.from_peg_id);
            PERFORM fn_assert_subcontract_peg_transfer_coverage(
                OLD.to_peg_id);
        END IF;
        IF TG_OP <> 'DELETE' THEN
            PERFORM fn_assert_subcontract_peg_transfer_coverage(
                NEW.from_peg_id);
            PERFORM fn_assert_subcontract_peg_transfer_coverage(
                NEW.to_peg_id);
        END IF;
    ELSE
        IF TG_OP <> 'INSERT' THEN
            PERFORM fn_assert_subcontract_peg_receipt_coverage(
                OLD.order_peg_id);
            PERFORM
                fn_assert_subcontract_receipt_reservation_coverage(
                    OLD.reservation_id);
            PERFORM fn_assert_subcontract_receipt_item_capacity(
                OLD.receipt_item_id);
            PERFORM fn_assert_subcontract_receipt_allocation(OLD.id);
        END IF;
        IF TG_OP <> 'DELETE' THEN
            PERFORM fn_assert_subcontract_peg_receipt_coverage(
                NEW.order_peg_id);
            PERFORM
                fn_assert_subcontract_receipt_reservation_coverage(
                    NEW.reservation_id);
            PERFORM fn_assert_subcontract_receipt_item_capacity(
                NEW.receipt_item_id);
            PERFORM fn_assert_subcontract_receipt_allocation(NEW.id);
        END IF;
    END IF;
    RETURN NULL;
END;
$$;

CREATE OR REPLACE FUNCTION
    fn_check_subcontract_receipt_reservation()
RETURNS trigger
LANGUAGE plpgsql
AS $$
BEGIN
    IF TG_OP <> 'INSERT' THEN
        PERFORM fn_assert_subcontract_receipt_reservation_coverage(
            OLD.id);
    END IF;
    IF TG_OP <> 'DELETE' THEN
        PERFORM fn_assert_subcontract_receipt_reservation_coverage(
            NEW.id);
    END IF;
    RETURN NULL;
END;
$$;

CREATE CONSTRAINT TRIGGER trg_subcontract_peg_supply_conservation
    AFTER INSERT OR UPDATE OR DELETE
    ON production_material_supply_pegs
    DEFERRABLE INITIALLY DEFERRED
    FOR EACH ROW EXECUTE FUNCTION
        fn_check_subcontract_supply_conservation();

CREATE CONSTRAINT TRIGGER trg_subcontract_transfer_conservation
    AFTER INSERT OR UPDATE OR DELETE
    ON production_material_subcontract_peg_transfers
    DEFERRABLE INITIALLY DEFERRED
    FOR EACH ROW EXECUTE FUNCTION
        fn_check_subcontract_supply_conservation();

CREATE CONSTRAINT TRIGGER
    trg_subcontract_receipt_allocation_conservation
    AFTER INSERT OR UPDATE OR DELETE
    ON production_material_subcontract_receipt_allocations
    DEFERRABLE INITIALLY DEFERRED
    FOR EACH ROW EXECUTE FUNCTION
        fn_check_subcontract_supply_conservation();

CREATE CONSTRAINT TRIGGER
    trg_subcontract_receipt_reservation_conservation
    AFTER INSERT OR UPDATE OR DELETE
    ON stock_reservations
    DEFERRABLE INITIALLY DEFERRED
    FOR EACH ROW EXECUTE FUNCTION
        fn_check_subcontract_receipt_reservation();

-- Changes to any receipt/DRAW provenance object must also revalidate active
-- subcontract allocations. This closes direct-SQL mutation paths, not only
-- writes through the allocation service.
CREATE OR REPLACE FUNCTION
    fn_check_subcontract_receipt_provenance_source()
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
            WHEN TG_TABLE_NAME IN (
                'stock_documents', 'stock_document_items',
                'subcontract_receipts', 'subcontract_receipt_items'
            ) THEN (to_jsonb(OLD) ->> 'id')::uuid
            WHEN TG_TABLE_NAME = 'plan_draw_links'
                THEN (to_jsonb(OLD) ->> 'draw_id')::uuid
            WHEN TG_TABLE_NAME =
                    'production_planning_package_documents'
                THEN (to_jsonb(OLD) ->> 'document_id')::uuid
            ELSE (to_jsonb(OLD) ->> 'document_item_id')::uuid
        END;
    END IF;
    IF TG_OP <> 'DELETE' THEN
        v_new_identity := CASE
            WHEN TG_TABLE_NAME IN (
                'stock_documents', 'stock_document_items',
                'subcontract_receipts', 'subcontract_receipt_items'
            ) THEN (to_jsonb(NEW) ->> 'id')::uuid
            WHEN TG_TABLE_NAME = 'plan_draw_links'
                THEN (to_jsonb(NEW) ->> 'draw_id')::uuid
            WHEN TG_TABLE_NAME =
                    'production_planning_package_documents'
                THEN (to_jsonb(NEW) ->> 'document_id')::uuid
            ELSE (to_jsonb(NEW) ->> 'document_item_id')::uuid
        END;
    END IF;

    IF TG_TABLE_NAME = 'subcontract_receipt_items' THEN
        IF v_old_identity IS NOT NULL THEN
            PERFORM fn_assert_subcontract_receipt_item_capacity(
                v_old_identity);
        END IF;
        IF v_new_identity IS NOT NULL
           AND v_new_identity IS DISTINCT FROM v_old_identity THEN
            PERFORM fn_assert_subcontract_receipt_item_capacity(
                v_new_identity);
        END IF;
    END IF;

    FOR v_allocation_id IN
        SELECT allocation.id
        FROM production_material_subcontract_receipt_allocations allocation
        WHERE allocation.status = 'EFFECTIVE'
          AND (
              (
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
              OR (
                  TG_TABLE_NAME = 'subcontract_receipts'
                  AND (
                      allocation.receipt_id = v_old_identity
                      OR allocation.receipt_id = v_new_identity
                  )
              )
              OR (
                  TG_TABLE_NAME = 'subcontract_receipt_items'
                  AND (
                      allocation.receipt_item_id = v_old_identity
                      OR allocation.receipt_item_id = v_new_identity
                  )
              )
          )
    LOOP
        PERFORM fn_assert_subcontract_receipt_allocation(
            v_allocation_id);
    END LOOP;
    RETURN NULL;
END;
$$;

CREATE CONSTRAINT TRIGGER
    trg_subcontract_receipt_header_provenance
    AFTER INSERT OR UPDATE OR DELETE ON subcontract_receipts
    DEFERRABLE INITIALLY DEFERRED
    FOR EACH ROW EXECUTE FUNCTION
        fn_check_subcontract_receipt_provenance_source();
CREATE CONSTRAINT TRIGGER
    trg_subcontract_receipt_item_provenance
    AFTER INSERT OR UPDATE OR DELETE ON subcontract_receipt_items
    DEFERRABLE INITIALLY DEFERRED
    FOR EACH ROW EXECUTE FUNCTION
        fn_check_subcontract_receipt_provenance_source();
CREATE CONSTRAINT TRIGGER trg_subcontract_draw_provenance
    AFTER INSERT OR UPDATE OR DELETE ON stock_documents
    DEFERRABLE INITIALLY DEFERRED
    FOR EACH ROW EXECUTE FUNCTION
        fn_check_subcontract_receipt_provenance_source();
CREATE CONSTRAINT TRIGGER trg_subcontract_draw_item_provenance
    AFTER INSERT OR UPDATE OR DELETE ON stock_document_items
    DEFERRABLE INITIALLY DEFERRED
    FOR EACH ROW EXECUTE FUNCTION
        fn_check_subcontract_receipt_provenance_source();
CREATE CONSTRAINT TRIGGER trg_subcontract_plan_draw_provenance
    AFTER INSERT OR UPDATE OR DELETE ON plan_draw_links
    DEFERRABLE INITIALLY DEFERRED
    FOR EACH ROW EXECUTE FUNCTION
        fn_check_subcontract_receipt_provenance_source();
CREATE CONSTRAINT TRIGGER trg_subcontract_package_draw_provenance
    AFTER INSERT OR UPDATE OR DELETE
    ON production_planning_package_documents
    DEFERRABLE INITIALLY DEFERRED
    FOR EACH ROW EXECUTE FUNCTION
        fn_check_subcontract_receipt_provenance_source();
CREATE CONSTRAINT TRIGGER
    trg_subcontract_package_draw_item_provenance
    AFTER INSERT OR UPDATE OR DELETE
    ON production_planning_package_document_items
    DEFERRABLE INITIALLY DEFERRED
    FOR EACH ROW EXECUTE FUNCTION
        fn_check_subcontract_receipt_provenance_source();

COMMENT ON FUNCTION fn_has_protected_production_supply_peg(TEXT, UUID)
    IS 'True once any production source peg exists; source history is immutable.';
COMMENT ON FUNCTION fn_guard_subcontract_production_mapping_lifecycle()
    IS 'V158 mapping rows are append-only and may only move EFFECTIVE to REVERSED.';
