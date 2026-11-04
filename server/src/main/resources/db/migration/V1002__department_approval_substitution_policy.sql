-- Explicit, versioned recusal routing. A substitution only covers the department manager's own application.
CREATE TABLE department_approval_policies (
 id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
 department_id uuid NOT NULL UNIQUE REFERENCES departments(id),
 substitute_employee_id uuid REFERENCES employees(id),
 version bigint NOT NULL DEFAULT 1 CHECK(version>0),
 created_at timestamptz NOT NULL DEFAULT now(),updated_at timestamptz NOT NULL DEFAULT now(),
 created_by uuid,updated_by uuid
);
CREATE INDEX idx_department_approval_substitute ON department_approval_policies(substitute_employee_id) WHERE substitute_employee_id IS NOT NULL;
CREATE TRIGGER trg_audit_department_approval_policies AFTER INSERT OR UPDATE OR DELETE ON department_approval_policies FOR EACH ROW EXECUTE FUNCTION fn_audit();
ALTER TABLE expense_claims ADD COLUMN department_approval_snapshot jsonb;
ALTER TABLE business_applications ADD COLUMN department_approval_snapshot jsonb;
ALTER TABLE expense_claims ADD COLUMN routing_stale_notified_round integer;
ALTER TABLE expense_claims ADD COLUMN abandoned_at timestamptz;
ALTER TABLE expense_claims ADD CONSTRAINT expense_claims_abandoned_fact_chk CHECK(abandoned_at IS NULL OR (is_deleted AND status='REJECTED' AND paid_at IS NULL AND finance_expense_id IS NULL));
ALTER TABLE expense_claim_events DROP CONSTRAINT expense_claim_events_type_chk;
ALTER TABLE expense_claim_events ADD CONSTRAINT expense_claim_events_type_chk CHECK(event_type IN('CREATED','SUBMITTED','WITHDRAWN','EDITED','STAGE_APPROVED','APPROVED','REJECTED','PAID','ABANDONED'));
ALTER TABLE business_applications ADD COLUMN routing_stale_notified_round integer;
CREATE TRIGGER trg_department_approval_policy_read_scope AFTER INSERT OR UPDATE OR DELETE ON department_approval_policies
FOR EACH STATEMENT EXECUTE FUNCTION fn_mark_read_scope_domains('expense');
ALTER TABLE department_approval_policies ENABLE ALWAYS TRIGGER trg_department_approval_policy_read_scope;
CREATE TRIGGER trg_department_approval_manager_read_scope AFTER UPDATE OF manager_id,parent_id,is_deleted,level ON departments
FOR EACH ROW WHEN(OLD.manager_id IS DISTINCT FROM NEW.manager_id OR OLD.parent_id IS DISTINCT FROM NEW.parent_id OR OLD.is_deleted IS DISTINCT FROM NEW.is_deleted OR OLD.level IS DISTINCT FROM NEW.level)
EXECUTE FUNCTION fn_mark_read_scope_domains('expense');
CREATE TRIGGER trg_department_approval_employee_read_scope AFTER UPDATE OF department_id,status,is_deleted ON employees
FOR EACH ROW WHEN(OLD.department_id IS DISTINCT FROM NEW.department_id OR OLD.status IS DISTINCT FROM NEW.status OR OLD.is_deleted IS DISTINCT FROM NEW.is_deleted)
EXECUTE FUNCTION fn_mark_read_scope_domains('expense');
CREATE TRIGGER trg_department_approval_secondary_read_scope AFTER INSERT OR UPDATE OR DELETE ON employee_secondary_departments
FOR EACH STATEMENT EXECUTE FUNCTION fn_mark_read_scope_domains('expense');
CREATE TRIGGER trg_expense_approval_department_read_scope AFTER UPDATE OF applicant_department_id ON expense_claims
FOR EACH ROW WHEN(OLD.applicant_department_id IS DISTINCT FROM NEW.applicant_department_id) EXECUTE FUNCTION fn_mark_read_scope_domains('expense');
CREATE TRIGGER trg_application_approval_department_read_scope AFTER UPDATE OF department_id,applicant_id ON business_applications
FOR EACH ROW WHEN(OLD.department_id IS DISTINCT FROM NEW.department_id OR OLD.applicant_id IS DISTINCT FROM NEW.applicant_id) EXECUTE FUNCTION fn_mark_read_scope_domains('expense');
-- Peer reviewers lose current-node read authority when a different employee advances the document.
CREATE TRIGGER trg_expense_approval_phase_read_scope AFTER UPDATE OF status,approval_stage,approval_participants,approval_round,is_deleted ON expense_claims
FOR EACH ROW WHEN(ROW(OLD.status,OLD.approval_stage,OLD.approval_participants,OLD.approval_round,OLD.is_deleted)
 IS DISTINCT FROM ROW(NEW.status,NEW.approval_stage,NEW.approval_participants,NEW.approval_round,NEW.is_deleted))
