-- A workshop self-inspection creates one actual FINISHED_IN per direct report
-- row. A later row in that SAME admitted report transaction can follow either
-- its first physical output or its real CONSUMED posting. Neither is the
-- same-document continuation proved by V1066; keep that proof unchanged.
-- Discover original ownership only. Existing workers still apply every amount,
-- clear pending knowledge, and finish the original durable closure.

-- Admission, replay and the post-inventory-lock proof share this exact graph
-- reader. Its existing body, limits, owner and invoker semantics stay unchanged.
-- Repeated LLVM compilation costs seconds for these bounded UUID walks; scope
-- execution tuning to the common reader and restore the caller's setting on exit.
ALTER FUNCTION fn_inventory_value_precision_scope(uuid[]) SET jit=off;

CREATE FUNCTION fn_inventory_value_continuation_work_applied(p_nodes uuid[])
RETURNS boolean LANGUAGE sql STABLE AS $$
 SELECT NOT EXISTS(SELECT 1 FROM stock_value_tasks task JOIN stock_value_edges edge ON edge.id=task.edge_id
     WHERE task.status='PENDING' AND (edge.parent_node_id=ANY(p_nodes) OR edge.child_node_id=ANY(p_nodes)))
   AND NOT EXISTS(SELECT 1 FROM stock_value_jobs job WHERE job.status<>'APPLIED' AND job.source_node_id=ANY(p_nodes))
   AND NOT EXISTS(SELECT 1 FROM stock_value_production_cost_tasks task WHERE task.status='PENDING'
     AND (task.input_node_id=ANY(p_nodes) OR task.output_source_node_id=ANY(p_nodes)))
   AND NOT EXISTS(SELECT 1 FROM stock_value_production_cost_dirty dirty WHERE dirty.observed_revision>dirty.cleared_revision
     AND dirty.input_node_id=ANY(p_nodes))
$$;

CREATE FUNCTION fn_inventory_value_direct_output_owner(
 p_scope uuid,p_movement uuid,p_txid bigint,p_actor uuid,p_policy jsonb)
RETURNS TABLE(source_node_id uuid,report_id uuid,report_item_id uuid,
 output_batch_id uuid,source_version bigint,approved_at timestamptz)
