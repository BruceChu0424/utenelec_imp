-- V898 is restored to its applied immutable content.
-- Carry later numbering-batch capture and platform-field category fixes forward only.
CREATE OR REPLACE FUNCTION fn_capture_master_record_version() RETURNS trigger LANGUAGE plpgsql AS $$
DECLARE b jsonb; a jsonb; n jsonb; root_id uuid; entity text:=TG_ARGV[0]; category uuid; identity_key text;
 actor uuid:=NULLIF(current_setting('app.actor_id',true),'')::uuid; actor_label text;
 old_code text; batch uuid:=NULLIF(current_setting('app.master_code_batch_id',true),'')::uuid;
BEGIN
 IF TG_TABLE_NAME IN ('goods','clients','suppliers','moulds') AND batch IS NOT NULL
    AND current_setting('app.master_code_audit_stage',true)='temporary' THEN RETURN COALESCE(NEW,OLD); END IF;
 IF TG_OP<>'INSERT' THEN b:=fn_goods_history_snapshot(TG_RELID,OLD); END IF;
 IF TG_OP<>'DELETE' THEN a:=fn_goods_history_snapshot(TG_RELID,NEW); END IF;
 IF TG_OP='UPDATE' AND TG_TABLE_NAME IN ('goods','clients','suppliers','moulds') AND batch IS NOT NULL
    AND current_setting('app.master_code_audit_stage',true)='final' THEN
  SELECT h.old_code INTO old_code FROM master_code_history h WHERE h.batch_id=batch AND h.entity_id=(b->>'id')::uuid;
  IF NOT FOUND THEN RAISE EXCEPTION 'Final master identifier lacks frozen numbering evidence'; END IF;
  b:=jsonb_set(b,'{code}',COALESCE(to_jsonb(old_code),'null'::jsonb));
 END IF;
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
 IF TG_TABLE_NAME='platform_record_fields' THEN
  CASE n->>'scope'
   WHEN 'master_goods' THEN SELECT category_id INTO category FROM goods WHERE id=root_id;
   WHEN 'master_client' THEN SELECT category_id INTO category FROM clients WHERE id=root_id;
   WHEN 'master_supplier' THEN SELECT category_id INTO category FROM suppliers WHERE id=root_id;
   WHEN 'master_mould' THEN SELECT category_id INTO category FROM moulds WHERE id=root_id;
   ELSE NULL;
  END CASE;
 END IF;
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
