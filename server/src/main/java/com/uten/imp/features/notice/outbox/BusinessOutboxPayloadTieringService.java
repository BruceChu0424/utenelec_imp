package com.uten.imp.features.notice.outbox;

import org.springframework.beans.factory.annotation.Value;
import org.springframework.jdbc.core.JdbcTemplate;
import org.springframework.stereotype.Service;
import org.springframework.transaction.annotation.Transactional;

import java.util.List;

/**
 * 业务 Outbox 大载荷无损分层（B3）。
 *
 * <p>已送达（status=1）超过保留天数的事件，把完整 payload 原文迁入
 * {@code business_outbox_payload_history}，热行只留永久防重身份
 * （dedupe_key/event_type/aggregate）并把 payload 置空对象。分层与热行清空
 * 同一事务：崩溃可整批重放，重复执行幂等（payload_archived_at 过滤）。
 *
 * <p>不触碰的边界：status=0（待处理）与 status=2（死信）事件永不迁入；
 * 防重等价比较、反审依赖事实与 IQC 检测守卫统一读
 * {@code v_business_outbox_full}，跨层语义与分层前一致。
 */
@Service
public class BusinessOutboxPayloadTieringService {

    private final JdbcTemplate jdbc;
    private final int minAgeDays;
    private final int batchSize;
    private final int maxRowsPerRun;

    public BusinessOutboxPayloadTieringService(
            JdbcTemplate jdbc,
            @Value("${uten.outbox.payload-tiering.min-age-days:90}") int minAgeDays,
            @Value("${uten.outbox.payload-tiering.batch-size:500}") int batchSize,
            @Value("${uten.outbox.payload-tiering.max-rows-per-run:5000}") int maxRowsPerRun) {
        this.jdbc = jdbc;
        this.minAgeDays = Math.max(1, minAgeDays);
        this.batchSize = Math.max(1, Math.min(batchSize, 5_000));
        this.maxRowsPerRun = Math.max(batchSize, Math.min(maxRowsPerRun, 50_000));
    }

    /**
     * 单批分层：认领（FOR UPDATE SKIP LOCKED）→ 历史层 INSERT（md5 随行）→
     * 热行 payload 置空并打标。返回本批迁出条数；0 表示没有可分层行。
     */
    @Transactional
    public int archiveBatch() {
        List<java.util.UUID> ids = jdbc.queryForList("""
                SELECT id
                FROM business_outbox
                WHERE status = 1
                  AND processed_at < now() - make_interval(days => ?)
                  AND payload_archived_at IS NULL
                ORDER BY processed_at, id
                LIMIT ?
                FOR UPDATE SKIP LOCKED
                """, java.util.UUID.class, minAgeDays, batchSize);
        if (ids.isEmpty()) {
            return 0;
        }
        String placeholders = String.join(",", java.util.Collections.nCopies(ids.size(), "?"));
        // 防重身份仍以热表 dedupe_key 为准；历史层再存一份键便于按键追溯与核对。
        jdbc.update("""
                INSERT INTO business_outbox_payload_history(outbox_id, dedupe_key, payload, payload_md5)
                SELECT id, dedupe_key, payload, md5(payload::text)
                FROM business_outbox
                WHERE id IN (%s)
                """.formatted(placeholders), ids.toArray());
        jdbc.update("""
                UPDATE business_outbox
                SET payload = '{}'::jsonb, payload_archived_at = now()
                WHERE id IN (%s)
                  AND payload_archived_at IS NULL
                """.formatted(placeholders), ids.toArray());
        return ids.size();
    }

    /** 当前仍滞留热层、已满足分层年龄的载荷行数（新鲜度/进度观测用）。 */
    public long pendingEligibleCount() {
        Long count = jdbc.queryForObject("""
                SELECT count(*)
                FROM business_outbox
                WHERE status = 1
                  AND processed_at < now() - make_interval(days => ?)
                  AND payload_archived_at IS NULL
                """, Long.class, minAgeDays);
        return count == null ? 0 : count;
    }

    /** 已分层载荷行数与历史层字节量（容量观测用）。 */
    public long archivedCount() {
        Long count = jdbc.queryForObject(
                "SELECT count(*) FROM business_outbox_payload_history", Long.class);
        return count == null ? 0 : count;
    }

    int batchSize() {
        return batchSize;
    }

    int maxRowsPerRun() {
        return maxRowsPerRun;
    }
}
