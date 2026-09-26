-- Actual physical production is distinct from the immutable approved plan.
-- Existing rows keep their historical identity. New commands persist one batch
-- and disjoint demand / planned-public / actual-surplus report lines.
ALTER TABLE production_daily_report_items
    ADD COLUMN output_batch_id UUID,
    ADD COLUMN output_batch_qty NUMERIC(18,4),
    ADD COLUMN is_public_output BOOLEAN NOT NULL DEFAULT FALSE,
    ADD COLUMN is_actual_surplus BOOLEAN NOT NULL DEFAULT FALSE;

ALTER TABLE production_daily_report_items ADD CONSTRAINT daily_report_output_slice_shape CHECK (
    ((output_batch_id IS NULL AND output_batch_qty IS NULL)
      OR (output_batch_id IS NOT NULL AND output_batch_qty IS NOT NULL AND qty IS NOT NULL
          AND output_batch_qty>0 AND qty>0 AND qty<=output_batch_qty))
    AND (NOT is_actual_surplus OR (is_public_output AND output_batch_id IS NOT NULL))
    AND (NOT is_public_output OR (
        execution_segment_id IS NOT NULL AND sales_order_item_id IS NULL
        AND execution_segment_sales_allocation_id IS NULL
        AND destination='WAREHOUSE' AND direct_transfer_demand_id IS NULL AND NOT is_final))
);
CREATE INDEX idx_daily_report_output_batch ON production_daily_report_items(output_batch_id)
    WHERE output_batch_id IS NOT NULL;
CREATE INDEX idx_daily_report_actual_surplus ON production_daily_report_items(execution_segment_id,plan_item_id)
    WHERE is_actual_surplus AND NOT is_deleted;

CREATE FUNCTION fn_execution_actual_surplus_qty(p_segment UUID,p_include_drafts BOOLEAN DEFAULT FALSE)
RETURNS NUMERIC LANGUAGE sql STABLE AS $$
    SELECT COALESCE(SUM(item.qty),0)
    FROM production_daily_report_items item JOIN production_daily_reports report ON report.id=item.report_id
    WHERE item.execution_segment_id=p_segment AND item.is_actual_surplus
      AND item.fqc_recovery_authorization_id IS NULL AND NOT item.is_deleted AND NOT report.is_deleted
      AND (report.status=1 OR (p_include_drafts AND report.status=0));
$$;
CREATE FUNCTION fn_plan_actual_surplus_qty(p_plan_item UUID,p_include_drafts BOOLEAN DEFAULT FALSE)
RETURNS NUMERIC LANGUAGE sql STABLE AS $$
    SELECT COALESCE(SUM(item.qty),0)
    FROM production_daily_report_items item JOIN production_daily_reports report ON report.id=item.report_id
    WHERE item.plan_item_id=p_plan_item AND item.is_actual_surplus
      AND item.fqc_recovery_authorization_id IS NULL AND NOT item.is_deleted AND NOT report.is_deleted
      AND (report.status=1 OR (p_include_drafts AND report.status=0));
$$;

-- Physical surplus contributes to fqty, but can never count as produced sales
-- responsibility when an explicit early-final report reduces the old target.
CREATE FUNCTION fn_plan_actual_output_contribution_qty(p_plan_item UUID,p_current_report UUID DEFAULT NULL)
RETURNS NUMERIC LANGUAGE sql STABLE AS $$
    SELECT COALESCE(SUM(GREATEST(item.qty-COALESCE((
        SELECT SUM(adjustment.adjusted_qty) FROM production_fqc_contribution_adjustments adjustment
        WHERE adjustment.source_report_item_id=item.id),0),0)),0)
    FROM production_daily_report_items item JOIN production_daily_reports report ON report.id=item.report_id
    WHERE item.plan_item_id=p_plan_item AND item.is_actual_surplus
      AND NOT item.is_deleted AND NOT report.is_deleted AND (report.status=1 OR report.id=p_current_report);
$$;

