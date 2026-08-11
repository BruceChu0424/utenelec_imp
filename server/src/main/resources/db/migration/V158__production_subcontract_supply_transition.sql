-- V158: exact subcontract supply transition for production material demand.
--
-- application peg -> order peg -> approved target-warehouse receipt
--                 -> complete-kit reservation + exact DRAW
--
-- Partial receipts remain physical stock only. A WAITING execution segment is
-- promoted atomically only when every material demand is coverable.

ALTER TABLE production_planning_package_documents
    DROP CONSTRAINT production_planning_package_document_type_chk,
    ADD CONSTRAINT production_planning_package_document_type_chk
        CHECK (document_type IN (
            'SUBPLAN', 'PURCHASE_REQUEST',
            'SUBCONTRACT_APPLICATION', 'DRAW'));

CREATE TABLE production_material_subcontract_peg_transfers (
    id                    UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    demand_id             UUID NOT NULL
        REFERENCES production_material_demands(id),
    from_peg_id           UUID NOT NULL
        REFERENCES production_material_supply_pegs(id),
    to_peg_id             UUID NOT NULL
        REFERENCES production_material_supply_pegs(id),
    application_item_id   UUID NOT NULL
        REFERENCES subcontract_application_items(id),
    order_item_id         UUID NOT NULL
        REFERENCES subcontract_order_items(id),
    transferred_qty       NUMERIC(18,4) NOT NULL,
    status                TEXT NOT NULL DEFAULT 'EFFECTIVE',
    idempotency_key       TEXT NOT NULL,
    created_at            TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_at            TIMESTAMPTZ NOT NULL DEFAULT now(),
    created_by            UUID,
    updated_by            UUID,
    CONSTRAINT production_material_subcontract_transfer_qty_chk
        CHECK (transferred_qty > 0),
    CONSTRAINT production_material_subcontract_transfer_status_chk
        CHECK (status IN ('EFFECTIVE', 'REVERSED')),
    CONSTRAINT production_material_subcontract_transfer_key_chk
        CHECK (length(btrim(idempotency_key)) BETWEEN 8 AND 128)
);

CREATE UNIQUE INDEX uq_production_material_subcontract_transfer_key
    ON production_material_subcontract_peg_transfers(idempotency_key);
CREATE UNIQUE INDEX uq_production_material_subcontract_transfer_active
    ON production_material_subcontract_peg_transfers(
        from_peg_id, order_item_id)
    WHERE status = 'EFFECTIVE';
CREATE UNIQUE INDEX uq_production_material_subcontract_transfer_target
    ON production_material_subcontract_peg_transfers(to_peg_id);
CREATE INDEX idx_production_material_subcontract_transfer_order
    ON production_material_subcontract_peg_transfers(
        order_item_id, status);

CREATE TABLE production_material_subcontract_receipt_allocations (
    id                    UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    receipt_id            UUID NOT NULL
        REFERENCES subcontract_receipts(id),
    receipt_item_id       UUID NOT NULL
        REFERENCES subcontract_receipt_items(id),
    package_id            UUID NOT NULL
        REFERENCES production_planning_packages(id),
    demand_id             UUID NOT NULL
        REFERENCES production_material_demands(id),
    order_peg_id          UUID NOT NULL
        REFERENCES production_material_supply_pegs(id),
    reservation_id        UUID NOT NULL
        REFERENCES stock_reservations(id),
    draw_id               UUID NOT NULL
        REFERENCES stock_documents(id),
    draw_item_id          UUID NOT NULL
        REFERENCES stock_document_items(id),
    allocated_qty         NUMERIC(18,4) NOT NULL,
    status                TEXT NOT NULL DEFAULT 'EFFECTIVE',
    idempotency_key       TEXT NOT NULL,
    created_at            TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_at            TIMESTAMPTZ NOT NULL DEFAULT now(),
    created_by            UUID,
    updated_by            UUID,
    CONSTRAINT production_material_subcontract_receipt_qty_chk
        CHECK (allocated_qty > 0),
    CONSTRAINT production_material_subcontract_receipt_status_chk
        CHECK (status IN ('EFFECTIVE', 'REVERSED')),
    CONSTRAINT production_material_subcontract_receipt_key_chk
        CHECK (length(btrim(idempotency_key)) BETWEEN 8 AND 128)
);

