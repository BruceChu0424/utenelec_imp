-- =====================================================================
-- V227：货品折扣查看权限（goods:discount:view）
-- =====================================================================
-- 背景：
--   V226 收紧了折扣的「编辑」侧（goods:price:edit，默认仅财务部），但折扣的「查看」
--   仍对任何持有 goods:view 者敞开。用户要求：折扣属敏感商务信息，默认仅销售部与
--   财务部可见（销售需带价/折扣谈单、财务维护价折扣），其余部门（生产/仓库/PMC 等）
--   在货品详情、列表、编辑表单一律看不到折扣字段。可由超管在「权限管理」页按需增授/回收。
-- 授权集：对齐既有的「销售价可见」权限 sales_order:price:view（恰好授予 DEPT_SALES +
--   DEPT_RAIL 两条销售线），再加维护折扣的财务部 DEPT_FIN。
-- 实现：读侧字段级脱敏（仿 V226 goods:cost:view / GoodsCostMasker）——后端未授权时折扣
--   置 null + discountMasked=true，前端隐藏字段/列；写侧 ensurePriceEditIfTouched 对不可
--   查看者跳过折扣触碰判定、apply 仅可查看者折扣落库（顺带修复 V226 遗漏的 setDiscount）。
-- 幂等：ON CONFLICT，重跑安全。
-- =====================================================================

-- ① 种权限点（category 与 goods:view/edit 同为「主数据」；sort_order 接 V226 的 24 之后）。
INSERT INTO permissions (code, name, category, sort_order) VALUES
    ('goods:discount:view', '查看货品折扣', '主数据', 25)
ON CONFLICT (code) DO UPDATE
SET name = EXCLUDED.name,
    category = EXCLUDED.category,
    sort_order = EXCLUDED.sort_order;

-- ② 默认授予销售两条线（DEPT_SALES 综合营销事业部 / DEPT_RAIL 轨道事业部）+ 财务部 DEPT_FIN。
INSERT INTO department_permissions (department_id, permission_id)
SELECT d.id, p.id
FROM departments d
CROSS JOIN permissions p
WHERE d.code IN ('DEPT_SALES', 'DEPT_RAIL', 'DEPT_FIN')
  AND d.is_deleted = FALSE
  AND p.code = 'goods:discount:view'
ON CONFLICT DO NOTHING;
