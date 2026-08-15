-- =====================================================================
-- V256：BOM 行审计标记 + goods:bom:audit 权限
-- =====================================================================
-- 背景：
--   质检/工程核对货品组装信息时，需要逐行标记「这个组件已核对无误」，
--   否则核对到一半记不住哪些行已经审过。组装信息页签新增「审计模式」：
--   点行即标记/取消，已审行绿色高亮（多人、跨天、换机器都保留）。
--
-- 数据模型：
--   * goods_bom_items.audited_at / audited_by：非空即「已审」。
--     编辑组件行内容（用量/备注等）时服务端自动清空——内容变了，原核对结论作废。
--     审计标记不属于 BOM 数据变更：不触发 sourceE 重算，不发 GOODS_BOM_UPDATED。
--
-- 权限：goods:bom:audit（独立权限点，跟随 goods:edit 回填授予；超管恒有，
--   可在权限管理页单独授权给质检）。
-- =====================================================================

-- ① BOM 行审计列
ALTER TABLE goods_bom_items
    ADD COLUMN IF NOT EXISTS audited_at timestamptz,
    ADD COLUMN IF NOT EXISTS audited_by uuid;

COMMENT ON COLUMN goods_bom_items.audited_at IS '审计标记时间（V256；非空=该组件已核对无误）';
COMMENT ON COLUMN goods_bom_items.audited_by IS '审计标记人（users.id；宽松不 FK，同其它审计列）';

-- ② 权限点 goods:bom:audit（module+category 与 goods:import 同归类，V251 范式）
INSERT INTO permissions (code, name, category, module, sort_order) VALUES
    ('goods:bom:audit', '审计组装信息', '货品资料', '基础资料', 23)
ON CONFLICT (code) DO NOTHING;

-- ③ 回填：审计跟随编辑（持有 goods:edit 的部门自动获得 goods:bom:audit）
INSERT INTO department_permissions (department_id, permission_id)
SELECT dp.department_id, p_audit.id
FROM department_permissions dp
JOIN permissions p_edit  ON p_edit.id  = dp.permission_id
JOIN permissions p_audit ON p_audit.code = 'goods:bom:audit'
WHERE p_edit.code = 'goods:edit'
ON CONFLICT DO NOTHING;
