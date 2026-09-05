-- V472: split exact pre-plan demand from optional public surplus and add
-- explicit shared-future claims.  requested_qty and action allocations remain
-- the exact demand authority; public_surplus_qty never becomes an entitlement
-- until another analysis explicitly creates a SHARED_FUTURE_CLAIM action.

ALTER TABLE preplan_supply_actions
    ADD COLUMN public_surplus_qty NUMERIC(18,4) NOT NULL DEFAULT 0,
    ADD COLUMN public_surplus_external_item_id UUID,
    ADD COLUMN claim_source_action_id UUID,
    ADD COLUMN operation_type TEXT NOT NULL DEFAULT 'SUPPLY';

ALTER TABLE preplan_supply_actions
    ADD CONSTRAINT preplan_supply_action_claim_source_fk
        FOREIGN KEY (claim_source_action_id)
        REFERENCES preplan_supply_actions(id) ON DELETE RESTRICT
        NOT VALID,
    ADD CONSTRAINT preplan_supply_action_operation_type_chk CHECK (
        operation_type IN ('SUPPLY', 'SHARED_FUTURE_CLAIM')
    ) NOT VALID,
    ADD CONSTRAINT preplan_supply_action_public_surplus_qty_chk CHECK (
        public_surplus_qty >= 0
        AND (public_surplus_qty = 0 OR route IN ('BUY','SUBCONTRACT'))
    ) NOT VALID,
    ADD CONSTRAINT preplan_supply_action_operation_shape_chk CHECK (
        (operation_type = 'SUPPLY' AND claim_source_action_id IS NULL)
        OR
        (operation_type = 'SHARED_FUTURE_CLAIM'
         AND claim_source_action_id IS NOT NULL
         AND requested_qty > 0
         AND public_surplus_qty = 0
         AND public_surplus_external_item_id IS NULL
         AND safety_replenishment_qty = 0
         AND route IN ('BUY','SUBCONTRACT'))
    ) NOT VALID;

ALTER TABLE preplan_supply_actions
    DROP CONSTRAINT preplan_supply_action_qty_chk,
    ADD CONSTRAINT preplan_supply_action_qty_chk CHECK (
        requested_qty >= 0
        AND safety_replenishment_qty >= 0
        AND public_surplus_qty >= 0
        AND requested_qty + safety_replenishment_qty + public_surplus_qty > 0
    ) NOT VALID;

ALTER TABLE preplan_supply_actions
    VALIDATE CONSTRAINT preplan_supply_action_claim_source_fk;
ALTER TABLE preplan_supply_actions
    VALIDATE CONSTRAINT preplan_supply_action_operation_type_chk;
ALTER TABLE preplan_supply_actions
    VALIDATE CONSTRAINT preplan_supply_action_public_surplus_qty_chk;
ALTER TABLE preplan_supply_actions
    VALIDATE CONSTRAINT preplan_supply_action_operation_shape_chk;
ALTER TABLE preplan_supply_actions
    VALIDATE CONSTRAINT preplan_supply_action_qty_chk;

CREATE INDEX idx_preplan_supply_action_claim_source
    ON preplan_supply_actions(claim_source_action_id, status, created_at, id)
    WHERE claim_source_action_id IS NOT NULL;
CREATE INDEX idx_preplan_supply_action_public_surplus
    ON preplan_supply_actions(
        warehouse_id, goods_id, color_id, unit_id, route, status, id)
    WHERE operation_type = 'SUPPLY' AND status <> 'CANCELLED';

ALTER TABLE production_material_analysis_commands
    DROP CONSTRAINT production_material_analysis_command_operation_chk,
    ADD CONSTRAINT production_material_analysis_command_operation_chk CHECK (
        operation IN (
            'PREVIEW', 'ROUTE', 'REALLOCATE', 'NOTIFY', 'GENERATE_PLAN',
            'CANCEL_ANALYSIS', 'CANCEL_ACTION',
            'BORROW', 'BORROW_REVOKE',
            'CROSS_REALLOCATE', 'CROSS_REALLOCATE_REVOKE',
            'CLAIM_SHARED_FUTURE'
        )
    ) NOT VALID;
ALTER TABLE production_material_analysis_commands
    VALIDATE CONSTRAINT production_material_analysis_command_operation_chk;

-- Explicit authority catalog.  Flutter constants or super-admin fallbacks do
-- not make a permission assignable; the database catalog and page surface are
-- the authority used by ordinary accounts.
INSERT INTO permissions
    (code, name, module, category, sort_order, action_type, description,
     active, assignable, bulk_assignable, sensitivity)
VALUES
    ('production_material_analysis:over_supply',
     '物料分析公共超量备货', '生产管理', '物料分析', 218,
     'EXECUTE',
     '允许将采购或无子层委外的超需求数量单独下达为公共备货；不得进入本分析精确需求分摊',
     TRUE, TRUE, FALSE, 'NORMAL'),
    ('production_material_analysis:claim_shared_future',
     '物料分析采用公共在途', '生产管理', '物料分析', 219,
     'EXECUTE',
     '允许在同仓、同路线、同货品颜色单位且按期的范围内，显式采用其它分析已批准公共在途',
     TRUE, TRUE, TRUE, 'NORMAL')
ON CONFLICT (code) DO UPDATE
SET name = EXCLUDED.name,
    module = EXCLUDED.module,
    category = EXCLUDED.category,
    sort_order = EXCLUDED.sort_order,
    action_type = EXCLUDED.action_type,
    description = EXCLUDED.description,
    active = EXCLUDED.active,
    assignable = EXCLUDED.assignable,
    bulk_assignable = EXCLUDED.bulk_assignable,
    sensitivity = EXCLUDED.sensitivity;

INSERT INTO department_permissions(department_id, permission_id)
SELECT department.id, permission.id
FROM departments department
JOIN permissions permission
  ON (permission.code = 'production_material_analysis:over_supply'
      AND department.code IN ('GM','SUB_PLAN'))
  OR (permission.code = 'production_material_analysis:claim_shared_future'
      AND department.code IN ('GM','DEPT_PMC','SUB_PLAN'))
WHERE department.is_deleted = FALSE
ON CONFLICT DO NOTHING;

INSERT INTO permission_surface_permissions(surface_id, permission_id)
SELECT surface.id, permission.id
FROM permission_surfaces surface
JOIN permissions permission
  ON permission.code IN (
      'production_material_analysis:over_supply',
      'production_material_analysis:claim_shared_future')
