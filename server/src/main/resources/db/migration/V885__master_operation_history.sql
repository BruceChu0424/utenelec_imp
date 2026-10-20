-- Durable actor-owned history for the other basic-data editors. Goods keeps
-- its existing specialised BOM/cost replay implementation and lineage.
-- Directory rows previously had only created_at. A server-owned version makes
-- a later edit-then-restore detectable even when values return to the old text.
ALTER TABLE party_contact_methods ADD COLUMN version bigint NOT NULL DEFAULT 0;
ALTER TABLE party_addresses ADD COLUMN version bigint NOT NULL DEFAULT 0;
ALTER TABLE client_ship_addresses ADD COLUMN version bigint NOT NULL DEFAULT 0;
CREATE FUNCTION fn_master_directory_version() RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN NEW.version:=OLD.version+1; RETURN NEW; END $$;
CREATE TRIGGER trg_master_contact_version BEFORE UPDATE ON party_contact_methods FOR EACH ROW EXECUTE FUNCTION fn_master_directory_version();
CREATE TRIGGER trg_master_address_version BEFORE UPDATE ON party_addresses FOR EACH ROW EXECUTE FUNCTION fn_master_directory_version();
CREATE TRIGGER trg_master_ship_address_version BEFORE UPDATE ON client_ship_addresses FOR EACH ROW EXECUTE FUNCTION fn_master_directory_version();
CREATE TABLE master_operation_history (
 id uuid PRIMARY KEY DEFAULT gen_random_uuid(), actor_id uuid NOT NULL,
 entity_type text NOT NULL, request_id uuid NOT NULL, transaction_id bigint NOT NULL,
 operation_type text NOT NULL, label text NOT NULL, request_path text NOT NULL,
 request_method text NOT NULL, state text NOT NULL DEFAULT 'APPLIED' CHECK(state IN ('APPLIED','UNDONE')),
 version bigint NOT NULL DEFAULT 0, redo_allowed boolean NOT NULL DEFAULT false,
 unsupported_reason text, created_at timestamptz NOT NULL DEFAULT clock_timestamp(),
 UNIQUE(actor_id,request_id,transaction_id)
);
CREATE INDEX idx_master_history_actor ON master_operation_history(actor_id,entity_type,created_at DESC,id DESC);
CREATE TABLE master_operation_history_rows (
 operation_id uuid NOT NULL REFERENCES master_operation_history(id), table_name text NOT NULL,
 row_id uuid NOT NULL, before_row jsonb, after_row jsonb, expected_row jsonb,
 before_token jsonb, after_token jsonb, capture_order bigint GENERATED ALWAYS AS IDENTITY,
 PRIMARY KEY(operation_id,table_name,row_id),
 CHECK(table_name IN ('clients','suppliers','moulds','colors','units','currencies','warehouses','accounts',
  'settlement_methods','payment_styles','client_categories','supplier_categories','mould_categories','party_contact_methods','party_addresses','client_ship_addresses'))
);
CREATE INDEX idx_master_history_lineage ON master_operation_history_rows(table_name,row_id);
CREATE TABLE master_operation_history_events (
 id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
 operation_id uuid NOT NULL REFERENCES master_operation_history(id), actor_id uuid NOT NULL,
 action text NOT NULL CHECK(action IN ('UNDO','REDO')), created_at timestamptz NOT NULL DEFAULT clock_timestamp()
);
CREATE INDEX idx_master_history_events_actor ON master_operation_history_events(actor_id,id DESC);

