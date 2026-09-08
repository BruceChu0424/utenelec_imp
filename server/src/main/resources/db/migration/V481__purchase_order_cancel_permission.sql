-- V481 采购订货单「取消」权限（2026-09-05 用户口径：采购自己可取消草稿单——
-- 含已提交财务审核的在审单，取消后财务任务中心不再显示该单）。
-- 与 purchase_order:submit_finance（V196）同口径发放：PMC / 采购部。
-- 修正（同日，由并行委外同构会话代为补齐）：初版 INSERT 缺 action_type（非空约束）
-- 且 category 误填模块名、sort 113 与 purchase_order:create 撞号——按同族
-- purchase_order:* 权限的规范值补齐（module=采购管理 / category=采购订货 /
-- sort=118 / action_type=EXECUTE），否则全部 Flyway 引导的测试类连环失败。

INSERT INTO permissions
    (code, name, module, category, sort_order, action_type, description,
     active, assignable, bulk_assignable, sensitivity)
VALUES
    ('purchase_order:cancel',
     '取消采购订货单', '采购管理', '采购订货', 118, 'EXECUTE',
     '采购员取消本人草稿或已提交财务审核的在审订货单；已审核单据走既有红冲链路',
     TRUE, TRUE, TRUE, 'NORMAL')
ON CONFLICT (code) DO NOTHING;

INSERT INTO department_permissions(department_id, permission_id)
SELECT d.id, p.id
FROM departments d
JOIN permissions p ON p.code = 'purchase_order:cancel'
WHERE d.code IN ('DEPT_PMC', 'SUB_PURCHASE') AND d.is_deleted = FALSE
ON CONFLICT DO NOTHING;
