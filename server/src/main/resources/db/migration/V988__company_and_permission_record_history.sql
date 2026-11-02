-- Reuse the permanent append-only object history store. Never retain passwords,
-- storage paths, request fingerprints or raw account rows in the public history.
CREATE FUNCTION fn_library_history_snapshot(n jsonb) RETURNS jsonb
LANGUAGE sql IMMUTABLE AS $$
 SELECT CASE WHEN n IS NULL THEN NULL ELSE jsonb_build_object(
  'name',n->'name','kind',n->'kind','parent_id',n->'parent_id',
  'description',n->'description','deleted',n->'deleted','pending',n->'pending',
  'size_bytes',n->'size_bytes','content_type',n->'content_type','position',n->'position',
  'inherit_permissions',n->'inherit_permissions',
  'password_revision',n->'password_revision','password_protected',COALESCE(n->>'password_hash','')<>'') END
$$;

CREATE FUNCTION fn_capture_library_record_history() RETURNS trigger LANGUAGE plpgsql AS $$
DECLARE b jsonb; a jsonb; n jsonb; root uuid; snapshot jsonb; actor uuid;
BEGIN
 IF TG_TABLE_NAME='company_file_nodes' THEN
  IF TG_OP<>'INSERT' THEN b:=fn_library_history_snapshot(to_jsonb(OLD)); END IF;
  IF TG_OP<>'DELETE' THEN a:=fn_library_history_snapshot(to_jsonb(NEW)); END IF;
  n:=COALESCE(to_jsonb(NEW),to_jsonb(OLD)); root:=(n->>'id')::uuid;
 ELSE
  n:=COALESCE(to_jsonb(NEW),to_jsonb(OLD)); root:=(n->>'node_id')::uuid;
  SELECT fn_library_history_snapshot(to_jsonb(f)) INTO snapshot FROM company_file_nodes f WHERE id=root;
  IF TG_OP<>'INSERT' THEN b:=snapshot||jsonb_build_object('access_rule',to_jsonb(OLD)-'node_id'); END IF;
  IF TG_OP<>'DELETE' THEN a:=snapshot||jsonb_build_object('access_rule',to_jsonb(NEW)-'node_id'); END IF;
 END IF;
 IF b IS NOT DISTINCT FROM a THEN RETURN COALESCE(NEW,OLD); END IF;
 actor:=NULLIF(current_setting('app.actor_id',true),'')::uuid;
 INSERT INTO master_record_versions(entity_type,source_table,row_id,record_id,before_row,after_row,
  action,actor_id,actor_name,request_id)
 VALUES('company-files',TG_TABLE_NAME,root,root,b,a,
  CASE WHEN TG_TABLE_NAME='company_file_acl' THEN 'EDIT' WHEN b IS NULL THEN 'CREATE'
   WHEN a IS NULL OR NOT COALESCE((b->>'deleted')::boolean,false) AND (a->>'deleted')::boolean THEN 'DELETE'
   WHEN COALESCE((b->>'deleted')::boolean,false) AND NOT (a->>'deleted')::boolean THEN 'RESTORE' ELSE 'EDIT' END,
  actor,NULLIF(current_setting('app.actor_account',true),''),NULLIF(current_setting('app.audit_request_id',true),'')::uuid);
 RETURN COALESCE(NEW,OLD);
END $$;
CREATE TRIGGER trg_library_record_history AFTER INSERT OR UPDATE OR DELETE ON company_file_nodes
 FOR EACH ROW EXECUTE FUNCTION fn_capture_library_record_history();
CREATE TRIGGER trg_library_acl_history AFTER INSERT OR UPDATE OR DELETE ON company_file_acl
 FOR EACH ROW EXECUTE FUNCTION fn_capture_library_record_history();
ALTER TABLE company_file_nodes ENABLE ALWAYS TRIGGER trg_library_record_history;
ALTER TABLE company_file_acl ENABLE ALWAYS TRIGGER trg_library_acl_history;

