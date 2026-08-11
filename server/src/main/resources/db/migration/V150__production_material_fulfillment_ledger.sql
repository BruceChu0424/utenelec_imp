-- V150: persistent production material fulfillment ledger.
--
-- This migration deliberately evolves stock_reservations into the single
-- physical stock-allocation ledger. It does not introduce a second
-- production_material_locks table. Production owns planning packages and
-- material demands; stock owns physical allocation; purchase/subcontract
-- sources are pegged explicitly and are never guessed from matching goods.

-- ========================= production-owned demand =========================

CREATE TABLE production_planning_packages (
    id                    UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    plan_id               UUID NOT NULL REFERENCES production_plans(id),
    warehouse_id          UUID NOT NULL REFERENCES warehouses(id),
    idempotency_key       TEXT NOT NULL,
    request_hash          TEXT NOT NULL,
    preview_fingerprint   TEXT NOT NULL,
    status                TEXT NOT NULL DEFAULT 'CONFIRMED',
    purchase_request_id   UUID,
    cancel_idempotency_key TEXT,
    reverse_idempotency_key TEXT,
    lifecycle_reason      TEXT,
    lock_version          BIGINT NOT NULL DEFAULT 0,
    created_at            TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_at            TIMESTAMPTZ NOT NULL DEFAULT now(),
    created_by            UUID,
    updated_by            UUID,
    is_deleted            BOOLEAN NOT NULL DEFAULT FALSE,
    deleted_at            TIMESTAMPTZ,
    CONSTRAINT production_planning_packages_status_chk
        CHECK (status IN ('CONFIRMED', 'CANCELLED', 'REVERSED')),
    CONSTRAINT production_planning_packages_key_chk
        CHECK (length(btrim(idempotency_key)) BETWEEN 8 AND 128),
    CONSTRAINT production_planning_packages_hash_chk
        CHECK (length(request_hash) = 64 AND length(preview_fingerprint) = 64)
);

CREATE UNIQUE INDEX uq_production_planning_package_request
    ON production_planning_packages(plan_id, idempotency_key)
    WHERE is_deleted = FALSE;

CREATE UNIQUE INDEX uq_production_planning_package_active_plan
    ON production_planning_packages(plan_id)
    WHERE is_deleted = FALSE AND status = 'CONFIRMED';

CREATE INDEX idx_production_planning_package_warehouse
    ON production_planning_packages(warehouse_id, status)
    WHERE is_deleted = FALSE;

CREATE TABLE production_planning_package_documents (
    id             UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    package_id     UUID NOT NULL REFERENCES production_planning_packages(id) ON DELETE CASCADE,
    document_type  TEXT NOT NULL,
    document_id    UUID NOT NULL,
    document_no    TEXT,
    created_at     TIMESTAMPTZ NOT NULL DEFAULT now(),
    created_by     UUID,
    CONSTRAINT production_planning_package_document_type_chk
        CHECK (document_type IN ('SUBPLAN', 'PURCHASE_REQUEST'))
);

CREATE UNIQUE INDEX uq_production_planning_package_document
    ON production_planning_package_documents(package_id, document_type, document_id);

CREATE UNIQUE INDEX uq_production_planning_package_owned_document
    ON production_planning_package_documents(document_type, document_id);

CREATE TABLE production_material_demands (
    id               UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    package_id       UUID NOT NULL REFERENCES production_planning_packages(id) ON DELETE CASCADE,
    plan_id          UUID NOT NULL REFERENCES production_plans(id),
    warehouse_id     UUID NOT NULL REFERENCES warehouses(id),
    goods_id         UUID NOT NULL REFERENCES goods(id),
    color_id         UUID REFERENCES colors(id),
    unit_id          UUID NOT NULL REFERENCES units(id),
    required_qty     NUMERIC(18,4) NOT NULL,
    released_qty     NUMERIC(18,4) NOT NULL DEFAULT 0,
    need_date        DATE,
    supply_route     TEXT NOT NULL,
    status           TEXT NOT NULL DEFAULT 'OPEN',
    idempotency_key  TEXT NOT NULL,
    lock_version     BIGINT NOT NULL DEFAULT 0,
    created_at       TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_at       TIMESTAMPTZ NOT NULL DEFAULT now(),
    created_by       UUID,
    updated_by       UUID,
    is_deleted       BOOLEAN NOT NULL DEFAULT FALSE,
    deleted_at       TIMESTAMPTZ,
    CONSTRAINT production_material_demand_qty_chk
        CHECK (
            required_qty > 0
            AND released_qty >= 0
            AND released_qty <= required_qty
        ),
    CONSTRAINT production_material_demand_route_chk
        CHECK (supply_route IN ('BUY', 'MAKE', 'SUBCONTRACT')),
    CONSTRAINT production_material_demand_status_chk
        CHECK (status IN (
            'OPEN', 'PARTIAL', 'ALLOCATED', 'WAITING_SUPPLY',
            'FULFILLED', 'RELEASED', 'REVERSED'
        ))
);

