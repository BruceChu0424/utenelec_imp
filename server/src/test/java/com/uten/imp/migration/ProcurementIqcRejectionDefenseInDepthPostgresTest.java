package com.uten.imp.migration;

import org.flywaydb.core.Flyway;
import org.flywaydb.core.api.MigrationVersion;
import org.junit.jupiter.api.AfterAll;
import org.junit.jupiter.api.BeforeAll;
import org.junit.jupiter.api.Test;
import org.junit.jupiter.api.condition.EnabledIfEnvironmentVariable;
import org.postgresql.util.PSQLException;
import org.testcontainers.containers.PostgreSQLContainer;

import java.sql.Connection;
import java.sql.DriverManager;
import java.sql.PreparedStatement;
import java.sql.ResultSet;
import java.sql.SQLException;
import java.sql.Statement;
import java.util.List;
import java.util.UUID;

import static org.assertj.core.api.Assertions.assertThat;
import static org.assertj.core.api.Assertions.catchThrowableOfType;
import static org.junit.jupiter.api.Assertions.assertInstanceOf;
import static org.junit.jupiter.api.Assertions.assertNotNull;

@EnabledIfEnvironmentVariable(named = "UTEN_RUN_DB_TESTS", matches = "(?i)true")
class ProcurementIqcRejectionDefenseInDepthPostgresTest {

    private static final PostgreSQLContainer<?> POSTGRES =
            new PostgreSQLContainer<>("postgres:16-alpine")
                    .withDatabaseName("uten_v440_defense")
                    .withUsername("uten")
                    .withPassword("uten-test-only");

    private static UUID supplierId;
    private static UUID currencyId;
    private static UUID settlementMethodId;

    @BeforeAll
    static void migrateAndSeedReferenceData() throws Exception {
        POSTGRES.start();
        Flyway.configure()
                .dataSource(
                        POSTGRES.getJdbcUrl(),
                        POSTGRES.getUsername(),
                        POSTGRES.getPassword())
                .locations("classpath:db/migration")
                .target(MigrationVersion.fromVersion("440"))
                .load()
                .migrate();

        supplierId = UUID.randomUUID();
        currencyId = UUID.randomUUID();
        settlementMethodId = UUID.randomUUID();
        try (Connection connection = connection()) {
            execute(connection, """
                    INSERT INTO suppliers(
                        id,code,name,status,category_id,code_sequence,code_managed)
                    SELECT '%s','V440-DEF-S','V440纵深供应商','使用',category.id,
                           (SELECT COALESCE(MAX(code_sequence),0)+1 FROM suppliers),FALSE
                    FROM supplier_categories category
                    ORDER BY category.id LIMIT 1
                    """.formatted(supplierId));
            execute(connection, """
                    INSERT INTO currencies(id,code,name,exchange_rate,status)
                    VALUES('%s','V440-DEF-C','V440纵深币种',1,'使用')
                    """.formatted(currencyId));
            execute(connection, """
                    INSERT INTO settlement_methods(id,code,name,status)
                    VALUES('%s','V440-DEF-T','V440纵深结算','使用')
                    """.formatted(settlementMethodId));
        }
    }

    @AfterAll
    static void stop() {
        POSTGRES.stop();
    }

