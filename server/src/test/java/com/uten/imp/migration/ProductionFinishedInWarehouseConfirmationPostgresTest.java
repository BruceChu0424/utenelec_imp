package com.uten.imp.migration;

import org.flywaydb.core.Flyway;
import org.junit.jupiter.api.AfterAll;
import org.junit.jupiter.api.BeforeAll;
import org.junit.jupiter.api.Test;
import org.junit.jupiter.api.condition.EnabledIfEnvironmentVariable;
import org.postgresql.util.PSQLException;
import org.testcontainers.containers.PostgreSQLContainer;

import java.math.BigDecimal;
import java.sql.Connection;
import java.sql.DriverManager;
import java.sql.PreparedStatement;
import java.sql.ResultSet;
import java.sql.Statement;
import java.time.LocalDate;
import java.nio.file.Files;
import java.nio.file.Path;
import java.nio.file.StandardCopyOption;
import java.util.UUID;

import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertThrows;
import static org.junit.jupiter.api.Assertions.assertTrue;

@EnabledIfEnvironmentVariable(named = "UTEN_RUN_DB_TESTS", matches = "(?i)true")
class ProductionFinishedInWarehouseConfirmationPostgresTest {

    private static final java.util.concurrent.atomic.AtomicInteger
            BUSINESS_IDENTIFIER_SEQUENCE =
            new java.util.concurrent.atomic.AtomicInteger();

    private static final PostgreSQLContainer<?> POSTGRES =
            new PostgreSQLContainer<>("postgres:16-alpine")
                    .withDatabaseName("uten_imp_finished_in_confirm")
                    .withUsername("uten")
                    .withPassword("uten-test-only");

    private static Fixture legacy;

    @BeforeAll
    static void migrateWithHistoricalApprovedReceipt() throws Exception {
        POSTGRES.start();
        flyway("329").migrate();
        try (Connection connection = connection()) {
            legacy = createLegacyFixture(
                    connection, new BigDecimal("3.0000"));
        }
        migrateOnlyV338();
    }

    @AfterAll
    static void stopPostgres() {
        POSTGRES.stop();
    }

    @Test
    void migrationBackfillsHistoricalApprovedReceiptAndReportedQuantity()
            throws Exception {
        try (Connection connection = connection()) {
            assertEquals("LEGACY_APPROVED", scalarString(connection, """
                    SELECT decision
                    FROM production_finished_in_confirmations
                    WHERE stock_document_id = ?
                    """, legacy.documentId()));
            assertDecimal(connection, """
                    SELECT reported_qty
                    FROM stock_document_items
                    WHERE id = ?
                    """, legacy.itemId(), "3.0000");
            assertDecimal(connection, """
                    SELECT accepted_qty
                    FROM production_finished_in_confirmation_items
                    WHERE stock_document_item_id = ?
                    """, legacy.itemId(), "3.0000");
        }
    }

    @Test
    void productionLinkedQuantityCanShrinkOnlyInsideTheNarrowGucLane()
            throws Exception {
        Fixture fixture;
        try (Connection connection = connection()) {
            fixture = createFixture(
                    connection, (short) 0, new BigDecimal("10.0000"), false);
            PSQLException blocked = assertThrows(
                    PSQLException.class,
                    () -> execute(connection, """
                            UPDATE stock_document_items
                            SET qty = 6, base_qty = 6, reported_qty = 10
                            WHERE id = ?
                            """, fixture.itemId()));
            assertEquals(
                    "production_linked_stock_document_item_update_guard",
                    blocked.getServerErrorMessage().getConstraint());
        }

        try (Connection connection = connection()) {
            connection.setAutoCommit(false);
            try (Statement statement = connection.createStatement()) {
                statement.execute("""
                        SELECT set_config(
                            'app.production_finished_in_confirm_doc_id',
                            '%s', true)
                        """.formatted(fixture.documentId()));
            }
            execute(connection, """
                    UPDATE stock_document_items
                    SET qty = 6, base_qty = 6, reported_qty = 10
                    WHERE id = ?
                    """, fixture.itemId());
            connection.commit();
        }
        try (Connection connection = connection()) {
            assertDecimal(connection, """
                    SELECT qty FROM stock_document_items WHERE id = ?
                    """, fixture.itemId(), "6.0000");
            assertDecimal(connection, """
                    SELECT reported_qty FROM stock_document_items WHERE id = ?
                    """, fixture.itemId(), "10.0000");
        }
    }