CREATE FUNCTION fn_master_history_entity(p_path text,p_method text) RETURNS text LANGUAGE sql IMMUTABLE AS $$
 SELECT CASE WHEN p_method NOT IN ('POST','PUT','PATCH','DELETE') THEN NULL
 WHEN p_method='PATCH' AND p_path ~ '^/api/master/inline-edit/(colors|units|currencies|moulds|accounts|reference-methods|clients|suppliers)/[0-9a-fA-F-]{36}$' THEN split_part(p_path,'/',5)
 WHEN p_path ~ '^/api/master/(clients|suppliers|moulds|colors|units|currencies|warehouses|accounts)(/[0-9a-fA-F-]{36}(/status|/warning)?|/batch-status|/batch-delete)?$'
  THEN split_part(p_path,'/',4)
 WHEN p_path ~ '^/api/master/(clients|suppliers)/[0-9a-fA-F-]{36}/(contact-methods|addresses|activity-records)(/[0-9a-fA-F-]{36})?$' THEN split_part(p_path,'/',4)
 WHEN p_path ~ '^/api/master/clients/[0-9a-fA-F-]{36}/ship-addresses(/[0-9a-fA-F-]{36})?$' THEN 'clients'
 WHEN p_path ~ '^/api/master/warehouses/[0-9a-fA-F-]{36}/keepers$' THEN 'warehouses'
 WHEN p_path ~ '^/api/master/clients/([0-9a-fA-F-]{36}/access|access/batch)$' THEN 'clients'
 WHEN p_path ~ '^/api/master/(client-categories|supplier-categories|mould-categories)(/[0-9a-fA-F-]{36})?$'
  THEN CASE split_part(p_path,'/',4) WHEN 'client-categories' THEN 'clients' WHEN 'supplier-categories' THEN 'suppliers' ELSE 'moulds' END
 WHEN p_path ~ '^/api/master/payment-styles(/[0-9a-fA-F-]{36})?$' THEN 'payment-styles'
 WHEN p_path ~ '^/api/master/reference-methods/settlement/[0-9a-fA-F-]{36}/terms$' THEN 'reference-methods'
 WHEN p_path='/api/master/reference-methods/settlement' AND p_method='POST' THEN 'reference-methods'
 ELSE NULL END
$$;

CREATE FUNCTION fn_begin_master_history_request() RETURNS void LANGUAGE plpgsql AS $$
DECLARE actor uuid:=nullif(current_setting('app.actor_id',true),'')::uuid;
 path text:=current_setting('app.audit_request_path',true); method text:=current_setting('app.audit_request_method',true);
BEGIN
 IF actor IS NULL OR (fn_master_history_entity(path,method) IS NULL
  AND NOT COALESCE(path,'') ~ '^/api/master/operation-history(/[0-9a-fA-F-]{36}/(undo|redo))?$') THEN RETURN; END IF;
 IF current_setting('app.master_history_prelocked_actor',true)=actor::text THEN RETURN; END IF;
 PERFORM pg_advisory_xact_lock(hashtextextended('master-history:'||actor::text,0));
 PERFORM set_config('app.master_history_prelocked_actor',actor::text,true);
END $$;

-- A strict field allowlist keeps money, numbering, custody, conversion profiles
-- and materialised hierarchy commands out of generic snapshot replay. It is
-- deliberately shared by capture and replay, so a future new column fails shut.
CREATE FUNCTION fn_master_history_unsupported(p_table text,b jsonb,a jsonb) RETURNS text LANGUAGE plpgsql IMMUTABLE AS $$
DECLARE allowed text[]; changed text[];
BEGIN
 IF p_table IN ('party_contact_methods','party_addresses') AND (a IS NULL OR b IS NULL) THEN RETURN NULL; END IF;
 IF a IS NULL THEN RETURN '永久删除不能通过资料历史恢复'; END IF;
 IF b IS NULL AND p_table IN ('accounts','payment_styles','units','warehouses') THEN
  RETURN '此新增操作包含账户、财务类别、计量或仓库责任设置，请使用对应维护流程处理';
 END IF;
 IF b IS NULL THEN RETURN NULL; END IF;
 allowed:=CASE p_table
 WHEN 'clients' THEN ARRAY['name','name_en','full_name','client_rank','region','place_id','legal_person','linkman','mobile','phone','phone2','fax','postcode','address','email','website','ship_via','ship_address','bank','bank_account','tax_id','tday','default_settlement_method_id','price_style','default_shipment_policy','default_currency_id','credit_floor','status','remark','is_deleted','deleted_at']
 WHEN 'suppliers' THEN ARRAY['name','description','place','ship_via','ship_address','legal_person','linkman','mobile','phone','phone2','fax','postcode','address','email','website','bank','bank_account','tax_id','tday','default_settlement_method_id','default_currency_id','default_tax_rate','price_style','status','remark','is_deleted','deleted_at']
 WHEN 'moulds' THEN ARRAY['name','mnumber','qty','tqty','mstatus','place','manufacturer','remark','status','is_deleted','deleted_at']
 WHEN 'colors' THEN ARRAY['name','remark','status','is_deleted','deleted_at']
 WHEN 'units' THEN ARRAY['name','status','is_deleted','deleted_at']
 WHEN 'currencies' THEN ARRAY['name','exchange_rate','status','is_deleted','deleted_at']
 WHEN 'warehouses' THEN ARRAY['name','status','is_deleted','deleted_at']
 WHEN 'accounts' THEN ARRAY['name','bank_account_no','balance_floor']
 WHEN 'settlement_methods' THEN ARRAY['name','terms_base','due_rule','default_due_days','fixed_day_of_month','months_ahead']
 WHEN 'payment_styles' THEN ARRAY['name','sort_order']
 WHEN 'client_categories' THEN ARRAY['name','remark','is_deleted','deleted_at']
 WHEN 'supplier_categories' THEN ARRAY['name','remark','is_deleted','deleted_at']
 WHEN 'mould_categories' THEN ARRAY['name','remark','is_deleted','deleted_at']
 WHEN 'party_contact_methods' THEN ARRAY['kind','value','is_primary','remark']
 WHEN 'party_addresses' THEN ARRAY['kind','address','is_default','remark']
 WHEN 'client_ship_addresses' THEN ARRAY['address','link_phone','usage_count','last_used_at','is_deleted','deleted_at']
 ELSE ARRAY[]::text[] END;
 SELECT array_agg(e.key ORDER BY e.key) INTO changed FROM jsonb_each(a) e
 WHERE b->e.key IS DISTINCT FROM e.value
 AND e.key<>ALL(allowed||ARRAY['updated_at','updated_by','version']);
 IF changed IS NOT NULL THEN RETURN CASE
  WHEN p_table='accounts' THEN '此操作涉及账户余额、币种、分类或使用状态，请使用账户维护及财务调整流程处理'
  WHEN p_table='payment_styles' THEN '此操作涉及财务类别层级、方向、账户或使用状态，请使用收付款类别维护流程处理'
  WHEN p_table='warehouses' THEN '此操作涉及仓库核算形态、车间或保管责任，请使用仓库维护流程处理'
  WHEN p_table='units' THEN '此操作涉及单位换算或计量规则，请使用单位维护流程处理'
  ELSE '此操作涉及编号、归属、层级或期初业务设置，请使用对应维护流程处理' END; END IF;
 RETURN NULL;
