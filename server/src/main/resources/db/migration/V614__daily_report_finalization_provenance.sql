-- Final-report target reductions and demand releases need their own immutable
-- provenance. A red reversal may restore only facts created by that report.
CREATE INDEX idx_daily_report_material_plan_item
ON production_material_demands(source_plan_item_id,id) WHERE NOT is_deleted;

CREATE FUNCTION fn_daily_report_open_material_commitment(p_demand UUID)
RETURNS NUMERIC LANGUAGE sql STABLE AS $$
    SELECT COALESCE((SELECT SUM(qty-released_qty) FROM stock_reservations
        WHERE demand_id=p_demand AND NOT is_deleted),0)
      + COALESCE((SELECT SUM(allocated_qty-consumed_qty-released_qty) FROM production_material_supply_pegs
        WHERE demand_id=p_demand AND status<>'REVERSED'),0);
$$;

-- GOOD_RETURN restores reservation consumption but is not never-issued stock.
-- Distinguish actual issue history from the unused commitment before closing a target.
CREATE FUNCTION fn_daily_report_has_unissued_material(p_plan_item UUID)
RETURNS BOOLEAN LANGUAGE sql STABLE AS $$
    SELECT EXISTS(
        SELECT 1 FROM production_material_demands demand
        JOIN stock_reservations reservation ON reservation.demand_id=demand.id
        WHERE demand.source_plan_item_id=p_plan_item AND NOT demand.is_deleted
          AND reservation.owner_type='PRODUCTION_MATERIAL_DEMAND' AND NOT reservation.is_deleted
          AND reservation.qty-reservation.released_qty>COALESCE((
              SELECT SUM(CASE posting_type WHEN 'ISSUE' THEN qty_base
                         WHEN 'ISSUE_REVERSE' THEN -qty_base ELSE 0 END)
              FROM production_material_stock_postings WHERE reservation_id=reservation.id),0))
       OR EXISTS(
        SELECT 1 FROM production_material_demands demand
        JOIN production_planning_package_document_items mapping ON mapping.demand_id=demand.id
          AND mapping.document_type='DRAW'
        JOIN stock_document_items item ON item.id=mapping.document_item_id AND NOT item.is_deleted
        JOIN stock_documents document ON document.id=item.doc_id AND document.doc_type='DRAW'
          AND document.status IN (0,1) AND NOT document.is_deleted
        WHERE demand.source_plan_item_id=p_plan_item AND NOT demand.is_deleted
          AND item.qty>COALESCE(item.issued_qty,0));
$$;

CREATE TABLE production_daily_report_target_events (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    report_id UUID NOT NULL REFERENCES production_daily_reports(id),
    plan_item_id UUID NOT NULL REFERENCES production_plan_items(id),
    event_type TEXT NOT NULL CHECK(event_type IN ('CAP','RESTORE')),
    before_qty NUMERIC(18,4) NOT NULL CHECK(before_qty>0),
    after_qty NUMERIC(18,4) NOT NULL CHECK(after_qty>0),
    source_event_id UUID UNIQUE REFERENCES production_daily_report_target_events(id),
    created_by UUID NOT NULL REFERENCES users(id),
    created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    UNIQUE(report_id,plan_item_id,event_type),
    CHECK(event_type='CAP' AND before_qty>after_qty AND source_event_id IS NULL
       OR event_type='RESTORE' AND before_qty<after_qty AND source_event_id IS NOT NULL)
);
CREATE INDEX idx_daily_report_target_plan_item ON production_daily_report_target_events(plan_item_id,id);

