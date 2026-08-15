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
import java.time.Instant;
import java.time.LocalDate;
import java.util.UUID;

import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertFalse;
import static org.junit.jupiter.api.Assertions.assertNull;
import static org.junit.jupiter.api.Assertions.assertThrows;
import static org.junit.jupiter.api.Assertions.assertTrue;

/** PostgreSQL proof for the V288/V289 borrow ownership, endpoint and lifecycle guards. */
@EnabledIfEnvironmentVariable(named = "UTEN_RUN_DB_TESTS", matches = "(?i)true")
class ProductionMaterialAnalysisBorrowMigrationPostgresTest {

    private static final PostgreSQLContainer<?> POSTGRES =
            new PostgreSQLContainer<>("postgres:16-alpine")
                    .withDatabaseName("uten_imp")
                    .withUsername("uten")
                    .withPassword("uten");

    @BeforeAll
    static void migrate() {
        POSTGRES.start();
        Flyway.configure()
                .dataSource(
                        POSTGRES.getJdbcUrl(), POSTGRES.getUsername(), POSTGRES.getPassword())
                .locations("classpath:db/migration")
                .target("289")
                .load()
                .migrate();
    }

    @AfterAll
    static void stopPostgres() {
        POSTGRES.stop();
    }

    @Test
    void directRevokedInsertIsRejectedBeforeForeignKeyEvaluation() throws Exception {
        try (Connection connection = connection(); Statement statement = connection.createStatement()) {
            SQLException rejected = assertThrows(SQLException.class, () ->
                    statement.executeUpdate("""
                            INSERT INTO production_material_analysis_borrows (
                                analysis_id, from_material_id, to_material_id,
                                goods_id, unit_id, qty, reason, status,
                                last_effective_qty, idempotency_key, created_by,
                                revoked_by, revoked_at, revoke_reason)
                            VALUES (
                                '28900000-0000-4000-8100-000000000001',
                                '28900000-0000-4000-8100-000000000002',
                                '28900000-0000-4000-8100-000000000003',
                                '28900000-0000-4000-8100-000000000004',
                                '28900000-0000-4000-8100-000000000005',
                                1, 'direct revoked bypass', 'REVOKED', 0,
                                'V289-DIRECT-REVOKED-BYPASS',
                                '28900000-0000-4000-8100-000000000006',
                                '28900000-0000-4000-8100-000000000006',
                                now(), 'must be rejected')
                            """));
            assertEquals("55000", rejected.getSQLState(),
                    "The lifecycle guard must reject REVOKED before missing FKs can surface");
        }
    }

    @Test
    void activeInsertCannotForgeAnAlreadyEffectiveAllocation() throws Exception {
        try (Connection connection = connection()) {
            Fixture fixture = fixture(connection);
            setActor(connection, fixture.userId());

            assertSqlState(connection, "55000", """
                    INSERT INTO production_material_analysis_borrows (
                        id, analysis_id, from_material_id, to_material_id,
                        goods_id, unit_id, qty, reason, status,
                        last_effective_qty, idempotency_key, created_by)
                    VALUES (?, ?, ?, ?, ?, ?, 10, 'forged effective quantity',
                            'ACTIVE', 1, ?, ?)
                    """, fixture.borrowId(), fixture.analysisId(),
                    fixture.fromMaterialId(), fixture.toMaterialId(),
                    fixture.goodsId(), fixture.unitId(),
                    "V289-forged-" + fixture.borrowId(), fixture.userId());
        }
    }

    @Test
    void compositeOwnerForeignKeysRejectEndpointsFromAnotherAnalysis() throws Exception {
        try (Connection connection = connection()) {
            Fixture fixture = fixture(connection);
            setActor(connection, fixture.userId());

            assertSqlState(connection, "23503", """
                    INSERT INTO production_material_analysis_borrows (
                        id, analysis_id, from_material_id, to_material_id,
                        goods_id, unit_id, qty, reason, status,
                        last_effective_qty, idempotency_key, created_by)
                    VALUES (?, ?, ?, ?, ?, ?, 10, 'cross analysis endpoints',
                            'ACTIVE', 0, ?, ?)
                    """, fixture.borrowId(), fixture.otherAnalysisId(),
                    fixture.fromMaterialId(), fixture.toMaterialId(),
                    fixture.goodsId(), fixture.unitId(),
                    "V289-cross-analysis-" + fixture.borrowId(), fixture.userId());
        }
    }