WHERE surface.surface_key = 'production.material-analysis'
ON CONFLICT (surface_id, permission_id) DO NOTHING;

DROP INDEX IF EXISTS idx_production_material_analysis_material_last_route;
CREATE INDEX idx_production_material_analysis_material_last_route
    ON production_material_analysis_materials(
        goods_id, color_id, unit_id, route_confirmed_at DESC,
        created_at DESC, id DESC)
    WHERE confirmed_route IS NOT NULL AND active = TRUE;

-- A single external request/application line is the only historical shape from
-- which downstream commercial over-ordering can be inferred without guessing.
WITH source_shape AS (
    SELECT action.id AS action_id,
           min(allocation.external_item_id::text)::uuid AS external_item_id,
           count(DISTINCT allocation.external_item_id) AS item_count,
           count(DISTINCT other_action.id) AS claimant_count,
           action.route, action.requested_qty
    FROM preplan_supply_actions action
    JOIN preplan_supply_action_allocations allocation
      ON allocation.action_id = action.id
     AND allocation.external_item_id IS NOT NULL
    LEFT JOIN preplan_supply_action_allocations other_allocation
      ON other_allocation.external_item_id = allocation.external_item_id
     AND other_allocation.action_id <> allocation.action_id
    LEFT JOIN preplan_supply_actions other_action
      ON other_action.id = other_allocation.action_id
     AND other_action.status <> 'CANCELLED'
    WHERE action.operation_type = 'SUPPLY'
      AND action.route IN ('BUY','SUBCONTRACT')
      AND action.status <> 'CANCELLED'
    GROUP BY action.id, action.route, action.requested_qty
), candidate AS (
    SELECT shape.*,
           CASE shape.route
             WHEN 'BUY' THEN COALESCE((
                 SELECT SUM(src.alloc_qty * COALESCE(order_item.unit_rate,1))
                 FROM purchase_order_item_sources src
                 JOIN purchase_order_items order_item
                   ON order_item.id = src.order_item_id
                  AND order_item.is_deleted = FALSE
                 JOIN purchase_orders order_header
                   ON order_header.id = order_item.order_id
                  AND order_header.status = 1
                  AND order_header.is_deleted = FALSE
                 WHERE src.request_item_id = shape.external_item_id
             ),0)
             WHEN 'SUBCONTRACT' THEN COALESCE((
                 SELECT SUM(src.alloc_qty * COALESCE(order_item.unit_rate,1))
                 FROM subcontract_order_item_sources src
                 JOIN subcontract_order_items order_item
                   ON order_item.id = src.order_item_id
                  AND order_item.is_deleted = FALSE
                 JOIN subcontract_orders order_header
                   ON order_header.id = order_item.order_id
                  AND order_header.status = 1
                  AND order_header.is_deleted = FALSE
                 WHERE src.application_item_id = shape.external_item_id
             ),0)
             ELSE 0
           END AS approved_base_qty
    FROM source_shape shape
), proven AS (
    SELECT action_id, external_item_id,
           approved_base_qty - requested_qty AS public_surplus_qty
    FROM candidate
    WHERE item_count = 1
      AND claimant_count = 0
      AND approved_base_qty > requested_qty
)
UPDATE preplan_supply_actions action
SET public_surplus_qty = proven.public_surplus_qty,
    public_surplus_external_item_id = proven.external_item_id
FROM proven
WHERE action.id = proven.action_id
  AND action.public_surplus_qty = 0
  AND (action.route <> 'SUBCONTRACT' OR NOT EXISTS (
      SELECT 1 FROM goods_bom_items bom
      WHERE bom.goods_id = action.goods_id AND bom.is_deleted = FALSE));

CREATE VIEW v_preplan_public_surplus_migration_issues AS
WITH source_shape AS (
    SELECT action.id AS action_id,
           action.analysis_id,
           action.route,
           action.requested_qty,
           count(DISTINCT allocation.external_item_id) AS external_item_count,
           count(DISTINCT other_action.id) AS other_action_count
    FROM preplan_supply_actions action
    JOIN preplan_supply_action_allocations allocation
      ON allocation.action_id = action.id
     AND allocation.external_item_id IS NOT NULL
    LEFT JOIN preplan_supply_action_allocations other_allocation
      ON other_allocation.external_item_id = allocation.external_item_id
     AND other_allocation.action_id <> action.id
    LEFT JOIN preplan_supply_actions other_action
      ON other_action.id = other_allocation.action_id
     AND other_action.status <> 'CANCELLED'
    WHERE action.route IN ('BUY','SUBCONTRACT')
      AND action.status <> 'CANCELLED'
    GROUP BY action.id, action.analysis_id, action.route, action.requested_qty
)
SELECT action_id, analysis_id, route, requested_qty,
       external_item_count, other_action_count,
       CASE
         WHEN external_item_count <> 1 THEN 'MULTIPLE_EXTERNAL_ITEMS'
         WHEN other_action_count <> 0 THEN 'SHARED_EXTERNAL_ITEM'
         ELSE 'REVIEW_REQUIRED'
       END AS issue_code
FROM source_shape
WHERE external_item_count <> 1 OR other_action_count <> 0
UNION ALL
SELECT action.id, action.analysis_id, action.route, action.requested_qty,
       (SELECT count(DISTINCT allocation.external_item_id)
        FROM preplan_supply_action_allocations allocation
        WHERE allocation.action_id = action.id
          AND allocation.external_item_id IS NOT NULL),
       0,
       CASE WHEN action.route = 'SUBCONTRACT' AND EXISTS (
           SELECT 1 FROM goods_bom_items bom
           WHERE bom.goods_id = action.goods_id AND bom.is_deleted = FALSE)
         THEN 'SUBCONTRACT_WITH_SUPPLY_BOM'
         ELSE 'APPROVED_OVERAGE_NOT_BACKFILLED' END