CREATE FUNCTION fn_guard_daily_report_target_event() RETURNS trigger LANGUAGE plpgsql AS $$
DECLARE target production_plan_items%ROWTYPE; source production_daily_report_target_events%ROWTYPE;
BEGIN
    IF TG_OP<>'INSERT' THEN
        RAISE EXCEPTION 'Daily-report target events are append-only' USING ERRCODE='55000';
    END IF;
    IF NEW.created_by::text IS DISTINCT FROM NULLIF(current_setting('app.actor_id',TRUE),'') THEN
        RAISE EXCEPTION 'Final target event actor must match the transaction audit actor' USING ERRCODE='23514';
    END IF;
    SELECT * INTO target FROM production_plan_items WHERE id=NEW.plan_item_id AND NOT is_deleted FOR UPDATE;
    IF NOT FOUND OR target.qty<>NEW.before_qty OR NOT EXISTS(
        SELECT 1 FROM production_daily_reports report
        JOIN production_daily_report_items item ON item.report_id=report.id
        WHERE report.id=NEW.report_id AND NOT report.is_deleted AND NOT item.is_deleted
          AND item.plan_item_id=NEW.plan_item_id AND item.is_final
          AND item.fqc_recovery_authorization_id IS NULL
          AND report.status=CASE NEW.event_type WHEN 'CAP' THEN 0 ELSE 1 END) THEN
        RAISE EXCEPTION 'Target change requires its exact active final report and original quantity' USING ERRCODE='23514';
    END IF;
    IF NEW.event_type='CAP' THEN
        IF fn_daily_report_has_unissued_material(NEW.plan_item_id) THEN
            RAISE EXCEPTION 'Finish existing unissued material commitments before an early final report' USING ERRCODE='23514';
        END IF;
        IF NOT EXISTS(SELECT 1 FROM plan_order_item_links link
            WHERE link.plan_item_id=NEW.plan_item_id AND NOT link.is_deleted) THEN
            RAISE EXCEPTION 'Internal short production keeps its original task and parent supply responsibility' USING ERRCODE='23514';
        END IF;
        IF EXISTS(SELECT 1 FROM production_material_demands demand
            JOIN production_material_supply_pegs peg ON peg.demand_id=demand.id
            WHERE demand.source_plan_item_id=NEW.plan_item_id AND NOT demand.is_deleted
              AND peg.status<>'REVERSED' AND peg.allocated_qty-peg.consumed_qty-peg.released_qty>0) THEN
            RAISE EXCEPTION 'Resolve outstanding material supply commitments before an early final report' USING ERRCODE='23514';
        END IF;
        IF NEW.after_qty<>GREATEST(COALESCE(target.fqty,0),COALESCE((
            SELECT SUM(item.qty) FROM production_daily_report_items item
            JOIN production_daily_reports report ON report.id=item.report_id
            WHERE item.plan_item_id=NEW.plan_item_id AND NOT item.is_deleted AND NOT report.is_deleted
              AND item.fqc_recovery_authorization_id IS NULL
              AND (report.status=1 OR report.id=NEW.report_id)),0)) THEN
            RAISE EXCEPTION 'Final target must retain all physically reported output, including quality failures' USING ERRCODE='23514';
        END IF;
        IF COALESCE(target.capped_qty,0)<>0 OR EXISTS(
            SELECT 1 FROM production_daily_report_target_events cap
            WHERE cap.plan_item_id=NEW.plan_item_id AND cap.event_type='CAP'
              AND NOT EXISTS(SELECT 1 FROM production_daily_report_target_events back WHERE back.source_event_id=cap.id)) THEN
            RAISE EXCEPTION 'Reverse the previous final report before reducing its target again' USING ERRCODE='23514';
        END IF;
    ELSE
        SELECT * INTO source FROM production_daily_report_target_events WHERE id=NEW.source_event_id;
        IF NOT FOUND OR source.event_type<>'CAP' OR source.report_id<>NEW.report_id
           OR source.plan_item_id<>NEW.plan_item_id OR source.after_qty<>NEW.before_qty
           OR source.before_qty<>NEW.after_qty
           OR COALESCE(target.capped_qty,0)<>NEW.after_qty-NEW.before_qty THEN
            RAISE EXCEPTION 'Target restoration must exactly reverse this report own reduction' USING ERRCODE='23514';
        END IF;
    END IF;
    RETURN NEW;
END;
$$;
CREATE TRIGGER trg_guard_daily_report_target_event BEFORE INSERT OR UPDATE OR DELETE
ON production_daily_report_target_events FOR EACH ROW EXECUTE FUNCTION fn_guard_daily_report_target_event();
ALTER TABLE production_daily_report_target_events ENABLE ALWAYS TRIGGER trg_guard_daily_report_target_event;

CREATE FUNCTION fn_is_daily_report_plan_target_change(p_item UUID,p_before NUMERIC,p_after NUMERIC,p_old_cap NUMERIC,p_new_cap NUMERIC)
RETURNS BOOLEAN LANGUAGE sql STABLE AS $$
    SELECT p_before+COALESCE(p_old_cap,0)=p_after+COALESCE(p_new_cap,0)
      AND EXISTS(SELECT 1 FROM production_daily_report_target_events event
          WHERE event.plan_item_id=p_item AND event.before_qty=p_before AND event.after_qty=p_after
            AND event.xmin::text=pg_current_xact_id()::text);
