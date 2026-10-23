CREATE TYPE public.legacy_production_plan_counter_source_row AS (
    legacy_id int, plan_legacy_id int, product_no text,
    goods_legacy_id int, color_legacy_id int, mgoods_legacy_id int,
    unit_legacy_id int, unit_rate numeric(18,6),
    s_order_item_legacy int, sales_order_no text, client_name text, client_no text,
    oqty numeric(18,4), qty numeric(18,4), lqty numeric(18,4), iqty numeric(18,4),
    fqty numeric(18,4), rqty numeric(18,4), bqty numeric(18,4), tqty numeric(18,4),
    paqty numeric(18,4), isrqty numeric(18,4), cpqty numeric(18,4),
    poqty numeric(18,4), piqty numeric(18,4),
    order_date date, outbound_date date, plan_begin_date date, plan_end_date date,
    finished_weight numeric(18,4), inbound_weight numeric(18,4),
    lstatus smallint, cstatus smallint,
    step_legacy_id int, veil_legacy_id int, ass_team_legacy_id int, fittings text,
    request_note text, customer_model text, discount numeric(18,4),
    label_no text, plan_app_no text, in_no text, tran_no text, remark text);
CREATE TYPE public.legacy_production_plan_counter_parent_row AS (
    legacy_id int, bill_no text, bill_date date, f_style text, delivery_date date,
    workshop_name text, worker_name text, seller_name text,
    maker_legacy int, approver_legacy int,
    remark text, status smallint,
    fulfill_bit boolean, stop_bit boolean, cancel_bit boolean);

