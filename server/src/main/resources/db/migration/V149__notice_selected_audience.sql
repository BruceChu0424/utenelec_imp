-- V149：人工发布通知支持「全员 / 多部门 + 多人员」接收范围。
--
-- selected 模式在发布时把部门子树与显式人员解析为 users.id，并预创建
-- notice_user_states 行；这些空状态行同时充当不可变的接收人快照。
-- 后续调岗不会改变历史通知可见性，read_at / deleted_at 仍保持原有每用户语义。

ALTER TABLE notices
    ADD COLUMN IF NOT EXISTS audience_scope TEXT NOT NULL DEFAULT 'all',
    ADD COLUMN IF NOT EXISTS audience_summary TEXT NOT NULL DEFAULT '全体员工',
    ADD COLUMN IF NOT EXISTS audience_count INTEGER,
    ADD COLUMN IF NOT EXISTS target_department_ids JSONB NOT NULL DEFAULT '[]',
    ADD COLUMN IF NOT EXISTS target_employee_ids JSONB NOT NULL DEFAULT '[]';

-- V95 的单用户定向通知迁移到统一 selected 语义，并补齐接收人状态快照。
UPDATE notices
SET audience_scope = 'selected',
    audience_summary = '指定人员',
    audience_count = 1,
    target_employee_ids = '[]'::jsonb
WHERE audience_user_id IS NOT NULL;

INSERT INTO notice_user_states (notice_id, user_id)
SELECT id, audience_user_id
FROM notices
WHERE audience_user_id IS NOT NULL
ON CONFLICT (notice_id, user_id) DO NOTHING;

ALTER TABLE notices
    DROP CONSTRAINT IF EXISTS ck_notices_audience_scope;

ALTER TABLE notices
    ADD CONSTRAINT ck_notices_audience_scope
    CHECK (audience_scope IN ('all', 'selected'));

CREATE INDEX IF NOT EXISTS idx_notices_audience_scope_published
    ON notices(audience_scope, published_at DESC);
