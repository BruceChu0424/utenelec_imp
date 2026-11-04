-- This projection does not change price, knowledge state or any original GL.
-- It proves only a complete inverse of actually linked cost postings.
DO $contract$
BEGIN
 IF to_regprocedure('fn_inventory_value_revaluation_contract_version()') IS NULL
    OR to_regprocedure('fn_inventory_value_producer_withdrawal_proof(uuid)') IS NULL THEN
  RAISE EXCEPTION 'exact cost storno requires the actual whole-target restore contract';END IF;
 IF fn_inventory_value_revaluation_contract_version()<>1 THEN RAISE EXCEPTION 'Review changed whole-target restore contract';END IF;
END $contract$;
-- A later, proven withdrawal in the same real root may advance this node's
-- head. Only the core's actual continuous restore-chain proof authorizes it.
-- Earlier installed contracts keep the previous conservative single-head gate.
CREATE FUNCTION fn_inventory_cost_storno_head_proven(p_node uuid,p_revision bigint,p_event uuid,p_after jsonb)
RETURNS boolean LANGUAGE plpgsql STABLE AS $$
DECLARE node stock_value_nodes%ROWTYPE;event stock_value_events%ROWTYPE;proven boolean;
BEGIN
 SELECT * INTO node FROM stock_value_nodes WHERE id=p_node;
 SELECT * INTO event FROM stock_value_events WHERE id=p_event;
 IF node.id IS NULL OR event.id IS NULL OR p_after IS NULL THEN RETURN false;END IF;
 IF event.operation='COST_ALLOCATE' AND to_regprocedure('fn_inventory_value_withdrawal_node_chain_proven(uuid,bigint,uuid)') IS NOT NULL THEN
  IF event.valuation_root_id IS NULL THEN RETURN false;END IF;
  EXECUTE 'SELECT fn_inventory_value_withdrawal_node_chain_proven($1,$2,$3)'
    INTO proven USING p_node,p_revision,event.valuation_root_id;
  RETURN coalesce(proven,false);
 END IF;
 RETURN node.revision=p_revision AND node.owned_value_local=(p_after->>'ownedValue')::numeric;
END $$;
CREATE FUNCTION fn_inventory_cost_storno_knowledge_bridge_proven(p_original uuid,p_inverse uuid)
RETURNS boolean LANGUAGE plpgsql STABLE AS $$
DECLARE proven boolean;
BEGIN
 IF to_regprocedure('fn_inventory_value_restore_knowledge_bridge_proven(uuid,uuid)') IS NULL THEN RETURN false;END IF;
 EXECUTE 'SELECT fn_inventory_value_restore_knowledge_bridge_proven($1,$2)' INTO proven USING p_original,p_inverse;
 RETURN coalesce(proven,false);
