package com.uten.imp.migration;

import org.flywaydb.core.Flyway;
import org.junit.jupiter.api.AfterAll;
import org.junit.jupiter.api.BeforeAll;
import org.junit.jupiter.api.Test;
import org.junit.jupiter.api.condition.EnabledIfEnvironmentVariable;
import org.testcontainers.containers.PostgreSQLContainer;

import java.sql.Connection;
import java.sql.DriverManager;
import java.sql.PreparedStatement;
import java.sql.ResultSet;
import java.sql.SQLException;
import java.sql.Statement;
import java.util.UUID;

import static org.assertj.core.api.Assertions.assertThat;
import static org.junit.jupiter.api.Assertions.assertDoesNotThrow;
import static org.junit.jupiter.api.Assertions.assertThrows;

@EnabledIfEnvironmentVariable(named = "UTEN_RUN_DB_TESTS", matches = "(?i)true")
class SubcontractTargetOutboundPreparationPostgresTest {

    private static final PostgreSQLContainer<?> POSTGRES =
            new PostgreSQLContainer<>("postgres:16-alpine")
                    .withDatabaseName("uten_imp_subcontract_target")
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

    @AfterAll
    static void stop() {
        POSTGRES.stop();
    }

    @Test
    void emptyDatabaseAppliesV436TablesAndDeferredGuards() throws Exception {
        try (Connection connection = connection();
             Statement statement = connection.createStatement()) {
            assertThat(scalar(statement, """
                    SELECT COUNT(*) FROM flyway_schema_history
                    WHERE version = '436' AND success
                    """)).isEqualTo(1);
            assertThat(scalar(statement, """
                    SELECT COUNT(*) FROM information_schema.tables
                    WHERE table_schema = 'public'
                      AND table_name IN (
                        'subcontract_outbound_preparation_commands',
                        'subcontract_outbound_issue_reservation_allocations')
                    """)).isEqualTo(2);
            assertThat(scalar(statement, """
                    SELECT COUNT(*) FROM pg_trigger
                    WHERE NOT tgisinternal AND tgenabled <> 'D'
                      AND tgname IN (
                        'trg_subcontract_preparation_source_guard',
                        'trg_subcontract_preparation_analysis_source_guard',
                        'trg_subcontract_outbound_allocation_guard',
                        'trg_subcontract_outbound_reservation_guard',
                        'trg_subcontract_outbound_issue_item_allocation_guard',
                        'trg_subcontract_outbound_issue_header_allocation_guard',
                        'trg_subcontract_target_receipt_header_guard',
                        'trg_subcontract_target_receipt_item_guard',
                        'trg_subcontract_target_issue_consumption_guard',
                        'trg_subcontract_target_issue_header_guard',
                        'trg_subcontract_prep_finished_stock_item_guard',
                        'trg_subcontract_prep_finished_stock_doc_guard',
                        'trg_subcontract_prep_finished_production_item_guard',
                        'trg_subcontract_prep_finished_production_plan_guard',
                        'trg_subcontract_prep_finished_analysis_link_guard',
                        'trg_subcontract_prep_finished_plan_item_guard')
                    """)).isEqualTo(16);
        }
    }

    @Test
    void approvedReceiptBeforeTargetOutboundIsRejectedAtDeferredBoundary()
            throws Exception {
        try (Connection connection = connection()) {
            connection.setAutoCommit(false);
            try {
                Fixture fixture = seedDirectPlan(connection);
                setReplica(connection, true);
                insertReceipt(connection, fixture, "receipt-before-outbound");
                setReplica(connection, false);
                execute(connection, """
                        UPDATE subcontract_receipt_items
                        SET updated_at = now() WHERE id = ?
                        """, fixture.receiptItemId());

                SQLException rejected = assertThrows(SQLException.class, () ->
                        setConstraints(connection,
                                "trg_subcontract_target_receipt_item_guard"));
                assertThat(rejected.getSQLState()).isEqualTo("23514");
                assertThat(rejected.getMessage())
                        .contains("exceeds approved target-item outbound");
            } finally {
                connection.rollback();
            }
        }
    }

