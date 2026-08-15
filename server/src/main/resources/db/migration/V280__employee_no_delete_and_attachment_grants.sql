-- =====================================================================
-- V280：禁止删除员工（下线 employee:delete）+ 附件权限授予（员工文档/我的文件）
-- =====================================================================
-- 背景：用户要求——任何人都不能删除员工，离职即终态（status='resigned' 永久留存，
--   可在花名册"离职"筛选查看）。删除端点与 employee:delete 权限一并下线。
--   附件权限补授：员工查看自己的档案文件(attachment:view，对象级策略限定本人)；
--   HR 上传/管理员工文档、合同与照片(attachment:manage)。
--   通用附件层只挡无权限者，真正防枚举靠各 ownerType 的 AttachmentOwnerAccessPolicy。
-- 幂等：DELETE/INSERT 均可重复执行；与 V06/V212/V228/V240 不交叉（只动终态数据）。
-- =====================================================================

-- ① 下线 employee:delete。
--    role_permissions / department_permissions / user_permission_overrides 均对
--    permission_id ON DELETE CASCADE，故先清子表再删权限点（显式+幂等，不依赖级联语义）。
DELETE FROM role_permissions
 WHERE permission_id = (SELECT id FROM permissions WHERE code = 'employee:delete');
DELETE FROM department_permissions
 WHERE permission_id = (SELECT id FROM permissions WHERE code = 'employee:delete');
DELETE FROM user_permission_overrides
 WHERE permission_id = (SELECT id FROM permissions WHERE code = 'employee:delete');
DELETE FROM permissions WHERE code = 'employee:delete';

-- ② 授予 attachment:view 给所有在职部门（员工"我的文件"自服务）。
--    对象级 EmployeeAttachmentAccessPolicy 限定本人仅能看自己的档案，防枚举。
INSERT INTO department_permissions (department_id, permission_id)
SELECT d.id, p.id
FROM departments d
CROSS JOIN permissions p
WHERE d.is_deleted = FALSE
  AND p.code = 'attachment:view'
ON CONFLICT (department_id, permission_id) DO NOTHING;

-- ③ 授予 attachment:manage 给 HR（上传/删除员工文档、合同、照片）。
INSERT INTO department_permissions (department_id, permission_id)
SELECT d.id, p.id
FROM departments d
CROSS JOIN permissions p
WHERE d.code = 'DEPT_HR'
  AND d.is_deleted = FALSE
  AND p.code = 'attachment:manage'
ON CONFLICT (department_id, permission_id) DO NOTHING;
