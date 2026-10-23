-- A first bootstrap INSERT is the original historical counter, not new work.
-- V132 already permits corrective decreases of accepted historical over-delivery.
-- Admit that original baseline only through exact immutable source evidence.
-- No approval, arrival allowance, stock, demand, or quantity is synthesized.
CREATE TABLE public.legacy_quantity_counter_import_sources (
    id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    run_id uuid NOT NULL REFERENCES public.legacy_migration_runs(run_id) ON DELETE RESTRICT,
    source_kind text NOT NULL,
    source_legacy_id integer NOT NULL CHECK(source_legacy_id>0),
    target_table text NOT NULL,
    target_id uuid NOT NULL UNIQUE,
    source_file text NOT NULL,
    source_row_sha256 char(64) NOT NULL CHECK(source_row_sha256 ~ '^[0-9a-f]{64}$'),
    source_file_sha256 char(64) NOT NULL CHECK(source_file_sha256 ~ '^[0-9a-f]{64}$'),
    target_fields text[] NOT NULL CHECK(cardinality(target_fields)>0),
    target_snapshot_sha256 char(64) NOT NULL CHECK(target_snapshot_sha256 ~ '^[0-9a-f]{64}$'),
    issued_txid bigint NOT NULL,
    created_at timestamptz NOT NULL DEFAULT now(),
    UNIQUE(run_id,source_kind,source_legacy_id),
    UNIQUE(run_id,target_id)
);
COMMENT ON TABLE public.legacy_quantity_counter_import_sources IS
    'PRESERVE: immutable exact first-bootstrap source quantity baseline; not finance approval or usable capacity; no source personal text';

DO $columns$
DECLARE target text;
BEGIN
    FOREACH target IN ARRAY ARRAY['purchase_order_items','sales_order_items','sales_shipment_items'] LOOP
        EXECUTE format('ALTER TABLE public.%I ADD COLUMN legacy_counter_import_run_id uuid',target);
        EXECUTE format('ALTER TABLE public.%I ADD CONSTRAINT %I FOREIGN KEY(legacy_counter_import_run_id,id) '
            'REFERENCES public.legacy_quantity_counter_import_sources(run_id,target_id) ON DELETE RESTRICT',target,target||'_counter_import_fk');
    END LOOP;
END;
$columns$;

CREATE FUNCTION public.fn_legacy_quantity_counter_kind(p_kind text)
RETURNS TABLE(target_table text,source_file text,source_keys text[])
LANGUAGE sql IMMUTABLE SET search_path=pg_catalog,public,pg_temp AS $$
    SELECT table_name,file_name,string_to_array(keys,',') FROM (VALUES
      ('PURCHASE_ORDER_ITEM','purchase_order_items','purchase_order_items.csv','amount_original,bill_legacy_id,color_legacy_id,deliver_date,goods_legacy_id,legacy_id,price,production_plan_no,qty,receipt_no,received_qty,request_item_legacy_id,returned_qty,sales_order_no,source_doc_no,unit_legacy_id,unit_rate,weight'),
      ('SALES_ORDER_ITEM','sales_order_items','sales_order_items.csv','amount_original,bill_legacy,circumference,client_model,client_no,color_legacy,die_cast_price,discount,flag_qty,goods_legacy,in_no,inbound_qty,legacy_id,machining_price,material_price,out_no,plan_no,price,qty,remark,returned_qty,shipped_qty,swdraw_no,tax_amount,unit_legacy,unit_rate,weight'),
      ('SALES_SHIPMENT_ITEM','sales_shipment_items','sales_shipment_items.csv','amount_original,bill_legacy,carton_count,circumference,client_model,client_no,color_legacy,cost_amount,die_cast_price,discount,goods_legacy,legacy_id,machining_price,material_price,order_item_legacy,order_no,parcel_qty,price,qty,remark,returned_amount,returned_qty,swdraw_no,tax_amount,unit_legacy,unit_rate,weight')
    ) AS mappings(kind,table_name,file_name,keys) WHERE kind=p_kind
$$;

-- All quantity/capacity fields and their real source relationships are bound,
-- including modern defaults absent from the old source. Descriptive fields are
-- left with the established loader. Missing source links stay NULL exactly as
-- the historical loader did; neither legacy ID nor a name guesses a relation.
CREATE FUNCTION public.fn_legacy_quantity_counter_source_projection(p_kind text,s jsonb) RETURNS jsonb
LANGUAGE plpgsql SET search_path=pg_catalog,public,pg_temp AS $$
DECLARE parent_row jsonb; parent_legacy integer; parent_table text; goods uuid; color uuid; unit uuid;
    payload jsonb; purchase boolean:=p_kind='PURCHASE_ORDER_ITEM';
