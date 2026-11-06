-- Main V1067 owns the only source/actor/transaction/line-map proof.
-- Extend that owner for sales returns and complete initial physical facts.
-- No second source column or transaction identity is created.
CREATE FUNCTION fn_unapproval_source_profiles()
RETURNS TABLE(item_table text,family text,header_table text,parent_column text)
LANGUAGE sql IMMUTABLE PARALLEL SAFE SET search_path=pg_catalog,public AS $$
 SELECT * FROM (VALUES
  ('purchase_order_items','purchaseOrder','purchase_orders','order_id'),
  ('purchase_receipt_items','purchaseReceipt','purchase_receipts','receipt_id'),
  ('purchase_return_items','purchaseReturn','purchase_returns','return_id'),
  ('subcontract_order_items','subcontractOrder','subcontract_orders','order_id'),
  ('subcontract_receipt_items','subcontractReceipt','subcontract_receipts','receipt_id'),
  ('subcontract_material_return_items','subcontractMaterialReturn','subcontract_material_returns','material_return_id'),
  ('sales_return_items','salesReturn','sales_returns','return_id')
 ) profile(item_table,family,header_table,parent_column)
$$;
CREATE OR REPLACE FUNCTION fn_unapproval_source_profile(p_table text)
RETURNS TABLE(family text,header_table text,parent_column text)
LANGUAGE sql IMMUTABLE PARALLEL SAFE SET search_path=pg_catalog,public AS $$
 SELECT profile.family,profile.header_table,profile.parent_column
 FROM fn_unapproval_source_profiles() profile WHERE profile.item_table=p_table
$$;
ALTER TABLE sales_return_items ADD COLUMN unapproval_source_item_id uuid;

DO $share_unapproval_profiles$
DECLARE definition text;anchor text;
BEGIN
 definition:=pg_get_functiondef('fn_guard_unapproval_creation_proof()'::regprocedure);
 anchor:=$old$SELECT p.* INTO profile FROM (VALUES('purchase_order_items'),('purchase_receipt_items'),('purchase_return_items'),
  ('subcontract_order_items'),('subcontract_receipt_items'),('subcontract_material_return_items')) owner(item_table)
  CROSS JOIN LATERAL fn_unapproval_source_profile(owner.item_table) p WHERE p.family=NEW.family;$old$;
 IF (length(definition)-length(replace(definition,anchor,'')))/length(anchor)<>1 THEN
  RAISE EXCEPTION 'Main unapproval creation profile anchor differs'; END IF;
 EXECUTE replace(definition,anchor,'SELECT p.family,p.header_table,p.parent_column INTO profile FROM fn_unapproval_source_profiles() p WHERE p.family=NEW.family;');
 definition:=pg_get_functiondef('fn_validate_unapproval_source_completion()'::regprocedure);
 anchor:=$old$SELECT owner.item_table,p.* INTO profile FROM (VALUES('purchase_order_items'),('purchase_receipt_items'),('purchase_return_items'),
  ('subcontract_order_items'),('subcontract_receipt_items'),('subcontract_material_return_items')) owner(item_table)
  CROSS JOIN LATERAL fn_unapproval_source_profile(owner.item_table) p WHERE p.family=NEW.family;$old$;
 IF (length(definition)-length(replace(definition,anchor,'')))/length(anchor)<>1 THEN
  RAISE EXCEPTION 'Main unapproval completion profile anchor differs'; END IF;
 EXECUTE replace(definition,anchor,'SELECT p.* INTO profile FROM fn_unapproval_source_profiles() p WHERE p.family=NEW.family;');
END $share_unapproval_profiles$;

