package com.uten.imp.migration;

import org.flywaydb.core.Flyway;
import org.junit.jupiter.api.AfterAll;
import org.junit.jupiter.api.BeforeAll;
import org.junit.jupiter.api.Test;
import org.junit.jupiter.api.condition.EnabledIfEnvironmentVariable;
import org.testcontainers.containers.PostgreSQLContainer;

import java.sql.Connection;
import java.sql.DriverManager;
import java.sql.PreparedStatement;
import java.sql.ResultSet;
import java.sql.Statement;
import java.util.UUID;

import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertTrue;
import static org.junit.jupiter.api.Assertions.assertThrows;

/** Non-empty V266 -> V267 rehearsal for account/payment-style UUID truth. */
@EnabledIfEnvironmentVariable(named = "UTEN_RUN_DB_TESTS", matches = "(?i)true")
class AccountPaymentStyleUuidPostgresTest {

    private static final PostgreSQLContainer<?> POSTGRES =
            new PostgreSQLContainer<>("postgres:16-alpine")
                    .withDatabaseName("uten_imp")
                    .withUsername("uten")
                    .withPassword("uten");

    @BeforeAll
    static void migrateToV266AndSeedHistoricalMappings() throws Exception {
        POSTGRES.start();
        flyway("266").migrate();

        try (Connection connection = connection()) {
            connection.setAutoCommit(false);
            try (Statement mode = connection.createStatement()) {
                mode.execute("SELECT set_config('uten.payment_style_reference_import',"
                        + "'legacy-finance-v1',true)");
            }

            UUID activeStyle = insertStyle(
                    connection, 910001, "UUID-ACTIVE", "使用", 920001);
            UUID disabledStyle = insertStyle(
                    connection, 910002, "UUID-HISTORY", "禁用", 920002);
            UUID activeAccount = insertAccount(
                    connection, 920001, "UUID 在用账户", "使用", 910001);
            UUID disabledAccount = insertAccount(
                    connection, 920002, "UUID 历史账户", "禁用", 910002);
            connection.commit();

            assertTrue(activeStyle != null && disabledStyle != null
                    && activeAccount != null && disabledAccount != null);
        }
    }

    @AfterAll
    static void stopPostgres() {
        POSTGRES.stop();
    }

    @Test
    void v267BackfillsActiveAndHistoricalUuidIdentitiesWithoutDroppingShadows()
            throws Exception {
        assertEquals(1, flyway("267").migrate().migrationsExecuted);

        try (Connection connection = connection()) {
            assertEquals(2, scalar(connection, """
                    SELECT COUNT(*)
                    FROM accounts account
                    JOIN payment_styles style ON style.id=account.style_id
                    WHERE style.legacy_id=account.style_legacy_id
                      AND style.category='ACCOUNT'
                    """));
            assertEquals(2, scalar(connection, """
                    SELECT COUNT(*)
                    FROM payment_styles style
                    JOIN accounts account ON account.id=style.linked_account_id
                    WHERE account.legacy_id=style.linked_account_legacy_id
                    """));
            assertEquals(2, scalar(connection, """
                    SELECT COUNT(*) FROM pg_trigger
                    WHERE tgrelid='accounts'::regclass
                      AND tgname IN ('trg_psref_accounts_style',
                                     'trg_psref_accounts_style_uuid')
                      AND NOT tgisinternal
                    """));
        }
    }

    @Test
    void v267DatabaseGuardsBothAccountReactivationAndStyleDeactivation()
            throws Exception {
        try (Connection connection = connection()) {
            UUID activeStyle = uuid(connection,
                    "SELECT id FROM payment_styles WHERE legacy_id=910001");
            UUID activeAccount = uuid(connection,
                    "SELECT id FROM accounts WHERE legacy_id=920001");
            UUID disabledStyle = uuid(connection,
                    "SELECT id FROM payment_styles WHERE legacy_id=910002");
            UUID disabledAccount = uuid(connection,
                    "SELECT id FROM accounts WHERE legacy_id=920002");

            var styleError = assertThrows(java.sql.SQLException.class, () -> {
                try (PreparedStatement update = connection.prepareStatement(
                        "UPDATE payment_styles SET status='禁用' WHERE id=?")) {
                    update.setObject(1, activeStyle);
                    update.executeUpdate();
                }
            });
            assertEquals("23514", styleError.getSQLState());

            var accountError = assertThrows(java.sql.SQLException.class, () -> {
                try (PreparedStatement update = connection.prepareStatement(
                        "UPDATE accounts SET status='使用' WHERE id=?")) {
                    update.setObject(1, disabledAccount);
                    update.executeUpdate();
                }
            });
            assertEquals("23514", accountError.getSQLState());

            assertTrue(activeAccount != null && disabledStyle != null);
        }
    }

    private static UUID insertStyle(
            Connection connection,
            int legacyId,
            String code,
            String status,
            int linkedAccountLegacyId) throws Exception {
        UUID id = UUID.randomUUID();
        try (PreparedStatement insert = connection.prepareStatement("""
                INSERT INTO payment_styles (
                    id, legacy_id, code, name, category, level, sort_order,
                    status, linked_account_legacy_id, is_deleted)
                VALUES (?, ?, ?, ?, 'ACCOUNT', 0, 0, ?, ?, false)
                """)) {
            insert.setObject(1, id);
            insert.setInt(2, legacyId);
            insert.setString(3, code);
            insert.setString(4, "科目-" + code);
            insert.setString(5, status);
            insert.setInt(6, linkedAccountLegacyId);
            assertEquals(1, insert.executeUpdate());
        }
        return id;
    }

    private static UUID insertAccount(
            Connection connection,
            int legacyId,
            String name,
            String status,
            int styleLegacyId) throws Exception {
        UUID id = UUID.randomUUID();
        try (PreparedStatement insert = connection.prepareStatement("""
                INSERT INTO accounts (
                    id, legacy_id, code, name, account_type, status,
                    style_legacy_id, is_deleted)
                VALUES (?, ?, ?, ?, 'BANK', ?, ?, false)
                """)) {
            insert.setObject(1, id);
            insert.setInt(2, legacyId);
            insert.setString(3, "AC-" + legacyId);
            insert.setString(4, name);
            insert.setString(5, status);
            insert.setInt(6, styleLegacyId);
            assertEquals(1, insert.executeUpdate());
        }
        return id;
    }

    private static int scalar(Connection connection, String sql) throws Exception {
        try (Statement statement = connection.createStatement();
             ResultSet result = statement.executeQuery(sql)) {
            assertTrue(result.next());
            return result.getInt(1);
        }
    }

    private static UUID uuid(Connection connection, String sql) throws Exception {
        try (Statement statement = connection.createStatement();
             ResultSet result = statement.executeQuery(sql)) {
            assertTrue(result.next());
            return result.getObject(1, UUID.class);
        }
    }

    private static Flyway flyway(String target) {
        return Flyway.configure()
                .dataSource(
                        POSTGRES.getJdbcUrl(),
                        POSTGRES.getUsername(),
                        POSTGRES.getPassword())
                .locations("classpath:db/migration")
                .target(target)
                .load();
    }

    private static Connection connection() throws Exception {
        return DriverManager.getConnection(
                POSTGRES.getJdbcUrl(),
                POSTGRES.getUsername(),
                POSTGRES.getPassword());
    }
}
