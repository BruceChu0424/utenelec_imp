-- A fully capped sales share remains as a zero-quantity historical anchor.
-- It is authorized only by the same transaction's final-report CAP event;
-- normal planning must still create positive allocations.
ALTER TABLE plan_order_item_links DROP CONSTRAINT plan_order_item_links_allocated_qty_check;
ALTER TABLE plan_order_item_links ADD CONSTRAINT plan_order_item_links_allocated_qty_check
    CHECK (allocated_qty > 0 OR (allocated_qty = 0 AND COALESCE(capped_qty,0) > 0
        AND produced_qty = 0 AND inbound_qty = 0));

CREATE FUNCTION fn_guard_zero_capped_plan_link() RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
    IF NEW.allocated_qty <> 0 THEN RETURN NEW; END IF;
    IF TG_OP = 'UPDATE' THEN
        IF OLD.allocated_qty = 0 AND
            (NEW.plan_item_id, NEW.order_item_id, NEW.capped_qty)
                IS NOT DISTINCT FROM (OLD.plan_item_id, OLD.order_item_id, OLD.capped_qty) THEN
            RETURN NEW;
        END IF;
        IF OLD.allocated_qty > 0 AND NEW.plan_item_id = OLD.plan_item_id
            AND NEW.order_item_id = OLD.order_item_id
            AND OLD.allocated_qty + COALESCE(OLD.capped_qty,0) = NEW.capped_qty
            AND EXISTS(SELECT 1 FROM production_daily_report_target_events event
                WHERE event.plan_item_id = NEW.plan_item_id AND event.event_type = 'CAP'
                  AND event.xmin::text = pg_current_xact_id()::text) THEN
            RETURN NEW;
        END IF;
    END IF;
    RAISE EXCEPTION 'Zero sales allocation requires the exact final-report reduction event'
        USING ERRCODE = '23514', CONSTRAINT = 'zero_capped_plan_link_provenance';
END;
$$;
CREATE TRIGGER trg_zero_capped_plan_link BEFORE INSERT OR UPDATE ON plan_order_item_links
FOR EACH ROW EXECUTE FUNCTION fn_guard_zero_capped_plan_link();

-- An unposted supplement may have been explicitly started. Its own immutable
-- reversal is the authority to cancel it; ordinary started tasks stay guarded.
CREATE FUNCTION fn_actual_supplement_cancel_authorized(p_segment UUID) RETURNS BOOLEAN
LANGUAGE sql STABLE AS $$
    SELECT EXISTS(SELECT 1 FROM production_actual_output_supplement_proofs proof
        JOIN production_actual_output_supplement_reversals reversed ON reversed.proof_id=proof.id
        WHERE proof.supplement_execution_segment_id=p_segment
          AND reversed.xmin::text=pg_current_xact_id()::text)
      AND NOT EXISTS(SELECT 1 FROM production_daily_report_items item
          JOIN production_daily_reports report ON report.id=item.report_id
          WHERE item.execution_segment_id=p_segment AND NOT item.is_deleted
            AND NOT report.is_deleted AND report.status IN(0,1));
$$;

DO $cancel_transition$
DECLARE definition TEXT; anchor TEXT := 'OR (OLD.status = ''IN_PROGRESS'' AND NEW.status = ''COMPLETED'')';
BEGIN
    SELECT pg_get_functiondef('fn_validate_production_execution_segment()'::regprocedure) INTO definition;
    IF position(anchor IN definition)=0 THEN RAISE EXCEPTION 'V704 execution transition contract changed'; END IF;
    EXECUTE replace(definition,anchor,anchor || E'\n OR (OLD.status IN (''DISPATCHED'',''IN_PROGRESS'')\n'
        || ' AND NEW.status = ''CANCELLED'' AND fn_actual_supplement_cancel_authorized(OLD.id))');
END;
$cancel_transition$;
