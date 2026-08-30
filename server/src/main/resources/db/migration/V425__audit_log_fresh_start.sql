-- V425: 审计日志全新开始。
--
-- 背景：审计日志刚完成降噪（V424）与全面中文化改造，历史行里遗留了大量
-- 系统噪音（notice_user_states 触发行等）和旧格式英文摘要，对核查没有价值。
-- 按管理者要求清空全部审计记录（含冷归档 audit_log_archive），并让自增 ID
-- 从 1 重新开始，新格式从零积累。
--
-- 说明：
--   1. 本迁移只动 audit_log / audit_log_archive 两张表；业务数据不受影响。
--   2. 新库/离线 bootstrap 目标库本来就没有审计历史，TRUNCATE 为空操作。
--   3. 各端本机操作回执（DeviceAuditStore）是客户端本地数据，不受影响；
--      清空后"核对本机回执"会提示未找到服务器记录，属预期。
--   4. 之后的第一条审计记录（通常为每日保留任务的 delete audit_retention 行）
--      将获得 id=1。

TRUNCATE TABLE audit_log, audit_log_archive RESTART IDENTITY;
