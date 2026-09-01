-- V446: IQC release and warehouse stock-in are separate business facts.
--
-- Before this migration, a quality PASS wrote usable inventory immediately and
-- advanced production supply.  From V446 onward PASS only releases a frozen
-- slice to the warehouse queue.  A warehouse user must confirm the immutable
-- PASS slice and its physical place before stock_balances can increase.
--
-- Existing PASS rows were already posted by the old implementation.  The
-- backfill therefore marks them as warehouse-stocked without replaying stock.

ALTER TABLE procurement_inspection_items
    ADD COLUMN warehouse_stocked_base_qty NUMERIC(18,4) NOT NULL DEFAULT 0,
    ADD COLUMN warehouse_stocked_amount_local NUMERIC(18,4) NOT NULL DEFAULT 0,
    ADD COLUMN warehouse_stocked_weight NUMERIC(18,4),
    ADD COLUMN legacy_stocked_base_qty NUMERIC(18,4) NOT NULL DEFAULT 0,
    ADD COLUMN legacy_stocked_amount_local NUMERIC(18,4) NOT NULL DEFAULT 0,
    ADD COLUMN legacy_stocked_weight NUMERIC(18,4);

DO $$
DECLARE
    mismatch_count INTEGER;
BEGIN
    SELECT count(*)
    INTO mismatch_count
    FROM procurement_inspection_items inspection
    WHERE inspection.status <> 'REVERSED'
      AND inspection.passed_base_qty > 0
      AND (
       COALESCE((
          SELECT SUM(movement.qty)
          FROM stock_movements movement
          WHERE movement.source_doc_type = inspection.receipt_type || '_RECEIPT'
            AND movement.source_doc_id = inspection.receipt_id
            AND movement.source_item_id = inspection.id
            AND movement.direction = 1
       ), 0) IS DISTINCT FROM inspection.passed_base_qty
       OR EXISTS (
           SELECT 1
           FROM stock_movements movement
           WHERE movement.source_doc_type = inspection.receipt_type || '_RECEIPT'
             AND movement.source_doc_id = inspection.receipt_id
             AND movement.source_item_id = inspection.id
             AND movement.direction = 1
             AND movement.weight IS NOT NULL
             AND movement.actual_weight_unit_id
                 IS DISTINCT FROM inspection.received_weight_unit_id
       )
      );

    IF mismatch_count <> 0 THEN
        RAISE EXCEPTION
            'V446 cannot prove legacy IQC PASS stock postings for % active item(s)',
            mismatch_count;
    END IF;
END;
$$;

UPDATE procurement_inspection_items inspection
SET warehouse_stocked_base_qty = inspection.passed_base_qty,
    warehouse_stocked_amount_local = CASE
        WHEN inspection.passed_base_qty = 0 THEN 0
        ELSE COALESCE((
            SELECT SUM(COALESCE(movement.amount_local, 0))
            FROM stock_movements movement
            WHERE movement.source_doc_type = inspection.receipt_type || '_RECEIPT'
              AND movement.source_doc_id = inspection.receipt_id
              AND movement.source_item_id = inspection.id
              AND movement.direction = 1
        ), ROUND(
            inspection.received_amount_local
                * inspection.passed_base_qty
                / inspection.received_base_qty,
            4))
    END,
    warehouse_stocked_weight = (
        SELECT SUM(movement.weight)
        FROM stock_movements movement
        WHERE movement.source_doc_type = inspection.receipt_type || '_RECEIPT'
          AND movement.source_doc_id = inspection.receipt_id
          AND movement.source_item_id = inspection.id
          AND movement.direction = 1
          AND movement.weight IS NOT NULL
    ),
    legacy_stocked_base_qty = inspection.passed_base_qty,
    legacy_stocked_amount_local = CASE
        WHEN inspection.passed_base_qty = 0 THEN 0
        ELSE COALESCE((
            SELECT SUM(COALESCE(movement.amount_local, 0))
            FROM stock_movements movement
            WHERE movement.source_doc_type = inspection.receipt_type || '_RECEIPT'
              AND movement.source_doc_id = inspection.receipt_id
              AND movement.source_item_id = inspection.id
              AND movement.direction = 1
        ), ROUND(
            inspection.received_amount_local
                * inspection.passed_base_qty
                / inspection.received_base_qty,
            4))
    END,
    legacy_stocked_weight = (
        SELECT SUM(movement.weight)
        FROM stock_movements movement
        WHERE movement.source_doc_type = inspection.receipt_type || '_RECEIPT'
          AND movement.source_doc_id = inspection.receipt_id
          AND movement.source_item_id = inspection.id
          AND movement.direction = 1
          AND movement.weight IS NOT NULL
    )
WHERE inspection.status <> 'REVERSED'
  AND inspection.passed_base_qty > 0;

ALTER TABLE procurement_inspection_items
    ADD CONSTRAINT procurement_inspection_items_stocked_qty_chk CHECK (
        warehouse_stocked_base_qty >= 0
        AND warehouse_stocked_base_qty <= passed_base_qty
    ) NOT VALID,
    ADD CONSTRAINT procurement_inspection_items_stocked_amount_chk CHECK (
        warehouse_stocked_amount_local >= 0
        AND (
            warehouse_stocked_base_qty > 0
            OR warehouse_stocked_amount_local = 0
        )
    ) NOT VALID,
    ADD CONSTRAINT procurement_inspection_items_stocked_weight_chk CHECK (
        (warehouse_stocked_weight IS NULL OR warehouse_stocked_weight >= 0)
        AND (
            warehouse_stocked_base_qty > 0
            OR COALESCE(warehouse_stocked_weight, 0) = 0
        )
    ) NOT VALID,
    ADD CONSTRAINT procurement_inspection_items_legacy_stocked_chk CHECK (
        legacy_stocked_base_qty >= 0
        AND legacy_stocked_amount_local >= 0
        AND (legacy_stocked_weight IS NULL OR legacy_stocked_weight >= 0)
        AND (
            legacy_stocked_base_qty > 0
            OR (
                legacy_stocked_amount_local = 0
                AND COALESCE(legacy_stocked_weight, 0) = 0
            )
        )
    ) NOT VALID;

ALTER TABLE procurement_inspection_items
    VALIDATE CONSTRAINT procurement_inspection_items_stocked_qty_chk;
ALTER TABLE procurement_inspection_items
    VALIDATE CONSTRAINT procurement_inspection_items_stocked_amount_chk;
ALTER TABLE procurement_inspection_items
    VALIDATE CONSTRAINT procurement_inspection_items_stocked_weight_chk;
ALTER TABLE procurement_inspection_items
    VALIDATE CONSTRAINT procurement_inspection_items_legacy_stocked_chk;

-- V420 treated a quality PASS as qualified stock.  Preserve the view contract
-- but move its physical authority to warehouse confirmation.  A PASS slice
-- waiting for warehouse remains future supply, so it cannot complete an action
-- early and also cannot trigger a duplicate purchase.
CREATE OR REPLACE VIEW v_preplan_buy_action_slice_progress AS
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
               WHEN inspection.status = 'REVERSED' THEN 0
               ELSE inspection.warehouse_stocked_base_qty
           END),0)::numeric AS passed_qty,
           COALESCE(SUM(CASE
               WHEN inspection.id IS NULL OR inspection.status = 'REVERSED'
               THEN 0 ELSE inspection.failed_base_qty
           END),0)::numeric AS failed_qty,
           COALESCE(SUM(CASE
               WHEN inspection.id IS NULL OR inspection.status = 'REVERSED'
               THEN 0
               ELSE GREATEST(
                   inspection.received_base_qty
                       - inspection.failed_base_qty
                       - inspection.warehouse_stocked_base_qty,
                   0
               )
           END),0)::numeric AS pending_qty
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