    @Test
    void creditMetadataAndSevenPermissionsAreDatabaseDerivedAndZeroGrant()
            throws Exception {
        try (Connection connection = connection()) {
            for (String sourceType : List.of(
                    "PURCHASE_IQC_CREDIT", "SUBCONTRACT_IQC_CREDIT")) {
                UUID ledgerId = UUID.randomUUID();
                String billNo = "V440-" + ledgerId.toString().substring(0, 8);
                try (PreparedStatement insert = connection.prepareStatement("""
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
                        VALUES(?,'AP','DIRECT','PAYABLE',?,?,?, ?,DATE '2026-08-31',
                               ?,?,1,?,-12,-12,0,0,0,0,0,0,-12,0,-12,FALSE,1,FALSE)
                        """)) {
                    insert.setObject(1, ledgerId);
                    insert.setString(2, sourceType);
                    insert.setObject(3, UUID.randomUUID());
                    insert.setString(4, billNo);
                    insert.setString(5, billNo);
                    insert.setObject(6, supplierId);
                    insert.setObject(7, currencyId);
                    insert.setObject(8, settlementMethodId);
                    insert.executeUpdate();
                }
                try (PreparedStatement query = connection.prepareStatement("""
                        SELECT business_type,open_item_kind
                        FROM ar_ap_ledger WHERE id=?
                        """)) {
                    query.setObject(1, ledgerId);
                    try (ResultSet rows = query.executeQuery()) {
                        assertThat(rows.next()).isTrue();
                        assertThat(rows.getString("business_type")).isEqualTo(
                                sourceType.startsWith("PURCHASE")
                                        ? "PURCHASE" : "SUBCONTRACT");
                        assertThat(rows.getString("open_item_kind")).isEqualTo("CREDIT");
                    }
                }
            }

            assertThat(scalar(connection, """
                    SELECT count(*) FROM permissions
                    WHERE code IN(
                        'procurement_iqc_rejection:view',
                        'procurement_iqc_rejection:view_all',
                        'procurement_iqc_rejection:amount:view',
                        'procurement_iqc_rejection:record_return',
                        'procurement_iqc_rejection:confirm_credit',
                        'procurement_iqc_rejection:close_no_credit',
                        'procurement_iqc_rejection:reverse')
                    """)).isEqualTo(7);
            assertThat(scalar(connection, """
                    SELECT count(*)
                    FROM permission_surface_permissions link
                    JOIN permission_surfaces surface ON surface.id=link.surface_id
                    JOIN permissions permission ON permission.id=link.permission_id
                    WHERE surface.surface_key='procurement.iqc-rejection'
                      AND permission.code LIKE 'procurement_iqc_rejection:%'
                    """)).isEqualTo(7);
            assertThat(scalar(connection, """
                    SELECT count(*) FROM (
                        SELECT permission_id FROM department_permissions
                        UNION ALL SELECT permission_id FROM role_permissions
                        UNION ALL SELECT permission_id FROM user_permission_overrides
                        UNION ALL SELECT permission_id FROM manager_permission_delegations
                    ) grants
                    JOIN permissions permission ON permission.id=grants.permission_id
                    WHERE permission.code LIKE 'procurement_iqc_rejection:%'
                    """)).isZero();
        }
    }

    @Test
    void deferredFailureRequiresMatchingFailEventAndDetectedOutbox()
            throws Exception {
        UUID noEventItem = seedPendingInspection();
        assertDeferredDetectionFailure(noEventItem, false, false);

        UUID noOutboxItem = seedPendingInspection();
        assertDeferredDetectionFailure(noOutboxItem, true, false);

        UUID completeItem = seedPendingInspection();
        UUID failEvent = UUID.randomUUID();
        try (Connection connection = connection()) {
            connection.setAutoCommit(false);
            insertFailEvent(connection, completeItem, failEvent);
            insertDetectionOutbox(connection, completeItem, failEvent);
            resolveFailure(connection, completeItem);
            connection.commit();
        }
        try (Connection connection = connection()) {
            assertThat(scalar(connection, """
                    SELECT count(*)
                    FROM procurement_inspection_items inspection
                    JOIN procurement_inspection_events event
                      ON event.inspection_item_id=inspection.id
                     AND event.action='FAIL'
                    JOIN business_outbox detection
                      ON detection.aggregate_id=inspection.id
                     AND detection.event_type='PROCUREMENT_IQC_REJECTION_DETECTED'
                     AND detection.payload->>'inspectionEventId'=event.id::text
                    WHERE inspection.id='%s' AND inspection.failed_base_qty=2
                    """.formatted(completeItem))).isEqualTo(1);
        }
    }