    @Test
    void partialConfirmationCommitsAcceptedAndResidualSlicesAndIsAppendOnly()
            throws Exception {
        Fixture source;
        Fixture residual;
        try (Connection connection = connection()) {
            ReportSource report = createReportSource(
                    connection, new BigDecimal("10.0000"));
            source = createFixture(
                    connection, (short) 1, new BigDecimal("6.0000"),
                    true, report, new BigDecimal("10.0000"));
            residual = createResidualFixture(
                    connection, source, report, new BigDecimal("4.0000"));
        }

        UUID confirmationId = UUID.randomUUID();
        try (Connection connection = connection()) {
            connection.setAutoCommit(false);
            execute(connection, """
                    INSERT INTO production_finished_in_confirmations(
                        id, stock_document_id, residual_stock_document_id,
                        decision, variance_reason, idempotency_key,
                        request_hash)
                    VALUES (?, ?, ?, 'PARTIAL', '分批实收', ?, ?)
                    """, confirmationId, source.documentId(), residual.documentId(),
                    "partial-confirm-" + confirmationId,
                    "a".repeat(64));
            execute(connection, """
                    INSERT INTO production_finished_in_confirmation_items(
                        confirmation_id, stock_document_item_id,
                        residual_stock_document_item_id,
                        reported_qty, accepted_qty, residual_qty)
                    VALUES (?, ?, ?, 10, 6, 4)
                    """, confirmationId, source.itemId(), residual.itemId());
            connection.commit();
        }

        try (Connection connection = connection()) {
            assertEquals("PARTIAL", scalarString(connection, """
                    SELECT decision
                    FROM production_finished_in_confirmations
                    WHERE id = ?
                    """, confirmationId));
            assertDecimal(connection, """
                    SELECT accepted_qty + residual_qty
                    FROM production_finished_in_confirmation_items
                    WHERE confirmation_id = ?
                    """, confirmationId, "10.0000");
            PSQLException appendOnly = assertThrows(
                    PSQLException.class,
                    () -> execute(connection, """
                            UPDATE production_finished_in_confirmations
                            SET variance_reason = '改写'
                            WHERE id = ?
                            """, confirmationId));
            assertEquals("55000", appendOnly.getSQLState());
        }
    }

    @Test
    void invalidAcceptedResidualConservationFailsInIsolatedPostgres()
            throws Exception {
        Fixture source;
        try (Connection connection = connection()) {
            source = createFixture(
                    connection, (short) 1, new BigDecimal("10.0000"), false);
        }
        try (Connection connection = connection()) {
            connection.setAutoCommit(false);
            UUID confirmationId = UUID.randomUUID();
            execute(connection, """
                    INSERT INTO production_finished_in_confirmations(
                        id, stock_document_id, decision,
                        idempotency_key, request_hash)
                    VALUES (?, ?, 'ACCEPTED', ?, ?)
                    """, confirmationId, source.documentId(),
                    "invalid-confirm-" + confirmationId,
                    "b".repeat(64));
            PSQLException invalid = assertThrows(
                    PSQLException.class,
                    () -> execute(connection, """
                            INSERT INTO production_finished_in_confirmation_items(
                                confirmation_id, stock_document_item_id,
                                reported_qty, accepted_qty, residual_qty)
                            VALUES (?, ?, 10, 7, 4)
                            """, confirmationId, source.itemId()));
            assertEquals("23514", invalid.getSQLState());
            connection.rollback();
        }
    }