CREATE INDEX idx_procurement_inspection_items_pending_stock_in
    ON procurement_inspection_items(
        warehouse_id, received_at, receipt_type, receipt_id, id)
    WHERE status <> 'REVERSED'
      AND passed_base_qty > warehouse_stocked_base_qty;

-- New receipts use a truthful receipt-resolution marker.  Historical
-- PRODUCTION_WOKEN events remain valid evidence of the old implementation.
ALTER TABLE procurement_inspection_events
    DROP CONSTRAINT procurement_inspection_events_action_chk;
ALTER TABLE procurement_inspection_events
    ADD CONSTRAINT procurement_inspection_events_action_chk CHECK (
        action IN (
            'RECEIVED', 'PASS', 'FAIL', 'PRODUCTION_WOKEN',
            'RECEIPT_RESOLVED', 'RECEIPT_REVERSED'
        )
    ) NOT VALID;
ALTER TABLE procurement_inspection_events
    VALIDATE CONSTRAINT procurement_inspection_events_action_chk;

ALTER TABLE procurement_inspection_events
    DROP CONSTRAINT procurement_inspection_events_reason_chk;
ALTER TABLE procurement_inspection_events
    ADD CONSTRAINT procurement_inspection_events_reason_chk CHECK (
        action IN (
            'RECEIVED', 'PASS', 'PRODUCTION_WOKEN',
            'RECEIPT_RESOLVED', 'RECEIPT_REVERSED'
        )
        OR NULLIF(btrim(reason), '') IS NOT NULL
    ) NOT VALID;
ALTER TABLE procurement_inspection_events
    VALIDATE CONSTRAINT procurement_inspection_events_reason_chk;

-- Historical PASS events were already posted by the pre-V446 service.  Only
-- PASS events appended after cutover opt into the warehouse confirmation queue.
ALTER TABLE procurement_inspection_events
    ADD COLUMN requires_warehouse_stock_in BOOLEAN NOT NULL DEFAULT FALSE;
ALTER TABLE procurement_inspection_events
    ADD COLUMN released_amount_local NUMERIC(18,4),
    ADD COLUMN released_weight NUMERIC(18,4),
    ADD COLUMN released_weight_unit_id UUID;
ALTER TABLE procurement_inspection_events
    ADD CONSTRAINT procurement_inspection_events_released_weight_unit_fk
        FOREIGN KEY (released_weight_unit_id)
        REFERENCES units(id) ON DELETE RESTRICT NOT VALID;
ALTER TABLE procurement_inspection_events
    VALIDATE CONSTRAINT procurement_inspection_events_released_weight_unit_fk;
ALTER TABLE procurement_inspection_events
    ADD CONSTRAINT procurement_inspection_events_stock_in_flag_chk CHECK (
        (
            requires_warehouse_stock_in = FALSE
            AND released_amount_local IS NULL
            AND released_weight IS NULL
            AND released_weight_unit_id IS NULL
        )
        OR (
            requires_warehouse_stock_in = TRUE
            AND action = 'PASS'
            AND actor_employee_id IS NOT NULL
            AND released_amount_local IS NOT NULL
            AND released_amount_local >= 0
            AND (
                (released_weight IS NULL AND released_weight_unit_id IS NULL)
                OR (
                    released_weight IS NOT NULL
                    AND released_weight >= 0
                )
            )
        )
    ) NOT VALID;
ALTER TABLE procurement_inspection_events
    VALIDATE CONSTRAINT procurement_inspection_events_stock_in_flag_chk;

CREATE OR REPLACE FUNCTION fn_guard_procurement_iqc_stock_in_release_flag()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
BEGIN
    IF (NEW.action = 'PASS'
            AND NEW.requires_warehouse_stock_in IS DISTINCT FROM TRUE)
       OR (NEW.action <> 'PASS'
            AND NEW.requires_warehouse_stock_in IS DISTINCT FROM FALSE) THEN
        RAISE EXCEPTION
            'new IQC PASS events must explicitly require warehouse stock-in'
            USING ERRCODE = '23514',
                  CONSTRAINT = 'procurement_inspection_stock_in_release_flag_guard';
    END IF;
    IF NEW.action = 'PASS'
       AND NOT EXISTS (
           SELECT 1 FROM employees employee
           WHERE employee.id = NEW.actor_employee_id
       ) THEN
        RAISE EXCEPTION 'new IQC PASS event actor must reference an employee'
            USING ERRCODE = '23503',
                  CONSTRAINT = 'procurement_inspection_stock_in_actor_guard';
    END IF;
    RETURN NEW;
END;
$$;

CREATE TRIGGER trg_guard_procurement_iqc_stock_in_release_flag
    BEFORE INSERT ON procurement_inspection_events
    FOR EACH ROW EXECUTE FUNCTION fn_guard_procurement_iqc_stock_in_release_flag();
ALTER TABLE procurement_inspection_events
    ENABLE ALWAYS TRIGGER trg_guard_procurement_iqc_stock_in_release_flag;

CREATE OR REPLACE FUNCTION fn_validate_procurement_iqc_pass_release_value()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
DECLARE
    v_inspection procurement_inspection_items%ROWTYPE;
    v_pass_total NUMERIC(18,4);
    v_fail_total NUMERIC(18,4);
    v_resolved_before NUMERIC(18,4);
    v_expected_amount NUMERIC(18,4);
    v_expected_weight NUMERIC(18,4);
    v_expected_weight_unit_id UUID;
BEGIN
    IF NEW.requires_warehouse_stock_in IS DISTINCT FROM TRUE THEN
        RETURN NEW;
    END IF;

    SELECT * INTO v_inspection
    FROM procurement_inspection_items
    WHERE id = NEW.inspection_item_id;

    SELECT COALESCE(SUM(event.base_qty) FILTER (WHERE event.action = 'PASS'), 0),
           COALESCE(SUM(event.base_qty) FILTER (WHERE event.action = 'FAIL'), 0),
           COALESCE(SUM(event.base_qty) FILTER (
               WHERE event.action IN ('PASS', 'FAIL')
                 AND (event.occurred_at, event.id) < (NEW.occurred_at, NEW.id)
           ), 0)
    INTO v_pass_total, v_fail_total, v_resolved_before
    FROM procurement_inspection_events event
    WHERE event.inspection_item_id = NEW.inspection_item_id;

    v_expected_amount := ROUND(
        v_inspection.received_amount_local
            * (v_resolved_before + NEW.base_qty)
            / v_inspection.received_base_qty,
        4
    ) - ROUND(
        v_inspection.received_amount_local
            * v_resolved_before
            / v_inspection.received_base_qty,
        4
    );

    v_expected_weight := CASE
        WHEN v_inspection.received_weight IS NULL THEN NULL
        ELSE ROUND(
            v_inspection.received_weight
                * (v_resolved_before + NEW.base_qty)
                / v_inspection.received_base_qty,
            4
        ) - ROUND(
            v_inspection.received_weight
                * v_resolved_before
                / v_inspection.received_base_qty,
            4
        )
    END;

    v_expected_weight_unit_id := CASE
        WHEN v_expected_weight IS NULL THEN NULL
        ELSE v_inspection.received_weight_unit_id
    END;

    IF v_inspection.id IS NULL
       OR v_pass_total IS DISTINCT FROM v_inspection.passed_base_qty
       OR v_fail_total IS DISTINCT FROM v_inspection.failed_base_qty
       OR v_pass_total + v_fail_total > v_inspection.received_base_qty
       OR NEW.released_amount_local IS DISTINCT FROM v_expected_amount
       OR NEW.released_weight IS DISTINCT FROM v_expected_weight
       OR NEW.released_weight_unit_id
            IS DISTINCT FROM v_expected_weight_unit_id THEN
        RAISE EXCEPTION
            'IQC PASS release value must match the frozen receipt quantity, amount and weight sequence'
            USING ERRCODE = '23514',
                  CONSTRAINT = 'procurement_inspection_pass_release_value_chk';
    END IF;
    RETURN NEW;
