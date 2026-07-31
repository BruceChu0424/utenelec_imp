package com.uten.imp.features.sales.order;

import com.uten.imp.common.web.ApiException;
import com.uten.imp.common.web.ErrorCode;
import com.uten.imp.features.sales.order.dto.OrderChangeQtyRequest;
import jakarta.persistence.EntityManager;
import jakarta.persistence.Query;
import org.flywaydb.core.Flyway;
import org.junit.jupiter.api.AfterAll;
import org.junit.jupiter.api.BeforeAll;
import org.junit.jupiter.api.Test;
import org.junit.jupiter.api.condition.EnabledIfEnvironmentVariable;
import org.postgresql.util.PSQLException;
import org.testcontainers.containers.PostgreSQLContainer;

import java.lang.reflect.InvocationTargetException;
import java.math.BigDecimal;
import java.sql.Connection;
import java.sql.DriverManager;
import java.sql.PreparedStatement;
import java.sql.ResultSet;
import java.time.LocalDate;
import java.util.List;
import java.util.Map;
import java.util.UUID;

import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertInstanceOf;
import static org.junit.jupiter.api.Assertions.assertThrows;
import static org.junit.jupiter.api.Assertions.assertTrue;
import static org.mockito.ArgumentMatchers.anyString;
import static org.mockito.Mockito.mock;
import static org.mockito.Mockito.when;

/**
 * PostgreSQL acceptance evidence for V157 exact segment-to-sales ownership.
 */
@EnabledIfEnvironmentVariable(named = "UTEN_RUN_DB_TESTS", matches = "(?i)true")
class ExecutionSegmentSalesAllocationPostgresTest {

    private static final String CHECK_VIOLATION = "23514";
    private static final PostgreSQLContainer<?> POSTGRES =
            new PostgreSQLContainer<>("postgres:16-alpine")
                    .withDatabaseName("uten_imp")
                    .withUsername("uten")
                    .withPassword("uten");

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
    static void stopPostgres() {
        POSTGRES.stop();
    }

    @Test
    void twoSegmentsArePartitionedAcrossTwoSalesLinesWithoutCartesianLeak()
            throws Exception {
        try (Connection connection = connection()) {
            Fixture fixture = fixture(connection);
            Allocations allocations = persistValidAllocations(
                    connection, fixture);

            assertQuantity(connection, """
                    SELECT allocated_qty
                    FROM execution_segment_sales_allocations
                    WHERE id = ?
                    """, allocations.segmentOneOrderOne(), "6");
            assertQuantity(connection, """
                    SELECT allocated_qty
                    FROM execution_segment_sales_allocations
                    WHERE id = ?
                    """, allocations.segmentTwoOrderOne(), "1");
            assertQuantity(connection, """
                    SELECT allocated_qty
                    FROM execution_segment_sales_allocations
                    WHERE id = ?
                    """, allocations.segmentTwoOrderTwo(), "3");
            assertQuantity(connection, """
                    SELECT COUNT(*)
                    FROM execution_segment_sales_allocations
                    WHERE execution_segment_id = ?
                      AND sales_order_item_id = ?
                    """, fixture.segmentOne(), fixture.orderItemTwo(), "0");
        }
    }

