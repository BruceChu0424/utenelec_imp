-- =====================================================================
-- V64：下线决策支持模块，删除 analytics:view 权限点
-- =====================================================================
-- 背景：经营 Dashboard / 多维分析 / 异常告警 三页（前端 mock 数据，无真实后端表/接口）
--   整体下线。前端 /analytics/* 路由、工作台卡片、Perm.analyticsView 常量与超管兜底
--   均已移除。analytics:view 无任何 Java @PreAuthorize / hasPermission 引用，删除安全。
-- 授权清理：V25 曾把 analytics:view grant 给 manager/admin 角色（role_permissions），
--   V29 角色体系下线后存量沉淀进 department_permissions。两表均 ON DELETE CASCADE
--   引用 permissions，删 permissions 行即自动级联——此处仍显式 DELETE 与 V63 风格一致、
--   对 FK 配置鲁棒。
-- 视角权限 viewcontext:scoped（管理视角切换）是另一个权限点，不受影响。
-- 幂等：DELETE 无副作用，重跑安全。
-- =====================================================================

DELETE FROM role_permissions
WHERE permission_id IN (
    SELECT id FROM permissions WHERE code = 'analytics:view');

DELETE FROM department_permissions
WHERE permission_id IN (
    SELECT id FROM permissions WHERE code = 'analytics:view');

DELETE FROM permissions
WHERE code = 'analytics:view';
