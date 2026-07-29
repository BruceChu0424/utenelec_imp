-- =====================================================================
-- V96：建议箱模块（建议 + 回复 + 点赞）
-- =====================================================================
-- 背景：建议箱此前全是前端 Mock（mock_suggestion_repository），现接真实后端。
-- 设计（对照 notice 模块 ADR-016 模式）：
--   suggestions        建议本体（提交人快照 + 匿名标记 + 状态机）
--   suggestion_replies 官方回复（人事/管理层，可顺带推进状态）
--   suggestion_likes   点赞（每用户一票，复合主键）
-- 审计列：实体继承 BaseEntity（AuditableEntity 四审计列），建表一次带全
--   （V94 教训：缺 updated_at/updated_by 会卡 Hibernate schema-validation）。
-- 权限：suggestion:submit（employee 全员基础包）提交/点赞；
--       suggestion:reply 回复 + 推进状态。
-- =====================================================================

CREATE TABLE IF NOT EXISTS suggestions (
    id             UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    submitter_id   UUID        NOT NULL REFERENCES users(id),
    submitter_name TEXT        NOT NULL,           -- 提交人姓名快照（匿名时服务端脱敏返回）
    category       TEXT        NOT NULL,           -- product/process/welfare/environment/equipment/other
    title          TEXT        NOT NULL,
    content        TEXT        NOT NULL,
    status         TEXT        NOT NULL DEFAULT 'submitted',  -- submitted/reviewing/resolved/rejected
    is_anonymous   BOOLEAN     NOT NULL DEFAULT false,
    submitted_at   TIMESTAMPTZ NOT NULL DEFAULT now(),
    created_at     TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_at     TIMESTAMPTZ NOT NULL DEFAULT now(),
    created_by     UUID,
    updated_by     UUID
);

CREATE INDEX IF NOT EXISTS idx_suggestions_submitted ON suggestions(submitted_at DESC);
CREATE INDEX IF NOT EXISTS idx_suggestions_submitter ON suggestions(submitter_id);

CREATE TABLE IF NOT EXISTS suggestion_replies (
    id            UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    suggestion_id UUID        NOT NULL REFERENCES suggestions(id) ON DELETE CASCADE,
    replier_id    UUID        NOT NULL REFERENCES users(id),
    replier_name  TEXT        NOT NULL,            -- 回复人姓名快照
    replier_role  TEXT        NOT NULL DEFAULT '', -- 回复人部门/角色快照（展示用）
    content       TEXT        NOT NULL,
    replied_at    TIMESTAMPTZ NOT NULL DEFAULT now(),
    created_at    TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_at    TIMESTAMPTZ NOT NULL DEFAULT now(),
    created_by    UUID,
    updated_by    UUID
);

CREATE INDEX IF NOT EXISTS idx_suggestion_replies_sug ON suggestion_replies(suggestion_id);

CREATE TABLE IF NOT EXISTS suggestion_likes (
    suggestion_id UUID        NOT NULL REFERENCES suggestions(id) ON DELETE CASCADE,
    user_id       UUID        NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    created_at    TIMESTAMPTZ NOT NULL DEFAULT now(),
    PRIMARY KEY (suggestion_id, user_id)
);

CREATE INDEX IF NOT EXISTS idx_suggestion_likes_user ON suggestion_likes(user_id);