FROM preplan_supply_actions action
WHERE action.operation_type = 'SUPPLY'
  AND action.route IN ('BUY','SUBCONTRACT')
  AND action.status <> 'CANCELLED'
  AND action.public_surplus_qty = 0
  AND CASE action.route
      WHEN 'BUY' THEN COALESCE((
          SELECT SUM(src.alloc_qty * COALESCE(order_item.unit_rate,1))
          FROM preplan_supply_action_allocations allocation
          JOIN purchase_order_item_sources src
            ON src.request_item_id = allocation.external_item_id
          JOIN purchase_order_items order_item
            ON order_item.id = src.order_item_id AND order_item.is_deleted = FALSE
          JOIN purchase_orders order_header
            ON order_header.id = order_item.order_id
           AND order_header.status = 1 AND order_header.is_deleted = FALSE
          WHERE allocation.action_id = action.id),0)
      ELSE COALESCE((
          SELECT SUM(src.alloc_qty * COALESCE(order_item.unit_rate,1))
          FROM preplan_supply_action_allocations allocation
          JOIN subcontract_order_item_sources src
            ON src.application_item_id = allocation.external_item_id
          JOIN subcontract_order_items order_item
            ON order_item.id = src.order_item_id AND order_item.is_deleted = FALSE
          JOIN subcontract_orders order_header
            ON order_header.id = order_item.order_id
           AND order_header.status = 1 AND order_header.is_deleted = FALSE
          WHERE allocation.action_id = action.id),0)
      END > action.requested_qty;

-- Approved order quantity above exact demand is the maximum public capacity.
-- It intentionally ignores order_header.warehouse_id: new orders no longer own
-- a warehouse; the source action/request warehouse is the pre-receipt intent.
CREATE OR REPLACE FUNCTION fn_preplan_public_surplus_approved_capacity(
    p_action_id UUID
) RETURNS NUMERIC
LANGUAGE plpgsql
STABLE
AS $$
DECLARE
    source_action preplan_supply_actions%ROWTYPE;
    approved_qty NUMERIC(18,4) := 0;
    demand_item_id UUID;
    separate_public_item BOOLEAN;
BEGIN
    SELECT * INTO source_action
    FROM preplan_supply_actions WHERE id = p_action_id;
    IF source_action.id IS NULL OR source_action.operation_type <> 'SUPPLY'
       OR source_action.route NOT IN ('BUY','SUBCONTRACT') THEN
        RETURN 0;
    END IF;
    SELECT min(allocation.external_item_id::text)::uuid
    INTO demand_item_id
    FROM preplan_supply_action_allocations allocation
    WHERE allocation.action_id = source_action.id
      AND allocation.external_item_id IS NOT NULL;
    separate_public_item := source_action.public_surplus_external_item_id IS NOT NULL
        AND source_action.public_surplus_external_item_id
            IS DISTINCT FROM demand_item_id;
    IF source_action.route = 'BUY' THEN
        SELECT COALESCE(SUM(fn_purchase_order_source_share(
                   order_item.id, src.request_item_id,
                   order_item.qty * COALESCE(order_item.unit_rate,1))),0)
        INTO approved_qty
        FROM purchase_order_item_sources src
        JOIN purchase_order_items order_item ON order_item.id = src.order_item_id
        JOIN purchase_orders order_header ON order_header.id = order_item.order_id
        WHERE order_header.status = 1 AND order_header.is_deleted = FALSE
          AND order_item.is_deleted = FALSE
          AND src.request_item_id = CASE WHEN separate_public_item
              THEN source_action.public_surplus_external_item_id
              ELSE demand_item_id END;
    ELSE
        SELECT COALESCE(SUM(fn_subcontract_order_source_share(
                   order_item.id, src.application_item_id,
                   order_item.qty * COALESCE(order_item.unit_rate,1))),0)
        INTO approved_qty
        FROM subcontract_order_item_sources src
        JOIN subcontract_order_items order_item ON order_item.id = src.order_item_id
        JOIN subcontract_orders order_header ON order_header.id = order_item.order_id
        WHERE order_header.status = 1 AND order_header.is_deleted = FALSE
          AND order_item.is_deleted = FALSE
          AND src.application_item_id = CASE WHEN separate_public_item
              THEN source_action.public_surplus_external_item_id
              ELSE demand_item_id END;
    END IF;
    RETURN LEAST(
        source_action.public_surplus_qty,
        CASE WHEN separate_public_item THEN approved_qty
             ELSE GREATEST(approved_qty - source_action.requested_qty, 0)
        END);
END;
$$;

CREATE OR REPLACE FUNCTION fn_preplan_public_surplus_open_qty(
    p_action_id UUID
) RETURNS NUMERIC
LANGUAGE plpgsql
STABLE
AS $$
DECLARE
    source_action preplan_supply_actions%ROWTYPE;
    open_qty NUMERIC(18,4) := 0;
    exact_demand NUMERIC(18,4) := 0;
    demand_open NUMERIC(18,4) := 0;
    demand_item_id UUID;
    separate_public_item BOOLEAN;
BEGIN
    SELECT * INTO source_action
    FROM preplan_supply_actions WHERE id = p_action_id;
    IF source_action.id IS NULL THEN RETURN 0; END IF;
    SELECT min(allocation.external_item_id::text)::uuid
    INTO demand_item_id
    FROM preplan_supply_action_allocations allocation
    WHERE allocation.action_id = source_action.id
      AND allocation.external_item_id IS NOT NULL;
    separate_public_item := source_action.public_surplus_external_item_id IS NOT NULL
        AND source_action.public_surplus_external_item_id
            IS DISTINCT FROM demand_item_id;

    SELECT COALESCE(SUM(CASE
               WHEN reservation.release_reason = 'TRANSFERRED_TO_PLAN' THEN exact.qty
               ELSE GREATEST(reservation.qty - reservation.consumed_qty
                                      - reservation.released_qty,0)
           END),0)
    INTO exact_demand
    FROM preplan_supply_action_allocations allocation
    JOIN preplan_analysis_stock_exact_pegs exact
      ON exact.supply_action_allocation_id = allocation.id
    JOIN stock_reservations reservation
      ON reservation.id = exact.stock_reservation_id
     AND reservation.is_deleted = FALSE
    WHERE allocation.action_id = source_action.id
      AND (reservation.status = 0
           OR reservation.release_reason = 'TRANSFERRED_TO_PLAN');
    demand_open := GREATEST(source_action.requested_qty - exact_demand, 0);

    IF source_action.route = 'BUY' THEN
        SELECT COALESCE(SUM(GREATEST(
                   fn_purchase_order_source_share(
                       order_item.id, src.request_item_id,
                       COALESCE(order_item.qty,0)
                           * COALESCE(order_item.unit_rate,1))
                   - fn_purchase_order_source_share(
                       order_item.id, src.request_item_id,
                       GREATEST(COALESCE(order_item.received_qty,0)
                           - COALESCE(order_item.returned_qty,0),0)
                           * COALESCE(order_item.unit_rate,1)), 0)),0)
        INTO open_qty
        FROM purchase_order_item_sources src
        JOIN purchase_order_items order_item ON order_item.id = src.order_item_id
        JOIN purchase_orders order_header ON order_header.id = order_item.order_id
        WHERE order_header.status = 1 AND order_header.is_deleted = FALSE
          AND order_header.is_closed = FALSE
          AND order_item.is_deleted = FALSE
          AND src.request_item_id = CASE WHEN separate_public_item
              THEN source_action.public_surplus_external_item_id
              ELSE demand_item_id END;
    ELSIF source_action.route = 'SUBCONTRACT' THEN
        SELECT COALESCE(SUM(GREATEST(
                   fn_subcontract_order_source_share(
                       order_item.id, src.application_item_id,
                       COALESCE(order_item.qty,0)
                           * COALESCE(order_item.unit_rate,1))
                   - fn_subcontract_order_source_share(
                       order_item.id, src.application_item_id,
                       GREATEST(COALESCE(order_item.received_qty,0)
                           - COALESCE(order_item.returned_qty,0),0)
                           * COALESCE(order_item.unit_rate,1)), 0)),0)
        INTO open_qty
        FROM subcontract_order_item_sources src
        JOIN subcontract_order_items order_item ON order_item.id = src.order_item_id
        JOIN subcontract_orders order_header ON order_header.id = order_item.order_id
        WHERE order_header.status = 1 AND order_header.is_deleted = FALSE
          AND order_header.is_closed = FALSE
          AND order_item.is_deleted = FALSE
          AND src.application_item_id = CASE WHEN separate_public_item
              THEN source_action.public_surplus_external_item_id
              ELSE demand_item_id END;
    END IF;
    RETURN LEAST(fn_preplan_public_surplus_approved_capacity(source_action.id),
                 CASE WHEN separate_public_item THEN open_qty
                      ELSE GREATEST(open_qty - demand_open,0) END);
