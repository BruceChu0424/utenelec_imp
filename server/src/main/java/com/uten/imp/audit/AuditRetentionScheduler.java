package com.uten.imp.audit;

import com.uten.imp.common.time.BusinessTime;
import lombok.extern.slf4j.Slf4j;
import org.springframework.beans.factory.annotation.Autowired;
import org.springframework.boot.autoconfigure.condition.ConditionalOnProperty;
import org.springframework.context.annotation.Profile;
import org.springframework.scheduling.annotation.Scheduled;
import org.springframework.stereotype.Component;

import javax.sql.DataSource;
import java.sql.Connection;
import java.sql.PreparedStatement;
import java.sql.ResultSet;
import java.sql.SQLException;
import java.sql.Timestamp;
import java.time.Clock;
import java.time.Duration;
import java.time.Instant;
import java.time.ZonedDateTime;

/**
 * Two-stage audit retention worker.
 *
 * <p>Expired online rows are copied to {@code audit_log_archive} and removed
 * from the queryable table in the same small transaction. Archive rows are
 * permanently deleted only after the additional archive period. A PostgreSQL
 * session advisory lock prevents duplicate work across application instances.
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

    static final int BATCH_SIZE = 5_000;
    static final int MAX_BATCHES_PER_RUN = 200;
    static final int MIN_HOT_MONTHS = 1;
    static final int MAX_HOT_MONTHS = 120;
    static final int MIN_ARCHIVE_MONTHS = 0;
    static final int MAX_ARCHIVE_MONTHS = 240;

    private static final long ADVISORY_LOCK_ID = 0x5554454E41554454L;
    private static final String ACQUIRE_LOCK_SQL =
            "SELECT pg_try_advisory_lock(?)";
    private static final String RELEASE_LOCK_SQL =
            "SELECT pg_advisory_unlock(?)";

    /**
     * The final SELECT returns both counts so each batch is one atomic
     * archive-confirm-delete statement. Newly inserted IDs travel through the
     * RETURNING CTE; pre-existing archive IDs are visible in the transaction
     * snapshot. A hot row can therefore never be deleted without a cold copy.
     */
    private static final String ARCHIVE_HOT_BATCH_SQL = """
            WITH candidates AS (
                SELECT hot.id
                FROM audit_log hot
                WHERE hot.created_at < ?
                ORDER BY hot.created_at, hot.id
                LIMIT ?
                FOR UPDATE OF hot SKIP LOCKED
            ),
            inserted AS (
                INSERT INTO audit_log_archive (
                    id, actor_id, actor_account, action, target_type, target_id,
                    "before", "after", ip, user_agent, result, created_at,
                    request_id, event_source, http_method, http_path,
                    status_code, duration_ms, risk_level, event_category,
                    client_event_id, device_installation_id, device_name,
                    device_manufacturer, device_model, device_platform,
                    device_os_version, app_version, app_build,
                    device_form_factor, device_browser, device_locale,
                    device_time_zone, device_time_zone_offset_minutes,
                    device_is_physical, client_event_at,
                    device_capture_status, device_profile_hash
                )
                SELECT
                    hot.id, hot.actor_id, hot.actor_account, hot.action,
                    hot.target_type, hot.target_id, hot."before", hot."after",
                    hot.ip, hot.user_agent, hot.result, hot.created_at,
                    hot.request_id, hot.event_source, hot.http_method,
                    hot.http_path, hot.status_code, hot.duration_ms,
                    hot.risk_level, hot.event_category,
                    hot.client_event_id, hot.device_installation_id,
                    hot.device_name, hot.device_manufacturer,
                    hot.device_model, hot.device_platform,
                    hot.device_os_version, hot.app_version, hot.app_build,
                    hot.device_form_factor, hot.device_browser,
                    hot.device_locale, hot.device_time_zone,
                    hot.device_time_zone_offset_minutes,
                    hot.device_is_physical, hot.client_event_at,
                    hot.device_capture_status, hot.device_profile_hash
                FROM audit_log hot
                JOIN candidates candidate ON candidate.id = hot.id
                ON CONFLICT (id) DO NOTHING
                RETURNING id
            ),
            safe_ids AS (
                SELECT id FROM inserted
                UNION
                SELECT candidate.id
                FROM candidates candidate
                JOIN audit_log_archive cold ON cold.id = candidate.id
            ),
            deleted AS (
                DELETE FROM audit_log hot
                USING safe_ids safe
                WHERE hot.id = safe.id
                RETURNING hot.id
            )
            SELECT
                (SELECT count(*) FROM inserted) AS archived_count,
                (SELECT count(*) FROM deleted) AS removed_count
            """;

    private static final String DELETE_ARCHIVE_BATCH_SQL = """
            WITH candidates AS (
                SELECT cold.ctid
                FROM audit_log_archive cold
                WHERE cold.created_at < ?
                ORDER BY cold.created_at, cold.id
                LIMIT ?
                FOR UPDATE OF cold SKIP LOCKED
            ),
            deleted AS (
                DELETE FROM audit_log_archive cold
                USING candidates candidate
                WHERE cold.ctid = candidate.ctid
                RETURNING cold.id
            )
            SELECT count(*) AS deleted_count FROM deleted
            """;

    private final DataSource dataSource;
    private final AuditRuntimeSettings settings;
    private final AuditService audit;
    private final Clock clock;

    @Autowired
    public AuditRetentionScheduler(
            DataSource dataSource,
            AuditRuntimeSettings settings,
            AuditService audit) {
        this(dataSource, settings, audit, Clock.systemUTC());
    }

    AuditRetentionScheduler(
            DataSource dataSource,
            AuditRuntimeSettings settings,
            AuditService audit,
            Clock clock) {
        this.dataSource = dataSource;
        this.settings = settings;
        this.audit = audit;
        this.clock = clock;
    }

    @Scheduled(
            cron = "${uten.audit.retention.cron:0 17 3 * * *}",
            zone = "Asia/Shanghai")
    public void runScheduled() {
        int hotMonths = -1;
        int archiveMonths = -1;
        Instant startedAt = clock.instant();
        try {
            hotMonths = settings.hotRetentionMonths();
            archiveMonths = settings.archiveRetentionMonths();
            validateSettings(hotMonths, archiveMonths);
            Cutoffs cutoffs = cutoffs(clock, hotMonths, archiveMonths);
            RetentionResult result = execute(cutoffs);
            if (!result.lockAcquired()) {
                log.debug("Audit retention skipped because another instance owns the lock");
                return;
            }
            long durationMillis = Math.max(
                    0, Duration.between(startedAt, clock.instant()).toMillis());
            String detail = "hotMonths=" + hotMonths
                    + "; archiveMonths=" + archiveMonths
                    + "; onlineArchived=" + result.archived()
                    + "; onlineRemoved=" + result.removedFromHot()
                    + "; permanentlyDeleted=" + result.deletedFromArchive()
                    + "; durationMs=" + durationMillis;
            log.info("Audit retention completed: {}", detail);
        } catch (Exception exception) {
            String detail = "hotMonths=" + hotMonths
                    + "; archiveMonths=" + archiveMonths
                    + "; error=" + truncate(exception.getMessage(), 400);
            auditFailureSafely(detail);
            log.error("Audit retention failed; no unarchived hot row is deleted", exception);
        }
    }

    RetentionResult execute(Cutoffs cutoffs) throws SQLException {
        try (Connection connection = dataSource.getConnection()) {
            connection.setAutoCommit(true);
            if (!tryAcquireLock(connection)) {
                return RetentionResult.skipped();
            }
            try {
                long archived = 0;
                long removedFromHot = 0;
                boolean hotLimitReached = false;
                for (int batch = 0; batch < MAX_BATCHES_PER_RUN; batch++) {
                    BatchResult current = archiveHotBatch(
                            connection, cutoffs.hotCutoff());
                    archived += current.archived();
                    removedFromHot += current.removed();
                    if (current.removed() < BATCH_SIZE) {
                        break;
                    }
                    hotLimitReached = batch == MAX_BATCHES_PER_RUN - 1;
                }

                long deletedFromArchive = 0;
                boolean archiveLimitReached = false;
                for (int batch = 0; batch < MAX_BATCHES_PER_RUN; batch++) {
                    int deleted = deleteArchiveBatch(
                            connection, cutoffs.archiveCutoff());
                    deletedFromArchive += deleted;
                    if (deleted < BATCH_SIZE) {
                        break;
                    }
                    archiveLimitReached = batch == MAX_BATCHES_PER_RUN - 1;
                }
                if (hotLimitReached || archiveLimitReached) {
                    log.warn(
                            "Audit retention reached its per-run batch cap; "
                                    + "remaining rows will continue next cycle "
                                    + "(hotCap={}, archiveCap={})",
                            hotLimitReached,
                            archiveLimitReached);
                }
                return new RetentionResult(
                        true, archived, removedFromHot, deletedFromArchive);
            } finally {
                releaseLock(connection);
            }
        }
    }

    private BatchResult archiveHotBatch(
            Connection connection,
            Instant cutoff) throws SQLException {
        connection.setAutoCommit(false);
        try (PreparedStatement statement =
                     connection.prepareStatement(ARCHIVE_HOT_BATCH_SQL)) {
            statement.setTimestamp(1, Timestamp.from(cutoff));
            statement.setInt(2, BATCH_SIZE);
            try (ResultSet rows = statement.executeQuery()) {
                if (!rows.next()) {
                    throw new SQLException("Audit archive batch returned no result");
                }
                BatchResult result = new BatchResult(
                        rows.getInt("archived_count"),
                        rows.getInt("removed_count"));
                connection.commit();
                return result;
            }
        } catch (SQLException exception) {
            rollbackSafely(connection, exception);
            throw exception;
        } finally {
            connection.setAutoCommit(true);
        }
    }

    private int deleteArchiveBatch(
            Connection connection,
            Instant cutoff) throws SQLException {
        connection.setAutoCommit(false);
        try (PreparedStatement statement =
                     connection.prepareStatement(DELETE_ARCHIVE_BATCH_SQL)) {
            statement.setTimestamp(1, Timestamp.from(cutoff));
            statement.setInt(2, BATCH_SIZE);
            try (ResultSet rows = statement.executeQuery()) {
                if (!rows.next()) {
                    throw new SQLException("Audit archive cleanup returned no result");
                }
                int result = rows.getInt("deleted_count");
                connection.commit();
                return result;
            }
        } catch (SQLException exception) {
            rollbackSafely(connection, exception);
            throw exception;
        } finally {
            connection.setAutoCommit(true);
        }
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
            log.error("Failed to write the audit-retention summary event", auditFailure);
        }
    }

    private static void validateSettings(int hotMonths, int archiveMonths) {
        if (hotMonths < MIN_HOT_MONTHS || hotMonths > MAX_HOT_MONTHS) {
            throw new IllegalStateException(
                    "audit_hot_retention_months must be between "
                            + MIN_HOT_MONTHS + " and " + MAX_HOT_MONTHS);
        }
        if (archiveMonths < MIN_ARCHIVE_MONTHS
                || archiveMonths > MAX_ARCHIVE_MONTHS) {
            throw new IllegalStateException(
                    "audit_archive_retention_months must be between "
                            + MIN_ARCHIVE_MONTHS + " and " + MAX_ARCHIVE_MONTHS);
        }
    }

    static Cutoffs cutoffs(Clock clock, int hotMonths, int archiveMonths) {
        ZonedDateTime now = ZonedDateTime.ofInstant(
                clock.instant(), BusinessTime.ZONE);
        return new Cutoffs(
                now.minusMonths(hotMonths).toInstant(),
                now.minusMonths((long) hotMonths + archiveMonths).toInstant());
    }

    private static void rollbackSafely(
            Connection connection,
            SQLException original) {
        try {
            connection.rollback();
        } catch (SQLException rollbackFailure) {
            original.addSuppressed(rollbackFailure);
        }
    }

    private static String truncate(String value, int maxLength) {
        String safe = value == null ? "unknown" : value;
        return safe.length() <= maxLength
                ? safe
                : safe.substring(0, maxLength);
    }

    record Cutoffs(Instant hotCutoff, Instant archiveCutoff) {}

    private record BatchResult(int archived, int removed) {}

    record RetentionResult(
            boolean lockAcquired,
            long archived,
            long removedFromHot,
            long deletedFromArchive) {

        static RetentionResult skipped() {
            return new RetentionResult(false, 0, 0, 0);
        }
    }
}
