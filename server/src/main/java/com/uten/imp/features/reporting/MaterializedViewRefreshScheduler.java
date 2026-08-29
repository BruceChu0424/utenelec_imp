package com.uten.imp.features.reporting;

import lombok.extern.slf4j.Slf4j;
import org.springframework.boot.autoconfigure.condition.ConditionalOnProperty;
import org.springframework.beans.factory.annotation.Autowired;
import org.springframework.context.annotation.Profile;
import org.springframework.scheduling.annotation.Scheduled;
import org.springframework.stereotype.Component;

import javax.sql.DataSource;
import java.net.InetAddress;
import java.sql.Connection;
import java.sql.PreparedStatement;
import java.sql.ResultSet;
import java.sql.SQLException;
import java.sql.Statement;
import java.time.Clock;
import java.time.Duration;
import java.time.Instant;
import java.util.List;

/**
 * Keeps reporting materialized views fresh without blocking readers.
 *
 * <p>A session-level PostgreSQL advisory lock ensures that only one application
 * instance performs the refresh cycle. Views are refreshed independently so a
 * problem in one report does not leave every other report stale.
 */
@Slf4j
@Component
@Profile("!cloud")
@ConditionalOnProperty(
        prefix = "uten.reporting.materialized-view-refresh",
        name = "enabled",
        havingValue = "true",
        matchIfMissing = true)
public class MaterializedViewRefreshScheduler {

    static final List<String> REPORT_VIEWS = List.of(
            "finance_ar_ap_mv",
            "production_monthly_mv",
            "purchase_monthly_mv",
            "sales_monthly_mv",
            "stock_monthly_mv",
            "subcontract_monthly_mv");

    private static final long ADVISORY_LOCK_ID = 0x5554454E52455054L;
    private static final int MAX_ERROR_LENGTH = 2000;

    private static final String ACQUIRE_LOCK_SQL = "SELECT pg_try_advisory_lock(?)";
    private static final String RELEASE_LOCK_SQL = "SELECT pg_advisory_unlock(?)";
    private static final String MARK_RUNNING_SQL = """
            INSERT INTO report_materialized_view_refresh_state
                (view_name, status, last_started_at, last_error, refreshed_by)
            VALUES (?, 'RUNNING', CURRENT_TIMESTAMP, NULL, ?)
            ON CONFLICT (view_name) DO UPDATE
            SET status = 'RUNNING',
                last_started_at = EXCLUDED.last_started_at,
                last_error = NULL,
                refreshed_by = EXCLUDED.refreshed_by
            """;
    private static final String MARK_SUCCESS_SQL = """
            UPDATE report_materialized_view_refresh_state
            SET status = 'SUCCESS',
                last_succeeded_at = CURRENT_TIMESTAMP,
                last_duration_ms = ?,
                last_error = NULL,
                refreshed_by = ?
            WHERE view_name = ?
            """;
    private static final String MARK_FAILED_SQL = """
            UPDATE report_materialized_view_refresh_state
            SET status = 'FAILED',
                last_failed_at = CURRENT_TIMESTAMP,
                last_duration_ms = ?,
                last_error = ?,
                refreshed_by = ?
            WHERE view_name = ?
            """;

    private final DataSource dataSource;
    private final Clock clock;
    private final String instanceId;

    @Autowired
    public MaterializedViewRefreshScheduler(DataSource dataSource) {
        this(dataSource, Clock.systemUTC(), resolveInstanceId());
    }

    MaterializedViewRefreshScheduler(DataSource dataSource, Clock clock, String instanceId) {
        this.dataSource = dataSource;
        this.clock = clock;
        this.instanceId = instanceId;
    }