    @Test
    void mixedZeroAndPositiveAcceptanceSoftDeletesOnlyTheZeroLine()
            throws Exception {
        ReportSource report;
        Fixture source;
        UUID zeroAcceptedItemId;
        try (Connection connection = connection()) {
            report = createReportSource(
                    connection, new BigDecimal("20.0000"));
            source = createFixture(
                    connection, (short) 0, new BigDecimal("10.0000"),
                    true, report, new BigDecimal("10.0000"));
            zeroAcceptedItemId = createAdditionalSourceItem(
                    connection, source, report, 2,
                    new BigDecimal("10.0000"));
        }

        UUID confirmationId = UUID.randomUUID();
        Fixture residual;
        UUID zeroResidualItemId;
        try (Connection connection = connection()) {
            connection.setAutoCommit(false);
            setConfirmDocumentLane(connection, source.documentId());
            execute(connection, """
                    UPDATE stock_document_items
                    SET qty = 6, base_qty = 6, reported_qty = 10
                    WHERE id = ?
                    """, source.itemId());
            execute(connection, """
                    UPDATE stock_document_items
                    SET is_deleted = TRUE, deleted_at = now()
                    WHERE id = ?
                    """, zeroAcceptedItemId);
            residual = createResidualFixture(
                    connection, source, report, new BigDecimal("4.0000"));
            zeroResidualItemId = createAdditionalSourceItem(
                    connection, residual, report, 2,
                    new BigDecimal("10.0000"));
            execute(connection, """
                    UPDATE stock_documents SET status = 1 WHERE id = ?
                    """, source.documentId());
            execute(connection, """
                    INSERT INTO production_finished_in_confirmations(
                        id, stock_document_id, residual_stock_document_id,
                        decision, variance_reason, idempotency_key,
                        request_hash)
                    VALUES (?, ?, ?, 'PARTIAL', '逐行仓库点收差异', ?, ?)
                    """, confirmationId, source.documentId(),
                    residual.documentId(),
                    "mixed-confirm-" + confirmationId,
                    "c".repeat(64));
            execute(connection, """
                    INSERT INTO production_finished_in_confirmation_items(
                        confirmation_id, stock_document_item_id,
                        residual_stock_document_item_id,
                        reported_qty, accepted_qty, residual_qty)
                    VALUES (?, ?, ?, 10, 6, 4)
                    """, confirmationId, source.itemId(), residual.itemId());
            execute(connection, """
                    INSERT INTO production_finished_in_confirmation_items(
                        confirmation_id, stock_document_item_id,
                        residual_stock_document_item_id,
                        reported_qty, accepted_qty, residual_qty)
                    VALUES (?, ?, ?, 10, 0, 10)
                    """, confirmationId, zeroAcceptedItemId,
                    zeroResidualItemId);
            connection.commit();
        }

        try (Connection connection = connection()) {
            assertTrue(scalarBoolean(connection, """
                    SELECT is_deleted
                    FROM stock_document_items
                    WHERE id = ?
                    """, zeroAcceptedItemId));
            assertEquals(false, scalarBoolean(connection, """
                    SELECT is_deleted
                    FROM stock_document_items
                    WHERE id = ?
                    """, source.itemId()));
            assertDecimal(connection, """
                    SELECT qty FROM stock_document_items WHERE id = ?
                    """, source.itemId(), "6.0000");
            assertDecimal(connection, """
                    SELECT accepted_qty
                    FROM production_finished_in_confirmation_items
                    WHERE confirmation_id = ?
                      AND stock_document_item_id = '%s'::uuid
                    """.formatted(zeroAcceptedItemId),
                    confirmationId, "0.0000");
            assertDecimal(connection, """
                    SELECT residual_qty
                    FROM production_finished_in_confirmation_items
                    WHERE confirmation_id = ?
                      AND stock_document_item_id = '%s'::uuid
                    """.formatted(zeroAcceptedItemId),
                    confirmationId, "10.0000");
            assertDecimal(connection, """
                    SELECT accepted_qty
                    FROM production_finished_in_confirmation_items
                    WHERE confirmation_id = ?
                      AND stock_document_item_id = '%s'::uuid
                    """.formatted(source.itemId()),
                    confirmationId, "6.0000");
            assertDecimal(connection, """
                    SELECT qty
                    FROM stock_document_items
                    WHERE id = ?
                    """, zeroResidualItemId, "10.0000");
        }
    }

