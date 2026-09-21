-- =====================================================================
-- V632 出货放行记账汇率 + 标准收付款方式
-- =====================================================================
-- 背景(2026-09-21 用户口径)：「销售出货财务审批那里应该可以填汇率」。
-- 此前 V631 只在财审放行前校验币种主档汇率 > 0，真正锁定汇率是仓库确认出库
-- 那一刻从币种主档取，财务在审核页只能看不能填。对齐金蝶/用友/SAP 的通行做法：
--   * 记账汇率在单据放行(审核)时从汇率表自动带出、审核前可改、审核后冻结在单据上；
--   * 收款按到账当天汇率，与应收记账汇率的差额进汇兑损益(V407 已有)。
-- 本迁移：
--   1. 放行事件表加 exchange_rate / exchange_rate_source 两列，记录这次放行冻结的
--      记账汇率与来源(CURRENCY_MASTER=币种主档预填, FINANCE_MANUAL=财务手工填写)。
--      RELEASED 且收费的事件必带；REVOKED/REJECTED/REJECT_REVOKED 与免费发货为空。
--   2. sales_shipments.exchange_rate 语义改为「财务放行时冻结的记账汇率」：
--      草稿仍不带销售端汇率(应用侧置空)；放行写入；撤回放行清空；
--      仓库确认出库按它折算本币立应收(没有冻结值的老放行单仍回落到币种主档)。
--   3. 收付款方式字典：V273 只带 3 条「旧库收付款方式 N(待同步名称)」占位行
--      (legacy_name_confirmed=false，不进选择器)。未从 recstyle.csv 导入精确名称的
--      安装(含清库后的公司库)收款单「收款方式」下拉为空且前端必填，收款单根本存不了。
--      这里补一套标准方式，仅在库里没有任何已确认方式时播种；固定 UUID、ON CONFLICT 幂等。
-- 不加表、不改保留列数据；条数 587→588。
-- =====================================================================

ALTER TABLE sales_shipment_finance_release_events
    ADD COLUMN exchange_rate        NUMERIC(18,6),
    ADD COLUMN exchange_rate_source VARCHAR(20);

ALTER TABLE sales_shipment_finance_release_events
    ADD CONSTRAINT sales_shipment_finance_release_event_rate_chk
        CHECK (exchange_rate IS NULL OR exchange_rate > 0),
    ADD CONSTRAINT sales_shipment_finance_release_event_rate_source_chk
        CHECK (exchange_rate_source IS NULL
               OR exchange_rate_source IN ('CURRENCY_MASTER', 'FINANCE_MANUAL')),
    ADD CONSTRAINT sales_shipment_finance_release_event_rate_pair_chk
        CHECK ((exchange_rate IS NULL) = (exchange_rate_source IS NULL));

COMMENT ON COLUMN sales_shipment_finance_release_events.exchange_rate IS
    '本次放行冻结的记账汇率(本位币/1 原币, V632)；仅 RELEASED 且收费的事件有值';
COMMENT ON COLUMN sales_shipment_finance_release_events.exchange_rate_source IS
    '记账汇率来源(V632)：CURRENCY_MASTER=币种主档参考汇率预填, FINANCE_MANUAL=财务放行时手工填写';

COMMENT ON COLUMN sales_shipments.exchange_rate IS
    '记账汇率(本位币/1 原币)：财务放行时冻结(币种主档预填或财务手填, V632)，仓库确认出库按它折算本币立应收；草稿不带销售端汇率，撤回放行后清空';

-- ---------------------------------------------------------------------
-- 标准收付款方式(仅在没有任何已确认方式时播种)
-- ---------------------------------------------------------------------
INSERT INTO finance_payment_methods
    (id, legacy_id, code, name, is_receipt, is_payment, legacy_name_confirmed, status, sort_order, remark)
SELECT seed.id, NULL, seed.code, seed.name, TRUE, TRUE, TRUE, '使用', seed.sort_order,
       '标准收付款方式(V632 补齐；旧库 RecStyle 精确名称导入后可按需禁用)'
FROM (VALUES
    ('63200000-0000-4000-8200-000000000001'::UUID, 'REC-BANK',   '银行转账', 100),
    ('63200000-0000-4000-8200-000000000002'::UUID, 'REC-CASH',   '现金',     110),
    ('63200000-0000-4000-8200-000000000003'::UUID, 'REC-CHEQUE', '支票',     120),
    ('63200000-0000-4000-8200-000000000004'::UUID, 'REC-DRAFT',  '承兑汇票', 130)
) AS seed(id, code, name, sort_order)
WHERE NOT EXISTS (
    SELECT 1 FROM finance_payment_methods existing
    WHERE existing.legacy_name_confirmed
      AND COALESCE(existing.is_deleted, FALSE) = FALSE
)
ON CONFLICT (code) DO NOTHING;
