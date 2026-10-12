package com.uten.imp.migration;

import org.flywaydb.core.Flyway;
import org.flywaydb.core.api.FlywayException;
import org.flywaydb.core.api.callback.Event;
import org.junit.jupiter.api.AfterAll;
import org.junit.jupiter.api.BeforeAll;
import org.junit.jupiter.api.Test;
import org.junit.jupiter.api.condition.EnabledIfEnvironmentVariable;
import org.junit.jupiter.api.io.TempDir;
import org.testcontainers.containers.PostgreSQLContainer;
import org.testcontainers.utility.MountableFile;

import java.nio.charset.StandardCharsets;
import java.nio.file.Files;
import java.nio.file.Path;
import java.sql.Connection;
import java.sql.DriverManager;
import java.sql.SQLException;
import java.sql.Statement;
import java.util.UUID;

import static org.junit.jupiter.api.Assertions.*;

/** Rehearses installed Main V845 with the actual V670/V830 overloads, not stub functions. */
@EnabledIfEnvironmentVariable(named = "UTEN_RUN_DB_TESTS", matches = "(?i)true")
class AuditRegistrationOverloadUpgradePostgresTest {
    private static final String SIX = "public.fn_audit_track_table(text,text,text,boolean,text[],boolean)";
    private static final String SEVEN = "public.fn_audit_track_table(text,text,text,boolean,text[],boolean,text)";
    private static final PostgreSQLContainer<?> DB = new PostgreSQLContainer<>("postgres:16-alpine")
            .withDatabaseName("audit_overload_845").withUsername("uten").withPassword("uten-test-only")
            .withCommand("postgres", "-c", "max_locks_per_transaction=512");
    @TempDir Path failedMigrations;

    @BeforeAll static void start() throws Exception {
        DB.start();
        // Local rehearsal can reuse an archive of this exact, empty canonical845
        // fixture. The default remains a fresh migration; both paths revalidate
        // every applied checksum before restoring either real historical overload.
        String archive = System.getProperty("uten.audit.overload.baselineArchive");
        if (archive != null) {
            DB.copyFileToContainer(MountableFile.forHostPath(archive), "/tmp/canonical845.dump");
            var restore = DB.execInContainer("pg_restore", "--exit-on-error", "--single-transaction", "--no-owner", "-U", DB.getUsername(), "-d", DB.getDatabaseName(), "/tmp/canonical845.dump");
            assertEquals(0, restore.getExitCode(), restore.getStderr());
        }
        flyway(DB.getDatabaseName(), "845", true, location()).migrate();
    }
    @AfterAll static void stop() { DB.stop(); }