DO $planned_final_quantity$
DECLARE definition TEXT;anchor TEXT;
BEGIN
    SELECT pg_get_functiondef('fn_guard_daily_report_target_event()'::regprocedure) INTO definition;
    anchor:='GREATEST(COALESCE(target.fqty,0),COALESCE(('; 
    IF position(anchor IN definition)=0 THEN RAISE EXCEPTION 'V694 final target contribution anchor changed'; END IF;
    definition:=replace(definition,anchor,
        'GREATEST(COALESCE(target.fqty,0)-fn_plan_actual_output_contribution_qty(target.id,NEW.report_id),COALESCE((');
    definition:=replace(definition,'AND item.fqc_recovery_authorization_id IS NULL',
        'AND item.fqc_recovery_authorization_id IS NULL AND NOT item.is_actual_surplus');
    EXECUTE definition;
END;
$planned_final_quantity$;

-- Old V690 mixed sales/public rows already have a provable public identity.
-- A plain internal MAKE task is not by itself proof of public ownership.
CREATE FUNCTION fn_daily_report_is_public_output(p_item UUID)
RETURNS BOOLEAN LANGUAGE sql STABLE AS $$
    SELECT COALESCE((SELECT item.is_public_output OR (
        item.execution_segment_id IS NOT NULL AND item.execution_segment_sales_allocation_id IS NULL
        AND item.sales_order_item_id IS NULL AND (EXISTS(
            SELECT 1 FROM execution_segment_sales_allocations allocation
            WHERE allocation.execution_segment_id=item.execution_segment_id)
          OR EXISTS(
            SELECT 1 FROM production_execution_segments segment
            JOIN production_plans plan ON plan.id=segment.plan_id
            JOIN production_material_analysis_plan_links approved_surplus
              ON approved_surplus.plan_id=plan.id AND approved_surplus.analysis_id=plan.material_analysis_id
             AND approved_surplus.analysis_item_id=plan.material_analysis_item_id
             AND approved_surplus.allocation_status='APPROVED' AND approved_surplus.public_surplus_qty>0
            WHERE segment.id=item.execution_segment_id
              AND EXISTS(SELECT 1 FROM plan_order_item_links sales_origin
                  WHERE sales_origin.plan_item_id=segment.source_plan_item_id AND NOT sales_origin.is_deleted))))
        FROM production_daily_report_items item WHERE item.id=p_item),FALSE);
$$;

CREATE FUNCTION fn_guard_daily_report_output_identity() RETURNS trigger LANGUAGE plpgsql AS $$
DECLARE source production_daily_report_items%ROWTYPE;
BEGIN
    IF TG_OP='UPDATE' AND
       (OLD.output_batch_id,OLD.output_batch_qty,OLD.is_public_output,OLD.is_actual_surplus)
       IS DISTINCT FROM (NEW.output_batch_id,NEW.output_batch_qty,NEW.is_public_output,NEW.is_actual_surplus)
       AND EXISTS(SELECT 1 FROM production_daily_reports WHERE id=OLD.report_id AND status<>0) THEN
        RAISE EXCEPTION 'Approved production output identity is immutable' USING ERRCODE='23514';
    END IF;
    IF NEW.fqc_recovery_authorization_id IS NOT NULL AND NEW.output_batch_id IS NOT NULL THEN
        SELECT item.* INTO source FROM production_fqc_recovery_authorizations authority
        JOIN production_daily_report_items item ON item.id=authority.source_report_item_id
        WHERE authority.id=NEW.fqc_recovery_authorization_id;
        IF NOT FOUND OR NEW.is_public_output IS DISTINCT FROM fn_daily_report_is_public_output(source.id)
            OR NEW.is_actual_surplus IS DISTINCT FROM source.is_actual_surplus THEN
            RAISE EXCEPTION 'Quality recovery must retain its original output ownership' USING ERRCODE='23514';
        END IF;
    END IF;
    RETURN NEW;
END;
$$;
CREATE TRIGGER trg_guard_daily_report_output_identity
BEFORE INSERT OR UPDATE ON production_daily_report_items FOR EACH ROW
EXECUTE FUNCTION fn_guard_daily_report_output_identity();