CREATE UNIQUE INDEX uq_production_material_demand_dimension
    ON production_material_demands
        (package_id, goods_id, color_id, need_date) NULLS NOT DISTINCT
    WHERE is_deleted = FALSE;

CREATE UNIQUE INDEX uq_production_material_demand_key
    ON production_material_demands(idempotency_key)
    WHERE is_deleted = FALSE;

CREATE INDEX idx_production_material_demand_plan
    ON production_material_demands(plan_id, status)
    WHERE is_deleted = FALSE;

CREATE INDEX idx_production_material_demand_work
    ON production_material_demands(supply_route, need_date, goods_id, color_id)
    WHERE is_deleted = FALSE
      AND status NOT IN ('RELEASED', 'REVERSED', 'FULFILLED');

-- Explicit demand-to-document supply pegs. A matching goods/color is only a
-- candidate until a row exists here.
CREATE TABLE production_material_supply_pegs (
    id               UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    demand_id        UUID NOT NULL REFERENCES production_material_demands(id) ON DELETE CASCADE,
    supply_type      TEXT NOT NULL,
    supply_item_id   UUID NOT NULL,
    allocated_qty    NUMERIC(18,4) NOT NULL,
    consumed_qty     NUMERIC(18,4) NOT NULL DEFAULT 0,
    released_qty     NUMERIC(18,4) NOT NULL DEFAULT 0,
    expected_date    DATE,
    status           TEXT NOT NULL DEFAULT 'EFFECTIVE',
    idempotency_key  TEXT NOT NULL,
    lock_version     BIGINT NOT NULL DEFAULT 0,
    created_at       TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_at       TIMESTAMPTZ NOT NULL DEFAULT now(),
    created_by       UUID,
    updated_by       UUID,
    CONSTRAINT production_material_supply_peg_type_chk
        CHECK (supply_type IN (
            'PURCHASE_REQUEST_ITEM', 'PURCHASE_ORDER_ITEM',
            'SUBCONTRACT_APPLICATION_ITEM', 'SUBCONTRACT_ORDER_ITEM'
        )),
    CONSTRAINT production_material_supply_peg_qty_chk
        CHECK (
            allocated_qty > 0
            AND consumed_qty >= 0
            AND released_qty >= 0
            AND consumed_qty + released_qty <= allocated_qty
        ),
    CONSTRAINT production_material_supply_peg_status_chk
        CHECK (status IN ('EFFECTIVE', 'DONE', 'RELEASED', 'REVERSED')),
    CONSTRAINT production_material_supply_peg_lifecycle_chk
        CHECK (
            (
                status NOT IN ('DONE', 'RELEASED', 'REVERSED')
                OR consumed_qty + released_qty = allocated_qty
            )
            AND (
                status <> 'REVERSED'
                OR (consumed_qty = 0 AND released_qty = allocated_qty)
            )
        )
);

CREATE UNIQUE INDEX uq_production_material_supply_peg_source
    ON production_material_supply_pegs(demand_id, supply_type, supply_item_id)
    WHERE status <> 'REVERSED';

CREATE UNIQUE INDEX uq_production_material_supply_peg_key
    ON production_material_supply_pegs(idempotency_key);

CREATE INDEX idx_production_material_supply_peg_supply
    ON production_material_supply_pegs(supply_type, supply_item_id)
    WHERE status = 'EFFECTIVE';

-- =========================== stock-owned allocation =========================

ALTER TABLE stock_reservations
    ALTER COLUMN order_item_id DROP NOT NULL,
    ADD COLUMN owner_type TEXT,
    ADD COLUMN owner_id UUID,
    ADD COLUMN purpose TEXT,
    ADD COLUMN demand_id UUID,
    ADD COLUMN supply_type TEXT,
    ADD COLUMN supply_id UUID,
    ADD COLUMN idempotency_key TEXT,
    ADD COLUMN release_reason TEXT,
    ADD COLUMN lock_version BIGINT NOT NULL DEFAULT 0;

UPDATE stock_reservations
SET owner_type = 'SALES_ORDER_ITEM',
    owner_id = order_item_id,
    purpose = 'SALES_FULFILLMENT'