END;
$$;

CREATE CONSTRAINT TRIGGER trg_validate_procurement_iqc_pass_release_value
    AFTER INSERT ON procurement_inspection_events
    DEFERRABLE INITIALLY DEFERRED
    FOR EACH ROW EXECUTE FUNCTION fn_validate_procurement_iqc_pass_release_value();

CREATE TABLE procurement_iqc_stock_in_batches (
    id                  UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    actor_user_id       UUID NOT NULL REFERENCES users(id) ON DELETE RESTRICT,
    actor_employee_id   UUID NOT NULL REFERENCES employees(id) ON DELETE RESTRICT,
    receipt_type        TEXT NOT NULL,
    receipt_id          UUID NOT NULL,
    idempotency_key     VARCHAR(128) NOT NULL,
    request_hash        CHAR(64) NOT NULL,
    confirmed_count     INTEGER NOT NULL,
    confirmed_at        TIMESTAMPTZ NOT NULL DEFAULT now(),
    CONSTRAINT procurement_iqc_stock_in_batch_type_chk CHECK (
        receipt_type IN ('PURCHASE', 'SUBCONTRACT')
    ),
    CONSTRAINT procurement_iqc_stock_in_batch_key_chk CHECK (
        idempotency_key = btrim(idempotency_key)
        AND length(idempotency_key) BETWEEN 8 AND 128
        AND idempotency_key ~ '^[A-Za-z0-9._:-]+$'
    ),
    CONSTRAINT procurement_iqc_stock_in_batch_hash_chk CHECK (
        request_hash ~ '^[0-9a-f]{64}$'
    ),
    CONSTRAINT procurement_iqc_stock_in_batch_count_chk CHECK (
        confirmed_count BETWEEN 1 AND 100
    ),
    CONSTRAINT procurement_iqc_stock_in_batch_actor_key_uk
        UNIQUE (actor_user_id, idempotency_key)
);

CREATE TABLE procurement_iqc_stock_in_batch_items (
    id                  UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    batch_id            UUID NOT NULL
        REFERENCES procurement_iqc_stock_in_batches(id) ON DELETE RESTRICT,
    position            INTEGER NOT NULL,
    inspection_item_id  UUID NOT NULL
        REFERENCES procurement_inspection_items(id) ON DELETE RESTRICT,
    pass_event_id       UUID NOT NULL
        REFERENCES procurement_inspection_events(id) ON DELETE RESTRICT,
    stock_movement_id   UUID NOT NULL UNIQUE
        REFERENCES stock_movements(id) ON DELETE RESTRICT,
    warehouse_id        UUID NOT NULL REFERENCES warehouses(id) ON DELETE RESTRICT,
    goods_id            UUID NOT NULL REFERENCES goods(id) ON DELETE RESTRICT,
    color_id            UUID REFERENCES colors(id) ON DELETE RESTRICT,
    expected_remaining_base_qty NUMERIC(18,4) NOT NULL,
    base_qty            NUMERIC(18,4) NOT NULL,
    amount_local        NUMERIC(18,4) NOT NULL,
    weight              NUMERIC(18,4),
    weight_unit_id      UUID REFERENCES units(id) ON DELETE RESTRICT,
    place_snapshot      VARCHAR(100) NOT NULL,
    created_at          TIMESTAMPTZ NOT NULL DEFAULT now(),
    CONSTRAINT procurement_iqc_stock_in_item_position_chk CHECK (
        position BETWEEN 1 AND 100
    ),
    CONSTRAINT procurement_iqc_stock_in_item_qty_chk CHECK (base_qty > 0),
    CONSTRAINT procurement_iqc_stock_in_item_expected_chk CHECK (
        expected_remaining_base_qty >= base_qty
    ),
    CONSTRAINT procurement_iqc_stock_in_item_amount_chk CHECK (amount_local >= 0),
    CONSTRAINT procurement_iqc_stock_in_item_weight_chk CHECK (
        (weight IS NULL AND weight_unit_id IS NULL)
        OR (weight IS NOT NULL AND weight >= 0)
    ),
    CONSTRAINT procurement_iqc_stock_in_item_place_chk CHECK (
        place_snapshot = btrim(place_snapshot)
        AND length(place_snapshot) BETWEEN 1 AND 100
    ),
    CONSTRAINT procurement_iqc_stock_in_item_batch_position_uk
        UNIQUE (batch_id, position),
    CONSTRAINT procurement_iqc_stock_in_item_batch_event_uk
        UNIQUE (batch_id, pass_event_id)
);

CREATE INDEX idx_procurement_iqc_stock_in_batch_receipt
    ON procurement_iqc_stock_in_batches(
        receipt_type, receipt_id, confirmed_at DESC, id DESC);
CREATE INDEX idx_procurement_iqc_stock_in_item_inspection
    ON procurement_iqc_stock_in_batch_items(inspection_item_id, created_at, id);
CREATE INDEX idx_procurement_iqc_stock_in_item_pass_event
    ON procurement_iqc_stock_in_batch_items(pass_event_id, created_at, id);

CREATE OR REPLACE FUNCTION fn_guard_procurement_iqc_stock_in_fact()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
BEGIN
    RAISE EXCEPTION 'procurement IQC warehouse stock-in facts are append-only'
        USING ERRCODE = '55000',
              CONSTRAINT = 'procurement_iqc_stock_in_append_only_guard';
END;
$$;

CREATE TRIGGER trg_guard_procurement_iqc_stock_in_batches
    BEFORE UPDATE OR DELETE ON procurement_iqc_stock_in_batches
    FOR EACH ROW EXECUTE FUNCTION fn_guard_procurement_iqc_stock_in_fact();
ALTER TABLE procurement_iqc_stock_in_batches
    ENABLE ALWAYS TRIGGER trg_guard_procurement_iqc_stock_in_batches;

CREATE TRIGGER trg_guard_procurement_iqc_stock_in_batch_items
    BEFORE UPDATE OR DELETE ON procurement_iqc_stock_in_batch_items
    FOR EACH ROW EXECUTE FUNCTION fn_guard_procurement_iqc_stock_in_fact();
ALTER TABLE procurement_iqc_stock_in_batch_items
    ENABLE ALWAYS TRIGGER trg_guard_procurement_iqc_stock_in_batch_items;