-- Exact first-bootstrap historical counters, never modern production capacity.
CREATE TABLE public.legacy_production_plan_counter_import_contexts (
 run_id uuid PRIMARY KEY REFERENCES public.legacy_migration_runs(run_id) ON DELETE RESTRICT,
 issued_txid bigint NOT NULL,
 origin_system_identifier text NOT NULL,
 origin_database_oid oid NOT NULL,
 origin_database_name text NOT NULL,
 evidence jsonb NOT NULL CHECK(jsonb_typeof(evidence)='object' AND pg_column_size(evidence)<=8192),
 evidence_sha256 char(64) NOT NULL CHECK(evidence_sha256 ~ '^[0-9a-f]{64}$'),
 created_at timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX idx_legacy_production_context_issued_txid ON public.legacy_production_plan_counter_import_contexts(issued_txid);
CREATE TABLE public.legacy_production_plan_counter_import_sources (
 id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
 run_id uuid NOT NULL REFERENCES public.legacy_migration_runs(run_id) ON DELETE RESTRICT,
 source_kind text NOT NULL CHECK(source_kind='PRODUCTION_PLAN_ITEM'),
 source_legacy_id integer NOT NULL CHECK(source_legacy_id>0),
 source_parent_legacy_id integer NOT NULL CHECK(source_parent_legacy_id>0),
 target_table text NOT NULL CHECK(target_table='production_plan_items'),
 target_id uuid NOT NULL UNIQUE,
 target_plan_id uuid NOT NULL,
 source_file text NOT NULL CHECK(source_file='production_plan_items.csv'),
 source_parent_file text NOT NULL CHECK(source_parent_file='production_plans.csv'),
 source_file_sha256 char(64) NOT NULL CHECK(source_file_sha256 ~ '^[0-9a-f]{64}$'),
 source_parent_file_sha256 char(64) NOT NULL CHECK(source_parent_file_sha256 ~ '^[0-9a-f]{64}$'),
 source_row_sha256 char(64) NOT NULL CHECK(source_row_sha256 ~ '^[0-9a-f]{64}$'),
 source_parent_row_sha256 char(64) NOT NULL CHECK(source_parent_row_sha256 ~ '^[0-9a-f]{64}$'),
 source_reference_legacy_ids jsonb NOT NULL,
 parent_identity_sha256 char(64) NOT NULL,
 run_evidence_sha256 char(64) NOT NULL,
 target_fields text[] NOT NULL,
 target_snapshot_sha256 char(64) NOT NULL,
 issued_txid bigint NOT NULL,
 created_at timestamptz NOT NULL DEFAULT now(),
 UNIQUE(run_id,source_legacy_id), UNIQUE(run_id,target_id)
);
ALTER TABLE public.legacy_production_plan_counter_import_sources ADD CONSTRAINT legacy_production_source_context_fk
 FOREIGN KEY(run_id) REFERENCES public.legacy_production_plan_counter_import_contexts(run_id) ON DELETE RESTRICT;
CREATE INDEX idx_legacy_production_source_parent ON public.legacy_production_plan_counter_import_sources(run_id,target_plan_id);
CREATE INDEX idx_legacy_production_source_goods ON public.legacy_production_plan_counter_import_sources(run_id,(source_reference_legacy_ids->>'goods_legacy_id'));
CREATE INDEX idx_legacy_production_source_mgoods ON public.legacy_production_plan_counter_import_sources(run_id,(source_reference_legacy_ids->>'mgoods_legacy_id'));
CREATE INDEX idx_legacy_production_source_color ON public.legacy_production_plan_counter_import_sources(run_id,(source_reference_legacy_ids->>'color_legacy_id'));
CREATE INDEX idx_legacy_production_source_unit ON public.legacy_production_plan_counter_import_sources(run_id,(source_reference_legacy_ids->>'unit_legacy_id'));
CREATE INDEX idx_legacy_production_source_upstream ON public.legacy_production_plan_counter_import_sources(run_id,(source_reference_legacy_ids->>'s_order_item_legacy'));
COMMENT ON TABLE public.legacy_production_plan_counter_import_sources IS
 'PRESERVE: exact initial legacy production counters, not surplus/approval/capacity; no original personal text';
ALTER TABLE public.production_plan_items ADD COLUMN legacy_production_import_run_id uuid;
ALTER TABLE public.production_plan_items ADD CONSTRAINT production_plan_items_legacy_counter_proof_fk
 FOREIGN KEY(legacy_production_import_run_id,id)
 REFERENCES public.legacy_production_plan_counter_import_sources(run_id,target_id) ON DELETE RESTRICT;

CREATE FUNCTION public.fn_legacy_production_plan_counter_bound_fields() RETURNS text[] LANGUAGE sql IMMUTABLE AS $$
 SELECT array_agg(k ORDER BY k) FROM unnest(ARRAY[
 'id','legacy_production_import_run_id','legacy_id','bill_no','bill_date','plan_id','line_no','product_no',
 'goods_id','color_id','mgoods_id','unit_id','unit_rate','sales_order_item_id','sales_order_no','client_name','client_no',
 'oqty','qty','lqty','iqty','fqty','rqty','bqty','tqty','paqty','isrqty','cpqty','poqty','piqty',
 'order_date','outbound_date','plan_begin_date','plan_end_date','finished_weight','inbound_weight','lstatus','cstatus',
 'step_legacy_id','veil_legacy_id','ass_team_legacy_id','fittings','request_note','customer_model','discount','label_no',
 'plan_app_no','source_doc_no','remark','is_deleted','capped_qty','allowed_overproduction_rate','allowed_overproduction_rate_source']) k
$$;

DO $projection_schema$
DECLARE actual text[];
BEGIN
 SELECT array_agg(attname::text ORDER BY attname) INTO actual FROM pg_catalog.pg_attribute
 WHERE attrelid='public.production_plan_items'::regclass AND attnum>0 AND NOT attisdropped
 AND attname NOT IN('created_at','updated_at','created_by','updated_by');
 IF actual IS DISTINCT FROM public.fn_legacy_production_plan_counter_bound_fields() THEN
  RAISE EXCEPTION 'V913 full production business projection schema changed';
 END IF;
END $projection_schema$;

CREATE FUNCTION public.fn_legacy_production_plan_parent_identity(p_id uuid) RETURNS jsonb
LANGUAGE sql STABLE SET search_path=pg_catalog,public,pg_temp AS $$
 SELECT jsonb_build_object('id',p.id,'legacy_id',p.legacy_id,'bill_no',p.bill_no,'bill_date',p.bill_date)
 FROM public.production_plans p WHERE p.id=p_id
$$;
CREATE FUNCTION public.fn_legacy_production_plan_run_evidence(p_run uuid) RETURNS jsonb
LANGUAGE sql STABLE SET search_path=pg_catalog,public,pg_temp AS $$
 SELECT jsonb_build_object('run_id',r.run_id,'target',r.target,'migration_mode',r.migration_mode,
 'database_user',r.database_user,'export_manifest_sha256',r.export_manifest_sha256,
 'checksum_manifest_sha256',r.checksum_manifest_sha256,'migration_repository_commit',r.migration_repository_commit,
 'migration_script_sha256',r.migration_script_sha256,'mapping_version',r.mapping_version,
 'source_backup_sha256',r.source_backup_sha256,'export_approval_reference',r.export_approval_reference,
 'targetDatabase',r.reconciliation_summary->'targetDatabase',
 'targetSystemIdentifier',r.reconciliation_summary->'targetSystemIdentifier',
 'targetApprovalReference',r.reconciliation_summary->'targetApprovalReference',
 'importAtomicity',r.reconciliation_summary->'importAtomicity',
 'sourceSnapshotAsOfUtc',r.reconciliation_summary->'sourceSnapshotAsOfUtc')
 FROM public.legacy_migration_runs r WHERE r.run_id=p_run
$$;

-- No summary column is selected by this terminal-path primitive oracle.
CREATE FUNCTION public.fn_legacy_production_plan_run_primitives(p_run uuid) RETURNS jsonb
LANGUAGE sql STABLE SET search_path=pg_catalog,public,pg_temp AS $$
 SELECT jsonb_build_object('run_id',r.run_id,'target',r.target,'migration_mode',r.migration_mode,
 'database_user',r.database_user,'export_manifest_sha256',r.export_manifest_sha256,
 'checksum_manifest_sha256',r.checksum_manifest_sha256,'migration_repository_commit',r.migration_repository_commit,
 'migration_script_sha256',r.migration_script_sha256,'mapping_version',r.mapping_version,
 'source_backup_sha256',r.source_backup_sha256,'export_approval_reference',r.export_approval_reference)
 FROM public.legacy_migration_runs r WHERE r.run_id=p_run
$$;

-- This tiny read-only helper also works for ordinary non-superuser updates on
-- a restored copy; no application session needs direct control-file access.
CREATE FUNCTION public.fn_legacy_production_origin_matches(p_system text,p_oid oid,p_name text) RETURNS boolean
LANGUAGE sql STABLE SECURITY DEFINER SET search_path=pg_catalog AS $$
 SELECT p_name=current_database() AND p_oid=(SELECT oid FROM pg_catalog.pg_database WHERE datname=current_database())
 AND p_system=(SELECT system_identifier::text FROM pg_catalog.pg_control_system())
$$;

CREATE FUNCTION public.fn_guard_legacy_production_plan_context() RETURNS trigger
LANGUAGE plpgsql SET search_path=pg_catalog,public,pg_temp AS $$
BEGIN
 IF TG_OP<>'INSERT' THEN RAISE EXCEPTION 'legacy production execution context is immutable' USING ERRCODE='55000'; END IF;
 PERFORM public.fn_require_legacy_bootstrap(NEW.run_id,'production_plan_items.csv');
 PERFORM public.fn_require_legacy_bootstrap(NEW.run_id,'production_plans.csv');
 IF NOT EXISTS(SELECT 1 FROM public.legacy_migration_runs WHERE run_id=NEW.run_id
    AND mapping_version ~ '^bootstrap-v[1-9][0-9]*$'
    AND substring(mapping_version FROM '^bootstrap-v([0-9]+)$')::numeric>=17) THEN
  RAISE EXCEPTION 'legacy production initial proof requires bootstrap protocol v17 or newer' USING ERRCODE='23514';
 END IF;
 IF NEW.issued_txid<>txid_current()
 OR NOT public.fn_legacy_production_origin_matches(NEW.origin_system_identifier,NEW.origin_database_oid,NEW.origin_database_name)
 OR NEW.evidence IS DISTINCT FROM public.fn_legacy_production_plan_run_evidence(NEW.run_id)
 OR NEW.evidence_sha256 IS DISTINCT FROM encode(public.digest(NEW.evidence::text,'sha256'),'hex') THEN
  RAISE EXCEPTION 'legacy production context differs from its original execution identity' USING ERRCODE='23514';
 END IF;
 RETURN NEW;
END $$;
CREATE TRIGGER trg_guard_legacy_production_plan_context BEFORE INSERT OR UPDATE OR DELETE
 ON public.legacy_production_plan_counter_import_contexts FOR EACH ROW EXECUTE FUNCTION public.fn_guard_legacy_production_plan_context();
ALTER TABLE public.legacy_production_plan_counter_import_contexts ENABLE ALWAYS TRIGGER trg_guard_legacy_production_plan_context;
SELECT public.fn_audit_track_table('legacy_production_plan_counter_import_contexts','NONE','system',false);

CREATE FUNCTION public.fn_prepare_legacy_production_plan_context(p_run uuid) RETURNS void
LANGUAGE plpgsql SET search_path=pg_catalog,public,pg_temp AS $$
DECLARE identity jsonb; context public.legacy_production_plan_counter_import_contexts%ROWTYPE;
BEGIN
 -- fn_require locks the real run row FOR UPDATE; keep that lock through COMMIT
 -- so another transaction cannot miss our uncommitted context and alter it.
 PERFORM public.fn_require_legacy_bootstrap(p_run,'production_plan_items.csv');
 PERFORM public.fn_require_legacy_bootstrap(p_run,'production_plans.csv');
 SELECT * INTO context FROM public.legacy_production_plan_counter_import_contexts WHERE run_id=p_run;
 IF FOUND THEN
  IF context.issued_txid<>txid_current() OR NOT public.fn_legacy_production_origin_matches(
     context.origin_system_identifier,context.origin_database_oid,context.origin_database_name) THEN
   RAISE EXCEPTION 'legacy production execution context cannot be reused in another transaction or database' USING ERRCODE='23514';
  END IF;
  RETURN;
 END IF;
 identity:=public.fn_legacy_production_plan_run_evidence(p_run);
 INSERT INTO public.legacy_production_plan_counter_import_contexts(run_id,issued_txid,origin_system_identifier,
 origin_database_oid,origin_database_name,evidence,evidence_sha256)
 SELECT p_run,txid_current(),system_identifier::text,(SELECT oid FROM pg_catalog.pg_database WHERE datname=current_database()),
 current_database(),identity,encode(public.digest(identity::text,'sha256'),'hex') FROM pg_catalog.pg_control_system();
END $$;

CREATE FUNCTION public.fn_guard_legacy_production_run_identity() RETURNS trigger
LANGUAGE plpgsql SET search_path=pg_catalog,public,pg_temp AS $$
DECLARE context public.legacy_production_plan_counter_import_contexts%ROWTYPE; identity jsonb; summary_identity jsonb;
BEGIN
 SELECT * INTO context FROM public.legacy_production_plan_counter_import_contexts WHERE run_id=OLD.run_id;
 IF NOT FOUND THEN RETURN NEW; END IF;
 -- Parse the summary once per RUN update, never once per deferred source row.
 SELECT to_jsonb(x) INTO summary_identity FROM jsonb_to_record(NEW.reconciliation_summary) AS x(
 "targetDatabase" text,"targetSystemIdentifier" text,"targetApprovalReference" text,
 "importAtomicity" text,"sourceSnapshotAsOfUtc" text);
 identity:=jsonb_build_object('run_id',NEW.run_id,'target',NEW.target,'migration_mode',NEW.migration_mode,
 'database_user',NEW.database_user,'export_manifest_sha256',NEW.export_manifest_sha256,
 'checksum_manifest_sha256',NEW.checksum_manifest_sha256,'migration_repository_commit',NEW.migration_repository_commit,
 'migration_script_sha256',NEW.migration_script_sha256,'mapping_version',NEW.mapping_version,
 'source_backup_sha256',NEW.source_backup_sha256,'export_approval_reference',NEW.export_approval_reference)||summary_identity;
 IF identity IS DISTINCT FROM context.evidence THEN
  RAISE EXCEPTION 'admitted legacy production run identity cannot be changed' USING ERRCODE='23514';
 END IF;
 RETURN NEW;
END $$;
CREATE TRIGGER trg_guard_legacy_production_run_identity BEFORE UPDATE ON public.legacy_migration_runs
 FOR EACH ROW EXECUTE FUNCTION public.fn_guard_legacy_production_run_identity();
ALTER TABLE public.legacy_migration_runs ENABLE ALWAYS TRIGGER trg_guard_legacy_production_run_identity;

CREATE FUNCTION public.fn_guard_legacy_production_source_file_identity() RETURNS trigger
LANGUAGE plpgsql SET search_path=pg_catalog,public,pg_temp AS $$
BEGIN
 IF OLD.file_name IN('production_plan_items.csv','production_plans.csv')
 AND EXISTS(SELECT 1 FROM public.legacy_production_plan_counter_import_contexts WHERE run_id=OLD.run_id) THEN
  IF TG_OP='DELETE' THEN RAISE EXCEPTION 'admitted production source file identity cannot be deleted' USING ERRCODE='55000'; END IF;
  IF (NEW.run_id,NEW.file_name,NEW.sha256,NEW.byte_size) IS DISTINCT FROM (OLD.run_id,OLD.file_name,OLD.sha256,OLD.byte_size) THEN
   RAISE EXCEPTION 'admitted production source file identity cannot be changed' USING ERRCODE='23514';
  END IF;
 END IF;
 RETURN COALESCE(NEW,OLD);
END $$;
CREATE TRIGGER trg_guard_legacy_production_source_file_identity BEFORE UPDATE OR DELETE ON public.legacy_migration_run_files
 FOR EACH ROW EXECUTE FUNCTION public.fn_guard_legacy_production_source_file_identity();
ALTER TABLE public.legacy_migration_run_files ENABLE ALWAYS TRIGGER trg_guard_legacy_production_source_file_identity;

-- Protect actual reference identities even after an early SET CONSTRAINTS.
-- No state/department/owner fields participate, and later transactions retain
-- their existing rules. New unrelated master records remain valid.
CREATE FUNCTION public.fn_guard_legacy_production_reference_identity() RETURNS trigger
LANGUAGE plpgsql SET search_path=pg_catalog,public,pg_temp AS $$
DECLARE context record; keys text[]; key text; ids text[]; touched boolean; parent_id uuid;
BEGIN
 IF TG_TABLE_NAME='production_plans' THEN parent_id:=OLD.id;
 ELSE
  keys:=CASE TG_TABLE_NAME WHEN 'goods' THEN ARRAY['goods_legacy_id','mgoods_legacy_id']
   WHEN 'colors' THEN ARRAY['color_legacy_id'] WHEN 'units' THEN ARRAY['unit_legacy_id']
   WHEN 'sales_order_items' THEN ARRAY['s_order_item_legacy'] ELSE NULL END;
  ids:=CASE WHEN TG_OP='INSERT' THEN ARRAY[NEW.legacy_id::text] ELSE ARRAY[OLD.legacy_id::text,NEW.legacy_id::text] END;
 END IF;
 FOR context IN SELECT run_id,origin_system_identifier,origin_database_oid,origin_database_name
  FROM public.legacy_production_plan_counter_import_contexts WHERE issued_txid=txid_current() LOOP
  IF public.fn_legacy_production_origin_matches(context.origin_system_identifier,context.origin_database_oid,context.origin_database_name) THEN
   IF TG_TABLE_NAME='production_plans' THEN
    SELECT EXISTS(SELECT 1 FROM public.legacy_production_plan_counter_import_sources WHERE run_id=context.run_id AND target_plan_id=parent_id) INTO touched;
    IF touched THEN RAISE EXCEPTION 'initial production parent identity cannot change after source admission' USING ERRCODE='23514'; END IF;
   ELSE
    FOREACH key IN ARRAY keys LOOP
     EXECUTE format('SELECT EXISTS(SELECT 1 FROM public.legacy_production_plan_counter_import_sources WHERE run_id=$1 '
       'AND source_reference_legacy_ids->>%L=ANY($2) %s)',key,
       CASE WHEN key IN('color_legacy_id','mgoods_legacy_id','s_order_item_legacy') THEN 'AND source_reference_legacy_ids->>'||quote_literal(key)||'<>''0''' ELSE '' END)
      INTO touched USING context.run_id,ids;
     IF touched THEN RAISE EXCEPTION 'initial production master/reference identity cannot change after source admission' USING ERRCODE='23514'; END IF;
    END LOOP;
   END IF;
  END IF;
 END LOOP;
 RETURN NEW;
END $$;
CREATE TRIGGER trg_legacy_production_parent_identity BEFORE UPDATE OF id,legacy_id,bill_no,bill_date ON public.production_plans
 FOR EACH ROW WHEN ((OLD.id,OLD.legacy_id,OLD.bill_no,OLD.bill_date) IS DISTINCT FROM (NEW.id,NEW.legacy_id,NEW.bill_no,NEW.bill_date))
 EXECUTE FUNCTION public.fn_guard_legacy_production_reference_identity();
ALTER TABLE public.production_plans ENABLE ALWAYS TRIGGER trg_legacy_production_parent_identity;
DO $reference_guards$
DECLARE relation text;
BEGIN
 FOREACH relation IN ARRAY ARRAY['goods','colors','units','sales_order_items'] LOOP
  EXECUTE format('CREATE TRIGGER trg_legacy_production_reference_insert BEFORE INSERT ON public.%I FOR EACH ROW '
   'EXECUTE FUNCTION public.fn_guard_legacy_production_reference_identity()',relation);
  EXECUTE format('CREATE TRIGGER trg_legacy_production_reference_update BEFORE UPDATE OF legacy_id ON public.%I '
   'FOR EACH ROW WHEN(OLD.legacy_id IS DISTINCT FROM NEW.legacy_id) EXECUTE FUNCTION public.fn_guard_legacy_production_reference_identity()',relation);
  EXECUTE format('ALTER TABLE public.%I ENABLE ALWAYS TRIGGER trg_legacy_production_reference_insert',relation);
  EXECUTE format('ALTER TABLE public.%I ENABLE ALWAYS TRIGGER trg_legacy_production_reference_update',relation);
 END LOOP;
END $reference_guards$;

CREATE FUNCTION public.fn_legacy_production_plan_counter_source_projection(
 p_run uuid,s jsonb,h jsonb,p_line integer,p_target uuid) RETURNS jsonb
LANGUAGE plpgsql STABLE SET search_path=pg_catalog,public,pg_temp AS $$
DECLARE parent public.production_plans%ROWTYPE; typed jsonb; typed_parent jsonb; g uuid; c uuid; mg uuid; u uuid; so uuid;
 fields text[]; counters jsonb; payload jsonb;
BEGIN
 SELECT to_jsonb(t) INTO typed FROM jsonb_populate_record(NULL::public.legacy_production_plan_counter_source_row,s)t;
 SELECT to_jsonb(t) INTO typed_parent FROM jsonb_populate_record(NULL::public.legacy_production_plan_counter_parent_row,h)t;
 IF jsonb_typeof(s) IS DISTINCT FROM 'object' OR jsonb_typeof(h) IS DISTINCT FROM 'object'
    OR s IS DISTINCT FROM typed OR h IS DISTINCT FROM typed_parent
    OR (s->>'legacy_id')::integer IS NULL OR (s->>'legacy_id')::integer<=0
    OR (s->>'plan_legacy_id')::integer IS DISTINCT FROM (h->>'legacy_id')::integer
    OR p_line IS NULL OR p_line<=0 OR p_target IS NULL OR p_run IS NULL THEN
  RAISE EXCEPTION 'legacy production requires complete typed original item, parent and identity' USING ERRCODE='23514';
 END IF;
 -- Preserve original negative rules; other historical counters are not given new sign rules.
 IF COALESCE((s->>'qty')::numeric,0)<0 OR COALESCE((s->>'fqty')::numeric,0)<0 OR COALESCE((s->>'iqty')::numeric,0)<0 THEN
  RAISE EXCEPTION 'legacy production initial quantity, finished and inbound counters cannot be negative' USING ERRCODE='23514';
 END IF;
 IF EXISTS(SELECT 1 FROM unnest(ARRAY['oqty','qty','lqty','iqty','fqty','rqty','bqty','tqty','paqty','isrqty','cpqty','poqty','piqty']) k
   WHERE (s->>k)::numeric::text IN('NaN','Infinity','-Infinity')) THEN
  RAISE EXCEPTION 'legacy production original counters must be finite' USING ERRCODE='23514';
 END IF;
 SELECT * INTO parent FROM public.production_plans WHERE legacy_id=(s->>'plan_legacy_id')::integer;
 IF NOT FOUND OR parent.bill_no IS DISTINCT FROM h->>'bill_no' OR parent.bill_date IS DISTINCT FROM (h->>'bill_date')::date THEN
  RAISE EXCEPTION 'legacy production requires its exact original loaded parent identity' USING ERRCODE='23514';
 END IF;
 SELECT id INTO g FROM public.goods WHERE legacy_id=(s->>'goods_legacy_id')::integer;
 SELECT id INTO c FROM public.colors WHERE legacy_id=NULLIF((s->>'color_legacy_id')::integer,0);
 SELECT id INTO mg FROM public.goods WHERE legacy_id=NULLIF((s->>'mgoods_legacy_id')::integer,0);
 SELECT id INTO u FROM public.units WHERE legacy_id=(s->>'unit_legacy_id')::integer;
 SELECT id INTO so FROM public.sales_order_items WHERE legacy_id=NULLIF((s->>'s_order_item_legacy')::integer,0);
 IF g IS NULL THEN RAISE EXCEPTION 'legacy production goods identity is unresolved' USING ERRCODE='23514'; END IF;
 IF (COALESCE((s->>'color_legacy_id')::integer,0)<>0 AND c IS NULL)
 OR (COALESCE((s->>'mgoods_legacy_id')::integer,0)<>0 AND mg IS NULL)
 OR (COALESCE((s->>'unit_legacy_id')::integer,0)<>0 AND u IS NULL) THEN
  RAISE EXCEPTION 'legacy production nonzero master identity is unresolved' USING ERRCODE='23514';
 END IF;
 SELECT jsonb_object_agg(k,COALESCE((s->>k)::numeric,0)) INTO counters
 FROM unnest(ARRAY['oqty','qty','lqty','iqty','fqty','rqty','bqty','tqty','paqty','isrqty','cpqty','poqty','piqty']) k;
 payload:=jsonb_build_object('id',p_target,'legacy_production_import_run_id',p_run,
  'legacy_id',(s->>'legacy_id')::integer,'bill_no',parent.bill_no,'bill_date',parent.bill_date,
  'plan_id',parent.id,'line_no',p_line,'product_no',s->'product_no','goods_id',g,'color_id',c,'mgoods_id',mg,
  'unit_id',u,'unit_rate',COALESCE((s->>'unit_rate')::numeric,1),'sales_order_item_id',so,
  'sales_order_no',NULLIF(s->>'sales_order_no',''),'client_name',NULLIF(s->>'client_name',''),'client_no',NULLIF(s->>'client_no',''))
  ||counters||jsonb_build_object('order_date',(s->>'order_date')::date,'outbound_date',(s->>'outbound_date')::date,
  'plan_begin_date',(s->>'plan_begin_date')::date,'plan_end_date',(s->>'plan_end_date')::date,
  'finished_weight',(s->>'finished_weight')::numeric,'inbound_weight',(s->>'inbound_weight')::numeric,
  'lstatus',(s->>'lstatus')::smallint,'cstatus',(s->>'cstatus')::smallint,
  'step_legacy_id',(s->>'step_legacy_id')::integer,'veil_legacy_id',(s->>'veil_legacy_id')::integer,
  'ass_team_legacy_id',(s->>'ass_team_legacy_id')::integer,'fittings',NULLIF(s->>'fittings',''),
  'request_note',NULLIF(s->>'request_note',''),'customer_model',NULLIF(s->>'customer_model',''),
  'discount',(s->>'discount')::numeric,'label_no',NULLIF(s->>'label_no',''),'plan_app_no',NULLIF(s->>'plan_app_no',''),
  'source_doc_no',CONCAT_WS(' | ',CASE WHEN NULLIF(s->>'in_no','') IS NOT NULL THEN 'IN:'||(s->>'in_no') END,
    CASE WHEN NULLIF(s->>'tran_no','') IS NOT NULL THEN 'TRAN:'||(s->>'tran_no') END),'remark',NULLIF(s->>'remark',''),
  'is_deleted',false,'capped_qty',NULL,'allowed_overproduction_rate',public.fn_goods_default_overproduction_rate(g),
  'allowed_overproduction_rate_source','DEFAULT');
 SELECT array_agg(k ORDER BY k) INTO fields FROM jsonb_object_keys(payload) k;
 IF fields IS DISTINCT FROM public.fn_legacy_production_plan_counter_bound_fields() THEN
  RAISE EXCEPTION 'legacy production complete target projection differs from its declared schema' USING ERRCODE='23514';
 END IF;
 RETURN payload;
END $$;

CREATE FUNCTION public.fn_guard_legacy_production_plan_counter_proof() RETURNS trigger
LANGUAGE plpgsql SET search_path=pg_catalog,public,pg_temp AS $$
BEGIN
 IF TG_OP<>'INSERT' THEN RAISE EXCEPTION 'legacy production source proof is immutable' USING ERRCODE='55000'; END IF;
 PERFORM public.fn_require_legacy_bootstrap(NEW.run_id,NEW.source_file);
 PERFORM public.fn_require_legacy_bootstrap(NEW.run_id,NEW.source_parent_file);
 IF NEW.issued_txid<>txid_current() OR NEW.target_fields IS DISTINCT FROM public.fn_legacy_production_plan_counter_bound_fields()
 OR NEW.source_file_sha256 IS DISTINCT FROM (SELECT sha256 FROM public.legacy_migration_run_files WHERE run_id=NEW.run_id AND file_name=NEW.source_file)
 OR NEW.source_parent_file_sha256 IS DISTINCT FROM (SELECT sha256 FROM public.legacy_migration_run_files WHERE run_id=NEW.run_id AND file_name=NEW.source_parent_file)
 OR NEW.run_evidence_sha256 IS DISTINCT FROM encode(public.digest(public.fn_legacy_production_plan_run_evidence(NEW.run_id)::text,'sha256'),'hex') THEN
  RAISE EXCEPTION 'legacy production proof is outside its exact source execution' USING ERRCODE='23514';
 END IF;
 RETURN NEW;
END $$;
CREATE TRIGGER trg_guard_legacy_production_plan_counter_proof BEFORE INSERT OR UPDATE OR DELETE
 ON public.legacy_production_plan_counter_import_sources FOR EACH ROW EXECUTE FUNCTION public.fn_guard_legacy_production_plan_counter_proof();
ALTER TABLE public.legacy_production_plan_counter_import_sources ENABLE ALWAYS TRIGGER trg_guard_legacy_production_plan_counter_proof;
SELECT public.fn_audit_track_table('legacy_production_plan_counter_import_sources','NONE','system',false);

CREATE FUNCTION public.fn_register_legacy_production_plan_counter_source(p_run uuid,s jsonb,h jsonb,p_line integer) RETURNS uuid
LANGUAGE plpgsql SET search_path=pg_catalog,public,pg_temp AS $$
DECLARE target uuid:=gen_random_uuid(); payload jsonb; already_exists boolean;
BEGIN
 PERFORM public.fn_require_legacy_bootstrap(p_run,'production_plan_items.csv');
 PERFORM public.fn_require_legacy_bootstrap(p_run,'production_plans.csv');
 payload:=public.fn_legacy_production_plan_counter_source_projection(p_run,s,h,p_line,target);
 PERFORM public.fn_prepare_legacy_production_plan_context(p_run);
 EXECUTE 'SELECT EXISTS(SELECT 1 FROM public.production_plan_items WHERE id=$1 OR legacy_id=$2)'
 INTO already_exists USING target,(s->>'legacy_id')::integer;
 IF already_exists THEN RAISE EXCEPTION 'legacy production proof is only issued before first target insert' USING ERRCODE='23514'; END IF;
 INSERT INTO public.legacy_production_plan_counter_import_sources(run_id,source_kind,source_legacy_id,source_parent_legacy_id,
 target_table,target_id,target_plan_id,source_file,source_parent_file,source_file_sha256,source_parent_file_sha256,
 source_row_sha256,source_parent_row_sha256,source_reference_legacy_ids,parent_identity_sha256,run_evidence_sha256,
 target_fields,target_snapshot_sha256,issued_txid)
 SELECT p_run,'PRODUCTION_PLAN_ITEM',(s->>'legacy_id')::integer,(s->>'plan_legacy_id')::integer,
 'production_plan_items',target,(payload->>'plan_id')::uuid,'production_plan_items.csv','production_plans.csv',f.sha256,p.sha256,
 encode(public.digest(s::text,'sha256'),'hex'),encode(public.digest(h::text,'sha256'),'hex'),
 jsonb_build_object('goods_legacy_id',s->'goods_legacy_id','color_legacy_id',s->'color_legacy_id',
 'mgoods_legacy_id',s->'mgoods_legacy_id','unit_legacy_id',s->'unit_legacy_id','s_order_item_legacy',s->'s_order_item_legacy'),
 encode(public.digest(public.fn_legacy_production_plan_parent_identity((payload->>'plan_id')::uuid)::text,'sha256'),'hex'),
 encode(public.digest(public.fn_legacy_production_plan_run_evidence(p_run)::text,'sha256'),'hex'),
 public.fn_legacy_production_plan_counter_bound_fields(),
 encode(public.digest(public.fn_legacy_finance_snapshot(payload,public.fn_legacy_production_plan_counter_bound_fields())::text,'sha256'),'hex'),txid_current()
 FROM public.legacy_migration_run_files f JOIN public.legacy_migration_run_files p ON p.run_id=f.run_id
 WHERE f.run_id=p_run AND f.file_name='production_plan_items.csv' AND p.file_name='production_plans.csv';
 IF NOT FOUND THEN RAISE EXCEPTION 'legacy production sealed source files are absent' USING ERRCODE='23514'; END IF;
 RETURN target;
END $$;

CREATE FUNCTION public.fn_assert_legacy_production_plan_counter(p_row jsonb,p_before boolean) RETURNS void
LANGUAGE plpgsql SET search_path=pg_catalog,public,pg_temp AS $$
DECLARE proof public.legacy_production_plan_counter_import_sources%ROWTYPE; run record;
 context public.legacy_production_plan_counter_import_contexts%ROWTYPE;
 id_run uuid:=(p_row->>'legacy_production_import_run_id')::uuid; actual jsonb; exists_target boolean; trusted boolean;
 lock_key bigint:=hashtextextended('uten:legacy-bootstrap:'||current_database(),0); refs jsonb; actual_keys text[];
BEGIN
 EXECUTE 'SELECT * FROM public.legacy_production_plan_counter_import_sources WHERE run_id=$1 AND target_id=$2 AND source_legacy_id=$3'
 INTO proof USING id_run,(p_row->>'id')::uuid,(p_row->>'legacy_id')::integer;
 IF proof.id IS NULL OR proof.issued_txid<>txid_current() THEN
  RAISE EXCEPTION 'legacy production initial counter lacks same-transaction exact source proof' USING ERRCODE='23514';
 END IF;
 SELECT * INTO context FROM public.legacy_production_plan_counter_import_contexts WHERE run_id=proof.run_id;
 IF NOT FOUND OR context.issued_txid<>txid_current() OR NOT public.fn_legacy_production_origin_matches(
    context.origin_system_identifier,context.origin_database_oid,context.origin_database_name) THEN
  RAISE EXCEPTION 'legacy production proof is outside its immutable origin transaction' USING ERRCODE='23514';
 END IF;
 IF p_before THEN
  PERFORM public.fn_require_legacy_bootstrap(id_run,proof.source_file);
  PERFORM public.fn_require_legacy_bootstrap(id_run,proof.source_parent_file);
  EXECUTE 'SELECT EXISTS(SELECT 1 FROM public.production_plan_items WHERE id=$1 OR legacy_id=$2)'
   INTO exists_target USING proof.target_id,proof.source_legacy_id;
  IF exists_target THEN RAISE EXCEPTION 'legacy production initial proof cannot authorize an existing target' USING ERRCODE='23514'; END IF;
 ELSE
  SELECT status,reconciliation_status,database_user,mapping_version,migration_repository_commit,
   export_manifest_sha256,target,migration_mode INTO run FROM public.legacy_migration_runs WHERE run_id=id_run;
  SELECT rolsuper OR (rolname='uten_migrator' AND rolcanlogin) INTO trusted FROM pg_catalog.pg_roles WHERE rolname=session_user;
  IF NOT COALESCE(trusted,false) OR current_setting('uten.bootstrap_run_id',true) IS DISTINCT FROM id_run::text
   OR current_setting('uten.bootstrap_mapping_version',true) IS DISTINCT FROM run.mapping_version
   OR current_setting('uten.bootstrap_repository_commit',true) IS DISTINCT FROM run.migration_repository_commit
   OR current_setting('uten.bootstrap_manifest_sha',true) IS DISTINCT FROM run.export_manifest_sha256::text
   OR run.database_user IS DISTINCT FROM current_user OR run.target IS DISTINCT FROM '--bootstrap-all'
   OR run.migration_mode IS DISTINCT FROM 'BOOTSTRAP'
   OR NOT(run.status='RUNNING' OR (run.status='SUCCESS' AND run.reconciliation_status='PASSED'))
   OR NOT EXISTS(SELECT 1 FROM pg_catalog.pg_locks WHERE locktype='advisory' AND pid=pg_backend_pid() AND granted AND mode='ExclusiveLock'
      AND objsubid=1 AND classid=((lock_key>>32)&4294967295)::oid AND objid=(lock_key&4294967295)::oid) THEN
    RAISE EXCEPTION 'legacy production deferred proof is outside its admitted bootstrap transaction' USING ERRCODE='23514';
  END IF;
  EXECUTE 'SELECT to_jsonb(i) FROM public.production_plan_items i WHERE id=$1' INTO actual USING proof.target_id;
  IF actual IS NULL THEN RAISE EXCEPTION 'legacy production issued proof has no exact surviving target' USING ERRCODE='23514'; END IF;
  p_row:=actual;
 END IF;
 SELECT array_agg(k ORDER BY k) INTO actual_keys FROM jsonb_object_keys(p_row) k
 WHERE k NOT IN('created_at','updated_at','created_by','updated_by');
 IF actual_keys IS DISTINCT FROM public.fn_legacy_production_plan_counter_bound_fields() THEN
  RAISE EXCEPTION 'legacy production actual business schema differs from its declared initial projection' USING ERRCODE='23514';
 END IF;
 IF proof.target_fields IS DISTINCT FROM public.fn_legacy_production_plan_counter_bound_fields()
 OR (p_row->>'legacy_id')::integer IS DISTINCT FROM proof.source_legacy_id
 OR (p_row->>'legacy_production_import_run_id')::uuid IS DISTINCT FROM proof.run_id
 OR (p_row->>'plan_id')::uuid IS DISTINCT FROM proof.target_plan_id
 OR proof.source_file_sha256 IS DISTINCT FROM (SELECT sha256 FROM public.legacy_migration_run_files WHERE run_id=id_run AND file_name=proof.source_file)
 OR proof.source_parent_file_sha256 IS DISTINCT FROM (SELECT sha256 FROM public.legacy_migration_run_files WHERE run_id=id_run AND file_name=proof.source_parent_file)
 OR proof.run_evidence_sha256 IS DISTINCT FROM context.evidence_sha256
 OR public.fn_legacy_production_plan_run_primitives(id_run) IS DISTINCT FROM
    context.evidence-ARRAY['targetDatabase','targetSystemIdentifier','targetApprovalReference','importAtomicity','sourceSnapshotAsOfUtc']
 OR proof.parent_identity_sha256 IS DISTINCT FROM encode(public.digest(public.fn_legacy_production_plan_parent_identity(proof.target_plan_id)::text,'sha256'),'hex')
 OR proof.source_parent_legacy_id IS DISTINCT FROM (SELECT legacy_id FROM public.production_plans WHERE id=proof.target_plan_id)
 OR proof.target_snapshot_sha256 IS DISTINCT FROM encode(public.digest(public.fn_legacy_finance_snapshot(p_row,proof.target_fields)::text,'sha256'),'hex') THEN
  RAISE EXCEPTION 'legacy production counter differs from its full initial source projection or identity' USING ERRCODE='23514';
 END IF;
 refs:=proof.source_reference_legacy_ids;
 IF (p_row->>'goods_id')::uuid IS DISTINCT FROM (SELECT id FROM public.goods WHERE legacy_id=(refs->>'goods_legacy_id')::integer)
 OR (p_row->>'color_id')::uuid IS DISTINCT FROM (SELECT id FROM public.colors WHERE legacy_id=NULLIF((refs->>'color_legacy_id')::integer,0))
 OR (p_row->>'mgoods_id')::uuid IS DISTINCT FROM (SELECT id FROM public.goods WHERE legacy_id=NULLIF((refs->>'mgoods_legacy_id')::integer,0))
 OR (p_row->>'unit_id')::uuid IS DISTINCT FROM (SELECT id FROM public.units WHERE legacy_id=(refs->>'unit_legacy_id')::integer)
 OR (p_row->>'sales_order_item_id')::uuid IS DISTINCT FROM (SELECT id FROM public.sales_order_items WHERE legacy_id=NULLIF((refs->>'s_order_item_legacy')::integer,0)) THEN
  RAISE EXCEPTION 'legacy production source master/reference binding changed' USING ERRCODE='23514';
 END IF;
END $$;

CREATE FUNCTION public.fn_guard_legacy_production_plan_counter_target() RETURNS trigger
LANGUAGE plpgsql SET search_path=pg_catalog,public,pg_temp AS $$
DECLARE lineage record;
BEGIN
 IF TG_OP='INSERT' THEN
  IF NEW.legacy_production_import_run_id IS NOT NULL THEN PERFORM public.fn_assert_legacy_production_plan_counter(to_jsonb(NEW),true); END IF;
  RETURN NEW;
 END IF;
 IF TG_OP='DELETE' THEN
  IF OLD.legacy_production_import_run_id IS NOT NULL THEN RAISE EXCEPTION 'original production initial source identity cannot be deleted and replayed' USING ERRCODE='55000'; END IF;
  RETURN OLD;
 END IF;
 IF NEW.legacy_production_import_run_id IS DISTINCT FROM OLD.legacy_production_import_run_id
 OR (OLD.legacy_production_import_run_id IS NOT NULL AND (NEW.id IS DISTINCT FROM OLD.id OR NEW.legacy_id IS DISTINCT FROM OLD.legacy_id)) THEN
  RAISE EXCEPTION 'production initial source provenance cannot be attached, cleared or rebound' USING ERRCODE='23514';
 END IF;
 IF OLD.legacy_production_import_run_id IS NOT NULL THEN
  EXECUTE 'SELECT p.issued_txid,c.origin_system_identifier,c.origin_database_oid,c.origin_database_name '
   'FROM public.legacy_production_plan_counter_import_sources p JOIN public.legacy_production_plan_counter_import_contexts c ON c.run_id=p.run_id '
   'WHERE p.run_id=$1 AND p.target_id=$2'
  INTO lineage USING OLD.legacy_production_import_run_id,OLD.id;
  IF lineage.issued_txid=txid_current() THEN
   IF public.fn_legacy_production_origin_matches(lineage.origin_system_identifier,lineage.origin_database_oid,lineage.origin_database_name)
    AND public.fn_legacy_finance_snapshot(to_jsonb(NEW),public.fn_legacy_production_plan_counter_bound_fields())
      IS DISTINCT FROM public.fn_legacy_finance_snapshot(to_jsonb(OLD),public.fn_legacy_production_plan_counter_bound_fields()) THEN
    RAISE EXCEPTION 'initial production source fields cannot change in their admitted transaction' USING ERRCODE='23514';
   END IF;
  END IF;
 END IF;
 RETURN NEW;
END $$;
CREATE TRIGGER trg_zz_legacy_production_plan_counter_target BEFORE INSERT OR UPDATE OR DELETE
 ON public.production_plan_items FOR EACH ROW EXECUTE FUNCTION public.fn_guard_legacy_production_plan_counter_target();
ALTER TABLE public.production_plan_items ENABLE ALWAYS TRIGGER trg_zz_legacy_production_plan_counter_target;

CREATE FUNCTION public.fn_accept_legacy_initial_production_plan_counter(p_row jsonb,p_before boolean) RETURNS boolean
LANGUAGE plpgsql SET search_path=pg_catalog,public,pg_temp AS $$
BEGIN
 IF p_row->>'legacy_production_import_run_id' IS NULL THEN RETURN false; END IF;
 IF COALESCE((p_row->>'qty')::numeric,0)<0 OR COALESCE((p_row->>'fqty')::numeric,0)<0 OR COALESCE((p_row->>'iqty')::numeric,0)<0 THEN RETURN false; END IF;
 PERFORM public.fn_assert_legacy_production_plan_counter(p_row,p_before);
 RETURN true;
END $$;

CREATE FUNCTION public.fn_finish_legacy_production_plan_counter_proof() RETURNS trigger
LANGUAGE plpgsql SET search_path=pg_catalog,public,pg_temp AS $$
BEGIN
 PERFORM public.fn_assert_legacy_production_plan_counter(jsonb_build_object('id',NEW.target_id,'legacy_id',NEW.source_legacy_id,
   'legacy_production_import_run_id',NEW.run_id),false);
 RETURN NULL;
END $$;
CREATE CONSTRAINT TRIGGER trg_finish_legacy_production_plan_counter_proof
 AFTER INSERT ON public.legacy_production_plan_counter_import_sources DEFERRABLE INITIALLY DEFERRED
 FOR EACH ROW EXECUTE FUNCTION public.fn_finish_legacy_production_plan_counter_proof();

DO $forward$
DECLARE definition text; anchor text;
BEGIN
 definition:=pg_get_functiondef('public.fn_guard_plan_actual_inbound_quantity()'::regprocedure);
 anchor:='        RAISE EXCEPTION ''finished-in exceeds approved production including proven actual surplus''';
 IF (length(definition)-length(replace(definition,anchor,'')))/length(anchor)<>1 THEN RAISE EXCEPTION 'V913 inbound guard oracle changed'; END IF;
 definition:=replace(definition,anchor,E'        IF TG_OP=''INSERT'' AND public.fn_accept_legacy_initial_production_plan_counter(to_jsonb(NEW),true) THEN RETURN NEW; END IF;\n'||anchor);
 EXECUTE definition;
 definition:=pg_get_functiondef('public.fn_assert_production_plan_actual_finished()'::regprocedure);
 anchor:='        RAISE EXCEPTION ''Actual production exceeds the approved plan and separately approved surplus facts''';
 IF (length(definition)-length(replace(definition,anchor,'')))/length(anchor)<>1 THEN RAISE EXCEPTION 'V913 finished guard oracle changed'; END IF;
 definition:=replace(definition,anchor,E'        IF TG_OP=''INSERT'' AND public.fn_accept_legacy_initial_production_plan_counter(to_jsonb(actual),false) THEN RETURN NULL; END IF;\n'||anchor);
 EXECUTE definition;
END $forward$;

REVOKE ALL ON public.legacy_production_plan_counter_import_sources FROM PUBLIC;
REVOKE ALL ON public.legacy_production_plan_counter_import_contexts FROM PUBLIC;
REVOKE ALL ON FUNCTION public.fn_register_legacy_production_plan_counter_source(uuid,jsonb,jsonb,integer) FROM PUBLIC;
DO $privileges$
BEGIN
 IF EXISTS(SELECT 1 FROM pg_catalog.pg_roles WHERE rolname='uten') THEN
  GRANT SELECT ON public.legacy_production_plan_counter_import_sources TO uten;
  GRANT SELECT ON public.legacy_production_plan_counter_import_contexts TO uten;
  REVOKE ALL ON FUNCTION public.fn_register_legacy_production_plan_counter_source(uuid,jsonb,jsonb,integer) FROM uten;
 END IF;
 IF EXISTS(SELECT 1 FROM pg_catalog.pg_roles WHERE rolname='uten_migrator') THEN
  GRANT SELECT,INSERT ON public.legacy_production_plan_counter_import_sources TO uten_migrator;
  GRANT SELECT,INSERT ON public.legacy_production_plan_counter_import_contexts TO uten_migrator;
  GRANT EXECUTE ON FUNCTION public.fn_register_legacy_production_plan_counter_source(uuid,jsonb,jsonb,integer) TO uten_migrator;
 END IF;
END $privileges$;
SELECT public.fn_audit_track_table('legacy_production_plan_counter_import_sources','NONE','system',false);
DO $reset_policy$
DECLARE definition text; anchor text:='(''goods'', ''PRESERVE'')';
BEGIN
 SELECT pg_get_functiondef('public.business_data_reset()'::regprocedure) INTO definition;
 IF (length(definition)-length(replace(definition,anchor,'')))/length(anchor)<>1 THEN RAISE EXCEPTION 'V913 reset policy oracle changed'; END IF;
 EXECUTE replace(definition,anchor,anchor||E',\n (''legacy_production_plan_counter_import_sources'', ''PRESERVE''),\n (''legacy_production_plan_counter_import_contexts'', ''PRESERVE'')');
END $reset_policy$;
