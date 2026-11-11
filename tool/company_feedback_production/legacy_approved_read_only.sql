-- Read-only triage, never an instruction to reverse or rewrite accepted output.
-- Run with the ordinary authorized production/audit read scope applied by the
-- owning service. A missing proof is uncertainty, not proof that old output is false.
BEGIN READ ONLY;
WITH ordinary_output AS (
 SELECT item.execution_segment_id,
   SUM(item.qty) FILTER (WHERE report.status=1) AS approved_qty,
   SUM(item.qty) FILTER (WHERE report.status=0) AS draft_qty
 FROM production_daily_report_items item
 JOIN production_daily_reports report ON report.id=item.report_id
 WHERE NOT item.is_deleted AND NOT report.is_deleted
  AND item.fqc_recovery_authorization_id IS NULL AND report.status IN(0,1)
 GROUP BY item.execution_segment_id
), inspection AS (
 SELECT segment.id AS execution_segment_id,segment.plan_id,segment.segment_code,
  segment.planned_qty,segment.material_snapshot_product_qty,
  fn_execution_material_output_capacity(segment.id,TRUE) AS current_material_capacity,
  fn_execution_full_kit_checkpoint_valid(segment.id) AS valid_immutable_checkpoint,
  fn_execution_partial_material_report_room(segment.id,NULL) AS ordinary_room,
  COALESCE(output.approved_qty,0) AS approved_qty,COALESCE(output.draft_qty,0) AS draft_qty,
  EXISTS(SELECT 1 FROM production_material_demands demand
    JOIN production_material_stock_postings posting ON posting.demand_id=demand.id
    WHERE demand.execution_segment_id=segment.id AND posting.posting_type='ISSUE'
      AND posting.ledger_order IS NULL) AS has_unordered_legacy_issue,
  EXISTS(SELECT 1 FROM production_daily_report_target_events target_event
    WHERE target_event.plan_item_id=segment.source_plan_item_id) AS has_target_history
 FROM production_execution_segments segment
 LEFT JOIN ordinary_output output ON output.execution_segment_id=segment.id
 WHERE NOT segment.is_deleted AND segment.material_requirement_mode<>'ZERO_MATERIAL'
)
SELECT * FROM inspection
WHERE has_unordered_legacy_issue AND ordinary_room IS NOT NULL
 AND approved_qty>current_material_capacity
ORDER BY segment_code,execution_segment_id;
ROLLBACK;
