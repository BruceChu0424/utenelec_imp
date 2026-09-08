package com.uten.imp.features.warehouse.inbound;

import com.uten.imp.support.ProcurementReceiptFixtureSupport;
import com.fasterxml.jackson.databind.ObjectMapper;
import com.uten.imp.application.port.BusinessEventPublisher;
import com.uten.imp.application.port.FinanceReviewerEligibilityPort;
import com.uten.imp.features.purchase.receipt.ReceiptPriceMasker;
import com.uten.imp.security.SecurityContextCurrentUser;
import com.uten.imp.security.TxSessionVars;
import org.flywaydb.core.Flyway;
import org.flywaydb.core.api.MigrationVersion;
import org.junit.jupiter.api.AfterAll;
import org.junit.jupiter.api.BeforeAll;
import org.junit.jupiter.api.Test;
import org.junit.jupiter.api.condition.EnabledIfEnvironmentVariable;
import org.springframework.jdbc.core.JdbcTemplate;
import org.springframework.jdbc.datasource.DriverManagerDataSource;
import org.testcontainers.containers.PostgreSQLContainer;

import java.math.BigDecimal;
import java.sql.Connection;
import java.sql.DriverManager;
import java.sql.PreparedStatement;
import java.sql.ResultSet;
import java.sql.SQLException;
import java.sql.Statement;
import java.time.LocalDate;
import java.util.UUID;

import static org.junit.jupiter.api.Assertions.assertDoesNotThrow;
import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertFalse;
import static org.junit.jupiter.api.Assertions.assertThrows;
import static org.junit.jupiter.api.Assertions.assertTrue;
import static org.mockito.Mockito.mock;

/** Real PostgreSQL proof for V201's receipt-bound finance allowance. */
@EnabledIfEnvironmentVariable(named = "UTEN_RUN_DB_TESTS", matches = "(?i)true")
class ProcurementArrivalGuardPostgresTest {

    private static final java.util.concurrent.atomic.AtomicInteger BUSINESS_IDENTIFIER_SEQUENCE =
            new java.util.concurrent.atomic.AtomicInteger();

    private static final PostgreSQLContainer<?> POSTGRES =
            new PostgreSQLContainer<>("postgres:16-alpine")
                    .withDatabaseName("uten_imp")
                    .withUsername("uten")
                    .withPassword("uten");

    @BeforeAll
    static void migrate() {
        POSTGRES.start();
        var configuration = Flyway.configure()
                .dataSource(POSTGRES.getJdbcUrl(), POSTGRES.getUsername(), POSTGRES.getPassword())
                .locations("classpath:db/migration");
        String target = System.getProperty("uten.test.flyway.target");
        if (target != null && !target.isBlank()) {
            configuration.target(MigrationVersion.fromVersion(target));
        }
        configuration.load().migrate();
    }

    @AfterAll
    static void stopPostgres() {
        POSTGRES.stop();
    }

    @Test
    void emptyFiltersExecuteExpectationQueriesOnPostgres() {
        JdbcTemplate jdbc = new JdbcTemplate(new DriverManagerDataSource(
                POSTGRES.getJdbcUrl(), POSTGRES.getUsername(), POSTGRES.getPassword()));
        ProcurementArrivalControlService service =
                new ProcurementArrivalControlService(
                        jdbc,
                        new ObjectMapper(),
                        mock(BusinessEventPublisher.class),
                        mock(SecurityContextCurrentUser.class),
                        mock(TxSessionVars.class),
                        mock(FinanceReviewerEligibilityPort.class),
                        mock(ReceiptPriceMasker.class),
                        com.uten.imp.support.FulfillmentMutationLockTestSupport.procurementLocks());

        var page = assertDoesNotThrow(() -> service.expectations(1, 20, null, null));

        assertTrue(page.getItems().isEmpty());
        assertEquals(0L, page.getTotal());
        assertEquals(0L, assertDoesNotThrow(service::countExpectations));
        assertTrue(assertDoesNotThrow(service::countExpectationsByType).isEmpty());
    }