EXECUTE FUNCTION fn_mark_read_scope_domains('expense');
CREATE TRIGGER trg_application_approval_phase_read_scope AFTER UPDATE OF status,approval_stage,round,finance_document_id,finance_document_type ON business_applications
FOR EACH ROW WHEN(ROW(OLD.status,OLD.approval_stage,OLD.round,OLD.finance_document_id,OLD.finance_document_type)
 IS DISTINCT FROM ROW(NEW.status,NEW.approval_stage,NEW.round,NEW.finance_document_id,NEW.finance_document_type))
EXECUTE FUNCTION fn_mark_read_scope_domains('expense');
CREATE FUNCTION fn_department_approval_workbench_code(p_department uuid) RETURNS text LANGUAGE sql STABLE AS $body$
 WITH RECURSIVE ancestors(id,parent_id,code,level,depth) AS (
  SELECT id,parent_id,code,level,0 FROM departments WHERE id=p_department AND NOT is_deleted
  UNION ALL SELECT p.id,p.parent_id,p.code,p.level,a.depth+1 FROM departments p JOIN ancestors a ON a.parent_id=p.id WHERE NOT p.is_deleted
 ) SELECT code FROM ancestors ORDER BY CASE WHEN level='一级部门' OR code='GM' THEN 0 ELSE 1 END,depth DESC LIMIT 1;
$body$;
CREATE FUNCTION fn_department_approval_snapshot_stale(p_applicant uuid,p_department uuid,p_snapshot jsonb)
RETURNS boolean LANGUAGE sql STABLE AS $body$
 SELECT COALESCE((SELECT CASE WHEN COALESCE(p_snapshot->>'requiresSubstitute','false')='true' THEN NOT COALESCE(
    p_snapshot->>'departmentId'=d.id::text AND p_snapshot->>'managerId'=p_applicant::text AND d.manager_id=p_applicant
    AND p_snapshot->>'departmentGeneration'=d.permission_delegation_generation::text
    AND p_snapshot->>'configurationVersion'=COALESCE(p.version,0)::text
    AND p_snapshot->>'substituteEmployeeId'=p.substitute_employee_id::text AND NOT d.is_deleted,FALSE)
   ELSE (d.manager_id IS NOT DISTINCT FROM p_applicant) OR d.is_deleted END
  FROM departments d LEFT JOIN department_approval_policies p ON p.department_id=d.id WHERE d.id=p_department),TRUE);
$body$;
CREATE FUNCTION fn_queue_department_approval_routing_changed() RETURNS trigger LANGUAGE plpgsql AS $body$
DECLARE changed jsonb:=CASE WHEN TG_OP='DELETE' THEN to_jsonb(OLD) ELSE to_jsonb(NEW) END;
        department uuid:=(changed->>CASE WHEN TG_TABLE_NAME='departments' THEN 'id' ELSE 'department_id' END)::uuid;
