-- V543 车间默认权限收紧（二）：清 V541 残留 + 页面权限面对齐 + `*:view:all` 退出批量授权
-- （2026-09-10 审计口径，承接 V541「车间只需 我的车间任务/日报报工/FQC送检」）。
--
-- 背景：V541 从 DEPT_PROD（生产部，6 个 WS_* 车间继承）删除了 16 个查看/编辑码，
-- 但下列残留与其自身表头矛盾：
--   production_plan:view:all —— 对象范围码；任何人一旦被个别加授 production_plan:view
--     即看到全部车间的生产计划（范围扩张不该来自车间默认包）；
--   production_plan:delete/batchDelete/reverse/flags、
--   production_planning_package:cancel/draft_edit/generate/reverse、
--   production_execution:overview/assign/dispatch —— 计划部（SUB_PLAN）职责，
--     车间没有对应页面入口；
--   mould:create/delete/status、mould_category:create/delete/move/reorder ——
--     V541 已收回 mould:edit/mould_category:edit，只留只读；
--   production_execution:cancel/reverse、production_mrp:generate_purchase ——
--     V455 起 active=false 的僵尸码仍挂在部门行。
-- 保留（车间本职）：production_execution:view/start/release_defer、
--   production_daily_report:view/create/edit/approve/delete/reverse（车间负责人
--   审核/红冲本车间日报）、production_material:settle/reverse/close（确认用料）、
--   production_quality_inspection:view（FQC 送检）、goods/material_category/
--   mould/mould_category 的 :view、attachment:view/download。
-- 个人加授（user_permission_overrides）一律不触碰：需要个别车间负责人看计划的，
-- 走 /admin/permissions 逐人加授 production_plan:view。

-- 1. 部门行收回：DEPT_PROD 及其子树（WS_* 车间、MFG_CENTER 制造中心）——
--    当前 dev 库子树只挂 attachment:*，一并列出保证任何环境幂等收口。
DELETE FROM department_permissions dp
USING departments d, permissions p
WHERE dp.department_id = d.id
  AND dp.permission_id = p.id
  AND d.is_deleted = FALSE
  AND (d.code = 'DEPT_PROD' OR d.code = 'MFG_CENTER' OR d.code LIKE 'WS\_%')
  AND p.code IN (
    'production_plan:view:all',
    'production_plan:delete', 'production_plan:batchDelete',
    'production_plan:reverse', 'production_plan:flags',
    'production_planning_package:cancel', 'production_planning_package:draft_edit',
    'production_planning_package:generate', 'production_planning_package:reverse',
    'production_execution:overview', 'production_execution:assign',
    'production_execution:dispatch',
    'mould:create', 'mould:delete', 'mould:status',
    'mould_category:create', 'mould_category:delete',
    'mould_category:move', 'mould_category:reorder',
    'production_execution:cancel', 'production_execution:reverse',
    'production_mrp:generate_purchase'
  );

-- 2. 页面权限面（permission_surfaces）对齐真实按钮：
--    2a. 生产面（production.*）上的僵尸码下架：production_execution:cancel/reverse、
--        production_mrp:generate_purchase（V455 停用）、production_material_analysis:manage
--        （V423 后停用）、planning_supply_request:view（停用）。active=false 的码
--        PermissionSurfaceRegistry 本就过滤不到，但挂着会误导目录审计与
--        PermissionSurfaceCatalogPostgresTest 的面计数。其他模块面上的停用码
--        （subcontract.preparation 等历史停用面）有独立契约锁定，本次不动。
DELETE FROM permission_surface_permissions link
USING permission_surfaces surface, permissions p
WHERE link.surface_id = surface.id
  AND link.permission_id = p.id
  AND surface.surface_key LIKE 'production.%'
  AND p.active = FALSE
  AND p.code IN (
    'production_execution:cancel', 'production_execution:reverse',
    'production_mrp:generate_purchase',
    'production_material_analysis:manage',
    'planning_supply_request:view'
  );

--    2b. 我的车间任务页（production.workshop-tasks）实际渲染「批量开工」与
--        「确认用料/冲销」，V470 建面时只登记了 view/日报两码——补齐
--        production_execution:start、production_material:settle/reverse，
--        使页面内委派候选与按钮一致（委派仍受中央授权与对象范围约束）。
INSERT INTO permission_surface_permissions(surface_id, permission_id)
SELECT surface.id, permission.id
FROM permission_surfaces surface
JOIN permissions permission
  ON permission.code IN ('production_execution:start',
      'production_material:settle', 'production_material:reverse')
 AND permission.active = TRUE
WHERE surface.surface_key = 'production.workshop-tasks'
ON CONFLICT (surface_id, permission_id) DO NOTHING;

-- 3. `*:view:all` 是显式全量对象范围（ADR-050），不是普通功能权限：
--    退出「全部授权/本模块/本组」批量三档（bulk_assignable=false，前端
--    authorize_all_excluded.dart 同步登记），仍可按部门或逐人显式授予。
UPDATE permissions
SET bulk_assignable = FALSE
WHERE active = TRUE
  AND code LIKE '%:view:all'
  AND bulk_assignable = TRUE;

-- 幂等性说明：三段 DELETE/UPDATE 天然可重放；INSERT 带 ON CONFLICT DO NOTHING。
-- 收回后若日后需要恢复，由新的部门权限迁移或管理页重新授予，本迁移不承担恢复职责。