    @Test
    void reportAndFinishedInboundAreCappedByTheExactSalesAllocation()
            throws Exception {
        try (Connection connection = connection()) {
            Fixture fixture = fixture(connection);
            Allocations allocations = persistValidAllocations(
                    connection, fixture);

            UUID report = insertReport(
                    connection,
                    fixture,
                    allocations.segmentOneOrderOne(),
                    fixture.segmentOne(),
                    fixture.orderItemOne(),
                    "6",
                    (short) 1);
            assertQuantity(connection, """
                    SELECT SUM(item.qty)
                    FROM production_daily_report_items item
                    WHERE item.report_id = ?
                    """, report, "6");

            connection.setAutoCommit(false);
            insertReport(
                    connection,
                    fixture,
                    allocations.segmentOneOrderOne(),
                    fixture.segmentOne(),
                    fixture.orderItemOne(),
                    "0.1",
                    (short) 0);
            PSQLException overReport =
                    assertThrows(PSQLException.class, connection::commit);
            assertEquals(CHECK_VIOLATION, overReport.getSQLState());
            assertEquals(
                    "daily_report_segment_sales_capacity_guard",
                    overReport.getServerErrorMessage().getConstraint());
            connection.rollback();
            connection.setAutoCommit(true);

            insertFinishedIn(
                    connection,
                    fixture,
                    allocations.segmentOneOrderOne(),
                    fixture.segmentOne(),
                    "6");

            connection.setAutoCommit(false);
            insertFinishedIn(
                    connection,
                    fixture,
                    allocations.segmentOneOrderOne(),
                    fixture.segmentOne(),
                    "0.1");
            PSQLException overInbound =
                    assertThrows(PSQLException.class, connection::commit);
            assertEquals(CHECK_VIOLATION, overInbound.getSQLState());
            assertEquals(
                    "finished_in_segment_sales_report_guard",
                    overInbound.getServerErrorMessage().getConstraint());
            connection.rollback();
        }
    }

    @Test
    void deletingOneOfSeveralSalesLinksFailsClosed() throws Exception {
        try (Connection connection = connection()) {
            Fixture fixture = fixture(connection);
            persistValidAllocations(connection, fixture);

            connection.setAutoCommit(false);
            update(connection, """
                    UPDATE plan_order_item_links
                    SET is_deleted = TRUE, deleted_at = now()
                    WHERE id = ?
                    """, fixture.linkTwo());
            PSQLException error =
                    assertThrows(PSQLException.class, connection::commit);
            assertEquals(CHECK_VIOLATION, error.getSQLState());
            assertEquals(
                    "execution_segment_sales_allocation_link_identity_guard",
                    error.getServerErrorMessage().getConstraint());
            connection.rollback();
        }
    }

    @Test
    void shrinkingAFrozenPlanLinkFailsAtTheDatabaseBoundary()
            throws Exception {
        try (Connection connection = connection()) {
            Fixture fixture = fixture(connection);
            persistValidAllocations(connection, fixture);

            connection.setAutoCommit(false);
            update(connection, """
                    UPDATE plan_order_item_links
                    SET allocated_qty = 6
                    WHERE id = ?
                    """, fixture.linkOne());
            PSQLException error =
                    assertThrows(PSQLException.class, connection::commit);
            assertEquals(CHECK_VIOLATION, error.getSQLState());
            assertEquals(
                    "execution_segment_sales_link_capacity_guard",
                    error.getServerErrorMessage().getConstraint());
            connection.rollback();
        }
    }

    @Test
    void salesChangeQuantityUsesA409FrozenAllocationGate() throws Exception {
        EntityManager em = mock(EntityManager.class);
        Query query = mock(Query.class);
        when(em.createNativeQuery(anyString())).thenReturn(query);
        when(query.setParameter(
                anyString(),
                org.mockito.ArgumentMatchers.any())).thenReturn(query);
        when(query.getSingleResult()).thenReturn(1L);

        SalesOrderService service = new SalesOrderService(
                null, null, null, null, null, null, null, null, null,
                null, null, null, null, em, null, null);
        UUID orderItemId = UUID.randomUUID();
        SalesOrderItem item = new SalesOrderItem();
        item.setQty(new BigDecimal("10"));
        OrderChangeQtyRequest.Line line = new OrderChangeQtyRequest.Line();
        line.setOrderItemId(orderItemId);
        line.setNewQty(new BigDecimal("9"));
        OrderChangeQtyRequest request = new OrderChangeQtyRequest();
        request.setItems(List.of(line));

        var method = SalesOrderService.class.getDeclaredMethod(
                "requireNoFrozenExecutionAllocationDecrease",
                OrderChangeQtyRequest.class,
                Map.class);
        method.setAccessible(true);
        InvocationTargetException invocation = assertThrows(
                InvocationTargetException.class,
                () -> method.invoke(
                        service, request, Map.of(orderItemId, item)));
        ApiException error = assertInstanceOf(
                ApiException.class, invocation.getCause());
        assertEquals(ErrorCode.CONFLICT, error.getCode());
        assertEquals(409, error.getCode().getHttpStatus());
        assertTrue(error.getMessage().contains("\u6267\u884c\u8ba1\u5212\u5305"));
    }

