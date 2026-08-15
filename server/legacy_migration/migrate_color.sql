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

BEGIN;
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

INSERT INTO colors (legacy_id, code, name, status)
SELECT
    legacy_id,
    code,
    NULLIF(BTRIM(name, ' ' || chr(12288)), ''),   -- 去首尾半角/全角空白，空串→NULL
    status
FROM color_stage;

COMMIT;

SELECT '✔ 颜色 总 ' || count(*) ||
       '，使用 ' || count(*) FILTER (WHERE status = N'使用') ||
       '，禁用 ' || count(*) FILTER (WHERE status = N'禁用') ||
       '，空名 ' || count(*) FILTER (WHERE name IS NULL) AS 结果
FROM colors;
