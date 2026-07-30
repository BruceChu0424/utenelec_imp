-- V74：系统设置优化——令牌 TTL 改用户友好 + 会话空闲超时改名
-- --------------------------------------------------------------------------------
-- 管理员反馈「Access Token 有效期」「Refresh Token 有效期」是开发术语看不懂。
-- 处理：
--   ① access token TTL（15 分）：内部刷新参数，管理员无业务意义，且误调可能破坏刷新 → 移除
--      （代码 readInt 项缺失时返回默认 15，无需改代码）。
--   ② refresh token TTL（7 天）：=「登录能保持多久不输密码」，管理员可调 → 保留，改通俗名。
--   ③ session idle timeout（30 分）：=「无操作自动退出」→ 改通俗名。

DELETE FROM system_settings WHERE key = 'jwt_access_ttl_minutes';

UPDATE system_settings SET
  label = '登录保持时长',
  description = '登录后多少天内免重新输密码（超期需重新登录；access 令牌内部自动刷新，无需关注）'
WHERE key = 'jwt_refresh_ttl_days';

UPDATE system_settings SET
  label = '自动退出登录',
  description = '无操作多少分钟后自动退出账号（有操作自动续期；到时间弹窗提示后退出，需重新登录）'
WHERE key = 'session_idle_timeout_minutes';