    @Test
    void confirmedSourceCannotReverseWithoutACompleteReversalLedger()
            throws Exception {
        ConfirmedFixture confirmed;
        try (Connection connection = connection()) {
            confirmed = createAcceptedConfirmation(connection);
        }

        try (Connection connection = connection()) {
            connection.setAutoCommit(false);
            execute(connection, """
                    UPDATE stock_documents SET status = -1 WHERE id = ?
                    """, confirmed.source().documentId());
            PSQLException missingLedger = assertThrows(
                    PSQLException.class, connection::commit);
            assertEquals("23514", missingLedger.getSQLState());
            connection.rollback();
        }
        try (Connection connection = connection()) {
            assertEquals("1", scalarString(connection, """
                    SELECT status FROM stock_documents WHERE id = ?
                    """, confirmed.source().documentId()));
        }
    }

    @Test
    void completeReversalMapsEveryAcceptedSliceAndIsAppendOnly()
            throws Exception {
        ConfirmedFixture confirmed;
        try (Connection connection = connection()) {
            confirmed = createAcceptedConfirmation(connection);
        }

        UUID reversalId = UUID.randomUUID();
        UUID reversalItemId = UUID.randomUUID();
        Fixture replacement;
        try (Connection connection = connection()) {
            connection.setAutoCommit(false);
            execute(connection, """
                    UPDATE stock_documents SET status = -1 WHERE id = ?
                    """, confirmed.source().documentId());
            replacement = createResidualFixture(
                    connection, confirmed.source(), confirmed.report(),
                    new BigDecimal("10.0000"));
            execute(connection, """
                    INSERT INTO production_finished_in_confirmation_reversals(
                        id, confirmation_id, reversed_stock_document_id,
                        replacement_stock_document_id, idempotency_key)
                    VALUES (?, ?, ?, ?, ?)
                    """, reversalId, confirmed.confirmationId(),
                    confirmed.source().documentId(), replacement.documentId(),
                    "reverse-confirm-" + reversalId);
            execute(connection, """
                    INSERT INTO
                        production_finished_in_confirmation_reversal_items(
                            id, reversal_id, confirmation_item_id,
                            replacement_stock_document_item_id, qty)
                    VALUES (?, ?, ?, ?, 10)
                    """, reversalItemId, reversalId,
                    confirmed.confirmationItemId(), replacement.itemId());
            connection.commit();
        }

        try (Connection connection = connection()) {
            assertEquals("-1", scalarString(connection, """
                    SELECT status FROM stock_documents WHERE id = ?
                    """, confirmed.source().documentId()));
            assertEquals("0", scalarString(connection, """
                    SELECT status FROM stock_documents WHERE id = ?
                    """, replacement.documentId()));
            assertDecimal(connection, """
                    SELECT confirmed.accepted_qty - reversal_item.qty
                    FROM production_finished_in_confirmation_reversal_items
                        reversal_item
                    JOIN production_finished_in_confirmation_items confirmed
                      ON confirmed.id = reversal_item.confirmation_item_id
                    WHERE reversal_item.id = ?
                    """, reversalItemId, "0.0000");
            assertDecimal(connection, """
                    SELECT qty FROM stock_document_items WHERE id = ?
                    """, replacement.itemId(), "10.0000");
        }

        try (Connection connection = connection()) {
            PSQLException headerAppendOnly = assertThrows(
                    PSQLException.class,
                    () -> execute(connection, """
                            UPDATE production_finished_in_confirmation_reversals
                            SET idempotency_key = ?
                            WHERE id = ?
                            """, "rewrite-" + reversalId, reversalId));
            assertEquals("55000", headerAppendOnly.getSQLState());
        }
        try (Connection connection = connection()) {
            PSQLException itemAppendOnly = assertThrows(
                    PSQLException.class,
                    () -> execute(connection, """
                            UPDATE
                                production_finished_in_confirmation_reversal_items
                            SET qty = 9
                            WHERE id = ?
                            """, reversalItemId));
            assertEquals("55000", itemAppendOnly.getSQLState());
        }
    }