    @Test
    void deferredEndpointGuardAllowsRefreshRewriteButRejectsFinalBomDrift()
            throws Exception {
        try (Connection connection = connection()) {
            Fixture fixture = fixture(connection);
            setActor(connection, fixture.userId());
            insertActiveBorrow(connection, fixture, fixture.borrowId());

            connection.setAutoCommit(false);
            execute(connection, """
                    UPDATE production_material_analysis_materials
                    SET active = FALSE
                    WHERE id = ?
                    """, fixture.fromMaterialId());
            execute(connection, """
                    UPDATE production_material_analysis_materials
                    SET active = TRUE
                    WHERE id = ?
                    """, fixture.fromMaterialId());
            connection.commit();

            execute(connection, """
                    UPDATE production_material_analysis_materials
                    SET goods_id = ?
                    WHERE id = ?
                    """, fixture.otherGoodsId(), fixture.toMaterialId());
            SQLException dimensionDrift = assertThrows(SQLException.class, connection::commit);
            assertEquals("55000", dimensionDrift.getSQLState());
            connection.rollback();

            execute(connection, """
                    UPDATE production_material_analysis_materials
                    SET analysis_item_id = ?
                    WHERE id = ?
                    """, fixture.fromItemId(), fixture.toMaterialId());
            SQLException sameProduct = assertThrows(SQLException.class, connection::commit);
            assertEquals("55000", sameProduct.getSQLState());
            connection.rollback();
        }
    }

    @Test
    void activeBorrowHasAppendPreservedLifecycleAndAuditedSuccessfulMutations()
            throws Exception {
        try (Connection connection = connection()) {
            Fixture fixture = fixture(connection);
            setActor(connection, fixture.userId());

            execute(connection, """
                    INSERT INTO production_material_analysis_borrows (
                        id, analysis_id, from_material_id, to_material_id,
                        goods_id, unit_id, qty, reason, status,
                        last_effective_qty, idempotency_key, created_by, updated_at)
                    VALUES (?, ?, ?, ?, ?, ?, 10, 'borrow lifecycle proof',
                            'ACTIVE', 0, ?, ?, TIMESTAMPTZ '2000-01-01 00:00:00+00')
                    """, fixture.borrowId(), fixture.analysisId(),
                    fixture.fromMaterialId(), fixture.toMaterialId(),
                    fixture.goodsId(), fixture.unitId(),
                    "V289-borrow-" + fixture.borrowId(), fixture.userId());
            assertBorrowState(
                    connection, fixture.borrowId(), "ACTIVE", "0", null);

            assertEquals(1, execute(connection, """
                    UPDATE production_material_analysis_borrows
                    SET last_effective_qty = 4
                    WHERE id = ?
                    """, fixture.borrowId()));
            assertBorrowState(
                    connection, fixture.borrowId(), "ACTIVE", "4", null);
            assertTrue(updatedAt(connection, fixture.borrowId())
                            .isAfter(Instant.parse("2000-01-01T00:00:00Z")),
                    "the dedicated updated_at trigger must replace the supplied old timestamp");

            assertSqlState(connection, "55000", """
                    UPDATE production_material_analysis_borrows
                    SET qty = 11
                    WHERE id = ?
                    """, fixture.borrowId());

            assertSqlState(connection, "55000", """
                    UPDATE production_material_analysis_borrows
                    SET status = 'REVOKED', revoked_by = ?, revoked_at = now(),
                        revoke_reason = 'must preserve effective evidence',
                        last_effective_qty = 5
                    WHERE id = ?
                    """, fixture.userId(), fixture.borrowId());
            assertBorrowState(
                    connection, fixture.borrowId(), "ACTIVE", "4", null);

            assertEquals(1, execute(connection, """
                    UPDATE production_material_analysis_borrows
                    SET status = 'REVOKED', revoked_by = ?, revoked_at = now(),
                        revoke_reason = 'operator revoked allocation'
                    WHERE id = ?
                    """, fixture.userId(), fixture.borrowId()));
            assertBorrowState(
                    connection, fixture.borrowId(), "REVOKED", "4", fixture.userId());

            assertSqlState(connection, "55000", """
                    UPDATE production_material_analysis_borrows
                    SET last_effective_qty = 5
                    WHERE id = ?
                    """, fixture.borrowId());
            assertSqlState(connection, "55000", """
                    DELETE FROM production_material_analysis_borrows
                    WHERE id = ?
                    """, fixture.borrowId());
            assertBorrowState(
                    connection, fixture.borrowId(), "REVOKED", "4", fixture.userId());

            assertAuditLifecycle(connection, fixture);
        }
    }

