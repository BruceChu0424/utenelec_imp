package com.uten.imp.migration;

import org.flywaydb.core.Flyway;
import org.junit.jupiter.api.AfterAll;
import org.junit.jupiter.api.BeforeAll;
import org.junit.jupiter.api.Test;
import org.junit.jupiter.api.condition.EnabledIfEnvironmentVariable;
import org.testcontainers.containers.PostgreSQLContainer;

import java.sql.Connection;
import java.sql.DriverManager;
import java.sql.ResultSet;
import java.sql.SQLException;
import java.sql.Statement;
import java.util.UUID;

import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertThrows;
import static org.junit.jupiter.api.Assertions.assertTrue;

/** Non-empty V283 -> V284 rehearsal for sensitive profile-change snapshots. */
@EnabledIfEnvironmentVariable(named = "UTEN_RUN_DB_TESTS", matches = "(?i)true")
class ProfileChangeSnapshotProtectionPostgresTest {

    private static final PostgreSQLContainer<?> POSTGRES =
            new PostgreSQLContainer<>("postgres:16-alpine")
                    .withDatabaseName("uten_imp")
                    .withUsername("uten")
                    .withPassword("uten");

    private static UUID sensitiveRowId;

    @BeforeAll
    static void migrateAndSeedHistoricalLeakShape() throws Exception {
        POSTGRES.start();
        flyway("283").migrate();
        sensitiveRowId = UUID.randomUUID();
        UUID employeeId;
        UUID batchId = UUID.randomUUID();

        try (Connection connection = connection(); Statement statement = connection.createStatement()) {
            try (ResultSet result = statement.executeQuery(
                    "SELECT id FROM employees WHERE code = 'ADMIN'")) {
                assertTrue(result.next());
                employeeId = result.getObject(1, UUID.class);
            }
            // Seed the exact old row shape without inventing unrelated employee fixtures.
            // This is test-only setup before V284; production migration never disables triggers.
            statement.execute("SET session_replication_role = replica");
            statement.executeUpdate("""
                    INSERT INTO profile_change_requests (
                        id, employee_id, batch_id, field_code, field_label, field_group,
                        old_value_enc, new_value_enc, status, submitted_by, submitted_at,
                        employee_version, idem_key, created_at, updated_at)
                    VALUES (
                        '%s', '%s', '%s', 'phone', '手机号', 'contact',
                        '13700137000', '13800138000', 'pending', '%s', now(),
                        0, 'v284-sensitive', now(), now()),
                    (
                        '%s', '%s', '%s', 'fullName', '姓名', 'identity',
                        '旧姓名', '新姓名', 'pending', '%s', now(),
                        0, 'v284-plain', now(), now())
                    """.formatted(
                    sensitiveRowId, employeeId, batchId, employeeId,
                    UUID.randomUUID(), employeeId, batchId, employeeId));
            statement.executeUpdate("""
                    INSERT INTO audit_log (
                        action, target_type, target_id, before, "after", result)
                    VALUES (
                        'update', 'profile_change_requests', '%s',
                        '{"old_value_enc":"13700137000","status":"pending"}'::jsonb,
                        '{"new_value_enc":"13800138000","status":"approved"}'::jsonb,
                        'success'),
                    (
                        'UPDATE', 'profileChangeRequest', '%s',
                        '{"old_value_enc":"legacy-address"}'::jsonb,
                        '{"new_value_enc":"new-address"}'::jsonb,
                        'success')
                    """.formatted(sensitiveRowId, sensitiveRowId));
            statement.execute("SET session_replication_role = origin");
        }

        assertEquals(1, flyway("284").migrate().migrationsExecuted);
    }

    @AfterAll
    static void stopPostgres() {
        POSTGRES.stop();
    }