LANGUAGE plpgsql STABLE ROWS 1 AS $$
BEGIN
 RETURN QUERY
 SELECT output.source_node_id,report.id,report_item.id,report_item.output_batch_id,
        event.source_version,approval.created_at
 FROM stock_value_production_cost_outputs output
 JOIN stock_value_production_cost_objects object USING(execution_segment_id)
 JOIN stock_value_nodes node ON node.id=output.source_node_id
   AND node.pool_id=object.product_pool_id AND node.movement_id=output.movement_id
 JOIN stock_value_events event ON event.movement_id=output.movement_id
   AND event.operation='RECEIVE' AND event.result_node_id=node.id AND node.creation_event_id=event.id
 JOIN stock_movements movement ON movement.id=output.movement_id
 JOIN stock_document_items item ON item.id=event.source_item_id AND item.id=movement.source_item_id
 JOIN stock_documents document ON document.id=item.doc_id
   AND document.id=event.source_doc_id AND document.id=movement.source_doc_id
 JOIN production_daily_report_items report_item ON report_item.id=item.source_daily_report_item_id
 JOIN production_daily_reports report ON report.id=report_item.report_id
   AND report.id=document.source_daily_report_id
 JOIN production_daily_report_commands approval ON approval.report_id=report.id AND approval.command_kind='APPROVE'
 JOIN production_workshop_direct_transfer_items transfer_item ON transfer_item.source_report_item_id=report_item.id
   AND transfer_item.reversal_id IS NULL
 JOIN production_workshop_direct_transfers transfer ON transfer.id=transfer_item.transfer_id
   AND transfer.source_report_id=report.id AND transfer.line_side_warehouse_id=movement.warehouse_id
 JOIN production_fqc_inspections inspection ON inspection.source_report_id=report.id
   AND inspection.source_report_item_id=report_item.id AND inspection.inspection_kind='WORKSHOP_SELF'
 JOIN production_fqc_release_commands release ON release.inspection_id=inspection.id
   AND release.source_report_item_id=report_item.id AND release.stock_document_item_id=item.id
 JOIN production_fqc_release_allocations allocation ON allocation.release_command_id=release.id
   AND allocation.inspection_id=inspection.id AND allocation.qty=release.requested_qty
 JOIN production_fqc_decision_events decision ON decision.id=allocation.decision_event_id
   AND decision.inspection_id=inspection.id AND decision.decision='PASS'
 JOIN production_finished_in_confirmations confirmation ON confirmation.stock_document_id=document.id
 WHERE output.execution_segment_id=p_scope AND output.movement_id=p_movement
   AND output.withdrawn_movement_id IS NULL
   AND event.created_txid=p_txid AND event.value_precision_version=2
   AND event.business_precision_policy=p_policy AND event.actor_user_id=p_actor
   AND event.source_doc_type='STOCK_DOC' AND movement.source_doc_type='STOCK_DOC'
   AND event.source_event_id=movement.id AND event.source_version IS NOT NULL
   AND document.doc_type='FINISHED_IN' AND document.status=1 AND NOT document.is_deleted
   AND item.bill_type='FINISHED_IN' AND NOT item.is_deleted
   AND report.status=1 AND NOT report.is_deleted AND NOT report.is_canceled
   AND NOT report_item.is_deleted AND report_item.destination='WORKSHOP'
   AND report_item.execution_segment_id=p_scope AND item.execution_segment_id=p_scope
   AND inspection.execution_segment_id=p_scope
   AND report_item.output_batch_id IS NOT NULL
   AND report_item.goods_id=movement.goods_id AND report_item.color_id IS NOT DISTINCT FROM movement.color_id
   AND report_item.unit_id=item.unit_id AND report_item.unit_rate=item.unit_rate
   AND item.qty=report_item.qty AND item.qty=movement.qty AND item.qty=release.requested_qty
   AND transfer_item.qty=item.qty AND event.qty_base=output.qty_base
   AND output.qty_base=item.qty*item.unit_rate AND node.quantity_basis=output.qty_base
   AND inspection.status='RESOLVED' AND inspection.passed_qty=inspection.reported_qty
   AND inspection.reported_qty=item.qty AND inspection.failed_qty=0
   AND decision.pass_qty=item.qty AND decision.fail_qty=0
   AND confirmation.decision='ACCEPTED'
   AND movement.created_by=p_actor AND approval.actor_user_id=p_actor AND approval.created_by=p_actor
   AND transfer.created_by=p_actor AND inspection.created_by=p_actor AND release.created_by=p_actor
   AND allocation.created_by=p_actor AND decision.created_by=p_actor AND confirmation.created_by=p_actor
   -- These immutable facts were authored by the same report approval transaction.
   -- V1 has no reviewed version: never reinterpret its NULL as version zero.
   AND approval.approval_protocol_version IN(1,2,3)
   AND (approval.approval_protocol_version=1 OR approval.reviewed_row_version=report.row_version-1)
   AND inspection.created_at=approval.created_at AND decision.decided_at=approval.created_at
   AND release.created_at=approval.created_at AND allocation.created_at=approval.created_at
   AND confirmation.confirmed_at=approval.created_at AND transfer.created_at=approval.created_at
   AND NOT EXISTS(SELECT 1 FROM production_daily_report_commands reversal
     WHERE reversal.report_id=report.id AND reversal.command_kind='REVERSE')
   AND NOT EXISTS(SELECT 1 FROM production_fqc_cancellation_events cancellation WHERE cancellation.inspection_id=inspection.id)
   AND NOT EXISTS(SELECT 1 FROM production_fqc_release_allocations other
     WHERE other.release_command_id=release.id AND other.id<>allocation.id);
