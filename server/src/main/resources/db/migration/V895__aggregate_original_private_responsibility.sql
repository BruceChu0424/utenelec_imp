-- Child supply retains its recorded original private owners after a parent
-- manufacturing batch is withdrawn. A cancelled parent never becomes active.
-- The immutable CREATE/APPEND intent is provenance, not current supply capacity.
CREATE INDEX idx_preplan_cancelled_action_analysis ON preplan_supply_actions(analysis_id,id) WHERE status='CANCELLED';
CREATE FUNCTION fn_preplan_aggregate_recorded_private_sources_scoped_batches(p_analysis UUID,p_material UUID,p_batches UUID[])
RETURNS TABLE(supply_batch_id UUID,supply_action_id UUID,allocation_id UUID,
    canonical_material_id UUID,original_material_id UUID,original_analysis_item_id UUID,
    recorded_qty NUMERIC,structural_valid BOOLEAN)
LANGUAGE sql STABLE AS $$
    WITH source_scope AS MATERIALIZED (
        SELECT p_material AS id WHERE p_material IS NOT NULL
        UNION SELECT alias.source_material_id FROM preplan_aggregate_material_aliases alias
          WHERE alias.aggregate_material_id=p_material
    ), target_scope AS MATERIALIZED (
        SELECT DISTINCT alias.aggregate_material_id AS id FROM source_scope source
        JOIN preplan_aggregate_material_aliases alias ON alias.source_material_id=source.id
    ), complete AS MATERIALIZED (
        SELECT batch.id,batch.action_id,batch.analysis_id
        FROM preplan_aggregate_batches batch
        JOIN preplan_aggregate_batch_events event ON event.batch_id=batch.id
        WHERE batch.analysis_id=p_analysis AND event.event_type IN('CREATE','APPEND')
          AND (p_batches IS NULL OR batch.id=ANY(p_batches))
          AND (p_material IS NULL OR EXISTS(SELECT 1 FROM preplan_supply_action_allocations allocation
            JOIN target_scope target ON target.id=allocation.analysis_material_id WHERE allocation.action_id=batch.action_id))
        GROUP BY batch.id,batch.action_id,batch.analysis_id
        HAVING bool_and(jsonb_typeof(event.intent_snapshot->'sourcePrivateQtyByTargetMaterialLineId')
            IS NOT DISTINCT FROM 'object' OR event.event_type='APPEND' AND event.allocation_deltas='{}'::jsonb)
    ), recorded AS MATERIALIZED (
        SELECT batch.id,batch.action_id,batch.analysis_id,allocation.id AS allocation_id,allocation.analysis_material_id AS target_id,
            original.key::uuid AS original_id,SUM(original.value::numeric) AS qty
        FROM complete batch
        JOIN preplan_supply_action_allocations allocation ON allocation.action_id=batch.action_id AND allocation.analysis_id=batch.analysis_id
        JOIN preplan_aggregate_batch_events event ON event.batch_id=batch.id
        CROSS JOIN LATERAL jsonb_each_text(event.intent_snapshot->'sourcePrivateQtyByTargetMaterialLineId'->allocation.analysis_material_id::text) original
        WHERE event.event_type IN('CREATE','APPEND')
        GROUP BY batch.id,batch.action_id,batch.analysis_id,allocation.id,allocation.analysis_material_id,original.key
    ), proof AS MATERIALIZED (
        SELECT recorded.*,SUM(recorded.qty) OVER(PARTITION BY recorded.id,recorded.target_id) AS total_qty
        FROM recorded
    )
    SELECT proof.id,proof.action_id,allocation.id,canonical.id,original.id,original.analysis_item_id,proof.qty,
        (proof.total_qty=allocation.allocated_qty AND proof.qty>0
          AND (original.goods_id,original.color_id,original.unit_id)
            IS NOT DISTINCT FROM (canonical.goods_id,canonical.color_id,canonical.unit_id)
          AND (canonical.goods_id,canonical.color_id,canonical.unit_id)
            IS NOT DISTINCT FROM (action.goods_id,action.color_id,action.unit_id)
          AND (original.id=canonical.id OR EXISTS (
            SELECT 1 FROM preplan_aggregate_material_aliases alias
            JOIN preplan_aggregate_batches parent_batch ON parent_batch.id=alias.batch_id
              AND parent_batch.analysis_id=proof.analysis_id
            JOIN production_material_analysis_materials parent ON parent.id=alias.source_parent_material_id
              AND parent.analysis_id=proof.analysis_id
            WHERE alias.source_material_id=original.id AND alias.aggregate_material_id=canonical.id
              AND canonical.analysis_item_id=parent_batch.anchor_analysis_item_id
              AND alias.relative_bom_path=fn_aggregate_relative_bom_path(original.id,parent.id)
              AND alias.relative_bom_path=fn_aggregate_relative_bom_path(canonical.id,NULL))))
    FROM proof
    JOIN preplan_supply_actions action ON action.id=proof.action_id AND action.analysis_id=proof.analysis_id
    JOIN preplan_supply_action_allocations allocation ON allocation.id=proof.allocation_id
    JOIN production_material_analysis_materials canonical ON canonical.id=proof.target_id
      AND canonical.analysis_id=proof.analysis_id
    JOIN production_material_analysis_materials original ON original.id=proof.original_id
      AND original.analysis_id=proof.analysis_id;
