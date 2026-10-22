-- Object history is shared by all authorised viewers. Personal undo stacks stay
-- separate: these immutable facts are never rebased by undo/redo.
CREATE TABLE master_record_versions (
 id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
 entity_type text NOT NULL, source_table text NOT NULL, row_id uuid NOT NULL, source_key text NOT NULL DEFAULT '',
 record_id uuid NOT NULL, category_id uuid, before_row jsonb, after_row jsonb,
 action text NOT NULL, actor_id uuid, actor_name text,
 request_id uuid, transaction_id bigint NOT NULL DEFAULT txid_current(),
 recorded_at timestamptz NOT NULL DEFAULT clock_timestamp(),
 CHECK(before_row IS NOT NULL OR after_row IS NOT NULL)
);
CREATE INDEX ix_master_versions_object ON master_record_versions(entity_type,record_id,id DESC);
CREATE INDEX ix_master_versions_category ON master_record_versions(entity_type,category_id,id DESC);
CREATE INDEX ix_master_versions_overview ON master_record_versions(entity_type,id DESC);
CREATE INDEX ix_master_versions_command ON master_record_versions(transaction_id,record_id,id);
SELECT fn_audit_track_table('master_record_versions','NONE','data_change',false);
CREATE TRIGGER trg_master_versions_immutable BEFORE UPDATE OR DELETE ON master_record_versions
 FOR EACH ROW EXECUTE FUNCTION fn_lifecycle_evidence_immutable();
CREATE TRIGGER trg_master_versions_no_truncate BEFORE TRUNCATE ON master_record_versions
 FOR EACH STATEMENT EXECUTE FUNCTION fn_lifecycle_evidence_immutable();
ALTER TABLE master_record_versions ENABLE ALWAYS TRIGGER trg_master_versions_immutable;
ALTER TABLE master_record_versions ENABLE ALWAYS TRIGGER trg_master_versions_no_truncate;

CREATE FUNCTION fn_capture_master_record_version() RETURNS trigger LANGUAGE plpgsql AS $$
DECLARE b jsonb; a jsonb; n jsonb; root_id uuid; entity text:=TG_ARGV[0]; category uuid; identity_key text;
 actor uuid:=NULLIF(current_setting('app.actor_id',true),'')::uuid; actor_label text;