END;
$$;

CREATE OR REPLACE FUNCTION fn_preplan_action_effective_exact_qty(
    p_action_id UUID
) RETURNS NUMERIC
LANGUAGE sql
STABLE
AS $$
    SELECT COALESCE(SUM(CASE
               WHEN reservation.release_reason = 'TRANSFERRED_TO_PLAN' THEN exact.qty
               ELSE GREATEST(reservation.qty - reservation.consumed_qty
                                      - reservation.released_qty,0)
           END),0)
    FROM preplan_supply_action_allocations allocation
    JOIN preplan_analysis_stock_exact_pegs exact
      ON exact.supply_action_allocation_id = allocation.id
    JOIN stock_reservations reservation
      ON reservation.id = exact.stock_reservation_id
     AND reservation.is_deleted = FALSE
    WHERE allocation.action_id = p_action_id
      AND (reservation.status = 0
           OR reservation.release_reason = 'TRANSFERRED_TO_PLAN');
$$;

CREATE OR REPLACE FUNCTION fn_preplan_allocation_effective_exact_qty(
    p_allocation_id UUID
) RETURNS NUMERIC
LANGUAGE sql
STABLE
AS $$
    SELECT COALESCE(SUM(CASE
               WHEN reservation.release_reason = 'TRANSFERRED_TO_PLAN' THEN exact.qty
               ELSE GREATEST(reservation.qty - reservation.consumed_qty
                                      - reservation.released_qty,0)
           END),0)
    FROM preplan_analysis_stock_exact_pegs exact
    JOIN stock_reservations reservation
      ON reservation.id = exact.stock_reservation_id
     AND reservation.is_deleted = FALSE
    WHERE exact.supply_action_allocation_id = p_allocation_id
      AND (reservation.status = 0
           OR reservation.release_reason = 'TRANSFERRED_TO_PLAN');
$$;

CREATE VIEW v_preplan_public_surplus_source_state AS
WITH source AS (
    SELECT action.*,
           fn_preplan_public_surplus_approved_capacity(action.id) AS approved_capacity_qty,
           fn_preplan_public_surplus_open_qty(action.id) AS approved_open_qty
    FROM preplan_supply_actions action
    WHERE action.operation_type = 'SUPPLY'
      AND action.route IN ('BUY','SUBCONTRACT')
      AND action.status <> 'CANCELLED'
), claim AS (
    SELECT claim_source_action_id AS source_action_id,
           SUM(requested_qty)::numeric AS claimed_qty,
           SUM(GREATEST(requested_qty
                   - fn_preplan_action_effective_exact_qty(id),0))::numeric
               AS claim_open_qty
    FROM preplan_supply_actions
    WHERE operation_type = 'SHARED_FUTURE_CLAIM'
      AND status <> 'CANCELLED'
    GROUP BY claim_source_action_id
), eta AS (
    SELECT source.id AS source_action_id,
           min(candidate.eta) AS expected_date
    FROM source
    LEFT JOIN LATERAL (
        SELECT COALESCE(order_item.deliver_date, order_header.deliver_date) AS eta
        FROM purchase_order_item_sources src
        JOIN purchase_order_items order_item ON order_item.id = src.order_item_id
        JOIN purchase_orders order_header ON order_header.id = order_item.order_id
        WHERE source.route = 'BUY'
          AND src.request_item_id = source.public_surplus_external_item_id
          AND order_header.status = 1 AND order_header.is_deleted = FALSE
          AND order_header.is_closed = FALSE
          AND order_item.is_deleted = FALSE
          AND fn_purchase_order_source_share(
                  order_item.id, src.request_item_id,
                  COALESCE(order_item.qty,0)
                      * COALESCE(order_item.unit_rate,1))
              - fn_purchase_order_source_share(
                  order_item.id, src.request_item_id,
                  GREATEST(COALESCE(order_item.received_qty,0)
                      - COALESCE(order_item.returned_qty,0),0)
                      * COALESCE(order_item.unit_rate,1)) > 0
        UNION ALL
        SELECT COALESCE(order_item.deliver_date, order_header.deliver_date)
        FROM subcontract_order_item_sources src
        JOIN subcontract_order_items order_item ON order_item.id = src.order_item_id
        JOIN subcontract_orders order_header ON order_header.id = order_item.order_id
        WHERE source.route = 'SUBCONTRACT'
          AND src.application_item_id = source.public_surplus_external_item_id
          AND order_header.status = 1 AND order_header.is_deleted = FALSE
          AND order_header.is_closed = FALSE
          AND order_item.is_deleted = FALSE
          AND fn_subcontract_order_source_share(
                  order_item.id, src.application_item_id,
                  COALESCE(order_item.qty,0)
                      * COALESCE(order_item.unit_rate,1))
              - fn_subcontract_order_source_share(
                  order_item.id, src.application_item_id,
                  GREATEST(COALESCE(order_item.received_qty,0)
                      - COALESCE(order_item.returned_qty,0),0)
                      * COALESCE(order_item.unit_rate,1)) > 0
    ) candidate ON TRUE
    GROUP BY source.id
)
SELECT source.id AS source_action_id,
       source.analysis_id AS source_analysis_id,
       source.warehouse_id, source.goods_id, source.color_id, source.unit_id,
       source.route, source.external_document_type,
       source.external_document_id, source.external_document_no,
       source.public_surplus_external_item_id AS claim_external_item_id,
       source.approved_capacity_qty,
       source.approved_open_qty,
       COALESCE(claim.claimed_qty,0)::numeric AS claimed_qty,
       COALESCE(claim.claim_open_qty,0)::numeric AS claim_open_qty,
       LEAST(
           GREATEST(source.approved_capacity_qty
                        - COALESCE(claim.claimed_qty,0),0),
           GREATEST(source.approved_open_qty
                        - COALESCE(claim.claim_open_qty,0),0)
       )::numeric AS available_to_claim_qty,
       eta.expected_date,
       source.created_at
