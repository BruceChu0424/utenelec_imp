package com.uten.imp.features.production.fulfillment;

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
import java.time.LocalDate;
import java.util.UUID;

import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertTrue;
import static org.junit.jupiter.api.Assertions.fail;

/**
 * PostgreSQL acceptance evidence for V163's purchase receipt provenance.
 */
@EnabledIfEnvironmentVariable(named = "UTEN_RUN_DB_TESTS", matches = "(?i)true")
class ProductionPurchaseReceiptProvenancePostgresTest {

    private static final java.util.concurrent.atomic.AtomicInteger BUSINESS_IDENTIFIER_SEQUENCE =
            new java.util.concurrent.atomic.AtomicInteger();

    private static final LocalDate BILL_DATE = LocalDate.of(2026, 7, 31);
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
    void approvedReceiptPromotesReadyAndUnissuedReverseRemainsAtomic()
            throws Exception {
        try (Connection connection = connection()) {
            Fixture fixture = createFixture(connection);

            assertEquals(
                    "READY",
                    scalarString(
                            connection,
                            "select status from production_execution_segments where id = ?",
                            fixture.segmentId()));
            assertEquals(
                    0,
                    decimal("10").compareTo(
                            scalarDecimal(
                                    connection,
                                    """
                                    select sum(allocated_qty)
                                    from production_material_receipt_allocations
                                    where receipt_item_id = ?
                                      and status = 'EFFECTIVE'
                                    """,
                                    fixture.receiptItemId())));

            reverseUnissuedReceipt(connection, fixture);

            assertEquals(
                    "WAITING",
                    scalarString(
                            connection,
                            "select status from production_execution_segments where id = ?",
                            fixture.segmentId()));
            assertEquals(
                    "REVERSED",
                    scalarString(
                            connection,
                            """
                            select status
                            from production_material_receipt_allocations
                            where id = ?
                            """,
                            fixture.allocationId()));
            assertEquals(
                    -1,
                    scalarInt(
                            connection,
                            "select status from purchase_receipts where id = ?",
                            fixture.receiptId()));
            assertEquals(
                    0,
                    scalarInt(
                            connection,
                            """
                            select count(*)
                            from stock_reservations
                            where id = ? and is_deleted = false
                            """,
                            fixture.reservationId()));
        }
    }

    @Test
    void wrongWarehouseAndReceiptSoftDeleteAreRejected() throws Exception {
        try (Connection connection = connection()) {
            Fixture fixture = createFixture(connection);

            assertDeferredConstraint(
                    connection,
                    "production_receipt_allocation_provenance_guard",
                    null,
                    () -> execute(
                            connection,
                            """
                            update purchase_receipts
                            set warehouse_id = ?
                            where id = ?
                            """,
                            fixture.otherWarehouseId(),
                            fixture.receiptId()));

            assertDeferredConstraint(
                    connection,
                    "production_receipt_allocation_provenance_guard",
                    null,
                    () -> execute(
                            connection,
                            """
                            update purchase_receipts
                            set is_deleted = true
                            where id = ?
                            """,
                            fixture.receiptId()));

            assertDeferredConstraint(
                    connection,
                    "production_purchase_receipt_item_capacity_guard",
                    null,
                    () -> execute(
                            connection,
                            """
                            update purchase_receipt_items
                            set is_deleted = true
                            where id = ?
                            """,
                            fixture.receiptItemId()));
        }
    }

    @Test
    void receiptDimensionAndAggregateCapacityAreRejected() throws Exception {
        try (Connection connection = connection()) {
            Fixture fixture = createFixture(connection);

            assertDeferredConstraint(
                    connection,
                    "production_receipt_allocation_provenance_guard",
                    null,
                    () -> execute(
                            connection,
                            """
                            update purchase_receipt_items
                            set goods_id = ?
                            where id = ?
                            """,
                            fixture.otherGoodsId(),
                            fixture.receiptItemId()));

            assertDeferredConstraint(
                    connection,
                    "production_purchase_receipt_item_capacity_guard",
                    null,
                    () -> execute(
                            connection,
                            """
                            update purchase_receipt_items
                            set qty = 9
                            where id = ?
                            """,
                            fixture.receiptItemId()));
        }
    }

