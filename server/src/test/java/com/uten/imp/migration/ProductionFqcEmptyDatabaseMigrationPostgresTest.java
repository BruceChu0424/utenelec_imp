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
import java.sql.Savepoint;
import java.sql.Statement;
import java.time.LocalDate;
import java.util.UUID;

import static org.assertj.core.api.Assertions.assertThat;
import static org.junit.jupiter.api.Assertions.assertThrows;

@EnabledIfEnvironmentVariable(named = "UTEN_RUN_DB_TESTS", matches = "(?i)true")
class ProductionFqcEmptyDatabaseMigrationPostgresTest {

    private static final PostgreSQLContainer<?> POSTGRES =
            new PostgreSQLContainer<>("postgres:16-alpine")
                    .withDatabaseName("uten_imp_fqc_migration")
                    .withUsername("uten")
                    .withPassword("uten-test-only");

    @BeforeAll
    static void migrate() {
        POSTGRES.start();
        Flyway.configure()
                .dataSource(
                        POSTGRES.getJdbcUrl(),
                        POSTGRES.getUsername(),
                        POSTGRES.getPassword())
                .locations("classpath:db/migration")
                .load()
                .migrate();
    }

    @Test
    void fakeMaterialReadyIsRejectedWithoutFulfilledIssuedDraw()
            throws Exception {
        try (Connection connection = DriverManager.getConnection(
                POSTGRES.getJdbcUrl(),
                POSTGRES.getUsername(),
                POSTGRES.getPassword());
             Statement statement = connection.createStatement()) {
            connection.setAutoCommit(false);
            UUID cycleId = UUID.randomUUID();
            UUID authorizationId = UUID.randomUUID();
            UUID taskId = UUID.randomUUID();
            UUID packageId = UUID.randomUUID();
            UUID planId = UUID.randomUUID();
            UUID planItemId = UUID.randomUUID();
            UUID segmentId = UUID.randomUUID();
            UUID warehouseId = UUID.randomUUID();
            UUID actorId = UUID.randomUUID();
            UUID drawId = UUID.randomUUID();
            UUID demandId = UUID.randomUUID();
            try {
                statement.execute("SET LOCAL session_replication_role = replica");
                statement.executeUpdate("""
                        INSERT INTO users(
                            id, employee_id, login_account, password_hash, status)
                        VALUES ('%s','%s','v415-fake-ready','test-only','active')
                        """.formatted(actorId, UUID.randomUUID()));
                statement.executeUpdate("""
                        INSERT INTO production_fqc_recovery_authorizations(
                            id, source_inspection_id, source_decision_event_id,
                            source_report_item_id, source_plan_item_id,
                            execution_segment_id, warehouse_id,
                            goods_id, unit_id, unit_rate, authorized_qty,
                            disposition_code, idempotency_key, created_by)
                        VALUES ('%s','%s','%s','%s','%s','%s','%s','%s','%s',
                                1,1,'SCRAP','fake-ready-authorization','%s')
                        """.formatted(
                        authorizationId, UUID.randomUUID(), UUID.randomUUID(),
                        UUID.randomUUID(), planItemId, segmentId, warehouseId,
                        UUID.randomUUID(), UUID.randomUUID(), actorId));
                statement.executeUpdate("""
                        INSERT INTO production_fqc_replenishment_tasks(
                            id, authorization_id, created_by)
                        VALUES ('%s','%s','%s')
                        """.formatted(taskId, authorizationId, actorId));
                statement.executeUpdate("""
                        INSERT INTO production_fqc_replenishment_cycles(
                            id, replenishment_task_id, authorization_id,
                            generation, package_id, plan_id,
                            source_plan_item_id, source_execution_segment_id,
                            warehouse_id, product_qty,
                            planning_snapshot_fingerprint, bom_fingerprint,
                            initial_idempotency_key, request_hash, created_by)
                        VALUES ('%s','%s','%s',1,'%s','%s','%s','%s','%s',1,
                                '%s','%s','fake-ready-cycle','%s','%s')
                        """.formatted(
                        cycleId, taskId, authorizationId, packageId, planId,
                        planItemId, segmentId, warehouseId,
                        "a".repeat(64), "b".repeat(64),
                        "c".repeat(64), actorId));
                statement.executeUpdate("""
                        INSERT INTO stock_documents(
                            id, doc_type, bill_no, bill_date, warehouse_id,
                            status, issue_status, is_deleted)
                        VALUES ('%s','DRAW','PD-FAKE-READY',DATE '%s','%s',0,0,FALSE)
                        """.formatted(drawId, LocalDate.of(2026, 8, 28), warehouseId));
                statement.executeUpdate("""
                        INSERT INTO production_fqc_replenishment_draw_links(
                            cycle_id, authorization_id, stock_document_id, created_by)
                        VALUES ('%s','%s','%s','%s')
                        """.formatted(cycleId, authorizationId, drawId, actorId));
                statement.executeUpdate("""
                        INSERT INTO production_material_demands(
                            id, package_id, plan_id, execution_segment_id,
                            fqc_recovery_authorization_id,
                            fqc_replenishment_cycle_id,
                            source_plan_item_id, warehouse_id,
                            goods_id, unit_id, required_qty, per_product_qty,
                            requirement_mode, required_for_product_qty,
                            requirement_fingerprint, supply_route, status,
                            idempotency_key)
                        VALUES ('%s','%s','%s',NULL,'%s','%s','%s','%s',
                                '%s','%s',1,1,'EXACT_SNAPSHOT',1,'%s','BUY',
                                'OPEN','fake-ready-demand')
                        """.formatted(
                        demandId, packageId, planId, authorizationId, cycleId,
                        planItemId, warehouseId, UUID.randomUUID(),
                        UUID.randomUUID(), "d".repeat(64)));
                statement.execute("SET LOCAL session_replication_role = origin");

                Savepoint beforeFakeReady = connection.setSavepoint();
                SQLException fakeReady = assertThrows(
                        SQLException.class,
                        () -> statement.executeUpdate("""
                                INSERT INTO production_fqc_replenishment_ready_events(
                                    id, cycle_id, authorization_id,
                                    stock_document_id, idempotency_key, created_by)
                                VALUES (gen_random_uuid(), '%s', '%s', '%s',
                                        'fake-ready-event', '%s')
                                """.formatted(
                                cycleId, authorizationId, drawId, actorId)));
                assertThat(fakeReady.getSQLState()).isEqualTo("23514");
                assertThat(fakeReady.getMessage())
                        .contains("lacks fulfilled physical DRAW facts");
                connection.rollback(beforeFakeReady);

                statement.execute("SET LOCAL session_replication_role = replica");
                statement.executeUpdate("""
                        UPDATE production_material_demands
                        SET status = 'FULFILLED'
                        WHERE id = '%s'
                        """.formatted(demandId));
                statement.executeUpdate("""
                        UPDATE stock_documents
                        SET status = 1, issue_status = 2
                        WHERE id = '%s'
                        """.formatted(drawId));
                statement.execute("SET LOCAL session_replication_role = origin");
                statement.execute("""
                        SELECT fn_reconcile_fqc_replenishment_ready('%s')
                        """.formatted(cycleId));
                assertThat(scalar(statement, """
                        SELECT COUNT(*)
                        FROM v_production_fqc_replenishment_material_ready
                        WHERE authorization_id = '%s'
                        """.formatted(authorizationId))).isEqualTo(1);
                assertThat(bool(statement, """
                        SELECT fn_fqc_replenishment_material_ready('%s')
                        """.formatted(authorizationId))).isTrue();
            } finally {
                connection.rollback();
            }
        }
    }