CREATE UNIQUE INDEX uq_production_material_subcontract_receipt_key
    ON production_material_subcontract_receipt_allocations(
        idempotency_key);
CREATE UNIQUE INDEX uq_production_material_subcontract_receipt_active
    ON production_material_subcontract_receipt_allocations(
        receipt_item_id, order_peg_id)
    WHERE status = 'EFFECTIVE';
CREATE INDEX idx_production_material_subcontract_receipt_receipt
    ON production_material_subcontract_receipt_allocations(
        receipt_id, status);
CREATE INDEX idx_production_material_subcontract_receipt_draw
    ON production_material_subcontract_receipt_allocations(
        draw_id, status);

CREATE TRIGGER trg_audit_production_material_subcontract_transfers
    AFTER INSERT OR UPDATE OR DELETE
    ON production_material_subcontract_peg_transfers
    FOR EACH ROW EXECUTE FUNCTION fn_audit();
CREATE TRIGGER trg_audit_production_material_subcontract_receipts
    AFTER INSERT OR UPDATE OR DELETE
    ON production_material_subcontract_receipt_allocations
    FOR EACH ROW EXECUTE FUNCTION fn_audit();

CREATE OR REPLACE FUNCTION fn_guard_subcontract_transfer_immutable()
RETURNS trigger
LANGUAGE plpgsql
AS $$
BEGIN
    IF NEW.demand_id IS DISTINCT FROM OLD.demand_id
       OR NEW.from_peg_id IS DISTINCT FROM OLD.from_peg_id
       OR NEW.to_peg_id IS DISTINCT FROM OLD.to_peg_id
       OR NEW.application_item_id
            IS DISTINCT FROM OLD.application_item_id
       OR NEW.order_item_id IS DISTINCT FROM OLD.order_item_id
       OR NEW.transferred_qty IS DISTINCT FROM OLD.transferred_qty
       OR NEW.idempotency_key IS DISTINCT FROM OLD.idempotency_key THEN
        RAISE EXCEPTION
            'subcontract supply transfer identity and quantity are immutable'
            USING ERRCODE = '23514',
                  CONSTRAINT =
                      'production_subcontract_transfer_immutable_guard';
    END IF;
    RETURN NEW;
END;
$$;

CREATE TRIGGER trg_guard_subcontract_transfer_immutable
    BEFORE UPDATE ON production_material_subcontract_peg_transfers
    FOR EACH ROW EXECUTE FUNCTION
        fn_guard_subcontract_transfer_immutable();

CREATE OR REPLACE FUNCTION fn_assert_subcontract_transfer(
    p_transfer_id UUID
) RETURNS void
LANGUAGE plpgsql
AS $$
BEGIN
    IF EXISTS (
        SELECT 1
        FROM production_material_subcontract_peg_transfers transfer
        JOIN production_material_supply_pegs source
          ON source.id = transfer.from_peg_id
        JOIN production_material_supply_pegs target
          ON target.id = transfer.to_peg_id
        JOIN subcontract_order_items order_item
          ON order_item.id = transfer.order_item_id
        WHERE transfer.id = p_transfer_id
          AND (
              source.supply_type <> 'SUBCONTRACT_APPLICATION_ITEM'
              OR source.supply_item_id <> transfer.application_item_id
              OR source.demand_id <> transfer.demand_id
              OR target.supply_type <> 'SUBCONTRACT_ORDER_ITEM'
              OR target.supply_item_id <> transfer.order_item_id
              OR target.demand_id <> transfer.demand_id
              OR target.allocated_qty <> transfer.transferred_qty
              OR order_item.application_item_id IS DISTINCT FROM
                    transfer.application_item_id
              OR (
                  transfer.status = 'EFFECTIVE'
                  AND target.status = 'REVERSED'
              )
              OR (
                  transfer.status = 'REVERSED'
                  AND (
                      target.status <> 'REVERSED'
                      OR target.consumed_qty <> 0
                      OR target.released_qty <> target.allocated_qty
                  )
              )
          )
    ) THEN
        RAISE EXCEPTION
            'subcontract supply transfer provenance is inconsistent'
            USING ERRCODE = '23514',
                  CONSTRAINT =
                      'production_subcontract_transfer_provenance_guard';
    END IF;
