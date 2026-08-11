-- =====================================================================
-- V127：生产计划 看板标记——置顶 / 重要
-- =====================================================================
-- 生产调度与进度看板（进行中/已完成 Tab）：用户可将计划卡片置顶（始终排最前）
-- 或标注重要（星标高亮）。标记存主表，全员可见、跨端一致。
-- =====================================================================

ALTER TABLE production_plans
    ADD COLUMN IF NOT EXISTS is_pinned    BOOLEAN NOT NULL DEFAULT FALSE,  -- 看板置顶
    ADD COLUMN IF NOT EXISTS is_important BOOLEAN NOT NULL DEFAULT FALSE;  -- 看板重要标注

COMMENT ON COLUMN production_plans.is_pinned    IS '看板置顶（V127）：进行中/已完成列表始终排最前';
COMMENT ON COLUMN production_plans.is_important IS '看板重要标注（V127）：卡片星标高亮';
