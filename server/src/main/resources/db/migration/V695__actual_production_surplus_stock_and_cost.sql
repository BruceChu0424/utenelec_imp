-- Actual excess output keeps its original execution/cost lineage, while its
-- warehouse ownership is public. Planned quantities and sales allocations stay frozen.
CREATE FUNCTION fn_finished_in_is_public_output(p_stock_item UUID)
RETURNS BOOLEAN LANGUAGE sql STABLE AS $$
    SELECT EXISTS (
        SELECT 1 FROM stock_document_items item
        JOIN production_daily_report_items source ON source.id=item.source_daily_report_item_id
        WHERE item.id=p_stock_item AND item.bill_type='FINISHED_IN'
          AND fn_daily_report_is_public_output(source.id)
          AND source.execution_segment_id=item.execution_segment_id
          AND source.plan_item_id=item.upstream_item_id
    )
$$;

CREATE FUNCTION fn_guard_plan_actual_inbound_quantity()
RETURNS TRIGGER LANGUAGE plpgsql AS $$
DECLARE v_limit NUMERIC; v_old NUMERIC := 0;
BEGIN
    IF TG_OP='UPDATE' THEN v_old:=COALESCE(OLD.iqty,0); END IF;
    v_limit:=LEAST(COALESCE(NEW.fqty,0),
        COALESCE(NEW.qty,0)+fn_plan_actual_surplus_qty(NEW.id,FALSE));
    IF COALESCE(NEW.iqty,0)<0 OR
       (COALESCE(NEW.iqty,0)>v_limit AND (TG_OP='INSERT' OR COALESCE(NEW.iqty,0)>v_old)) THEN
        RAISE EXCEPTION 'finished-in exceeds approved production including proven actual surplus'
            USING ERRCODE='23514', CONSTRAINT='production_plan_actual_inbound_guard';
    END IF;
    RETURN NEW;
END;
$$;
DROP TRIGGER trg_production_plan_inbound_guard ON production_plan_items;
CREATE TRIGGER trg_production_plan_inbound_guard BEFORE INSERT OR UPDATE OF iqty ON production_plan_items
    FOR EACH ROW EXECUTE FUNCTION fn_guard_plan_actual_inbound_quantity();