BEGIN
 INSERT INTO business_outbox(id,event_type,aggregate_type,aggregate_id,payload,dedupe_key,created_by)
 VALUES(gen_random_uuid(),'DEPARTMENT_APPROVAL_ROUTING_CHANGED','DEPARTMENT',department,'{}'::jsonb,
   'DEPARTMENT_APPROVAL_ROUTING_CHANGED:'||department||':'||txid_current(),NULLIF(current_setting('app.actor_id',true),'')::uuid)
 ON CONFLICT(dedupe_key) DO NOTHING;
 RETURN NULL;
END;
$body$;
CREATE TRIGGER trg_department_approval_routing_changed AFTER INSERT OR UPDATE OR DELETE ON department_approval_policies
FOR EACH ROW EXECUTE FUNCTION fn_queue_department_approval_routing_changed();
CREATE TRIGGER trg_department_manager_approval_routing_changed AFTER UPDATE OF manager_id,parent_id,is_deleted,level ON departments
FOR EACH ROW WHEN(OLD.manager_id IS DISTINCT FROM NEW.manager_id OR OLD.parent_id IS DISTINCT FROM NEW.parent_id OR OLD.is_deleted IS DISTINCT FROM NEW.is_deleted OR OLD.level IS DISTINCT FROM NEW.level)
EXECUTE FUNCTION fn_queue_department_approval_routing_changed();
-- Existing manager-owned pending documents have no fabricated routing assignment.
-- Their applicants receive the same actionable receipt after this upgrade commits.
INSERT INTO business_outbox(id,event_type,aggregate_type,aggregate_id,payload,dedupe_key)
SELECT gen_random_uuid(),'DEPARTMENT_APPROVAL_ROUTING_CHANGED','DEPARTMENT',department_id,'{}'::jsonb,
 'DEPARTMENT_APPROVAL_ROUTING_UPGRADE:V1002:'||department_id
FROM (
 SELECT applicant_department_id AS department_id FROM expense_claims
 WHERE NOT is_deleted AND status IN('SUBMITTED','REVIEWING') AND approval_stage='DEPARTMENT'
  AND fn_department_approval_snapshot_stale(applicant_id,applicant_department_id,department_approval_snapshot)
 UNION
 SELECT department_id FROM business_applications WHERE status IN('SUBMITTED','REVIEWING') AND approval_stage='DEPARTMENT'
  AND fn_department_approval_snapshot_stale(applicant_id,department_id,department_approval_snapshot)
) affected WHERE department_id IS NOT NULL
ON CONFLICT(dedupe_key) DO NOTHING;
INSERT INTO permissions(code,name,module,category,sort_order,action_type,description,grant_policy,high_risk,baseline)
VALUES('approval_policy:manage','配置负责人回避审批人','组织管理','审批设置',420,'EDIT',
 '配置部门负责人本人申请的上级或替补审核人；版本改变后旧申请须撤回重提，不自动授予审批权限。',ARRAY['INDIVIDUAL_ONLY']::text[],true,false);
INSERT INTO permission_surface_permissions(surface_id,permission_id)
SELECT s.id,p.id FROM permission_surfaces s CROSS JOIN permissions p WHERE s.surface_key IN('approvals.center','hr.department') AND p.code='approval_policy:manage' ON CONFLICT DO NOTHING;
CREATE FUNCTION fn_department_approval_can_review(p_actor uuid,p_applicant uuid,p_department uuid,p_snapshot jsonb)
RETURNS boolean LANGUAGE sql STABLE AS $body$
 WITH RECURSIVE roots(id) AS (
  SELECT d.id FROM departments d WHERE NOT d.is_deleted AND (d.manager_id=p_actor
   OR d.id=(SELECT department_id FROM employees WHERE id=p_actor AND NOT is_deleted)
   OR d.id IN(SELECT department_id FROM employee_secondary_departments WHERE employee_id=p_actor))
 ), scoped(id) AS (
  SELECT id FROM roots UNION SELECT child.id FROM departments child JOIN scoped parent ON child.parent_id=parent.id WHERE NOT child.is_deleted
 )
 SELECT EXISTS(SELECT 1 FROM departments d LEFT JOIN department_approval_policies policy ON policy.department_id=d.id
  WHERE d.id=p_department AND NOT d.is_deleted AND p_actor<>p_applicant
   AND EXISTS(SELECT 1 FROM employees e WHERE e.id=p_actor AND NOT e.is_deleted AND e.status IN('active','probation','onLeave'))
   AND CASE WHEN COALESCE(p_snapshot->>'requiresSubstitute','false')='true' THEN
     p_snapshot->>'departmentId'=d.id::text AND p_snapshot->>'managerId'=p_applicant::text AND d.manager_id=p_applicant
     AND p_snapshot->>'departmentGeneration'=d.permission_delegation_generation::text
     AND p_snapshot->>'configurationVersion'=COALESCE(policy.version,0)::text
     AND p_snapshot->>'substituteEmployeeId'=p_actor::text AND policy.substitute_employee_id=p_actor
    ELSE d.manager_id IS DISTINCT FROM p_applicant AND d.id IN(SELECT id FROM scoped) END);