$$;
-- Preserve every original identity guard. The only exception is an exact,
-- transaction-proven final-report target change that preserves qty+capped_qty.
DO $target_identity$
DECLARE definition TEXT; needle TEXT:='OR OLD.qty IS DISTINCT FROM NEW.qty';
BEGIN
    SELECT pg_get_functiondef('fn_guard_material_analysis_plan_item_identity()'::regprocedure) INTO definition;
    IF position(needle IN definition)=0 THEN RAISE EXCEPTION 'Analysis plan-item identity guard changed before V614'; END IF;
    EXECUTE replace(definition,needle,
       'OR (OLD.qty IS DISTINCT FROM NEW.qty AND NOT fn_is_daily_report_plan_target_change(OLD.id,OLD.qty,NEW.qty,OLD.capped_qty,NEW.capped_qty))');
END;
$target_identity$;

CREATE FUNCTION fn_check_daily_report_target_event() RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
    IF NOT EXISTS(SELECT 1 FROM production_daily_reports report
        JOIN production_plan_items item ON item.id=NEW.plan_item_id
        WHERE report.id=NEW.report_id AND report.xmin::text=pg_current_xact_id()::text
          AND report.updated_by=NEW.created_by
          AND report.status=CASE NEW.event_type WHEN 'CAP' THEN 1 ELSE -1 END
          AND item.qty=NEW.after_qty
          AND COALESCE(item.capped_qty,0)=CASE NEW.event_type WHEN 'CAP' THEN NEW.before_qty-NEW.after_qty ELSE 0 END) THEN
        RAISE EXCEPTION 'Final target event and report approval/reversal must commit together' USING ERRCODE='23514';
    END IF;
    RETURN NULL;
END;
$$;
CREATE CONSTRAINT TRIGGER trg_check_daily_report_target_event AFTER INSERT ON production_daily_report_target_events
DEFERRABLE INITIALLY DEFERRED FOR EACH ROW EXECUTE FUNCTION fn_check_daily_report_target_event();
ALTER TABLE production_daily_report_target_events ENABLE ALWAYS TRIGGER trg_check_daily_report_target_event;

CREATE TABLE production_daily_report_material_release_events (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    report_id UUID NOT NULL REFERENCES production_daily_reports(id),
    demand_id UUID NOT NULL REFERENCES production_material_demands(id),
    event_type TEXT NOT NULL CHECK(event_type IN ('RELEASE','RESTORE')),
    qty_base NUMERIC(18,4) NOT NULL CHECK(qty_base>0),
    source_event_id UUID UNIQUE REFERENCES production_daily_report_material_release_events(id),
    created_by UUID NOT NULL REFERENCES users(id),
    created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    UNIQUE(report_id,demand_id,event_type),
    CHECK(event_type='RELEASE' AND source_event_id IS NULL OR event_type='RESTORE' AND source_event_id IS NOT NULL)
);
CREATE INDEX idx_daily_report_material_release_demand ON production_daily_report_material_release_events(demand_id,id);

CREATE FUNCTION fn_guard_daily_report_material_release_event() RETURNS trigger LANGUAGE plpgsql AS $$
DECLARE demand production_material_demands%ROWTYPE; source production_daily_report_material_release_events%ROWTYPE; committed NUMERIC;
BEGIN
    IF TG_OP<>'INSERT' THEN
        RAISE EXCEPTION 'Daily-report material release events are append-only' USING ERRCODE='55000';
    END IF;
    IF NEW.created_by::text IS DISTINCT FROM NULLIF(current_setting('app.actor_id',TRUE),'') THEN
        RAISE EXCEPTION 'Material release event actor must match the transaction audit actor' USING ERRCODE='23514';
    END IF;
    SELECT * INTO demand FROM production_material_demands WHERE id=NEW.demand_id AND NOT is_deleted FOR UPDATE;
    IF NOT FOUND OR NOT EXISTS(
        SELECT 1 FROM production_daily_reports report
        JOIN production_daily_report_items item ON item.report_id=report.id
        JOIN production_execution_segments segment ON segment.id=item.execution_segment_id
        WHERE report.id=NEW.report_id AND NOT report.is_deleted AND NOT item.is_deleted
          AND item.is_final AND item.fqc_recovery_authorization_id IS NULL
          AND segment.id=demand.execution_segment_id AND segment.continuous_supply
          AND report.status=CASE NEW.event_type WHEN 'RELEASE' THEN 0 ELSE 1 END) THEN
        RAISE EXCEPTION 'Material release requires its exact continuous final report' USING ERRCODE='23514';
    END IF;
    IF NEW.event_type='RELEASE' THEN
        committed:=fn_daily_report_open_material_commitment(demand.id);
        IF NEW.qty_base<>demand.required_qty-committed-demand.released_qty THEN
            RAISE EXCEPTION 'Final release must equal only the uncommitted outstanding demand' USING ERRCODE='23514';
        END IF;
    ELSE
        SELECT * INTO source FROM production_daily_report_material_release_events WHERE id=NEW.source_event_id;
        IF NOT FOUND OR source.event_type<>'RELEASE' OR source.report_id<>NEW.report_id
           OR source.demand_id<>NEW.demand_id OR source.qty_base<>NEW.qty_base OR demand.released_qty<NEW.qty_base THEN
            RAISE EXCEPTION 'Material restoration must exactly reverse this report own release' USING ERRCODE='23514';
        END IF;
    END IF;
    RETURN NEW;
