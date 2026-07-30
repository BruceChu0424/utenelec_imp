-- =====================================================================
-- V54：委外管理报表 · 月度上卷物化视图（subcontract_monthly_mv）
-- =====================================================================
-- 范本：V46__purchase_report.sql（采购月度上卷同构）
-- 设计依据：docs/数据迁移/22-委外管理-新库与迁移.md §六（17 张报表收敛为参数化查询）
-- 一致性契约：docs/数据迁移/27-DDL一致性契约.md（§一 V54 归属委外）
--
-- subcontract_monthly_mv：按 单据类型×年月×货品×供应商×币种 预聚合（最细粒度），
--   查询时按用户选定维度 GROUP BY 上卷（货品/供应商/时间…），起止日期按 ym 过滤。
--   涵盖 7 类有物流/金额的单据：ORDER/RECEIPT/RETURN/MATERIAL_ISSUE/MATERIAL_RETURN/WASTE
--   + INQUIRY/APPLICATION（空表，保未来启用零返工）。
--   CONCURRENTLY 刷新（需唯一索引；supplier_id/currency_id COALESCE 到 nil-uuid 避免空值破坏唯一性）。
--   规模：月(180) × 7 类型 × 活跃货品供应商组合 → 估算百万级行，查询毫秒级。
--   REFRESH 策略：每日 cron 全量 + 委外单据审核接口手动触发（调 refresh_subcontract_monthly_mv()）。
--
-- 17 张老库报表 → 新库查询路径（design doc 22 §6.1）：
--   明细报表 ×8 = 过滤 doc_type + ym + supplier + goods 的明细表查询；
--   汇总报表 ×8 = 本物化视图按维度上卷；
--   委外出入状况表 ×1 = 综合 JOIN（按 supplier×goods 汇总各类型流水，design doc 22 §6.3）。
-- =====================================================================

CREATE MATERIALIZED VIEW IF NOT EXISTS subcontract_monthly_mv AS
-- 委外询价（INQUIRY，空表·保结构）
SELECT 'INQUIRY'::text  AS doc_type,
       date_trunc('month', it.bill_date)::date AS ym,
       it.goods_id,
       COALESCE(o.supplier_id, '00000000-0000-0000-0000-000000000000'::uuid) AS supplier_id,
       COALESCE(o.currency_id, '00000000-0000-0000-0000-000000000000'::uuid) AS currency_id,
       SUM(it.qty)             AS qty_sum,
       SUM(it.amount_local)    AS amt_local,
       SUM(it.amount_original) AS amt_original,
       COUNT(*)                AS line_cnt
FROM subcontract_inquiry_items it
JOIN subcontract_inquiries o ON o.id = it.inquiry_id
WHERE it.is_deleted = false AND o.is_deleted = false AND o.status = 1
GROUP BY 1, 2, it.goods_id, o.supplier_id, o.currency_id
UNION ALL
-- 委外申请（APPLICATION，空表·保结构；applications 主表无 currency_id 列，按 design doc 22 §3.2）
SELECT 'APPLICATION'::text,
       date_trunc('month', it.bill_date)::date,
       it.goods_id,
       COALESCE(o.supplier_id, '00000000-0000-0000-0000-000000000000'::uuid),
       '00000000-0000-0000-0000-000000000000'::uuid,
       SUM(it.qty), SUM(it.amount_local), SUM(it.amount_original), COUNT(*)
FROM subcontract_application_items it
JOIN subcontract_applications o ON o.id = it.application_id
WHERE it.is_deleted = false AND o.is_deleted = false AND o.status = 1
GROUP BY 1, 2, it.goods_id, o.supplier_id
UNION ALL
-- 委外订货（ORDER，含 BOM 展开订货明细）
SELECT 'ORDER'::text,
       date_trunc('month', it.bill_date)::date,
       it.goods_id,
       COALESCE(o.supplier_id, '00000000-0000-0000-0000-000000000000'::uuid),
       COALESCE(o.currency_id, '00000000-0000-0000-0000-000000000000'::uuid),
       SUM(it.qty), SUM(it.amount_local), SUM(it.amount_original), COUNT(*)
FROM subcontract_order_items it
JOIN subcontract_orders o ON o.id = it.order_id
WHERE it.is_deleted = false AND o.is_deleted = false AND o.status = 1
GROUP BY 1, 2, it.goods_id, o.supplier_id, o.currency_id
UNION ALL
-- 委外进仓（RECEIPT，收回成品）
SELECT 'RECEIPT'::text,
       date_trunc('month', it.bill_date)::date,
       it.goods_id,
       COALESCE(o.supplier_id, '00000000-0000-0000-0000-000000000000'::uuid),
       COALESCE(o.currency_id, '00000000-0000-0000-0000-000000000000'::uuid),
       SUM(it.qty), SUM(it.amount_local), SUM(it.amount_original), COUNT(*)