BEGIN
    IF NOT EXISTS(SELECT 1 FROM public.fn_legacy_quantity_counter_kind(p_kind))
       OR jsonb_typeof(s) IS DISTINCT FROM 'object' THEN
        RAISE EXCEPTION 'unsupported historical quantity counter source shape' USING ERRCODE='23514';
    END IF;
    parent_legacy:=(s->>CASE WHEN purchase THEN 'bill_legacy_id' ELSE 'bill_legacy' END)::integer;
    parent_table:=CASE p_kind WHEN 'PURCHASE_ORDER_ITEM' THEN 'purchase_orders'
        WHEN 'SALES_ORDER_ITEM' THEN 'sales_orders' ELSE 'sales_shipments' END;
    EXECUTE format('SELECT to_jsonb(parent) FROM public.%I parent WHERE legacy_id=$1',parent_table)
        INTO parent_row USING parent_legacy;
    IF parent_legacy IS NULL OR parent_legacy<=0 OR parent_row IS NULL THEN
        RAISE EXCEPTION 'historical counter item requires its exact original source header' USING ERRCODE='23514';
    END IF;
    goods:=(SELECT id FROM public.goods WHERE legacy_id=(s->>CASE WHEN purchase THEN 'goods_legacy_id' ELSE 'goods_legacy' END)::integer);
    color:=(SELECT id FROM public.colors WHERE legacy_id=(s->>CASE WHEN purchase THEN 'color_legacy_id' ELSE 'color_legacy' END)::integer);
    unit:=(SELECT id FROM public.units WHERE legacy_id=CASE WHEN purchase
        THEN NULLIF((s->>'unit_legacy_id')::integer,0) ELSE (s->>'unit_legacy')::integer END);
    payload:=jsonb_build_object('legacy_id',(s->>'legacy_id')::integer,
        'bill_no',parent_row->'bill_no','bill_date',parent_row->'bill_date',
        'goods_id',goods,'color_id',color,'unit_id',unit,
        'unit_rate',CASE WHEN purchase THEN (s->>'unit_rate')::numeric ELSE COALESCE((s->>'unit_rate')::numeric,1) END,
        'qty',(s->>'qty')::numeric,'price',(s->>'price')::numeric,
        'amount_original',(s->>'amount_original')::numeric,
        'amount_local',CASE WHEN purchase THEN public.fn_legacy_source_book_amount((s->>'amount_original')::numeric,(parent_row->>'exchange_rate')::numeric)
            ELSE (s->>'amount_original')::numeric*COALESCE((parent_row->>'exchange_rate')::numeric,1) END,
        'weight',(s->>'weight')::numeric,'is_deleted',false,'goods_snapshot_source','LEGACY_IMPORT');
    IF purchase THEN
        RETURN payload||jsonb_build_object('order_id',(parent_row->>'id')::uuid,
            'request_item_id',(SELECT id FROM public.purchase_request_items WHERE legacy_id=(s->>'request_item_legacy_id')::integer),
            'received_qty',COALESCE((s->>'received_qty')::numeric,0),'returned_qty',COALESCE((s->>'returned_qty')::numeric,0),
            'gift_qty',0,'gift_received_qty',0,'gift_returned_qty',0,'arrival_overage_posted_qty',0,
            'allowed_over_receipt_pct',NULL,'quantity_semantics','LEGACY_RECORDED','total_amount_input',NULL);
    END IF;
    IF p_kind='SALES_ORDER_ITEM' THEN
        RETURN payload||jsonb_build_object('order_id',(parent_row->>'id')::uuid,
            'shipped_qty',COALESCE((s->>'shipped_qty')::numeric,0),'returned_qty',COALESCE((s->>'returned_qty')::numeric,0),
            'flag_qty',COALESCE((s->>'flag_qty')::numeric,0),'inbound_qty',COALESCE((s->>'inbound_qty')::numeric,0),
            'discount',COALESCE((s->>'discount')::numeric,0),'tax_amount',COALESCE((s->>'tax_amount')::numeric,0),
            'circumference',(s->>'circumference')::numeric,'machining_price',(s->>'machining_price')::numeric,
            'reserved_qty',0,'planned_qty',0,'produced_qty',0,'chain_status',0,'priority',3);
    END IF;
    RETURN payload||jsonb_build_object('shipment_id',(parent_row->>'id')::uuid,
        'order_item_id',(SELECT id FROM public.sales_order_items WHERE legacy_id=NULLIF((s->>'order_item_legacy')::integer,0)),
        'returned_qty',COALESCE((s->>'returned_qty')::numeric,0),'returned_amount',COALESCE((s->>'returned_amount')::numeric,0),
        'cost_amount',(s->>'cost_amount')::numeric,'parcel_qty',(s->>'parcel_qty')::numeric,
        'carton_count',(s->>'carton_count')::numeric,'circumference',(s->>'circumference')::numeric,
        'material_price',(s->>'material_price')::numeric,'die_cast_price',(s->>'die_cast_price')::numeric,
        'machining_price',(s->>'machining_price')::numeric,'discount',COALESCE((s->>'discount')::numeric,0),
        'warehouse_id',NULL,'deleted_at',NULL);
