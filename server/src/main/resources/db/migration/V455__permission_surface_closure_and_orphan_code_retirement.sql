-- =====================================================================
-- V455：权限目录收口——补 10 个守卫页 surface + 下线 15 个双端零引用孤儿码
-- =====================================================================
-- 背景（2026-09-02 平台专业化 Phase 1）：全仓盘点发现——
--   ① 10 个带路由守卫的页面没有 permission_surface，无法走页面内人员授权
--     （ManagerPermissionDelegation）；本次补齐，零默认 grant。
--   ② 15 个权限码在后端 @PreAuthorize 与前端 Perm 常量均零引用（历史演进遗留），
--     按 V280 模式下线：先清授权再删码。库内存量授权一并清理（均无运行时效果）。
-- 幂等：INSERT ... ON CONFLICT DO NOTHING；DELETE 天然幂等。
-- 同步：docs/数据迁移/README.md 头部计数、server/ops/reset_business_data.sql
--       白名单（本迁移无新表，CLEAR 清单不变）。
-- =====================================================================

-- ① 补 10 个守卫页 surface（sort 顺延 266-275）。
INSERT INTO permission_surfaces (id, surface_key, name, sort_order, enabled) VALUES
    ('45500000-0000-4000-8000-000000000001',
     'admin.permission-console', '授权管理总控', 266, TRUE),
    ('45500000-0000-4000-8000-000000000002',
     'admin.audit-center', '审计中心', 267, TRUE),
    ('45500000-0000-4000-8000-000000000003',
     'admin.system-settings', '系统设置', 268, TRUE),
    ('45500000-0000-4000-8000-000000000004',
     'settings.device-receipts', '本机回执核查', 269, TRUE),
    ('45500000-0000-4000-8000-000000000005',
     'quality.task-center', '品质任务中心', 270, TRUE),
    ('45500000-0000-4000-8000-000000000006',
     'quality.production-fqc', '生产FQC补产队列', 271, TRUE),
    ('45500000-0000-4000-8000-000000000007',
     'warehouse.quality-results', '仓库质检结果', 272, TRUE),
    ('45500000-0000-4000-8000-000000000008',
     'production.schedule', '生产调度', 273, TRUE),
    ('45500000-0000-4000-8000-000000000009',
     'production.progress', '生产进度', 274, TRUE),
    ('45500000-0000-4000-8000-000000000010',
     'production.chain-health', '生产链路健康', 275, TRUE)
ON CONFLICT (surface_key) DO NOTHING;

-- 页面-权限精确关联（与 permission_by_path.dart 的路由守卫同源；audit_log:view
-- 属调查证据例外码：仅超管或个人覆盖点名加授，页面内授权通道即点名通道，合规）。
INSERT INTO permission_surface_permissions (surface_id, permission_id)
SELECT surface.id, permission.id
FROM permission_surfaces surface
JOIN permissions permission
  ON permission.code IN (
      'account:support', 'authorization:manage')  -- admin.permission-console
WHERE surface.surface_key = 'admin.permission-console'
ON CONFLICT (surface_id, permission_id) DO NOTHING;

INSERT INTO permission_surface_permissions (surface_id, permission_id)
SELECT surface.id, permission.id
FROM permission_surfaces surface
JOIN permissions permission
  ON permission.code IN ('audit_log:view')
WHERE surface.surface_key IN ('admin.audit-center', 'settings.device-receipts')
ON CONFLICT (surface_id, permission_id) DO NOTHING;

INSERT INTO permission_surface_permissions (surface_id, permission_id)
SELECT surface.id, permission.id
FROM permission_surfaces surface
JOIN permissions permission
  ON permission.code IN ('authorization:manage')
WHERE surface.surface_key = 'admin.system-settings'
ON CONFLICT (surface_id, permission_id) DO NOTHING;

INSERT INTO permission_surface_permissions (surface_id, permission_id)
SELECT surface.id, permission.id
FROM permission_surfaces surface
JOIN permissions permission
  ON permission.code IN (
      'procurement_inspection:view',
      'production_quality_inspection:view')
WHERE surface.surface_key = 'quality.task-center'
ON CONFLICT (surface_id, permission_id) DO NOTHING;

INSERT INTO permission_surface_permissions (surface_id, permission_id)
SELECT surface.id, permission.id
FROM permission_surfaces surface
JOIN permissions permission
  ON permission.code IN (
      'production_quality_inspection:view',
      'production_fqc_replenishment:view',
      'production_fqc_replenishment:confirm')
WHERE surface.surface_key = 'quality.production-fqc'
ON CONFLICT (surface_id, permission_id) DO NOTHING;

INSERT INTO permission_surface_permissions (surface_id, permission_id)
SELECT surface.id, permission.id
FROM permission_surfaces surface
JOIN permissions permission
  ON permission.code IN (
      'warehouse_iqc_stock_in:view',
      'warehouse_iqc_return:view')
WHERE surface.surface_key = 'warehouse.quality-results'
ON CONFLICT (surface_id, permission_id) DO NOTHING;

