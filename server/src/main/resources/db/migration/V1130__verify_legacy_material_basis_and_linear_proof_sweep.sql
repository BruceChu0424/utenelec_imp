-- Forward-only correction of V1129; no historical facts or accepted output are mutated.

CREATE INDEX idx_material_full_kit_proof_source
 ON production_material_full_kit_proofs(execution_segment_id,source_stock_order,rules_version,planned_qty);

-- Sweep reversal intervals once per demand. A reversal removes credit only
-- from proofs after its original ISSUE and before that reversal. Later ISSUEs
-- never retire earlier proofs. All positions were assigned under existing owner
-- locks; historical NULL positions are not reconstructed or backfilled.
CREATE OR REPLACE FUNCTION fn_execution_full_kit_checkpoint_valid(p_segment UUID,p_stock_order BIGINT DEFAULT NULL)
RETURNS BOOLEAN LANGUAGE plpgsql STABLE AS $$
BEGIN
 -- Capture normally observes a new stock prefix. Avoid planning or sweeping
 -- all old reversals when that prefix has no candidate checkpoint at all.
 IF NOT EXISTS(SELECT 1 FROM production_material_full_kit_proofs proof
   JOIN production_execution_segments segment ON segment.id=proof.execution_segment_id AND NOT segment.is_deleted
   WHERE proof.execution_segment_id=p_segment AND proof.rules_version=1 AND proof.planned_qty=segment.planned_qty
    AND (p_stock_order IS NULL OR proof.source_stock_order=p_stock_order)) THEN RETURN FALSE; END IF;
 RETURN (
 WITH current_demands AS MATERIALIZED (
  SELECT demand.id,fn_material_full_kit_identity(demand.id) AS identity_snapshot
  FROM production_material_demands demand WHERE demand.execution_segment_id=p_segment AND NOT demand.is_deleted
   AND demand.material_increment_request_id IS NULL AND demand.status NOT IN('RELEASED','REVERSED')
 ), candidate_proofs AS MATERIALIZED (
  SELECT proof.id,proof.ledger_order,proof.planned_qty
  FROM production_material_full_kit_proofs proof
  JOIN production_execution_segments segment ON segment.id=proof.execution_segment_id AND NOT segment.is_deleted
  WHERE proof.execution_segment_id=p_segment AND proof.rules_version=1 AND proof.planned_qty=segment.planned_qty
   AND (p_stock_order IS NULL OR proof.source_stock_order=p_stock_order)
   AND (SELECT COUNT(*) FROM current_demands)>0
   AND (SELECT COUNT(*) FROM production_material_full_kit_proof_items item WHERE item.proof_id=proof.id)
       =(SELECT COUNT(*) FROM current_demands)
 ), reversal_intervals AS MATERIALIZED (
  SELECT reversed.demand_id,COALESCE(original.ledger_order,0) AS issue_order,
    reversed.ledger_order AS reverse_order,reversed.qty_base
  FROM current_demands demand
  JOIN production_material_stock_postings reversed ON reversed.demand_id=demand.id
   AND reversed.posting_type='ISSUE_REVERSE' AND reversed.ledger_order IS NOT NULL
  JOIN production_material_stock_postings original ON original.id=reversed.source_posting_id
   AND original.posting_type='ISSUE'
 ), timeline AS (
  SELECT item.demand_id,proof.ledger_order,item.proof_id,item.supported_qty,
     proof.planned_qty,item.identity_snapshot,demand.identity_snapshot AS current_identity,0::numeric AS delta
  FROM candidate_proofs proof JOIN production_material_full_kit_proof_items item ON item.proof_id=proof.id
  JOIN current_demands demand ON demand.id=item.demand_id
  UNION ALL
  SELECT demand_id,issue_order,NULL::uuid,NULL::numeric,NULL::numeric,NULL::jsonb,NULL::jsonb,qty_base FROM reversal_intervals
  UNION ALL
  SELECT demand_id,reverse_order,NULL::uuid,NULL::numeric,NULL::numeric,NULL::jsonb,NULL::jsonb,-qty_base FROM reversal_intervals
 ), credits AS MATERIALIZED (
  SELECT *,SUM(delta) OVER(PARTITION BY demand_id ORDER BY ledger_order ROWS UNBOUNDED PRECEDING) AS revoked_qty
  FROM timeline
 )
 SELECT EXISTS(SELECT 1 FROM credits WHERE proof_id IS NOT NULL GROUP BY proof_id
  HAVING COUNT(*)=(SELECT COUNT(*) FROM current_demands)
   AND bool_and(identity_snapshot IS NOT DISTINCT FROM current_identity
      AND fn_demand_material_output_capacity(demand_id,GREATEST(supported_qty-revoked_qty,0))>=planned_qty)));
END;
$$;

