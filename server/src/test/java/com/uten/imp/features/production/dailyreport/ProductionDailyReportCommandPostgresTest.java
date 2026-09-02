package com.uten.imp.features.production.dailyreport;

import org.flywaydb.core.Flyway;
import org.junit.jupiter.api.AfterAll;
import org.junit.jupiter.api.BeforeAll;
import org.junit.jupiter.api.Test;
import org.junit.jupiter.api.condition.EnabledIfEnvironmentVariable;
import org.postgresql.util.PSQLException;
import org.testcontainers.containers.PostgreSQLContainer;

import java.sql.Connection;
import java.sql.DriverManager;
import java.sql.PreparedStatement;
import java.sql.ResultSet;
import java.time.Duration;
import java.time.LocalDate;
import java.util.UUID;
import java.util.concurrent.CountDownLatch;
import java.util.concurrent.ExecutorService;
import java.util.concurrent.Executors;
import java.util.concurrent.Future;
import java.util.concurrent.TimeUnit;
import java.util.concurrent.atomic.AtomicInteger;

import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertFalse;
import static org.junit.jupiter.api.Assertions.assertThrows;
import static org.junit.jupiter.api.Assertions.assertTimeoutPreemptively;
import static org.junit.jupiter.api.Assertions.assertTrue;

/** PostgreSQL proof for V409 command serialization, append-only history and CAS. */
@EnabledIfEnvironmentVariable(named = "UTEN_RUN_DB_TESTS", matches = "(?i)true")
class ProductionDailyReportCommandPostgresTest {

    private static final PostgreSQLContainer<?> POSTGRES =
            new PostgreSQLContainer<>("postgres:16-alpine")
                    .withDatabaseName("uten_imp")
                    .withUsername("uten")
                    .withPassword("uten");
    private static final AtomicInteger BUSINESS_SEQUENCE = new AtomicInteger();
    private static UUID actorUserId;

    @BeforeAll
    static void migrateAndSeedActor() throws Exception {
        POSTGRES.start();
        Flyway.configure()
                .dataSource(
                        POSTGRES.getJdbcUrl(),
                        POSTGRES.getUsername(),
                        POSTGRES.getPassword())
                .locations("classpath:db/migration")
                .target("408")
                .load()
                .migrate();
        UUID legacyReportId = UUID.randomUUID();
        try (Connection connection = connection()) {
            insertReport(connection, legacyReportId, "legacy-before-v409");
        }
        Flyway.configure()
                .dataSource(
                        POSTGRES.getJdbcUrl(),
                        POSTGRES.getUsername(),
                        POSTGRES.getPassword())
                .locations("classpath:db/migration")
                .load()
                .migrate();
        assertEquals(0, count("""
                SELECT row_version
                FROM production_daily_reports
                WHERE id=?
                """, legacyReportId));
        assertEquals(0, count(
                "SELECT count(*) FROM production_daily_report_commands"));

        try (Connection connection = connection()) {
            UUID departmentId = scalarUuid(connection, """
                    SELECT id FROM departments
                    WHERE is_deleted=FALSE ORDER BY code LIMIT 1
                    """);
            UUID employeeId = UUID.randomUUID();
            actorUserId = UUID.randomUUID();
            update(connection, """
                    INSERT INTO employees(
                        id,code,full_name,id_type,department_id,hire_date,
                        status,employment_type)
                    VALUES(?,?,?,'其他',?,?,'active','regular')
                    """, employeeId, "V409-E-" + employeeId,
                    "V409 command actor", departmentId,
                    LocalDate.of(2026, 8, 28));
            update(connection, """
                    INSERT INTO users(
                        id,employee_id,login_account,password_hash,status)
                    VALUES(?,?,?,?,'active')
                    """, actorUserId, employeeId,
                    "v409-" + actorUserId, "test-only-hash");
        }
    }

    @AfterAll
    static void stopPostgres() {
        POSTGRES.stop();
    }

