-- 2026-11-08 导出任务进度百分比: 读取开始时已算出的总行数随心跳一起记下, 客户端据此显示
-- 「已处理 N / 总数」与百分比。总数未知(文档类导出等)保持 NULL, 客户端显示扫动条, 不伪造。
-- 只增进度事实列, 不触碰身份/请求不可变字段(fn_guard_report_export_identity 不受影响)。
ALTER TABLE report_export_jobs ADD COLUMN total_rows bigint;
ALTER TABLE report_export_jobs ADD CONSTRAINT report_export_jobs_total_rows_check
    CHECK (total_rows IS NULL OR total_rows >= 0);
COMMENT ON COLUMN report_export_jobs.total_rows IS '读取开始时的权威总行数; NULL=总数未知(进度显示为不确定)';
