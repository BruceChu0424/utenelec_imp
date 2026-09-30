-- =====================================================================
-- 颜色主档迁移：CSV → colors（不依赖 server 启动）
-- =====================================================================
-- 用法：bash server/legacy_migration/migrate.sh --color-data
-- 前提：colors 表已存在（V39 由 server Flyway 创建）。
-- 来源：老库 B_Color（151 条），扁平表（ParentID 全 0，无分类树）。
--   字段映射：ID→legacy_id、Number→code、ColorName→name、Status→status。
--   name 做 BTRIM（含全角空格 chr(12288)）+ 空串→NULL（实测 1 条空名）。
--   其余原样保留（噪音行：尾点/中文逗号/重复名——保证货品 color_legacy_id 引用不悬空）。
-- staging 用真实类型，COPY csv 自动 cast + 空字段→null。
-- =====================================================================

SELECT set_config('app.business_identifier_legacy_import', 'on', true);
-- Preserve FK/audit enforcement; referenced colors make a reload fail closed.
DELETE FROM colors;

CREATE TEMP TABLE color_stage (
    legacy_id int,
    code      text,          -- Number
    name      text,          -- ColorName
    status    text           -- Status
) ON COMMIT DROP;
\copy color_stage FROM '/tmp/color.csv' WITH (FORMAT csv, DELIMITER '|', HEADER true)

-- V276 主档码终身预留：老库 B_Color 存在同码不同身份的重复行（实测 '01'×18 等 6 组 22 行），
-- 按现行设计不改表、不改码值语义：每组按 legacy_id 序第一条保留老库原码，其余走固定前缀
-- 主档分配器 master_code_sequences(prefix='YS') 取号（MasterCodePrefix.COLOR →
-- MasterCodeService.create，前缀 + %06d；颜色无分类树，不占 category_master_code_sequences）。
WITH ordered AS (
    SELECT cs.*,
           row_number() OVER (ORDER BY cs.legacy_id) AS legacy_ordinal,
           row_number() OVER (PARTITION BY upper(btrim(cs.code)) ORDER BY cs.legacy_id) AS dup_ordinal
    FROM color_stage cs
), dup_count AS (
    SELECT count(*)::int AS n FROM ordered WHERE dup_ordinal > 1
), reserved AS (
    INSERT INTO master_code_sequences (prefix, last_seq)
    SELECT 'YS', n FROM dup_count WHERE n > 0
    ON CONFLICT (prefix) DO UPDATE
    SET last_seq = master_code_sequences.last_seq + EXCLUDED.last_seq
    RETURNING last_seq
)
INSERT INTO colors (legacy_id, code, name, status)
SELECT
    ordered.legacy_id,
    CASE WHEN ordered.dup_ordinal = 1 THEN ordered.code
         ELSE 'YS' || to_char(
                  reserved.last_seq - dup_count.n
                  + (SELECT count(*) FROM ordered d2
                     WHERE d2.dup_ordinal > 1 AND d2.legacy_ordinal <= ordered.legacy_ordinal),
                  'FM000000')
    END,
    NULLIF(BTRIM(ordered.name, ' ' || chr(12288)), ''),   -- 去首尾半角/全角空白，空串→NULL
    ordered.status
-- No duplicate codes means no sequence allocation and therefore no reserved
-- row. Keep all original identities even when that optional allocation is empty.
FROM ordered CROSS JOIN dup_count LEFT JOIN reserved ON TRUE;

DO $color_identity$
BEGIN
    IF (SELECT count(*) FROM colors) <> (SELECT count(*) FROM color_stage)
       OR EXISTS (SELECT legacy_id FROM color_stage EXCEPT SELECT legacy_id FROM colors)
       OR EXISTS (SELECT legacy_id FROM colors EXCEPT SELECT legacy_id FROM color_stage) THEN
        RAISE EXCEPTION 'color bootstrap did not preserve every source identity';
    END IF;
END;
$color_identity$;


SELECT '✔ 颜色 总 ' || count(*) ||
       '，使用 ' || count(*) FILTER (WHERE status = N'使用') ||
       '，禁用 ' || count(*) FILTER (WHERE status = N'禁用') ||
       '，空名 ' || count(*) FILTER (WHERE name IS NULL) ||
       '，重码改派 YS ' || count(*) FILTER (WHERE code ~ '^YS[0-9]{6}$') AS 结果
FROM colors;
