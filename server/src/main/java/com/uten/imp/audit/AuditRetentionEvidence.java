package com.uten.imp.audit;

import org.springframework.jdbc.core.JdbcTemplate;
import org.springframework.stereotype.Component;

import java.sql.Timestamp;
import java.time.Instant;
import java.util.Optional;

/**
 * 审计留存的持久证据(ADR-105): 最近一次 {@code audit_retention_completed} 系统事件的时间。
 * 服务器状态页用它显示「最近一次成功归档」, 重启后也不丢。
 */
@Component
public class AuditRetentionEvidence {

    private static final String LAST_COMPLETED_SQL = """
            SELECT max(created_at)
            FROM audit_log
            WHERE target_type = 'audit_retention'
              AND action = 'audit_retention_completed'
              AND event_source = 'system'
            """;

    private final JdbcTemplate jdbc;

    public AuditRetentionEvidence(JdbcTemplate jdbc) {
        this.jdbc = jdbc;
    }

    public Optional<Instant> lastCompletedAt() {
        Timestamp value = jdbc.queryForObject(LAST_COMPLETED_SQL, Timestamp.class);
        return Optional.ofNullable(value).map(Timestamp::toInstant);
    }
}
