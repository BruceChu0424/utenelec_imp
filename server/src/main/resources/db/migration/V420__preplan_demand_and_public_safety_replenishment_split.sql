-- V420: keep production-demand entitlement and public safety replenishment separate.
--
-- requested_qty remains the exact, analysis-owned demand slice.  A BUY action may
-- additionally carry one public safety-stock slice in the same purchase request.
-- The safety request item is deliberately not referenced by
-- preplan_supply_action_allocations, so IQC PASS cannot peg it to one analysis.

ALTER TABLE preplan_supply_actions
    ADD COLUMN safety_replenishment_qty NUMERIC(18,4) NOT NULL DEFAULT 0,
    ADD COLUMN safety_stock_snapshot_qty NUMERIC(18,4) NOT NULL DEFAULT 0,
    ADD COLUMN public_available_snapshot_qty NUMERIC(18,4) NOT NULL DEFAULT 0,
    ADD COLUMN open_safety_supply_snapshot_qty NUMERIC(18,4) NOT NULL DEFAULT 0,
    ADD COLUMN safety_external_item_id UUID;

ALTER TABLE preplan_supply_actions
    DROP CONSTRAINT preplan_supply_action_qty_chk,
    ADD CONSTRAINT preplan_supply_action_qty_chk CHECK (
        requested_qty >= 0
        AND safety_replenishment_qty >= 0
        AND requested_qty + safety_replenishment_qty > 0
    ) NOT VALID,
    ADD CONSTRAINT preplan_supply_action_safety_snapshot_chk CHECK (
        safety_stock_snapshot_qty >= 0
        AND public_available_snapshot_qty >= 0
        AND open_safety_supply_snapshot_qty >= 0
        AND safety_replenishment_qty = GREATEST(
            safety_stock_snapshot_qty
                - public_available_snapshot_qty
                - open_safety_supply_snapshot_qty,
            0
        )
    ) NOT VALID,
    ADD CONSTRAINT preplan_supply_action_safety_route_chk CHECK (
        route = 'BUY'
        OR (
            safety_replenishment_qty = 0
            AND safety_stock_snapshot_qty = 0
            AND public_available_snapshot_qty = 0
            AND open_safety_supply_snapshot_qty = 0
            AND safety_external_item_id IS NULL
        )
    ) NOT VALID,
    ADD CONSTRAINT preplan_supply_action_safety_external_shape_chk CHECK (
        safety_replenishment_qty = 0
        AND safety_external_item_id IS NULL
        OR safety_replenishment_qty > 0
        AND (
            status = 'OPEN' AND safety_external_item_id IS NULL
            OR status IN ('CREATED','IN_PROGRESS','DONE','CANCELLED')
               AND safety_external_item_id IS NOT NULL
        )
    ) NOT VALID,
    ADD CONSTRAINT preplan_supply_action_safety_external_item_fk
        FOREIGN KEY (safety_external_item_id)
        REFERENCES purchase_request_items(id) ON DELETE RESTRICT
        NOT VALID;

ALTER TABLE preplan_supply_actions
    VALIDATE CONSTRAINT preplan_supply_action_qty_chk;
ALTER TABLE preplan_supply_actions
    VALIDATE CONSTRAINT preplan_supply_action_safety_snapshot_chk;
ALTER TABLE preplan_supply_actions
    VALIDATE CONSTRAINT preplan_supply_action_safety_route_chk;
ALTER TABLE preplan_supply_actions
    VALIDATE CONSTRAINT preplan_supply_action_safety_external_shape_chk;
ALTER TABLE preplan_supply_actions
    VALIDATE CONSTRAINT preplan_supply_action_safety_external_item_fk;

CREATE UNIQUE INDEX uq_preplan_supply_action_safety_external_item
    ON preplan_supply_actions(safety_external_item_id)
    WHERE safety_external_item_id IS NOT NULL;

CREATE INDEX idx_preplan_supply_action_open_safety_dimension
    ON preplan_supply_actions(
        warehouse_id, goods_id, color_id, status, id)
    WHERE route = 'BUY'
      AND safety_replenishment_qty > 0
      AND status <> 'CANCELLED';

CREATE OR REPLACE FUNCTION fn_guard_preplan_supply_action_safety_split()
RETURNS trigger
LANGUAGE plpgsql
AS $$
DECLARE
    v_item purchase_request_items%ROWTYPE;
    v_base_unit_id UUID;