    @Test void historicalSixPlusSevenOverloadsFailUnpatchedThenUpgradeAndPreserveAuditPolicies() throws Exception {
        String database = cloneDatabase("upgrade");
        String history;
        String seven;
        String branding;
        try (Connection connection = connection(database)) {
            restoreActualSixArgumentFunction(connection);
            assertBothOverloads(connection);
            history = history(connection, "845");
            seven = scalar(connection, "SELECT pg_get_functiondef('" + SEVEN + "'::regprocedure)");
            branding = auditTriggers(connection, "platform_branding");
        }
        FlywayException red = assertThrows(FlywayException.class,
                () -> flyway(database, "852", false, location()).migrate());
        assertEquals("42725", sqlState(red), "The original V846 four-argument call must reproduce ambiguity");
        try (Connection connection = connection(database)) {
            assertEquals("845", head(connection));
            assertEquals(history, history(connection, "845"));
            assertBothOverloads(connection);
        }
        flyway(database, "852", true, location()).migrate();
        try (Connection connection = connection(database)) {
            assertEquals("852", head(connection));
            assertEquals("778", scalar(connection, "SELECT count(*) FROM flyway_schema_history WHERE success"));
            assertNull(scalar(connection, "SELECT to_regprocedure('" + SIX + "')::text"));
            assertEquals(seven, scalar(connection, "SELECT pg_get_functiondef('" + SEVEN + "'::regprocedure)"));
            assertEquals(history, history(connection, "845"), "Already-applied checksums/rows are immutable");
            assertEquals(branding, auditTriggers(connection, "platform_branding"));
            assertEquals("0", auditTriggerCount(connection, "purchase_request_qty_revisions"));
            assertEquals("2", auditTriggerCount(connection, "document_unapprovals"));
            assertEquals("1", auditTriggerCount(connection, "platform_branding"));
            assertEquals("2", scalar(connection, "SELECT count(*) FROM pg_trigger WHERE tgrelid='document_unapprovals'::regclass AND tgfoid='fn_audit()'::regprocedure AND tgenabled='A'"));
            long before = Long.parseLong(scalar(connection, "SELECT count(*) FROM audit_log WHERE target_type='platform_branding'"));
            execute(connection, "UPDATE platform_branding SET tagline='audit-overload-upgrade-proof' WHERE id=1");
            assertEquals(Long.toString(before + 1), scalar(connection, "SELECT count(*) FROM audit_log WHERE target_type='platform_branding'"));
            execute(connection, "UPDATE platform_branding SET updated_at=updated_at+interval '1 second' WHERE id=1");
            assertEquals(Long.toString(before + 1), scalar(connection, "SELECT count(*) FROM audit_log WHERE target_type='platform_branding'"), "Unscoped metadata must not manufacture a branding event");
        }

        // An installation that already passed immutable V851 still gets cleanup from V852,
        // without requiring either compatibility callback to run again.
        String installed = cloneDatabase("installed_851");
        flyway(installed, "851", true, location()).migrate();
        String registered;
        try (Connection connection = connection(installed)) {
            assertEquals("777", scalar(connection, "SELECT count(*) FROM flyway_schema_history WHERE success"));
            restoreActualSixArgumentFunction(connection);
            registered = auditTriggers(connection, "document_unapprovals");
        }
        flyway(installed, "852", false, location()).migrate();
        try (Connection connection = connection(installed)) {
            assertEquals("852", head(connection));
            assertNull(scalar(connection, "SELECT to_regprocedure('" + SIX + "')::text"));
            assertEquals(registered, auditTriggers(connection, "document_unapprovals"));
        }
    }

    @Test void failedImmutableMigrationRollsBackCallbackDropAndPreservesBothFunctions() throws Exception {
        String database = cloneDatabase("rollback");
        String oldFunction;
        String seven;
        String history;
        try (Connection connection = connection(database)) {
            restoreActualSixArgumentFunction(connection);
            oldFunction = scalar(connection, "SELECT pg_get_functiondef('" + SIX + "'::regprocedure)");
            seven = scalar(connection, "SELECT pg_get_functiondef('" + SEVEN + "'::regprocedure)");
            history = history(connection, "845");
        }
        for (var resource : migrationResources()) {
            Files.writeString(failedMigrations.resolve(resource), resourceText(resource), StandardCharsets.UTF_8);
        }
        Path migration = failedMigrations.resolve("V846__proven_purchase_request_quantity_corrections.sql");
        Files.writeString(migration, Files.readString(migration) + "\nDO $$ BEGIN RAISE EXCEPTION 'audit-overload-transaction-failure' USING ERRCODE='P0001'; END $$;\n");
        FlywayException failure = assertThrows(FlywayException.class,
                () -> flyway(database, "846", true, "filesystem:" + failedMigrations).migrate());
        assertEquals("P0001", sqlState(failure));
        assertTrue(failure.getMessage().contains("audit-overload-transaction-failure"));
        try (Connection connection = connection(database)) {
            assertBothOverloads(connection);
            assertEquals(oldFunction, scalar(connection, "SELECT pg_get_functiondef('" + SIX + "'::regprocedure)"));
            assertEquals(seven, scalar(connection, "SELECT pg_get_functiondef('" + SEVEN + "'::regprocedure)"));
            assertEquals(history, history(connection, "845"));
            assertNull(scalar(connection, "SELECT to_regclass('public.purchase_request_qty_revisions')::text"));
        }
        flyway(database, "852", true, location()).migrate();
        try (Connection connection = connection(database)) {
            assertEquals("852", head(connection));
            assertNull(scalar(connection, "SELECT to_regprocedure('" + SIX + "')::text"));
        }
    }

