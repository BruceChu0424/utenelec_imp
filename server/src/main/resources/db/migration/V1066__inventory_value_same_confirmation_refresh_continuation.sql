-- A multi-line finished-in confirmation can register a second real output while
-- its first cost plan is APPLYING. The queued output refresh is a continuation
-- of that admitted physical confirmation, not a new source-cost decision.
-- Preserve all original events, revisions, policies, amounts and task states.

CREATE FUNCTION fn_inventory_value_output_refresh_continuation(p_scope uuid)
RETURNS uuid LANGUAGE sql STABLE AS $$
 SELECT object.precision_origin_id
 FROM stock_value_production_cost_objects object
 JOIN stock_value_production_cost_revisions revision ON revision.id=object.current_revision_id
   AND revision.execution_segment_id=object.execution_segment_id
 JOIN stock_value_production_cost_revisions root ON root.id=revision.precision_origin_id
 JOIN stock_value_production_cost_outputs original_output ON original_output.execution_segment_id=object.execution_segment_id
   AND original_output.movement_id=revision.source_event_id
 JOIN stock_value_events original_event ON original_event.movement_id=original_output.movement_id
   AND original_event.operation='RECEIVE' AND original_event.result_node_id=original_output.source_node_id
 JOIN stock_value_production_cost_outputs pending_output ON pending_output.execution_segment_id=object.execution_segment_id
   AND pending_output.movement_id=object.business_refresh_event_id
 JOIN stock_value_events pending_event ON pending_event.movement_id=pending_output.movement_id
   AND pending_event.operation='RECEIVE' AND pending_event.result_node_id=pending_output.source_node_id
 JOIN stock_documents document ON document.id=original_event.source_doc_id
   AND document.id=pending_event.source_doc_id
 JOIN production_finished_in_confirmations confirmation ON confirmation.stock_document_id=document.id
 CROSS JOIN LATERAL (SELECT fn_inventory_value_root_nodes(root.id) nodes) closure
 WHERE object.execution_segment_id=p_scope AND object.source_kind='PRODUCTION_EXECUTION'
   AND object.business_refresh_pending AND object.business_refresh_precision_root_id IS NULL
   AND object.state<>'APPLYING' AND object.precision_closure_pending AND NOT object.precision_closure_complete
   AND object.precision_origin_id=revision.precision_origin_id
   AND object.precision_work_txid=revision.precision_created_txid
   AND object.version=revision.version AND revision.source_doc_type='PRODUCTION_COST_BUSINESS'
   AND revision.source_doc_id=object.execution_segment_id
   AND revision.value_precision_version=2 AND root.value_precision_version=2
   AND object.business_refresh_precision_version=2
   AND revision.request_precision_policy=object.business_refresh_precision_policy
   AND root.request_precision_policy=object.business_refresh_precision_policy
   AND revision.actor_user_id=object.business_refresh_actor_id
   AND root.actor_user_id=object.business_refresh_actor_id
   AND original_event.actor_user_id=object.business_refresh_actor_id
   AND pending_event.actor_user_id=object.business_refresh_actor_id
   AND confirmation.created_by=object.business_refresh_actor_id
   AND confirmation.decision IN('ACCEPTED','PARTIAL')
   AND document.doc_type='FINISHED_IN' AND document.status=1 AND NOT document.is_deleted
   AND original_event.source_doc_type='STOCK_DOC' AND pending_event.source_doc_type='STOCK_DOC'
   AND original_event.source_version=pending_event.source_version
   AND original_event.source_version IS NOT NULL
   AND original_output.source_node_id<>pending_output.source_node_id
   AND original_output.source_node_id=ANY(revision.precision_closure_nodes)
   AND object.precision_closure_nodes @> ARRAY[original_output.source_node_id,pending_output.source_node_id]
   AND closure.nodes @> object.precision_closure_nodes
   AND object.precision_closure_keys IS NOT NULL AND object.precision_forecast_hash~'^[a-f0-9]{64}$'
   AND fn_inventory_value_root_incomplete(root.id)
   AND NOT EXISTS(SELECT 1 FROM stock_value_tasks task JOIN stock_value_edges edge ON edge.id=task.edge_id
     WHERE task.status='PENDING' AND (edge.parent_node_id=ANY(closure.nodes) OR edge.child_node_id=ANY(closure.nodes)))
   AND NOT EXISTS(SELECT 1 FROM stock_value_jobs job WHERE job.status<>'APPLIED' AND job.source_node_id=ANY(closure.nodes))
   AND NOT EXISTS(SELECT 1 FROM stock_value_production_cost_tasks task WHERE task.status='PENDING'
     AND (task.input_node_id=ANY(closure.nodes) OR task.output_source_node_id=ANY(closure.nodes)))
   AND NOT EXISTS(SELECT 1 FROM stock_value_production_cost_dirty dirty WHERE dirty.observed_revision>dirty.cleared_revision
     AND dirty.input_node_id=ANY(closure.nodes))
