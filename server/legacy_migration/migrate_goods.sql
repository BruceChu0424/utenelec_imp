-- =====================================================================
-- 货品分类迁移：CSV → material_categories（不依赖 server 启动）
-- =====================================================================
-- 用法：bash server/legacy_migration/migrate.sh [--goods]
-- 树结构（顶级分组 + 分类 + 孤儿虚拟根）：
--   货品资料 (GOODS, level 0, 顶级分组，将来模具/颜色资料同级)
--   ├─ 原材料 A (level 1) → 包装材料 (2) → 标贴 (3) → ...
--   ├─ 半成品 BCP / 成品 C / 轨道 GD01 / 辅料 HL / 广告展板 HL01 / OEM×3
--   └─ ...
--   未分类（历史孤儿）(LEGACY_ORPHAN, level 0) → 15 个孤儿 (level 1)
-- 递归算 depth（不信老库 Level）；分层 INSERT（父在上一层已可见，FK + path 触发器正确）。
-- =====================================================================

-- 清表：goods 通过 category_id 引用本表，TRUNCATE 必须同时清 goods
--   （重载分类会让分类 UUID 变化，goods 的 category_id 失效，需重跑 --goods-data）。
--   不依赖 session_replication_role（实测它绕不过 TRUNCATE 的 FK 检查，V32 建表后单独 TRUNCATE 会失败）。
BEGIN;
TRUNCATE goods, material_categories;

CREATE TEMP TABLE mc_stage (legacy_id int, parent_legacy int, code text, name text);
\copy mc_stage FROM '/tmp/goods_categories.csv' WITH (FORMAT text, DELIMITER '|', HEADER true)

-- 顶级分组：货品资料（legacy_id=NULL；将来模具资料/颜色资料各加一个同级分组）
INSERT INTO material_categories (legacy_id, code, name, level, parent_id)
VALUES (NULL, 'GOODS', '货品资料', 0, NULL);

-- 虚拟孤儿根
INSERT INTO material_categories (legacy_id, code, name, level, parent_id)
VALUES (-1, 'LEGACY_ORPHAN', '未分类（历史孤儿）', 0, NULL);

-- 递归算 depth：老库根（ParentID=0）→ depth 1（挂货品资料分组）；子 → depth+1
CREATE TEMP TABLE mc_nodes AS
WITH RECURSIVE mc_tree AS (
    SELECT legacy_id, parent_legacy, code, name, 1 AS depth
    FROM mc_stage WHERE parent_legacy IS NULL OR parent_legacy = 0
    UNION ALL
    SELECT s.legacy_id, s.parent_legacy, s.code, s.name, t.depth + 1
    FROM mc_stage s JOIN mc_tree t ON s.parent_legacy = t.legacy_id
)
SELECT * FROM mc_tree;

-- 分层 INSERT：depth 1 → parent=货品资料分组；depth 2+ → parent=legacy 关联
DO $$
DECLARE d INT; maxd INT; goods_root UUID;
BEGIN
    SELECT id INTO goods_root FROM material_categories WHERE code = 'GOODS' AND legacy_id IS NULL;
    SELECT COALESCE(MAX(depth), 1) INTO maxd FROM mc_nodes;
    FOR d IN 1..maxd LOOP
        INSERT INTO material_categories (legacy_id, code, name, level, sort_order, parent_id)
        SELECT n.legacy_id, n.code, n.name, n.depth,
               ROW_NUMBER() OVER (ORDER BY n.code),
               CASE WHEN n.depth = 1 THEN goods_root
                    ELSE (SELECT id FROM material_categories WHERE legacy_id = n.parent_legacy) END
        FROM mc_nodes n WHERE n.depth = d;
    END LOOP;
END $$;

-- 孤儿（父已被删，挂虚拟根）
INSERT INTO material_categories (legacy_id, code, name, level, sort_order, parent_id)
SELECT s.legacy_id, s.code, s.name, 1, 0, (SELECT id FROM material_categories WHERE legacy_id = -1)
FROM mc_stage s
WHERE s.parent_legacy <> 0
  AND NOT EXISTS (SELECT 1 FROM mc_stage p WHERE p.legacy_id = s.parent_legacy)
  AND NOT EXISTS (SELECT 1 FROM mc_nodes   n WHERE n.legacy_id = s.legacy_id);

COMMIT;

SELECT '✔ 分类 总 ' || count(*) ||
       '，根 ' || count(*) FILTER (WHERE parent_id IS NULL) ||
       '，最大深度 ' || MAX(level) AS 结果
FROM material_categories;
