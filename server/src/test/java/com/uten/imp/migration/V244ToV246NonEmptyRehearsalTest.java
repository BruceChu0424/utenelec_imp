package com.uten.imp.migration;

import org.flywaydb.core.Flyway;
import org.flywaydb.core.api.output.MigrateResult;
import org.junit.jupiter.api.Test;
import org.junit.jupiter.api.condition.EnabledIfEnvironmentVariable;

import java.math.BigDecimal;
import java.sql.Connection;
import java.sql.DriverManager;
import java.sql.ResultSet;
import java.sql.SQLException;
import java.sql.Statement;
import java.util.Map;
import java.util.TreeMap;

import static org.assertj.core.api.Assertions.assertThat;

/**
 * Repeatable evidence for upgrading a fresh non-empty V244 clone through V245-V246.
 *
 * <p>This test intentionally refuses ordinary database names. Point it only at a disposable clone
 * whose name contains {@code rehearsal}; Flyway clean remains disabled.
 */
@EnabledIfEnvironmentVariable(
        named = "UTEN_RUN_REHEARSAL_DB_TESTS",
        matches = "(?i)true")
class V244ToV246NonEmptyRehearsalTest {

    private static final String URL_ENV = "UTEN_REHEARSAL_DB_URL";
    private static final String USER_ENV = "UTEN_REHEARSAL_DB_USER";
    private static final String PASSWORD_ENV = "UTEN_REHEARSAL_DB_PASSWORD";
    private static final String EXPECTED_DATABASE_ENV = "UTEN_REHEARSAL_DB_EXPECTED_NAME";

    @Test
    void migratesNonEmptyCloneWithoutChangingTableCountsOrPaymentTotals() throws Exception {
        String url = requiredEnv(URL_ENV);
        String user = requiredEnv(USER_ENV);
        String password = requiredEnv(PASSWORD_ENV);
        String expectedDatabase = requiredEnv(EXPECTED_DATABASE_ENV);

        Snapshot before;
        try (Connection connection = DriverManager.getConnection(url, user, password)) {
            String database = scalarText(connection, "SELECT current_database()");
            assertThat(database)
                    .as("safety guard: this destructive rehearsal must use an isolated clone")
                    .containsIgnoringCase("rehearsal")
                    .isEqualTo(expectedDatabase)
                    .isNotEqualTo("uten_imp");
            assertThat(latestSuccessfulVersion(connection)).isEqualTo("244");
            before = snapshot(connection);
            assertThat(before.paymentTotals().activeCount())
                    .as("the rehearsal must exercise non-empty historical payment data")
                    .isPositive();
        }

        MigrateResult result = Flyway.configure()
                .dataSource(url, user, password)
                .locations("classpath:db/migration")
                .baselineOnMigrate(false)
                .cleanDisabled(true)
                .validateMigrationNaming(true)
                .target("246")
                .load()
                .migrate();

        assertThat(result.migrationsExecuted).isEqualTo(2);

        try (Connection connection = DriverManager.getConnection(url, user, password)) {
            assertThat(latestSuccessfulVersion(connection)).isEqualTo("246");
            Snapshot after = snapshot(connection);
            assertThat(after.tableRows()).containsExactlyEntriesOf(before.tableRows());
            assertThat(after.scopeRows()).containsExactlyEntriesOf(before.scopeRows());
            assertThat(after.paymentTotals().activeCount())
                    .isEqualTo(before.paymentTotals().activeCount());
            assertThat(after.paymentTotals().amountOriginal())
                    .isEqualByComparingTo(before.paymentTotals().amountOriginal());
            assertThat(after.paymentTotals().amountLocal())
                    .isEqualByComparingTo(before.paymentTotals().amountLocal());
            assertThat(scalarLong(connection, """
                    SELECT COUNT(*)
                    FROM finance_payments
                    WHERE COALESCE(is_deleted, FALSE) = FALSE
                      AND amount_authority_version = 0
                    """))
                    .as("V246 must leave every historical active payment explicitly unverified")
                    .isEqualTo(before.paymentTotals().activeCount());
            assertThat(constraintDefinition(connection,
                    "user_data_scopes", "user_data_scopes_scope_check"))
                    .contains("'finance'::text");
            assertThat(constraintDefinition(connection,
                    "finance_payments", "finance_payments_amount_authority_version_chk"))
                    .contains("amount_authority_version")
                    .contains("0")
                    .contains("1");
        }

        Flyway.configure()
                .dataSource(url, user, password)
                .locations("classpath:db/migration")
                .cleanDisabled(true)
                .validateMigrationNaming(true)
                .target("246")
                .load()
                .validate();
    }

