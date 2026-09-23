-- =====================================================================
-- V657：可对外接待的员工白名单 = 接待访客权限(ADR-109 §3.9)
-- =====================================================================
-- 背景(security-08 / permissions-13)：访客账号靠短信验证码自助注册，搜索接待人时
--   原先能搜到全部在职员工。白名单与「能确认本人来访」本来就是同一件事：
--   被访客选中的人必须能确认这次来访，否则申请会卡在「待接待人确认」。
-- 本迁移：
--   1) visitor:host_confirm 不再放在全员基础包里，改名「接待访客」：持有者才会被访客搜到、
--      被选为接待人，并能确认本人的来访；管理员在权限管理页按部门或逐人增减，
--      白名单就是权限目录本身，不另设名单表。
--   2) 授权策略 NON_DELEGABLE：接待白名单是防名册外泄的安全边界，只由超级管理员按部门或逐人
--      授予，部门负责人不能在页面里自行转授(原是基础包码，不存在委派行，顺手清理以防万一)。
--   3) 默认发给对外接待的部门(客户、供应商、审厂、面试等来访的对口部门)：
--      总经办、综合营销事业部、轨道事业部、新媒体事业部、行政与人力资源部、
--      PMC运营采购部、品质管理部、工程研发部；部门授权对下级部门同样生效。
-- 平台未上线：不做存量兼容，历史申请里的接待人不受影响(只约束新提交与搜索)。
-- =====================================================================

UPDATE permissions
SET baseline = FALSE,
    grant_policy = ARRAY['NON_DELEGABLE']::TEXT[],
    name = '接待访客',
    description = '可被外部访客搜到并选为接待人，并确认本人的来访申请；未持有的员工不会出现在访客搜索结果里'
WHERE code = 'visitor:host_confirm';

DELETE FROM manager_permission_delegations delegation
USING permissions permission
WHERE permission.id = delegation.permission_id
  AND permission.code = 'visitor:host_confirm';

WITH defaults(department_code) AS (VALUES
    ('GM'),
    ('DEPT_SALES'),
    ('DEPT_RAIL'),
    ('DEPT_NEWMEDIA'),
    ('DEPT_HR'),
    ('SUB_PURCHASE'),
    ('DEPT_QA'),
    ('DEPT_ENG')
)
INSERT INTO department_permissions (department_id, permission_id)
SELECT department.id, permission.id
FROM defaults
JOIN departments department ON department.code = defaults.department_code AND NOT department.is_deleted
JOIN permissions permission ON permission.code = 'visitor:host_confirm'
ON CONFLICT DO NOTHING;

-- 失败关闭：接待权限必须存在且至少有一个部门持有，否则访客来访链路没人能接。
DO $$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM permissions WHERE code = 'visitor:host_confirm' AND NOT baseline) THEN
        RAISE EXCEPTION 'V657 visitor host permission must exist outside the baseline package';
    END IF;
    IF NOT EXISTS (
        SELECT 1 FROM department_permissions allocation
        JOIN permissions permission ON permission.id = allocation.permission_id
        WHERE permission.code = 'visitor:host_confirm') THEN
        RAISE EXCEPTION 'V657 at least one department must host external visitors';
    END IF;
END;
$$;
