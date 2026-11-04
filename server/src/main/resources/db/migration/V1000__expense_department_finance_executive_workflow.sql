-- Paper-source reimbursement chain: department manager -> finance initial -> finance review -> executive -> payment.
-- People named on the paper are authorization assignments, never identities embedded in executable rules.
-- Existing completed approvals/payments keep their original facts. Pending documents restart at the
-- department gate without inventing past signatures; no existing user receives a new approval grant.
ALTER TABLE expense_claims ADD COLUMN expense_kind TEXT NOT NULL DEFAULT 'GENERAL';
ALTER TABLE expense_claims ADD COLUMN approval_stage TEXT DEFAULT 'DEPARTMENT';
ALTER TABLE expense_claims ADD COLUMN approval_round INTEGER NOT NULL DEFAULT 0;
ALTER TABLE expense_claims ADD COLUMN approval_participants TEXT NOT NULL DEFAULT '';
UPDATE expense_claims SET approval_stage=NULL WHERE status IN ('APPROVED','PAID');
UPDATE expense_claims SET approval_round=1 WHERE status IN ('SUBMITTED','REVIEWING');
-- Single-stage leases/reminders cannot block or describe the new department gate.
UPDATE task_claims SET released_at=now(),release_reason='workflow_changed'
WHERE target_type='EXPENSE_APPROVE' AND released_at IS NULL AND target_key IN
 (SELECT id::text FROM expense_claims WHERE status IN('SUBMITTED','REVIEWING'));
UPDATE notices SET resolved_at=now(),resolved_reason='EXPENSE_WORKFLOW_UPGRADED'
WHERE source_event='EXPENSE_CLAIM_SUBMITTED' AND resolved_at IS NULL AND aggregate_id IN
 (SELECT id FROM expense_claims WHERE status IN('SUBMITTED','REVIEWING'));
ALTER TABLE expense_claims ADD CONSTRAINT expense_claims_kind_chk CHECK(expense_kind IN ('GENERAL','TRAVEL'));
ALTER TABLE expense_claims ADD CONSTRAINT expense_claims_stage_chk CHECK(approval_stage IS NULL OR approval_stage IN ('DEPARTMENT','FINANCE_INITIAL','FINANCE_REVIEW','EXECUTIVE'));
ALTER TABLE expense_claims ADD CONSTRAINT expense_claims_round_chk CHECK(approval_round>=0);
ALTER TABLE expense_claim_events ADD COLUMN approval_stage TEXT;
ALTER TABLE expense_claim_events ADD COLUMN approval_round INTEGER;
ALTER TABLE expense_claim_events DROP CONSTRAINT expense_claim_events_type_chk;
ALTER TABLE expense_claim_events ADD CONSTRAINT expense_claim_events_type_chk CHECK(event_type IN ('CREATED','SUBMITTED','WITHDRAWN','EDITED','STAGE_APPROVED','APPROVED','REJECTED','PAID'));
CREATE INDEX idx_expense_claims_approval_stage ON expense_claims(approval_stage,applicant_department_id,submitted_at,id) WHERE NOT is_deleted AND status IN ('SUBMITTED','REVIEWING');
CREATE INDEX idx_expense_claim_events_participant ON expense_claim_events(actor_employee_id,claim_id,approval_stage) WHERE event_type IN ('STAGE_APPROVED','APPROVED','REJECTED');
CREATE UNIQUE INDEX uq_expense_claim_stage_round_approval ON expense_claim_events(claim_id,approval_round,approval_stage) WHERE event_type IN ('STAGE_APPROVED','APPROVED') AND approval_stage IS NOT NULL;

WITH additions(code,name,description,baseline) AS (VALUES
 ('expense:approve:department','审核本部门报销','审核本部门及负责范围内的报销，填写驳回原因；通过后交财务初核。不能审批自己的报销，也不能代替财务或总经办审批。',FALSE),
 ('expense:approve:finance_initial','报销财务初核','核对报销凭证、用途与金额，通过后交另一员工财务复核；不能审批自己的报销或兼审同单其他节点。',FALSE),
 ('expense:approve:finance_review','报销财务复核','对财务初核后的报销再次复核，通过后交总经办批准；不能兼任同一报销的初核人。',FALSE),
 ('expense:approve:executive','总经办批准报销','批准已经部门审核、财务初核及财务复核的报销，批准后财务方可登记付款；不能自审或越级。',FALSE))
