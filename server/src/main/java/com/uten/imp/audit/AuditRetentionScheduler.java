package com.uten.imp.audit;

import lombok.extern.slf4j.Slf4j;
import org.springframework.boot.autoconfigure.condition.ConditionalOnProperty;
import org.springframework.context.annotation.Profile;
import org.springframework.scheduling.annotation.Scheduled;
import org.springframework.stereotype.Component;

import javax.sql.DataSource;
import java.sql.Array;
import java.sql.Connection;
import java.sql.PreparedStatement;
import java.sql.ResultSet;
import java.sql.SQLException;
import java.util.List;

/**
 * 审计留存任务(ADR-105)。
 *
 * <p>audit_log / audit_log_archive 按北京时间月分区。每天由数据库函数
 * {@code fn_audit_retention_run()} 以表所有者身份一次完成: 整月都早于在线截止点的分区
 * DETACH 后 ATTACH 到归档表, 整月都早于最终截止点的归档分区直接 DROP, 预建之后 3 个月的在线分区,
 * 并在同一事务里写一条 {@code audit_retention_completed} 系统事件(截止点、分区、行数)。
 * 保留期由函数直接读系统设置 audit_hot_retention_months / audit_archive_retention_months,
 * 运行账号对审计表没有改删权限。不再 5000 行一批地复制和删除。
 *
 * <p>失败时独立写一条 {@code audit_retention_failed} 事件并把异常抛给调度器, 服务器状态页
 * 据此显示失败; 多实例之间用会话级咨询锁只让一个实例执行。
 */
@Slf4j
@Component
@Profile("!cloud")
@ConditionalOnProperty(
        prefix = "uten.audit.retention",
        name = "enabled",
        havingValue = "true",
        matchIfMissing = true)
public class AuditRetentionScheduler {

    private static final long ADVISORY_LOCK_ID = 0x5554454E41554454L;
    private static final String ACQUIRE_LOCK_SQL = "SELECT pg_try_advisory_lock(?)";
    private static final String RELEASE_LOCK_SQL = "SELECT pg_advisory_unlock(?)";
    private static final String RUN_SQL = """
            SELECT hot_months, archive_months, hot_cutoff, archive_cutoff,
                   archived_partitions, archived_rows, dropped_partitions, dropped_rows,
                   created_partitions, completion_event_id
            FROM fn_audit_retention_run()
            """;

    private final DataSource dataSource;
    private final AuditService audit;

    public AuditRetentionScheduler(DataSource dataSource, AuditService audit) {
        this.dataSource = dataSource;
        this.audit = audit;
    }

    @Scheduled(
            cron = "${uten.audit.retention.cron:0 17 3 * * *}",
            zone = "Asia/Shanghai")
    public void runScheduled() {
        try {
            RetentionResult result = execute();
            if (!result.lockAcquired()) {
                log.debug("Audit retention skipped because another instance owns the lock");
                return;
            }
            log.info("Audit retention completed: hotMonths={}, archiveMonths={}, archived={} rows in {}, "
                            + "dropped={} rows in {}, created={}, event={}",
                    result.hotMonths(), result.archiveMonths(), result.archivedRows(),
                    result.archivedPartitions(), result.droppedRows(), result.droppedPartitions(),
                    result.createdPartitions(), result.completionEventId());
        } catch (SQLException | RuntimeException exception) {
            auditFailureSafely("error=" + truncate(exception.getMessage(), 400));
            log.error("Audit retention failed; partitions are moved only as whole months", exception);
            throw new IllegalStateException("审计日志归档与清理失败", exception);
        }
    }

    RetentionResult execute() throws SQLException {
        try (Connection connection = dataSource.getConnection()) {
            connection.setAutoCommit(true);
            if (!tryAcquireLock(connection)) {
                return RetentionResult.skipped();
            }
            try (PreparedStatement statement = connection.prepareStatement(RUN_SQL);
                 ResultSet rows = statement.executeQuery()) {
                if (!rows.next()) {
                    throw new SQLException("Audit retention returned no summary row");
                }
                return new RetentionResult(
                        true,
                        rows.getInt("hot_months"),
                        rows.getInt("archive_months"),
                        texts(rows.getArray("archived_partitions")),
                        rows.getLong("archived_rows"),
                        texts(rows.getArray("dropped_partitions")),
                        rows.getLong("dropped_rows"),
                        texts(rows.getArray("created_partitions")),
                        rows.getLong("completion_event_id"));
            } finally {
                releaseLock(connection);
            }
        }
    }

    private static List<String> texts(Array array) throws SQLException {
        if (array == null) {
            return List.of();
        }
        Object value = array.getArray();
        return value instanceof String[] names ? List.of(names) : List.of();
    }

    private boolean tryAcquireLock(Connection connection) throws SQLException {
        try (PreparedStatement statement =
                     connection.prepareStatement(ACQUIRE_LOCK_SQL)) {
            statement.setLong(1, ADVISORY_LOCK_ID);
            try (ResultSet rows = statement.executeQuery()) {
                return rows.next() && rows.getBoolean(1);
            }
        }
    }

    private void releaseLock(Connection connection) {
        try (PreparedStatement statement =
                     connection.prepareStatement(RELEASE_LOCK_SQL)) {
            statement.setLong(1, ADVISORY_LOCK_ID);
            try (ResultSet ignored = statement.executeQuery()) {
                // Session lock released before the pooled connection is returned.
            }
        } catch (SQLException exception) {
            log.error("Failed to release the audit-retention advisory lock", exception);
        }
    }

    private void auditFailureSafely(String detail) {
        try {
            audit.logExplicit(
                    null,
                    "system",
                    "audit_retention_failed",
                    "audit_retention",
                    truncate(detail, 1_000),
                    "failure");
        } catch (RuntimeException auditFailure) {
            log.error("Failed to write the audit-retention failure event", auditFailure);
        }
    }

    private static String truncate(String value, int maxLength) {
        String safe = value == null ? "unknown" : value;
        return safe.length() <= maxLength
                ? safe
                : safe.substring(0, maxLength);
    }

    record RetentionResult(
            boolean lockAcquired,
            int hotMonths,
            int archiveMonths,
            List<String> archivedPartitions,
            long archivedRows,
            List<String> droppedPartitions,
            long droppedRows,
            List<String> createdPartitions,
            long completionEventId) {

        static RetentionResult skipped() {
            return new RetentionResult(false, 0, 0, List.of(), 0, List.of(), 0, List.of(), 0);
        }
    }
}
