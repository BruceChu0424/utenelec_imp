-- V229: 采购/委外订货审批与到货超量审批由「指定单一负责人」改为
-- 「财务部门树内持有 finance_order_approval:review 的审核组」(ADR-027)。
--
-- 审批实例与到货异常不再快照单一负责人；assignee_* 列保留为历史快照、V229 起的新行为 NULL。
-- 审批权由 finance_order_approval:review 权限叠加 WorkflowReviewerEligibility 的「财务部门树
-- + 在职 + 账号启用」资格共同决定，超管不在财务部门仍不能审批（保留 ADR-019 的安全边界）。
-- 退役「审批负责人设置」入口：权限码 workflow_assignment:manage 与配置表
-- workflow_responsibility_assignments 一并移除——配置改由权限管理完成。

-- 1) 审批实例/到货异常的负责人快照列改为可空（新行为 NULL；旧行保留）。
ALTER TABLE procurement_order_approval_cases ALTER COLUMN assignee_user_id DROP NOT NULL;
ALTER TABLE procurement_order_approval_cases ALTER COLUMN assignee_employee_id DROP NOT NULL;
ALTER TABLE procurement_order_approval_cases ALTER COLUMN assignee_name_snapshot DROP NOT NULL;

ALTER TABLE procurement_arrival_exceptions ALTER COLUMN finance_assignee_user_id DROP NOT NULL;
ALTER TABLE procurement_arrival_exceptions ALTER COLUMN finance_assignee_employee_id DROP NOT NULL;
ALTER TABLE procurement_arrival_exceptions ALTER COLUMN finance_assignee_name_snapshot DROP NOT NULL;

COMMENT ON COLUMN procurement_order_approval_cases.assignee_user_id IS
    '历史负责人快照（V229 前单负责人模型）；V229 起新行为 NULL。审批权改由 finance_order_approval:review + 财务部门资格决定';
COMMENT ON COLUMN procurement_order_approval_cases.assignee_employee_id IS
    '历史负责人快照（V229 前单负责人模型）；V229 起新行为 NULL';
COMMENT ON COLUMN procurement_arrival_exceptions.finance_assignee_user_id IS
    '历史负责人快照（V229 前单负责人模型）；V229 起新行为 NULL。审批权改由 finance_order_approval:review + 财务部门资格决定';

-- 2) 退役审批负责人配置权限码（先清理授权关联，再删权限，最后删配置表）。
DELETE FROM department_permissions
WHERE permission_id IN (
    SELECT id FROM permissions WHERE code = 'workflow_assignment:manage');
DELETE FROM user_permission_overrides
WHERE permission_id IN (
    SELECT id FROM permissions WHERE code = 'workflow_assignment:manage');
DELETE FROM permissions WHERE code = 'workflow_assignment:manage';

DROP TABLE workflow_responsibility_assignments;