    @AfterAll
    static void stop() {
        POSTGRES.stop();
    }

    @Test
    void emptyDatabaseAppliesFqcTablesPermissionsAndEnabledGuards()
            throws Exception {
        try (Connection connection = DriverManager.getConnection(
                POSTGRES.getJdbcUrl(),
                POSTGRES.getUsername(),
                POSTGRES.getPassword());
             Statement statement = connection.createStatement()) {
            assertThat(scalar(statement, """
                    SELECT COUNT(*)
                    FROM flyway_schema_history
                    WHERE version = '410' AND success
                    """)).isEqualTo(1);
            assertThat(scalar(statement, """
                    SELECT COUNT(*)
                    FROM flyway_schema_history
                    WHERE version = '415' AND success
                    """)).isEqualTo(1);
            assertThat(scalar(statement, """
                    SELECT COUNT(*)
                    FROM flyway_schema_history
                    WHERE version = '432' AND success
                    """)).isEqualTo(1);
            assertThat(scalar(statement, """
                    SELECT COUNT(*)
                    FROM information_schema.tables
                    WHERE table_schema = 'public'
                      AND table_name IN (
                        'production_fqc_inspections',
                        'production_fqc_decision_events',
                        'production_fqc_release_commands',
                        'production_fqc_release_allocations',
                        'production_fqc_pass_all_batches',
                        'production_fqc_pass_all_batch_items')
                    """)).isEqualTo(6);
            assertThat(scalar(statement, """
                    SELECT COUNT(*)
                    FROM permissions
                    WHERE code IN (
                        'production_quality_inspection:view',
                        'production_quality_inspection:approve')
                    """)).isEqualTo(2);
            assertThat(scalar(statement, """
                    SELECT COUNT(*)
                    FROM pg_trigger
                    WHERE NOT tgisinternal
                      AND tgname IN (
                        'trg_guard_production_fqc_inspection',
                         'trg_guard_production_fqc_decision_append_only',
                         'trg_validate_production_fqc_release_command',
                         'trg_validate_production_fqc_release_allocation',
                         'trg_validate_production_fqc_pass_all_batch_header',
                         'trg_validate_production_fqc_pass_all_batch_item',
                         'trg_guard_production_fqc_pass_all_batch_append_only',
                         'trg_guard_production_fqc_pass_all_batch_item_append_only')
                       AND tgenabled <> 'D'
                    """)).isEqualTo(8);
            assertThat(scalar(statement, """
                    SELECT COUNT(*) FROM production_fqc_inspections
                    """)).isZero();
            assertThat(scalar(statement, """
                    SELECT COUNT(*)
                    FROM information_schema.tables
                    WHERE table_schema = 'public'
                      AND table_name IN (
                        'production_fqc_legacy_exemptions',
                        'production_fqc_recovery_authorizations',
                        'production_fqc_recovery_allocation_events',
                        'production_fqc_recovery_cancellation_events',
                        'production_fqc_contribution_adjustments')
                    """)).isEqualTo(5);
            assertThat(scalar(statement, """
                    SELECT COUNT(*) FROM v_production_fqc_recovery_balance
                    """)).isZero();
            assertThat(scalar(statement, """
                    SELECT COUNT(*)
                    FROM pg_trigger
                    WHERE NOT tgisinternal AND tgenabled = 'A'
                      AND tgname IN (
                        'trg_guard_production_fqc_legacy_exemption',
                        'trg_guard_fqc_recovery_authorization_append_only',
                        'trg_guard_fqc_recovery_allocation_append_only',
                        'trg_guard_fqc_recovery_cancellation_append_only',
                        'trg_guard_fqc_contribution_adjustment_append_only')
                    """)).isEqualTo(5);

            SQLException legacyWrite = assertThrows(
                    SQLException.class,
                    () -> statement.executeUpdate("""
                            INSERT INTO production_fqc_legacy_exemptions(
                                source_report_item_id, source_report_id)
                            VALUES (gen_random_uuid(), gen_random_uuid())
                            """));
            assertThat(legacyWrite.getSQLState()).isEqualTo("55000");

            SQLException arbitraryAdjustment = assertThrows(
                    SQLException.class,
                    () -> statement.executeUpdate("""
                            INSERT INTO production_fqc_contribution_adjustments(
                                inspection_id, decision_event_id,
                                source_report_item_id, source_plan_item_id,
                                adjusted_qty, created_by)
                            VALUES (
                                gen_random_uuid(), gen_random_uuid(),
                                gen_random_uuid(), gen_random_uuid(),
                                1, gen_random_uuid())
                            """));
            assertThat(arbitraryAdjustment.getSQLState()).isEqualTo("23514");
        }
    }