CREATE FUNCTION fn_assert_daily_report_output_batch() RETURNS trigger LANGUAGE plpgsql AS $$
DECLARE batch UUID; batch_qty NUMERIC; actual_qty NUMERIC; identities INTEGER; original_qty INTEGER;
BEGIN
    FOR batch IN SELECT DISTINCT id FROM unnest(ARRAY[
        CASE WHEN TG_OP<>'INSERT' THEN OLD.output_batch_id END,
        CASE WHEN TG_OP<>'DELETE' THEN NEW.output_batch_id END]) id WHERE id IS NOT NULL
    LOOP
        SELECT SUM(qty),MIN(output_batch_qty),COUNT(DISTINCT output_batch_qty),
               COUNT(DISTINCT (report_id,execution_segment_id,plan_item_id,goods_id,color_id,unit_id,unit_rate))
        INTO actual_qty,batch_qty,original_qty,identities
        FROM production_daily_report_items WHERE output_batch_id=batch AND NOT is_deleted;
        IF actual_qty IS NOT NULL AND (actual_qty<>batch_qty OR identities<>1 OR original_qty<>1) THEN
            RAISE EXCEPTION 'Production batch slices must conserve the original quantity and exact source'
                USING ERRCODE='23514',CONSTRAINT='daily_report_output_batch_conservation';
        END IF;
    END LOOP;
    RETURN NULL;
END;
$$;
CREATE CONSTRAINT TRIGGER trg_assert_daily_report_output_batch
AFTER INSERT OR UPDATE OR DELETE ON production_daily_report_items
DEFERRABLE INITIALLY DEFERRED FOR EACH ROW EXECUTE FUNCTION fn_assert_daily_report_output_batch();

DO $migration$
DECLARE definition TEXT; anchor TEXT;
BEGIN
    SELECT pg_get_functiondef('fn_validate_daily_report_execution_segment()'::regprocedure) INTO definition;
    anchor := 'IF NEW.execution_segment_sales_allocation_id IS NULL';
    IF position(anchor IN definition)=0 THEN RAISE EXCEPTION 'V694 report ownership anchor changed'; END IF;
    EXECUTE replace(definition,anchor,anchor||E'\n           AND NOT NEW.is_actual_surplus');
END;
$migration$;

-- Plan fqty remains an actual, quality-adjusted production fact. Only separately
-- recorded actual-surplus reports enlarge its admissible physical total.
DROP TRIGGER trg_production_plan_finished_guard ON production_plan_items;
CREATE FUNCTION fn_assert_production_plan_actual_finished() RETURNS trigger LANGUAGE plpgsql AS $$
DECLARE actual production_plan_items%ROWTYPE;
BEGIN
    IF TG_OP='UPDATE' AND NEW.fqty<=OLD.fqty THEN RETURN NULL; END IF;
    SELECT * INTO actual FROM production_plan_items WHERE id=NEW.id;
    IF actual.fqty<0 OR actual.fqty>actual.qty+fn_plan_actual_surplus_qty(actual.id,FALSE) THEN
        RAISE EXCEPTION 'Actual production exceeds the approved plan and separately approved surplus facts'
            USING ERRCODE='23514',CONSTRAINT='production_plan_actual_finished_guard';
    END IF;
    RETURN NULL;
END;
$$;
CREATE CONSTRAINT TRIGGER trg_production_plan_finished_guard
AFTER INSERT OR UPDATE OF fqty ON production_plan_items DEFERRABLE INITIALLY DEFERRED
FOR EACH ROW EXECUTE FUNCTION fn_assert_production_plan_actual_finished();

