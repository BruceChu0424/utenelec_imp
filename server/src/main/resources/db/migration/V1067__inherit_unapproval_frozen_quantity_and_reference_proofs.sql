-- A successor inherits an already adopted source. It is not a new calculation
-- under the reversing actor's unrelated precision selection.
ALTER TABLE document_unapprovals ADD COLUMN created_txid bigint;

CREATE FUNCTION fn_unapproval_source_profile(p_table text)
RETURNS TABLE(family text,header_table text,parent_column text)
LANGUAGE sql IMMUTABLE PARALLEL SAFE SET search_path=pg_catalog,public AS $$
 SELECT profile.family,profile.header_table,profile.parent_column
 FROM (VALUES
  ('purchase_order_items','purchaseOrder','purchase_orders','order_id'),
  ('purchase_receipt_items','purchaseReceipt','purchase_receipts','receipt_id'),
  ('purchase_return_items','purchaseReturn','purchase_returns','return_id'),
  ('subcontract_order_items','subcontractOrder','subcontract_orders','order_id'),
  ('subcontract_receipt_items','subcontractReceipt','subcontract_receipts','receipt_id'),
  ('subcontract_material_return_items','subcontractMaterialReturn','subcontract_material_returns','material_return_id')
 ) profile(item_table,family,header_table,parent_column) WHERE profile.item_table=p_table
$$;

DO $source_columns$ DECLARE target text; BEGIN
 FOREACH target IN ARRAY ARRAY['purchase_order_items','purchase_receipt_items','purchase_return_items',
   'subcontract_order_items','subcontract_receipt_items','subcontract_material_return_items'] LOOP
  EXECUTE format('ALTER TABLE public.%I ADD COLUMN unapproval_source_item_id uuid',target);
 END LOOP;
END $source_columns$;

CREATE FUNCTION fn_unapproval_originals_match(p_new jsonb,p_source jsonb,p_header boolean,p_initial boolean)
RETURNS boolean LANGUAGE plpgsql IMMUTABLE PARALLEL SAFE SET search_path=pg_catalog,public AS $$
DECLARE field text; fields text[];
BEGIN
 fields:=CASE WHEN p_header THEN ARRAY['bill_date','supplier_id','warehouse_id','currency_id','exchange_rate',
   'tax_rate','settlement_method_id','total_original','total_local','quantity_semantics','source_doc_no']
  ELSE ARRAY['goods_id','color_id','unit_id','unit_rate','qty','quantity_semantics','gift_qty',
   'order_item_id','receipt_item_id','material_issue_item_id','request_item_id','application_item_id',
   'parent_goods_id','parent_color_id'] END;
 IF NOT p_header AND p_initial THEN fields:=fields||ARRAY['line_no','bill_date','goods_code_snapshot','goods_name_snapshot',
   'goods_snapshot_source','parent_goods_code_snapshot','parent_goods_name_snapshot','parent_goods_snapshot_source',
   'price','total_amount_input','amount_original','amount_local','extra_columns','weight']; END IF;
 FOREACH field IN ARRAY fields LOOP
  IF p_new->field IS DISTINCT FROM p_source->field THEN RETURN FALSE; END IF;
 END LOOP;
 RETURN TRUE;
END $$;