CREATE OR REPLACE FUNCTION fn_validate_procurement_iqc_stock_in_item()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
DECLARE
    v_batch procurement_iqc_stock_in_batches%ROWTYPE;
    v_event procurement_inspection_events%ROWTYPE;
    v_inspection procurement_inspection_items%ROWTYPE;
    v_movement stock_movements%ROWTYPE;
    v_confirmed NUMERIC(18,4);
    v_confirmed_amount NUMERIC(18,4);
    v_confirmed_weight NUMERIC(18,4);
    v_confirmed_has_weight BOOLEAN;
    v_expected_weight NUMERIC(18,4);
    v_event_confirmed NUMERIC(18,4);
    v_event_confirmed_amount NUMERIC(18,4);
    v_event_confirmed_weight NUMERIC(18,4);
    v_actor_employee_id UUID;
    v_actor_active BOOLEAN;
    v_batch_has_same_actor BOOLEAN;
BEGIN
    SELECT * INTO v_batch
    FROM procurement_iqc_stock_in_batches
    WHERE id = NEW.batch_id;

    SELECT user_account.employee_id,
           user_account.status = 'active' AND user_account.is_deleted = FALSE
    INTO v_actor_employee_id, v_actor_active
    FROM users user_account
    WHERE user_account.id = v_batch.actor_user_id;

    SELECT * INTO v_event
    FROM procurement_inspection_events
    WHERE id = NEW.pass_event_id;

    SELECT COALESCE(BOOL_OR(
               pass_event.actor_employee_id = v_batch.actor_employee_id), FALSE)
    INTO v_batch_has_same_actor
    FROM procurement_iqc_stock_in_batch_items batch_item
    JOIN procurement_inspection_events pass_event
      ON pass_event.id = batch_item.pass_event_id
    WHERE batch_item.batch_id = NEW.batch_id;

    SELECT * INTO v_inspection
    FROM procurement_inspection_items
    WHERE id = NEW.inspection_item_id;

    SELECT * INTO v_movement
    FROM stock_movements
    WHERE id = NEW.stock_movement_id;

    SELECT COALESCE(SUM(item.base_qty), 0),
           COALESCE(SUM(item.amount_local), 0),
           COALESCE(SUM(item.weight), 0),
           BOOL_OR(item.weight IS NOT NULL)
    INTO v_confirmed, v_confirmed_amount,
         v_confirmed_weight, v_confirmed_has_weight
    FROM procurement_iqc_stock_in_batch_items item
    WHERE item.inspection_item_id = NEW.inspection_item_id;

    v_expected_weight := CASE
        WHEN v_inspection.legacy_stocked_weight IS NULL
             AND COALESCE(v_confirmed_has_weight, FALSE) = FALSE
        THEN NULL
        ELSE COALESCE(v_inspection.legacy_stocked_weight, 0)
            + v_confirmed_weight
    END;

    SELECT COALESCE(SUM(item.base_qty), 0),
           COALESCE(SUM(item.amount_local), 0),
           COALESCE(SUM(item.weight), 0)
    INTO v_event_confirmed,
         v_event_confirmed_amount,
         v_event_confirmed_weight
    FROM procurement_iqc_stock_in_batch_items item
    WHERE item.pass_event_id = NEW.pass_event_id;

    IF v_batch.id IS NULL
       OR v_event.id IS NULL
       OR v_inspection.id IS NULL
       OR v_movement.id IS NULL
       OR v_event.action <> 'PASS'
       OR v_event.requires_warehouse_stock_in IS DISTINCT FROM TRUE
       OR v_event.base_qty <= 0
       OR NEW.expected_remaining_base_qty IS DISTINCT FROM
            v_event.base_qty - (v_event_confirmed - NEW.base_qty)
       OR v_event.released_amount_local IS NULL
       OR v_event_confirmed_amount IS DISTINCT FROM ROUND(
            v_event.released_amount_local * v_event_confirmed / v_event.base_qty,
            4)
       OR (
            v_event.released_weight IS NULL
            AND (NEW.weight IS NOT NULL OR NEW.weight_unit_id IS NOT NULL)
       )
       OR (
            v_event.released_weight IS NOT NULL
            AND (
                NEW.weight IS NULL
                OR NEW.weight_unit_id
                    IS DISTINCT FROM v_event.released_weight_unit_id
                OR v_event_confirmed_weight IS DISTINCT FROM ROUND(
                    v_event.released_weight
                        * v_event_confirmed / v_event.base_qty,
                    4)
            )
       )
       OR v_actor_active IS DISTINCT FROM TRUE
       OR v_actor_employee_id IS DISTINCT FROM v_batch.actor_employee_id
       OR v_batch_has_same_actor
       OR v_event.inspection_item_id <> NEW.inspection_item_id
       OR v_event_confirmed > v_event.base_qty
       OR v_batch.receipt_type <> v_inspection.receipt_type
       OR v_batch.receipt_id <> v_inspection.receipt_id
       OR v_inspection.status = 'REVERSED'
       OR v_inspection.warehouse_id <> NEW.warehouse_id
       OR v_inspection.goods_id <> NEW.goods_id
       OR v_inspection.color_id IS DISTINCT FROM NEW.color_id
       OR v_movement.source_doc_type
            <> v_batch.receipt_type || '_RECEIPT'
       OR v_movement.source_doc_id <> v_batch.receipt_id
       OR v_movement.source_item_id <> NEW.id
       OR v_movement.warehouse_id <> NEW.warehouse_id
       OR v_movement.goods_id <> NEW.goods_id
       OR v_movement.color_id IS DISTINCT FROM NEW.color_id
       OR v_movement.direction <> 1
       OR v_movement.qty IS DISTINCT FROM NEW.base_qty
       OR COALESCE(v_movement.amount_local, 0)
            IS DISTINCT FROM NEW.amount_local
       OR v_movement.weight IS DISTINCT FROM NEW.weight
       OR v_movement.actual_weight_unit_id IS DISTINCT FROM NEW.weight_unit_id
       OR v_inspection.warehouse_stocked_base_qty
            IS DISTINCT FROM v_inspection.legacy_stocked_base_qty + v_confirmed
       OR v_inspection.warehouse_stocked_amount_local
            IS DISTINCT FROM v_inspection.legacy_stocked_amount_local
                + v_confirmed_amount
       OR v_inspection.warehouse_stocked_weight
            IS DISTINCT FROM v_expected_weight THEN
        RAISE EXCEPTION 'invalid procurement IQC warehouse stock-in identity or quantity'
            USING ERRCODE = '23514',
                  CONSTRAINT = 'procurement_iqc_stock_in_item_identity_chk';
    END IF;
    RETURN NEW;
END;
$$;

CREATE CONSTRAINT TRIGGER trg_validate_procurement_iqc_stock_in_item
    AFTER INSERT ON procurement_iqc_stock_in_batch_items
    DEFERRABLE INITIALLY DEFERRED
    FOR EACH ROW EXECUTE FUNCTION fn_validate_procurement_iqc_stock_in_item();

CREATE OR REPLACE FUNCTION fn_validate_procurement_iqc_stock_in_batch_count()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
DECLARE
    v_count INTEGER;