END;
$$;

CREATE OR REPLACE FUNCTION fn_check_subcontract_transfer()
RETURNS trigger
LANGUAGE plpgsql
AS $$
BEGIN
    PERFORM fn_assert_subcontract_transfer(COALESCE(NEW.id, OLD.id));
    RETURN NULL;
END;
$$;

CREATE CONSTRAINT TRIGGER trg_check_subcontract_transfer
    AFTER INSERT OR UPDATE
    ON production_material_subcontract_peg_transfers
    DEFERRABLE INITIALLY DEFERRED
    FOR EACH ROW EXECUTE FUNCTION fn_check_subcontract_transfer();

CREATE OR REPLACE FUNCTION
    fn_guard_subcontract_receipt_allocation_immutable()
RETURNS trigger
LANGUAGE plpgsql
AS $$
BEGIN
    IF NEW.receipt_id IS DISTINCT FROM OLD.receipt_id
       OR NEW.receipt_item_id IS DISTINCT FROM OLD.receipt_item_id
       OR NEW.package_id IS DISTINCT FROM OLD.package_id
       OR NEW.demand_id IS DISTINCT FROM OLD.demand_id
       OR NEW.order_peg_id IS DISTINCT FROM OLD.order_peg_id
       OR NEW.reservation_id IS DISTINCT FROM OLD.reservation_id
       OR NEW.draw_id IS DISTINCT FROM OLD.draw_id
       OR NEW.draw_item_id IS DISTINCT FROM OLD.draw_item_id
       OR NEW.allocated_qty IS DISTINCT FROM OLD.allocated_qty
       OR NEW.idempotency_key IS DISTINCT FROM OLD.idempotency_key THEN
        RAISE EXCEPTION
            'subcontract receipt allocation identity and quantity are immutable'
            USING ERRCODE = '23514',
                  CONSTRAINT =
                    'production_subcontract_receipt_allocation_immutable_guard';
    END IF;
    RETURN NEW;
END;
$$;

CREATE TRIGGER trg_guard_subcontract_receipt_allocation_immutable
    BEFORE UPDATE
    ON production_material_subcontract_receipt_allocations
    FOR EACH ROW EXECUTE FUNCTION
        fn_guard_subcontract_receipt_allocation_immutable();