    private static Fixture fixture(Connection connection) throws Exception {
        UUID plan = UUID.randomUUID();
        UUID planItem = UUID.randomUUID();
        UUID warehouse = UUID.randomUUID();
        UUID goods = UUID.randomUUID();
        UUID unit = UUID.randomUUID();
        UUID packageId = UUID.randomUUID();
        UUID orderOne = UUID.randomUUID();
        UUID orderTwo = UUID.randomUUID();
        UUID orderItemOne = UUID.randomUUID();
        UUID orderItemTwo = UUID.randomUUID();
        UUID linkOne = UUID.randomUUID();
        UUID linkTwo = UUID.randomUUID();
        UUID segmentOne = UUID.randomUUID();
        UUID segmentTwo = UUID.randomUUID();

        update(connection, "SET session_replication_role = replica");
        insert(connection, """
                INSERT INTO goods(id, code, name)
                VALUES(?, ?, 'V157 test product')
                """, goods, "V157-G-" + goods);
        insert(connection, """
                INSERT INTO units(id, code, name)
                VALUES(?, ?, 'V157 test unit')
                """, unit, "V157-U-" + unit);
        insert(connection, """
                INSERT INTO warehouses(id, code, name)
                VALUES(?, ?, 'V157 test warehouse')
                """, warehouse, "V157-W-" + warehouse);
        insert(connection, """
                INSERT INTO production_plans(
                    id,bill_no,bill_date,status
                ) VALUES(?,?,?,1)
                """, plan, "PLAN-" + plan, LocalDate.of(2026, 7, 31));
        insert(connection, """
                INSERT INTO production_plan_items(
                    id,bill_no,bill_date,plan_id,product_no,
                    goods_id,unit_id,unit_rate,qty,fqty,iqty
                ) VALUES(?,?,?,?,?,?,?,1,10,0,0)
                """, planItem, "PLAN-" + plan,
                LocalDate.of(2026, 7, 31), plan,
                "PRODUCT-" + planItem, goods, unit);
        insertOrder(
                connection, orderOne, orderItemOne, goods, unit,
                "SO-1-" + orderOne);
        insertOrder(
                connection, orderTwo, orderItemTwo, goods, unit,
                "SO-2-" + orderTwo);
        insert(connection, """
                INSERT INTO plan_order_item_links(
                    id,plan_item_id,order_item_id,allocated_qty,
                    produced_qty,inbound_qty
                ) VALUES(?,?,?,7,0,0)
                """, linkOne, planItem, orderItemOne);
        insert(connection, """
                INSERT INTO plan_order_item_links(
                    id,plan_item_id,order_item_id,allocated_qty,
                    produced_qty,inbound_qty
                ) VALUES(?,?,?,3,0,0)
                """, linkTwo, planItem, orderItemTwo);
        insert(connection, """
                INSERT INTO production_planning_packages(
                    id,plan_id,warehouse_id,idempotency_key,
                    request_hash,preview_fingerprint,status,
                    execution_model_version
                ) VALUES(?,?,?,'package-key',?,?,'CONFIRMED',1)
                """, packageId, plan, warehouse,
                "a".repeat(64), "b".repeat(64));
        insertSegment(
                connection, segmentOne, packageId, plan, planItem,
                goods, unit, 1, "6");
        insertSegment(
                connection, segmentTwo, packageId, plan, planItem,
                goods, unit, 2, "4");
        update(connection, "SET session_replication_role = origin");
        return new Fixture(
                plan, planItem, warehouse, goods, unit, packageId,
                orderItemOne, orderItemTwo, linkOne, linkTwo,
                segmentOne, segmentTwo);
    }

