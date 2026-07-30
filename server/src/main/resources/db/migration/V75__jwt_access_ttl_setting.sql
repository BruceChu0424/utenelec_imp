-- V75：重新开放「登录令牌有效期（access token TTL）」为系统设置可选项
-- --------------------------------------------------------------------------------
-- 背景：V74 曾删除 jwt_access_ttl_minutes（理由：开发术语、误调怕破坏刷新）。但 15 分钟的短
-- access TTL 叠加「过期 token 被默认返 403」（已在 SecurityConfig 修为 401）之外，本身也让活跃
-- 用户每 15 分钟触发一次刷新，体验不佳。管理员要求可自定义时长（默认 8 小时），后续自行调整。
--
-- 设计：
--   * JwtService.issueAccess/getAccessTtlSeconds 已 readLong("jwt_access_ttl_minutes", 15)，
--     本迁移落库后自动按 DB 值生效（默认 480 分钟 = 8 小时），后端零代码改动。
--   * SystemSettingsService.validate 对本 key 加最小值 5 校验（防误设 0/1 致登录即过期）。
--   * 安全权衡：access TTL 变长 → token 泄露可滥用窗口变长；由 idle timeout（30 分钟无操作登出）
--     + refresh 重用检测 + 可调短 三重兜底。详见 ADR-013 与会话超时修复计划。

INSERT INTO system_settings (key, value, value_type, category, label, description, unit, sort_order) VALUES
    ('jwt_access_ttl_minutes', '480', 'long', 'token', '登录令牌有效期',
     '登录后多久内无需重新验证（期间自动续期；建议 480=8 小时；过短会频繁刷新影响体验，最小 5）',
     '分钟', 115)
ON CONFLICT (key) DO NOTHING;
