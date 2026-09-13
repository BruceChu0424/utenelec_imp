-- =====================================================================
-- V570：货品售价查看权限（goods:price:view）
-- =====================================================================
-- 背景（2026-09-12 用户口径）：
--   折扣已有查看权限（V227 goods:discount:view），但售价对任何 goods:view 持有者
--   敞开——货品列表/详情/导出、组装信息（BOM）行单价金额全可见。价格属敏感商务
--   信息，应默认仅财务与两条销售线可见（销售带价谈单、财务维护价格），其余部门
--   （生产/仓库/PMC/品质等）字段置空隐藏；可由超管在「权限管理」页按部门/个人
--   增授回收。
-- 授权集：与 goods:discount:view（V227）完全同线——DEPT_SALES / DEPT_RAIL / DEPT_FIN
--   （DEPT_FIN 本就持有 goods:price:edit，加码让口径显式）。
-- 实现（读侧字段级脱敏，仿 V227/V226）：
--   * GoodsService：未授权者列表/详情（导出走 list）价格置 null + priceMasked=true，
--     前端隐藏价格字段/列；持有 goods:price:edit 视为可见（编辑者必须能看到在改的价）。
--   * 写侧 ensurePriceEditIfTouched：价格触碰仅可查看者参与判定（null=脱敏产物非改价
--     意图）；apply 对不可查看者保留原价，防误清。
--   * GoodsBomService：BOM 行单价/金额同步脱敏；null 单价提交时新建回退组件货品价、
--     编辑保留行原值（保住 sourceE 成本聚合口径，不因脱敏丢数据）。
--   * bulk_assignable=false：敏感商务信息不随「一键全部授权」发放（前端
--     authorize_all_excluded.dart 同步排除）。
-- surface：basic.goods 按 'goods:' 前缀匹配（V328 规则表），本码自动进面，无需单独登记。
-- 幂等：ON CONFLICT，重跑安全。
-- =====================================================================

-- ① 种权限点（module/category 与 goods 家族同款：基础资料·货品资料；sort 接 V227 的 25 之后）。
INSERT INTO permissions (code, name, module, category, sort_order, action_type, description,
                         active, assignable, bulk_assignable, sensitivity)
VALUES ('goods:price:view', '查看货品售价', '基础资料', '货品资料', 26, 'VIEW',
        '货品列表/详情/导出与组装信息单价金额的售价可见性；未授权者字段置空隐藏；持有 goods:price:edit 视为可见',
        TRUE, TRUE, FALSE, 'NORMAL')
ON CONFLICT (code) DO UPDATE SET
    name = EXCLUDED.name, module = EXCLUDED.module, category = EXCLUDED.category,
    sort_order = EXCLUDED.sort_order, action_type = EXCLUDED.action_type,
    description = EXCLUDED.description, active = EXCLUDED.active,
    assignable = EXCLUDED.assignable, bulk_assignable = EXCLUDED.bulk_assignable,
    sensitivity = EXCLUDED.sensitivity;

-- ② 默认授予两条销售线 + 财务部（与 V227 goods:discount:view 同集）。
INSERT INTO department_permissions (department_id, permission_id)
SELECT d.id, p.id
FROM departments d
JOIN permissions p ON p.code = 'goods:price:view'
WHERE d.code IN ('DEPT_SALES', 'DEPT_RAIL', 'DEPT_FIN')
  AND d.is_deleted = FALSE
ON CONFLICT DO NOTHING;
