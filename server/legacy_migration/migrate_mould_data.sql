-- =====================================================================
-- 模具主档迁移：CSV → moulds（不依赖 server 启动）
-- =====================================================================
-- 用法：bash server/legacy_migration/migrate.sh --mould-data
-- 前提：moulds 表已存在（V34 由 server Flyway 创建）；mould_categories 已迁。
-- 来源：老库 B_Mould（1605 条），category_id 关联 mould_categories.legacy_id
--   （B_Mould.ParentID → SystemItem.ItemID ItemclassID=18）。19 条 ParentID 悬空
--   （指向已删 SystemItem）统一挂 V275 注册表中的系统“未分类”根。
-- 字段语义见 V34（MStatus=制造年月、Status=使用/报废、summary=保管人）。
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

-- Do not bypass FK/audit triggers: referenced moulds make a reload fail closed.
DELETE FROM moulds;

CREATE TEMP TABLE mould_stage (
    legacy_id    int,
    parent_legacy int,
    name         text,
    code         text,
    mnumber      text,
    qty          text,
    tqty         numeric(18,4),
    mstatus      text,
    status       text,
    place        text,
    keeper       text,
    remark       text
);
\copy mould_stage FROM '/tmp/mould.csv' WITH (FORMAT csv, DELIMITER '|', HEADER true)

WITH numbered AS (
    SELECT ms.*,
           row_number() OVER (ORDER BY ms.legacy_id) AS seq_ordinal,
           count(*) OVER ()::bigint AS allocation_count
    FROM mould_stage ms
), reserved AS (
    INSERT INTO category_master_code_sequences (master_type, last_seq)
    SELECT 'MOULD', COALESCE(max(allocation_count), 0) FROM numbered
    ON CONFLICT (master_type) DO UPDATE
    SET last_seq = category_master_code_sequences.last_seq + EXCLUDED.last_seq
    RETURNING last_seq
)
INSERT INTO moulds (
    legacy_id, category_id, name, code, mnumber, qty, tqty, mstatus, status, place, keeper, remark,
    code_managed, code_sequence
)
SELECT
    ms.legacy_id,
    COALESCE(
        (SELECT c.id FROM mould_categories c WHERE c.legacy_id = ms.parent_legacy),
        (SELECT mould_category_id
         FROM system_master_category_registry
         WHERE id = '27500000-0000-4000-8000-000000000001'::uuid)),
    ms.name, ms.code, ms.mnumber, ms.qty, ms.tqty, ms.mstatus, ms.status, ms.place, ms.keeper, ms.remark,
    FALSE, reserved.last_seq - ms.allocation_count + ms.seq_ordinal
FROM numbered ms CROSS JOIN reserved;

COMMIT;

SELECT '✔ 模具 ' || count(*) ||
       '，已挂分类 ' || count(category_id) ||
       '，未挂分类 ' || count(*) FILTER (WHERE category_id IS NULL) ||
       '，在用 ' || count(*) FILTER (WHERE status = N'使用') ||
       '，禁用 ' || count(*) FILTER (WHERE status = N'禁用') AS 结果
FROM moulds;