    @Test
    void rejectionEvidenceIsAppendOnlyAndCaseUpdateNeedsCasAndFrozenSnapshot()
            throws Exception {
        UUID caseId = seedCase("PENDING_RETURN", null, null, 20, 20);
        UUID eventId = UUID.randomUUID();
        UUID commandId = UUID.randomUUID();
        withReplica(connection -> {
            execute(connection, """
                    INSERT INTO procurement_iqc_rejection_events(
                        id,case_id,event_type,payload)
                    VALUES('%s','%s','FAIL_DETECTED','{}')
                    """.formatted(eventId, caseId));
            execute(connection, """
                    INSERT INTO procurement_iqc_rejection_commands(
                        id,case_id,command_type,expected_version,actor_user_id,
                        request_hash,result_status,result_version)
                    VALUES('%s','%s','RECORD_RETURN',1,'%s',
                           repeat('a',64),'PENDING_RETURN',1)
                    """.formatted(commandId, caseId, UUID.randomUUID()));
        });

        try (Connection connection = connection()) {
            assertSqlError(connection,
                    "UPDATE procurement_iqc_rejection_events SET payload='{\"x\":1}' WHERE id='"
                            + eventId + "'",
                    "55000", "procurement_iqc_rejection_append_only_guard");
            assertSqlError(connection,
                    "DELETE FROM procurement_iqc_rejection_commands WHERE id='" + commandId + "'",
                    "55000", "procurement_iqc_rejection_append_only_guard");
            assertSqlError(connection,
                    "UPDATE procurement_iqc_rejection_cases SET row_version=1 WHERE id='"
                            + caseId + "'",
                    "40001", "procurement_iqc_rejection_case_cas_guard");
            assertSqlError(connection,
                    "UPDATE procurement_iqc_rejection_cases SET row_version=2,"
                            + "receipt_bill_no='FORGED' WHERE id='" + caseId + "'",
                    "55000", "procurement_iqc_rejection_snapshot_guard");
            assertThat(scalar(connection, """
                    SELECT count(*) FROM procurement_iqc_rejection_events WHERE id='%s'
                    """.formatted(eventId))).isEqualTo(1);
            assertThat(scalar(connection, """
                    SELECT count(*) FROM procurement_iqc_rejection_commands WHERE id='%s'
                    """.formatted(commandId))).isEqualTo(1);
        }
    }

    @Test
    void replacementDirectSqlRejectsWrongIdentityOverCapacityAndActiveCaseReverse()
            throws Exception {
        UUID caseId = seedCase(
                "RETURN_RECORDED", "RET-440", null, 20, 20);
        UUID caseOrderItem = uuidValue(caseId, 1);
        UUID caseGoods = uuidValue(caseId, 2);

        ReceiptItem wrong = seedPurchaseReceiptItem(
                UUID.randomUUID(), caseGoods, 10, 100, 100);
        try (Connection connection = connection()) {
            assertAllocationError(connection, caseId, wrong, 1, 1, 10, 10,
                    "procurement_iqc_replacement_receipt_identity_guard");
        }

        ReceiptItem matching = seedPurchaseReceiptItem(
                caseOrderItem, caseGoods, 10, 100, 100);
        try (Connection connection = connection()) {
            assertAllocationError(connection, caseId, matching, 3, 3, 30, 30,
                    "procurement_iqc_replacement_case_capacity_guard");
            insertAllocation(connection, caseId, matching, 2, 2, 20, 20);
            assertSqlError(connection, """
                    UPDATE procurement_iqc_rejection_cases
                    SET status='REVERSED',row_version=2,
                        previous_status='RETURN_RECORDED',
                        reverse_reason='test reverse',reversed_at=now()
                    WHERE id='%s'
                    """.formatted(caseId),
                    "23514", "procurement_iqc_rejection_active_replacement_guard");
        }
    }

