-- =====================================================================
-- 基本单位主档迁移：CSV → units（不依赖 server 启动）
-- =====================================================================
-- 用法：bash server/legacy_migration/migrate.sh --unit-data
-- 前提：units 表已存在（V40 由 server Flyway 创建）。
-- 来源：老库 B_Unit（66 条），扁平表（ParentID 全 0，无分类树）。
--   字段映射：ID→legacy_id、Number→code、Unit_Name→name、Status→status。
--   name 做 BTRIM（含全角空格 chr(12288)）+ 空串→NULL（实测 1 条空名；" 套" 前导空白也修）。
--   其余原样保留（噪音行："1"/"0.1" 换算系数、"单联单控开关7" 非单位污染——保证货品
--   unit_legacy_id 引用不悬空，用户可在 UI 禁用/删除）。
-- =====================================================================

BEGIN;
SET session_replication_role = replica;
TRUNCATE units;
SET session_replication_role = DEFAULT;

CREATE TEMP TABLE unit_stage (
    legacy_id int,
    code      text,          -- Number
    name      text,          -- Unit_Name
    status    text           -- Status
);
\copy unit_stage FROM '/tmp/unit.csv' WITH (FORMAT csv, DELIMITER '|', HEADER true)

INSERT INTO units (legacy_id, code, name, status)
SELECT
    legacy_id,
    code,
    NULLIF(BTRIM(name, ' ' || chr(12288)), ''),   -- 去首尾半角/全角空白，空串→NULL
    status
FROM unit_stage;

COMMIT;

SELECT '✔ 单位 总 ' || count(*) ||
       '，使用 ' || count(*) FILTER (WHERE status = N'使用') ||
       '，禁用 ' || count(*) FILTER (WHERE status = N'禁用') ||
       '，空名 ' || count(*) FILTER (WHERE name IS NULL) AS 结果
FROM units;