BEGIN
    SELECT count(*)
    INTO v_count
    FROM procurement_iqc_stock_in_batch_items item
    WHERE item.batch_id = NEW.id;
    IF v_count <> NEW.confirmed_count THEN
        RAISE EXCEPTION 'IQC stock-in batch count does not match immutable items'
            USING ERRCODE = '23514',
                  CONSTRAINT = 'procurement_iqc_stock_in_batch_count_match_chk';
    END IF;
    RETURN NEW;
END;
$$;

CREATE CONSTRAINT TRIGGER trg_validate_procurement_iqc_stock_in_batch_count
    AFTER INSERT ON procurement_iqc_stock_in_batches
    DEFERRABLE INITIALLY DEFERRED
    FOR EACH ROW EXECUTE FUNCTION fn_validate_procurement_iqc_stock_in_batch_count();

CREATE OR REPLACE FUNCTION fn_validate_procurement_iqc_stock_in_item_count()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
DECLARE
    v_expected INTEGER;
    v_count INTEGER;
BEGIN
    SELECT batch.confirmed_count
    INTO v_expected
    FROM procurement_iqc_stock_in_batches batch
    WHERE batch.id = NEW.batch_id;

    SELECT count(*)
    INTO v_count
    FROM procurement_iqc_stock_in_batch_items item
    WHERE item.batch_id = NEW.batch_id;

    IF v_expected IS NULL OR v_count <> v_expected THEN
        RAISE EXCEPTION 'IQC stock-in batch item count does not match immutable header'
            USING ERRCODE = '23514',
                  CONSTRAINT = 'procurement_iqc_stock_in_batch_count_match_chk';
    END IF;
    RETURN NEW;
END;
$$;

CREATE CONSTRAINT TRIGGER trg_validate_procurement_iqc_stock_in_item_count
    AFTER INSERT ON procurement_iqc_stock_in_batch_items
    DEFERRABLE INITIALLY DEFERRED
    FOR EACH ROW EXECUTE FUNCTION fn_validate_procurement_iqc_stock_in_item_count();

CREATE OR REPLACE FUNCTION fn_validate_procurement_iqc_stocked_projection()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
DECLARE
    v_current procurement_inspection_items%ROWTYPE;
    v_base NUMERIC(18,4);
    v_amount NUMERIC(18,4);
    v_weight NUMERIC(18,4);
    v_has_weight BOOLEAN;
    v_expected_weight NUMERIC(18,4);
BEGIN
    -- Deferred row triggers execute against the transaction's final batch-item
    -- set. Re-read the current projection as well; an earlier UPDATE's NEW image
    -- would otherwise reject two PASS slices of one inspection confirmed together.
    SELECT * INTO v_current
    FROM procurement_inspection_items
    WHERE id = NEW.id;

    SELECT COALESCE(SUM(item.base_qty), 0),
           COALESCE(SUM(item.amount_local), 0),
           COALESCE(SUM(item.weight), 0),
           BOOL_OR(item.weight IS NOT NULL)
    INTO v_base, v_amount, v_weight, v_has_weight
    FROM procurement_iqc_stock_in_batch_items item
    WHERE item.inspection_item_id = NEW.id;

    v_expected_weight := CASE
        WHEN v_current.legacy_stocked_weight IS NULL
             AND COALESCE(v_has_weight, FALSE) = FALSE
        THEN NULL
        ELSE COALESCE(v_current.legacy_stocked_weight, 0) + v_weight
    END;

    IF v_current.status = 'REVERSED' THEN
        IF v_current.warehouse_stocked_base_qty <> 0
           OR v_current.warehouse_stocked_amount_local <> 0
           OR COALESCE(v_current.warehouse_stocked_weight, 0) <> 0 THEN
            RAISE EXCEPTION 'reversed IQC item cannot retain stocked projection'
                USING ERRCODE = '23514',
                      CONSTRAINT = 'procurement_iqc_stocked_projection_chk';
        END IF;
        RETURN NEW;
    END IF;

    IF v_current.warehouse_stocked_base_qty
            IS DISTINCT FROM v_current.legacy_stocked_base_qty + v_base
       OR v_current.warehouse_stocked_amount_local
            IS DISTINCT FROM v_current.legacy_stocked_amount_local + v_amount
       OR v_current.warehouse_stocked_weight IS DISTINCT FROM v_expected_weight THEN
        RAISE EXCEPTION 'IQC stocked projection must equal legacy baseline plus immutable warehouse facts'
            USING ERRCODE = '23514',
                  CONSTRAINT = 'procurement_iqc_stocked_projection_chk';
    END IF;
    RETURN NEW;
END;
$$;

CREATE CONSTRAINT TRIGGER trg_validate_procurement_iqc_stocked_projection
    AFTER UPDATE OF warehouse_stocked_base_qty,
                    warehouse_stocked_amount_local,
                    warehouse_stocked_weight,
                    status
    ON procurement_inspection_items
    DEFERRABLE INITIALLY DEFERRED
    FOR EACH ROW EXECUTE FUNCTION fn_validate_procurement_iqc_stocked_projection();

CREATE OR REPLACE FUNCTION fn_guard_procurement_iqc_legacy_baseline()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
BEGIN
    IF NEW.legacy_stocked_base_qty IS DISTINCT FROM OLD.legacy_stocked_base_qty
       OR NEW.legacy_stocked_amount_local
            IS DISTINCT FROM OLD.legacy_stocked_amount_local
       OR NEW.legacy_stocked_weight IS DISTINCT FROM OLD.legacy_stocked_weight THEN
        RAISE EXCEPTION 'legacy IQC stocked baseline is immutable'
            USING ERRCODE = '55000',
                  CONSTRAINT = 'procurement_iqc_legacy_baseline_guard';
    END IF;
    RETURN NEW;
END;
$$;

CREATE TRIGGER trg_guard_procurement_iqc_legacy_baseline
    BEFORE UPDATE OF legacy_stocked_base_qty,
                     legacy_stocked_amount_local,
                     legacy_stocked_weight
    ON procurement_inspection_items
    FOR EACH ROW EXECUTE FUNCTION fn_guard_procurement_iqc_legacy_baseline();
ALTER TABLE procurement_inspection_items
    ENABLE ALWAYS TRIGGER trg_guard_procurement_iqc_legacy_baseline;

CREATE OR REPLACE FUNCTION fn_guard_procurement_iqc_linked_movement()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
BEGIN
    IF EXISTS (
        SELECT 1
        FROM procurement_iqc_stock_in_batch_items item
        WHERE item.stock_movement_id = OLD.id
    ) THEN
        RAISE EXCEPTION 'IQC warehouse stock-in movement is append-only'
            USING ERRCODE = '55000',
                  CONSTRAINT = 'procurement_iqc_stock_in_movement_guard';
    END IF;
    IF TG_OP = 'DELETE' THEN
        RETURN OLD;
    END IF;
    RETURN NEW;
END;
$$;

CREATE TRIGGER trg_guard_procurement_iqc_linked_movement
    BEFORE UPDATE OR DELETE ON stock_movements
    FOR EACH ROW EXECUTE FUNCTION fn_guard_procurement_iqc_linked_movement();
ALTER TABLE stock_movements
    ENABLE ALWAYS TRIGGER trg_guard_procurement_iqc_linked_movement;

