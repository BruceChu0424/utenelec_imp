-- V157: exact sales ownership for each production execution segment.
--
-- A production plan item may aggregate several sales order lines.  V155 made
-- the execution segment exact to the plan item, but that is not sufficient:
-- joining a segment to every plan_order_item_link creates a Cartesian
-- ambiguity for reporting and finished-product inbound.  This immutable
-- allocation ledger freezes the exact segment -> plan link -> sales line
-- partition when the planning package is confirmed.

CREATE TABLE execution_segment_sales_allocations (
    id                       UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    execution_segment_id     UUID NOT NULL
        REFERENCES production_execution_segments(id),
    plan_order_item_link_id  UUID NOT NULL
        REFERENCES plan_order_item_links(id),
    sales_order_item_id      UUID NOT NULL,
    allocated_qty            NUMERIC(18,4) NOT NULL,
    created_at               TIMESTAMPTZ NOT NULL DEFAULT now(),
    created_by               UUID,
    CONSTRAINT execution_segment_sales_allocation_qty_chk
        CHECK (allocated_qty > 0),
    CONSTRAINT uq_execution_segment_sales_allocation_link
        UNIQUE (execution_segment_id, plan_order_item_link_id),
    CONSTRAINT uq_execution_segment_sales_allocation_order_item
        UNIQUE (execution_segment_id, sales_order_item_id)
);

CREATE INDEX idx_execution_segment_sales_allocation_order_item
    ON execution_segment_sales_allocations(
        sales_order_item_id, execution_segment_id);
CREATE INDEX idx_execution_segment_sales_allocation_plan_link
    ON execution_segment_sales_allocations(plan_order_item_link_id);

ALTER TABLE production_daily_report_items
    ADD COLUMN execution_segment_sales_allocation_id UUID
        REFERENCES execution_segment_sales_allocations(id);

CREATE INDEX idx_pdri_execution_segment_sales_allocation
    ON production_daily_report_items(execution_segment_sales_allocation_id)
    WHERE execution_segment_sales_allocation_id IS NOT NULL;

ALTER TABLE stock_document_items
    ADD COLUMN execution_segment_sales_allocation_id UUID
        REFERENCES execution_segment_sales_allocations(id);

CREATE INDEX idx_sdi_execution_segment_sales_allocation
    ON stock_document_items(execution_segment_sales_allocation_id)
    WHERE execution_segment_sales_allocation_id IS NOT NULL;

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

CREATE TRIGGER trg_validate_execution_segment_sales_allocation
    BEFORE INSERT OR UPDATE OR DELETE
    ON execution_segment_sales_allocations
    FOR EACH ROW EXECUTE FUNCTION
        fn_validate_execution_segment_sales_allocation();

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

    SELECT COUNT(*)
    INTO v_over_link
    FROM (
        SELECT allocation.plan_order_item_link_id
        FROM execution_segment_sales_allocations allocation
        JOIN plan_order_item_links link
          ON link.id = allocation.plan_order_item_link_id
        GROUP BY allocation.plan_order_item_link_id, link.allocated_qty
        HAVING SUM(allocation.allocated_qty) > link.allocated_qty
    ) over_allocated
    WHERE EXISTS (
        SELECT 1
        FROM execution_segment_sales_allocations current_allocation
        WHERE current_allocation.execution_segment_id = p_segment_id
          AND current_allocation.plan_order_item_link_id =
              over_allocated.plan_order_item_link_id
    );
    IF v_over_link > 0 THEN
        RAISE EXCEPTION
            'execution segment allocations exceed the production plan sales link'
            USING ERRCODE = '23514',
                  CONSTRAINT =
                      'execution_segment_sales_link_capacity_guard';
    END IF;
END;
$$;

CREATE OR REPLACE FUNCTION fn_assert_execution_segment_sales_allocation_row()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
BEGIN
    PERFORM fn_assert_execution_segment_sales_allocation(
        COALESCE(NEW.execution_segment_id, OLD.execution_segment_id));
    RETURN NULL;
END;
$$;