INSERT INTO permissions(code,name,description,baseline,action_type,module,category,grant_policy,high_risk)
SELECT code,name,description,baseline,'APPROVE','员工报销','报销审批',ARRAY['BULK_EXCLUDED']::text[],true FROM additions
ON CONFLICT(code) DO NOTHING;
UPDATE permissions SET category='员工报销' WHERE code IN ('expense:approve:department','expense:approve:finance_initial','expense:approve:finance_review','expense:approve:executive');

INSERT INTO permission_surfaces(id,surface_key,name,sort_order,enabled) VALUES('10000000-0000-4000-8000-000000000003','approvals.center','审批中心',5,TRUE) ON CONFLICT(surface_key) DO NOTHING;
WITH mapping(surface_key,permission_code) AS (VALUES
 ('hr.expense','expense:approve:department'),
 ('hr.expense','expense:approve:finance_initial'),
 ('hr.expense','expense:approve:finance_review'),
 ('hr.expense','expense:approve:executive'),
 ('finance.hub','expense:approve:finance_initial'),
 ('finance.hub','expense:approve:finance_review'))
INSERT INTO permission_surface_permissions(surface_id,permission_id)
SELECT s.id,p.id FROM mapping m JOIN permission_surfaces s ON s.surface_key=m.surface_key JOIN permissions p ON p.code=m.permission_code
ON CONFLICT DO NOTHING;
INSERT INTO permission_surface_permissions(surface_id,permission_id)
SELECT s.id,p.id FROM permission_surfaces s CROSS JOIN permissions p
WHERE s.surface_key='approvals.center' AND p.code IN ('expense:approve:department','expense:approve:finance_initial','expense:approve:finance_review','expense:approve:executive','expense:pay','expense:view')
ON CONFLICT DO NOTHING;
INSERT INTO permission_surface_permissions(surface_id,permission_id)
SELECT s.id,p.id FROM permission_surfaces s CROSS JOIN permissions p
WHERE s.surface_key IN('hr.expense','approvals.center') AND p.code IN('attachment:view','attachment:download')
ON CONFLICT DO NOTHING;
-- The sales manager's established review surface remains the authority for every order/quote action.
INSERT INTO permission_surface_permissions(surface_id,permission_id)
SELECT target.id,link.permission_id FROM permission_surfaces source
JOIN permission_surface_permissions link ON link.surface_id=source.id
CROSS JOIN permission_surfaces target
WHERE source.surface_key='sales.manager-review' AND target.surface_key='approvals.center'
ON CONFLICT DO NOTHING;
UPDATE permission_surfaces SET name='审批中心' WHERE surface_key='sales.manager-review';
-- All existing expense settings/approval surfaces expose the precise grants for administrators.
INSERT INTO permission_surface_permissions(surface_id,permission_id)
SELECT DISTINCT s.id,p.id FROM permission_surfaces s CROSS JOIN permissions p
WHERE (s.surface_key='hr.expense' OR s.surface_key='finance.hub')
AND p.code IN ('expense:approve:department','expense:approve:finance_initial','expense:approve:finance_review','expense:approve:executive')
ON CONFLICT DO NOTHING;