CREATE FUNCTION fn_guard_unapproval_creation_proof() RETURNS trigger
LANGUAGE plpgsql SET search_path=pg_catalog,public AS $$
DECLARE profile record; old_status smallint; new_status smallint; count_entries bigint; count_values bigint;
BEGIN
 IF TG_OP<>'INSERT' THEN
  RAISE EXCEPTION 'document unapproval lineage is append-only' USING ERRCODE='23514'; END IF;
 IF NEW.created_txid IS NOT NULL THEN
  RAISE EXCEPTION 'unapproval transaction proof is database-owned' USING ERRCODE='55000'; END IF;
 IF jsonb_typeof(NEW.line_id_map) IS DISTINCT FROM 'object' OR EXISTS(
  SELECT 1 FROM jsonb_each(NEW.line_id_map) entry
  WHERE jsonb_typeof(entry.value)<>'string'
    OR entry.key !~ '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$'
    OR entry.value#>>'{}' !~ '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$'
 ) THEN RAISE EXCEPTION 'unapproval line map requires exact UUID identities' USING ERRCODE='23514'; END IF;
 SELECT count(*),count(DISTINCT value) INTO count_entries,count_values FROM jsonb_each_text(NEW.line_id_map);
 IF count_entries<>count_values THEN
  RAISE EXCEPTION 'unapproval line map cannot merge source identities' USING ERRCODE='23514'; END IF;
 SELECT p.* INTO profile FROM (VALUES('purchase_order_items'),('purchase_receipt_items'),('purchase_return_items'),
  ('subcontract_order_items'),('subcontract_receipt_items'),('subcontract_material_return_items')) owner(item_table)
  CROSS JOIN LATERAL fn_unapproval_source_profile(owner.item_table) p WHERE p.family=NEW.family;
 IF FOUND THEN
  EXECUTE format('SELECT status FROM public.%I WHERE id=$1 AND NOT is_deleted',profile.header_table)
   INTO old_status USING NEW.original_id;
  EXECUTE format('SELECT status FROM public.%I WHERE id=$1 AND NOT is_deleted',profile.header_table)
   INTO new_status USING NEW.draft_id;
  IF old_status IS DISTINCT FROM -1 OR new_status IS DISTINCT FROM 0
    OR fn_imported_business_document(profile.header_table,NEW.original_id) THEN
   RAISE EXCEPTION 'unapproval proof requires a mutable reversed original and draft successor' USING ERRCODE='23514'; END IF;
 END IF;
 NEW.created_txid:=txid_current();
 RETURN NEW;
END $$;
CREATE TRIGGER trg_00_unapproval_creation_proof BEFORE INSERT OR UPDATE ON document_unapprovals
 FOR EACH ROW EXECUTE FUNCTION fn_guard_unapproval_creation_proof();
ALTER TABLE document_unapprovals ENABLE ALWAYS TRIGGER trg_00_unapproval_creation_proof;

-- Shared identity proof only. Each owner still validates its own header, input
-- and frozen-field semantics before consuming the returned source generation.
CREATE FUNCTION fn_unapproval_lineage_source(p_family text,p_draft_id uuid,p_source_item_id uuid,
 p_new_item_id uuid,p_actor_id uuid,p_current_transaction boolean DEFAULT true)
RETURNS document_unapprovals LANGUAGE plpgsql VOLATILE SET search_path=pg_catalog,public AS $$
DECLARE lineage document_unapprovals%ROWTYPE;
BEGIN
 IF p_family IS NULL OR p_draft_id IS NULL OR p_source_item_id IS NULL OR p_new_item_id IS NULL THEN
  RAISE EXCEPTION 'unapproval source identities are incomplete' USING ERRCODE='55000'; END IF;
 SELECT * INTO lineage FROM public.document_unapprovals
  WHERE family=p_family AND draft_id=p_draft_id AND created_txid IS NOT NULL
    AND (NOT p_current_transaction OR created_txid=txid_current());
 IF NOT FOUND OR lineage.line_id_map->>p_source_item_id::text IS DISTINCT FROM p_new_item_id::text
   OR p_current_transaction AND (p_actor_id IS NULL OR lineage.created_by IS DISTINCT FROM p_actor_id) THEN
  RAISE EXCEPTION 'clone lacks its actual same-transaction source lineage' USING ERRCODE='55000'; END IF;
 RETURN lineage;
END $$;

CREATE FUNCTION fn_unapproval_source_item(p_table text,p_new jsonb,p_current_transaction boolean DEFAULT true)
RETURNS jsonb LANGUAGE plpgsql VOLATILE SET search_path=pg_catalog,public AS $$
DECLARE profile record; lineage document_unapprovals%ROWTYPE; source_row jsonb; old_header jsonb; new_header jsonb;
 source_id uuid; parent_id uuid;
