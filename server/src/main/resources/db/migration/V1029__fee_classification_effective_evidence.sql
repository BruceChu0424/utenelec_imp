-- V1020 has no forward dependency. This extension preserves original approved labels and projects current metadata separately.
CREATE VIEW v_finance_payable_statement_adjustment_parts_effective AS
 SELECT line.id AS line_id,line.category AS original_category,part.target_category AS category,
 part.source_category,part.amount_original,part.target_local AS amount_local,part.source_local,
 classified.source_classification_id,classified.target_classification_id,classified.id AS offset_classification_id,
 node.correction_id
 FROM finance_payable_statement_adjustment_lines line
 JOIN supplier_open_item_offsets actual ON actual.offset_batch_id=line.offset_batch_id AND actual.source_ledger_id=line.credit_ledger_id AND actual.target_ledger_id=line.target_ledger_id
 JOIN v_finance_supplier_offset_classification_current classified ON classified.offset_id=actual.id
 JOIN finance_supplier_offset_classification_parts part ON part.batch_id=classified.id
 LEFT JOIN finance_classification_correction_nodes node ON node.kind='AP_OFFSET' AND node.new_batch_id=classified.id
 WHERE line.decision='RELEASED';
CREATE FUNCTION fn_finance_fee_classification_correction_terminal() RETURNS trigger LANGUAGE plpgsql AS $$
DECLARE line record;parts record;
BEGIN
 FOR line IN SELECT DISTINCT l.* FROM finance_payable_statement_adjustment_lines l
 JOIN finance_classification_correction_nodes n ON n.kind='SOURCE' AND n.object_id IN(l.credit_ledger_id,l.target_ledger_id)
 WHERE n.correction_id=NEW.id AND l.decision='RELEASED' AND l.credit_ledger_id IS NOT NULL LOOP
 SELECT sum(amount_original) original,sum(amount_local) local INTO parts FROM v_finance_payable_statement_adjustment_parts_effective WHERE line_id=line.id;
 IF (parts.original,parts.local) IS DISTINCT FROM(line.amount_original,line.amount_local) THEN
 RAISE EXCEPTION 'Fee correction must preserve the original approved amount and its actual credit/offset effective parts' USING ERRCODE='23514';END IF;
 END LOOP;RETURN NULL;
END $$;
CREATE CONSTRAINT TRIGGER finance_fee_classification_correction_terminal AFTER INSERT OR UPDATE ON finance_classification_corrections DEFERRABLE INITIALLY DEFERRED FOR EACH ROW EXECUTE FUNCTION fn_finance_fee_classification_correction_terminal();