    @Test
    void concurrentSameActorKeySerializesAndReturnsOneReport() {
        assertTimeoutPreemptively(Duration.ofSeconds(15), () -> {
            String key = "v409-concurrent-" + UUID.randomUUID();
            String hash = "a".repeat(64);
            CountDownLatch firstHasLock = new CountDownLatch(1);
            CountDownLatch allowFirstCommit = new CountDownLatch(1);
            CountDownLatch secondReachedLock = new CountDownLatch(1);
            CountDownLatch secondHasLock = new CountDownLatch(1);
            try (ExecutorService executor = Executors.newFixedThreadPool(2)) {
                Future<UUID> first = executor.submit(() -> createOrReplay(
                        key, hash, firstHasLock, allowFirstCommit, null));
                assertTrue(firstHasLock.await(5, TimeUnit.SECONDS));

                Future<UUID> second = executor.submit(() -> createOrReplay(
                        key, hash, secondHasLock, null, secondReachedLock));
                assertTrue(secondReachedLock.await(5, TimeUnit.SECONDS));
                assertFalse(
                        secondHasLock.await(500, TimeUnit.MILLISECONDS),
                        "the second create must wait on actor+key advisory lock");

                allowFirstCommit.countDown();
                UUID firstId = first.get(5, TimeUnit.SECONDS);
                UUID secondId = second.get(5, TimeUnit.SECONDS);
                assertEquals(firstId, secondId);
                assertEquals(1, count("""
                        SELECT count(*)
                        FROM production_daily_report_commands
                        WHERE actor_user_id=? AND idempotency_key=?
                        """, actorUserId, key));
                assertEquals(1, count("""
                        SELECT count(*)
                        FROM production_daily_reports
                        WHERE remark=?
                        """, "V409:" + key));
            } finally {
                allowFirstCommit.countDown();
            }
        });
    }

    @Test
    void commandAndReportRollbackTogetherAndCommandHistoryIsAppendOnly()
            throws Exception {
        String rollbackKey = "v409-rollback-" + UUID.randomUUID();
        UUID rolledBackReport = UUID.randomUUID();
        try (Connection connection = connection()) {
            connection.setAutoCommit(false);
            insertReport(connection, rolledBackReport, rollbackKey);
            insertCommand(
                    connection, rollbackKey, "b".repeat(64), rolledBackReport);
            connection.rollback();
        }
        assertEquals(0, count("""
                SELECT count(*) FROM production_daily_report_commands
                WHERE actor_user_id=? AND idempotency_key=?
                """, actorUserId, rollbackKey));
        assertEquals(0, count(
                "SELECT count(*) FROM production_daily_reports WHERE id=?",
                rolledBackReport));

        String appendOnlyKey = "v409-append-" + UUID.randomUUID();
        UUID reportId = UUID.randomUUID();
        try (Connection connection = connection()) {
            insertReport(connection, reportId, appendOnlyKey);
            insertCommand(
                    connection, appendOnlyKey, "c".repeat(64), reportId);
        }
        // V424 审计降噪：幂等指令表是命令去重记录，与请求级审计行重复，
        // 其插入不再挂审计触发器；业务事实仍由报表本体的审计触发器留痕。
        assertEquals(0, count("""
                SELECT count(*) FROM audit_log
                WHERE target_type='production_daily_report_commands'
                """), "idempotent command rows must stay out of trigger audit");
        assertTrue(count("""
                SELECT count(*) FROM audit_log
                WHERE target_type='production_daily_reports'
                """) >= 1, "accepted report insert must be audited");
        try (Connection connection = connection()) {
            PSQLException update = assertThrows(
                    PSQLException.class,
                    () -> update(connection, """
                            UPDATE production_daily_report_commands
                            SET request_hash=?
                            WHERE actor_user_id=? AND idempotency_key=?
                            """, "d".repeat(64), actorUserId, appendOnlyKey));
            assertEquals("55000", update.getSQLState());
        }
        try (Connection connection = connection()) {
            PSQLException delete = assertThrows(
                    PSQLException.class,
                    () -> update(connection, """
                            DELETE FROM production_daily_report_commands
                            WHERE actor_user_id=? AND idempotency_key=?
                            """, actorUserId, appendOnlyKey));
            assertEquals("55000", delete.getSQLState());
        }
    }

    @Test
    void reportRowVersionAdvancesExactlyOnceAndStaleCasWritesNothing()
            throws Exception {
        String key = "v409-version-" + UUID.randomUUID();
        UUID reportId = UUID.randomUUID();
        try (Connection connection = connection()) {
            insertReport(connection, reportId, key);
            assertEquals(1, update(connection, """
                    UPDATE production_daily_reports
                    SET remark='first', row_version=row_version+1
                    WHERE id=? AND row_version=0
                    """, reportId));
            assertEquals(0, update(connection, """
                    UPDATE production_daily_reports
                    SET remark='stale', row_version=row_version+1
                    WHERE id=? AND row_version=0
                    """, reportId));
        }
        try (Connection connection = connection()) {
            PSQLException missingIncrement = assertThrows(
                    PSQLException.class,
                    () -> update(connection, """
                            UPDATE production_daily_reports
                            SET remark='illegal'
                            WHERE id=?
                            """, reportId));
            assertEquals("23514", missingIncrement.getSQLState());
        }
        assertEquals(1, count("""
                SELECT row_version FROM production_daily_reports WHERE id=?
                """, reportId));
    }

