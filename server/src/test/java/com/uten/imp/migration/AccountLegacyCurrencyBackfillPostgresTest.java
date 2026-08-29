package com.uten.imp.migration;

import org.flywaydb.core.Flyway;
import org.junit.jupiter.api.AfterAll;
import org.junit.jupiter.api.BeforeAll;
import org.junit.jupiter.api.Test;
import org.junit.jupiter.api.condition.EnabledIfEnvironmentVariable;
import org.testcontainers.containers.PostgreSQLContainer;

import java.math.BigDecimal;
import java.sql.Connection;
import java.sql.DriverManager;
import java.sql.PreparedStatement;
import java.sql.ResultSet;
import java.sql.SQLException;
import java.sql.Statement;
import java.sql.Types;
import java.util.UUID;

import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertNull;
import static org.junit.jupiter.api.Assertions.assertThrows;
import static org.junit.jupiter.api.Assertions.assertTrue;

@EnabledIfEnvironmentVariable(named = "UTEN_RUN_DB_TESTS", matches = "(?i)true")
class AccountLegacyCurrencyBackfillPostgresTest {

    private static final PostgreSQLContainer<?> POSTGRES =
            new PostgreSQLContainer<>("postgres:16-alpine")
                    .withDatabaseName("uten_imp")
                    .withUsername("uten")
                    .withPassword("uten");

    @BeforeAll
    static void migrateTemplateToV399() {
        POSTGRES.start();
        flyway(POSTGRES.getJdbcUrl(), "399").migrate();
    }

    @AfterAll
    static void stop() {
        POSTGRES.stop();
    }

    @Test
    void v400BackfillsOnlyNullLegacyAccountsWithReviewedRmbOffshoreSplit()
            throws Exception {
        String url = cloneTemplate("v400_currency_positive");
        UUID rmb;
        UUID usd;
        UUID hkd;
        UUID bank;
        UUID offshore;
        UUID disabledLegacy;
        UUID explicit;
        UUID manual;
        try (Connection connection = connection(url)) {
            rmb = insertCurrency(connection, 1, "BZ920001", "人民币", "1", "使用");
            usd = insertCurrency(connection, 3, "BZ920003", "美金", "0", "使用");
            hkd = insertCurrency(connection, 4, "BZ920004", "港币", "1", "使用");
            UUID style = accountStyle(connection);
            bank = insertAccount(connection, 101, "ZH920101", "银行账户", "BANK", null, style, "使用");
            offshore = insertAccount(connection, 102, "ZH920102", "香港账户", "OFFSHORE", null, style, "使用");
            disabledLegacy = insertAccount(connection, 103, "ZH920103", "旧停用账户", "BANK", null, style, "禁用");
            explicit = insertAccount(connection, 104, "ZH920104", "显式港币账户", "OFFSHORE", hkd, style, "使用");
            manual = insertAccount(connection, null, "ZH920105", "手工停用账户", "BANK", null, style, "禁用");
        }

        assertEquals(1, flyway(url, "400").migrate().migrationsExecuted);
        try (Connection connection = connection(url)) {
            assertEquals(rmb, currencyOf(connection, bank));
            assertEquals(usd, currencyOf(connection, offshore));
            assertEquals(rmb, currencyOf(connection, disabledLegacy));
            assertEquals(hkd, currencyOf(connection, explicit));
            assertNull(currencyOf(connection, manual));
        }
    }

    @Test
    void v400FailsWhenRequiredLegacyTargetIsMissing() throws Exception {
        String url = cloneTemplate("v400_currency_missing");
        try (Connection connection = connection(url)) {
            insertCurrency(connection, 1, "BZ921001", "人民币", "1", "使用");
            insertAccount(connection, 201, "ZH921201", "境外账户", "OFFSHORE", null,
                    accountStyle(connection), "使用");
        }

        assertMigrationFailure(url, "23514", "legacy OFFSHORE account currency mapping");
    }

    @Test
    void v400FailsWhenReviewedLegacyTargetIsAmbiguous() throws Exception {
        String url = cloneTemplate("v400_currency_ambiguous");
        try (Connection connection = connection(url); Statement statement = connection.createStatement()) {
            statement.execute("ALTER TABLE currencies DROP CONSTRAINT currencies_legacy_id_key");
            insertCurrency(connection, 1, "BZ922001", "人民币一", "1", "使用");
            insertCurrency(connection, 1, "BZ922002", "人民币二", "1", "使用");
            insertAccount(connection, 301, "ZH922301", "普通账户", "BANK", null,
                    accountStyle(connection), "使用");
        }

        assertMigrationFailure(url, "23514", "found 2");
    }