BEGIN
 IF p_new->>'unapproval_source_item_id' IS NULL THEN RETURN NULL; END IF;
 SELECT * INTO profile FROM fn_unapproval_source_profile(p_table);
 IF NOT FOUND THEN RAISE EXCEPTION 'unsupported frozen unapproval owner' USING ERRCODE='55000'; END IF;
 source_id:=(p_new->>'unapproval_source_item_id')::uuid;
 parent_id:=(p_new->>profile.parent_column)::uuid;
 lineage:=fn_unapproval_lineage_source(profile.family,parent_id,source_id,(p_new->>'id')::uuid,
  (p_new->>'updated_by')::uuid,p_current_transaction);
 EXECUTE format('SELECT to_jsonb(item) FROM public.%I item WHERE id=$1 AND %I=$2',p_table,profile.parent_column)
  INTO source_row USING source_id,lineage.original_id;
 EXECUTE format('SELECT to_jsonb(header) FROM public.%I header WHERE id=$1 AND NOT is_deleted',profile.header_table)
  INTO old_header USING lineage.original_id;
 EXECUTE format('SELECT to_jsonb(header) FROM public.%I header WHERE id=$1 AND NOT is_deleted',profile.header_table)
  INTO new_header USING lineage.draft_id;
 IF source_row IS NULL OR old_header->>'status' IS DISTINCT FROM '-1' OR new_header IS NULL
   OR p_current_transaction AND new_header->>'status' IS DISTINCT FROM '0'
   OR p_current_transaction AND NOT fn_unapproval_originals_match(new_header,old_header,true,true)
   OR NOT fn_unapproval_originals_match(p_new,source_row,false,p_current_transaction)
   OR fn_imported_business_document(profile.header_table,lineage.original_id) THEN
  RAISE EXCEPTION 'quantity clone differs from its original identity or operands' USING ERRCODE='55000'; END IF;
 IF source_row->>'unit_id' IS NULL OR source_row->>'unit_rate' IS NULL
   OR (source_row->>'unit_rate')::numeric<=0 OR source_row->>'qty' IS NULL
   OR NOT fn_financial_amount_is_exact((source_row->>'qty')::numeric)
   OR NOT fn_financial_amount_is_exact((source_row->>'unit_rate')::numeric) THEN
  RAISE EXCEPTION 'original clone quantity lacks its real unit basis' USING ERRCODE='55000'; END IF;
 RETURN source_row;
END $$;

CREATE FUNCTION fn_unapproval_frozen_fields(p_table text,p_source jsonb)
RETURNS jsonb LANGUAGE plpgsql VOLATILE SET search_path=pg_catalog,public AS $$
DECLARE result jsonb:='{}'; field text; adopted numeric; facts bigint;
BEGIN
 IF p_source ? 'quantity_adoption_version' THEN
  IF (p_source->>'quantity_adoption_version')::integer NOT IN(1,2)
    OR p_source->>'quantity_adoption_version'='1' AND p_source->>'quantity_precision_policy' IS NOT NULL
    OR p_source->>'quantity_adoption_version'='2' AND NOT fn_procurement_reference_price_policy_valid(p_source->'quantity_precision_policy') THEN
   RAISE EXCEPTION 'original quantity adoption evidence is incomplete' USING ERRCODE='55000'; END IF;
  FOREACH field IN ARRAY ARRAY['quantity_adoption_version','quantity_precision_policy','charged_base_qty','gift_base_qty','quantity_source_proof'] LOOP
   IF p_source ? field THEN result:=result||jsonb_build_object(field,p_source->field); END IF;
  END LOOP;
  IF p_source ? 'adopted_base_qty' THEN
   adopted:=(p_source->>'adopted_base_qty')::numeric;
   IF adopted IS NULL AND p_source->>'quantity_adoption_version'='1' THEN
    IF p_table='subcontract_material_return_items' THEN
     SELECT count(*),sum(movement.qty) INTO facts,adopted FROM public.stock_movements movement
      JOIN public.subcontract_material_returns header ON header.id=movement.source_doc_id
      WHERE movement.source_doc_type='SUBCONTRACT_MATERIAL_RETURN' AND movement.movement_type=16 AND movement.direction=1
        AND movement.source_item_id=(p_source->>'id')::uuid AND movement.source_doc_id=(p_source->>'material_return_id')::uuid
        AND movement.goods_id=(p_source->>'goods_id')::uuid
        AND movement.color_id IS NOT DISTINCT FROM (p_source->>'color_id')::uuid AND movement.warehouse_id=header.warehouse_id;
    ELSIF p_table='subcontract_receipt_items' THEN
     SELECT count(*),sum(received_base_qty) INTO facts,adopted FROM public.procurement_inspection_items
      WHERE receipt_type='SUBCONTRACT' AND receipt_id=(p_source->>'receipt_id')::uuid AND receipt_item_id=(p_source->>'id')::uuid;
    END IF;
    IF facts IS DISTINCT FROM 1 THEN
     RAISE EXCEPTION 'legacy unapproval requires its actual original physical quantity evidence' USING ERRCODE='55000'; END IF;
   END IF;
   IF adopted IS NULL OR adopted<=0 OR NOT fn_financial_amount_is_exact(adopted) THEN
    RAISE EXCEPTION 'original adopted basic quantity is unavailable' USING ERRCODE='55000'; END IF;
   result:=result||jsonb_build_object('adopted_base_qty',adopted);
  END IF;
 END IF;
 IF p_source ? 'reference_price_precision_policy' THEN
  IF p_source->>'total_amount_input' IS NOT NULL AND (p_source->>'price')::numeric IS DISTINCT FROM
    fn_procurement_reference_price_proof((p_source->>'total_amount_input')::numeric,(p_source->>'qty')::numeric,p_source->'reference_price_precision_policy') THEN
   RAISE EXCEPTION 'original reference price proof is inconsistent' USING ERRCODE='55000'; END IF;
  result:=result||jsonb_build_object('reference_price_precision_policy',p_source->'reference_price_precision_policy');
 END IF;
 RETURN result;