    private static Allocations persistValidAllocations(
            Connection connection, Fixture fixture) throws Exception {
        UUID segmentOneOrderOne = UUID.randomUUID();
        UUID segmentTwoOrderOne = UUID.randomUUID();
        UUID segmentTwoOrderTwo = UUID.randomUUID();
        connection.setAutoCommit(false);
        insertAllocation(
                connection, segmentOneOrderOne, fixture.segmentOne(),
                fixture.linkOne(), fixture.orderItemOne(), "6");
        insertAllocation(
                connection, segmentTwoOrderOne, fixture.segmentTwo(),
                fixture.linkOne(), fixture.orderItemOne(), "1");
        insertAllocation(
                connection, segmentTwoOrderTwo, fixture.segmentTwo(),
                fixture.linkTwo(), fixture.orderItemTwo(), "3");
        connection.commit();
        connection.setAutoCommit(true);
        return new Allocations(
                segmentOneOrderOne,
                segmentTwoOrderOne,
                segmentTwoOrderTwo);
    }

    private static void insertOrder(
            Connection connection,
            UUID orderId,
            UUID orderItemId,
            UUID goods,
            UUID unit,
            String billNo) throws Exception {
        insert(connection, """
                INSERT INTO sales_orders(
                    id,bill_no,bill_date,client_id,status
                ) VALUES(?,?,?,?,1)
                """, orderId, billNo, LocalDate.of(2026, 7, 31),
                UUID.randomUUID());
        insert(connection, """
                INSERT INTO sales_order_items(
                    id,bill_no,bill_date,order_id,goods_id,
                    unit_id,unit_rate,qty,chain_status
                ) VALUES(?,?,?,?,?,?,1,10,4)
                """, orderItemId, billNo,
                LocalDate.of(2026, 7, 31), orderId, goods, unit);
    }

    private static void insertSegment(
            Connection connection,
            UUID segment,
            UUID packageId,
            UUID plan,
            UUID planItem,
            UUID goods,
            UUID unit,
            int number,
            String quantity) throws Exception {
        insert(connection, """
                INSERT INTO production_execution_segments(
                    id,package_id,plan_id,source_plan_item_id,
                    segment_no,segment_code,client_segment_key,
                    product_goods_id,product_unit_id,product_unit_rate,
                    planned_qty,status,bom_fingerprint,idempotency_key
                ) VALUES(?,?,?,?,?,?,?,?,?,1,?,'IN_PROGRESS',?,?)
                """, segment, packageId, plan, planItem, number,
                "SEG-" + number + "-" + segment,
                "client-" + segment,
                goods, unit, new BigDecimal(quantity),
                "c".repeat(64), "segment-" + segment);
    }

    private static void insertAllocation(
            Connection connection,
            UUID id,
            UUID segment,
            UUID link,
            UUID orderItem,
            String quantity) throws Exception {
        insert(connection, """
                INSERT INTO execution_segment_sales_allocations(
                    id,execution_segment_id,plan_order_item_link_id,
                    sales_order_item_id,allocated_qty
                ) VALUES(?,?,?,?,?)
                """, id, segment, link, orderItem,
                new BigDecimal(quantity));
    }

    private static UUID insertReport(
            Connection connection,
            Fixture fixture,
            UUID allocation,
            UUID segment,
            UUID orderItem,
            String quantity,
            short status) throws Exception {
        UUID report = UUID.randomUUID();
        insert(connection, """
                INSERT INTO production_daily_reports(
                    id,bill_no,bill_date,status
                ) VALUES(?,?,?,?)
                """, report, "RP-" + report,
                LocalDate.of(2026, 7, 31), status);
        insert(connection, """
                INSERT INTO production_daily_report_items(
                    id,bill_no,bill_date,report_id,line_no,
                    goods_id,unit_id,unit_rate,qty,
                    sales_order_item_id,plan_item_id,
                    execution_segment_id,
                    execution_segment_sales_allocation_id
                ) VALUES(?,?,?,?,1,?,?,1,?,?,?,?,?)
                """, UUID.randomUUID(), "RP-" + report,
                LocalDate.of(2026, 7, 31), report,
                fixture.goods(), fixture.unit(),
                new BigDecimal(quantity), orderItem,
                fixture.planItem(), segment, allocation);
        if (connection.getAutoCommit()) {
            // Force all deferred V157 constraints before returning.
            connection.setAutoCommit(false);
            connection.commit();
            connection.setAutoCommit(true);
        }
        return report;
    }

