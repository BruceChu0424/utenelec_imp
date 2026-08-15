package com.uten.imp.migration;

import org.flywaydb.core.Flyway;
import org.flywaydb.core.api.FlywayException;
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
import java.util.UUID;

import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertNull;
import static org.junit.jupiter.api.Assertions.assertThrows;
import static org.junit.jupiter.api.Assertions.assertTrue;

/** Non-empty V276 -> V277 rehearsal for strict account/style UUID authority. */
@EnabledIfEnvironmentVariable(named = "UTEN_RUN_DB_TESTS", matches = "(?i)true")
@TestMethodOrder(MethodOrderer.OrderAnnotation.class)
class AccountStyleUuidStrictAuthorityPostgresTest {

    private static final PostgreSQLContainer<?> POSTGRES =
            new PostgreSQLContainer<>("postgres:16-alpine")
                    .withDatabaseName("uten_imp")
                    .withUsername("uten")
                    .withPassword("uten");

    private static UUID cashStyleId;
    private static UUID bankStyleId;
    private static UUID cashAccountId;
    private static UUID bankAccountId;
    private static UUID existingUuidAccountId;
    private static int migrationsExecuted;

    @BeforeAll
    static void migrateToV276AndSeedHistoricalRows() throws Exception {
        POSTGRES.start();
        flyway(POSTGRES.getJdbcUrl(), "276").migrate();

        cashStyleId = UUID.randomUUID();
        bankStyleId = UUID.randomUUID();
        cashAccountId = UUID.randomUUID();
        bankAccountId = UUID.randomUUID();
        existingUuidAccountId = UUID.randomUUID();

        try (Connection connection = connection()) {
            insertStyle(connection, cashStyleId, 977101, "101", "现金");
            insertStyle(connection, bankStyleId, 977102, "102", "银行存款");
            insertAccount(connection, cashAccountId, 978101, "AC-V277-CASH",
                    "CASH", null, null, "使用");
            insertAccount(connection, bankAccountId, 978102, "AC-V277-BANK",
                    "BANK", null, null, "使用");

            // V267 independently validates both columns but did not compare
            // their identities. V277 must make the UUID's shadow canonical.
            insertAccount(connection, existingUuidAccountId, 978103,
                    "AC-V277-EXISTING", "BANK", bankStyleId, 977101, "使用");
            try (PreparedStatement update = connection.prepareStatement("""
                    UPDATE payment_styles
                    SET linked_account_id=?, linked_account_legacy_id=978101
                    WHERE id=?
                    """)) {
                update.setObject(1, bankAccountId);
                update.setObject(2, bankStyleId);
                assertEquals(1, update.executeUpdate());
            }
        }

        migrationsExecuted = flyway(POSTGRES.getJdbcUrl(), "277")
                .migrate().migrationsExecuted;
    }

    @AfterAll
    static void stopPostgres() {
        POSTGRES.stop();
    }

    @Test
    @Order(1)
    void migrationBackfillsOnlyReviewedDefaultsAndCanonicalizesShadows()
            throws Exception {
        assertEquals(1, migrationsExecuted);
        try (Connection connection = connection()) {
            assertEquals(cashStyleId, object(connection,
                    "SELECT style_id FROM accounts WHERE id=?", cashAccountId));
            assertEquals(977101, integer(connection,
                    "SELECT style_legacy_id FROM accounts WHERE id=?", cashAccountId));
            assertEquals(bankStyleId, object(connection,
                    "SELECT style_id FROM accounts WHERE id=?", bankAccountId));
            assertEquals(977102, integer(connection,
                    "SELECT style_legacy_id FROM accounts WHERE id=?", bankAccountId));
            assertEquals(977102, integer(connection,
                    "SELECT style_legacy_id FROM accounts WHERE id=?",
                    existingUuidAccountId));
            assertEquals(978102, integer(connection,
                    "SELECT linked_account_legacy_id FROM payment_styles WHERE id=?",
                    bankStyleId));
            assertEquals(3, scalar(connection, """
                    SELECT COUNT(*) FROM pg_constraint
                    WHERE conname IN (
                        'ck_accounts_active_style_uuid',
                        'ck_accounts_style_shadow_requires_uuid',
                        'ck_payment_styles_linked_account_shadow_requires_uuid')
                      AND convalidated
                    """));
        }
    }