BEGIN
    IF NEW.safety_replenishment_qty > 0 THEN
        SELECT goods.unit_id INTO v_base_unit_id
        FROM goods WHERE goods.id = NEW.goods_id;
        IF v_base_unit_id IS NULL
           OR NEW.unit_id IS DISTINCT FROM v_base_unit_id THEN
            RAISE EXCEPTION USING
                ERRCODE = '23514',
                MESSAGE = 'public safety replenishment must use the goods base unit',
                CONSTRAINT = 'preplan_supply_action_safety_base_unit_guard';
        END IF;
    END IF;
    IF TG_OP = 'UPDATE' THEN
        IF OLD.safety_replenishment_qty
                IS DISTINCT FROM NEW.safety_replenishment_qty
           OR OLD.safety_stock_snapshot_qty
                IS DISTINCT FROM NEW.safety_stock_snapshot_qty
           OR OLD.public_available_snapshot_qty
                IS DISTINCT FROM NEW.public_available_snapshot_qty
           OR OLD.open_safety_supply_snapshot_qty
                IS DISTINCT FROM NEW.open_safety_supply_snapshot_qty THEN
            RAISE EXCEPTION USING
                ERRCODE = '23514',
                MESSAGE = 'preplan safety replenishment quantity and basis are immutable',
                CONSTRAINT = 'preplan_supply_action_safety_identity_guard';
        END IF;
        IF OLD.safety_external_item_id IS NOT NULL
           AND NEW.safety_external_item_id
                IS DISTINCT FROM OLD.safety_external_item_id THEN
            RAISE EXCEPTION USING
                ERRCODE = '23514',
                MESSAGE = 'preplan safety replenishment purchase item is immutable',
                CONSTRAINT = 'preplan_supply_action_safety_external_guard';
        END IF;
        IF OLD.safety_external_item_id IS NULL
           AND NEW.safety_external_item_id IS NOT NULL
           AND NOT (
               OLD.status = 'OPEN'
               AND NEW.status = 'CREATED'
               AND NEW.route = 'BUY'
               AND NEW.external_document_type = 'PURCHASE_REQUEST'
               AND NEW.external_document_id IS NOT NULL
           ) THEN
            RAISE EXCEPTION USING
                ERRCODE = '23514',
                MESSAGE = 'safety purchase item may only be attached during BUY externalization',
                CONSTRAINT = 'preplan_supply_action_safety_external_guard';
        END IF;
    END IF;

    IF NEW.safety_external_item_id IS NOT NULL THEN
        SELECT * INTO v_item
        FROM purchase_request_items item
        WHERE item.id = NEW.safety_external_item_id;
        IF v_item.id IS NULL
           OR v_item.is_deleted
           OR v_item.request_id IS DISTINCT FROM NEW.external_document_id
           OR v_item.goods_id IS DISTINCT FROM NEW.goods_id
           OR v_item.color_id IS DISTINCT FROM NEW.color_id
           OR v_item.unit_id IS DISTINCT FROM NEW.unit_id
           OR COALESCE(v_item.unit_rate, 1) <> 1
           OR v_item.qty * COALESCE(v_item.unit_rate, 1)
                IS DISTINCT FROM NEW.safety_replenishment_qty
           OR EXISTS (
               SELECT 1
               FROM preplan_supply_action_allocations allocation
               WHERE allocation.external_item_id = NEW.safety_external_item_id
           ) THEN
            RAISE EXCEPTION USING
                ERRCODE = '23514',
                MESSAGE = 'public safety replenishment item must be a separate matching purchase-request line',
                CONSTRAINT = 'preplan_supply_action_safety_external_guard';
        END IF;
    END IF;
    RETURN NEW;
END;
$$;

CREATE TRIGGER trg_guard_preplan_supply_action_safety_split
    BEFORE INSERT OR UPDATE ON preplan_supply_actions
    FOR EACH ROW EXECUTE FUNCTION
        fn_guard_preplan_supply_action_safety_split();

