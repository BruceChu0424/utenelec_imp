-- =====================================================================
-- 模具分类迁移：CSV → mould_categories（不依赖 server 启动）
-- =====================================================================
-- 用法：bash server/legacy_migration/migrate.sh [--mould]
-- 数据来源：老库 SystemItem WHERE ItemclassID=18（模具系列，65 个扁平根），
--   由 export_legacy.ps1 MouldCategory 导出。V275 固定系统未分类根 UUID；
--   迁移保留该行，只重建普通分类。
-- 树形：65 个全是 ParentID=0 的扁平根 → 直接 level 0 入库（无 wrapper 分组：
--   表本身即模具，分组冗余）。保留递归 depth + 孤儿兜底以兼容将来老库加嵌套/孤儿。
--   dev classpath 样例使用相同树形，但不参与正式导入。
-- DELETE 让任何 goods/业务引用在写入前 fail-closed；禁止 TRUNCATE/CASCADE。
-- =====================================================================

BEGIN;
SELECT set_config('app.business_identifier_legacy_import', 'on', true);

DO $$
BEGIN
    IF (SELECT count(*) FROM system_master_category_registry) <> 1
       OR NOT EXISTS (
           SELECT 1
           FROM system_master_category_registry registry
           JOIN mould_categories category ON category.id = registry.mould_category_id
           WHERE registry.id = '27500000-0000-4000-8000-000000000001'::uuid
             AND category.legacy_id = -1
             AND category.is_deleted = FALSE
       ) THEN
        RAISE EXCEPTION 'current system mould-category UUID authority is missing or invalid';
    END IF;
END;
$$;

DELETE FROM moulds;
DELETE FROM mould_categories
WHERE id <> (
    SELECT mould_category_id
    FROM system_master_category_registry
    WHERE id = '27500000-0000-4000-8000-000000000001'::uuid
);

CREATE TEMP TABLE mc_stage (legacy_id int, parent_legacy int, code text, name text)
ON COMMIT DROP;
\copy mc_stage FROM '/tmp/mould_categories.csv' WITH (FORMAT text, DELIMITER '|', HEADER true)

CREATE OR REPLACE FUNCTION pg_temp.next_category_code(p_prefix text) RETURNS text AS $$
DECLARE v_seq bigint;
BEGIN
    INSERT INTO master_code_sequences (prefix, last_seq) VALUES (p_prefix, 1)
    ON CONFLICT (prefix) DO UPDATE SET last_seq = master_code_sequences.last_seq + 1
    RETURNING last_seq INTO v_seq;
    RETURN p_prefix || lpad(v_seq::text, 6, '0');
END;
$$ LANGUAGE plpgsql;

-- 递归算 depth：老库根（ParentID=0）→ depth 0；子 → depth+1
CREATE TEMP TABLE mc_nodes ON COMMIT DROP AS
WITH RECURSIVE mc_tree AS (
    SELECT legacy_id, parent_legacy, code, name, 0 AS depth
    FROM mc_stage WHERE parent_legacy IS NULL OR parent_legacy = 0
    UNION ALL
    SELECT s.legacy_id, s.parent_legacy, s.code, s.name, t.depth + 1
    FROM mc_stage s JOIN mc_tree t ON s.parent_legacy = t.legacy_id
)
SELECT * FROM mc_tree;

-- 系统未分类根由 V275 固定并登记，迁移只复用其 UUID。

-- 分层 INSERT：depth 0 → parent=NULL；depth>0 → parent=legacy 关联
DO $$
DECLARE d INT; maxd INT;
BEGIN
    SELECT COALESCE(MAX(depth), 0) INTO maxd FROM mc_nodes;
    FOR d IN 0..maxd LOOP
        INSERT INTO mould_categories
            (legacy_id, code, remark, legacy_code_snapshot, name, level, sort_order, parent_id)
        SELECT n.legacy_id, pg_temp.next_category_code('MF'), n.code, n.code, n.name, n.depth,
               ROW_NUMBER() OVER (ORDER BY n.code),
               CASE WHEN n.depth = 0 THEN NULL
                    ELSE (SELECT id FROM mould_categories WHERE legacy_id = n.parent_legacy) END
        FROM mc_nodes n WHERE n.depth = d;
    END LOOP;
END $$;

-- 孤儿兜底：父已被删的节点挂虚拟根（实测 0 行）
INSERT INTO mould_categories
    (legacy_id, code, remark, legacy_code_snapshot, name, level, sort_order, parent_id)
SELECT s.legacy_id, pg_temp.next_category_code('MF'), s.code, s.code, s.name,
       1, 0, (
           SELECT mould_category_id
           FROM system_master_category_registry
           WHERE id = '27500000-0000-4000-8000-000000000001'::uuid
       )
FROM mc_stage s
WHERE s.parent_legacy <> 0
  AND NOT EXISTS (SELECT 1 FROM mc_stage p WHERE p.legacy_id = s.parent_legacy)
  AND NOT EXISTS (SELECT 1 FROM mc_nodes   n WHERE n.legacy_id = s.legacy_id);

COMMIT;

SELECT '✔ 模具分类 总 ' || count(*) ||
       '，根 ' || count(*) FILTER (WHERE parent_id IS NULL) ||
       '，最大深度 ' || COALESCE(MAX(level), 0) AS 结果
FROM mould_categories;
