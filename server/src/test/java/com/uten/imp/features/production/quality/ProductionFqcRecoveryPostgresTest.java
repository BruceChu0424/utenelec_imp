package com.uten.imp.features.production.quality;

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
import java.time.LocalDate;
import java.util.UUID;
import java.util.concurrent.atomic.AtomicInteger;

import static org.junit.jupiter.api.Assertions.assertEquals;

/** PostgreSQL proof for the V414 REWORK remediation quantity cycle. */
@EnabledIfEnvironmentVariable(named = "UTEN_RUN_DB_TESTS", matches = "(?i)true")
class ProductionFqcRecoveryPostgresTest {

    private static final PostgreSQLContainer<?> POSTGRES =
            new PostgreSQLContainer<>("postgres:16-alpine")
                    .withDatabaseName("uten_imp_fqc_recovery")
                    .withUsername("uten")
                    .withPassword("uten");
    private static final AtomicInteger DOCUMENT_SEQUENCE = new AtomicInteger();
    private static UUID actorUserId;
    private static UUID actorEmployeeId;
    private static UUID actorDepartmentId;

    @BeforeAll
    static void migrateAndSeedActor() throws Exception {
        POSTGRES.start();
        Flyway.configure()
                .dataSource(
                        POSTGRES.getJdbcUrl(),
                        POSTGRES.getUsername(),
                        POSTGRES.getPassword())
                .locations("classpath:db/migration")
                .target("414")
                .load()
                .migrate();
        try (Connection connection = connection()) {
            actorDepartmentId = scalarUuid(connection, """
                    SELECT id FROM departments
                    WHERE code = 'WS_ZHUSU' AND is_deleted = FALSE
                    """);
            actorEmployeeId = UUID.randomUUID();
            actorUserId = UUID.randomUUID();
            update(connection, """
                    INSERT INTO employees(
                        id, code, full_name, id_type, department_id,
                        hire_date, status, employment_type)
                    VALUES (?, ?, 'V414 FQC actor', '其他', ?,
                            DATE '2026-08-28', 'active', 'regular')
                    """, actorEmployeeId, "V414-E-" + actorEmployeeId,
                    actorDepartmentId);
            update(connection, """
                    INSERT INTO users(
                        id, employee_id, login_account, password_hash, status)
                    VALUES (?, ?, ?, 'test-only-hash', 'active')
                    """, actorUserId, actorEmployeeId,
                    "v414-" + actorUserId);
        }
    }

    @AfterAll
    static void stop() {
        POSTGRES.stop();
    }

    @Test
    void planTenFailOneThenReworkPassRestoresEffectiveProgressToTen()
            throws Exception {
        try (Connection connection = connection()) {
            Fixture fixture = sourcePartialFailure(connection);

            assertDecimal(connection, """
                    SELECT fqty FROM production_plan_items WHERE id = ?
                    """, fixture.planItemId(), "9.0000");
            assertDecimal(connection, """
                    SELECT available_qty
                    FROM v_production_fqc_recovery_balance
                    WHERE authorization_id = ?
                    """, fixture.authorizationId(), "1.0000");

            Replacement replacement = replacement(
                    connection, fixture, true);

            assertDecimal(connection, """
                    SELECT fqty FROM production_plan_items WHERE id = ?
                    """, fixture.planItemId(), "10.0000");
            assertDecimal(connection, """
                    SELECT allocated_qty
                    FROM v_production_fqc_recovery_balance
                    WHERE authorization_id = ?
                    """, fixture.authorizationId(), "1.0000");
            assertDecimal(connection, """
                    SELECT available_qty
                    FROM v_production_fqc_recovery_balance
                    WHERE authorization_id = ?
                    """, fixture.authorizationId(), "0.0000");
            assertEquals("RESOLVED", scalarString(connection, """
                    SELECT status FROM production_fqc_inspections WHERE id = ?
                    """, replacement.inspectionId()));
            assertDecimal(connection, """
                    SELECT passed_qty FROM production_fqc_inspections WHERE id = ?
                    """, replacement.inspectionId(), "1.0000");
        }
    }