CREATE CONSTRAINT TRIGGER trg_assert_execution_segment_sales_allocation_row
    AFTER INSERT OR UPDATE OR DELETE
    ON execution_segment_sales_allocations
    DEFERRABLE INITIALLY DEFERRED
    FOR EACH ROW EXECUTE FUNCTION
        fn_assert_execution_segment_sales_allocation_row();
CREATE OR REPLACE FUNCTION fn_assert_execution_segment_sales_allocation_segment()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
BEGIN
    PERFORM fn_assert_execution_segment_sales_allocation(
        COALESCE(NEW.id, OLD.id));
    RETURN NULL;
END;
$$;


CREATE CONSTRAINT TRIGGER trg_assert_execution_segment_sales_allocation_segment
    AFTER INSERT OR UPDATE
    ON production_execution_segments
    DEFERRABLE INITIALLY DEFERRED
    FOR EACH ROW EXECUTE FUNCTION
        fn_assert_execution_segment_sales_allocation_segment();

CREATE OR REPLACE FUNCTION fn_assert_plan_link_execution_allocations()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
DECLARE
    v_segment_id UUID;
BEGIN
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

CREATE CONSTRAINT TRIGGER trg_assert_plan_link_execution_allocations
    AFTER UPDATE OR DELETE
    ON plan_order_item_links
    DEFERRABLE INITIALLY DEFERRED
    FOR EACH ROW EXECUTE FUNCTION
        fn_assert_plan_link_execution_allocations();

CREATE OR REPLACE FUNCTION fn_validate_daily_report_execution_segment()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
DECLARE
    v_segment production_execution_segments%ROWTYPE;
    v_allocation RECORD;
    v_has_sales_allocations BOOLEAN;
BEGIN
    IF NEW.execution_segment_id IS NOT NULL THEN
        SELECT * INTO v_segment
        FROM production_execution_segments
        WHERE id = NEW.execution_segment_id
          AND is_deleted = FALSE;
        IF NOT FOUND
           OR NEW.plan_item_id IS DISTINCT FROM v_segment.source_plan_item_id
           OR NEW.goods_id IS DISTINCT FROM v_segment.product_goods_id
           OR NEW.color_id IS DISTINCT FROM v_segment.product_color_id
           OR NEW.unit_id IS DISTINCT FROM v_segment.product_unit_id THEN
            RAISE EXCEPTION
                'daily report line is mapped to a different execution segment'
                USING ERRCODE = '23514',
                      CONSTRAINT =
                          'production_daily_report_execution_segment_guard';
        END IF;

        SELECT EXISTS (
            SELECT 1
            FROM execution_segment_sales_allocations allocation
            WHERE allocation.execution_segment_id = NEW.execution_segment_id
        ) INTO v_has_sales_allocations;
        IF v_has_sales_allocations
           AND NEW.execution_segment_sales_allocation_id IS NULL THEN
            RAISE EXCEPTION
                'daily report line requires the exact segment sales allocation'
                USING ERRCODE = '23514',
                      CONSTRAINT =
                          'daily_report_segment_sales_allocation_required';
        END IF;
        IF NOT v_has_sales_allocations
           AND (
               NEW.execution_segment_sales_allocation_id IS NOT NULL
               OR NEW.sales_order_item_id IS NOT NULL
           ) THEN
            RAISE EXCEPTION
                'internal execution segment cannot reference a sales allocation'
                USING ERRCODE = '23514',
                      CONSTRAINT =
                          'daily_report_internal_segment_sales_guard';
        END IF;
        IF NEW.execution_segment_sales_allocation_id IS NOT NULL THEN
            SELECT allocation.execution_segment_id,
                   allocation.sales_order_item_id
            INTO v_allocation
            FROM execution_segment_sales_allocations allocation
            WHERE allocation.id =
                NEW.execution_segment_sales_allocation_id;
            IF NOT FOUND
               OR v_allocation.execution_segment_id
                  <> NEW.execution_segment_id
               OR v_allocation.sales_order_item_id
                  <> NEW.sales_order_item_id THEN
                RAISE EXCEPTION
                    'daily report sales allocation does not match its segment/order line'
                    USING ERRCODE = '23514',
                          CONSTRAINT =
                              'daily_report_segment_sales_allocation_guard';
            END IF;
        END IF;
    ELSIF NEW.execution_segment_sales_allocation_id IS NOT NULL THEN
        RAISE EXCEPTION
            'legacy daily report cannot reference a segment sales allocation'
            USING ERRCODE = '23514',
                  CONSTRAINT =
                      'daily_report_legacy_sales_allocation_guard';
    ELSIF NEW.plan_item_id IS NOT NULL
       AND EXISTS (
           SELECT 1
           FROM production_execution_segments s
           JOIN production_planning_packages p ON p.id = s.package_id
           WHERE s.source_plan_item_id = NEW.plan_item_id
             AND s.is_deleted = FALSE
             AND p.is_deleted = FALSE
             AND p.status = 'CONFIRMED'
             AND p.execution_model_version = 1
       ) THEN
        RAISE EXCEPTION
            'execution segment is required for this daily report line'
            USING ERRCODE = '23514',
                  CONSTRAINT =
                      'production_daily_report_execution_segment_required';
    END IF;
    RETURN NEW;
