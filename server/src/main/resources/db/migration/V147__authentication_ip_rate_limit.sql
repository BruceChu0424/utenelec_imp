-- 主体低阈值防爆破；IP 粗桶使用独立高阈值，避免园区 NAT/运营商 CGNAT 用户共用 5 次桶。
INSERT INTO system_settings (
    key,
    value,
    value_type,
    category,
    label,
    description,
    unit,
    sort_order
) VALUES (
    'login_ip_rate_limit_per_minute',
    '300',
    'int',
    'security',
    '鉴权 IP 粗限流',
    '员工登录、访客发码和访客登录各自每 IP 每分钟上限；应显著高于单主体阈值',
    '次/分',
    11
)
ON CONFLICT (key) DO NOTHING;

UPDATE system_settings
SET label = '登录主体限流',
    description = '每个登录账号或规范化手机号在每个鉴权入口每分钟允许的尝试次数'
WHERE key = 'login_rate_limit_per_minute';
