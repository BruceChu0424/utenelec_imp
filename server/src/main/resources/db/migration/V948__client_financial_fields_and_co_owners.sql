-- Split financial maintenance from ordinary customer editing. V936 keeps new
-- permissions closed until an administrator explicitly grants them.
INSERT INTO permissions(code,name,module,category,action_type,description,sort_order,grant_policy,high_risk,sensitivity)
VALUES('client:finance','维护客户财务资料','基础资料','客户资料','EDIT',
 '维护客户银行税务、信用及期初应收、铺底额、结算天数、默认结账方式和币种；不授予客户普通资料或负责人维护权限',47,
 ARRAY['NORMAL'],true,'SENSITIVE_COMMERCIAL');
INSERT INTO permission_surface_permissions(surface_id,permission_id)
SELECT s.id,p.id FROM permission_surfaces s CROSS JOIN permissions p
WHERE s.surface_key='basic.client' AND p.code='client:finance';

CREATE TABLE client_co_owners(
 id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
 client_id uuid NOT NULL REFERENCES clients(id) ON DELETE RESTRICT,
 employee_id uuid NOT NULL REFERENCES employees(id) ON DELETE RESTRICT,
 sort_order integer NOT NULL CHECK(sort_order>0),
 UNIQUE(client_id,employee_id)
);
CREATE INDEX idx_client_co_owners_employee ON client_co_owners(employee_id,client_id);
COMMENT ON TABLE client_co_owners IS 'Additional writable customer owners; clients.owner_employee_id retains the first owner. Customer viewers remain read-only and sales documents keep their own responsibility.';
ALTER TABLE client_access_change_events ADD COLUMN previous_owner_ids uuid[] NOT NULL DEFAULT ARRAY[]::uuid[];
ALTER TABLE client_access_change_events ADD COLUMN new_owner_ids uuid[] NOT NULL DEFAULT ARRAY[]::uuid[];
-- Historical events keep their original single-owner columns; no immutable rows are rewritten.

CREATE TRIGGER trg_client_co_owner_current_employee
BEFORE INSERT OR UPDATE OF employee_id ON client_co_owners
FOR EACH ROW EXECUTE FUNCTION fn_require_current_employee_reference_strict('employee_id');
CREATE FUNCTION fn_require_client_co_owner_account() RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
 PERFORM 1 FROM users WHERE employee_id=NEW.employee_id AND NOT is_deleted AND status='active'
 ORDER BY id FOR SHARE;
 IF NOT FOUND THEN RAISE EXCEPTION '客户共同负责人必须具有启用的登录账号' USING ERRCODE='23514'; END IF;
 RETURN NEW;
END $$;
CREATE TRIGGER trg_client_co_owner_account BEFORE INSERT OR UPDATE OF employee_id ON client_co_owners
FOR EACH ROW EXECUTE FUNCTION fn_require_client_co_owner_account();
CREATE FUNCTION fn_guard_client_co_owner_offboarding() RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
 IF (NEW.is_deleted OR NEW.status NOT IN ('active','probation','onLeave')) AND EXISTS(
   SELECT 1 FROM client_co_owners co_owner JOIN clients client ON client.id=co_owner.client_id
   WHERE co_owner.employee_id=NEW.id AND NOT client.is_deleted) THEN
   RAISE EXCEPTION '客户共同负责人须先完成客户责任交接' USING ERRCODE='23514';
 END IF;
 RETURN NEW;
END $$;
CREATE TRIGGER trg_client_co_owner_offboarding BEFORE UPDATE OF status,is_deleted ON employees
FOR EACH ROW EXECUTE FUNCTION fn_guard_client_co_owner_offboarding();
SELECT fn_audit_track_table('client_co_owners','FULL','authorization',false);
CREATE TRIGGER trg_read_scope_client_co_owners AFTER INSERT OR UPDATE OR DELETE ON client_co_owners
FOR EACH ROW EXECUTE FUNCTION fn_mark_read_scope_domains('client');
ALTER TABLE client_co_owners ENABLE ALWAYS TRIGGER trg_read_scope_client_co_owners;
CREATE TRIGGER trg_read_scope_client_co_owners_truncate AFTER TRUNCATE ON client_co_owners
FOR EACH STATEMENT EXECUTE FUNCTION fn_mark_read_scope_domains('client');
ALTER TABLE client_co_owners ENABLE ALWAYS TRIGGER trg_read_scope_client_co_owners_truncate;

-- Reuse the existing customer-owned history roots and dedicated non-replayable
-- access operation. Keep the original trigger functions as the sole implementation.
DO $$ DECLARE definition text; changed text; function_name text;
BEGIN
 FOREACH function_name IN ARRAY ARRAY['fn_capture_master_record_version()','fn_record_master_history_auxiliary()'] LOOP
  SELECT pg_get_functiondef(function_name::regprocedure) INTO definition;
  changed:=replace(definition, 'TG_TABLE_NAME=''client_visibility_grants''',
     'TG_TABLE_NAME IN (''client_visibility_grants'',''client_co_owners'')');
  IF changed=definition THEN RAISE EXCEPTION 'Missing customer history anchor in %',function_name; END IF;
  EXECUTE changed;
 END LOOP;
END $$;
CREATE TRIGGER trg_client_co_owner_record_history AFTER INSERT OR UPDATE OR DELETE ON client_co_owners
FOR EACH ROW EXECUTE FUNCTION fn_capture_master_record_version('clients');
CREATE TRIGGER trg_client_co_owner_operation_history AFTER INSERT OR UPDATE OR DELETE ON client_co_owners
FOR EACH ROW EXECUTE FUNCTION fn_record_master_history_auxiliary();
-- The old server business-data reset was removed in V919; it is deliberately not recreated.
