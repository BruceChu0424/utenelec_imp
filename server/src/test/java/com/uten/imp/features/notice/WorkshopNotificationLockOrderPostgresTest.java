package com.uten.imp.features.notice;

import com.uten.imp.support.MigratedProjectionSchema;
import org.junit.jupiter.api.AfterAll;
import org.junit.jupiter.api.BeforeAll;
import org.junit.jupiter.api.Test;
import org.junit.jupiter.api.condition.EnabledIfEnvironmentVariable;
import org.springframework.jdbc.core.JdbcTemplate;
import org.springframework.jdbc.datasource.SingleConnectionDataSource;
import org.testcontainers.postgresql.PostgreSQLContainer;

import java.sql.Connection;
import java.sql.DriverManager;
import java.sql.SQLException;
import java.util.List;
import java.util.UUID;
import java.util.concurrent.CountDownLatch;
import java.util.concurrent.Executors;
import java.util.concurrent.TimeUnit;
import java.util.concurrent.atomic.AtomicInteger;
import static org.assertj.core.api.Assertions.assertThat;
import static org.assertj.core.api.Assertions.assertThatThrownBy;

/** Exercises the actual projection prelock SQL against the foreground draw row-lock order. */
@EnabledIfEnvironmentVariable(named="UTEN_RUN_DB_TESTS", matches="(?i)true")
class WorkshopNotificationLockOrderPostgresTest {
    private static final PostgreSQLContainer PG = new PostgreSQLContainer("postgres:16-alpine");
    private static final UUID FIRST = UUID.fromString("00000000-0000-0000-0000-000000000011");
    private static final UUID SECOND = UUID.fromString("00000000-0000-0000-0000-000000000022");

    @BeforeAll
    static void prepare() throws SQLException {
        PG.start();
        try (var connection = open()) {
            MigratedProjectionSchema.createCurrentTables(jdbc(connection),
                    "production_planning_packages", "production_execution_segments");
        }
        insert(FIRST, FIRST); insert(SECOND, SECOND);
    }

    @AfterAll
    static void stop() { PG.stop(); }

    @Test
    void reversePlanEventOrderCannotHoldTheSecondSegmentWhileWaitingForTheFirst() throws Exception {
        try (var foreground = open(); var workers = Executors.newSingleThreadExecutor()) {
            foreground.setAutoCommit(false);
            lock(foreground, FIRST);
            int foregroundPid = pid(foreground);
            var workerPid = new AtomicInteger();
            var started = new CountDownLatch(1);
            var projection = workers.submit(() -> {
                try (var connection = open()) {
                    connection.setAutoCommit(false);
                    workerPid.set(pid(connection)); started.countDown();
                    var frozen = ChainNoticeService.lockWorkshopSegmentsForPlans(
                            jdbc(connection), List.of(SECOND, FIRST));
                    connection.commit();
                    return frozen;
                }
            });
            assertThat(started.await(5, TimeUnit.SECONDS)).isTrue();
            awaitBlockedBy(workerPid.get(), foregroundPid);
            // The former per-plan loop held SECOND here, forming the confirmed 40P01 cycle.
            // The actual production prelock waits on FIRST before acquiring SECOND.
            lock(foreground, SECOND);
            foreground.commit();
            assertThat(projection.get(15, TimeUnit.SECONDS))
                    .containsEntry(FIRST, List.of(FIRST)).containsEntry(SECOND, List.of(SECOND));
        }
    }

    @Test
    void laterSegmentsRemainOutsideThisDeliveryAndAreVisibleToTheirOwnEvent() throws Exception {
        UUID later = UUID.fromString("00000000-0000-0000-0000-000000000003");
        try (var connection = open()) {
            connection.setAutoCommit(false);
            var frozen = ChainNoticeService.lockWorkshopSegmentsForPlans(jdbc(connection), List.of(SECOND, FIRST));
            insert(later, SECOND);
            assertThat(frozen.values().stream().flatMap(List::stream).toList()).doesNotContain(later);
            assertThatThrownBy(() -> frozen.put(later, List.of(later))).isInstanceOf(UnsupportedOperationException.class);
            assertThatThrownBy(() -> frozen.get(SECOND).add(later)).isInstanceOf(UnsupportedOperationException.class);
            connection.commit();
        }
        try (var connection = open()) {
            connection.setAutoCommit(false);
            assertThat(ChainNoticeService.lockWorkshopSegmentsForPlans(jdbc(connection), List.of(SECOND)).get(SECOND))
                    .containsExactly(later, SECOND);
            connection.commit();
        } finally {
            try (var connection = open(); var statement = connection.prepareStatement("DELETE FROM production_execution_segments WHERE id=?")) {
                statement.setObject(1, later); statement.executeUpdate();
            }
        }
    }

    private static void insert(UUID segment, UUID plan) throws SQLException {
        try (var connection = open();
             var packages = connection.prepareStatement("INSERT INTO production_planning_packages(id,is_deleted,status) VALUES (?,false,'CONFIRMED') ON CONFLICT DO NOTHING");
             var segments = connection.prepareStatement("INSERT INTO production_execution_segments(id,plan_id,package_id,is_deleted,status) VALUES (?,?,?,false,'READY')")) {
            packages.setObject(1, plan); packages.executeUpdate();
            segments.setObject(1, segment); segments.setObject(2, plan); segments.setObject(3, plan); segments.executeUpdate();
        }
    }

    private static void lock(Connection connection, UUID segment) throws SQLException {
        try (var statement = connection.prepareStatement("SELECT id FROM production_execution_segments WHERE id=? FOR UPDATE")) {
            statement.setObject(1, segment);
            try (var rows = statement.executeQuery()) { assertThat(rows.next()).isTrue(); }
        }
    }

    private static void awaitBlockedBy(int blocked, int blocker) throws Exception {
        try (var connection = open(); var query = connection.prepareStatement("SELECT ?=ANY(pg_blocking_pids(?))")) {
            query.setInt(1, blocker); query.setInt(2, blocked);
            for (int attempt = 0; attempt < 500; attempt++) {
                try (var rows = query.executeQuery()) { rows.next(); if (rows.getBoolean(1)) return; }
                Thread.sleep(10);
            }
        }
        throw new AssertionError("Projection must reach a database-observed wait on the foreground's first segment");
    }

    private static int pid(Connection connection) throws SQLException {
        try (var statement = connection.createStatement(); var rows = statement.executeQuery("SELECT pg_backend_pid()")) {
            rows.next(); return rows.getInt(1);
        }
    }

    private static JdbcTemplate jdbc(Connection connection) {
        return new JdbcTemplate(new SingleConnectionDataSource(connection, true));
    }

    private static Connection open() throws SQLException {
        Connection connection = DriverManager.getConnection(PG.getJdbcUrl(), PG.getUsername(), PG.getPassword());
        try {
            try (var statement = connection.createStatement()) { statement.execute("SET lock_timeout='5s'; SET statement_timeout='10s'"); }
            return connection;
        } catch (SQLException | RuntimeException | Error failure) {
            try { connection.close(); } catch (SQLException closeFailure) { failure.addSuppressed(closeFailure); }
            throw failure;
        }
    }
}
