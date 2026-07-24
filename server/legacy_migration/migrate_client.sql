-- =====================================================================
-- 客户分类迁移：CSV → client_categories（不依赖 server 启动）
-- =====================================================================
-- 用法：bash server/legacy_migration/migrate.sh [--client]
-- 数据来源：老库 SystemItem WHERE ItemclassID=2（客户/业务区域分组，10 根/40 节点/最大深 3：
--   外贸钟/苏/刘/罗、OEM苏、南区/北区→省份→分销商），由 export_legacy.ps1 ClientCategory 导出。
--   本表独立于 material/mould/supplier_categories，故 TRUNCATE 只清自己 + clients（FK）。
-- 树形：有真实嵌套（南区→省份→分销商，最大深 2）→ 递归算 depth（根=0），与货品分类同构。
--   无顶级分组（与模具一致：表本身即客户分类，分组冗余）。保留孤儿兜底以兼容将来老库加孤儿。
--   与 Java ClientCategoryMigrator 产出的形状一致（扁平/嵌套根，legacy_id=-1 孤儿根）。
-- 清表：clients 通过 category_id 引用本表，故 TRUNCATE 必须同时清 clients
--   （重载分类会让分类 UUID 变化，clients 的 category_id 失效，需重跑 --client-data）。
-- =====================================================================

BEGIN;
TRUNCATE clients, client_categories;

CREATE TEMP TABLE mc_stage (legacy_id int, parent_legacy int, code text, name text);
\copy mc_stage FROM '/tmp/client_categories.csv' WITH (FORMAT text, DELIMITER '|', HEADER true)

-- 递归算 depth：老库根（ParentID=0）→ depth 0；子 → depth+1
CREATE TEMP TABLE mc_nodes AS
WITH RECURSIVE mc_tree AS (
    SELECT legacy_id, parent_legacy, code, name, 0 AS depth
    FROM mc_stage WHERE parent_legacy IS NULL OR parent_legacy = 0
    UNION ALL
    SELECT s.legacy_id, s.parent_legacy, s.code, s.name, t.depth + 1
    FROM mc_stage s JOIN mc_tree t ON s.parent_legacy = t.legacy_id
)
SELECT * FROM mc_tree;

-- 虚拟孤儿根（客户分类实测 0 孤儿，此行保留兜底；与 Java ClientCategoryMigrator 一致）
INSERT INTO client_categories (legacy_id, code, name, level, parent_id)
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
        INSERT INTO client_categories (legacy_id, code, name, level, sort_order, parent_id)
        SELECT n.legacy_id, n.code, n.name, n.depth,
               ROW_NUMBER() OVER (ORDER BY n.code),
               CASE WHEN n.depth = 0 THEN NULL
                    ELSE (SELECT id FROM client_categories WHERE legacy_id = n.parent_legacy) END
        FROM mc_nodes n WHERE n.depth = d;
    END LOOP;
END $$;

-- 孤儿兜底：父已被删的节点挂虚拟根（实测 0 行）
INSERT INTO client_categories (legacy_id, code, name, level, sort_order, parent_id)
SELECT s.legacy_id, s.code, s.name, 1, 0, (SELECT id FROM client_categories WHERE legacy_id = -1)
FROM mc_stage s
WHERE s.parent_legacy <> 0
  AND NOT EXISTS (SELECT 1 FROM mc_stage p WHERE p.legacy_id = s.parent_legacy)
  AND NOT EXISTS (SELECT 1 FROM mc_nodes   n WHERE n.legacy_id = s.legacy_id);

COMMIT;

SELECT '✔ 客户分类 总 ' || count(*) ||
       '，根 ' || count(*) FILTER (WHERE parent_id IS NULL) ||
       '，最大深度 ' || COALESCE(MAX(level), 0) AS 结果
FROM client_categories;
