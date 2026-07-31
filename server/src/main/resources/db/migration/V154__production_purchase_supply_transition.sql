-- V154: explicit purchase supply transition into production material stock.
--
-- A purchase request/order is future supply. Once a receipt reaches the
-- production demand's target warehouse, the same quantity stops being future
-- coverage and becomes a physical stock reservation. The transition is
-- one-for-one and every hop is mapped for reversal and audit.

CREATE TABLE production_material_peg_transfers (
    id                UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    demand_id         UUID NOT NULL
        REFERENCES production_material_demands(id),
    from_peg_id       UUID NOT NULL
        REFERENCES production_material_supply_pegs(id),
    to_peg_id         UUID NOT NULL
        REFERENCES production_material_supply_pegs(id),
    request_item_id   UUID NOT NULL
        REFERENCES purchase_request_items(id),
    order_item_id     UUID NOT NULL
        REFERENCES purchase_order_items(id),
    transferred_qty   NUMERIC(18,4) NOT NULL,
    status            TEXT NOT NULL DEFAULT 'EFFECTIVE',
    idempotency_key   TEXT NOT NULL,
    created_at        TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_at        TIMESTAMPTZ NOT NULL DEFAULT now(),
    created_by        UUID,
    updated_by        UUID,
    CONSTRAINT production_material_peg_transfer_qty_chk
        CHECK (transferred_qty > 0),
    CONSTRAINT production_material_peg_transfer_status_chk
        CHECK (status IN ('EFFECTIVE', 'REVERSED')),
    CONSTRAINT production_material_peg_transfer_key_chk
        CHECK (length(btrim(idempotency_key)) BETWEEN 8 AND 128)
);

CREATE UNIQUE INDEX uq_production_material_peg_transfer_key
    ON production_material_peg_transfers(idempotency_key);
CREATE UNIQUE INDEX uq_production_material_peg_transfer_active
    ON production_material_peg_transfers(from_peg_id, order_item_id)
    WHERE status = 'EFFECTIVE';
CREATE UNIQUE INDEX uq_production_material_peg_transfer_target
    ON production_material_peg_transfers(to_peg_id);
CREATE INDEX idx_production_material_peg_transfer_order
    ON production_material_peg_transfers(order_item_id, status);

CREATE TABLE production_material_receipt_allocations (
    id                UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    receipt_id        UUID NOT NULL
        REFERENCES purchase_receipts(id),
    receipt_item_id   UUID NOT NULL
        REFERENCES purchase_receipt_items(id),
    package_id        UUID NOT NULL
        REFERENCES production_planning_packages(id),
    demand_id         UUID NOT NULL
        REFERENCES production_material_demands(id),
    order_peg_id      UUID NOT NULL
        REFERENCES production_material_supply_pegs(id),
    reservation_id    UUID NOT NULL
        REFERENCES stock_reservations(id),
    draw_id           UUID NOT NULL
        REFERENCES stock_documents(id),
    draw_item_id      UUID NOT NULL
        REFERENCES stock_document_items(id),
    allocated_qty     NUMERIC(18,4) NOT NULL,
    status            TEXT NOT NULL DEFAULT 'EFFECTIVE',
    idempotency_key   TEXT NOT NULL,
    created_at        TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_at        TIMESTAMPTZ NOT NULL DEFAULT now(),
    created_by        UUID,
    updated_by        UUID,
    CONSTRAINT production_material_receipt_allocation_qty_chk
        CHECK (allocated_qty > 0),
    CONSTRAINT production_material_receipt_allocation_status_chk
        CHECK (status IN ('EFFECTIVE', 'REVERSED')),
    CONSTRAINT production_material_receipt_allocation_key_chk
        CHECK (length(btrim(idempotency_key)) BETWEEN 8 AND 128)
);

CREATE UNIQUE INDEX uq_production_material_receipt_allocation_key
    ON production_material_receipt_allocations(idempotency_key);
CREATE UNIQUE INDEX uq_production_material_receipt_allocation_active
    ON production_material_receipt_allocations(receipt_item_id, order_peg_id)
    WHERE status = 'EFFECTIVE';
CREATE INDEX idx_production_material_receipt_allocation_receipt
    ON production_material_receipt_allocations(receipt_id, status);
CREATE INDEX idx_production_material_receipt_allocation_draw
    ON production_material_receipt_allocations(draw_id, status);
CREATE INDEX idx_production_material_receipt_allocation_reservation
    ON production_material_receipt_allocations(reservation_id, status);

CREATE TRIGGER trg_audit_production_material_peg_transfers
    AFTER INSERT OR UPDATE OR DELETE
    ON production_material_peg_transfers
    FOR EACH ROW EXECUTE FUNCTION fn_audit();

CREATE TRIGGER trg_audit_production_material_receipt_allocations
    AFTER INSERT OR UPDATE OR DELETE
    ON production_material_receipt_allocations
    FOR EACH ROW EXECUTE FUNCTION fn_audit();

-- Demand capacity counts stock reservations for their full lifecycle, but a
-- future supply peg only while it has not been received. Source capacity
-- intentionally continues to count consumed supply so the same request/order
-- line can never be reused by a second demand.
CREATE OR REPLACE FUNCTION fn_guard_production_stock_allocation()
RETURNS trigger
LANGUAGE plpgsql
AS $$
DECLARE
    v_demand       production_material_demands%ROWTYPE;
    v_balance      stock_balances%ROWTYPE;
    v_new_open numeric;
    v_old_open numeric := 0;
    v_new_committed numeric;
    v_other_reserved numeric;
    v_other_stock_demand numeric;
    v_other_supply_demand numeric;
    v_safety       numeric;
    v_key          text;
