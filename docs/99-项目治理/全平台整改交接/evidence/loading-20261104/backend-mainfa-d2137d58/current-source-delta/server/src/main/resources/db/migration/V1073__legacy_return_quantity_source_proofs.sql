-- The two remaining legacy loaders now register every original CSV row in the
-- existing immutable exact-source registry before its first insert. No new
-- business quantity, unit, base adoption, precision policy or usable capacity
-- is manufactured. Their original native write/ledger guards remain enabled.
ALTER TABLE public.purchase_return_items ADD COLUMN legacy_counter_import_run_id uuid;
ALTER TABLE public.subcontract_material_return_items ADD COLUMN legacy_counter_import_run_id uuid;
ALTER TABLE public.purchase_return_items ADD CONSTRAINT purchase_return_items_counter_import_fk
 FOREIGN KEY(legacy_counter_import_run_id,id) REFERENCES public.legacy_quantity_counter_import_sources(run_id,target_id) ON DELETE RESTRICT;
ALTER TABLE public.subcontract_material_return_items ADD CONSTRAINT subcontract_material_return_items_counter_import_fk
 FOREIGN KEY(legacy_counter_import_run_id,id) REFERENCES public.legacy_quantity_counter_import_sources(run_id,target_id) ON DELETE RESTRICT;

CREATE OR REPLACE FUNCTION public.fn_legacy_quantity_counter_kind(p_kind text)
RETURNS TABLE(target_table text,source_file text,source_keys text[])
LANGUAGE sql IMMUTABLE SET search_path=pg_catalog,public,pg_temp AS $$
    SELECT table_name,file_name,string_to_array(keys,',') FROM (VALUES
      ('PURCHASE_ORDER_ITEM','purchase_order_items','purchase_order_items.csv','amount_original,bill_legacy_id,color_legacy_id,deliver_date,goods_legacy_id,legacy_id,price,production_plan_no,qty,receipt_no,received_qty,request_item_legacy_id,returned_qty,sales_order_no,source_doc_no,unit_legacy_id,unit_rate,weight'),
      ('SALES_ORDER_ITEM','sales_order_items','sales_order_items.csv','amount_original,bill_legacy,circumference,client_model,client_no,color_legacy,die_cast_price,discount,flag_qty,goods_legacy,in_no,inbound_qty,legacy_id,machining_price,material_price,out_no,plan_no,price,qty,remark,returned_qty,shipped_qty,swdraw_no,tax_amount,unit_legacy,unit_rate,weight'),
      ('PURCHASE_RETURN_ITEM','purchase_return_items','purchase_return_items.csv','amount_original,bill_legacy_id,color_legacy_id,goods_legacy_id,legacy_id,order_item_legacy_id,order_no,price,production_plan_no,qty,receipt_item_legacy_id,receipt_no,sales_order_no,source_doc_no,unit_legacy_id,unit_rate,weight'),
      ('SUBCONTRACT_MATERIAL_RETURN_ITEM','subcontract_material_return_items','subcontract_swithdraw_i.csv','amount_local,bill_legacy_id,color_legacy_id,girth_qty,goods_legacy_id,issue_no,legacy_id,material_issue_item_legacy_id,order_item_legacy_id,order_no,parent_color_legacy_id,parent_goods_legacy_id,qty,source_doc_no,unit_legacy_id,unit_rate,weight'),
      ('SALES_SHIPMENT_ITEM','sales_shipment_items','sales_shipment_items.csv','amount_original,bill_legacy,carton_count,circumference,client_model,client_no,color_legacy,cost_amount,die_cast_price,discount,goods_legacy,legacy_id,machining_price,material_price,order_item_legacy,order_no,parcel_qty,price,qty,remark,returned_amount,returned_qty,swdraw_no,tax_amount,unit_legacy,unit_rate,weight')
    ) AS mappings(kind,table_name,file_name,keys) WHERE kind=p_kind
$$;