END; $$;

CREATE FUNCTION public.fn_legacy_quantity_counter_bound_fields(p_kind text) RETURNS text[]
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
        ELSE NULL::text[] END) field
$$;

CREATE FUNCTION public.fn_guard_legacy_quantity_counter_evidence() RETURNS trigger
LANGUAGE plpgsql SET search_path=pg_catalog,public,pg_temp AS $$
DECLARE mapping record;
BEGIN
    IF TG_OP<>'INSERT' THEN
        RAISE EXCEPTION 'legacy initial quantity counter evidence is immutable' USING ERRCODE='55000';
    END IF;
    SELECT * INTO mapping FROM public.fn_legacy_quantity_counter_kind(NEW.source_kind);
    IF NOT FOUND OR NEW.target_table IS DISTINCT FROM mapping.target_table OR NEW.source_file IS DISTINCT FROM mapping.source_file
       OR NEW.target_fields IS DISTINCT FROM public.fn_legacy_quantity_counter_bound_fields(NEW.source_kind) THEN
        RAISE EXCEPTION 'legacy initial quantity counter source kind is not registered' USING ERRCODE='23514';
    END IF;
    PERFORM public.fn_require_legacy_bootstrap(NEW.run_id,NEW.source_file);
    IF NEW.issued_txid<>txid_current() OR NEW.source_file_sha256 IS DISTINCT FROM
       (SELECT sha256 FROM public.legacy_migration_run_files WHERE run_id=NEW.run_id AND file_name=NEW.source_file) THEN
        RAISE EXCEPTION 'legacy initial counter evidence belongs to another input or transaction' USING ERRCODE='23514';
    END IF;
    RETURN NEW;
END; $$;
CREATE TRIGGER trg_guard_legacy_quantity_counter_evidence BEFORE INSERT OR UPDATE OR DELETE
    ON public.legacy_quantity_counter_import_sources FOR EACH ROW EXECUTE FUNCTION public.fn_guard_legacy_quantity_counter_evidence();
ALTER TABLE public.legacy_quantity_counter_import_sources ENABLE ALWAYS TRIGGER trg_guard_legacy_quantity_counter_evidence;
-- Same current V670 legacy/NONE policy as V627 receipt proof: immutable row
-- evidence plus the bootstrap run audit, without millions of duplicate events.
SELECT public.fn_audit_track_table('legacy_quantity_counter_import_sources','NONE','system',false);