    @Test
    void exactOwnedAllocationConsumptionAndReceiptPassAllDeferredGuards()
            throws Exception {
        try (Connection connection = connection()) {
            connection.setAutoCommit(false);
            try {
                Fixture fixture = seedDirectPlan(connection);
                setReplica(connection, true);
                insertIssueReservationAllocation(
                        connection, fixture, fixture.planItemId(), "exact");
                insertReceipt(connection, fixture, "exact");
                setReplica(connection, false);
                execute(connection, """
                        UPDATE subcontract_material_issue_items
                        SET updated_at = now() WHERE id = ?
                        """, fixture.issueItemId());
                execute(connection, """
                        UPDATE stock_reservations
                        SET updated_at = now() WHERE id = ?
                        """, fixture.reservationId());
                execute(connection, """
                        UPDATE subcontract_receipt_items
                        SET updated_at = now() WHERE id = ?
                        """, fixture.receiptItemId());

                assertDoesNotThrow(() -> setConstraints(connection, String.join(", ",
                        "trg_subcontract_outbound_issue_item_allocation_guard",
                        "trg_subcontract_outbound_reservation_guard",
                        "trg_subcontract_target_issue_consumption_guard",
                        "trg_subcontract_target_receipt_item_guard")));
            } finally {
                connection.rollback();
            }
        }
    }

    @Test
    void reverseAnalysisItemGuardRejectsWrongPreparationLineage()
            throws Exception {
        try (Connection connection = connection()) {
            connection.setAutoCommit(false);
            try {
                Fixture fixture = seedDirectPlan(connection);
                setReplica(connection, true);
                UUID analysisId = UUID.randomUUID();
                UUID analysisItemId = UUID.randomUUID();
                execute(connection, """
                        INSERT INTO production_material_analyses(
                            id, warehouse_id, status, version, fingerprint,
                            initial_idempotency_key, maker_id)
                        VALUES (?, ?, 'ACTIVE', 0, repeat('b', 64),
                                ?, ?)
                        """, analysisId, fixture.warehouseId(),
                        "wrong-lineage-" + analysisId,
                        fixture.actorEmployeeId());
                execute(connection, """
                        INSERT INTO production_material_analysis_items(
                            id, analysis_id, source_type, goods_id, unit_id,
                            source_ref, source_reason, requested_qty)
                        VALUES (?, ?, 'OTHER', ?, ?, 'WRONG-SOURCE',
                                'wrong subcontract preparation lineage', 5)
                        """, analysisItemId, analysisId, fixture.goodsId(),
                        fixture.unitId());
                execute(connection, """
                        UPDATE subcontract_material_plan_items
                        SET flow_mode = 'MAKE_THEN_OUTBOUND',
                            preparation_status = 'IN_PREPARATION',
                            prepared_qty = 0,
                            bom_has_children_snapshot = TRUE,
                            preparation_bom_fingerprint = repeat('c', 64),
                            preparation_warehouse_id = ?,
                            preparation_analysis_id = ?,
                            preparation_analysis_item_id = ?,
                            preparation_started_by = ?,
                            preparation_started_at = now()
                        WHERE id = ?
                        """, fixture.warehouseId(), analysisId, analysisItemId,
                        fixture.actorUserId(), fixture.planItemId());
                setReplica(connection, false);
                execute(connection, """
                        UPDATE production_material_analysis_items
                        SET updated_at = now() WHERE id = ?
                        """, analysisItemId);

                SQLException rejected = assertThrows(SQLException.class, () ->
                        setConstraints(connection,
                                "trg_subcontract_preparation_analysis_source_guard"));
                assertThat(rejected.getSQLState()).isEqualTo("23514");
                assertThat(rejected.getMessage())
                        .contains("analysis lineage is inconsistent");
            } finally {
                connection.rollback();
            }
        }
    }

    @Test
    void preparationCommandUpdateIsRejectedAsAppendOnly() throws Exception {
        try (Connection connection = connection()) {
            connection.setAutoCommit(false);
            try {
                Fixture fixture = seedDirectPlan(connection);
                UUID commandId = UUID.randomUUID();
                setReplica(connection, true);
                execute(connection, """
                        INSERT INTO subcontract_outbound_preparation_commands(
                            id, plan_item_id, operation, idempotency_key,
                            request_hash, expected_version, resulting_version,
                            created_by)
                        VALUES (?, ?, 'START_PREPARATION', ?,
                                repeat('d', 64), 0, 1, ?)
                        """, commandId, fixture.planItemId(),
                        "command-key-" + commandId, fixture.actorUserId());
                setReplica(connection, false);

                SQLException rejected = assertThrows(SQLException.class, () ->
                        execute(connection, """
                                UPDATE subcontract_outbound_preparation_commands
                                SET request_hash = repeat('e', 64)
                                WHERE id = ?
                                """, commandId));
                assertThat(rejected.getSQLState()).isEqualTo("23514");
                assertThat(rejected.getMessage()).contains("append-only");
            } finally {
                connection.rollback();
            }
        }
    }