BEGIN
 IF TG_OP<>'INSERT' THEN b:=fn_goods_history_snapshot(TG_RELID,OLD); END IF;
 IF TG_OP<>'DELETE' THEN a:=fn_goods_history_snapshot(TG_RELID,NEW); END IF;
 IF b-ARRAY['updated_at','updated_by','version','row_version'] IS NOT DISTINCT FROM a-ARRAY['updated_at','updated_by','version','row_version'] THEN RETURN COALESCE(NEW,OLD); END IF;
 n:=COALESCE(a,b); root_id:=(n->>'id')::uuid;
 IF TG_TABLE_NAME='platform_record_fields' THEN
  entity:=CASE n->>'scope' WHEN 'master_goods' THEN 'goods' WHEN 'master_material_category' THEN 'goods'
   WHEN 'master_client' THEN 'clients' WHEN 'master_client_category' THEN 'clients'
   WHEN 'master_supplier' THEN 'suppliers' WHEN 'master_supplier_category' THEN 'suppliers'
   WHEN 'master_mould' THEN 'moulds' WHEN 'master_mould_category' THEN 'moulds'
   WHEN 'master_color' THEN 'colors' WHEN 'master_unit' THEN 'units' WHEN 'master_currency' THEN 'currencies'
   WHEN 'master_warehouse' THEN 'warehouses' WHEN 'master_account' THEN 'accounts'
   WHEN 'master_settlement_method' THEN 'reference-methods' WHEN 'master_payment_style' THEN 'payment-styles' ELSE NULL END;
  IF entity IS NULL THEN RETURN COALESCE(NEW,OLD); END IF;
  root_id:=(n->>'record_id')::uuid;
 ELSIF TG_TABLE_NAME='goods_bom_items' THEN root_id:=(n->>'goods_id')::uuid;
 ELSIF TG_TABLE_NAME IN ('party_contact_methods','party_addresses','party_activity_records') THEN
   root_id:=(n->>'party_id')::uuid;
   entity:=CASE n->>'party_type' WHEN 'CLIENT' THEN 'clients' ELSE 'suppliers' END;
 ELSIF TG_TABLE_NAME='client_ship_addresses' THEN root_id:=(n->>'client_id')::uuid;
 ELSIF TG_TABLE_NAME='warehouse_keepers' THEN root_id:=(n->>'warehouse_id')::uuid;
 ELSIF TG_TABLE_NAME='client_visibility_grants' THEN root_id:=(n->>'client_id')::uuid;
 ELSIF TG_TABLE_NAME='unit_measurement_profiles' THEN root_id:=(n->>'unit_id')::uuid;
 END IF;
 identity_key:=COALESCE(n->>'id',n->>'employee_id',n->>'grantee_employee_id',n->>'unit_id',root_id::text);
 IF TG_TABLE_NAME='platform_record_fields' THEN identity_key:=n->>'scope'; END IF;
 category:=NULLIF(n->>'category_id','')::uuid;
 IF TG_TABLE_NAME='goods_bom_items' THEN SELECT category_id INTO category FROM goods WHERE id=root_id; END IF;
 IF current_setting('app.master_version_actor_name_id',true) IS DISTINCT FROM COALESCE(actor::text,'') THEN
  SELECT e.full_name||' ('||u.login_account||')' INTO actor_label FROM users u JOIN employees e ON e.id=u.employee_id WHERE u.id=actor;
  actor_label:=COALESCE(actor_label,NULLIF(current_setting('app.actor_account',true),''));
  PERFORM set_config('app.master_version_actor_name_id',COALESCE(actor::text,''),true);
  PERFORM set_config('app.master_version_actor_name',COALESCE(actor_label,''),true);
 ELSE actor_label:=NULLIF(current_setting('app.master_version_actor_name',true),''); END IF;
 INSERT INTO master_record_versions(entity_type,source_table,row_id,source_key,record_id,category_id,before_row,after_row,
   action,actor_id,actor_name,request_id)
 VALUES(entity,TG_TABLE_NAME,COALESCE((n->>'id')::uuid,root_id),identity_key,root_id,category,b,a,
   CASE WHEN NULLIF(current_setting('app.master_version_restore',true),'') IS NOT NULL THEN 'RESTORE'
    WHEN TG_OP='INSERT' THEN 'CREATE' WHEN TG_OP='DELETE' OR (NOT COALESCE((b->>'is_deleted')::boolean,false) AND COALESCE((a->>'is_deleted')::boolean,false)) THEN 'DELETE'
    WHEN COALESCE((b->>'is_deleted')::boolean,false) AND NOT COALESCE((a->>'is_deleted')::boolean,false) THEN 'RESTORE'
    WHEN b->'status' IS DISTINCT FROM a->'status' THEN 'STATUS' ELSE 'EDIT' END,
   actor,actor_label,NULLIF(current_setting('app.audit_request_id',true),'')::uuid);
 RETURN COALESCE(NEW,OLD);
