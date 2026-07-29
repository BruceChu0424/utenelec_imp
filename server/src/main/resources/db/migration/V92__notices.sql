-- =====================================================================
-- V92：通知模块（公司广播 + 每用户已读/删除状态）
-- =====================================================================
-- 背景：通知此前全是前端 Mock（mock_notice_repository），现接真实后端。
-- 设计：
--   notices            通知本体（广播型，一条记录全员可见）
--   notice_user_states 每用户状态（已读 read_at / 删除 deleted_at）——
--                      删除是「从自己列表移除」的微信式语义，不影响他人。
-- 权限：notice:read（employee 角色自带）读写自己的状态；
--       notice:publish（HR/管理员）发布通知。
-- =====================================================================

CREATE TABLE IF NOT EXISTS notices (
    id            UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    title         TEXT        NOT NULL,
    content       TEXT        NOT NULL,
    type          TEXT        NOT NULL,           -- announcement/policy/benefit/system/urgent/task/approval/workflow
    publisher     TEXT        NOT NULL,           -- 发布人姓名快照（发布后改名不回溯）
    published_at  TIMESTAMPTZ NOT NULL DEFAULT now(),
    top_priority  BOOLEAN     NOT NULL DEFAULT false,
    priority      TEXT        NOT NULL DEFAULT 'normal',  -- normal/important/urgent
    attachments   JSONB       NOT NULL DEFAULT '[]',
    created_at    TIMESTAMPTZ NOT NULL DEFAULT now(),
    created_by    UUID
);

CREATE INDEX IF NOT EXISTS idx_notices_published ON notices(published_at DESC);

CREATE TABLE IF NOT EXISTS notice_user_states (
    notice_id  UUID NOT NULL REFERENCES notices(id) ON DELETE CASCADE,
    user_id    UUID NOT NULL REFERENCES users(id)   ON DELETE CASCADE,
    read_at    TIMESTAMPTZ,
    deleted_at TIMESTAMPTZ,
    PRIMARY KEY (notice_id, user_id)
);

CREATE INDEX IF NOT EXISTS idx_notice_user_states_user ON notice_user_states(user_id);