$body$;
CREATE OR REPLACE FUNCTION fn_expense_approval_eligible(p_employee uuid,p_permissions text[],p_id uuid)
RETURNS boolean LANGUAGE sql STABLE AS $body$
 SELECT EXISTS(SELECT 1 FROM expense_claims c WHERE c.id=p_id AND NOT c.is_deleted
  AND c.status IN('SUBMITTED','REVIEWING') AND c.applicant_id<>p_employee
  AND EXISTS(SELECT 1 FROM employees e WHERE e.id=p_employee AND NOT e.is_deleted AND e.status IN('active','probation','onLeave'))
  AND POSITION(p_employee::text IN COALESCE(c.approval_participants,''))=0
  AND CASE c.approval_stage
   WHEN 'DEPARTMENT' THEN 'expense:approve:department'=ANY(p_permissions) AND fn_department_approval_can_review(p_employee,c.applicant_id,c.applicant_department_id,c.department_approval_snapshot)
   WHEN 'FINANCE_INITIAL' THEN 'expense:approve:finance_initial'=ANY(p_permissions)
   WHEN 'FINANCE_REVIEW' THEN 'expense:approve:finance_review'=ANY(p_permissions)
   WHEN 'EXECUTIVE' THEN 'expense:approve:executive'=ANY(p_permissions) ELSE FALSE END);
$body$;
-- A payment notification cannot revive an earlier reviewer's duty through its read-side predicate.
-- EXPENSE_PAYMENT_NOTICE_PATCH:START
DO $migration$
DECLARE definition text; anchor text:=$anchor$WHEN 'EXPENSE_CLAIM_PENDING_PAYMENT' THEN task.status='APPROVED' AND task.applicant_id<>employee_id
                        AND task.approved_by IS DISTINCT FROM employee_id$anchor$;
BEGIN
 definition:=pg_get_functiondef('fn_notice_business_action_visible(uuid,text,text,uuid,text,text,text,text,text,text)'::regprocedure);
 IF (length(definition)-length(replace(definition,anchor,'')))/length(anchor)<>1 THEN RAISE EXCEPTION 'Expense payment notice predicate changed; inspect before upgrading'; END IF;
 EXECUTE replace(definition,anchor,anchor||E'\n                        AND POSITION(employee_id::text IN COALESCE(task.approval_participants,\'\'))=0');
END;
$migration$;
-- EXPENSE_PAYMENT_NOTICE_PATCH:END

UPDATE permissions SET description=E'能做什么：配置部门负责人本人申请时的上级或替补审批人。\n\n范围与限制：仅有本项的管理员可以更改配置，不能指定负责人本人，也不会因此授予替补任何审批权限；普通员工申请不使用这份跨部门回避范围。\n\n提醒和待办：本项不加入业务待办；配置或负责人变更后，原负责人本人待审单据须撤回重提，旧审批范围不会因删除后重新添加而恢复。\n\n例如：为某部门负责人自己的报销预先配置另一位有部门审核权限的上级，由其回避处理。' WHERE code='approval_policy:manage';
