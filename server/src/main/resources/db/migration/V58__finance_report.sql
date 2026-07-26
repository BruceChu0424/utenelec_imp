-- =====================================================================
-- V58：钱流报表 · 月度上卷物化视图（finance_ar_ap_mv）
-- =====================================================================
-- 归属：钱流模块 V58（钱流报表 · 物化视图 + 刷新函数）。
--
-- 设计依据：docs/数据迁移/26-钱流管理-新库与迁移.md §6.1。
-- 老库 23 张钱流报表（应收应付类 10 / 收付款单据类 4 / 费用收入类 5 / 账户流水类 3 + 1 存疑）
--   SQL 不在 DB 视图（应用层水晶报表），口径只能从底层表+触发器语义重建。
-- 落地策略：物化视图（汇总类 Z/B/D/F/H/N/P）+ 参数化查询（明细类 X/A/C/E/G/I-L/M-O/S）。
--
-- finance_ar_ap_mv：应收应付月度上卷（月×方向×来源类型×客/供应商×币种）。
--   * 查询时按用户选定维度 GROUP BY 上卷（客户/供应商/月/账龄分桶…），起止日期按 ym 过滤。
--   * CONCURRENTLY 刷新（需唯一索引；party_id/currency_id COALESCE 到 nil-uuid 避免空值破坏唯一性，
--     同 V46 purchase_monthly_mv 范式）。
--   * 规模估算：月(180) × 方向(2) × 来源类型(8) × 活跃客/供应商(几百) → 几十万行，查询毫秒级。
--   * REFRESH 策略：每日 cron 全量 + 收款/付款审核接口手动触发（调 refresh_finance_ar_ap_mv()）。
--
-- 详见 docs/数据迁移/27-DDL一致性契约.md §一文件归属（V58 仅 finance_ar_ap_mv）、§八自检。
-- =====================================================================

CREATE MATERIALIZED VIEW IF NOT EXISTS finance_ar_ap_mv AS
SELECT date_trunc('month', bill_date)::date                  AS ym,
       direction,
       source_doc_type,
       COALESCE(client_id, supplier_id)                      AS party_id,
       COALESCE(currency_id, '00000000-0000-0000-0000-000000000000'::uuid) AS currency_id,
       COUNT(*)                                               AS entry_cnt,
       SUM(amount_original)                                   AS original_sum,
       SUM(amount_original_local)                             AS original_local_sum,
       SUM(amount_settled)                                    AS settled_sum,
       SUM(amount_balance)                                    AS balance_sum
FROM ar_ap_ledger
WHERE is_deleted = false AND status = 1
GROUP BY 1, 2, 3, 4, 5;

-- 唯一索引（CONCURRENTLY 刷新所需；COALESCE 后全非 null，安全）
CREATE UNIQUE INDEX IF NOT EXISTS mv_fin_ar_ap_uidx
    ON finance_ar_ap_mv (ym, direction, source_doc_type, party_id, currency_id);
CREATE INDEX IF NOT EXISTS mv_fin_ar_ap_ym     ON finance_ar_ap_mv (ym);
CREATE INDEX IF NOT EXISTS mv_fin_ar_ap_party  ON finance_ar_ap_mv (party_id);
CREATE INDEX IF NOT EXISTS mv_fin_ar_ap_dir    ON finance_ar_ap_mv (direction);
CREATE INDEX IF NOT EXISTS mv_fin_ar_ap_src    ON finance_ar_ap_mv (source_doc_type);

COMMENT ON MATERIALIZED VIEW finance_ar_ap_mv IS '应收应付月度上卷（月×方向×来源类型×客/供应商×币种）；钱流汇总报表加速，CONCURRENTLY 刷新';

-- 刷新函数（CONCURRENTLY 需唯一索引；审核接口/每日 cron 调用）
CREATE OR REPLACE FUNCTION refresh_finance_ar_ap_mv() RETURNS void AS $$
BEGIN
    REFRESH MATERIALIZED VIEW CONCURRENTLY finance_ar_ap_mv;
END;
$$ LANGUAGE plpgsql;
