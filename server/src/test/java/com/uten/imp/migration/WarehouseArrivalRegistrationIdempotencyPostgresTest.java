package com.uten.imp.migration;

import org.flywaydb.core.Flyway;
import org.junit.jupiter.api.AfterAll;
import org.junit.jupiter.api.BeforeAll;
import org.junit.jupiter.api.Test;
import org.junit.jupiter.api.condition.EnabledIfEnvironmentVariable;
import org.testcontainers.containers.PostgreSQLContainer;

import java.sql.Connection;
import java.sql.DriverManager;
import java.sql.ResultSet;
import java.sql.SQLException;
import java.sql.Savepoint;
import java.sql.Statement;
import java.util.UUID;

import static org.assertj.core.api.Assertions.assertThat;
import static org.junit.jupiter.api.Assertions.assertThrows;

@EnabledIfEnvironmentVariable(named = "UTEN_RUN_DB_TESTS", matches = "(?i)true")
class WarehouseArrivalRegistrationIdempotencyPostgresTest {

    private static final PostgreSQLContainer<?> POSTGRES =
            new PostgreSQLContainer<>("postgres:16-alpine")
                    .withDatabaseName("uten_arrival_command")
                    .withUsername("uten")
                    .withPassword("uten-test-only");

    @BeforeAll
    static void migrate() {
        POSTGRES.start();
        Flyway.configure()
                .dataSource(
                        POSTGRES.getJdbcUrl(),
                        POSTGRES.getUsername(),
                        POSTGRES.getPassword())
                .locations("classpath:db/migration")
                .load()
                .migrate();
    }

    @AfterAll
    static void stop() {
        POSTGRES.stop();
    }

    @Test
    void makerKeyIsUniqueAndIdentityAndTerminalResultAreImmutable()
            throws Exception {
        try (Connection connection = DriverManager.getConnection(
                POSTGRES.getJdbcUrl(),
                POSTGRES.getUsername(),
                POSTGRES.getPassword());
             Statement statement = connection.createStatement()) {
            connection.setAutoCommit(false);
            UUID makerId = uuid(statement, "SELECT id FROM employees ORDER BY id LIMIT 1");
            UUID receiptId = UUID.randomUUID();
            UUID commandId = UUID.randomUUID();
            try {
                statement.executeUpdate("""
                        INSERT INTO purchase_receipts(id, bill_no, bill_date, status)
                        VALUES ('%s','CJ20260828000001',DATE '2026-08-28',0)
                        """.formatted(receiptId));
                statement.executeUpdate("""
                        INSERT INTO warehouse_arrival_registration_commands(
                            id,maker_id,idempotency_key,request_hash,order_type)
                        VALUES ('%s','%s','arrival-v419-key','%s','PURCHASE')
                        """.formatted(commandId, makerId, "a".repeat(64)));

                Savepoint duplicatePoint = connection.setSavepoint();
                SQLException duplicate = assertThrows(SQLException.class,
                        () -> statement.executeUpdate("""
                                INSERT INTO warehouse_arrival_registration_commands(
                                    id,maker_id,idempotency_key,request_hash,order_type)
                                VALUES (gen_random_uuid(),'%s','arrival-v419-key','%s','PURCHASE')
                                """.formatted(makerId, "a".repeat(64))));
                assertThat(duplicate.getSQLState()).isEqualTo("23505");
                connection.rollback(duplicatePoint);

                Savepoint identityPoint = connection.setSavepoint();
                SQLException identity = assertThrows(SQLException.class,
                        () -> statement.executeUpdate("""
                                UPDATE warehouse_arrival_registration_commands
                                SET request_hash='%s' WHERE id='%s'
                                """.formatted("b".repeat(64), commandId)));
                assertThat(identity.getSQLState()).isEqualTo("55000");
                assertThat(identity.getMessage()).contains("identity is immutable");
                connection.rollback(identityPoint);

                assertThat(statement.executeUpdate("""
                        UPDATE warehouse_arrival_registration_commands
                        SET status='COMPLETED',
                            outcome='SUBMITTED_FOR_INSPECTION',
                            purchase_receipt_id='%s',
                            receipt_bill_no_snapshot='CJ20260828000001',
                            completed_at=now()
                        WHERE id='%s'
                        """.formatted(receiptId, commandId))).isEqualTo(1);
                assertThat(text(statement, """
                        SELECT status || '|' || outcome || '|' || receipt_bill_no_snapshot
                        FROM warehouse_arrival_registration_commands
                        WHERE id='%s'
                        """.formatted(commandId)))
                        .isEqualTo("COMPLETED|SUBMITTED_FOR_INSPECTION|CJ20260828000001");

                Savepoint terminalPoint = connection.setSavepoint();
                SQLException terminal = assertThrows(SQLException.class,
                        () -> statement.executeUpdate("""
                                UPDATE warehouse_arrival_registration_commands
                                SET receipt_bill_no_snapshot='MUTATED'
                                WHERE id='%s'
                                """.formatted(commandId)));
                assertThat(terminal.getSQLState()).isEqualTo("55000");
                assertThat(terminal.getMessage()).contains("terminal result is immutable");
                connection.rollback(terminalPoint);

                Savepoint deletePoint = connection.setSavepoint();
                SQLException deletion = assertThrows(SQLException.class,
                        () -> statement.executeUpdate("""
                                DELETE FROM warehouse_arrival_registration_commands
                                WHERE id='%s'
                                """.formatted(commandId)));
                assertThat(deletion.getSQLState()).isEqualTo("55000");
                connection.rollback(deletePoint);

                assertThat(count(statement, """
                        SELECT COUNT(*) FROM pg_trigger
                        WHERE NOT tgisinternal
                          AND tgname IN (
                            'trg_guard_warehouse_arrival_registration_command',
                            'trg_audit_warehouse_arrival_registration_commands')
                          AND tgenabled <> 'D'
                        """)).isEqualTo(2);
            } finally {
                connection.rollback();
            }
        }
    }

    private static UUID uuid(Statement statement, String sql) throws Exception {
        try (ResultSet result = statement.executeQuery(sql)) {
            assertThat(result.next()).isTrue();
            return result.getObject(1, UUID.class);
        }
    }

    private static String text(Statement statement, String sql) throws Exception {
        try (ResultSet result = statement.executeQuery(sql)) {
            assertThat(result.next()).isTrue();
            return result.getString(1);
        }
    }

    private static long count(Statement statement, String sql) throws Exception {
        try (ResultSet result = statement.executeQuery(sql)) {
            result.next();
            return result.getLong(1);
        }
    }
}
