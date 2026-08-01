-- =====================================================================
-- 货品组装信息（BOM）迁移：CSV → goods_bom_items（不依赖 server 启动）
-- =====================================================================
-- 用法：bash server/legacy_migration/migrate.sh --goods-bom
-- 前提：goods_bom_items 表已存在（V79 由 server Flyway 创建）+ goods 主档已迁
--   （--goods-data 先跑，legacy_id 映射靠 goods.legacy_id）。
-- 来源：老库 B_BomItem（218,820 行 / 23,322 个父货品）。
--   BillID → goods_id（成品/半成品），GoodsID → component_goods_id（组件）。
-- 孤儿行（BillID/GoodsID 指向已删除/未迁货品，或命中 auto_created 历史引用锚）跳过不迁。
-- 注意：业务单据迁移会为 NOT NULL FK 保留 goods stub；即使它先存在，也必须继续按
-- “老库 B_Goods 不存在”处理，否则会把孤儿 B_BomItem 接入当前 BOM（V181 修正）。
-- color_legacy_id / vend_legacy_id 老库 0 = 未设 → NULL。
-- sort_order 按老库 ID 序生成（保持老系统 001.jpg 的行序）。
-- =====================================================================

BEGIN;
SET session_replication_role = replica;
TRUNCATE goods_bom_items;
SET session_replication_role = DEFAULT;

CREATE TEMP TABLE bom_stage (
    legacy_id int, goods_legacy_id int, component_legacy_id int,
    color_legacy_id int, qty numeric(18,5), price numeric(18,3), total numeric(18,2),
    vend_legacy_id int, summary text, bom_status boolean, sstatus boolean
);
\copy bom_stage FROM '/tmp/goods_bom.csv' WITH (FORMAT csv, DELIMITER '|', HEADER true)

INSERT INTO goods_bom_items (
    legacy_id, goods_id, component_goods_id,
    color_legacy_id, qty, price, total, vend_legacy_id, summary,
    color_id, default_supplier_id,
    bom_status, sstatus, sort_order
)
SELECT
    bs.legacy_id,
    g.id,
    c.id,
    NULLIF(bs.color_legacy_id, 0),
    bs.qty, bs.price, bs.total,
    NULLIF(bs.vend_legacy_id, 0),
    NULLIF(bs.summary, ''),
    (SELECT color_master.id FROM colors color_master WHERE color_master.legacy_id = NULLIF(bs.color_legacy_id, 0)),
    (SELECT supplier_master.id FROM suppliers supplier_master WHERE supplier_master.legacy_id = NULLIF(bs.vend_legacy_id, 0)),
    bs.bom_status, bs.sstatus,
    ROW_NUMBER() OVER (PARTITION BY bs.goods_legacy_id ORDER BY bs.legacy_id)
FROM bom_stage bs
JOIN goods g ON g.legacy_id = bs.goods_legacy_id
            AND g.is_deleted = FALSE
            AND g.auto_created = FALSE
JOIN goods c ON c.legacy_id = bs.component_legacy_id
            AND c.is_deleted = FALSE
            AND c.auto_created = FALSE;

-- 防御性清理：即使上方 JOIN 被后续改坏，也不允许迁移生成的占位端点进入活动 BOM。
UPDATE goods_bom_items bi
SET is_deleted = TRUE,
    deleted_at = COALESCE(bi.deleted_at, CURRENT_TIMESTAMP),
    updated_at = CURRENT_TIMESTAMP
FROM goods parent_goods, goods component_goods
WHERE parent_goods.id = bi.goods_id
  AND component_goods.id = bi.component_goods_id
  AND bi.legacy_id IS NOT NULL
  AND bi.is_deleted = FALSE
  AND (parent_goods.auto_created OR component_goods.auto_created);

DO $$
BEGIN
    IF EXISTS (
        SELECT 1
        FROM goods_bom_items bi
        JOIN goods parent_goods ON parent_goods.id = bi.goods_id
        JOIN goods component_goods ON component_goods.id = bi.component_goods_id
        WHERE bi.is_deleted = FALSE
          AND (parent_goods.auto_created OR component_goods.auto_created)
    ) THEN
        RAISE EXCEPTION 'active BOM references auto_created goods';
    END IF;
END
$$;

COMMIT;

SELECT '✔ 组装信息 迁入 ' || count(*) || ' 行，覆盖成品 ' || count(DISTINCT goods_id) || ' 个' AS 结果
FROM goods_bom_items;

SELECT '⚠ 跳过无有效主档行（父/组件不存在、已删除或为历史占位）：' || count(*) || ' 行' AS 孤儿
FROM bom_stage bs
WHERE NOT EXISTS (
          SELECT 1 FROM goods g
          WHERE g.legacy_id = bs.goods_legacy_id
            AND g.is_deleted = FALSE
            AND g.auto_created = FALSE)
   OR NOT EXISTS (
          SELECT 1 FROM goods c
          WHERE c.legacy_id = bs.component_legacy_id
            AND c.is_deleted = FALSE
            AND c.auto_created = FALSE);

SELECT '✔ 活动 BOM 占位端点 0 / 实际 ' || count(*) AS 占位门禁
FROM goods_bom_items bi
JOIN goods parent_goods ON parent_goods.id = bi.goods_id
JOIN goods component_goods ON component_goods.id = bi.component_goods_id
WHERE bi.is_deleted = FALSE
  AND (parent_goods.auto_created OR component_goods.auto_created);
