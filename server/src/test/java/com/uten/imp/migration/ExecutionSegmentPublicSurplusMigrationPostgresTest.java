package com.uten.imp.migration;

import org.flywaydb.core.Flyway;
import org.junit.jupiter.api.*;
import org.junit.jupiter.api.condition.EnabledIfEnvironmentVariable;
import org.postgresql.util.PSQLException;
import org.testcontainers.containers.PostgreSQLContainer;

import java.sql.*;
import java.util.List;
import java.util.UUID;

import static org.junit.jupiter.api.Assertions.*;

/** Real V689 -> V690 forward migration, then isolated migrated-column/function oracles. */
@EnabledIfEnvironmentVariable(named = "UTEN_RUN_DB_TESTS", matches = "(?i)true")
class ExecutionSegmentPublicSurplusMigrationPostgresTest {
    static final PostgreSQLContainer<?> DATABASE = new PostgreSQLContainer<>("postgres:16-alpine");
    Connection db;
    String schema;
    UUID segment, planItem, goods, unit, sales, allocation;

    @BeforeAll static void migrate() {
        DATABASE.start();
        migration("689").migrate();
        assertEquals(1, migration("690").migrate().migrationsExecuted);
        assertEquals(0, migration("690").migrate().migrationsExecuted);
    }
    static Flyway migration(String target) {
        return Flyway.configure().dataSource(DATABASE.getJdbcUrl(), DATABASE.getUsername(), DATABASE.getPassword())
                .locations("classpath:db/migration").target(target).load();
    }
    @AfterAll static void stop() { DATABASE.stop(); }
    @AfterEach void close() throws Exception { db.close(); }

    @BeforeEach void fixture() throws Exception {
        schema = "surplus_" + UUID.randomUUID().toString().replace("-", "");
        db = connection();
        sql(db, "CREATE SCHEMA " + schema);
        sql(db, "SET search_path TO " + schema + ", public");
        // Keep real migrated columns; deliberately isolate these ownership guards
        // from unrelated order/quality fixture requirements (covered by business-chain E2E).
        for (String table : List.of("production_execution_segments", "execution_segment_sales_allocations",
                "production_daily_reports", "production_daily_report_items", "stock_documents",
                "stock_document_items", "production_planning_packages")) {
            sql(db, "CREATE TABLE " + schema + "." + table + " AS SELECT * FROM public." + table + " WITH NO DATA");
        }
        for (String function : List.of("fn_validate_daily_report_execution_segment()",
                "fn_validate_finished_in_execution_segment()",
                "fn_assert_execution_segment_public_surplus_capacity(uuid)",
                "fn_assert_execution_segment_public_surplus_row()",
                "fn_assert_daily_report_segment_public_status()",
                "fn_assert_stock_document_segment_public_status()",
                "fn_assert_execution_segment_public_capacity_change()")) {
            String definition = scalar(db, "SELECT pg_get_functiondef(CAST(? AS regprocedure))", "public." + function);
            sql(db, definition.replace("FUNCTION public.", "FUNCTION " + schema + "."));
        }
        try (Statement statement = db.createStatement(); ResultSet rows = statement.executeQuery("""
                SELECT pg_get_triggerdef(trigger.oid)
                FROM pg_trigger trigger JOIN pg_class relation ON relation.oid=trigger.tgrelid
                JOIN pg_namespace namespace ON namespace.oid=relation.relnamespace
                WHERE namespace.nspname='public' AND NOT trigger.tgisinternal
                  AND (trigger.tgname LIKE 'trg_assert_%public%'
                    OR trigger.tgname LIKE 'trg_validate_daily_report_execution_segment%'
                    OR trigger.tgname LIKE 'trg_validate_finished_in_execution_segment%')
                """)) {
            while (rows.next()) sql(db, rows.getString(1).replace(" ON public.", " ON " + schema + ".")
                    .replace("FUNCTION public.", "FUNCTION " + schema + "."));
        }
        segment = UUID.randomUUID(); planItem = UUID.randomUUID(); goods = UUID.randomUUID();
        unit = UUID.randomUUID(); sales = UUID.randomUUID(); allocation = UUID.randomUUID();
        sql(db, """
                INSERT INTO production_execution_segments(id,source_plan_item_id,product_goods_id,
                    product_unit_id,planned_qty,is_deleted,status)
                VALUES(?,?,?,?,2000,false,'IN_PROGRESS')
                """, segment, planItem, goods, unit);
        sql(db, "INSERT INTO execution_segment_sales_allocations(id,execution_segment_id,sales_order_item_id,allocated_qty) VALUES(?,?,?,1000)",
                allocation, segment, sales);
    }