    @Test
    void holdFunctionHonorsNoCreditClosureAndScopedMultiCaseOffsetException()
            throws Exception {
        UUID sourceLedger = UUID.randomUUID();
        UUID receiptId = UUID.randomUUID();
        seedSourcePayable(sourceLedger, receiptId);

        UUID closedInspection = seedResolvedInspection(receiptId);
        seedCaseForHold(
                "CLOSED_NO_CREDIT", closedInspection, sourceLedger, 0, 0);
        UUID openInspection = seedResolvedInspection(receiptId);
        UUID allowedCase = seedCaseForHold(
                "RETURN_RECORDED", openInspection, sourceLedger, 20, 20);
        seedCreditLedger(allowedCase);

        try (Connection connection = connection()) {
            assertThat(holdReason(connection, sourceLedger, null))
                    .contains("供应商贷项尚未闭环");
            assertThat(holdReason(connection, sourceLedger, UUID.randomUUID()))
                    .contains("供应商贷项尚未闭环");
            assertThat(holdReason(connection, sourceLedger, allowedCase)).isNull();
        }

        UUID closedLedger = UUID.randomUUID();
        UUID closedReceipt = UUID.randomUUID();
        seedSourcePayable(closedLedger, closedReceipt);
        seedCaseForHold(
                "CLOSED_NO_CREDIT", seedResolvedInspection(closedReceipt),
                closedLedger, 0, 0);
        seedCaseForHold(
                "CLOSED_NO_CREDIT", seedResolvedInspection(closedReceipt),
                closedLedger, 0, 0);
        try (Connection connection = connection()) {
            assertThat(holdReason(connection, closedLedger, null)).isNull();
        }
    }

    private static void assertDeferredDetectionFailure(
            UUID inspectionItemId,
            boolean includeEvent,
            boolean includeOutbox) throws Exception {
        try (Connection connection = connection()) {
            connection.setAutoCommit(false);
            UUID eventId = UUID.randomUUID();
            if (includeEvent) {
                insertFailEvent(connection, inspectionItemId, eventId);
            }
            if (includeOutbox) {
                insertDetectionOutbox(connection, inspectionItemId, eventId);
            }
            resolveFailure(connection, inspectionItemId);
            SQLException failure = catchThrowableOfType(connection::commit, SQLException.class);
            assertNotNull(failure);
            assertThat(failure.getSQLState()).isEqualTo("23514");
            assertThat(((PSQLException) failure).getServerErrorMessage().getConstraint())
                    .isEqualTo("procurement_iqc_failure_detection_guard");
            connection.rollback();
        }
    }

    private static UUID seedPendingInspection() throws Exception {
        UUID inspectionId = UUID.randomUUID();
        withReplica(connection -> execute(connection, """
                INSERT INTO procurement_inspection_items(
                    id,receipt_type,receipt_id,receipt_item_id,warehouse_id,
                    goods_id,unit_rate,received_base_qty,received_amount_local,
                    passed_base_qty,failed_base_qty,status)
                VALUES('%s','PURCHASE','%s','%s','%s','%s',1,10,100,0,0,'PENDING')
                """.formatted(
                inspectionId, UUID.randomUUID(), UUID.randomUUID(),
                UUID.randomUUID(), UUID.randomUUID())));
        return inspectionId;
    }

    private static void insertFailEvent(
            Connection connection, UUID inspectionItemId, UUID eventId)
            throws SQLException {
        execute(connection, """
                INSERT INTO procurement_inspection_events(
                    id,inspection_item_id,action,base_qty,reason)
                VALUES('%s','%s','FAIL',2,'V440 defense probe')
                """.formatted(eventId, inspectionItemId));
    }

    private static void insertDetectionOutbox(
            Connection connection, UUID inspectionItemId, UUID eventId)
            throws SQLException {
        execute(connection, """
                INSERT INTO business_outbox(
                    id,event_type,aggregate_type,aggregate_id,payload,dedupe_key)
                VALUES('%s','PROCUREMENT_IQC_REJECTION_DETECTED',
                       'PROCUREMENT_INSPECTION_ITEM','%s',
                       jsonb_build_object('inspectionEventId','%s'),'%s')
                """.formatted(
                UUID.randomUUID(), inspectionItemId, eventId,
                "v440-detected-" + eventId));
    }

    private static void resolveFailure(Connection connection, UUID inspectionItemId)
            throws SQLException {
        execute(connection, """
                UPDATE procurement_inspection_items
                SET failed_base_qty=2,status='PARTIAL',updated_at=now()
                WHERE id='%s'
                """.formatted(inspectionItemId));
    }