$$;

CREATE FUNCTION fn_preplan_aggregate_recorded_private_sources_scoped(p_analysis UUID,p_material UUID,p_batch UUID)
RETURNS TABLE(supply_batch_id UUID,supply_action_id UUID,allocation_id UUID,
    canonical_material_id UUID,original_material_id UUID,original_analysis_item_id UUID,
    recorded_qty NUMERIC,structural_valid BOOLEAN)
LANGUAGE sql STABLE AS $$
    SELECT * FROM fn_preplan_aggregate_recorded_private_sources_scoped_batches(p_analysis,p_material,
        CASE WHEN p_batch IS NULL THEN NULL::uuid[] ELSE ARRAY[p_batch] END);
$$;

CREATE FUNCTION fn_preplan_aggregate_recorded_private_sources_scoped(p_analysis UUID,p_material UUID)
RETURNS TABLE(supply_batch_id UUID,supply_action_id UUID,allocation_id UUID,
    canonical_material_id UUID,original_material_id UUID,original_analysis_item_id UUID,
    recorded_qty NUMERIC,structural_valid BOOLEAN)
LANGUAGE sql STABLE AS $$
    SELECT * FROM fn_preplan_aggregate_recorded_private_sources_scoped(p_analysis,p_material,NULL);
$$;

CREATE FUNCTION fn_preplan_aggregate_recorded_private_sources(p_analysis UUID)
RETURNS TABLE(supply_batch_id UUID,supply_action_id UUID,allocation_id UUID,
    canonical_material_id UUID,original_material_id UUID,original_analysis_item_id UUID,
    recorded_qty NUMERIC,structural_valid BOOLEAN)
LANGUAGE sql STABLE AS $$
    SELECT * FROM fn_preplan_aggregate_recorded_private_sources_scoped(p_analysis,NULL,NULL);
$$;

COMMENT ON FUNCTION fn_preplan_aggregate_recorded_private_sources(UUID) IS
    'Immutable exact original private source proof; recorded_qty is historical intent, never current coverage by itself';

-- Current node demand and live alias responsibility are produced by the
-- authoritative refresh, including real stock, future supply and each frozen
-- non-linear output batch. A retained member changes its descendants, never
-- its own required_qty. Historical source_capacity MAX is not new admission.
CREATE FUNCTION fn_preplan_original_material_capacity(p_material UUID)
RETURNS NUMERIC LANGUAGE plpgsql STABLE AS $$
DECLARE material production_material_analysis_materials%ROWTYPE;
    source production_material_analysis_items%ROWTYPE; edge RECORD;
    conversion NUMERIC; expected_depth INTEGER:=0; last_depth INTEGER;
    parent_expands BOOLEAN:=TRUE;