    @Test
    void reservationSegmentAndNakedDemandChangesAreRejected()
            throws Exception {
        try (Connection connection = connection()) {
            Fixture fixture = createFixture(connection);

            assertDeferredConstraint(
                    connection,
                    "production_receipt_allocation_provenance_guard",
                    null,
                    () -> execute(
                            connection,
                            """
                            update stock_reservations
                            set status = 1, consumed_qty = qty
                            where id = ?
                            """,
                            fixture.reservationId()));

            assertDeferredConstraint(
                    connection,
                    "production_receipt_allocation_provenance_guard",
                    "trg_purchase_package_draw_provenance",
                    () -> execute(
                            connection,
                            """
                            update production_planning_package_documents
                            set execution_segment_id = null
                            where package_id = ?
                              and document_type = 'DRAW'
                              and document_id = ?
                            """,
                            fixture.packageId(),
                            fixture.drawId()));

            assertDeferredConstraint(
                    connection,
                    "production_receipt_allocation_provenance_guard",
                    null,
                    () -> execute(
                            connection,
                            """
                            update production_material_demands
                            set supply_route = 'SUBCONTRACT'
                            where id = ?
                            """,
                            fixture.demandId()));
        }
    }

    private static Fixture createFixture(Connection connection)
            throws Exception {
        UUID unitId = UUID.randomUUID();
        UUID productId = UUID.randomUUID();
        UUID materialId = UUID.randomUUID();
        UUID otherGoodsId = UUID.randomUUID();
        UUID warehouseId = UUID.randomUUID();
        UUID otherWarehouseId = UUID.randomUUID();
        UUID balanceId = UUID.randomUUID();
        UUID planId = UUID.randomUUID();
        UUID planItemId = UUID.randomUUID();
        UUID packageId = UUID.randomUUID();
        UUID segmentId = UUID.randomUUID();
        UUID demandId = UUID.randomUUID();
        UUID orderId = UUID.randomUUID();
        UUID orderItemId = UUID.randomUUID();
        UUID orderPegId = UUID.randomUUID();
        UUID receiptId = UUID.randomUUID();
        UUID receiptItemId = UUID.randomUUID();
        UUID reservationId = UUID.randomUUID();
        UUID drawId = UUID.randomUUID();
        UUID drawItemId = UUID.randomUUID();
        UUID allocationId = UUID.randomUUID();
        String planNo = businessIdentifier("SJ", BILL_DATE);
        String orderNo = businessIdentifier("CD", BILL_DATE);
        String receiptNo = businessIdentifier("CJ", BILL_DATE);
        String drawNo = businessIdentifier("SL", BILL_DATE);

        connection.setAutoCommit(false);
        try {
            execute(
                    connection,
                    "insert into units(id, code, name) values (?, ?, 'piece')",
                    unitId,
                    "UNIT-" + unitId);
            insertGoods(connection, productId);
            insertGoods(connection, materialId);
            insertGoods(connection, otherGoodsId);
            insertWarehouse(connection, warehouseId);
            insertWarehouse(connection, otherWarehouseId);
            execute(
                    connection,
                    """
                    insert into stock_balances(
                        id, warehouse_id, goods_id, qty
                    ) values (?, ?, ?, 10)
                    """,
                    balanceId,
                    warehouseId,
                    materialId);
            execute(
                    connection,
                    """
                    insert into production_plans(
                        id, bill_no, bill_date, delivery_date, status
                    ) values (?, ?, ?, ?, 1)
                    """,
                    planId,
                    planNo,
                    BILL_DATE,
                    BILL_DATE.plusDays(7));
            execute(
                    connection,
                    """
                    insert into production_plan_items(
                        id, bill_no, bill_date, plan_id, line_no,
                        product_no, goods_id, unit_id, unit_rate, qty
                    ) values (?, ?, ?, ?, 1, ?, ?, ?, 1, 10)
                    """,
                    planItemId,
                    planNo,
                    BILL_DATE,
                    planId,
                    "PRODUCT-" + planItemId,
                    productId,
                    unitId);
            execute(
                    connection,
                    """
                    insert into production_planning_packages(
                        id, plan_id, warehouse_id, idempotency_key,
                        request_hash, preview_fingerprint, status,
                        execution_model_version
                    ) values (?, ?, ?, ?, ?, ?, 'CONFIRMED', 1)
                    """,
                    packageId,
                    planId,
                    warehouseId,
                    "package-" + packageId,
                    "a".repeat(64),
                    "b".repeat(64));
            execute(
                    connection,
                    """
                    insert into production_execution_segments(
                        id, package_id, plan_id, source_plan_item_id,
                        segment_no, segment_code, client_segment_key,
                        product_goods_id, product_unit_id, product_unit_rate,
                        planned_qty, status, bom_fingerprint, idempotency_key
                    ) values (
                        ?, ?, ?, ?, 1, ?, ?, ?, ?, 1,
                        10, 'WAITING', ?, ?
                    )
                    """,
                    segmentId,
                    packageId,
                    planId,
                    planItemId,
                    canonicalSegmentCode(segmentId),
                    "CLIENT-" + segmentId,
                    productId,
                    unitId,
                    "c".repeat(64),
                    "segment-" + segmentId);
            execute(
                    connection,
                    """
                    insert into production_material_demands(
                        id, package_id, plan_id, warehouse_id,
                        goods_id, unit_id, required_qty, need_date,
                        supply_route, status, idempotency_key,
                        execution_segment_id, source_plan_item_id,
                        per_product_qty
                    ) values (
                        ?, ?, ?, ?, ?, ?, 10, ?,
                        'BUY', 'WAITING_SUPPLY', ?, ?, ?, 1
                    )
                    """,
                    demandId,
                    packageId,
                    planId,
                    warehouseId,
                    materialId,
                    unitId,
                    BILL_DATE.plusDays(3),
                    "demand-" + demandId,
                    segmentId,
                    planItemId);
            execute(
                    connection,
                    """
                    insert into purchase_orders(
                        id, bill_no, bill_date, warehouse_id, status
                    ) values (?, ?, ?, ?, 1)
                    """,
                    orderId,
                    orderNo,
                    BILL_DATE,
                    warehouseId);
            execute(
                    connection,
                    """
                    insert into purchase_order_items(
                        id, bill_no, bill_date, order_id,
                        goods_id, unit_id, unit_rate, qty,
                        goods_snapshot_source
                    ) values (?, ?, ?, ?, ?, ?, 1, 10, 'MASTER_AT_SAVE')
                    """,
                    orderItemId,
                    orderNo,
                    BILL_DATE,
                    orderId,
                    materialId,
                    unitId);
            execute(
                    connection,
                    """
                    insert into production_material_supply_pegs(
                        id, demand_id, supply_type, supply_item_id,
                        allocated_qty, consumed_qty, released_qty,
                        expected_date, status, idempotency_key
                    ) values (
                        ?, ?, 'PURCHASE_ORDER_ITEM', ?,
                        10, 10, 0, ?, 'DONE', ?
                    )
                    """,
                    orderPegId,
                    demandId,
                    orderItemId,
                    BILL_DATE,
                    "order-peg-" + orderPegId);
            execute(
                    connection,
                    """
                    insert into purchase_receipts(
                        id, bill_no, bill_date, warehouse_id, status
                    ) values (?, ?, ?, ?, 1)
                    """,
                    receiptId,
                    receiptNo,
                    BILL_DATE,
                    warehouseId);
            execute(
                    connection,
                    """
                    insert into purchase_receipt_items(
                        id, bill_no, bill_date, receipt_id,
                        order_item_id, goods_id, unit_id, unit_rate, qty,
                        goods_snapshot_source
                    ) values (?, ?, ?, ?, ?, ?, ?, 1, 10, 'MASTER_AT_SAVE')
                    """,
                    receiptItemId,
                    receiptNo,
                    BILL_DATE,
                    receiptId,
                    orderItemId,
                    materialId,
                    unitId);
            execute(
                    connection,
                    """
                    insert into stock_reservations(
                        id, order_item_id, goods_id, warehouse_id,
                        qty, consumed_qty, released_qty, status, source,
                        source_doc_type, source_doc_id,
                        owner_type, owner_id, purpose, demand_id,
                        supply_type, supply_id, idempotency_key
                    ) values (
                        ?, null, ?, ?, 10, 0, 0, 0, 2,
                        'PURCHASE_RECEIPT', ?,
                        'PRODUCTION_MATERIAL_DEMAND', ?,
                        'PRODUCTION_MATERIAL', ?,
                        'STOCK_BALANCE', ?, ?
                    )
                    """,
                    reservationId,
                    materialId,
                    warehouseId,
                    receiptId,
                    demandId,
                    demandId,
                    balanceId,
                    "reservation-" + reservationId);
            execute(
                    connection,
                    """
                    insert into stock_documents(
                        id, doc_type, bill_no, bill_date,
                        warehouse_id, plan_no, status
                    ) values (?, 'DRAW', ?, ?, ?, ?, 0)
                    """,
                    drawId,
                    drawNo,
                    BILL_DATE,
                    warehouseId,
                    planNo);
            execute(
                    connection,
                    """
                    insert into stock_document_items(
                        id, doc_id, bill_type, bill_no, bill_date,
                        line_no, goods_id, unit_id, unit_rate,
                        qty, base_qty, goods_snapshot_source
                    ) values (?, ?, 'DRAW', ?, ?, 1, ?, ?, 1, 10, 10, 'MASTER_AT_SAVE')
                    """,
                    drawItemId,
                    drawId,
                    drawNo,
                    BILL_DATE,
                    materialId,
                    unitId);
            execute(
                    connection,
                    """
                    insert into production_planning_package_documents(
                        package_id, execution_segment_id,
                        document_type, document_id, document_no
                    ) values (?, ?, 'DRAW', ?, ?)
                    """,
                    packageId,
                    segmentId,
                    drawId,
                    drawNo);
            execute(
                    connection,
                    """
                    insert into production_planning_package_document_items(
                        package_id, demand_id, document_type,
                        document_id, document_item_id
                    ) values (?, ?, 'DRAW', ?, ?)
                    """,
                    packageId,
                    demandId,
                    drawId,
                    drawItemId);
            execute(
                    connection,
                    """
                    insert into plan_draw_links(plan_id, draw_id)
                    values (?, ?)
                    """,
                    planId,
                    drawId);
            execute(
                    connection,
                    """
                    insert into production_material_receipt_allocations(
                        id, receipt_id, receipt_item_id, package_id,
                        demand_id, order_peg_id, reservation_id,
                        draw_id, draw_item_id, allocated_qty,
                        status, idempotency_key
                    ) values (
                        ?, ?, ?, ?, ?, ?, ?, ?, ?, 10,
                        'EFFECTIVE', ?
                    )
                    """,
                    allocationId,
                    receiptId,
                    receiptItemId,
                    packageId,
                    demandId,
                    orderPegId,
                    reservationId,
                    drawId,
                    drawItemId,
                    "receipt-allocation-" + allocationId);
            execute(
                    connection,
                    """
                    update production_material_demands
                    set status = 'ALLOCATED'
                    where id = ?
                    """,
                    demandId);
            execute(
                    connection,
                    """
                    update production_execution_segments
                    set status = 'READY'
                    where id = ?
                    """,
                    segmentId);
            connection.commit();
        } catch (Exception error) {
            connection.rollback();
            throw error;
        } finally {
            connection.setAutoCommit(true);
        }
        return new Fixture(
                otherWarehouseId,
                otherGoodsId,
                balanceId,
                packageId,
                segmentId,
                demandId,
                orderPegId,
                receiptId,
                receiptItemId,
                reservationId,
                drawId,
                drawItemId,
                allocationId);
    }