END;
$$;

DROP TRIGGER trg_validate_daily_report_execution_segment
    ON production_daily_report_items;
CREATE TRIGGER trg_validate_daily_report_execution_segment
    BEFORE INSERT OR UPDATE OF
        execution_segment_id, execution_segment_sales_allocation_id,
        sales_order_item_id, plan_item_id, goods_id, color_id, unit_id
    ON production_daily_report_items
    FOR EACH ROW EXECUTE FUNCTION
        fn_validate_daily_report_execution_segment();

CREATE OR REPLACE FUNCTION fn_validate_finished_in_execution_segment()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
DECLARE
    v_segment production_execution_segments%ROWTYPE;
    v_allocation_segment UUID;
    v_has_sales_allocations BOOLEAN;
BEGIN
    IF NEW.bill_type IS DISTINCT FROM 'FINISHED_IN' THEN
        IF NEW.execution_segment_id IS NOT NULL
           OR NEW.execution_segment_sales_allocation_id IS NOT NULL THEN
            RAISE EXCEPTION
                'execution segment is only valid on finished-in stock lines'
                USING ERRCODE = '23514',
                      CONSTRAINT =
                          'stock_document_execution_segment_type_guard';
        END IF;
        RETURN NEW;
    END IF;

    IF NEW.execution_segment_id IS NOT NULL THEN
        SELECT * INTO v_segment
        FROM production_execution_segments
        WHERE id = NEW.execution_segment_id
          AND is_deleted = FALSE;
        IF NOT FOUND
           OR NEW.upstream_item_id IS DISTINCT FROM
              v_segment.source_plan_item_id
           OR NEW.goods_id IS DISTINCT FROM v_segment.product_goods_id
           OR NEW.color_id IS DISTINCT FROM v_segment.product_color_id
           OR NEW.unit_id IS DISTINCT FROM v_segment.product_unit_id THEN
            RAISE EXCEPTION
                'finished-in line is mapped to a different execution segment'
                USING ERRCODE = '23514',
                      CONSTRAINT =
                          'stock_document_execution_segment_guard';
        END IF;
        SELECT EXISTS (
            SELECT 1
            FROM execution_segment_sales_allocations allocation
            WHERE allocation.execution_segment_id = NEW.execution_segment_id
        ) INTO v_has_sales_allocations;
        IF v_has_sales_allocations
           AND NEW.execution_segment_sales_allocation_id IS NULL THEN
            RAISE EXCEPTION
                'finished-in line requires the exact segment sales allocation'
                USING ERRCODE = '23514',
                      CONSTRAINT =
                          'finished_in_segment_sales_allocation_required';
        END IF;
        IF NOT v_has_sales_allocations
           AND NEW.execution_segment_sales_allocation_id IS NOT NULL THEN
            RAISE EXCEPTION
                'internal execution segment cannot reference a sales allocation'
                USING ERRCODE = '23514',
                      CONSTRAINT =
                          'finished_in_internal_segment_sales_guard';
        END IF;
        IF NEW.execution_segment_sales_allocation_id IS NOT NULL THEN
            SELECT allocation.execution_segment_id
            INTO v_allocation_segment
            FROM execution_segment_sales_allocations allocation
            WHERE allocation.id =
                NEW.execution_segment_sales_allocation_id;
            IF NOT FOUND OR v_allocation_segment <> NEW.execution_segment_id THEN
                RAISE EXCEPTION
                    'finished-in sales allocation does not match its segment'
                    USING ERRCODE = '23514',
                          CONSTRAINT =
                              'finished_in_segment_sales_allocation_guard';
            END IF;
        END IF;
    ELSIF NEW.execution_segment_sales_allocation_id IS NOT NULL THEN
        RAISE EXCEPTION
            'legacy finished-in cannot reference a segment sales allocation'
            USING ERRCODE = '23514',
                  CONSTRAINT =
                      'finished_in_legacy_sales_allocation_guard';
    ELSIF NEW.upstream_item_id IS NOT NULL
       AND EXISTS (
           SELECT 1
           FROM production_execution_segments s
           JOIN production_planning_packages p ON p.id = s.package_id
           WHERE s.source_plan_item_id = NEW.upstream_item_id
             AND s.is_deleted = FALSE
             AND p.is_deleted = FALSE
             AND p.status = 'CONFIRMED'
             AND p.execution_model_version = 1
       ) THEN
        RAISE EXCEPTION
            'execution segment is required for this finished-in line'
            USING ERRCODE = '23514',
                  CONSTRAINT =
                      'stock_document_execution_segment_required';
    END IF;
    RETURN NEW;