END $$;

-- BOM drag commands move by retaining the old identity and creating the new
-- edge, so the existing multi-row replay/derived-cost machinery applies.
DO $$ DECLARE definition text; anchor text:='WHEN p_path ~ ''^/api/master/goods/[0-9a-fA-F-]{36}/bom$'' AND p_method=''POST'' THEN ''BOM_CREATE'''; BEGIN
 SELECT pg_get_functiondef('public.fn_goods_history_operation(text,text)'::regprocedure) INTO definition;
 IF strpos(definition,anchor)=0 THEN RAISE EXCEPTION 'Cannot extend BOM drag history capture'; END IF;
 EXECUTE replace(definition,anchor,E'WHEN p_path ~ ''^/api/master/goods/[0-9a-fA-F-]{36}/bom/move$'' AND p_method=''PUT'' THEN ''BOM_MOVE''\n WHEN p_path ~ ''^/api/master/inline-edit/goods/[0-9a-fA-F-]{36}$'' AND p_method=''PATCH'' THEN ''GOODS_EDIT''\n '||anchor);
 SELECT pg_get_functiondef('public.fn_capture_goods_operation_history()'::regprocedure) INTO definition;
 anchor:='WHEN ''BOM_AUDIT'' THEN ''核对组装组件''';
 IF strpos(definition,anchor)=0 THEN RAISE EXCEPTION 'Cannot extend BOM drag history label'; END IF;
 EXECUTE replace(definition,anchor,'WHEN ''BOM_MOVE'' THEN ''移动组装组件'' '||anchor);
END $$;

CREATE FUNCTION fn_capture_master_operation_history() RETURNS trigger LANGUAGE plpgsql AS $$
DECLARE actor uuid:=nullif(current_setting('app.actor_id',true),'')::uuid;
 request uuid:=nullif(current_setting('app.audit_request_id',true),'')::uuid;
 path text:=current_setting('app.audit_request_path',true); method text:=current_setting('app.audit_request_method',true);
 entity text; b jsonb; a jsonb; operation uuid; typ text; noun text; blocked text;