END $$;

CREATE FUNCTION fn_guard_unapproval_source_item() RETURNS trigger
LANGUAGE plpgsql SET search_path=pg_catalog,public AS $$
DECLARE source_row jsonb; frozen jsonb; field text; current_row jsonb; original_changed boolean:=false;
BEGIN
 IF TG_OP='UPDATE' THEN
  IF NEW.unapproval_source_item_id IS DISTINCT FROM OLD.unapproval_source_item_id THEN
   RAISE EXCEPTION 'unapproval source identity cannot be replaced' USING ERRCODE='55000'; END IF;
  IF OLD.unapproval_source_item_id IS NOT NULL THEN
   FOREACH field IN ARRAY ARRAY['qty','unit_id','unit_rate','quantity_semantics','gift_qty'] LOOP
    IF to_jsonb(NEW)->field IS DISTINCT FROM to_jsonb(OLD)->field THEN original_changed:=true; END IF;
   END LOOP;
   IF NOT original_changed THEN
    FOREACH field IN ARRAY ARRAY['quantity_adoption_version','quantity_precision_policy','charged_base_qty',
      'gift_base_qty','adopted_base_qty','quantity_source_proof'] LOOP
     IF to_jsonb(NEW)->field IS DISTINCT FROM to_jsonb(OLD)->field THEN
      RAISE EXCEPTION 'inherited quantity adoption requires an actual operand edit' USING ERRCODE='55000'; END IF;
    END LOOP;
   END IF;
  END IF;
  RETURN NEW;
 END IF;
 source_row:=fn_unapproval_source_item(TG_TABLE_NAME,to_jsonb(NEW));
 IF source_row IS NULL THEN RETURN NEW; END IF;
 frozen:=fn_unapproval_frozen_fields(TG_TABLE_NAME,source_row);current_row:=to_jsonb(NEW);
 FOREACH field IN ARRAY ARRAY['quantity_precision_policy','quantity_source_proof','reference_price_precision_policy','adopted_base_qty'] LOOP
  IF current_row->>field IS NOT NULL AND current_row->field IS DISTINCT FROM frozen->field THEN
   RAISE EXCEPTION 'a clone cannot supply a different frozen adoption proof' USING ERRCODE='55000'; END IF;
 END LOOP;
 IF current_row ? 'quantity_adoption_version' AND current_row->>'quantity_adoption_version'<>'2'
   AND current_row->'quantity_adoption_version' IS DISTINCT FROM frozen->'quantity_adoption_version' THEN
  RAISE EXCEPTION 'a clone cannot choose its adoption version' USING ERRCODE='55000'; END IF;
 NEW:=jsonb_populate_record(NEW,frozen);
 RETURN NEW;