    @Test
    void v400LeavesManualNullUntouchedAndThenFailsClosedForActiveAccount()
            throws Exception {
        String url = cloneTemplate("v400_currency_manual");
        try (Connection connection = connection(url)) {
            insertCurrency(connection, 1, "BZ923001", "人民币", "1", "使用");
            insertCurrency(connection, 3, "BZ923003", "美金", "0", "使用");
            insertAccount(connection, null, "ZH923401", "手工活动账户", "BANK", null,
                    accountStyle(connection), "使用");
        }

        assertMigrationFailure(url, "23514", "active accounts have missing");
    }

    private static UUID insertCurrency(
            Connection connection, int legacyId, String code, String name,
            String rate, String status) throws SQLException {
        UUID id = UUID.randomUUID();
        try (PreparedStatement insert = connection.prepareStatement("""
                INSERT INTO currencies(
                    id,legacy_id,code,name,exchange_rate,status,auto_created,is_deleted)
                VALUES(?,?,?,?,?,?,FALSE,FALSE)
                """)) {
            insert.setObject(1, id);
            insert.setInt(2, legacyId);
            insert.setString(3, code);
            insert.setString(4, name);
            insert.setBigDecimal(5, new BigDecimal(rate));
            insert.setString(6, status);
            assertEquals(1, insert.executeUpdate());
        }
        return id;
    }

    private static UUID insertAccount(
            Connection connection, Integer legacyId, String code, String name,
            String accountType, UUID currencyId, UUID styleId, String status)
            throws SQLException {
        UUID id = UUID.randomUUID();
        try (PreparedStatement insert = connection.prepareStatement("""
                INSERT INTO accounts(
                    id,legacy_id,code,name,account_type,currency_id,style_id,status,is_deleted)
                VALUES(?,?,?,?,?,?,?,?,FALSE)
                """)) {
            insert.setObject(1, id);
            if (legacyId == null) insert.setNull(2, Types.INTEGER); else insert.setInt(2, legacyId);
            insert.setString(3, code);
            insert.setString(4, name);
            insert.setString(5, accountType);
            if (currencyId == null) insert.setNull(6, Types.OTHER); else insert.setObject(6, currencyId);
            insert.setObject(7, styleId);
            insert.setString(8, status);
            assertEquals(1, insert.executeUpdate());
        }
        return id;
    }

    private static UUID accountStyle(Connection connection) throws SQLException {
        try (Statement statement = connection.createStatement();
             ResultSet rows = statement.executeQuery("""
                     SELECT style.id FROM payment_styles style
                     WHERE style.category='ACCOUNT' AND style.status='使用'
                       AND COALESCE(style.is_deleted,FALSE)=FALSE
                       AND NOT EXISTS(SELECT 1 FROM payment_styles child
                                      WHERE child.parent_id=style.id
                                        AND COALESCE(child.is_deleted,FALSE)=FALSE)
                     ORDER BY style.id LIMIT 1
                     """)) {
            assertTrue(rows.next());
            return rows.getObject(1, UUID.class);
        }
    }

    private static UUID currencyOf(Connection connection, UUID accountId) throws SQLException {
        try (PreparedStatement query = connection.prepareStatement(
                "SELECT currency_id FROM accounts WHERE id=?")) {
            query.setObject(1, accountId);
            try (ResultSet rows = query.executeQuery()) {
                assertTrue(rows.next());
                return rows.getObject(1, UUID.class);
            }
        }
    }

    private static void assertMigrationFailure(
            String url, String sqlState, String messagePart) {
        Exception failure = assertThrows(Exception.class, () -> flyway(url, "400").migrate());
        Throwable current = failure;
        SQLException sql = null;
        while (current != null) {
            if (current instanceof SQLException candidate) {
                sql = candidate;
                break;
            }
            current = current.getCause();
        }
        assertTrue(sql != null, failure.toString());
        assertEquals(sqlState, sql.getSQLState());
        assertTrue(failure.toString().contains(messagePart)
                        || sql.getMessage().contains(messagePart),
                failure.toString());
    }

    private static String cloneTemplate(String name) throws SQLException {
        String adminUrl = "jdbc:postgresql://" + POSTGRES.getHost() + ":"
                + POSTGRES.getMappedPort(5432) + "/postgres";
        try (Connection admin = connection(adminUrl); Statement create = admin.createStatement()) {
            create.execute("CREATE DATABASE " + name + " TEMPLATE uten_imp");
        }
        return "jdbc:postgresql://" + POSTGRES.getHost() + ":"
                + POSTGRES.getMappedPort(5432) + "/" + name;
    }

    private static Flyway flyway(String url, String target) {
        return Flyway.configure()
                .dataSource(url, POSTGRES.getUsername(), POSTGRES.getPassword())
                .locations("classpath:db/migration")
                .target(target)
                .load();
    }

    private static Connection connection(String url) throws SQLException {
        return DriverManager.getConnection(url, POSTGRES.getUsername(), POSTGRES.getPassword());
    }
}