END;
$$;

DROP TRIGGER trg_validate_finished_in_execution_segment
    ON stock_document_items;
CREATE TRIGGER trg_validate_finished_in_execution_segment
    BEFORE INSERT OR UPDATE OF
        execution_segment_id, execution_segment_sales_allocation_id,
        bill_type, upstream_item_id, goods_id, color_id, unit_id
    ON stock_document_items
    FOR EACH ROW EXECUTE FUNCTION
        fn_validate_finished_in_execution_segment();

CREATE OR REPLACE FUNCTION fn_assert_execution_segment_sales_fact_capacity(
    p_allocation_id UUID
) RETURNS VOID
LANGUAGE plpgsql
AS $$
DECLARE
    v_allocated NUMERIC(18,4);
    v_reported NUMERIC(18,4);
    v_inbound NUMERIC(18,4);
BEGIN
    IF p_allocation_id IS NULL THEN
        RETURN;
    END IF;
    SELECT allocated_qty INTO v_allocated
    FROM execution_segment_sales_allocations
    WHERE id = p_allocation_id;
    IF NOT FOUND THEN
        RETURN;
    END IF;

    SELECT COALESCE(SUM(item.qty), 0)
    INTO v_reported
    FROM production_daily_report_items item
    JOIN production_daily_reports report
      ON report.id = item.report_id
    WHERE item.execution_segment_sales_allocation_id = p_allocation_id
      AND item.is_deleted = FALSE
      AND report.is_deleted = FALSE
      AND report.status IN (0, 1);
    IF v_reported > v_allocated THEN
        RAISE EXCEPTION
            'daily report quantity exceeds its segment sales allocation'
            USING ERRCODE = '23514',
                  CONSTRAINT =
                      'daily_report_segment_sales_capacity_guard';
    END IF;

    SELECT COALESCE(SUM(item.qty), 0)
    INTO v_inbound
    FROM stock_document_items item
    JOIN stock_documents document
      ON document.id = item.doc_id
    WHERE item.execution_segment_sales_allocation_id = p_allocation_id
      AND item.is_deleted = FALSE
      AND document.is_deleted = FALSE
      AND document.doc_type = 'FINISHED_IN'
      AND document.status = 1;
    IF v_inbound > (
        SELECT COALESCE(SUM(item.qty), 0)
        FROM production_daily_report_items item
        JOIN production_daily_reports report
          ON report.id = item.report_id
        WHERE item.execution_segment_sales_allocation_id = p_allocation_id
          AND item.is_deleted = FALSE
          AND report.is_deleted = FALSE
          AND report.status = 1
    ) THEN
        RAISE EXCEPTION
            'finished-in quantity exceeds approved report quantity for its sales allocation'
            USING ERRCODE = '23514',
                  CONSTRAINT =
                      'finished_in_segment_sales_report_guard';
    END IF;