END $$;

CREATE FUNCTION fn_inventory_value_direct_report_refresh_continuation(p_scope uuid)
RETURNS uuid LANGUAGE plpgsql STABLE AS $$
DECLARE object stock_value_production_cost_objects%ROWTYPE;
 revision stock_value_production_cost_revisions%ROWTYPE;pending record;nodes uuid[];keys text[];
BEGIN
 -- Gate the one exact durable owner before walking any graph. SQL inlining must
 -- not turn repeated discovery into closure walks for unrelated cost objects.
 SELECT * INTO object FROM stock_value_production_cost_objects WHERE execution_segment_id=p_scope;
 IF NOT FOUND OR object.source_kind<>'PRODUCTION_EXECUTION' OR NOT object.business_refresh_pending
   OR object.business_refresh_precision_root_id IS NOT NULL OR object.state='APPLYING'
   OR NOT object.precision_closure_pending OR object.precision_closure_complete THEN RETURN NULL;END IF;
 SELECT * INTO revision FROM stock_value_production_cost_revisions WHERE id=object.current_revision_id;
 IF NOT FOUND OR revision.execution_segment_id IS DISTINCT FROM p_scope
   OR revision.precision_origin_id IS DISTINCT FROM revision.id
   OR object.precision_origin_id IS DISTINCT FROM revision.id
   OR object.precision_work_txid IS DISTINCT FROM revision.precision_created_txid
   OR object.version IS DISTINCT FROM revision.version OR revision.source_doc_type<>'PRODUCTION_COST_BUSINESS'
   OR revision.source_doc_id IS DISTINCT FROM p_scope OR revision.value_precision_version IS DISTINCT FROM 2
   OR object.business_refresh_precision_version IS DISTINCT FROM 2
   OR revision.request_precision_policy IS DISTINCT FROM object.business_refresh_precision_policy
   OR revision.business_precision_policy IS DISTINCT FROM object.business_refresh_precision_policy
   OR revision.actor_user_id IS DISTINCT FROM object.business_refresh_actor_id
   OR object.precision_forecast_hash IS NULL OR object.precision_forecast_hash!~'^[a-f0-9]{64}$'
   OR NOT fn_inventory_value_root_incomplete(revision.id) THEN RETURN NULL;END IF;
 -- Recorded pending work already disproves readiness. Reject it before the
 -- graph walk so a busy refresh cannot consume the worker's task-apply budget.
 -- Acceptance still requires exact recorded/recomputed closure equality and
 -- the same readiness check over the complete recomputed graph below.
 IF NOT fn_inventory_value_continuation_work_applied(object.precision_closure_nodes) THEN RETURN NULL;END IF;
 SELECT * INTO pending FROM fn_inventory_value_direct_output_owner(p_scope,
   object.business_refresh_event_id,revision.precision_created_txid,revision.actor_user_id,revision.request_precision_policy);
 IF NOT FOUND OR revision.source_version IS DISTINCT FROM pending.source_version THEN RETURN NULL;END IF;
 nodes:=fn_inventory_value_precision_scope(ARRAY(
   SELECT (source->>'node')::uuid FROM jsonb_array_elements(revision.input_snapshot) source
   UNION SELECT (source->>'source')::uuid FROM jsonb_array_elements(revision.output_snapshot) source));
 SELECT array_agg(DISTINCT fn_inventory_value_precision_key(pool.goods_id,pool.color_id)
   ORDER BY fn_inventory_value_precision_key(pool.goods_id,pool.color_id)) INTO keys
 FROM stock_value_nodes node JOIN stock_value_pools pool ON pool.id=node.pool_id WHERE node.id=ANY(nodes);
 IF object.precision_closure_nodes IS DISTINCT FROM nodes
   OR NOT object.precision_closure_nodes @> revision.precision_closure_nodes
   OR NOT pending.source_node_id=ANY(object.precision_closure_nodes)
   OR EXISTS(SELECT 1 FROM jsonb_array_elements(revision.output_snapshot) captured
     WHERE (captured->>'source')::uuid=pending.source_node_id)
   OR object.precision_input_ancestor_nodes IS DISTINCT FROM fn_inventory_value_production_input_ancestors(p_scope)
   OR object.precision_closure_keys IS DISTINCT FROM keys THEN RETURN NULL;END IF;
 IF NOT (
     -- The first direct row of this same report already registered its output.
     EXISTS(SELECT 1 FROM fn_inventory_value_direct_output_owner(p_scope,revision.source_event_id,
       revision.precision_created_txid,revision.actor_user_id,revision.request_precision_policy) original
       WHERE original.report_id=pending.report_id AND original.output_batch_id=pending.output_batch_id
         AND original.source_node_id<>pending.source_node_id
         AND original.source_version=pending.source_version
         AND original.approved_at=pending.approved_at
         AND original.source_node_id=ANY(revision.precision_closure_nodes))
     OR
     -- A subsequent report admitted its actual consumption before its own output.
     EXISTS(SELECT 1 FROM production_material_settlement_events event
       JOIN production_material_settlement_postings posting ON posting.event_id=event.id
       JOIN stock_value_production_cost_inputs input ON input.approved_posting_id=posting.id
         AND input.execution_segment_id=p_scope AND input.input_kind='CONSUMED'
       WHERE event.id=revision.source_event_id AND event.event_type='POST'
         AND event.daily_report_id=pending.report_id AND event.created_by=revision.actor_user_id
         AND event.created_at=pending.approved_at AND posting.id=revision.source_item_id
         AND posting.created_by=revision.actor_user_id AND posting.settlement_type='CONSUMED' AND posting.qty_base>0
         AND EXISTS(SELECT 1 FROM jsonb_array_elements(revision.input_snapshot) captured
           WHERE (captured->>'node')::uuid=input.input_node_id)
         AND EXISTS(SELECT 1 FROM jsonb_array_elements(revision.request_payload->'inputs') captured
           WHERE (captured->>'node')::uuid=input.input_node_id AND (captured->>'posting')::uuid=posting.id
             AND captured->>'kind'='CONSUMED'))
   ) THEN RETURN NULL;END IF;
 IF NOT fn_inventory_value_continuation_work_applied(nodes) THEN RETURN NULL;END IF;
 RETURN revision.id;