BEGIN
    SELECT * INTO material FROM production_material_analysis_materials WHERE id=p_material AND active;
    IF NOT FOUND THEN RETURN NULL; END IF;
    SELECT * INTO source FROM production_material_analysis_items WHERE id=material.analysis_item_id
      AND analysis_id=material.analysis_id AND NOT is_deleted AND source_type NOT IN('MAKE_COMPONENT','AGGREGATE_MAKE');
    IF NOT FOUND THEN RETURN NULL; END IF;
    conversion:=1;
    IF source.source_type='SALES_ORDER_ITEM' THEN
      SELECT COALESCE(item.unit_rate,1) INTO conversion FROM sales_order_items item
      JOIN sales_orders header ON header.id=item.order_id AND header.status=1 AND header.finance_confirmed
        AND NOT header.is_deleted AND NOT header.is_closed AND NOT header.is_stopped
      WHERE item.id=source.sales_order_item_id AND NOT item.is_deleted
        AND (item.goods_id,item.color_id,item.unit_id) IS NOT DISTINCT FROM (source.goods_id,source.color_id,source.unit_id);
      IF NOT FOUND OR conversion<=0 THEN RETURN NULL; END IF;
    END IF;
    last_depth:=NULL;
    FOR edge IN WITH RECURSIVE ancestry AS (
      SELECT row.*,ARRAY[row.id] AS visited FROM production_material_analysis_materials row WHERE row.id=p_material AND row.active
      UNION ALL
      SELECT parent.*,child.visited||parent.id FROM ancestry child
      JOIN production_material_analysis_materials parent ON parent.analysis_item_id=child.analysis_item_id
        AND parent.analysis_id=child.analysis_id AND parent.node_key=child.parent_node_key AND parent.active
      WHERE NOT parent.id=ANY(child.visited) AND cardinality(child.visited)<64
    ) SELECT * FROM ancestry ORDER BY depth LOOP
      IF last_depth IS NULL THEN
        IF NOT (edge.depth=0 AND edge.parent_node_key IS NULL OR edge.depth=1 AND edge.parent_node_key IS NULL) THEN RETURN NULL; END IF;
        expected_depth:=edge.depth;
      END IF;
      IF edge.depth<>expected_depth OR edge.bom_qty<=0 OR edge.basis_output_qty<=0 THEN RETURN NULL; END IF;
      IF edge.depth>0 THEN
        IF edge.depth>1 AND NOT parent_expands THEN RETURN NULL; END IF;
      END IF;
      IF edge.consumption_basis NOT IN('PER_UNIT','PER_PACKAGE','FIXED_BATCH') THEN RETURN NULL; END IF;
      last_depth:=edge.depth;expected_depth:=edge.depth+1;
      parent_expands:=COALESCE(edge.confirmed_route,edge.source_suggestion,'REVIEW') IN('MAKE','SUBCONTRACT') AND edge.control_stage<>'REFERENCE';
    END LOOP;
    IF last_depth IS DISTINCT FROM material.depth THEN RETURN NULL; END IF;
    RETURN GREATEST(material.required_qty+COALESCE((SELECT SUM(fn_preplan_aggregate_alias_qty(alias.id))
      FROM preplan_aggregate_material_aliases alias WHERE alias.source_material_id=p_material
        AND fn_preplan_aggregate_alias_identity_valid(alias.id)),0),0);
END $$;

-- The existing allocation receipt authority, filtered by immutable original.
-- Formalized output remains received; physical release/reversal is netted and
-- root fulfillment is added once. Header SUM(qty) is not a receipt balance.
CREATE FUNCTION fn_preplan_original_allocation_received_qty(p_allocation UUID,p_original UUID)
RETURNS NUMERIC LANGUAGE sql STABLE AS $$
    SELECT COALESCE((SELECT SUM(CASE WHEN reservation.release_reason='TRANSFERRED_TO_PLAN' THEN exact.qty
        ELSE GREATEST(reservation.qty-reservation.consumed_qty-reservation.released_qty,0) END)
      FROM preplan_analysis_stock_exact_pegs exact
      JOIN stock_reservations reservation ON reservation.id=exact.stock_reservation_id AND NOT reservation.is_deleted
      WHERE exact.supply_action_allocation_id=p_allocation AND exact.origin_analysis_material_id=p_original
        AND (reservation.status=0 OR reservation.release_reason='TRANSFERRED_TO_PLAN')),0)
      +COALESCE((SELECT SUM(CASE WHEN output.event_kind='FULFILL' THEN output.qty_base ELSE -output.qty_base END)
        FROM preplan_root_output_events output JOIN preplan_analysis_stock_exact_pegs exact ON exact.stock_reservation_id=output.source_reservation_id
        WHERE exact.supply_action_allocation_id=p_allocation AND exact.origin_analysis_material_id=p_original),0);
$$;

CREATE FUNCTION fn_preplan_allocation_base_admitted_qty(p_allocation UUID) RETURNS NUMERIC LANGUAGE sql STABLE AS $$
    SELECT COALESCE((SELECT GREATEST(allocation.allocated_qty
      -COALESCE((SELECT sum(transfer.qty-fn_preplan_future_transfer_restored_qty(transfer.id))
          FROM preplan_future_supply_transfers transfer WHERE transfer.source_allocation_id=allocation.id),0)
      -COALESCE((SELECT fn_preplan_future_transfer_cancelled_qty(transfer.id)
          FROM preplan_future_supply_transfers transfer WHERE transfer.target_allocation_id=allocation.id),0),0)
      FROM preplan_supply_action_allocations allocation WHERE allocation.id=p_allocation),0);
$$;

CREATE FUNCTION fn_preplan_aggregate_retained_private_sources_scoped(p_analysis UUID,p_material UUID)
RETURNS TABLE(supply_batch_id UUID,supply_action_id UUID,allocation_id UUID,canonical_material_id UUID,
    original_material_id UUID,current_qty NUMERIC,admitted_qty NUMERIC,received_qty NUMERIC,pending_qty NUMERIC,source_valid BOOLEAN)
