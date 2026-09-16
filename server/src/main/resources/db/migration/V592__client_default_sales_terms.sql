-- =====================================================================
-- V592 2026-09-15 客户「默认销售条款」落客户表（单一事实源，与货品归属同思路）
-- =====================================================================
-- 用户口径：新建销售订货单选客户后预填的结账方式/货运策略/币种，此前是实时
--   查该客户最近一张订单推导（SalesOrderRepository.findLastTermsByClientId，
--   无表）。现改为**客户表列**：
--   - 基础资料客户详情可直接维护（和货品所属仓库一样就地编辑）；
--   - 每次保存/审核销售订货单把本次条款写回客户行（最新一次选择胜出，
--     值没变不写——goods 归属仓同款幂等守卫）；
--   - 预填一律读客户行；本迁移按「最近一张未删订单」做存量回填。
--
-- 列：
--   clients.default_shipment_policy TEXT        （货运策略，单头同款自由文本）
--   clients.default_currency_id     UUID        → currencies(id)（币种）
--   （结账方式复用既有 clients.default_settlement_method_id，不另加列）
--
-- 顺序规矩（V259/V587/V590 同款）：clients 带审计/行触发器，先加列/索引/FK，
--   再做 UPDATE 回填，之后不再 ALTER clients。回填只填空（IS NULL 守卫），
--   已人工维护的默认值绝不覆盖；重放幂等。
-- =====================================================================

ALTER TABLE clients
    ADD COLUMN IF NOT EXISTS default_shipment_policy TEXT;

ALTER TABLE clients
    ADD COLUMN IF NOT EXISTS default_currency_id UUID
        REFERENCES currencies(id) ON DELETE RESTRICT;

CREATE INDEX IF NOT EXISTS idx_clients_default_currency
    ON clients(default_currency_id)
    WHERE default_currency_id IS NOT NULL;

-- 存量回填：每个客户最近一张未删销售订单（不限审核状态，与旧学习口径一致）
-- 的单头条款。DISTINCT ON 取最新，三个字段一起搬。
-- ⚠️ 结账方式必须过 fn_sync_client_default_settlement_method_reference()
-- 触发器（V285）：只回填「使用中且未软删」的字典值（订单可能记着已停用的
-- 结账方式，直接写会炸迁移/给客户打上不可用默认），price_style 旧快照随
-- 字典 legacy_id 成对写入（触发器要求 UUID 与快照一致）。
UPDATE clients c
SET default_settlement_method_id = COALESCE(active.id, c.default_settlement_method_id),
    price_style = CASE WHEN active.id IS NOT NULL
        THEN active.legacy_id ELSE c.price_style END,
    default_shipment_policy = latest.shipment_policy,
    default_currency_id = latest.currency_id
FROM (
    SELECT DISTINCT ON (o.client_id)
           o.client_id,
           o.settlement_method_id,
           o.shipment_policy,
           o.currency_id
    FROM sales_orders o
    WHERE o.is_deleted = false
      AND o.client_id IS NOT NULL
    ORDER BY o.client_id, o.created_at DESC, o.id DESC
) latest
LEFT JOIN settlement_methods active
  ON active.id = latest.settlement_method_id
 AND active.status = '使用'
 AND COALESCE(active.is_deleted, FALSE) = FALSE
WHERE c.id = latest.client_id
  AND (c.default_settlement_method_id IS DISTINCT FROM
            COALESCE(active.id, c.default_settlement_method_id)
       OR c.price_style IS DISTINCT FROM
            CASE WHEN active.id IS NOT NULL
                 THEN active.legacy_id ELSE c.price_style END
       OR c.default_shipment_policy IS DISTINCT FROM latest.shipment_policy
       OR c.default_currency_id IS DISTINCT FROM latest.currency_id);

COMMENT ON COLUMN clients.default_shipment_policy IS
    '默认货运策略：新建销售订货单选客户后预填；每次下单自动写回最新一次选择（V592 单一事实源）。';
COMMENT ON COLUMN clients.default_currency_id IS
    '默认币种(currencies.id)：新建销售订货单选客户后预填；每次下单自动写回最新一次选择（V592 单一事实源）。';
