-- A partially issued ordinary work order may only report the output jointly
-- supported by all frozen material demands. Complete issue, zero-material and
-- separately authorized recovery/supplement flows retain their existing rules.
-- NULL means this additional partial-issue ceiling does not apply; never zero.
-- The existing event timestamp is transaction-start time, so it cannot prove
-- order after a lock wait. Postings are inserted only after their demand locks.
-- Keep historical rows NULL; assigning them a sequence would invent history.
CREATE SEQUENCE production_material_stock_posting_order_seq;
ALTER TABLE production_material_stock_postings ADD COLUMN ledger_order BIGINT;
ALTER SEQUENCE production_material_stock_posting_order_seq OWNED BY production_material_stock_postings.ledger_order;
ALTER TABLE production_material_stock_postings ALTER COLUMN ledger_order
    SET DEFAULT nextval('production_material_stock_posting_order_seq');
CREATE UNIQUE INDEX uq_material_stock_posting_ledger_order
    ON production_material_stock_postings(ledger_order) WHERE ledger_order IS NOT NULL;

-- Only existing INSERT grantees need nextval; do not grant setval/UPDATE.
DO $sequence_permissions$
DECLARE permission RECORD; role_sql TEXT;
BEGIN
    FOR permission IN SELECT DISTINCT acl.grantee FROM pg_class relation
        CROSS JOIN LATERAL aclexplode(COALESCE(relation.relacl,acldefault('s',relation.relowner))) acl
        WHERE relation.oid='production_material_stock_posting_order_seq'::regclass AND acl.grantee<>relation.relowner
    LOOP
        role_sql:=CASE WHEN permission.grantee=0 THEN 'PUBLIC' ELSE quote_ident(pg_get_userbyid(permission.grantee)) END;
        EXECUTE 'REVOKE ALL ON SEQUENCE production_material_stock_posting_order_seq FROM '||role_sql;
    END LOOP;
    FOR permission IN SELECT DISTINCT acl.grantee FROM pg_class relation
        CROSS JOIN LATERAL aclexplode(COALESCE(relation.relacl,acldefault('r',relation.relowner))) acl
        WHERE relation.oid='production_material_stock_postings'::regclass AND acl.privilege_type='INSERT'
    LOOP
        role_sql:=CASE WHEN permission.grantee=0 THEN 'PUBLIC' ELSE quote_ident(pg_get_userbyid(permission.grantee)) END;
        EXECUTE 'GRANT USAGE ON SEQUENCE production_material_stock_posting_order_seq TO '||role_sql;
    END LOOP;
END;
$sequence_permissions$;