LANGUAGE plpgsql STABLE AS $$
#variable_conflict use_column
BEGIN
    -- The normal path has no cancelled parent. Do not introduce a graph scan
    -- for each ordinary material-analysis allocation or receipt.
    IF NOT EXISTS(SELECT 1 FROM preplan_aggregate_batches parent
        JOIN preplan_supply_actions action ON action.id=parent.action_id AND action.status='CANCELLED' AND action.analysis_id=p_analysis
        WHERE parent.analysis_id=p_analysis) THEN RETURN; END IF;
    RETURN QUERY
    WITH material_scope AS MATERIALIZED (
      SELECT p_material AS id WHERE p_material IS NOT NULL
      UNION SELECT alias.source_material_id FROM preplan_aggregate_material_aliases alias WHERE alias.aggregate_material_id=p_material
    ), candidate_batches AS MATERIALIZED (
      SELECT DISTINCT child.id FROM preplan_aggregate_batches child
      JOIN preplan_supply_actions child_action ON child_action.id=child.action_id AND child_action.status<>'CANCELLED'
      JOIN preplan_supply_action_allocations allocation ON allocation.action_id=child.action_id
      JOIN production_material_analysis_materials canonical ON canonical.id=allocation.analysis_material_id
      JOIN preplan_aggregate_batches parent ON parent.anchor_analysis_item_id=canonical.analysis_item_id AND parent.analysis_id=p_analysis
      JOIN preplan_supply_actions parent_action ON parent_action.id=parent.action_id AND parent_action.status='CANCELLED'
      WHERE child.analysis_id=p_analysis AND (p_material IS NULL OR EXISTS(
        SELECT 1 FROM preplan_aggregate_material_aliases alias JOIN material_scope material ON material.id=alias.source_material_id
        WHERE alias.aggregate_material_id=canonical.id))
    ), recorded_private AS MATERIALIZED (
      SELECT recorded.* FROM (SELECT array_agg(candidate.id) AS ids FROM candidate_batches candidate HAVING count(*)>0) scope
      CROSS JOIN LATERAL fn_preplan_aggregate_recorded_private_sources_scoped_batches(p_analysis,NULL,scope.ids) recorded
    ), proof AS MATERIALIZED (
      SELECT recorded.*,allocation.created_at,action.status,
        fn_preplan_original_allocation_received_qty(recorded.allocation_id,recorded.original_material_id) AS received,
        fn_preplan_allocation_base_admitted_qty(recorded.allocation_id) AS allocation_admitted,
        SUM(recorded.recorded_qty) OVER(PARTITION BY recorded.allocation_id) AS recorded_total,
        SUM(recorded.recorded_qty) OVER(PARTITION BY recorded.allocation_id ORDER BY recorded.original_material_id) AS recorded_prefix,
        BOOL_AND(recorded.structural_valid) OVER(PARTITION BY recorded.allocation_id) AS allocation_proof_valid
      FROM recorded_private recorded
      JOIN preplan_supply_action_allocations allocation ON allocation.id=recorded.allocation_id
      JOIN preplan_supply_actions action ON action.id=recorded.supply_action_id AND action.status<>'CANCELLED'
      JOIN production_material_analysis_materials canonical ON canonical.id=recorded.canonical_material_id
      JOIN preplan_aggregate_batches parent ON parent.anchor_analysis_item_id=canonical.analysis_item_id AND parent.analysis_id=p_analysis
      JOIN preplan_supply_actions parent_action ON parent_action.id=parent.action_id AND parent_action.status='CANCELLED'
      WHERE recorded.original_material_id<>recorded.canonical_material_id
    ), originals AS MATERIALIZED (
      SELECT DISTINCT proof.original_material_id AS id FROM proof
    ), capacity AS MATERIALIZED (
      SELECT original.id,fn_preplan_original_material_capacity(original.id) AS gross,
        GREATEST(fn_preplan_aggregate_target_committed_qty(original.id)
          +COALESCE((SELECT SUM(fn_preplan_aggregate_alias_delegated_qty(alias.id))
            FROM preplan_aggregate_material_aliases alias WHERE alias.source_material_id=original.id
              AND fn_preplan_aggregate_alias_identity_valid(alias.id)),0)
          -COALESCE((SELECT SUM(proof.received) FROM proof WHERE proof.original_material_id=original.id),0),0) AS other_received,
        COALESCE((SELECT SUM(GREATEST(fn_preplan_allocation_admitted_qty(other.id)-fn_preplan_allocation_received_qty(other.id),0))
          FROM preplan_supply_action_allocations other JOIN preplan_supply_actions other_action ON other_action.id=other.action_id
          WHERE other.analysis_material_id=original.id AND other_action.status<>'CANCELLED'
            AND NOT EXISTS(SELECT 1 FROM proof WHERE proof.allocation_id=other.id)),0) AS other_pending
      FROM originals original
    ), canonicals AS MATERIALIZED (
      SELECT DISTINCT proof.canonical_material_id AS id FROM proof
    ), canonical_state AS MATERIALIZED (
      SELECT canonical.id,fn_preplan_material_has_qualified_receipt(canonical.id) AS legacy_receipt FROM canonicals canonical
    ), budget AS MATERIALIZED (
      SELECT proof.*,capacity.gross,capacity.gross IS NOT NULL AND proof.allocation_proof_valid AND NOT canonical_state.legacy_receipt AS source_valid,
        CASE WHEN proof.structural_valid AND proof.allocation_proof_valid AND capacity.gross IS NOT NULL
          AND NOT canonical_state.legacy_receipt THEN LEAST(proof.recorded_qty,
            (floor(proof.allocation_admitted*proof.recorded_prefix/NULLIF(proof.recorded_total,0)*10000)
             -floor(proof.allocation_admitted*(proof.recorded_prefix-proof.recorded_qty)/NULLIF(proof.recorded_total,0)*10000))/10000) ELSE 0 END AS quota,
        GREATEST(COALESCE(capacity.gross,0)-capacity.other_received-capacity.other_pending,0) AS current_capacity
      FROM proof JOIN capacity ON capacity.id=proof.original_material_id
      JOIN canonical_state ON canonical_state.id=proof.canonical_material_id
    ), ranked AS MATERIALIZED (
      SELECT budget.*,COALESCE(SUM(quota) OVER(PARTITION BY original_material_id ORDER BY created_at,allocation_id
        ROWS BETWEEN UNBOUNDED PRECEDING AND 1 PRECEDING),0) AS preceding
      FROM budget
    ), admitted AS MATERIALIZED (
      SELECT ranked.*,LEAST(quota,GREATEST(current_capacity-preceding,0)) AS current_admission,
        GREATEST(received,LEAST(quota,GREATEST(current_capacity-preceding,0))) AS admitted
      FROM ranked
    ) SELECT admitted.supply_batch_id,admitted.supply_action_id,admitted.allocation_id,admitted.canonical_material_id,
        admitted.original_material_id,admitted.current_admission,admitted.admitted,admitted.received,
        CASE WHEN admitted.status IN('OPEN','CREATED','IN_PROGRESS') THEN GREATEST(admitted.current_admission-admitted.received,0) ELSE 0 END,admitted.source_valid
      FROM admitted;