CREATE OR REPLACE FUNCTION fn_assert_subcontract_receipt_allocation(
    p_allocation_id UUID
) RETURNS void
LANGUAGE plpgsql
AS $$
BEGIN
    IF EXISTS (
        SELECT 1
        FROM production_material_subcontract_receipt_allocations allocation
        JOIN subcontract_receipt_items receipt_item
          ON receipt_item.id = allocation.receipt_item_id
        JOIN production_material_supply_pegs peg
          ON peg.id = allocation.order_peg_id
        JOIN production_material_demands demand
          ON demand.id = allocation.demand_id
        JOIN stock_reservations reservation
          ON reservation.id = allocation.reservation_id
        JOIN stock_document_items draw_item
          ON draw_item.id = allocation.draw_item_id
        JOIN stock_documents draw
          ON draw.id = allocation.draw_id
        WHERE allocation.id = p_allocation_id
          AND (
              receipt_item.receipt_id <> allocation.receipt_id
              OR receipt_item.order_item_id IS DISTINCT FROM
                    peg.supply_item_id
              OR peg.supply_type <> 'SUBCONTRACT_ORDER_ITEM'
              OR peg.demand_id <> allocation.demand_id
              OR demand.package_id <> allocation.package_id
              OR reservation.demand_id <> allocation.demand_id
              OR reservation.owner_type <>
                    'PRODUCTION_MATERIAL_DEMAND'
              OR draw_item.doc_id <> allocation.draw_id
              OR draw.doc_type <> 'DRAW'
              OR draw_item.goods_id <> demand.goods_id
              OR draw_item.color_id IS DISTINCT FROM demand.color_id
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

CREATE OR REPLACE FUNCTION fn_check_subcontract_receipt_allocation()
RETURNS trigger
LANGUAGE plpgsql
AS $$
BEGIN
    PERFORM fn_assert_subcontract_receipt_allocation(
        COALESCE(NEW.id, OLD.id));
    RETURN NULL;
END;
$$;

CREATE CONSTRAINT TRIGGER trg_check_subcontract_receipt_allocation
    AFTER INSERT OR UPDATE
    ON production_material_subcontract_receipt_allocations
    DEFERRABLE INITIALLY DEFERRED
    FOR EACH ROW EXECUTE FUNCTION
        fn_check_subcontract_receipt_allocation();

CREATE OR REPLACE FUNCTION fn_guard_subcontract_order_reversal()
RETURNS trigger
LANGUAGE plpgsql
AS $$
BEGIN
    IF OLD.status = 1 AND NEW.status = -1
       AND EXISTS (
           SELECT 1
           FROM subcontract_order_items item
           JOIN production_material_subcontract_peg_transfers transfer
             ON transfer.order_item_id = item.id
            AND transfer.status = 'EFFECTIVE'
           WHERE item.order_id = OLD.id
       ) THEN
        RAISE EXCEPTION
            'subcontract order production supply must be unwound first'
            USING ERRCODE = '23514',
                  CONSTRAINT =
                      'production_subcontract_order_reversal_guard';
    END IF;
    RETURN NEW;
END;
$$;

CREATE TRIGGER trg_guard_subcontract_order_reversal
    BEFORE UPDATE OF status ON subcontract_orders
    FOR EACH ROW EXECUTE FUNCTION
        fn_guard_subcontract_order_reversal();

CREATE OR REPLACE FUNCTION fn_guard_subcontract_receipt_reversal()
RETURNS trigger
LANGUAGE plpgsql
AS $$
BEGIN
    IF OLD.status = 1 AND NEW.status = -1
       AND EXISTS (
           SELECT 1
           FROM production_material_subcontract_receipt_allocations allocation
           WHERE allocation.receipt_id = OLD.id
             AND allocation.status = 'EFFECTIVE'
       ) THEN
        RAISE EXCEPTION
            'subcontract receipt production allocation must be unwound first'
            USING ERRCODE = '23514',
                  CONSTRAINT =
                      'production_subcontract_receipt_reversal_guard';
    END IF;
    RETURN NEW;
END;
$$;

CREATE TRIGGER trg_guard_subcontract_receipt_reversal
    BEFORE UPDATE OF status ON subcontract_receipts
    FOR EACH ROW EXECUTE FUNCTION
        fn_guard_subcontract_receipt_reversal();

-- Actionable subcontract stages. The latest real linked document wins; no
-- goods-only inference is used.
CREATE OR REPLACE VIEW v_fulfillment_workbench_actions AS
SELECT w.department,
       w.task_id,
       w.package_id,
       w.plan_id,
       w.plan_no,
       w.source_doc_type,
       w.source_item_id,
       w.warehouse_id,
       w.warehouse_name,
       w.goods_id,
       w.goods_code,
       w.goods_name,
       w.spec,
       w.color_id,
       w.color_name,
       w.unit_id,
       w.unit_name,
       w.supply_route,
       w.required_qty,
       w.allocated_qty,
       w.fulfilled_qty,
       w.supply_pegged_qty,
       w.open_qty,
       CASE
           WHEN w.department <> 'SUBCONTRACT' THEN w.task_status
           WHEN w.task_status = 'COVERED' THEN 'COVERED'
           WHEN action.document_type = 'SUBCONTRACT_APPLICATION'
                AND action.document_status = '0'
               THEN 'APPLICATION_PENDING_APPROVAL'
           WHEN action.document_type = 'SUBCONTRACT_APPLICATION'
                AND action.document_status = '1'
               THEN 'WAITING_ORDER'
           WHEN action.document_type = 'SUBCONTRACT_ORDER'
                AND action.document_status = '0'
               THEN 'ORDER_PENDING_APPROVAL'
           WHEN action.document_type = 'SUBCONTRACT_RECEIPT'
                AND action.document_status = '0'
               THEN 'RECEIPT_PENDING_APPROVAL'
           WHEN action.document_type IN (
                    'SUBCONTRACT_ORDER', 'SUBCONTRACT_RECEIPT')
                AND action.document_status = '1'
               THEN 'WAITING_RETURN'
           ELSE w.task_status
       END::text AS task_status,
       w.need_date,
       w.expected_date,
       w.exception_code,
       w.updated_at,
       action.document_type AS action_doc_type,
       action.document_id AS action_doc_id,
       action.document_no AS action_doc_no,
       action.action_item_id,
       action.document_status AS action_doc_status
FROM v_fulfillment_workbench w
LEFT JOIN LATERAL (
    SELECT 'DRAW'::text AS document_type,
           pd.document_id,
           pd.document_no,
           di.document_item_id AS action_item_id,
           sd.status::text AS document_status,
           pd.created_at,
           100 AS stage_rank
    FROM production_planning_package_document_items di
    JOIN production_planning_package_documents pd
      ON pd.package_id = di.package_id
     AND pd.document_type = di.document_type
     AND pd.document_id = di.document_id
    JOIN stock_documents sd
      ON sd.id = pd.document_id
     AND sd.is_deleted = FALSE
     AND sd.status <> -1
    JOIN stock_document_items sdi
      ON sdi.id = di.document_item_id
     AND sdi.is_deleted = FALSE
    WHERE w.department = 'WAREHOUSE'
      AND di.package_id = w.package_id
      AND di.demand_id = w.task_id
      AND di.document_type = 'DRAW'

    UNION ALL

    SELECT 'PURCHASE_RECEIPT'::text,
           receipt.id,
           receipt.bill_no,
           receipt_item.id,
           receipt.status::text,
           receipt.created_at,
           30
    FROM production_material_supply_pegs request_peg
    JOIN purchase_request_items request_item
      ON request_item.id = request_peg.supply_item_id
     AND request_item.is_deleted = FALSE
    JOIN purchase_order_items order_item
      ON order_item.request_item_id = request_item.id
     AND order_item.is_deleted = FALSE
    JOIN purchase_orders purchase_order
      ON purchase_order.id = order_item.order_id
     AND purchase_order.is_deleted = FALSE
     AND purchase_order.status <> -1
    JOIN purchase_receipt_items receipt_item
      ON receipt_item.order_item_id = order_item.id
     AND receipt_item.is_deleted = FALSE
    JOIN purchase_receipts receipt
      ON receipt.id = receipt_item.receipt_id
     AND receipt.is_deleted = FALSE
     AND receipt.status <> -1
    WHERE w.department = 'PURCHASE'
      AND request_peg.demand_id = w.task_id
      AND request_peg.supply_type = 'PURCHASE_REQUEST_ITEM'
      AND request_peg.status <> 'REVERSED'

    UNION ALL

    SELECT 'PURCHASE_ORDER'::text,
           purchase_order.id,
           purchase_order.bill_no,
           order_item.id,
           purchase_order.status::text,
           purchase_order.created_at,
           20
    FROM production_material_supply_pegs request_peg
    JOIN purchase_request_items request_item
      ON request_item.id = request_peg.supply_item_id
     AND request_item.is_deleted = FALSE
    JOIN purchase_order_items order_item
      ON order_item.request_item_id = request_item.id
     AND order_item.is_deleted = FALSE
    JOIN purchase_orders purchase_order
      ON purchase_order.id = order_item.order_id
     AND purchase_order.is_deleted = FALSE
     AND purchase_order.status <> -1
    WHERE w.department = 'PURCHASE'
      AND request_peg.demand_id = w.task_id
      AND request_peg.supply_type = 'PURCHASE_REQUEST_ITEM'
      AND request_peg.status <> 'REVERSED'

    UNION ALL

    SELECT 'PURCHASE_REQUEST'::text,
           pd.document_id,
           pd.document_no,
           peg.supply_item_id,
           pr.status::text,
           pd.created_at,
           10
    FROM production_planning_package_documents pd
    JOIN purchase_requests pr
      ON pr.id = pd.document_id
     AND pr.is_deleted = FALSE
     AND pr.status <> -1
    JOIN production_material_supply_pegs peg
      ON peg.demand_id = w.task_id
     AND peg.supply_type = 'PURCHASE_REQUEST_ITEM'
     AND peg.status <> 'REVERSED'
    WHERE w.department = 'PURCHASE'
      AND pd.package_id = w.package_id
      AND pd.document_type = 'PURCHASE_REQUEST'

    UNION ALL

    SELECT 'SUBCONTRACT_RECEIPT'::text,
           receipt.id,
           receipt.bill_no,
           receipt_item.id,
           receipt.status::text,
           receipt.created_at,
           30
    FROM production_material_supply_pegs application_peg
    JOIN subcontract_application_items application_item
      ON application_item.id = application_peg.supply_item_id
     AND application_item.is_deleted = FALSE
    JOIN subcontract_order_items order_item
      ON order_item.application_item_id = application_item.id
     AND order_item.is_deleted = FALSE
    JOIN subcontract_orders subcontract_order
      ON subcontract_order.id = order_item.order_id
     AND subcontract_order.is_deleted = FALSE
     AND subcontract_order.status <> -1
    JOIN subcontract_receipt_items receipt_item
      ON receipt_item.order_item_id = order_item.id
     AND receipt_item.is_deleted = FALSE
    JOIN subcontract_receipts receipt
      ON receipt.id = receipt_item.receipt_id
     AND receipt.is_deleted = FALSE
     AND receipt.status <> -1
    WHERE w.department = 'SUBCONTRACT'
      AND application_peg.demand_id = w.task_id
      AND application_peg.supply_type =
            'SUBCONTRACT_APPLICATION_ITEM'
      AND application_peg.status <> 'REVERSED'

    UNION ALL

    SELECT 'SUBCONTRACT_ORDER'::text,
           subcontract_order.id,
           subcontract_order.bill_no,
           order_item.id,
           subcontract_order.status::text,
           subcontract_order.created_at,
           20
    FROM production_material_supply_pegs application_peg
    JOIN subcontract_application_items application_item
      ON application_item.id = application_peg.supply_item_id
     AND application_item.is_deleted = FALSE
    JOIN subcontract_order_items order_item
      ON order_item.application_item_id = application_item.id
     AND order_item.is_deleted = FALSE
    JOIN subcontract_orders subcontract_order
      ON subcontract_order.id = order_item.order_id
     AND subcontract_order.is_deleted = FALSE
     AND subcontract_order.status <> -1
    WHERE w.department = 'SUBCONTRACT'
      AND application_peg.demand_id = w.task_id
      AND application_peg.supply_type =
            'SUBCONTRACT_APPLICATION_ITEM'
      AND application_peg.status <> 'REVERSED'

    UNION ALL

    SELECT 'SUBCONTRACT_APPLICATION'::text,
           application.id,
           application.bill_no,
           application_item.id,
           application.status::text,
           application.created_at,
           10
    FROM production_material_supply_pegs application_peg
    JOIN subcontract_application_items application_item
      ON application_item.id = application_peg.supply_item_id
     AND application_item.is_deleted = FALSE
    JOIN subcontract_applications application
      ON application.id = application_item.application_id
     AND application.is_deleted = FALSE
     AND application.status <> -1
    WHERE w.department = 'SUBCONTRACT'
      AND application_peg.demand_id = w.task_id
      AND application_peg.supply_type =
            'SUBCONTRACT_APPLICATION_ITEM'
      AND application_peg.status <> 'REVERSED'

    ORDER BY stage_rank DESC, created_at DESC, document_id
    LIMIT 1
) action ON TRUE;

COMMENT ON TABLE production_material_subcontract_peg_transfers IS
    'Exact subcontract application-peg to order-peg migration.';
COMMENT ON TABLE production_material_subcontract_receipt_allocations IS
    'Exact subcontract receipt contribution to production kit reservation and DRAW.';
