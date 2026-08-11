-- =====================================================================
-- V226：货品售价/折扣编辑授权（goods:price:edit）+ 成本可见性（goods:cost:view）
-- =====================================================================
-- 背景：
--   ① 货品折扣（goods.zk，复用老库 B_Goods.zk）现暴露为 discount 倍率字段（1.00=原价、0.90=9折）。
--   ② 售价/折扣此前任何持有 goods:edit 者均可改；现收紧为仅 goods:price:edit 持有者可改
--      （写侧字段级权限，仿 V141 employee:pii:edit）。DEPT_FIN 此前仅 goods:view、连编辑权都没有，
--      故一并补 goods:edit 以便财务通过编辑表单维护售价/折扣（其他部门仍可编辑货品其它字段，
--      但售价/折扣在前端置只读、后端兜底 403）。
--   ③ 成本（成本预算 18 字段）此前详情无条件返回；现仅 goods:cost:view 持有者可见，未授权清空 +
--      costMasked=true（前端隐藏「成本预算」Tab），仿 V90 sales_order:price:view。
--   超管恒有全量权限；其他部门/个人可在「权限管理」页按需增授/回收（个人权限覆盖机制）。
-- 幂等：ON CONFLICT，重跑安全。
-- =====================================================================

-- ① 折扣列语义自描述（COMMENT ON COLUMN 仅接受单字符串字面量）。
COMMENT ON COLUMN goods.zk IS '折扣倍率 1.00=原价、0.90=9折（复用老库 B_Goods.zk；有效售价 = 单价 × 折扣）';

-- ② 种两个新权限点（category 与 goods:view/edit 同为「主数据」）。
INSERT INTO permissions (code, name, category, sort_order) VALUES
    ('goods:price:edit', '编辑货品售价/折扣', '主数据', 23),
    ('goods:cost:view',  '查看货品成本',      '主数据', 24)
ON CONFLICT (code) DO UPDATE
SET name = EXCLUDED.name,
    category = EXCLUDED.category,
    sort_order = EXCLUDED.sort_order;

-- ③ 默认授予财务部（DEPT_FIN）：编辑（goods:edit）+ 售价/折扣编辑 + 成本可见。
INSERT INTO department_permissions (department_id, permission_id)
SELECT d.id, p.id
FROM departments d
CROSS JOIN permissions p
WHERE d.code = 'DEPT_FIN'
  AND d.is_deleted = FALSE
  AND p.code IN (
      'goods:edit',
      'goods:price:edit',
      'goods:cost:view'
  )
ON CONFLICT DO NOTHING;
