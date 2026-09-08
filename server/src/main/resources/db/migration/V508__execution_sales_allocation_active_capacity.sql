-- V508: retiring an unused execution package must allow a fresh package on the
-- same plan without rewriting immutable segment -> sales allocation history.
-- Only CANCELLED/REVERSED segments exit current capacity. Completed physical
-- work remains counted. No historical row, quantity, or migration byte changes.

CREATE OR REPLACE FUNCTION fn_assert_execution_segment_sales_allocation(
    p_segment_id UUID
) RETURNS VOID
LANGUAGE plpgsql
AS $$
DECLARE
    v_segment RECORD;
    v_active_link_count BIGINT;
    v_allocation_count BIGINT;
    v_allocated NUMERIC(18,4);
    v_over_link BIGINT;
    v_bad_identity BIGINT;
BEGIN
    SELECT s.id, s.source_plan_item_id, s.planned_qty, s.status,
           package.status AS package_status
    INTO v_segment
    FROM production_execution_segments s
    JOIN production_planning_packages package
      ON package.id = s.package_id
     AND package.is_deleted = FALSE
    WHERE s.id = p_segment_id
      AND s.is_deleted = FALSE;
    IF NOT FOUND OR v_segment.status IN ('CANCELLED', 'REVERSED') THEN
        RETURN;
    END IF;

    -- Different segments share one plan-link capacity. NO KEY UPDATE serializes
    -- decisions without upgrading the FK's compatible KEY SHARE to UPDATE.
    PERFORM link.id
    FROM plan_order_item_links link
    WHERE link.id IN (
        SELECT allocation.plan_order_item_link_id
        FROM execution_segment_sales_allocations allocation
        WHERE allocation.execution_segment_id = p_segment_id
    )
    ORDER BY link.id
    FOR NO KEY UPDATE;

    SELECT COUNT(*)
    INTO v_active_link_count
    FROM plan_order_item_links link
    WHERE link.plan_item_id = v_segment.source_plan_item_id
      AND link.is_deleted = FALSE;

    SELECT COUNT(*), COALESCE(SUM(allocation.allocated_qty), 0)
    INTO v_allocation_count, v_allocated
    FROM execution_segment_sales_allocations allocation
    WHERE allocation.execution_segment_id = p_segment_id;

    SELECT COUNT(*)
    INTO v_bad_identity
    FROM execution_segment_sales_allocations allocation
    LEFT JOIN plan_order_item_links link
      ON link.id = allocation.plan_order_item_link_id
    WHERE allocation.execution_segment_id = p_segment_id
      AND (
          link.id IS NULL
          OR link.is_deleted
          OR link.plan_item_id <> v_segment.source_plan_item_id
          OR link.order_item_id <> allocation.sales_order_item_id
      );
    IF v_bad_identity > 0 THEN
        RAISE EXCEPTION
            'execution segment sales allocation references an invalid plan link'
            USING ERRCODE = '23514',
                  CONSTRAINT =
                      'execution_segment_sales_allocation_link_identity_guard';
    END IF;

    IF v_active_link_count = 0 AND v_allocation_count <> 0 THEN
        RAISE EXCEPTION
            'internal execution segment cannot have a sales allocation'
            USING ERRCODE = '23514',
                  CONSTRAINT =
                      'execution_segment_internal_allocation_guard';
    END IF;
    IF v_active_link_count > 0
       AND v_allocated IS DISTINCT FROM v_segment.planned_qty THEN
        RAISE EXCEPTION
            'sales execution segment must be allocated exactly to planned quantity'
            USING ERRCODE = '23514',
                  CONSTRAINT =
                      'execution_segment_sales_allocation_total_guard';
    END IF;

    -- Only an explicit cancelled/reversed execution segment releases this
    -- capacity. Completed work and a merely soft-deleted row/package still
    -- consume it; deleting display history is not a physical reversal.
    -- Restrict to this segment's links before summing, using the existing
    -- allocation(plan_order_item_link_id) index instead of grouping all history.
    SELECT COUNT(*)
    INTO v_over_link
    FROM plan_order_item_links link
    WHERE link.id IN (
        SELECT current_allocation.plan_order_item_link_id
        FROM execution_segment_sales_allocations current_allocation
        WHERE current_allocation.execution_segment_id = p_segment_id
    )
      AND COALESCE((
          SELECT SUM(allocation.allocated_qty)
          FROM execution_segment_sales_allocations allocation
          JOIN production_execution_segments allocated_segment
            ON allocated_segment.id = allocation.execution_segment_id
          WHERE allocation.plan_order_item_link_id = link.id
            AND allocated_segment.status NOT IN ('CANCELLED', 'REVERSED')
      ), 0) > link.allocated_qty;
    IF v_over_link > 0 THEN
        RAISE EXCEPTION
            'execution segment allocations exceed the production plan sales link'
            USING ERRCODE = '23514',
                  CONSTRAINT =
                      'execution_segment_sales_link_capacity_guard';
    END IF;