-- One read model for lifecycle reconciliation and duplicate-supply prevention.
-- qualified_qty is already public stock for SAFETY because that request item has
-- no demand allocation.  future_qty contains only unordered, physically open,
-- or IQC-pending quantities; terminal FAIL does not masquerade as future supply.
CREATE VIEW v_preplan_buy_action_slice_progress AS
WITH slice_items AS (
    SELECT DISTINCT action.id AS action_id,
           'DEMAND'::TEXT AS slice_type,
           allocation.external_item_id AS request_item_id
    FROM preplan_supply_actions action
    JOIN preplan_supply_action_allocations allocation
      ON allocation.action_id = action.id
     AND allocation.external_item_id IS NOT NULL
    WHERE action.route = 'BUY'
    UNION ALL
    SELECT action.id, 'SAFETY', action.safety_external_item_id
    FROM preplan_supply_actions action
    WHERE action.route = 'BUY'
      AND action.safety_external_item_id IS NOT NULL
), request_progress AS (
    SELECT slice.action_id, slice.slice_type,
           COUNT(*)::BIGINT AS item_count,
           BOOL_AND(
               item.is_deleted = FALSE
               AND request.id IS NOT NULL
               AND request.is_deleted = FALSE
               AND request.status IN (0,1)
               AND COALESCE(request.is_stopped,FALSE) = FALSE
               AND request.id = action.external_document_id
           ) AS source_valid,
           SUM(GREATEST(
               COALESCE(item.qty,0) - COALESCE(item.ordered_qty,0), 0
           ) * COALESCE(item.unit_rate,1))::numeric AS unordered_qty
    FROM slice_items slice
    JOIN preplan_supply_actions action ON action.id = slice.action_id
    LEFT JOIN purchase_request_items item
      ON item.id = slice.request_item_id
    LEFT JOIN purchase_requests request
      ON request.id = item.request_id
    GROUP BY slice.action_id, slice.slice_type
), receipt_by_order_item AS (
    SELECT slice.action_id, slice.slice_type, order_item.id AS order_item_id,
           COALESCE(SUM(CASE
               WHEN receipt.id IS NULL THEN 0
               WHEN inspection.id IS NULL
               THEN receipt_item.qty * COALESCE(receipt_item.unit_rate,1)
               ELSE inspection.passed_base_qty
           END),0)::numeric AS passed_qty,
           COALESCE(SUM(CASE WHEN inspection.id IS NULL
               THEN 0 ELSE inspection.failed_base_qty END),0)::numeric AS failed_qty,
           COALESCE(SUM(CASE WHEN inspection.id IS NULL THEN 0 ELSE
               GREATEST(
                   inspection.received_base_qty
                       - inspection.passed_base_qty
                       - inspection.failed_base_qty,
                   0
               ) END),0)::numeric AS pending_qty
    FROM slice_items slice
    JOIN purchase_order_items order_item
      ON order_item.request_item_id = slice.request_item_id
     AND order_item.is_deleted = FALSE
    JOIN purchase_orders purchase_order
      ON purchase_order.id = order_item.order_id
     AND purchase_order.status = 1
     AND purchase_order.is_deleted = FALSE
    LEFT JOIN purchase_receipt_items receipt_item
      ON receipt_item.order_item_id = order_item.id
     AND receipt_item.is_deleted = FALSE
    LEFT JOIN purchase_receipts receipt
      ON receipt.id = receipt_item.receipt_id
     AND receipt.status = 1
     AND receipt.is_deleted = FALSE
    LEFT JOIN procurement_inspection_items inspection
      ON receipt.id IS NOT NULL
     AND inspection.receipt_type = 'PURCHASE'
     AND inspection.receipt_item_id = receipt_item.id
     AND inspection.status <> 'REVERSED'
    GROUP BY slice.action_id, slice.slice_type, order_item.id
), order_progress AS (
    SELECT slice.action_id, slice.slice_type,
           BOOL_OR(purchase_order.id IS NOT NULL) AS order_exists,
           COALESCE(SUM(CASE WHEN purchase_order.id IS NULL THEN 0 ELSE
               GREATEST(
                   COALESCE(order_item.qty,0)
                       - COALESCE(order_item.received_qty,0)
                       + COALESCE(order_item.returned_qty,0),
                   0
               ) * COALESCE(order_item.unit_rate,1)
           END),0)::numeric AS open_order_qty,
           COALESCE(SUM(GREATEST(
               COALESCE(receipt.passed_qty,0)
                   - COALESCE(order_item.returned_qty,0)
                       * COALESCE(order_item.unit_rate,1),
               0
           )),0)::numeric AS qualified_qty,
           COALESCE(SUM(COALESCE(receipt.failed_qty,0)),0)::numeric AS failed_qty,
           COALESCE(SUM(COALESCE(receipt.pending_qty,0)),0)::numeric AS pending_qty
    FROM slice_items slice
    LEFT JOIN purchase_order_items order_item
      ON order_item.request_item_id = slice.request_item_id
     AND order_item.is_deleted = FALSE
    LEFT JOIN purchase_orders purchase_order
      ON purchase_order.id = order_item.order_id
     AND purchase_order.status = 1
     AND purchase_order.is_deleted = FALSE
    LEFT JOIN receipt_by_order_item receipt
      ON receipt.action_id = slice.action_id
     AND receipt.slice_type = slice.slice_type
     AND receipt.order_item_id = order_item.id
    GROUP BY slice.action_id, slice.slice_type
), kind_progress AS (
    SELECT request.action_id, request.slice_type,
           request.item_count, request.source_valid,
           COALESCE(request.unordered_qty,0) AS unordered_qty,
           COALESCE(orders.order_exists,FALSE) AS order_exists,
           COALESCE(orders.open_order_qty,0) AS open_order_qty,
           COALESCE(orders.qualified_qty,0) AS qualified_qty,
           COALESCE(orders.failed_qty,0) AS failed_qty,
           COALESCE(orders.pending_qty,0) AS pending_qty
    FROM request_progress request
    LEFT JOIN order_progress orders
      ON orders.action_id = request.action_id
     AND orders.slice_type = request.slice_type
)
SELECT action.id AS action_id,
       action.requested_qty AS demand_requested_qty,
       action.safety_replenishment_qty AS safety_requested_qty,
       (action.requested_qty = 0 OR COALESCE(demand.item_count,0) > 0
          AND COALESCE(demand.source_valid,FALSE)) AS demand_source_valid,
       (action.safety_replenishment_qty = 0 OR COALESCE(safety.item_count,0) > 0
          AND COALESCE(safety.source_valid,FALSE)) AS safety_source_valid,
       COALESCE(demand.qualified_qty,0) AS demand_qualified_qty,
       COALESCE(safety.qualified_qty,0) AS safety_qualified_qty,
       COALESCE(demand.failed_qty,0) AS demand_failed_qty,
       COALESCE(safety.failed_qty,0) AS safety_failed_qty,
       COALESCE(demand.unordered_qty,0)
          + COALESCE(demand.open_order_qty,0)
          + COALESCE(demand.pending_qty,0) AS demand_future_qty,
       COALESCE(safety.unordered_qty,0)
          + COALESCE(safety.open_order_qty,0)
          + COALESCE(safety.pending_qty,0) AS safety_future_qty,
       COALESCE(demand.pending_qty,0) AS demand_pending_qty,
       COALESCE(safety.pending_qty,0) AS safety_pending_qty,
       COALESCE(demand.order_exists,FALSE) AS demand_order_exists,
       COALESCE(safety.order_exists,FALSE) AS safety_order_exists