    private static UUID seedCase(
            String status,
            String returnReference,
            UUID sourceLedgerId,
            int failedAmountOriginal,
            int failedAmountLocal) throws Exception {
        UUID caseId = UUID.randomUUID();
        UUID inspectionId = UUID.randomUUID();
        UUID orderItemId = uuidValue(caseId, 1);
        UUID goodsId = uuidValue(caseId, 2);
        String returnedShape = returnReference == null ?
                "NULL,NULL,NULL,NULL,NULL" :
                "'" + returnReference + "',DATE '2026-08-31','physical return',"
                        + "'" + UUID.randomUUID() + "',now()";
        String closeShape = status.equals("CLOSED_NO_CREDIT")
                ? ",'zero-price rejection','" + UUID.randomUUID() + "',now()"
                : ",NULL,NULL,NULL";
        withReplica(connection -> execute(connection, """
                INSERT INTO procurement_iqc_rejection_cases(
                    id,receipt_type,receipt_id,receipt_item_id,inspection_item_id,
                    order_item_id,source_ap_ledger_id,receipt_bill_no,order_bill_no,
                    supplier_id,currency_id,exchange_rate,tax_rate,
                    settlement_method_id,goods_id,unit_rate,
                    received_base_qty,received_qty,
                    received_amount_original,received_amount_local,
                    failed_base_qty,failed_qty,
                    failed_amount_original,failed_amount_local,status,row_version,
                    return_reference,return_date,return_note,
                    return_recorded_by,return_recorded_at,
                    closed_no_credit_reason,closed_no_credit_by,closed_no_credit_at)
                VALUES('%s','PURCHASE','%s','%s','%s','%s',%s,
                       'RC-%s','PO-%s','%s','%s',1,13,'%s','%s',1,
                       10,10,100,100,2,2,%s,%s,'%s',1,
                       %s%s)
                """.formatted(
                caseId, UUID.randomUUID(), UUID.randomUUID(), inspectionId,
                orderItemId, nullableUuid(sourceLedgerId),
                caseId.toString().substring(0, 8), caseId.toString().substring(0, 8),
                supplierId, currencyId, settlementMethodId, goodsId,
                failedAmountOriginal, failedAmountLocal, status,
                returnedShape, closeShape)));
        return caseId;
    }

    private static ReceiptItem seedPurchaseReceiptItem(
            UUID orderItemId,
            UUID goodsId,
            int qty,
            int amountOriginal,
            int amountLocal) throws Exception {
        ReceiptItem item = new ReceiptItem(UUID.randomUUID(), UUID.randomUUID());
        withReplica(connection -> {
            execute(connection, """
                    INSERT INTO purchase_receipts(
                        id,bill_no,bill_date,status,is_deleted)
                    VALUES('%s','RP-%s',DATE '2026-08-31',1,FALSE)
                    """.formatted(
                    item.receiptId(), item.receiptId().toString().substring(0, 8)));
            execute(connection, """
                    INSERT INTO purchase_receipt_items(
                        id,bill_no,bill_date,receipt_id,order_item_id,goods_id,
                        unit_rate,qty,amount_original,amount_local,is_deleted,
                        goods_code_snapshot,goods_name_snapshot,
                        goods_snapshot_source)
                    VALUES('%s','RP-%s',DATE '2026-08-31','%s','%s','%s',
                           1,%s,%s,%s,FALSE,'V440-G','V440 goods','MASTER_AT_SAVE')
                    """.formatted(
                    item.itemId(), item.receiptId().toString().substring(0, 8),
                    item.receiptId(), orderItemId, goodsId,
                    qty, amountOriginal, amountLocal));
        });
        return item;
    }

    private static void assertAllocationError(
            Connection connection,
            UUID caseId,
            ReceiptItem item,
            int qty,
            int baseQty,
            int amountOriginal,
            int amountLocal,
            String constraint) throws SQLException {
        SQLException failure = catchThrowableOfType(
                () -> insertAllocation(
                        connection, caseId, item, qty, baseQty,
                        amountOriginal, amountLocal),
                SQLException.class);
        assertDatabaseError(failure, "23514", constraint);
    }

