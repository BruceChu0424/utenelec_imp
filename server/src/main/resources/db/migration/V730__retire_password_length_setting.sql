-- 员工密码统一只要求非空，退出已失效的最短长度设置。
-- 只删除该配置，不改账号哈希、密码历史或任何已应用迁移。
DELETE FROM system_settings WHERE key = 'password_min_length';