END $$;
-- Bound the owning proof by the actual posting or requested period before
-- traversing producer history. The existing UNIQUE(value_event_id) supplies
-- the producer lookup; no duplicate financial index or second proof is added.
CREATE FUNCTION fn_inventory_cost_exact_storno_candidates(p_period text,p_posting uuid)
RETURNS TABLE(posting_id uuid,source_period text,target_period text,business_date date,event_id uuid,node_id uuid,amount_local numeric,original_voucher_ids uuid[])
LANGUAGE sql STABLE AS $proof$
WITH scope_events AS MATERIALIZED (
 SELECT DISTINCT cost.event_id FROM v_inventory_cost_gl_status cost
 WHERE cost.amount_local<0 AND (p_period IS NULL OR cost.target_period=p_period)
   AND (p_posting IS NULL OR cost.posting_id=p_posting)
), roots AS MATERIALIZED (
  SELECT inverse.id,ARRAY[original.id] original_events
  FROM stock_value_events inverse JOIN stock_value_events original
    ON original.id=inverse.reversal_of_event_id AND original.id=inverse.projection_restore_of_event_id
  JOIN stock_value_jobs inverse_job ON inverse_job.event_id=inverse.id
  JOIN stock_value_jobs original_job ON original_job.event_id=original.id
  JOIN scope_events scope ON scope.event_id=inverse.id
  WHERE inverse.operation='COST_ADJUST_REVERSE' AND original.operation='COST_ADJUST'
    AND original.request_payload->>'inputKind'='TOTAL_CONFIRMATION'
    AND original.before_source_final=false AND original.after_source_final=true
    AND inverse.before_source_final=true AND inverse.after_source_final=false
    AND inverse.valuation_root_kind='EVENT' AND inverse.valuation_root_id=inverse.id
    AND original.valuation_root_kind='EVENT' AND original.valuation_root_id=original.id
    AND cardinality(inverse_job.precision_closure_nodes)>0 AND cardinality(original_job.precision_closure_nodes)>0
    AND fn_inventory_value_revaluation_work_complete(inverse.id)
    AND fn_inventory_value_revaluation_work_complete(original.id)
  UNION ALL
  SELECT inverse.id,ARRAY(SELECT value::uuid FROM jsonb_array_elements_text(proof.value->'originalValueEventIds') member(value))
  FROM stock_value_production_cost_tasks producer
  JOIN stock_value_events inverse ON inverse.id=producer.value_event_id AND inverse.operation='COST_ALLOCATE'
  JOIN scope_events scope ON scope.event_id=inverse.id
  CROSS JOIN LATERAL (SELECT fn_inventory_value_producer_withdrawal_proof(producer.id) value OFFSET 0) proof
  WHERE proof.value->>'version'='1' AND proof.value->>'kind'='SHARE_WITHDRAWAL'
    AND proof.value->>'restoresOriginalPoint'='true' AND (proof.value->>'afterShare')::numeric=0
    AND proof.value->>'inverseValueEventId'=inverse.id::text
    AND inverse.projection_restore_of_event_id=(proof.value->'originalValueEventIds'->>0)::uuid
    AND jsonb_array_length(proof.value->'originalValueEventIds')>0
    AND fn_inventory_value_revaluation_work_complete(inverse.id)
    AND NOT EXISTS(SELECT 1 FROM jsonb_array_elements_text(proof.value->'originalValueEventIds') member(value)
      WHERE NOT fn_inventory_value_revaluation_work_complete(member.value::uuid))
), slices AS MATERIALIZED (
  SELECT roots.id inverse_event,posting.node_id,posting.owner_id,posting.id posting_id,posting.amount_delta_local,
    original_task.id task_id,original_task.edge_id,original_task.before_allocated_amount_local,original_task.target_amount_local,
    original_task.before_pending_contribution,original_task.target_pending,
    original_revision.revision,original_revision.before_projection,original_revision.after_projection,
    original_revision.before_pending,original_revision.after_pending,original_revision.before_value,original_revision.after_value,
    original_link.voucher_id,
    lag(original_revision.after_projection) OVER(PARTITION BY roots.id,posting.node_id,posting.owner_id ORDER BY original_revision.revision) previous_projection,
    lag(original_revision.after_pending) OVER(PARTITION BY roots.id,posting.node_id,posting.owner_id ORDER BY original_revision.revision) previous_pending,
    lag(original_revision.after_value) OVER(PARTITION BY roots.id,posting.node_id,posting.owner_id ORDER BY original_revision.revision) previous_value,
    (original_link.posting_id IS NOT NULL AND original_link.source_event_id=posting.event_id
      AND original_link.source_node_id=posting.node_id AND original_link.amount_local=posting.amount_delta_local
      AND original_voucher.source='AUTO' AND original_voucher.source_type='ACTUAL_COGS'
      AND original_voucher.source_doc_id=posting.id AND original_voucher.status=1 AND NOT original_voucher.is_deleted
      AND original_revision.before_projection IS NOT NULL AND original_revision.after_projection IS NOT NULL
      AND (SELECT count(*) FROM gl_entries entry WHERE entry.voucher_id=original_voucher.id)=2
      AND (SELECT count(DISTINCT entry.direction) FROM gl_entries entry WHERE entry.voucher_id=original_voucher.id)=2
      AND NOT EXISTS(SELECT 1 FROM gl_entries entry WHERE entry.voucher_id=original_voucher.id
        AND (entry.is_deleted OR entry.direction NOT IN(-1,1) OR entry.amount<>original_link.amount_local OR entry.period<>original_voucher.period
          OR entry.entry_date<>original_voucher.voucher_date OR entry.source_doc_type IS DISTINCT FROM 'ACTUAL_COGS' OR entry.source_doc_id IS DISTINCT FROM posting.id))) proved
  FROM roots JOIN stock_value_postings posting ON posting.event_id=ANY(roots.original_events) AND posting.owner_kind='COGS'
  JOIN stock_value_tasks original_task ON original_task.id=posting.task_id AND original_task.event_id=posting.event_id AND original_task.status='APPLIED'
  LEFT JOIN inventory_cost_gl_links original_link ON original_link.posting_id=posting.id
  LEFT JOIN gl_vouchers original_voucher ON original_voucher.id=original_link.voucher_id
  LEFT JOIN stock_value_node_revisions original_revision ON original_revision.node_id=posting.node_id
    AND original_revision.task_id=original_task.id AND original_revision.event_id=posting.event_id AND original_revision.revision=original_task.applied_child_revision
), histories AS MATERIALIZED (
  SELECT inverse_event,node_id,owner_id,sum(amount_delta_local) amount_local,array_agg(voucher_id ORDER BY revision) original_voucher_ids,
    (array_agg(task_id ORDER BY revision))[1] first_task,
    (array_agg(task_id ORDER BY revision DESC))[1] last_task,
    (array_agg(edge_id ORDER BY revision))[1] first_edge,
    (array_agg(before_allocated_amount_local ORDER BY revision))[1] first_allocated,
    (array_agg(target_amount_local ORDER BY revision DESC))[1] last_allocated,
    (array_agg(before_pending_contribution ORDER BY revision))[1] first_task_pending,
    (array_agg(target_pending ORDER BY revision DESC))[1] last_task_pending,
    (array_agg(before_projection ORDER BY revision))[1] first_projection,
    (array_agg(after_projection ORDER BY revision DESC))[1] last_projection,
    (array_agg(before_pending ORDER BY revision))[1] first_pending,
    (array_agg(after_pending ORDER BY revision DESC))[1] last_pending,
    (array_agg(before_value ORDER BY revision))[1] first_value,
    (array_agg(after_value ORDER BY revision DESC))[1] last_value
  FROM slices GROUP BY inverse_event,node_id,owner_id
  HAVING bool_and(coalesce(proved,false)) AND count(DISTINCT edge_id)=1
    AND bool_and(previous_projection IS NULL OR (previous_projection=before_projection AND previous_pending=before_pending AND previous_value=before_value))
), eligible AS MATERIALIZED (
  SELECT cost.*,history.original_voucher_ids
  FROM v_inventory_cost_gl_status cost JOIN histories history ON history.inverse_event=cost.event_id AND history.node_id=cost.node_id
  JOIN stock_value_postings posting ON posting.id=cost.posting_id AND posting.owner_kind='COGS' AND posting.owner_id=history.owner_id
  JOIN stock_value_tasks inverse_task ON inverse_task.id=posting.task_id AND inverse_task.event_id=cost.event_id AND inverse_task.status='APPLIED'
  JOIN stock_value_node_revisions inverse_revision ON inverse_revision.node_id=posting.node_id
    AND inverse_revision.task_id=inverse_task.id AND inverse_revision.event_id=cost.event_id AND inverse_revision.revision=inverse_task.applied_child_revision
  JOIN stock_value_nodes node ON node.id=posting.node_id
  CROSS JOIN inventory_cost_gl_policy policy
  LEFT JOIN inventory_cost_gl_period_choices choice ON choice.posting_id=posting.id
  WHERE cost.posting_status IN('READY','COST_PENDING','POSTED') AND cost.amount_local<0
    AND cost.shipment_item_id IS NOT NULL AND cost.shipment_id IS NOT NULL
    AND history.amount_local>0 AND cost.amount_local=-history.amount_local
    AND inverse_task.restores_task_id=history.first_task AND inverse_task.edge_id=history.first_edge
    AND inverse_task.before_allocated_amount_local=history.last_allocated AND inverse_task.target_amount_local=history.first_allocated
    AND inverse_task.target_pending=history.first_task_pending
    AND ((inverse_task.before_pending_contribution=history.last_task_pending AND inverse_revision.before_pending=history.last_pending)
      OR fn_inventory_cost_storno_knowledge_bridge_proven(history.last_task,inverse_task.id))
    AND inverse_revision.before_projection=history.last_projection AND inverse_revision.after_projection=history.first_projection
    AND inverse_revision.after_pending=history.first_pending
    AND inverse_revision.before_value=history.last_value AND inverse_revision.after_value=history.first_value
    AND fn_inventory_cost_storno_head_proven(node.id,inverse_revision.revision,cost.event_id,inverse_revision.after_projection)
    AND (inverse_revision.before_projection->>'ownedValue')::numeric-(inverse_revision.after_projection->>'ownedValue')::numeric=history.amount_local
    AND policy.enabled AND policy.effective_from IS NOT NULL
    AND NOT(cost.business_date<policy.effective_from AND (cost.created_at AT TIME ZONE 'Asia/Shanghai')::date<policy.effective_from)
    AND (choice.posting_id IS NOT NULL OR (cost.business_date>=policy.effective_from
      AND (cost.created_at AT TIME ZONE 'Asia/Shanghai')::date<(date_trunc('month',cost.business_date)::date+interval '1 month')))
    AND cost.target_period>=cost.source_period
    AND NOT EXISTS(SELECT 1 FROM gl_vouchers legacy WHERE legacy.source='AUTO' AND legacy.source_type='COST_CARRY'
      AND legacy.source_doc_id=cost.shipment_id AND legacy.status=1 AND NOT legacy.is_deleted)
)
SELECT eligible.posting_id,eligible.source_period,eligible.target_period,eligible.business_date,eligible.event_id,eligible.node_id,eligible.amount_local,eligible.original_voucher_ids FROM eligible;
$proof$;
CREATE FUNCTION fn_inventory_cost_exact_storno_legs(p_vouchers uuid[])
RETURNS TABLE(style_id uuid,direction integer,amount numeric,line_no integer) LANGUAGE sql STABLE AS $$
 SELECT original.style_id,original.direction::integer,-sum(original.amount),
  row_number() OVER(ORDER BY original.direction DESC,original.style_id)::integer
 FROM gl_entries original WHERE original.voucher_id=ANY(p_vouchers)
 GROUP BY original.style_id,original.direction HAVING sum(original.amount)<>0