-- Fail closed if a pre-V446 application instance remains online after cutover.
-- The legacy PASS path used inspection.id as stock_movements.source_item_id;
-- the new warehouse path uses the immutable stock-in batch item UUID instead.
CREATE OR REPLACE FUNCTION fn_guard_legacy_procurement_iqc_auto_stock_in()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
BEGIN
    IF NEW.direction = 1
       AND NEW.source_doc_type IN ('PURCHASE_RECEIPT', 'SUBCONTRACT_RECEIPT')
       AND EXISTS (
           SELECT 1
           FROM procurement_inspection_items inspection
           WHERE inspection.id = NEW.source_item_id
             AND inspection.receipt_id = NEW.source_doc_id
             AND inspection.receipt_type || '_RECEIPT' = NEW.source_doc_type
       ) THEN
        RAISE EXCEPTION
            'pre-V446 IQC automatic stock-in writer is not compatible with this schema'
            USING ERRCODE = '55000',
                  CONSTRAINT = 'procurement_iqc_legacy_auto_stock_in_guard';
    END IF;
    RETURN NEW;
END;
$$;

CREATE TRIGGER trg_guard_legacy_procurement_iqc_auto_stock_in
    BEFORE INSERT ON stock_movements
    FOR EACH ROW EXECUTE FUNCTION fn_guard_legacy_procurement_iqc_auto_stock_in();
ALTER TABLE stock_movements
    ENABLE ALWAYS TRIGGER trg_guard_legacy_procurement_iqc_auto_stock_in;

CREATE TRIGGER trg_audit_procurement_iqc_stock_in_batches
    AFTER INSERT OR UPDATE OR DELETE ON procurement_iqc_stock_in_batches
    FOR EACH ROW EXECUTE FUNCTION fn_audit();
CREATE TRIGGER trg_audit_procurement_iqc_stock_in_batch_items
    AFTER INSERT OR UPDATE OR DELETE ON procurement_iqc_stock_in_batch_items
    FOR EACH ROW EXECUTE FUNCTION fn_audit();

COMMENT ON COLUMN procurement_inspection_items.warehouse_stocked_base_qty IS
    'IQC PASS quantity that warehouse has physically confirmed into usable inventory; never advanced by quality PASS itself.';
COMMENT ON COLUMN procurement_inspection_items.legacy_stocked_base_qty IS
    'Immutable upgrade baseline for PASS quantities already posted by the pre-V446 implementation.';
COMMENT ON COLUMN procurement_inspection_events.requires_warehouse_stock_in IS
    'False for historical PASS events already posted before V446; true makes a new PASS slice eligible for warehouse confirmation.';
COMMENT ON TABLE procurement_iqc_stock_in_batches IS
    'Immutable actor-scoped command ledger for warehouse confirmation of IQC-released slices.';
COMMENT ON TABLE procurement_iqc_stock_in_batch_items IS
    'One immutable IQC PASS slice, its physical place snapshot, and internal stock valuation posted by warehouse.';

-- Permission cutover is semantics-preserving: every effective old grant/revoke
-- is copied to its exact new authority. Unknown pre-existing target codes are a
-- deployment collision and must be reconciled explicitly, never overwritten.
DO $$
BEGIN
    IF EXISTS (
        SELECT 1
        FROM (VALUES
            ('warehouse_inbound:view', 'VIEW'),
            ('warehouse_inbound:stock_in', 'EXECUTE')
        ) expected(code, action_type)
        LEFT JOIN permissions source_permission
          ON source_permission.code = expected.code
        WHERE source_permission.id IS NULL
           OR source_permission.active IS DISTINCT FROM TRUE
           OR source_permission.action_type IS DISTINCT FROM expected.action_type
    ) THEN
        RAISE EXCEPTION
            'V446 source warehouse inbound permissions are missing, inactive or semantically incompatible';
    END IF;

    IF EXISTS (
        SELECT 1 FROM permissions
        WHERE code IN (
            'warehouse_iqc_stock_in:view',
            'warehouse_iqc_stock_in:confirm'
        )
    ) OR EXISTS (
        SELECT 1 FROM permission_surfaces
        WHERE surface_key = 'warehouse.iqc-stock-in'
    ) THEN
        RAISE EXCEPTION
            'V446 target IQC stock-in permission codes or surface already exist; reconcile provenance before migration';
    END IF;
END;
$$;

CREATE TEMP TABLE v446_permission_expansion (
    old_code TEXT NOT NULL,
    new_code TEXT NOT NULL,
    surface_key TEXT NOT NULL,
    PRIMARY KEY (old_code, new_code)
) ON COMMIT DROP;

INSERT INTO v446_permission_expansion(old_code, new_code, surface_key) VALUES
    ('warehouse_inbound:view',
     'warehouse_iqc_stock_in:view',
     'warehouse.iqc-stock-in'),
    ('warehouse_inbound:stock_in',
     'warehouse_iqc_stock_in:confirm',
     'warehouse.iqc-stock-in');

-- Capture only delegations that are effective before the permission catalog
-- changes advance authorization generations/epoch. Stale grants stay stale.
CREATE TEMP TABLE v446_effective_manager_delegation_source
ON COMMIT DROP AS
SELECT delegation.*
FROM manager_permission_delegations delegation
JOIN permissions delegated_permission
  ON delegated_permission.id = delegation.permission_id
 AND delegated_permission.code IN (
     'warehouse_inbound:view',
     'warehouse_inbound:stock_in'
 )
 AND delegated_permission.active = TRUE
JOIN users target_user ON target_user.id = delegation.user_id
JOIN employees target_employee ON target_employee.id = target_user.employee_id
JOIN departments target_department
  ON target_department.id = delegation.department_id
 AND target_department.id = target_employee.department_id
JOIN users grantor_user ON grantor_user.id = delegation.granted_by_user_id
LEFT JOIN employees grantor_employee ON grantor_employee.id = grantor_user.employee_id
CROSS JOIN authorization_state auth_state
LEFT JOIN departments scope_department
  ON scope_department.id = delegation.scope_department_id