BEGIN
    IF TG_OP = 'UPDATE'
       AND OLD.owner_type = 'PRODUCTION_MATERIAL_DEMAND'
       AND (
           NEW.owner_type IS DISTINCT FROM OLD.owner_type
           OR NEW.demand_id IS DISTINCT FROM OLD.demand_id
           OR NEW.supply_id IS DISTINCT FROM OLD.supply_id
           OR NEW.goods_id IS DISTINCT FROM OLD.goods_id
           OR NEW.color_id IS DISTINCT FROM OLD.color_id
           OR NEW.warehouse_id IS DISTINCT FROM OLD.warehouse_id
       ) THEN
        RAISE EXCEPTION 'production stock allocation identity is immutable'
            USING ERRCODE = '23514',
                  CONSTRAINT = 'stock_reservations_production_identity_guard';
    END IF;

    IF NEW.owner_type IS DISTINCT FROM 'PRODUCTION_MATERIAL_DEMAND' THEN
        RETURN NEW;
    END IF;

    SELECT * INTO v_demand
    FROM production_material_demands
    WHERE id = NEW.demand_id
      AND is_deleted = FALSE
    FOR UPDATE;

    IF NOT FOUND
       OR v_demand.status IN ('RELEASED', 'REVERSED')
       OR v_demand.goods_id <> NEW.goods_id
       OR v_demand.color_id IS DISTINCT FROM NEW.color_id
       OR v_demand.warehouse_id <> NEW.warehouse_id THEN
        RAISE EXCEPTION 'production stock allocation does not match an active demand'
            USING ERRCODE = '23514',
                  CONSTRAINT = 'stock_reservations_production_demand_guard';
    END IF;

    v_new_committed := CASE
        WHEN NEW.is_deleted THEN 0
        ELSE NEW.qty - NEW.released_qty
    END;
    v_new_open := CASE
        WHEN NEW.is_deleted OR NEW.status <> 0 THEN 0
        ELSE NEW.qty - NEW.consumed_qty - NEW.released_qty
    END;
    IF TG_OP = 'UPDATE' THEN
        v_old_open := CASE
            WHEN OLD.is_deleted OR OLD.status <> 0 THEN 0
            ELSE OLD.qty - OLD.consumed_qty - OLD.released_qty
        END;
    END IF;

    SELECT COALESCE(SUM(r.qty - r.released_qty), 0)
    INTO v_other_stock_demand
    FROM stock_reservations r
    WHERE r.id IS DISTINCT FROM NEW.id
      AND r.demand_id = NEW.demand_id
      AND r.owner_type = 'PRODUCTION_MATERIAL_DEMAND'
      AND r.is_deleted = FALSE;

    SELECT COALESCE(SUM(
               p.allocated_qty - p.consumed_qty - p.released_qty
           ), 0)
    INTO v_other_supply_demand
    FROM production_material_supply_pegs p
    WHERE p.demand_id = NEW.demand_id
      AND p.status <> 'REVERSED';

    IF v_other_stock_demand + v_other_supply_demand + v_new_committed
       > v_demand.required_qty - v_demand.released_qty THEN
        RAISE EXCEPTION 'production stock allocation exceeds demand quantity'
            USING ERRCODE = '23514',
                  CONSTRAINT = 'stock_reservations_production_demand_capacity_guard';
    END IF;

    v_key := NEW.goods_id::text || ':' ||
        COALESCE(NEW.color_id::text, '00000000-0000-0000-0000-000000000000');
    PERFORM pg_advisory_xact_lock(
        hashtextextended(v_key, 6148615593807138892)
    );

    SELECT * INTO v_balance
    FROM stock_balances
    WHERE id = NEW.supply_id
      AND warehouse_id = NEW.warehouse_id
      AND goods_id = NEW.goods_id
      AND color_id IS NOT DISTINCT FROM NEW.color_id
    FOR UPDATE;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'production stock allocation supply row is invalid'
            USING ERRCODE = '23514',
                  CONSTRAINT = 'stock_reservations_production_supply_guard';
    END IF;

    IF v_new_open <= v_old_open THEN
        RETURN NEW;
    END IF;

    SELECT COALESCE(SUM(
               CASE WHEN r.status = 0 AND r.is_deleted = FALSE
                    THEN r.qty - r.consumed_qty - r.released_qty
                    ELSE 0 END
           ), 0)
    INTO v_other_reserved
    FROM stock_reservations r
    WHERE r.id IS DISTINCT FROM NEW.id
      AND r.goods_id = NEW.goods_id
      AND r.color_id IS NOT DISTINCT FROM NEW.color_id
      AND (r.warehouse_id IS NULL OR r.warehouse_id = NEW.warehouse_id);

    SELECT GREATEST(COALESCE(g.min_qty, 0), 0)
    INTO v_safety
    FROM goods g
    WHERE g.id = NEW.goods_id;

    IF v_new_open > GREATEST(v_balance.qty - v_other_reserved - v_safety, 0) THEN
        RAISE EXCEPTION 'production stock allocation exceeds available quantity'
            USING ERRCODE = '23514',
                  CONSTRAINT = 'stock_reservations_production_capacity_guard';
    END IF;
    RETURN NEW;
END;
$$;

CREATE OR REPLACE FUNCTION fn_guard_production_material_supply_peg()
RETURNS trigger
LANGUAGE plpgsql
AS $$
DECLARE
    v_demand                  production_material_demands%ROWTYPE;
    v_source_goods            UUID;
    v_source_color            UUID;
    v_source_qty              numeric;
    v_source_rate             numeric;
    v_new_source_committed    numeric;
    v_old_source_committed    numeric := 0;
    v_new_demand_effective    numeric;
    v_old_demand_effective    numeric := 0;
    v_other_source            numeric;
    v_other_demand            numeric;
    v_stock_demand            numeric;