BEGIN
 IF current_setting('app.master_history_replay',true)='on' OR actor IS NULL OR request IS NULL THEN RETURN COALESCE(NEW,OLD); END IF;
 entity:=fn_master_history_entity(path,method);
 IF entity IS NULL THEN RETURN COALESCE(NEW,OLD); END IF;
 IF TG_OP<>'INSERT' THEN b:=fn_goods_history_snapshot(TG_RELID,OLD); END IF;
 IF TG_OP<>'DELETE' THEN a:=fn_goods_history_snapshot(TG_RELID,NEW); END IF;
 IF b IS NOT DISTINCT FROM a THEN RETURN COALESCE(NEW,OLD); END IF;
 IF current_setting('app.master_history_prelocked_actor',true) IS DISTINCT FROM actor::text THEN
  IF NOT pg_try_advisory_xact_lock(hashtextextended('master-history:'||actor::text,0)) THEN
   RAISE EXCEPTION '当前账号的另一项资料操作正在提交' USING ERRCODE='55P03'; END IF;
  PERFORM set_config('app.master_history_prelocked_actor',actor::text,true);
 END IF;
 typ:=CASE WHEN path ~ '/(contact-methods|addresses)(/|$)' THEN 'EDIT'
  WHEN method='DELETE' OR path LIKE '%/batch-delete' THEN 'DELETE'
  WHEN path LIKE '%/status' OR path LIKE '%/batch-status' THEN 'STATUS'
  WHEN b IS NULL THEN 'CREATE' ELSE 'EDIT' END;
 noun:=CASE TG_TABLE_NAME WHEN 'clients' THEN '客户' WHEN 'suppliers' THEN '供应商' WHEN 'moulds' THEN '模具'
  WHEN 'colors' THEN '颜色' WHEN 'units' THEN '单位' WHEN 'currencies' THEN '币种' WHEN 'warehouses' THEN '仓库'
  WHEN 'accounts' THEN '账户' WHEN 'settlement_methods' THEN '结算方式' WHEN 'payment_styles' THEN '收付款类别'
  WHEN 'party_contact_methods' THEN '联系方式' WHEN 'party_addresses' THEN '地址' WHEN 'client_ship_addresses' THEN '客户收货地址' ELSE '资料分类' END;
 blocked:=fn_master_history_unsupported(TG_TABLE_NAME,b,a);
 INSERT INTO master_operation_history(actor_id,entity_type,request_id,transaction_id,operation_type,label,request_path,request_method,unsupported_reason)
 VALUES(actor,entity,request,txid_current(),typ,
  CASE typ WHEN 'CREATE' THEN '新增' WHEN 'DELETE' THEN '删除' WHEN 'STATUS' THEN '启停' ELSE '修改' END||noun,path,method,blocked)
 ON CONFLICT(actor_id,request_id,transaction_id) DO NOTHING RETURNING id INTO operation;
 IF operation IS NOT NULL THEN
  UPDATE master_operation_history SET redo_allowed=false WHERE actor_id=actor AND entity_type=entity AND state='UNDONE' AND redo_allowed;
 ELSE
  SELECT id INTO STRICT operation FROM master_operation_history WHERE actor_id=actor AND request_id=request AND transaction_id=txid_current();
  IF blocked IS NOT NULL THEN UPDATE master_operation_history SET unsupported_reason=COALESCE(unsupported_reason,blocked) WHERE id=operation; END IF;
 END IF;
 INSERT INTO master_operation_history_rows(operation_id,table_name,row_id,before_row,after_row,expected_row,before_token,after_token)
 VALUES(operation,TG_TABLE_NAME,(COALESCE(a,b)->>'id')::uuid,b,a,a,b,a)
 ON CONFLICT(operation_id,table_name,row_id) DO UPDATE SET after_row=excluded.after_row,expected_row=excluded.expected_row,after_token=excluded.after_token;
 RETURN COALESCE(NEW,OLD);
END $$;

-- Unit measurement settings live outside units. A unit name edit alone is
-- reversible; a command that also changes its profile must never partially undo.
CREATE FUNCTION fn_mark_master_history_profile() RETURNS trigger LANGUAGE plpgsql AS $$
DECLARE actor uuid:=nullif(current_setting('app.actor_id',true),'')::uuid;
 request uuid:=nullif(current_setting('app.audit_request_id',true),'')::uuid;
 path text:=current_setting('app.audit_request_path',true); method text:=current_setting('app.audit_request_method',true);
 operation uuid; snapshot jsonb; unit_id uuid;
