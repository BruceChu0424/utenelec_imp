package com.uten.imp.migration;

import com.uten.imp.common.finance.ProcurementOrderClosurePolicy;
import com.uten.imp.support.ProcurementReceiptFixtureSupport;
import jakarta.persistence.EntityManager;
import jakarta.persistence.Query;
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
import java.util.List;
import java.util.HashMap;
import java.util.Map;
import java.util.UUID;
import java.util.concurrent.CountDownLatch;
import java.util.concurrent.ExecutorService;
import java.util.concurrent.Executors;
import java.util.concurrent.Future;
import java.util.concurrent.TimeUnit;
import java.util.concurrent.TimeoutException;

import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertThrows;
import static org.junit.jupiter.api.Assertions.assertTrue;
import static org.mockito.ArgumentMatchers.anyString;
import static org.mockito.Mockito.mock;
import static org.mockito.Mockito.when;

@EnabledIfEnvironmentVariable(named = "UTEN_RUN_DB_TESTS", matches = "(?i)true")
class ProcurementCommercialSnapshotGuardPostgresTest {
    private static final java.util.concurrent.atomic.AtomicInteger DOCUMENT_SEQUENCE =
            new java.util.concurrent.atomic.AtomicInteger();
    private static final PostgreSQLContainer<?> POSTGRES =
            new PostgreSQLContainer<>("postgres:16-alpine")
                    .withDatabaseName("uten_imp")
                    .withUsername("uten")
                    .withPassword("uten");

    private static UUID actorUser;
    private static UUID actorEmployee;
    private static UUID supplier;
    private static UUID activeCurrency;
    private static UUID inactiveCurrency;
    private static UUID activeSettlement;
    private static UUID inactiveSettlement;
    private static UUID goods;
    private static UUID warehouse;

    @BeforeAll
    static void migrateAndSeed() throws Exception {
        POSTGRES.start();
        Flyway.configure()
                .dataSource(POSTGRES.getJdbcUrl(), POSTGRES.getUsername(), POSTGRES.getPassword())
                .locations("classpath:db/migration")
                .load().migrate();
        try (Connection connection = connection()) {
            actorEmployee = uuid(connection,
                    "SELECT id FROM employees WHERE code='ADMIN' ORDER BY id LIMIT 1");
            actorUser = UUID.randomUUID();
            try (PreparedStatement insert = connection.prepareStatement("""
                    INSERT INTO users(id,employee_id,login_account,password_hash,status)
                    VALUES(?,?,?,'test-only-hash','active')
                    """)) {
                insert.setObject(1, actorUser);
                insert.setObject(2, actorEmployee);
                insert.setString(3, "v438-" + actorUser);
                insert.executeUpdate();
            }
            supplier = UUID.randomUUID();
            exec(connection, """
                    INSERT INTO suppliers(
                        id,code,name,status,category_id,code_sequence,code_managed)
                    SELECT '%s','V438-S','V438供应商','使用',category.id,
                           (SELECT COALESCE(MAX(code_sequence),0)+1 FROM suppliers),FALSE
                    FROM supplier_categories category
                    ORDER BY category.id LIMIT 1
                    """.formatted(supplier));
            activeCurrency = uuid(connection, """
                    SELECT id FROM currencies
                    WHERE status='使用' AND COALESCE(is_deleted,FALSE)=FALSE
                    ORDER BY id LIMIT 1
                    """);
            inactiveCurrency = UUID.randomUUID();
            exec(connection, "INSERT INTO currencies(id,code,name,exchange_rate,status) VALUES('"
                    + inactiveCurrency + "','V438-CUR-X','停用测试币',1,'禁用')");
            activeSettlement = uuid(connection, """
                    SELECT id FROM settlement_methods
                    WHERE status='使用' AND COALESCE(is_deleted,FALSE)=FALSE
                    ORDER BY id LIMIT 1
                    """);
            inactiveSettlement = UUID.randomUUID();
            exec(connection, "INSERT INTO settlement_methods(id,code,name,status) VALUES('"
                    + inactiveSettlement + "','V438-SET-X','停用测试结算','禁用')");
            goods = UUID.randomUUID();
            exec(connection, """
                    INSERT INTO goods(
                        id,code,name,status,category_id,code_sequence,code_managed)
                    SELECT '%s','V438-G','V438货品','使用',category.id,
                           (SELECT COALESCE(MAX(code_sequence),0)+1 FROM goods),FALSE
                    FROM material_categories category
                    ORDER BY category.id LIMIT 1
                    """.formatted(goods));
            warehouse = UUID.randomUUID();
            exec(connection, "INSERT INTO warehouses(id,code,name,status) VALUES('"
                    + warehouse + "','WH990001','V438锁序仓','使用')");
        }
    }

    @AfterAll
    static void stop() {
        POSTGRES.stop();
    }

    @Test
    void validPurchaseAndSubcontractPendingAndApprovedPass() throws Exception {
        try (Connection connection = connection()) {
            for (String type : List.of("PURCHASE", "SUBCONTRACT")) {
                UUID pendingOrder = order(connection, type, activeCurrency,
                        BigDecimal.ONE, new BigDecimal("13"), activeSettlement);
                UUID pendingItem = orderItem(connection, type, pendingOrder);
                approval(connection, type, pendingOrder, "PENDING", 1);
                assertEquals(1, count(connection, pendingOrder));
                assert23514(() -> updateOrderTax(connection, type, pendingOrder));
                assert23514(() -> updateItemPrice(connection, type, pendingItem));
                assert23514(() -> orderItem(connection, type, pendingOrder));
                assert23514(() -> deleteItem(connection, type, pendingItem));

                UUID approvedOrder = order(connection, type, activeCurrency,
                        BigDecimal.ONE, BigDecimal.ZERO, activeSettlement);
                UUID approvedItem = orderItem(connection, type, approvedOrder);
                approval(connection, type, approvedOrder, "APPROVED", 1);
                assertEquals(1, count(connection, approvedOrder));
                exec(connection, "UPDATE " + orderTable(type)
                        + " SET status=1 WHERE id='" + approvedOrder + "'");
                exec(connection, "UPDATE " + itemTable(type)
                        + " SET received_qty=1 WHERE id='" + approvedItem + "'");
            }
        }
    }