END;
$$;
CREATE TRIGGER trg_guard_daily_report_material_release_event BEFORE INSERT OR UPDATE OR DELETE
ON production_daily_report_material_release_events FOR EACH ROW EXECUTE FUNCTION fn_guard_daily_report_material_release_event();
ALTER TABLE production_daily_report_material_release_events ENABLE ALWAYS TRIGGER trg_guard_daily_report_material_release_event;

CREATE FUNCTION fn_apply_daily_report_material_release_event() RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
    UPDATE production_material_demands SET released_qty=released_qty+
        CASE NEW.event_type WHEN 'RELEASE' THEN NEW.qty_base ELSE -NEW.qty_base END,
        lock_version=lock_version+1,updated_at=now() WHERE id=NEW.demand_id;
    RETURN NULL;
END;
$$;
CREATE TRIGGER trg_apply_daily_report_material_release_event AFTER INSERT ON production_daily_report_material_release_events
FOR EACH ROW EXECUTE FUNCTION fn_apply_daily_report_material_release_event();
ALTER TABLE production_daily_report_material_release_events ENABLE ALWAYS TRIGGER trg_apply_daily_report_material_release_event;

CREATE FUNCTION fn_check_daily_report_material_release_event() RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
    IF NOT EXISTS(SELECT 1 FROM production_daily_reports report WHERE report.id=NEW.report_id
        AND report.xmin::text=pg_current_xact_id()::text
        AND report.updated_by=NEW.created_by
        AND report.status=CASE NEW.event_type WHEN 'RELEASE' THEN 1 ELSE -1 END) THEN
        RAISE EXCEPTION 'Material release and report approval/reversal must commit together' USING ERRCODE='23514';
    END IF;
    RETURN NULL;
END;
$$;
CREATE CONSTRAINT TRIGGER trg_check_daily_report_material_release_event AFTER INSERT ON production_daily_report_material_release_events
DEFERRABLE INITIALLY DEFERRED FOR EACH ROW EXECUTE FUNCTION fn_check_daily_report_material_release_event();
ALTER TABLE production_daily_report_material_release_events ENABLE ALWAYS TRIGGER trg_check_daily_report_material_release_event;

CREATE TRIGGER trg_audit_production_daily_report_target_events AFTER INSERT OR UPDATE OR DELETE ON production_daily_report_target_events
FOR EACH ROW EXECUTE FUNCTION fn_audit();
CREATE TRIGGER trg_audit_production_daily_report_material_release_events AFTER INSERT OR UPDATE OR DELETE ON production_daily_report_material_release_events
FOR EACH ROW EXECUTE FUNCTION fn_audit();
ALTER TABLE production_daily_report_target_events ENABLE ALWAYS TRIGGER trg_audit_production_daily_report_target_events;
ALTER TABLE production_daily_report_material_release_events ENABLE ALWAYS TRIGGER trg_audit_production_daily_report_material_release_events;
COMMENT ON TABLE production_daily_report_target_events IS 'Final-report target reductions/restorations. Analysis approval and frozen material basis remain historical facts.';
COMMENT ON TABLE production_daily_report_material_release_events IS 'Exact final-report uncommitted material releases and symmetric restorations; never infer old provenance from current balances.';

DO $reset_policy$
DECLARE definition TEXT; anchor TEXT := '(''stock_movements'', ''CLEAR'')';
BEGIN
    SELECT pg_get_functiondef('business_data_reset()'::regprocedure) INTO definition;
    IF (length(definition)-length(replace(definition,anchor,'')))/length(anchor)<>1
       OR position('(''production_daily_report_target_events'', ''CLEAR'')' IN definition)>0
       OR position('(''production_daily_report_material_release_events'', ''CLEAR'')' IN definition)>0 THEN
        RAISE EXCEPTION 'V614 cannot extend business_data_reset policy safely';
    END IF;
    EXECUTE replace(definition,anchor,
        '(''production_daily_report_target_events'', ''CLEAR''),'
        || '(''production_daily_report_material_release_events'', ''CLEAR''),'
        || anchor);
END;
$reset_policy$;
