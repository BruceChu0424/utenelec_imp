package com.uten.imp.migration;

import org.flywaydb.core.Flyway;
import org.junit.jupiter.api.Test;
import org.testcontainers.containers.PostgreSQLContainer;
import org.testcontainers.junit.jupiter.Container;
import org.testcontainers.junit.jupiter.Testcontainers;

import java.sql.Connection;
import java.sql.DriverManager;
import java.sql.SQLException;
import java.time.LocalDate;
import java.util.List;
import java.util.UUID;

import static org.assertj.core.api.Assertions.assertThat;
import static org.junit.jupiter.api.Assertions.assertThrows;

@Testcontainers(disabledWithoutDocker = true)
class ProductionFinishedArrivalPartialRegistrationPostgresTest {

    @Container
    static final PostgreSQLContainer<?> POSTGRES =
            new PostgreSQLContainer<>("postgres:16.15-alpine")
                    .withDatabaseName("finished_arrival_partial_v469")
                    .withUsername("uten")
                    .withPassword("uten");

    @Test
    void nonEmptyV468RegistrationIsPreservedAndNewLineCanUseASecondBatch()
            throws Exception {
        migrate("468");

        try (Connection connection = DriverManager.getConnection(
                POSTGRES.getJdbcUrl(),
                POSTGRES.getUsername(),
                POSTGRES.getPassword())) {
            Fixture fixture = seed(connection);
            insertBatch(
                    connection, fixture,
                    List.of(fixture.firstItemId(), fixture.secondItemId()),
                    List.of("LEGACY-A-01", "LEGACY-A-02"),
                    "legacy-complete-batch");
            assertThat(scalar(connection, """
                    SELECT count(*)
                    FROM production_finished_arrival_registrations
                    WHERE source_report_id = '%s'
                    """.formatted(fixture.reportId()))).isEqualTo(1);

            migrate("469");
            UUID thirdItemId = UUID.randomUUID();
            insertReportItemInReplicaMode(
                    connection, fixture.reportId(), thirdItemId, 3);
            insertBatch(
                    connection, fixture,
                    List.of(thirdItemId), List.of("PARTIAL-A-03"),
                    "partial-second-batch");

            assertThat(scalar(connection, """
                    SELECT count(*)
                    FROM production_finished_arrival_registrations
                    WHERE source_report_id = '%s'
                    """.formatted(fixture.reportId()))).isEqualTo(2);
            assertThat(scalar(connection, """
                    SELECT count(*)
                    FROM production_finished_arrival_registration_items item
                    JOIN production_finished_arrival_registrations registration
                      ON registration.id = item.registration_id
                    WHERE registration.source_report_id = '%s'
                    """.formatted(fixture.reportId()))).isEqualTo(3);
            assertThat(scalar(connection, """
                    SELECT count(*)
                    FROM production_finished_arrival_registration_items
                    WHERE place_snapshot IN ('LEGACY-A-01', 'LEGACY-A-02')
                    """)).isEqualTo(2);
            assertThat(scalar(connection, """
                    SELECT count(*)
                    FROM pg_indexes
                    WHERE schemaname = 'public'
                      AND indexname =
                          'idx_finished_arrival_registration_report_created'
                    """)).isEqualTo(1);

            SQLException duplicateLine = assertThrows(
                    SQLException.class,
                    () -> insertBatch(
                            connection, fixture,
                            List.of(fixture.firstItemId()),
                            List.of("ILLEGAL-DUPLICATE"),
                            "duplicate-line-batch"));
            assertThat(duplicateLine.getSQLState()).isEqualTo("23505");

            connection.setAutoCommit(false);
            try (var statement = connection.prepareStatement("""
                    INSERT INTO production_finished_arrival_registrations(
                        id, source_report_id, warehouse_id,
                        warehouse_code_snapshot, warehouse_name_snapshot,
                        receiver_employee_id, receiver_name_snapshot,
                        idempotency_key, request_hash, created_by)
                    VALUES (?, ?, ?, 'CP', '成品仓', ?, '仓管员',
                            'empty-batch', ?, ?)
                    """)) {
                statement.setObject(1, UUID.randomUUID());
                statement.setObject(2, fixture.reportId());
                statement.setObject(3, fixture.warehouseId());
                statement.setObject(4, fixture.employeeId());
                statement.setString(5, "e".repeat(64));
                statement.setObject(6, fixture.userId());
                statement.executeUpdate();
            }
            SQLException emptyBatch = assertThrows(
                    SQLException.class, connection::commit);
            assertThat(emptyBatch.getSQLState()).isEqualTo("23514");
            assertThat(emptyBatch.getMessage()).contains(
                    "must contain exact report lines");
            connection.rollback();
            connection.setAutoCommit(true);
        }
    }

    private static void migrate(String target) {
        Flyway.configure()
                .dataSource(
                        POSTGRES.getJdbcUrl(),
                        POSTGRES.getUsername(),
                        POSTGRES.getPassword())
                .locations("classpath:db/migration")
                .target(target)
                .load()
                .migrate();
    }

