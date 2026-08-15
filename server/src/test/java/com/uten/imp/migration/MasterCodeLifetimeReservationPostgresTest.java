package com.uten.imp.migration;

import org.flywaydb.core.Flyway;
import org.junit.jupiter.api.AfterAll;
import org.junit.jupiter.api.BeforeAll;
import org.junit.jupiter.api.MethodOrderer;
import org.junit.jupiter.api.Order;
import org.junit.jupiter.api.Test;
import org.junit.jupiter.api.TestMethodOrder;
import org.junit.jupiter.api.condition.EnabledIfEnvironmentVariable;
import org.testcontainers.containers.PostgreSQLContainer;

import java.sql.Connection;
import java.sql.DriverManager;
import java.sql.PreparedStatement;
import java.sql.ResultSet;
import java.sql.SQLException;
import java.sql.Statement;
import java.util.ArrayList;
import java.util.List;
import java.util.UUID;

import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertThrows;
import static org.junit.jupiter.api.Assertions.assertTrue;

/** Non-empty PostgreSQL 16 upgrade proof for V276 lifetime code reservations. */
@EnabledIfEnvironmentVariable(named = "UTEN_RUN_DB_TESTS", matches = "(?i)true")
@TestMethodOrder(MethodOrderer.OrderAnnotation.class)
class MasterCodeLifetimeReservationPostgresTest {

    private static final PostgreSQLContainer<?> POSTGRES =
            new PostgreSQLContainer<>("postgres:16-alpine")
                    .withDatabaseName("uten_imp")
                    .withUsername("uten")
                    .withPassword("uten");

    private static UUID deletedColorId;
    private static UUID activeColorId;
    private static int migrationsExecuted;

    @BeforeAll
    static void migrateNonEmptyDatabase() throws Exception {
        POSTGRES.start();
        flyway("275").migrate();
        deletedColorId = UUID.randomUUID();
        activeColorId = UUID.randomUUID();
        try (Connection connection = connection();
             PreparedStatement insert = connection.prepareStatement("""
                     INSERT INTO colors (
                         id, legacy_id, code, name, status, is_deleted, deleted_at)
                     VALUES (?, ?, ?, ?, '使用', ?, CASE WHEN ? THEN now() ELSE NULL END)
                     """)) {
            insertColor(insert, deletedColorId, 976001, " CaseCode ", true);
            insertColor(insert, activeColorId, 976002, "casecode", false);
        }
        migrationsExecuted = flyway("276").migrate().migrationsExecuted;
    }

    @AfterAll
    static void stopPostgres() {
        POSTGRES.stop();
    }

    @Test
    @Order(1)
    void upgradeRegistersLegacyDuplicatesWithoutRewritingTheirDisplayCodes()
            throws Exception {
        assertEquals(1, migrationsExecuted);
        try (Connection connection = connection()) {
            assertEquals(1, scalar(connection, """
                    SELECT count(*) FROM master_code_reservations
                    WHERE master_domain='COLOR' AND normalized_code='CASECODE'
                    """));
            assertEquals(2, scalar(connection, """
                    SELECT count(*) FROM master_code_reservation_members
                    WHERE master_domain='COLOR' AND normalized_code='CASECODE'
                    """));
            assertEquals(" CaseCode ", text(connection,
                    "SELECT code FROM colors WHERE id=?", deletedColorId));
            assertEquals("casecode", text(connection,
                    "SELECT code FROM colors WHERE id=?", activeColorId));
        }
    }

    @Test
    @Order(2)
    void anotherIdentityCannotUseADeletedOrCaseVariantCode() throws Exception {
        SQLException conflict = assertThrows(SQLException.class, () -> {
            try (Connection connection = connection();
                 PreparedStatement insert = connection.prepareStatement("""
                         INSERT INTO colors (id, legacy_id, code, name, status, is_deleted)
                         VALUES (?, 976003, ' CASECODE ', 'new identity', '使用', false)
                         """)) {
                insert.setObject(1, UUID.randomUUID());
                insert.executeUpdate();
            }
        });
        assertEquals("23505", conflict.getSQLState());
        assertTrue(conflict.getMessage().contains(
                "master code is reserved for another identity"));
    }

    @Test
    @Order(3)
    void blankMasterCodeIsRejectedAtTheDatabaseBoundary() {
        SQLException invalid = assertThrows(SQLException.class, () -> {
            try (Connection connection = connection();
                 PreparedStatement insert = connection.prepareStatement("""
                         INSERT INTO colors (id, legacy_id, code, name, status, is_deleted)
                         VALUES (?, 976005, '   ', 'blank code', '浣跨敤', false)
                         """)) {
                insert.setObject(1, UUID.randomUUID());
                insert.executeUpdate();
            }
        });
        assertEquals("23514", invalid.getSQLState());
        assertTrue(invalid.getMessage().contains("code must not be blank"));
    }