$$;

-- Discovery remains read-only and takes no business row lock before inventory.
CREATE OR REPLACE FUNCTION fn_inventory_value_root_next_refresh(p_root uuid) RETURNS uuid LANGUAGE sql STABLE AS $$
 WITH candidates AS (
  SELECT dirty.execution_segment_id FROM stock_value_production_cost_dirty dirty
  JOIN stock_value_events event ON event.id=dirty.source_event_id JOIN stock_value_production_cost_objects object USING(execution_segment_id)
  WHERE dirty.observed_revision>dirty.cleared_revision AND object.state<>'APPLYING' AND NOT object.business_refresh_pending
   AND coalesce(event.valuation_root_id,event.id)=p_root
  UNION SELECT execution_segment_id FROM stock_value_production_cost_objects
   WHERE business_refresh_pending AND state<>'APPLYING'
     AND (business_refresh_precision_root_id=p_root
       OR (business_refresh_precision_root_id IS NULL AND fn_inventory_value_output_refresh_continuation(execution_segment_id)=p_root))
 )
 SELECT execution_segment_id FROM candidates WHERE fn_inventory_value_production_inputs_ready(execution_segment_id)
  AND NOT EXISTS(SELECT 1 FROM stock_value_tasks stock JOIN stock_value_events source ON source.id=stock.event_id
   WHERE stock.status='PENDING' AND coalesce(source.valuation_root_id,source.id)=p_root)
 ORDER BY execution_segment_id LIMIT 1
$$;

CREATE OR REPLACE FUNCTION fn_inventory_value_try_refresh_root(p_scope uuid) RETURNS boolean LANGUAGE plpgsql VOLATILE AS $$
DECLARE v_root uuid;v_keys text[];v_next uuid;v_constraint text;
BEGIN
 SELECT business_refresh_precision_root_id INTO v_root FROM stock_value_production_cost_objects WHERE execution_segment_id=p_scope AND business_refresh_pending;
 IF FOUND AND v_root IS NULL THEN
  v_root:=fn_inventory_value_output_refresh_continuation(p_scope);
  IF v_root IS NULL THEN RETURN true;END IF;
 END IF;
 IF v_root IS NULL THEN
 SELECT coalesce(event.valuation_root_id,event.id) INTO v_root FROM stock_value_production_cost_dirty dirty
 JOIN stock_value_events event ON event.id=dirty.source_event_id
 WHERE dirty.execution_segment_id=p_scope AND dirty.observed_revision>dirty.cleared_revision
 ORDER BY dirty.observed_revision DESC,dirty.input_node_id LIMIT 1;
 END IF;
 IF v_root IS NULL THEN RETURN true;END IF;
 v_keys:=fn_inventory_value_root_keys(v_root);
 IF v_keys IS NULL THEN RETURN true;END IF;
 v_next:=fn_inventory_value_root_next_refresh(v_root);
 IF v_next IS DISTINCT FROM p_scope THEN RETURN false;END IF;
 BEGIN
  PERFORM fn_inventory_value_try_precision_claim(v_keys[1]);
 EXCEPTION WHEN serialization_failure THEN
  GET STACKED DIAGNOSTICS v_constraint=CONSTRAINT_NAME;
  IF v_constraint='stock_value_precision_scope_busy' THEN RETURN false;END IF;
  RAISE;
 END;
 RETURN fn_inventory_value_root_next_refresh(v_root)=p_scope;
END $$;