    private static Fixture seed(Connection connection) throws Exception {
        UUID employeeId = UUID.randomUUID();
        UUID userId = UUID.randomUUID();
        UUID warehouseId = UUID.randomUUID();
        UUID reportId = UUID.randomUUID();
        UUID firstItemId = UUID.randomUUID();
        UUID secondItemId = UUID.randomUUID();
        connection.setAutoCommit(false);
        try (var statement = connection.createStatement()) {
            statement.execute("SET LOCAL session_replication_role = replica");
            statement.executeUpdate("""
                    INSERT INTO employees(
                        id, code, full_name, id_type, department_id,
                        hire_date, status, employment_type)
                    VALUES ('%s', 'E-%s', '仓管员', '其他', '%s',
                            DATE '2026-09-04', 'active', 'regular')
                    """.formatted(
                    employeeId, employeeId, UUID.randomUUID()));
            statement.executeUpdate("""
                    INSERT INTO users(
                        id, employee_id, login_account, password_hash, status)
                    VALUES ('%s', '%s', 'U-%s', 'test-only', 'active')
                    """.formatted(userId, employeeId, userId));
            statement.executeUpdate("""
                    INSERT INTO warehouses(id, code, name, status, is_accountable)
                    VALUES ('%s', 'CP-%s', '成品仓', '使用', TRUE)
                    """.formatted(warehouseId, warehouseId));
            statement.executeUpdate("""
                    INSERT INTO production_daily_reports(
                        id, bill_no, bill_date, status)
                    VALUES ('%s', 'RB-%s', DATE '%s', 1)
                    """.formatted(reportId, reportId, LocalDate.of(2026, 9, 4)));
            insertReportItem(statement, reportId, firstItemId, 1);
            insertReportItem(statement, reportId, secondItemId, 2);
            connection.commit();
        } catch (Throwable error) {
            connection.rollback();
            throw error;
        } finally {
            connection.setAutoCommit(true);
        }
        return new Fixture(
                employeeId, userId, warehouseId, reportId,
                firstItemId, secondItemId);
    }

    private static void insertReportItem(
            java.sql.Statement statement,
            UUID reportId,
            UUID itemId,
            int lineNo) throws Exception {
        statement.executeUpdate("""
                INSERT INTO production_daily_report_items(
                    id, bill_no, bill_date, report_id, line_no,
                    goods_id, unit_id, unit_rate, qty,
                    plan_item_id, execution_segment_id)
                VALUES ('%s', 'RB-%s', DATE '2026-09-04', '%s', %s,
                        '%s', '%s', 1, 10, '%s', '%s')
                """.formatted(
                itemId, reportId, reportId, lineNo,
                UUID.randomUUID(), UUID.randomUUID(),
                UUID.randomUUID(), UUID.randomUUID()));
    }

    private static void insertReportItemInReplicaMode(
            Connection connection,
            UUID reportId,
            UUID itemId,
            int lineNo) throws Exception {
        connection.setAutoCommit(false);
        try (var statement = connection.createStatement()) {
            statement.execute("SET LOCAL session_replication_role = replica");
            insertReportItem(statement, reportId, itemId, lineNo);
            connection.commit();
        } catch (Throwable error) {
            connection.rollback();
            throw error;
        } finally {
            connection.setAutoCommit(true);
        }
    }

    private static void insertBatch(
            Connection connection,
            Fixture fixture,
            List<UUID> reportItemIds,
            List<String> places,
            String key) throws Exception {
        if (reportItemIds.size() != places.size() || reportItemIds.isEmpty()) {
            throw new IllegalArgumentException("batch lines and places must match");
        }
        UUID registrationId = UUID.randomUUID();
        connection.setAutoCommit(false);
        try (var header = connection.prepareStatement("""
                     INSERT INTO production_finished_arrival_registrations(
                         id, source_report_id, warehouse_id,
                         warehouse_code_snapshot, warehouse_name_snapshot,
                         receiver_employee_id, receiver_name_snapshot,
                         idempotency_key, request_hash, created_by)
                     VALUES (?, ?, ?, 'CP', '成品仓', ?, '仓管员', ?, ?, ?)
                     """);
             var item = connection.prepareStatement("""
                     INSERT INTO production_finished_arrival_registration_items(
                         id, registration_id, source_report_item_id,
                         place_snapshot, created_by)
                     VALUES (?, ?, ?, ?, ?)
                     """)) {
            header.setObject(1, registrationId);
            header.setObject(2, fixture.reportId());
            header.setObject(3, fixture.warehouseId());
            header.setObject(4, fixture.employeeId());
            header.setString(5, key);
            header.setString(6, "a".repeat(64));
            header.setObject(7, fixture.userId());
            header.executeUpdate();

            for (int i = 0; i < reportItemIds.size(); i++) {
                item.setObject(1, UUID.randomUUID());
                item.setObject(2, registrationId);
                item.setObject(3, reportItemIds.get(i));
                item.setString(4, places.get(i));
                item.setObject(5, fixture.userId());
                item.addBatch();
            }
            item.executeBatch();
            connection.commit();
        } catch (Throwable error) {
            connection.rollback();
            throw error;
        } finally {
            connection.setAutoCommit(true);
        }
    }

    private static long scalar(Connection connection, String sql)
            throws Exception {
        try (var statement = connection.createStatement();
             var rows = statement.executeQuery(sql)) {
            rows.next();
            return rows.getLong(1);
        }
    }

    private record Fixture(
            UUID employeeId,
            UUID userId,
            UUID warehouseId,
            UUID reportId,
            UUID firstItemId,
            UUID secondItemId) {
    }
}
