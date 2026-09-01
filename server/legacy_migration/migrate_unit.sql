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
SELECT set_config('app.business_identifier_legacy_import', 'on', true);
-- Preserve FK/audit enforcement; referenced units make a reload fail closed.
DELETE FROM units;

CREATE TEMP TABLE unit_stage (
    legacy_id int,
    code      text,          -- Number
    name      text,          -- Unit_Name
    status    text           -- Status
) ON COMMIT DROP;
\copy unit_stage FROM '/tmp/unit.csv' WITH (FORMAT csv, DELIMITER '|', HEADER true)

INSERT INTO units (legacy_id, code, name, status)
SELECT
    legacy_id,
    code,
    NULLIF(BTRIM(name, ' ' || chr(12288)), ''),   -- 去首尾半角/全角空白，空串→NULL
    status
FROM unit_stage;

-- Explicit reviewed legacy identities only. This declares that these three
-- unit UUIDs are MASS units and records conversion to the imported kg UUID.
-- It does NOT claim that generic legacy Weight columns are kg, and it never
-- classifies a goods item from a unit name.
INSERT INTO unit_measurement_profiles(
    unit_id,
    measurement_dimension,
    canonical_unit_id,
    to_canonical_factor,
    provenance
)
SELECT source_unit.id,
       'MASS',
       kg.id,
       mapping.to_kg_factor,
       'LEGACY_EXPLICIT_ID'
FROM (
    VALUES
        (108, 1.000000000000::numeric),
        (109, 0.001000000000::numeric),
        (241, 0.500000000000::numeric)
) mapping(legacy_id, to_kg_factor)
JOIN units source_unit ON source_unit.legacy_id = mapping.legacy_id
JOIN units kg ON kg.legacy_id = 108;

COMMIT;

SELECT '✔ 单位 总 ' || count(*) ||
       '，使用 ' || count(*) FILTER (WHERE status = N'使用') ||
       '，禁用 ' || count(*) FILTER (WHERE status = N'禁用') ||
       '，空名 ' || count(*) FILTER (WHERE name IS NULL) AS 结果
FROM units;