FROM subcontract_receipt_items it
JOIN subcontract_receipts o ON o.id = it.receipt_id
WHERE it.is_deleted = false AND o.is_deleted = false AND o.status = 1
GROUP BY 1, 2, it.goods_id, o.supplier_id, o.currency_id
UNION ALL
-- 委外退货（RETURN，成品退）
SELECT 'RETURN'::text,
       date_trunc('month', it.bill_date)::date,
       it.goods_id,
       COALESCE(o.supplier_id, '00000000-0000-0000-0000-000000000000'::uuid),
       COALESCE(o.currency_id, '00000000-0000-0000-0000-000000000000'::uuid),
       SUM(it.qty), SUM(it.amount_local), SUM(it.amount_original), COUNT(*)
FROM subcontract_return_items it
JOIN subcontract_returns o ON o.id = it.return_id
WHERE it.is_deleted = false AND o.is_deleted = false AND o.status = 1
GROUP BY 1, 2, it.goods_id, o.supplier_id, o.currency_id
UNION ALL
-- 委外材料出仓（MATERIAL_ISSUE，发料；无币种，amt_original=amt_local）
SELECT 'MATERIAL_ISSUE'::text,
       date_trunc('month', it.bill_date)::date,
       it.goods_id,
       COALESCE(o.supplier_id, '00000000-0000-0000-0000-000000000000'::uuid),
       '00000000-0000-0000-0000-000000000000'::uuid,
       SUM(it.qty), SUM(it.amount_local), SUM(it.amount_local), COUNT(*)
FROM subcontract_material_issue_items it
JOIN subcontract_material_issues o ON o.id = it.issue_id
WHERE it.is_deleted = false AND o.is_deleted = false AND o.status = 1
GROUP BY 1, 2, it.goods_id, o.supplier_id
UNION ALL
-- 委外材料退货（MATERIAL_RETURN，材料退；无币种）
SELECT 'MATERIAL_RETURN'::text,
       date_trunc('month', it.bill_date)::date,
       it.goods_id,
       COALESCE(o.supplier_id, '00000000-0000-0000-0000-000000000000'::uuid),
       '00000000-0000-0000-0000-000000000000'::uuid,
       SUM(it.qty), SUM(it.amount_local), SUM(it.amount_local), COUNT(*)
FROM subcontract_material_return_items it
JOIN subcontract_material_returns o ON o.id = it.material_return_id
WHERE it.is_deleted = false AND o.is_deleted = false AND o.status = 1
GROUP BY 1, 2, it.goods_id, o.supplier_id
UNION ALL
-- 委外损耗（WASTE；无币种）
SELECT 'WASTE'::text,
       date_trunc('month', it.bill_date)::date,
       it.goods_id,
       COALESCE(o.supplier_id, '00000000-0000-0000-0000-000000000000'::uuid),
       '00000000-0000-0000-0000-000000000000'::uuid,
       SUM(it.qty), SUM(it.amount_local), SUM(it.amount_local), COUNT(*)
FROM subcontract_waste_items it
JOIN subcontract_wastes o ON o.id = it.waste_id
WHERE it.is_deleted = false AND o.is_deleted = false AND o.status = 1
GROUP BY 1, 2, it.goods_id, o.supplier_id;

-- 唯一索引（CONCURRENTLY 刷新所需；COALESCE 后全非 null，安全）
CREATE UNIQUE INDEX IF NOT EXISTS mv_subcontract_monthly_uidx
    ON subcontract_monthly_mv (doc_type, ym, goods_id, supplier_id, currency_id);
CREATE INDEX IF NOT EXISTS mv_subcontract_monthly_goods    ON subcontract_monthly_mv (goods_id);
CREATE INDEX IF NOT EXISTS mv_subcontract_monthly_supplier ON subcontract_monthly_mv (supplier_id);
CREATE INDEX IF NOT EXISTS mv_subcontract_monthly_ym       ON subcontract_monthly_mv (ym);
CREATE INDEX IF NOT EXISTS mv_subcontract_monthly_type     ON subcontract_monthly_mv (doc_type);

COMMENT ON MATERIALIZED VIEW subcontract_monthly_mv IS '委外月度聚合（询价/申请/订货/进仓/退货/发料/材料退/损耗 × 年月 × 货品 × 供应商 × 币种）；CONCURRENTLY 刷新';

-- 刷新函数（CONCURRENTLY 需唯一索引；审核接口/每日 cron 调用）
CREATE OR REPLACE FUNCTION refresh_subcontract_monthly_mv() RETURNS void AS $$
BEGIN
    REFRESH MATERIALIZED VIEW CONCURRENTLY subcontract_monthly_mv;
END;
$$ LANGUAGE plpgsql;