    private static String location() { return System.getProperty("uten.audit.overload.migrations", "classpath:db/migration"); }
    private static java.util.List<String> migrationResources() throws Exception {
        // Flyway's resolver supplies the actual immutable inventory, including Main's V840.
        return java.util.Arrays.stream(flyway(DB.getDatabaseName(), "852", true, location()).info().all())
                .map(info -> info.getScript()).filter(script -> script.startsWith("V") && script.endsWith(".sql")).toList();
    }
    private static String resourceText(String name) throws Exception {
        try (var stream = AuditRegistrationOverloadUpgradePostgresTest.class.getClassLoader().getResourceAsStream("db/migration/" + name)) {
            assertNotNull(stream, name); return new String(stream.readAllBytes(), StandardCharsets.UTF_8);
        }
    }
    private static void restoreActualSixArgumentFunction(Connection connection) throws Exception {
        String v670 = resourceText("V670__audit_three_list_policy_change_only_rows.sql");
        int begin = v670.indexOf("CREATE OR REPLACE FUNCTION public.fn_audit_track_table(");
        int end = v670.indexOf("REVOKE ALL ON FUNCTION public.fn_audit_track_table", begin);
        assertTrue(begin > 0 && end > begin);
        execute(connection, v670.substring(begin, v670.indexOf(';', end) + 1));
    }
    private static void assertBothOverloads(Connection connection) throws SQLException {
        assertNotNull(scalar(connection, "SELECT to_regprocedure('" + SIX + "')::text"));
        assertNotNull(scalar(connection, "SELECT to_regprocedure('" + SEVEN + "')::text"));
    }
    private static Flyway flyway(String database, String target, boolean compatible, String location) {
        var config = Flyway.configure().dataSource(url(database), DB.getUsername(), DB.getPassword())
                .locations(location).target(target).cleanDisabled(true).initSql("SET client_min_messages=WARNING");
        if (compatible) config.callbacks(new AppliedMigrationCompatibilityCallback());
        return config.load();
    }
    private static String cloneDatabase(String label) throws SQLException {
        String database = "audit_overload_" + label + "_" + UUID.randomUUID().toString().replace("-", "");
        try (Connection connection = connection("postgres")) { execute(connection, "CREATE DATABASE \"" + database + "\" TEMPLATE \"" + DB.getDatabaseName() + "\""); }
        return database;
    }
    private static String url(String database) { return DB.getJdbcUrl().replace("/" + DB.getDatabaseName(), "/" + database); }
    private static Connection connection(String database) throws SQLException { return DriverManager.getConnection(url(database), DB.getUsername(), DB.getPassword()); }
    private static String head(Connection connection) throws SQLException { return scalar(connection, "SELECT version FROM flyway_schema_history WHERE success ORDER BY installed_rank DESC LIMIT 1"); }
    private static String history(Connection connection, String through) throws SQLException { return scalar(connection, "SELECT md5(string_agg(to_jsonb(history)::text,E'\\n' ORDER BY installed_rank)) FROM flyway_schema_history history WHERE version::numeric<=" + through); }
    private static String auditTriggerCount(Connection connection, String table) throws SQLException { return scalar(connection, "SELECT count(*) FROM pg_trigger WHERE tgrelid='" + table + "'::regclass AND tgfoid='fn_audit()'::regprocedure"); }
    private static String auditTriggers(Connection connection, String table) throws SQLException { return scalar(connection, "SELECT string_agg(pg_get_triggerdef(oid)||':'||tgenabled::text,E'\\n' ORDER BY tgname) FROM pg_trigger WHERE tgrelid='" + table + "'::regclass AND tgfoid='fn_audit()'::regprocedure"); }
    private static void execute(Connection connection, String sql) throws SQLException { try (Statement statement = connection.createStatement()) { statement.execute(sql); } }
    private static String scalar(Connection connection, String sql) throws SQLException { try (Statement statement = connection.createStatement(); var rows = statement.executeQuery(sql)) { assertTrue(rows.next()); return rows.getString(1); } }
    private static String sqlState(Throwable failure) { for (Throwable current = failure; current != null; current = current.getCause()) if (current instanceof SQLException sql) return sql.getSQLState(); return null; }
}