    @Test
    @Order(2)
    void normalAccountWritesRejectLegacyOnlyAndConflictButDeriveCanonicalShadow()
            throws Exception {
        assertSqlState("23514", () -> withConnection(connection -> insertAccount(
                connection, UUID.randomUUID(), 978201, "AC-V277-LEGACY",
                "BANK", null, 977102, "禁用")));
        assertSqlState("23514", () -> withConnection(connection -> insertAccount(
                connection, UUID.randomUUID(), 978202, "AC-V277-MISSING",
                "BANK", null, null, "使用")));
        assertSqlState("23514", () -> withConnection(connection -> insertAccount(
                connection, UUID.randomUUID(), 978203, "AC-V277-CONFLICT",
                "BANK", bankStyleId, 977101, "使用")));

        UUID canonical = UUID.randomUUID();
        try (Connection connection = connection()) {
            insertAccount(connection, canonical, 978204, "AC-V277-CANONICAL",
                    "BANK", bankStyleId, null, "使用");
            assertEquals(977102, integer(connection,
                    "SELECT style_legacy_id FROM accounts WHERE id=?", canonical));
            try (PreparedStatement clearShadow = connection.prepareStatement(
                    "UPDATE accounts SET style_legacy_id=NULL WHERE id=?")) {
                clearShadow.setObject(1, canonical);
                assertEquals(1, clearShadow.executeUpdate());
            }
            assertEquals(977102, integer(connection,
                    "SELECT style_legacy_id FROM accounts WHERE id=?", canonical));
        }
    }

    @Test
    @Order(3)
    void linkedAccountAndPostingResolverAreUuidOnly() throws Exception {
        assertSqlState("23514", () -> withConnection(connection ->
                insertLinkedStyle(connection, "V277-LINK-LEGACY", null, 978102)));
        assertSqlState("23514", () -> withConnection(connection ->
                insertLinkedStyle(
                        connection, "V277-LINK-CONFLICT", bankAccountId, 978101)));

        UUID linkedStyle;
        UUID unlinkedStyle;
        try (Connection connection = connection()) {
            linkedStyle = insertLinkedStyle(
                    connection, "V277-LINK-UUID", bankAccountId, null);
            unlinkedStyle = insertLinkedStyle(
                    connection, "V277-LINK-NONE", null, null);
        }
        UUID disabledCash = UUID.randomUUID();
        UUID deletedAccount = UUID.randomUUID();
        try (Connection connection = connection()) {
            assertEquals(978102, integer(connection, """
                    SELECT linked_account_legacy_id
                    FROM payment_styles WHERE id=?
                    """, linkedStyle));
            assertNull(object(connection, """
                    SELECT linked_account_legacy_id
                    FROM payment_styles WHERE id=?
                    """, unlinkedStyle));

            insertAccount(connection, disabledCash, 978301, "AC-V277-NO-GUESS",
                    "CASH", null, null, "禁用");
            insertAccount(connection, deletedAccount, 978302, "AC-V277-DELETED",
                    "BANK", null, null, "禁用");
            try (PreparedStatement delete = connection.prepareStatement(
                    "UPDATE accounts SET status='使用', is_deleted=true WHERE id=?")) {
                delete.setObject(1, deletedAccount);
                assertEquals(1, delete.executeUpdate());
            }
            assertNull(object(connection,
                    "SELECT account_style_id(?)", disabledCash));
            assertSqlState("23514", () -> withConnection(nested ->
                    insertLinkedStyle(
                            nested, "V277-LINK-DISABLED", disabledCash, null)));
            assertSqlState("23514", () -> withConnection(nested ->
                    insertLinkedStyle(
                            nested, "V277-LINK-DELETED", deletedAccount, null)));
            assertSqlState("23514", () -> {
                try (Connection nested = connection();
                     PreparedStatement activate = nested.prepareStatement(
                             "UPDATE accounts SET status='使用' WHERE id=?")) {
                    activate.setObject(1, disabledCash);
                    activate.executeUpdate();
                }
            });
        }
    }