CREATE OR REPLACE FUNCTION fn_assert_execution_segment_public_surplus_capacity(p_segment_id UUID)
RETURNS VOID LANGUAGE plpgsql AS $$
DECLARE v_planned NUMERIC;v_public NUMERIC;v_reported NUMERIC;v_approved NUMERIC;v_inbound NUMERIC;v_actual NUMERIC;
BEGIN
    IF p_segment_id IS NULL THEN RETURN; END IF;
    IF current_setting('transaction_isolation')<>'read committed' THEN
        RAISE EXCEPTION 'Production output writes require READ COMMITTED isolation' USING ERRCODE='25001';
    END IF;
    SELECT planned_qty INTO v_planned FROM production_execution_segments WHERE id=p_segment_id FOR UPDATE;
    IF NOT FOUND THEN RETURN; END IF;
    SELECT GREATEST(v_planned-COALESCE(SUM(allocated_qty),0),0) INTO v_public
        FROM execution_segment_sales_allocations WHERE execution_segment_id=p_segment_id;
    SELECT COALESCE(SUM(item.qty),0) INTO v_reported
        FROM production_daily_report_items item JOIN production_daily_reports report ON report.id=item.report_id
        WHERE item.execution_segment_id=p_segment_id AND item.fqc_recovery_authorization_id IS NULL
          AND NOT item.is_actual_surplus AND NOT item.is_deleted AND NOT report.is_deleted AND report.status IN(0,1);
    IF v_reported>v_planned THEN
        RAISE EXCEPTION 'Planned production reports exceed immutable task quantity'
            USING ERRCODE='23514',CONSTRAINT='daily_report_segment_planned_capacity_guard';
    END IF;
    IF EXISTS(SELECT 1 FROM execution_segment_sales_allocations allocation
        WHERE allocation.execution_segment_id=p_segment_id AND allocation.allocated_qty<(
            SELECT COALESCE(SUM(item.qty),0) FROM production_daily_report_items item
            JOIN production_daily_reports report ON report.id=item.report_id
            WHERE item.execution_segment_sales_allocation_id=allocation.id
              AND item.fqc_recovery_authorization_id IS NULL
              AND NOT item.is_deleted AND NOT report.is_deleted AND report.status IN(0,1))) THEN
        RAISE EXCEPTION 'Sales production reports exceed their exact allocation'
            USING ERRCODE='23514',CONSTRAINT='daily_report_segment_sales_capacity_guard';
    END IF;
    SELECT COALESCE(SUM(item.qty) FILTER(WHERE item.fqc_recovery_authorization_id IS NULL AND NOT item.is_actual_surplus),0),
           COALESCE(SUM(item.qty) FILTER(WHERE report.status=1),0)
      INTO v_reported,v_approved
      FROM production_daily_report_items item JOIN production_daily_reports report ON report.id=item.report_id
      WHERE item.execution_segment_id=p_segment_id AND item.execution_segment_sales_allocation_id IS NULL
        AND item.sales_order_item_id IS NULL AND NOT item.is_deleted AND NOT report.is_deleted AND report.status IN(0,1);
    IF v_reported>v_public THEN
        RAISE EXCEPTION 'Planned public reports exceed their independent allocation'
            USING ERRCODE='23514',CONSTRAINT='daily_report_segment_public_capacity_guard';
    END IF;
    v_actual:=fn_execution_actual_surplus_qty(p_segment_id,FALSE);
    SELECT COALESCE(SUM(item.qty),0) INTO v_inbound
      FROM stock_document_items item JOIN stock_documents document ON document.id=item.doc_id
      WHERE item.execution_segment_id=p_segment_id AND item.execution_segment_sales_allocation_id IS NULL
        AND NOT item.is_deleted AND NOT document.is_deleted AND document.doc_type='FINISHED_IN' AND document.status=1;
    IF v_inbound>LEAST(v_public+v_actual,v_approved) THEN
        RAISE EXCEPTION 'Finished-in exceeds approved public output facts'
            USING ERRCODE='23514',CONSTRAINT='finished_in_segment_public_report_guard';
    END IF;
END;
$$;