    @Test void salesAndPublicReportAndInboundStayDisjointAfterPartialProduction() throws Exception {
        report(db, 1000, true, 1, null);
        UUID publicReport = report(db, 600, false, 0, null);
        assertConstraint("daily_report_segment_public_capacity_guard", () -> report(db, 401, false, 0, null));
        assertConstraint("finished_in_segment_public_report_guard", () -> inbound(db, 1, 1));
        sql(db, "UPDATE production_daily_reports SET status=1 WHERE id=?", publicReport);
        UUID receipt = inbound(db, 600, 1);
        assertConstraint("daily_report_segment_public_capacity_guard", () -> report(db, 401, false, 0, null));
        assertConstraint("finished_in_segment_public_report_guard", () -> inbound(db, 1, 1));
        assertConstraint("finished_in_segment_public_report_guard", () ->
                sql(db, "UPDATE production_daily_reports SET status=-1 WHERE id=?", publicReport));
        sql(db, "UPDATE stock_documents SET status=-1 WHERE id=?", receipt);
        sql(db, "UPDATE production_daily_reports SET status=-1 WHERE id=?", publicReport);
        report(db, 1000, false, 0, null);
        assertConstraint("daily_report_segment_public_capacity_guard", () -> report(db, 1, false, 0, null));
    }

    @Test void publicIdentityCannotBorrowSalesAndSalesIdentityMustNotBeNull() throws Exception {
        UUID report = report(db, 1, false, 0, null);
        assertConstraint("daily_report_segment_sales_allocation_required", () -> sql(db,
                "UPDATE production_daily_report_items SET sales_order_item_id=? WHERE report_id=?", sales, report));
        assertConstraint("daily_report_segment_sales_allocation_guard", () -> sql(db,
                "UPDATE production_daily_report_items SET execution_segment_sales_allocation_id=? WHERE report_id=?", allocation, report));
        sql(db, "UPDATE production_daily_report_items SET is_deleted=true WHERE report_id=?", report);
        assertConstraint("daily_report_segment_sales_allocation_required", () -> {
            sql(db, "UPDATE execution_segment_sales_allocations SET allocated_qty=2000");
            report(db, 1, false, 0, null);
        });
    }

    @Test void recoveryDoesNotConsumeOrdinaryQuotaAndHeaderRestorationRechecksCapacity() throws Exception {
        report(db, 1000, false, 0, null);
        report(db, 200, false, 0, UUID.randomUUID());
        UUID cancelled = report(db, 1, false, -1, null);
        assertConstraint("daily_report_segment_public_capacity_guard", () ->
                sql(db, "UPDATE production_daily_reports SET status=0 WHERE id=?", cancelled));
        assertConstraint("daily_report_segment_public_capacity_guard", () ->
                sql(db, "UPDATE production_execution_segments SET planned_qty=1999 WHERE id=?", segment));
        assertConstraint("daily_report_segment_public_capacity_guard", () ->
                sql(db, "UPDATE execution_segment_sales_allocations SET allocated_qty=1001 WHERE id=?", allocation));
    }

    @Test void concurrentDraftsCannotTogetherExceedPublicQuota() throws Exception {
        try (Connection left = connection(); Connection right = connection()) {
            sql(left, "SET search_path TO " + schema + ",public");
            sql(right, "SET search_path TO " + schema + ",public");
            left.setAutoCommit(false); right.setAutoCommit(false);
            report(left, 600, false, 0, null);
            report(right, 600, false, 0, null);
            left.commit();
            assertConstraint("daily_report_segment_public_capacity_guard", right::commit);
            right.rollback();
        }
        assertEquals("600.0000", scalar(db, "SELECT SUM(qty)::numeric(18,4)::text FROM production_daily_report_items"));
    }

    @Test void multipleReportAndInboundBatchesPreserveTheirOwnRemainingQuantity() throws Exception {
        report(db, 400, false, 1, null);
        report(db, 600, false, 1, null);
        UUID first = inbound(db, 300, 1);
        UUID second = inbound(db, 400, 1);
        UUID third = inbound(db, 300, 1);
        assertConstraint("finished_in_segment_public_report_guard", () -> inbound(db, 1, 1));
        sql(db, "UPDATE stock_documents SET status=-1 WHERE id=?", second);
        inbound(db, 400, 1);
        assertConstraint("finished_in_segment_public_report_guard", () ->
                sql(db, "UPDATE stock_documents SET status=1 WHERE id=?", second));
        sql(db, "UPDATE stock_documents SET status=-1 WHERE id=?", first);
        sql(db, "UPDATE stock_documents SET status=-1 WHERE id=?", third);
        inbound(db, 600, 1);
        assertConstraint("finished_in_segment_public_report_guard", () -> inbound(db, 1, 1));
    }