    private static void reverseUnissuedReceipt(
            Connection connection, Fixture fixture) throws Exception {
        connection.setAutoCommit(false);
        try {
            execute(
                    connection,
                    """
                    update production_execution_segments
                    set status = 'WAITING'
                    where id = ?
                    """,
                    fixture.segmentId());
            execute(
                    connection,
                    """
                    update production_material_demands
                    set status = 'WAITING_SUPPLY'
                    where id = ?
                    """,
                    fixture.demandId());
            execute(
                    connection,
                    """
                    update production_material_receipt_allocations
                    set status = 'REVERSED'
                    where id = ?
                    """,
                    fixture.allocationId());
            execute(
                    connection,
                    """
                    update stock_reservations
                    set released_qty = qty, status = -1,
                        is_deleted = true, deleted_at = now()
                    where id = ?
                    """,
                    fixture.reservationId());
            execute(
                    connection,
                    """
                    update production_material_supply_pegs
                    set consumed_qty = 0, status = 'EFFECTIVE'
                    where id = ?
                    """,
                    fixture.orderPegId());
            execute(
                    connection,
                    """
                    delete from production_planning_package_document_items
                    where document_item_id = ?
                    """,
                    fixture.drawItemId());
            authorizeDrawCleanup(connection, fixture.drawId());
            execute(
                    connection,
                    """
                    update stock_document_items
                    set is_deleted = true
                    where id = ?
                    """,
                    fixture.drawItemId());
            execute(
                    connection,
                    """
                    update stock_documents
                    set status = -1, is_deleted = true, deleted_at = now()
                    where id = ?
                    """,
                    fixture.drawId());
            execute(
                    connection,
                    """
                    update plan_draw_links
                    set is_deleted = true, deleted_at = now()
                    where draw_id = ?
                    """,
                    fixture.drawId());
            execute(
                    connection,
                    """
                    delete from production_planning_package_documents
                    where package_id = ?
                      and document_type = 'DRAW'
                      and document_id = ?
                    """,
                    fixture.packageId(),
                    fixture.drawId());
            execute(
                    connection,
                    "update stock_balances set qty = 0 where id = ?",
                    fixture.balanceId());
            execute(
                    connection,
                    "update purchase_receipts set status = -1 where id = ?",
                    fixture.receiptId());
            connection.commit();
        } catch (Exception error) {
            connection.rollback();
            throw error;
        } finally {
            connection.setAutoCommit(true);
        }
    }