$$;
CREATE VIEW v_inventory_cost_exact_storno_candidates AS
 SELECT * FROM fn_inventory_cost_exact_storno_candidates(NULL,NULL);
CREATE VIEW v_inventory_cost_exact_storno_legs AS
 SELECT cost.posting_id,leg.* FROM v_inventory_cost_exact_storno_candidates cost
 CROSS JOIN LATERAL fn_inventory_cost_exact_storno_legs(cost.original_voucher_ids) leg;

CREATE FUNCTION fn_inventory_cost_exact_storno_valid(p_posting uuid,p_voucher uuid,p_target text) RETURNS boolean LANGUAGE sql STABLE AS $$
 WITH candidate AS MATERIALIZED (SELECT * FROM fn_inventory_cost_exact_storno_candidates(p_target,p_posting)),
 expected AS MATERIALIZED (SELECT cost.posting_id,leg.* FROM candidate cost CROSS JOIN LATERAL fn_inventory_cost_exact_storno_legs(cost.original_voucher_ids) leg)
 SELECT EXISTS(
  SELECT 1 FROM candidate cost JOIN gl_vouchers voucher ON voucher.id=p_voucher
  WHERE cost.posting_id=p_posting AND cost.target_period=p_target AND cost.amount_local<0
   AND voucher.source='AUTO' AND voucher.source_type='ACTUAL_COGS' AND voucher.source_doc_id=cost.posting_id
   AND voucher.period=cost.target_period AND voucher.status=1 AND NOT voucher.is_deleted
   AND voucher.voucher_date=CASE WHEN cost.source_period=p_target THEN cost.business_date ELSE to_date(p_target||'-01','YYYY-MM-DD') END
   AND (SELECT count(*) FROM gl_entries entry WHERE entry.voucher_id=voucher.id)=
       (SELECT count(*) FROM expected leg WHERE leg.posting_id=cost.posting_id)
   AND (SELECT count(*) FROM expected leg WHERE leg.posting_id=cost.posting_id)>=2
   AND NOT EXISTS(SELECT 1 FROM expected leg
     LEFT JOIN gl_entries reversed ON reversed.voucher_id=voucher.id AND reversed.line_no=leg.line_no
     WHERE leg.posting_id=cost.posting_id AND (reversed.id IS NULL OR reversed.is_deleted OR reversed.style_id<>leg.style_id
       OR reversed.direction<>leg.direction OR reversed.amount<>leg.amount OR reversed.period<>voucher.period
       OR reversed.entry_date<>voucher.voucher_date OR reversed.source_doc_type IS DISTINCT FROM 'ACTUAL_COGS' OR reversed.source_doc_id IS DISTINCT FROM cost.posting_id))
   AND (SELECT sum(entry.direction*entry.amount) FROM gl_entries entry WHERE entry.voucher_id=voucher.id)=0
   AND (SELECT sum(entry.amount) FROM gl_entries entry WHERE entry.voucher_id=voucher.id AND entry.direction=1)=cost.amount_local
   AND (SELECT sum(entry.amount) FROM gl_entries entry WHERE entry.voucher_id=voucher.id AND entry.direction=-1)=cost.amount_local
 )