    private static void insertFinishedIn(
            Connection connection,
            Fixture fixture,
            UUID allocation,
            UUID segment,
            String quantity) throws Exception {
        UUID document = UUID.randomUUID();
        insert(connection, """
                INSERT INTO stock_documents(
                    id,doc_type,bill_no,bill_date,warehouse_id,status
                ) VALUES(?,'FINISHED_IN',?,?,?,1)
                """, document, "FI-" + document,
                LocalDate.of(2026, 7, 31), fixture.warehouse());
        insert(connection, """
                INSERT INTO stock_document_items(
                    id,doc_id,bill_type,bill_no,bill_date,line_no,
                    goods_id,unit_id,unit_rate,qty,base_qty,
                    upstream_item_id,execution_segment_id,
                    execution_segment_sales_allocation_id
                ) VALUES(?,?,'FINISHED_IN',?,?,1,?,?,1,?,?,?, ?,?)
                """, UUID.randomUUID(), document, "FI-" + document,
                LocalDate.of(2026, 7, 31),
                fixture.goods(), fixture.unit(),
                new BigDecimal(quantity), new BigDecimal(quantity),
                fixture.planItem(), segment, allocation);
        if (connection.getAutoCommit()) {
            connection.setAutoCommit(false);
            connection.commit();
            connection.setAutoCommit(true);
        }
    }

    private static Connection connection() throws Exception {
        return DriverManager.getConnection(
                POSTGRES.getJdbcUrl(),
                POSTGRES.getUsername(),
                POSTGRES.getPassword());
    }

    private static void insert(
            Connection connection, String sql, Object... args)
            throws Exception {
        try (PreparedStatement statement =
                     connection.prepareStatement(sql)) {
            for (int index = 0; index < args.length; index++) {
                statement.setObject(index + 1, args[index]);
            }
            statement.executeUpdate();
        }
    }

    private static void update(
            Connection connection, String sql, Object... args)
            throws Exception {
        insert(connection, sql, args);
    }

    private static void assertQuantity(
            Connection connection,
            String sql,
            UUID id,
            String expected) throws Exception {
        try (PreparedStatement statement =
                     connection.prepareStatement(sql)) {
            statement.setObject(1, id);
            try (ResultSet result = statement.executeQuery()) {
                assertTrue(result.next());
                assertEquals(
                        0,
                        new BigDecimal(expected).compareTo(
                                result.getBigDecimal(1)));
            }
        }
    }

    private static void assertQuantity(
            Connection connection,
            String sql,
            UUID first,
            UUID second,
            String expected) throws Exception {
        try (PreparedStatement statement =
                     connection.prepareStatement(sql)) {
            statement.setObject(1, first);
            statement.setObject(2, second);
            try (ResultSet result = statement.executeQuery()) {
                assertTrue(result.next());
                assertEquals(
                        0,
                        new BigDecimal(expected).compareTo(
                                result.getBigDecimal(1)));
            }
        }
    }

    private record Fixture(
            UUID plan,
            UUID planItem,
            UUID warehouse,
            UUID goods,
            UUID unit,
            UUID packageId,
            UUID orderItemOne,
            UUID orderItemTwo,
            UUID linkOne,
            UUID linkTwo,
            UUID segmentOne,
            UUID segmentTwo) {
    }

    private record Allocations(
            UUID segmentOneOrderOne,
            UUID segmentTwoOrderOne,
            UUID segmentTwoOrderTwo) {
    }
}
