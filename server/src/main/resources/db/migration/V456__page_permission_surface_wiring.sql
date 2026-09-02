-- =====================================================================
-- V456：页面内授权入口接线——5 个业务页改挂 V455 登记的专属 surface
-- =====================================================================
-- 背景（2026-09-02 平台专业化 Phase 1.5）：V455 把 10 个守卫页补进 surface 目录，
--   但页面内授权「入口」由前端 page_permission_scope.dart 的唯一映射决定，
--   其中 5 个业务页当时仍复用既有业务 surface（委派面过宽或 FQC 委派真空）。
--   本次按「页面守卫同源」原则接线：
--   ① quality.task-center 成为品质任务中心唯一面：补 IQC 处置 + FQC 审批两码
--      （待检处置合并卡的 IQC/FQC 决定都在本页；扩码后是旧 quality.inspection 面
--      [IQC view+handle] 的严格超集，无能力回退）。
--   ② 退役 quality.inspection 旧面（先删关联再删面；历史委派行的 surface_key
--      文本列无外键，dangling 行属审计证据，保留不动）。
--   ③ quality.production-fqc 补 FQC 审批码并更名「生产成品质检与FQC补产」：
--      /quality/production-inspections 自此有专属委派面（此前无任何映射）。
--   ④ warehouse.quality-results 补 IQC 入库确认码（合并页主操作）。
--   production.schedule / production.progress 两面 V455 已是 view-only 终态，
--   纯前端接线，无需迁移改动。
-- surface 总数 111 → 110。零默认 grant，纯目录迁移，不新增业务表。
-- 幂等：INSERT ... ON CONFLICT DO NOTHING；UPDATE/DELETE 天然幂等。
-- 同步：docs/数据迁移/README.md 头部计数、server/ops/reset_business_data.sql
--       白名单（本迁移无新表，CLEAR 清单不变）。
-- =====================================================================

-- ① 品质任务中心：IQC/FQC 两域 view + 本页两个决定动作（共 4 码）。
INSERT INTO permission_surface_permissions (surface_id, permission_id)
SELECT surface.id, permission.id
FROM permission_surfaces surface
JOIN permissions permission
  ON permission.code IN (
      'procurement_inspection:handle',
      'production_quality_inspection:approve')
WHERE surface.surface_key = 'quality.task-center'
ON CONFLICT (surface_id, permission_id) DO NOTHING;

-- ② 退役 quality.inspection 旧面：能力已全部并入 quality.task-center。
DELETE FROM permission_surface_permissions
 WHERE surface_id IN (
     SELECT id FROM permission_surfaces
      WHERE surface_key = 'quality.inspection');

DELETE FROM permission_surfaces
 WHERE surface_key = 'quality.inspection';

-- ③ 生产成品质检（/quality/production-inspections）：补 FQC 审批码并更名。
INSERT INTO permission_surface_permissions (surface_id, permission_id)
SELECT surface.id, permission.id
FROM permission_surfaces surface
JOIN permissions permission
  ON permission.code = 'production_quality_inspection:approve'
WHERE surface.surface_key = 'quality.production-fqc'
ON CONFLICT (surface_id, permission_id) DO NOTHING;

UPDATE permission_surfaces
   SET name = '生产成品质检与FQC补产'
 WHERE surface_key = 'quality.production-fqc';

-- ④ 仓库质检结果合并页：补 IQC 入库确认码（共 3 码）。
INSERT INTO permission_surface_permissions (surface_id, permission_id)
SELECT surface.id, permission.id
FROM permission_surfaces surface
JOIN permissions permission
  ON permission.code = 'warehouse_iqc_stock_in:confirm'
WHERE surface.surface_key = 'warehouse.quality-results'
ON CONFLICT (surface_id, permission_id) DO NOTHING;