BEGIN
    IF TG_OP = 'UPDATE'
       AND (
           NEW.demand_id IS DISTINCT FROM OLD.demand_id
           OR NEW.supply_type IS DISTINCT FROM OLD.supply_type
           OR NEW.supply_item_id IS DISTINCT FROM OLD.supply_item_id
       ) THEN
        RAISE EXCEPTION 'material supply peg identity is immutable'
            USING ERRCODE = '23514',
                  CONSTRAINT = 'production_material_supply_peg_identity_guard';
    END IF;

    SELECT * INTO v_demand
    FROM production_material_demands
    WHERE id = NEW.demand_id
      AND is_deleted = FALSE
    FOR UPDATE;
    IF NOT FOUND OR v_demand.status IN ('RELEASED', 'REVERSED') THEN
        RAISE EXCEPTION 'material supply peg demand is not active'
            USING ERRCODE = '23514',
                  CONSTRAINT = 'production_material_supply_peg_demand_guard';
    END IF;

    PERFORM pg_advisory_xact_lock(
        hashtextextended(
            'DEMAND:' || NEW.demand_id::text,
            6148615593807138892
        )
    );
    PERFORM pg_advisory_xact_lock(
        hashtextextended(
            NEW.supply_type || ':' || NEW.supply_item_id::text,
            6148615593807138892
        )
    );

    CASE NEW.supply_type
        WHEN 'PURCHASE_REQUEST_ITEM' THEN
            SELECT goods_id, color_id, qty, unit_rate
            INTO v_source_goods, v_source_color, v_source_qty, v_source_rate
            FROM purchase_request_items
            WHERE id = NEW.supply_item_id AND is_deleted = FALSE
            FOR UPDATE;
        WHEN 'PURCHASE_ORDER_ITEM' THEN
            SELECT goods_id, color_id, qty, unit_rate
            INTO v_source_goods, v_source_color, v_source_qty, v_source_rate
            FROM purchase_order_items
            WHERE id = NEW.supply_item_id AND is_deleted = FALSE
            FOR UPDATE;
        WHEN 'SUBCONTRACT_APPLICATION_ITEM' THEN
            SELECT goods_id, color_id, qty, unit_rate
            INTO v_source_goods, v_source_color, v_source_qty, v_source_rate
            FROM subcontract_application_items
            WHERE id = NEW.supply_item_id AND is_deleted = FALSE
            FOR UPDATE;
        WHEN 'SUBCONTRACT_ORDER_ITEM' THEN
            SELECT goods_id, color_id, qty, unit_rate
            INTO v_source_goods, v_source_color, v_source_qty, v_source_rate
            FROM subcontract_order_items
            WHERE id = NEW.supply_item_id AND is_deleted = FALSE
            FOR UPDATE;
    END CASE;

    IF v_source_goods IS NULL
       OR v_source_goods <> v_demand.goods_id
       OR v_source_color IS DISTINCT FROM v_demand.color_id
       OR COALESCE(v_source_rate, 0) <= 0
       OR COALESCE(v_source_qty, 0) <= 0 THEN
        RAISE EXCEPTION 'material supply peg source dimension is invalid'
            USING ERRCODE = '23514',
                  CONSTRAINT = 'production_material_supply_peg_source_guard';
    END IF;

    v_new_source_committed := NEW.allocated_qty - NEW.released_qty;
    v_new_demand_effective :=
        NEW.allocated_qty - NEW.consumed_qty - NEW.released_qty;
    IF TG_OP = 'UPDATE' THEN
        v_old_source_committed := OLD.allocated_qty - OLD.released_qty;
        v_old_demand_effective :=
            OLD.allocated_qty - OLD.consumed_qty - OLD.released_qty;
    END IF;

    IF v_new_source_committed > v_old_source_committed THEN
        SELECT COALESCE(SUM(p.allocated_qty - p.released_qty), 0)
        INTO v_other_source
        FROM production_material_supply_pegs p
        WHERE p.id IS DISTINCT FROM NEW.id
          AND p.supply_type = NEW.supply_type
          AND p.supply_item_id = NEW.supply_item_id;

        IF v_other_source + v_new_source_committed
           > v_source_qty * v_source_rate THEN
            RAISE EXCEPTION 'material supply peg exceeds source quantity'
                USING ERRCODE = '23514',
                      CONSTRAINT = 'production_material_supply_peg_capacity_guard';
        END IF;
    END IF;

    IF v_new_demand_effective > v_old_demand_effective THEN
        SELECT COALESCE(SUM(
                   p.allocated_qty - p.consumed_qty - p.released_qty
               ), 0)
        INTO v_other_demand
        FROM production_material_supply_pegs p
        WHERE p.id IS DISTINCT FROM NEW.id
          AND p.demand_id = NEW.demand_id
          AND p.status <> 'REVERSED';

        SELECT COALESCE(SUM(r.qty - r.released_qty), 0)
        INTO v_stock_demand
        FROM stock_reservations r
        WHERE r.demand_id = NEW.demand_id
          AND r.owner_type = 'PRODUCTION_MATERIAL_DEMAND'
          AND r.is_deleted = FALSE;

        IF v_other_demand + v_stock_demand + v_new_demand_effective
           > v_demand.required_qty - v_demand.released_qty THEN
            RAISE EXCEPTION 'material supply peg exceeds demand quantity'
                USING ERRCODE = '23514',
                      CONSTRAINT = 'production_material_supply_peg_demand_capacity_guard';
        END IF;
    END IF;
    RETURN NEW;
END;
$$;

CREATE OR REPLACE FUNCTION fn_guard_production_material_demand_update()
RETURNS trigger
LANGUAGE plpgsql
AS $$
DECLARE
    v_stock_committed numeric;
    v_supply_effective numeric;
BEGIN
    SELECT COALESCE(SUM(r.qty - r.released_qty), 0)
    INTO v_stock_committed
    FROM stock_reservations r
    WHERE r.demand_id = OLD.id
      AND r.owner_type = 'PRODUCTION_MATERIAL_DEMAND'
      AND r.is_deleted = FALSE;

    SELECT COALESCE(SUM(
               p.allocated_qty - p.consumed_qty - p.released_qty
           ), 0)
    INTO v_supply_effective
    FROM production_material_supply_pegs p
    WHERE p.demand_id = OLD.id
      AND p.status <> 'REVERSED';

    IF (
        OLD.goods_id IS DISTINCT FROM NEW.goods_id
        OR OLD.color_id IS DISTINCT FROM NEW.color_id
        OR OLD.warehouse_id IS DISTINCT FROM NEW.warehouse_id
        OR OLD.unit_id IS DISTINCT FROM NEW.unit_id
    ) AND v_stock_committed + v_supply_effective > 0 THEN
        RAISE EXCEPTION 'allocated production demand dimensions are immutable'
            USING ERRCODE = '23514',
                  CONSTRAINT = 'production_material_demand_dimension_guard';
    END IF;

    IF v_stock_committed + v_supply_effective
       > NEW.required_qty - NEW.released_qty THEN
        RAISE EXCEPTION 'production demand release exceeds uncommitted quantity'
            USING ERRCODE = '23514',
                  CONSTRAINT = 'production_material_demand_capacity_guard';
    END IF;

    IF (
        NEW.is_deleted
        OR NEW.status IN ('RELEASED', 'REVERSED')
    ) AND v_stock_committed + v_supply_effective > 0 THEN
        RAISE EXCEPTION 'committed production demand cannot be deleted or closed'
            USING ERRCODE = '23514',
                  CONSTRAINT = 'production_material_demand_lifecycle_guard';
    END IF;
    RETURN NEW;
