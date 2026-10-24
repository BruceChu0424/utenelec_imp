package com.uten.imp.migration;

import java.nio.file.Files;
import java.nio.file.Path;
import java.sql.Connection;
import java.sql.DriverManager;
import java.sql.Savepoint;
import java.sql.SQLException;
import java.util.UUID;
import java.util.regex.Pattern;
import java.util.stream.Stream;
import org.junit.jupiter.api.AfterAll;
import org.junit.jupiter.api.AfterEach;
import org.junit.jupiter.api.BeforeAll;
import org.junit.jupiter.api.BeforeEach;
import org.junit.jupiter.api.Test;
import org.junit.jupiter.api.condition.EnabledIfEnvironmentVariable;
import org.junit.jupiter.params.ParameterizedTest;
import org.junit.jupiter.params.provider.Arguments;
import org.junit.jupiter.params.provider.MethodSource;
import org.testcontainers.postgresql.PostgreSQLContainer;
import static org.assertj.core.api.Assertions.assertThat;
import static org.assertj.core.api.Assertions.assertThatThrownBy;

/** Runs the actual offline-import resolver in a private, disposable database. */
@EnabledIfEnvironmentVariable(named = "UTEN_RUN_DB_TESTS", matches = "(?i)true")
class LegacyOwnerResolutionPostgresTest {
    private static final PostgreSQLContainer PG = new PostgreSQLContainer("postgres:16-alpine");
    private static Connection connection;
    private Savepoint before;
    private record Resolution(UUID owner, UUID original, String reason) {}
    private static UUID id(long value) { return new UUID(0, value); }

    @BeforeAll static void initialize() throws Exception {
        PG.start();
        connection = DriverManager.getConnection(PG.getJdbcUrl(), PG.getUsername(), PG.getPassword());
        connection.setAutoCommit(false);
        com.uten.imp.support.MigratedProjectionSchema.createCurrentColumns(
                new org.springframework.jdbc.core.JdbcTemplate(
                        new org.springframework.jdbc.datasource.SingleConnectionDataSource(connection,true)),
                "employees","users");
        String resolver = Files.readString(Path.of("legacy_migration/migrate_owner_custody.sql"));
        var login = Pattern.compile("u\\.login_account='([^']+)'").matcher(resolver);
        if (!login.find()) throw new IllegalStateException("The resolver must bind one reviewed custodian login");
        try (var statement = connection.createStatement()) {
            statement.execute("ALTER TABLE employees ADD PRIMARY KEY(id)");
            statement.execute(resolver);
        }
        try (var statement = connection.prepareStatement("INSERT INTO employees(id,legacy_id,code,status,is_deleted) VALUES (?,?,?,?,?)")) {
            Object[][] rows = {
                    {1L, null, "ADMIN", "active", false},
                    {2L, 501, "UT2", "active", false},
                    {3L, 502, "UT3", "probation", false},
                    {4L, 503, "UT4", "onLeave", false},
                    {5L, 504, "UT5", "resigned", false},
                    {6L, 505, "UT6", "active", true},
                    {7L, 506, "UT7", "active", false},
                    {8L, 506, "UT8", "active", false},
                    {9L, Integer.MAX_VALUE, "UT9", "active", false}
            };
            for (Object[] row : rows) {
                statement.setObject(1, id((Long) row[0]));
                for (int i = 1; i < row.length; i++) statement.setObject(i + 1, row[i]);
                statement.executeUpdate();
            }
        }
        try (var statement = connection.prepareStatement("INSERT INTO users(employee_id,login_account,is_super_admin,status,is_deleted) VALUES (?,?,true,'active',false)")) {
            statement.setObject(1, id(1));
            statement.setString(2, login.group(1));
            statement.executeUpdate();
        }
    }

    @AfterAll static void close() throws Exception {
        try {
            if (connection != null) connection.close();
        } finally { PG.stop(); }
    }
    @BeforeEach void savepoint() throws Exception { before = connection.setSavepoint(); }
    @AfterEach void restore() throws Exception {
        connection.rollback(before);
        connection.releaseSavepoint(before);
    }

    static Stream<Arguments> references() {
        return Stream.of(
                Arguments.of(null, null, null, "PUBLIC_SOURCE"),
                Arguments.of("", null, null, "PUBLIC_SOURCE"),
                Arguments.of("  ", null, null, "PUBLIC_SOURCE"),
                Arguments.of("000", null, null, "PUBLIC_SOURCE"),
                Arguments.of("501", id(2), id(2), "CURRENT_EMPLOYEE"),
                Arguments.of(" 501 ", id(2), id(2), "CURRENT_EMPLOYEE"),
                Arguments.of("00501", id(2), id(2), "CURRENT_EMPLOYEE"),
                Arguments.of("502", id(3), id(3), "CURRENT_EMPLOYEE"),
                Arguments.of("503", id(4), id(4), "CURRENT_EMPLOYEE"),
                Arguments.of("504", id(1), id(5), "SOURCE_EMPLOYEE_NOT_CURRENT"),
                Arguments.of("505", id(1), id(6), "SOURCE_EMPLOYEE_DELETED"),
                Arguments.of("506", id(1), null, "SOURCE_EMPLOYEE_AMBIGUOUS"),
                Arguments.of("507", id(1), null, "SOURCE_EMPLOYEE_MISSING"),
                Arguments.of("2147483647", id(9), id(9), "CURRENT_EMPLOYEE"),
                Arguments.of("2147483648", id(1), null, "UNRESOLVED_SOURCE_REFERENCE"),
                Arguments.of("501x", id(1), null, "UNRESOLVED_SOURCE_REFERENCE"),
                Arguments.of("Employee Name", id(1), null, "UNRESOLVED_SOURCE_REFERENCE"));
    }

    @ParameterizedTest @MethodSource("references")
    void preservesPublicSourcesAndRoutesEveryNoncurrentIdentityToExplicitCustody(
            String reference, UUID owner, UUID original, String reason) throws Exception {
        assertThat(resolve(reference)).isEqualTo(new Resolution(owner, original, reason));
    }

    @Test void missingCustodianCannotSilentlyMakeUnknownSourcesPublic() throws Exception {
        try (var statement = connection.createStatement()) { statement.executeUpdate("DELETE FROM users"); }
        assertThatThrownBy(() -> resolve("507")).isInstanceOf(SQLException.class)
                .hasMessageContaining("requires the unique preserved active super-administrator");
    }

    @Test void ambiguousCustodianCannotPickOne() throws Exception {
        try (var statement = connection.createStatement()) {
            statement.executeUpdate("INSERT INTO users SELECT * FROM users");
        }
        assertThatThrownBy(() -> resolve("507")).isInstanceOf(SQLException.class)
                .hasMessageContaining("requires the unique preserved active super-administrator");
    }

    private static Resolution resolve(String reference) throws Exception {
        try (var statement = connection.prepareStatement("SELECT * FROM pg_temp.legacy_owner_resolution(?)")) {
            statement.setString(1, reference);
            try (var row = statement.executeQuery()) {
                assertThat(row.next()).isTrue();
                Resolution result = new Resolution(row.getObject("owner_id", UUID.class),
                        row.getObject("original_employee_id", UUID.class), row.getString("reason"));
                assertThat(row.next()).isFalse();
                return result;
            }
        }
    }
}