    @Test
    void subcontractExpectationAppearsOnlyForTheActuallyOutboundBatch() throws Exception {
        UUID unitId = UUID.randomUUID();
        UUID goodsId = UUID.randomUUID();
        UUID warehouseId = UUID.randomUUID();
        UUID supplierId = UUID.randomUUID();
        UUID currencyId = UUID.randomUUID();
        UUID settlementMethodId = UUID.randomUUID();
        UUID orderId = UUID.randomUUID();
        UUID orderItemId = UUID.randomUUID();
        UUID planId = UUID.randomUUID();
        UUID planItemId = UUID.randomUUID();
        UUID approvalCaseId = UUID.randomUUID();
        UUID expectationId = UUID.randomUUID();
        String orderNo="EO20260831000001",issueNo="EC20260831000001",receiptNo="EJ20260831000001",replacementNo="EJ20260902000001";
        UUID inspectionId=UUID.randomUUID();
        Identity actor;
        try (Connection connection = connection()) {
            connection.setAutoCommit(false);
            actor = loadIdentity(connection);
            executeSql(connection, """
                    INSERT INTO units(id, code, name, status)
                    VALUES (?, ?, 'piece', '使用')
                    """, unitId, "ARR-REL-U-" + unitId);
            executeSql(connection, """
                    INSERT INTO goods(id, code, name, unit_id, code_sequence)
                    VALUES (?, ?, 'outbound released goods', ?,
                            (SELECT COALESCE(MAX(code_sequence),0)+1 FROM goods))
                    """, goodsId, "ARR-REL-G-" + goodsId, unitId);
            executeSql(connection, """
                    INSERT INTO warehouses(id, code, name, status)
                    VALUES (?, ?, 'outbound release warehouse', '使用')
                    """, warehouseId, "ARR-REL-W-" + warehouseId);
            executeSql(connection, """
                    INSERT INTO currencies(id, code, name, exchange_rate, status)
                    VALUES (?, ?, 'outbound release currency', 1, '使用')
                    """, currencyId, "ARR-REL-C-" + currencyId);
            executeSql(connection, """
                    INSERT INTO settlement_methods(id, code, name, status)
                    VALUES (?, ?, 'outbound release settlement', '使用')
                    """, settlementMethodId, "ARR-REL-S-" + settlementMethodId);
            executeSql(connection, """
                    INSERT INTO suppliers(
                        id, code, name, status, category_id,
                        code_sequence, code_managed)
                    SELECT ?, ?, 'outbound release supplier', '使用', category.id,
                           (SELECT COALESCE(MAX(code_sequence), 0) + 1 FROM suppliers),
                           FALSE
                    FROM supplier_categories category
                    WHERE category.is_deleted = FALSE
                    ORDER BY category.id
                    LIMIT 1
                    """, supplierId, "ARR-REL-SUP-" + supplierId);
            executeSql(connection, """
                    INSERT INTO subcontract_orders(
                        id, bill_no, bill_date, supplier_id, warehouse_id,
                        currency_id, exchange_rate, tax_rate,
                        settlement_method_id, total_original, total_local, status)
                    VALUES (?, ?, DATE '2026-08-31', ?, ?, ?, 1, 0, ?, 0, 0, 1)
                    """, orderId, orderNo,
                    supplierId, warehouseId, currencyId, settlementMethodId);
            executeSql(connection, """
                    INSERT INTO subcontract_order_items(
                        id, bill_no, bill_date, order_id, line_no,
                        goods_id, unit_id, unit_rate, qty, price,
                        amount_original, amount_local,
                        goods_code_snapshot, goods_name_snapshot,
                        goods_snapshot_source, goods_snapshot_locked_at)
                    VALUES (?, ?, DATE '2026-08-31', ?, 1,
                            ?, ?, 1, 5, 0, 0, 0, ?, 'outbound released goods',
                            'MASTER_AT_APPROVAL', now())
                    """, orderItemId, orderNo, orderId,
                    goodsId, unitId, "ARR-REL-G-" + goodsId);
            executeSql(connection, """
                    INSERT INTO procurement_order_approval_cases(
                        id, order_type, order_id, attempt, bill_no_snapshot,
                        amount_snapshot, submission_snapshot, snapshot_hash,
                        submitted_by_user_id, submitted_by_employee_id,
                        assignee_user_id, assignee_employee_id,
                        assignee_name_snapshot, status,
                        decided_by_user_id, decided_by_employee_id, decided_at)
                    VALUES (?, 'SUBCONTRACT', ?, 1, ?, 0, '{}'::jsonb,
                            repeat('a',64), ?, ?, ?, ?, ?, 'APPROVED', ?, ?, now())
                    """, approvalCaseId, orderId, orderNo,
                    actor.userId(), actor.employeeId(), actor.userId(), actor.employeeId(),
                    actor.name(), actor.userId(), actor.employeeId());
            executeSql(connection, """
                    INSERT INTO inbound_expectations(
                        id, order_type, order_id, approval_case_id,
                        bill_no_snapshot, warehouse_id, expected_date,
                        owner_employee_id, status, created_by)
                    VALUES (?, 'SUBCONTRACT', ?, ?, ?, ?, DATE '2026-09-10',
                            ?, 'OPEN', ?)
                    """, expectationId, orderId, approvalCaseId,
                    orderNo, warehouseId,
                    actor.employeeId(), actor.userId());
            executeSql(connection, """
                    INSERT INTO inbound_expectation_items(
                        id, expectation_id, order_item_id, line_no,
                        goods_id, unit_id, unit_rate,
                        ordered_qty, accepted_qty, expected_date)
                    VALUES (?, ?, ?, 1, ?, ?, 1, 5, 0, DATE '2026-09-10')
                    """, UUID.randomUUID(), expectationId, orderItemId, goodsId, unitId);
            executeSql(connection, """
                    INSERT INTO subcontract_material_plans(
                        id, order_id, order_bill_no, status, created_by, updated_by)
                    VALUES (?, ?, ?, 'OPEN', ?, ?)
                    """, planId, orderId, orderNo,
                    actor.userId(), actor.userId());
            executeSql(connection, """
                    INSERT INTO subcontract_material_plan_items(
                        id, plan_id, order_item_id, line_no,
                        parent_goods_id, goods_id, unit_id,
                        unit_rate, bom_unit_qty, planned_qty, issued_qty,
                        flow_mode, preparation_status, prepared_qty,
                        bom_has_children_snapshot, preparation_bom_fingerprint,
                        preparation_warehouse_id, created_by, updated_by)
                    VALUES (?, ?, ?, 1, ?, ?, ?, 1, 1, 5, 0,
                            'DIRECT_OUTBOUND', 'READY_OUTBOUND', 5,
                            FALSE, repeat('b',64), ?, ?, ?)
                    """, planItemId, planId, orderItemId, goodsId, goodsId,
                    unitId, warehouseId, actor.userId(), actor.userId());
            connection.commit();
        }

        try(Connection connection=connection()) {
            ProcurementReceiptFixtureSupport.seedZeroPriceQualifiedStock(connection,warehouseId,goodsId,unitId,supplierId,currencyId,
                    settlementMethodId,new BigDecimal("5"),actor.userId(),LocalDate.of(2026,8,31));
        }

        ProcurementArrivalControlService service = service();
        assertEquals(0L, service.expectations(1, 20, "SUBCONTRACT", "").getTotal());
        assertEquals(0L, service.countExpectations());

        UUID issueId = UUID.randomUUID();
        UUID issueItemId=UUID.randomUUID();
        try(Connection connection=connection()) {
            ProcurementReceiptFixtureSupport.postSubcontractIssueFixture(connection,issueId,issueItemId,orderItemId,planItemId,
                    warehouseId,goodsId,unitId,new BigDecimal("2"),actor.userId(),issueNo,LocalDate.of(2026,8,31));
        }

        var released = service.expectations(1, 20, "SUBCONTRACT", "");
        assertEquals(1L, released.getTotal());
        assertEquals(0, new BigDecimal("2.0000")
                .compareTo(released.getItems().getFirst().remainingQty()));
        assertEquals(0, new BigDecimal("2.0000")
                .compareTo(released.getItems().getFirst().items().getFirst().remainingQty()));
        assertEquals(1L, service.countExpectationsByType().get("SUBCONTRACT"));

        UUID receiptId = UUID.randomUUID();
        UUID receiptItemId = UUID.randomUUID();
        try (Connection connection = connection()) {
            connection.setAutoCommit(false);
            executeSql(connection, """
                    INSERT INTO subcontract_receipts(
                        id, bill_no, bill_date, warehouse_id, supplier_id,currency_id,settlement_method_id,exchange_rate,total_original,total_local,status,created_by)
                    VALUES (?, ?, DATE '2026-08-31', ?,?,?,?,1,0,0,1,?)
                    """, receiptId, receiptNo,warehouseId,supplierId,currencyId,settlementMethodId,actor.userId());
            executeSql(connection, """
                    INSERT INTO subcontract_receipt_items(
                        id, bill_no, bill_date, receipt_id, order_item_id, line_no,
                        goods_id, unit_id, unit_rate, qty,price,amount_original,amount_local,replacement_intent,
                        goods_code_snapshot, goods_name_snapshot,
                        goods_snapshot_source, goods_snapshot_locked_at)
                    VALUES (?, ?, DATE '2026-08-31', ?, ?, 1,
                            ?, ?, 1, 2,0,0,0,'NORMAL', ?, 'outbound released goods',
                            'MASTER_AT_APPROVAL', now())
                    """, receiptItemId, receiptNo,
                    receiptId, orderItemId, goodsId, unitId,
                    "ARR-REL-G-" + goodsId);
            executeSql(connection,"UPDATE subcontract_material_issue_items SET consumed_qty=2 WHERE id=?",issueItemId);
            executeSql(connection,"INSERT INTO subcontract_receipt_material_consumptions(id,receipt_item_id,issue_item_id,qty_doc,qty_base,consumption_basis,created_by) VALUES(?,?,?,2,2,'DIRECT_TARGET',?)",UUID.randomUUID(),receiptItemId,issueItemId,actor.userId());
            ProcurementReceiptFixtureSupport.appendStandardReceipt(connection,"SUBCONTRACT",receiptId,actor.userId());
            executeSql(connection,"""
                    INSERT INTO procurement_inspection_items(id,receipt_type,receipt_id,receipt_item_id,warehouse_id,goods_id,
                        unit_id,unit_rate,received_base_qty,received_amount_local,status)
                    VALUES(?,'SUBCONTRACT',?,?,?,?,?,1,2,0,'PENDING')
                    """,inspectionId,receiptId,receiptItemId,warehouseId,goodsId,unitId);
            ProcurementReceiptFixtureSupport.recordZeroPriceQualityDecision(connection,inspectionId,"FAIL",new BigDecimal("2"),actor.userId());
            connection.commit();
        }

        assertEquals(0L, service.expectations(1, 20, "SUBCONTRACT", "").getTotal());
        assertEquals(0L, service.countExpectations());

        UUID rejectionCaseId = UUID.randomUUID();
        UUID fundingId;
        try (Connection connection = connection()) {
            connection.setAutoCommit(false);
            executeSql(connection, """
                    INSERT INTO procurement_iqc_rejection_cases(
                        id, receipt_type, receipt_id, receipt_item_id,
                        inspection_item_id, order_item_id, receipt_bill_no,
                        order_bill_no, supplier_id, currency_id, exchange_rate,
                        tax_rate, settlement_method_id, goods_id, unit_id,
                        unit_rate, received_base_qty, received_qty,
                        received_amount_original, received_amount_local,
                        failed_base_qty, failed_qty, failed_amount_original,
                        failed_amount_local, owner_user_id, status, row_version,
                        return_reference, return_date, return_note,
                        return_recorded_by, return_recorded_at, created_by, updated_by)
                    VALUES (?, 'SUBCONTRACT', ?, ?, ?, ?, ?, ?, ?, ?, 1, 0, ?, ?, ?,
                            1, 2, 2, 0, 0, 2, 2, 0, 0, ?, 'RETURN_RECORDED', 1,
                            'RET-ARR-REL', DATE '2026-09-01', 'physical IQC return',
                            ?, now(), ?, ?)
                    """, rejectionCaseId, receiptId, receiptItemId, inspectionId,
                    orderItemId, receiptNo,
                    orderNo, supplierId, currencyId,
                    settlementMethodId, goodsId, unitId, actor.userId(),
                    actor.userId(), actor.userId(), actor.userId());
            fundingId=ProcurementReceiptFixtureSupport.appendFailureFunding(connection,rejectionCaseId,actor.userId());
            connection.commit();
        }

        var replacementReleased = service.expectations(1, 20, "SUBCONTRACT", "");
        assertEquals(1L, replacementReleased.getTotal());
        assertEquals(0, new BigDecimal("2")
                .compareTo(replacementReleased.getItems().getFirst().remainingQty()));

        UUID replacementReceiptId = UUID.randomUUID();
        UUID replacementReceiptItemId = UUID.randomUUID();
        UUID replacementAllocationId=UUID.randomUUID();
        try (Connection connection = connection()) {
            connection.setAutoCommit(false);
            executeSql(connection, """
                    INSERT INTO subcontract_receipts(
                        id, bill_no, bill_date, warehouse_id,supplier_id,currency_id,settlement_method_id,exchange_rate,total_original,total_local,status,created_by)
                    VALUES (?, ?, DATE '2026-09-02', ?,?,?,?,1,0,0,1,?)
                    """, replacementReceiptId,replacementNo,warehouseId,supplierId,currencyId,settlementMethodId,actor.userId());
            executeSql(connection, """
                    INSERT INTO subcontract_receipt_items(
                        id, bill_no, bill_date, receipt_id, order_item_id, line_no,
                        goods_id, unit_id, unit_rate, qty,price,amount_original,amount_local,replacement_intent,
                        goods_code_snapshot, goods_name_snapshot,
                        goods_snapshot_source, goods_snapshot_locked_at)
                    VALUES (?, ?, DATE '2026-09-02', ?, ?, 1,
                            ?, ?, 1, 1,0,0,0,'RETURN_REPLACEMENT', ?, 'outbound released goods',
                            'MASTER_AT_APPROVAL', now())
                    """, replacementReceiptItemId,
                    replacementNo,
                    replacementReceiptId, orderItemId, goodsId, unitId,
                    "ARR-REL-G-" + goodsId);
            executeSql(connection, """
                    INSERT INTO procurement_iqc_replacement_allocations(
                        id, case_id, replacement_receipt_type,
                        replacement_receipt_id, replacement_receipt_item_id,
                        allocated_base_qty, allocated_qty,
                        allocated_amount_original, allocated_amount_local,
                        status, row_version, created_by)
                    VALUES (?, ?, 'SUBCONTRACT', ?, ?, 1, 1, 0, 0, 'ACTIVE', 1, ?)
                    """, replacementAllocationId, rejectionCaseId,
                    replacementReceiptId, replacementReceiptItemId, actor.userId());
            ProcurementReceiptFixtureSupport.appendNoChargeReplacement(connection,"SUBCONTRACT",replacementReceiptId,replacementAllocationId,fundingId,actor.userId());
            connection.commit();
        }

        var partiallyReplaced = service.expectations(1, 20, "SUBCONTRACT", "");
        assertEquals(1L, partiallyReplaced.getTotal());
        assertEquals(0, BigDecimal.ONE
                .compareTo(partiallyReplaced.getItems().getFirst().remainingQty()));
    }

