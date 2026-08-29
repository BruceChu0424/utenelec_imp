package com.uten.imp.features.production.dailyreport;

import com.uten.imp.features.production.ProductionDocumentAccessPolicy;
import com.uten.imp.features.production.dailyreport.dto.ReportablePlanLine;
import com.uten.imp.security.OwnerVisibility;
import org.flywaydb.core.Flyway;
import org.junit.jupiter.api.AfterAll;
import org.junit.jupiter.api.BeforeAll;
import org.junit.jupiter.api.BeforeEach;
import org.junit.jupiter.api.Test;
import org.junit.jupiter.api.condition.EnabledIfEnvironmentVariable;
import org.springframework.jdbc.core.JdbcTemplate;
import org.springframework.jdbc.datasource.DriverManagerDataSource;
import org.springframework.jdbc.datasource.DataSourceTransactionManager;
import org.springframework.transaction.support.TransactionTemplate;
import org.testcontainers.containers.PostgreSQLContainer;

import java.util.List;
import java.util.UUID;

import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertTrue;
import static org.mockito.Mockito.mock;
import static org.mockito.Mockito.when;

/** Real PostgreSQL evidence for the report-source CQRS query. */
@EnabledIfEnvironmentVariable(named = "UTEN_RUN_DB_TESTS", matches = "(?i)true")
class ReportablePlanLinePostgresTest {

    private static final PostgreSQLContainer<?> POSTGRES =
            new PostgreSQLContainer<>("postgres:16-alpine")
                    .withDatabaseName("uten_imp")
                    .withUsername("uten")
                    .withPassword("uten");

    private static final UUID GOODS_ID =
            UUID.fromString("10000000-0000-0000-0000-000000000001");
    private static final UUID UNIT_ID =
            UUID.fromString("10000000-0000-0000-0000-000000000002");
    private static final UUID CLIENT_ID =
            UUID.fromString("10000000-0000-0000-0000-000000000003");
    private static final UUID ORDER_ONE_ID =
            UUID.fromString("10000000-0000-0000-0000-000000000004");
    private static final UUID ORDER_TWO_ID =
            UUID.fromString("10000000-0000-0000-0000-000000000005");
    private static final UUID ORDER_ITEM_ONE_ID =
            UUID.fromString("10000000-0000-0000-0000-000000000006");
    private static final UUID ORDER_ITEM_TWO_ID =
            UUID.fromString("10000000-0000-0000-0000-000000000007");
    private static final UUID PLAN_ID =
            UUID.fromString("10000000-0000-0000-0000-000000000008");
    private static final UUID PLAN_ITEM_ID =
            UUID.fromString("10000000-0000-0000-0000-000000000009");
    private static final UUID WAREHOUSE_ID =
            UUID.fromString("10000000-0000-0000-0000-000000000010");
    private static final UUID PACKAGE_ID =
            UUID.fromString("10000000-0000-0000-0000-000000000011");
    private static final UUID SEGMENT_ID =
            UUID.fromString("10000000-0000-0000-0000-000000000012");
    private static final UUID LINK_ONE_ID =
            UUID.fromString("10000000-0000-0000-0000-000000000013");
    private static final UUID LINK_TWO_ID =
            UUID.fromString("10000000-0000-0000-0000-000000000014");
    private static final UUID ALLOCATION_ONE_ID =
            UUID.fromString("10000000-0000-0000-0000-000000000015");
    private static final UUID ALLOCATION_TWO_ID =
            UUID.fromString("10000000-0000-0000-0000-000000000016");
    private static final UUID ANALYSIS_ID =
            UUID.fromString("10000000-0000-0000-0000-000000000020");
    private static final UUID ANALYSIS_ITEM_ID =
            UUID.fromString("10000000-0000-0000-0000-000000000021");
    private static final UUID EMPLOYEE_ID =
            UUID.fromString("10000000-0000-0000-0000-000000000022");

