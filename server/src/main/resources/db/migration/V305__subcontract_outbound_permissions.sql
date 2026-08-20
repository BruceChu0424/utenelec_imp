-- V305: 委外出仓工作台独立权限点（权限管理页可授权/收回）。
--
-- 背景（ADR-042 + bruce 2026-08-20 口径）：委外出仓是仓库的本职新职能，必须有独立
-- 权限点，在权限管理里授权后才看得到任务中心、才能执行出仓；不得默认搭车在
-- 既有宽泛权限上。默认授予仓库本职部门 SUB_WH（与 V196 warehouse_inbound:view、
-- V296 收货编辑同先例），其它部门/个人须在权限管理显式授权。
--
-- 分层：
--   subcontract_outbound:view   —— 看任务中心/计划详情（hub 卡片与角标显隐）
--   subcontract_outbound:handle —— 拣货保存/审核出仓/关闭计划/补齐草稿
-- 单据本身仍受 subcontract_material_issue:view/edit 管辖（V304 已授 SUB_WH），
-- 两层权限独立可收回：收回 handle 只看不操作，收回 view 工作台完全隐藏。

INSERT INTO permissions (code, name, module, category, sort_order) VALUES
    ('subcontract_outbound:view',   '查看委外出仓任务',         '库存管理', '委外出仓', 249),
    ('subcontract_outbound:handle', '执行委外出仓拣货与审核',   '库存管理', '委外出仓', 250)
ON CONFLICT (code) DO NOTHING;

INSERT INTO department_permissions (department_id, permission_id)
SELECT d.id, p.id
FROM departments d
JOIN permissions p ON p.code IN ('subcontract_outbound:view', 'subcontract_outbound:handle')
WHERE d.code = 'SUB_WH' AND d.is_deleted = FALSE
ON CONFLICT DO NOTHING;