BEGIN
 IF current_setting('app.master_history_replay',true)='on' OR actor IS NULL OR request IS NULL
  OR fn_master_history_entity(path,method) IS DISTINCT FROM 'units' THEN RETURN COALESCE(NEW,OLD); END IF;
 IF current_setting('app.master_history_prelocked_actor',true) IS DISTINCT FROM actor::text THEN
  IF NOT pg_try_advisory_xact_lock(hashtextextended('master-history:'||actor::text,0)) THEN RAISE EXCEPTION '当前账号的另一项资料操作正在提交' USING ERRCODE='55P03'; END IF;
  PERFORM set_config('app.master_history_prelocked_actor',actor::text,true);
 END IF;
 INSERT INTO master_operation_history(actor_id,entity_type,request_id,transaction_id,operation_type,label,request_path,request_method,unsupported_reason)
 VALUES(actor,'units',request,txid_current(),'EDIT','修改单位计量设置',path,method,'此操作同时修改计量维度或换算规则，请使用单位维护流程处理')
 ON CONFLICT(actor_id,request_id,transaction_id) DO NOTHING RETURNING id INTO operation;
 IF operation IS NOT NULL THEN
  UPDATE master_operation_history SET redo_allowed=false WHERE actor_id=actor AND entity_type='units' AND state='UNDONE' AND redo_allowed;
 ELSE
  SELECT id INTO STRICT operation FROM master_operation_history WHERE actor_id=actor AND request_id=request AND transaction_id=txid_current();
 END IF;
 UPDATE master_operation_history SET unsupported_reason='此操作同时修改计量维度或换算规则，请使用单位维护流程处理'
 WHERE actor_id=actor AND request_id=request AND transaction_id=txid_current();
 unit_id:=COALESCE(NEW.unit_id,OLD.unit_id);
 SELECT fn_goods_history_snapshot('units'::regclass,u) INTO snapshot FROM units u WHERE u.id=unit_id;
 INSERT INTO master_operation_history_rows(operation_id,table_name,row_id,before_row,after_row,expected_row,before_token,after_token)
 VALUES(operation,'units',unit_id,snapshot,snapshot,snapshot,snapshot,snapshot)
 ON CONFLICT(operation_id,table_name,row_id) DO NOTHING;
 RETURN COALESCE(NEW,OLD);
END $$;
CREATE TRIGGER trg_master_history_unit_profile AFTER INSERT OR UPDATE OR DELETE ON unit_measurement_profiles
 FOR EACH ROW EXECUTE FUNCTION fn_mark_master_history_profile();

-- Responsibility, access grants and append-only score evidence are visible
-- commands but must keep their dedicated business/security transitions.
CREATE FUNCTION fn_record_master_history_auxiliary() RETURNS trigger LANGUAGE plpgsql AS $$
DECLARE actor uuid:=nullif(current_setting('app.actor_id',true),'')::uuid;
 request uuid:=nullif(current_setting('app.audit_request_id',true),'')::uuid;
 path text:=current_setting('app.audit_request_path',true); method text:=current_setting('app.audit_request_method',true);
 entity text; parent_table text; parent_id uuid; operation uuid; snapshot jsonb; node jsonb; command_label text; blocked text;
BEGIN
 IF current_setting('app.master_history_replay',true)='on' OR actor IS NULL OR request IS NULL THEN RETURN COALESCE(NEW,OLD); END IF;
 entity:=fn_master_history_entity(path,method);IF entity IS NULL THEN RETURN COALESCE(NEW,OLD); END IF;
 node:=to_jsonb(COALESCE(NEW,OLD));
 IF TG_TABLE_NAME='warehouse_keepers' THEN
  parent_table:='warehouses';parent_id:=(node->>'warehouse_id')::uuid;
  command_label:='修改仓库保管责任';blocked:='仓库保管责任会影响任务、库存责任及交接范围，请通过仓库负责人维护流程调整，不能直接回放旧责任';
 ELSIF TG_TABLE_NAME='client_visibility_grants' THEN
  parent_table:='clients';parent_id:=(node->>'client_id')::uuid;
  command_label:='修改客户访问授权';blocked:='客户访问授权需要重新核对负责人、被授权人与当前账号权限，请使用客户访问设置重新调整';
 ELSE
  parent_table:=CASE WHEN node->>'party_type'='CLIENT' THEN 'clients' ELSE 'suppliers' END;parent_id:=(node->>'party_id')::uuid;
  command_label:='新增跟进与信誉记录';blocked:='跟进及信誉分属于追加业务证据，不能删除或回放旧分数；请新增纠正记录保留完整过程';
 END IF;
 IF current_setting('app.master_history_prelocked_actor',true) IS DISTINCT FROM actor::text THEN
  IF NOT pg_try_advisory_xact_lock(hashtextextended('master-history:'||actor::text,0)) THEN RAISE EXCEPTION '当前账号的另一项资料操作正在提交' USING ERRCODE='55P03'; END IF;
  PERFORM set_config('app.master_history_prelocked_actor',actor::text,true);
 END IF;
 INSERT INTO master_operation_history(actor_id,entity_type,request_id,transaction_id,operation_type,label,request_path,request_method,unsupported_reason)
 VALUES(actor,entity,request,txid_current(),'EDIT',command_label,path,method,blocked)
 ON CONFLICT(actor_id,request_id,transaction_id) DO NOTHING RETURNING id INTO operation;
 IF operation IS NOT NULL THEN
  UPDATE master_operation_history SET redo_allowed=false WHERE actor_id=actor AND entity_type=entity AND state='UNDONE' AND redo_allowed;
 ELSE
  SELECT id INTO STRICT operation FROM master_operation_history WHERE actor_id=actor AND request_id=request AND transaction_id=txid_current();
  UPDATE master_operation_history SET unsupported_reason=blocked,label=command_label WHERE id=operation;
 END IF;
 EXECUTE format('SELECT fn_goods_history_snapshot(%L::regclass,t) FROM %I t WHERE id=$1',parent_table,parent_table) INTO snapshot USING parent_id;
 INSERT INTO master_operation_history_rows(operation_id,table_name,row_id,before_row,after_row,expected_row,before_token,after_token)
 VALUES(operation,parent_table,parent_id,snapshot,snapshot,snapshot,snapshot,snapshot)
 ON CONFLICT(operation_id,table_name,row_id) DO NOTHING;
 RETURN COALESCE(NEW,OLD);
