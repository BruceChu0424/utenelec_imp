package com.uten.imp.features.production.dailyreport;

import com.uten.imp.features.production.dailyreport.dto.ReportablePlanLine;
import org.flywaydb.core.Flyway;
import org.junit.jupiter.api.AfterAll;
import org.junit.jupiter.api.BeforeAll;
import org.junit.jupiter.api.BeforeEach;
import org.junit.jupiter.api.Test;
import org.junit.jupiter.api.condition.EnabledIfEnvironmentVariable;
import org.springframework.jdbc.core.JdbcTemplate;
import org.springframework.jdbc.datasource.DriverManagerDataSource;
import org.testcontainers.containers.PostgreSQLContainer;

import java.util.List;
import java.util.UUID;

import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertTrue;

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

    private static JdbcTemplate jdbc;
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
    }

    @AfterAll
    static void stopPostgres() {
        POSTGRES.stop();
    }

    @BeforeEach
    void prepareFixture() {
        jdbc.update("DELETE FROM plan_order_item_links");
        jdbc.update("DELETE FROM production_plan_items");
        jdbc.update("DELETE FROM production_plans");
        jdbc.update("DELETE FROM sales_order_items");
        jdbc.update("DELETE FROM sales_orders");
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
                INSERT INTO plan_order_item_links(
                    plan_item_id, order_item_id, allocated_qty, produced_qty
                ) VALUES (?, ?, 70, 20)
                """, PLAN_ITEM_ID, ORDER_ITEM_ONE_ID);
        jdbc.update("""
                INSERT INTO plan_order_item_links(
                    plan_item_id, order_item_id, allocated_qty, produced_qty
                ) VALUES (?, ?, 30, 20)
                """, PLAN_ITEM_ID, ORDER_ITEM_TWO_ID);

        service = new ReportablePlanLineQueryService(jdbc);
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
        jdbc.update("""
                UPDATE plan_order_item_links
                SET is_deleted = true, deleted_at = now()
                WHERE plan_item_id = ?
                """, PLAN_ITEM_ID);

        assertTrue(service.list(1, 100, null, null).getItems().isEmpty());
    }

    @Test
    void oneInvalidSalesTargetBlocksTheWholeMergedPlan() {
        jdbc.update(
                "UPDATE sales_order_items SET chain_status = 9 WHERE id = ?",
                ORDER_ITEM_TWO_ID);

        assertTrue(service.list(1, 100, null, null).getItems().isEmpty());
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
}