    private static Flyway flyway(String target) {
        return Flyway.configure()
                .dataSource(
                        POSTGRES.getJdbcUrl(),
                        POSTGRES.getUsername(),
                        POSTGRES.getPassword())
                .locations("classpath:db/migration")
                .validateMigrationNaming(true)
                .target(target)
                .load();
    }

    /**
     * V330 is an unrelated pending finance migration and currently blocks a
     * full empty-database replay.  This test isolates V338 by starting from the
     * last installed local baseline (V329) and giving Flyway a location that
     * contains only the immutable V338 candidate under test.
     */
    private static void migrateOnlyV338() throws Exception {
        Path directory = Files.createTempDirectory("uten-v338-only-");
        Path migration = directory.resolve(
                "V338__production_finished_in_warehouse_confirmation.sql");
        try {
            Files.copy(
                    Path.of("src/main/resources/db/migration/"
                            + "V338__production_finished_in_warehouse_confirmation.sql"),
                    migration,
                    StandardCopyOption.REPLACE_EXISTING);
            Flyway.configure()
                    .dataSource(
                            POSTGRES.getJdbcUrl(),
                            POSTGRES.getUsername(),
                            POSTGRES.getPassword())
                    .locations("filesystem:" + directory.toAbsolutePath())
                    .validateOnMigrate(false)
                    .target("338")
                    .load()
                    .migrate();
        } finally {
            Files.deleteIfExists(migration);
            Files.deleteIfExists(directory);
        }
    }

    private static Fixture createFixture(
            Connection connection,
            short documentStatus,
            BigDecimal qty,
            boolean ignored) throws Exception {
        return createFixture(connection, documentStatus, qty, ignored, null, qty);
    }

    private static Fixture createFixture(
            Connection connection,
            short documentStatus,
            BigDecimal qty,
            boolean withReport,
            ReportSource report,
            BigDecimal reportedQty) throws Exception {
        UUID unitId = UUID.randomUUID();
        UUID goodsId = report == null ? UUID.randomUUID() : report.goodsId();
        UUID warehouseId = UUID.randomUUID();
        UUID planId = UUID.randomUUID();
        UUID documentId = UUID.randomUUID();
        UUID itemId = UUID.randomUUID();
        LocalDate date = LocalDate.of(2026, 8, 22);
        if (report == null) {
            execute(connection,
                    "INSERT INTO units(id, code, name) VALUES (?, ?, 'piece')",
                    unitId, "U-" + unitId);
            execute(connection, """
                    INSERT INTO goods(id, code, name, code_sequence)
                    VALUES (?, ?, 'fixture',
                        (SELECT COALESCE(MAX(code_sequence), 0) + 1 FROM goods))
                    """, goodsId, "G-" + goodsId);
        } else {
            unitId = report.unitId();
        }
        execute(connection,
                "INSERT INTO warehouses(id, code, name) VALUES (?, ?, 'fixture')",
                warehouseId, "WH-" + warehouseId);
        execute(connection, """
                INSERT INTO production_plans(id, bill_no, bill_date, status)
                VALUES (?, ?, ?, 1)
                """, planId, businessNo("SJ", planId), date);
        execute(connection, """
                INSERT INTO stock_documents(
                    id, doc_type, bill_no, bill_date, warehouse_id,
                    status, source_daily_report_id)
                VALUES (?, 'FINISHED_IN', ?, ?, ?, ?, ?)
                """, documentId, businessNo("CR", documentId), date,
                warehouseId, documentStatus,
                withReport ? report.reportId() : null);
        execute(connection, """
                INSERT INTO stock_document_items(
                    id, doc_id, bill_type, bill_no, bill_date, line_no,
                    goods_id, unit_id, unit_rate, qty, reported_qty,
                    base_qty, source_daily_report_item_id,
                    goods_snapshot_source)
                VALUES (?, ?, 'FINISHED_IN', ?, ?, 1,
                    ?, ?, 1, ?, ?, ?, ?, 'MASTER_AT_SAVE')
                """, itemId, documentId, businessNo("CR", documentId), date,
                goodsId, unitId, qty, reportedQty, qty,
                withReport ? report.reportItemId() : null);
        execute(connection, """
                INSERT INTO plan_draw_links(plan_id, draw_id)
                VALUES (?, ?)
                """, planId, documentId);
        return new Fixture(
                planId, documentId, itemId, warehouseId,
                goodsId, unitId);
    }