END $$;
DO $source_guards$ DECLARE target text; BEGIN
 FOREACH target IN ARRAY ARRAY['purchase_order_items','purchase_receipt_items','purchase_return_items',
   'subcontract_order_items','subcontract_receipt_items','subcontract_material_return_items'] LOOP
  EXECUTE format('CREATE TRIGGER trg_000_unapproval_source_item BEFORE INSERT OR UPDATE ON public.%I FOR EACH ROW EXECUTE FUNCTION fn_guard_unapproval_source_item()',target);
  EXECUTE format('ALTER TABLE public.%I ENABLE ALWAYS TRIGGER trg_000_unapproval_source_item',target);
 END LOOP;
END $source_guards$;

CREATE FUNCTION fn_validate_unapproval_source_completion() RETURNS trigger
LANGUAGE plpgsql SET search_path=pg_catalog,public AS $$
DECLARE profile record; entries bigint; originals bigint; successors bigint; inconsistent boolean;
BEGIN
 SELECT owner.item_table,p.* INTO profile FROM (VALUES('purchase_order_items'),('purchase_receipt_items'),('purchase_return_items'),
  ('subcontract_order_items'),('subcontract_receipt_items'),('subcontract_material_return_items')) owner(item_table)
  CROSS JOIN LATERAL fn_unapproval_source_profile(owner.item_table) p WHERE p.family=NEW.family;
 IF NOT FOUND THEN RETURN NULL; END IF;
 IF NEW.created_txid IS DISTINCT FROM txid_current() OR NOT EXISTS(
  SELECT 1 FROM public.document_unapprovals WHERE id=NEW.id AND created_txid=NEW.created_txid) THEN
  RAISE EXCEPTION 'unapproval source lineage did not complete in its creation transaction' USING ERRCODE='23514'; END IF;
 SELECT count(*) INTO entries FROM jsonb_each(NEW.line_id_map);
 EXECUTE format('SELECT count(*) FROM public.%I WHERE %I=$1',profile.item_table,profile.parent_column)
  INTO originals USING NEW.original_id;
 EXECUTE format('SELECT count(*) FROM public.%I WHERE %I=$1',profile.item_table,profile.parent_column)
  INTO successors USING NEW.draft_id;
 IF entries<>originals OR entries<>successors THEN
  RAISE EXCEPTION 'unapproval source line map is incomplete' USING ERRCODE='23514'; END IF;
 EXECUTE format($query$
  SELECT EXISTS(SELECT 1 FROM public.%I source
   LEFT JOIN public.%I draft ON draft.id=CAST($1->>source.id::text AS uuid)
   WHERE source.%I=$2 AND (draft.id IS NULL OR draft.%I IS DISTINCT FROM $3
     OR draft.unapproval_source_item_id IS DISTINCT FROM source.id
     OR NOT fn_unapproval_originals_match(to_jsonb(draft),to_jsonb(source),false,true)
     OR NOT to_jsonb(draft) @> fn_unapproval_frozen_fields($4,to_jsonb(source))))
 $query$,profile.item_table,profile.item_table,profile.parent_column,profile.parent_column)
 INTO inconsistent USING NEW.line_id_map,NEW.original_id,NEW.draft_id,profile.item_table;
 IF inconsistent THEN
  RAISE EXCEPTION 'unapproval successor does not retain its complete original frozen facts' USING ERRCODE='23514'; END IF;
 RETURN NULL;
END $$;
CREATE CONSTRAINT TRIGGER document_unapproval_frozen_source_complete AFTER INSERT ON document_unapprovals
 DEFERRABLE INITIALLY DEFERRED FOR EACH ROW EXECUTE FUNCTION fn_validate_unapproval_source_completion();
ALTER TABLE document_unapprovals ENABLE ALWAYS TRIGGER document_unapproval_frozen_source_complete;