    @Test
    @Order(4)
    void changingAwayDoesNotReleaseTheOldCodeButExactLegacyReimportIsAllowed()
            throws Exception {
        try (Connection connection = connection();
             PreparedStatement update = connection.prepareStatement(
                     "UPDATE colors SET code='NEW-CODE' WHERE id=?")) {
            update.setObject(1, activeColorId);
            assertEquals(1, update.executeUpdate());
        }

        SQLException conflict = assertThrows(SQLException.class, () -> {
            try (Connection connection = connection();
                 PreparedStatement insert = connection.prepareStatement("""
                         INSERT INTO colors (id, legacy_id, code, name, status, is_deleted)
                         VALUES (?, 976004, 'casecode', 'reused identity', '使用', false)
                         """)) {
                insert.setObject(1, UUID.randomUUID());
                insert.executeUpdate();
            }
        });
        assertEquals("23505", conflict.getSQLState());

        try (Connection connection = connection();
             PreparedStatement delete = connection.prepareStatement(
                     "DELETE FROM colors WHERE id IN (?, ?)")) {
            delete.setObject(1, deletedColorId);
            delete.setObject(2, activeColorId);
            assertEquals(2, delete.executeUpdate());
        }
        try (Connection connection = connection();
             PreparedStatement reimport = connection.prepareStatement("""
                     INSERT INTO colors (id, legacy_id, code, name, status, is_deleted)
                     VALUES (?, 976002, 'casecode', 'exact legacy reimport', '使用', false)
                     """)) {
            reimport.setObject(1, UUID.randomUUID());
            assertEquals(1, reimport.executeUpdate());
        }
    }

    @Test
    @Order(5)
    void reservationHistoryIsAuditedAndAppendOnly() throws Exception {
        try (Connection connection = connection()) {
            assertTrue(scalar(connection, """
                    SELECT count(*) FROM audit_log
                    WHERE target_type IN (
                        'master_code_reservations',
                        'master_code_reservation_members')
                    """) > 0);
        }
        SQLException guarded = assertThrows(SQLException.class, () -> {
            try (Connection connection = connection();
                 Statement delete = connection.createStatement()) {
                delete.executeUpdate("""
                        DELETE FROM master_code_reservations
                        WHERE master_domain='COLOR' AND normalized_code='CASECODE'
                        """);
            }
        });
        assertEquals("55000", guarded.getSQLState());
    }

    @Test
    @Order(6)
    void everyCodeColumnIsEitherLifetimeReservedOrExplicitlyClassified() throws Exception {
        List<String> codeTables = new ArrayList<>();
        List<String> guardedTables = new ArrayList<>();
        try (Connection connection = connection();
             Statement statement = connection.createStatement();
             ResultSet result = statement.executeQuery("""
                     SELECT columns.table_name,
                            EXISTS (
                                SELECT 1
                                FROM pg_trigger trigger
                                JOIN pg_class relation ON relation.oid = trigger.tgrelid
                                JOIN pg_namespace namespace ON namespace.oid = relation.relnamespace
                                WHERE namespace.nspname = 'public'
                                  AND relation.relname = columns.table_name
                                  AND NOT trigger.tgisinternal
                                  AND trigger.tgname LIKE 'trg_reserve_code_%'
                            ) AS guarded
                     FROM information_schema.columns columns
                     WHERE columns.table_schema = 'public'
                       AND columns.column_name = 'code'
                     ORDER BY columns.table_name
                     """)) {
            while (result.next()) {
                codeTables.add(result.getString("table_name"));
                if (result.getBoolean("guarded")) {
                    guardedTables.add(result.getString("table_name"));
                }
            }
        }
        List<String> unclassified = new ArrayList<>(codeTables);
        unclassified.removeAll(guardedTables);
        assertEquals(List.of("legacy_departments", "permissions", "roles"), unclassified,
                "Only migration trace rows and immutable authorization machine keys may "
                        + "remain outside business-master lifetime reservations");
    }

    private static void insertColor(
            PreparedStatement insert,
            UUID id,
            int legacyId,
            String code,
            boolean deleted) throws Exception {
        insert.setObject(1, id);
        insert.setInt(2, legacyId);
        insert.setString(3, code);
        insert.setString(4, "V276 seed " + legacyId);
        insert.setBoolean(5, deleted);
        insert.setBoolean(6, deleted);
        assertEquals(1, insert.executeUpdate());
    }

    private static String text(Connection connection, String sql, UUID id)
            throws Exception {
        try (PreparedStatement query = connection.prepareStatement(sql)) {
            query.setObject(1, id);
            try (ResultSet result = query.executeQuery()) {
                assertTrue(result.next());
                return result.getString(1);
            }
        }
    }

    private static int scalar(Connection connection, String sql) throws Exception {
        try (Statement statement = connection.createStatement();
             ResultSet result = statement.executeQuery(sql)) {
            assertTrue(result.next());
            return result.getInt(1);
        }
    }

    private static Flyway flyway(String target) {
        return Flyway.configure()
                .dataSource(POSTGRES.getJdbcUrl(), POSTGRES.getUsername(), POSTGRES.getPassword())
                .locations("classpath:db/migration")
                .target(target)
                .load();
    }

    private static Connection connection() throws Exception {
        return DriverManager.getConnection(
                POSTGRES.getJdbcUrl(), POSTGRES.getUsername(), POSTGRES.getPassword());
    }
}
