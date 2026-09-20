-- Freeze the actual consumption curve, not an average derived from the full lot.
-- Existing EXACT_SNAPSHOT rows without a curve remain valid: partial capacity is
-- deliberately unavailable until their complete frozen demand has been issued.
ALTER TABLE production_material_demands ADD COLUMN consumption_snapshot JSONB;

CREATE INDEX idx_material_stock_posting_demand_capacity
ON production_material_stock_postings(demand_id,posting_type) INCLUDE(id,qty_base);

-- Point lookups by demand avoid aggregating the entire issue history for each
-- task on a paginated workbench. Consumed material still supports cumulative output.
CREATE FUNCTION fn_execution_material_net_issued_qty(p_demand UUID)
RETURNS NUMERIC LANGUAGE sql STABLE AS $$
    SELECT COALESCE((SELECT SUM(CASE posting_type
               WHEN 'ISSUE' THEN qty_base WHEN 'ISSUE_REVERSE' THEN -qty_base
               WHEN 'GOOD_RETURN' THEN -qty_base WHEN 'GOOD_RETURN_REVERSE' THEN qty_base ELSE 0 END)
        FROM production_material_stock_postings WHERE demand_id=p_demand),0)
      - COALESCE((SELECT SUM(CASE event.event_type WHEN 'POST' THEN posting.qty_base ELSE -posting.qty_base END)
        FROM production_material_settlement_postings posting
        JOIN production_material_settlement_events event ON event.id=posting.event_id
        WHERE posting.demand_id=p_demand AND posting.settlement_type IN ('APPROVED_LOSS','LEGAL_WIP')),0)
      - COALESCE((SELECT SUM(fn_material_issue_pending_return(issue.id,NULL))
        FROM production_material_stock_postings issue WHERE issue.demand_id=p_demand AND issue.posting_type='ISSUE'),0);
$$;

CREATE FUNCTION fn_material_snapshot_required(p_snapshot JSONB, p_output NUMERIC)
RETURNS NUMERIC LANGUAGE plpgsql IMMUTABLE AS $$
DECLARE rule JSONB; amount NUMERIC; output NUMERIC; total NUMERIC := 0;
BEGIN
    IF p_snapshot IS NULL OR jsonb_typeof(p_snapshot->'rules') IS DISTINCT FROM 'array' THEN
        RAISE EXCEPTION 'Invalid frozen material consumption rules' USING ERRCODE='23514';
    END IF;
    IF jsonb_array_length(p_snapshot->'rules') = 0
       OR COALESCE((p_snapshot->>'productUnitRate')::numeric, 0) <= 0 THEN
        RAISE EXCEPTION 'Invalid frozen material consumption rules' USING ERRCODE='23514';
    END IF;
    output := GREATEST(p_output, 0) * (p_snapshot->>'productUnitRate')::numeric;
    FOR rule IN SELECT * FROM jsonb_array_elements(p_snapshot->'rules') LOOP
        IF COALESCE((rule->>'bomQty')::numeric,0) <= 0
           OR COALESCE((rule->>'basisOutputQty')::numeric,0) <= 0 THEN
            RAISE EXCEPTION 'Invalid frozen material consumption quantities' USING ERRCODE='23514';
        END IF;
        CASE rule->>'consumptionBasis'
            WHEN 'PER_UNIT' THEN amount := output * (rule->>'bomQty')::numeric;
            WHEN 'PER_PACKAGE' THEN
                IF COALESCE((rule->>'allowPartialPackage')::boolean,FALSE) THEN
                    amount := ceil(output * (rule->>'bomQty')::numeric
                                   / (rule->>'basisOutputQty')::numeric * 1000000000000) / 1000000000000;
                ELSE amount := ceil(output / (rule->>'basisOutputQty')::numeric) * (rule->>'bomQty')::numeric;
                END IF;
            WHEN 'FIXED_BATCH' THEN
                amount := ceil(output / (rule->>'basisOutputQty')::numeric) * (rule->>'bomQty')::numeric;
            ELSE RAISE EXCEPTION 'Unsupported frozen material consumption basis' USING ERRCODE='23514';
        END CASE;
        total := total + ceil(amount * 10000) / 10000;
    END LOOP;
    RETURN total;
END;
$$;