END $$;
DO $$ DECLARE t text; entity text; BEGIN
 FOREACH t IN ARRAY ARRAY['goods','material_categories','goods_bom_items','clients','client_categories',
 'suppliers','supplier_categories','moulds','mould_categories','colors','units','currencies','warehouses',
 'accounts','settlement_methods','payment_styles','party_contact_methods','party_addresses','party_activity_records','client_ship_addresses',
 'warehouse_keepers','client_visibility_grants','unit_measurement_profiles','platform_record_fields'] LOOP
 entity:=CASE t WHEN 'material_categories' THEN 'goods' WHEN 'goods_bom_items' THEN 'goods'
  WHEN 'client_categories' THEN 'clients' WHEN 'supplier_categories' THEN 'suppliers' WHEN 'mould_categories' THEN 'moulds'
  WHEN 'settlement_methods' THEN 'reference-methods' WHEN 'payment_styles' THEN 'payment-styles'
  WHEN 'client_ship_addresses' THEN 'clients' WHEN 'client_visibility_grants' THEN 'clients'
  WHEN 'warehouse_keepers' THEN 'warehouses' WHEN 'unit_measurement_profiles' THEN 'units' ELSE t END;
 EXECUTE format('CREATE TRIGGER trg_capture_master_record_version AFTER INSERT OR UPDATE OR DELETE ON %I FOR EACH ROW EXECUTE FUNCTION fn_capture_master_record_version(%L)',t,entity);
 EXECUTE format('ALTER TABLE %I ENABLE ALWAYS TRIGGER trg_capture_master_record_version',t);
 END LOOP;
END $$;
-- Import already retained personal command snapshots without modifying their
-- evidence. A migration snapshot is explicitly labelled; its time is not an edit.
INSERT INTO master_record_versions(entity_type,source_table,row_id,record_id,category_id,before_row,after_row,
 action,actor_id,actor_name,request_id,transaction_id,recorded_at)
SELECT 'goods',r.table_name,r.row_id,
 CASE WHEN r.table_name='goods_bom_items' THEN (COALESCE(r.after_row,r.before_row)->>'goods_id')::uuid ELSE r.row_id END,
 NULLIF(COALESCE(r.after_row,r.before_row)->>'category_id','')::uuid,r.before_row,r.after_row,
 CASE WHEN r.before_row IS NULL THEN 'CREATE' WHEN COALESCE((r.after_row->>'is_deleted')::boolean,false) OR r.after_row IS NULL THEN 'DELETE' ELSE 'EDIT' END,
 h.actor_id,NULL,h.request_id,h.transaction_id,h.created_at
FROM goods_operation_history h JOIN goods_operation_history_rows r ON r.operation_id=h.id
WHERE r.table_name IN ('goods','material_categories','goods_bom_items') ORDER BY h.created_at,h.id,r.capture_order;
INSERT INTO master_record_versions(entity_type,source_table,row_id,record_id,category_id,before_row,after_row,
 action,actor_id,request_id,transaction_id,recorded_at)
SELECT h.entity_type,r.table_name,r.row_id,
 CASE WHEN r.table_name IN ('party_contact_methods','party_addresses') THEN (COALESCE(r.after_row,r.before_row)->>'party_id')::uuid
 WHEN r.table_name='client_ship_addresses' THEN (COALESCE(r.after_row,r.before_row)->>'client_id')::uuid ELSE r.row_id END,
 NULLIF(COALESCE(r.after_row,r.before_row)->>'category_id','')::uuid,r.before_row,r.after_row,
 CASE WHEN r.before_row IS NULL THEN 'CREATE' WHEN COALESCE((r.after_row->>'is_deleted')::boolean,false) OR r.after_row IS NULL THEN 'DELETE' ELSE 'EDIT' END,
 h.actor_id,h.request_id,h.transaction_id,h.created_at
FROM master_operation_history h JOIN master_operation_history_rows r ON r.operation_id=h.id ORDER BY h.created_at,h.id,r.capture_order;
DO $$ DECLARE definition text; anchor text:='(''master_operation_history_events'', ''PRESERVE'')'; BEGIN
 SELECT pg_get_functiondef('business_data_reset()'::regprocedure) INTO definition;
 IF strpos(definition,anchor)=0 THEN RAISE EXCEPTION 'V898 cannot extend retained history policy'; END IF;
 EXECUTE replace(definition,anchor,anchor||E',\n    (''master_record_versions'', ''PRESERVE'')');
END $$;
