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

-- V275 起系统“历史孤儿”分类 UUID 固化在 system_master_category_registry。
-- 只允许在没有下游业务引用的 bootstrap 库重载；DELETE 会让 FK
-- RESTRICT 在已使用库上 fail-closed，禁止 TRUNCATE/CASCADE 绕过保护。
BEGIN;
SELECT set_config('app.business_identifier_legacy_import', 'on', true);

DO $$
BEGIN
    IF (SELECT count(*) FROM system_master_category_registry) <> 1
       OR NOT EXISTS (
           SELECT 1
           FROM system_master_category_registry registry
           JOIN material_categories category
             ON category.id = registry.material_category_id
           WHERE registry.id = '27500000-0000-4000-8000-000000000001'::uuid
             AND category.legacy_id = -1
             AND category.legacy_code_snapshot = 'LEGACY_ORPHAN'
             AND category.is_deleted = FALSE
       ) THEN
        RAISE EXCEPTION 'current system material-category UUID authority is missing or invalid';
    END IF;
END;
$$;

DELETE FROM goods;
DELETE FROM material_categories
WHERE id <> (
    SELECT material_category_id
    FROM system_master_category_registry
    WHERE id = '27500000-0000-4000-8000-000000000001'::uuid
);

CREATE TEMP TABLE mc_stage (legacy_id int, parent_legacy int, code text, name text)
ON COMMIT DROP;
\copy mc_stage FROM '/tmp/goods_categories.csv' WITH (FORMAT text, DELIMITER '|', HEADER true)

-- 与 MasterCodeService 使用同一高水位；旧库 Number 只冻结为备注/溯源，不再充当内部 path code。
CREATE OR REPLACE FUNCTION pg_temp.next_category_code(p_prefix text) RETURNS text AS $$
DECLARE v_seq bigint;
BEGIN
    INSERT INTO master_code_sequences (prefix, last_seq) VALUES (p_prefix, 1)
    ON CONFLICT (prefix) DO UPDATE SET last_seq = master_code_sequences.last_seq + 1
    RETURNING last_seq INTO v_seq;
    RETURN p_prefix || lpad(v_seq::text, 6, '0');
END;
$$ LANGUAGE plpgsql;

-- 顶级分组：货品资料（legacy_id=NULL；将来模具资料/颜色资料各加一个同级分组）
INSERT INTO material_categories
    (legacy_id, code, remark, legacy_code_snapshot, name, level, parent_id)
VALUES (NULL, pg_temp.next_category_code('FL'), 'GOODS', 'GOODS', '货品资料', 0, NULL);

-- 虚拟孤儿根由 V275 固定并登记，迁移只复用其 UUID，绝不重建。

-- 递归算 depth：老库根（ParentID=0）→ depth 1（挂货品资料分组）；子 → depth+1
CREATE TEMP TABLE mc_nodes ON COMMIT DROP AS
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
    SELECT id INTO goods_root FROM material_categories
    WHERE legacy_code_snapshot = 'GOODS' AND legacy_id IS NULL;
    SELECT COALESCE(MAX(depth), 1) INTO maxd FROM mc_nodes;
    FOR d IN 1..maxd LOOP
        INSERT INTO material_categories
            (legacy_id, code, remark, legacy_code_snapshot, name, level, sort_order, parent_id)
        SELECT n.legacy_id, pg_temp.next_category_code('FL'), n.code, n.code, n.name, n.depth,
               ROW_NUMBER() OVER (ORDER BY n.code),
               CASE WHEN n.depth = 1 THEN goods_root
                    ELSE (SELECT id FROM material_categories WHERE legacy_id = n.parent_legacy) END
        FROM mc_nodes n WHERE n.depth = d;
    END LOOP;
END $$;

-- 孤儿（父已被删，挂虚拟根）
INSERT INTO material_categories
    (legacy_id, code, remark, legacy_code_snapshot, name, level, sort_order, parent_id)
SELECT s.legacy_id, pg_temp.next_category_code('FL'), s.code, s.code, s.name,
       1, 0, (
           SELECT material_category_id
           FROM system_master_category_registry
           WHERE id = '27500000-0000-4000-8000-000000000001'::uuid
       )
FROM mc_stage s
WHERE s.parent_legacy <> 0
  AND NOT EXISTS (SELECT 1 FROM mc_stage p WHERE p.legacy_id = s.parent_legacy)
  AND NOT EXISTS (SELECT 1 FROM mc_nodes   n WHERE n.legacy_id = s.legacy_id);

COMMIT;

SELECT '✔ 分类 总 ' || count(*) ||
       '，根 ' || count(*) FILTER (WHERE parent_id IS NULL) ||
       '，最大深度 ' || MAX(level) AS 结果
FROM material_categories;