    @Test
    void v284ClassifiesHistoryCleansAuditCopiesAndBlocksUseUntilJvmBackfill()
            throws Exception {
        try (Connection connection = connection(); Statement statement = connection.createStatement()) {
            assertEquals("LEGACY_UNKNOWN", scalarText(statement, """
                    SELECT value_encoding
                    FROM profile_change_requests
                    WHERE id = '%s'
                    """.formatted(sensitiveRowId)));
            assertEquals("PLAIN", scalarText(statement, """
                    SELECT value_encoding
                    FROM profile_change_requests
                    WHERE field_code = 'fullName'
                    """));
            assertEquals(0, scalarInt(statement, """
                    SELECT count(*)
                    FROM audit_log
                    WHERE target_type IN ('profile_change_requests', 'profileChangeRequest')
                      AND (
                          COALESCE(before ?| ARRAY['old_value_enc','new_value_enc'], false)
                          OR COALESCE("after" ?| ARRAY['old_value_enc','new_value_enc'], false)
                      )
                    """));

            SQLException error = assertThrows(SQLException.class, () ->
                    statement.executeUpdate("""
                            UPDATE profile_change_requests
                            SET status = 'approved'
                            WHERE id = '%s'
                            """.formatted(sensitiveRowId)));
            assertEquals("P0001", error.getSQLState());
        }
    }

    @Test
    void v284RejectsNewSensitivePlaintextEvenWhenColumnNamesSayEnc() throws Exception {
        try (Connection connection = connection(); Statement statement = connection.createStatement()) {
            SQLException error = assertThrows(SQLException.class, () ->
                    statement.executeUpdate("""
                            INSERT INTO profile_change_requests (
                                employee_id, batch_id, field_code, field_label, field_group,
                                old_value_enc, new_value_enc, value_encoding, status,
                                submitted_by, submitted_at, employee_version, idem_key)
                            SELECT employee_id, gen_random_uuid(), 'hujiAddress', '户籍地址',
                                   'address', '旧地址', '新地址', 'PLAIN', 'pending',
                                   submitted_by, now(), 0, 'v284-reject-plain'
                            FROM profile_change_requests
                            WHERE id = '%s'
                            """.formatted(sensitiveRowId)));
            assertEquals("P0001", error.getSQLState());
        }
    }

    @Test
    void v284RejectsOldProcessStatusMutationWithoutCodecCapability() throws Exception {
        UUID protectedId = UUID.randomUUID();
        try (Connection connection = connection(); Statement statement = connection.createStatement()) {
            statement.execute("SELECT set_config('app.profile_change_snapshot_codec', 'v1', false)");
            statement.executeUpdate("""
                    INSERT INTO profile_change_requests (
                        id, employee_id, batch_id, field_code, field_label, field_group,
                        old_value_enc, new_value_enc, value_encoding, status,
                        submitted_by, submitted_at, employee_version, idem_key)
                    SELECT '%s', employee_id, gen_random_uuid(), 'phone', '手机号', 'contact',
                           '1:YWJjZGVmZ2g=', '1:YWJjZGVmZ2g=', 'PGCRYPTO_V1', 'pending',
                           submitted_by, now(), 0, 'v284-old-process-%s'
                    FROM profile_change_requests
                    WHERE id = '%s'
                    """.formatted(protectedId, protectedId, sensitiveRowId));

            statement.execute("SELECT set_config('app.profile_change_snapshot_codec', '', false)");
            SQLException rejected = assertThrows(SQLException.class, () ->
                    statement.executeUpdate("""
                            UPDATE profile_change_requests
                            SET status = 'rejected'
                            WHERE id = '%s'
                            """.formatted(protectedId)));
            assertEquals("P0001", rejected.getSQLState());

            statement.execute("SELECT set_config('app.profile_change_snapshot_codec', 'v1', false)");
            assertEquals(1, statement.executeUpdate("""
                    UPDATE profile_change_requests
                    SET status = 'rejected'
                    WHERE id = '%s'
                    """.formatted(protectedId)));
        }
    }

    private static String scalarText(Statement statement, String sql) throws Exception {
        try (ResultSet result = statement.executeQuery(sql)) {
            assertTrue(result.next());
            return result.getString(1);
        }
    }

    private static int scalarInt(Statement statement, String sql) throws Exception {
        try (ResultSet result = statement.executeQuery(sql)) {
            assertTrue(result.next());
            return result.getInt(1);
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
