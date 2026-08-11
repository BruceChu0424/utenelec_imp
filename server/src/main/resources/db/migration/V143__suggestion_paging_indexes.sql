-- 建议箱长期分页与当前页互动统计。
--
-- 列表固定按 submitted_at DESC, id DESC，后缀 id 保证同一时间戳跨页不重不漏。
-- submitter/category 在等值过滤列之后排列，覆盖“我的建议”和类别筛选。
-- 点赞态只查询当前页 suggestion_id 集合，user_id 领先的复合索引可直接命中。

CREATE INDEX IF NOT EXISTS idx_suggestions_submitted_stable
    ON suggestions (submitted_at DESC, id DESC);

CREATE INDEX IF NOT EXISTS idx_suggestions_submitter_submitted_stable
    ON suggestions (submitter_id, submitted_at DESC, id DESC);

CREATE INDEX IF NOT EXISTS idx_suggestions_category_submitted_stable
    ON suggestions (category, submitted_at DESC, id DESC);

CREATE INDEX IF NOT EXISTS idx_suggestion_likes_user_suggestion
    ON suggestion_likes (user_id, suggestion_id);

-- 新复合索引完整覆盖旧单列索引，删除冗余副本以降低写放大和长期膨胀。
DROP INDEX IF EXISTS idx_suggestions_submitted;
DROP INDEX IF EXISTS idx_suggestions_submitter;
DROP INDEX IF EXISTS idx_suggestion_likes_user;