FROM preplan_supply_actions action
LEFT JOIN kind_progress demand
  ON demand.action_id = action.id AND demand.slice_type = 'DEMAND'
LEFT JOIN kind_progress safety
  ON safety.action_id = action.id AND safety.slice_type = 'SAFETY'
WHERE action.route = 'BUY';

-- Extend V250 provenance protection so the public safety line and every order
-- derived from it are just as immutable as the exact-demand line.
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
    ) OR (
        p_supply_type = 'PURCHASE_REQUEST_ITEM'
        AND EXISTS (
            SELECT 1
            FROM preplan_supply_actions action
            LEFT JOIN preplan_supply_action_allocations allocation
              ON allocation.action_id = action.id
            WHERE action.route = 'BUY'
              AND (allocation.external_item_id = p_supply_item_id
                   OR action.safety_external_item_id = p_supply_item_id)
        )
    ) OR (
        p_supply_type = 'SUBCONTRACT_APPLICATION_ITEM'
        AND EXISTS (
            SELECT 1
            FROM preplan_supply_action_allocations allocation
            JOIN preplan_supply_actions action
              ON action.id = allocation.action_id
             AND action.route = 'SUBCONTRACT'
            WHERE allocation.external_item_id = p_supply_item_id
        )
    ) OR (
        p_supply_type = 'PURCHASE_ORDER_ITEM'
        AND EXISTS (
            SELECT 1
            FROM purchase_order_items order_item
            JOIN purchase_orders order_header
              ON order_header.id = order_item.order_id
            JOIN preplan_supply_actions action
              ON action.route = 'BUY'
            LEFT JOIN preplan_supply_action_allocations allocation
              ON allocation.action_id = action.id
             AND allocation.external_item_id = order_item.request_item_id
            WHERE order_item.id = p_supply_item_id
              AND (allocation.id IS NOT NULL
                   OR action.safety_external_item_id = order_item.request_item_id)
              AND (order_header.status <> 0
                   OR action.status IN ('IN_PROGRESS','DONE','CANCELLED'))
        )
    ) OR (
        p_supply_type = 'SUBCONTRACT_ORDER_ITEM'
        AND EXISTS (
            SELECT 1
            FROM subcontract_order_items order_item
            JOIN subcontract_orders order_header
              ON order_header.id = order_item.order_id
            JOIN preplan_supply_action_allocations allocation
              ON allocation.external_item_id = order_item.application_item_id
            JOIN preplan_supply_actions action
              ON action.id = allocation.action_id
             AND action.route = 'SUBCONTRACT'
            WHERE order_item.id = p_supply_item_id
              AND (order_header.status <> 0
                   OR action.status IN ('IN_PROGRESS','DONE','CANCELLED'))
        )
    );
