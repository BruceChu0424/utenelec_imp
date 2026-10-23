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
-- 当前归属只给在职员工；离职/缺失旧人由 ADMIN 暂管并写交接清单。已维护的当前归属不覆盖。
-- =====================================================================


-- ② 子树根 → 归属人（老库 SystemItem.ItemID → B_Worker.ID）
CREATE TEMP TABLE owner_root (root_legacy_id int PRIMARY KEY, worker_legacy_id int, note text);
INSERT INTO owner_root VALUES
    (2978, 545, '成品/外贸系列(1胡钟炎) → 胡钟炎'),
    (2953, 513, '成品/外贸订单(2小苏) → 苏君丽'),
    (3334, 549, '成品/外贸订单(3刘炎勇) → 刘炎勇'),
    (2891, 545, '物料/外贸物料(胡钟炎)'),
    (2942, 549, '物料/外贸物料(刘炎勇)'),
    (2969, 513, '物料/外贸物料(小苏)');

-- ③ 每个根递归展开分类闭包 → 精确旧人解析；仅当前员工直接接责，历史桩交 ADMIN 暂管。
CREATE TEMP TABLE goods_owner_resolution AS
WITH RECURSIVE sub AS (
    SELECT c.id AS category_id, r.worker_legacy_id
    FROM material_categories c
    JOIN owner_root r ON c.legacy_id = r.root_legacy_id
    UNION ALL
    SELECT c.id, s.worker_legacy_id
    FROM material_categories c
    JOIN sub s ON c.parent_id = s.category_id
)
SELECT g.id,g.legacy_id,sub.worker_legacy_id,r.owner_id,r.original_employee_id,r.reason
FROM goods g JOIN sub ON g.category_id=sub.category_id
CROSS JOIN LATERAL pg_temp.legacy_owner_resolution(sub.worker_legacy_id::text) r
WHERE g.owner_employee_id IS NULL OR NOT EXISTS (
 SELECT 1 FROM employees e WHERE e.id=g.owner_employee_id AND NOT e.is_deleted AND e.status IN ('active','probation','onLeave'));
DO $$ BEGIN
 IF EXISTS (SELECT id FROM goods_owner_resolution GROUP BY id HAVING count(DISTINCT worker_legacy_id)>1) THEN
  RAISE EXCEPTION 'Goods owner category roots overlap with different historical owners';
 END IF;
END $$;
UPDATE goods g SET owner_employee_id=r.owner_id FROM goods_owner_resolution r
WHERE g.id=r.id AND g.owner_employee_id IS DISTINCT FROM r.owner_id;
INSERT INTO pg_temp.legacy_owner_custody
SELECT DISTINCT 'goods',id,legacy_id,worker_legacy_id::text,original_employee_id,owner_id,reason
FROM goods_owner_resolution WHERE reason NOT IN ('PUBLIC_SOURCE','CURRENT_EMPLOYEE');


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
