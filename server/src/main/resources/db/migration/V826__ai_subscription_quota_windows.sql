-- V826: 套餐类服务商(GLM Coding Plan 等)的 5 小时/每周额度次数。
-- 服务商没有公开的额度查询接口; 全公司 AI 调用都走本平台网关并落在 ai_call_logs,
-- 已用次数按成功调用自动统计, 这里只补「套餐额度」两个配置列(次), 留空=未配置。
ALTER TABLE ai_providers
    ADD COLUMN IF NOT EXISTS billing_quota_5h integer,
    ADD COLUMN IF NOT EXISTS billing_quota_weekly integer;

COMMENT ON COLUMN ai_providers.billing_quota_5h IS '套餐每 5 小时额度(次); NULL=未配置';
COMMENT ON COLUMN ai_providers.billing_quota_weekly IS '套餐每周额度(次); NULL=未配置';