    @Test
    void secondFullFailReplacementHasZeroContributionAndCanReverseCleanly()
            throws Exception {
        try (Connection connection = connection()) {
            Fixture fixture = sourcePartialFailure(connection);
            Replacement replacement = replacement(
                    connection, fixture, false);

            assertDecimal(connection, """
                    SELECT item.qty - COALESCE(SUM(adjustment.adjusted_qty), 0)
                    FROM production_daily_report_items item
                    LEFT JOIN production_fqc_contribution_adjustments adjustment
                      ON adjustment.source_report_item_id = item.id
                    WHERE item.id = ?
                    GROUP BY item.qty
                    """, replacement.reportItemId(), "0.0000");
            assertDecimal(connection, """
                    SELECT fqty FROM production_plan_items WHERE id = ?
                    """, fixture.planItemId(), "9.0000");

            update(connection, """
                    UPDATE production_daily_reports
                    SET status = -1, row_version = row_version + 1
                    WHERE id = ?
                    """, replacement.reportId());
            update(connection, """
                    INSERT INTO production_fqc_recovery_allocation_events(
                        id, authorization_id, recovery_report_item_id,
                        event_type, qty, source_allocation_event_id,
                        idempotency_key, created_by)
                    VALUES (?, ?, ?, 'RELEASE', 1, ?, ?, ?)
                    """, UUID.randomUUID(), fixture.authorizationId(),
                    replacement.reportItemId(), replacement.allocationEventId(),
                    "release-" + replacement.allocationEventId(), actorUserId);
            update(connection, """
                    INSERT INTO production_fqc_recovery_cancellation_events(
                        id, authorization_id, source_report_id, reason_code,
                        idempotency_key, created_by)
                    VALUES (?, ?, ?, 'SOURCE_REPORT_REVERSED', ?, ?)
                    """, UUID.randomUUID(), replacement.childAuthorizationId(),
                    replacement.reportId(),
                    "cancel-" + replacement.childAuthorizationId(), actorUserId);
            update(connection, """
                    INSERT INTO production_fqc_cancellation_events(
                        id, inspection_id, source_report_id, reason_code,
                        idempotency_key, created_by)
                    VALUES (?, ?, ?, 'SOURCE_REPORT_REVERSED', ?, ?)
                    """, UUID.randomUUID(), replacement.inspectionId(),
                    replacement.reportId(),
                    "fqc-cancel-" + replacement.inspectionId(), actorUserId);

            assertDecimal(connection, """
                    SELECT allocated_qty
                    FROM v_production_fqc_recovery_balance
                    WHERE authorization_id = ?
                    """, fixture.authorizationId(), "0.0000");
            assertDecimal(connection, """
                    SELECT available_qty
                    FROM v_production_fqc_recovery_balance
                    WHERE authorization_id = ?
                    """, fixture.authorizationId(), "1.0000");
            assertEquals("CANCELLED", scalarString(connection, """
                    SELECT status FROM production_fqc_inspections WHERE id = ?
                    """, replacement.inspectionId()));
            assertEquals(1, scalarInt(connection, """
                    SELECT COUNT(*)
                    FROM production_fqc_recovery_cancellation_events
                    WHERE authorization_id = ?
                    """, replacement.childAuthorizationId()));
            assertDecimal(connection, """
                    SELECT fqty FROM production_plan_items WHERE id = ?
                    """, fixture.planItemId(), "9.0000");
        }
    }

