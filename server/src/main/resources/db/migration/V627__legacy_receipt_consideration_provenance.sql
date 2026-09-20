-- V627 keeps original P_In/E_In snapshots in the pre-V518 historical lane.
-- It does not synthesize arrival intent, consideration, inventory or AP facts.
CREATE TABLE public.legacy_procurement_receipt_import_sources (
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
COMMENT ON TABLE public.legacy_procurement_receipt_import_sources IS
    'PRESERVE: immutable original receipt source hashes and target identity; no source personal or monetary payload';

DO $columns$
DECLARE target text;
BEGIN
    FOREACH target IN ARRAY ARRAY['purchase_receipts','purchase_receipt_items','subcontract_receipts','subcontract_receipt_items'] LOOP
        EXECUTE format('ALTER TABLE public.%I ADD COLUMN legacy_import_run_id uuid',target);
        EXECUTE format('ALTER TABLE public.%I ADD CONSTRAINT %I FOREIGN KEY(legacy_import_run_id,id) '
            'REFERENCES public.legacy_procurement_receipt_import_sources(run_id,target_id) ON DELETE RESTRICT',target,target||'_legacy_import_fk');
    END LOOP;
END;
$columns$;

CREATE FUNCTION public.fn_legacy_receipt_import_kind(p_kind text)
RETURNS TABLE(target_table text,source_file text,source_keys text[])
LANGUAGE sql IMMUTABLE SET search_path=pg_catalog,public,pg_temp AS $$
    SELECT table_name,file_name,string_to_array(keys,',') FROM (VALUES
      ('PURCHASE_HEADER','purchase_receipts','purchase_receipts.csv','approver_legacy,bill_date,bill_no,cancel_bit,currency_legacy_id,exchange_rate,last_date,legacy_id,maker_legacy,receiver_legacy,remark,salesman_legacy,sender_legacy,settlement_style_legacy,status,supplier_legacy_id,tax_rate,total_original,warehouse_legacy_id'),
      ('PURCHASE_ITEM','purchase_receipt_items','purchase_receipt_items.csv','amount_original,bill_legacy_id,color_legacy_id,gift_qty,goods_legacy_id,legacy_id,order_item_legacy_id,order_no,price,production_plan_no,qty,returned_qty,sales_order_no,source_doc_no,unit_legacy_id,unit_rate,weight'),
      ('SUBCONTRACT_HEADER','subcontract_receipts','subcontract_in_m.csv','approver_legacy,bill_date,bill_no,cancel_bit,currency_legacy_id,exchange_rate,last_date,legacy_id,maker_legacy,remark,sender_legacy,settlement_style_legacy,status,supplier_legacy_id,tax_rate,total_original,warehouse_legacy_id'),
      ('SUBCONTRACT_ITEM','subcontract_receipt_items','subcontract_in_i.csv','amount_local,amount_original,bill_legacy_id,check_qty,color_legacy_id,girth_qty,goods_legacy_id,legacy_id,order_item_legacy_id,order_no,order_qty,price,qty,return_amount,return_no,returned_qty,source_doc_no,step_legacy_id,unit_legacy_id,unit_rate,weight')
    ) AS mappings(kind,table_name,file_name,keys) WHERE kind=p_kind
$$;


-- Complete typed source rows, with historical monetary and unit unknowns kept
-- explicit. This returns commercial/source fields only; the controlled caller
-- owns provenance, while the loader supplies descriptive personnel snapshots.
CREATE FUNCTION public.fn_legacy_receipt_source_projection(p_kind text,s jsonb) RETURNS jsonb
LANGUAGE plpgsql SET search_path=pg_catalog,public,pg_temp AS $$
DECLARE
    purchase boolean := p_kind LIKE 'PURCHASE_%';
    header boolean := p_kind LIKE '%_HEADER';
    currency uuid; rate numeric; original numeric; local_amount numeric;
    receipt uuid; parent_row jsonb; unit uuid; order_item uuid; goods uuid; color uuid;
    payload jsonb;
BEGIN
    IF p_kind NOT IN('PURCHASE_HEADER','PURCHASE_ITEM','SUBCONTRACT_HEADER','SUBCONTRACT_ITEM')
       OR jsonb_typeof(s) IS DISTINCT FROM 'object' THEN
        RAISE EXCEPTION USING ERRCODE='23514',MESSAGE='unsupported historical receipt source shape';
    END IF;
    IF header THEN
        currency:=(SELECT id FROM public.currencies WHERE legacy_id=(s->>'currency_legacy_id')::integer);
        rate:=(s->>'exchange_rate')::numeric;
        original:=(s->>'total_original')::numeric;
        -- The original document rate is evidence; today's master rate is not.
        local_amount:=public.fn_legacy_source_book_amount(original,rate);
        payload:=jsonb_build_object(
            'legacy_id',(s->>'legacy_id')::integer,'bill_no',s->>'bill_no','bill_date',(s->>'bill_date')::date,
            'supplier_id',(SELECT id FROM public.suppliers WHERE legacy_id=(s->>'supplier_legacy_id')::integer),
            'warehouse_id',(SELECT id FROM public.warehouses WHERE legacy_id=(s->>'warehouse_legacy_id')::integer),
            'currency_id',currency,'exchange_rate',rate,'tax_rate',(s->>'tax_rate')::numeric,
            'total_original',original,'total_local',local_amount,'status',(s->>'status')::smallint,
            'is_closed',false,'consideration_required',false,
            'maker_legacy_id',NULLIF((s->>'maker_legacy')::integer,0),
            'approver_legacy_id',NULLIF((s->>'approver_legacy')::integer,0),
            'settlement_style_legacy',(s->>'settlement_style_legacy')::integer,
            'settlement_method_id',(SELECT id FROM public.settlement_methods
                WHERE legacy_id=NULLIF((s->>'settlement_style_legacy')::integer,0)));
        IF EXISTS (SELECT 1 FROM (VALUES
            ('supplier_legacy_id','supplier_id'),('warehouse_legacy_id','warehouse_id'),
            ('currency_legacy_id','currency_id')) reference(source_key,target_key)
            WHERE NULLIF((s->>reference.source_key)::integer,0) IS NOT NULL
              AND payload->>reference.target_key IS NULL) THEN
            RAISE EXCEPTION USING ERRCODE='23514',MESSAGE='historical receipt header has an unresolved explicit master identity';
        END IF;
        IF purchase THEN
            RETURN payload||jsonb_build_object('sender_id',NULL,'receiver_id',NULL,'maker_id',NULL,'approver_id',NULL,
                'sender_legacy_id',NULLIF((s->>'sender_legacy')::integer,0),
                'receiver_legacy_id',NULLIF((s->>'receiver_legacy')::integer,0),
                'purchaser_legacy_id',NULLIF((s->>'salesman_legacy')::integer,0),
                'purchaser_id',(SELECT id FROM public.employees WHERE legacy_id=NULLIF((s->>'salesman_legacy')::integer,0)));
        END IF;
        RETURN payload||jsonb_build_object('last_date',(s->>'last_date')::date,
            'receiver_legacy_id',NULLIF((s->>'sender_legacy')::integer,0));
    END IF;

    IF purchase THEN
        SELECT to_jsonb(parent) INTO parent_row FROM public.purchase_receipts parent
          WHERE legacy_id=(s->>'bill_legacy_id')::integer;
        order_item:=(SELECT id FROM public.purchase_order_items WHERE legacy_id=(s->>'order_item_legacy_id')::integer);
    ELSE
        SELECT to_jsonb(parent) INTO parent_row FROM public.subcontract_receipts parent
          WHERE legacy_id=(s->>'bill_legacy_id')::integer;
        order_item:=(SELECT id FROM public.subcontract_order_items WHERE legacy_id=(s->>'order_item_legacy_id')::integer);
    END IF;
    IF parent_row IS NULL OR parent_row->>'legacy_import_run_id' IS DISTINCT FROM current_setting('uten.bootstrap_run_id',true) THEN
        RAISE EXCEPTION USING ERRCODE='23514',MESSAGE='historical receipt item requires its exact same-run source header';
    END IF;
    receipt:=(parent_row->>'id')::uuid;
    currency:=(parent_row->>'currency_id')::uuid;
    rate:=(parent_row->>'exchange_rate')::numeric;
    goods:=(SELECT id FROM public.goods WHERE legacy_id=(s->>'goods_legacy_id')::integer);
    color:=(SELECT id FROM public.colors WHERE legacy_id=NULLIF((s->>'color_legacy_id')::integer,0));
    unit:=(SELECT id FROM public.units WHERE legacy_id=NULLIF((s->>'unit_legacy_id')::integer,0));
    IF purchase THEN
        original:=(s->>'amount_original')::numeric;
        local_amount:=public.fn_legacy_source_book_amount(original,rate);
    ELSE
        -- E_InItem.STotal is recorded functional-currency inventory cost. It
        -- is not evidence of a commercial subcontract fee or foreign amount.
        local_amount:=(s->>'amount_local')::numeric;
        original:=CASE WHEN rate=1 AND EXISTS(SELECT 1 FROM public.currencies WHERE id=currency AND is_base_currency)
            THEN local_amount ELSE NULL END;
    END IF;
    payload:=jsonb_build_object(
        'legacy_id',(s->>'legacy_id')::integer,'bill_no',parent_row->'bill_no','bill_date',parent_row->'bill_date',
        'receipt_id',receipt,'order_item_id',order_item,'goods_id',goods,'color_id',color,'unit_id',unit,
        'unit_rate',(s->>'unit_rate')::numeric,'qty',(s->>'qty')::numeric,'price',(s->>'price')::numeric,
        'amount_original',original,'amount_local',local_amount,'returned_qty',(s->>'returned_qty')::numeric,
        'weight',(s->>'weight')::numeric,'source_doc_no',NULLIF(s->>'source_doc_no',''),
        'order_no',NULLIF(s->>'order_no',''),'replacement_intent',NULL,
        'goods_snapshot_source','LEGACY_IMPORT');
    IF EXISTS (SELECT 1 FROM (VALUES
        ('goods_legacy_id','goods_id'),('color_legacy_id','color_id'),
        ('unit_legacy_id','unit_id'),('order_item_legacy_id','order_item_id')) reference(source_key,target_key)
        WHERE NULLIF((s->>reference.source_key)::integer,0) IS NOT NULL
          AND payload->>reference.target_key IS NULL) THEN
        RAISE EXCEPTION USING ERRCODE='23514',MESSAGE='historical receipt item has an unresolved explicit source identity';
    END IF;
    IF purchase THEN
        RETURN payload||jsonb_build_object('gift_qty',(s->>'gift_qty')::numeric,
            'sales_order_no',NULLIF(s->>'sales_order_no',''),'production_plan_no',NULLIF(s->>'production_plan_no',''));
    END IF;
    RETURN payload||jsonb_build_object('check_qty',(s->>'check_qty')::numeric,'order_qty',(s->>'order_qty')::numeric,
        'girth_qty',(s->>'girth_qty')::numeric,'step_legacy_id',NULLIF((s->>'step_legacy_id')::integer,0),
        'return_amount',(s->>'return_amount')::numeric,'return_no',NULLIF(s->>'return_no',''));
END; $$;


CREATE FUNCTION public.fn_guard_legacy_receipt_import_evidence() RETURNS trigger
LANGUAGE plpgsql SET search_path=pg_catalog,public,pg_temp AS $$
DECLARE mapping record;
BEGIN
    IF TG_OP<>'INSERT' THEN
        RAISE EXCEPTION 'legacy receipt import evidence is immutable' USING ERRCODE='55000';
    END IF;
    SELECT * INTO mapping FROM public.fn_legacy_receipt_import_kind(NEW.source_kind);
    IF NOT FOUND OR NEW.target_table IS DISTINCT FROM mapping.target_table OR NEW.source_file IS DISTINCT FROM mapping.source_file THEN
        RAISE EXCEPTION 'legacy receipt source kind is not registered' USING ERRCODE='23514';
    END IF;
    PERFORM public.fn_require_legacy_bootstrap(NEW.run_id,NEW.source_file);
    IF NEW.issued_txid<>txid_current() OR NEW.source_file_sha256 IS DISTINCT FROM
       (SELECT sha256 FROM public.legacy_migration_run_files WHERE run_id=NEW.run_id AND file_name=NEW.source_file) THEN
        RAISE EXCEPTION 'legacy receipt evidence belongs to another input or transaction' USING ERRCODE='23514';
    END IF;
    RETURN NEW;
END; $$;
CREATE TRIGGER trg_guard_legacy_receipt_import_evidence BEFORE INSERT OR UPDATE OR DELETE
    ON public.legacy_procurement_receipt_import_sources FOR EACH ROW EXECUTE FUNCTION public.fn_guard_legacy_receipt_import_evidence();
ALTER TABLE public.legacy_procurement_receipt_import_sources ENABLE ALWAYS TRIGGER trg_guard_legacy_receipt_import_evidence;
CREATE TRIGGER trg_audit_legacy_procurement_receipt_import_sources AFTER INSERT OR UPDATE OR DELETE
    ON public.legacy_procurement_receipt_import_sources FOR EACH ROW EXECUTE FUNCTION public.fn_audit();
ALTER TABLE public.legacy_procurement_receipt_import_sources ENABLE ALWAYS TRIGGER trg_audit_legacy_procurement_receipt_import_sources;

CREATE FUNCTION public.fn_register_legacy_receipt_import_source(p_run_id uuid,p_kind text,p_source jsonb) RETURNS uuid
LANGUAGE plpgsql SET search_path=pg_catalog,public,pg_temp AS $$
DECLARE mapping record; keys text[]; payload jsonb; record_id uuid:=gen_random_uuid(); fields text[]; original_id integer;
BEGIN
    SELECT * INTO mapping FROM public.fn_legacy_receipt_import_kind(p_kind);
    IF NOT FOUND THEN RAISE EXCEPTION 'unsupported original receipt source kind' USING ERRCODE='23514'; END IF;
    PERFORM public.fn_require_legacy_bootstrap(p_run_id,mapping.source_file);
    IF jsonb_typeof(p_source) IS DISTINCT FROM 'object' THEN
        RAISE EXCEPTION 'legacy receipt source must be the complete typed original row' USING ERRCODE='23514';
    END IF;
    SELECT array_agg(key ORDER BY key) INTO keys FROM jsonb_object_keys(p_source) key;
    original_id:=(p_source->>'legacy_id')::integer;
    IF keys IS DISTINCT FROM (SELECT array_agg(key ORDER BY key) FROM unnest(mapping.source_keys) key)
       OR original_id IS NULL OR original_id<=0 THEN
        RAISE EXCEPTION 'legacy receipt source shape or identity is not authoritative' USING ERRCODE='23514';
    END IF;
    payload:=public.fn_legacy_receipt_source_projection(p_kind,p_source)
        ||jsonb_build_object('id',record_id,'legacy_import_run_id',p_run_id);
    SELECT array_agg(key ORDER BY key) INTO fields FROM jsonb_object_keys(payload) key;
    INSERT INTO public.legacy_procurement_receipt_import_sources(run_id,source_kind,source_legacy_id,target_table,target_id,
        source_file,source_row_sha256,source_file_sha256,target_fields,target_snapshot_sha256,issued_txid)
    SELECT p_run_id,p_kind,original_id,mapping.target_table,record_id,mapping.source_file,
        encode(public.digest(p_source::text,'sha256'),'hex'),sha256,fields,
        encode(public.digest(public.fn_legacy_finance_snapshot(payload,fields)::text,'sha256'),'hex'),txid_current()
    FROM public.legacy_migration_run_files WHERE run_id=p_run_id AND file_name=mapping.source_file;
    RETURN record_id;
END; $$;

CREATE FUNCTION public.fn_assert_legacy_receipt_import_source(p_table text,p_row jsonb) RETURNS void
LANGUAGE plpgsql SET search_path=pg_catalog,public,pg_temp AS $$
DECLARE proof public.legacy_procurement_receipt_import_sources%ROWTYPE; run uuid;
BEGIN
    run:=(p_row->>'legacy_import_run_id')::uuid;
    SELECT * INTO proof FROM public.legacy_procurement_receipt_import_sources
      WHERE run_id=run AND target_id=(p_row->>'id')::uuid AND target_table=p_table
        AND source_legacy_id=(p_row->>'legacy_id')::integer;
    IF NOT FOUND OR proof.issued_txid<>txid_current() THEN
        RAISE EXCEPTION 'legacy receipt row has no exact source proof in this transaction' USING ERRCODE='23514';
    END IF;
    PERFORM public.fn_require_legacy_bootstrap(run,proof.source_file);
    IF proof.target_snapshot_sha256 IS DISTINCT FROM
       encode(public.digest(public.fn_legacy_finance_snapshot(p_row,proof.target_fields)::text,'sha256'),'hex') THEN
        RAISE EXCEPTION 'legacy receipt does not match its original source projection' USING ERRCODE='23514';
    END IF;
END; $$;

CREATE FUNCTION public.fn_guard_legacy_receipt_source_facts() RETURNS trigger
LANGUAGE plpgsql SET search_path=pg_catalog,public,pg_temp AS $$
DECLARE previous jsonb; next_row jsonb; parent_table text; parent_id uuid; parent_imported boolean; previous_parent_imported boolean;
    mutable_fields text[];
BEGIN
    previous:=CASE WHEN TG_OP='INSERT' THEN NULL ELSE to_jsonb(OLD) END;
    next_row:=CASE WHEN TG_OP='DELETE' THEN NULL ELSE to_jsonb(NEW) END;
    IF TG_OP='INSERT' AND (next_row->>'legacy_id' IS NOT NULL OR next_row->>'legacy_import_run_id' IS NOT NULL) THEN
        PERFORM public.fn_assert_legacy_receipt_import_source(TG_TABLE_NAME,next_row);
    END IF;
    -- An exact old header never authorizes arbitrary new or rebound child rows.
    IF TG_TABLE_NAME IN('purchase_receipt_items','subcontract_receipt_items') THEN
        parent_table:=CASE TG_TABLE_NAME WHEN 'purchase_receipt_items' THEN 'purchase_receipts' ELSE 'subcontract_receipts' END;
        IF TG_OP<>'INSERT' THEN
            EXECUTE format('SELECT legacy_id IS NOT NULL OR legacy_import_run_id IS NOT NULL FROM public.%I WHERE id=$1',parent_table)
                INTO previous_parent_imported USING (previous->>'receipt_id')::uuid;
        END IF;
        parent_id:=(next_row->>'receipt_id')::uuid;
        IF parent_id IS NOT NULL THEN
            EXECUTE format('SELECT legacy_id IS NOT NULL OR legacy_import_run_id IS NOT NULL FROM public.%I WHERE id=$1',parent_table)
                INTO parent_imported USING parent_id;
            IF COALESCE(parent_imported,false) AND TG_OP='INSERT' THEN
                PERFORM public.fn_assert_legacy_receipt_import_source(TG_TABLE_NAME,next_row);
            ELSIF COALESCE(parent_imported,false) AND next_row->'receipt_id' IS DISTINCT FROM previous->'receipt_id' THEN
                RAISE EXCEPTION 'existing item cannot be rebound to an original legacy receipt' USING ERRCODE='23514';
            END IF;
        END IF;
    END IF;
    IF TG_OP<>'INSERT' AND (previous->>'legacy_id' IS NOT NULL OR previous->>'legacy_import_run_id' IS NOT NULL
        OR COALESCE(previous_parent_imported,false)) THEN
        mutable_fields:=CASE WHEN TG_TABLE_NAME IN('purchase_receipts','subcontract_receipts')
            THEN ARRAY['updated_at','updated_by','is_closed']
            ELSE ARRAY['updated_at','updated_by','returned_qty','gift_returned_qty'] END;
        IF TG_OP='DELETE' OR (next_row-mutable_fields) IS DISTINCT FROM (previous-mutable_fields) THEN
            RAISE EXCEPTION 'original legacy receipt commercial and source facts are immutable' USING ERRCODE='55000';
        END IF;
    ELSIF TG_OP='UPDATE' AND (next_row->'legacy_id' IS DISTINCT FROM previous->'legacy_id'
        OR next_row->'legacy_import_run_id' IS DISTINCT FROM previous->'legacy_import_run_id') THEN
        RAISE EXCEPTION 'receipt legacy provenance cannot be added, rebound or cleared' USING ERRCODE='23514';
    END IF;
    IF TG_OP='DELETE' THEN RETURN OLD; END IF;
    RETURN NEW;
END; $$;
DO $source_guards$
DECLARE target text;
BEGIN
    FOREACH target IN ARRAY ARRAY['purchase_receipts','purchase_receipt_items','subcontract_receipts','subcontract_receipt_items'] LOOP
        EXECUTE format('CREATE TRIGGER trg_zz_legacy_receipt_source_facts BEFORE INSERT OR UPDATE OR DELETE ON public.%I '
            'FOR EACH ROW EXECUTE FUNCTION public.fn_guard_legacy_receipt_source_facts()',target);
        EXECUTE format('ALTER TABLE public.%I ENABLE ALWAYS TRIGGER trg_zz_legacy_receipt_source_facts',target);
    END LOOP;
END;
$source_guards$;

-- A new receipt cannot consume capacity computed by guessing a historical
-- conversion. Original zero-quantity rows make no contribution to that sum.
CREATE FUNCTION public.fn_guard_receipt_legacy_capacity_basis() RETURNS trigger
LANGUAGE plpgsql SET search_path=pg_catalog,public,pg_temp AS $$
DECLARE headers text; ambiguous boolean;
BEGIN
    IF NEW.legacy_id IS NOT NULL OR NEW.legacy_import_run_id IS NOT NULL OR NEW.order_item_id IS NULL THEN RETURN NEW; END IF;
    headers:=CASE TG_TABLE_NAME WHEN 'purchase_receipt_items' THEN 'purchase_receipts' ELSE 'subcontract_receipts' END;
    EXECUTE format('SELECT EXISTS(SELECT 1 FROM public.%I item JOIN public.%I receipt ON receipt.id=item.receipt_id '
        'WHERE item.order_item_id=$1 AND NOT item.is_deleted AND receipt.status=1 AND NOT receipt.is_deleted '
        'AND (item.legacy_id IS NOT NULL OR item.legacy_import_run_id IS NOT NULL OR receipt.legacy_id IS NOT NULL) '
        'AND item.qty<>0 AND (item.unit_id IS NULL OR item.unit_rate IS NULL OR item.unit_rate<=0))',TG_TABLE_NAME,headers)
        INTO ambiguous USING NEW.order_item_id;
    IF ambiguous THEN
        RAISE EXCEPTION 'new receipt capacity requires review of the original historical unit conversion'
            USING ERRCODE='23514',CONSTRAINT='legacy_receipt_capacity_basis_guard';
    END IF;
    RETURN NEW;
END; $$;
CREATE TRIGGER trg_legacy_receipt_capacity_basis BEFORE INSERT OR UPDATE OF order_item_id,receipt_id,qty,unit_id,unit_rate
    ON public.purchase_receipt_items FOR EACH ROW EXECUTE FUNCTION public.fn_guard_receipt_legacy_capacity_basis();
CREATE TRIGGER trg_legacy_receipt_capacity_basis BEFORE INSERT OR UPDATE OF order_item_id,receipt_id,qty,unit_id,unit_rate
    ON public.subcontract_receipt_items FOR EACH ROW EXECUTE FUNCTION public.fn_guard_receipt_legacy_capacity_basis();
ALTER TABLE public.purchase_receipt_items ENABLE ALWAYS TRIGGER trg_legacy_receipt_capacity_basis;
ALTER TABLE public.subcontract_receipt_items ENABLE ALWAYS TRIGGER trg_legacy_receipt_capacity_basis;

REVOKE ALL ON public.legacy_procurement_receipt_import_sources FROM PUBLIC;
REVOKE ALL ON FUNCTION public.fn_register_legacy_receipt_import_source(uuid,text,jsonb) FROM PUBLIC;
DO $source_privileges$
BEGIN
    IF EXISTS(SELECT 1 FROM pg_catalog.pg_roles WHERE rolname='uten') THEN
        REVOKE ALL ON public.legacy_procurement_receipt_import_sources FROM uten;
        GRANT SELECT ON public.legacy_procurement_receipt_import_sources TO uten;
        REVOKE ALL ON FUNCTION public.fn_register_legacy_receipt_import_source(uuid,text,jsonb) FROM uten;
    END IF;
    IF EXISTS(SELECT 1 FROM pg_catalog.pg_roles WHERE rolname='uten_migrator') THEN
        GRANT SELECT,INSERT ON public.legacy_procurement_receipt_import_sources TO uten_migrator;
        GRANT EXECUTE ON FUNCTION public.fn_register_legacy_receipt_import_source(uuid,text,jsonb) TO uten_migrator;
    END IF;
END;
$source_privileges$;

DO $reset_policy$
DECLARE definition text; anchor text:='(''stock_movements'', ''CLEAR'')';
BEGIN
    SELECT pg_get_functiondef('public.business_data_reset()'::regprocedure) INTO definition;
    IF (length(definition)-length(replace(definition,anchor,'')))/length(anchor)<>1 THEN
        RAISE EXCEPTION 'V627 cannot extend business-data reset policy safely';
    END IF;
    EXECUTE replace(definition,anchor,anchor||E',\n            (''legacy_procurement_receipt_import_sources'', ''PRESERVE'')');
END;
$reset_policy$;

CREATE OR REPLACE FUNCTION public.fn_mark_procurement_consideration_required()
 RETURNS trigger
 LANGUAGE plpgsql
 SET search_path=pg_catalog,public,pg_temp
AS $function$
BEGIN
    IF TG_OP='INSERT' AND NEW.legacy_import_run_id IS NOT NULL THEN
        NEW.consideration_required:=FALSE;
        PERFORM public.fn_assert_legacy_receipt_import_source(TG_TABLE_NAME,to_jsonb(NEW));
        RETURN NEW;
    END IF;
    IF TG_OP='INSERT' OR (NEW.status=1 AND OLD.status IS DISTINCT FROM 1) THEN
        NEW.consideration_required:=TRUE;
    ELSIF OLD.consideration_required AND NOT NEW.consideration_required THEN
        RAISE EXCEPTION 'receipt consideration requirement cannot be removed'
            USING ERRCODE='23514',CONSTRAINT=TG_NAME;
    END IF;
    RETURN NEW;
END;
$function$;

-- Only the original explicit positive document rate can establish book money.
CREATE FUNCTION public.fn_legacy_source_book_amount(p_original numeric,p_source_rate numeric) RETURNS numeric
LANGUAGE sql IMMUTABLE SET search_path=pg_catalog,public,pg_temp AS $$
    SELECT CASE WHEN p_source_rate>0 THEN p_original*p_source_rate ELSE NULL END
$$;

CREATE OR REPLACE FUNCTION public.fn_register_legacy_subcontract_order_source(p_run_id uuid, p_source jsonb)
 RETURNS uuid
 LANGUAGE plpgsql
 SET search_path TO 'pg_catalog', 'public'
AS $function$
DECLARE
    expected public.subcontract_orders%ROWTYPE;
    result uuid := gen_random_uuid();
    keys text[];
BEGIN
    PERFORM public.fn_require_legacy_subcontract_bootstrap(p_run_id);
    IF jsonb_typeof(p_source) IS DISTINCT FROM 'object' THEN
        RAISE EXCEPTION USING ERRCODE='23514', MESSAGE='E_Order source must be the complete typed source row';
    END IF;
    SELECT array_agg(key ORDER BY key) INTO keys FROM jsonb_object_keys(p_source) key;
    IF keys IS DISTINCT FROM ARRAY['approver_legacy','bill_date','bill_no','cancel_bit','currency_legacy_id',
        'deliver_date','exchange_rate','fulfill_bit','legacy_id','maker_legacy','remark','send_legacy',
        'status','stop_bit','supplier_legacy_id','tax_rate','total_original']::text[]
       OR (p_source->>'status')::smallint IS DISTINCT FROM 1::smallint
       OR (p_source->>'legacy_id')::integer IS NULL OR (p_source->>'legacy_id')::integer<=0 THEN
        RAISE EXCEPTION USING ERRCODE='23514', MESSAGE='E_Order evidence has an unsupported source shape or state';
    END IF;
    expected.legacy_id := (p_source->>'legacy_id')::integer;
    expected.bill_no := p_source->>'bill_no';
    expected.bill_date := (p_source->>'bill_date')::date;
    expected.supplier_id := (SELECT id FROM public.suppliers WHERE legacy_id=(p_source->>'supplier_legacy_id')::integer);
    expected.currency_id := (SELECT id FROM public.currencies WHERE legacy_id=(p_source->>'currency_legacy_id')::integer);
    expected.exchange_rate := (p_source->>'exchange_rate')::numeric;
    expected.tax_rate := (p_source->>'tax_rate')::numeric;
    expected.deliver_date := (p_source->>'deliver_date')::date;
    expected.remark := p_source->>'remark';
    expected.total_original := (p_source->>'total_original')::numeric;
    expected.total_local := public.fn_legacy_source_book_amount(expected.total_original,expected.exchange_rate);
    expected.status := 1;
    expected.fulfill := COALESCE((p_source->>'fulfill_bit')::boolean,false);
    expected.is_closed := expected.fulfill;
    INSERT INTO public.legacy_subcontract_order_import_sources(run_id,source_legacy_id,order_id,
        source_row_sha256,source_file_sha256,expected_header_sha256,issued_txid)
    SELECT p_run_id,expected.legacy_id,result,encode(public.digest(p_source::text,'sha256'),'hex'),sha256,
        encode(public.digest(public.fn_legacy_subcontract_header_snapshot(expected)::text,'sha256'),'hex'),txid_current()
    FROM public.legacy_migration_run_files WHERE run_id=p_run_id AND file_name='subcontract_order_m.csv';
    RETURN result;
END; $function$;
