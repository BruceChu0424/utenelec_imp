-- V141: split ordinary employee profile maintenance from encrypted PII and
-- compensation writes. Read permissions remain independent.
INSERT INTO permissions (code, name, category, sort_order) VALUES
    ('employee:pii:edit', '编辑员工证件、联系方式与银行字段', '员工档案', 61),
    ('employee:compensation:edit', '编辑员工薪资、社保、公积金与补贴字段', '员工档案', 62)
ON CONFLICT (code) DO UPDATE
SET name = EXCLUDED.name,
    category = EXCLUDED.category,
    sort_order = EXCLUDED.sort_order;

-- PermissionResolver composes effective grants from department permissions and
-- user overrides. Grant both capabilities to the active HR department by
-- default; super administrators receive the complete permission catalogue.
INSERT INTO department_permissions (department_id, permission_id)
SELECT d.id, p.id
FROM departments d
CROSS JOIN permissions p
WHERE d.code = 'DEPT_HR'
  AND d.is_deleted = FALSE
  AND p.code IN (
      'employee:pii:edit',
      'employee:compensation:edit'
  )
ON CONFLICT DO NOTHING;
