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
import java.sql.SQLException;
import java.sql.Statement;
import java.util.UUID;

import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertNull;
import static org.junit.jupiter.api.Assertions.assertThrows;
import static org.junit.jupiter.api.Assertions.assertTrue;

@EnabledIfEnvironmentVariable(named = "UTEN_RUN_DB_TESTS", matches = "(?i)true")
class SystemPostingStyleUuidRolePostgresTest {

    private static final PostgreSQLContainer<?> POSTGRES =
            new PostgreSQLContainer<>("postgres:16-alpine")
                    .withDatabaseName("uten_imp")
                    .withUsername("uten")
                    .withPassword("uten");

    @BeforeAll
    static void migrate() {
        POSTGRES.start();
        Flyway.configure()
                .dataSource(POSTGRES.getJdbcUrl(), POSTGRES.getUsername(), POSTGRES.getPassword())
                .locations("classpath:db/migration")
                .target("278")
                .load()
                .migrate();
    }

    @AfterAll
    static void stop() {
        POSTGRES.stop();
    }

    @Test
    void emptyDatabaseStaysUnmappedAndRuntimeAndGuardsAreUuidOnly() throws Exception {
        UUID styleId = UUID.randomUUID();
        try (Connection connection = connection()) {
            assertEquals(7, scalar(connection,
                    "SELECT COUNT(*) FROM system_posting_style_roles"));
            assertNull(object(connection,
                    "SELECT system_posting_style_id('AR_CONTROL')"));

            try (PreparedStatement insert = connection.prepareStatement("""
                    INSERT INTO payment_styles
                        (id, code, name, category, path, status, is_deleted)
                    VALUES (?, 'V278-AR', '测试应收', 'ACCOUNT', '/V278-AR/', '使用', false)
                    """)) {
                insert.setObject(1, styleId);
                assertEquals(1, insert.executeUpdate());
            }
            try (PreparedStatement map = connection.prepareStatement("""
                    UPDATE system_posting_style_roles SET style_id=?
                    WHERE role_key='AR_CONTROL'
                    """)) {
                map.setObject(1, styleId);
                assertEquals(1, map.executeUpdate());
            }
            assertEquals(styleId, object(connection,
                    "SELECT system_posting_style_id('AR_CONTROL')"));

            try (PreparedStatement rename = connection.prepareStatement(
                    "UPDATE payment_styles SET name='已重命名应收' WHERE id=?")) {
                rename.setObject(1, styleId);
                assertEquals(1, rename.executeUpdate());
            }
            assertEquals(styleId, object(connection,
                    "SELECT system_posting_style_id('AR_CONTROL')"));
        }

        assertSqlState("23514", """
                UPDATE payment_styles SET status='禁用' WHERE id='%s'
                """.formatted(styleId));
        assertSqlState("23514", """
                UPDATE system_posting_style_roles SET role_key='AR_CONTROL_CHANGED'
                WHERE role_key='AR_CONTROL'
                """);
        assertSqlState("23514", """
                DELETE FROM system_posting_style_roles WHERE role_key='AR_CONTROL'
                """);
    }

    @Test
    void v277ToV278BackfillsEveryUniquelyReviewedLocatorToItsExactUuid() throws Exception {
        String url = createDatabase("uten_v278_unique");
        flyway(url, "277").migrate();

        UUID ar = UUID.randomUUID();
        UUID revenue = UUID.randomUUID();
        UUID inventory = UUID.randomUUID();
        UUID ap = UUID.randomUUID();
        UUID cost = UUID.randomUUID();
        UUID fee = UUID.randomUUID();
        UUID fx = UUID.randomUUID();
        try (Connection connection = DriverManager.getConnection(
                url, POSTGRES.getUsername(), POSTGRES.getPassword())) {
            try (Statement renameSeeds = connection.createStatement()) {
                renameSeeds.executeUpdate("""
                        UPDATE payment_styles SET name='旧手续费种子'
                        WHERE category='EXPENSE' AND name='手续费'
                        """);
                renameSeeds.executeUpdate("""
                        UPDATE payment_styles SET name='旧汇兑种子'
                        WHERE category='EXPENSE' AND name='汇兑损益'
                        """);
            }
            insertStyle(connection, ar, "113", "应收账款", "ACCOUNT", "/113/");
            insertStyle(connection, revenue, "031", "销售收入", "INCOME", "/031/");
            insertStyle(connection, inventory, "123", "库存商品", "ACCOUNT", "/123/");
            insertStyle(connection, ap, "203", "应付账款", "LIABILITY", "/203/");
            insertStyle(connection, cost, "041", "销售成本", "EXPENSE", "/041/");
            insertStyle(connection, fee, "V278-FEE", "手续费", "EXPENSE", "/V278-FEE/");
            insertStyle(connection, fx, "V278-FX", "汇兑损益", "EXPENSE", "/V278-FX/");
        }

        assertEquals(1, flyway(url, "278").migrate().migrationsExecuted);
        try (Connection connection = DriverManager.getConnection(
                url, POSTGRES.getUsername(), POSTGRES.getPassword())) {
            assertRole(connection, "AR_CONTROL", ar);
            assertRole(connection, "SALES_REVENUE", revenue);
            assertRole(connection, "INVENTORY_ASSET", inventory);
            assertRole(connection, "AP_CONTROL", ap);
            assertRole(connection, "SALES_COST", cost);
            assertRole(connection, "BANK_FEE_EXPENSE", fee);
            assertRole(connection, "FX_GAIN_LOSS", fx);
        }
    }

