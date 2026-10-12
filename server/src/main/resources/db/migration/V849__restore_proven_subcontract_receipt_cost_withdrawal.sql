-- V843's confirmed-zero IQC rewrite accidentally restored V527's blanket
-- cost-output ban. Restore V528's exact source-reversibility proof, retaining
-- all later entry dispatches and every quantity/custody/zero-posting predicate.
DO $restore_subcontract_cost_withdrawal$
DECLARE definition TEXT;
    needle TEXT:='EXISTS(SELECT 1 FROM stock_value_production_cost_outputs WHERE source_node_id=original.result_node_id)';
    replacement TEXT:='NOT fn_stock_value_stored_cost_reversible(original.result_node_id)';
BEGIN
    SELECT pg_get_functiondef('fn_check_stock_value_reverse_store()'::regprocedure) INTO definition;
    IF length(definition)-length(replace(definition,needle,''))<>length(needle) THEN
        RAISE EXCEPTION 'V849 expected exactly one obsolete blanket stored-cost predicate';
    END IF;
    EXECUTE replace(definition,needle,replacement);
END;
$restore_subcontract_cost_withdrawal$;
