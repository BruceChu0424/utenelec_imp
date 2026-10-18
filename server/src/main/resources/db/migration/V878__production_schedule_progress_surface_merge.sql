-- =====================================================================
-- V878：生产调度与进度同页双路由收口——production.progress 面并入 production.schedule
-- =====================================================================
-- 背景（2026-10-19）：/production/schedule 与 /production/progress 自 2026-09-03
--   两页合并后一直是同一物理页面的双路由，但权限层仍保留两张面、两种守卫：
--   production.schedule「生产调度」挂 production_plan:view（调度员入口），
--   production.progress「生产进度」挂 production_execution:overview（执行视角
--   入口）。同一页面在页面权限目录里呈现为两个条目，且从 A 口进得去、从 B 口
--   会被守卫拦住。
-- 收口（前端同日改：/production/progress 降级为重定向 /production/schedule?tab=progress，
--   路由守卫与页面 scope 同步合并）：
--   ① production.schedule 补挂 production_execution:overview（两类入口守卫的
--      并集），并更名「生产调度与进度」与页面 AppBar 标题一致；
--   ② 退役 production.progress 面（先删码关联再删面；manager_permission_delegations
--      的 surface_key 文本列无外键，dangling 行属审计证据保留不动——V456 同款口径）。
-- surface 总数 122 → 121。零默认 grant，纯目录迁移，不新增业务表。
-- 幂等：INSERT ... ON CONFLICT DO NOTHING；UPDATE/DELETE 天然幂等。
-- 同步：docs/数据迁移/README.md 头部计数、docs/05-架构/权限体系总设计.md 守卫表。
-- =====================================================================

-- ① 生产调度与进度面：补执行总览码（两类账号守卫并集）并更名。
INSERT INTO permission_surface_permissions (surface_id, permission_id)
SELECT surface.id, permission.id
FROM permission_surfaces surface
JOIN permissions permission
  ON permission.code = 'production_execution:overview'
WHERE surface.surface_key = 'production.schedule'
ON CONFLICT (surface_id, permission_id) DO NOTHING;

UPDATE permission_surfaces
   SET name = '生产调度与进度'
 WHERE surface_key = 'production.schedule';

-- ② 退役 production.progress 旧面：能力已并入 production.schedule。
DELETE FROM permission_surface_permissions
 WHERE surface_id IN (
     SELECT id FROM permission_surfaces
      WHERE surface_key = 'production.progress');

DELETE FROM permission_surfaces
 WHERE surface_key = 'production.progress';
