-- 访客黑名单运营元数据：拉黑原因/时间/操作人（2026-09-18 黑名单 UI 首发配套）。
-- 解除拉黑时清空三个字段（历史留痕由 visitor_accounts 上的 fn_audit 触发器承载）。
ALTER TABLE visitor_accounts ADD COLUMN IF NOT EXISTS blocked_reason TEXT;
ALTER TABLE visitor_accounts ADD COLUMN IF NOT EXISTS blocked_at TIMESTAMPTZ;
ALTER TABLE visitor_accounts ADD COLUMN IF NOT EXISTS blocked_by UUID;

COMMENT ON COLUMN visitor_accounts.blocked_reason IS '拉黑原因（拉黑时必填，解除时清空）';
COMMENT ON COLUMN visitor_accounts.blocked_at IS '拉黑时间（status=blocked 时非空）';
COMMENT ON COLUMN visitor_accounts.blocked_by IS '拉黑操作人（users.id，解除时清空）';