    @Test
    void borrowTableHasExactlyOneValidAuditTrigger() throws Exception {
        try (Connection connection = connection(); Statement statement = connection.createStatement();
             ResultSet result = statement.executeQuery("""
                     SELECT count(*) AS prefixed_count,
                            count(*) FILTER (WHERE
                                trigger_row.tgenabled IN ('O', 'A')
                                AND (trigger_row.tgtype::integer & 1) = 1
                                AND (trigger_row.tgtype::integer & 2) = 0
                                AND (trigger_row.tgtype::integer & 4) = 4
                                AND (trigger_row.tgtype::integer & 8) = 8
                                AND (trigger_row.tgtype::integer & 16) = 16
                                AND function_schema.nspname = 'public'
                                AND trigger_function.proname IN (
                                    'fn_audit', 'fn_audit_redacted')) AS valid_count
                     FROM pg_trigger trigger_row
                     JOIN pg_proc trigger_function ON trigger_function.oid = trigger_row.tgfoid
                     JOIN pg_namespace function_schema ON function_schema.oid = trigger_function.pronamespace
                     WHERE trigger_row.tgrelid = 'production_material_analysis_borrows'::regclass
                       AND NOT trigger_row.tgisinternal
                       AND trigger_row.tgname LIKE 'trg_audit%'
                     """)) {
            assertTrue(result.next());
            assertEquals(1, result.getInt("prefixed_count"),
                    "the table must not carry a shadow or duplicate trg_audit* trigger");
            assertEquals(1, result.getInt("valid_count"),
                    "the only audit trigger must be enabled AFTER ROW INSERT/UPDATE/DELETE");
        }
    }

