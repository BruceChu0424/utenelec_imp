-- =====================================================================
-- V63：清理悬空权限 finance_check_register:view/edit
-- =====================================================================
-- 背景：V57 seed 种入了 finance_check_register:view/edit（sort 570/571）并 grant，
--   但 Java 无 @PreAuthorize 引用、前端无 Perm 常量、/finance/checks 实际用 account:view
--   （支票管理 = accounts.account_type IN(CHECK,FOREIGN_CHECK) 的过滤视图，design doc 26 决策）。
--   故这俩权限码"悬空"——超管/管理员勾选它无任何效果，反而误导。
-- 处理：删除这俩权限点 + 其 department_permissions 授权。支票访问由 account:view 兜底
--   （V50 seed 已 grant 全部门 view、DEPT_FIN edit），语义正确。
-- 幂等：DELETE 无副作用，重跑安全。
-- =====================================================================

DELETE FROM department_permissions
WHERE permission_id IN (
    SELECT id FROM permissions WHERE code IN ('finance_check_register:view', 'finance_check_register:edit'));

DELETE FROM permissions
WHERE code IN ('finance_check_register:view', 'finance_check_register:edit');