    @Test
    void everyIncompleteCommercialShapeFails23514WithoutCaseWrite() throws Exception {
        try (Connection connection = connection()) {
            for (String type : List.of("PURCHASE", "SUBCONTRACT")) {
                for (Shape shape : List.of(
                        new Shape(null, BigDecimal.ONE, BigDecimal.ZERO, activeSettlement),
                        new Shape(inactiveCurrency, BigDecimal.ONE, BigDecimal.ZERO, activeSettlement),
                        new Shape(activeCurrency, null, BigDecimal.ZERO, activeSettlement),
                        new Shape(activeCurrency, BigDecimal.ZERO, BigDecimal.ZERO, activeSettlement),
                        new Shape(activeCurrency, BigDecimal.ONE, null, activeSettlement),
                        new Shape(activeCurrency, BigDecimal.ONE, new BigDecimal("-0.1"), activeSettlement),
                        new Shape(activeCurrency, BigDecimal.ONE, new BigDecimal("100.1"), activeSettlement),
                        new Shape(activeCurrency, BigDecimal.ONE, BigDecimal.ZERO, null),
                        new Shape(activeCurrency, BigDecimal.ONE, BigDecimal.ZERO, inactiveSettlement))) {
                    UUID order = order(connection, type, activeCurrency, BigDecimal.ONE,
                            BigDecimal.ZERO, activeSettlement);
                    orderItem(connection, type, order);
                    forceCommercialShape(connection, type, order, shape);
                    SQLException failure = assertThrows(
                            SQLException.class,
                            () -> approval(connection, type, order, "PENDING", 1));
                    assertEquals("23514", failure.getSQLState());
                    assertEquals(
                            "procurement_finance_commercial_snapshot_guard",
                            ((org.postgresql.util.PSQLException) failure)
                                    .getServerErrorMessage().getConstraint());
                    assertEquals(0, count(connection, order));
                }
            }
        }
    }

    @Test
    void rejectedHistoricalCaseIsNotBlockedAndTriggerIsAlwaysEnabled() throws Exception {
        try (Connection connection = connection()) {
            UUID order = order(connection, "PURCHASE", null, null, null, null);
            UUID item = orderItem(connection, "PURCHASE", order);
            approval(connection, "PURCHASE", order, "REJECTED", 1);
            assertEquals(1, count(connection, order));
            updateItemPrice(connection, "PURCHASE", item);
            assertTrue(bool(connection, """
                    SELECT trigger.tgenabled='A'
                    FROM pg_trigger trigger
                    JOIN pg_class table_row ON table_row.oid=trigger.tgrelid
                    WHERE table_row.relname='procurement_order_approval_cases'
                      AND trigger.tgname='trg_guard_procurement_finance_commercial_snapshot'
                    """));
        }
    }

    @Test
    void forgedButSelfConsistentHeaderAndCaseCannotHideWrongLineFormula() throws Exception {
        try (Connection connection = connection()) {
            for (String type : List.of("PURCHASE", "SUBCONTRACT")) {
                UUID order = order(connection, type, activeCurrency,
                        BigDecimal.ONE, BigDecimal.ZERO, activeSettlement);
                UUID item = orderItem(connection, type, order);
                exec(connection, "UPDATE " + itemTable(type)
                        + " SET amount_original=1,amount_local=1 WHERE id='" + item + "'");
                exec(connection, "UPDATE " + orderTable(type)
                        + " SET total_original=1,total_local=1 WHERE id='" + order + "'");
                SQLException failure = assertThrows(SQLException.class,
                        () -> approval(connection, type, order, "PENDING", 1, BigDecimal.ONE));
                assertEquals("23514", failure.getSQLState());
                assertEquals("procurement_finance_commercial_snapshot_guard",
                        ((org.postgresql.util.PSQLException) failure)
                                .getServerErrorMessage().getConstraint());
            }
            UUID missingOrder = UUID.randomUUID();
            SQLException missing = assertThrows(SQLException.class,
                    () -> approval(connection, "PURCHASE", missingOrder,
                            "PENDING", 1, BigDecimal.TEN));
            assertEquals("procurement_finance_commercial_snapshot_guard",
                    ((org.postgresql.util.PSQLException) missing)
                            .getServerErrorMessage().getConstraint());
        }
    }

    @Test
    void caseAndCommercialUpdatesSerializeWithoutStaleSnapshotWindow() throws Exception {
        ExecutorService executor = Executors.newFixedThreadPool(2);
        try {
            for (String type : List.of("PURCHASE", "SUBCONTRACT")) {
                UUID caseFirstOrder;
                UUID caseFirstItem;
                try (Connection seed = connection()) {
                    caseFirstOrder = order(seed, type, activeCurrency,
                            BigDecimal.ONE, new BigDecimal("13"), activeSettlement);
                    caseFirstItem = orderItem(seed, type, caseFirstOrder);
                }
                try (Connection caseTx = connection()) {
                    caseTx.setAutoCommit(false);
                    approval(caseTx, type, caseFirstOrder, "PENDING", 1);
                    CountDownLatch started = new CountDownLatch(1);
                    Future<SQLException> update = executor.submit(() -> {
                        started.countDown();
                        try (Connection other = connection()) {
                            updateItemPrice(other, type, caseFirstItem);
                            return null;
                        } catch (SQLException failure) {
                            return failure;
                        }
                    });
                    assertTrue(started.await(2, TimeUnit.SECONDS));
                    assertThrows(TimeoutException.class,
                            () -> update.get(250, TimeUnit.MILLISECONDS));
                    caseTx.commit();
                    SQLException blocked = update.get(5, TimeUnit.SECONDS);
                    assertEquals("23514", blocked.getSQLState());
                }

                UUID updateFirstOrder;
                UUID updateFirstItem;
                try (Connection seed = connection()) {
                    updateFirstOrder = order(seed, type, activeCurrency,
                            BigDecimal.ONE, new BigDecimal("13"), activeSettlement);
                    updateFirstItem = orderItem(seed, type, updateFirstOrder);
                }
                try (Connection updateTx = connection()) {
                    updateTx.setAutoCommit(false);
                    exec(updateTx, "UPDATE " + orderTable(type)
                            + " SET total_original=20,total_local=20 WHERE id='"
                            + updateFirstOrder + "'");
                    updateItemPrice(updateTx, type, updateFirstItem);
                    CountDownLatch started = new CountDownLatch(1);
                    Future<SQLException> submit = executor.submit(() -> {
                        started.countDown();
                        try (Connection other = connection()) {
                            approval(other, type, updateFirstOrder, "PENDING", 1);
                            return null;
                        } catch (SQLException failure) {
                            return failure;
                        }
                    });
                    assertTrue(started.await(2, TimeUnit.SECONDS));
                    assertThrows(TimeoutException.class,
                            () -> submit.get(250, TimeUnit.MILLISECONDS));
                    updateTx.commit();
                    SQLException staleSnapshotRejected = submit.get(5, TimeUnit.SECONDS);
                    assertEquals("23514", staleSnapshotRejected.getSQLState());
                    try (Connection verify = connection()) {
                        assertEquals(0, count(verify, updateFirstOrder));
                    }
                }
            }
        } finally {
            executor.shutdownNow();
        }
    }