FROM source
LEFT JOIN claim ON claim.source_action_id = source.id
LEFT JOIN eta ON eta.source_action_id = source.id;

CREATE OR REPLACE FUNCTION fn_validate_preplan_shared_future_claim()
RETURNS trigger
LANGUAGE plpgsql
AS $$
DECLARE
    claim_action preplan_supply_actions%ROWTYPE;
    source_action preplan_supply_actions%ROWTYPE;
    allocation_total NUMERIC(18,4);
    other_claim_total NUMERIC(18,4);
    expected_item UUID;
    allocation_item_count INTEGER;
BEGIN
    IF TG_TABLE_NAME = 'preplan_supply_action_allocations' THEN
        SELECT * INTO claim_action FROM preplan_supply_actions
        WHERE id = COALESCE(NEW.action_id, OLD.action_id);
    ELSE
        claim_action := NEW;
    END IF;
    IF claim_action.operation_type <> 'SHARED_FUTURE_CLAIM' THEN RETURN NULL; END IF;
    SELECT * INTO source_action FROM preplan_supply_actions
    WHERE id = claim_action.claim_source_action_id FOR UPDATE;
    SELECT COALESCE(SUM(allocated_qty),0),
           min(external_item_id::text)::uuid,
           count(DISTINCT external_item_id)
    INTO allocation_total, expected_item, allocation_item_count
    FROM preplan_supply_action_allocations
    WHERE action_id = claim_action.id;
    SELECT COALESCE(SUM(requested_qty),0) INTO other_claim_total
    FROM preplan_supply_actions
    WHERE claim_source_action_id = source_action.id
      AND operation_type = 'SHARED_FUTURE_CLAIM'
      AND status <> 'CANCELLED'
      AND id <> claim_action.id;
    IF source_action.id IS NULL
       OR source_action.operation_type <> 'SUPPLY'
       OR source_action.public_surplus_qty <= 0
       OR source_action.status = 'CANCELLED'
       OR source_action.analysis_id = claim_action.analysis_id
       OR source_action.warehouse_id <> claim_action.warehouse_id
       OR source_action.goods_id <> claim_action.goods_id
       OR source_action.color_id IS DISTINCT FROM claim_action.color_id
       OR source_action.unit_id <> claim_action.unit_id
       OR source_action.route <> claim_action.route
       OR source_action.external_document_type <> claim_action.external_document_type
       OR source_action.external_document_id <> claim_action.external_document_id
       OR claim_action.status NOT IN ('CREATED','IN_PROGRESS','DONE','CANCELLED')
       OR expected_item IS NULL
       OR allocation_item_count <> 1
       OR expected_item IS DISTINCT FROM
            source_action.public_surplus_external_item_id
       OR allocation_total IS DISTINCT FROM claim_action.requested_qty
       OR other_claim_total + claim_action.requested_qty
            > fn_preplan_public_surplus_approved_capacity(source_action.id) THEN
        RAISE EXCEPTION 'invalid or over-capacity shared future claim'
            USING ERRCODE = '23514',
                  CONSTRAINT = 'preplan_shared_future_claim_capacity_guard';
    END IF;
    RETURN NULL;
END;
$$;

CREATE OR REPLACE FUNCTION fn_guard_preplan_public_surplus_shape()
RETURNS trigger LANGUAGE plpgsql AS $$
DECLARE
    item_qty NUMERIC(18,4);
    item_valid BOOLEAN := FALSE;
    shared_with_demand BOOLEAN := FALSE;
BEGIN
    IF NEW.public_surplus_qty = 0 THEN
        IF NEW.public_surplus_external_item_id IS NOT NULL THEN
            RAISE EXCEPTION 'zero public surplus cannot reference an external item'
                USING ERRCODE = '23514';
        END IF;
        RETURN NEW;
    END IF;
    IF NEW.operation_type <> 'SUPPLY' OR NEW.route NOT IN ('BUY','SUBCONTRACT') THEN
        RAISE EXCEPTION 'public surplus is allowed only on BUY/SUBCONTRACT supply actions'
            USING ERRCODE = '23514';
    END IF;
    IF NEW.route = 'SUBCONTRACT' AND EXISTS (
        SELECT 1 FROM goods_bom_items bom
        WHERE bom.goods_id = NEW.goods_id
          AND bom.is_deleted = FALSE) THEN
        RAISE EXCEPTION 'subcontract public surplus requires a leaf goods item'
            USING ERRCODE = '23514',
                  CONSTRAINT = 'preplan_public_surplus_subcontract_leaf_guard';
    END IF;
    IF NEW.status = 'OPEN' THEN
        IF NEW.public_surplus_external_item_id IS NOT NULL THEN
            RAISE EXCEPTION 'open public surplus action cannot be externally anchored yet'
                USING ERRCODE = '23514';
        END IF;
        RETURN NEW;
    END IF;
    IF NEW.public_surplus_external_item_id IS NULL THEN
        RAISE EXCEPTION 'externalized public surplus must reference its public item'
            USING ERRCODE = '23514';
    END IF;
    SELECT EXISTS (
        SELECT 1 FROM preplan_supply_action_allocations allocation
        WHERE allocation.action_id = NEW.id
          AND allocation.external_item_id = NEW.public_surplus_external_item_id)
    INTO shared_with_demand;
    IF NEW.route = 'BUY' THEN
        SELECT item.qty * COALESCE(item.unit_rate,1),
               item.request_id = NEW.external_document_id
               AND item.goods_id = NEW.goods_id
               AND item.color_id IS NOT DISTINCT FROM NEW.color_id
               AND item.unit_id = NEW.unit_id
               AND item.is_deleted = FALSE
        INTO item_qty, item_valid
        FROM purchase_request_items item
        WHERE item.id = NEW.public_surplus_external_item_id;
    ELSE
        SELECT item.qty * COALESCE(item.unit_rate,1),
               item.application_id = NEW.external_document_id
               AND item.goods_id = NEW.goods_id
               AND item.color_id IS NOT DISTINCT FROM NEW.color_id
               AND item.unit_id = NEW.unit_id
               AND item.is_deleted = FALSE
        INTO item_qty, item_valid
        FROM subcontract_application_items item
        WHERE item.id = NEW.public_surplus_external_item_id;
    END IF;
    IF NOT COALESCE(item_valid,FALSE)
       OR (NOT shared_with_demand
           AND item_qty IS DISTINCT FROM NEW.public_surplus_qty) THEN
        RAISE EXCEPTION 'public surplus external item identity or quantity is invalid'
            USING ERRCODE = '23514',
                  CONSTRAINT = 'preplan_public_surplus_external_item_guard';
    END IF;
    RETURN NEW;