    @Test
    void insertPathDoesNotReadOldAndUnapprovedOverageStillFails() throws Exception {
        UUID goodsId = UUID.randomUUID();
        UUID orderId = UUID.randomUUID();
        try (Connection connection = connection()) {
            insertGoodsAndOrder(connection, goodsId, orderId);
            assertEquals(1, insertOrderItem(
                    connection, UUID.randomUUID(), orderId, goodsId,
                    new BigDecimal("10.0000"), BigDecimal.ZERO));

            SQLException error = assertThrows(SQLException.class, () -> insertOrderItem(
                    connection, UUID.randomUUID(), orderId, goodsId,
                    new BigDecimal("10.0000"), new BigDecimal("10.0001")));
            assertEquals("23514", error.getSQLState());
            assertTrue(error.getMessage().contains(
                    "received_qty exceeds finance-approved arrival capacity"));
        }
    }

    @Test
    void approvedExcessCanOnlyBeConsumedByItsOwnReceipt() throws Exception {
        ArrivalFixture fixture;
        try (Connection connection = connection()) {
            fixture = insertArrivalFixture(connection);
        }

        try (Connection connection = connection()) {
            connection.setAutoCommit(false);
            try {
                setReceiptContext(connection, fixture.receiptId());
                assertEquals(1, updateReceivedQty(
                        connection, fixture.orderItemId(), new BigDecimal("15.0000")));
            } finally {
                connection.rollback();
            }
        }

        try (Connection connection = connection()) {
            connection.setAutoCommit(false);
            try {
                setReceiptContext(connection, UUID.randomUUID());
                SQLException error = assertThrows(SQLException.class, () -> updateReceivedQty(
                        connection, fixture.orderItemId(), new BigDecimal("15.0000")));
                assertEquals("23514", error.getSQLState());
                assertTrue(error.getMessage().contains(
                        "received_qty exceeds finance-approved arrival capacity"));
            } finally {
                connection.rollback();
            }
        }
    }

