-- =====================================================================
-- V951：库存/应收应付月度物化视图退出周期刷新（B2）
-- =====================================================================
-- stock_monthly_mv 与 finance_ar_ap_mv 在应用代码中没有任何读取方
-- （全仓核对：仅 MaterializedViewRefreshScheduler 周期刷新、遗留导入
-- 脚本与 V915 封存的 business_data_reset 引用）。它们每 5 分钟对
-- stock_movements / ar_ap_ledger 做全量 CONCURRENTLY 重算，是纯常驻
-- 成本。B2 起：
--   · 调度器（MaterializedViewRefreshScheduler.REPORT_VIEWS）不再刷新
--     这两张视图，只保留销售/采购/生产/委外四张仍有读者的过渡视图；
--   · 库存月度口径由 V949 stock_monthly_summaries（触发器增量、可重建、
--     有完整性断言）承接；往来期间口径由 V950 party_monthly_summaries 承接；
--   · 视图对象本身保留：遗留导入脚本收尾与封存的隔离开发重置入口仍会
--     自行 REFRESH 它们，此后即为冻结诊断快照，不代表实时数据。
-- report_materialized_view_refresh_state 中两行历史状态保留原事实，
-- 不回填、不删除。回退路径：代码回退后调度器即恢复刷新，无破坏性变更。
-- =====================================================================

COMMENT ON MATERIALIZED VIEW stock_monthly_mv IS
    'Frozen diagnostic projection since V951 (B2): no application reader; live monthly stock statistics live in stock_monthly_summaries (trigger-maintained, rebuildable). Only refreshed by legacy import finishers or the sealed reset entry';
COMMENT ON MATERIALIZED VIEW finance_ar_ap_mv IS
    'Frozen diagnostic projection since V951 (B2): no application reader; party-period reporting uses party_monthly_summaries. Only refreshed by legacy import finishers or the sealed reset entry';
