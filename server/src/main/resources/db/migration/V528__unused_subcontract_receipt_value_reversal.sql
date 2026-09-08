-- A reversed unused receipt retains its original output record but is excluded
-- from future cost allocation. Own materials must first return to their exact issue custody.
ALTER TABLE stock_value_production_cost_outputs ADD COLUMN withdrawn_movement_id UUID
    REFERENCES stock_movements(id) DEFERRABLE INITIALLY DEFERRED;

CREATE FUNCTION fn_stock_value_stored_cost_reversible(p_source UUID) RETURNS BOOLEAN LANGUAGE sql STABLE AS $$
    SELECT NOT EXISTS(SELECT 1 FROM stock_value_production_cost_outputs output
        JOIN stock_value_production_cost_objects object ON object.execution_segment_id=output.execution_segment_id
        WHERE output.source_node_id=p_source AND (
            object.source_kind NOT IN('SUBCONTRACT_RECEIPT_ITEM','SUBCONTRACT_ORDER_NORMAL_LOSS')
            OR object.source_kind='SUBCONTRACT_ORDER_NORMAL_LOSS' AND EXISTS(
                SELECT 1 FROM stock_value_production_cost_inputs input WHERE input.execution_segment_id=object.execution_segment_id)
            OR object.source_kind='SUBCONTRACT_RECEIPT_ITEM' AND EXISTS(
                SELECT 1 FROM stock_value_production_cost_inputs input JOIN stock_value_nodes node ON node.id=input.input_node_id
                WHERE input.execution_segment_id=object.execution_segment_id AND node.returned_consumption_qty<>node.quantity_basis)))
        AND NOT EXISTS(SELECT 1 FROM stock_value_production_cost_shares WHERE output_source_node_id=p_source AND allocated_value_local<>0)
        AND NOT EXISTS(SELECT 1 FROM stock_value_production_cost_tasks WHERE output_source_node_id=p_source AND status='PENDING')
        AND NOT EXISTS(SELECT 1 FROM stock_value_jobs WHERE source_node_id=p_source AND status='PENDING');
$$;
DO $reversible_source$
DECLARE definition TEXT;needle TEXT:='EXISTS(SELECT 1 FROM stock_value_production_cost_outputs WHERE source_node_id=original.result_node_id)';
BEGIN
    SELECT pg_get_functiondef('fn_check_stock_value_reverse_store()'::regprocedure) INTO definition;
    IF position(needle IN definition)=0 THEN RAISE EXCEPTION 'unused receipt reversal source guard changed before V528'; END IF;
    EXECUTE replace(definition,needle,'NOT fn_stock_value_stored_cost_reversible(original.result_node_id)');
END;
$reversible_source$;

CREATE FUNCTION fn_guard_withdrawn_cost_output() RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
    IF TG_OP='DELETE' THEN RAISE EXCEPTION 'cost output history cannot be deleted' USING ERRCODE='55000'; END IF;
    IF OLD.withdrawn_movement_id IS NOT NULL OR NEW.withdrawn_movement_id IS NULL
        OR (to_jsonb(NEW)-'withdrawn_movement_id') IS DISTINCT FROM (to_jsonb(OLD)-'withdrawn_movement_id') THEN
        RAISE EXCEPTION 'only one exact physical withdrawal may retire a cost output' USING ERRCODE='55000';
    END IF;
    RETURN NEW;
END;
$$;
DROP TRIGGER stock_value_production_cost_outputs_immutable ON stock_value_production_cost_outputs;
CREATE TRIGGER stock_value_production_cost_outputs_immutable BEFORE UPDATE OR DELETE ON stock_value_production_cost_outputs
    FOR EACH ROW EXECUTE FUNCTION fn_guard_withdrawn_cost_output();
ALTER TABLE stock_value_production_cost_outputs ENABLE ALWAYS TRIGGER stock_value_production_cost_outputs_immutable;