    /**
     * recordApproval 的入库通知触发条件：仅当异常推进后仍有 PENDING_RETURN 任务时，
     * 状态转为 RECEIPT_POSTED（ProcurementArrivalControlService 据此 publish 入库通知）；
     * 无待退则转 CLOSED、不打扰。此处用与 service 完全相同的 SQL 在真实 PG 上验证。
     */
    @Test
    void recordApprovalSignalsReturnOnlyWhenPendingReturnTaskExists() throws Exception {
        Identity actor;
        ReturnFixture withReturn;
        ReturnFixture withoutReturn;
        try (Connection connection = connection()) {
            actor = loadIdentity(connection);
            // 异常 A：有未退量 + PENDING_RETURN 任务 → RECEIPT_POSTED + 触发入库通知
            withReturn = insertAdjustedException(
                    connection, actor, "10.0000", "5.0000", "0.0000", "REJECT_EXCESS");
            insertPendingReturnTask(connection, withReturn, actor, "5.0000");
            // 异常 B：全部接收、无未退量、无 return 任务 → CLOSED（不通知）
            withoutReturn = insertAdjustedException(
                    connection, actor, "15.0000", "0.0000", "5.0000", "APPROVE_ALL");
        }

        try (Connection connection = connection()) {
            // hasPendingReturnTask（与 ProcurementArrivalControlService 相同 SQL）
            assertTrue(pendingReturnExists(connection, withReturn.exceptionId()));
            assertFalse(pendingReturnExists(connection, withoutReturn.exceptionId()));

            // recordApproval 的 CASE 状态转移 UPDATE（与 service 相同 SQL）
            assertEquals(1, applyReceiptPostedTransition(connection, withReturn.exceptionId()));
            assertEquals(1, applyReceiptPostedTransition(connection, withoutReturn.exceptionId()));
            assertEquals("RECEIPT_POSTED", statusOf(connection, withReturn.exceptionId()));
            assertEquals("CLOSED", statusOf(connection, withoutReturn.exceptionId()));
        }
    }