CREATE FUNCTION fn_guard_execution_consumption_snapshot() RETURNS trigger LANGUAGE plpgsql AS $$
DECLARE segment production_execution_segments%ROWTYPE; expected NUMERIC;
BEGIN
    IF TG_OP='UPDATE' AND OLD.consumption_snapshot IS NOT NULL
       AND NEW.consumption_snapshot IS DISTINCT FROM OLD.consumption_snapshot THEN
        RAISE EXCEPTION 'Frozen material consumption rules are immutable' USING ERRCODE='23514';
    END IF;
    IF NEW.consumption_snapshot IS NULL OR
       (TG_OP='UPDATE' AND NEW.consumption_snapshot IS NOT DISTINCT FROM OLD.consumption_snapshot) THEN RETURN NEW; END IF;
    SELECT * INTO segment FROM production_execution_segments WHERE id=NEW.execution_segment_id;
    IF NOT FOUND OR segment.source_segment_id IS NOT NULL THEN
        RAISE EXCEPTION 'Consumption curve requires an original execution segment' USING ERRCODE='23514';
    END IF;
    IF EXISTS(SELECT 1 FROM stock_reservations WHERE demand_id=NEW.id)
       OR EXISTS(SELECT 1 FROM production_daily_report_items WHERE execution_segment_id=segment.id) THEN
        RAISE EXCEPTION 'Cannot add material rules after execution has begun' USING ERRCODE='23514';
    END IF;
    expected := fn_material_snapshot_required(NEW.consumption_snapshot,
                    COALESCE(segment.material_snapshot_product_qty,segment.planned_qty));
    IF expected <> NEW.required_qty THEN
        RAISE EXCEPTION 'Frozen consumption curve does not match material demand' USING ERRCODE='23514';
    END IF;
    RETURN NEW;
END;
$$;
CREATE TRIGGER trg_execution_consumption_snapshot BEFORE INSERT OR UPDATE ON production_material_demands
    FOR EACH ROW EXECUTE FUNCTION fn_guard_execution_consumption_snapshot();
ALTER TABLE production_material_demands ENABLE ALWAYS TRIGGER trg_execution_consumption_snapshot;

CREATE FUNCTION fn_demand_material_output_capacity(p_demand UUID, p_available NUMERIC)
RETURNS NUMERIC LANGUAGE plpgsql STABLE AS $$
DECLARE demand production_material_demands%ROWTYPE; segment production_execution_segments%ROWTYPE;
        low NUMERIC := 0; high NUMERIC; middle NUMERIC; required NUMERIC;
BEGIN
    SELECT * INTO demand FROM production_material_demands WHERE id=p_demand AND NOT is_deleted;
    IF NOT FOUND THEN RETURN 0; END IF;
    SELECT * INTO segment FROM production_execution_segments WHERE id=demand.execution_segment_id AND NOT is_deleted;
    IF NOT FOUND THEN RETURN 0; END IF;
    IF p_available IS NULL THEN RETURN 0; END IF;
    IF p_available < 0 THEN RAISE EXCEPTION 'Negative net material capacity' USING ERRCODE='23514'; END IF;
    IF p_available >= demand.required_qty THEN RETURN segment.planned_qty; END IF;
    IF demand.consumption_snapshot IS NULL THEN
        IF demand.requirement_mode='LINEAR' AND demand.per_product_qty > 0 THEN
            RETURN LEAST(segment.planned_qty,trunc(p_available/demand.per_product_qty,4));
        END IF;
        -- Old nonlinear / split requirements cannot be reconstructed from today's BOM.
        RETURN 0;
    END IF;
    high := trunc(segment.planned_qty*10000);
    WHILE low < high LOOP
        middle := floor((low+high+1)/2);
        required := fn_material_snapshot_required(demand.consumption_snapshot,middle/10000);
        IF required <= p_available THEN low := middle; ELSE high := middle-1; END IF;
    END LOOP;
    RETURN low/10000;
END;
$$;

CREATE FUNCTION fn_execution_material_output_capacity(p_segment UUID, p_issued_only BOOLEAN DEFAULT TRUE)
RETURNS NUMERIC LANGUAGE sql STABLE AS $$
    SELECT CASE WHEN segment.material_requirement_mode='ZERO_MATERIAL' THEN segment.planned_qty
                WHEN fn_split_batch_empty_issued(segment.id) THEN segment.planned_qty
                ELSE COALESCE((
                    SELECT MIN(fn_demand_material_output_capacity(demand.id,
                        CASE WHEN p_issued_only THEN
                            fn_execution_material_net_issued_qty(demand.id)
                        ELSE COALESCE((SELECT SUM(reservation.qty-reservation.released_qty)
                            FROM stock_reservations reservation
                            WHERE reservation.demand_id=demand.id AND NOT reservation.is_deleted),0)
                        END))
                    FROM production_material_demands demand
                    WHERE demand.execution_segment_id=segment.id AND NOT demand.is_deleted
                      AND demand.status NOT IN ('RELEASED','REVERSED')
                ),0) END
    FROM production_execution_segments segment WHERE segment.id=p_segment AND NOT segment.is_deleted;
$$;

COMMENT ON COLUMN production_material_demands.consumption_snapshot IS
    'Immutable execution consumption curve. NULL historical nonlinear demand requires full frozen quantity; never infer from mutable current BOM.';