END;
$$;
CREATE TRIGGER trg_guard_preplan_public_surplus_shape
    BEFORE INSERT OR UPDATE ON preplan_supply_actions
    FOR EACH ROW EXECUTE FUNCTION fn_guard_preplan_public_surplus_shape();

CREATE CONSTRAINT TRIGGER trg_validate_preplan_shared_future_claim_action
    AFTER INSERT OR UPDATE ON preplan_supply_actions
    DEFERRABLE INITIALLY DEFERRED
    FOR EACH ROW EXECUTE FUNCTION fn_validate_preplan_shared_future_claim();
CREATE CONSTRAINT TRIGGER trg_validate_preplan_shared_future_claim_allocation
    AFTER INSERT OR UPDATE OR DELETE ON preplan_supply_action_allocations
    DEFERRABLE INITIALLY DEFERRED
    FOR EACH ROW EXECUTE FUNCTION fn_validate_preplan_shared_future_claim();

CREATE OR REPLACE FUNCTION fn_guard_preplan_public_surplus_history()
RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
    IF OLD.external_document_id IS NOT NULL
       AND (NEW.public_surplus_qty IS DISTINCT FROM OLD.public_surplus_qty
            OR NEW.public_surplus_external_item_id
                 IS DISTINCT FROM OLD.public_surplus_external_item_id
            OR NEW.operation_type IS DISTINCT FROM OLD.operation_type
            OR NEW.claim_source_action_id IS DISTINCT FROM OLD.claim_source_action_id) THEN
        RAISE EXCEPTION 'preplan public surplus and claim identity is immutable'
            USING ERRCODE = '23514';
    END IF;
    IF NEW.status = 'CANCELLED' AND OLD.status <> 'CANCELLED'
       AND EXISTS (
           SELECT 1 FROM preplan_supply_actions claim
           WHERE claim.claim_source_action_id = OLD.id
             AND claim.operation_type = 'SHARED_FUTURE_CLAIM'
             AND claim.status <> 'CANCELLED') THEN
        RAISE EXCEPTION 'public surplus source has active shared future claims'
            USING ERRCODE = '23514',
                  CONSTRAINT = 'preplan_public_surplus_active_claim_guard';
    END IF;
    RETURN NEW;
END;
$$;
CREATE TRIGGER trg_guard_preplan_public_surplus_history
    BEFORE UPDATE ON preplan_supply_actions
    FOR EACH ROW EXECUTE FUNCTION fn_guard_preplan_public_surplus_history();

-- V463 documented this invariant but did not enforce it.  The deferred form
-- permits an order item and all of its source rows to be written in one tx.
CREATE OR REPLACE FUNCTION fn_validate_order_item_source_total()
RETURNS trigger LANGUAGE plpgsql AS $$
DECLARE
    item_id UUID;
    item_qty NUMERIC(18,4);
    source_qty NUMERIC(18,4);
BEGIN
    item_id := COALESCE(
        (to_jsonb(NEW)->>'order_item_id')::uuid,
        (to_jsonb(OLD)->>'order_item_id')::uuid,
        (to_jsonb(NEW)->>'id')::uuid,
        (to_jsonb(OLD)->>'id')::uuid);
    IF TG_TABLE_NAME IN ('purchase_order_items','purchase_order_item_sources') THEN
        SELECT qty INTO item_qty FROM purchase_order_items WHERE id = item_id;
        IF item_qty IS NULL THEN RETURN NULL; END IF;
        SELECT COALESCE(SUM(alloc_qty),0) INTO source_qty
        FROM purchase_order_item_sources WHERE order_item_id = item_id;
    ELSE
        SELECT qty INTO item_qty FROM subcontract_order_items WHERE id = item_id;
        IF item_qty IS NULL THEN RETURN NULL; END IF;
        SELECT COALESCE(SUM(alloc_qty),0) INTO source_qty
        FROM subcontract_order_item_sources WHERE order_item_id = item_id;
    END IF;
    IF source_qty > 0 AND source_qty IS DISTINCT FROM item_qty THEN
        RAISE EXCEPTION 'order item source allocation total must equal item quantity'
            USING ERRCODE = '23514',
                  CONSTRAINT = 'order_item_source_total_guard';
    END IF;
    RETURN NULL;
END;
$$;

CREATE CONSTRAINT TRIGGER trg_validate_purchase_order_item_source_total
    AFTER INSERT OR UPDATE OR DELETE ON purchase_order_item_sources
    DEFERRABLE INITIALLY DEFERRED
    FOR EACH ROW EXECUTE FUNCTION fn_validate_order_item_source_total();
CREATE CONSTRAINT TRIGGER trg_validate_purchase_order_item_source_header
    AFTER INSERT OR UPDATE OF qty ON purchase_order_items
    DEFERRABLE INITIALLY DEFERRED
    FOR EACH ROW EXECUTE FUNCTION fn_validate_order_item_source_total();