    private static void assertDeferredConstraint(
            Connection connection,
            String expectedConstraint,
            String forceConstraint,
            CheckedRunnable mutation) throws Exception {
        connection.setAutoCommit(false);
        try {
            mutation.run();
            if (forceConstraint != null) {
                if (!"trg_purchase_package_draw_provenance"
                        .equals(forceConstraint)) {
                    throw new IllegalArgumentException(
                            "unsupported constraint trigger");
                }
                execute(
                        connection,
                        "set constraints "
                                + forceConstraint
                                + " immediate");
            }
            connection.commit();
            fail("expected deferred PostgreSQL constraint "
                    + expectedConstraint);
        } catch (PSQLException error) {
            connection.rollback();
            assertEquals(
                    expectedConstraint,
                    error.getServerErrorMessage().getConstraint());
        } finally {
            connection.setAutoCommit(true);
        }
    }

    private static void insertGoods(Connection connection, UUID id)
            throws Exception {
        execute(
                connection,
                """
                insert into goods(id, code, name, min_qty, code_sequence)
                values (?, ?, 'fixture goods', 0,
                        (select coalesce(max(code_sequence), 0) + 1 from goods))
                """,
                id,
                "GOODS-" + id);
    }

    private static void insertWarehouse(Connection connection, UUID id)
            throws Exception {
        execute(
                connection,
                """
                insert into warehouses(id, code, name)
                values (?, ?, 'fixture warehouse')
                """,
                id,
                "WH-" + id);
    }