END;
$$;

-- Rebuild the CQRS workbench with future supply and receipts separated.
CREATE OR REPLACE VIEW v_fulfillment_workbench AS
WITH stock_totals AS (
    SELECT demand_id,
           SUM(qty - released_qty) AS committed_qty,
           SUM(consumed_qty) AS fulfilled_qty,
           SUM(GREATEST(qty - consumed_qty - released_qty, 0)) AS open_qty,
           MAX(updated_at) AS updated_at
    FROM stock_reservations
    WHERE demand_id IS NOT NULL
      AND is_deleted = FALSE
    GROUP BY demand_id
),
peg_totals AS (
    SELECT demand_id,
           SUM(allocated_qty - consumed_qty - released_qty)
               AS committed_qty,
           SUM(consumed_qty) AS received_qty,
           MIN(expected_date)
               FILTER (
                   WHERE status NOT IN ('RELEASED', 'REVERSED')
                     AND allocated_qty - consumed_qty - released_qty > 0
               ) AS expected_date,
           MAX(updated_at) AS updated_at
    FROM production_material_supply_pegs
    WHERE status <> 'REVERSED'
    GROUP BY demand_id
),
base AS (
    SELECT d.id AS demand_id,
           d.package_id,
           d.plan_id,
           p.bill_no AS plan_no,
           d.warehouse_id,
           w.name AS warehouse_name,
           d.goods_id,
           g.code AS goods_code,
           g.name AS goods_name,
           g.spec,
           d.color_id,
           c.name AS color_name,
           d.unit_id,
           u.name AS unit_name,
           d.supply_route,
           d.need_date,
           d.status AS demand_status,
           GREATEST(d.required_qty - d.released_qty, 0) AS required_qty,
           COALESCE(st.committed_qty, 0) AS stock_committed_qty,
           COALESCE(st.fulfilled_qty, 0) AS stock_fulfilled_qty,
           COALESCE(st.open_qty, 0) AS stock_open_qty,
           COALESCE(pt.committed_qty, 0) AS supply_committed_qty,
           COALESCE(pt.received_qty, 0) AS supply_received_qty,
           pt.expected_date,
           GREATEST(
               d.updated_at,
               COALESCE(st.updated_at, d.updated_at),
               COALESCE(pt.updated_at, d.updated_at)
           ) AS updated_at
    FROM production_material_demands d
    JOIN production_planning_packages pk
      ON pk.id = d.package_id
     AND pk.is_deleted = FALSE
     AND pk.status = 'CONFIRMED'
    JOIN production_plans p ON p.id = d.plan_id
    JOIN warehouses w ON w.id = d.warehouse_id
    JOIN goods g ON g.id = d.goods_id
    LEFT JOIN colors c ON c.id = d.color_id
    JOIN units u ON u.id = d.unit_id
    LEFT JOIN stock_totals st ON st.demand_id = d.id
    LEFT JOIN peg_totals pt ON pt.demand_id = d.id
    WHERE d.is_deleted = FALSE
      AND d.status NOT IN ('RELEASED', 'REVERSED')
)
SELECT 'WAREHOUSE'::text AS department,
       demand_id AS task_id,
       package_id,
       plan_id,
       plan_no,
       'PRODUCTION_MATERIAL_DEMAND'::text AS source_doc_type,
       demand_id AS source_item_id,
       warehouse_id,
       warehouse_name,
       goods_id,
       goods_code,
       goods_name,
       spec,
       color_id,
       color_name,
       unit_id,
       unit_name,
       supply_route,
       stock_committed_qty AS required_qty,
       stock_committed_qty AS allocated_qty,
       stock_fulfilled_qty AS fulfilled_qty,
       0::numeric AS supply_pegged_qty,
       stock_open_qty AS open_qty,
       CASE
           WHEN stock_open_qty <= 0 THEN 'DONE'
           WHEN stock_fulfilled_qty > 0 THEN 'PARTIAL'
           ELSE 'READY_TO_PICK'
       END::text AS task_status,
       need_date,
       expected_date,
       CASE
           WHEN stock_open_qty > 0 AND need_date < CURRENT_DATE THEN 'OVERDUE'
           ELSE NULL
       END::text AS exception_code,
       updated_at
FROM base
WHERE stock_committed_qty > 0

UNION ALL

SELECT CASE WHEN supply_route = 'SUBCONTRACT'
            THEN 'SUBCONTRACT' ELSE 'PURCHASE' END::text AS department,
       demand_id AS task_id,
       package_id,
       plan_id,
       plan_no,
       'PRODUCTION_MATERIAL_DEMAND'::text AS source_doc_type,
       demand_id AS source_item_id,
       warehouse_id,
       warehouse_name,
       goods_id,
       goods_code,
       goods_name,
       spec,
       color_id,
       color_name,
       unit_id,
       unit_name,
       supply_route,
       required_qty,
       stock_committed_qty AS allocated_qty,
       stock_fulfilled_qty + supply_received_qty AS fulfilled_qty,
       supply_committed_qty AS supply_pegged_qty,
       GREATEST(
           required_qty - stock_committed_qty - supply_committed_qty, 0
       ) AS open_qty,
       CASE
           WHEN required_qty - stock_committed_qty - supply_committed_qty > 0
                THEN 'UNPEGGED'
           WHEN supply_committed_qty > 0 THEN 'WAITING_SUPPLY'
           ELSE 'COVERED'
       END::text AS task_status,
       need_date,
       expected_date,
       CASE
           WHEN required_qty - stock_committed_qty - supply_committed_qty > 0
                AND need_date < CURRENT_DATE THEN 'OVERDUE_SHORTAGE'
           WHEN required_qty - stock_committed_qty - supply_committed_qty > 0
                THEN 'SUPPLY_PEG_REQUIRED'
           ELSE NULL
       END::text AS exception_code,
       updated_at
