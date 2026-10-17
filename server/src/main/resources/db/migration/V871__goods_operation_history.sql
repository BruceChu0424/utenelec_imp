-- User-owned, transaction-grouped goods editing history. Snapshots are private
-- server evidence; the API never returns them. Existing row audit stays enabled.
CREATE TABLE goods_operation_history (
    id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    actor_id uuid NOT NULL,
    request_id uuid NOT NULL,
    transaction_id bigint NOT NULL,
    operation_type text NOT NULL,
    label text NOT NULL,
    request_path text NOT NULL,
    request_method text NOT NULL,
    state text NOT NULL DEFAULT 'APPLIED' CHECK (state IN ('APPLIED','UNDONE')),
    version bigint NOT NULL DEFAULT 0,
    redo_allowed boolean NOT NULL DEFAULT false,
    unsupported_reason text,
    category_context text,
    created_at timestamptz NOT NULL DEFAULT clock_timestamp(),
    UNIQUE(actor_id, request_id, transaction_id)
);
CREATE INDEX idx_goods_operation_history_actor ON goods_operation_history(actor_id,created_at DESC,id DESC);
CREATE TABLE goods_operation_history_rows (
    operation_id uuid NOT NULL REFERENCES goods_operation_history(id),
    table_name text NOT NULL CHECK (table_name IN ('goods','goods_bom_items','material_categories','colors','units')),
    row_id uuid NOT NULL,
    before_row jsonb,
    after_row jsonb,
    expected_row jsonb,
    before_token jsonb,
    after_token jsonb,
    capture_order bigint GENERATED ALWAYS AS IDENTITY,
    PRIMARY KEY(operation_id,table_name,row_id)
);
CREATE INDEX idx_goods_history_row_lineage ON goods_operation_history_rows(table_name,row_id);
CREATE TABLE goods_operation_history_events (
    id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    operation_id uuid NOT NULL REFERENCES goods_operation_history(id),
    actor_id uuid NOT NULL,
    action text NOT NULL CHECK (action IN ('UNDO','REDO')),
    created_at timestamptz NOT NULL DEFAULT clock_timestamp()
);
CREATE INDEX idx_goods_operation_history_events_actor ON goods_operation_history_events(actor_id,id DESC);

