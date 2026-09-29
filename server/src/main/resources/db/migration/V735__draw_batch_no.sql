-- V735 领料单批次号 draw_batch_no(2026-09-27)。
--
-- 背景: 车间从「我的车间任务」一次批量领料会提交多张 DRAW 单(备料阶段按
-- 工单×实际仓各自建单、各自 SL 单号)，仓库无法看出这些单是同一个人同一批领的。
-- 用户口径「这几个领料单号能不能一样，仓库就知道是一个人领料」。
--
-- 单据行在生产链 immutable 守卫(V164)下不可跨单搬移，合并成一张单不可行；
-- 这里给 stock_documents 加可空列 draw_batch_no：批量领料提交时整批写同一个
-- 批次号(取本批最小 bill_no，不另设取号序列)，仓库待领任务按批次识别同批。
-- V164 守卫按列举字段拦截，新列不在清单内，UPDATE 放行。
-- 单张领料(车间任务单行「去领料」)同样走 submit 端点，单张也会写批次号(=自身单号)，
-- 语义一致：draw_batch_no 恒表示「最近一次批量领料提交的批次锚点」。

ALTER TABLE stock_documents ADD COLUMN draw_batch_no text;
COMMENT ON COLUMN stock_documents.draw_batch_no IS
    'DRAW 领料单批次锚点：同一车间任务批量领料提交的多张单写同一批次号(取本批最小单号)，供仓库识别同批；NULL=尚未经批量领料提交';