CREATE FUNCTION fn_check_withdrawn_cost_output() RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
    IF NEW.withdrawn_movement_id IS NULL THEN RETURN NULL; END IF;
    IF NOT fn_stock_value_stored_cost_reversible(NEW.source_node_id)
        OR NOT EXISTS(SELECT 1 FROM stock_value_events reversed
            JOIN stock_value_events original ON original.id=reversed.position_store_reversal_of
            JOIN stock_movements movement ON movement.id=reversed.movement_id
            WHERE reversed.operation='POSITION_STORE_REVERSE' AND reversed.movement_id=NEW.withdrawn_movement_id
                AND original.movement_id=NEW.movement_id AND original.result_node_id=NEW.source_node_id
                AND movement.direction=-1 AND movement.qty=NEW.qty_base AND movement.source_doc_type='SUBCONTRACT_RECEIPT') THEN
        RAISE EXCEPTION 'retired subcontract output requires the exact physical reversal after material-cost restoration' USING ERRCODE='23514';
    END IF;
    RETURN NULL;
END;
$$;
CREATE CONSTRAINT TRIGGER trg_withdrawn_cost_output AFTER INSERT OR UPDATE ON stock_value_production_cost_outputs
    DEFERRABLE INITIALLY DEFERRED FOR EACH ROW EXECUTE FUNCTION fn_check_withdrawn_cost_output();
ALTER TABLE stock_value_production_cost_outputs ENABLE ALWAYS TRIGGER trg_withdrawn_cost_output;

CREATE FUNCTION fn_check_subcontract_material_unconsume() RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
    IF NEW.source_doc_type<>'SUBCONTRACT_RECEIPT_MATERIAL_UNCONSUME' THEN RETURN NULL; END IF;
    IF NEW.operation<>'CONSUMPTION_RETURN' OR NOT EXISTS(
        SELECT 1 FROM subcontract_receipt_material_consumptions original
        JOIN subcontract_receipt_items item ON item.id=original.receipt_item_id
        JOIN subcontract_receipt_material_consumptions reversed ON reversed.reversal_of=original.id
        JOIN stock_value_events consumed ON consumed.source_item_id=original.id AND consumed.source_doc_type='SUBCONTRACT_CONSUMED_MATERIAL'
        JOIN stock_value_nodes restored ON restored.id=NEW.result_node_id
        WHERE original.id=NEW.source_item_id AND item.receipt_id=NEW.source_doc_id AND consumed.result_node_id=NEW.source_node_id
            AND reversed.qty_base=NEW.qty_base AND restored.owner_kind='SUBCONTRACT_WIP' AND restored.owner_id=original.id) THEN
        RAISE EXCEPTION 'subcontract material cost restoration must match the same actual receipt consumption reversal' USING ERRCODE='23514';
    END IF;
    RETURN NULL;
END;
$$;
CREATE CONSTRAINT TRIGGER trg_subcontract_material_unconsume AFTER INSERT ON stock_value_events
    DEFERRABLE INITIALLY DEFERRED FOR EACH ROW EXECUTE FUNCTION fn_check_subcontract_material_unconsume();
ALTER TABLE stock_value_events ENABLE ALWAYS TRIGGER trg_subcontract_material_unconsume;

-- A pending source may have a known amount of zero. The ledger intentionally
-- creates no zero postings; the same exact quantity and interval guards still apply.
DO $zero_known_return$
DECLARE definition TEXT;needle TEXT:='OR NOT EXISTS(SELECT 1 FROM stock_value_postings WHERE event_id=e.id';
BEGIN
    SELECT pg_get_functiondef('fn_assert_consumption_return(uuid)'::regprocedure) INTO definition;
    IF position(needle IN definition)=0 THEN RAISE EXCEPTION 'consumption return posting guard changed before V528'; END IF;
    EXECUTE replace(definition,needle,'OR expected<>0 AND NOT EXISTS(SELECT 1 FROM stock_value_postings WHERE event_id=e.id');
END;
$zero_known_return$;
