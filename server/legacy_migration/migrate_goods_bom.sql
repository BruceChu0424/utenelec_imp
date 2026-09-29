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

-- V711/V739 的 fn_bom_learning_manual_ownership 对每行 INSERT 做整子树递归环检测，
-- 198k 行下随表增长二次方退化（实测 5k 行 20.7s、50k 行 9:47）。V739 迁移自身在批量
-- 拓扑写入时就以 app.bom_learning_write='on' 跳过逐行重校验（模块自有守恒/结构校验），
-- 首导同场景同口径；导入后由运维一次性全图环检测兜底。
SELECT set_config('app.bom_learning_write', 'on', true);

-- Analysis/material rows may reference BOM evidence in the current schema.
-- Keep FK/audit triggers active so a reload on a used database fails closed.
DELETE FROM goods_bom_items;

CREATE TEMP TABLE bom_stage (
    legacy_id int, goods_legacy_id int, component_legacy_id int,
    color_legacy_id int, qty numeric(18,5), price numeric(18,3), total numeric(18,2),
    vend_legacy_id int, summary text, bom_status boolean, sstatus boolean
);
\copy bom_stage FROM '/tmp/goods_bom.csv' WITH (FORMAT csv, DELIMITER '|', HEADER true)

DO $$
BEGIN
    IF EXISTS (SELECT 1 FROM bom_stage GROUP BY legacy_id HAVING legacy_id IS NULL OR count(*) <> 1) THEN
        RAISE EXCEPTION 'legacy BOM requires one non-null unique source identity per edge';
    END IF;
END;
$$;

-- The full bootstrap preserves this explicit source evidence across modules.
-- Standalone execution also reports it; an excluded legacy edge never becomes
-- an operational BOM through a later historical-reference master insertion.
CREATE TEMP TABLE IF NOT EXISTS bootstrap_bom_exclusions (
    source_file text NOT NULL,
    source_legacy_id integer NOT NULL,
    parent_legacy_id integer,
    component_legacy_id integer,
    reason text NOT NULL CHECK (reason IN ('EXCLUDED_NON_OPERATIONAL_MASTER', 'EXCLUDED_NON_POSITIVE_QTY')),
    PRIMARY KEY (source_file, source_legacy_id)
);
-- V739 起 goods_bom_items.qty 要求为正（goods_bom_qty_positive_chk）；老库存在
-- qty=0 的行（实测 142 行）——按孤儿行同款口径显式排除并留痕，不伪造用量。
INSERT INTO bootstrap_bom_exclusions (
    source_file, source_legacy_id, parent_legacy_id, component_legacy_id, reason)
SELECT 'goods_bom.csv', source.legacy_id, source.goods_legacy_id, source.component_legacy_id,
       CASE WHEN source.qty IS NULL OR source.qty <= 0
            THEN 'EXCLUDED_NON_POSITIVE_QTY'
            ELSE 'EXCLUDED_NON_OPERATIONAL_MASTER' END
FROM bom_stage source
WHERE source.qty IS NULL OR source.qty <= 0
   OR NOT EXISTS (
          SELECT 1 FROM goods parent_goods
          WHERE parent_goods.legacy_id = source.goods_legacy_id
            AND NOT parent_goods.is_deleted AND NOT parent_goods.auto_created)
   OR NOT EXISTS (
          SELECT 1 FROM goods component_goods
          WHERE component_goods.legacy_id = source.component_legacy_id
            AND NOT component_goods.is_deleted AND NOT component_goods.auto_created);

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
            AND c.auto_created = FALSE
WHERE bs.qty > 0;

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

DO $$
BEGIN
    IF (SELECT count(*) FROM bom_stage) <>
       (SELECT count(*) FROM goods_bom_items item
        JOIN bom_stage source ON source.legacy_id = item.legacy_id)
       + (SELECT count(*) FROM bootstrap_bom_exclusions WHERE source_file = 'goods_bom.csv') THEN
        RAISE EXCEPTION 'legacy BOM source rows must equal imported edges plus exact non-operational exclusions';
    END IF;
END;
$$;


SELECT '✔ 组装信息 迁入 ' || count(*) || ' 行，覆盖成品 ' || count(DISTINCT goods_id) || ' 个' AS 结果
FROM goods_bom_items;

SELECT '⚠ 跳过无有效主档行（父/组件不存在、已删除或为历史占位）：' || count(*) || ' 行' AS 孤儿
FROM bom_stage bs
WHERE bs.qty > 0
  AND (NOT EXISTS (
          SELECT 1 FROM goods g
          WHERE g.legacy_id = bs.goods_legacy_id
            AND g.is_deleted = FALSE
            AND g.auto_created = FALSE)
   OR NOT EXISTS (
          SELECT 1 FROM goods c
          WHERE c.legacy_id = bs.component_legacy_id
            AND c.is_deleted = FALSE
            AND c.auto_created = FALSE));

SELECT '⚠ 跳过零/负用量行（V739 要求 qty 为正）：' || count(*) || ' 行' AS 零用量
FROM bom_stage bs WHERE bs.qty IS NULL OR bs.qty <= 0;

SELECT '✔ 活动 BOM 占位端点 0 / 实际 ' || count(*) AS 占位门禁
FROM goods_bom_items bi
JOIN goods parent_goods ON parent_goods.id = bi.goods_id
JOIN goods component_goods ON component_goods.id = bi.component_goods_id
WHERE bi.is_deleted = FALSE
  AND (parent_goods.auto_created OR component_goods.auto_created);