    @Test
    void allocationOwnerMismatchIsRejectedAtDeferredBoundary()
            throws Exception {
        try (Connection connection = connection()) {
            connection.setAutoCommit(false);
            try {
                Fixture fixture = seedDirectPlan(connection);
                setReplica(connection, true);
                insertIssueReservationAllocation(
                        connection, fixture, UUID.randomUUID(), "owner-mismatch");
                setReplica(connection, false);
                execute(connection, """
                        UPDATE subcontract_material_issue_items
                        SET updated_at = now() WHERE id = ?
                        """, fixture.issueItemId());

                SQLException rejected = assertThrows(SQLException.class, () ->
                        setConstraints(connection,
                                "trg_subcontract_outbound_issue_item_allocation_guard"));
                assertThat(rejected.getSQLState()).isEqualTo("23514");
                assertThat(rejected.getMessage())
                        .contains("allocation provenance is inconsistent");
            } finally {
                connection.rollback();
            }
        }
    }

    @Test
    void finishedInReservationWithoutExactLineageIsRejected()
            throws Exception {
        try (Connection connection = connection()) {
            connection.setAutoCommit(false);
            try {
                Fixture fixture = seedDirectPlan(connection);
                setReplica(connection, true);
                execute(connection, """
                        INSERT INTO stock_reservations(
                            id, order_item_id, goods_id, warehouse_id,
                            qty, consumed_qty, released_qty, status, source,
                            source_doc_type, source_doc_id,
                            owner_type, owner_id, purpose, demand_id,
                            supply_type, supply_id, idempotency_key,
                            created_by, updated_by)
                        VALUES (?, NULL, ?, ?, 5, 0, 0, 0, 1,
                                'PRODUCTION_INBOUND', ?,
                                'SUBCONTRACT_OUTBOUND', ?,
                                'SUBCONTRACT_OUTBOUND', NULL,
                                'PRODUCTION_FINISHED_IN', ?, ?, ?, ?)
                        """, fixture.reservationId(), fixture.goodsId(),
                        fixture.warehouseId(), UUID.randomUUID(),
                        fixture.planItemId(), UUID.randomUUID(),
                        "missing-finished-lineage-" + fixture.reservationId(),
                        fixture.actorUserId(), fixture.actorUserId());
                setReplica(connection, false);
                execute(connection, """
                        UPDATE stock_reservations
                        SET updated_at = now() WHERE id = ?
                        """, fixture.reservationId());

                SQLException rejected = assertThrows(SQLException.class, () ->
                        setConstraints(connection,
                                "trg_subcontract_outbound_reservation_guard"));
                assertThat(rejected.getSQLState()).isEqualTo("23514");
                assertThat(rejected.getMessage())
                        .contains("FINISHED_IN reservation lineage is inconsistent");
            } finally {
                connection.rollback();
            }
        }
    }