END $$;
CREATE TRIGGER trg_master_history_keepers AFTER INSERT OR UPDATE OR DELETE ON warehouse_keepers FOR EACH ROW EXECUTE FUNCTION fn_record_master_history_auxiliary();
CREATE TRIGGER trg_master_history_access AFTER INSERT OR UPDATE OR DELETE ON client_visibility_grants FOR EACH ROW EXECUTE FUNCTION fn_record_master_history_auxiliary();
CREATE TRIGGER trg_master_history_activity AFTER INSERT OR UPDATE OR DELETE ON party_activity_records FOR EACH ROW EXECUTE FUNCTION fn_record_master_history_auxiliary();

CREATE FUNCTION fn_replay_master_operation(p_id uuid,p_actor uuid,p_version bigint,p_undo boolean,p_employee uuid DEFAULT NULL) RETURNS void LANGUAGE plpgsql AS $$
DECLARE op master_operation_history%ROWTYPE; r record; actual jsonb; target jsonb; token jsonb; cols text; next_redo uuid; blocked text;
BEGIN
 PERFORM pg_advisory_xact_lock(hashtextextended('master-history:'||p_actor::text,0));
 SELECT * INTO op FROM master_operation_history WHERE id=p_id AND actor_id=p_actor FOR UPDATE;
 IF NOT FOUND THEN RAISE EXCEPTION '操作历史不存在'; END IF;
 IF NOT EXISTS(SELECT 1 FROM (SELECT id FROM master_operation_history WHERE actor_id=p_actor AND entity_type=op.entity_type ORDER BY created_at DESC,id DESC LIMIT 10) h WHERE id=p_id) THEN RAISE EXCEPTION '仅支持最近 10 次操作'; END IF;
 IF op.version<>p_version OR (p_undo AND op.state<>'APPLIED') OR (NOT p_undo AND op.state<>'UNDONE') THEN RAISE EXCEPTION '记录已变化，请刷新后重试'; END IF;
 IF op.unsupported_reason IS NOT NULL THEN RAISE EXCEPTION '%',op.unsupported_reason; END IF;
 IF NOT p_undo THEN
  SELECT h.id INTO next_redo FROM master_operation_history_events e JOIN master_operation_history h ON h.id=e.operation_id
   WHERE e.actor_id=p_actor AND h.entity_type=op.entity_type AND e.action='UNDO' AND h.state='UNDONE' AND h.redo_allowed ORDER BY e.id DESC LIMIT 1;
  IF NOT op.redo_allowed OR next_redo IS DISTINCT FROM p_id THEN RAISE EXCEPTION '只能取消最近一次撤回；新增操作后不能再取消之前的撤回'; END IF;
 END IF;
 FOR r IN SELECT * FROM master_operation_history_rows WHERE operation_id=p_id ORDER BY table_name,row_id LOOP
  blocked:=fn_master_history_unsupported(r.table_name,r.before_row,r.after_row);
  IF blocked IS NOT NULL THEN RAISE EXCEPTION '%',blocked; END IF;
  EXECUTE format('SELECT fn_goods_history_snapshot(%L::regclass,t) FROM %I t WHERE id=$1 FOR UPDATE',r.table_name,r.table_name) INTO actual USING r.row_id;
  IF actual IS DISTINCT FROM r.expected_row THEN RAISE EXCEPTION '相关资料已有后续修改，没有覆盖任何修改'; END IF;
 END LOOP;
 PERFORM set_config('app.master_history_replay','on',true);
 FOR r IN SELECT * FROM master_operation_history_rows WHERE operation_id=p_id
  ORDER BY CASE WHEN COALESCE((CASE WHEN p_undo THEN before_row ELSE after_row END)->>'is_deleted','true')='true'
   THEN CASE WHEN table_name IN ('client_categories','supplier_categories','mould_categories') THEN 2 ELSE 1 END
   ELSE CASE WHEN table_name IN ('client_categories','supplier_categories','mould_categories') THEN 0 ELSE 3 END END,
  CASE WHEN table_name IN ('client_categories','supplier_categories','mould_categories') THEN
   CASE WHEN COALESCE((CASE WHEN p_undo THEN before_row ELSE after_row END)->>'is_deleted','true')='true'
    THEN -COALESCE((after_row->>'level')::int,0) ELSE COALESCE(((CASE WHEN p_undo THEN before_row ELSE after_row END)->>'level')::int,0) END END,
  capture_order LOOP
  EXECUTE format('SELECT fn_goods_history_snapshot(%L::regclass,t) FROM %I t WHERE id=$1',r.table_name,r.table_name) INTO actual USING r.row_id;
  token:=CASE WHEN p_undo THEN r.before_token ELSE r.after_token END;
  target:=CASE WHEN p_undo THEN r.before_row ELSE r.after_row END;
  IF r.table_name IN ('party_contact_methods','party_addresses') THEN
   IF target IS NOT NULL THEN target:=target||jsonb_build_object('updated_at',clock_timestamp(),'updated_by',p_actor); END IF;
   IF target IS NULL THEN
    EXECUTE format('DELETE FROM %I WHERE id=$1',r.table_name) USING r.row_id;
   ELSIF actual IS NULL THEN
    target:=target||jsonb_build_object('version',greatest(COALESCE((r.before_token->>'version')::bigint,0),COALESCE((r.after_token->>'version')::bigint,0))+1);
    EXECUTE format('INSERT INTO %I SELECT * FROM jsonb_populate_record(NULL::%I,$1)',r.table_name,r.table_name) USING target;
   ELSE
    target:=actual||COALESCE((SELECT jsonb_object_agg(e.key,e.value) FROM jsonb_each(target) e
     WHERE r.before_row->e.key IS DISTINCT FROM r.after_row->e.key AND e.key IN ('kind','value','is_primary','remark','address','is_default')),'{}'::jsonb);
    target:=target||jsonb_build_object('updated_at',clock_timestamp(),'updated_by',p_actor);
    SELECT string_agg(format('%I',attname),',' ORDER BY attnum) INTO cols FROM pg_attribute
     WHERE attrelid=r.table_name::regclass AND attnum>0 AND NOT attisdropped AND attname NOT IN ('id','party_type','party_id','created_at','created_by');
    EXECUTE format('UPDATE %I SET (%s)=(SELECT %s FROM jsonb_populate_record(NULL::%I,$1)) WHERE id=$2',r.table_name,cols,cols,r.table_name) USING target,r.row_id;
   END IF;
  ELSE
  IF r.before_row IS NULL THEN
   target:=actual||jsonb_build_object('is_deleted',p_undo,'deleted_at',CASE WHEN p_undo THEN to_jsonb(clock_timestamp()) ELSE 'null'::jsonb END);
  ELSE
   target:=actual||COALESCE((SELECT jsonb_object_agg(e.key,e.value) FROM jsonb_each(target) e
    WHERE r.before_row->e.key IS DISTINCT FROM r.after_row->e.key
    AND e.key NOT IN ('id','created_at','created_by','updated_at','updated_by','version','__binary')),'{}'::jsonb);
  END IF;
  target:=target||jsonb_build_object('updated_at',clock_timestamp(),'updated_by',CASE WHEN r.table_name='client_ship_addresses' THEN p_employee ELSE p_actor END);
  IF actual ? 'version' THEN target:=target||jsonb_build_object('version',(actual->>'version')::bigint+1); END IF;
  SELECT string_agg(format('%I',attname),',' ORDER BY attnum) INTO cols FROM pg_attribute
   WHERE attrelid=r.table_name::regclass AND attnum>0 AND NOT attisdropped AND attgenerated=''
   AND atttypid<>'bytea'::regtype AND attname NOT IN ('id','created_at','created_by');
  EXECUTE format('UPDATE %I SET (%s)=(SELECT %s FROM jsonb_populate_record(NULL::%I,$1)) WHERE id=$2',r.table_name,cols,cols,r.table_name) USING target-'__binary',r.row_id;
  END IF;
  EXECUTE format('SELECT fn_goods_history_snapshot(%L::regclass,t) FROM %I t WHERE id=$1',r.table_name,r.table_name) INTO actual USING r.row_id;
  UPDATE master_operation_history_rows SET expected_row=CASE WHEN expected_row=token THEN actual ELSE expected_row END,
   before_token=CASE WHEN before_token=token THEN actual ELSE before_token END, after_token=CASE WHEN after_token=token THEN actual ELSE after_token END
   WHERE table_name=r.table_name AND row_id=r.row_id AND token IS NOT NULL AND (expected_row=token OR before_token=token OR after_token=token);
  UPDATE master_operation_history_rows SET expected_row=actual WHERE operation_id=p_id AND table_name=r.table_name AND row_id=r.row_id;
 END LOOP;
 UPDATE master_operation_history SET state=CASE WHEN p_undo THEN 'UNDONE' ELSE 'APPLIED' END,version=version+1,redo_allowed=p_undo WHERE id=p_id;
 INSERT INTO master_operation_history_events(operation_id,actor_id,action) VALUES(p_id,p_actor,CASE WHEN p_undo THEN 'UNDO' ELSE 'REDO' END);
 PERFORM set_config('app.master_history_replay','off',true);