WHERE delegation.enabled = TRUE
  AND target_user.status = 'active'
  AND target_user.is_deleted = FALSE
  AND target_employee.status IN ('active', 'probation', 'onLeave')
  AND target_employee.is_deleted = FALSE
  AND target_department.is_deleted = FALSE
  AND delegation.target_user_generation =
      target_user.permission_delegation_generation
  AND delegation.target_employee_generation =
      target_employee.permission_delegation_generation
  AND delegation.target_department_generation =
      target_department.permission_delegation_generation
  AND grantor_user.status = 'active'
  AND grantor_user.is_deleted = FALSE
  AND delegation.grantor_user_generation =
      grantor_user.permission_delegation_generation
  AND delegation.grantor_auth_version = grantor_user.auth_version
  AND auth_state.singleton_id = 1
  AND delegation.grantor_authorization_epoch = auth_state.epoch
  AND EXISTS (
        SELECT 1
        FROM permission_surfaces source_surface
        JOIN permission_surface_permissions source_link
          ON source_link.surface_id = source_surface.id
        WHERE source_surface.surface_key = delegation.surface_key
          AND source_surface.enabled = TRUE
          AND source_link.permission_id = delegation.permission_id
  )
  AND NOT EXISTS (
        SELECT 1
        FROM roles baseline_role
        JOIN role_permissions baseline_link
          ON baseline_link.role_id = baseline_role.id
        WHERE baseline_role.code = 'employee'
          AND baseline_link.permission_id = delegation.permission_id
  )
  AND NOT EXISTS (
        SELECT 1
        FROM user_permission_overrides grantor_revoke
        WHERE grantor_revoke.user_id = delegation.granted_by_user_id
          AND grantor_revoke.permission_id = delegation.permission_id
          AND grantor_revoke.active = TRUE
          AND grantor_revoke.effect = 'revoke'
  )
  AND (
        (
            delegation.scope_source = 'SUPER_ADMIN'
            AND grantor_user.is_super_admin = TRUE
            AND delegation.grantor_employee_generation IS NULL
            AND delegation.scope_department_id IS NULL
            AND delegation.scope_generation IS NULL
            AND delegation.scope_assignment_id IS NULL
            AND delegation.scope_assignment_version IS NULL
        )
        OR (
            delegation.scope_source = 'DEPARTMENT_MANAGER'
            AND grantor_employee.id IS NOT NULL
            AND grantor_employee.status IN ('active', 'probation', 'onLeave')
            AND grantor_employee.is_deleted = FALSE
            AND delegation.grantor_employee_generation =
                grantor_employee.permission_delegation_generation
            AND scope_department.is_deleted = FALSE
            AND scope_department.manager_id = grantor_employee.id
            AND delegation.scope_generation =
                scope_department.permission_delegation_generation
            AND delegation.scope_assignment_id IS NULL
            AND delegation.scope_assignment_version IS NULL
            AND (
                EXISTS (
                    WITH RECURSIVE grantor_ancestors(id, parent_id, visited) AS (
                        SELECT department.id,
                               department.parent_id,
                               ARRAY[department.id]
                        FROM departments department
                        WHERE department.id = grantor_employee.department_id
                        UNION ALL
                        SELECT parent.id,
                               parent.parent_id,
                               ancestor.visited || parent.id
                        FROM departments parent
                        JOIN grantor_ancestors ancestor
                          ON parent.id = ancestor.parent_id
                        WHERE NOT parent.id = ANY(ancestor.visited)
                    )
                    SELECT 1
                    FROM grantor_ancestors ancestor
                    JOIN department_permissions grantor_department_permission
                      ON grantor_department_permission.department_id = ancestor.id
                    WHERE grantor_department_permission.permission_id =
                        delegation.permission_id
                )
                OR EXISTS (
                    SELECT 1
                    FROM user_permission_overrides grantor_grant
                    WHERE grantor_grant.user_id = delegation.granted_by_user_id
                      AND grantor_grant.permission_id = delegation.permission_id
                      AND grantor_grant.active = TRUE
                      AND grantor_grant.effect = 'grant'
                      AND grantor_grant.authority_source =
                          'SUPER_ADMIN_CONFIRMED'
                )
            )
            AND EXISTS (
                WITH RECURSIVE target_ancestors(id, parent_id, visited) AS (
                    SELECT target_department.id,
                           target_department.parent_id,
                           ARRAY[target_department.id]
                    UNION ALL
                    SELECT parent.id,
                           parent.parent_id,
                           ancestor.visited || parent.id
                    FROM departments parent
                    JOIN target_ancestors ancestor
                      ON parent.id = ancestor.parent_id
                    WHERE NOT parent.id = ANY(ancestor.visited)
                )
                SELECT 1
                FROM target_ancestors ancestor
                WHERE ancestor.id = delegation.scope_department_id
            )
        )
  );

-- Enabled rows that fail any current runtime condition above are already
-- ineffective (for example a stale generation or a revoked grant).  They are
-- deliberately not copied; copying them with fresh generations would revive a
-- permission that the current resolver denies.

INSERT INTO permissions
    (code, name, module, category, sort_order, action_type, description,
     active, assignable, bulk_assignable, sensitivity)
VALUES
    ('warehouse_iqc_stock_in:view',
     '查看 IQC 合格待入库任务', '仓库管理', 'IQC 合格入库', 317,
     'VIEW', '查看品质已放行但仓库尚未确认入库的实物任务；不含金额、单价、成本或结算信息',
     TRUE, TRUE, TRUE, 'NORMAL'),
    ('warehouse_iqc_stock_in:confirm',
     '确认 IQC 合格品入库', '仓库管理', 'IQC 合格入库', 318,
     'EXECUTE', '确认品质放行切片的实际库位并写入可用库存；品质 PASS 本身不再自动入库',
     TRUE, TRUE, TRUE, 'NORMAL')
ON CONFLICT (code) DO UPDATE
SET name = EXCLUDED.name,
    module = EXCLUDED.module,
    category = EXCLUDED.category,
    sort_order = EXCLUDED.sort_order,
    action_type = EXCLUDED.action_type,
    description = EXCLUDED.description,
    active = TRUE,
    assignable = TRUE,
    bulk_assignable = TRUE,
    sensitivity = 'NORMAL';

INSERT INTO permission_surfaces
    (id, surface_key, name, sort_order, enabled)
VALUES
    ('44600000-0000-4000-8000-000000000001',
     'warehouse.iqc-stock-in', 'IQC 合格待入库', 69, TRUE)
ON CONFLICT (surface_key) DO UPDATE
SET name = EXCLUDED.name,
    sort_order = EXCLUDED.sort_order,
    enabled = TRUE;

WITH mapping(surface_key, permission_code) AS (VALUES
    ('warehouse.iqc-stock-in', 'warehouse_iqc_stock_in:view'),
    ('warehouse.iqc-stock-in', 'warehouse_iqc_stock_in:confirm')
)
INSERT INTO permission_surface_permissions(surface_id, permission_id)
SELECT surface.id, permission.id
FROM mapping
JOIN permission_surfaces surface ON surface.surface_key = mapping.surface_key
JOIN permissions permission ON permission.code = mapping.permission_code
ON CONFLICT (surface_id, permission_id) DO NOTHING;

-- Preserve the effective old authority graph exactly. Do not grant the whole
-- warehouse department by fiat: personal revoke and external explicit grants
-- must survive the split.
INSERT INTO role_permissions(role_id, permission_id)
SELECT DISTINCT source.role_id, target_permission.id
FROM role_permissions source
JOIN permissions old_permission ON old_permission.id = source.permission_id
                               AND old_permission.active = TRUE
JOIN v446_permission_expansion expansion
  ON expansion.old_code = old_permission.code
JOIN permissions target_permission ON target_permission.code = expansion.new_code
ON CONFLICT (role_id, permission_id) DO NOTHING;

INSERT INTO department_permissions(
    department_id, permission_id, created_at, created_by
)
SELECT DISTINCT ON (source.department_id, target_permission.id)
       source.department_id,
       target_permission.id,
       source.created_at,
       source.created_by
FROM department_permissions source
JOIN permissions old_permission ON old_permission.id = source.permission_id
                               AND old_permission.active = TRUE
JOIN v446_permission_expansion expansion
  ON expansion.old_code = old_permission.code
JOIN permissions target_permission ON target_permission.code = expansion.new_code
ORDER BY source.department_id, target_permission.id, source.created_at
ON CONFLICT (department_id, permission_id) DO NOTHING;

INSERT INTO user_permission_overrides(
    user_id, permission_id, effect, authority_source,
    source_actor_user_id, row_version, active
)
SELECT source.user_id,
       target_permission.id,
       source.effect,
       source.authority_source,
       source.source_actor_user_id,
       source.row_version,
       TRUE