FROM base
WHERE supply_route IN ('BUY', 'SUBCONTRACT');

CREATE OR REPLACE VIEW v_fulfillment_workbench_actions AS
SELECT w.*,
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
      AND (
          receipt.status = 0
          OR EXISTS (
              SELECT 1
              FROM production_material_receipt_allocations allocation
              WHERE allocation.demand_id = w.task_id
                AND allocation.receipt_item_id = receipt_item.id
                AND allocation.status = 'EFFECTIVE'
          )
      )

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
      AND (
          purchase_order.status = 0
          OR EXISTS (
              SELECT 1
              FROM production_material_peg_transfers transfer
              WHERE transfer.demand_id = w.task_id
                AND transfer.order_item_id = order_item.id
                AND transfer.status = 'EFFECTIVE'
          )
      )

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

    ORDER BY stage_rank DESC, created_at DESC, document_id
    LIMIT 1
) action ON TRUE;

COMMENT ON TABLE production_material_peg_transfers IS
    'Exact request-peg to order-peg quantity migration; reversible before receipt.';
COMMENT ON TABLE production_material_receipt_allocations IS
    'Exact receipt item to order peg, stock reservation and new DRAW item mapping.';
COMMENT ON VIEW v_fulfillment_workbench IS
    'Fulfillment read model: received purchase supply is physical stock, never simultaneous future coverage.';