    @Test
    @Order(4)
    void migrationCreatesOnlyMissingCanonicalRootsForNativeAccounts()
            throws Exception {
        String database = "uten_v277_missing_roots";
        try (Connection admin = connection();
             Statement create = admin.createStatement()) {
            create.execute("CREATE DATABASE " + database);
        }
        String url = "jdbc:postgresql://" + POSTGRES.getHost() + ":"
                + POSTGRES.getMappedPort(5432) + "/" + database;
        flyway(url, "276").migrate();

        UUID nativeCash = UUID.randomUUID();
        UUID nativeBank = UUID.randomUUID();
        try (Connection connection = DriverManager.getConnection(
                url, POSTGRES.getUsername(), POSTGRES.getPassword())) {
            insertAccount(connection, nativeCash, 979101,
                    "AC-V277-NATIVE-CASH", "CASH", null, null, "使用");
            insertAccount(connection, nativeBank, 979102,
                    "AC-V277-NATIVE-BANK", "BANK", null, null, "使用");
            assertEquals(0, scalar(connection, """
                    SELECT COUNT(*)
                    FROM payment_styles
                    WHERE path IN ('/101/', '/102/')
                    """));
        }

        assertEquals(1, flyway(url, "277").migrate().migrationsExecuted);
        try (Connection connection = DriverManager.getConnection(
                url, POSTGRES.getUsername(), POSTGRES.getPassword())) {
            assertEquals(2, scalar(connection, """
                    SELECT COUNT(*)
                    FROM payment_styles
                    WHERE path IN ('/101/', '/102/')
                      AND category='ACCOUNT'
                      AND status='使用'
                      AND is_deleted=false
                      AND auto_created=true
                    """));
            assertEquals("/101/", text(connection, """
                    SELECT style.path
                    FROM accounts account
                    JOIN payment_styles style ON style.id=account.style_id
                    WHERE account.id=?
                    """, nativeCash));
            assertEquals("/102/", text(connection, """
                    SELECT style.path
                    FROM accounts account
                    JOIN payment_styles style ON style.id=account.style_id
                    WHERE account.id=?
                    """, nativeBank));
        }
    }

    @Test
    @Order(5)
    void migrationFailsClosedWhenDefaultPathIsNotAnActiveLeaf() throws Exception {
        String database = "uten_v277_unavailable";
        try (Connection admin = connection();
             Statement create = admin.createStatement()) {
            create.execute("CREATE DATABASE " + database);
        }
        String url = "jdbc:postgresql://" + POSTGRES.getHost() + ":"
                + POSTGRES.getMappedPort(5432) + "/" + database;
        flyway(url, "276").migrate();
        try (Connection connection = DriverManager.getConnection(
                url, POSTGRES.getUsername(), POSTGRES.getPassword())) {
            UUID unavailableStyle = UUID.randomUUID();
            insertStyle(connection, unavailableStyle, 979101, "101", "已停用现金");
            try (PreparedStatement disable = connection.prepareStatement(
                    "UPDATE payment_styles SET status='禁用' WHERE id=?")) {
                disable.setObject(1, unavailableStyle);
                assertEquals(1, disable.executeUpdate());
            }
            insertAccount(connection, UUID.randomUUID(), 979201,
                    "AC-V277-UNAVAILABLE", "CASH", null, null, "使用");
        }

        FlywayException failure = assertThrows(
                FlywayException.class, () -> flyway(url, "277").migrate());
        assertTrue(failure.getMessage().contains("resolved to 0 active ACCOUNT leaves"));
    }