CREATE FUNCTION fn_goods_history_operation(p_path text,p_method text)
RETURNS text LANGUAGE sql IMMUTABLE AS $$
 SELECT CASE
 WHEN p_method NOT IN ('POST','PUT','PATCH','DELETE') THEN NULL
 WHEN p_path='/api/master/goods/import/commit' AND p_method='POST' THEN 'GOODS_IMPORT'
 WHEN p_path='/api/master/goods' AND p_method='POST' THEN 'GOODS_CREATE'
 WHEN p_path='/api/master/goods/batch-delete' AND p_method='POST' THEN 'GOODS_DELETE'
 WHEN p_path='/api/master/goods/batch-status' AND p_method='POST' THEN 'GOODS_STATUS'
 WHEN p_path='/api/master/goods/bom/paste' AND p_method='POST' THEN 'BOM_PASTE'
 WHEN p_path ~ '^/api/master/goods/[0-9a-fA-F-]{36}/bom/import/commit$' AND p_method='POST' THEN 'BOM_PASTE'
 WHEN p_path ~ '^/api/master/goods/[0-9a-fA-F-]{36}$' AND p_method='PUT' THEN 'GOODS_EDIT'
 WHEN p_path ~ '^/api/master/goods/[0-9a-fA-F-]{36}$' AND p_method='DELETE' THEN 'GOODS_DELETE'
 WHEN p_path ~ '^/api/master/goods/[0-9a-fA-F-]{36}/name-en$' AND p_method='PUT' THEN 'GOODS_NAME_EN'
 WHEN p_path ~ '^/api/master/goods/[0-9a-fA-F-]{36}/purchase-receipt-policy$' AND p_method='PUT' THEN 'GOODS_PURCHASE_POLICY'
 WHEN p_path ~ '^/api/master/goods/[0-9a-fA-F-]{36}/subcontract-loss-policy$' AND p_method='PUT' THEN 'GOODS_SUBCONTRACT_POLICY'
 WHEN p_path ~ '^/api/master/goods/[0-9a-fA-F-]{36}/status$' AND p_method='PATCH' THEN 'GOODS_STATUS'
 WHEN p_path ~ '^/api/master/goods/[0-9a-fA-F-]{36}/bom$' AND p_method='POST' THEN 'BOM_CREATE'
 WHEN p_path ~ '^/api/master/goods/[0-9a-fA-F-]{36}/bom/[0-9a-fA-F-]{36}$' AND p_method='PUT' THEN 'BOM_EDIT'
 WHEN p_path ~ '^/api/master/goods/[0-9a-fA-F-]{36}/bom/[0-9a-fA-F-]{36}$' AND p_method='DELETE' THEN 'BOM_DELETE'
 WHEN p_path ~ '^/api/master/goods/[0-9a-fA-F-]{36}/bom/batch-delete$' AND p_method='POST' THEN 'BOM_DELETE'
 WHEN p_path ~ '^/api/master/goods/[0-9a-fA-F-]{36}/bom/[0-9a-fA-F-]{36}/audit$' AND p_method='PUT' THEN 'BOM_AUDIT'
 WHEN p_path='/api/master/material-categories' AND p_method='POST' THEN 'CATEGORY_CREATE'
 WHEN p_path ~ '^/api/master/material-categories/[0-9a-fA-F-]{36}$' AND p_method='PUT' THEN 'CATEGORY_EDIT'
 WHEN p_path ~ '^/api/master/material-categories/[0-9a-fA-F-]{36}$' AND p_method='DELETE' THEN 'CATEGORY_DELETE'
 WHEN p_path='/api/master/goods/issue-method/batch' THEN 'SPECIALIZED_OPERATION'
 WHEN p_path ~ '^/api/master/goods/[0-9a-fA-F-]{36}/bom-learning/relearn$' THEN 'SPECIALIZED_OPERATION'
 WHEN p_path ~ '/(detect|export|preview)$' THEN NULL
 WHEN p_path LIKE '/api/master/goods/%' AND p_path NOT LIKE '/api/master/goods/history%' THEN 'SPECIALIZED_OPERATION'
 ELSE NULL END
$$;

-- The request preparation SPI calls this immediately after binding actor and
-- route metadata, before any domain row or numbering-sequence lock. Serializing
-- at capture time alone can invert actor -> goods/category lock ordering.
CREATE FUNCTION fn_begin_goods_history_request() RETURNS void LANGUAGE plpgsql AS $$
DECLARE
 v_actor uuid:=nullif(current_setting('app.actor_id',true),'')::uuid;
 v_path text:=current_setting('app.audit_request_path',true);
 v_method text:=current_setting('app.audit_request_method',true);
BEGIN
 IF v_actor IS NULL OR v_method IS NULL OR v_method NOT IN ('POST','PUT','PATCH','DELETE') THEN RETURN; END IF;
 IF fn_goods_history_operation(v_path,v_method) IS NULL
    AND NOT (v_method='POST' AND COALESCE(v_path,'') ~ '^/api/master/goods/history/[0-9a-fA-F-]{36}/(undo|redo)$') THEN RETURN; END IF;
 IF current_setting('app.goods_history_prelocked_actor',true)=v_actor::text THEN RETURN; END IF;
 PERFORM pg_advisory_xact_lock(hashtextextended('goods-history:'||v_actor::text,0));
 PERFORM set_config('app.goods_history_prelocked_actor',v_actor::text,true);
END $$;