CREATE CONSTRAINT TRIGGER trg_validate_subcontract_order_item_source_total
    AFTER INSERT OR UPDATE OR DELETE ON subcontract_order_item_sources
    DEFERRABLE INITIALLY DEFERRED
    FOR EACH ROW EXECUTE FUNCTION fn_validate_order_item_source_total();
CREATE CONSTRAINT TRIGGER trg_validate_subcontract_order_item_source_header
    AFTER INSERT OR UPDATE OF qty ON subcontract_order_items
    DEFERRABLE INITIALLY DEFERRED
    FOR EACH ROW EXECUTE FUNCTION fn_validate_order_item_source_total();

CREATE OR REPLACE FUNCTION fn_guard_approved_order_item_source()
RETURNS trigger LANGUAGE plpgsql AS $$
DECLARE
    item_id UUID := COALESCE(NEW.order_item_id, OLD.order_item_id);
    approved BOOLEAN;
BEGIN
    IF TG_TABLE_NAME = 'purchase_order_item_sources' THEN
        SELECT order_header.status <> 0 INTO approved
        FROM purchase_order_items item
        JOIN purchase_orders order_header ON order_header.id = item.order_id
        WHERE item.id = item_id;
    ELSE
        SELECT order_header.status <> 0 INTO approved
        FROM subcontract_order_items item
        JOIN subcontract_orders order_header ON order_header.id = item.order_id
        WHERE item.id = item_id;
    END IF;
    IF COALESCE(approved,FALSE) THEN
        RAISE EXCEPTION 'approved order item source allocation is immutable'
            USING ERRCODE = '55000';
    END IF;
    IF TG_OP = 'DELETE' THEN RETURN OLD; END IF;
    RETURN NEW;
END;
$$;
CREATE TRIGGER trg_guard_approved_purchase_order_item_source
    BEFORE INSERT OR UPDATE OR DELETE ON purchase_order_item_sources
    FOR EACH ROW EXECUTE FUNCTION fn_guard_approved_order_item_source();
CREATE TRIGGER trg_guard_approved_subcontract_order_item_source
    BEFORE INSERT OR UPDATE OR DELETE ON subcontract_order_item_sources
    FOR EACH ROW EXECUTE FUNCTION fn_guard_approved_order_item_source();

CREATE OR REPLACE FUNCTION fn_guard_purchase_shared_future_source()
RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
    IF EXISTS (
        SELECT 1
        FROM purchase_order_item_sources src
        JOIN preplan_supply_actions source
          ON source.public_surplus_external_item_id = src.request_item_id
         AND source.operation_type = 'SUPPLY'
        JOIN preplan_supply_actions claim
          ON claim.claim_source_action_id = source.id
         AND claim.operation_type = 'SHARED_FUTURE_CLAIM'
         AND claim.status <> 'CANCELLED'
        WHERE src.order_item_id = OLD.id
    ) THEN
        RAISE EXCEPTION 'purchase source has active shared future claims'
            USING ERRCODE = '23514',
                  CONSTRAINT = 'purchase_shared_future_source_guard';
    END IF;
    IF TG_OP = 'DELETE' THEN RETURN OLD; END IF;
    RETURN NEW;
END;
$$;
CREATE TRIGGER trg_guard_purchase_shared_future_source_item
    BEFORE UPDATE OF order_id, qty, unit_rate, goods_id, color_id, unit_id,
                     is_deleted OR DELETE ON purchase_order_items
    FOR EACH ROW EXECUTE FUNCTION fn_guard_purchase_shared_future_source();

CREATE OR REPLACE FUNCTION fn_guard_subcontract_shared_future_source()
RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
    IF EXISTS (
        SELECT 1
        FROM subcontract_order_item_sources src
        JOIN preplan_supply_actions source
          ON source.public_surplus_external_item_id = src.application_item_id
         AND source.operation_type = 'SUPPLY'
        JOIN preplan_supply_actions claim
          ON claim.claim_source_action_id = source.id
         AND claim.operation_type = 'SHARED_FUTURE_CLAIM'
         AND claim.status <> 'CANCELLED'
        WHERE src.order_item_id = OLD.id
    ) THEN
        RAISE EXCEPTION 'subcontract source has active shared future claims'
            USING ERRCODE = '23514',
                  CONSTRAINT = 'subcontract_shared_future_source_guard';
    END IF;
    IF TG_OP = 'DELETE' THEN RETURN OLD; END IF;
    RETURN NEW;
END;
$$;
CREATE TRIGGER trg_guard_subcontract_shared_future_source_item
    BEFORE UPDATE OF order_id, qty, unit_rate, goods_id, color_id, unit_id,
                     is_deleted OR DELETE ON subcontract_order_items
    FOR EACH ROW EXECUTE FUNCTION fn_guard_subcontract_shared_future_source();

CREATE OR REPLACE FUNCTION fn_guard_purchase_shared_future_source_header()
RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
    IF (NEW.status IS DISTINCT FROM OLD.status
        OR NEW.is_deleted IS DISTINCT FROM OLD.is_deleted
        OR (NEW.is_closed IS DISTINCT FROM OLD.is_closed
            AND NEW.is_closed = TRUE
            AND EXISTS (
                SELECT 1 FROM purchase_order_items open_item
                WHERE open_item.order_id = OLD.id
                  AND open_item.is_deleted = FALSE
                  AND COALESCE(open_item.qty,0)
                      - COALESCE(open_item.received_qty,0)
                      + COALESCE(open_item.returned_qty,0) > 0)))
       AND EXISTS (
        SELECT 1
        FROM purchase_order_items item
        JOIN purchase_order_item_sources src ON src.order_item_id = item.id
        JOIN preplan_supply_actions source
          ON source.public_surplus_external_item_id = src.request_item_id
        JOIN preplan_supply_actions claim
          ON claim.claim_source_action_id = source.id
         AND claim.status <> 'CANCELLED'
        WHERE item.order_id = OLD.id) THEN
        RAISE EXCEPTION 'purchase order has active shared future claims'
            USING ERRCODE = '23514';
    END IF;
    RETURN NEW;
END;
$$;
CREATE TRIGGER trg_guard_purchase_shared_future_source_header
    BEFORE UPDATE OF status, is_deleted, is_closed ON purchase_orders
    FOR EACH ROW EXECUTE FUNCTION fn_guard_purchase_shared_future_source_header();

