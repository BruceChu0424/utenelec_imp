-- A future consumer with no current admitted cost plan keeps its dirty fact
-- for its first real plan; it cannot self-block this already-admitted root.
-- Match canonical closure readiness. Preserve actual pending work, all owner,
-- actor, policy, version, history and recorded/recomputed closure boundaries.

CREATE OR REPLACE FUNCTION fn_inventory_value_continuation_work_applied(p_nodes uuid[])
RETURNS boolean LANGUAGE sql STABLE AS $$
 SELECT NOT EXISTS(SELECT 1 FROM stock_value_tasks task JOIN stock_value_edges edge ON edge.id=task.edge_id
     WHERE task.status='PENDING' AND (edge.parent_node_id=ANY(p_nodes) OR edge.child_node_id=ANY(p_nodes)))
   AND NOT EXISTS(SELECT 1 FROM stock_value_jobs job WHERE job.status<>'APPLIED' AND job.source_node_id=ANY(p_nodes))
   AND NOT EXISTS(SELECT 1 FROM stock_value_production_cost_tasks task WHERE task.status='PENDING'
     AND (task.input_node_id=ANY(p_nodes) OR task.output_source_node_id=ANY(p_nodes)))
   AND NOT EXISTS(SELECT 1 FROM stock_value_production_cost_dirty dirty
     JOIN stock_value_production_cost_objects object USING(execution_segment_id)
     WHERE object.current_revision_id IS NOT NULL AND dirty.observed_revision>dirty.cleared_revision
       AND dirty.input_node_id=ANY(p_nodes))
$$;


-- Reuse the same readiness in the V1066 same-document family. Splice only its
-- known final queue block from the actual catalog: copying the SQL body through
-- a different checkout would alter CRLF/LF bytes in its unchanged owner proof.
DO $migration$
DECLARE definition text;body text;remaining text;new_body text;queue_start integer;
 expected text := $expected$   AND NOT EXISTS(SELECT 1 FROM stock_value_tasks task JOIN stock_value_edges edge ON edge.id=task.edge_id
     WHERE task.status='PENDING' AND (edge.parent_node_id=ANY(closure.nodes) OR edge.child_node_id=ANY(closure.nodes)))
   AND NOT EXISTS(SELECT 1 FROM stock_value_jobs job WHERE job.status<>'APPLIED' AND job.source_node_id=ANY(closure.nodes))
   AND NOT EXISTS(SELECT 1 FROM stock_value_production_cost_tasks task WHERE task.status='PENDING'
     AND (task.input_node_id=ANY(closure.nodes) OR task.output_source_node_id=ANY(closure.nodes)))
   AND NOT EXISTS(SELECT 1 FROM stock_value_production_cost_dirty dirty WHERE dirty.observed_revision>dirty.cleared_revision
     AND dirty.input_node_id=ANY(closure.nodes))
$expected$;
BEGIN
 SELECT prosrc,pg_get_functiondef(oid) INTO body,definition FROM pg_proc
 WHERE oid='fn_inventory_value_output_refresh_continuation(uuid)'::regprocedure;
 queue_start:=strpos(body,'   AND NOT EXISTS(SELECT 1 FROM stock_value_tasks');
 IF queue_start=0 THEN RAISE EXCEPTION 'Original output continuation queue boundary is missing';END IF;
 remaining:=substring(body FROM queue_start);
 IF regexp_replace(remaining,'[[:space:]]+','','g') IS DISTINCT FROM
    regexp_replace(expected,'[[:space:]]+','','g') THEN
  RAISE EXCEPTION 'Original output continuation queue proof differs; reviewed forward adoption required';END IF;
 IF length(definition)-length(replace(definition,body,''))<>length(body) THEN
  RAISE EXCEPTION 'Original output continuation body is not unique';END IF;
 new_body:=left(body,queue_start-1)||'   AND fn_inventory_value_continuation_work_applied(closure.nodes)'||chr(10);
 EXECUTE replace(definition,body,new_body);
END
$migration$;