    private static Fixture sourcePartialFailure(Connection connection)
            throws Exception {
        UUID unitId = UUID.randomUUID();
        UUID goodsId = UUID.randomUUID();
        UUID warehouseId = UUID.randomUUID();
        UUID analysisId = UUID.randomUUID();
        UUID analysisItemId = UUID.randomUUID();
        UUID planId = UUID.randomUUID();
        UUID planItemId = UUID.randomUUID();
        UUID packageId = UUID.randomUUID();
        UUID segmentId = UUID.randomUUID();
        UUID reportId = UUID.randomUUID();
        UUID reportItemId = UUID.randomUUID();
        UUID inspectionId = UUID.randomUUID();
        UUID decisionId = UUID.randomUUID();
        UUID authorizationId = UUID.randomUUID();
        LocalDate date = LocalDate.of(2026, 8, 28);
        String planNo = documentNo("SJ", date);
        String reportNo = documentNo("SR", date);

        update(connection,
                "INSERT INTO units(id, code, name, status) VALUES (?, ?, 'piece', '使用')",
                unitId, "U-" + unitId);
        update(connection, """
                INSERT INTO goods(
                    id, code, name, min_qty, code_sequence)
                VALUES (?, ?, 'V414 recovery product', 0,
                    (SELECT COALESCE(MAX(code_sequence), 0) + 1 FROM goods))
                """, goodsId, "G-" + goodsId);
        update(connection, """
                INSERT INTO warehouses(id, code, name, status)
                VALUES (?, ?, 'V414 recovery warehouse', '使用')
                """, warehouseId, "W-" + warehouseId);
        update(connection, """
                INSERT INTO production_material_analyses(
                    id, warehouse_id, status, fingerprint,
                    initial_idempotency_key, maker_id, created_by)
                VALUES (?, ?, 'ACTIVE', ?, ?, ?, ?)
                """, analysisId, warehouseId, "a".repeat(64),
                "analysis-" + analysisId, actorEmployeeId, actorUserId);
        update(connection, """
                INSERT INTO production_material_analysis_items(
                    id, analysis_id, source_type, goods_id, unit_id,
                    source_ref, source_reason, requested_qty)
                VALUES (?, ?, 'OTHER', ?, ?, ?, 'V414 recovery fixture', 10)
                """, analysisItemId, analysisId, goodsId, unitId,
                "V414-" + analysisItemId);
        update(connection, """
                INSERT INTO production_plans(
                    id, bill_no, bill_date, status, maker_id)
                VALUES (?, ?, ?, 1, ?)
                """, planId, planNo, date, actorEmployeeId);
        update(connection, """
                INSERT INTO production_plan_items(
                    id, bill_no, bill_date, plan_id, product_no,
                    goods_id, unit_id, unit_rate, qty, fqty, iqty)
                VALUES (?, ?, ?, ?, ?, ?, ?, 1, 10, 10, 0)
                """, planItemId, planNo, date, planId,
                "PRODUCT-" + planItemId, goodsId, unitId);
        update(connection, """
                UPDATE production_plans
                SET material_analysis_id = ?, material_analysis_item_id = ?
                WHERE id = ?
                """, analysisId, analysisItemId, planId);

        connection.setAutoCommit(false);
        try {
            update(connection, """
                    INSERT INTO production_planning_packages(
                        id, plan_id, warehouse_id, idempotency_key,
                        request_hash, preview_fingerprint, status,
                        execution_model_version)
                    VALUES (?, ?, ?, ?, ?, ?, 'CONFIRMED', 1)
                    """, packageId, planId, warehouseId,
                    "package-" + packageId,
                    "b".repeat(64), "c".repeat(64));
            update(connection, """
                    INSERT INTO production_execution_segments(
                        id, package_id, plan_id, source_plan_item_id,
                        segment_no, segment_code, client_segment_key,
                        product_goods_id, product_unit_id, product_unit_rate,
                        planned_qty, status, bom_fingerprint, idempotency_key,
                        material_requirement_mode, zero_material_reason,
                        zero_material_analysis_id)
                    VALUES (?, ?, ?, ?, 1, ?, ?, ?, ?, 1,
                            10, 'READY', ?, ?, 'ZERO_MATERIAL',
                            'DIRECT_MAKE', ?)
                    """, segmentId, packageId, planId, planItemId,
                    segmentCode(segmentId), "segment-client-" + segmentId,
                    goodsId, unitId, "d".repeat(64),
                    "segment-" + segmentId, analysisId);
            connection.commit();
        } catch (Throwable error) {
            connection.rollback();
            throw error;
        } finally {
            connection.setAutoCommit(true);
        }
        update(connection, """
                UPDATE production_execution_segments
                SET workshop_department_id = ?, responsible_employee_id = ?,
                    plan_begin_date = DATE '2026-08-28',
                    plan_end_date = DATE '2026-08-29', status = 'DISPATCHED'
                WHERE id = ?
                """, actorDepartmentId, actorEmployeeId, segmentId);
        update(connection, """
                UPDATE production_execution_segments
                SET status = 'IN_PROGRESS' WHERE id = ?
                """, segmentId);
        update(connection, """
                INSERT INTO production_daily_reports(
                    id, bill_no, bill_date, warehouse_id,
                    maker_id, status)
                VALUES (?, ?, ?, ?, ?, 1)
                """, reportId, reportNo, date, warehouseId, actorEmployeeId);
        update(connection, """
                INSERT INTO production_daily_report_items(
                    id, bill_no, bill_date, report_id, line_no,
                    goods_id, unit_id, unit_rate, qty, plan_item_id,
                    execution_segment_id)
                VALUES (?, ?, ?, ?, 1, ?, ?, 1, 10, ?, ?)
                """, reportItemId, reportNo, date, reportId,
                goodsId, unitId, planItemId, segmentId);
        insertInspection(connection, inspectionId, reportId, reportItemId,
                planItemId, segmentId, warehouseId, goodsId, unitId,
                BigDecimal.TEN);
        insertDecision(connection, decisionId, inspectionId,
                "PARTIAL", new BigDecimal("9"), BigDecimal.ONE,
                "REWORK", "one failed unit");
        update(connection,
                "UPDATE production_plan_items SET fqty = 9 WHERE id = ?",
                planItemId);
        insertAdjustment(connection, inspectionId, decisionId,
                reportItemId, planItemId, BigDecimal.ONE);
        insertAuthorization(connection, authorizationId, inspectionId,
                decisionId, reportItemId, planItemId, segmentId,
                warehouseId, goodsId, unitId, BigDecimal.ONE, "REWORK");
        return new Fixture(warehouseId, goodsId, unitId, planItemId,
                segmentId, authorizationId);
    }