END;
$$;

CREATE OR REPLACE FUNCTION fn_validate_execution_segment_sales_allocation()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
DECLARE
    v_segment_plan_item UUID;
    v_link_plan_item UUID;
    v_link_order_item UUID;
    v_link_deleted BOOLEAN;
BEGIN
    IF TG_OP IN ('UPDATE', 'DELETE') THEN
        RAISE EXCEPTION 'execution segment sales allocation is immutable'
            USING ERRCODE = '23514',
                  CONSTRAINT =
                      'execution_segment_sales_allocation_immutable_guard';
    END IF;

    -- The application allocates under READ COMMITTED. A repeatable-read
    -- snapshot can remain stale after a pure row lock; reject that capacity
    -- increase explicitly instead of claiming unsupported isolation safety.
    IF current_setting('transaction_isolation') <> 'read committed' THEN
        RAISE EXCEPTION 'execution sales allocation writes require READ COMMITTED'
            USING ERRCODE = '23514',
                  CONSTRAINT = 'execution_sales_allocation_isolation_guard';
    END IF;

    SELECT source_plan_item_id
    INTO v_segment_plan_item
    FROM production_execution_segments
    WHERE id = NEW.execution_segment_id
      AND is_deleted = FALSE;

    SELECT plan_item_id, order_item_id, is_deleted
    INTO v_link_plan_item, v_link_order_item, v_link_deleted
    FROM plan_order_item_links
    WHERE id = NEW.plan_order_item_link_id;

    IF v_segment_plan_item IS NULL
       OR v_link_plan_item IS NULL
       OR COALESCE(v_link_deleted, FALSE)
       OR v_segment_plan_item <> v_link_plan_item
       OR NEW.sales_order_item_id <> v_link_order_item THEN
        RAISE EXCEPTION
            'execution segment sales allocation identity is inconsistent'
            USING ERRCODE = '23514',
                  CONSTRAINT =
                      'execution_segment_sales_allocation_identity_guard';
    END IF;
    RETURN NEW;
END;
$$;

CREATE OR REPLACE FUNCTION fn_assert_plan_link_execution_allocations()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
DECLARE
    v_segment_id UUID;
BEGIN
    -- Pure owner/audit metadata updates used by RR handover do not increase
    -- capacity. Changing capacity or identity must use the allocation writer's
    -- RC contract so its post-lock checks see any preceding committed insert.
    IF TG_OP = 'UPDATE'
       AND (NEW.allocated_qty IS DISTINCT FROM OLD.allocated_qty
         OR NEW.is_deleted IS DISTINCT FROM OLD.is_deleted
         OR NEW.plan_item_id IS DISTINCT FROM OLD.plan_item_id
         OR NEW.order_item_id IS DISTINCT FROM OLD.order_item_id)
       AND current_setting('transaction_isolation') <> 'read committed' THEN
        RAISE EXCEPTION 'execution sales link capacity changes require READ COMMITTED'
            USING ERRCODE = '23514',
                  CONSTRAINT = 'execution_sales_allocation_isolation_guard';
    END IF;
    FOR v_segment_id IN
        SELECT DISTINCT allocation.execution_segment_id
        FROM execution_segment_sales_allocations allocation
        WHERE allocation.plan_order_item_link_id = COALESCE(NEW.id, OLD.id)
        ORDER BY allocation.execution_segment_id
    LOOP
        PERFORM fn_assert_execution_segment_sales_allocation(v_segment_id);
    END LOOP;
    RETURN NULL;
END;
$$;