-- Legacy images can be megabytes each. Project bytea out before JSON creation,
-- retaining only a digest to detect an intervening image change. Replay never
-- writes binary columns or attachment/object-store state.
CREATE FUNCTION fn_goods_history_snapshot(p_relation regclass,p_row anyelement)
RETURNS jsonb LANGUAGE plpgsql STABLE AS $$
DECLARE projection text; binary_projection text; result jsonb;
BEGIN
 SELECT string_agg(format('($1).%I AS %I',attname,attname),',' ORDER BY attnum),
        string_agg(format('%L,encode(sha256(($1).%I),''hex'')',attname,attname),',' ORDER BY attnum)
          FILTER(WHERE atttypid='bytea'::regtype)
 INTO projection,binary_projection
 FROM pg_attribute WHERE attrelid=p_relation AND attnum>0 AND NOT attisdropped AND atttypid<>'bytea'::regtype;
 -- Build the binary expression separately so no bytea enters projection.
 SELECT string_agg(format('%L,encode(sha256(($1).%I),''hex'')',attname,attname),',' ORDER BY attnum)
 INTO binary_projection FROM pg_attribute
 WHERE attrelid=p_relation AND attnum>0 AND NOT attisdropped AND atttypid='bytea'::regtype;
 EXECUTE 'SELECT to_jsonb(projected)'||CASE WHEN binary_projection IS NULL THEN ''
   ELSE '||jsonb_build_object(''__binary'',jsonb_build_object('||binary_projection||'))' END
   ||' FROM (SELECT '||projection||') projected' INTO result USING p_row;
 RETURN result;
END $$;

CREATE FUNCTION fn_capture_goods_operation_history() RETURNS trigger LANGUAGE plpgsql AS $$
DECLARE
 v_path text:=current_setting('app.audit_request_path',true);
 v_method text:=current_setting('app.audit_request_method',true);
 v_actor uuid:=nullif(current_setting('app.actor_id',true),'')::uuid;
 v_request uuid:=nullif(current_setting('app.audit_request_id',true),'')::uuid;
 v_type text; v_id uuid; v_before jsonb; v_after jsonb; v_row uuid;
BEGIN
 IF current_setting('app.goods_history_replay',true)='on' OR v_actor IS NULL OR v_request IS NULL THEN
   RETURN COALESCE(NEW,OLD);
 END IF;
 v_type:=fn_goods_history_operation(v_path,v_method);
 IF v_type IS NULL THEN RETURN COALESCE(NEW,OLD); END IF;
 IF TG_OP<>'INSERT' THEN v_before:=fn_goods_history_snapshot(TG_RELID,OLD); END IF;
 IF TG_OP<>'DELETE' THEN v_after:=fn_goods_history_snapshot(TG_RELID,NEW); END IF;
 IF v_before IS NOT DISTINCT FROM v_after THEN RETURN COALESCE(NEW,OLD); END IF;
 v_row:=COALESCE(v_after,v_before)->>'id';
 -- Normal requests acquired this lock before touching domain rows. A legacy
 -- or direct caller may still capture safely when the actor is free, but must
 -- never wait for that actor while already holding business-row locks.
 IF current_setting('app.goods_history_prelocked_actor',true) IS DISTINCT FROM v_actor::text THEN
  IF NOT pg_try_advisory_xact_lock(hashtextextended('goods-history:'||v_actor::text,0)) THEN
   RAISE EXCEPTION '同一账号的另一项货品操作正在提交，请稍后重试' USING ERRCODE='55P03';
  END IF;
  PERFORM set_config('app.goods_history_prelocked_actor',v_actor::text,true);
 END IF;
 INSERT INTO goods_operation_history(actor_id,request_id,transaction_id,operation_type,label,request_path,request_method,unsupported_reason)
 VALUES(v_actor,v_request,txid_current(),v_type,
   CASE v_type WHEN 'GOODS_CREATE' THEN '新增货品' WHEN 'GOODS_EDIT' THEN '修改货品'
   WHEN 'GOODS_NAME_EN' THEN '修改英文名称' WHEN 'GOODS_STATUS' THEN '启用或停用货品'
   WHEN 'GOODS_PURCHASE_POLICY' THEN '修改采购超收设置' WHEN 'GOODS_SUBCONTRACT_POLICY' THEN '修改委外损耗设置'
   WHEN 'GOODS_DELETE' THEN '删除货品' WHEN 'GOODS_IMPORT' THEN '导入货品'
   WHEN 'BOM_CREATE' THEN '新增组装组件' WHEN 'BOM_EDIT' THEN '修改组装组件'
   WHEN 'BOM_DELETE' THEN '删除组装组件' WHEN 'BOM_PASTE' THEN '粘贴或导入组装信息'
   WHEN 'BOM_AUDIT' THEN '核对组装组件' WHEN 'CATEGORY_CREATE' THEN '新增货品分类'
   WHEN 'CATEGORY_EDIT' THEN '修改货品分类' WHEN 'CATEGORY_DELETE' THEN '删除货品分类'
   ELSE '专用业务操作' END,v_path,v_method,
   CASE WHEN v_type='SPECIALIZED_OPERATION' THEN '此操作涉及业务准备或学习状态，请使用对应业务流程处理' END)
 ON CONFLICT(actor_id,request_id,transaction_id) DO NOTHING RETURNING id INTO v_id;
 IF v_id IS NOT NULL THEN
   UPDATE goods_operation_history SET redo_allowed=false
    WHERE actor_id=v_actor AND state='UNDONE' AND redo_allowed;
 ELSE
   SELECT id INTO STRICT v_id FROM goods_operation_history
    WHERE actor_id=v_actor AND request_id=v_request AND transaction_id=txid_current();
 END IF;
 IF TG_OP='DELETE' OR (v_before IS NOT NULL AND v_before->'__binary' IS DISTINCT FROM v_after->'__binary') THEN
  UPDATE goods_operation_history SET unsupported_reason='此操作涉及原始图片或永久删除，不能通过资料历史恢复' WHERE id=v_id;
 END IF;
 INSERT INTO goods_operation_history_rows(operation_id,table_name,row_id,before_row,after_row,expected_row,before_token,after_token)
 VALUES(v_id,TG_TABLE_NAME,v_row,v_before,v_after,v_after,v_before,v_after)
 ON CONFLICT(operation_id,table_name,row_id) DO UPDATE
 SET after_row=excluded.after_row,expected_row=excluded.expected_row,after_token=excluded.after_token;
 RETURN COALESCE(NEW,OLD);
