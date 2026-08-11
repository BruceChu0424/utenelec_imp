-- V217: mirror-cut execution_segment_sales_allocations during daily-report cap/restore.
--
-- PROD-P1-1: ProductionDailyReportService.capAndRemake cuts
-- plan_order_item_links.allocated_qty (down to produced) but NOT the parallel
-- execution_segment_sales_allocations.allocated_qty, so the V157 deferred guards
-- drift:
--   * execution_segment_sales_link_capacity_guard:
--       SUM(allocations.allocated_qty) > link.allocated_qty  (link dropped, alloc did not)
--   * execution_segment_sales_allocation_total_guard:
--       SUM(allocations.allocated_qty) <> segment.planned_qty
-- A plain mirror-cut crashes because the V157 row trigger
-- (fn_validate_execution_segment_sales_allocation) raises on UPDATE.
--
-- This migration opens a narrow transaction-local GUC window
-- (app.cap_segment_allocations = 'on') that only ProductionDailyReportService
-- sets around the mirror-cut + planned_qty recompute.  Within the window UPDATE
-- is allowed (and still identity-validated); outside it the immutability guard
-- is unchanged.  DELETE remains immutable; INSERT keeps its identity validation.
--
-- The allocated_qty CHECK is relaxed from '> 0' to '>= 0' so a fully capped-out
-- allocation (order line moved to a remake plan, none of its quantity produced on
-- this segment) may legitimately reach zero.  Existing data satisfies '>= 0'.

ALTER TABLE execution_segment_sales_allocations
    DROP CONSTRAINT execution_segment_sales_allocation_qty_chk;

ALTER TABLE execution_segment_sales_allocations
    ADD CONSTRAINT execution_segment_sales_allocation_qty_chk
        CHECK (allocated_qty >= 0);

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
    IF TG_OP = 'DELETE' THEN
        RAISE EXCEPTION 'execution segment sales allocation is immutable'
            USING ERRCODE = '23514',
                  CONSTRAINT =
                      'execution_segment_sales_allocation_immutable_guard';
    END IF;

    IF TG_OP = 'UPDATE'
       AND COALESCE(
               current_setting('app.cap_segment_allocations', TRUE), 'off')
           <> 'on' THEN
        RAISE EXCEPTION 'execution segment sales allocation is immutable'
            USING ERRCODE = '23514',
                  CONSTRAINT =
                      'execution_segment_sales_allocation_immutable_guard';
    END IF;

    -- INSERT (always) and GUC-gated UPDATE fall through to identity validation.
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

COMMENT ON FUNCTION fn_validate_execution_segment_sales_allocation() IS
    'V157 immutability guard. V217 opens a transaction-local GUC window (app.cap_segment_allocations=on) allowing only ProductionDailyReportService cap/restore to UPDATE allocated_qty, and relaxes the qty CHECK to >= 0 so a capped-out allocation may reach zero. DELETE stays immutable; INSERT keeps identity validation.';