    private static void insertAllocation(
            Connection connection,
            UUID caseId,
            ReceiptItem item,
            int qty,
            int baseQty,
            int amountOriginal,
            int amountLocal) throws SQLException {
        execute(connection, """
                INSERT INTO procurement_iqc_replacement_allocations(
                    id,case_id,replacement_receipt_type,replacement_receipt_id,
                    replacement_receipt_item_id,allocated_base_qty,allocated_qty,
                    allocated_amount_original,allocated_amount_local,status)
                VALUES('%s','%s','PURCHASE','%s','%s',%s,%s,%s,%s,'ACTIVE')
                """.formatted(
                UUID.randomUUID(), caseId, item.receiptId(), item.itemId(),
                baseQty, qty, amountOriginal, amountLocal));
    }

    private static void seedSourcePayable(UUID ledgerId, UUID receiptId)
            throws Exception {
        withReplica(connection -> execute(connection, ledgerInsertSql(
                ledgerId, "PURCHASE_RECEIPT", receiptId,
                "PURCHASE", "PAYABLE", 100, 100)));
    }

    private static UUID seedResolvedInspection(UUID receiptId) throws Exception {
        UUID inspectionId = UUID.randomUUID();
        withReplica(connection -> execute(connection, """
                INSERT INTO procurement_inspection_items(
                    id,receipt_type,receipt_id,receipt_item_id,warehouse_id,
                    goods_id,unit_rate,received_base_qty,received_amount_local,
                    passed_base_qty,failed_base_qty,status)
                VALUES('%s','PURCHASE','%s','%s','%s','%s',1,2,20,0,2,'RESOLVED')
                """.formatted(
                inspectionId, receiptId, UUID.randomUUID(),
                UUID.randomUUID(), UUID.randomUUID())));
        return inspectionId;
    }

    private static UUID seedCaseForHold(
            String status,
            UUID inspectionId,
            UUID sourceLedger,
            int failedAmountOriginal,
            int failedAmountLocal) throws Exception {
        UUID caseId = UUID.randomUUID();
        String closeShape = status.equals("CLOSED_NO_CREDIT")
                ? ",'zero-price rejection','" + UUID.randomUUID() + "',now()"
                : ",NULL,NULL,NULL";
        withReplica(connection -> execute(connection, """
                INSERT INTO procurement_iqc_rejection_cases(
                    id,receipt_type,receipt_id,receipt_item_id,inspection_item_id,
                    order_item_id,source_ap_ledger_id,receipt_bill_no,
                    supplier_id,currency_id,exchange_rate,tax_rate,
                    settlement_method_id,goods_id,unit_rate,
                    received_base_qty,received_qty,
                    received_amount_original,received_amount_local,
                    failed_base_qty,failed_qty,
                    failed_amount_original,failed_amount_local,status,row_version,
                    return_reference,return_date,return_note,
                    return_recorded_by,return_recorded_at,
                    closed_no_credit_reason,closed_no_credit_by,closed_no_credit_at)
                SELECT '%s','PURCHASE',inspection.receipt_id,inspection.receipt_item_id,
                       inspection.id,'%s','%s','RH-%s',
                       '%s','%s',1,13,'%s',inspection.goods_id,1,
                       2,2,%s,%s,2,2,%s,%s,'%s',1,
                       'RET-%s',DATE '2026-08-31','physical return','%s',now()%s
                FROM procurement_inspection_items inspection
                WHERE inspection.id='%s'
                """.formatted(
                caseId, UUID.randomUUID(), sourceLedger,
                caseId.toString().substring(0, 8), supplierId, currencyId,
                settlementMethodId, failedAmountOriginal, failedAmountLocal,
                failedAmountOriginal,failedAmountLocal,
                status, caseId.toString().substring(0, 8), UUID.randomUUID(),
                closeShape, inspectionId)));
        return caseId;
    }

