-- A source-verified historical receipt is recorded history, not a new native
-- quantity adoption. Require the existing same-transaction source authority
-- before retaining that lane; neither a legacy marker nor replica mode grants it.
DO $migration$
DECLARE
    v_definition TEXT;
    v_anchor TEXT := $anchor$ IF TG_OP='INSERT' THEN$anchor$;
    v_legacy_entry TEXT := $entry$ IF TG_OP='INSERT' AND TG_TABLE_NAME IN('purchase_receipt_items','subcontract_receipt_items')
    AND (to_jsonb(NEW)->>'legacy_id' IS NOT NULL OR to_jsonb(NEW)->>'legacy_import_run_id' IS NOT NULL) THEN
  PERFORM public.fn_assert_legacy_receipt_import_source(TG_TABLE_NAME,to_jsonb(NEW));
  IF NEW.quantity_adoption_version IS DISTINCT FROM 2 OR NEW.quantity_precision_policy IS NOT NULL
     OR TG_TABLE_NAME='purchase_receipt_items' AND (
       to_jsonb(NEW)->>'quantity_semantics' IS DISTINCT FROM 'LEGACY_RECORDED'
       OR to_jsonb(NEW)->>'charged_base_qty' IS NOT NULL OR to_jsonb(NEW)->>'gift_base_qty' IS NOT NULL)
     OR TG_TABLE_NAME='subcontract_receipt_items' AND to_jsonb(NEW)->>'adopted_base_qty' IS NOT NULL THEN
   RAISE EXCEPTION 'historical receipt cannot supply a new quantity adoption or invented derived values' USING ERRCODE='23514';
  END IF;
  NEW.quantity_adoption_version:=1;
  NEW.quantity_precision_policy:=NULL;
  RETURN NEW;
 END IF;
$entry$;
BEGIN
    v_definition := pg_get_functiondef('public.fn_guard_document_quantity_adoption()'::regprocedure);
    IF (length(v_definition)-length(replace(v_definition,v_anchor,'')))/length(v_anchor)<>1 THEN
        RAISE EXCEPTION 'quantity adoption native entry differs from the reviewed source';
    END IF;
    -- V1067's frozen unapproval branch precedes this native entry and stays
    -- byte-for-byte unchanged, as do the complete native calculation and guards.
    EXECUTE replace(v_definition,v_anchor,v_legacy_entry||v_anchor);

    v_definition := pg_get_functiondef('public.fn_validate_receipt_weight_adoption()'::regprocedure);
    v_anchor := ' IF NEW.weight IS NULL';
    v_legacy_entry := $entry$ IF TG_OP='INSERT' AND TG_TABLE_NAME IN('purchase_receipt_items','subcontract_receipt_items')
    AND (to_jsonb(NEW)->>'legacy_id' IS NOT NULL OR to_jsonb(NEW)->>'legacy_import_run_id' IS NOT NULL) THEN
  PERFORM public.fn_assert_legacy_receipt_import_source(TG_TABLE_NAME,to_jsonb(NEW));
  RETURN NULL;
 END IF;
$entry$;
    IF (length(v_definition)-length(replace(v_definition,v_anchor,'')))/length(v_anchor)<>1 THEN
        RAISE EXCEPTION 'receipt weight input entry differs from the reviewed source';
    END IF;
    -- The source CSV weight remains its recorded historical fact. Inventing a
    -- modern user input, unit conversion or precision evidence would change it.
    EXECUTE replace(v_definition,v_anchor,v_legacy_entry||v_anchor);
END
$migration$;
