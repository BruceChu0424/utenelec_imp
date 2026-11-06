-- A verified first historical import is not a new native quantity/weight adoption.
-- Keep its original unknown bases and units; do not apply today's precision policy.
-- V1033/V1034 and all original provenance/immutable guards retain their bytes.
CREATE FUNCTION public.fn_accept_verified_legacy_quantity_adoption(p_table text,p_row jsonb,p_phase text)
RETURNS boolean LANGUAGE plpgsql SET search_path=pg_catalog,public AS $$
DECLARE run uuid; source_file text;
BEGIN
 IF p_phase IS NULL OR p_phase NOT IN ('QUANTITY','WEIGHT') THEN
  RAISE EXCEPTION 'unsupported verified historical adoption phase' USING ERRCODE='23514';
 END IF;
 IF p_table IN ('purchase_receipt_items','subcontract_receipt_items') THEN
  IF p_row->>'legacy_import_run_id' IS NULL THEN
   IF p_row->>'legacy_id' IS NOT NULL THEN RAISE EXCEPTION 'historical quantity insert requires exact registered source proof' USING ERRCODE='23514'; END IF;
   RETURN false;
  END IF;
  IF (p_phase='QUANTITY' AND p_row->>'quantity_adoption_version' IS DISTINCT FROM '2')
     OR (p_phase='WEIGHT' AND p_row->>'quantity_adoption_version' IS DISTINCT FROM '1') THEN
   RAISE EXCEPTION 'verified historical receipts require initial version two and adopted weight version one' USING ERRCODE='23514';
  END IF;
  run:=(p_row->>'legacy_import_run_id')::uuid;
  source_file:=CASE p_table WHEN 'purchase_receipt_items' THEN 'purchase_receipt_items.csv' ELSE 'subcontract_in_i.csv' END;
  PERFORM public.fn_require_legacy_bootstrap(run,source_file);
  PERFORM public.fn_assert_legacy_receipt_import_source(p_table,p_row);
 ELSIF p_table='purchase_order_items' THEN
  IF p_phase<>'QUANTITY' THEN RETURN false; END IF;
  IF p_row->>'legacy_counter_import_run_id' IS NULL THEN
   IF p_row->>'legacy_id' IS NOT NULL THEN RAISE EXCEPTION 'historical quantity insert requires exact registered source proof' USING ERRCODE='23514'; END IF;
   RETURN false;
  END IF;
  run:=(p_row->>'legacy_counter_import_run_id')::uuid;
  PERFORM public.fn_require_legacy_bootstrap(run,'purchase_order_items.csv');
  PERFORM public.fn_assert_legacy_quantity_counter_source(p_table,p_row);
 ELSE
  RETURN false;
 END IF;
 IF (p_row->>'legacy_id')::integer IS NULL OR (p_row->>'legacy_id')::integer<=0
    OR p_row->>'quantity_adoption_version' IS NULL OR p_row->>'quantity_adoption_version' NOT IN ('1','2')
    OR p_row->>'quantity_precision_policy' IS NOT NULL OR p_row->>'quantity_source_proof' IS NOT NULL
    OR p_row->>'charged_base_qty' IS NOT NULL OR p_row->>'gift_base_qty' IS NOT NULL
    OR p_row->>'adopted_base_qty' IS NOT NULL
    OR (p_row ? 'quantity_semantics' AND p_row->>'quantity_semantics' IS DISTINCT FROM 'LEGACY_RECORDED')
    OR p_row->>'gift_replacement_intent' IS NOT NULL OR p_row->>'finance_approval_case_id' IS NOT NULL
    OR (p_row ? 'gift_returned_qty' AND (p_row->>'gift_returned_qty')::numeric IS DISTINCT FROM 0::numeric)
    OR (p_row ? 'is_deleted' AND p_row->>'is_deleted' IS DISTINCT FROM 'false') THEN
  RAISE EXCEPTION 'verified historical quantities cannot carry new adoption, gift or precision facts' USING ERRCODE='23514';
 END IF;
 RETURN true;
END $$;

DO $quantity_guard$
DECLARE definition text; anchor text:=E' IF TG_OP=''INSERT'' THEN'; replacement text; main_legacy text:=$main_legacy$ IF TG_OP='INSERT' AND TG_TABLE_NAME IN('purchase_receipt_items','subcontract_receipt_items')
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
$main_legacy$;
BEGIN
 definition:=pg_get_functiondef('public.fn_guard_document_quantity_adoption()'::regprocedure);
 IF (length(definition)-length(replace(definition,main_legacy,'')))/length(main_legacy)<>1 THEN
  RAISE EXCEPTION 'Review changed Main1076 historical quantity_guard entry before unifying the verified helper';
 END IF;
 definition:=replace(definition,main_legacy,'');
 IF (length(definition)-length(replace(definition,anchor,'')))/length(anchor)<>1 THEN
  RAISE EXCEPTION 'Review changed native quantity adoption guard before adding verified historical inserts';
 END IF;
 replacement:=E' IF TG_OP=''INSERT'' AND TG_TABLE_SCHEMA=''public''\n'
  ||E'    AND (NEW.legacy_id IS NOT NULL OR to_jsonb(NEW)->>''legacy_import_run_id'' IS NOT NULL\n'
  ||E'         OR to_jsonb(NEW)->>''legacy_counter_import_run_id'' IS NOT NULL)\n'
  ||E'    AND public.fn_accept_verified_legacy_quantity_adoption(TG_TABLE_NAME,to_jsonb(NEW),''QUANTITY'') THEN\n'
  ||E'  NEW.quantity_adoption_version:=1; NEW.quantity_precision_policy:=NULL; RETURN NEW;\n END IF;\n IF TG_OP=''INSERT'' THEN';
 EXECUTE replace(definition,anchor,replacement);
END $quantity_guard$;

-- The same exact row proof binds the original weight, including NULL and every
-- recorded digit. It does not fabricate a current same-action weight choice.
DO $weight_guard$
DECLARE definition text; anchor text:=E' IF NEW.weight IS NULL'; replacement text; main_legacy text:=$main_legacy$ IF TG_OP='INSERT' AND TG_TABLE_NAME IN('purchase_receipt_items','subcontract_receipt_items')
    AND (to_jsonb(NEW)->>'legacy_id' IS NOT NULL OR to_jsonb(NEW)->>'legacy_import_run_id' IS NOT NULL) THEN
  PERFORM public.fn_assert_legacy_receipt_import_source(TG_TABLE_NAME,to_jsonb(NEW));
  RETURN NULL;
 END IF;
$main_legacy$;
BEGIN
 definition:=pg_get_functiondef('public.fn_validate_receipt_weight_adoption()'::regprocedure);
 IF (length(definition)-length(replace(definition,main_legacy,'')))/length(main_legacy)<>1 THEN
  RAISE EXCEPTION 'Review changed Main1076 historical weight_guard entry before unifying the verified helper';
 END IF;
 definition:=replace(definition,main_legacy,'');
 IF (length(definition)-length(replace(definition,anchor,'')))/length(anchor)<>1 THEN
  RAISE EXCEPTION 'Review changed receipt weight adoption guard before adding verified historical inserts';
 END IF;
 replacement:=E' IF TG_OP=''INSERT'' AND TG_TABLE_SCHEMA=''public'' AND NEW.quantity_adoption_version=1\n'
  ||E'    AND public.fn_accept_verified_legacy_quantity_adoption(TG_TABLE_NAME,to_jsonb(NEW),''WEIGHT'') THEN RETURN NULL; END IF;\n IF NEW.weight IS NULL';
 EXECUTE replace(definition,anchor,replacement);
END $weight_guard$;