    @Test
    void iqcDispositionAndReturnUseInspectionBeforeOrderWithoutDeadlock() throws Exception {
        ExecutorService executor = Executors.newFixedThreadPool(2);
        try {
            for (String type : List.of("PURCHASE", "SUBCONTRACT")) {
                UUID order;
                try (Connection seed = connection()) {
                    order = order(seed, type, activeCurrency, BigDecimal.ONE,
                            BigDecimal.ZERO, activeSettlement);
                    orderItem(seed, type, order);
                }

                UUID iqcFirst = inspection(type);
                try (Connection quality = connection()) {
                    quality.setAutoCommit(false);
                    lockInventoryDimension(quality);
                    lockInspection(quality, iqcFirst);
                    exec(quality, """
                            UPDATE procurement_inspection_items
                            SET failed_base_qty=10,status='RESOLVED'
                            WHERE id='%s'
                            """.formatted(iqcFirst));
                    appendDetectedFailure(quality,type,iqcFirst,BigDecimal.TEN);
                    CountDownLatch started = new CountDownLatch(1);
                    Future<SQLException> returning = executor.submit(() -> {
                        started.countDown();
                        try (Connection other = connection()) {
                            lockInventoryDimension(other);
                            lockInspection(other, iqcFirst);
                            lockOrder(other, type, order);
                            return null;
                        } catch (SQLException failure) {
                            return failure;
                        }
                    });
                    assertTrue(started.await(2, TimeUnit.SECONDS));
                    assertThrows(TimeoutException.class,
                            () -> returning.get(250, TimeUnit.MILLISECONDS));
                    lockOrder(quality, type, order);
                    quality.commit();
                    assertTrue(returning.get(5, TimeUnit.SECONDS) == null);
                }

                UUID returnFirst = inspection(type);
                try (Connection returning = connection()) {
                    returning.setAutoCommit(false);
                    lockInventoryDimension(returning);
                    lockInspection(returning, returnFirst);
                    lockOrder(returning, type, order);
                    CountDownLatch started = new CountDownLatch(1);
                    Future<SQLException> quality = executor.submit(() -> {
                        started.countDown();
                        try (Connection other = connection()) {
                            lockInventoryDimension(other);
                            lockInspection(other, returnFirst);
                            lockOrder(other, type, order);
                            return null;
                        } catch (SQLException failure) {
                            return failure;
                        }
                    });
                    assertTrue(started.await(2, TimeUnit.SECONDS));
                    assertThrows(TimeoutException.class,
                            () -> quality.get(250, TimeUnit.MILLISECONDS));
                    returning.commit();
                    assertTrue(quality.get(5, TimeUnit.SECONDS) == null);
                }
            }
        } finally {
            executor.shutdownNow();
        }
    }

    @Test
    void closureHandlesHistoricalNewMixedFailReturnAndReversalForBothTypes() throws Exception {
        try (Connection connection = connection()) {
            for (String type : List.of("PURCHASE", "SUBCONTRACT")) {
                ClosureSeed historical = closureSeed(connection, type);
                receipt(connection, type, historical.itemId(), new BigDecimal("10"),
                        null, null);
                recalculateClosure(connection, type, historical.itemId());
                assertTrue(closed(connection, type, historical.orderId()));

                ClosureSeed current = closureSeed(connection, type);
                ReceiptSeed currentReceipt = receipt(
                        connection, type, current.itemId(), new BigDecimal("10"),
                        new BigDecimal("10"), BigDecimal.ZERO);
                recalculateClosure(connection, type, current.itemId());
                assertTrue(!closed(connection, type, current.orderId()));
                markWarehouseStocked(connection, currentReceipt.inspectionId(),
                        new BigDecimal("10"));
                recalculateClosure(connection, type, current.itemId());
                assertTrue(closed(connection, type, current.orderId()));

                ClosureSeed mixed = closureSeed(connection, type);
                receipt(connection, type, mixed.itemId(), new BigDecimal("5"),
                        null, null);
                ReceiptSeed mixedCurrentReceipt = receipt(
                        connection, type, mixed.itemId(), new BigDecimal("5"),
                        new BigDecimal("5"), BigDecimal.ZERO);
                recalculateClosure(connection, type, mixed.itemId());
                assertTrue(!closed(connection, type, mixed.orderId()));
                markWarehouseStocked(connection, mixedCurrentReceipt.inspectionId(),
                        new BigDecimal("5"));
                recalculateClosure(connection, type, mixed.itemId());
                assertTrue(closed(connection, type, mixed.orderId()));

                ClosureSeed failed = closureSeed(connection, type);
                ReceiptSeed failedReceipt = receipt(
                        connection, type, failed.itemId(), new BigDecimal("10"),
                        new BigDecimal("5"), new BigDecimal("5"));
                markWarehouseStocked(connection, failedReceipt.inspectionId(),
                        new BigDecimal("5"));
                recalculateClosure(connection, type, failed.itemId());
                assertTrue(!closed(connection, type, failed.orderId()));

                ClosureSeed returned = closureSeed(connection, type);
                ReceiptSeed returnedReceipt = receipt(
                        connection, type, returned.itemId(), new BigDecimal("10"),
                        new BigDecimal("10"), BigDecimal.ZERO);
                markWarehouseStocked(connection, returnedReceipt.inspectionId(),
                        new BigDecimal("10"));
                exec(connection, "UPDATE " + itemTable(type)
                        + " SET returned_qty=2,received_qty=10 WHERE id='" + returned.itemId() + "'");
                recalculateClosure(connection, type, returned.itemId());
                assertTrue(!closed(connection, type, returned.orderId()));

                ClosureSeed reversed = closureSeed(connection, type);
                ReceiptSeed reversedReceipt = receipt(
                        connection, type, reversed.itemId(), new BigDecimal("10"),
                        new BigDecimal("10"), BigDecimal.ZERO);
                markWarehouseStocked(connection, reversedReceipt.inspectionId(),
                        new BigDecimal("10"));
                ProcurementReceiptFixtureSupport.reverseStoredReceipt(connection,type,reversedReceipt.receiptId(),actorUser);
                exec(connection, "UPDATE " + itemTable(type)
                        + " SET received_qty=0 WHERE id='" + reversed.itemId() + "'");
                recalculateClosure(connection, type, reversed.itemId());
                assertTrue(!closed(connection, type, reversed.orderId()));
            }
        }
    }