-- V690 only scheduled its deferred checker for NULL-sales rows. Planned sales
-- and shared batch capacity use the same serialization and database backstop.
CREATE OR REPLACE FUNCTION fn_assert_execution_segment_public_surplus_row()
RETURNS TRIGGER LANGUAGE plpgsql AS $$
DECLARE v_old UUID;v_new UUID;v_segment UUID;
BEGIN
    IF TG_OP<>'INSERT' THEN v_old:=OLD.execution_segment_id; END IF;
    IF TG_OP<>'DELETE' THEN v_new:=NEW.execution_segment_id; END IF;
    FOR v_segment IN SELECT DISTINCT segment FROM unnest(ARRAY[v_old,v_new]) segment
        WHERE segment IS NOT NULL ORDER BY segment
    LOOP PERFORM fn_assert_execution_segment_public_surplus_capacity(v_segment); END LOOP;
    RETURN NULL;
END;
$$;
CREATE CONSTRAINT TRIGGER trg_assert_daily_report_output_ownership_capacity
AFTER UPDATE OF is_actual_surplus,is_public_output ON production_daily_report_items
DEFERRABLE INITIALLY DEFERRED FOR EACH ROW EXECUTE FUNCTION fn_assert_execution_segment_public_surplus_row();

CREATE FUNCTION fn_assert_actual_report_material_posting(p_report UUID) RETURNS VOID LANGUAGE plpgsql AS $$
BEGIN
    IF NOT EXISTS(SELECT 1 FROM production_daily_reports WHERE id=p_report AND status=1 AND NOT is_deleted) THEN RETURN; END IF;
    IF EXISTS(
        SELECT 1 FROM production_daily_report_items item
        JOIN production_execution_segments segment ON segment.id=item.execution_segment_id
        WHERE item.report_id=p_report AND NOT item.is_deleted AND item.output_batch_id IS NOT NULL
          AND item.fqc_recovery_authorization_id IS NULL AND segment.material_requirement_mode<>'ZERO_MATERIAL'
          AND NOT (NOT item.is_actual_surplus AND fn_split_batch_empty_issued(segment.id))
          AND NOT EXISTS(
              SELECT 1 FROM production_material_settlement_events event
              JOIN production_material_settlement_postings posting ON posting.event_id=event.id
              JOIN production_material_demands demand ON demand.id=posting.demand_id
              WHERE event.daily_report_id=p_report AND event.event_type='POST'
                AND posting.settlement_type='CONSUMED' AND posting.qty_base>0
                AND demand.execution_segment_id IN (
                    SELECT segment_id FROM fn_production_material_usage_source_segments(segment.id)))) THEN
        RAISE EXCEPTION 'Actual production requires its own positive, exact material consumption posting'
            USING ERRCODE='23514',CONSTRAINT='daily_report_actual_material_posting_guard';
    END IF;
END;
$$;
CREATE FUNCTION fn_check_actual_report_material_posting() RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
    IF TG_TABLE_NAME='production_daily_reports' THEN
        PERFORM fn_assert_actual_report_material_posting(NEW.id);
    ELSE
        IF TG_OP<>'INSERT' THEN PERFORM fn_assert_actual_report_material_posting(OLD.report_id); END IF;
        IF TG_OP<>'DELETE' THEN PERFORM fn_assert_actual_report_material_posting(NEW.report_id); END IF;
    END IF;
    RETURN NULL;
END;
$$;
CREATE CONSTRAINT TRIGGER trg_assert_actual_report_material_posting
AFTER INSERT OR UPDATE OF status,is_deleted ON production_daily_reports
DEFERRABLE INITIALLY DEFERRED FOR EACH ROW EXECUTE FUNCTION fn_check_actual_report_material_posting();
CREATE CONSTRAINT TRIGGER trg_assert_actual_report_item_material_posting
AFTER INSERT OR UPDATE OR DELETE ON production_daily_report_items
DEFERRABLE INITIALLY DEFERRED FOR EACH ROW EXECUTE FUNCTION fn_check_actual_report_material_posting();
COMMENT ON COLUMN production_daily_report_items.is_actual_surplus IS
    'Actual production outside the immutable planned quantity; PUBLIC ownership is retained through FQC recovery and warehouse receipt';
COMMENT ON COLUMN production_daily_report_items.output_batch_id IS
    'One operator-entered physical production batch, conserved across its server-generated output slices';