-- These seven reviewed item tables all have a NOT NULL is_deleted column.
-- Their Java snapshots plan/copy active lines; completion consumes that exact
-- set and still rejects a clone deleted in its initial assembly transaction.
DO $complete_active_unapproval_lines$
DECLARE definition text;anchor text;
BEGIN
 definition:=pg_get_functiondef('fn_validate_unapproval_source_completion()'::regprocedure);
 anchor:=$old$SELECT count(*) FROM public.%I WHERE %I=$1$old$;
 IF (length(definition)-length(replace(definition,anchor,'')))/length(anchor)<>2 THEN
  RAISE EXCEPTION 'Main unapproval original/successor count anchors differ'; END IF;
 definition:=replace(definition,anchor,anchor||' AND NOT is_deleted');
 anchor:=$old$WHERE source.%I=$2 AND (draft.id IS NULL OR draft.%I IS DISTINCT FROM $3$old$;
 IF (length(definition)-length(replace(definition,anchor,'')))/length(anchor)<>1 THEN
  RAISE EXCEPTION 'Main unapproval complete source set anchor differs'; END IF;
 EXECUTE replace(definition,anchor,$new$WHERE source.%I=$2 AND NOT source.is_deleted
    AND (draft.id IS NULL OR draft.is_deleted OR draft.%I IS DISTINCT FROM $3$new$);
END $complete_active_unapproval_lines$;

-- All candidate initial fields remain covered by the existing complete-map
-- commit validator and by the same-transaction update guard.
DO $complete_unapproval_initial_fields$
DECLARE definition text;anchor text;
BEGIN
 definition:=pg_get_functiondef('fn_unapproval_originals_match(jsonb,jsonb,boolean,boolean)'::regprocedure);
 anchor:=$old$fields:=CASE WHEN p_header THEN ARRAY['bill_date','supplier_id','warehouse_id','currency_id','exchange_rate',$old$;
 IF (length(definition)-length(replace(definition,anchor,'')))/length(anchor)<>1 THEN
  RAISE EXCEPTION 'Main unapproval header fields anchor differs'; END IF;
 definition:=replace(definition,anchor,$new$fields:=CASE WHEN p_header THEN ARRAY['bill_date','supplier_id','client_id','warehouse_id','currency_id','exchange_rate',$new$);
 anchor:=$old$'parent_goods_id','parent_color_id'] END;$old$;
 IF (length(definition)-length(replace(definition,anchor,'')))/length(anchor)<>1 THEN
  RAISE EXCEPTION 'Main unapproval source fields anchor differs'; END IF;
 definition:=replace(definition,anchor,$new$'parent_goods_id','parent_color_id','out_item_id','is_deleted'] END;$new$);
 anchor:=$old$'price','total_amount_input','amount_original','amount_local','extra_columns','weight']; END IF;$old$;
 IF (length(definition)-length(replace(definition,anchor,'')))/length(anchor)<>1 THEN
  RAISE EXCEPTION 'Main unapproval initial fields anchor differs'; END IF;
 definition:=replace(definition,anchor,$new$'price','total_amount_input','amount_original','amount_local','extra_columns','weight',
   'replacement_intent','gift_replacement_intent','cost_amount']; END IF;$new$);
 EXECUTE definition;
END $complete_unapproval_initial_fields$;

DO $require_live_unapproval_source_line$
DECLARE definition text;anchor text;
BEGIN
 definition:=pg_get_functiondef('fn_unapproval_source_item(text,jsonb,boolean)'::regprocedure);
 anchor:=$old$IF source_row IS NULL OR old_header->>'status' IS DISTINCT FROM '-1' OR new_header IS NULL$old$;
 IF (length(definition)-length(replace(definition,anchor,'')))/length(anchor)<>1 THEN
  RAISE EXCEPTION 'Main unapproval live source anchor differs'; END IF;
 EXECUTE replace(definition,anchor,$new$IF source_row IS NULL OR (source_row->>'is_deleted')::boolean IS DISTINCT FROM false
   OR (p_new->>'is_deleted')::boolean IS DISTINCT FROM false
   OR old_header->>'status' IS DISTINCT FROM '-1' OR new_header IS NULL$new$);
END $require_live_unapproval_source_line$;

-- V1033 retains genuine pre-adoption facts as version 1. Copying a proved
-- reversed native snapshot is not a new quantity conversion. For the three
-- purchase owners only, retain a genuinely NULL original unit/rate pair;
-- public save still requires explicit repair before any new v2 adoption.
-- The preceding Main source/actor/transaction/line-map/live/nonimported checks
-- remain mandatory, and original-input equality retains both NULLs exactly.
DO $retain_proved_v1_unknown_purchase_basis$
DECLARE definition text;anchor text;
BEGIN
 definition:=pg_get_functiondef('fn_unapproval_source_item(text,jsonb,boolean)'::regprocedure);
 anchor:=$old$IF source_row->>'unit_id' IS NULL OR source_row->>'unit_rate' IS NULL
   OR (source_row->>'unit_rate')::numeric<=0 OR source_row->>'qty' IS NULL
   OR NOT fn_financial_amount_is_exact((source_row->>'qty')::numeric)
   OR NOT fn_financial_amount_is_exact((source_row->>'unit_rate')::numeric) THEN$old$;
 IF (length(definition)-length(replace(definition,anchor,'')))/length(anchor)<>1 THEN
  RAISE EXCEPTION 'Main proved source basis guard differs'; END IF;
 EXECUTE replace(definition,anchor,$new$IF source_row->>'qty' IS NULL OR NOT fn_financial_amount_is_exact((source_row->>'qty')::numeric)
   OR (p_table IN('purchase_order_items','purchase_receipt_items','purchase_return_items')
    AND source_row->>'quantity_adoption_version'='1' AND source_row->>'quantity_precision_policy' IS NULL
    AND source_row->>'unit_id' IS NULL AND source_row->>'unit_rate' IS NULL) IS NOT TRUE
    AND (source_row->>'unit_id' IS NULL OR source_row->>'unit_rate' IS NULL
     OR (source_row->>'unit_rate')::numeric<=0 OR NOT fn_financial_amount_is_exact((source_row->>'unit_rate')::numeric)) THEN$new$);
END $retain_proved_v1_unknown_purchase_basis$;

