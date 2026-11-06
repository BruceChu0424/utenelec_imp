package com.uten.imp.migration;

import com.fasterxml.jackson.databind.ObjectMapper;
import org.flywaydb.core.api.MigrationVersion;
import org.junit.jupiter.api.Test;

import java.math.BigDecimal;
import java.nio.file.Files;
import java.nio.file.Path;
import java.sql.Connection;
import java.sql.ResultSet;
import java.sql.Statement;
import java.util.HashMap;
import java.util.List;
import java.util.Map;

import static org.junit.jupiter.api.Assertions.*;
import static org.mockito.ArgumentMatchers.anyString;
import static org.mockito.Mockito.*;

class MigrationRehearsalVersionSnapshotTest {
    @Test
    void actualSnapshotKeepsDottedVersionAndConservationFactsWithoutIntegerParsing() throws Exception {
        var snapshot = MigrationRehearsalSupport.snapshot(database(List.of(
                List.of("999.11", "V999_11__eleventh.sql"),
                List.of("999.2", "V999_2__second.sql"),
                List.of("999.1", "V999_1__first.sql"))));
        assertEquals(MigrationVersion.fromVersion("999.11"), snapshot.schemaVersion());
        assertEquals(Map.of("audit_log", 0L), snapshot.tableRows());
        assertEquals("1|synthetic-id:fixture", snapshot.userIdentity());
        assertEquals(Map.of("SELF", 1L), snapshot.scopeRows());
        assertEquals(new MigrationRehearsalSupport.PaymentTotals(0, BigDecimal.ZERO, BigDecimal.ZERO), snapshot.paymentTotals());
        assertEquals(new MigrationRehearsalSupport.StockTotals(0, BigDecimal.ZERO), snapshot.stockTotals());
        MigrationRehearsalSupport.assertStableSnapshot(snapshot, snapshot);
    }

    @Test
    void headIsTheSemanticMaximumAndOnlyExactHistoricalScriptRetainsLeadingZero() throws Exception {
        assertEquals("1000", MigrationRehearsalSupport.latestSuccessfulVersion(database(List.of(
                List.of("999.11", "V999_11__prior.sql"),
                List.of("1000", "V1000__whole.sql"),
                List.of("999.2", "V999_2__later_installed.sql")))));
        assertEquals("1", MigrationRehearsalSupport.latestSuccessfulVersion(database(
                List.of(List.of("01", "V01__enable_pgcrypto.sql")))));
        for (var row : List.of(List.of("001", "V01__enable_pgcrypto.sql"),
                List.of("02", "V01__enable_pgcrypto.sql"),
                List.of("999_1", "V999_1__first.sql"))) {
            assertThrows(IllegalStateException.class,
                    () -> MigrationRehearsalSupport.latestSuccessfulVersion(database(List.of(row))));
        }
        assertThrows(IllegalStateException.class, () -> MigrationRehearsalSupport.latestSuccessfulVersion(database(List.of(
                List.of("999.1", "V999_1__first.sql"), List.of("999.1", "V999.1__alias.sql")))));
    }

    @Test
    void allSharedVersionVectorsAndTheExactNineLegacyNamesMatchJava() throws Exception {
        Path fixture = Path.of("contracts/flyway-version/fixtures.json");
        if (!Files.isRegularFile(fixture)) fixture = Path.of("..").resolve(fixture);
        var vectors = new ObjectMapper().readTree(Files.readString(fixture));
        MigrationVersion previous = MigrationVersion.fromVersion("0");
        for (var version : vectors.get("canonicalOrder")) {
            var actual = MigrationRehearsalSupport.migrationVersionForScript(
                    "V" + version.asText().replace('.', '_') + "__vector.sql");
            assertEquals(version.asText(), actual.getVersion());
            assertTrue(actual.compareTo(previous) > 0);
            previous = actual;
        }
        for (var legacy : vectors.get("legacyHistory")) {
            assertEquals(legacy.get("canonical").asText(),
                    MigrationRehearsalSupport.migrationVersionForScript(legacy.get("file").asText()).getVersion());
        }
        for (String filename : List.of("V001__enable_pgcrypto.sql", "V01__forged.sql", "V999_01__alias.sql",
                "V999_1_0__alias.sql", "V999.1_2__mixed.sql", "V0__zero.sql")) {
            assertThrows(IllegalArgumentException.class,
                    () -> MigrationRehearsalSupport.migrationVersionForScript(filename), filename);
        }
    }

    @Test
    void namespaceExceptionCrossesExact608BoundaryAndCannotBeReusedAfterward() {
        var before = new HashMap<>(Map.of("audit_log", 0L, "business_identifier_namespaces", 0L,
                "business_prefix_reservations", 0L, "business_prefix_reservation_members", 0L));
        var after = new HashMap<>(before);
        after.replaceAll((table, count) -> table.equals("audit_log") ? count : count + 1);
        MigrationRehearsalSupport.assertStableSnapshot(snapshot("607.99", before), snapshot("608", after));
        assertThrows(AssertionError.class, () -> MigrationRehearsalSupport.assertStableSnapshot(
                snapshot("608.1", before), snapshot("608.2", after)));
        assertThrows(AssertionError.class, () -> MigrationRehearsalSupport.assertStableSnapshot(
                snapshot("607.99", before), snapshot("607.100", after)));
    }

    private static MigrationRehearsalSupport.Snapshot snapshot(String version, Map<String, Long> rows) {
        return new MigrationRehearsalSupport.Snapshot(MigrationVersion.fromVersion(version), rows, "unchanged",
                Map.of(), new MigrationRehearsalSupport.PaymentTotals(0, BigDecimal.ZERO, BigDecimal.ZERO),
                new MigrationRehearsalSupport.StockTotals(0, BigDecimal.ZERO));
    }

    private static Connection database(List<List<String>> history) throws Exception {
        Connection connection = mock(Connection.class);
        Statement statement = mock(Statement.class);
        when(connection.createStatement()).thenReturn(statement);
        when(statement.executeQuery(anyString())).thenAnswer(invocation -> {
            String sql = invocation.getArgument(0);
            if (sql.contains("FROM flyway_schema_history")) return rows(history);
            if (sql.contains("FROM information_schema.tables")) return rows(List.of(List.of("audit_log")));
            if (sql.contains("FROM users")) return rows(List.of(List.of("1|synthetic-id:fixture")));
            if (sql.contains("FROM user_data_scopes")) return rows(List.of(List.of("SELF", 1L)));
            if (sql.contains("FROM finance_payments")) return rows(List.of(List.of(0L, BigDecimal.ZERO, BigDecimal.ZERO)));
            if (sql.contains("FROM stock_balances")) return rows(List.of(List.of(0L, BigDecimal.ZERO)));
            if (sql.contains("FROM \"audit_log\"")) return rows(List.of(List.of(0L)));
            throw new AssertionError("Unexpected snapshot query: " + sql);
        });
        return connection;
    }

    private static ResultSet rows(List<? extends List<?>> values) {
        int[] cursor = {-1};
        return mock(ResultSet.class, invocation -> {
            String method = invocation.getMethod().getName();
            if (method.equals("next")) return ++cursor[0] < values.size();
            if (method.equals("getString") || method.equals("getLong") || method.equals("getBigDecimal")) {
                Object value = values.get(cursor[0]).get(invocation.<Integer>getArgument(0) - 1);
                if (method.equals("getString")) return value.toString();
                if (method.equals("getLong")) return ((Number) value).longValue();
                return value;
            }
            return RETURNS_DEFAULTS.answer(invocation);
        });
    }
}
