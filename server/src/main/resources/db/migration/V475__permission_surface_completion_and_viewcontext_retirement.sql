-- =====================================================================
-- V475：权限面收口两处补遗 + viewcontext:scoped 孤儿码下线
-- =====================================================================
-- 背景（2026-09-04 权限全量审计）：
--   ① V455 声明「全仓带路由守卫的页面 100% 纳入 surface 目录」，但两页随
--     V448-V453 批次引入、未补 surface，页面内人员授权（ManagerPermission-
--     Delegation）无入口：
--       finance.payables           = /finance/payables（3 码守卫 any-of）
--       quality.inspection-records = /quality/inspection-records（2 码守卫）
--     本次补齐，零默认 grant（纯目录迁移）。
--   ② viewcontext:scoped（管理视角切换）种子于 V06、V212 授 GM 部门，但后端
--     无 @PreAuthorize 强制、前端无常量无 UI——V455「双端零引用即下线」口径
--     的漏网（该码有存量授权，但授权无任何运行时语义）。按 V455 模式先清
--     存量授权再删码。
-- 幂等：INSERT ... ON CONFLICT DO NOTHING；DELETE 天然幂等。
-- 同步：docs/数据迁移/README.md 头部计数、docs/05-架构/页面权限一览.md、
--       docs/03-页面/权限管理页.md（§四-A surface 总数）。
--       本迁移无新表，reset_business_data.sql 白名单不变。
-- =====================================================================

-- ① 补 2 个守卫页 surface（sort 顺延 277-278；V459/V470 已用至 276）。
INSERT INTO permission_surfaces (id, surface_key, name, sort_order, enabled) VALUES
    ('47500000-0000-4000-8000-000000000001',
     'finance.payables', '采购委外应付结算工作台', 277, TRUE),
    ('47500000-0000-4000-8000-000000000002',
     'quality.inspection-records', '品质检测记录', 278, TRUE)
ON CONFLICT (surface_key) DO NOTHING;

-- 页面-权限精确关联：与 permission_by_path.dart 路由守卫同源，外加该页
-- 实际按码显隐的动作位（工作台内结算/索赔/红冲/付款/抵扣全部操作）。
-- finance:view:all 为公司级数据范围码（页内「全部供应商」口径开关），属
-- V455 audit_log:view 同类的页面必需码，允许页面内点名授予。
INSERT INTO permission_surface_permissions (surface_id, permission_id)
SELECT surface.id, permission.id
FROM permission_surfaces surface
JOIN permissions permission
  ON permission.code IN (
      'ar_ap_ledger:view',
      'subcontract_loss_claim:view',
      'subcontract_loss_claim:review',
      'subcontract_loss_claim:fulfill',
      'subcontract_loss_claim:reverse',
      'supplier_settlement:view',
      'supplier_settlement:create',
      'supplier_settlement:confirm',
      'supplier_settlement:dispute',
      'supplier_settlement:reverse',
      'supplier_open_item_offset:apply',
      'finance_payment:create',
      'finance:view:all')
WHERE surface.surface_key = 'finance.payables'
ON CONFLICT (surface_id, permission_id) DO NOTHING;

INSERT INTO permission_surface_permissions (surface_id, permission_id)
SELECT surface.id, permission.id
FROM permission_surfaces surface
JOIN permissions permission
  ON permission.code IN (
      'procurement_inspection:view',
      'production_quality_inspection:view')
WHERE surface.surface_key = 'quality.inspection-records'
ON CONFLICT (surface_id, permission_id) DO NOTHING;

-- ② 下线 viewcontext:scoped 孤儿码（V455 模式：先清四类授权引用再删码；
--    该码无页面动作、无 surface 关联）。
DELETE FROM permission_surface_permissions
 WHERE permission_id IN (
     SELECT id FROM permissions WHERE code = 'viewcontext:scoped');

DELETE FROM manager_permission_delegations
 WHERE permission_id IN (
     SELECT id FROM permissions WHERE code = 'viewcontext:scoped');

DELETE FROM role_permissions
 WHERE permission_id IN (
     SELECT id FROM permissions WHERE code = 'viewcontext:scoped');

DELETE FROM department_permissions
 WHERE permission_id IN (
     SELECT id FROM permissions WHERE code = 'viewcontext:scoped');

DELETE FROM user_permission_overrides
 WHERE permission_id IN (
     SELECT id FROM permissions WHERE code = 'viewcontext:scoped');

DELETE FROM permissions
 WHERE code = 'viewcontext:scoped';