    @Test
    void financeDraftAdjustmentCannotDeleteAnApprovedReceiptItem()
            throws Exception {
        try (Connection connection = connection()) {
            Identity actor = loadIdentity(connection);
            ReturnFixture fixture = insertAdjustedException(
                    connection, actor,
                    "10.0000", "5.0000", "0.0000", "REJECT_EXCESS");
            connection.setAutoCommit(false);
            try {
                try (PreparedStatement approve = connection.prepareStatement("""
                        UPDATE purchase_receipts
                        SET status = 1
                        WHERE id = ? AND status = 0
                        """)) {
                    approve.setObject(1, fixture.receiptId());
                    assertEquals(1, approve.executeUpdate());
                }
                try (PreparedStatement context = connection.prepareStatement("""
                        SELECT set_config(
                            'app.procurement_arrival_decision', 'on', true)
                        """)) {
                    context.executeQuery();
                }
                try (PreparedStatement delete = connection.prepareStatement("""
                        DELETE FROM purchase_receipt_items item
                        USING purchase_receipts receipt
                        WHERE item.id = ?
                          AND receipt.id = item.receipt_id
                          AND receipt.status = 0
                          AND receipt.is_deleted = FALSE
                          AND item.is_deleted = FALSE
                        """)) {
                    delete.setObject(1, fixture.receiptItemId());
                    assertEquals(0, delete.executeUpdate());
                }
                try (PreparedStatement count = connection.prepareStatement("""
                        SELECT COUNT(*)
                        FROM purchase_receipt_items
                        WHERE id = ?
                        """)) {
                    count.setObject(1, fixture.receiptItemId());
                    try (var result = count.executeQuery()) {
                        assertTrue(result.next());
                        assertEquals(1L, result.getLong(1));
                    }
                }
            } finally {
                connection.rollback();
            }
        }
    }