    private static Fixture fixture(Connection connection) throws Exception {
        // Self-contained fixture: insert its own employee + user instead of
        // relying on the V08 'ADMIN' seed, so the test stays hermetic even if
        // seed data changes. Pattern proven by
        // ProductionMaterialAnalysisPersistencePostgresTest against the full schema.
        UUID departmentId = scalarUuid(connection, """
                SELECT id FROM departments WHERE is_deleted = FALSE ORDER BY code LIMIT 1
                """);
        UUID employeeId = UUID.randomUUID();
        execute(connection, """
                INSERT INTO employees (
                    id, code, full_name, id_type, department_id, hire_date,
                    status, employment_type)
                VALUES (?, ?, ?, '其他', ?, ?, 'active', 'regular')
                """, employeeId, "V289-E-" + employeeId, "V289 borrow owner",
                departmentId, LocalDate.of(2026, 1, 1));
        UUID userId = UUID.randomUUID();
        execute(connection, """
                INSERT INTO users (
                    id, employee_id, login_account, password_hash, status)
                VALUES (?, ?, ?, 'test-only-not-a-real-password', 'active')
                """, userId, employeeId, "v289-borrow-" + userId);
        UUID unitId = UUID.randomUUID();
        UUID goodsId = UUID.randomUUID();
        UUID otherGoodsId = UUID.randomUUID();
        UUID analysisId = UUID.randomUUID();
        UUID otherAnalysisId = UUID.randomUUID();
        UUID fromItemId = UUID.randomUUID();
        UUID toItemId = UUID.randomUUID();
        UUID fromMaterialId = UUID.randomUUID();
        UUID toMaterialId = UUID.randomUUID();
        UUID borrowId = UUID.randomUUID();

        execute(connection, """
                INSERT INTO units (id, code, name)
                VALUES (?, ?, 'V289 borrow unit')
                """, unitId, "V289-UNIT-" + unitId);
        execute(connection, """
                INSERT INTO goods (id, code, name, unit_id, code_sequence)
                VALUES (?, ?, 'V289 borrow goods', ?,
                        (SELECT COALESCE(max(code_sequence), 0) + 1 FROM goods))
                """, goodsId, "V289-GOODS-" + goodsId, unitId);
        execute(connection, """
                INSERT INTO goods (id, code, name, unit_id, code_sequence)
                VALUES (?, ?, 'V289 other goods', ?,
                        (SELECT COALESCE(max(code_sequence), 0) + 1 FROM goods))
                """, otherGoodsId, "V289-OTHER-" + otherGoodsId, unitId);
        execute(connection, """
                INSERT INTO production_material_analyses (
                    id, status, fingerprint, initial_idempotency_key,
                    maker_id, created_by, updated_by)
                VALUES (?, 'ACTIVE', ?, ?, ?, ?, ?)
                """, analysisId, "a".repeat(64), "V289-analysis-" + analysisId,
                employeeId, userId, userId);
        execute(connection, """
                INSERT INTO production_material_analyses (
                    id, status, fingerprint, initial_idempotency_key,
                    maker_id, created_by, updated_by)
                VALUES (?, 'ACTIVE', ?, ?, ?, ?, ?)
                """, otherAnalysisId, "b".repeat(64),
                "V289-analysis-" + otherAnalysisId, employeeId, userId, userId);
        execute(connection, """
                INSERT INTO production_material_analysis_items (
                    id, analysis_id, source_type, goods_id, unit_id,
                    source_ref, source_reason, requested_qty, line_priority,
                    created_by, updated_by)
                VALUES
                    (?, ?, 'OTHER', ?, ?, ?, 'borrow source fixture', 10, 1, ?, ?),
                    (?, ?, 'OTHER', ?, ?, ?, 'borrow target fixture', 10, 2, ?, ?)
                """, fromItemId, analysisId, goodsId, unitId,
                "V289-analysis-item-" + fromItemId, userId, userId,
                toItemId, analysisId, otherGoodsId, unitId,
                "V289-analysis-item-" + toItemId, userId, userId);
        insertMaterial(connection, analysisId, fromItemId, fromMaterialId,
                goodsId, unitId, "from-" + fromMaterialId);
        insertMaterial(connection, analysisId, toItemId, toMaterialId,
                goodsId, unitId, "to-" + toMaterialId);

        return new Fixture(
                userId, goodsId, otherGoodsId, unitId, analysisId, otherAnalysisId,
                fromItemId, toItemId, fromMaterialId, toMaterialId, borrowId);
    }

    private static void insertMaterial(
            Connection connection, UUID analysisId, UUID itemId, UUID materialId,
            UUID goodsId, UUID unitId, String nodeKey) throws Exception {
        execute(connection, """
                INSERT INTO production_material_analysis_materials (
                    id, analysis_id, analysis_item_id, node_key,
                    goods_id, unit_id, depth, path, per_product_qty,
                    required_qty, available_qty, allocated_available_qty,
                    shortage_qty, source_suggestion)
                VALUES (?, ?, ?, ?, ?, ?, 1, ?, 1, 10, 10, 10, 0, 'BUY')
                """, materialId, analysisId, itemId, nodeKey,
                goodsId, unitId, nodeKey);
    }

    private static void insertActiveBorrow(
            Connection connection, Fixture fixture, UUID borrowId) throws Exception {
        execute(connection, """
                INSERT INTO production_material_analysis_borrows (
                    id, analysis_id, from_material_id, to_material_id,
                    goods_id, unit_id, qty, reason, status,
                    last_effective_qty, idempotency_key, created_by)
                VALUES (?, ?, ?, ?, ?, ?, 10, 'active endpoint guard proof',
                        'ACTIVE', 0, ?, ?)
                """, borrowId, fixture.analysisId(), fixture.fromMaterialId(),
                fixture.toMaterialId(), fixture.goodsId(), fixture.unitId(),
                "V289-endpoint-" + borrowId, fixture.userId());
    }

    private static void assertBorrowState(
            Connection connection, UUID borrowId, String status,
            String lastEffectiveQty, UUID revokedBy) throws Exception {
        try (PreparedStatement query = connection.prepareStatement("""
                SELECT status, last_effective_qty, revoked_by
                FROM production_material_analysis_borrows
                WHERE id = ?
                """)) {
            query.setObject(1, borrowId);
            try (ResultSet row = query.executeQuery()) {
                assertTrue(row.next());
                assertEquals(status, row.getString("status"));
                assertEquals(0, row.getBigDecimal("last_effective_qty")
                        .compareTo(new BigDecimal(lastEffectiveQty)));
                assertEquals(revokedBy, row.getObject("revoked_by", UUID.class));
                assertFalse(row.next());
            }
        }
    }