INSERT INTO permission_surface_permissions (surface_id, permission_id)
SELECT surface.id, permission.id
FROM permission_surfaces surface
JOIN permissions permission
  ON permission.code IN ('production_plan:view')
WHERE surface.surface_key IN ('production.schedule', 'production.progress')
ON CONFLICT (surface_id, permission_id) DO NOTHING;

INSERT INTO permission_surface_permissions (surface_id, permission_id)
SELECT surface.id, permission.id
FROM permission_surfaces surface
JOIN permissions permission
  ON permission.code IN ('production_material_analysis:view')
WHERE surface.surface_key = 'production.chain-health'
ON CONFLICT (surface_id, permission_id) DO NOTHING;

-- ② 下线 15 个双端零引用孤儿码（V280/V423 模式；清理存量部门授权合计 20 条，
--    均无运行时效果）。
--    stock:edit / inventory:view / workflow_assignment:manage / user:manage /
--    lab:test:view / lab:test:upload / purchase_request:edit /
--    webinquiry:manage / attachment:manage / attachment:reconcile /
--    attachment:manage 已由 attachment:upload/delete 取代（V328）/
--    production_plan:forward_rd（ADR-057 下线）/ rd_task:edit（控制器只用
--    view/create/resolve/assign）/ production_mrp:generate_draw、
--    production_mrp:generate_finished_in（仅 generate_purchase 仍被
--    MrpController 强制）。
DELETE FROM permission_surface_permissions
 WHERE permission_id IN (
     SELECT id FROM permissions WHERE code IN (
         'stock:edit','inventory:view','workflow_assignment:manage','user:manage',
         'lab:test:view','lab:test:upload','purchase_request:edit','webinquiry:manage',
         'attachment:manage','attachment:reconcile','production_plan:forward_rd',
         'rd_task:edit','production_mrp:generate_draw',
         'production_mrp:generate_finished_in','subcontract_application:edit'));

-- manager_permission_delegations 对 permissions 有外键（V423 同款先例）：
-- 删码前必须先清引用这些码的委派行（均无运行时效果，码已零引用）。
DELETE FROM manager_permission_delegations
 WHERE permission_id IN (
     SELECT id FROM permissions WHERE code IN (
         'stock:edit','inventory:view','workflow_assignment:manage','user:manage',
         'lab:test:view','lab:test:upload','purchase_request:edit','webinquiry:manage',
         'attachment:manage','attachment:reconcile','production_plan:forward_rd',
         'rd_task:edit','production_mrp:generate_draw',
         'production_mrp:generate_finished_in','subcontract_application:edit'));

-- roles 体系 V29 已下线，role_permissions 仅存历史证据；孤儿码的残留引用一并清理。
DELETE FROM role_permissions
 WHERE permission_id IN (
     SELECT id FROM permissions WHERE code IN (
         'stock:edit','inventory:view','workflow_assignment:manage','user:manage',
         'lab:test:view','lab:test:upload','purchase_request:edit','webinquiry:manage',
         'attachment:manage','attachment:reconcile','production_plan:forward_rd',
         'rd_task:edit','production_mrp:generate_draw',
         'production_mrp:generate_finished_in','subcontract_application:edit'));

DELETE FROM department_permissions
 WHERE permission_id IN (
     SELECT id FROM permissions WHERE code IN (
         'stock:edit','inventory:view','workflow_assignment:manage','user:manage',
         'lab:test:view','lab:test:upload','purchase_request:edit','webinquiry:manage',
         'attachment:manage','attachment:reconcile','production_plan:forward_rd',
         'rd_task:edit','production_mrp:generate_draw',
         'production_mrp:generate_finished_in','subcontract_application:edit'));

DELETE FROM user_permission_overrides
 WHERE permission_id IN (
     SELECT id FROM permissions WHERE code IN (
         'stock:edit','inventory:view','workflow_assignment:manage','user:manage',
         'lab:test:view','lab:test:upload','purchase_request:edit','webinquiry:manage',
         'attachment:manage','attachment:reconcile','production_plan:forward_rd',
         'rd_task:edit','production_mrp:generate_draw',
         'production_mrp:generate_finished_in','subcontract_application:edit'));

DELETE FROM permissions
 WHERE code IN (
     'stock:edit','inventory:view','workflow_assignment:manage','user:manage',
     'lab:test:view','lab:test:upload','purchase_request:edit','webinquiry:manage',
     'attachment:manage','attachment:reconcile','production_plan:forward_rd',
     'rd_task:edit','production_mrp:generate_draw',
     'production_mrp:generate_finished_in','subcontract_application:edit');

-- ③ quality.lab-test surface 的全部关联只有 lab:test:view/upload 两个码；
--    码删除后该 surface 成为无关联空壳（违反“每个 surface 至少一条权限关联”
--    目录不变量，实验室检测页 2026-08-31 已下线），一并退役。
DELETE FROM permission_surfaces
 WHERE surface_key = 'quality.lab-test';