WHERE owner_type IS NULL;

ALTER TABLE stock_reservations
    ALTER COLUMN owner_type SET NOT NULL,
    ALTER COLUMN owner_id SET NOT NULL,
    ALTER COLUMN purpose SET NOT NULL,
    ADD CONSTRAINT stock_reservations_owner_type_chk
        CHECK (owner_type IN ('SALES_ORDER_ITEM', 'PRODUCTION_MATERIAL_DEMAND')),
    ADD CONSTRAINT stock_reservations_purpose_chk
        CHECK (purpose IN ('SALES_FULFILLMENT', 'PRODUCTION_MATERIAL')),
    ADD CONSTRAINT stock_reservations_owner_shape_chk
        CHECK (
            (
                owner_type = 'SALES_ORDER_ITEM'
                AND purpose = 'SALES_FULFILLMENT'
                AND order_item_id IS NOT NULL
                AND owner_id = order_item_id
                AND demand_id IS NULL
            )
            OR
            (
                owner_type = 'PRODUCTION_MATERIAL_DEMAND'
                AND purpose = 'PRODUCTION_MATERIAL'
                AND order_item_id IS NULL
                AND demand_id IS NOT NULL
                AND owner_id = demand_id
                AND warehouse_id IS NOT NULL
                AND supply_type = 'STOCK_BALANCE'
                AND supply_id IS NOT NULL
                AND idempotency_key IS NOT NULL
            )
        ),
    ADD CONSTRAINT stock_reservations_production_lifecycle_chk
        CHECK (
            owner_type <> 'PRODUCTION_MATERIAL_DEMAND'
            OR (
                (
                    status = 0
                    OR consumed_qty + released_qty = qty
                )
                AND (
                    is_deleted = FALSE
                    OR (consumed_qty = 0 AND released_qty = qty)
                )
            )
        );

ALTER TABLE stock_reservations
    ADD CONSTRAINT stock_reservations_demand_fk
        FOREIGN KEY (demand_id) REFERENCES production_material_demands(id);

CREATE UNIQUE INDEX uq_stock_reservation_production_key
    ON stock_reservations(idempotency_key)
    WHERE idempotency_key IS NOT NULL;

CREATE UNIQUE INDEX uq_stock_reservation_demand_supply
    ON stock_reservations(demand_id, supply_id)
    WHERE is_deleted = FALSE
      AND owner_type = 'PRODUCTION_MATERIAL_DEMAND';

CREATE INDEX idx_stock_reservation_demand
    ON stock_reservations(demand_id, status)
    WHERE is_deleted = FALSE AND demand_id IS NOT NULL;

-- Existing JPA sales inserts do not map the new generic owner columns. This
-- trigger derives them before NOT NULL/check constraints are evaluated.
CREATE OR REPLACE FUNCTION fn_stock_reservation_owner_defaults()
RETURNS trigger
LANGUAGE plpgsql
AS $$
BEGIN
    IF NEW.order_item_id IS NOT NULL AND NEW.owner_type IS NULL THEN
        NEW.owner_type := 'SALES_ORDER_ITEM';
        NEW.owner_id := NEW.order_item_id;
        NEW.purpose := 'SALES_FULFILLMENT';
    END IF;
    RETURN NEW;
END;
$$;

CREATE TRIGGER trg_stock_reservation_owner_defaults
    BEFORE INSERT OR UPDATE OF order_item_id, owner_type, owner_id, purpose
    ON stock_reservations
    FOR EACH ROW EXECUTE FUNCTION fn_stock_reservation_owner_defaults();

-- Database backstop for physical production allocations. The trigger uses the
-- same goods/color advisory-lock key and namespace as InventoryMutationLock.
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
    v_old_committed numeric := 0;
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

    -- Lifecycle commitment deliberately does not subtract consumed quantity:
    -- fulfillment cannot make the same demand capacity allocatable again.
    v_new_committed := CASE
        WHEN NEW.is_deleted THEN 0
        ELSE NEW.qty - NEW.released_qty
    END;
    v_new_open := CASE
        WHEN NEW.is_deleted OR NEW.status <> 0 THEN 0
        ELSE NEW.qty - NEW.consumed_qty - NEW.released_qty
    END;
    IF TG_OP = 'UPDATE' THEN
        v_old_committed := CASE
            WHEN OLD.is_deleted THEN 0
            ELSE OLD.qty - OLD.released_qty
        END;
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

    SELECT COALESCE(SUM(p.allocated_qty - p.released_qty), 0)
    INTO v_other_supply_demand
    FROM production_material_supply_pegs p
    WHERE p.demand_id = NEW.demand_id;

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