    private static JdbcTemplate jdbc;
    private static TransactionTemplate transaction;
    private ReportablePlanLineQueryService service;

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
        var dataSource = new DriverManagerDataSource(
                POSTGRES.getJdbcUrl(),
                POSTGRES.getUsername(),
                POSTGRES.getPassword());
        jdbc = new JdbcTemplate(dataSource);
        transaction = new TransactionTemplate(
                new DataSourceTransactionManager(dataSource));
        jdbc.update(
                "INSERT INTO units(id, code, name, status) "
                        + "VALUES (?, 'DW900001', '件', '使用')",
                UNIT_ID);
        jdbc.update(
                "INSERT INTO goods(id, code, name, spec, code_sequence) "
                        + "VALUES (?, 'HP900001', '成品灯', '300mm', 900001)",
                GOODS_ID);
        jdbc.update(
                "INSERT INTO clients(id, code, name, status, code_sequence) "
                        + "VALUES (?, 'KH900001', '测试客户', '使用', 900001)",
                CLIENT_ID);
        jdbc.update(
                "INSERT INTO warehouses(id, code, name, status) "
                        + "VALUES (?, 'WH900001', '成品仓', '使用')",
                WAREHOUSE_ID);
        jdbc.update("""
                INSERT INTO employees(
                    id, code, full_name, id_type, department_id,
                    hire_date, status, employment_type
                ) VALUES (?, 'UT900001', '报工查询测试员工', '其他',
                          (
                              SELECT id
                              FROM departments
                              WHERE code = 'WS_ZHUSU'
                                AND is_deleted = FALSE
                          ),
                          DATE '2026-08-01', 'active', 'regular')
                """, EMPLOYEE_ID);
        jdbc.update("""
                INSERT INTO production_material_analyses(
                    id, warehouse_id, status, fingerprint,
                    initial_idempotency_key, maker_id
                ) VALUES (?, ?, 'ACTIVE', ?, 'reportable-plan-line-analysis',
                          ?)
                """, ANALYSIS_ID, WAREHOUSE_ID, "d".repeat(64),
                EMPLOYEE_ID);
        jdbc.update("""
                INSERT INTO production_material_analysis_items(
                    id, analysis_id, source_type, goods_id, unit_id,
                    source_ref, source_reason, requested_qty
                ) VALUES (?, ?, 'OTHER', ?, ?,
                          'REPORTABLE-PLAN-LINE',
                          'reportable plan line fixture', 100)
                """, ANALYSIS_ITEM_ID, ANALYSIS_ID, GOODS_ID, UNIT_ID);
    }

    @AfterAll
    static void stopPostgres() {
        POSTGRES.stop();
    }

    @BeforeEach
    void prepareFixture() {
        transaction.executeWithoutResult(ignored -> {
        jdbc.update("SET LOCAL session_replication_role = replica");
        jdbc.update("DELETE FROM production_daily_report_items");
        jdbc.update("DELETE FROM production_daily_reports");
        jdbc.update("DELETE FROM execution_segment_sales_allocations");
        jdbc.update("DELETE FROM production_execution_segments");
        jdbc.update("DELETE FROM production_planning_packages");
        jdbc.update("DELETE FROM plan_order_item_links");
        jdbc.update("DELETE FROM production_plan_items");
        jdbc.update("DELETE FROM production_plans");
        jdbc.update("DELETE FROM sales_order_items");
        jdbc.update("DELETE FROM sales_orders");
        jdbc.update("SET LOCAL session_replication_role = origin");
        insertOrder(ORDER_ONE_ID, ORDER_ITEM_ONE_ID, "XD20260801000001");
        insertOrder(ORDER_TWO_ID, ORDER_ITEM_TWO_ID, "XD20260801000002");
        jdbc.update("""
                INSERT INTO production_plans(
                    id, bill_no, bill_date, delivery_date, status
                ) VALUES (?, 'SJ20260801000001', DATE '2026-08-01', DATE '2026-08-10', 1)
                """, PLAN_ID);
        jdbc.update("""
                INSERT INTO production_plan_items(
                    id, bill_no, bill_date, plan_id, product_no,
                    goods_id, unit_id, unit_rate, qty, fqty
                ) VALUES (
                    ?, 'SJ20260801000001', DATE '2026-08-01', ?, 'SJ-001-1',
                    ?, ?, 1, 100, 40
                )
                """, PLAN_ITEM_ID, PLAN_ID, GOODS_ID, UNIT_ID);
        jdbc.update("""
                UPDATE production_plans
                SET material_analysis_id = ?, material_analysis_item_id = ?
                WHERE id = ?
                """, ANALYSIS_ID, ANALYSIS_ITEM_ID, PLAN_ID);
        jdbc.update("""
                INSERT INTO plan_order_item_links(
                    id, plan_item_id, order_item_id, allocated_qty, produced_qty
                ) VALUES (?, ?, ?, 70, 20)
                """, LINK_ONE_ID, PLAN_ITEM_ID, ORDER_ITEM_ONE_ID);
        jdbc.update("""
                INSERT INTO plan_order_item_links(
                    id, plan_item_id, order_item_id, allocated_qty, produced_qty
                ) VALUES (?, ?, ?, 30, 20)
                """, LINK_TWO_ID, PLAN_ITEM_ID, ORDER_ITEM_TWO_ID);
        jdbc.update("""
                INSERT INTO production_planning_packages(
                    id, plan_id, warehouse_id, idempotency_key,
                    request_hash, preview_fingerprint, status,
                    execution_model_version
                ) VALUES (?, ?, ?, 'reportable-plan-line-package', ?, ?,
                          'CONFIRMED', 1)
                """, PACKAGE_ID, PLAN_ID, WAREHOUSE_ID,
                "a".repeat(64), "b".repeat(64));
        jdbc.update("""
                INSERT INTO production_execution_segments(
                    id, package_id, plan_id, source_plan_item_id,
                    segment_no, segment_code, client_segment_key,
                    product_goods_id, product_unit_id, product_unit_rate,
                    planned_qty, status, bom_fingerprint, idempotency_key,
                    material_requirement_mode, zero_material_reason,
                    zero_material_analysis_id
                ) VALUES (?, ?, ?, ?, 1, ?,
                          'reportable-plan-line-segment', ?, ?, 1,
                          100, 'READY', ?,
                          'reportable-plan-line-segment', 'ZERO_MATERIAL',
                          'DIRECT_MAKE', ?)
                """, SEGMENT_ID, PACKAGE_ID, PLAN_ID, PLAN_ITEM_ID,
                canonicalSegmentCode(SEGMENT_ID), GOODS_ID, UNIT_ID,
                "c".repeat(64), ANALYSIS_ID);
        jdbc.update("""
                INSERT INTO execution_segment_sales_allocations(
                    id, execution_segment_id, plan_order_item_link_id,
                    sales_order_item_id, allocated_qty
                ) VALUES (?, ?, ?, ?, 70)
                """, ALLOCATION_ONE_ID, SEGMENT_ID, LINK_ONE_ID,
                ORDER_ITEM_ONE_ID);
        jdbc.update("""
                INSERT INTO execution_segment_sales_allocations(
                    id, execution_segment_id, plan_order_item_link_id,
                    sales_order_item_id, allocated_qty
                ) VALUES (?, ?, ?, ?, 30)
                """, ALLOCATION_TWO_ID, SEGMENT_ID, LINK_TWO_ID,
                ORDER_ITEM_TWO_ID);
        jdbc.update("""
                UPDATE production_execution_segments
                SET workshop_department_id = (
                        SELECT id
                        FROM departments
                        WHERE code = 'WS_ZHUSU'
                          AND is_deleted = FALSE
                    ),
                    responsible_employee_id = ?,
                    plan_begin_date = DATE '2026-08-01',
                    plan_end_date = DATE '2026-08-10',
                    status = 'DISPATCHED'
                WHERE id = ?
                """, EMPLOYEE_ID, SEGMENT_ID);
        jdbc.update("""
                UPDATE production_execution_segments
                SET status = 'IN_PROGRESS'
                WHERE id = ?
                """, SEGMENT_ID);
        insertDraftProgress();
        });

        ProductionDocumentAccessPolicy access =
                mock(ProductionDocumentAccessPolicy.class);
        when(access.scope()).thenReturn(
                new OwnerVisibility.OwnerScope(true, java.util.Set.of()));
        service = new ReportablePlanLineQueryService(jdbc, access);
    }

    private void insertDraftProgress() {
        UUID reportId = UUID.fromString(
                "10000000-0000-0000-0000-000000000017");
        String reportNo = "SR20260801000001";
        jdbc.update("""
                INSERT INTO production_daily_reports(
                    id, bill_no, bill_date, status
                ) VALUES (?, ?, DATE '2026-08-01', 0)
                """, reportId, reportNo);
        jdbc.update("""
                INSERT INTO production_daily_report_items(
                    id, bill_no, bill_date, report_id, line_no,
                    goods_id, unit_id, unit_rate, qty,
                    sales_order_item_id, plan_item_id,
                    execution_segment_id,
                    execution_segment_sales_allocation_id
                ) VALUES (?, ?, DATE '2026-08-01', ?, 1,
                          ?, ?, 1, 20, ?, ?, ?, ?)
                """, UUID.fromString(
                        "10000000-0000-0000-0000-000000000018"),
                reportNo, reportId, GOODS_ID, UNIT_ID,
                ORDER_ITEM_ONE_ID, PLAN_ITEM_ID, SEGMENT_ID,
                ALLOCATION_ONE_ID);
        jdbc.update("""
                INSERT INTO production_daily_report_items(
                    id, bill_no, bill_date, report_id, line_no,
                    goods_id, unit_id, unit_rate, qty,
                    sales_order_item_id, plan_item_id,
                    execution_segment_id,
                    execution_segment_sales_allocation_id
                ) VALUES (?, ?, DATE '2026-08-01', ?, 2,
                          ?, ?, 1, 20, ?, ?, ?, ?)
                """, UUID.fromString(
                        "10000000-0000-0000-0000-000000000019"),
                reportNo, reportId, GOODS_ID, UNIT_ID,
                ORDER_ITEM_TWO_ID, PLAN_ITEM_ID, SEGMENT_ID,
                ALLOCATION_TWO_ID);
    }

    @Test
    void mergedPlanIsExpandedByOrderWithIndependentReportCaps() {
        List<ReportablePlanLine> items =
                service.list(1, 100, null, null).getItems();

        assertEquals(2, items.size());
        assertEquals(0, items.get(0).maxReportQty().compareTo(
                new java.math.BigDecimal("50.0000")));
        assertEquals(0, items.get(1).maxReportQty().compareTo(
                new java.math.BigDecimal("10.0000")));
        assertEquals(List.of("XD20260801000001", "XD20260801000002"),
                items.stream().map(ReportablePlanLine::orderNo).toList());
    }

    @Test
    void historicalLinksNeverFallBackToAnInternalPlan() {
        writeHistoricalState(() -> jdbc.update("""
                    UPDATE plan_order_item_links
                    SET is_deleted = true, deleted_at = now()
                    WHERE plan_item_id = ?
                    """, PLAN_ITEM_ID));

        assertTrue(service.list(1, 100, null, null).getItems().isEmpty());
    }

    @Test
    void oneInvalidSalesTargetBlocksTheWholeMergedPlan() {
        writeHistoricalState(() -> jdbc.update(
                "UPDATE sales_order_items SET chain_status = 9 WHERE id = ?",
                ORDER_ITEM_TWO_ID));

        assertTrue(service.list(1, 100, null, null).getItems().isEmpty());
    }

    private void writeHistoricalState(Runnable mutation) {
        transaction.executeWithoutResult(ignored -> {
            jdbc.update("SET LOCAL session_replication_role = replica");
            mutation.run();
        });
    }

    private void insertOrder(UUID orderId, UUID itemId, String billNo) {
        jdbc.update("""
                INSERT INTO sales_orders(
                    id, bill_no, bill_date, client_id, deliver_date, status
                ) VALUES (?, ?, DATE '2026-08-01', ?, DATE '2026-08-10', 1)
                """, orderId, billNo, CLIENT_ID);
        jdbc.update("""
                INSERT INTO sales_order_items(
                    id, bill_no, bill_date, order_id, goods_id,
                    goods_code_snapshot, goods_name_snapshot,
                    goods_snapshot_source, goods_snapshot_locked_at,
                    unit_id, unit_rate, qty, chain_status
                ) VALUES (?, ?, DATE '2026-08-01', ?, ?,
                          'HP900001', '成品灯', 'MASTER_AT_APPROVAL', now(),
                          ?, 1, 100, 4)
                """, itemId, billNo, orderId, GOODS_ID, UNIT_ID);
    }

    private static String canonicalSegmentCode(UUID segmentId) {
        return "ZX%08d".formatted(
                Math.floorMod(segmentId.hashCode(), 99_999_999) + 1);
    }
}