    /** 构造一条 status=RECEIPT_ADJUSTED 的异常（declared = accepted + unaccepted；accepted = approved_remaining + approved_excess）。 */
    private static ReturnFixture insertAdjustedException(
            Connection connection, Identity actor,
            String acceptedQty, String unacceptedQty,
            String approvedExcessQty, String decision) throws Exception {
        UUID goodsId = UUID.randomUUID();
        UUID orderId = UUID.randomUUID();
        UUID orderItemId = UUID.randomUUID();
        UUID receiptId = UUID.randomUUID();
        UUID receiptItemId = UUID.randomUUID();
        UUID exceptionId = UUID.randomUUID();
        BigDecimal accepted = new BigDecimal(acceptedQty);
        BigDecimal approvedExcess = new BigDecimal(approvedExcessQty);
        BigDecimal approvedRemaining = accepted.subtract(approvedExcess);
        LocalDate billDate = LocalDate.of(2026, 8, 2);
        String orderNo = insertGoodsAndOrder(connection, goodsId, orderId);
        String receiptNo = businessIdentifier("CJ", billDate);
        insertOrderItem(connection, orderItemId, orderId, goodsId,
                new BigDecimal("15.0000"), BigDecimal.ZERO);
        try (PreparedStatement receipt = connection.prepareStatement("""
                insert into purchase_receipts(id, bill_no, bill_date, status)
                values (?, ?, ?, 0)
                """)) {
            receipt.setObject(1, receiptId);
            receipt.setString(2, receiptNo);
            receipt.setObject(3, billDate);
            assertEquals(1, receipt.executeUpdate());
        }
        try (PreparedStatement item = connection.prepareStatement("""
                insert into purchase_receipt_items(
                    id, bill_no, bill_date, receipt_id, order_item_id, goods_id, qty,
                    goods_snapshot_source)
                values (?, ?, ?, ?, ?, ?, 15.0000, 'MASTER_AT_SAVE')
                """)) {
            item.setObject(1, receiptItemId);
            item.setString(2, receiptNo);
            item.setObject(3, billDate);
            item.setObject(4, receiptId);
            item.setObject(5, orderItemId);
            item.setObject(6, goodsId);
            assertEquals(1, item.executeUpdate());
        }
        try (PreparedStatement exception = connection.prepareStatement("""
                insert into procurement_arrival_exceptions(
                    id, order_type, receipt_id, receipt_item_id,
                    receipt_bill_no_snapshot, order_id, order_item_id,
                    order_bill_no_snapshot, goods_id, declared_qty,
                    approved_remaining_qty, approved_excess_qty,
                    accepted_qty, unaccepted_qty,
                    finance_assignee_user_id, finance_assignee_employee_id,
                    finance_assignee_name_snapshot,
                    status, decision, finance_reason,
                    detected_by_user_id, detected_by_employee_id,
                    decided_by_user_id, decided_by_employee_id, decided_at)
                values (
                    ?, 'PURCHASE', ?, ?, ?, ?, ?, ?, ?, 15.0000,
                    ?, ?, ?, ?,
                    ?, ?, ?, 'RECEIPT_ADJUSTED', ?, ?,
                    ?, ?, ?, ?, now())
                """)) {
            int index = 1;
            exception.setObject(index++, exceptionId);
            exception.setObject(index++, receiptId);
            exception.setObject(index++, receiptItemId);
            exception.setString(index++, receiptNo);
            exception.setObject(index++, orderId);
            exception.setObject(index++, orderItemId);
            exception.setString(index++, orderNo);
            exception.setObject(index++, goodsId);
            exception.setBigDecimal(index++, approvedRemaining);
            exception.setBigDecimal(index++, approvedExcess);
            exception.setBigDecimal(index++, accepted);
            exception.setBigDecimal(index++, new BigDecimal(unacceptedQty));
            exception.setObject(index++, actor.userId());
            exception.setObject(index++, actor.employeeId());
            exception.setString(index++, actor.name());
            exception.setString(index++, decision);
            exception.setString(index++, "db test: receipt-posted transition");
            exception.setObject(index++, actor.userId());
            exception.setObject(index++, actor.employeeId());
            exception.setObject(index++, actor.userId());
            exception.setObject(index, actor.employeeId());
            assertEquals(1, exception.executeUpdate());
        }
        return new ReturnFixture(exceptionId, orderId, orderItemId, receiptId, receiptItemId);
    }

    private static void insertPendingReturnTask(
            Connection connection, ReturnFixture fixture, Identity actor, String qty) throws Exception {
        try (PreparedStatement task = connection.prepareStatement("""
                insert into supplier_return_tasks(
                    id, arrival_exception_id, order_type, order_id, order_item_id,
                    receipt_id, receipt_item_id, owner_user_id, owner_employee_id,
                    qty, status, version)
                values (?, ?, 'PURCHASE', ?, ?, ?, ?, ?, ?, ?, 'PENDING_RETURN', 1)
                """)) {
            task.setObject(1, UUID.randomUUID());
            task.setObject(2, fixture.exceptionId());
            task.setObject(3, fixture.orderId());
            task.setObject(4, fixture.orderItemId());
            task.setObject(5, fixture.receiptId());
            task.setObject(6, fixture.receiptItemId());
            task.setObject(7, actor.userId());
            task.setObject(8, actor.employeeId());
            task.setBigDecimal(9, new BigDecimal(qty));
            assertEquals(1, task.executeUpdate());
        }
    }

    private static boolean pendingReturnExists(Connection connection, UUID exceptionId) throws Exception {
        try (PreparedStatement ps = connection.prepareStatement("""
                SELECT EXISTS(
                    SELECT 1 FROM supplier_return_tasks
                    WHERE arrival_exception_id = ? AND status = 'PENDING_RETURN')
                """)) {
            ps.setObject(1, exceptionId);
            try (ResultSet rs = ps.executeQuery()) {
                assertTrue(rs.next());
                return rs.getBoolean(1);
            }
        }
    }

