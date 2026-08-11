-- Production-generated warehouse documents are owned by the production chain.
-- Generic stock CRUD must not mutate their identity or detail rows because that
-- would detach reservations, execution segments and approved report facts.

CREATE OR REPLACE FUNCTION fn_is_production_linked_stock_document(
    p_document_id UUID)
RETURNS BOOLEAN
LANGUAGE sql
STABLE
AS $$
    SELECT EXISTS (
        SELECT 1
        FROM stock_documents document
        WHERE document.id = p_document_id
          AND (
              EXISTS (
                  SELECT 1
                  FROM production_planning_package_documents package_document
                  WHERE package_document.document_id = document.id
                    AND package_document.document_type = document.doc_type
              )
              OR EXISTS (
                  SELECT 1
                  FROM plan_draw_links plan_link
                  WHERE plan_link.draw_id = document.id
                    AND plan_link.is_deleted = FALSE
              )
              OR EXISTS (
                  SELECT 1
                  FROM stock_document_items item
                  WHERE item.doc_id = document.id
                    AND item.is_deleted = FALSE
                    AND (
                        item.execution_segment_id IS NOT NULL
                        OR item.execution_segment_sales_allocation_id IS NOT NULL
                    )
              )
          )
    );
$$;

CREATE OR REPLACE FUNCTION fn_is_production_report_cleanup_authorized(
    p_document_id UUID)
RETURNS BOOLEAN
LANGUAGE sql
STABLE
AS $$
    SELECT current_setting(
               'app.production_report_reverse_doc_id', TRUE)
               = p_document_id::TEXT
       AND EXISTS (
           SELECT 1
           FROM stock_documents document
           WHERE document.id = p_document_id
             AND document.doc_type = 'FINISHED_IN'
             AND document.status = 0
       );
$$;

CREATE OR REPLACE FUNCTION fn_is_production_stock_cleanup_authorized(
    p_document_id UUID)
RETURNS BOOLEAN
LANGUAGE sql
STABLE
AS $$
    SELECT current_setting(
               'app.production_stock_cleanup_doc_id', TRUE)
               = p_document_id::TEXT
       AND EXISTS (
           SELECT 1
           FROM stock_documents document
           WHERE document.id = p_document_id
             AND document.doc_type = 'DRAW'
             AND document.status = 0
             AND document.is_deleted = FALSE
       );
$$;

CREATE OR REPLACE FUNCTION fn_guard_production_linked_stock_document()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
BEGIN
    IF TG_OP = 'DELETE' THEN
        IF fn_is_production_linked_stock_document(OLD.id) THEN
            RAISE EXCEPTION
                'production-linked stock document cannot be deleted by generic CRUD'
                USING ERRCODE = '23514',
                      CONSTRAINT =
                          'production_linked_stock_document_delete_guard';
        END IF;
        RETURN OLD;
    END IF;

    IF fn_is_production_report_cleanup_authorized(OLD.id)
       AND OLD.is_deleted = FALSE
       AND NEW.is_deleted = TRUE
       AND NEW.deleted_at IS NOT NULL
       AND (
           to_jsonb(NEW) - ARRAY[
               'is_deleted', 'deleted_at', 'updated_at', 'updated_by']
       ) = (
           to_jsonb(OLD) - ARRAY[
               'is_deleted', 'deleted_at', 'updated_at', 'updated_by']
       ) THEN
        RETURN NEW;
    END IF;
    IF fn_is_production_stock_cleanup_authorized(OLD.id)
       AND OLD.is_deleted = FALSE
       AND NEW.is_deleted = TRUE
       AND NEW.deleted_at IS NOT NULL
       AND NEW.status IN (0, -1)
       AND (
           to_jsonb(NEW) - ARRAY[
               'status', 'is_deleted', 'deleted_at',
               'updated_at', 'updated_by']
       ) = (
           to_jsonb(OLD) - ARRAY[
               'status', 'is_deleted', 'deleted_at',
               'updated_at', 'updated_by']
       ) THEN
        RETURN NEW;
    END IF;
    IF fn_is_production_linked_stock_document(OLD.id)
       AND (
           NEW.doc_type IS DISTINCT FROM OLD.doc_type
           OR NEW.bill_no IS DISTINCT FROM OLD.bill_no
           OR NEW.bill_date IS DISTINCT FROM OLD.bill_date
           OR NEW.warehouse_id IS DISTINCT FROM OLD.warehouse_id
           OR NEW.to_warehouse_id IS DISTINCT FROM OLD.to_warehouse_id
           OR NEW.supplier_id IS DISTINCT FROM OLD.supplier_id
           OR NEW.client_id IS DISTINCT FROM OLD.client_id
           OR NEW.worker_id IS DISTINCT FROM OLD.worker_id
           OR NEW.maker_id IS DISTINCT FROM OLD.maker_id
           OR NEW.plan_no IS DISTINCT FROM OLD.plan_no
           OR NEW.source_doc_no IS DISTINCT FROM OLD.source_doc_no
           OR NEW.department_id IS DISTINCT FROM OLD.department_id
           OR NEW.ass_team IS DISTINCT FROM OLD.ass_team
           OR NEW.remark IS DISTINCT FROM OLD.remark
           OR NEW.total_original IS DISTINCT FROM OLD.total_original
           OR NEW.total_local IS DISTINCT FROM OLD.total_local
           OR NEW.is_closed IS DISTINCT FROM OLD.is_closed
           OR NEW.is_deleted IS DISTINCT FROM OLD.is_deleted
           OR NEW.deleted_at IS DISTINCT FROM OLD.deleted_at
       ) THEN
        RAISE EXCEPTION
            'production-linked stock document identity is immutable'
            USING ERRCODE = '23514',
                  CONSTRAINT =
                      'production_linked_stock_document_update_guard';
    END IF;
    RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trg_guard_production_linked_stock_document
    ON stock_documents;
