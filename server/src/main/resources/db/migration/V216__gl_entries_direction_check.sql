-- =====================================================================
-- V216 · gl_entries.direction 数据完整性 CHECK 约束（FIN-P2-1）
-- =====================================================================
-- 背景：gl_entries.direction 此前仅在应用层（GlPostingService）写入时约束为 1/-1，
-- 数据库层无防护；历史数据或绕过 Service 的写入可能出现 direction=0 或其它值，
-- 破坏报表 SUM(direction*amount) 的借贷核算。
--
-- 仅约束 direction（必须 1=借 / -1=贷）。
-- **不**给 amount 加 CHECK(>=0)：负数 amount 是文档化的红字（红冲/退货）约定——
-- 见 V122 gl_entries.amount 列注释「正数；负值业务用红字（同向负金额）不反向」，
-- 报表（GlReportService）以 SUM(direction*amount) 计入净额，依赖负数表达反向业务。
-- 加 CHECK(>=0) 会破坏 SALES_RETURN/PURCHASE_RETURN 的红字立帐（postAr/postAp）。
-- 详见 FIN-P2-3 调研结论。
-- =====================================================================

ALTER TABLE gl_entries
    ADD CONSTRAINT gl_entries_direction_chk CHECK (direction IN (-1, 1));

COMMENT ON CONSTRAINT gl_entries_direction_chk ON gl_entries IS
    'direction 仅允许 1(借) / -1(贷)；amount 允许负数（红字约定，见 V122 列注释）';