$$;

-- The legacy normal-posting source/style/period guard stays authoritative.
-- A pending negative inverse has one narrowly proven alternative; it never
-- marks its source final and does not authorize an unrelated positive cost.
DO $strict_cost_storno_guard$
DECLARE definition text;needle text;replacement text;
BEGIN
 SELECT replace(pg_get_functiondef('fn_guard_inventory_cost_gl_link()'::regprocedure),E'\r','') INTO definition;
 needle:='DECLARE cost RECORD; debit NUMERIC;credit NUMERIC;voucher RECORD;';
 replacement:=needle||E'\n proven_storno boolean;';
 IF position(needle IN definition)=0 THEN RAISE EXCEPTION 'Review changed actual-cost GL guard declarations';END IF;
 definition:=replace(definition,needle,replacement);
 needle:='SELECT * INTO voucher FROM gl_vouchers WHERE id=NEW.voucher_id;';
 IF position(needle IN definition)=0 THEN RAISE EXCEPTION 'Review changed actual-cost GL voucher identity guard';END IF;
 definition:=replace(definition,needle,needle||E'\n    proven_storno:=fn_inventory_cost_exact_storno_valid(NEW.posting_id,NEW.voucher_id,NEW.target_period);');
 needle:='cost.posting_id IS NULL OR cost.pending OR';
 IF position(needle IN definition)=0 THEN RAISE EXCEPTION 'Review changed actual-cost GL pending guard';END IF;
 definition:=replace(definition,needle,'cost.posting_id IS NULL OR (cost.pending AND NOT proven_storno) OR');
 needle:='IF debit IS DISTINCT FROM NEW.amount_local OR credit IS DISTINCT FROM NEW.amount_local';
 IF position(needle IN definition)=0 THEN RAISE EXCEPTION 'Review changed actual-cost GL leg guard';END IF;
 definition:=replace(definition,needle,'IF NOT proven_storno AND (debit IS DISTINCT FROM NEW.amount_local OR credit IS DISTINCT FROM NEW.amount_local');
 needle:='''INVENTORY_ASSET'' END)) THEN';
 IF position(needle IN definition)=0 THEN RAISE EXCEPTION 'Review changed actual-cost GL original role guard';END IF;
 definition:=replace(definition,needle,'''INVENTORY_ASSET'' END))) THEN');
 EXECUTE definition;
END $strict_cost_storno_guard$;