CREATE FUNCTION public.fn_register_legacy_quantity_counter_source(p_run_id uuid,p_kind text,p_source jsonb) RETURNS uuid
LANGUAGE plpgsql SET search_path=pg_catalog,public,pg_temp AS $$
DECLARE mapping record; keys text[]; payload jsonb; record_id uuid:=gen_random_uuid(); fields text[]; original_id integer; exists_target boolean;
BEGIN
    SELECT * INTO mapping FROM public.fn_legacy_quantity_counter_kind(p_kind);
    IF NOT FOUND THEN RAISE EXCEPTION 'unsupported initial quantity counter source kind' USING ERRCODE='23514'; END IF;
    PERFORM public.fn_require_legacy_bootstrap(p_run_id,mapping.source_file);
    IF jsonb_typeof(p_source) IS DISTINCT FROM 'object' THEN
        RAISE EXCEPTION 'legacy counter source must be the complete typed original row' USING ERRCODE='23514';
    END IF;
    SELECT array_agg(key ORDER BY key) INTO keys FROM jsonb_object_keys(p_source) key;
    original_id:=(p_source->>'legacy_id')::integer;
    IF keys IS DISTINCT FROM (SELECT array_agg(key ORDER BY key) FROM unnest(mapping.source_keys) key)
       OR original_id IS NULL OR original_id<=0 THEN
        RAISE EXCEPTION 'legacy counter source shape or identity is not authoritative' USING ERRCODE='23514';
    END IF;
    EXECUTE format('SELECT EXISTS(SELECT 1 FROM public.%I WHERE legacy_id=$1)',mapping.target_table)
        INTO exists_target USING original_id;
    IF exists_target THEN
        RAISE EXCEPTION 'legacy counter proof is only issued before the original first insert' USING ERRCODE='23514';
    END IF;
    payload:=public.fn_legacy_quantity_counter_source_projection(p_kind,p_source)
        ||jsonb_build_object('id',record_id,'legacy_counter_import_run_id',p_run_id);
    SELECT array_agg(key ORDER BY key) INTO fields FROM jsonb_object_keys(payload) key;
    INSERT INTO public.legacy_quantity_counter_import_sources(run_id,source_kind,source_legacy_id,target_table,target_id,
        source_file,source_row_sha256,source_file_sha256,target_fields,target_snapshot_sha256,issued_txid)
    SELECT p_run_id,p_kind,original_id,mapping.target_table,record_id,mapping.source_file,
        encode(public.digest(p_source::text,'sha256'),'hex'),sha256,fields,
        encode(public.digest(public.fn_legacy_finance_snapshot(payload,fields)::text,'sha256'),'hex'),txid_current()
    FROM public.legacy_migration_run_files WHERE run_id=p_run_id AND file_name=mapping.source_file;
    RETURN record_id;
END; $$;

CREATE FUNCTION public.fn_assert_legacy_quantity_counter_source(p_table text,p_row jsonb) RETURNS void
LANGUAGE plpgsql SET search_path=pg_catalog,public,pg_temp AS $$
DECLARE proof public.legacy_quantity_counter_import_sources%ROWTYPE; run uuid; mapping record; already_inserted boolean;
BEGIN
    run:=(p_row->>'legacy_counter_import_run_id')::uuid;
    -- Replan the exact unique lookup: a tiny first source family must not cache
    -- a sequential scan that survives a later large family in this transaction.
    EXECUTE 'SELECT * FROM public.legacy_quantity_counter_import_sources '
        'WHERE run_id=$1 AND target_id=$2 AND target_table=$3 AND source_legacy_id=$4'
        INTO proof USING run,(p_row->>'id')::uuid,p_table,(p_row->>'legacy_id')::integer;
    IF proof.id IS NULL OR proof.issued_txid<>txid_current() THEN
        RAISE EXCEPTION 'legacy initial counter row has no exact source proof in this transaction' USING ERRCODE='23514';
    END IF;
    SELECT * INTO mapping FROM public.fn_legacy_quantity_counter_kind(proof.source_kind);
    IF NOT FOUND OR proof.target_table IS DISTINCT FROM mapping.target_table
       OR proof.source_file IS DISTINCT FROM mapping.source_file
       OR proof.target_fields IS DISTINCT FROM public.fn_legacy_quantity_counter_bound_fields(proof.source_kind)
       OR proof.source_file_sha256 IS DISTINCT FROM (SELECT sha256 FROM public.legacy_migration_run_files
           WHERE run_id=run AND file_name=proof.source_file) THEN
        RAISE EXCEPTION 'legacy initial counter proof differs from its exact registered input shape' USING ERRCODE='23514';
    END IF;
    PERFORM public.fn_require_legacy_bootstrap(run,proof.source_file);
    EXECUTE format('SELECT EXISTS(SELECT 1 FROM public.%I WHERE id=$1 OR legacy_id=$2)',mapping.target_table)
        INTO already_inserted USING proof.target_id,proof.source_legacy_id;
    IF already_inserted THEN
        RAISE EXCEPTION 'legacy initial counter proof cannot authorize an existing row' USING ERRCODE='23514';
    END IF;
    IF proof.target_snapshot_sha256 IS DISTINCT FROM
       encode(public.digest(public.fn_legacy_finance_snapshot(p_row,proof.target_fields)::text,'sha256'),'hex') THEN
        RAISE EXCEPTION 'legacy initial counter does not match its complete original quantity projection' USING ERRCODE='23514';
    END IF;
END; $$;

