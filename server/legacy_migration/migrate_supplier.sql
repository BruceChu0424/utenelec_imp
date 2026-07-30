-- =====================================================================
-- 供应商分类迁移：CSV → supplier_categories（不依赖 server 启动）
-- =====================================================================
-- 用法：bash server/legacy_migration/migrate.sh [--supplier]
-- 数据来源：老库 SystemItem WHERE ItemclassID=3（供应商/材质分类，15 个扁平根：
--   五金类/塑胶原料/塑胶件 001/玻璃面板/轨道配件/电子类…），由 export_legacy.ps1 SupplierCategory 导出。
--   本表独立于 material/mould/client_categories，故 TRUNCATE 只清自己 + suppliers（FK）。
-- 树形：15 个全是 ParentID=0 的扁平根 → 直接 level 0 入库（与模具分类同构，无嵌套、无顶级分组）。
--   保留递归 depth + 孤儿兜底以兼容将来老库加嵌套/孤儿。
--   与 Java SupplierCategoryMigrator 产出的形状一致。
-- 清表：suppliers 通过 category_id 引用本表，故 TRUNCATE 必须同时清 suppliers。
-- =====================================================================

BEGIN;
TRUNCATE suppliers, supplier_categories;

CREATE TEMP TABLE mc_stage (legacy_id int, parent_legacy int, code text, name text);
\copy mc_stage FROM '/tmp/supplier_categories.csv' WITH (FORMAT text, DELIMITER '|', HEADER true)

-- 递归算 depth：老库根（ParentID=0）→ depth 0；子 → depth+1（供应商实测全根，depth 全 0）
CREATE TEMP TABLE mc_nodes AS
WITH RECURSIVE mc_tree AS (
    SELECT legacy_id, parent_legacy, code, name, 0 AS depth
    FROM mc_stage WHERE parent_legacy IS NULL OR parent_legacy = 0
    UNION ALL
    SELECT s.legacy_id, s.parent_legacy, s.code, s.name, t.depth + 1
    FROM mc_stage s JOIN mc_tree t ON s.parent_legacy = t.legacy_id
)
SELECT * FROM mc_tree;

-- 虚拟孤儿根（供应商分类实测 0 孤儿，此行保留兜底；与 Java SupplierCategoryMigrator 一致）
INSERT INTO supplier_categories (legacy_id, code, name, level, parent_id)
SELECT -1, 'LEGACY_ORPHAN', '未分类（历史孤儿）', 0, NULL
WHERE EXISTS (SELECT 1 FROM mc_stage s
              WHERE s.parent_legacy <> 0
                AND NOT EXISTS (SELECT 1 FROM mc_stage p WHERE p.legacy_id = s.parent_legacy));

-- 分层 INSERT：depth 0 → parent=NULL；depth>0 → parent=legacy 关联
DO $$
DECLARE d INT; maxd INT;
BEGIN
    SELECT COALESCE(MAX(depth), 0) INTO maxd FROM mc_nodes;
    FOR d IN 0..maxd LOOP
        INSERT INTO supplier_categories (legacy_id, code, name, level, sort_order, parent_id)
        SELECT n.legacy_id, n.code, n.name, n.depth,
               ROW_NUMBER() OVER (ORDER BY n.code),
               CASE WHEN n.depth = 0 THEN NULL
                    ELSE (SELECT id FROM supplier_categories WHERE legacy_id = n.parent_legacy) END
        FROM mc_nodes n WHERE n.depth = d;
    END LOOP;
END $$;

-- 孤儿兜底：父已被删的节点挂虚拟根（实测 0 行）
INSERT INTO supplier_categories (legacy_id, code, name, level, sort_order, parent_id)
SELECT s.legacy_id, s.code, s.name, 1, 0, (SELECT id FROM supplier_categories WHERE legacy_id = -1)
FROM mc_stage s
WHERE s.parent_legacy <> 0
  AND NOT EXISTS (SELECT 1 FROM mc_stage p WHERE p.legacy_id = s.parent_legacy)
  AND NOT EXISTS (SELECT 1 FROM mc_nodes   n WHERE n.legacy_id = s.legacy_id);

COMMIT;

SELECT '✔ 供应商分类 总 ' || count(*) ||
       '，根 ' || count(*) FILTER (WHERE parent_id IS NULL) ||
       '，最大深度 ' || COALESCE(MAX(level), 0) AS 结果
FROM supplier_categories;