    private static Fixture seedDirectPlan(Connection connection) throws Exception {
        setReplica(connection, true);
        UUID actorUserId = UUID.randomUUID();
        UUID actorEmployeeId = UUID.randomUUID();
        execute(connection, """
                INSERT INTO employees(
                    id, code, full_name, id_type, department_id,
                    hire_date, status, employment_type)
                VALUES (?, ?, 'V436 guard actor', '其他', ?,
                        DATE '2026-08-30', 'active', 'regular')
                """, actorEmployeeId, "V436-E-" + actorEmployeeId,
                UUID.randomUUID());
        execute(connection, """
                INSERT INTO users(
                    id, employee_id, login_account, password_hash, status)
                VALUES (?, ?, ?, 'test-only-not-a-real-password', 'active')
                """, actorUserId, actorEmployeeId,
                "v436-guard-" + actorUserId);
        UUID unitId = UUID.randomUUID();
        UUID goodsId = UUID.randomUUID();
        UUID warehouseId = UUID.randomUUID();
        UUID orderId = UUID.randomUUID();
        UUID orderItemId = UUID.randomUUID();
        UUID planId = UUID.randomUUID();
        UUID planItemId = UUID.randomUUID();
        UUID settlementMethodId = UUID.randomUUID();
        execute(connection, """
                INSERT INTO units(id, code, name, status)
                VALUES (?, ?, 'piece', '使用')
                """, unitId, "V436-U-" + unitId);
        execute(connection, """
                INSERT INTO goods(
                    id, code, name, unit_id, code_sequence)
                VALUES (?, ?, 'V436 target goods', ?,
                        (SELECT COALESCE(MAX(code_sequence), 0) + 1 FROM goods))
                """, goodsId, "V436-G-" + goodsId, unitId);
        execute(connection, """
                INSERT INTO warehouses(id, code, name, status)
                VALUES (?, ?, 'V436 warehouse', '使用')
                """, warehouseId, "V436-W-" + warehouseId);
        execute(connection, """
                INSERT INTO settlement_methods(id, code, name, status)
                VALUES (?, ?, 'V436 settlement', '使用')
                """, settlementMethodId, "V436-S-" + settlementMethodId);
        execute(connection, """
                INSERT INTO subcontract_orders(
                    id, bill_no, bill_date, warehouse_id,
                    settlement_method_id, status)
                VALUES (?, ?, DATE '2026-08-30', ?, ?, 1)
                """, orderId, "EO-V436-" + orderId, warehouseId,
                settlementMethodId);
        execute(connection, """
                INSERT INTO subcontract_order_items(
                    id, bill_no, bill_date, order_id, line_no,
                    goods_id, unit_id, unit_rate, qty,
                    goods_code_snapshot, goods_name_snapshot,
                    goods_snapshot_source, goods_snapshot_locked_at)
                VALUES (?, ?, DATE '2026-08-30', ?, 1,
                        ?, ?, 1, 5, ?, 'V436 target goods',
                        'MASTER_AT_APPROVAL', now())
                """, orderItemId, "EO-V436-" + orderId, orderId,
                goodsId, unitId, "V436-G-" + goodsId);
        execute(connection, """
                INSERT INTO subcontract_material_plans(
                    id, order_id, order_bill_no, status, created_by, updated_by)
                VALUES (?, ?, ?, 'OPEN', ?, ?)
                """, planId, orderId, "EO-V436-" + orderId,
                actorUserId, actorUserId);
        execute(connection, """
                INSERT INTO subcontract_material_plan_items(
                    id, plan_id, order_item_id, line_no,
                    parent_goods_id, goods_id, unit_id,
                    unit_rate, bom_unit_qty, planned_qty, issued_qty,
                    flow_mode, preparation_status, prepared_qty,
                    bom_has_children_snapshot, preparation_bom_fingerprint,
                    preparation_warehouse_id, created_by, updated_by)
                VALUES (?, ?, ?, 1, ?, ?, ?, 1, 1, 5, 5,
                        'DIRECT_OUTBOUND', 'OUTBOUND_COMPLETE', 5,
                        FALSE, repeat('a', 64), ?, ?, ?)
                """, planItemId, planId, orderItemId, goodsId, goodsId,
                unitId, warehouseId, actorUserId, actorUserId);
        setReplica(connection, false);
        return new Fixture(
                actorUserId, actorEmployeeId, unitId, goodsId, warehouseId,
                orderId, orderItemId, planId, planItemId,
                UUID.randomUUID(), UUID.randomUUID(), UUID.randomUUID(),
                UUID.randomUUID(), UUID.randomUUID(), UUID.randomUUID());
    }