    @Test
    void iqcCreditLedgerMetadataRemainsPurchaseOrSubcontractCredit()
            throws Exception {
        try(Connection connection=connection()){
            for(String sourceType:List.of(
                    "PURCHASE_IQC_CREDIT","SUBCONTRACT_IQC_CREDIT")){
                UUID ledgerId=UUID.randomUUID();
                UUID sourceId=UUID.randomUUID();
                String billNo="IQCC-"+DOCUMENT_SEQUENCE.incrementAndGet();
                try(PreparedStatement insert=connection.prepareStatement("""
                        INSERT INTO ar_ap_ledger(
                            id,direction,business_type,open_item_kind,
                            source_doc_type,source_doc_id,source_doc_no,
                            bill_no,bill_date,supplier_id,currency_id,exchange_rate,
                            settlement_type_id,amount_original,amount_original_local,
                            amount_received_original,amount_received_local,
                            amount_write_off_original,amount_write_off_local,
                            amount_offset_original,amount_offset_local,
                            amount_balance_original,amount_settled,amount_balance,
                            is_settled,status,is_deleted)
                        VALUES(?,'AP','DIRECT','PAYABLE',?,?,?,?,
                               DATE '2026-08-30',?,?,1,?,-1,-1,
                               0,0,0,0,0,0,-1,0,-1,FALSE,1,FALSE)
                        """)){
                    insert.setObject(1,ledgerId);
                    insert.setString(2,sourceType);
                    insert.setObject(3,sourceId);
                    insert.setString(4,billNo);
                    insert.setString(5,billNo);
                    insert.setObject(6,supplier);
                    insert.setObject(7,activeCurrency);
                    insert.setObject(8,activeSettlement);
                    insert.executeUpdate();
                }
                try(PreparedStatement query=connection.prepareStatement("""
                        SELECT business_type,open_item_kind
                        FROM ar_ap_ledger WHERE id=?
                        """)){
                    query.setObject(1,ledgerId);
                    try(ResultSet result=query.executeQuery()){
                        assertTrue(result.next());
                        assertEquals(sourceType.startsWith("PURCHASE")
                                ?"PURCHASE":"SUBCONTRACT",result.getString(1));
                        assertEquals("CREDIT",result.getString(2));
                    }
                }
            }
        }
    }

    @Test
    void replacementAllocationDbGuardConservesReturnedCaseCapacity()
            throws Exception {
        try(Connection connection=connection()){
            ClosureSeed order=closureSeed(connection,"PURCHASE");
            ReceiptSeed rejected=receipt(
                    connection,"PURCHASE",order.itemId(),BigDecimal.TEN,
                    new BigDecimal("8"),new BigDecimal("2"));
            UUID caseId=UUID.randomUUID();
            UUID fundingId;
            connection.setAutoCommit(false);
            try(PreparedStatement insert=connection.prepareStatement("""
                    INSERT INTO procurement_iqc_rejection_cases(
                        id,receipt_type,receipt_id,receipt_item_id,inspection_item_id,
                        order_item_id,receipt_bill_no,supplier_id,currency_id,
                        exchange_rate,tax_rate,settlement_method_id,goods_id,
                        unit_rate,received_base_qty,received_qty,
                        received_amount_original,received_amount_local,
                        failed_base_qty,failed_qty,failed_amount_original,
                        failed_amount_local,owner_user_id,status,row_version,
                        return_reference,return_date,return_note,
                        return_recorded_by,return_recorded_at,created_by,updated_by)
                    SELECT ?,'PURCHASE',receipt.id,item.id,?,item.order_item_id,
                           receipt.bill_no,receipt.supplier_id,receipt.currency_id,
                           receipt.exchange_rate,receipt.tax_rate,
                           receipt.settlement_method_id,item.goods_id,item.unit_rate,
                           10,10,10,10,2,2,2,2,?,'RETURN_RECORDED',1,
                           'RET-V440',DATE '2026-08-30','PG退回证据',?,now(),?,?
                    FROM purchase_receipts receipt
                    JOIN purchase_receipt_items item ON item.receipt_id=receipt.id
                    WHERE receipt.id=? AND item.id=?
                    """)){
                int i=1;
                insert.setObject(i++,caseId);
                insert.setObject(i++,rejected.inspectionId());
                insert.setObject(i++,actorUser);
                insert.setObject(i++,actorUser);
                insert.setObject(i++,actorUser);
                insert.setObject(i++,actorUser);
                insert.setObject(i++,rejected.receiptId());
                insert.setObject(i,rejected.receiptItemId());
                assertEquals(1,insert.executeUpdate());
            }
            fundingId=ProcurementReceiptFixtureSupport.appendFailureFunding(connection,caseId,actorUser);
            connection.commit();connection.setAutoCommit(true);
            connection.setAutoCommit(false);
            ReceiptSeed replacement=draftPurchaseReceiptItem(connection,order.itemId(),new BigDecimal("2"));
            exec(connection,"UPDATE purchase_receipt_items SET replacement_intent='RETURN_REPLACEMENT' WHERE id='"+replacement.receiptItemId()+"'");
            UUID allocationId=UUID.randomUUID();
            exec(connection,"""
                    INSERT INTO procurement_iqc_replacement_allocations(
                        id,case_id,replacement_receipt_type,replacement_receipt_id,
                        replacement_receipt_item_id,allocated_base_qty,allocated_qty,
                        allocated_amount_original,allocated_amount_local,
                        status,row_version,created_by)
                    VALUES('%s','%s','PURCHASE','%s','%s',2,2,2,2,'ACTIVE',1,'%s')
                    """.formatted(allocationId,caseId,replacement.receiptId(),
                    replacement.receiptItemId(),actorUser));
            exec(connection,"UPDATE purchase_receipts SET status=1 WHERE id='"+replacement.receiptId()+"'");
            ProcurementReceiptFixtureSupport.appendNoChargeReplacement(connection,"PURCHASE",replacement.receiptId(),allocationId,fundingId,actorUser);
            connection.commit();connection.setAutoCommit(true);
            ReceiptSeed excess=draftPurchaseReceiptItem(
                    connection,order.itemId(),BigDecimal.ONE);
            assert23514(()->exec(connection,"""
                    INSERT INTO procurement_iqc_replacement_allocations(
                        id,case_id,replacement_receipt_type,replacement_receipt_id,
                        replacement_receipt_item_id,allocated_base_qty,allocated_qty,
                        allocated_amount_original,allocated_amount_local,
                        status,row_version,created_by)
                    VALUES(gen_random_uuid(),'%s','PURCHASE','%s','%s',
                           1,1,1,1,'ACTIVE',1,'%s')
                    """.formatted(caseId,excess.receiptId(),
                    excess.receiptItemId(),actorUser)));
            assert23514(()->exec(connection,"""
                    UPDATE procurement_iqc_rejection_cases
                    SET status='REVERSED',previous_status='RETURN_RECORDED',
                        reverse_reason='直接SQL绕过',reversed_by='%s',
                        reversed_at=now(),row_version=row_version+1
                    WHERE id='%s'
                    """.formatted(actorUser,caseId)));
            connection.setAutoCommit(false);
            ProcurementReceiptFixtureSupport.appendReceiptReversal(connection,"PURCHASE",replacement.receiptId());
            exec(connection,"""
                    UPDATE procurement_iqc_replacement_allocations
                    SET status='REVERSED',row_version=2,reversed_by='%s',
                        reversed_at=now(),reverse_reason='补货收货红冲'
                    WHERE id='%s'
                    """.formatted(actorUser,allocationId));
            exec(connection,"UPDATE purchase_receipts SET status=-1 WHERE id='"+replacement.receiptId()+"'");
            connection.commit();connection.setAutoCommit(true);
            assertEquals(0,scalar(connection,"""
                    SELECT COUNT(*) FROM procurement_iqc_replacement_allocations
                    WHERE id='%s' AND status='ACTIVE'
                    """.formatted(allocationId)));
        }
    }