    private static Replacement replacement(
            Connection connection, Fixture source, boolean pass)
            throws Exception {
        UUID reportId = UUID.randomUUID();
        UUID reportItemId = UUID.randomUUID();
        UUID allocationEventId = UUID.randomUUID();
        UUID inspectionId = UUID.randomUUID();
        UUID decisionId = UUID.randomUUID();
        UUID childAuthorizationId = pass ? null : UUID.randomUUID();
        LocalDate date = LocalDate.of(2026, 8, 28);
        String reportNo = documentNo("SR", date);
        update(connection, """
                INSERT INTO production_daily_reports(
                    id, bill_no, bill_date, warehouse_id,
                    maker_id, status)
                VALUES (?, ?, ?, ?, ?, 1)
                """, reportId, reportNo, date, source.warehouseId(),
                actorEmployeeId);
        update(connection, """
                INSERT INTO production_daily_report_items(
                    id, bill_no, bill_date, report_id, line_no,
                    goods_id, unit_id, unit_rate, qty, plan_item_id,
                    execution_segment_id, fqc_recovery_authorization_id)
                VALUES (?, ?, ?, ?, 1, ?, ?, 1, 1, ?, ?, ?)
                """, reportItemId, reportNo, date, reportId,
                source.goodsId(), source.unitId(), source.planItemId(),
                source.segmentId(), source.authorizationId());
        update(connection,
                "UPDATE production_plan_items SET fqty = fqty + 1 WHERE id = ?",
                source.planItemId());
        update(connection, """
                INSERT INTO production_fqc_recovery_allocation_events(
                    id, authorization_id, recovery_report_item_id,
                    event_type, qty, idempotency_key, created_by)
                VALUES (?, ?, ?, 'ALLOCATE', 1, ?, ?)
                """, allocationEventId, source.authorizationId(),
                reportItemId, "allocate-" + allocationEventId, actorUserId);
        insertInspection(connection, inspectionId, reportId, reportItemId,
                source.planItemId(), source.segmentId(), source.warehouseId(),
                source.goodsId(), source.unitId(), BigDecimal.ONE);
        if (pass) {
            insertDecision(connection, decisionId, inspectionId,
                    "PASS", BigDecimal.ONE, BigDecimal.ZERO,
                    null, null);
        } else {
            insertDecision(connection, decisionId, inspectionId,
                    "FAIL", BigDecimal.ZERO, BigDecimal.ONE,
                    "REWORK", "replacement failed again");
            update(connection,
                    "UPDATE production_plan_items SET fqty = fqty - 1 WHERE id = ?",
                    source.planItemId());
            insertAdjustment(connection, inspectionId, decisionId,
                    reportItemId, source.planItemId(), BigDecimal.ONE);
            insertAuthorization(connection, childAuthorizationId, inspectionId,
                    decisionId, reportItemId, source.planItemId(),
                    source.segmentId(), source.warehouseId(), source.goodsId(),
                    source.unitId(), BigDecimal.ONE, "REWORK");
        }
        return new Replacement(reportId, reportItemId, allocationEventId,
                inspectionId, childAuthorizationId);
    }

    private static void insertInspection(
            Connection connection, UUID inspectionId, UUID reportId,
            UUID reportItemId, UUID planItemId, UUID segmentId,
            UUID warehouseId, UUID goodsId, UUID unitId,
            BigDecimal quantity) throws Exception {
        update(connection, """
                INSERT INTO production_fqc_inspections(
                    id, source_report_id, source_report_item_id,
                    source_plan_item_id, execution_segment_id,
                    warehouse_id, goods_id, unit_id, unit_rate,
                    reported_qty, report_maker_id, created_by)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, 1, ?, ?, ?)
                """, inspectionId, reportId, reportItemId, planItemId,
                segmentId, warehouseId, goodsId, unitId, quantity,
                actorEmployeeId, actorUserId);
    }