    private static void authorizeDrawCleanup(
            Connection connection, UUID drawId) throws Exception {
        try (PreparedStatement statement = connection.prepareStatement("""
                select set_config(
                    'app.production_stock_cleanup_doc_id', ?, true)
                """)) {
            statement.setString(1, drawId.toString());
            statement.executeQuery();
        }
    }

    private static void execute(
            Connection connection, String sql, Object... parameters)
            throws Exception {
        try (PreparedStatement statement = connection.prepareStatement(sql)) {
            bind(statement, parameters);
            statement.executeUpdate();
        }
    }

    private static BigDecimal scalarDecimal(
            Connection connection, String sql, Object... parameters)
            throws Exception {
        try (PreparedStatement statement = connection.prepareStatement(sql)) {
            bind(statement, parameters);
            try (ResultSet result = statement.executeQuery()) {
                assertTrue(result.next());
                return result.getBigDecimal(1);
            }
        }
    }

    private static String scalarString(
            Connection connection, String sql, Object parameter)
            throws Exception {
        try (PreparedStatement statement = connection.prepareStatement(sql)) {
            statement.setObject(1, parameter);
            try (ResultSet result = statement.executeQuery()) {
                assertTrue(result.next());
                return result.getString(1);
            }
        }
    }

    private static int scalarInt(
            Connection connection, String sql, Object parameter)
            throws Exception {
        try (PreparedStatement statement = connection.prepareStatement(sql)) {
            statement.setObject(1, parameter);
            try (ResultSet result = statement.executeQuery()) {
                assertTrue(result.next());
                return result.getInt(1);
            }
        }
    }