CREATE OR REPLACE FUNCTION fn_assert_purchase_transfer_row(
    p_transfer_id UUID
)
RETURNS void
LANGUAGE plpgsql
AS $$
BEGIN
    IF EXISTS (
        SELECT 1
        FROM production_material_peg_transfers transfer
        JOIN production_material_supply_pegs source
          ON source.id = transfer.from_peg_id
        JOIN production_material_supply_pegs target
          ON target.id = transfer.to_peg_id
        JOIN purchase_order_items order_item
          ON order_item.id = transfer.order_item_id
        WHERE transfer.id = p_transfer_id
          AND (
              source.supply_type <> 'PURCHASE_REQUEST_ITEM'
              OR source.supply_item_id <> transfer.request_item_id
              OR source.demand_id <> transfer.demand_id
              OR target.supply_type <> 'PURCHASE_ORDER_ITEM'
              OR target.supply_item_id <> transfer.order_item_id
              OR target.demand_id <> transfer.demand_id
              OR target.allocated_qty <> transfer.transferred_qty
              OR order_item.request_item_id IS DISTINCT FROM
                    transfer.request_item_id
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
            'purchase supply transfer provenance is inconsistent'
            USING ERRCODE = '23514',
                  CONSTRAINT =
                      'production_purchase_transfer_provenance_guard';
    END IF;
END;
$$;

CREATE OR REPLACE FUNCTION fn_assert_purchase_peg_transfer_coverage(
    p_peg_id UUID
)
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
    SELECT supply_type, allocated_qty, consumed_qty, released_qty, status
    INTO v_type, v_allocated, v_consumed, v_released, v_status
    FROM production_material_supply_pegs
    WHERE id = p_peg_id;

    IF NOT FOUND THEN
        RETURN;
    END IF;

    IF v_type = 'PURCHASE_REQUEST_ITEM' THEN
        SELECT COALESCE(SUM(transferred_qty), 0)
        INTO v_active
        FROM production_material_peg_transfers
        WHERE from_peg_id = p_peg_id
          AND status = 'EFFECTIVE';

        IF v_active > v_released THEN
            RAISE EXCEPTION
                'active order transfers exceed request peg release'
                USING ERRCODE = '23514',
                      CONSTRAINT =
                          'production_purchase_transfer_source_guard';
        END IF;
        RETURN;
    END IF;

    IF v_type <> 'PURCHASE_ORDER_ITEM' THEN
        RETURN;
    END IF;

    SELECT EXISTS (
               SELECT 1
               FROM production_material_peg_transfers
               WHERE to_peg_id = p_peg_id
           ),
           COALESCE(SUM(transferred_qty)
               FILTER (WHERE status = 'EFFECTIVE'), 0)
    INTO v_has_link, v_active
    FROM production_material_peg_transfers
    WHERE to_peg_id = p_peg_id;

    IF NOT v_has_link THEN
        RETURN;
    END IF;

    IF v_status = 'REVERSED' THEN
        IF v_active <> 0
           OR v_consumed <> 0
           OR v_released <> v_allocated THEN
            RAISE EXCEPTION
                'reversed order peg is not fully unwound'
                USING ERRCODE = '23514',
                      CONSTRAINT =
                          'production_purchase_transfer_target_guard';
        END IF;
    ELSIF v_active <> v_allocated THEN
        RAISE EXCEPTION
            'order peg is not exactly covered by its active transfer'
            USING ERRCODE = '23514',
                  CONSTRAINT =
                      'production_purchase_transfer_target_guard';
    END IF;
END;
$$;

CREATE OR REPLACE FUNCTION fn_check_purchase_transfer_conservation()
RETURNS trigger
LANGUAGE plpgsql
AS $$
BEGIN
    IF TG_OP <> 'INSERT' THEN
        PERFORM fn_assert_purchase_transfer_row(OLD.id);
        PERFORM fn_assert_purchase_peg_transfer_coverage(OLD.from_peg_id);
        PERFORM fn_assert_purchase_peg_transfer_coverage(OLD.to_peg_id);
    END IF;
    IF TG_OP <> 'DELETE' THEN
        PERFORM fn_assert_purchase_transfer_row(NEW.id);
        PERFORM fn_assert_purchase_peg_transfer_coverage(NEW.from_peg_id);
        PERFORM fn_assert_purchase_peg_transfer_coverage(NEW.to_peg_id);
    END IF;
    RETURN NULL;
END;
$$;

CREATE CONSTRAINT TRIGGER trg_purchase_transfer_conservation
    AFTER INSERT OR UPDATE OR DELETE
    ON production_material_peg_transfers
    DEFERRABLE INITIALLY DEFERRED
    FOR EACH ROW EXECUTE FUNCTION fn_check_purchase_transfer_conservation();

-- The service performs receipt conversion inside one transaction, so the
-- conservation assertion is deferred until commit. A naked consumed_qty
-- update can no longer free demand capacity without the exact receipt,
-- reservation and DRAW provenance being present.
CREATE OR REPLACE FUNCTION fn_assert_purchase_peg_receipt_coverage(
    p_peg_id UUID
)
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

    IF v_type = 'PURCHASE_REQUEST_ITEM' AND v_consumed <> 0 THEN
        RAISE EXCEPTION
            'purchase request supply cannot be consumed before order migration'
            USING ERRCODE = '23514',
                  CONSTRAINT =
                      'production_purchase_request_peg_consumption_guard';
    END IF;

    IF v_type <> 'PURCHASE_ORDER_ITEM' THEN
        RETURN;
    END IF;

    SELECT COALESCE(SUM(allocated_qty), 0)
    INTO v_mapped
    FROM production_material_receipt_allocations
    WHERE order_peg_id = p_peg_id
      AND status = 'EFFECTIVE';

    IF v_mapped <> v_consumed THEN
        RAISE EXCEPTION
            'purchase order peg consumption is not exactly covered by receipt allocations'
            USING ERRCODE = '23514',
                  CONSTRAINT =
                      'production_purchase_peg_receipt_coverage_guard';
    END IF;
END;
$$;

CREATE OR REPLACE FUNCTION fn_assert_receipt_reservation_coverage(
    p_reservation_id UUID
)
RETURNS void
LANGUAGE plpgsql
AS $$
DECLARE
    v_committed numeric;
    v_mapped    numeric;
BEGIN
    SELECT CASE WHEN is_deleted THEN 0 ELSE qty - released_qty END
    INTO v_committed
    FROM stock_reservations
    WHERE id = p_reservation_id
      AND owner_type = 'PRODUCTION_MATERIAL_DEMAND';

    IF NOT FOUND THEN
        RETURN;
    END IF;

    SELECT COALESCE(SUM(allocated_qty), 0)
    INTO v_mapped
    FROM production_material_receipt_allocations
    WHERE reservation_id = p_reservation_id
      AND status = 'EFFECTIVE';

    IF v_mapped > v_committed THEN
        RAISE EXCEPTION
            'receipt allocations exceed their production stock reservation'
            USING ERRCODE = '23514',
                  CONSTRAINT =
                      'production_receipt_reservation_capacity_guard';
    END IF;

    IF EXISTS (
        SELECT 1
        FROM production_material_receipt_allocations a
        JOIN production_material_supply_pegs peg
          ON peg.id = a.order_peg_id
        JOIN production_material_demands demand
          ON demand.id = a.demand_id
        JOIN stock_reservations reservation
          ON reservation.id = a.reservation_id
        JOIN purchase_receipt_items receipt_item
          ON receipt_item.id = a.receipt_item_id
        JOIN purchase_receipts receipt
          ON receipt.id = a.receipt_id
        JOIN stock_document_items draw_item
          ON draw_item.id = a.draw_item_id
        JOIN stock_documents draw
          ON draw.id = a.draw_id
        WHERE a.reservation_id = p_reservation_id
          AND a.status = 'EFFECTIVE'
          AND (
              peg.supply_type <> 'PURCHASE_ORDER_ITEM'
              OR peg.demand_id <> a.demand_id
              OR peg.supply_item_id <> receipt_item.order_item_id
              OR demand.package_id <> a.package_id
              OR reservation.demand_id <> a.demand_id
              OR reservation.owner_type <>
                    'PRODUCTION_MATERIAL_DEMAND'
              OR reservation.purpose <> 'PRODUCTION_MATERIAL'
              OR reservation.goods_id <> demand.goods_id
              OR reservation.color_id IS DISTINCT FROM demand.color_id
              OR reservation.warehouse_id <> demand.warehouse_id
              OR reservation.is_deleted
              OR receipt_item.receipt_id <> a.receipt_id
              OR receipt.warehouse_id <> demand.warehouse_id
              OR draw_item.doc_id <> a.draw_id
              OR draw_item.goods_id <> demand.goods_id
              OR draw_item.color_id IS DISTINCT FROM demand.color_id
              OR COALESCE(
                    draw_item.base_qty,
                    draw_item.qty * COALESCE(draw_item.unit_rate, 1)
                 ) <> a.allocated_qty
              OR draw.warehouse_id <> demand.warehouse_id
              OR draw.doc_type <> 'DRAW'
              OR draw.is_deleted
              OR draw.status = -1
              OR draw_item.is_deleted
               OR NOT EXISTS (
                   SELECT 1
                   FROM plan_draw_links draw_link
                   WHERE draw_link.plan_id = demand.plan_id
                     AND draw_link.draw_id = a.draw_id
                     AND NOT draw_link.is_deleted
               )
               OR NOT EXISTS (
                   SELECT 1
                   FROM production_planning_package_documents mapped_document
                   WHERE mapped_document.package_id = a.package_id
                     AND mapped_document.document_type = 'DRAW'
                     AND mapped_document.document_id = a.draw_id
               )
              OR NOT EXISTS (
                  SELECT 1
                  FROM production_planning_package_document_items mapped_item
                  WHERE mapped_item.package_id = a.package_id
                    AND mapped_item.demand_id = a.demand_id
                    AND mapped_item.document_type = 'DRAW'
                    AND mapped_item.document_id = a.draw_id
                    AND mapped_item.document_item_id = a.draw_item_id
              )
          )
    ) THEN
        RAISE EXCEPTION
            'receipt allocation provenance does not match peg, reservation and DRAW'
            USING ERRCODE = '23514',
                  CONSTRAINT =
                      'production_receipt_allocation_provenance_guard';
    END IF;
END;
$$;

CREATE OR REPLACE FUNCTION fn_check_purchase_receipt_conservation()
RETURNS trigger
LANGUAGE plpgsql
AS $$
BEGIN
    IF TG_TABLE_NAME = 'production_material_supply_pegs' THEN
        IF TG_OP <> 'INSERT' THEN
            PERFORM fn_assert_purchase_peg_transfer_coverage(OLD.id);
            PERFORM fn_assert_purchase_peg_receipt_coverage(OLD.id);
        END IF;
        IF TG_OP <> 'DELETE' THEN
            PERFORM fn_assert_purchase_peg_transfer_coverage(NEW.id);
            PERFORM fn_assert_purchase_peg_receipt_coverage(NEW.id);
        END IF;
    ELSIF TG_TABLE_NAME =
            'production_material_receipt_allocations' THEN
        IF TG_OP <> 'INSERT' THEN
            PERFORM fn_assert_purchase_peg_receipt_coverage(
                OLD.order_peg_id);
            PERFORM fn_assert_receipt_reservation_coverage(
                OLD.reservation_id);
        END IF;
        IF TG_OP <> 'DELETE' THEN
            PERFORM fn_assert_purchase_peg_receipt_coverage(
                NEW.order_peg_id);
            PERFORM fn_assert_receipt_reservation_coverage(
                NEW.reservation_id);
        END IF;
    ELSIF TG_TABLE_NAME = 'stock_reservations' THEN
        IF TG_OP <> 'INSERT' THEN
            PERFORM fn_assert_receipt_reservation_coverage(OLD.id);
        END IF;
        IF TG_OP <> 'DELETE' THEN
            PERFORM fn_assert_receipt_reservation_coverage(NEW.id);
        END IF;
    END IF;
    RETURN NULL;
END;
$$;

CREATE CONSTRAINT TRIGGER trg_purchase_peg_receipt_conservation
    AFTER INSERT OR UPDATE OR DELETE
    ON production_material_supply_pegs
    DEFERRABLE INITIALLY DEFERRED
    FOR EACH ROW EXECUTE FUNCTION fn_check_purchase_receipt_conservation();

CREATE CONSTRAINT TRIGGER trg_receipt_allocation_conservation
    AFTER INSERT OR UPDATE OR DELETE
    ON production_material_receipt_allocations
    DEFERRABLE INITIALLY DEFERRED
    FOR EACH ROW EXECUTE FUNCTION fn_check_purchase_receipt_conservation();

CREATE CONSTRAINT TRIGGER trg_receipt_reservation_conservation
    AFTER INSERT OR UPDATE OR DELETE
    ON stock_reservations
    DEFERRABLE INITIALLY DEFERRED
    FOR EACH ROW EXECUTE FUNCTION fn_check_purchase_receipt_conservation();

CREATE OR REPLACE FUNCTION fn_guard_production_receipt_allocation_reversal()
RETURNS trigger
LANGUAGE plpgsql
AS $$
DECLARE
    v_issued numeric;
BEGIN
    IF TG_OP = 'DELETE' THEN
        RAISE EXCEPTION
            'production receipt allocation history cannot be deleted'
            USING ERRCODE = '23514',
                  CONSTRAINT =
                      'production_receipt_allocation_delete_guard';
    END IF;

    IF ROW(
           OLD.receipt_id,
           OLD.receipt_item_id,
           OLD.package_id,
           OLD.demand_id,
           OLD.order_peg_id,
           OLD.reservation_id,
           OLD.draw_id,
           OLD.draw_item_id,
           OLD.allocated_qty,
           OLD.idempotency_key,
           OLD.created_at,
           OLD.created_by
       ) IS DISTINCT FROM ROW(
           NEW.receipt_id,
           NEW.receipt_item_id,
           NEW.package_id,
           NEW.demand_id,
           NEW.order_peg_id,
           NEW.reservation_id,
           NEW.draw_id,
           NEW.draw_item_id,
           NEW.allocated_qty,
           NEW.idempotency_key,
           NEW.created_at,
           NEW.created_by
       )
       OR (OLD.status = 'REVERSED' AND NEW.status <> 'REVERSED') THEN
        RAISE EXCEPTION
            'production receipt allocation history is immutable'
            USING ERRCODE = '23514',
                  CONSTRAINT =
                      'production_receipt_allocation_immutable_guard';
    END IF;

    IF OLD.status = 'EFFECTIVE' AND NEW.status = 'REVERSED' THEN
        SELECT GREATEST(
                   COALESCE(item.issued_qty, 0),
                   COALESCE((
                       SELECT SUM(CASE posting_type
                           WHEN 'ISSUE' THEN qty_base
                           WHEN 'ISSUE_REVERSE' THEN -qty_base
                           ELSE 0 END)
                       FROM production_material_stock_postings
                       WHERE stock_document_item_id = item.id
                         AND posting_type IN ('ISSUE', 'ISSUE_REVERSE')
                   ), 0)
               )
        INTO v_issued
        FROM stock_document_items item
        WHERE item.id = OLD.draw_item_id
        FOR UPDATE;

        IF COALESCE(v_issued, 0) > 0 THEN
            RAISE EXCEPTION
                'received production material has already been issued'
                USING ERRCODE = '23514',
                      CONSTRAINT =
                          'production_receipt_issued_draw_guard';
        END IF;
    END IF;
    RETURN NEW;
END;
$$;

CREATE TRIGGER trg_guard_production_receipt_allocation_reversal
    BEFORE UPDATE OR DELETE
    ON production_material_receipt_allocations
    FOR EACH ROW
    EXECUTE FUNCTION fn_guard_production_receipt_allocation_reversal();

CREATE OR REPLACE FUNCTION fn_guard_purchase_document_supply_reversal()
RETURNS trigger
LANGUAGE plpgsql
AS $$
BEGIN
    IF OLD.status = 1 AND NEW.status = -1 THEN
        IF TG_TABLE_NAME = 'purchase_orders' AND EXISTS (
            SELECT 1
            FROM production_material_peg_transfers transfer
            JOIN purchase_order_items item
              ON item.id = transfer.order_item_id
            WHERE item.order_id = OLD.id
              AND transfer.status = 'EFFECTIVE'
        ) THEN
            RAISE EXCEPTION
                'purchase order production pegs must be reversed first'
                USING ERRCODE = '23514',
                      CONSTRAINT =
                          'production_purchase_order_reversal_guard';
        ELSIF TG_TABLE_NAME = 'purchase_receipts' AND EXISTS (
            SELECT 1
            FROM production_material_receipt_allocations allocation
            WHERE allocation.receipt_id = OLD.id
              AND allocation.status = 'EFFECTIVE'
        ) THEN
            RAISE EXCEPTION
                'purchase receipt production allocations must be reversed first'
                USING ERRCODE = '23514',
                      CONSTRAINT =
                          'production_purchase_receipt_reversal_guard';
        END IF;
    END IF;
    RETURN NEW;
END;
$$;

CREATE TRIGGER trg_guard_purchase_order_supply_reversal
    BEFORE UPDATE OF status
    ON purchase_orders
    FOR EACH ROW
    EXECUTE FUNCTION fn_guard_purchase_document_supply_reversal();

CREATE TRIGGER trg_guard_purchase_receipt_supply_reversal
    BEFORE UPDATE OF status
    ON purchase_receipts
    FOR EACH ROW
    EXECUTE FUNCTION fn_guard_purchase_document_supply_reversal();

CREATE OR REPLACE FUNCTION fn_forbid_production_peg_transfer_delete()
RETURNS trigger
LANGUAGE plpgsql
AS $$
BEGIN
    IF TG_OP = 'DELETE' THEN
        RAISE EXCEPTION 'production peg transfer history cannot be deleted'
            USING ERRCODE = '23514',
                  CONSTRAINT = 'production_peg_transfer_delete_guard';
    END IF;

    IF ROW(
           OLD.demand_id,
           OLD.from_peg_id,
           OLD.to_peg_id,
           OLD.request_item_id,
           OLD.order_item_id,
           OLD.transferred_qty,
           OLD.idempotency_key,
           OLD.created_at,
           OLD.created_by
       ) IS DISTINCT FROM ROW(
           NEW.demand_id,
           NEW.from_peg_id,
           NEW.to_peg_id,
           NEW.request_item_id,
           NEW.order_item_id,
           NEW.transferred_qty,
           NEW.idempotency_key,
           NEW.created_at,
           NEW.created_by
       )
       OR (OLD.status = 'REVERSED' AND NEW.status <> 'REVERSED') THEN
        RAISE EXCEPTION
            'production peg transfer history is immutable'
            USING ERRCODE = '23514',
                  CONSTRAINT =
                      'production_peg_transfer_immutable_guard';
    END IF;
    RETURN NEW;
END;
$$;

CREATE TRIGGER trg_forbid_production_peg_transfer_delete
    BEFORE UPDATE OR DELETE ON production_material_peg_transfers
    FOR EACH ROW EXECUTE FUNCTION fn_forbid_production_peg_transfer_delete();

CREATE OR REPLACE FUNCTION fn_check_receipt_draw_provenance()
RETURNS trigger
LANGUAGE plpgsql
AS $$
DECLARE
    v_reservation_id uuid;
    v_old_identity uuid;
    v_new_identity uuid;
BEGIN
    IF TG_OP <> 'INSERT' THEN
        v_old_identity := CASE
            WHEN TG_TABLE_NAME IN (
                'stock_documents', 'stock_document_items'
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
                'stock_documents', 'stock_document_items'
            ) THEN (to_jsonb(NEW) ->> 'id')::uuid
            WHEN TG_TABLE_NAME = 'plan_draw_links'
                THEN (to_jsonb(NEW) ->> 'draw_id')::uuid
            WHEN TG_TABLE_NAME =
                    'production_planning_package_documents'
                THEN (to_jsonb(NEW) ->> 'document_id')::uuid
            ELSE (to_jsonb(NEW) ->> 'document_item_id')::uuid
        END;
    END IF;

    FOR v_reservation_id IN
        SELECT DISTINCT allocation.reservation_id
        FROM production_material_receipt_allocations allocation
        WHERE allocation.status = 'EFFECTIVE'
          AND (
              (
                  TG_TABLE_NAME IN (
                      'stock_documents',
                      'plan_draw_links',
                      'production_planning_package_documents'
                  )
                  AND (
                      allocation.draw_id = v_old_identity
                      OR allocation.draw_id = v_new_identity
                  )
              )
              OR
              (
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
        PERFORM fn_assert_receipt_reservation_coverage(
            v_reservation_id);
    END LOOP;
    RETURN NULL;
END;
$$;

CREATE CONSTRAINT TRIGGER trg_receipt_stock_document_provenance
    AFTER INSERT OR UPDATE OR DELETE ON stock_documents
    DEFERRABLE INITIALLY DEFERRED
    FOR EACH ROW EXECUTE FUNCTION fn_check_receipt_draw_provenance();
CREATE CONSTRAINT TRIGGER trg_receipt_stock_document_item_provenance
    AFTER INSERT OR UPDATE OR DELETE ON stock_document_items
    DEFERRABLE INITIALLY DEFERRED
    FOR EACH ROW EXECUTE FUNCTION fn_check_receipt_draw_provenance();
CREATE CONSTRAINT TRIGGER trg_receipt_plan_draw_link_provenance
    AFTER INSERT OR UPDATE OR DELETE ON plan_draw_links
    DEFERRABLE INITIALLY DEFERRED
    FOR EACH ROW EXECUTE FUNCTION fn_check_receipt_draw_provenance();
CREATE CONSTRAINT TRIGGER trg_receipt_package_document_provenance
    AFTER INSERT OR UPDATE OR DELETE
    ON production_planning_package_documents
    DEFERRABLE INITIALLY DEFERRED
    FOR EACH ROW EXECUTE FUNCTION fn_check_receipt_draw_provenance();
CREATE CONSTRAINT TRIGGER trg_receipt_package_document_item_provenance
    AFTER INSERT OR UPDATE OR DELETE
    ON production_planning_package_document_items
    DEFERRABLE INITIALLY DEFERRED
    FOR EACH ROW EXECUTE FUNCTION fn_check_receipt_draw_provenance();
