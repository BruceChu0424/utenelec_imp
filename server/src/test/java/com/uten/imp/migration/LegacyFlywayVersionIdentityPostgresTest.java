package com.uten.imp.migration;

import com.uten.imp.support.MigratedSchemaBaseline;
import org.junit.jupiter.api.Test;
import org.junit.jupiter.api.condition.EnabledIfEnvironmentVariable;

import java.nio.charset.StandardCharsets;
import java.nio.file.Path;
import java.sql.Connection;
import java.util.ArrayList;
import java.util.List;
import java.util.concurrent.TimeUnit;

import static org.junit.jupiter.api.Assertions.*;

/** Execute the exact two loader queries against the real complete current history, never a company database. */
@EnabledIfEnvironmentVariable(named = "UTEN_RUN_DB_TESTS", matches = "(?i)true")
class LegacyFlywayVersionIdentityPostgresTest {
    @Test void completeCompoundHistoryAndEverySignificantIdentityStillFailClosed() throws Exception {
        String stateSql = queryFromOriginalLoader("--history-state-sql");
        String rowsSql = queryFromOriginalLoader("--history-rows-sql");
        List<String> expectedRows = FlywayChecksumManifestExporterTest.manifestContents(getClass().getClassLoader())
                .lines().skip(1).map(line -> {
                    var fields = line.split("\t", -1);
                    return FlywayChecksumManifestExporterTest.rawVersionFromFilename(fields[1]) + "\t" + fields[1] + "\t" + fields[2];
                }).toList();
        String count = Integer.toString(MigrationRehearsalSupport.CURRENT_MIGRATION_COUNT);
        List<String> expectedState = List.of(count + "|" + count + "|" + count + "|" + MigrationRehearsalSupport.CURRENT_HEAD_VERSION);
        try (var database = MigratedSchemaBaseline.openDatabase("legacy_version_identity");
             Connection connection = database.openConnection()) {
            connection.setReadOnly(true);
            assertEquals(expectedState, rows(connection, stateSql, "|"));
            assertEquals(expectedRows, rows(connection, rowsSql, "\t"));
            var versions = expectedRows.stream().map(row -> row.split("\t")[0]).toList();
            assertEquals(List.of("01","02","03","04","05","06","07","08","09"), versions.subList(0,9));
            assertTrue(versions.stream().filter(version -> version.contains(".")).count() >= 14);
            assertTrue(versions.indexOf("999.1") < versions.indexOf("999.9"));
            assertTrue(versions.indexOf("999.9") < versions.indexOf("999.10"));
            assertTrue(versions.indexOf("999.10") < versions.indexOf("999.13"));
            var expectedDescriptions = expectedRows.stream().map(row -> {
                var fields = row.split("\t", -1);
                return fields[0] + "\t" + fields[1] + "\t" + FlywayChecksumManifestExporterTest.historyDescriptionFromFilename(fields[1], null);
            }).toList();
            assertEquals(expectedDescriptions, rows(connection,
                    "SELECT version,script,description FROM flyway_schema_history ORDER BY string_to_array(version, '.')::numeric[]", "\t"));
            // All negative edits are rollback-only in this private disposable clone.
            connection.setReadOnly(false);connection.setAutoCommit(false);
            try {
                try (var statement = connection.createStatement()) {
                    statement.executeUpdate("UPDATE flyway_schema_history SET version='1' WHERE script='V01__enable_pgcrypto.sql'");
                }
                assertEquals(expectedState, rows(connection, stateSql, "|"));
                assertNotEquals(expectedRows, rows(connection, rowsSql, "\t"), "tuple equality cannot erase original V01/raw01 audit identity");
            } finally { connection.rollback(); }
            try {
                try (var statement = connection.createStatement()) {
                    statement.executeUpdate("UPDATE flyway_schema_history SET version='999.01' WHERE version='999.1'");
                }
                assertEquals(expectedState, rows(connection, stateSql, "|"));
                assertNotEquals(expectedRows, rows(connection, rowsSql, "\t"), "a numeric alias must not impersonate original text");
            } finally { connection.rollback(); }
            try {
                try (var statement = connection.createStatement()) {
                    statement.executeUpdate("UPDATE flyway_schema_history SET checksum=checksum # 1 WHERE version='999.10'");
                }
                assertEquals(expectedState, rows(connection, stateSql, "|"));
                assertNotEquals(expectedRows, rows(connection, rowsSql, "\t"), "counts and head do not authorize a wrong checksum");
            } finally { connection.rollback(); }
            try {
                try (var statement = connection.createStatement()) {
                    statement.executeUpdate("UPDATE flyway_schema_history SET version='999.10' WHERE script='V01__enable_pgcrypto.sql'");
                }
                assertNotEquals(expectedState, rows(connection, stateSql, "|"), "duplicate versions must fail the independent state gate");
                assertNotEquals(expectedRows, rows(connection, rowsSql, "\t"));
            } finally { connection.rollback(); }
            try {
                try (var statement = connection.createStatement()) {
                    statement.executeUpdate("UPDATE flyway_schema_history SET success=false WHERE version='999.10'");
                }
                assertNotEquals(expectedState, rows(connection, stateSql, "|"), "unsuccessful rows must fail before import");
            } finally { connection.rollback(); }
            try {
                try (var statement = connection.createStatement()) {
                    statement.executeUpdate("""
                            INSERT INTO flyway_schema_history(installed_rank,version,description,type,script,checksum,installed_by,execution_time,success)
                            SELECT max(installed_rank)+1,NULL,'unregistered repeatable','SQL','R__unregistered.sql',0,current_user,0,true
                            FROM flyway_schema_history
                            """);
                }
                assertNotEquals(expectedState, rows(connection, stateSql, "|"), "a null/repeatable row cannot disappear from the complete state gate");
            } finally { connection.rollback(); }
            assertEquals(expectedState, rows(connection, stateSql, "|"));
            assertEquals(expectedRows, rows(connection, rowsSql, "\t"));
        }
    }

    private static String queryFromOriginalLoader(String selector) throws Exception {
        String python = System.getenv().getOrDefault("UTEN_PYTHON_EXECUTABLE", "python3");
        Process process = new ProcessBuilder(python, "-I",
                Path.of("legacy_migration", "verify_candidate.py").toAbsolutePath().toString(), selector)
                .redirectErrorStream(true).start();
        try {
            assertTrue(process.waitFor(30, TimeUnit.SECONDS), "fixed readonly loader query did not finish");
            String output = new String(process.getInputStream().readAllBytes(), StandardCharsets.UTF_8).strip();
            assertEquals(0, process.exitValue(), output);
            assertTrue(output.startsWith("SELECT "), output);
            assertFalse(output.contains(";"), "the fixed selector exposes exactly one read-only query");
            assertTrue(output.contains("string_to_array(version, '.')::numeric[]"));
            return output;
        } finally {
            if (process.isAlive()) { process.destroyForcibly();process.waitFor(5, TimeUnit.SECONDS); }
        }
    }

    private static List<String> rows(Connection connection, String sql, String separator) throws Exception {
        var result = new ArrayList<String>();
        try (var statement = connection.createStatement();var rows = statement.executeQuery(sql)) {
            int columns = rows.getMetaData().getColumnCount();
            while (rows.next()) {
                var values = new ArrayList<String>();
                for (int index = 1; index <= columns; index++) values.add(rows.getString(index));
                result.add(String.join(separator, values));
            }
        }
        return result;
    }
}
