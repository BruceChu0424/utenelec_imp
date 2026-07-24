-- 工资条职责调整：人事(hr)不再管工资，工资条生成/发布统一由财务(finance)管理。
-- 背景：V06 种子中 hr 持有 payroll:generate / payroll:publish（finance 原本已有
-- payroll:review / payroll:view:all / payroll:export）。已应用的种子迁移不可回改，
-- 本次权限移交通过新迁移在现有库上原地调整。

-- 1) 移除人事的工资条生成/发布权限
DELETE FROM role_permissions rp
USING roles r, permissions p
WHERE rp.role_id = r.id
  AND rp.permission_id = p.id
  AND r.code = 'hr'
  AND p.code IN ('payroll:generate', 'payroll:publish');

-- 2) 授予财务工资条生成/发布权限（幂等，已存在则跳过）
INSERT INTO role_permissions (role_id, permission_id)
SELECT r.id, p.id
FROM roles r, permissions p
WHERE r.code = 'finance'
  AND p.code IN ('payroll:generate', 'payroll:publish')
ON CONFLICT DO NOTHING;

-- 3) 同步角色描述文案（仅展示用途）
UPDATE roles SET description = '员工档案/部门/入离职/通知发布' WHERE code = 'hr';
UPDATE roles SET description = '报销审批/工资条生成与发布/工资条审核/报表' WHERE code = 'finance';