CREATE TRIGGER trg_guard_production_linked_stock_document
    BEFORE UPDATE OR DELETE ON stock_documents
    FOR EACH ROW EXECUTE FUNCTION
        fn_guard_production_linked_stock_document();

CREATE OR REPLACE FUNCTION fn_guard_production_linked_stock_document_item()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
DECLARE
    v_document_id UUID := COALESCE(OLD.doc_id, NEW.doc_id);
BEGIN
    IF TG_OP = 'DELETE' THEN
        IF fn_is_production_linked_stock_document(v_document_id) THEN
            RAISE EXCEPTION
                'production-linked stock document item cannot be deleted'
                USING ERRCODE = '23514',
                      CONSTRAINT =
                          'production_linked_stock_document_item_delete_guard';
        END IF;
        RETURN OLD;
    END IF;

    IF TG_OP = 'UPDATE'
       AND fn_is_production_report_cleanup_authorized(v_document_id)
       AND OLD.is_deleted = FALSE
       AND NEW.is_deleted = TRUE
       AND (
           to_jsonb(NEW) - ARRAY[
               'is_deleted', 'updated_at', 'updated_by']
       ) = (
           to_jsonb(OLD) - ARRAY[
               'is_deleted', 'updated_at', 'updated_by']
       ) THEN
        RETURN NEW;
    END IF;
    IF fn_is_production_stock_cleanup_authorized(v_document_id)
       AND OLD.is_deleted = FALSE
       AND NEW.is_deleted = TRUE
       AND (
           to_jsonb(NEW) - ARRAY[
               'is_deleted', 'updated_at', 'updated_by']
       ) = (
           to_jsonb(OLD) - ARRAY[
               'is_deleted', 'updated_at', 'updated_by']
       ) THEN
        RETURN NEW;
    END IF;

    IF fn_is_production_linked_stock_document(v_document_id) THEN
        IF NEW.doc_id IS DISTINCT FROM OLD.doc_id
           OR NEW.bill_type IS DISTINCT FROM OLD.bill_type
           OR NEW.bill_no IS DISTINCT FROM OLD.bill_no
           OR NEW.bill_date IS DISTINCT FROM OLD.bill_date
           OR NEW.line_no IS DISTINCT FROM OLD.line_no
           OR NEW.goods_id IS DISTINCT FROM OLD.goods_id
           OR NEW.color_id IS DISTINCT FROM OLD.color_id
           OR NEW.unit_id IS DISTINCT FROM OLD.unit_id
           OR NEW.unit_rate IS DISTINCT FROM OLD.unit_rate
           OR NEW.qty IS DISTINCT FROM OLD.qty
           OR NEW.base_qty IS DISTINCT FROM OLD.base_qty
           OR NEW.price IS DISTINCT FROM OLD.price
           OR NEW.amount_original IS DISTINCT FROM OLD.amount_original
           OR NEW.amount_local IS DISTINCT FROM OLD.amount_local
           OR NEW.weight IS DISTINCT FROM OLD.weight
           OR NEW.gift_qty IS DISTINCT FROM OLD.gift_qty
           OR NEW.surplus_qty IS DISTINCT FROM OLD.surplus_qty
           OR NEW.count_qty IS DISTINCT FROM OLD.count_qty
           OR NEW.place IS DISTINCT FROM OLD.place
           OR NEW.upstream_item_id IS DISTINCT FROM OLD.upstream_item_id
           OR NEW.execution_segment_id IS DISTINCT FROM
              OLD.execution_segment_id
           OR NEW.execution_segment_sales_allocation_id IS DISTINCT FROM
              OLD.execution_segment_sales_allocation_id
           OR NEW.source_doc_no IS DISTINCT FROM OLD.source_doc_no
           OR NEW.remark IS DISTINCT FROM OLD.remark
           OR NEW.is_deleted IS DISTINCT FROM OLD.is_deleted
       THEN
            RAISE EXCEPTION
                'production-linked stock document item is immutable'
                USING ERRCODE = '23514',
                      CONSTRAINT =
                          'production_linked_stock_document_item_update_guard';
        END IF;
    END IF;
    RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trg_guard_production_linked_stock_document_item
    ON stock_document_items;
CREATE TRIGGER trg_guard_production_linked_stock_document_item
    BEFORE UPDATE OR DELETE ON stock_document_items
    FOR EACH ROW EXECUTE FUNCTION
        fn_guard_production_linked_stock_document_item();

COMMENT ON FUNCTION fn_is_production_linked_stock_document(UUID) IS
    'Authoritative production provenance check; never infers from bill number text.';
