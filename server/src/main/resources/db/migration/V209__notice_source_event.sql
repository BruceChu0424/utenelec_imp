-- V209: notices 新增 source_event 列——标记业务事件来源（如完工入库/报工审核），
-- 供按事件类型统计未读徽章（销售订单进度「完工提醒」=未读的完工事件通知数）。
-- NULL = 人工发布或非链路通知，不参与事件徽章统计。
ALTER TABLE notices
    ADD COLUMN IF NOT EXISTS source_event VARCHAR(80);

CREATE INDEX IF NOT EXISTS idx_notices_source_event
    ON notices (source_event)
    WHERE source_event IS NOT NULL;

COMMENT ON COLUMN notices.source_event IS
    '业务事件来源标记（如 PRODUCTION_FINISHED_INBOUND/PRODUCTION_REPORTED）；NULL=人工/非链路通知';
