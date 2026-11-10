-- A partially issued ordinary work order may only report the output jointly
-- supported by all frozen material demands. Complete issue, zero-material and
-- separately authorized recovery/supplement flows retain their existing rules.
-- NULL means this additional partial-issue ceiling does not apply; never zero.
CREATE FUNCTION fn_execution_partial_material_report_room(p_segment UUID, p_exclude_report UUID DEFAULT NULL)
RETURNS NUMERIC LANGUAGE plpgsql STABLE AS $$
DECLARE segment production_execution_segments%ROWTYPE; capacity NUMERIC; occupied NUMERIC; issued_capacity NUMERIC;
BEGIN
    SELECT * INTO segment FROM production_execution_segments WHERE id=p_segment AND NOT is_deleted;
    IF NOT FOUND THEN RETURN 0; END IF;
    IF segment.material_requirement_mode='ZERO_MATERIAL' THEN RETURN NULL; END IF;
    capacity := COALESCE(fn_execution_material_output_capacity(segment.id, TRUE),0);
    IF capacity >= segment.planned_qty THEN RETURN NULL; END IF;
    -- A genuinely complete issue followed by a surplus return or explicit loss
    -- is not "not yet fully picked". Keep its actual-yield/settlement contract.
    -- issued_qty is the existing ledger's ISSUE minus ISSUE_REVERSE authority;
    -- reversing the issue therefore removes this exemption again.
    SELECT MIN(fn_demand_material_output_capacity(demand.id,clearance.issued_qty)) INTO issued_capacity
    FROM production_material_demands demand
    JOIN v_production_material_clearance clearance ON clearance.demand_id=demand.id
    WHERE demand.execution_segment_id=segment.id AND NOT demand.is_deleted
      AND demand.material_increment_request_id IS NULL AND demand.status NOT IN('RELEASED','REVERSED');
    IF issued_capacity >= segment.planned_qty THEN RETURN NULL; END IF;
    SELECT COALESCE(SUM(item.qty),0) INTO occupied
    FROM production_daily_report_items item
    JOIN production_daily_reports report ON report.id=item.report_id
    WHERE item.execution_segment_id=segment.id
      AND item.fqc_recovery_authorization_id IS NULL
      AND NOT item.is_deleted AND NOT report.is_deleted AND report.status IN (0,1)
      AND (p_exclude_report IS NULL OR report.id<>p_exclude_report);
    RETURN GREATEST(capacity-occupied,0);
END;
$$;

COMMENT ON FUNCTION fn_execution_partial_material_report_room(UUID,UUID) IS
    'Partial-issue report ceiling: frozen net-issue bottleneck less active ordinary output, including drafts and actual surplus; excludes edited report. NULL for effective complete ISSUE history (reversals remove that history).';
