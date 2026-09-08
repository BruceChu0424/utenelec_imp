-- Forward-only reset policy extension. V500 and V503 business facts are cleared
-- together with their physical stock and procurement sources; master data,
-- authorization and audit evidence retain the existing PRESERVE policy.
DO $reset_policy$
DECLARE
    definition TEXT;
    needle TEXT := '(''stock_movements'', ''CLEAR'')';
    addition TEXT := E',\n            (''stock_value_pools'', ''CLEAR''),\n            (''stock_value_events'', ''CLEAR''),\n            (''stock_value_nodes'', ''CLEAR''),\n            (''stock_value_edges'', ''CLEAR''),\n            (''stock_value_jobs'', ''CLEAR''),\n            (''stock_value_tasks'', ''CLEAR''),\n            (''stock_value_node_revisions'', ''CLEAR''),\n            (''stock_value_postings'', ''CLEAR''),\n            (''procurement_order_source_revisions'', ''CLEAR''),\n            (''procurement_order_source_revision_allocations'', ''CLEAR''),\n            (''procurement_order_source_revision_peg_changes'', ''CLEAR'')';
    table_name TEXT;
BEGIN
    SELECT pg_get_functiondef('business_data_reset()'::regprocedure) INTO definition;
    IF (length(definition)-length(replace(definition,needle,'')))/length(needle) <> 1 THEN
        RAISE EXCEPTION 'V504 cannot extend business_data_reset policy safely';
    END IF;
    FOREACH table_name IN ARRAY ARRAY[
        'stock_value_pools', 'stock_value_events', 'stock_value_nodes', 'stock_value_edges',
        'stock_value_jobs', 'stock_value_tasks', 'stock_value_node_revisions', 'stock_value_postings',
        'procurement_order_source_revisions', 'procurement_order_source_revision_allocations',
        'procurement_order_source_revision_peg_changes'
    ] LOOP
        IF to_regclass(format('public.%I',table_name)) IS NULL
           OR position(format('(%L, %L)',table_name,'CLEAR') IN definition)>0
           OR position(format('(%L, %L)',table_name,'PRESERVE') IN definition)>0 THEN
            RAISE EXCEPTION 'V504 reset policy source missing or already classified: %', table_name;
        END IF;
    END LOOP;
    EXECUTE replace(definition,needle,needle || addition);
END;
$reset_policy$;
