-- =====================================================================
-- 货架库位（目视化清单）迁移：人工维护 shelf_labels.csv → goods.stock_place
-- =====================================================================
-- 用法：bash server/legacy_migration/migrate.sh --shelf-labels --confirm-destructive
-- 前提：--goods-data 已迁（goods.legacy_id / goods.code 已就位）。
--
-- 来源说明（重要）：老库 B_Goods.StockPlace 只有 151 行且是历史残值（'18'/'20' 等
--   内部代码），与仓库现场挂牌的「库行-层-位」格式（如 A31-3-1、A39-1-5）完全无关。
--   现场挂牌数据只存在于纸质/打印的「目视化管理清单」，因此本迁移不读老库导出，
--   改由仓库部门按挂牌整理 data/shelf_labels.csv（| 分隔，UTF-8，含表头）：
--     place|goods_code|goods_legacy_id
--     A31-3-1|Z9UT-ZJ127C|
--     A31-3-2|Z9UT-ZJ124C|
--   匹配优先级：goods_legacy_id（老库 B_Goods.ID）> goods_code（ANumber/新编号）。
--   两者至少填一个；都填时以 legacy_id 为准。
--
-- 语义：只回填 goods.stock_place（库位号），幂等可重跑；
--   行内 place 会 BTRIM，空 place 视为「清除该货品库位」（显式清空）。
--   未匹配/重复匹配的行不静默：末尾 SELECT 输出对账清单，reject 不写入。
--   重复检查两层：同键重复（编码/legacy id 直接重复）+ 解析后同一货品经不同键重复。
-- 下游消费：仓库管理 → 货架目视化清单页（/warehouse/shelf-labels，
--   GET /api/stock/shelf-labels）+ 7 类仓库明细报表「库位号」列 + 即时库存「库位号」列。
-- =====================================================================

BEGIN;
SELECT set_config('app.business_identifier_legacy_import', 'on', true);

CREATE TEMP TABLE shelf_stage (
    place           text,    -- 库位号（库行-层-位，如 A31-3-1）
    goods_code      text,    -- 物料编码（goods.code / 老库 ANumber，可空）
    goods_legacy_id int      -- 老库 B_Goods.ID（可空，优先匹配）
) ON COMMIT DROP;
\copy shelf_stage FROM '/tmp/shelf_labels.csv' WITH (FORMAT csv, DELIMITER '|', HEADER true)

-- 归一化：去空白；code 空串→NULL。
UPDATE shelf_stage
SET place = NULLIF(BTRIM(place, ' ' || chr(12288)), ''),
    goods_code = NULLIF(BTRIM(COALESCE(goods_code, ''), ' ' || chr(12288)), '');

-- 违规输入直接失败（绝不静默改数据）：
DO $$
DECLARE bad int;
BEGIN
    SELECT count(*) INTO bad FROM shelf_stage
    WHERE goods_code IS NULL AND goods_legacy_id IS NULL;
    IF bad > 0 THEN
        RAISE EXCEPTION 'shelf_labels.csv 有 % 行物料编码与 legacy id 同时为空', bad;
    END IF;
    SELECT count(*) INTO bad FROM (
        SELECT COALESCE(goods_legacy_id::text, goods_code) AS k
        FROM shelf_stage GROUP BY 1 HAVING count(*) > 1
    ) d;
    IF bad > 0 THEN
        RAISE EXCEPTION 'shelf_labels.csv 有 % 个货品重复出现（同一货品只能一个库位）', bad;
    END IF;
END $$;

-- 解析目标货品：legacy_id 优先，其次 code；只匹配未软删货品。
CREATE TEMP TABLE shelf_resolved ON COMMIT DROP AS
SELECT s.place,
       COALESCE(g_by_legacy.id, g_by_code.id) AS goods_id,
       s.goods_code,
       s.goods_legacy_id
FROM shelf_stage s
LEFT JOIN goods g_by_legacy
  ON s.goods_legacy_id IS NOT NULL
 AND g_by_legacy.legacy_id = s.goods_legacy_id
 AND g_by_legacy.is_deleted = false
LEFT JOIN goods g_by_code
  ON g_by_legacy.id IS NULL
 AND s.goods_code IS NOT NULL
 AND g_by_code.code = s.goods_code
 AND g_by_code.is_deleted = false;

-- 解析后复核：同一货品可能经「编码」和「legacy id」两个不同的键分别出现，
-- 上面的按键查重抓不住这种跨键重复；UPDATE 多源行命中同一货品时结果非确定，
-- 必须在此显式拒绝（2026-08-17 开发库演练实测命中）。
DO $$
DECLARE dup int;
BEGIN
    SELECT count(*) INTO dup FROM (
        SELECT goods_id FROM shelf_resolved
        WHERE goods_id IS NOT NULL
        GROUP BY goods_id HAVING count(*) > 1
    ) d;
    IF dup > 0 THEN
        RAISE EXCEPTION 'shelf_labels.csv 有 % 个货品经不同键（编码/legacy id）重复出现，同一货品只能一个库位', dup;
    END IF;
END $$;

-- 回填库位号（含「空 place = 清除」语义；updated_at 触审计基线）。
UPDATE goods g
SET stock_place = r.place,
    updated_at = now()
FROM shelf_resolved r
WHERE g.id = r.goods_id
  AND COALESCE(g.stock_place, '') IS DISTINCT FROM COALESCE(r.place, '');

-- 对账输出（同事务内 psql 打印；未匹配行必须复核编码/legacy id 后重跑）：
SELECT '✔ 货架库位 总 ' || count(*) ||
       '，已匹配 ' || count(*) FILTER (WHERE goods_id IS NOT NULL) ||
       '，未匹配 ' || count(*) FILTER (WHERE goods_id IS NULL) AS 结果
FROM shelf_resolved;

SELECT goods_legacy_id, goods_code, place AS 未匹配库位
FROM shelf_resolved WHERE goods_id IS NULL ORDER BY place;

COMMIT;

-- 全库库位分布（迁移后货架目视化清单页/挂牌打印可见的库行一览）：
SELECT split_part(stock_place, '-', 1) AS 库行, count(*) AS 库位数
FROM goods
WHERE is_deleted = false AND NULLIF(BTRIM(stock_place), '') IS NOT NULL
GROUP BY 1 ORDER BY 1;