DO $stock_and_completion$
DECLARE definition TEXT; needle TEXT; replacement TEXT;
BEGIN
    SELECT pg_get_functiondef('fn_validate_finished_in_execution_segment()'::regprocedure) INTO definition;
    needle := 'IF NEW.execution_segment_sales_allocation_id IS NULL
           AND v_segment.planned_qty <= (';
    replacement := 'IF NEW.execution_segment_sales_allocation_id IS NULL
           AND NOT EXISTS (SELECT 1 FROM production_daily_report_items source
               WHERE source.id=NEW.source_daily_report_item_id AND source.is_actual_surplus
                 AND source.execution_segment_id=NEW.execution_segment_id
                 AND source.plan_item_id=NEW.upstream_item_id
                 AND source.sales_order_item_id IS NULL
                 AND source.execution_segment_sales_allocation_id IS NULL)
           AND v_segment.planned_qty <= (';
    IF position(needle IN definition)=0 THEN RAISE EXCEPTION 'V695 finished-in ownership anchor changed'; END IF;
    EXECUTE replace(definition,needle,replacement);

    SELECT pg_get_functiondef('fn_guard_execution_segment_finished_in()'::regprocedure) INTO definition;
    needle := 'SELECT segment.planned_qty';
    IF (length(definition)-length(replace(definition,needle,'')))/length(needle)<>1 THEN
        RAISE EXCEPTION 'V695 finished-in quantity anchor changed';
    END IF;
    EXECUTE replace(definition,needle,
        'SELECT segment.planned_qty + fn_execution_actual_surplus_qty(segment.id,FALSE)');

    SELECT pg_get_functiondef('fn_reconcile_execution_segment_completion(uuid)'::regprocedure) INTO definition;
    needle := 'SELECT planned_qty, status';
    IF position(needle IN definition)=0 THEN RAISE EXCEPTION 'V695 completion target anchor changed'; END IF;
    definition:=replace(definition,needle,
        'SELECT planned_qty + fn_execution_actual_surplus_qty(p_segment_id,FALSE), status');
    needle := 'IF v_status = ''COMPLETED'' THEN';
    IF position(needle IN definition)=0 THEN RAISE EXCEPTION 'V695 completion draft anchor changed'; END IF;
    EXECUTE replace(definition,needle,
        'v_clear := v_clear AND NOT EXISTS (
            SELECT 1 FROM production_daily_report_items item
            JOIN production_daily_reports report ON report.id=item.report_id
            WHERE item.execution_segment_id=p_segment_id AND NOT item.is_deleted
              AND report.status=0 AND NOT report.is_deleted);
    '||needle);

    SELECT pg_get_functiondef('fn_guard_cost_business_refresh_source()'::regprocedure) INTO definition;
    needle := 'AND item.is_final AND NOT item.is_deleted';
    IF position(needle IN definition)=0 THEN RAISE EXCEPTION 'V695 cost refresh source anchor changed'; END IF;
    EXECUTE replace(definition,needle,
        'AND (item.is_final OR item.is_actual_surplus) AND NOT item.is_deleted');
END;
$stock_and_completion$;

-- Revalidate a changed source UUID as well as the original segment/sales fields.
CREATE TRIGGER trg_validate_finished_in_actual_source
    BEFORE UPDATE OF source_daily_report_item_id ON stock_document_items
    FOR EACH ROW WHEN (OLD.source_daily_report_item_id IS DISTINCT FROM NEW.source_daily_report_item_id)
    EXECUTE FUNCTION fn_validate_finished_in_execution_segment();

CREATE OR REPLACE FUNCTION fn_production_execution_cost_target(p_scope UUID) RETURNS NUMERIC
LANGUAGE sql STABLE AS $$
    SELECT (CASE WHEN EXISTS(SELECT 1 FROM production_execution_segment_splits split WHERE split.source_segment_id=root.id)
        THEN (SELECT COALESCE(sum(leaf.planned_qty*leaf.product_unit_rate),0)
              FROM production_execution_segments leaf
              WHERE leaf.split_root_segment_id=root.id
                AND fn_production_execution_cost_scope(leaf.id)=root.id
                AND NOT EXISTS(SELECT 1 FROM production_execution_segment_splits retired WHERE retired.source_segment_id=leaf.id))
        ELSE root.planned_qty*root.product_unit_rate END)
        + COALESCE((SELECT sum(fn_execution_actual_surplus_qty(member.id,FALSE)*member.product_unit_rate)
                    FROM production_execution_segments member
                    WHERE (member.id=root.id OR member.split_root_segment_id=root.id)
                      AND fn_production_execution_cost_scope(member.id)=root.id),0)
    FROM production_execution_segments root WHERE root.id=p_scope
$$;

COMMENT ON FUNCTION fn_production_execution_cost_target(UUID) IS
    'Frozen leaf production target plus approved original actual excess; replacement recovery does not expand the denominator. Reversal derives a new forward cost revision.';
COMMENT ON FUNCTION fn_finished_in_is_public_output(UUID) IS
    'Explicit public ownership from the immutable report source; never infer ownership from a matching product or originating plan.';

-- A pending actual-output draft must stay approvable. Removing the final draft
-- re-evaluates completion without inventing any report or stock quantity.
CREATE FUNCTION fn_reconcile_execution_completion_report_change()
RETURNS TRIGGER LANGUAGE plpgsql AS $$
DECLARE segment_id UUID;
BEGIN
    IF TG_TABLE_NAME='production_daily_reports' THEN
        FOR segment_id IN SELECT DISTINCT item.execution_segment_id FROM production_daily_report_items item
            WHERE item.report_id=NEW.id AND item.execution_segment_id IS NOT NULL ORDER BY item.execution_segment_id
        LOOP PERFORM fn_reconcile_execution_segment_completion(segment_id); END LOOP;
    ELSE
        FOR segment_id IN SELECT DISTINCT id FROM unnest(ARRAY[
            CASE WHEN TG_OP<>'INSERT' THEN OLD.execution_segment_id END,
            CASE WHEN TG_OP<>'DELETE' THEN NEW.execution_segment_id END]) id WHERE id IS NOT NULL ORDER BY id
        LOOP PERFORM fn_reconcile_execution_segment_completion(segment_id); END LOOP;
    END IF;
    RETURN NULL;
END;
$$;
CREATE CONSTRAINT TRIGGER trg_completion_after_report_status
    AFTER UPDATE OF status,is_deleted ON production_daily_reports DEFERRABLE INITIALLY DEFERRED
    FOR EACH ROW EXECUTE FUNCTION fn_reconcile_execution_completion_report_change();
CREATE CONSTRAINT TRIGGER trg_completion_after_report_lines
    AFTER INSERT OR UPDATE OR DELETE ON production_daily_report_items DEFERRABLE INITIALLY DEFERRED
    FOR EACH ROW EXECUTE FUNCTION fn_reconcile_execution_completion_report_change();

-- These are inherited MAKE obligations. Public output can later be selected as
-- ordinary available stock, but must never be seized through the original plan peg.
CREATE FUNCTION fn_guard_public_output_inherited_peg()
RETURNS TRIGGER LANGUAGE plpgsql AS $$
DECLARE source_item UUID;
BEGIN
    source_item := CASE WHEN TG_TABLE_NAME='production_material_make_receipt_allocations'
        THEN (to_jsonb(NEW)->>'receipt_item_id')::UUID
        ELSE (to_jsonb(NEW)->>'source_stock_document_item_id')::UUID END;
    IF fn_finished_in_is_public_output(source_item) THEN
        RAISE EXCEPTION 'public production output cannot inherit its original MAKE obligation'
            USING ERRCODE='23514', CONSTRAINT='public_output_inherited_peg_guard';
    END IF;
    RETURN NEW;
END;
$$;
CREATE TRIGGER trg_public_output_make_receipt_peg
    BEFORE INSERT OR UPDATE OF receipt_item_id ON production_material_make_receipt_allocations
    FOR EACH ROW EXECUTE FUNCTION fn_guard_public_output_inherited_peg();
CREATE TRIGGER trg_public_output_analysis_exact_peg
    BEFORE INSERT OR UPDATE OF source_stock_document_item_id ON preplan_analysis_stock_exact_pegs
    FOR EACH ROW EXECUTE FUNCTION fn_guard_public_output_inherited_peg();
