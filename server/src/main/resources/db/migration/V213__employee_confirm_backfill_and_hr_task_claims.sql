-- =====================================================================
-- V210：转正日期老数据回填 + 任职事件 'confirm' + HR 任务软认领 + employee:export
-- 背景：ADR-021。正式名录 141 人仅 1 人登记转正日期，HR 任务中心噪音过大；
-- 老数据适配 = 未登记转正日期的非试用期员工默认按入职日期视为已转正；
-- 试用期员工不回填，继续走转正提醒与办理。
-- =====================================================================

-- 1) 老数据回填：confirmed_at 默认 = hire_date（仅非试用期；probation 待办理转正）
UPDATE employees
SET confirmed_at = hire_date
WHERE confirmed_at IS NULL
  AND status <> 'probation';

COMMENT ON COLUMN employees.confirmed_at IS
'转正日期。老数据已按入职日期回填（V210）；新员工：正式入职必填、试用期办理转正时写入；≠试用期结束（hire_date+contract.probation_months 派生）';

-- 2) 任职轨迹新增事件类型 confirm（转正办理写入，时间线可见）
ALTER TABLE employment_history DROP CONSTRAINT employment_history_event_type_check;
ALTER TABLE employment_history ADD CONSTRAINT employment_history_event_type_check
    CHECK (event_type IN ('onboard', 'transfer', 'resign', 'rehire', 'confirm'));

-- 3) HR 任务软认领（ADR-021 §四：任务不隐藏，显示「XXX 处理中」，24h 租约）
CREATE TABLE hr_task_claims (
    id           UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    task_type    TEXT NOT NULL,                 -- confirm / birthday / anniversary / newhire
    employee_id  UUID NOT NULL REFERENCES employees(id) ON DELETE CASCADE,
    claimed_by   UUID NOT NULL REFERENCES employees(id) ON DELETE CASCADE,
    claimed_at   TIMESTAMPTZ NOT NULL DEFAULT now(),
    lease_until  TIMESTAMPTZ NOT NULL,          -- 认领租约到期；过期视为自动释放（读取时惰性判定）
    released_at  TIMESTAMPTZ,                   -- 主动释放/被接管时间；NULL = 仍占用（在租约内有效）
    remark       TEXT,
    created_at   TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_at   TIMESTAMPTZ NOT NULL DEFAULT now(),
    created_by   UUID,
    updated_by   UUID
);
-- 同一任务同一时间只允许一条未释放认领
CREATE UNIQUE INDEX uq_hr_task_claim_active
    ON hr_task_claims (task_type, employee_id)
    WHERE released_at IS NULL;
CREATE INDEX idx_hr_task_claims_claimer ON hr_task_claims (claimed_by) WHERE released_at IS NULL;
COMMENT ON TABLE hr_task_claims IS
'HR 工作台任务软认领：任务始终可见，认领者显示「处理中」，租约过期自动失效；employee:edit 可接管';

-- 通用审计触发器（fn_audit 见 V05）
DROP TRIGGER IF EXISTS trg_audit_hr_task_claims ON hr_task_claims;
CREATE TRIGGER trg_audit_hr_task_claims
    AFTER INSERT OR UPDATE OR DELETE ON hr_task_claims
    FOR EACH ROW EXECUTE FUNCTION fn_audit();

-- 4) 新权限点 employee:export：员工资料打印/导出（花名册、部门架构图等文档下载）
INSERT INTO permissions (code, name, category, sort_order)
VALUES ('employee:export', '员工资料打印与导出（花名册/架构图）', '员工档案', 61)
ON CONFLICT (code) DO NOTHING;

-- 预配行政与人力资源部（幂等；其他部门由超管在权限管理页按需配置）
INSERT INTO department_permissions (department_id, permission_id)
SELECT d.id, p.id
FROM departments d, permissions p
WHERE d.code = 'DEPT_HR' AND p.code = 'employee:export'
ON CONFLICT DO NOTHING;