-- Provenance cannot be attached to, removed from, or rebound on an online row.
-- Actual quantities keep every existing corrective-decrease/reversal rule.
CREATE FUNCTION public.fn_guard_legacy_quantity_counter_source_facts() RETURNS trigger
LANGUAGE plpgsql SET search_path=pg_catalog,public,pg_temp AS $$
BEGIN
    IF TG_OP='DELETE' THEN
        IF OLD.legacy_counter_import_run_id IS NOT NULL THEN
            RAISE EXCEPTION 'original initial counter identity cannot be deleted and replayed' USING ERRCODE='55000';
        END IF;
        RETURN OLD;
    ELSIF TG_OP='INSERT' AND NEW.legacy_counter_import_run_id IS NOT NULL THEN
        PERFORM public.fn_assert_legacy_quantity_counter_source(TG_TABLE_NAME,to_jsonb(NEW));
    ELSIF TG_OP='UPDATE' AND (NEW.legacy_counter_import_run_id IS DISTINCT FROM OLD.legacy_counter_import_run_id
        OR (OLD.legacy_counter_import_run_id IS NOT NULL AND (NEW.id IS DISTINCT FROM OLD.id OR NEW.legacy_id IS DISTINCT FROM OLD.legacy_id))) THEN
        RAISE EXCEPTION 'initial counter source provenance cannot be added, cleared or rebound' USING ERRCODE='23514';
    END IF;
    RETURN NEW;
END; $$;
DO $guards$
DECLARE target text;
BEGIN
    FOREACH target IN ARRAY ARRAY['purchase_order_items','sales_order_items','sales_shipment_items'] LOOP
        EXECUTE format('CREATE TRIGGER trg_zz_legacy_quantity_counter_source_facts BEFORE INSERT OR UPDATE OR DELETE ON public.%I '
            'FOR EACH ROW EXECUTE FUNCTION public.fn_guard_legacy_quantity_counter_source_facts()',target);
        EXECUTE format('ALTER TABLE public.%I ENABLE ALWAYS TRIGGER trg_zz_legacy_quantity_counter_source_facts',target);
    END LOOP;
END;
$guards$;

-- This is deliberately not a generic import flag or an UPDATE allowance.
-- Call sites below invoke it solely in the original INSERT over-limit branch.
CREATE FUNCTION public.fn_accept_legacy_initial_quantity_counter(p_table text,p_row jsonb,p_counter text) RETURNS boolean
LANGUAGE plpgsql SET search_path=pg_catalog,public,pg_temp AS $$
DECLARE proof public.legacy_procurement_receipt_import_sources%ROWTYPE;
BEGIN
    IF (p_table='purchase_order_items' AND p_counter IN('received_qty','returned_qty'))
       OR (p_table='sales_order_items' AND p_counter IN('shipped_qty','returned_qty'))
       OR (p_table='sales_shipment_items' AND p_counter='returned_qty') THEN
        IF p_row->>'legacy_counter_import_run_id' IS NULL THEN RETURN false; END IF;
        PERFORM public.fn_assert_legacy_quantity_counter_source(p_table,p_row);
        RETURN true;
    END IF;
    IF p_table='purchase_receipt_items' AND p_counter='returned_qty' THEN
        IF p_row->>'legacy_import_run_id' IS NULL THEN RETURN false; END IF;
        -- V627 already binds original gift_qty, qty, unit/rate, parent/order and
        -- exact target UUID. Bind every newer quantity/approval default too.
        PERFORM public.fn_assert_legacy_receipt_import_source(p_table,p_row);
        SELECT * INTO proof FROM public.legacy_procurement_receipt_import_sources
        WHERE run_id=(p_row->>'legacy_import_run_id')::uuid AND target_id=(p_row->>'id')::uuid;
        IF proof.source_kind IS DISTINCT FROM 'PURCHASE_ITEM' OR proof.source_file IS DISTINCT FROM 'purchase_receipt_items.csv'
           OR proof.source_file_sha256 IS DISTINCT FROM (SELECT sha256 FROM public.legacy_migration_run_files
               WHERE run_id=proof.run_id AND file_name=proof.source_file) THEN
            RAISE EXCEPTION 'historical receipt counter proof differs from its original source input' USING ERRCODE='23514';
        END IF;
        IF (p_row->>'quantity_semantics') IS DISTINCT FROM 'LEGACY_RECORDED'
           OR (p_row->>'gift_returned_qty')::numeric IS DISTINCT FROM 0::numeric
           OR p_row->>'charged_base_qty' IS NOT NULL OR p_row->>'gift_base_qty' IS NOT NULL
           OR p_row->>'gift_replacement_intent' IS NOT NULL OR p_row->>'finance_approval_case_id' IS NOT NULL
           OR (p_row->>'is_deleted')::boolean IS DISTINCT FROM false THEN
            RAISE EXCEPTION 'historical receipt counter cannot carry new gift, approval or quantity semantics' USING ERRCODE='23514';
        END IF;
        RETURN true;
    END IF;
    RETURN false;