    @Test
    void v278LeavesAmbiguousHistoricalNameUnmappedInsteadOfPickingFirst() throws Exception {
        String url = createDatabase("uten_v278_ambiguous");
        flyway(url, "277").migrate();
        try (Connection connection = DriverManager.getConnection(
                url, POSTGRES.getUsername(), POSTGRES.getPassword())) {
            insertStyle(connection, UUID.randomUUID(), "V278-FEE-DUP",
                    "手续费", "EXPENSE", "/V278-FEE-DUP/");
        }

        assertEquals(1, flyway(url, "278").migrate().migrationsExecuted);
        try (Connection connection = DriverManager.getConnection(
                url, POSTGRES.getUsername(), POSTGRES.getPassword())) {
            assertNull(object(connection,
                    "SELECT style_id FROM system_posting_style_roles "
                            + "WHERE role_key='BANK_FEE_EXPENSE'"));
            assertNull(object(connection,
                    "SELECT system_posting_style_id('BANK_FEE_EXPENSE')"));
        }
    }

    private static void insertStyle(Connection connection, UUID id, String code,
                                    String name, String category, String path)
            throws SQLException {
        try (PreparedStatement insert = connection.prepareStatement("""
                INSERT INTO payment_styles
                    (id, code, name, category, path, status, is_deleted)
                VALUES (?, ?, ?, ?, ?, '使用', false)
                """)) {
            insert.setObject(1, id);
            insert.setString(2, code);
            insert.setString(3, name);
            insert.setString(4, category);
            insert.setString(5, path);
            assertEquals(1, insert.executeUpdate());
        }
    }

    private static void assertRole(Connection connection, String role, UUID expected)
            throws SQLException {
        try (PreparedStatement query = connection.prepareStatement("""
                SELECT style_id FROM system_posting_style_roles WHERE role_key=?
                """)) {
            query.setString(1, role);
            try (ResultSet result = query.executeQuery()) {
                assertTrue(result.next());
                assertEquals(expected, result.getObject(1));
            }
        }
    }

    private static String createDatabase(String name) throws SQLException {
        try (Connection admin = connection(); Statement create = admin.createStatement()) {
            create.execute("CREATE DATABASE " + name);
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

    private static void assertSqlState(String expected, String sql) {
        SQLException failure = assertThrows(SQLException.class, () -> {
            try (Connection connection = connection(); Statement statement = connection.createStatement()) {
                statement.executeUpdate(sql);
            }
        });
        assertEquals(expected, failure.getSQLState());
    }

    private static int scalar(Connection connection, String sql) throws SQLException {
        try (Statement statement = connection.createStatement();
             ResultSet result = statement.executeQuery(sql)) {
            assertTrue(result.next());
            return result.getInt(1);
        }
    }

    private static Object object(Connection connection, String sql) throws SQLException {
        try (Statement statement = connection.createStatement();
             ResultSet result = statement.executeQuery(sql)) {
            assertTrue(result.next());
            return result.getObject(1);
        }
    }

    private static Connection connection() throws SQLException {
        return DriverManager.getConnection(
                POSTGRES.getJdbcUrl(), POSTGRES.getUsername(), POSTGRES.getPassword());
    }
}