CREATE OR REPLACE FUNCTION public.fn_legacy_quantity_counter_bound_fields(p_kind text) RETURNS text[]
LANGUAGE sql IMMUTABLE SET search_path=pg_catalog,public,pg_temp AS $$
    SELECT array_agg(field ORDER BY field) FROM unnest(
      ARRAY['id','legacy_counter_import_run_id','legacy_id','bill_no','bill_date','goods_id','color_id','unit_id',
            'unit_rate','qty','price','amount_original','amount_local','weight','is_deleted','goods_snapshot_source']
      || CASE p_kind
        WHEN 'PURCHASE_ORDER_ITEM' THEN ARRAY['order_id','request_item_id','received_qty','returned_qty',
            'gift_qty','gift_received_qty','gift_returned_qty','arrival_overage_posted_qty',
            'allowed_over_receipt_pct','quantity_semantics','total_amount_input']
        WHEN 'SALES_ORDER_ITEM' THEN ARRAY['order_id','shipped_qty','returned_qty','flag_qty','inbound_qty',
            'discount','tax_amount','circumference','machining_price','reserved_qty','planned_qty','produced_qty','chain_status','priority']
        WHEN 'SALES_SHIPMENT_ITEM' THEN ARRAY['shipment_id','order_item_id','returned_qty','returned_amount',
            'cost_amount','parcel_qty','carton_count','circumference','material_price','die_cast_price','machining_price',
            'discount','warehouse_id','deleted_at']
        WHEN 'PURCHASE_RETURN_ITEM' THEN ARRAY['return_id','receipt_item_id','order_item_id','gift_qty','quantity_semantics',
            'charged_base_qty','gift_base_qty','quantity_adoption_version','quantity_precision_policy','quantity_source_proof',
            'source_doc_no','receipt_no','order_no','sales_order_no','production_plan_no']
        WHEN 'SUBCONTRACT_MATERIAL_RETURN_ITEM' THEN ARRAY['material_return_id','material_issue_item_id','order_item_id',
            'parent_goods_id','parent_color_id','parent_goods_snapshot_source','girth_qty','quantity_adoption_version',
            'quantity_precision_policy','adopted_base_qty','source_doc_no','issue_no','order_no']
        ELSE NULL::text[] END) field
$$;