    private static void insertIssueReservationAllocation(
            Connection connection, Fixture fixture, UUID reservationOwner,
            String suffix) throws Exception {
        execute(connection, """
                INSERT INTO subcontract_material_issues(
                    id, bill_no, bill_date, warehouse_id, status, created_by)
                VALUES (?, ?, DATE '2026-08-30', ?, 1, ?)
                """, fixture.issueId(), "EC-V436-" + suffix,
                fixture.warehouseId(), fixture.actorUserId());
        execute(connection, """
                INSERT INTO subcontract_material_issue_items(
                    id, bill_no, bill_date, issue_id, order_item_id, line_no,
                    goods_id, unit_id, unit_rate, qty,
                    at_supplier_qty, consumed_qty, plan_item_id,
                    goods_code_snapshot, goods_name_snapshot,
                    goods_snapshot_source, goods_snapshot_locked_at)
                VALUES (?, ?, DATE '2026-08-30', ?, ?, 1,
                        ?, ?, 1, 5, 5, 5, ?,
                        ?, 'V436 target goods',
                        'MASTER_AT_APPROVAL', now())
                """, fixture.issueItemId(), "EC-V436-" + suffix,
                fixture.issueId(), fixture.orderItemId(), fixture.goodsId(),
                fixture.unitId(), fixture.planItemId(),
                "V436-G-" + fixture.goodsId());
        execute(connection, """
                INSERT INTO stock_reservations(
                    id, order_item_id, goods_id, warehouse_id,
                    qty, consumed_qty, released_qty, status, source,
                    source_doc_type, source_doc_id,
                    owner_type, owner_id, purpose, demand_id,
                    supply_type, supply_id, idempotency_key,
                    created_by, updated_by)
                VALUES (?, NULL, ?, ?, 5, 5, 0, 1, 0,
                        'SUBCONTRACT_OUTBOUND_DRAFT', ?,
                        'SUBCONTRACT_OUTBOUND', ?,
                        'SUBCONTRACT_OUTBOUND', NULL,
                        'STOCK_BALANCE', ?, ?, ?, ?)
                """, fixture.reservationId(), fixture.goodsId(),
                fixture.warehouseId(), fixture.issueId(), reservationOwner,
                UUID.randomUUID(), "reservation-" + suffix + "-"
                        + fixture.reservationId(),
                fixture.actorUserId(), fixture.actorUserId());
        execute(connection, """
                INSERT INTO subcontract_outbound_issue_reservation_allocations(
                    id, issue_id, issue_item_id, plan_item_id,
                    reservation_id, allocated_qty, status,
                    idempotency_key, created_by)
                VALUES (?, ?, ?, ?, ?, 5, 'EFFECTIVE', ?, ?)
                """, fixture.allocationId(), fixture.issueId(),
                fixture.issueItemId(), fixture.planItemId(),
                fixture.reservationId(),
                "allocation-" + suffix + "-" + fixture.allocationId(),
                fixture.actorUserId());
    }

    private static void insertReceipt(
            Connection connection, Fixture fixture, String suffix)
            throws Exception {
        execute(connection, """
                INSERT INTO subcontract_receipts(
                    id, bill_no, bill_date, warehouse_id, status, created_by)
                VALUES (?, ?, DATE '2026-08-30', ?, 1, ?)
                """, fixture.receiptId(), "EI-V436-" + suffix,
                fixture.warehouseId(), fixture.actorUserId());
        execute(connection, """
                INSERT INTO subcontract_receipt_items(
                    id, bill_no, bill_date, receipt_id, order_item_id, line_no,
                    goods_id, unit_id, unit_rate, qty,
                    goods_code_snapshot, goods_name_snapshot,
                    goods_snapshot_source, goods_snapshot_locked_at)
                VALUES (?, ?, DATE '2026-08-30', ?, ?, 1,
                        ?, ?, 1, 5, ?, 'V436 target goods',
                        'MASTER_AT_APPROVAL', now())
                """, fixture.receiptItemId(), "EI-V436-" + suffix,
                fixture.receiptId(), fixture.orderItemId(), fixture.goodsId(),
                fixture.unitId(), "V436-G-" + fixture.goodsId());
    }

    private static void setReplica(Connection connection, boolean replica)
            throws SQLException {
        try (Statement statement = connection.createStatement()) {
            statement.execute("SET LOCAL session_replication_role = "
                    + (replica ? "replica" : "origin"));
        }
    }

    private static void setConstraints(Connection connection, String names)
            throws SQLException {
        try (Statement statement = connection.createStatement()) {
            statement.execute("SET CONSTRAINTS " + names + " IMMEDIATE");
        }
    }

    private static void execute(
            Connection connection, String sql, Object... values)
            throws SQLException {
        try (PreparedStatement statement = connection.prepareStatement(sql)) {
            for (int index = 0; index < values.length; index++) {
                statement.setObject(index + 1, values[index]);
            }
            statement.executeUpdate();
        }
    }

    private static long scalar(Statement statement, String sql)
            throws SQLException {
        try (ResultSet result = statement.executeQuery(sql)) {
            result.next();
            return result.getLong(1);
        }
    }

    private static Connection connection() throws SQLException {
        return DriverManager.getConnection(
                POSTGRES.getJdbcUrl(),
                POSTGRES.getUsername(),
                POSTGRES.getPassword());
    }

    private record Fixture(
            UUID actorUserId,
            UUID actorEmployeeId,
            UUID unitId,
            UUID goodsId,
            UUID warehouseId,
            UUID orderId,
            UUID orderItemId,
            UUID planId,
            UUID planItemId,
            UUID issueId,
            UUID issueItemId,
            UUID reservationId,
            UUID allocationId,
            UUID receiptId,
            UUID receiptItemId) {
    }
}