-- Read-side notification qualification is checked against the current node, not a historic pool.
CREATE FUNCTION fn_expense_approval_eligible(p_employee uuid,p_permissions text[],p_id uuid)
RETURNS boolean LANGUAGE sql STABLE AS $function$
 WITH RECURSIVE roots(id) AS (
   SELECT d.id FROM departments d WHERE NOT d.is_deleted AND (
     d.manager_id=p_employee OR d.id=(SELECT e.department_id FROM employees e WHERE e.id=p_employee AND NOT e.is_deleted)
     OR d.id IN(SELECT department_id FROM employee_secondary_departments WHERE employee_id=p_employee))
 ), scoped(id) AS (
   SELECT id FROM roots UNION SELECT d.id FROM departments d JOIN scoped p ON p.id=d.parent_id WHERE NOT d.is_deleted
 )
 SELECT EXISTS(SELECT 1 FROM expense_claims c WHERE c.id=p_id AND NOT c.is_deleted
   AND EXISTS(SELECT 1 FROM employees current_employee WHERE current_employee.id=p_employee AND NOT current_employee.is_deleted AND current_employee.status IN('active','probation','onLeave'))
   AND c.status IN('SUBMITTED','REVIEWING') AND c.applicant_id<>p_employee
   AND POSITION(p_employee::text IN COALESCE(c.approval_participants,''))=0
   AND CASE c.approval_stage
     WHEN 'DEPARTMENT' THEN 'expense:approve:department'=ANY(p_permissions) AND c.applicant_department_id IN(SELECT id FROM scoped)
     WHEN 'FINANCE_INITIAL' THEN 'expense:approve:finance_initial'=ANY(p_permissions)
     WHEN 'FINANCE_REVIEW' THEN 'expense:approve:finance_review'=ANY(p_permissions)
     WHEN 'EXECUTIVE' THEN 'expense:approve:executive'=ANY(p_permissions)
     ELSE FALSE END);
$function$;
DO $migration$
DECLARE definition text; anchor text := $$WHEN 'EXPENSE_CLAIM_SUBMITTED' THEN task.status='SUBMITTED' AND task.applicant_id<>employee_id$$;
BEGIN
 definition:=pg_get_functiondef('fn_notice_business_action_visible(uuid,text,text,uuid,text,text,text,text,text,text)'::regprocedure);
 IF (length(definition)-length(replace(definition,anchor,'')))/length(anchor)<>1 THEN RAISE EXCEPTION 'Expense notice predicate changed; inspect before upgrading'; END IF;
 EXECUTE replace(definition,anchor,$$WHEN 'EXPENSE_CLAIM_SUBMITTED' THEN fn_expense_approval_eligible(employee_id,permissions,task.id)$$);
END;
$migration$;

UPDATE permissions p SET name=h.name,description=h.description FROM (VALUES
 ('expense:approve:department','审核本部门报销','能做什么：审核本部门及负责范围内的报销，通过后交财务初核。

范围与限制：不能审批自己的报销，同一人不能兼审同单多个节点，不能越级；原件查看下载仍分别检查附件权限。

提醒和待办：仅接收当前轮次、当前节点且可由本人办理的报销待办，已审、撤回、驳回后及时办结。

例如：部门负责人核对本部门员工报销后通过，或填写原因退回修改。'),
 ('expense:approve:executive','总经办批准报销','能做什么：批准已经部门审核、财务初核和复核的报销，通过后交财务付款。

范围与限制：不能审批自己的报销，同一人不能兼审同单多个节点，不能越级；原件查看下载仍分别检查附件权限。

提醒和待办：仅接收当前轮次、当前节点且可由本人办理的报销待办，已审、撤回、驳回后及时办结。

例如：总经办经理核对完整审批记录后批准支付。'),
 ('expense:approve:finance_initial','报销财务初核','能做什么：逐张核对报销凭证、用途与金额，通过后交另一员工复核。

范围与限制：不能审批自己的报销，同一人不能兼审同单多个节点，不能越级；原件查看下载仍分别检查附件权限。

提醒和待办：仅接收当前轮次、当前节点且可由本人办理的报销待办，已审、撤回、驳回后及时办结。

例如：财务初核人登记发票核对依据，再交财务复核。'),
 ('expense:approve:finance_review','报销财务复核','能做什么：复核已完成初核的报销，通过后交总经办批准。

范围与限制：不能审批自己的报销，同一人不能兼审同单多个节点，不能越级；原件查看下载仍分别检查附件权限。

提醒和待办：仅接收当前轮次、当前节点且可由本人办理的报销待办，已审、撤回、驳回后及时办结。

例如：另一名财务复核人核对初核结果后批准或填写原因驳回。')
) h(code,name,description) WHERE p.code=h.code;