DO $inherit_guards$
DECLARE definition text; anchor text; replacement text;
BEGIN
 definition:=pg_get_functiondef('fn_guard_document_quantity_adoption()'::regprocedure);
 anchor:='BEGIN
 IF TG_OP=''INSERT'' THEN';
 IF (length(definition)-length(replace(definition,anchor,'')))/length(anchor)<>1 THEN
  RAISE EXCEPTION 'V1067 quantity adoption entry anchor differs'; END IF;
 replacement:='BEGIN
 IF TG_OP=''INSERT'' AND to_jsonb(NEW)->>''unapproval_source_item_id'' IS NOT NULL THEN
  RETURN jsonb_populate_record(NEW,fn_unapproval_frozen_fields(TG_TABLE_NAME,
    fn_unapproval_source_item(TG_TABLE_NAME,to_jsonb(NEW))));
 END IF;
 IF TG_OP=''INSERT'' THEN';
 EXECUTE replace(definition,anchor,replacement);

 definition:=pg_get_functiondef('fn_guard_procurement_reference_price_policy()'::regprocedure);
 anchor:='BEGIN
 IF TG_TABLE_NAME NOT IN(''purchase_order_items'',''subcontract_order_items'') THEN';
 IF (length(definition)-length(replace(definition,anchor,'')))/length(anchor)<>1 THEN
  RAISE EXCEPTION 'V1067 reference price entry anchor differs'; END IF;
 replacement:='BEGIN
 IF TG_OP=''INSERT'' AND to_jsonb(NEW)->>''unapproval_source_item_id'' IS NOT NULL THEN
  RETURN jsonb_populate_record(NEW,fn_unapproval_frozen_fields(TG_TABLE_NAME,
    fn_unapproval_source_item(TG_TABLE_NAME,to_jsonb(NEW))));
 END IF;
 IF TG_TABLE_NAME NOT IN(''purchase_order_items'',''subcontract_order_items'') THEN';
 EXECUTE replace(definition,anchor,replacement);

 definition:=pg_get_functiondef('fn_validate_receipt_weight_adoption()'::regprocedure);
 anchor:='BEGIN
 IF NEW.weight IS NULL';
 IF (length(definition)-length(replace(definition,anchor,'')))/length(anchor)<>1 THEN
  RAISE EXCEPTION 'V1067 inherited receipt weight entry anchor differs'; END IF;
 replacement:='BEGIN
 IF TG_OP=''INSERT'' AND to_jsonb(NEW)->>''unapproval_source_item_id'' IS NOT NULL THEN
  PERFORM fn_unapproval_source_item(TG_TABLE_NAME,to_jsonb(NEW));
  RETURN NULL;
 END IF;
 IF NEW.weight IS NULL';
 EXECUTE replace(definition,anchor,replacement);

 definition:=pg_get_functiondef('fn_document_material_return_base(subcontract_material_return_items)'::regprocedure);
 anchor:='DECLARE expected numeric;';
 IF (length(definition)-length(replace(definition,anchor,'')))/length(anchor)<>1 THEN
  RAISE EXCEPTION 'V1067 inherited material return declaration differs'; END IF;
 definition:=replace(definition,anchor,'DECLARE expected numeric; original jsonb; inherited jsonb;');
 anchor:=' IF item.quantity_adoption_version=1 AND item.quantity_precision_policy IS NULL THEN';
 IF (length(definition)-length(replace(definition,anchor,'')))/length(anchor)<>1 THEN
  RAISE EXCEPTION 'V1067 inherited legacy material return anchor differs'; END IF;
 replacement:=' IF item.unapproval_source_item_id IS NOT NULL AND item.quantity_adoption_version=1 AND item.quantity_precision_policy IS NULL THEN
  original:=fn_unapproval_source_item(''subcontract_material_return_items'',to_jsonb(item),false);
  inherited:=fn_unapproval_frozen_fields(''subcontract_material_return_items'',original);
  IF item.adopted_base_qty IS DISTINCT FROM (inherited->>''adopted_base_qty'')::numeric
    OR item.quantity_adoption_version IS DISTINCT FROM (inherited->>''quantity_adoption_version'')::smallint
    OR item.quantity_precision_policy IS DISTINCT FROM NULLIF(inherited->''quantity_precision_policy'',''null''::jsonb) THEN
   RAISE EXCEPTION ''inherited material return no longer matches its actual original adoption'' USING ERRCODE=''23514'';
  END IF;
  RETURN item.adopted_base_qty;
 END IF;
 IF item.quantity_adoption_version=1 AND item.quantity_precision_policy IS NULL THEN';
 EXECUTE replace(definition,anchor,replacement);
END $inherit_guards$;