CREATE FUNCTION fn_execution_partial_material_report_room(p_segment UUID, p_exclude_report UUID DEFAULT NULL)
RETURNS NUMERIC LANGUAGE plpgsql STABLE AS $$
DECLARE segment production_execution_segments%ROWTYPE; capacity NUMERIC; occupied NUMERIC; fully_issued BOOLEAN;
BEGIN
    SELECT * INTO segment FROM production_execution_segments WHERE id=p_segment AND NOT is_deleted;
    IF NOT FOUND THEN RETURN 0; END IF;
    IF segment.material_requirement_mode='ZERO_MATERIAL' THEN RETURN NULL; END IF;
    capacity := COALESCE(fn_execution_material_output_capacity(segment.id, TRUE),0);
    IF capacity >= segment.planned_qty THEN RETURN NULL; END IF;
    -- Preserve genuine full issue followed by return/loss, without letting
    -- issue 5 -> return 5 -> issue 5 masquerade as a ten-piece full kit.
    -- Reversals retire the original event's credit retrospectively. Consumption
    -- remains supporting cumulative output; returns remove that physical supply.
    WITH demands AS MATERIALIZED (
        SELECT id,required_qty FROM production_material_demands
        WHERE execution_segment_id=segment.id AND NOT is_deleted
          AND material_increment_request_id IS NULL AND status NOT IN('RELEASED','REVERSED')
    ), originals AS MATERIALIZED (
        SELECT posting.demand_id,posting.event_id,posting.ledger_order,posting.posting_type,
               posting.qty_base-COALESCE((SELECT SUM(reversed.qty_base)
                 FROM production_material_stock_postings reversed WHERE reversed.source_posting_id=posting.id
                   AND reversed.posting_type=CASE posting.posting_type WHEN 'ISSUE' THEN 'ISSUE_REVERSE' ELSE 'GOOD_RETURN_REVERSE' END),0) AS qty
        FROM production_material_stock_postings posting JOIN demands ON demands.id=posting.demand_id
        WHERE posting.posting_type IN('ISSUE','GOOD_RETURN')
    ), event_order AS MATERIALIZED (
        SELECT event_id,CASE WHEN bool_and(ledger_order IS NOT NULL) THEN MAX(ledger_order) END AS ordinal
        FROM originals GROUP BY event_id
    ), historical_single_kit AS (
        -- A single real issue delivering every complete demand is independently
        -- provable even when its historical order is unknown.
        SELECT original.event_id FROM originals original JOIN demands ON demands.id=original.demand_id
        WHERE original.posting_type='ISSUE'
        GROUP BY original.event_id
        HAVING COUNT(DISTINCT original.demand_id)=(SELECT COUNT(*) FROM demands)
          AND bool_and((SELECT COALESCE(SUM(other.qty),0) FROM originals other
                WHERE other.event_id=original.event_id AND other.demand_id=original.demand_id AND other.posting_type='ISSUE')>=demands.required_qty)
    ), changes AS (
        -- Unknown history contributes only its current net baseline, never a
        -- guessed peak. Future ordinals come from the locked owning ledger.
        SELECT demands.id AS demand_id,0::bigint AS ordinal,
               COALESCE(SUM(CASE original.posting_type WHEN 'ISSUE' THEN original.qty ELSE -original.qty END)
                   FILTER(WHERE ordered.ordinal IS NULL),0) AS delta
        FROM demands LEFT JOIN originals original ON original.demand_id=demands.id
        LEFT JOIN event_order ordered ON ordered.event_id=original.event_id GROUP BY demands.id
        UNION ALL
        SELECT original.demand_id,ordered.ordinal,
               SUM(CASE original.posting_type WHEN 'ISSUE' THEN original.qty ELSE -original.qty END)
        FROM originals original JOIN event_order ordered ON ordered.event_id=original.event_id
        WHERE ordered.ordinal IS NOT NULL GROUP BY original.demand_id,ordered.ordinal
    ), balances AS (
        SELECT changes.*,SUM(delta) OVER(PARTITION BY demand_id ORDER BY ordinal) AS supported
        FROM changes
    ), transitions AS (
        SELECT ordinal,(supported>=demands.required_qty)::integer-
               COALESCE(LAG((supported>=demands.required_qty)::integer) OVER(PARTITION BY demand_id ORDER BY ordinal),0) AS change
        FROM balances JOIN demands ON demands.id=balances.demand_id
    ), readiness AS (
        SELECT SUM(SUM(change)) OVER(ORDER BY ordinal) AS ready_count FROM transitions GROUP BY ordinal
    )
    SELECT (SELECT COUNT(*) FROM demands)>0 AND
           (EXISTS(SELECT 1 FROM historical_single_kit) OR
            EXISTS(SELECT 1 FROM readiness WHERE ready_count=(SELECT COUNT(*) FROM demands))) INTO fully_issued;
    IF fully_issued THEN RETURN NULL; END IF;
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
    'Partial-issue report ceiling: frozen net bottleneck less active output, excludes edited report. Full-issue exemption requires an ordered effective ledger prefix or a complete single ISSUE; reversals retire credit, return/reissue cycles cannot inflate it.';