CREATE OR REPLACE FUNCTION fn_execution_partial_material_report_room(p_segment UUID,p_exclude_report UUID DEFAULT NULL)
RETURNS NUMERIC LANGUAGE plpgsql STABLE AS $$
DECLARE segment production_execution_segments%ROWTYPE; capacity NUMERIC; occupied NUMERIC; single_kit BOOLEAN;
BEGIN
 SELECT * INTO segment FROM production_execution_segments WHERE id=p_segment AND NOT is_deleted;
 IF NOT FOUND THEN RETURN 0; END IF;
 IF segment.material_requirement_mode='ZERO_MATERIAL' THEN RETURN NULL; END IF;
 capacity:=COALESCE(fn_execution_material_output_capacity(segment.id,TRUE),0);
 IF capacity>=segment.planned_qty OR fn_execution_full_kit_checkpoint_valid(p_segment) THEN RETURN NULL; END IF;
 -- A legacy ISSUE has no trustworthy ledger position. Its one atomic event
 -- can prove a complete kit only against the immutable pre-execution material
 -- basis, never today's planned_qty (CAP may legitimately have reduced it).
 -- The snapshot basis/identity/curve are protected by the original owner guards.
 -- A changed target, missing curve or unmatched original goods/color/unit is
 -- insufficient evidence and keeps the current verifiable ceiling.
 WITH demands AS MATERIALIZED (
  SELECT demand.id,demand.goods_id,demand.color_id,demand.unit_id,CASE
    WHEN COALESCE((to_jsonb(segment)->>'material_snapshot_product_qty')::numeric,0)<=0 THEN NULL
    WHEN demand.consumption_snapshot IS NOT NULL THEN
      LEAST(demand.required_qty,fn_material_snapshot_required(demand.consumption_snapshot,
        (to_jsonb(segment)->>'material_snapshot_product_qty')::numeric))
    WHEN demand.requirement_mode='EXACT_SNAPSHOT'
      AND (to_jsonb(demand)->>'required_for_product_qty')::numeric
        =(to_jsonb(segment)->>'material_snapshot_product_qty')::numeric
      AND to_jsonb(demand)->>'requirement_fingerprint' ~ '^[0-9a-f]{64}$'
      THEN demand.required_qty
    ELSE NULL END AS full_threshold
  FROM production_material_demands demand WHERE demand.execution_segment_id=p_segment AND NOT demand.is_deleted
    AND demand.material_increment_request_id IS NULL AND demand.status NOT IN('RELEASED','REVERSED')
    -- Unknown legacy chronology is never reconstructed from timestamps. The
    -- untouched target has one verifiable frozen basis. Any CAP/restore history
    -- (including a round trip to the same quantity) requires a real checkpoint.
    AND (to_jsonb(segment)->>'source_plan_item_id') IS NOT NULL
    AND (to_jsonb(segment)->>'material_snapshot_product_qty')::numeric=segment.planned_qty
    AND NOT EXISTS(SELECT 1 FROM production_daily_report_target_events target_event
      WHERE target_event.plan_item_id=(to_jsonb(segment)->>'source_plan_item_id')::uuid)
 ), legacy_reversals AS MATERIALIZED (
  SELECT reversed.source_posting_id,SUM(reversed.qty_base) AS qty
  FROM production_material_stock_postings reversed JOIN demands ON demands.id=reversed.demand_id
  WHERE reversed.posting_type='ISSUE_REVERSE' GROUP BY reversed.source_posting_id
 ), legacy_issue AS MATERIALIZED (
  SELECT original.event_id,original.demand_id,SUM(original.qty_base-COALESCE(reversed.qty,0)) AS qty
  FROM production_material_stock_postings original JOIN demands ON demands.id=original.demand_id
  JOIN stock_document_items source_item ON source_item.id=original.stock_document_item_id
   AND source_item.goods_id=demands.goods_id
   AND source_item.color_id IS NOT DISTINCT FROM demands.color_id
   AND source_item.unit_id IS NOT DISTINCT FROM demands.unit_id
  LEFT JOIN legacy_reversals reversed ON reversed.source_posting_id=original.id
  WHERE original.posting_type='ISSUE' AND original.ledger_order IS NULL GROUP BY original.event_id,original.demand_id
 )
 SELECT EXISTS(SELECT 1 FROM legacy_issue issue JOIN demands ON demands.id=issue.demand_id
  GROUP BY issue.event_id HAVING COUNT(*)=(SELECT COUNT(*) FROM demands)
   AND bool_and(COALESCE(issue.qty>=demands.full_threshold,FALSE))) INTO single_kit;
 IF single_kit THEN RETURN NULL; END IF;
 SELECT COALESCE(SUM(item.qty),0) INTO occupied FROM production_daily_report_items item
 JOIN production_daily_reports report ON report.id=item.report_id
 WHERE item.execution_segment_id=p_segment AND item.fqc_recovery_authorization_id IS NULL
  AND NOT item.is_deleted AND NOT report.is_deleted AND report.status IN(0,1)
  AND (p_exclude_report IS NULL OR report.id<>p_exclude_report);
 RETURN GREATEST(capacity-occupied,0);
END;
$$;
COMMENT ON FUNCTION fn_execution_partial_material_report_room(UUID,UUID) IS
 'Current verifiable frozen material capacity less active ordinary output; full-kit exemption needs an immutable owner checkpoint or a single legacy ISSUE proven against the immutable pre-execution material basis. NULL is no extra ceiling; missing historical proof remains conservative.';

