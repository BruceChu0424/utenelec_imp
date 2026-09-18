-- V601：办结即已读 —— 存量回填
-- 2026-09-18 口径：审核待办通知被办结撤回（resolved_at 置位）后，对每个接收人
-- 也应视为已读，不再以未读形式滞留通知页与未读角标。应用侧
-- NoticeService.resolveReviewNotices 已改为撤回同时置 read_at；本迁移把历史上
-- 已办结但仍未读的行一次性补齐（幂等：已读不回退，已删除的列表项不复活）。

INSERT INTO notice_user_states (notice_id, user_id, read_at)
SELECT notice.id, notice.audience_user_id, now()
FROM notices notice
WHERE notice.resolved_at IS NOT NULL
  AND notice.audience_user_id IS NOT NULL
ON CONFLICT (notice_id, user_id) DO UPDATE
SET read_at = COALESCE(notice_user_states.read_at, EXCLUDED.read_at)
WHERE notice_user_states.deleted_at IS NULL;