    private static Snapshot snapshot(Connection connection) throws SQLException {
        return new Snapshot(
                businessTableRows(connection),
                groupedCounts(connection, "SELECT scope, COUNT(*) FROM user_data_scopes GROUP BY scope"),
                paymentTotals(connection));
    }

    private static Map<String, Long> businessTableRows(Connection connection) throws SQLException {
        Map<String, Long> rows = new TreeMap<>();
        try (Statement tables = connection.createStatement();
             ResultSet result = tables.executeQuery("""
                     SELECT table_name
                     FROM information_schema.tables
                     WHERE table_schema = 'public'
                       AND table_type = 'BASE TABLE'
                       AND table_name <> 'flyway_schema_history'
                     ORDER BY table_name
                     """)) {
            while (result.next()) {
                String table = result.getString(1);
                try (Statement count = connection.createStatement();
                     ResultSet countResult = count.executeQuery(
                             "SELECT COUNT(*) FROM \"" + table.replace("\"", "\"\"") + "\"")) {
                    countResult.next();
                    rows.put(table, countResult.getLong(1));
                }
            }
        }
        return rows;
    }

    private static Map<String, Long> groupedCounts(Connection connection, String sql)
            throws SQLException {
        Map<String, Long> counts = new TreeMap<>();
        try (Statement statement = connection.createStatement();
             ResultSet result = statement.executeQuery(sql)) {
            while (result.next()) {
                counts.put(result.getString(1), result.getLong(2));
            }
        }
        return counts;
    }

    private static PaymentTotals paymentTotals(Connection connection) throws SQLException {
        try (Statement statement = connection.createStatement();
             ResultSet result = statement.executeQuery("""
                     SELECT COUNT(*),
                            COALESCE(SUM(amount_original), 0),
                            COALESCE(SUM(amount_local), 0)
                     FROM finance_payments
                     WHERE COALESCE(is_deleted, FALSE) = FALSE
                     """)) {
            result.next();
            return new PaymentTotals(
                    result.getLong(1), result.getBigDecimal(2), result.getBigDecimal(3));
        }
    }

    private static String latestSuccessfulVersion(Connection connection) throws SQLException {
        return scalarText(connection, """
                SELECT version
                FROM flyway_schema_history
                WHERE success
                ORDER BY installed_rank DESC
                LIMIT 1
                """);
    }

    private static String constraintDefinition(
            Connection connection, String table, String constraint) throws SQLException {
        String sql = """
                SELECT pg_get_constraintdef(c.oid)
                FROM pg_constraint c
                JOIN pg_class t ON t.oid = c.conrelid
                JOIN pg_namespace n ON n.oid = t.relnamespace
                WHERE n.nspname = 'public'
                  AND t.relname = '%s'
                  AND c.conname = '%s'
                """.formatted(table, constraint);
        return scalarText(connection, sql);
    }

    private static String scalarText(Connection connection, String sql) throws SQLException {
        try (Statement statement = connection.createStatement();
             ResultSet result = statement.executeQuery(sql)) {
            assertThat(result.next()).as("query returned a row: %s", sql).isTrue();
            return result.getString(1);
        }
    }

    private static long scalarLong(Connection connection, String sql) throws SQLException {
        try (Statement statement = connection.createStatement();
             ResultSet result = statement.executeQuery(sql)) {
            assertThat(result.next()).as("query returned a row: %s", sql).isTrue();
            return result.getLong(1);
        }
    }

    private static String requiredEnv(String name) {
        String value = System.getenv(name);
        assertThat(value).as("required environment variable %s", name).isNotBlank();
        return value;
    }

    private record Snapshot(
            Map<String, Long> tableRows,
            Map<String, Long> scopeRows,
            PaymentTotals paymentTotals) {}

    private record PaymentTotals(
            long activeCount,
            BigDecimal amountOriginal,
            BigDecimal amountLocal) {}
}