    /** V329-era row: V338 columns intentionally do not exist yet. */
    private static Fixture createLegacyFixture(
            Connection connection, BigDecimal qty) throws Exception {
        UUID unitId = UUID.randomUUID();
        UUID goodsId = UUID.randomUUID();
        UUID warehouseId = UUID.randomUUID();
        UUID planId = UUID.randomUUID();
        UUID documentId = UUID.randomUUID();
        UUID itemId = UUID.randomUUID();
        LocalDate date = LocalDate.of(2026, 8, 22);
        execute(connection,
                "INSERT INTO units(id, code, name) VALUES (?, ?, 'piece')",
                unitId, "U-" + unitId);
        execute(connection, """
                INSERT INTO goods(id, code, name, code_sequence)
                VALUES (?, ?, 'legacy fixture',
                    (SELECT COALESCE(MAX(code_sequence), 0) + 1 FROM goods))
                """, goodsId, "G-" + goodsId);
        execute(connection,
                "INSERT INTO warehouses(id, code, name) VALUES (?, ?, 'fixture')",
                warehouseId, "WH-" + warehouseId);
        execute(connection, """
                INSERT INTO production_plans(id, bill_no, bill_date, status)
                VALUES (?, ?, ?, 1)
                """, planId, businessNo("SJ", planId), date);
        execute(connection, """
                INSERT INTO stock_documents(
                    id, doc_type, bill_no, bill_date, warehouse_id, status)
                VALUES (?, 'FINISHED_IN', ?, ?, ?, 1)
                """, documentId, businessNo("CR", documentId), date,
                warehouseId);
        execute(connection, """
                INSERT INTO stock_document_items(
                    id, doc_id, bill_type, bill_no, bill_date, line_no,
                    goods_id, unit_id, unit_rate, qty, base_qty,
                    goods_snapshot_source)
                VALUES (?, ?, 'FINISHED_IN', ?, ?, 1,
                    ?, ?, 1, ?, ?, 'MASTER_AT_SAVE')
                """, itemId, documentId, businessNo("CR", documentId), date,
                goodsId, unitId, qty, qty);
        execute(connection, """
                INSERT INTO plan_draw_links(plan_id, draw_id)
                VALUES (?, ?)
                """, planId, documentId);
        return new Fixture(
                planId, documentId, itemId, warehouseId, goodsId, unitId);
    }