    private static ClosureSeed closureSeed(Connection connection, String type)
            throws SQLException {
        UUID orderId = order(connection, type, activeCurrency,
                BigDecimal.ONE, BigDecimal.ZERO, activeSettlement);
        UUID itemId = orderItem(connection, type, orderId);
        exec(connection, "UPDATE " + orderTable(type)
                + " SET status=1 WHERE id='" + orderId + "'");
        return new ClosureSeed(orderId, itemId);
    }

    private static ReceiptSeed receipt(
            Connection connection,
            String type,
            UUID orderItemId,
            BigDecimal qty,
            BigDecimal passed,
            BigDecimal failed) throws SQLException {
        boolean ownTransaction=connection.getAutoCommit();
        if(ownTransaction)connection.setAutoCommit(false);
        try {
            UUID receiptId = UUID.randomUUID();
            UUID receiptItemId = UUID.randomUUID();
            String prefix = "PURCHASE".equals(type) ? "CJ" : "EJ";
            String billNo = "%s20260830%06d".formatted(
                    prefix, DOCUMENT_SEQUENCE.incrementAndGet());
            String extra = "SUBCONTRACT".equals(type) ? ",ap_posted" : "";
            String extraValue = "SUBCONTRACT".equals(type) ? ",TRUE" : "";
            try (PreparedStatement insert = connection.prepareStatement("""
                    INSERT INTO %s(
                        id,bill_no,bill_date,supplier_id,warehouse_id,currency_id,
                        exchange_rate,tax_rate,settlement_method_id,total_original,total_local,status%s)
                    VALUES(?,?,'2026-08-30',?,?,?,?,0,?,?,?,1%s)
                    """.formatted(receiptTable(type), extra, extraValue))) {
                insert.setObject(1, receiptId);
                insert.setString(2, billNo);
                insert.setObject(3, supplier);
                insert.setObject(4, warehouse);
                insert.setObject(5, activeCurrency);
                insert.setBigDecimal(6, BigDecimal.ONE);
                insert.setObject(7, activeSettlement);
                insert.setBigDecimal(8, qty);
                insert.setBigDecimal(9, qty);
                insert.executeUpdate();
            }
            try (PreparedStatement insert = connection.prepareStatement("""
                    INSERT INTO %s(
                        id,bill_no,bill_date,receipt_id,line_no,goods_id,unit_rate,
                        qty,price,amount_original,amount_local,order_item_id,
                        replacement_intent,goods_code_snapshot,goods_name_snapshot,goods_snapshot_source)
                    VALUES(?,?,'2026-08-30',?,1,?,1,?,1,?,?,?,
                        'NORMAL','V438-G','V438货品','MASTER_AT_SAVE')
                    """.formatted(receiptItemTable(type)))) {
                insert.setObject(1, receiptItemId);
                insert.setString(2, billNo);
                insert.setObject(3, receiptId);
                insert.setObject(4, goods);
                insert.setBigDecimal(5, qty);
                insert.setBigDecimal(6, qty);
                insert.setBigDecimal(7, qty);
                insert.setObject(8, orderItemId);
                insert.executeUpdate();
            }
            ProcurementReceiptFixtureSupport.postOriginalReceiptPayable(connection,type,receiptId,actorUser);
            ProcurementReceiptFixtureSupport.appendStandardReceipt(connection,type,receiptId,actorUser);
            exec(connection, "UPDATE " + itemTable(type)
                    + " SET received_qty=COALESCE(received_qty,0)+" + qty.toPlainString()
                    + " WHERE id='" + orderItemId + "'");
            UUID inspectionId = null;
            if (passed != null && failed != null) {
                boolean restoreAutoCommit=connection.getAutoCommit();
                if(restoreAutoCommit)connection.setAutoCommit(false);
                inspectionId = UUID.randomUUID();
                String status = passed.add(failed).compareTo(qty) == 0 ? "RESOLVED" : "PARTIAL";
                try (PreparedStatement insert = connection.prepareStatement("""
                        INSERT INTO procurement_inspection_items(
                            id,receipt_type,receipt_id,receipt_item_id,warehouse_id,goods_id,
                            unit_rate,received_base_qty,received_amount_local,
                            passed_base_qty,failed_base_qty,status)
                        VALUES(?,?,?,?,?,?,1,?,?,?, ?,?)
                        """)) {
                    insert.setObject(1, inspectionId);
                    insert.setString(2, type);
                    insert.setObject(3, receiptId);
                    insert.setObject(4, receiptItemId);
                    insert.setObject(5, warehouse);
                    insert.setObject(6, goods);
                    insert.setBigDecimal(7, qty);
                    insert.setBigDecimal(8, qty);
                    insert.setBigDecimal(9, passed);
                    insert.setBigDecimal(10, failed);
                    insert.setString(11, status);
                    insert.executeUpdate();
                }
                if (passed.signum() > 0) {
                    UUID passEvent = UUID.randomUUID();
                    exec(connection, """
                        INSERT INTO procurement_inspection_events(
                                id,inspection_item_id,action,base_qty,actor_employee_id,
                                requires_warehouse_stock_in,released_amount_local)
                            VALUES('%s','%s','PASS',%s,'%s',TRUE,%s)
                            """.formatted(passEvent, inspectionId,
                            passed.toPlainString(), actorEmployee,
                            passed.toPlainString()));
                }
                if (failed.signum() > 0) {
                    UUID failEvent = UUID.randomUUID();
                    exec(connection, """
                            INSERT INTO procurement_inspection_events(
                                id,inspection_item_id,action,base_qty,reason,actor_employee_id)
                            VALUES('%s','%s','FAIL',%s,'V440 PG fixture','%s')
                            """.formatted(failEvent, inspectionId,
                            failed.toPlainString(), actorEmployee));
                    exec(connection, """
                            INSERT INTO business_outbox(
                                id,event_type,aggregate_type,aggregate_id,payload,
                                dedupe_key,created_by)
                            VALUES(
                                gen_random_uuid(),'PROCUREMENT_IQC_REJECTION_DETECTED',
                                'PROCUREMENT_INSPECTION_ITEM','%s',
                                jsonb_build_object(
                                    'receiptType','%s','receiptId','%s',
                                    'inspectionEventId','%s'),
                                'V440-PG-%s','%s')
                            """.formatted(inspectionId,type,receiptId,failEvent,
                            failEvent,actorUser));
                }
                if(restoreAutoCommit){
                    connection.commit();
                    connection.setAutoCommit(true);
                }
            }
            ProcurementReceiptFixtureSupport.appendExistingQualityConsideration(connection,type,receiptId,actorUser);
            if(ownTransaction)connection.commit();
            return new ReceiptSeed(receiptId, receiptItemId, inspectionId);
        } catch(SQLException|RuntimeException failure) {
            if(ownTransaction)connection.rollback();
            throw failure;
        } finally {
            if(ownTransaction)connection.setAutoCommit(true);
        }
    }