END $$;

-- Category prefix/move operations depend on the complete subtree membership,
-- including goods that did not themselves change. A deferred once-per-operation
-- digest captures the final transaction state without retaining another copy
-- of the entire catalogue. UUID/code relationships, rather than wall-clock
-- timestamps, also detect a later commit from an older long-running transaction.
CREATE FUNCTION fn_goods_history_category_context(p_id uuid) RETURNS text LANGUAGE sql STABLE AS $$
 WITH RECURSIVE roots(id) AS (
  SELECT row_id FROM goods_operation_history_rows WHERE operation_id=p_id AND table_name='material_categories'
   AND ((before_row->'parent_id') IS DISTINCT FROM (after_row->'parent_id')
     OR (before_row->'code_prefix') IS DISTINCT FROM (after_row->'code_prefix'))
 ), subtree(id) AS (
  SELECT id FROM roots UNION SELECT c.id FROM material_categories c JOIN subtree p ON p.id=c.parent_id WHERE NOT c.is_deleted
 ), context_rows AS (
  SELECT 'C:'||c.id::text identity,jsonb_build_array(c.id,c.parent_id,c.code,c.code_prefix,c.is_deleted)::text content
   FROM material_categories c JOIN subtree s ON s.id=c.id
  UNION ALL
  SELECT 'G:'||g.id::text,jsonb_build_array(g.id,g.category_id,g.code,g.code_prefix_category_id)::text
   FROM goods g JOIN subtree s ON s.id=g.category_id WHERE NOT g.is_deleted
  UNION ALL
  SELECT 'P:'||p.id::text,jsonb_build_array(p.id,p.parent_id,p.path,p.level,p.code_prefix,p.is_deleted)::text
   FROM material_categories p WHERE p.id IN (
    SELECT (node->>'parent_id')::uuid FROM goods_operation_history_rows h
    CROSS JOIN LATERAL (VALUES(h.before_row),(h.after_row)) nodes(node)
    WHERE h.operation_id=p_id AND h.table_name='material_categories' AND node->>'parent_id' IS NOT NULL)
 ) SELECT CASE WHEN EXISTS(SELECT 1 FROM roots)
  THEN encode(sha256(convert_to(COALESCE(string_agg(identity||content,E'\n' ORDER BY identity),''),'UTF8')),'hex') END
 FROM context_rows