FROM user_permission_overrides source
JOIN permissions old_permission ON old_permission.id = source.permission_id
                               AND old_permission.active = TRUE
JOIN v446_permission_expansion expansion
  ON expansion.old_code = old_permission.code
JOIN permissions target_permission ON target_permission.code = expansion.new_code
WHERE source.active = TRUE
ON CONFLICT (user_id, permission_id) DO NOTHING;

CREATE TEMP TABLE v446_manager_delegation_expansion
ON COMMIT DROP AS
SELECT source.*,
       target_permission.id AS target_permission_id,
       expansion.surface_key AS target_surface_key
FROM v446_effective_manager_delegation_source source
JOIN permissions old_permission ON old_permission.id = source.permission_id
                               AND old_permission.active = TRUE
JOIN v446_permission_expansion expansion
  ON expansion.old_code = old_permission.code
JOIN permissions target_permission ON target_permission.code = expansion.new_code;

-- Permission/role/department statements above already advance the shared
-- authorization epoch through V135 triggers. Manager rows advance only their
-- affected target users; no organization-wide refresh-token revocation occurs.
WITH incoming AS (
    SELECT user_id, count(*)::BIGINT AS auth_bumps
    FROM v446_manager_delegation_expansion
    GROUP BY user_id
)
INSERT INTO manager_permission_delegations(
    user_id, permission_id, department_id, enabled, surface_key,
    granted_by_user_id, row_version, created_at, updated_at,
    created_by, updated_by, target_user_generation,
    target_employee_generation, target_department_generation,
    grantor_user_generation, grantor_employee_generation,
    grantor_auth_version, grantor_authorization_epoch,
    scope_source, scope_department_id, scope_generation,
    scope_assignment_id, scope_assignment_version
)
SELECT source.user_id,
       source.target_permission_id,
       source.department_id,
       TRUE,
       source.target_surface_key,
       source.granted_by_user_id,
       source.row_version,
       source.created_at,
       source.updated_at,
       source.created_by,
       source.updated_by,
       target_user.permission_delegation_generation,
       source.target_employee_generation,
       source.target_department_generation,
       grantor_user.permission_delegation_generation,
       source.grantor_employee_generation,
       grantor_user.auth_version + COALESCE(grantor_incoming.auth_bumps, 0),
       auth_state.epoch,
       source.scope_source,
       source.scope_department_id,
       source.scope_generation,
       source.scope_assignment_id,
       source.scope_assignment_version
FROM v446_manager_delegation_expansion source
JOIN users target_user ON target_user.id = source.user_id
JOIN users grantor_user ON grantor_user.id = source.granted_by_user_id
LEFT JOIN incoming grantor_incoming
  ON grantor_incoming.user_id = source.granted_by_user_id
CROSS JOIN authorization_state auth_state
WHERE auth_state.singleton_id = 1
ON CONFLICT (user_id, permission_id, department_id) DO NOTHING;

DO $$
DECLARE
    missing_mapping_count INTEGER;
    unsafe_mapping_count INTEGER;
    authorization_gap_count INTEGER;
BEGIN
    SELECT count(*)
    INTO missing_mapping_count
    FROM (VALUES
        ('warehouse.iqc-stock-in', 'warehouse_iqc_stock_in:view'),
        ('warehouse.iqc-stock-in', 'warehouse_iqc_stock_in:confirm')
    ) expected(surface_key, permission_code)
    WHERE NOT EXISTS (
        SELECT 1
        FROM permission_surfaces surface
        JOIN permission_surface_permissions link
          ON link.surface_id = surface.id
        JOIN permissions permission ON permission.id = link.permission_id
        WHERE surface.surface_key = expected.surface_key
          AND permission.code = expected.permission_code
    );
    IF missing_mapping_count <> 0 THEN
        RAISE EXCEPTION 'V446 missing IQC warehouse stock-in surface mappings: %',
            missing_mapping_count;
    END IF;

    SELECT count(*)
    INTO unsafe_mapping_count
    FROM permission_surfaces surface
    JOIN permission_surface_permissions link ON link.surface_id = surface.id
    JOIN permissions permission ON permission.id = link.permission_id
    WHERE surface.surface_key = 'warehouse.iqc-stock-in'
      AND permission.code NOT IN (
          'warehouse_iqc_stock_in:view',
          'warehouse_iqc_stock_in:confirm'
      );
    IF unsafe_mapping_count <> 0 THEN
        RAISE EXCEPTION
            'V446 IQC stock-in surface contains unrelated or commercial permissions: %',
            unsafe_mapping_count;
    END IF;

    SELECT count(*)
    INTO authorization_gap_count
    FROM (
        SELECT source.role_id::TEXT AS subject, expansion.new_code
        FROM role_permissions source
        JOIN permissions old_permission ON old_permission.id = source.permission_id
                                       AND old_permission.active = TRUE
        JOIN v446_permission_expansion expansion
          ON expansion.old_code = old_permission.code
        JOIN permissions target_permission
          ON target_permission.code = expansion.new_code
        WHERE NOT EXISTS (
            SELECT 1 FROM role_permissions target
            WHERE target.role_id = source.role_id
              AND target.permission_id = target_permission.id)
        UNION ALL
        SELECT source.department_id::TEXT, expansion.new_code
        FROM department_permissions source
        JOIN permissions old_permission ON old_permission.id = source.permission_id
                                       AND old_permission.active = TRUE
        JOIN v446_permission_expansion expansion
          ON expansion.old_code = old_permission.code
        JOIN permissions target_permission
          ON target_permission.code = expansion.new_code
        WHERE NOT EXISTS (
            SELECT 1 FROM department_permissions target
            WHERE target.department_id = source.department_id
              AND target.permission_id = target_permission.id)
        UNION ALL
        SELECT source.user_id::TEXT, expansion.new_code
        FROM user_permission_overrides source
        JOIN permissions old_permission ON old_permission.id = source.permission_id
                                       AND old_permission.active = TRUE
        JOIN v446_permission_expansion expansion
          ON expansion.old_code = old_permission.code
        JOIN permissions target_permission
          ON target_permission.code = expansion.new_code
        WHERE source.active = TRUE
          AND NOT EXISTS (
              SELECT 1 FROM user_permission_overrides target
              WHERE target.user_id = source.user_id
                AND target.permission_id = target_permission.id
                AND target.active = TRUE
                AND target.effect = source.effect)
        UNION ALL
        SELECT source.user_id::TEXT, target_permission.code
        FROM v446_effective_manager_delegation_source source
        JOIN permissions old_permission ON old_permission.id = source.permission_id
                                       AND old_permission.active = TRUE
        JOIN v446_permission_expansion expansion
          ON expansion.old_code = old_permission.code
        JOIN permissions target_permission
          ON target_permission.code = expansion.new_code
        WHERE NOT EXISTS (
            SELECT 1 FROM manager_permission_delegations target
            WHERE target.user_id = source.user_id
              AND target.permission_id = target_permission.id
              AND target.department_id = source.department_id
              AND target.enabled = TRUE)
    ) gap;
    IF authorization_gap_count <> 0 THEN
        RAISE EXCEPTION
            'V446 failed to preserve % old IQC-equivalent authorization decision(s)',
            authorization_gap_count;
    END IF;
END;
$$;
