-- =====================================================================
-- V593 2026-09-15 采购/委外链主档默认值单一事实源（货品价格/默认供应商 + 供应商条款）
-- =====================================================================
-- 用户口径（与 V587-V592 同一模式：主档列 + 下单写回 + 预填读主档）：
--   1. 新建采购订货单选货品 → 自动带出该货品绑定的供应商（goods.default_supplier_id，
--      复用既有列；此前由「查最近订单」实时推导，基础资料改不了）；
--   2. 供应商出来 → 币种/税率/结账方式自动跳出来（suppliers 新增 default_currency_id /
--      default_tax_rate；结账方式复用 V452 既有列）；
--   3. 采购单价/委外加工单价放进货品资料（goods 新增两列），订货行单价预填，
--      每次保存订单写回最新价。
--   全部支持实时更新：每次保存采购/委外订单，把本次选择写回主档（最新一次胜出，
--   值没变不写）；预填一律优先读主档，主档没有再回落最近订单推导。
--
-- 顺序规矩（V259/V587/V590/V592 同款）：goods/suppliers 带审计/行触发器，
--   先加列/索引/FK，再做 UPDATE 回填，之后不再 ALTER。
--   suppliers 的结账方式回填必须过 fn_sync_supplier_default_settlement_method_
--   reference()（V452）触发器：只回填「使用中且未软删」的字典值，price_style
--   旧快照随字典 legacy_id 成对写入（V592 客户侧同款教训）。
-- =====================================================================

ALTER TABLE goods
    ADD COLUMN IF NOT EXISTS default_purchase_price NUMERIC(18, 6);

ALTER TABLE goods
    ADD COLUMN IF NOT EXISTS default_subcontract_price NUMERIC(18, 6);

ALTER TABLE suppliers
    ADD COLUMN IF NOT EXISTS default_currency_id UUID
        REFERENCES currencies(id) ON DELETE RESTRICT;

ALTER TABLE suppliers
    ADD COLUMN IF NOT EXISTS default_tax_rate NUMERIC(18, 4);

-- ---------- 存量回填：货品采购单价（最近一张未删采购单该货品行价） ----------
UPDATE goods g
SET default_purchase_price = latest.price
FROM (
    SELECT DISTINCT ON (i.goods_id) i.goods_id, i.price
    FROM purchase_order_items i
    JOIN purchase_orders o ON o.id = i.order_id
    WHERE i.goods_id IS NOT NULL
      AND i.is_deleted = false
      AND o.is_deleted = false
      AND i.price IS NOT NULL
    ORDER BY i.goods_id, o.created_at DESC, o.id DESC, i.id DESC
) latest
WHERE g.id = latest.goods_id
  AND g.default_purchase_price IS DISTINCT FROM latest.price;

-- ---------- 存量回填：货品委外加工单价（最近一张未删委外单该货品行价） ----------
UPDATE goods g
SET default_subcontract_price = latest.price
FROM (
    SELECT DISTINCT ON (i.goods_id) i.goods_id, i.price
    FROM subcontract_order_items i
    JOIN subcontract_orders o ON o.id = i.order_id
    WHERE i.goods_id IS NOT NULL
      AND i.is_deleted = false
      AND o.is_deleted = false
      AND i.price IS NOT NULL
    ORDER BY i.goods_id, o.created_at DESC, o.id DESC, i.id DESC
) latest
WHERE g.id = latest.goods_id
  AND g.default_subcontract_price IS DISTINCT FROM latest.price;

-- ---------- 存量回填：货品默认供应商（最近一张未删采购/委外单的供应商） ----------
-- 采购与委外同源学习：一张单上用过的供应商就是该货品当前绑定的供应商。
-- DISTINCT ON 取「最新一张（按单据时间）」，两者合成一张视图再取最新。
UPDATE goods g
SET default_supplier_id = latest.supplier_id
FROM (
    SELECT DISTINCT ON (goods_id) goods_id, supplier_id
    FROM (
        SELECT i.goods_id, o.supplier_id, o.created_at, o.id AS order_id, i.id AS item_id
        FROM purchase_order_items i
        JOIN purchase_orders o ON o.id = i.order_id
        WHERE i.goods_id IS NOT NULL AND i.is_deleted = false
          AND o.is_deleted = false AND o.supplier_id IS NOT NULL
        UNION ALL
        SELECT i.goods_id, o.supplier_id, o.created_at, o.id, i.id
        FROM subcontract_order_items i
        JOIN subcontract_orders o ON o.id = i.order_id
        WHERE i.goods_id IS NOT NULL AND i.is_deleted = false
          AND o.is_deleted = false AND o.supplier_id IS NOT NULL
    ) both_orders
    ORDER BY goods_id, created_at DESC, order_id DESC, item_id DESC
) latest
WHERE g.id = latest.goods_id
  AND g.default_supplier_id IS DISTINCT FROM latest.supplier_id;

-- ---------- 存量回填：供应商默认条款（最近一张未删采购单头条款） ----------
-- 结账方式只回填「使用中且未软删」字典（触发器要求 + 订单可能记着停用值），
-- price_style 成对写；币种/税率照常回填。
UPDATE suppliers s
SET default_settlement_method_id = COALESCE(active.id, s.default_settlement_method_id),
    price_style = CASE WHEN active.id IS NOT NULL
        THEN active.legacy_id ELSE s.price_style END,
    default_currency_id = latest.currency_id,
    default_tax_rate = latest.tax_rate
FROM (
    SELECT DISTINCT ON (o.supplier_id)
           o.supplier_id, o.settlement_method_id, o.currency_id, o.tax_rate
    FROM purchase_orders o
    WHERE o.is_deleted = false
      AND o.supplier_id IS NOT NULL
    ORDER BY o.supplier_id, o.created_at DESC, o.id DESC
) latest
LEFT JOIN settlement_methods active
  ON active.id = latest.settlement_method_id
 AND active.status = '使用'
 AND COALESCE(active.is_deleted, FALSE) = FALSE
WHERE s.id = latest.supplier_id
  AND (s.default_settlement_method_id IS DISTINCT FROM
            COALESCE(active.id, s.default_settlement_method_id)
       OR s.price_style IS DISTINCT FROM
            CASE WHEN active.id IS NOT NULL
                 THEN active.legacy_id ELSE s.price_style END
       OR s.default_currency_id IS DISTINCT FROM latest.currency_id
       OR s.default_tax_rate IS DISTINCT FROM latest.tax_rate);

COMMENT ON COLUMN goods.default_purchase_price IS
    '采购单价（V593 单一事实源）：新建采购订货单行价预填；每次保存采购单写回最新行价。';
COMMENT ON COLUMN goods.default_subcontract_price IS
    '委外加工单价（V593 单一事实源）：新建委外订货单行价预填；每次保存委外单写回最新行价。';
COMMENT ON COLUMN suppliers.default_currency_id IS
    '默认币种(currencies.id，V593)：采购/委外订货选供应商后预填；每次下单写回最新选择。';
COMMENT ON COLUMN suppliers.default_tax_rate IS
    '默认税率(百分比数值，V593)：采购/委外订货选供应商后预填；每次下单写回最新选择。';