    private static void bind(
            PreparedStatement statement, Object... parameters)
            throws Exception {
        for (int index = 0; index < parameters.length; index++) {
            statement.setObject(index + 1, parameters[index]);
        }
    }

    private static BigDecimal decimal(String value) {
        return new BigDecimal(value);
    }

    private static String canonicalSegmentCode(UUID segmentId) {
        return "ZX%08d".formatted(
                Math.floorMod(segmentId.hashCode(), 99_999_999) + 1);
    }

    private static String businessIdentifier(String prefix, LocalDate date) {
        int sequence = BUSINESS_IDENTIFIER_SEQUENCE.incrementAndGet();
        if (sequence > 999_999) {
            throw new IllegalStateException("test business identifier sequence exhausted");
        }
        return prefix + date.toString().replace("-", "") + "%06d".formatted(sequence);
    }

    private static Connection connection() throws Exception {
        return DriverManager.getConnection(
                POSTGRES.getJdbcUrl(),
                POSTGRES.getUsername(),
                POSTGRES.getPassword());
    }

    @FunctionalInterface
    private interface CheckedRunnable {
        void run() throws Exception;
    }

    private record Fixture(
            UUID otherWarehouseId,
            UUID otherGoodsId,
            UUID balanceId,
            UUID packageId,
            UUID segmentId,
            UUID demandId,
            UUID orderPegId,
            UUID receiptId,
            UUID receiptItemId,
            UUID reservationId,
            UUID drawId,
            UUID drawItemId,
            UUID allocationId) {}
}