    private static int applyReceiptPostedTransition(Connection connection, UUID exceptionId) throws Exception {
        try (PreparedStatement ps = connection.prepareStatement("""
                UPDATE procurement_arrival_exceptions exception_row
                SET status = CASE WHEN EXISTS (
                        SELECT 1 FROM supplier_return_tasks return_task
                        WHERE return_task.arrival_exception_id = exception_row.id
                          AND return_task.status = 'PENDING_RETURN'
                    ) THEN 'RECEIPT_POSTED' ELSE 'CLOSED' END,
                    version = version + 1, updated_at = now()
                WHERE id = ? AND status = 'RECEIPT_ADJUSTED'
                """)) {
            ps.setObject(1, exceptionId);
            return ps.executeUpdate();
        }
    }

    private static String statusOf(Connection connection, UUID exceptionId) throws Exception {
        try (PreparedStatement ps = connection.prepareStatement(
                "SELECT status FROM procurement_arrival_exceptions WHERE id = ?")) {
            ps.setObject(1, exceptionId);
            try (ResultSet rs = ps.executeQuery()) {
                assertTrue(rs.next());
                return rs.getString(1);
            }
        }
    }

    private static ArrivalFixture insertArrivalFixture(Connection connection) throws Exception {
        UUID goodsId = UUID.randomUUID();
        UUID orderId = UUID.randomUUID();
        UUID orderItemId = UUID.randomUUID();
        UUID receiptId = UUID.randomUUID();
        UUID receiptItemId = UUID.randomUUID();
        UUID exceptionId = UUID.randomUUID();
        Identity actor = loadIdentity(connection);
        LocalDate billDate = LocalDate.of(2026, 8, 2);

        String orderNo = insertGoodsAndOrder(connection, goodsId, orderId);
        String receiptNo = businessIdentifier("CJ", billDate);
        insertOrderItem(
                connection, orderItemId, orderId, goodsId,
                new BigDecimal("10.0000"), BigDecimal.ZERO);

        try (PreparedStatement receipt = connection.prepareStatement("""
                insert into purchase_receipts(id, bill_no, bill_date, status)
                values (?, ?, ?, 0)
                """)) {
            receipt.setObject(1, receiptId);
            receipt.setString(2, receiptNo);
            receipt.setObject(3, billDate);
            assertEquals(1, receipt.executeUpdate());
        }
        try (PreparedStatement item = connection.prepareStatement("""
                insert into purchase_receipt_items(
                    id, bill_no, bill_date, receipt_id, order_item_id, goods_id, qty,
                    goods_snapshot_source)
                values (?, ?, ?, ?, ?, ?, 15.0000, 'MASTER_AT_SAVE')
                """)) {
            item.setObject(1, receiptItemId);
            item.setString(2, receiptNo);
            item.setObject(3, billDate);
            item.setObject(4, receiptId);
            item.setObject(5, orderItemId);
            item.setObject(6, goodsId);
            assertEquals(1, item.executeUpdate());
        }
        try (PreparedStatement exception = connection.prepareStatement("""
                insert into procurement_arrival_exceptions(
                    id, order_type, receipt_id, receipt_item_id,
                    receipt_bill_no_snapshot, order_id, order_item_id,
                    order_bill_no_snapshot, goods_id, declared_qty,
                    approved_remaining_qty, approved_excess_qty,
                    accepted_qty, unaccepted_qty,
                    finance_assignee_user_id, finance_assignee_employee_id,
                    finance_assignee_name_snapshot,
                    status, decision, finance_reason,
                    detected_by_user_id, detected_by_employee_id,
                    decided_by_user_id, decided_by_employee_id, decided_at)
                values (
                    ?, 'PURCHASE', ?, ?, ?, ?, ?, ?, ?, 15.0000,
                    10.0000, 5.0000, 15.0000, 0.0000,
                    ?, ?, ?, 'RECEIPT_ADJUSTED', 'APPROVE_ALL', ?,
                    ?, ?, ?, ?, now())
                """)) {
            int index = 1;
            exception.setObject(index++, exceptionId);
            exception.setObject(index++, receiptId);
            exception.setObject(index++, receiptItemId);
            exception.setString(index++, receiptNo);
            exception.setObject(index++, orderId);
            exception.setObject(index++, orderItemId);
            exception.setString(index++, orderNo);
            exception.setObject(index++, goodsId);
            exception.setObject(index++, actor.userId());
            exception.setObject(index++, actor.employeeId());
            exception.setString(index++, actor.name());
            exception.setString(index++, "finance approved full overage for database test");
            exception.setObject(index++, actor.userId());
            exception.setObject(index++, actor.employeeId());
            exception.setObject(index++, actor.userId());
            exception.setObject(index, actor.employeeId());
            assertEquals(1, exception.executeUpdate());
        }
        return new ArrivalFixture(orderItemId, receiptId);
    }

    private static String insertGoodsAndOrder(
            Connection connection, UUID goodsId, UUID orderId) throws Exception {
        LocalDate billDate = LocalDate.of(2026, 8, 2);
        String orderNo = businessIdentifier("CD", billDate);
        try (PreparedStatement goods = connection.prepareStatement("""
                insert into goods(id, code, name, min_qty, code_sequence)
                values (?, ?, ?, 0, (select coalesce(max(code_sequence), 0) + 1 from goods))
                """)) {
            goods.setObject(1, goodsId);
            goods.setString(2, "G-ARR-" + goodsId);
            goods.setString(3, "Arrival guard test goods");
            assertEquals(1, goods.executeUpdate());
        }
        try (PreparedStatement order = connection.prepareStatement("""
                insert into purchase_orders(id, bill_no, bill_date, status)
                values (?, ?, ?, 1)
                """)) {
            order.setObject(1, orderId);
            order.setString(2, orderNo);
            order.setObject(3, billDate);
            assertEquals(1, order.executeUpdate());
        }
        return orderNo;
    }