$$;
CREATE FUNCTION fn_finalize_goods_history_context() RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
 IF NEW.operation_type='CATEGORY_EDIT' THEN
  UPDATE goods_operation_history SET category_context=fn_goods_history_category_context(NEW.id) WHERE id=NEW.id;
 END IF;
 RETURN NEW;
END $$;
CREATE CONSTRAINT TRIGGER trg_finalize_goods_history_context AFTER INSERT ON goods_operation_history
 DEFERRABLE INITIALLY DEFERRED FOR EACH ROW EXECUTE FUNCTION fn_finalize_goods_history_context();

-- This function is called only after the service has rechecked the original
-- permissions, object scope and business-reference guards under table locks.
-- All work, state changes and events share the caller's transaction.
CREATE FUNCTION fn_replay_goods_operation(p_id uuid,p_actor uuid,p_version bigint,p_undo boolean)
RETURNS void LANGUAGE plpgsql AS $$
DECLARE op goods_operation_history%ROWTYPE; r record; actual jsonb; target jsonb;
 token jsonb; cols text; recent boolean; next_redo uuid; parent_id uuid;
BEGIN
 PERFORM pg_advisory_xact_lock(hashtextextended('goods-history:'||p_actor::text,0));
 PERFORM set_config('app.goods_history_prelocked_actor',p_actor::text,true);
 -- Forward commands may already hold a different prefix of these table locks.
 -- Never wait after acquiring a partial replay lock set: retry the whole
 -- transaction instead of creating a category/color/import lock cycle.
 LOCK TABLE colors,units,material_categories,goods,goods_bom_items IN SHARE ROW EXCLUSIVE MODE NOWAIT;
 SELECT * INTO op FROM goods_operation_history WHERE id=p_id AND actor_id=p_actor FOR UPDATE;
 IF NOT FOUND THEN RAISE EXCEPTION '操作历史不存在' USING ERRCODE='P0001'; END IF;
 SELECT EXISTS(SELECT 1 FROM (SELECT id FROM goods_operation_history WHERE actor_id=p_actor
  ORDER BY created_at DESC,id DESC LIMIT 10) recent WHERE id=p_id) INTO recent;
 IF NOT recent THEN RAISE EXCEPTION '仅支持最近 10 次操作，请刷新记录' USING ERRCODE='P0001'; END IF;
 IF op.version<>p_version THEN RAISE EXCEPTION '记录已变化，请刷新后重试' USING ERRCODE='P0001'; END IF;
 IF op.unsupported_reason IS NOT NULL THEN RAISE EXCEPTION '%',op.unsupported_reason USING ERRCODE='P0001'; END IF;
 IF op.category_context IS NOT NULL AND op.category_context IS DISTINCT FROM fn_goods_history_category_context(p_id) THEN
  RAISE EXCEPTION '此分类子树后来新增、移动或修改了资料，不能直接恢复旧层级或编号前缀' USING ERRCODE='P0001';
 END IF;
 IF (p_undo AND op.state<>'APPLIED') OR (NOT p_undo AND op.state<>'UNDONE') THEN
  RAISE EXCEPTION '操作状态已变化，请刷新后重试' USING ERRCODE='P0001';
 END IF;
 IF NOT p_undo THEN
  SELECT h.id INTO next_redo FROM goods_operation_history_events e JOIN goods_operation_history h ON h.id=e.operation_id
   WHERE e.actor_id=p_actor AND e.action='UNDO' AND h.state='UNDONE' AND h.redo_allowed
   ORDER BY e.id DESC LIMIT 1;
  IF next_redo IS DISTINCT FROM p_id THEN
   RAISE EXCEPTION '只能取消最近一次撤回；新增操作后不能再取消之前的撤回' USING ERRCODE='P0001';
  END IF;
 END IF;
 FOR r IN SELECT * FROM goods_operation_history_rows WHERE operation_id=p_id ORDER BY table_name,row_id LOOP
  EXECUTE format('SELECT fn_goods_history_snapshot(%L::regclass,t) FROM %I t WHERE id=$1 FOR UPDATE',r.table_name,r.table_name)
   INTO actual USING r.row_id;
  IF actual IS DISTINCT FROM r.expected_row THEN
   RAISE EXCEPTION '相关资料已有后续修改，请先撤回后续操作或刷新后处理；没有覆盖任何修改' USING ERRCODE='P0001';
  END IF;
 END LOOP;
 PERFORM set_config('app.goods_history_replay','on',true);
 FOR r IN SELECT *,CASE WHEN p_undo THEN before_row ELSE after_row END AS target_row
  FROM goods_operation_history_rows WHERE operation_id=p_id
  ORDER BY CASE WHEN COALESCE((CASE WHEN p_undo THEN before_row ELSE after_row END)->>'is_deleted','true')='true'
    THEN CASE table_name WHEN 'goods_bom_items' THEN 0 WHEN 'goods' THEN 1 WHEN 'material_categories' THEN 2 ELSE 3 END
    ELSE CASE table_name WHEN 'colors' THEN 4 WHEN 'units' THEN 4 WHEN 'material_categories' THEN 5 WHEN 'goods' THEN 6 ELSE 7 END END,
    CASE WHEN table_name='material_categories' THEN
     CASE WHEN COALESCE((CASE WHEN p_undo THEN before_row ELSE after_row END)->>'is_deleted','true')='true'
       THEN -COALESCE((after_row->>'level')::int,0)
       ELSE COALESCE(((CASE WHEN p_undo THEN before_row ELSE after_row END)->>'level')::int,0) END END,
    CASE WHEN COALESCE((CASE WHEN p_undo THEN before_row ELSE after_row END)->>'is_deleted','true')='true'
      THEN -capture_order ELSE capture_order END
 LOOP
  EXECUTE format('SELECT fn_goods_history_snapshot(%L::regclass,t) FROM %I t WHERE id=$1',r.table_name,r.table_name)
   INTO actual USING r.row_id;
  token:=CASE WHEN p_undo THEN r.before_token ELSE r.after_token END;
  target:=r.target_row;
  IF r.before_row IS NULL THEN
   -- A creation is retained as the same UUID. Undo/redo only toggles its
   -- lifecycle; later legitimate derived values are not copied from creation.
   target:=actual||jsonb_build_object('is_deleted',p_undo,'deleted_at',CASE WHEN p_undo THEN to_jsonb(clock_timestamp()) ELSE 'null'::jsonb END);
  ELSE
   -- Strict whole-row CAS above detects outside writers, while the replay
   -- writes only fields actually changed by this operation. In particular an
   -- older name/price edit must not restore a stale derived BOM material cost
   -- after a later BOM undo legitimately recalculated that cost.
   target:=actual||COALESCE((SELECT jsonb_object_agg(e.key,e.value) FROM jsonb_each(target) e
    WHERE r.before_row->e.key IS DISTINCT FROM r.after_row->e.key
     AND e.key NOT IN ('id','created_at','created_by','updated_at','updated_by','version','__binary')),'{}'::jsonb);
  END IF;
  target:=target||jsonb_build_object('updated_at',clock_timestamp(),'updated_by',p_actor);
  IF actual ? 'version' THEN target:=target||jsonb_build_object('version',(actual->>'version')::bigint+1); END IF;
  SELECT string_agg(format('%I',attname),',' ORDER BY attnum) INTO cols FROM pg_attribute
   WHERE attrelid=r.table_name::regclass AND attnum>0 AND NOT attisdropped AND attgenerated=''
     AND atttypid<>'bytea'::regtype AND attname NOT IN ('id','created_at','created_by');
  EXECUTE format('UPDATE %I SET (%s)=(SELECT %s FROM jsonb_populate_record(NULL::%I,$1)) WHERE id=$2',r.table_name,cols,cols,r.table_name)
   USING target-'__binary',r.row_id;
  EXECUTE format('SELECT fn_goods_history_snapshot(%L::regclass,t) FROM %I t WHERE id=$1',r.table_name,r.table_name)
   INTO actual USING r.row_id;
  -- Propagate only an exact lineage token, never a content-only match. Versions
  -- changed by an outside writer (including ABA) cannot be rebased this way.
  UPDATE goods_operation_history_rows SET
   expected_row=CASE WHEN expected_row=token THEN actual ELSE expected_row END,
   before_token=CASE WHEN before_token=token THEN actual ELSE before_token END,
   after_token=CASE WHEN after_token=token THEN actual ELSE after_token END
   WHERE table_name=r.table_name AND row_id=r.row_id AND token IS NOT NULL
    AND (expected_row=token OR before_token=token OR after_token=token);
  UPDATE goods_operation_history_rows SET expected_row=actual WHERE operation_id=p_id AND table_name=r.table_name AND row_id=r.row_id;
 END LOOP;
 IF EXISTS(WITH RECURSIVE ancestors(root,id) AS (
   SELECT c.id,c.parent_id FROM material_categories c
   JOIN goods_operation_history_rows h ON h.row_id=c.id AND h.table_name='material_categories' AND h.operation_id=p_id
   WHERE NOT c.is_deleted AND c.parent_id IS NOT NULL
   UNION SELECT a.root,c.parent_id FROM ancestors a JOIN material_categories c ON c.id=a.id
    WHERE c.parent_id IS NOT NULL AND NOT c.is_deleted)
   SELECT 1 FROM ancestors WHERE root=id) THEN
  RAISE EXCEPTION '恢复原分类会形成循环，请先处理后续分类移动' USING ERRCODE='P0001';
 END IF;
 -- A component's price may have changed independently since the original BOM
 -- edit. Derived material cost is always recalculated from the restored graph,
 -- never copied from an old cost snapshot. Rebase its exact old token as well.
 IF op.operation_type<>'BOM_AUDIT' THEN
  FOR parent_id IN SELECT DISTINCT (node->>'goods_id')::uuid
   FROM goods_operation_history_rows h
   CROSS JOIN LATERAL (VALUES(h.before_row),(h.after_row)) AS nodes(node)
   WHERE h.operation_id=p_id AND h.table_name='goods_bom_items' AND node IS NOT NULL
  LOOP
   SELECT fn_goods_history_snapshot('goods'::regclass,g) INTO token FROM goods g WHERE id=parent_id;
   UPDATE goods SET source_e=fn_goods_bom_material_cost(id),updated_at=clock_timestamp(),updated_by=p_actor,version=version+1
    WHERE id=parent_id AND NOT is_deleted AND source_e IS DISTINCT FROM fn_goods_bom_material_cost(id);
   SELECT fn_goods_history_snapshot('goods'::regclass,g) INTO actual FROM goods g WHERE id=parent_id;
   UPDATE goods_operation_history_rows SET
    expected_row=CASE WHEN expected_row=token THEN actual ELSE expected_row END,
    before_token=CASE WHEN before_token=token THEN actual ELSE before_token END,
    after_token=CASE WHEN after_token=token THEN actual ELSE after_token END
    WHERE table_name='goods' AND row_id=parent_id AND token IS NOT NULL
     AND (expected_row=token OR before_token=token OR after_token=token);
  END LOOP;
 END IF;
 UPDATE goods_operation_history SET state=CASE WHEN p_undo THEN 'UNDONE' ELSE 'APPLIED' END,
  version=version+1,redo_allowed=p_undo,category_context=fn_goods_history_category_context(p_id) WHERE id=p_id;
 INSERT INTO goods_operation_history_events(operation_id,actor_id,action) VALUES(p_id,p_actor,CASE WHEN p_undo THEN 'UNDO' ELSE 'REDO' END);
 PERFORM set_config('app.goods_history_replay','off',true);
