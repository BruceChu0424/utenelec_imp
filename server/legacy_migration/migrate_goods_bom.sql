-- =====================================================================
-- 货品组装信息（BOM）迁移：CSV → goods_bom_items（不依赖 server 启动）
-- =====================================================================
-- 用法：bash server/legacy_migration/migrate.sh --goods-bom
-- 前提：goods_bom_items 表已存在（V79 由 server Flyway 创建）+ goods 主档已迁
--   （--goods-data 先跑，legacy_id 映射靠 goods.legacy_id）。
-- 来源：老库 B_BomItem（218,820 行 / 23,322 个父货品）。
--   BillID → goods_id（成品/半成品），GoodsID → component_goods_id（组件）。
-- 孤儿行（BillID/GoodsID 指向已删除/未迁货品，老库实测约 1 万+1.2 万行）跳过不迁。
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
    bs.bom_status, bs.sstatus,
    ROW_NUMBER() OVER (PARTITION BY bs.goods_legacy_id ORDER BY bs.legacy_id)
FROM bom_stage bs
JOIN goods g ON g.legacy_id = bs.goods_legacy_id
JOIN goods c ON c.legacy_id = bs.component_legacy_id;

COMMIT;

SELECT '✔ 组装信息 迁入 ' || count(*) || ' 行，覆盖成品 ' || count(DISTINCT goods_id) || ' 个' AS 结果
FROM goods_bom_items;

SELECT '⚠ 跳过孤儿行（父/组件货品不存在）：' || count(*) || ' 行' AS 孤儿
FROM bom_stage bs
WHERE NOT EXISTS (SELECT 1 FROM goods g WHERE g.legacy_id = bs.goods_legacy_id)
   OR NOT EXISTS (SELECT 1 FROM goods c WHERE c.legacy_id = bs.component_legacy_id);