-- The existing domain refresh updates this row only after inventory locks and
-- footprint revalidation. Re-prove the exact continuation here before binding.
CREATE OR REPLACE FUNCTION fn_inventory_value_capture_business_refresh_precision() RETURNS trigger LANGUAGE plpgsql VOLATILE AS $$
DECLARE v_resuming boolean;v_continuation uuid;
BEGIN
 IF TG_OP='UPDATE' AND NEW.business_refresh_pending
  AND (NOT OLD.business_refresh_pending OR NEW.business_refresh_event_id IS DISTINCT FROM OLD.business_refresh_event_id
       OR NEW.business_refresh_actor_id IS DISTINCT FROM OLD.business_refresh_actor_id) THEN
  v_resuming:=current_setting('app.inventory_value_business_refresh_root',true)=coalesce(OLD.business_refresh_precision_root_id,OLD.execution_segment_id)::text
    AND current_setting('app.inventory_value_legacy_refresh',true)=OLD.business_refresh_precision_version::text
    AND NEW.business_refresh_event_id IS NOT DISTINCT FROM OLD.business_refresh_event_id;
  IF ((OLD.precision_closure_pending AND fn_inventory_value_root_incomplete(OLD.precision_origin_id)) OR (OLD.state='APPLYING' AND OLD.precision_origin_id IS NULL))
    AND OLD.precision_work_txid IS DISTINCT FROM txid_current() AND NOT coalesce(v_resuming,false) THEN
   RAISE EXCEPTION '原生产成本仍在处理，请保留本次原输入稍后重试；本次未确认' USING ERRCODE='40001',CONSTRAINT='stock_value_precision_scope_busy';END IF;
 END IF;
 IF NEW.business_refresh_pending AND (TG_OP='INSERT' OR NOT OLD.business_refresh_pending OR NEW.business_refresh_event_id IS DISTINCT FROM OLD.business_refresh_event_id) THEN
  NEW.business_refresh_precision_version:=2;NEW.business_refresh_precision_policy:=fn_business_precision_snapshot();NEW.business_refresh_precision_root_id:=NULL;
 ELSIF TG_OP='UPDATE' AND (NEW.business_refresh_precision_version IS DISTINCT FROM OLD.business_refresh_precision_version
   OR NEW.business_refresh_precision_policy IS DISTINCT FROM OLD.business_refresh_precision_policy) THEN
  RAISE EXCEPTION 'Original business refresh precision is immutable' USING ERRCODE='55000';
 END IF;
 IF TG_OP='UPDATE' AND NEW.business_refresh_pending AND OLD.business_refresh_pending
   AND OLD.business_refresh_precision_root_id IS NULL AND NEW.business_refresh_precision_root_id IS NULL
   AND NEW.business_refresh_event_id IS NOT DISTINCT FROM OLD.business_refresh_event_id
   AND NEW.business_refresh_actor_id IS NOT DISTINCT FROM OLD.business_refresh_actor_id
   AND NEW.current_revision_id IS NOT DISTINCT FROM OLD.current_revision_id AND NEW.version=OLD.version AND NEW.state=OLD.state
   AND NEW.precision_origin_id IS NOT DISTINCT FROM OLD.precision_origin_id
   AND NEW.precision_closure_nodes IS NOT DISTINCT FROM OLD.precision_closure_nodes
   AND NEW.precision_closure_keys IS NOT DISTINCT FROM OLD.precision_closure_keys
   AND NEW.precision_forecast_hash IS NOT DISTINCT FROM OLD.precision_forecast_hash
   AND NEW.precision_work_txid IS NOT DISTINCT FROM OLD.precision_work_txid
   AND NEW.precision_closure_pending=OLD.precision_closure_pending AND NEW.precision_closure_complete=OLD.precision_closure_complete
   AND current_setting('app.inventory_value_business_refresh_root',true)=OLD.execution_segment_id::text
   AND current_setting('app.inventory_value_legacy_refresh',true)=OLD.business_refresh_precision_version::text
   AND fn_business_precision_snapshot()=OLD.business_refresh_precision_policy THEN
  v_continuation:=fn_inventory_value_output_refresh_continuation(OLD.execution_segment_id);
  IF v_continuation IS NOT NULL THEN
   NEW.business_refresh_precision_root_id:=v_continuation;
   PERFORM set_config('app.inventory_value_business_refresh_root',v_continuation::text,true);
  END IF;
 END IF;
 IF TG_OP='UPDATE' AND NEW.business_refresh_precision_root_id IS DISTINCT FROM OLD.business_refresh_precision_root_id
   AND NOT (OLD.business_refresh_precision_root_id IS NULL AND pg_trigger_depth()>1)
   AND NOT (v_continuation IS NOT NULL AND NEW.business_refresh_precision_root_id=v_continuation) THEN
  IF NEW.business_refresh_pending AND (NOT OLD.business_refresh_pending OR NEW.business_refresh_event_id IS DISTINCT FROM OLD.business_refresh_event_id) THEN NULL;
  ELSE RAISE EXCEPTION 'Business refresh work root requires its actual original request' USING ERRCODE='55000';END IF;
 END IF;
 RETURN NEW;
END $$;