    @Test
    void qualityDecisionRecordQueriesAndFeedIndexesExecuteOnTheFullSchema()
            throws Exception {
        String iqcSql = privateRecordSql(
                "com.uten.imp.features.warehouse.inbound."
                        + "ProcurementInspectionRecordQueryService");
        String fqcSql = privateRecordSql(
                "com.uten.imp.features.production.quality."
                        + "ProductionFqcRecordQueryService");
        try (Connection connection = DriverManager.getConnection(
                POSTGRES.getJdbcUrl(),
                POSTGRES.getUsername(),
                POSTGRES.getPassword());
             Statement statement = connection.createStatement()) {
            try (ResultSet iqc = statement.executeQuery(
                    "SELECT * FROM (" + iqcSql + ") record WHERE FALSE")) {
                assertThat(iqc.next()).isFalse();
            }
            try (ResultSet fqc = statement.executeQuery(
                    "SELECT * FROM (" + fqcSql + ") record WHERE FALSE")) {
                assertThat(fqc.next()).isFalse();
            }
            assertThat(scalar(statement, """
                    SELECT COUNT(*)
                    FROM pg_indexes
                    WHERE schemaname = 'public'
                      AND indexname IN (
                        'idx_procurement_inspection_events_record_feed',
                        'idx_production_fqc_decision_events_record_feed',
                        'idx_production_fqc_cancellation_events_record_feed')
                    """)).isEqualTo(3);
        }
    }

    private static String privateRecordSql(String className) throws Exception {
        var method = Class.forName(className).getDeclaredMethod("recordSql");
        method.setAccessible(true);
        return (String) method.invoke(null);
    }

    private static long scalar(Statement statement, String sql) throws Exception {
        try (ResultSet result = statement.executeQuery(sql)) {
            result.next();
            return result.getLong(1);
        }
    }

    private static boolean bool(Statement statement, String sql) throws Exception {
        try (ResultSet result = statement.executeQuery(sql)) {
            result.next();
            return result.getBoolean(1);
        }
    }
}
