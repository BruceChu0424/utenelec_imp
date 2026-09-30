package com.uten.imp.support;

import com.uten.imp.migration.MigrationRehearsalSupport;
import org.flywaydb.core.Flyway;
import org.junit.jupiter.api.Test;
import org.junit.jupiter.api.condition.EnabledIfEnvironmentVariable;

import java.sql.Connection;
import java.sql.SQLException;
import java.util.ArrayList;
import java.util.HashSet;
import java.util.List;
import java.util.concurrent.Callable;
import java.util.concurrent.Executors;

import static org.junit.jupiter.api.Assertions.*;

/** Real PostgreSQL proof of current migration history, clone isolation and lease cleanup. */
@EnabledIfEnvironmentVariable(named = "UTEN_RUN_DB_TESTS", matches = "(?i)true")
class MigratedSchemaBaselinePostgresTest {
    @Test
    void clonesCarryTheLatestMigratedSchemaWithoutSharingFixtureWrites() throws Exception {
        try (var first = MigratedSchemaBaseline.openDatabase("baseline_smoke");
             var second = MigratedSchemaBaseline.openDatabase("baseline_smoke");
             Connection firstConnection = first.openConnection();
             Connection secondConnection = second.openConnection()) {
            assertNotEquals(first.getJdbcUrl(), second.getJdbcUrl());
            assertEquals(1, MigratedSchemaBaseline.processMigrationCount());
            assertHead(firstConnection);
            assertHead(secondConnection);
            Flyway.configure().dataSource(second.getJdbcUrl(), second.getUsername(), second.getPassword())
                    .locations("classpath:db/migration").load().validate();

            assertColumn(firstConnection, "warehouses", "is_line_side");
            assertColumn(firstConnection, "production_execution_segments", "continuous_supply");
            assertColumn(secondConnection, "production_execution_segments", "start_route");
            try (var statement = firstConnection.createStatement()) {
                statement.execute("CREATE TABLE isolation_probe(id integer)");
                statement.execute("INSERT INTO isolation_probe VALUES (1)");
                statement.execute("ALTER TABLE warehouses ADD COLUMN lease_only_probe integer");
            }
            assertMissingProbe(secondConnection);
            // A later clone proves writes did not reach the immutable source template.
            try (var third = MigratedSchemaBaseline.openDatabase("baseline_later");
                 Connection thirdConnection = third.openConnection()) {
                assertMissingProbe(thirdConnection);
                assertHead(thirdConnection);
            }
        }
    }

    @Test
    void closingOneLeaseDropsItsDatabaseAndConnectionsWithoutStoppingOtherLeases() throws Exception {
        try (var observer = MigratedSchemaBaseline.openDatabase("baseline_observer");
             Connection observerConnection = observer.openConnection()) {
            var released = MigratedSchemaBaseline.openDatabase("baseline_released");
            try (released; Connection leaked = released.openConnection()) {
                String name;
                try (var query = leaked.createStatement(); var rows = query.executeQuery("SELECT current_database()")) {
                    assertTrue(rows.next());
                    name = rows.getString(1);
                }
                released.close();
                released.close();
                assertFalse(leaked.isValid(2), "dropping the lease must release even an accidentally retained session");
                assertThrows(IllegalStateException.class, released::openConnection);
                assertThrows(IllegalStateException.class, released::getJdbcUrl);
                try (var query = observerConnection.prepareStatement("SELECT count(*) FROM pg_database WHERE datname=?")) {
                    query.setString(1, name);
                    try (var rows = query.executeQuery()) {
                        assertTrue(rows.next());
                        assertEquals(0, rows.getInt(1));
                    }
                }
                assertHead(observerConnection);
            }
            try (var later = MigratedSchemaBaseline.openDatabase("baseline_after_close");
                 Connection connection = later.openConnection()) {
                assertHead(connection);
                assertEquals(1, MigratedSchemaBaseline.processMigrationCount());
            }
        }
    }

    @Test
    void concurrentCallersGetDistinctDatabasesFromOneMigration() throws Exception {
        List<MigratedSchemaBaseline.ScopedDatabase> leases = new ArrayList<>();
        try (var executor = Executors.newFixedThreadPool(3)) {
            List<Callable<MigratedSchemaBaseline.ScopedDatabase>> tasks = List.of(
                    () -> MigratedSchemaBaseline.openDatabase("baseline_parallel"),
                    () -> MigratedSchemaBaseline.openDatabase("baseline_parallel"),
                    () -> MigratedSchemaBaseline.openDatabase("baseline_parallel"));
            for (var result : executor.invokeAll(tasks)) leases.add(result.get());
            var urls = new HashSet<String>();
            for (var lease : leases) {
                urls.add(lease.getJdbcUrl());
                try (var connection = lease.openConnection()) { assertHead(connection); }
            }
            assertEquals(3, urls.size());
            assertEquals(1, MigratedSchemaBaseline.processMigrationCount());
        } finally {
            for (var lease : leases) lease.close();
        }
    }

    private static void assertHead(Connection connection) throws SQLException {
        try (var query = connection.createStatement();
             var rows = query.executeQuery("SELECT max(version::int) FROM flyway_schema_history WHERE success")) {
            assertTrue(rows.next());
            assertEquals(Integer.parseInt(MigrationRehearsalSupport.CURRENT_HEAD_VERSION), rows.getInt(1));
        }
    }

    private static void assertMissingProbe(Connection connection) throws SQLException {
        try (var query = connection.createStatement();
             var rows = query.executeQuery("""
                     SELECT (SELECT count(*) FROM information_schema.tables WHERE table_name='isolation_probe')
                          + (SELECT count(*) FROM information_schema.columns WHERE column_name='lease_only_probe')
                     """)) {
            assertTrue(rows.next());
            assertEquals(0, rows.getInt(1));
        }
    }

    private static void assertColumn(Connection connection, String table, String column) throws SQLException {
        try (var query = connection.prepareStatement("""
                SELECT count(*) FROM information_schema.columns WHERE table_schema='public'
                  AND table_name=? AND column_name=?
                """)) {
            query.setString(1, table);
            query.setString(2, column);
            try (var rows = query.executeQuery()) {
                assertTrue(rows.next());
                assertEquals(1, rows.getInt(1), table + "." + column);
            }
        }
    }
}