    private static UUID createOrReplay(
            String key,
            String hash,
            CountDownLatch acquired,
            CountDownLatch releaseBeforeCommit,
            CountDownLatch reachedLock) throws Exception {
        try (Connection connection = connection()) {
            connection.setAutoCommit(false);
            if (reachedLock != null) reachedLock.countDown();
            try (PreparedStatement lock = connection.prepareStatement("""
                    SELECT pg_advisory_xact_lock(
                        hashtextextended(?, CAST(409 AS bigint)))
                    """)) {
                lock.setString(
                        1, "PRODUCTION-DAILY-REPORT-CREATE:"
                                + actorUserId + ":" + key);
                lock.executeQuery();
            }
            acquired.countDown();
            UUID existing = commandReportId(connection, key, hash);
            if (existing != null) {
                connection.commit();
                return existing;
            }

            UUID reportId = UUID.randomUUID();
            insertReport(connection, reportId, key);
            insertCommand(connection, key, hash, reportId);
            if (releaseBeforeCommit != null
                    && !releaseBeforeCommit.await(5, TimeUnit.SECONDS)) {
                throw new IllegalStateException("timed out before first commit");
            }
            connection.commit();
            return reportId;
        }
    }

    private static UUID commandReportId(
            Connection connection, String key, String expectedHash)
            throws Exception {
        try (PreparedStatement statement = connection.prepareStatement("""
                SELECT request_hash, report_id
                FROM production_daily_report_commands
                WHERE actor_user_id=? AND idempotency_key=?
                """)) {
            statement.setObject(1, actorUserId);
            statement.setString(2, key);
            try (ResultSet rows = statement.executeQuery()) {
                if (!rows.next()) return null;
                if (!expectedHash.equals(rows.getString(1))) {
                    throw new IllegalStateException("same key has different hash");
                }
                return rows.getObject(2, UUID.class);
            }
        }
    }

    private static void insertReport(
            Connection connection, UUID reportId, String key) throws Exception {
        update(connection, """
                INSERT INTO production_daily_reports(
                    id,bill_no,bill_date,status,remark)
                VALUES(?,?,?,0,?)
                """, reportId, businessIdentifier(),
                LocalDate.of(2026, 8, 28), "V409:" + key);
    }

    private static void insertCommand(
            Connection connection,
            String key,
            String hash,
            UUID reportId) throws Exception {
        update(connection, """
                INSERT INTO production_daily_report_commands(
                    id,actor_user_id,idempotency_key,request_hash,
                    report_id,created_by)
                VALUES(?,?,?,?,?,?)
                """, UUID.randomUUID(), actorUserId, key, hash,
                reportId, actorUserId);
    }

    private static int count(String sql, Object... values) throws Exception {
        try (Connection connection = connection();
             PreparedStatement statement = connection.prepareStatement(sql)) {
            bind(statement, values);
            try (ResultSet rows = statement.executeQuery()) {
                rows.next();
                return rows.getInt(1);
            }
        }
    }

    private static int update(
            Connection connection, String sql, Object... values)
            throws Exception {
        try (PreparedStatement statement = connection.prepareStatement(sql)) {
            bind(statement, values);
            return statement.executeUpdate();
        }
    }

    private static UUID scalarUuid(Connection connection, String sql)
            throws Exception {
        try (PreparedStatement statement = connection.prepareStatement(sql);
             ResultSet rows = statement.executeQuery()) {
            if (!rows.next()) throw new IllegalStateException("fixture row missing");
            return rows.getObject(1, UUID.class);
        }
    }

    private static void bind(
            PreparedStatement statement, Object... values) throws Exception {
        for (int index = 0; index < values.length; index++) {
            statement.setObject(index + 1, values[index]);
        }
    }

    private static String businessIdentifier() {
        int sequence = BUSINESS_SEQUENCE.incrementAndGet();
        return "SR20260828%06d".formatted(sequence);
    }

    private static Connection connection() throws Exception {
        return DriverManager.getConnection(
                POSTGRES.getJdbcUrl(),
                POSTGRES.getUsername(),
                POSTGRES.getPassword());
    }
}