    private static void insertStyle(
            Connection connection, UUID id, int legacyId, String code, String name)
            throws SQLException {
        try (PreparedStatement insert = connection.prepareStatement("""
                     INSERT INTO payment_styles (
                         id, legacy_id, code, name, category, status, is_deleted)
                     VALUES (?, ?, ?, ?, 'ACCOUNT', '使用', false)
                     """)) {
            insert.setObject(1, id);
            insert.setInt(2, legacyId);
            insert.setString(3, code);
            insert.setString(4, name);
            assertEquals(1, insert.executeUpdate());
        }
    }

    private static void insertAccount(
            Connection connection,
            UUID id,
            int legacyId,
            String code,
            String accountType,
            UUID styleId,
            Integer styleLegacyId,
            String status) throws SQLException {
        try (PreparedStatement insert = connection.prepareStatement("""
                     INSERT INTO accounts (
                         id, legacy_id, code, name, account_type, status,
                         style_id, style_legacy_id, is_deleted)
                     VALUES (?, ?, ?, ?, ?, ?, ?, ?, false)
                     """)) {
            insert.setObject(1, id);
            insert.setInt(2, legacyId);
            insert.setString(3, code);
            insert.setString(4, "V277账户-" + code);
            insert.setString(5, accountType);
            insert.setString(6, status);
            insert.setObject(7, styleId);
            if (styleLegacyId == null) insert.setNull(8, java.sql.Types.INTEGER);
            else insert.setInt(8, styleLegacyId);
            assertEquals(1, insert.executeUpdate());
        }
    }

    private static UUID insertLinkedStyle(
            Connection connection,
            String code,
            UUID linkedAccountId,
            Integer linkedAccountLegacyId) throws SQLException {
        UUID id = UUID.randomUUID();
        try (PreparedStatement insert = connection.prepareStatement("""
                     INSERT INTO payment_styles (
                         id, code, name, category, status,
                         linked_account_id, linked_account_legacy_id, is_deleted)
                     VALUES (?, ?, ?, 'ACCOUNT', '使用', ?, ?, false)
                     """)) {
            insert.setObject(1, id);
            insert.setString(2, code);
            insert.setString(3, "V277关联-" + code);
            insert.setObject(4, linkedAccountId);
            if (linkedAccountLegacyId == null) insert.setNull(5, java.sql.Types.INTEGER);
            else insert.setInt(5, linkedAccountLegacyId);
            assertEquals(1, insert.executeUpdate());
        }
        return id;
    }

    private static void assertSqlState(String state, SqlAction action) {
        SQLException failure = assertThrows(SQLException.class, action::run);
        assertEquals(state, failure.getSQLState());
    }

    private static void withConnection(ConnectionSqlAction action) throws SQLException {
        try (Connection connection = connection()) {
            action.run(connection);
        }
    }

    private static Object object(Connection connection, String sql, UUID id)
            throws SQLException {
        try (PreparedStatement query = connection.prepareStatement(sql)) {
            query.setObject(1, id);
            try (ResultSet result = query.executeQuery()) {
                assertTrue(result.next());
                return result.getObject(1);
            }
        }
    }

    private static int integer(Connection connection, String sql, UUID id)
            throws SQLException {
        return ((Number) object(connection, sql, id)).intValue();
    }

    private static int scalar(Connection connection, String sql) throws SQLException {
        try (Statement statement = connection.createStatement();
             ResultSet result = statement.executeQuery(sql)) {
            assertTrue(result.next());
            return result.getInt(1);
        }
    }

    private static String text(Connection connection, String sql, UUID id)
            throws SQLException {
        return String.valueOf(object(connection, sql, id));
    }

    private static Flyway flyway(String url, String target) {
        return Flyway.configure()
                .dataSource(url, POSTGRES.getUsername(), POSTGRES.getPassword())
                .locations("classpath:db/migration")
                .target(target)
                .load();
    }

    private static Connection connection() throws SQLException {
        return DriverManager.getConnection(
                POSTGRES.getJdbcUrl(), POSTGRES.getUsername(), POSTGRES.getPassword());
    }

    @FunctionalInterface
    private interface SqlAction {
        void run() throws SQLException;
    }

    @FunctionalInterface
    private interface ConnectionSqlAction {
        void run(Connection connection) throws SQLException;
    }
}
