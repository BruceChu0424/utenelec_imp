-- =====================================================================
-- 模具主档迁移：CSV → moulds（不依赖 server 启动）
-- =====================================================================
-- 用法：bash server/legacy_migration/migrate.sh --mould-data
-- 前提：moulds 表已存在（V34 由 server Flyway 创建）；mould_categories 已迁。
-- 来源：老库 B_Mould（1605 条），category_id 关联 mould_categories.legacy_id
--   （B_Mould.ParentID → SystemItem.ItemID ItemclassID=18）。19 条 ParentID 悬空
--   （指向已删 SystemItem）→ category_id 置 NULL（在前端"全部模具"视图可见）。
-- 字段语义见 V34（MStatus=制造年月、Status=使用/报废、summary=保管人）。
-- =====================================================================

BEGIN;
SET session_replication_role = replica;
TRUNCATE moulds;
SET session_replication_role = DEFAULT;

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

INSERT INTO moulds (
    legacy_id, category_id, name, code, mnumber, qty, tqty, mstatus, status, place, keeper, remark
)
SELECT
    ms.legacy_id,
    (SELECT c.id FROM mould_categories c WHERE c.legacy_id = ms.parent_legacy),
    ms.name, ms.code, ms.mnumber, ms.qty, ms.tqty, ms.mstatus, ms.status, ms.place, ms.keeper, ms.remark
FROM mould_stage ms;

COMMIT;

SELECT '✔ 模具 ' || count(*) ||
       '，已挂分类 ' || count(category_id) ||
       '，未挂分类 ' || count(*) FILTER (WHERE category_id IS NULL) ||
       '，在用 ' || count(*) FILTER (WHERE status = N'使用') ||
       '，禁用 ' || count(*) FILTER (WHERE status = N'禁用') AS 结果
FROM moulds;
