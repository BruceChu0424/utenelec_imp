-- =====================================================================
-- 货品归属（外贸按人）迁移：老库外贸子树 → goods.owner_employee_id
-- =====================================================================
-- 用法：bash server/legacy_migration/migrate.sh --goods-owner
-- 前提：goods/material_categories 已迁；employees 已有 legacy_id（B_Worker stub 或 HR 真员工）；V85 已应用。
-- 口径（老库取证）：
--   成品(2114) 下按业务员建子树：外贸系列(2978, Number='1胡钟炎') → 胡钟炎(B_Worker 545)；
--     外贸订单(2953, '2小苏') → 苏君丽(513)；外贸订单(3334, '3刘炎勇') → 刘炎勇(549)。
--   物料(2113) 下：外贸物料(2891 '胡钟炎') → 545；(2942 '刘炎勇') → 549；(2969 '小苏') → 513。
--   外贸系列(2682) Number 无法对应到人 → 公共（owner NULL，全员可见）。
-- 幂等：先全量清零再按子树灌入，重跑安全；HR 真员工替换 stub 后 legacy_id 不变，归属不断链。
-- =====================================================================

BEGIN;

-- ① 全量清零（重跑幂等；新手工设置的归属会被覆盖——正式上线重迁后请复查本表注释）
UPDATE goods SET owner_employee_id = NULL WHERE owner_employee_id IS NOT NULL;

-- ② 子树根 → 归属人（老库 SystemItem.ItemID → B_Worker.ID）
CREATE TEMP TABLE owner_root (root_legacy_id int PRIMARY KEY, worker_legacy_id int, note text);
INSERT INTO owner_root VALUES
    (2978, 545, '成品/外贸系列(1胡钟炎) → 胡钟炎'),
    (2953, 513, '成品/外贸订单(2小苏) → 苏君丽'),
    (3334, 549, '成品/外贸订单(3刘炎勇) → 刘炎勇'),
    (2891, 545, '物料/外贸物料(胡钟炎)'),
    (2942, 549, '物料/外贸物料(刘炎勇)'),
    (2969, 513, '物料/外贸物料(小苏)');

-- ③ 每个根递归展开分类闭包 → 批量归属（employees 按 legacy_id 对齐，stub/真员工均可）
WITH RECURSIVE sub AS (
    SELECT c.id AS category_id, r.worker_legacy_id
    FROM material_categories c
    JOIN owner_root r ON c.legacy_id = r.root_legacy_id
    UNION ALL
    SELECT c.id, s.worker_legacy_id
    FROM material_categories c
    JOIN sub s ON c.parent_id = s.category_id
)
UPDATE goods g
SET owner_employee_id = e.id
FROM sub
JOIN employees e ON e.legacy_id = sub.worker_legacy_id
WHERE g.category_id = sub.category_id;

COMMIT;

-- ---------------- 校验 ----------------
SELECT r FROM (
    SELECT 1 AS ord, '✔ 有归属货品 ' || count(*) AS r FROM goods WHERE owner_employee_id IS NOT NULL
    UNION ALL
    SELECT 2, '  ' || e.full_name || '（' || COALESCE(d.name, '?') || '）: ' || count(*)
    FROM goods g
    JOIN employees e ON e.id = g.owner_employee_id
    LEFT JOIN departments d ON d.id = e.department_id
    GROUP BY e.full_name, d.name
) t ORDER BY ord, r;