-- Existing entries get an explicitly labelled baseline, never a fabricated creation event.
INSERT INTO master_record_versions(entity_type,source_table,row_id,record_id,after_row,action,source_key)
 SELECT 'company-files','company_file_nodes',id,id,fn_library_history_snapshot(to_jsonb(n)),'STATUS','BASELINE'
 FROM company_file_nodes n;

CREATE FUNCTION fn_is_permission_history_action(a text) RETURNS boolean LANGUAGE sql IMMUTABLE AS $$
 SELECT a IN ('department_permission_change','permission_baseline_change','user_permission_override_change',
  'manager_permission_delegation_change','user_data_scope_change','permission_configuration_import',
  'permission_configuration_copy','permission_configuration_batch','permission_template_create','permission_template_update',
  'permission_template_delete','permission_template_sync','permission_template_bind','permission_template_apply',
  'permission_template_unbind')
$$;
CREATE FUNCTION fn_permission_history_snapshot(n jsonb) RETURNS jsonb LANGUAGE sql IMMUTABLE AS $$
 SELECT jsonb_strip_nulls(jsonb_build_object('added',n->'added','removed',n->'removed',
  'name',n->'name','description',n->'description','scope',n->'scope','surfaceKey',n->'surfaceKey',
  'templateName',n->'templateName','templateId',n->'templateId','preservePermissions',n->'preservePermissions',
  'userCount',n->'userCount','departmentCount',n->'departmentCount'))
$$;
CREATE FUNCTION fn_capture_permission_record_history() RETURNS trigger LANGUAGE plpgsql AS $$
DECLARE root uuid;
BEGIN
 IF NEW.event_source<>'business' OR NOT fn_is_permission_history_action(NEW.action)
  OR COALESCE(NEW.status_code,200)>=400 OR NEW.after IS NULL
  OR NOT (NEW.after ? 'added' AND NEW.after ? 'removed') THEN RETURN NEW; END IF;
 root:=CASE WHEN NEW.target_id ~* '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$'
  THEN NEW.target_id::uuid ELSE '00000000-0000-0000-0000-000000000000'::uuid END;
 INSERT INTO master_record_versions(entity_type,source_table,row_id,record_id,after_row,source_key,action,
  actor_id,actor_name,request_id,recorded_at)
 VALUES('permissions',NEW.target_type,root,root,fn_permission_history_snapshot(NEW.after),NEW.action,
  CASE WHEN NEW.action='permission_template_create' THEN 'CREATE'
   WHEN NEW.action='permission_template_delete' THEN 'DELETE' ELSE 'EDIT' END,
  NEW.actor_id,NEW.actor_account,NEW.request_id,NEW.created_at);
 RETURN NEW;
END $$;
-- Semantic authorization events already belong to the same business transaction.
-- Retain one permanent fact per real change, independent of audit hot/cold expiry.
CREATE TRIGGER trg_permission_record_history AFTER INSERT ON audit_log
 FOR EACH ROW EXECUTE FUNCTION fn_capture_permission_record_history();
ALTER TABLE audit_log ENABLE ALWAYS TRIGGER trg_permission_record_history;
INSERT INTO master_record_versions(entity_type,source_table,row_id,record_id,after_row,source_key,action,
 actor_id,actor_name,request_id,recorded_at)
SELECT 'permissions',target_type,
 CASE WHEN target_id ~* '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$' THEN target_id::uuid
  ELSE '00000000-0000-0000-0000-000000000000'::uuid END,
 CASE WHEN target_id ~* '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$' THEN target_id::uuid
  ELSE '00000000-0000-0000-0000-000000000000'::uuid END,
 fn_permission_history_snapshot(after),action,
 CASE WHEN action='permission_template_create' THEN 'CREATE' WHEN action='permission_template_delete' THEN 'DELETE' ELSE 'EDIT' END,
 actor_id,actor_account,request_id,created_at
FROM v_audit_log_all WHERE event_source='business' AND fn_is_permission_history_action(action)
 AND COALESCE(status_code,200)<400 AND after ? 'added' AND after ? 'removed' ORDER BY id;