END $$;

CREATE FUNCTION fn_preplan_aggregate_retained_private_sources(p_analysis UUID)
RETURNS TABLE(supply_batch_id UUID,supply_action_id UUID,allocation_id UUID,canonical_material_id UUID,
    original_material_id UUID,current_qty NUMERIC,admitted_qty NUMERIC,received_qty NUMERIC,pending_qty NUMERIC,source_valid BOOLEAN)
LANGUAGE sql STABLE AS $$
    SELECT * FROM fn_preplan_aggregate_retained_private_sources_scoped(p_analysis,NULL);
$$;

COMMENT ON FUNCTION fn_preplan_aggregate_retained_private_sources(UUID) IS
    'One current original private responsibility after parent cancellation; admitted includes received, pending subtracts received once';

CREATE OR REPLACE FUNCTION fn_preplan_allocation_admitted_qty(p_allocation UUID) RETURNS NUMERIC LANGUAGE plpgsql STABLE AS $$
DECLARE allocation preplan_supply_action_allocations%ROWTYPE; admitted NUMERIC; source_valid BOOLEAN;
BEGIN
    SELECT * INTO allocation FROM preplan_supply_action_allocations WHERE id=p_allocation;
    IF NOT FOUND THEN RETURN 0; END IF;
    IF NOT EXISTS(SELECT 1 FROM production_material_analysis_materials canonical
      JOIN preplan_aggregate_batches parent ON parent.anchor_analysis_item_id=canonical.analysis_item_id
        AND parent.analysis_id=allocation.analysis_id
      JOIN preplan_supply_actions action ON action.id=parent.action_id AND action.status='CANCELLED'
      WHERE canonical.id=allocation.analysis_material_id) THEN RETURN fn_preplan_allocation_base_admitted_qty(p_allocation); END IF;
    SELECT SUM(retained.admitted_qty),BOOL_AND(retained.source_valid) INTO admitted,source_valid FROM fn_preplan_aggregate_retained_private_sources_scoped(allocation.analysis_id,allocation.analysis_material_id) retained
      WHERE retained.allocation_id=p_allocation;
    IF admitted IS NULL OR NOT source_valid THEN RETURN fn_preplan_allocation_base_admitted_qty(p_allocation); END IF;
    RETURN GREATEST(admitted,fn_preplan_allocation_received_qty(p_allocation));
