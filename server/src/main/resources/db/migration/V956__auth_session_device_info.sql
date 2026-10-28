-- 单设备顶号可追溯（2026-10-27）：登录时记录本会话的设备名（客户端自报，仅用于
-- 「账号已在哪台设备登录」的提示与排查，不是安全边界）；顶号撤销旧会话时把新登录
-- 设备名快照到被撤销的会话行上，供刷新接口向被顶设备返回明确的下线原因。
ALTER TABLE auth_sessions ADD COLUMN device_info text;
ALTER TABLE auth_sessions ADD COLUMN replaced_by_device text;