$$;

CREATE OR REPLACE FUNCTION fn_has_protected_preplan_order_context(
    p_supply_type text,
    p_order_id uuid,
    p_upstream_item_id uuid
) RETURNS boolean
LANGUAGE sql
STABLE
AS $$
    SELECT CASE
        WHEN p_supply_type = 'PURCHASE_ORDER_ITEM' THEN EXISTS (
            SELECT 1
            FROM preplan_supply_actions action
            LEFT JOIN preplan_supply_action_allocations allocation
              ON allocation.action_id = action.id
             AND allocation.external_item_id = p_upstream_item_id
            WHERE action.route = 'BUY'
              AND (allocation.id IS NOT NULL
                   OR action.safety_external_item_id = p_upstream_item_id)
              AND (
                  action.status IN ('IN_PROGRESS','DONE','CANCELLED')
                  OR NOT EXISTS (
                      SELECT 1 FROM purchase_orders order_header
                      WHERE order_header.id = p_order_id
                  )
                  OR EXISTS (
                      SELECT 1 FROM purchase_orders order_header
                      WHERE order_header.id = p_order_id
                        AND order_header.status <> 0
                  )
              )
        )
        WHEN p_supply_type = 'SUBCONTRACT_ORDER_ITEM' THEN EXISTS (
            SELECT 1
            FROM preplan_supply_action_allocations allocation
            JOIN preplan_supply_actions action
              ON action.id = allocation.action_id
             AND action.route = 'SUBCONTRACT'
            WHERE allocation.external_item_id = p_upstream_item_id
              AND (
                  action.status IN ('IN_PROGRESS','DONE','CANCELLED')
                  OR NOT EXISTS (
                      SELECT 1 FROM subcontract_orders order_header
                      WHERE order_header.id = p_order_id
                  )
                  OR EXISTS (
                      SELECT 1 FROM subcontract_orders order_header
                      WHERE order_header.id = p_order_id
                        AND order_header.status <> 0
                  )
              )
        )
        ELSE FALSE
    END;
$$;

COMMENT ON COLUMN preplan_supply_actions.requested_qty IS
    'Exact production-demand slice; may be zero only when the same BUY action carries a confirmed public safety replenishment slice';
COMMENT ON COLUMN preplan_supply_actions.safety_replenishment_qty IS
    'Explicitly confirmed public safety-stock replenishment in the same purchase request; never exact-pegged to this analysis';
COMMENT ON COLUMN preplan_supply_actions.safety_external_item_id IS
    'Separate purchase-request item for the public safety slice; intentionally absent from preplan_supply_action_allocations';
COMMENT ON VIEW v_preplan_buy_action_slice_progress IS
    'Demand-exact and public-safety purchase progress kept separate across request, order, receipt and IQC';