    @Scheduled(
            fixedDelayString = "${uten.reporting.materialized-view-refresh.interval-ms:300000}",
            initialDelayString = "${uten.reporting.materialized-view-refresh.initial-delay-ms:60000}")
    public void refreshAll() {
        try (Connection connection = dataSource.getConnection()) {
            connection.setAutoCommit(true);
            if (!tryAcquireLock(connection)) {
                log.debug("Materialized-view refresh skipped because another instance owns the lock");
                return;
            }

            try {
                long cycleStartedNanos = System.nanoTime();
                int refreshed = 0;
                for (String viewName : REPORT_VIEWS) {
                    if (refreshOne(connection, viewName)) {
                        refreshed++;
                    }
                }
                long elapsedMillis = (System.nanoTime() - cycleStartedNanos) / 1_000_000L;
                // 全部成功：一行日志都不打（每 5 分钟一轮，纯噪音；dev 环境 DEBUG 也
                // 开着，降级别没用）。运行状态随时查 report_materialized_view_refresh_state
                // 表。失败由 refreshOne 记 error；部分失败补一条 warn 汇总，
                // 避免只看到单条 error 不知道整轮受影响面。
                if (refreshed < REPORT_VIEWS.size()) {
                    log.warn(
                            "物化视图刷新部分失败 {}/{}，总耗时 {} ms(明细见上方 error 日志)",
                            refreshed, REPORT_VIEWS.size(), elapsedMillis);
                }
            } finally {
                releaseLock(connection);
            }
        } catch (SQLException exception) {
            log.error("Materialized-view refresh cycle could not obtain a database connection", exception);
        }
    }

    private boolean refreshOne(Connection connection, String viewName) {
        Instant startedAt = clock.instant();
        try {
            markRunning(connection, viewName);
            try (Statement statement = connection.createStatement()) {
                // viewName comes exclusively from the immutable allowlist above.
                statement.execute("REFRESH MATERIALIZED VIEW CONCURRENTLY " + viewName);
            }
            long durationMillis = elapsedMillis(startedAt);
            markSuccess(connection, viewName, durationMillis);
            return true;
        } catch (SQLException exception) {
            long durationMillis = elapsedMillis(startedAt);
            markFailureSafely(connection, viewName, durationMillis, exception);
            log.error("Failed to refresh materialized view {}", viewName, exception);
            return false;
        }
    }

    private boolean tryAcquireLock(Connection connection) throws SQLException {
        try (PreparedStatement statement = connection.prepareStatement(ACQUIRE_LOCK_SQL)) {
            statement.setLong(1, ADVISORY_LOCK_ID);
            try (ResultSet result = statement.executeQuery()) {
                return result.next() && result.getBoolean(1);
            }
        }
    }

    private void releaseLock(Connection connection) {
        try (PreparedStatement statement = connection.prepareStatement(RELEASE_LOCK_SQL)) {
            statement.setLong(1, ADVISORY_LOCK_ID);
            statement.executeQuery().close();
        } catch (SQLException exception) {
            log.error("Failed to release the materialized-view advisory lock", exception);
        }
    }

    private void markRunning(Connection connection, String viewName) throws SQLException {
        try (PreparedStatement statement = connection.prepareStatement(MARK_RUNNING_SQL)) {
            statement.setString(1, viewName);
            statement.setString(2, instanceId);
            statement.executeUpdate();
        }
    }

    private void markSuccess(Connection connection, String viewName, long durationMillis)
            throws SQLException {
        try (PreparedStatement statement = connection.prepareStatement(MARK_SUCCESS_SQL)) {
            statement.setLong(1, durationMillis);
            statement.setString(2, instanceId);
            statement.setString(3, viewName);
            statement.executeUpdate();
        }
    }

    private void markFailureSafely(
            Connection connection,
            String viewName,
            long durationMillis,
            SQLException refreshFailure) {
        String error = truncate(refreshFailure.getMessage());
        try (PreparedStatement statement = connection.prepareStatement(MARK_FAILED_SQL)) {
            statement.setLong(1, durationMillis);
            statement.setString(2, error);
            statement.setString(3, instanceId);
            statement.setString(4, viewName);
            statement.executeUpdate();
        } catch (SQLException stateFailure) {
            refreshFailure.addSuppressed(stateFailure);
            log.error("Could not persist refresh failure state for {}", viewName, stateFailure);
        }
    }

    private long elapsedMillis(Instant startedAt) {
        return Math.max(0, Duration.between(startedAt, clock.instant()).toMillis());
    }

    private static String truncate(String value) {
        String safeValue = value == null ? "Unknown database error" : value;
        return safeValue.length() <= MAX_ERROR_LENGTH
                ? safeValue
                : safeValue.substring(0, MAX_ERROR_LENGTH);
    }

    private static String resolveInstanceId() {
        String hostname;
        try {
            hostname = InetAddress.getLocalHost().getHostName();
        } catch (Exception ignored) {
            hostname = "unknown-host";
        }
        return hostname + ':' + ProcessHandle.current().pid();
    }
}