    private static void seedCreditLedger(UUID caseId) throws Exception {
        withReplica(connection -> execute(connection, ledgerInsertSql(
                UUID.randomUUID(), "PURCHASE_IQC_CREDIT", caseId,
                "PURCHASE", "CREDIT", -20, -20)));
    }

    private static String ledgerInsertSql(
            UUID ledgerId,
            String sourceType,
            UUID sourceId,
            String businessType,
            String openItemKind,
            int original,
            int local) {
        String billNo = "HL-" + ledgerId.toString().substring(0, 8);
        return """
                INSERT INTO ar_ap_ledger(
                    id,direction,business_type,open_item_kind,
                    source_doc_type,source_doc_id,source_doc_no,bill_no,bill_date,
                    supplier_id,currency_id,exchange_rate,settlement_type_id,
                    amount_original,amount_original_local,
                    amount_received_original,amount_received_local,
                    amount_write_off_original,amount_write_off_local,
                    amount_offset_original,amount_offset_local,
                    amount_balance_original,amount_settled,amount_balance,
                    is_settled,status,is_deleted)
                VALUES('%s','AP','%s','%s','%s','%s','%s','%s',DATE '2026-08-31',
                       '%s','%s',1,'%s',%s,%s,0,0,0,0,0,0,%s,0,%s,FALSE,1,FALSE)
                """.formatted(
                ledgerId, businessType, openItemKind, sourceType, sourceId,
                billNo, billNo, supplierId, currencyId, settlementMethodId,
                original, local, original, local);
    }

    private static String holdReason(
            Connection connection, UUID ledgerId, UUID allowedCaseId)
            throws SQLException {
        String allowed = allowedCaseId == null ? "NULL" : "'" + allowedCaseId + "'";
        try (Statement statement = connection.createStatement();
             ResultSet rows = statement.executeQuery("""
                     SELECT fn_procurement_iqc_ap_hold_reason('%s',%s)
                     """.formatted(ledgerId, allowed))) {
            assertThat(rows.next()).isTrue();
            return rows.getString(1);
        }
    }

    private static void assertSqlError(
            Connection connection,
            String sql,
            String sqlState,
            String constraint) {
        SQLException failure = catchThrowableOfType(
                () -> execute(connection, sql), SQLException.class);
        assertDatabaseError(failure, sqlState, constraint);
    }

    private static void assertDatabaseError(
            SQLException failure, String sqlState, String constraint) {
        assertNotNull(failure);
        assertThat(failure.getSQLState()).isEqualTo(sqlState);
        assertInstanceOf(PSQLException.class, failure);
        assertThat(((PSQLException) failure).getServerErrorMessage().getConstraint())
                .isEqualTo(constraint);
    }

    private static long scalar(Connection connection, String sql) throws SQLException {
        try (Statement statement = connection.createStatement();
             ResultSet rows = statement.executeQuery(sql)) {
            assertThat(rows.next()).isTrue();
            return rows.getLong(1);
        }
    }

    private static void withReplica(SqlWork work) throws Exception {
        try (Connection connection = connection();
             Statement statement = connection.createStatement()) {
            statement.execute("SET session_replication_role=replica");
            try {
                work.run(connection);
            } finally {
                statement.execute("SET session_replication_role=origin");
            }
        }
    }

    private static void execute(Connection connection, String sql) throws SQLException {
        try (Statement statement = connection.createStatement()) {
            statement.execute(sql);
        }
    }

    private static Connection connection() throws SQLException {
        return DriverManager.getConnection(
                POSTGRES.getJdbcUrl(),
                POSTGRES.getUsername(),
                POSTGRES.getPassword());
    }

    private static UUID uuidValue(UUID source, int discriminator) {
        String value = source.toString();
        String suffix = String.format("%012d", discriminator);
        return UUID.fromString(value.substring(0, 24) + suffix);
    }

    private static String nullableUuid(UUID value) {
        return value == null ? "NULL" : "'" + value + "'";
    }

    private record ReceiptItem(UUID receiptId, UUID itemId) {
    }

    @FunctionalInterface
    private interface SqlWork {
        void run(Connection connection) throws Exception;
    }
}
