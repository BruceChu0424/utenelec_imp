-- A split shares its original approved production cost basis. Physical output
-- documents keep the exact child segment and actual warehouse identities.
CREATE FUNCTION fn_production_execution_cost_scope(p_segment UUID) RETURNS UUID
LANGUAGE sql STABLE AS $$
    WITH RECURSIVE lineage AS (
        SELECT segment.id,segment.source_segment_id,segment.split_root_segment_id,
               ARRAY[segment.id] AS visited
        FROM production_execution_segments segment WHERE segment.id=p_segment
        UNION ALL
        SELECT parent.id,parent.source_segment_id,parent.split_root_segment_id,
               child.visited||parent.id
        FROM lineage child
        JOIN production_execution_segment_splits proof
          ON proof.source_segment_id=child.source_segment_id
         AND child.id IN(proof.batch_segment_id,proof.remaining_segment_id)
        JOIN production_execution_segments parent ON parent.id=proof.source_segment_id
        WHERE NOT parent.id=ANY(child.visited)
    )
    SELECT root.id FROM lineage root
    JOIN production_execution_segments original ON original.id=p_segment
    WHERE root.source_segment_id IS NULL AND root.split_root_segment_id IS NULL
      AND root.id=COALESCE(original.split_root_segment_id,original.id)
$$;

-- Retired intermediate rows never add a second copy of the approved target.
-- This reads current leaf facts; it does not authorize changing an analysis
-- plan's frozen quantity or bypass any existing final-report/plan guard.
CREATE FUNCTION fn_production_execution_cost_target(p_scope UUID) RETURNS NUMERIC
LANGUAGE sql STABLE AS $$
    SELECT CASE WHEN EXISTS(SELECT 1 FROM production_execution_segment_splits split WHERE split.source_segment_id=root.id)
        THEN (SELECT COALESCE(sum(leaf.planned_qty*leaf.product_unit_rate),0)
              FROM production_execution_segments leaf
              WHERE leaf.split_root_segment_id=root.id
                AND fn_production_execution_cost_scope(leaf.id)=root.id
                AND NOT EXISTS(SELECT 1 FROM production_execution_segment_splits retired WHERE retired.source_segment_id=leaf.id))
        ELSE root.planned_qty*root.product_unit_rate END
    FROM production_execution_segments root WHERE root.id=p_scope
$$;

DO $existing_split_values$
BEGIN
    IF EXISTS(SELECT 1 FROM stock_value_production_cost_objects object
        JOIN production_execution_segments segment ON segment.id=object.execution_segment_id
        WHERE object.source_kind='PRODUCTION_EXECUTION' AND segment.split_root_segment_id IS NOT NULL)
      OR EXISTS(SELECT 1 FROM stock_value_nodes node
        JOIN production_execution_segments segment ON segment.id=node.owner_id
        WHERE node.owner_kind='COST_WIP' AND segment.split_root_segment_id IS NOT NULL) THEN
        RAISE EXCEPTION 'Existing split-child cost postings require explicit reconciliation before V562; historical monetary facts cannot be reparented';
    END IF;
END;
$existing_split_values$;

-- Keep the existing typed subcontract checks and physical-output checks. Only
-- the production execution equality expands through a proven split lineage.
DO $output_scope$
DECLARE definition TEXT; needle TEXT:='item.execution_segment_id=NEW.execution_segment_id';
BEGIN
    SELECT pg_get_functiondef('fn_check_subcontract_cost_scope_facts()'::regprocedure) INTO definition;
    IF (length(definition)-length(replace(definition,needle,'')))/length(needle)<>1 THEN
        RAISE EXCEPTION 'V562 production cost output source guard changed';
    END IF;
    EXECUTE replace(definition,needle,
        'fn_production_execution_cost_scope(item.execution_segment_id)=NEW.execution_segment_id');
END;
$output_scope$;

DO $withdrawal_scope$
DECLARE definition TEXT; needle TEXT:='item.execution_segment_id=object.execution_segment_id';
BEGIN
    SELECT pg_get_functiondef('fn_assert_unused_production_receipt_reversal(uuid)'::regprocedure) INTO definition;
    IF (length(definition)-length(replace(definition,needle,'')))/length(needle)<>1 THEN
        RAISE EXCEPTION 'V562 production cost withdrawal source guard changed';
    END IF;
    EXECUTE replace(definition,needle,
        'fn_production_execution_cost_scope(item.execution_segment_id)=object.execution_segment_id');
END;
$withdrawal_scope$;

DO $refresh_scope$
DECLARE definition TEXT; needle TEXT;
BEGIN
    SELECT pg_get_functiondef('fn_guard_cost_business_refresh_source()'::regprocedure) INTO definition;
    FOREACH needle IN ARRAY ARRAY['demand.execution_segment_id=NEW.execution_segment_id',
                                  'item.execution_segment_id=NEW.execution_segment_id'] LOOP
        IF (length(definition)-length(replace(definition,needle,'')))/length(needle)<>1 THEN
            RAISE EXCEPTION 'V562 production cost refresh source guard changed: %',needle;
        END IF;
        definition:=replace(definition,needle,
            'fn_production_execution_cost_scope('||split_part(needle,'=',1)||')=NEW.execution_segment_id');
    END LOOP;
    EXECUTE definition;
END;
$refresh_scope$;

COMMENT ON FUNCTION fn_production_execution_cost_scope(UUID) IS
    'Production cost scope is the exact original execution root proven by immutable batch splits; non-split execution keeps its own scope.';
COMMENT ON FUNCTION fn_production_execution_cost_target(UUID) IS
    'Approved production target of one cost scope; split families sum current leaf targets without counting retired split parents or changing approved plan quantities.';