END $$;

CREATE FUNCTION fn_inventory_value_business_refresh_continuation(p_scope uuid)
RETURNS uuid LANGUAGE sql STABLE AS $$
 SELECT coalesce(fn_inventory_value_output_refresh_continuation(p_scope),
                 fn_inventory_value_direct_report_refresh_continuation(p_scope))
$$;

-- Keep the V1066 same-document proof byte-for-byte. Only its established routing
-- sites gain the additional exact owner proof, including the post-I-lock trigger.
DO $$
DECLARE signature text;definition text;needle text:='fn_inventory_value_output_refresh_continuation(';
BEGIN
 FOREACH signature IN ARRAY ARRAY['fn_inventory_value_root_next_refresh(uuid)',
   'fn_inventory_value_try_refresh_root(uuid)','fn_inventory_value_capture_business_refresh_precision()'] LOOP
  definition:=pg_get_functiondef(signature::regprocedure);
  IF (length(definition)-length(replace(definition,needle,'')))/length(needle)<>1 THEN
   RAISE EXCEPTION 'Inventory refresh routing no longer matches the reviewed owner-proof shape: %',signature
     USING ERRCODE='23514';
  END IF;
  EXECUTE replace(definition,needle,'fn_inventory_value_business_refresh_continuation(');
 END LOOP;
END $$;