END $$;

-- An indexed allocation lookup is also usable by historical qualification;
-- it deliberately has no today's-capacity or action-status condition.
CREATE FUNCTION fn_preplan_aggregate_recorded_original_origin(p_allocation UUID,p_original UUID)
RETURNS BOOLEAN LANGUAGE sql STABLE AS $$
    SELECT EXISTS(
      SELECT 1 FROM preplan_supply_action_allocations allocation
      JOIN preplan_aggregate_batches child ON child.action_id=allocation.action_id AND child.analysis_id=allocation.analysis_id
      JOIN production_material_analysis_materials canonical ON canonical.id=allocation.analysis_material_id
      JOIN production_material_analysis_materials original ON original.id=p_original AND original.analysis_id=allocation.analysis_id
      WHERE allocation.id=p_allocation AND (original.goods_id,original.color_id,original.unit_id)
        IS NOT DISTINCT FROM (canonical.goods_id,canonical.color_id,canonical.unit_id)
        AND EXISTS(SELECT 1 FROM preplan_aggregate_material_aliases alias
          JOIN preplan_aggregate_batches parent ON parent.id=alias.batch_id AND parent.analysis_id=allocation.analysis_id
          WHERE alias.source_material_id=original.id AND alias.aggregate_material_id=canonical.id
            AND canonical.analysis_item_id=parent.anchor_analysis_item_id
            AND alias.relative_bom_path=fn_aggregate_relative_bom_path(original.id,alias.source_parent_material_id)
            AND alias.relative_bom_path=fn_aggregate_relative_bom_path(canonical.id,NULL))
        AND NOT EXISTS(SELECT 1 FROM preplan_aggregate_batch_events event WHERE event.batch_id=child.id
          AND event.event_type IN('CREATE','APPEND') AND jsonb_typeof(event.intent_snapshot->'sourcePrivateQtyByTargetMaterialLineId') IS DISTINCT FROM 'object'
          AND NOT(event.event_type='APPEND' AND event.allocation_deltas='{}'::jsonb))
        AND (SELECT COALESCE(sum((event.intent_snapshot->'sourcePrivateQtyByTargetMaterialLineId'
          ->allocation.analysis_material_id::text->>p_original::text)::numeric),0)
          FROM preplan_aggregate_batch_events event WHERE event.batch_id=child.id AND event.event_type IN('CREATE','APPEND'))>0
        AND (SELECT COALESCE(sum(value.value::numeric),0)
          FROM preplan_aggregate_batch_events event
          CROSS JOIN LATERAL jsonb_each_text(event.intent_snapshot->'sourcePrivateQtyByTargetMaterialLineId'->allocation.analysis_material_id::text) value
          WHERE event.batch_id=child.id AND event.event_type IN('CREATE','APPEND'))=allocation.allocated_qty);
$$;

CREATE OR REPLACE FUNCTION fn_preplan_aggregate_make_origin(p_child UUID,p_allocation UUID,p_material UUID,p_plan UUID)
RETURNS BOOLEAN LANGUAGE plpgsql STABLE AS $$
BEGIN
    RETURN EXISTS(SELECT 1 FROM preplan_aggregate_batches batch
      JOIN preplan_supply_actions action ON action.id=batch.action_id AND action.route='MAKE'
        AND action.external_document_type='PREPLAN_MAKE_TASK' AND action.external_document_id=p_child
      JOIN preplan_supply_action_allocations allocation ON allocation.id=p_allocation AND allocation.action_id=action.id
      WHERE batch.anchor_analysis_item_id=p_child AND batch.plan_id=p_plan AND batch.route='MAKE'
        AND allocation.external_item_id=p_child AND allocation.analysis_id=batch.analysis_id
        AND (allocation.analysis_material_id=p_material OR fn_preplan_aggregate_recorded_original_origin(allocation.id,p_material)));
END $$;