END $$;

DO $$ DECLARE t text; BEGIN
 FOREACH t IN ARRAY ARRAY['goods','goods_bom_items','material_categories','colors','units'] LOOP
  EXECUTE format('CREATE TRIGGER trg_goods_operation_history AFTER INSERT OR UPDATE OR DELETE ON %I FOR EACH ROW EXECUTE FUNCTION fn_capture_goods_operation_history()',t);
 END LOOP;
END $$;

-- Record tables use the current centralized FULL policy, including both row
-- and UPDATE audit triggers. Do not resurrect the pre-V670 trigger layout.
DO $history_audit_metadata$
DECLARE definition text; anchor text:='    RETURN v_row;';
BEGIN
 SELECT pg_get_functiondef('public.fn_audit_redact_row(text,jsonb)'::regprocedure) INTO definition;
 IF (length(definition)-length(replace(definition,anchor,'')))/length(anchor)<>1 THEN
  RAISE EXCEPTION 'V871 cannot safely extend history audit projection';
 END IF;
 EXECUTE replace(definition,anchor,
  E'    IF p_table_name=''goods_operation_history_rows'' THEN\n'
  ||E'        v_row:=v_row-ARRAY[''before_row'',''after_row'',''expected_row'',''before_token'',''after_token''];\n'
  ||E'    END IF;\n'||anchor);
