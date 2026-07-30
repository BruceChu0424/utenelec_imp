-- V72：系统设置（运行时可配的安全/业务策略阈值）
-- --------------------------------------------------------------------------------
-- 背景：原本硬编码在 SecurityProperties / JwtProperties / SmsProperties + 导出上限 100_000 的
-- 「次数/时长/阈值」类参数，管理员无法在线调整。提到 DB 持久化，供「系统设置」页可视化配置。
--
-- 范围：只放**运行时可生效的策略阈值**（安全/令牌/短信/业务 共 11 项）。
--   不纳入：密钥类（jwt.secret / crypto / sms AK——改了涉密钥/重启）、
--   部署类（CORS / swagger / DB / legacy——启动时定）。
--
-- 默认值与 application.yml 一致；改后立即生效（SystemSettingsService 不缓存，每次 findById）。

CREATE TABLE system_settings (
    key         TEXT PRIMARY KEY,
    value       TEXT NOT NULL,
    value_type  TEXT NOT NULL DEFAULT 'int',   -- int / long / string / bool
    category    TEXT NOT NULL,                  -- security / token / sms / business
    label       TEXT NOT NULL,                  -- 中文显示名
    description TEXT,                           -- 说明（UI 提示）
    unit        TEXT,                           -- 单位（次/分 / 分钟 / 天 / 秒 / 行 …）
    sort_order  INT  NOT NULL DEFAULT 0,
    updated_at  TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_by  UUID
);

COMMENT ON TABLE system_settings IS '系统设置（运行时可配的安全/业务策略阈值；密钥与部署类不在表内）';

-- 触发器：updated_at 自动维护（与 fn_audit 同类的 set_updated_at，若已有则复用）
CREATE OR REPLACE FUNCTION fn_set_updated_at() RETURNS trigger AS $$
BEGIN NEW.updated_at = now(); RETURN NEW; END; $$ LANGUAGE plpgsql;
CREATE TRIGGER trg_system_settings_updated BEFORE UPDATE ON system_settings
    FOR EACH ROW EXECUTE FUNCTION fn_set_updated_at();

-- 种子：11 个可配设置（默认值同 application.yml）
INSERT INTO system_settings (key, value, value_type, category, label, description, unit, sort_order) VALUES
    -- 安全策略
    ('login_rate_limit_per_minute', '5',     'int',  'security', '登录限流',         '每 IP 每分钟最多尝试登录次数（防爆破）',     '次/分', 10),
    ('lockout_threshold',           '5',     'int',  'security', '账号锁定阈值',     '连续登录失败几次后锁定账号',                 '次',    20),
    ('lockout_minutes',             '15',    'int',  'security', '锁定时长',         '账号锁定多少分钟后自动解锁',                 '分钟',  30),
    ('password_history_size',       '5',     'int',  'security', '密码历史回溯',     '改密码时禁止复用最近 N 个历史密码',          '个',    40),
    ('export_rate_limit_per_minute','10',    'int',  'security', '导出限流',         '每用户每分钟最多导出次数（防拖库）',         '次/分', 50),
    -- 登录令牌
    ('jwt_access_ttl_minutes',      '15',    'long', 'token',    'Access Token 有效期',  '登录访问令牌有效期（过期需 refresh 或重登）', '分钟', 110),
    ('jwt_refresh_ttl_days',        '7',     'long', 'token',    'Refresh Token 有效期', '刷新令牌有效期（过期需重新登录）',           '天',    120),
    -- 短信验证（访客端）
    ('sms_code_ttl_minutes',        '5',     'int',  'sms',      '验证码有效期', '短信验证码有效时长',                         '分钟',  210),
    ('sms_send_interval_seconds',   '60',    'int',  'sms',      '短信发送间隔', '同一手机号两次发送的最小间隔',               '秒',    220),
    ('sms_daily_limit',             '10',    'int',  'sms',      '每日短信上限', '同一手机号每日最多发送条数',                 '条',    230),
    -- 业务限制
    ('export_max_rows',             '100000','int',  'business', '导出行数上限', '单次导出最大行数（超限拒绝，防 OOM/拖库）',   '行',    310)
ON CONFLICT (key) DO NOTHING;