CREATE FUNCTION public.fn_legacy_return_quantity_source_projection(p_kind text,s jsonb) RETURNS jsonb
LANGUAGE plpgsql SET search_path=pg_catalog,public AS $$
DECLARE parent_row jsonb; parent_legacy integer; parent_table text; source_file text; payload jsonb;
BEGIN
 IF p_kind NOT IN ('PURCHASE_RETURN_ITEM','SUBCONTRACT_MATERIAL_RETURN_ITEM') OR jsonb_typeof(s) IS DISTINCT FROM 'object' THEN
  RAISE EXCEPTION 'unsupported historical return quantity source' USING ERRCODE='23514';
 END IF;
 parent_table:=CASE p_kind WHEN 'PURCHASE_RETURN_ITEM' THEN 'purchase_returns' ELSE 'subcontract_material_returns' END;
 source_file:=CASE p_kind WHEN 'PURCHASE_RETURN_ITEM' THEN 'purchase_return_items.csv' ELSE 'subcontract_swithdraw_i.csv' END;
 PERFORM public.fn_require_legacy_bootstrap(NULLIF(current_setting('uten.bootstrap_run_id',true),'')::uuid,source_file);
 parent_legacy:=(s->>'bill_legacy_id')::integer;
 EXECUTE format('SELECT to_jsonb(parent) FROM public.%I parent WHERE legacy_id=$1',parent_table) INTO parent_row USING parent_legacy;
 IF parent_legacy IS NULL OR parent_legacy<=0 OR parent_row IS NULL THEN
  RAISE EXCEPTION 'historical return requires its exact original header' USING ERRCODE='23514';
 END IF;
 payload:=jsonb_build_object(
  'legacy_id',(s->>'legacy_id')::integer,'bill_no',parent_row->'bill_no','bill_date',parent_row->'bill_date',
  'goods_id',(SELECT id FROM public.goods WHERE legacy_id=(s->>'goods_legacy_id')::integer),
  'color_id',(SELECT id FROM public.colors WHERE legacy_id=(s->>'color_legacy_id')::integer),
  'unit_rate',(s->>'unit_rate')::numeric,'qty',(s->>'qty')::numeric,'weight',(s->>'weight')::numeric,
  'is_deleted',false,'goods_snapshot_source','LEGACY_IMPORT','source_doc_no',NULLIF(s->>'source_doc_no',''),
  'order_no',NULLIF(s->>'order_no',''),'quantity_adoption_version',1,'quantity_precision_policy',NULL);
 IF p_kind='PURCHASE_RETURN_ITEM' THEN
  RETURN payload||jsonb_build_object(
   'return_id',(parent_row->>'id')::uuid,
   'receipt_item_id',(SELECT id FROM public.purchase_receipt_items WHERE legacy_id=(s->>'receipt_item_legacy_id')::integer),
   'order_item_id',(SELECT id FROM public.purchase_order_items WHERE legacy_id=(s->>'order_item_legacy_id')::integer),
   'unit_id',(SELECT id FROM public.units WHERE legacy_id=NULLIF((s->>'unit_legacy_id')::integer,0)),
   'price',(s->>'price')::numeric,'amount_original',(s->>'amount_original')::numeric,
   'amount_local',public.fn_legacy_source_book_amount((s->>'amount_original')::numeric,(parent_row->>'exchange_rate')::numeric),
   'quantity_semantics','LEGACY_RECORDED','gift_qty',0,'charged_base_qty',NULL,'gift_base_qty',NULL,'quantity_source_proof',NULL,
   'receipt_no',NULLIF(s->>'receipt_no',''),'sales_order_no',NULLIF(s->>'sales_order_no',''),
   'production_plan_no',NULLIF(s->>'production_plan_no',''));
 END IF;
 RETURN payload||jsonb_build_object(
  'material_return_id',(parent_row->>'id')::uuid,
  'material_issue_item_id',(SELECT id FROM public.subcontract_material_issue_items WHERE legacy_id=(s->>'material_issue_item_legacy_id')::integer),
  'order_item_id',(SELECT id FROM public.subcontract_order_items WHERE legacy_id=(s->>'order_item_legacy_id')::integer),
  'unit_id',(SELECT id FROM public.units WHERE legacy_id=(s->>'unit_legacy_id')::integer),
  'price',NULL,'amount_original',NULL,'amount_local',(s->>'amount_local')::numeric,
  'parent_goods_id',(SELECT id FROM public.goods WHERE legacy_id=(s->>'parent_goods_legacy_id')::integer),
  'parent_color_id',(SELECT id FROM public.colors WHERE legacy_id=(s->>'parent_color_legacy_id')::integer),
  'parent_goods_snapshot_source',CASE WHEN NULLIF((s->>'parent_goods_legacy_id')::integer,0) IS NOT NULL THEN 'LEGACY_IMPORT' END,
  'girth_qty',(s->>'girth_qty')::numeric,'issue_no',NULLIF(s->>'issue_no',''),'adopted_base_qty',NULL);
END $$;

DO $projection_dispatch$
DECLARE definition text; anchor text:=E'BEGIN\n    IF NOT EXISTS(SELECT 1 FROM public.fn_legacy_quantity_counter_kind(p_kind))'; replacement text;
BEGIN
 definition:=pg_get_functiondef('public.fn_legacy_quantity_counter_source_projection(text,jsonb)'::regprocedure);
 IF (length(definition)-length(replace(definition,anchor,'')))/length(anchor)<>1 THEN RAISE EXCEPTION 'Review changed legacy quantity source projection'; END IF;
 replacement:=E'BEGIN\n    IF p_kind IN(''PURCHASE_RETURN_ITEM'',''SUBCONTRACT_MATERIAL_RETURN_ITEM'') THEN\n'
   ||E'        RETURN public.fn_legacy_return_quantity_source_projection(p_kind,s);\n    END IF;\n    IF NOT EXISTS(SELECT 1 FROM public.fn_legacy_quantity_counter_kind(p_kind))';
 EXECUTE replace(definition,anchor,replacement);