    private static Fixture createResidualFixture(
            Connection connection,
            Fixture source,
            ReportSource report,
            BigDecimal qty) throws Exception {
        UUID documentId = UUID.randomUUID();
        UUID itemId = UUID.randomUUID();
        LocalDate date = LocalDate.of(2026, 8, 22);
        execute(connection, """
                INSERT INTO stock_documents(
                    id, doc_type, bill_no, bill_date, warehouse_id,
                    status, source_daily_report_id)
                VALUES (?, 'FINISHED_IN', ?, ?, ?, 0, ?)
                """, documentId, businessNo("CR", documentId), date,
                source.warehouseId(), report.reportId());
        execute(connection, """
                INSERT INTO stock_document_items(
                    id, doc_id, bill_type, bill_no, bill_date, line_no,
                    goods_id, unit_id, unit_rate, qty, reported_qty,
                    base_qty, source_daily_report_item_id,
                    goods_snapshot_source)
                VALUES (?, ?, 'FINISHED_IN', ?, ?, 1,
                    ?, ?, 1, ?, ?, ?, ?, 'MASTER_AT_SAVE')
                """, itemId, documentId, businessNo("CR", documentId), date,
                source.goodsId(), source.unitId(), qty, qty, qty,
                report.reportItemId());
        execute(connection, """
                INSERT INTO plan_draw_links(plan_id, draw_id)
                VALUES (?, ?)
                """, source.planId(), documentId);
        return new Fixture(
                source.planId(), documentId, itemId,
                source.warehouseId(), source.goodsId(), source.unitId());
    }

    private static ReportSource createReportSource(
            Connection connection, BigDecimal qty) throws Exception {
        UUID reportId = UUID.randomUUID();
        UUID reportItemId = UUID.randomUUID();
        UUID unitId = UUID.randomUUID();
        UUID goodsId = UUID.randomUUID();
        LocalDate date = LocalDate.of(2026, 8, 22);
        execute(connection,
                "INSERT INTO units(id, code, name) VALUES (?, ?, 'piece')",
                unitId, "U-" + unitId);
        execute(connection, """
                INSERT INTO goods(id, code, name, code_sequence)
                VALUES (?, ?, 'fixture',
                    (SELECT COALESCE(MAX(code_sequence), 0) + 1 FROM goods))
                """, goodsId, "G-" + goodsId);
        execute(connection, """
                INSERT INTO production_daily_reports(
                    id, bill_no, bill_date, status)
                VALUES (?, ?, ?, 1)
                """, reportId, businessNo("SR", reportId), date);
        execute(connection, """
                INSERT INTO production_daily_report_items(
                    id, report_id, bill_no, bill_date, line_no,
                    goods_id, unit_id, unit_rate, qty)
                VALUES (?, ?, ?, ?, 1, ?, ?, 1, ?)
                """, reportItemId, reportId, businessNo("SR", reportId),
                date, goodsId, unitId, qty);
        return new ReportSource(
                reportId, reportItemId, goodsId, unitId);
    }

    private static UUID createAdditionalSourceItem(
            Connection connection,
            Fixture source,
            ReportSource report,
            int lineNo,
            BigDecimal qty) throws Exception {
        UUID itemId = UUID.randomUUID();
        execute(connection, """
                INSERT INTO stock_document_items(
                    id, doc_id, bill_type, bill_no, bill_date, line_no,
                    goods_id, unit_id, unit_rate, qty, reported_qty,
                    base_qty, source_daily_report_item_id,
                    goods_snapshot_source)
                SELECT ?, document.id, 'FINISHED_IN',
                       document.bill_no, document.bill_date, ?,
                       ?, ?, 1, ?, ?, ?, ?, 'MASTER_AT_SAVE'
                FROM stock_documents document
                WHERE document.id = ?
                """, itemId, lineNo, source.goodsId(), source.unitId(),
                qty, qty, qty, report.reportItemId(), source.documentId());
        return itemId;
    }