    private static int insertOrderItem(
            Connection connection,
            UUID itemId,
            UUID orderId,
            UUID goodsId,
            BigDecimal qty,
            BigDecimal receivedQty) throws Exception {
        try (PreparedStatement item = connection.prepareStatement("""
                insert into purchase_order_items(
                    id, bill_no, bill_date, order_id, goods_id, qty, received_qty,
                    goods_snapshot_source)
                values (?, ?, ?, ?, ?, ?, ?, 'MASTER_AT_SAVE')
                """)) {
            item.setObject(1, itemId);
            item.setString(2, "POI-ARR-" + itemId);
            item.setObject(3, LocalDate.of(2026, 8, 2));
            item.setObject(4, orderId);
            item.setObject(5, goodsId);
            item.setBigDecimal(6, qty);
            item.setBigDecimal(7, receivedQty);
            return item.executeUpdate();
        }
    }

    private static Identity loadIdentity(Connection connection) throws Exception {
        UUID employeeId = UUID.randomUUID();
        UUID userId = UUID.randomUUID();
        try (PreparedStatement employee = connection.prepareStatement("""
                insert into employees(
                    id, code, full_name, id_type, department_id, hire_date,
                    status, employment_type)
                select ?, ?, ?, '其他', department_id, ?, 'active', 'regular'
                from employees
                where code = 'ADMIN'
                """)) {
            employee.setObject(1, employeeId);
            employee.setString(2, "E-ARR-" + employeeId);
            employee.setString(3, "Arrival finance reviewer");
            employee.setObject(4, LocalDate.of(2026, 8, 2));
            assertEquals(1, employee.executeUpdate());
        }
        try (PreparedStatement user = connection.prepareStatement("""
                insert into users(id, employee_id, login_account, password_hash, status)
                values (?, ?, ?, 'test-only-not-a-real-password', 'active')
                """)) {
            user.setObject(1, userId);
            user.setObject(2, employeeId);
            user.setString(3, "arrival-finance-" + userId);
            assertEquals(1, user.executeUpdate());
        }
        return new Identity(userId, employeeId, "Arrival finance reviewer");
    }
    private static void setReceiptContext(Connection connection, UUID receiptId)
            throws Exception {
        try (PreparedStatement context = connection.prepareStatement("""
                select set_config('app.procurement_arrival_receipt_id', ?, true),
                       set_config('app.procurement_arrival_order_type', 'PURCHASE', true)
                """)) {
            context.setString(1, receiptId.toString());
            try (ResultSet result = context.executeQuery()) {
                assertTrue(result.next());
            }
        }
    }

    private static int updateReceivedQty(
            Connection connection, UUID orderItemId, BigDecimal qty) throws Exception {
        try (PreparedStatement update = connection.prepareStatement("""
                update purchase_order_items set received_qty = ? where id = ?
                """)) {
            update.setBigDecimal(1, qty);
            update.setObject(2, orderItemId);
            return update.executeUpdate();
        }
    }

    private static String businessIdentifier(String prefix, LocalDate date) {
        int sequence = BUSINESS_IDENTIFIER_SEQUENCE.incrementAndGet();
        if (sequence > 999_999) {
            throw new IllegalStateException("test business identifier sequence exhausted");
        }
        return prefix + date.toString().replace("-", "") + "%06d".formatted(sequence);
    }

    private static ProcurementArrivalControlService service() {
        JdbcTemplate jdbc = new JdbcTemplate(new DriverManagerDataSource(
                POSTGRES.getJdbcUrl(), POSTGRES.getUsername(), POSTGRES.getPassword()));
        return new ProcurementArrivalControlService(
                jdbc,
                new ObjectMapper(),
                mock(BusinessEventPublisher.class),
                mock(SecurityContextCurrentUser.class),
                mock(TxSessionVars.class),
                mock(FinanceReviewerEligibilityPort.class),
                mock(ReceiptPriceMasker.class),
                        com.uten.imp.support.FulfillmentMutationLockTestSupport.procurementLocks());
    }

    private static void executeSql(
            Connection connection, String sql, Object... values) throws Exception {
        try (PreparedStatement statement = connection.prepareStatement(sql)) {
            for (int index = 0; index < values.length; index++) {
                statement.setObject(index + 1, values[index]);
            }
            assertEquals(1, statement.executeUpdate());
        }
    }

    private static void setReplica(Connection connection, boolean replica)
            throws SQLException {
        try (Statement statement = connection.createStatement()) {
            statement.execute("SET LOCAL session_replication_role = "
                    + (replica ? "replica" : "origin"));
        }
    }

    private static Connection connection() throws Exception {
        return DriverManager.getConnection(
                POSTGRES.getJdbcUrl(), POSTGRES.getUsername(), POSTGRES.getPassword());
    }

    private record Identity(UUID userId, UUID employeeId, String name) {
    }

    private record ArrivalFixture(UUID orderItemId, UUID receiptId) {
    }

    private record ReturnFixture(
            UUID exceptionId, UUID orderId, UUID orderItemId, UUID receiptId, UUID receiptItemId) {
    }
}