END; $$;

-- Forward patch only the three existing over-limit branches, fail closed if
-- their authoritative definitions drift. Negative checks precede each branch;
-- every UPDATE and every unsupported table/counter follows the original guard.
DO $patch$
DECLARE definition text; anchor text; replacement text;
BEGIN
    definition:=pg_get_functiondef('public.fn_guard_processed_quantity()'::regprocedure);
    anchor:='IF v_new_counter > v_old_counter AND v_new_counter > v_capacity THEN';
    IF (length(definition)-length(replace(definition,anchor,'')))/length(anchor)<>1 THEN
        RAISE EXCEPTION 'V908 processed quantity over-limit anchor differs';
    END IF;
    replacement:=anchor||E'\n        IF TG_OP=''INSERT'' AND public.fn_accept_legacy_initial_quantity_counter(TG_TABLE_NAME,v_new_row,v_counter_name) THEN RETURN NEW; END IF;';
    EXECUTE replace(definition,anchor,replacement);
    definition:=pg_get_functiondef('public.fn_guard_return_allowance()'::regprocedure);
    anchor:='IF v_new_returned>v_old_returned AND v_new_returned>v_processed THEN';
    IF (length(definition)-length(replace(definition,anchor,'')))/length(anchor)<>1 THEN
        RAISE EXCEPTION 'V908 return allowance over-limit anchor differs';
    END IF;
    replacement:=anchor||E'\n        IF TG_OP=''INSERT'' AND public.fn_accept_legacy_initial_quantity_counter(TG_TABLE_NAME,v_new_row,v_return_name) THEN RETURN NEW; END IF;';
    EXECUTE replace(definition,anchor,replacement);
    definition:=pg_get_functiondef('public.fn_guard_procurement_received_with_arrival_allowance()'::regprocedure);
    anchor:='AND v_new_received>v_capacity+v_receipt_extra THEN';
    IF (length(definition)-length(replace(definition,anchor,'')))/length(anchor)<>1 THEN
        RAISE EXCEPTION 'V908 procurement received over-limit anchor differs';
    END IF;
    replacement:=anchor||E'\n        IF TG_OP=''INSERT'' AND public.fn_accept_legacy_initial_quantity_counter(TG_TABLE_NAME,to_jsonb(NEW),''received_qty'') THEN RETURN NEW; END IF;';
    EXECUTE replace(definition,anchor,replacement);
END;
$patch$;

REVOKE ALL ON public.legacy_quantity_counter_import_sources FROM PUBLIC;
REVOKE ALL ON FUNCTION public.fn_register_legacy_quantity_counter_source(uuid,text,jsonb) FROM PUBLIC;
DO $privileges$
BEGIN
    IF EXISTS(SELECT 1 FROM pg_catalog.pg_roles WHERE rolname='uten') THEN
        REVOKE ALL ON public.legacy_quantity_counter_import_sources FROM uten;
        GRANT SELECT ON public.legacy_quantity_counter_import_sources TO uten;
        REVOKE ALL ON FUNCTION public.fn_register_legacy_quantity_counter_source(uuid,text,jsonb) FROM uten;
    END IF;
    IF EXISTS(SELECT 1 FROM pg_catalog.pg_roles WHERE rolname='uten_migrator') THEN
        GRANT SELECT,INSERT ON public.legacy_quantity_counter_import_sources TO uten_migrator;
        GRANT EXECUTE ON FUNCTION public.fn_register_legacy_quantity_counter_source(uuid,text,jsonb) TO uten_migrator;
    END IF;
END;
$privileges$;
DO $reset_policy$
DECLARE definition text; anchor text:='(''stock_movements'', ''CLEAR'')';
BEGIN
    SELECT pg_get_functiondef('public.business_data_reset()'::regprocedure) INTO definition;
    IF (length(definition)-length(replace(definition,anchor,'')))/length(anchor)<>1 THEN
        RAISE EXCEPTION 'V908 cannot extend business-data reset policy safely';
    END IF;
    EXECUTE replace(definition,anchor,anchor||E',\n            (''legacy_quantity_counter_import_sources'', ''PRESERVE'')');
END;
$reset_policy$;