CREATE TRIGGER trg_guard_production_stock_allocation
    BEFORE INSERT OR UPDATE OF
        qty, consumed_qty, released_qty, status, is_deleted,
        goods_id, color_id, warehouse_id, demand_id, supply_id,
        owner_type, owner_id, purpose
    ON stock_reservations
    FOR EACH ROW EXECUTE FUNCTION fn_guard_production_stock_allocation();

-- Explicit supply pegs are bounded both by the demand and by the selected
-- source row. Two different demands may share one source, but never over-peg.
CREATE OR REPLACE FUNCTION fn_guard_production_material_supply_peg()
RETURNS trigger
LANGUAGE plpgsql
AS $$
DECLARE
    v_demand          production_material_demands%ROWTYPE;
    v_source_goods    UUID;
    v_source_color    UUID;
    v_source_qty      numeric;
    v_source_rate     numeric;
    v_new_committed   numeric;
    v_old_committed   numeric := 0;
    v_other_source    numeric;
    v_other_demand    numeric;
    v_stock_demand    numeric;
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

    -- Lifecycle commitment remains allocated after consumption. Only an
    -- explicit release restores source or demand capacity.
    v_new_committed := NEW.allocated_qty - NEW.released_qty;
    IF TG_OP = 'UPDATE' THEN
        v_old_committed := OLD.allocated_qty - OLD.released_qty;
    END IF;
    IF v_new_committed <= v_old_committed THEN
        RETURN NEW;
    END IF;

    SELECT COALESCE(SUM(p.allocated_qty - p.released_qty), 0)
    INTO v_other_source
    FROM production_material_supply_pegs p
    WHERE p.id IS DISTINCT FROM NEW.id
      AND p.supply_type = NEW.supply_type
      AND p.supply_item_id = NEW.supply_item_id;

    IF v_other_source + v_new_committed > v_source_qty * v_source_rate THEN
        RAISE EXCEPTION 'material supply peg exceeds source quantity'
            USING ERRCODE = '23514',
                  CONSTRAINT = 'production_material_supply_peg_capacity_guard';
    END IF;

    SELECT COALESCE(SUM(p.allocated_qty - p.released_qty), 0)
    INTO v_other_demand
    FROM production_material_supply_pegs p
    WHERE p.id IS DISTINCT FROM NEW.id
      AND p.demand_id = NEW.demand_id;

    SELECT COALESCE(SUM(r.qty - r.released_qty), 0)
    INTO v_stock_demand
    FROM stock_reservations r
    WHERE r.demand_id = NEW.demand_id
      AND r.owner_type = 'PRODUCTION_MATERIAL_DEMAND'
      AND r.is_deleted = FALSE;

    IF v_other_demand + v_stock_demand + v_new_committed
       > v_demand.required_qty - v_demand.released_qty THEN
        RAISE EXCEPTION 'material supply peg exceeds demand quantity'
            USING ERRCODE = '23514',
                  CONSTRAINT = 'production_material_supply_peg_demand_capacity_guard';
    END IF;
    RETURN NEW;
END;
$$;

CREATE TRIGGER trg_guard_production_material_supply_peg
    BEFORE INSERT OR UPDATE OF
        demand_id, supply_type, supply_item_id, allocated_qty,
        consumed_qty, released_qty, status
    ON production_material_supply_pegs
    FOR EACH ROW EXECUTE FUNCTION fn_guard_production_material_supply_peg();

-- ============================= availability fix =============================

-- V90 joined warehouse and global reservation groups directly and could
-- duplicate one stock-balance row. The lateral scalar aggregation below
-- subtracts warehouse-local plus global reservations exactly once per row.
CREATE OR REPLACE VIEW v_stock_available AS
SELECT b.warehouse_id,
       b.goods_id,
       b.color_id,
       b.qty AS on_hand_qty,
       b.weight AS on_hand_weight,
       COALESCE(r.reserved_qty, 0) AS reserved_qty,
       b.qty - COALESCE(r.reserved_qty, 0) AS available_qty
FROM stock_balances b
LEFT JOIN LATERAL (
    SELECT SUM(sr.qty - sr.consumed_qty - sr.released_qty) AS reserved_qty
    FROM stock_reservations sr
    WHERE sr.is_deleted = FALSE
      AND sr.status = 0
      AND sr.goods_id = b.goods_id
      AND sr.color_id IS NOT DISTINCT FROM b.color_id
      AND (sr.warehouse_id IS NULL OR sr.warehouse_id = b.warehouse_id)
) r ON TRUE;

