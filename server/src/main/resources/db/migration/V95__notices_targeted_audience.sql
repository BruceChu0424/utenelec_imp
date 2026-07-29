-- V95：notices 支持定向投递（单用户可见）
-- 背景：V92 通知为纯广播（全员可见），但 approval/task/workflow 类通知天然是个人业务结果
-- （如「您的信息修改申请已批准/驳回」），广播会泄露他人隐私。
-- audience_user_id IS NULL = 广播（原语义）；非空 = 仅该用户可见（列表/未读数/详情全部过滤）。

ALTER TABLE notices
    ADD COLUMN IF NOT EXISTS audience_user_id UUID REFERENCES users(id);

CREATE INDEX IF NOT EXISTS idx_notices_audience ON notices(audience_user_id);