    private static Instant updatedAt(Connection connection, UUID borrowId) throws Exception {
        try (PreparedStatement query = connection.prepareStatement("""
                SELECT updated_at
                FROM production_material_analysis_borrows
                WHERE id = ?
                """)) {
            query.setObject(1, borrowId);
            try (ResultSet row = query.executeQuery()) {
                assertTrue(row.next());
                return row.getTimestamp(1).toInstant();
            }
        }
    }

    private static void assertAuditLifecycle(Connection connection, Fixture fixture)
            throws Exception {
        try (PreparedStatement query = connection.prepareStatement("""
                SELECT action, actor_id,
                       before ->> 'status' AS before_status,
                       "after" ->> 'status' AS after_status,
                       before ->> 'last_effective_qty' AS before_effective_qty,
                       "after" ->> 'last_effective_qty' AS after_effective_qty
                FROM audit_log
                WHERE target_type = 'production_material_analysis_borrows'
                  AND target_id = ?
                ORDER BY id
                """)) {
            query.setString(1, fixture.borrowId().toString());
            try (ResultSet events = query.executeQuery()) {
                assertTrue(events.next());
                assertEquals("insert", events.getString("action"));
                assertEquals(fixture.userId(), events.getObject("actor_id", UUID.class));
                assertNull(events.getString("before_status"));
                assertEquals("ACTIVE", events.getString("after_status"));
                assertDecimal("0", events.getString("after_effective_qty"));

                assertTrue(events.next());
                assertEquals("update", events.getString("action"));
                assertEquals("ACTIVE", events.getString("before_status"));
                assertEquals("ACTIVE", events.getString("after_status"));
                assertDecimal("0", events.getString("before_effective_qty"));
                assertDecimal("4", events.getString("after_effective_qty"));

                assertTrue(events.next());
                assertEquals("update", events.getString("action"));
                assertEquals("ACTIVE", events.getString("before_status"));
                assertEquals("REVOKED", events.getString("after_status"));
                assertDecimal("4", events.getString("before_effective_qty"));
                assertDecimal("4", events.getString("after_effective_qty"));

                assertFalse(events.next(),
                        "rejected payload changes, revoked-row changes and DELETE must not audit success");
            }
        }
    }

    private static void assertDecimal(String expected, String actual) {
        assertEquals(0, new BigDecimal(actual).compareTo(new BigDecimal(expected)));
    }

    private static void assertSqlState(
            Connection connection, String expectedState, String sql, Object... values)
            throws Exception {
        SQLException rejected = assertThrows(SQLException.class,
                () -> execute(connection, sql, values));
        assertEquals(expectedState, rejected.getSQLState());
    }

    private static int execute(Connection connection, String sql, Object... values)
            throws Exception {
        try (PreparedStatement statement = connection.prepareStatement(sql)) {
            for (int index = 0; index < values.length; index++) {
                statement.setObject(index + 1, values[index]);
            }
            return statement.executeUpdate();
        }
    }

    private static UUID scalarUuid(Connection connection, String sql) throws Exception {
        try (PreparedStatement query = connection.prepareStatement(sql);
             ResultSet row = query.executeQuery()) {
            assertTrue(row.next());
            return row.getObject(1, UUID.class);
        }
    }

    private static void setActor(Connection connection, UUID actorId) throws Exception {
        try (PreparedStatement statement = connection.prepareStatement(
                "SELECT set_config('app.actor_id', ?, false)")) {
            statement.setString(1, actorId.toString());
            try (ResultSet row = statement.executeQuery()) {
                assertTrue(row.next());
                assertEquals(actorId.toString(), row.getString(1));
            }
        }
    }

    private static Connection connection() throws SQLException {
        return DriverManager.getConnection(
                POSTGRES.getJdbcUrl(), POSTGRES.getUsername(), POSTGRES.getPassword());
    }

    private record Fixture(
            UUID userId, UUID goodsId, UUID otherGoodsId, UUID unitId,
            UUID analysisId, UUID otherAnalysisId, UUID fromItemId, UUID toItemId,
            UUID fromMaterialId, UUID toMaterialId, UUID borrowId) {
    }
}