COMMENT ON VIEW v_stock_available IS
    'Warehouse availability: balance minus active warehouse-local and global allocations, each counted once.';

-- ============================== CQRS read view ==============================

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
           SUM(allocated_qty - released_qty) AS committed_qty,
           SUM(consumed_qty) AS fulfilled_qty,
           MIN(expected_date)
               FILTER (WHERE status NOT IN ('RELEASED', 'REVERSED')) AS expected_date,
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
           COALESCE(pt.fulfilled_qty, 0) AS supply_fulfilled_qty,
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
       stock_fulfilled_qty + supply_fulfilled_qty AS fulfilled_qty,
       supply_committed_qty AS supply_pegged_qty,
       GREATEST(required_qty - stock_committed_qty - supply_committed_qty, 0) AS open_qty,
       CASE
           WHEN required_qty - stock_committed_qty - supply_committed_qty > 0
                THEN 'UNPEGGED'
           WHEN supply_committed_qty > supply_fulfilled_qty
                THEN 'WAITING_SUPPLY'
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

COMMENT ON VIEW v_fulfillment_workbench IS
    'Rebuildable warehouse/purchase/subcontract task read model derived from authoritative demand, allocation and supply-peg ledgers.';

-- Permissions reuse existing module read authorities; no broad cross-module
-- permission is introduced.

COMMENT ON TABLE production_planning_packages IS
    'Idempotent atomic production planning confirmations and lifecycle reversals.';
COMMENT ON TABLE production_material_demands IS
    'Authoritative production material requirements in base units.';
COMMENT ON TABLE production_material_supply_pegs IS
    'Explicit demand-to-purchase/subcontract source allocations; matching dimensions alone never imply a peg.';
COMMENT ON COLUMN stock_reservations.owner_type IS
    'Generic allocation owner. SALES_ORDER_ITEM and PRODUCTION_MATERIAL_DEMAND share one availability ledger.';

-- Demand-side backstop: demand reduction/release is serialized by the row
-- update lock and may never strand lifecycle commitments.
CREATE OR REPLACE FUNCTION fn_guard_production_material_demand_update()
RETURNS trigger
LANGUAGE plpgsql
AS $$
DECLARE
    v_stock_committed numeric;
    v_supply_committed numeric;
BEGIN
    SELECT COALESCE(SUM(r.qty - r.released_qty), 0)
    INTO v_stock_committed
    FROM stock_reservations r
    WHERE r.demand_id = OLD.id
      AND r.owner_type = 'PRODUCTION_MATERIAL_DEMAND'
      AND r.is_deleted = FALSE;

    SELECT COALESCE(SUM(p.allocated_qty - p.released_qty), 0)
    INTO v_supply_committed
    FROM production_material_supply_pegs p
    WHERE p.demand_id = OLD.id;

    IF (
        OLD.goods_id IS DISTINCT FROM NEW.goods_id
        OR OLD.color_id IS DISTINCT FROM NEW.color_id
        OR OLD.warehouse_id IS DISTINCT FROM NEW.warehouse_id
        OR OLD.unit_id IS DISTINCT FROM NEW.unit_id
    ) AND v_stock_committed + v_supply_committed > 0 THEN
        RAISE EXCEPTION 'allocated production demand dimensions are immutable'
            USING ERRCODE = '23514',
                  CONSTRAINT = 'production_material_demand_dimension_guard';
    END IF;

    IF v_stock_committed + v_supply_committed
       > NEW.required_qty - NEW.released_qty THEN
        RAISE EXCEPTION 'production demand release exceeds uncommitted quantity'
            USING ERRCODE = '23514',
                  CONSTRAINT = 'production_material_demand_capacity_guard';
    END IF;

    IF (
        NEW.is_deleted
        OR NEW.status IN ('RELEASED', 'REVERSED')
    ) AND v_stock_committed + v_supply_committed > 0 THEN
        RAISE EXCEPTION 'committed production demand cannot be deleted or closed'
            USING ERRCODE = '23514',
                  CONSTRAINT = 'production_material_demand_lifecycle_guard';
    END IF;
    RETURN NEW;
END;
$$;

CREATE TRIGGER trg_guard_production_material_demand_update
    BEFORE UPDATE OF
        goods_id, color_id, warehouse_id, unit_id,
        required_qty, released_qty, status, is_deleted
    ON production_material_demands
    FOR EACH ROW EXECUTE FUNCTION fn_guard_production_material_demand_update();
