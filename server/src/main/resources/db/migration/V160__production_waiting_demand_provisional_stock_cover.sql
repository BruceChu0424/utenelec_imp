-- V160: do not reserve partial material for WAITING execution segments, but
-- also do not ask Purchase/Subcontract to supply material that current free
-- stock can provisionally cover.
--
-- This is deliberately a read-side allocation. It never creates a reservation
-- and therefore never promises that the stock will still exist when the
-- missing materials arrive. Free stock is apportioned by need date and stable
-- demand UUID so every card and count uses one deterministic suggestion.
-- Promotion to READY still locks all material dimensions and creates an exact
-- complete-kit reservation in one transaction.

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
base_raw AS (
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
               COALESCE(sa.available_qty, 0)
                   - GREATEST(COALESCE(g.min_qty, 0)::numeric, 0),
               0
           ) AS free_stock_qty,
           GREATEST(
               GREATEST(d.required_qty - d.released_qty, 0)
                   - COALESCE(st.committed_qty, 0)
                   - COALESCE(pt.committed_qty, 0),
               0
           ) AS uncommitted_qty,
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
    LEFT JOIN v_stock_available sa
      ON sa.warehouse_id = d.warehouse_id
     AND sa.goods_id = d.goods_id
     AND sa.color_id IS NOT DISTINCT FROM d.color_id
    WHERE d.is_deleted = FALSE
      AND d.status NOT IN ('RELEASED', 'REVERSED')
),
ranked AS (
    SELECT base_raw.*,
           COALESCE(
               SUM(uncommitted_qty) OVER (
                   PARTITION BY warehouse_id, goods_id, color_id
                   ORDER BY need_date NULLS LAST, plan_id, demand_id
                   ROWS BETWEEN UNBOUNDED PRECEDING AND 1 PRECEDING
               ),
               0
           ) AS prior_uncommitted_qty
    FROM base_raw
),
base AS (
    SELECT ranked.*,
           LEAST(
               uncommitted_qty,
               GREATEST(free_stock_qty - prior_uncommitted_qty, 0)
           ) AS provisional_stock_cover_qty,
           GREATEST(
               uncommitted_qty
                   - LEAST(
                       uncommitted_qty,
                       GREATEST(free_stock_qty - prior_uncommitted_qty, 0)
                   ),
               0
           ) AS procurement_open_qty
    FROM ranked
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
           WHEN stock_open_qty > 0 AND need_date < CURRENT_DATE
               THEN 'OVERDUE'
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
       procurement_open_qty AS open_qty,
       CASE
           WHEN procurement_open_qty > 0 THEN 'UNPEGGED'
           WHEN supply_committed_qty > 0 THEN 'WAITING_SUPPLY'
           ELSE 'COVERED'
       END::text AS task_status,
       need_date,
       expected_date,
       CASE
           WHEN procurement_open_qty > 0
                AND need_date < CURRENT_DATE THEN 'OVERDUE_SHORTAGE'
           WHEN procurement_open_qty > 0 THEN 'SUPPLY_PEG_REQUIRED'
           ELSE NULL
       END::text AS exception_code,
       updated_at
FROM base
WHERE supply_route IN ('BUY', 'SUBCONTRACT')
  AND (
      procurement_open_qty > 0
      OR supply_committed_qty > 0
      OR supply_received_qty > 0
  );

COMMENT ON VIEW v_fulfillment_workbench IS
    'Authoritative fulfillment tasks. WAITING demand purchase/subcontract open quantity subtracts deterministic advisory free-stock coverage without reserving it; READY promotion remains the only complete-kit stock commitment.';