END;
$$;

CREATE OR REPLACE FUNCTION fn_assert_execution_segment_sales_fact_row()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
BEGIN
    PERFORM fn_assert_execution_segment_sales_fact_capacity(
        COALESCE(
            NEW.execution_segment_sales_allocation_id,
            OLD.execution_segment_sales_allocation_id));
    RETURN NULL;
END;
$$;

CREATE CONSTRAINT TRIGGER trg_assert_daily_report_segment_sales_fact
    AFTER INSERT OR UPDATE OR DELETE
    ON production_daily_report_items
    DEFERRABLE INITIALLY DEFERRED
    FOR EACH ROW EXECUTE FUNCTION
        fn_assert_execution_segment_sales_fact_row();

CREATE CONSTRAINT TRIGGER trg_assert_finished_in_segment_sales_fact
    AFTER INSERT OR UPDATE OR DELETE
    ON stock_document_items
    DEFERRABLE INITIALLY DEFERRED
    FOR EACH ROW EXECUTE FUNCTION
        fn_assert_execution_segment_sales_fact_row();

CREATE OR REPLACE FUNCTION fn_assert_daily_report_segment_sales_status()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
DECLARE
    v_allocation_id UUID;
BEGIN
    FOR v_allocation_id IN
        SELECT DISTINCT item.execution_segment_sales_allocation_id
        FROM production_daily_report_items item
        WHERE item.report_id = NEW.id
          AND item.execution_segment_sales_allocation_id IS NOT NULL
        ORDER BY item.execution_segment_sales_allocation_id
    LOOP
        PERFORM fn_assert_execution_segment_sales_fact_capacity(
            v_allocation_id);
    END LOOP;
    RETURN NULL;
END;
$$;

CREATE CONSTRAINT TRIGGER trg_assert_daily_report_segment_sales_status
    AFTER UPDATE OF status, is_deleted
    ON production_daily_reports
    DEFERRABLE INITIALLY DEFERRED
    FOR EACH ROW EXECUTE FUNCTION
        fn_assert_daily_report_segment_sales_status();

CREATE OR REPLACE FUNCTION fn_assert_stock_document_segment_sales_status()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
DECLARE
    v_allocation_id UUID;
BEGIN
    FOR v_allocation_id IN
        SELECT DISTINCT item.execution_segment_sales_allocation_id
        FROM stock_document_items item
        WHERE item.doc_id = NEW.id
          AND item.execution_segment_sales_allocation_id IS NOT NULL
        ORDER BY item.execution_segment_sales_allocation_id
    LOOP
        PERFORM fn_assert_execution_segment_sales_fact_capacity(
            v_allocation_id);
    END LOOP;
    RETURN NULL;
END;
$$;

CREATE CONSTRAINT TRIGGER trg_assert_stock_document_segment_sales_status
    AFTER UPDATE OF status, is_deleted
    ON stock_documents
    DEFERRABLE INITIALLY DEFERRED
    FOR EACH ROW EXECUTE FUNCTION
        fn_assert_stock_document_segment_sales_status();

CREATE TRIGGER trg_audit_execution_segment_sales_allocations
    AFTER INSERT OR UPDATE OR DELETE
    ON execution_segment_sales_allocations
    FOR EACH ROW EXECUTE FUNCTION fn_audit();

COMMENT ON TABLE execution_segment_sales_allocations IS
    'Immutable exact ownership of an execution segment quantity by sales order line.';
COMMENT ON COLUMN production_daily_report_items.execution_segment_sales_allocation_id IS
    'Exact sales allocation selected for a V155 execution-segment report line.';
COMMENT ON COLUMN stock_document_items.execution_segment_sales_allocation_id IS
    'Exact sales allocation inherited from the approved report for finished inbound.';