    private static void markWarehouseStocked(
            Connection connection, UUID inspectionId, BigDecimal quantity)
            throws SQLException {
        try(var query=connection.prepareStatement("SELECT passed_base_qty FROM procurement_inspection_items WHERE id=?")) {
            query.setObject(1,inspectionId);
            try(var rows=query.executeQuery()) {
                assertTrue(rows.next());
                assertEquals(0,quantity.compareTo(rows.getBigDecimal(1)));
            }
        }
        ProcurementReceiptFixtureSupport.stockPricedPasses(connection,List.of(inspectionId));
    }

    private static ReceiptSeed draftPurchaseReceiptItem(
            Connection connection,UUID orderItemId,BigDecimal qty)throws SQLException{
        UUID receiptId=UUID.randomUUID();
        UUID itemId=UUID.randomUUID();
        String billNo="CJ20260830%06d".formatted(
                DOCUMENT_SEQUENCE.incrementAndGet());
        try(PreparedStatement insert=connection.prepareStatement("""
                INSERT INTO purchase_receipts(
                    id,bill_no,bill_date,supplier_id,warehouse_id,currency_id,
                    exchange_rate,tax_rate,settlement_method_id,
                    total_original,total_local,status)
                VALUES(?,?,'2026-08-30',?,?,?,?,0,?,?,?,0)
                """)){
            insert.setObject(1,receiptId);
            insert.setString(2,billNo);
            insert.setObject(3,supplier);
            insert.setObject(4,warehouse);
            insert.setObject(5,activeCurrency);
            insert.setBigDecimal(6,BigDecimal.ONE);
            insert.setObject(7,activeSettlement);
            insert.setBigDecimal(8,qty);
            insert.setBigDecimal(9,qty);
            insert.executeUpdate();
        }
        try(PreparedStatement insert=connection.prepareStatement("""
                INSERT INTO purchase_receipt_items(
                    id,bill_no,bill_date,receipt_id,line_no,goods_id,unit_rate,
                    qty,price,amount_original,amount_local,order_item_id,
                    goods_code_snapshot,goods_name_snapshot,goods_snapshot_source)
                VALUES(?,?,'2026-08-30',?,1,?,1,?,1,?,?,?,
                       'V440-G','V440 goods','MASTER_AT_SAVE')
                """)){
            insert.setObject(1,itemId);
            insert.setString(2,billNo);
            insert.setObject(3,receiptId);
            insert.setObject(4,goods);
            insert.setBigDecimal(5,qty);
            insert.setBigDecimal(6,qty);
            insert.setBigDecimal(7,qty);
            insert.setObject(8,orderItemId);
            insert.executeUpdate();
        }
        return new ReceiptSeed(receiptId,itemId,null);
    }