CREATE OR REPLACE FUNCTION fn_guard_subcontract_shared_future_source_header()
RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
    IF (NEW.status IS DISTINCT FROM OLD.status
        OR NEW.is_deleted IS DISTINCT FROM OLD.is_deleted
        OR (NEW.is_closed IS DISTINCT FROM OLD.is_closed
            AND NEW.is_closed = TRUE
            AND EXISTS (
                SELECT 1 FROM subcontract_order_items open_item
                WHERE open_item.order_id = OLD.id
                  AND open_item.is_deleted = FALSE
                  AND COALESCE(open_item.qty,0)
                      - COALESCE(open_item.received_qty,0)
                      + COALESCE(open_item.returned_qty,0) > 0)))
       AND EXISTS (
        SELECT 1
        FROM subcontract_order_items item
        JOIN subcontract_order_item_sources src ON src.order_item_id = item.id
        JOIN preplan_supply_actions source
          ON source.public_surplus_external_item_id = src.application_item_id
        JOIN preplan_supply_actions claim
          ON claim.claim_source_action_id = source.id
         AND claim.status <> 'CANCELLED'
        WHERE item.order_id = OLD.id) THEN
        RAISE EXCEPTION 'subcontract order has active shared future claims'
            USING ERRCODE = '23514';
    END IF;
    RETURN NEW;
END;
$$;
CREATE TRIGGER trg_guard_subcontract_shared_future_source_header
    BEFORE UPDATE OF status, is_deleted, is_closed ON subcontract_orders
    FOR EACH ROW EXECUTE FUNCTION fn_guard_subcontract_shared_future_source_header();

CREATE OR REPLACE FUNCTION fn_has_protected_production_supply_peg(
    p_supply_type TEXT,
    p_supply_item_id UUID
) RETURNS boolean
LANGUAGE sql
STABLE
AS $$
    SELECT EXISTS (
        SELECT 1 FROM production_material_supply_pegs peg
        WHERE peg.supply_type = p_supply_type
          AND peg.supply_item_id = p_supply_item_id
    ) OR (
        p_supply_type = 'PURCHASE_REQUEST_ITEM' AND EXISTS (
            SELECT 1
            FROM preplan_supply_actions action
            LEFT JOIN preplan_supply_action_allocations allocation
              ON allocation.action_id = action.id
            WHERE action.route = 'BUY'
              AND (allocation.external_item_id = p_supply_item_id
                   OR action.safety_external_item_id = p_supply_item_id
                   OR action.public_surplus_external_item_id = p_supply_item_id)
        )
    ) OR (
        p_supply_type = 'SUBCONTRACT_APPLICATION_ITEM' AND EXISTS (
            SELECT 1
            FROM preplan_supply_actions action
            LEFT JOIN preplan_supply_action_allocations allocation
              ON allocation.action_id = action.id
            WHERE action.route = 'SUBCONTRACT'
              AND (allocation.external_item_id = p_supply_item_id
                   OR action.public_surplus_external_item_id = p_supply_item_id)
        )
    ) OR (
        p_supply_type = 'PURCHASE_ORDER_ITEM' AND EXISTS (
            SELECT 1
            FROM purchase_order_items order_item
            JOIN purchase_orders order_header ON order_header.id = order_item.order_id
            JOIN purchase_order_item_sources source
              ON source.order_item_id = order_item.id
            JOIN preplan_supply_actions action ON action.route = 'BUY'
            LEFT JOIN preplan_supply_action_allocations allocation
              ON allocation.action_id = action.id
             AND allocation.external_item_id = source.request_item_id
            WHERE order_item.id = p_supply_item_id
              AND (allocation.id IS NOT NULL
                   OR action.safety_external_item_id = source.request_item_id
                   OR action.public_surplus_external_item_id = source.request_item_id)
              AND (order_header.status <> 0
                   OR action.status IN ('IN_PROGRESS','DONE','CANCELLED'))
        )
    ) OR (
        p_supply_type = 'SUBCONTRACT_ORDER_ITEM' AND EXISTS (
            SELECT 1
            FROM subcontract_order_items order_item
            JOIN subcontract_orders order_header ON order_header.id = order_item.order_id
            JOIN subcontract_order_item_sources source
              ON source.order_item_id = order_item.id
            JOIN preplan_supply_actions action ON action.route = 'SUBCONTRACT'
            LEFT JOIN preplan_supply_action_allocations allocation
              ON allocation.action_id = action.id
             AND allocation.external_item_id = source.application_item_id
            WHERE order_item.id = p_supply_item_id
              AND (allocation.id IS NOT NULL
                   OR action.public_surplus_external_item_id =
                        source.application_item_id)
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
                   OR action.safety_external_item_id = p_upstream_item_id
                   OR action.public_surplus_external_item_id = p_upstream_item_id)
              AND (action.status IN ('IN_PROGRESS','DONE','CANCELLED')
                   OR NOT EXISTS (
                       SELECT 1 FROM purchase_orders header
                       WHERE header.id = p_order_id)
                   OR EXISTS (
                       SELECT 1 FROM purchase_orders header
                       WHERE header.id = p_order_id AND header.status <> 0))
        )
        WHEN p_supply_type = 'SUBCONTRACT_ORDER_ITEM' THEN EXISTS (
            SELECT 1
            FROM preplan_supply_actions action
            LEFT JOIN preplan_supply_action_allocations allocation
              ON allocation.action_id = action.id
             AND allocation.external_item_id = p_upstream_item_id
            WHERE action.route = 'SUBCONTRACT'
              AND (allocation.id IS NOT NULL
                   OR action.public_surplus_external_item_id = p_upstream_item_id)
              AND (action.status IN ('IN_PROGRESS','DONE','CANCELLED')
                   OR NOT EXISTS (
                       SELECT 1 FROM subcontract_orders header
                       WHERE header.id = p_order_id)
                   OR EXISTS (
                       SELECT 1 FROM subcontract_orders header
                       WHERE header.id = p_order_id AND header.status <> 0))
        )
        ELSE FALSE
    END;
$$;

COMMENT ON COLUMN preplan_supply_actions.public_surplus_qty IS
    'Optional public replenishment, never exact demand; old rows default zero.';
COMMENT ON COLUMN preplan_supply_actions.claim_source_action_id IS
    'Source SUPPLY action whose approved public surplus is claimed by this analysis.';
COMMENT ON VIEW v_preplan_public_surplus_source_state IS
    'Approved public future surplus, explicit claims, remaining claim capacity and ETA by source action.';