END $$;

DO $$ DECLARE t text; BEGIN
 FOREACH t IN ARRAY ARRAY['clients','suppliers','moulds','colors','units','currencies','warehouses','accounts','settlement_methods','payment_styles','client_categories','supplier_categories','mould_categories','party_contact_methods','party_addresses','client_ship_addresses'] LOOP
  EXECUTE format('CREATE TRIGGER trg_master_operation_history AFTER INSERT OR UPDATE OR DELETE ON %I FOR EACH ROW EXECUTE FUNCTION fn_capture_master_operation_history()',t);
 END LOOP;
END $$;

DO $$ DECLARE definition text; anchor text:='    RETURN v_row;'; BEGIN
 SELECT pg_get_functiondef('public.fn_audit_redact_row(text,jsonb)'::regprocedure) INTO definition;
 IF (length(definition)-length(replace(definition,anchor,'')))/length(anchor)<>1 THEN RAISE EXCEPTION 'Cannot safely extend history audit projection'; END IF;
 EXECUTE replace(definition,anchor,E'    IF p_table_name=''master_operation_history_rows'' THEN\n        v_row:=v_row-ARRAY[''before_row'',''after_row'',''expected_row'',''before_token'',''after_token''];\n    END IF;\n'||anchor);
END $$;
SELECT fn_audit_track_table('master_operation_history','FULL');
SELECT fn_audit_track_table('master_operation_history_rows','FULL');
SELECT fn_audit_track_table('master_operation_history_events','FULL');
CREATE TRIGGER trg_master_history_events_immutable BEFORE UPDATE OR DELETE ON master_operation_history_events FOR EACH ROW EXECUTE FUNCTION fn_lifecycle_evidence_immutable();
CREATE TRIGGER trg_master_history_events_no_truncate BEFORE TRUNCATE ON master_operation_history_events FOR EACH STATEMENT EXECUTE FUNCTION fn_lifecycle_evidence_immutable();
DO $$ DECLARE definition text; anchor text:='(''goods_operation_history_events'', ''PRESERVE'')'; BEGIN
 SELECT pg_get_functiondef('public.business_data_reset()'::regprocedure) INTO definition;
 IF (length(definition)-length(replace(definition,anchor,'')))/length(anchor)<>1 THEN RAISE EXCEPTION 'Cannot safely extend history reset policy'; END IF;
 EXECUTE replace(definition,anchor,anchor||E',\n    (''master_operation_history'', ''PRESERVE''),\n    (''master_operation_history_rows'', ''PRESERVE''),\n    (''master_operation_history_events'', ''PRESERVE'')');
END $$;