END $history_audit_metadata$;
SELECT fn_audit_track_table('goods_operation_history','FULL');
SELECT fn_audit_track_table('goods_operation_history_rows','FULL');
SELECT fn_audit_track_table('goods_operation_history_events','FULL');
CREATE TRIGGER trg_goods_history_events_immutable BEFORE UPDATE OR DELETE ON goods_operation_history_events
 FOR EACH ROW EXECUTE FUNCTION fn_lifecycle_evidence_immutable();
CREATE TRIGGER trg_goods_history_events_no_truncate BEFORE TRUNCATE ON goods_operation_history_events
 FOR EACH STATEMENT EXECUTE FUNCTION fn_lifecycle_evidence_immutable();

-- Full public-schema verification of the current three-list audit policy.
-- NONE tables stay NONE; every registered writer must use the centralized pair.
DO $verify_audit_coverage$ DECLARE invalid text; BEGIN
 SELECT string_agg(c.relname||':'||t.tgname,', ' ORDER BY c.relname,t.tgname) INTO invalid
 FROM pg_class c JOIN pg_namespace n ON n.oid=c.relnamespace JOIN pg_trigger t ON t.tgrelid=c.oid
 WHERE n.nspname='public' AND c.relkind IN ('r','p') AND NOT c.relispartition
  AND NOT t.tgisinternal AND t.tgparentid=0
  AND t.tgfoid IN ('public.fn_audit()'::regprocedure,'public.fn_audit_route_columns()'::regprocedure)
  AND (t.tgenabled<>'A' OR t.tgname NOT IN (left('trg_audit_'||c.relname,63),left('trg_audit_upd_'||c.relname,63))
   OR (t.tgname=left('trg_audit_upd_'||c.relname,63) AND t.tgqual IS NULL));
 IF invalid IS NOT NULL THEN RAISE EXCEPTION 'V871 audit coverage shape is invalid: %',invalid; END IF;
 IF EXISTS(SELECT t FROM unnest(ARRAY['goods_operation_history','goods_operation_history_rows','goods_operation_history_events']) t
  WHERE (SELECT count(*) FROM pg_trigger g WHERE g.tgrelid=t::regclass AND NOT g.tgisinternal
   AND g.tgfoid='public.fn_audit()'::regprocedure AND g.tgenabled='A')<>2) THEN
  RAISE EXCEPTION 'V871 history tables require the complete FULL audit pair';
 END IF;
END $verify_audit_coverage$;

DO $reset_policy$ DECLARE definition text; anchor text := '(''goods_import_batches'', ''PRESERVE'')'; BEGIN
 SELECT pg_get_functiondef('public.business_data_reset()'::regprocedure) INTO definition;
 IF (length(definition)-length(replace(definition,anchor,'')))/length(anchor)<>1 THEN
  RAISE EXCEPTION 'V871 cannot extend business-data reset policy safely';
 END IF;
 EXECUTE replace(definition,anchor,anchor||E',\n    (''goods_operation_history'', ''PRESERVE''),\n    (''goods_operation_history_rows'', ''PRESERVE''),\n    (''goods_operation_history_events'', ''PRESERVE'')');
END $reset_policy$;