DO $inherit_sales_return_physical_facts$
DECLARE definition text;anchor text;
BEGIN
 definition:=pg_get_functiondef('fn_unapproval_frozen_fields(text,jsonb)'::regprocedure);
 anchor:=$old$RETURN result;$old$;
 IF (length(definition)-length(replace(definition,anchor,'')))/length(anchor)<>1
  OR strpos(definition,'fn_procurement_reference_price_matches(p_source)')=0 THEN
  RAISE EXCEPTION 'Review shared frozen source facts before sales return extension'; END IF;
 EXECUTE replace(definition,anchor,$new$IF p_table='sales_return_items' THEN
  IF (p_source->>'receipt_quantity_version')::integer NOT IN(1,2)
   OR p_source->>'receipt_base_qty' IS NOT NULL AND
    ((p_source->>'receipt_base_qty')::numeric<=0 OR NOT fn_financial_amount_is_exact((p_source->>'receipt_base_qty')::numeric)
     OR p_source->>'receipt_quantity_version'<>'2' OR p_source->>'receipt_quantity_proof' IS NULL)
   OR (p_source->>'receipt_base_qty' IS NULL) IS DISTINCT FROM (p_source->>'receipt_quantity_proof' IS NULL) THEN
   RAISE EXCEPTION 'original sales return physical quantity proof is incomplete' USING ERRCODE='55000'; END IF;
  result:=result||jsonb_build_object('receipt_quantity_version',p_source->'receipt_quantity_version',
   'receipt_base_qty',p_source->'receipt_base_qty','receipt_quantity_proof',p_source->'receipt_quantity_proof');
 END IF;
 RETURN result;$new$);
 definition:=pg_get_functiondef('fn_guard_sales_return_quantity_adoption()'::regprocedure);
 anchor:=$old$BEGIN
 IF TG_OP='INSERT' THEN$old$;
 IF (length(definition)-length(replace(definition,anchor,'')))/length(anchor)<>1 THEN
  RAISE EXCEPTION 'Sales return physical adoption entry differs'; END IF;
 EXECUTE replace(definition,anchor,$new$BEGIN
 IF TG_OP='INSERT' AND NEW.unapproval_source_item_id IS NOT NULL THEN
  RETURN jsonb_populate_record(NEW,fn_unapproval_frozen_fields(TG_TABLE_NAME,
   fn_unapproval_source_item(TG_TABLE_NAME,to_jsonb(NEW))));
 END IF;
 IF TG_OP='INSERT' THEN$new$);
END $inherit_sales_return_physical_facts$;

DO $guard_initial_unapproval_assembly$
DECLARE definition text;anchor text;
BEGIN
 definition:=pg_get_functiondef('fn_guard_unapproval_source_item()'::regprocedure);
 anchor:=$old$IF OLD.unapproval_source_item_id IS NOT NULL THEN
   FOREACH field$old$;
 IF (length(definition)-length(replace(definition,anchor,'')))/length(anchor)<>1 THEN
  RAISE EXCEPTION 'Main inherited source update anchor differs'; END IF;
 EXECUTE replace(definition,anchor,$new$IF OLD.unapproval_source_item_id IS NOT NULL THEN
   IF NEW.id IS DISTINCT FROM OLD.id THEN
    RAISE EXCEPTION 'saved unapproval successor line identity is immutable' USING ERRCODE='55000'; END IF;
   IF EXISTS(SELECT 1 FROM document_unapprovals lineage
    JOIN fn_unapproval_source_profile(TG_TABLE_NAME) profile ON profile.family=lineage.family
    WHERE lineage.draft_id=(to_jsonb(OLD)->>profile.parent_column)::uuid AND lineage.created_txid=txid_current()) THEN
    IF NOT fn_unapproval_originals_match(to_jsonb(NEW),to_jsonb(OLD),false,true) THEN
     RAISE EXCEPTION 'initial successor copy inputs cannot change in its assembly transaction' USING ERRCODE='23514'; END IF;
    FOREACH field IN ARRAY ARRAY['quantity_adoption_version','quantity_precision_policy','charged_base_qty','gift_base_qty',
     'adopted_base_qty','quantity_source_proof','reference_price_precision_policy','receipt_quantity_version','receipt_base_qty','receipt_quantity_proof'] LOOP
     IF to_jsonb(NEW)->field IS DISTINCT FROM to_jsonb(OLD)->field THEN
      RAISE EXCEPTION 'initial successor frozen facts cannot change in its assembly transaction' USING ERRCODE='23514'; END IF;
    END LOOP;
   END IF;
   FOREACH field$new$);
END $guard_initial_unapproval_assembly$;

CREATE TRIGGER trg_000_unapproval_source_item BEFORE INSERT OR UPDATE ON sales_return_items
 FOR EACH ROW EXECUTE FUNCTION fn_guard_unapproval_source_item();
ALTER TABLE sales_return_items ENABLE ALWAYS TRIGGER trg_000_unapproval_source_item;
