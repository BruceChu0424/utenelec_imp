-- Existing history is retained with NULL provenance. New facts require an exact ISSUE.
ALTER TABLE production_material_settlement_postings ADD COLUMN issue_posting_id UUID
    REFERENCES production_material_stock_postings(id) ON DELETE RESTRICT;
CREATE INDEX idx_material_settlement_issue ON production_material_settlement_postings(issue_posting_id)
    WHERE issue_posting_id IS NOT NULL;

-- A later physical output must not be rejected merely because an older cost task is applying.
ALTER TABLE stock_value_production_cost_objects
    ADD COLUMN business_refresh_event_id UUID,
    ADD COLUMN business_refresh_actor_id UUID REFERENCES users(id),
    ADD COLUMN business_refresh_pending BOOLEAN NOT NULL DEFAULT FALSE;
CREATE INDEX idx_cost_object_business_refresh ON stock_value_production_cost_objects(execution_segment_id)
    WHERE business_refresh_pending;
DO $refresh_projection$
DECLARE definition TEXT;needle TEXT:='ARRAY[''version'',''current_revision_id'',''state'']';
BEGIN
    SELECT pg_get_functiondef('fn_guard_stock_value_cost_projection()'::regprocedure) INTO definition;
    IF position(needle IN definition)=0 THEN RAISE EXCEPTION 'cost object projection guard changed before V521'; END IF;
    EXECUTE replace(definition,needle,
        'ARRAY[''version'',''current_revision_id'',''state'',''business_refresh_event_id'',''business_refresh_actor_id'',''business_refresh_pending'']');
END;
$refresh_projection$;
CREATE FUNCTION fn_guard_cost_business_refresh_source() RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
    IF NEW.business_refresh_event_id IS NULL AND NEW.business_refresh_actor_id IS NULL AND NOT NEW.business_refresh_pending THEN RETURN NEW; END IF;
    IF NEW.business_refresh_event_id IS NULL OR NEW.business_refresh_actor_id IS NULL OR NOT (
        EXISTS(SELECT 1 FROM stock_value_production_cost_outputs output
            JOIN stock_value_events event ON event.movement_id=output.movement_id
            WHERE output.execution_segment_id=NEW.execution_segment_id AND output.movement_id=NEW.business_refresh_event_id
                AND event.actor_user_id=NEW.business_refresh_actor_id)
        OR EXISTS(SELECT 1 FROM production_material_settlement_events event
            JOIN production_material_settlement_postings posting ON posting.event_id=event.id
            JOIN production_material_demands demand ON demand.id=posting.demand_id
            WHERE event.id=NEW.business_refresh_event_id AND event.created_by=NEW.business_refresh_actor_id
                AND demand.execution_segment_id=NEW.execution_segment_id)) THEN
        RAISE EXCEPTION 'production cost refresh requires the real output or settlement event and original actor' USING ERRCODE='23514';
    END IF;
    RETURN NEW;
END;
$$;
CREATE TRIGGER trg_cost_business_refresh_source BEFORE INSERT OR UPDATE ON stock_value_production_cost_objects
    FOR EACH ROW EXECUTE FUNCTION fn_guard_cost_business_refresh_source();
ALTER TABLE stock_value_production_cost_objects ENABLE ALWAYS TRIGGER trg_cost_business_refresh_source;

CREATE FUNCTION fn_material_issue_unsettled(p_issue UUID) RETURNS NUMERIC LANGUAGE sql STABLE AS $$
    SELECT issue.qty_base
        -COALESCE((SELECT SUM(qty_base) FROM production_material_stock_postings
            WHERE source_posting_id=issue.id AND posting_type IN('ISSUE_REVERSE','GOOD_RETURN')),0)
        +COALESCE((SELECT SUM(reverse.qty_base) FROM production_material_stock_postings returned
            JOIN production_material_stock_postings reverse ON reverse.source_posting_id=returned.id
                AND reverse.posting_type='GOOD_RETURN_REVERSE'
            WHERE returned.source_posting_id=issue.id AND returned.posting_type='GOOD_RETURN'),0)
        -COALESCE((SELECT SUM(CASE WHEN settlement.source_posting_id IS NULL THEN settlement.qty_base ELSE -settlement.qty_base END)
            FROM production_material_settlement_postings settlement WHERE settlement.issue_posting_id=issue.id),0)
    FROM production_material_stock_postings issue WHERE issue.id=p_issue AND issue.posting_type='ISSUE';
$$;

CREATE FUNCTION fn_guard_material_settlement_issue() RETURNS trigger LANGUAGE plpgsql AS $$
DECLARE issue production_material_stock_postings%ROWTYPE;source production_material_settlement_postings%ROWTYPE;
BEGIN
    SELECT * INTO issue FROM production_material_stock_postings WHERE id=NEW.issue_posting_id FOR UPDATE;
    IF issue.id IS NULL OR issue.posting_type<>'ISSUE' OR issue.demand_id<>NEW.demand_id THEN
        RAISE EXCEPTION 'new settlement requires its exact original issue posting' USING ERRCODE='23514';
    END IF;
    IF NEW.source_posting_id IS NOT NULL THEN
        SELECT * INTO source FROM production_material_settlement_postings WHERE id=NEW.source_posting_id;
        IF source.issue_posting_id IS DISTINCT FROM NEW.issue_posting_id THEN
            RAISE EXCEPTION 'settlement reversal must restore the same original issue' USING ERRCODE='23514';
        END IF;
    ELSE
        IF EXISTS(SELECT 1 FROM production_material_settlement_postings historical
            WHERE historical.demand_id=NEW.demand_id AND historical.issue_posting_id IS NULL) THEN
            RAISE EXCEPTION 'legacy settlement issue provenance must be reconciled before new allocations' USING ERRCODE='23514';
        END IF;
        IF NEW.qty_base>fn_material_issue_unsettled(issue.id) THEN
            RAISE EXCEPTION 'settlement exceeds unconsumed quantity of the exact issue' USING ERRCODE='23514';
        END IF;
    END IF;
    RETURN NEW;
END;
$$;
CREATE TRIGGER trg_material_settlement_exact_issue BEFORE INSERT ON production_material_settlement_postings
    FOR EACH ROW EXECUTE FUNCTION fn_guard_material_settlement_issue();
ALTER TABLE production_material_settlement_postings ENABLE ALWAYS TRIGGER trg_material_settlement_exact_issue;

CREATE FUNCTION fn_guard_material_return_unsettled_issue() RETURNS trigger LANGUAGE plpgsql AS $$
DECLARE issue UUID;
BEGIN
    IF NEW.posting_type NOT IN('GOOD_RETURN','ISSUE_REVERSE') THEN RETURN NEW; END IF;
    issue:=NEW.source_posting_id;
    PERFORM 1 FROM production_material_stock_postings WHERE id=issue FOR UPDATE;
    IF NEW.qty_base>fn_material_issue_unsettled(issue) THEN
        RAISE EXCEPTION 'returned material cannot include consumed, lost or assigned WIP of the same issue' USING ERRCODE='23514';
    END IF;
    RETURN NEW;
END;
$$;
CREATE TRIGGER trg_material_return_unsettled_issue BEFORE INSERT ON production_material_stock_postings
    FOR EACH ROW EXECUTE FUNCTION fn_guard_material_return_unsettled_issue();
ALTER TABLE production_material_stock_postings ENABLE ALWAYS TRIGGER trg_material_return_unsettled_issue;