    @Test void sameInboundDocumentChecksAllPublicLinesWhenItsHeaderIsApproved() throws Exception {
        report(db, 1000, false, 1, null);
        UUID document = inbound(db, 600, 0);
        UUID secondItem = inboundLine(db, document, 600);
        assertConstraint("finished_in_segment_public_report_guard", () ->
                sql(db, "UPDATE stock_documents SET status=1 WHERE id=?", document));
        sql(db, "UPDATE stock_document_items SET qty=400 WHERE id=?", secondItem);
        sql(db, "UPDATE stock_documents SET status=1 WHERE id=?", document);
        assertConstraint("finished_in_segment_public_report_guard", () -> inbound(db, 1, 1));
    }

    @Test void recoveryBatchesNeverIncreaseThePublicFinishedStockCeiling() throws Exception {
        report(db, 1000, false, 1, null);
        report(db, 200, false, 1, UUID.randomUUID());
        report(db, 100, false, 1, UUID.randomUUID());
        UUID initialPass = inbound(db, 700, 1);
        inbound(db, 200, 1);
        inbound(db, 100, 1);
        assertConstraint("finished_in_segment_public_report_guard", () -> inbound(db, 1, 1));
        assertConstraint("daily_report_segment_public_capacity_guard", () -> report(db, 1, false, 0, null));
        sql(db, "UPDATE stock_documents SET status=-1 WHERE id=?", initialPass);
        inbound(db, 300, 1);
        inbound(db, 400, 1);
        assertConstraint("finished_in_segment_public_report_guard", () -> inbound(db, 1, 1));
    }

    @Test void snapshotIsolationCannotBypassSerializedPublicCapacity() throws Exception {
        db.setTransactionIsolation(Connection.TRANSACTION_REPEATABLE_READ);
        db.setAutoCommit(false);
        report(db, 1, false, 0, null);
        PSQLException error = assertThrows(PSQLException.class, db::commit);
        assertEquals("25001", error.getSQLState());
        db.rollback();
    }

    UUID report(Connection connection, int qty, boolean salesOwned, int status, UUID recovery) throws Exception {
        UUID report = UUID.randomUUID();
        sql(connection, "INSERT INTO production_daily_reports(id,status,is_deleted) VALUES(?,?,false)", report, status);
        sql(connection, """
                INSERT INTO production_daily_report_items(id,report_id,plan_item_id,goods_id,unit_id,
                    execution_segment_id,execution_segment_sales_allocation_id,sales_order_item_id,
                    qty,is_deleted,fqc_recovery_authorization_id)
                VALUES(?,?,?,?,?,?,?,?,?,false,?)
                """, UUID.randomUUID(), report, planItem, goods, unit, segment,
                salesOwned ? allocation : null, salesOwned ? sales : null, qty, recovery);
        return report;
    }
    UUID inbound(Connection connection, int qty, int status) throws Exception {
        UUID document = UUID.randomUUID();
        sql(connection, "INSERT INTO stock_documents(id,doc_type,status,is_deleted) VALUES(?,'FINISHED_IN',?,false)", document, status);
        inboundLine(connection, document, qty);
        return document;
    }
    UUID inboundLine(Connection connection, UUID document, int qty) throws Exception {
        UUID item = UUID.randomUUID();
        sql(connection, """
                INSERT INTO stock_document_items(id,doc_id,bill_type,upstream_item_id,goods_id,unit_id,
                    execution_segment_id,qty,is_deleted)
                VALUES(?,?,'FINISHED_IN',?,?,?,?,?,false)
                """, item, document, planItem, goods, unit, segment, qty);
        return item;
    }
    static Connection connection() throws SQLException {
        return DriverManager.getConnection(DATABASE.getJdbcUrl(), DATABASE.getUsername(), DATABASE.getPassword());
    }
    interface SqlAction { void run() throws Exception; }
    static void assertConstraint(String constraint, SqlAction action) {
        PSQLException error = assertThrows(PSQLException.class, action::run);
        assertEquals(constraint, error.getServerErrorMessage().getConstraint(), error.getMessage());
    }
    static void sql(Connection db, String sql, Object... args) throws SQLException {
        try (PreparedStatement statement = db.prepareStatement(sql)) {
            for (int i=0; i<args.length; i++) statement.setObject(i+1,args[i]);
            statement.execute();
        }
    }
    static String scalar(Connection db, String sql, Object... args) throws SQLException {
        try (PreparedStatement statement = db.prepareStatement(sql)) {
            for (int i=0; i<args.length; i++) statement.setObject(i+1,args[i]);
            try (ResultSet rows=statement.executeQuery()) { rows.next(); return rows.getString(1); }
        }
    }
}
