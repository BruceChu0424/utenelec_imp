-- B3-W2: 业务 Outbox 大载荷无损分层 + 永久防重身份。
--
-- 现状：business_outbox 的 dedupe_key 唯一索引承担永久防重；status=1（已送达）行
-- 连同完整 payload JSONB 永久累积在热表（07 方案「成功载荷可瘦身，精简防重身份保留」未落地）。
--
-- 本迁移：
--   1) business_outbox_payload_history：已送达事件的完整载荷无损迁出（md5 供完整性核对）；
--   2) 热表只加 payload_archived_at 标记列（无默认值，元数据级），分层后热行 payload 置 '{}'；
--      防重身份（dedupe_key/event_type/aggregate）不动、唯一索引不动、status=0/2 永不触碰；
--   3) v_business_outbox_full 视图：热行 + 生效载荷（未分层=热载荷，已分层=历史载荷），
--      等价比较/诊断查询统一读它，跨层语义与分层前一致；
--   4) V440 fn_guard_procurement_iqc_failure_detection 改为经历史层取检测载荷：
--      旧单更正 failed_base_qty 时，已分层的检测事件仍能对上 FAIL 事实，不误拦业务。
--
-- 分层由应用侧每日低峰任务执行（同事务 INSERT history + UPDATE 热行，崩溃可重放幂等）。

CREATE TABLE business_outbox_payload_history (
    outbox_id   UUID PRIMARY KEY,
    dedupe_key  VARCHAR(240) NOT NULL,
    payload     JSONB NOT NULL,
    payload_md5 CHAR(32) NOT NULL,
    archived_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    archived_by TEXT NOT NULL DEFAULT 'system:outbox-payload-tiering'
);

CREATE INDEX idx_business_outbox_payload_history_dedupe
    ON business_outbox_payload_history(dedupe_key);

COMMENT ON TABLE business_outbox_payload_history IS
    '已送达业务事件的大载荷无损分层：防重身份仍在 business_outbox 热行，此处只保存完整原文；'
    '分层与热行清空同事务，崩溃可重放；status=0/2 事件永不迁入';
COMMENT ON COLUMN business_outbox_payload_history.payload_md5 IS
    'md5(payload::text)，分层时的完整性指纹，用于历史层自核对';

ALTER TABLE business_outbox ADD COLUMN payload_archived_at TIMESTAMPTZ;

COMMENT ON COLUMN business_outbox.payload_archived_at IS
    '非空=完整载荷已无损分层至 business_outbox_payload_history，热行 payload 为空对象；'
    '防重等价比较与诊断读取经 v_business_outbox_full 自动取回历史载荷';

-- 生效载荷视图：分层前后读取语义一致（等价比较、反审依赖事实、诊断）。
CREATE VIEW v_business_outbox_full AS
SELECT b.id,
       b.event_type,
       b.aggregate_type,
       b.aggregate_id,
       b.dedupe_key,
       b.status,
       b.attempts,
       b.available_at,
       b.processed_at,
       b.last_error,
       b.created_by,
       b.created_at,
       (h.outbox_id IS NOT NULL) AS payload_archived,
       COALESCE(h.payload, b.payload) AS payload
FROM business_outbox b
LEFT JOIN business_outbox_payload_history h ON h.outbox_id = b.id;

COMMENT ON VIEW v_business_outbox_full IS
    '业务事件统一读取层：热行身份 + 生效载荷（未分层取热表，已分层取历史层）；'
    '认领/投递仍读 business_outbox 原表（只涉及 status=0/2，载荷必在）';

-- V440 检测守卫改走统一读取层：检测事件送达并分层后，
-- 旧质检单更正 failed_base_qty 重新校验时仍能按载荷对上 FAIL 事实。
CREATE OR REPLACE FUNCTION fn_guard_procurement_iqc_failure_detection()
RETURNS trigger
LANGUAGE plpgsql
AS $$
DECLARE
    v_failed_events NUMERIC(18,4);
    v_missing_detection BIGINT;
BEGIN
    IF NEW.status='REVERSED'
       OR NEW.failed_base_qty<=COALESCE(OLD.failed_base_qty,0) THEN
        RETURN NULL;
    END IF;
    SELECT COALESCE(SUM(event.base_qty),0),
           COUNT(*) FILTER(WHERE detection.id IS NULL)
      INTO v_failed_events,v_missing_detection
    FROM procurement_inspection_events event
    LEFT JOIN (
        SELECT id, payload
        FROM v_business_outbox_full
        WHERE event_type='PROCUREMENT_IQC_REJECTION_DETECTED'
          AND aggregate_id=NEW.id
    ) detection
      ON detection.payload->>'inspectionEventId'=event.id::TEXT
    WHERE event.inspection_item_id=NEW.id
      AND event.action='FAIL';
    IF v_failed_events<>NEW.failed_base_qty OR v_missing_detection<>0 THEN
        RAISE EXCEPTION USING ERRCODE='23514',
            MESSAGE='IQC failed quantity requires one durable detection event per FAIL fact',
            CONSTRAINT='procurement_iqc_failure_detection_guard';
    END IF;
    RETURN NULL;
END;
$$;

SELECT fn_audit_track_table('business_outbox_payload_history','NONE','system',true);