END $projection_dispatch$;

DO $verified_dispatch$
DECLARE definition text; anchor text:=E'ELSIF p_table=''purchase_order_items'' THEN'; replacement text;
BEGIN
 definition:=pg_get_functiondef('public.fn_accept_verified_legacy_quantity_adoption(text,jsonb)'::regprocedure);
 IF (length(definition)-length(replace(definition,anchor,'')))/length(anchor)<>1 THEN RAISE EXCEPTION 'Review changed verified legacy adoption dispatch'; END IF;
 replacement:='ELSIF p_table IN (''purchase_order_items'',''purchase_return_items'',''subcontract_material_return_items'') THEN';
 definition:=replace(definition,anchor,replacement);
 anchor:='PERFORM public.fn_require_legacy_bootstrap(run,''purchase_order_items.csv'');';
 IF (length(definition)-length(replace(definition,anchor,'')))/length(anchor)<>1 THEN RAISE EXCEPTION 'Review changed verified legacy adoption source file'; END IF;
 replacement:='PERFORM public.fn_require_legacy_bootstrap(run,CASE p_table WHEN ''purchase_order_items'' THEN ''purchase_order_items.csv'' WHEN ''purchase_return_items'' THEN ''purchase_return_items.csv'' ELSE ''subcontract_swithdraw_i.csv'' END);';
 EXECUTE replace(definition,anchor,replacement);
END $verified_dispatch$;

-- These return rows have no mutable running counter. Their proven historical
-- quantity/metadata cannot be upgraded by reusing the bootstrap context later.
CREATE FUNCTION public.fn_guard_legacy_return_quantity_source_facts() RETURNS trigger
LANGUAGE plpgsql SET search_path=pg_catalog,public AS $$
BEGIN
 IF OLD.legacy_counter_import_run_id IS NOT NULL THEN
  IF TG_OP='DELETE' OR (to_jsonb(NEW)-ARRAY['updated_at','updated_by']) IS DISTINCT FROM
      (to_jsonb(OLD)-ARRAY['updated_at','updated_by']) THEN
   RAISE EXCEPTION 'original historical return quantity and source facts are immutable' USING ERRCODE='55000';
  END IF;
 END IF;
 IF TG_OP='DELETE' THEN RETURN OLD; END IF;RETURN NEW;
END $$;

DO $provenance_guards$
DECLARE target text;
BEGIN
 FOREACH target IN ARRAY ARRAY['purchase_return_items','subcontract_material_return_items'] LOOP
  EXECUTE format('CREATE TRIGGER trg_zz_legacy_quantity_counter_source_facts BEFORE INSERT OR UPDATE OR DELETE ON public.%I FOR EACH ROW EXECUTE FUNCTION public.fn_guard_legacy_quantity_counter_source_facts()',target);
  EXECUTE format('ALTER TABLE public.%I ENABLE ALWAYS TRIGGER trg_zz_legacy_quantity_counter_source_facts',target);
  EXECUTE format('CREATE TRIGGER trg_zz_legacy_return_quantity_source_facts BEFORE UPDATE OR DELETE ON public.%I FOR EACH ROW EXECUTE FUNCTION public.fn_guard_legacy_return_quantity_source_facts()',target);
  EXECUTE format('ALTER TABLE public.%I ENABLE ALWAYS TRIGGER trg_zz_legacy_return_quantity_source_facts',target);
 END LOOP;
END $provenance_guards$;