    private static void insertDecision(
            Connection connection, UUID decisionId, UUID inspectionId,
            String decision, BigDecimal passQty, BigDecimal failQty,
            String disposition, String reason) throws Exception {
        update(connection, """
                INSERT INTO production_fqc_decision_events(
                    id, inspection_id, decision, pass_qty, fail_qty,
                    disposition_code, reason, idempotency_key, request_hash,
                    decided_by_employee_id, created_by)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                """, decisionId, inspectionId, decision, passQty, failQty,
                disposition, reason, "decision-" + decisionId,
                "e".repeat(64), actorEmployeeId, actorUserId);
    }

    private static void insertAdjustment(
            Connection connection, UUID inspectionId, UUID decisionId,
            UUID reportItemId, UUID planItemId, BigDecimal quantity)
            throws Exception {
        update(connection, """
                INSERT INTO production_fqc_contribution_adjustments(
                    id, inspection_id, decision_event_id,
                    source_report_item_id, source_plan_item_id,
                    adjusted_qty, created_by)
                VALUES (?, ?, ?, ?, ?, ?, ?)
                """, UUID.randomUUID(), inspectionId, decisionId,
                reportItemId, planItemId, quantity, actorUserId);
    }

    private static void insertAuthorization(
            Connection connection, UUID authorizationId, UUID inspectionId,
            UUID decisionId, UUID reportItemId, UUID planItemId,
            UUID segmentId, UUID warehouseId, UUID goodsId, UUID unitId,
            BigDecimal quantity, String disposition) throws Exception {
        update(connection, """
                INSERT INTO production_fqc_recovery_authorizations(
                    id, source_inspection_id, source_decision_event_id,
                    source_report_item_id, source_plan_item_id,
                    execution_segment_id, warehouse_id, goods_id,
                    unit_id, unit_rate, authorized_qty, disposition_code,
                    idempotency_key, created_by)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, 1, ?, ?, ?, ?)
                """, authorizationId, inspectionId, decisionId, reportItemId,
                planItemId, segmentId, warehouseId, goodsId, unitId, quantity,
                disposition, "recovery-" + decisionId, actorUserId);
    }

    private static void assertDecimal(
            Connection connection, String sql, UUID id, String expected)
            throws Exception {
        try (PreparedStatement statement = connection.prepareStatement(sql)) {
            statement.setObject(1, id);
            try (ResultSet rows = statement.executeQuery()) {
                rows.next();
                assertEquals(0, rows.getBigDecimal(1)
                        .compareTo(new BigDecimal(expected)));
            }
        }
    }

    private static int scalarInt(
            Connection connection, String sql, UUID id) throws Exception {
        try (PreparedStatement statement = connection.prepareStatement(sql)) {
            statement.setObject(1, id);
            try (ResultSet rows = statement.executeQuery()) {
                rows.next();
                return rows.getInt(1);
            }
        }
    }

    private static String scalarString(
            Connection connection, String sql, UUID id) throws Exception {
        try (PreparedStatement statement = connection.prepareStatement(sql)) {
            statement.setObject(1, id);
            try (ResultSet rows = statement.executeQuery()) {
                rows.next();
                return rows.getString(1);
            }
        }
    }

    private static UUID scalarUuid(Connection connection, String sql)
            throws Exception {
        try (PreparedStatement statement = connection.prepareStatement(sql);
             ResultSet rows = statement.executeQuery()) {
            rows.next();
            return rows.getObject(1, UUID.class);
        }
    }

    private static int update(
            Connection connection, String sql, Object... values)
            throws Exception {
        try (PreparedStatement statement = connection.prepareStatement(sql)) {
            for (int index = 0; index < values.length; index++) {
                statement.setObject(index + 1, values[index]);
            }
            return statement.executeUpdate();
        }
    }

    private static String documentNo(String prefix, LocalDate date) {
        return prefix + date.toString().replace("-", "")
                + "%06d".formatted(DOCUMENT_SEQUENCE.incrementAndGet());
    }

    private static String segmentCode(UUID id) {
        return "ZX%08d".formatted(
                Math.floorMod(id.hashCode(), 99_999_999) + 1);
    }

    private static Connection connection() throws Exception {
        return DriverManager.getConnection(
                POSTGRES.getJdbcUrl(),
                POSTGRES.getUsername(),
                POSTGRES.getPassword());
    }

    private record Fixture(
            UUID warehouseId,
            UUID goodsId,
            UUID unitId,
            UUID planItemId,
            UUID segmentId,
            UUID authorizationId) {
    }

    private record Replacement(
            UUID reportId,
            UUID reportItemId,
            UUID allocationEventId,
            UUID inspectionId,
            UUID childAuthorizationId) {
    }
}