    private static ConfirmedFixture createAcceptedConfirmation(
            Connection connection) throws Exception {
        ReportSource report = createReportSource(
                connection, new BigDecimal("10.0000"));
        Fixture source = createFixture(
                connection, (short) 1, new BigDecimal("10.0000"),
                true, report, new BigDecimal("10.0000"));
        UUID confirmationId = UUID.randomUUID();
        UUID confirmationItemId = UUID.randomUUID();
        connection.setAutoCommit(false);
        execute(connection, """
                INSERT INTO production_finished_in_confirmations(
                    id, stock_document_id, decision,
                    idempotency_key, request_hash)
                VALUES (?, ?, 'ACCEPTED', ?, ?)
                """, confirmationId, source.documentId(),
                "accepted-confirm-" + confirmationId,
                "d".repeat(64));
        execute(connection, """
                INSERT INTO production_finished_in_confirmation_items(
                    id, confirmation_id, stock_document_item_id,
                    reported_qty, accepted_qty, residual_qty)
                VALUES (?, ?, ?, 10, 10, 0)
                """, confirmationItemId, confirmationId, source.itemId());
        connection.commit();
        return new ConfirmedFixture(
                source, report, confirmationId, confirmationItemId);
    }

    private static void setConfirmDocumentLane(
            Connection connection, UUID documentId) throws Exception {
        try (PreparedStatement statement = connection.prepareStatement("""
                SELECT set_config(
                    'app.production_finished_in_confirm_doc_id', ?, true)
                """)) {
            statement.setString(1, documentId.toString());
            try (ResultSet result = statement.executeQuery()) {
                assertTrue(result.next());
                assertEquals(documentId.toString(), result.getString(1));
            }
        }
    }

    private static void execute(
            Connection connection, String sql, Object... values)
            throws Exception {
        try (PreparedStatement statement = connection.prepareStatement(sql)) {
            for (int i = 0; i < values.length; i++) {
                statement.setObject(i + 1, values[i]);
            }
            statement.executeUpdate();
        }
    }

    private static void assertDecimal(
            Connection connection,
            String sql,
            UUID id,
            String expected) throws Exception {
        try (PreparedStatement statement = connection.prepareStatement(sql)) {
            statement.setObject(1, id);
            try (ResultSet result = statement.executeQuery()) {
                assertTrue(result.next());
                assertEquals(0,
                        new BigDecimal(expected).compareTo(result.getBigDecimal(1)));
            }
        }
    }

    private static String scalarString(
            Connection connection, String sql, UUID id) throws Exception {
        try (PreparedStatement statement = connection.prepareStatement(sql)) {
            statement.setObject(1, id);
            try (ResultSet result = statement.executeQuery()) {
                assertTrue(result.next());
                return result.getString(1);
            }
        }
    }

    private static boolean scalarBoolean(
            Connection connection, String sql, UUID id) throws Exception {
        try (PreparedStatement statement = connection.prepareStatement(sql)) {
            statement.setObject(1, id);
            try (ResultSet result = statement.executeQuery()) {
                assertTrue(result.next());
                return result.getBoolean(1);
            }
        }
    }

    private static String businessNo(String prefix, UUID id) {
        int sequence = BUSINESS_IDENTIFIER_SEQUENCE.incrementAndGet();
        if (sequence > 999_999) {
            throw new IllegalStateException(
                    "test business identifier sequence exhausted");
        }
        return prefix + "20260822" + "%06d".formatted(sequence);
    }

    private static Connection connection() throws Exception {
        return DriverManager.getConnection(
                POSTGRES.getJdbcUrl(),
                POSTGRES.getUsername(),
                POSTGRES.getPassword());
    }

    private record Fixture(
            UUID planId,
            UUID documentId,
            UUID itemId,
            UUID warehouseId,
            UUID goodsId,
            UUID unitId) {
    }

    private record ReportSource(
            UUID reportId,
            UUID reportItemId,
            UUID goodsId,
            UUID unitId) {
    }

    private record ConfirmedFixture(
            Fixture source,
            ReportSource report,
            UUID confirmationId,
            UUID confirmationItemId) {
    }
}