    private static void recalculateClosure(
            Connection connection, String type, UUID orderItemId) {
        EntityManager em = mock(EntityManager.class);
        Query query = mock(Query.class);
        Map<String, Object> params = new HashMap<>();
        final String[] sql = new String[1];
        when(em.createNativeQuery(anyString())).thenAnswer(invocation -> {
            sql[0] = invocation.getArgument(0);
            return query;
        });
        when(query.setParameter(anyString(), org.mockito.ArgumentMatchers.any()))
                .thenAnswer(invocation -> {
                    params.put(invocation.getArgument(0), invocation.getArgument(1));
                    return query;
                });
        when(query.executeUpdate()).thenAnswer(invocation -> {
            String jdbcSql = sql[0]
                    .replace(":receiptType", "?")
                    .replace(":orderItemId", "?");
            try (PreparedStatement update = connection.prepareStatement(jdbcSql)) {
                update.setString(1, params.get("receiptType").toString());
                update.setObject(2, params.get("orderItemId"));
                return update.executeUpdate();
            }
        });
        ProcurementOrderClosurePolicy.recalculate(em, type, orderItemId);
    }

    private static boolean closed(Connection connection, String type, UUID orderId)
            throws SQLException {
        try (PreparedStatement query = connection.prepareStatement(
                "SELECT is_closed FROM " + orderTable(type) + " WHERE id=?")) {
            query.setObject(1, orderId);
            try (ResultSet result = query.executeQuery()) {
                result.next();
                return result.getBoolean(1);
            }
        }
    }

    private static String receiptTable(String type) {
        return "PURCHASE".equals(type)
                ? "purchase_receipts" : "subcontract_receipts";
    }

    private static String receiptItemTable(String type) {
        return "PURCHASE".equals(type)
                ? "purchase_receipt_items" : "subcontract_receipt_items";
    }

    private static UUID inspection(String type) throws SQLException {
        UUID id = UUID.randomUUID();
        try (Connection connection = connection();
             PreparedStatement insert = connection.prepareStatement("""
                     INSERT INTO procurement_inspection_items(
                         id,receipt_type,receipt_id,receipt_item_id,warehouse_id,
                         goods_id,unit_rate,received_base_qty,received_amount_local,status)
                     VALUES(?,?,?,?,?,?,1,10,10,'PENDING')
                     """)) {
            insert.setObject(1, id);
            insert.setString(2, type);
            insert.setObject(3, UUID.randomUUID());
            insert.setObject(4, UUID.randomUUID());
            insert.setObject(5, warehouse);
            insert.setObject(6, goods);
            insert.executeUpdate();
        }
        return id;
    }

    private static void lockInspection(Connection connection, UUID id) throws SQLException {
        try (PreparedStatement lock = connection.prepareStatement("""
                SELECT id FROM procurement_inspection_items
                WHERE id=? ORDER BY id FOR UPDATE
                """)) {
            lock.setObject(1, id);
            lock.executeQuery().close();
        }
    }

    private static void appendDetectedFailure(
            Connection connection,String type,UUID inspectionId,BigDecimal qty)
            throws SQLException{
        UUID eventId=UUID.randomUUID();
        exec(connection,"""
                INSERT INTO procurement_inspection_events(
                    id,inspection_item_id,action,base_qty,reason,actor_employee_id)
                VALUES('%s','%s','FAIL',%s,'V440 lock-order fixture','%s')
                """.formatted(eventId,inspectionId,qty.toPlainString(),actorEmployee));
        exec(connection,"""
                INSERT INTO business_outbox(
                    id,event_type,aggregate_type,aggregate_id,payload,
                    dedupe_key,created_by)
                VALUES(gen_random_uuid(),'PROCUREMENT_IQC_REJECTION_DETECTED',
                       'PROCUREMENT_INSPECTION_ITEM','%s',
                       jsonb_build_object(
                           'receiptType','%s','receiptId','%s',
                           'inspectionEventId','%s'),
                       'V440-LOCK-%s','%s')
                """.formatted(inspectionId,type,UUID.randomUUID(),eventId,eventId,actorUser));
    }

    private static void lockInventoryDimension(Connection connection) throws SQLException {
        try (PreparedStatement lock = connection.prepareStatement(
                "SELECT pg_advisory_xact_lock(438, hashtext(?))")) {
            lock.setString(1, goods.toString());
            lock.executeQuery().close();
        }
    }

    private static void lockOrder(Connection connection, String type, UUID id)
            throws SQLException {
        try (PreparedStatement lock = connection.prepareStatement(
                "SELECT id FROM " + orderTable(type) + " WHERE id=? FOR UPDATE")) {
            lock.setObject(1, id);
            lock.executeQuery().close();
        }
    }

    private static UUID orderItem(Connection connection, String type, UUID orderId)
            throws SQLException {
        UUID id = UUID.randomUUID();
        String billNo;
        try (PreparedStatement query = connection.prepareStatement(
                "SELECT bill_no FROM " + orderTable(type) + " WHERE id=?")) {
            query.setObject(1, orderId);
            try (ResultSet result = query.executeQuery()) {
                result.next();
                billNo = result.getString(1);
            }
        }
        try (PreparedStatement insert = connection.prepareStatement("""
                INSERT INTO %s(
                    id,bill_no,bill_date,order_id,line_no,goods_id,unit_rate,
                    qty,price,amount_original,amount_local,
                    goods_code_snapshot,goods_name_snapshot,goods_snapshot_source)
                VALUES(?,?,'2026-08-30',?,1,?,1,10,1,10,10,
                    'V438-G','V438货品','MASTER_AT_SAVE')
                """.formatted(itemTable(type)))) {
            insert.setObject(1, id);
            insert.setString(2, billNo);
            insert.setObject(3, orderId);
            insert.setObject(4, goods);
            insert.executeUpdate();
        }
        return id;
    }

    private static void updateOrderTax(Connection connection, String type, UUID orderId)
            throws SQLException {
        exec(connection, "UPDATE " + orderTable(type)
                + " SET tax_rate=9 WHERE id='" + orderId + "'");
    }