-- Existing exact stock, origin, stock-document, IQC and aggregate-allocation
-- guards remain. Only the exact recorded owner may differ from the old target.
DO $original_exact_guard$
DECLARE definition TEXT; needle TEXT;
BEGIN
    SELECT replace(pg_get_functiondef('fn_check_preplan_analysis_stock_exact_peg()'::regprocedure),chr(13),'') INTO definition;
    needle:='OR allocation.analysis_material_id <> NEW.origin_analysis_material_id';
    IF position(needle IN definition)=0 THEN RAISE EXCEPTION 'V895 exact allocation identity guard anchor changed'; END IF;
    definition:=replace(definition,needle,'OR (allocation.analysis_material_id <> NEW.origin_analysis_material_id
       AND NOT fn_preplan_aggregate_recorded_original_origin(allocation.id,NEW.origin_analysis_material_id))');
    needle:=E'    RETURN NEW;\nEND;';
    IF position(needle IN definition)=0 THEN RAISE EXCEPTION 'V895 exact original admission guard anchor changed'; END IF;
    definition:=replace(definition,needle,E'    IF allocation.analysis_material_id IS DISTINCT FROM NEW.origin_analysis_material_id
       AND fn_preplan_original_allocation_received_qty(allocation.id,NEW.origin_analysis_material_id)
           >COALESCE((SELECT retained.current_qty FROM fn_preplan_aggregate_retained_private_sources_scoped(allocation.analysis_id,NEW.origin_analysis_material_id) retained
               WHERE retained.allocation_id=allocation.id AND retained.original_material_id=NEW.origin_analysis_material_id),0)
    THEN RAISE EXCEPTION \'Original private receipt exceeds its current admitted responsibility\' USING ERRCODE=\'23514\',CONSTRAINT=\'aggregate_original_private_admission\'; END IF;
    RETURN NEW;\nEND;');
    EXECUTE definition;
END $original_exact_guard$;

-- Reuse the existing active-alias recursion after moving each old canonical
-- promise to its exact original once. A new parent receives that same promise
-- through its current alias; cancelled demand aliases are never reactivated.
DO $original_pending$
DECLARE definition TEXT; needle TEXT;
BEGIN
    SELECT replace(pg_get_functiondef('fn_preplan_aggregate_material_pending_qty(uuid,uuid[])'::regprocedure),chr(13),'') INTO definition;
    needle:='total:=total+COALESCE((SELECT sum(pending_qty) FROM fn_preplan_aggregate_direct_make_sources(p_material)),0);';
    IF position(needle IN definition)=0 THEN RAISE EXCEPTION 'V895 material pending guard anchor changed'; END IF;
    definition:=replace(definition,needle,needle||E'\n    SELECT GREATEST(total-COALESCE(SUM(retained.pending_qty) FILTER(WHERE retained.canonical_material_id=p_material),0),0)
        +COALESCE(SUM(retained.pending_qty) FILTER(WHERE retained.original_material_id=p_material),0) INTO total
      FROM fn_preplan_aggregate_retained_private_sources_scoped((SELECT analysis_id FROM production_material_analysis_materials WHERE id=p_material),p_material) retained;');
    EXECUTE definition;
END $original_pending$;

CREATE FUNCTION fn_preplan_material_has_qualified_receipt(p_material UUID)
RETURNS BOOLEAN LANGUAGE sql STABLE AS $$
    SELECT EXISTS(SELECT 1 FROM preplan_analysis_stock_exact_pegs exact
      WHERE exact.origin_analysis_material_id=p_material
        AND fn_preplan_reservation_has_qualified_origin(exact.stock_reservation_id));
$$;

CREATE FUNCTION fn_preplan_aggregate_allocation_private_proof_complete(p_allocation UUID)
RETURNS BOOLEAN LANGUAGE sql STABLE AS $$
    SELECT COALESCE((SELECT BOOL_AND(proof.structural_valid)
      FROM preplan_supply_action_allocations allocation
      JOIN preplan_aggregate_batches batch ON batch.action_id=allocation.action_id AND batch.analysis_id=allocation.analysis_id
      CROSS JOIN LATERAL fn_preplan_aggregate_recorded_private_sources_scoped_batches(allocation.analysis_id,NULL,ARRAY[batch.id]) proof
      WHERE allocation.id=p_allocation AND proof.allocation_id=allocation.id),FALSE);
$$;

CREATE FUNCTION fn_preplan_aggregate_cancelled_parent_receipt_blocks(p_analysis UUID)
RETURNS TABLE(analysis_item_id UUID,block_reason TEXT) LANGUAGE plpgsql STABLE AS $$
BEGIN
    IF NOT EXISTS(SELECT 1 FROM preplan_aggregate_batches parent
      JOIN preplan_supply_actions action ON action.id=parent.action_id AND action.status='CANCELLED' AND action.analysis_id=p_analysis
      WHERE parent.analysis_id=p_analysis) THEN RETURN; END IF;
    RETURN QUERY
    WITH affected AS MATERIALIZED (
      SELECT DISTINCT alias.aggregate_material_id,original.analysis_item_id AS original_source,canonical.analysis_item_id AS old_anchor,
        CASE WHEN fn_preplan_material_has_qualified_receipt(canonical.id)
          THEN '已撤回父批次的独立子件仍有原共享路径实收；请先核对收货、领用及归属，当前不能继续下达或调拨'
          WHEN fn_preplan_original_material_capacity(original.id) IS NULL
          THEN '独立子供给的原始来源、BOM或供应方式暂不可用；已有关联保持私有，请先核对后继续收货或规划'
          ELSE '已撤回父批次的独立子供给缺少可验证的原始私有来源；请先核对责任，当前不能继续下达或调拨' END AS reason
      FROM preplan_aggregate_batches parent
      JOIN preplan_supply_actions action ON action.id=parent.action_id AND action.status='CANCELLED'
      JOIN preplan_aggregate_material_aliases alias ON alias.batch_id=parent.id
      JOIN production_material_analysis_materials original ON original.id=alias.source_material_id
      JOIN production_material_analysis_materials canonical ON canonical.id=alias.aggregate_material_id
      WHERE parent.analysis_id=p_analysis AND alias.qty>0 AND (
        fn_preplan_material_has_qualified_receipt(canonical.id)
        OR EXISTS(SELECT 1 FROM preplan_supply_action_allocations allocation
          JOIN preplan_supply_actions child_action ON child_action.id=allocation.action_id AND child_action.status<>'CANCELLED'
          WHERE allocation.analysis_material_id=canonical.id AND (
            NOT fn_preplan_aggregate_allocation_private_proof_complete(allocation.id)
            OR (fn_preplan_aggregate_recorded_original_origin(allocation.id,original.id)
                AND fn_preplan_original_material_capacity(original.id) IS NULL)))
        OR EXISTS(SELECT 1 FROM production_material_analysis_items child
          JOIN production_material_analysis_plan_links link ON link.analysis_item_id=child.id AND link.allocation_status IN('SUBMITTED','APPROVED')
          JOIN production_plans plan ON plan.id=link.plan_id AND plan.status IN(0,1) AND NOT plan.is_deleted AND NOT plan.is_canceled
          WHERE child.parent_analysis_material_id=canonical.id AND child.source_type='MAKE_COMPONENT' AND NOT child.is_deleted))
    ) SELECT original_source,reason FROM affected
      UNION SELECT old_anchor,reason FROM affected
      UNION SELECT child.anchor_analysis_item_id,affected.reason FROM affected
        JOIN preplan_supply_action_allocations allocation ON allocation.analysis_material_id=affected.aggregate_material_id
        JOIN preplan_aggregate_batches child ON child.action_id=allocation.action_id AND child.analysis_id=p_analysis AND child.anchor_analysis_item_id IS NOT NULL
      UNION SELECT child.id,affected.reason FROM affected
        JOIN production_material_analysis_items child ON child.parent_analysis_material_id=affected.aggregate_material_id
        WHERE child.source_type='MAKE_COMPONENT' AND NOT child.is_deleted;
END;
$$;

-- Do not silently turn already-received old-canonical stock into original or
-- public stock. Until an explicit reversible custody transfer is reviewed,
-- reject the whole parent cancellation before any package/plan is reversed.
CREATE OR REPLACE FUNCTION fn_guard_aggregate_source_cancellation() RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
    IF NEW.status='CANCELLED' AND OLD.status<>'CANCELLED' AND EXISTS(
        SELECT 1 FROM preplan_aggregate_batches batch WHERE batch.action_id=NEW.id) THEN
      IF EXISTS(SELECT 1 FROM preplan_aggregate_batches batch
        JOIN preplan_aggregate_material_aliases alias ON alias.batch_id=batch.id
        WHERE batch.action_id=NEW.id AND fn_preplan_material_has_qualified_receipt(alias.aggregate_material_id)) THEN
        RAISE EXCEPTION '独立子件已有实收到原共享路径；请先处理收货、领用及其归属后再撤回父批次'
          USING ERRCODE='23514',CONSTRAINT='aggregate_parent_received_child_dependency';
      END IF;
      IF EXISTS(SELECT 1 FROM preplan_make_entitlement_delegations delegation WHERE delegation.supply_action_id=NEW.id
          AND fn_preplan_aggregate_delegation_active_qty(delegation.id)>0) THEN
        RAISE EXCEPTION '共享批次的原路径投入权益尚未归还；先处理领料、正式占用和后续依赖后再撤销'
          USING ERRCODE='23514',CONSTRAINT='aggregate_material_cancellation_dependency';
      END IF;
    END IF;
    RETURN NEW;
END $$;