    private static void forceCommercialShape(
            Connection connection, String type, UUID orderId, Shape shape)
            throws SQLException {
        try (Statement role = connection.createStatement()) {
            role.execute("SET session_replication_role='replica'");
        }
        try (PreparedStatement update = connection.prepareStatement("""
                UPDATE %s
                SET currency_id=?,exchange_rate=?,tax_rate=?,settlement_method_id=?
                WHERE id=?
                """.formatted(orderTable(type)))) {
            update.setObject(1, shape.currency());
            update.setBigDecimal(2, shape.rate());
            update.setBigDecimal(3, shape.tax());
            update.setObject(4, shape.settlement());
            update.setObject(5, orderId);
            update.executeUpdate();
        } finally {
            try (Statement role = connection.createStatement()) {
                role.execute("SET session_replication_role='origin'");
            }
        }
    }

    private static void updateItemPrice(Connection connection, String type, UUID itemId)
            throws SQLException {
        exec(connection, "UPDATE " + itemTable(type)
                + " SET price=2,amount_original=20,amount_local=20 WHERE id='" + itemId + "'");
    }

    private static void deleteItem(Connection connection, String type, UUID itemId)
            throws SQLException {
        exec(connection, "DELETE FROM " + itemTable(type) + " WHERE id='" + itemId + "'");
    }

    private static String orderTable(String type) {
        return "PURCHASE".equals(type) ? "purchase_orders" : "subcontract_orders";
    }

    private static String itemTable(String type) {
        return "PURCHASE".equals(type)
                ? "purchase_order_items" : "subcontract_order_items";
    }

    private static void assert23514(SqlAction action) {
        SQLException failure = assertThrows(SQLException.class, action::run);
        assertEquals("23514", failure.getSQLState());
    }

    private static UUID order(
            Connection connection, String type, UUID currency,
            BigDecimal rate, BigDecimal tax, UUID settlement) throws SQLException {
        UUID id = UUID.randomUUID();
        String table = "PURCHASE".equals(type) ? "purchase_orders" : "subcontract_orders";
        try (PreparedStatement insert = connection.prepareStatement("""
                INSERT INTO %s(
                    id,bill_no,bill_date,supplier_id,currency_id,exchange_rate,
                    tax_rate,settlement_method_id,status,total_original,total_local)
                VALUES(?,?,'2026-08-30',?,?,?,?,?,0,10,10)
                """.formatted(table))) {
            insert.setObject(1, id);
            insert.setString(2, ("%s20260830%06d".formatted(
                    "PURCHASE".equals(type) ? "CD" : "EO",
                    DOCUMENT_SEQUENCE.incrementAndGet())));
            insert.setObject(3, supplier);
            insert.setObject(4, currency);
            insert.setBigDecimal(5, rate);
            insert.setBigDecimal(6, tax);
            insert.setObject(7, settlement);
            insert.executeUpdate();
        }
        return id;
    }

    private static void approval(
            Connection connection, String type, UUID orderId, String status, int attempt)
            throws SQLException {
        approval(connection, type, orderId, status, attempt, BigDecimal.TEN);
    }

    private static void approval(
            Connection connection, String type, UUID orderId, String status, int attempt,
            BigDecimal amount)
            throws SQLException {
        try (PreparedStatement insert = connection.prepareStatement("""
                INSERT INTO procurement_order_approval_cases(
                    id,order_type,order_id,attempt,bill_no_snapshot,amount_snapshot,
                    submission_snapshot,snapshot_hash,submitted_by_user_id,
                    submitted_by_employee_id,status,rejection_reason,
                    decided_by_user_id,decided_by_employee_id,decided_at)
                VALUES(?,?,?,?,?,?,'{}'::jsonb,'hash',?,?,?,
                    CASE WHEN ?='REJECTED' THEN '历史驳回' ELSE NULL END,
                    CASE WHEN ? IN('APPROVED','REJECTED') THEN ? ELSE NULL END,
                    CASE WHEN ? IN('APPROVED','REJECTED') THEN ? ELSE NULL END,
                    CASE WHEN ? IN('APPROVED','REJECTED') THEN now() ELSE NULL END)
                """)) {
            int index = 1;
            insert.setObject(index++, UUID.randomUUID());
            insert.setString(index++, type);
            insert.setObject(index++, orderId);
            insert.setInt(index++, attempt);
            insert.setString(index++, "SNAP-" + orderId);
            insert.setBigDecimal(index++, amount);
            insert.setObject(index++, actorUser);
            insert.setObject(index++, actorEmployee);
            insert.setString(index++, status);
            insert.setString(index++, status);
            insert.setString(index++, status);
            insert.setObject(index++, actorUser);
            insert.setString(index++, status);
            insert.setObject(index++, actorEmployee);
            insert.setString(index, status);
            insert.executeUpdate();
        }
    }

    private static long count(Connection connection, UUID orderId) throws SQLException {
        try (PreparedStatement query = connection.prepareStatement(
                "SELECT COUNT(*) FROM procurement_order_approval_cases WHERE order_id=?")) {
            query.setObject(1, orderId);
            try (ResultSet result = query.executeQuery()) {
                result.next();
                return result.getLong(1);
            }
        }
    }

    private static UUID uuid(Connection connection, String sql) throws SQLException {
        try (Statement statement = connection.createStatement();
             ResultSet result = statement.executeQuery(sql)) {
            assertTrue(result.next());
            return result.getObject(1, UUID.class);
        }
    }

    private static long scalar(Connection connection,String sql)throws SQLException{
        try(Statement statement=connection.createStatement();
            ResultSet result=statement.executeQuery(sql)){
            assertTrue(result.next());
            return result.getLong(1);
        }
    }

    private static boolean bool(Connection connection, String sql) throws SQLException {
        try (Statement statement = connection.createStatement();
             ResultSet result = statement.executeQuery(sql)) {
            assertTrue(result.next());
            return result.getBoolean(1);
        }
    }

    private static void exec(Connection connection, String sql) throws SQLException {
        try (Statement statement = connection.createStatement()) {
            statement.executeUpdate(sql);
        }
    }

    private static Connection connection() throws SQLException {
        return DriverManager.getConnection(
                POSTGRES.getJdbcUrl(), POSTGRES.getUsername(), POSTGRES.getPassword());
    }

    private record Shape(
            UUID currency, BigDecimal rate, BigDecimal tax, UUID settlement) {
    }

    private record ClosureSeed(UUID orderId, UUID itemId) {
    }

    private record ReceiptSeed(UUID receiptId, UUID receiptItemId, UUID inspectionId) {
    }

    @FunctionalInterface
    private interface SqlAction {
        void run() throws SQLException;
    }
}
