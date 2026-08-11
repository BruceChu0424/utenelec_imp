package com.uten.imp.features.production.mrp;

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
import java.time.Duration;
import java.time.LocalDate;
import java.util.UUID;
import java.util.concurrent.CountDownLatch;
import java.util.concurrent.ExecutorService;
import java.util.concurrent.Executors;
import java.util.concurrent.Future;
import java.util.concurrent.TimeUnit;

import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertFalse;
import static org.junit.jupiter.api.Assertions.assertThrows;
import static org.junit.jupiter.api.Assertions.assertTrue;
import static org.junit.jupiter.api.Assertions.assertTimeoutPreemptively;

/**
 * Real PostgreSQL acceptance evidence for V150's production material demand,
 * physical stock allocation and explicit purchase/subcontract supply pegs.
 */
@EnabledIfEnvironmentVariable(named = "UTEN_RUN_DB_TESTS", matches = "(?i)true")
class ProductionMaterialFulfillmentPostgresTest {

    private static final String CAPACITY_SQL_STATE = "23514";
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
    void nakedPurchaseOrderPegConsumptionIsRejectedAtCommit() {
        assertTimeoutPreemptively(Duration.ofSeconds(15), () -> {
            try (Connection connection = connection()) {
                Inventory inventory = createInventory(connection, "10");
                Demand demand = createDemand(connection, inventory, "10");
                UUID orderItemId =
                        createPurchaseOrderSource(connection, inventory, "10");
                UUID pegId = insertPeg(
                        connection,
                        demand.id(),
                        "PURCHASE_ORDER_ITEM",
                        orderItemId,
                        "10",
                        "0",
                        "0",
                        "EFFECTIVE");

                connection.setAutoCommit(false);
                try (PreparedStatement consume = connection.prepareStatement("""
                        update production_material_supply_pegs
                        set consumed_qty = 10, status = 'DONE'
                        where id = ?
                        """)) {
                    consume.setObject(1, pegId);
                    consume.executeUpdate();
                }
                PSQLException error = assertThrows(
                        PSQLException.class, connection::commit);
                assertEquals(
                        "production_purchase_peg_receipt_coverage_guard",
                        error.getServerErrorMessage().getConstraint());
                connection.rollback();
                connection.setAutoCommit(true);

                assertQuantity(
                        connection,
                        """
                        select consumed_qty
                        from production_material_supply_pegs
                        where id = ?
                        """,
                        pegId,
                        "0");
            }
        });
    }

    @Test
    void stockAndSupplyPegCapacityIsSymmetricForBothInsertOrders() {
        assertTimeoutPreemptively(Duration.ofSeconds(15), () -> {
            try (Connection connection = connection()) {
                Inventory pegFirstInventory = createInventory(connection, "20");
                Demand pegFirstDemand = createDemand(connection, pegFirstInventory, "10");
                UUID pegFirstSource = createPurchaseSource(connection, pegFirstInventory, "10");
                insertPeg(
                        connection,
                        pegFirstDemand.id(),
                        pegFirstSource,
                        "6",
                        "0",
                        "0",
                        "EFFECTIVE");
                assertCapacityViolation(() -> insertStockReservation(
                        connection, pegFirstDemand, pegFirstInventory, "5"));

                Inventory stockFirstInventory = createInventory(connection, "20");
                Demand stockFirstDemand = createDemand(connection, stockFirstInventory, "10");
                UUID stockFirstSource = createPurchaseSource(connection, stockFirstInventory, "10");
                insertStockReservation(
                        connection, stockFirstDemand, stockFirstInventory, "6");
                assertCapacityViolation(() -> insertPeg(
                        connection,
                        stockFirstDemand.id(),
                        stockFirstSource,
                        "5",
                        "0",
                        "0",
                        "EFFECTIVE"));

                assertDemandCommitment(connection, pegFirstDemand.id(), "6");
                assertDemandCommitment(connection, stockFirstDemand.id(), "6");
            }
        });
    }

    @Test
    void competingDemandsCannotOverAllocateOnePhysicalStockBalance() {
        assertTimeoutPreemptively(Duration.ofSeconds(20), () -> {
            Inventory inventory;
            Demand firstDemand;
            Demand secondDemand;
            try (Connection setup = connection()) {
                inventory = createInventory(setup, "100");
                firstDemand = createDemand(setup, inventory, "70");
                secondDemand = createDemand(setup, inventory, "70");
            }

            CountDownLatch firstInserted = new CountDownLatch(1);
            CountDownLatch allowFirstCommit = new CountDownLatch(1);
            CountDownLatch secondStarted = new CountDownLatch(1);
            CountDownLatch secondFinished = new CountDownLatch(1);

            try (ExecutorService executor = Executors.newFixedThreadPool(2)) {
                Future<Boolean> first = executor.submit(() -> {
                    try (Connection connection = connection()) {
                        connection.setAutoCommit(false);
                        try {
                            insertStockReservation(
                                    connection, firstDemand, inventory, "70");
                            firstInserted.countDown();
                            assertTrue(allowFirstCommit.await(5, TimeUnit.SECONDS));
                            connection.commit();
                            return true;
                        } catch (Throwable error) {
                            connection.rollback();
                            firstInserted.countDown();
                            throw error;
                        }
                    }
                });

                assertTrue(firstInserted.await(5, TimeUnit.SECONDS));
                Future<String> second = executor.submit(() -> {
                    try (Connection connection = connection()) {
                        connection.setAutoCommit(false);
                        secondStarted.countDown();
                        try {
                            insertStockReservation(
                                    connection, secondDemand, inventory, "70");
                            connection.commit();
                            return "inserted";
                        } catch (PSQLException error) {
                            connection.rollback();
                            return error.getSQLState();
                        } finally {
                            secondFinished.countDown();
                        }
                    }
                });

                assertTrue(secondStarted.await(5, TimeUnit.SECONDS));
                assertFalse(
                        secondFinished.await(500, TimeUnit.MILLISECONDS),
                        "the competing allocation must wait for the same inventory key");

                allowFirstCommit.countDown();
                assertTrue(first.get(5, TimeUnit.SECONDS));
                assertEquals(CAPACITY_SQL_STATE, second.get(5, TimeUnit.SECONDS));
            } finally {
                allowFirstCommit.countDown();
            }

            try (Connection verification = connection()) {
                assertQuantity(
                        verification,
                        """
                        select coalesce(sum(qty - released_qty), 0)
                        from stock_reservations
                        where owner_type = 'PRODUCTION_MATERIAL_DEMAND'
                          and warehouse_id = ?
                          and goods_id = ?
                          and is_deleted = false
                        """,
                        inventory.warehouseId(),
                        inventory.goodsId(),
                        "70");
                assertQuantity(
                        verification,
                        """
                        select available_qty
                        from v_stock_available
                        where warehouse_id = ? and goods_id = ?
                        """,
                        inventory.warehouseId(),
                        inventory.goodsId(),
                        "30");
            }
        });
    }

    private static Inventory createInventory(Connection connection, String stockQty)
            throws Exception {
        UUID warehouseId = UUID.randomUUID();
        UUID goodsId = UUID.randomUUID();
        UUID unitId = UUID.randomUUID();
        UUID balanceId = UUID.randomUUID();

        try (PreparedStatement unit = connection.prepareStatement("""
                insert into units(id, code, name)
                values (?, ?, 'piece')
                """);
             PreparedStatement goods = connection.prepareStatement("""
                     insert into goods(id, code, name, min_qty)
                     values (?, ?, 'fixture material', 0)
                     """);
             PreparedStatement warehouse = connection.prepareStatement("""
                     insert into warehouses(id, code, name)
                     values (?, ?, 'fixture warehouse')
                     """);
             PreparedStatement balance = connection.prepareStatement("""
                     insert into stock_balances(id, warehouse_id, goods_id, qty)
                     values (?, ?, ?, ?)
                     """)) {
            unit.setObject(1, unitId);
            unit.setString(2, "UNIT-" + unitId);
            unit.executeUpdate();

            goods.setObject(1, goodsId);
            goods.setString(2, "GOODS-" + goodsId);
            goods.executeUpdate();

            warehouse.setObject(1, warehouseId);
            warehouse.setString(2, "WH-" + warehouseId);
            warehouse.executeUpdate();

            balance.setObject(1, balanceId);
            balance.setObject(2, warehouseId);
            balance.setObject(3, goodsId);
            balance.setBigDecimal(4, decimal(stockQty));
            balance.executeUpdate();
        }
        return new Inventory(warehouseId, goodsId, unitId, balanceId);
    }

    private static Demand createDemand(
            Connection connection, Inventory inventory, String requiredQty)
            throws Exception {
        UUID planId = UUID.randomUUID();
        UUID packageId = UUID.randomUUID();
        UUID demandId = UUID.randomUUID();
        LocalDate needDate = LocalDate.of(2026, 8, 1)
                .plusDays(Math.abs(demandId.getLeastSignificantBits() % 1000));

        try (PreparedStatement plan = connection.prepareStatement("""
                insert into production_plans(id, bill_no, bill_date, status)
                values (?, ?, ?, 1)
                """);
             PreparedStatement planningPackage = connection.prepareStatement("""
                     insert into production_planning_packages(
                         id, plan_id, warehouse_id, idempotency_key,
                         request_hash, preview_fingerprint, status
                     )
                     values (?, ?, ?, ?, ?, ?, 'CONFIRMED')
                     """);
             PreparedStatement demand = connection.prepareStatement("""
                     insert into production_material_demands(
                         id, package_id, plan_id, warehouse_id,
                         goods_id, unit_id, required_qty, need_date,
                         supply_route, status, idempotency_key
                     )
                     values (?, ?, ?, ?, ?, ?, ?, ?, 'BUY', 'OPEN', ?)
                     """)) {
            plan.setObject(1, planId);
            plan.setString(2, "PP-" + planId);
            plan.setObject(3, LocalDate.of(2026, 7, 31));
            plan.executeUpdate();

            planningPackage.setObject(1, packageId);
            planningPackage.setObject(2, planId);
            planningPackage.setObject(3, inventory.warehouseId());
            planningPackage.setString(4, "package-" + packageId);
            planningPackage.setString(5, "a".repeat(64));
            planningPackage.setString(6, "b".repeat(64));
            planningPackage.executeUpdate();

            demand.setObject(1, demandId);
            demand.setObject(2, packageId);
            demand.setObject(3, planId);
            demand.setObject(4, inventory.warehouseId());
            demand.setObject(5, inventory.goodsId());
            demand.setObject(6, inventory.unitId());
            demand.setBigDecimal(7, decimal(requiredQty));
            demand.setObject(8, needDate);
            demand.setString(9, "demand-" + demandId);
            demand.executeUpdate();
        }
        return new Demand(demandId, packageId);
    }

    private static UUID createPurchaseSource(
            Connection connection, Inventory inventory, String qty)
            throws Exception {
        UUID requestId = UUID.randomUUID();
        UUID itemId = UUID.randomUUID();
        LocalDate billDate = LocalDate.of(2026, 7, 31);
        String billNo = "PR-" + requestId;

        try (PreparedStatement request = connection.prepareStatement("""
                insert into purchase_requests(id, bill_no, bill_date, status)
                values (?, ?, ?, 1)
                """);
             PreparedStatement item = connection.prepareStatement("""
                     insert into purchase_request_items(
                         id, bill_no, bill_date, request_id,
                         goods_id, unit_id, unit_rate, qty
                     )
                     values (?, ?, ?, ?, ?, ?, 1, ?)
                     """)) {
            request.setObject(1, requestId);
            request.setString(2, billNo);
            request.setObject(3, billDate);
            request.executeUpdate();

            item.setObject(1, itemId);
            item.setString(2, billNo);
            item.setObject(3, billDate);
            item.setObject(4, requestId);
            item.setObject(5, inventory.goodsId());
            item.setObject(6, inventory.unitId());
            item.setBigDecimal(7, decimal(qty));
            item.executeUpdate();
        }
        return itemId;
    }

    private static UUID createPurchaseOrderSource(
            Connection connection, Inventory inventory, String qty)
            throws Exception {
        UUID orderId = UUID.randomUUID();
        UUID itemId = UUID.randomUUID();
        LocalDate billDate = LocalDate.of(2026, 7, 31);
        String billNo = "PO-" + orderId;
        try (PreparedStatement order = connection.prepareStatement("""
                insert into purchase_orders(
                    id, bill_no, bill_date, status, warehouse_id
                ) values (?, ?, ?, 1, ?)
                """);
             PreparedStatement item = connection.prepareStatement("""
                     insert into purchase_order_items(
                         id, bill_no, bill_date, order_id,
                         goods_id, unit_id, unit_rate, qty
                     ) values (?, ?, ?, ?, ?, ?, 1, ?)
                     """)) {
            order.setObject(1, orderId);
            order.setString(2, billNo);
            order.setObject(3, billDate);
            order.setObject(4, inventory.warehouseId());
            order.executeUpdate();

            item.setObject(1, itemId);
            item.setString(2, billNo);
            item.setObject(3, billDate);
            item.setObject(4, orderId);
            item.setObject(5, inventory.goodsId());
            item.setObject(6, inventory.unitId());
            item.setBigDecimal(7, decimal(qty));
            item.executeUpdate();
        }
        return itemId;
    }

    private static void insertPeg(
            Connection connection,
            UUID demandId,
            UUID sourceItemId,
            String allocatedQty,
            String consumedQty,
            String releasedQty,
            String status) throws Exception {
        insertPeg(
                connection, demandId, "PURCHASE_REQUEST_ITEM", sourceItemId,
                allocatedQty, consumedQty, releasedQty, status);
    }

    private static UUID insertPeg(
            Connection connection,
            UUID demandId,
            String supplyType,
            UUID sourceItemId,
            String allocatedQty,
            String consumedQty,
            String releasedQty,
            String status) throws Exception {
        UUID id = UUID.randomUUID();
        try (PreparedStatement statement = connection.prepareStatement("""
                insert into production_material_supply_pegs(
                    id, demand_id, supply_type, supply_item_id,
                    allocated_qty, consumed_qty, released_qty,
                    status, idempotency_key
                )
                values (?, ?, ?, ?, ?, ?, ?, ?, ?)
                """)) {
            statement.setObject(1, id);
            statement.setObject(2, demandId);
            statement.setString(3, supplyType);
            statement.setObject(4, sourceItemId);
            statement.setBigDecimal(5, decimal(allocatedQty));
            statement.setBigDecimal(6, decimal(consumedQty));
            statement.setBigDecimal(7, decimal(releasedQty));
            statement.setString(8, status);
            statement.setString(9, "peg-" + id);
            statement.executeUpdate();
        }
        return id;
    }

    private static void insertStockReservation(
            Connection connection,
            Demand demand,
            Inventory inventory,
            String qty) throws Exception {
        UUID id = UUID.randomUUID();
        try (PreparedStatement statement = connection.prepareStatement("""
                insert into stock_reservations(
                    id, order_item_id, goods_id, color_id, warehouse_id,
                    qty, consumed_qty, released_qty, status, source,
                    source_doc_type, source_doc_id,
                    owner_type, owner_id, purpose, demand_id,
                    supply_type, supply_id, idempotency_key
                )
                values (
                    ?, null, ?, null, ?,
                    ?, 0, 0, 0, 0,
                    'PRODUCTION_PLANNING_PACKAGE', ?,
                    'PRODUCTION_MATERIAL_DEMAND', ?, 'PRODUCTION_MATERIAL', ?,
                    'STOCK_BALANCE', ?, ?
                )
                """)) {
            statement.setObject(1, id);
            statement.setObject(2, inventory.goodsId());
            statement.setObject(3, inventory.warehouseId());
            statement.setBigDecimal(4, decimal(qty));
            statement.setObject(5, demand.packageId());
            statement.setObject(6, demand.id());
            statement.setObject(7, demand.id());
            statement.setObject(8, inventory.balanceId());
            statement.setString(9, "stock-allocation-" + id);
            statement.executeUpdate();
        }
    }

    private static void assertDemandCommitment(
            Connection connection, UUID demandId, String expected)
            throws Exception {
        try (PreparedStatement statement = connection.prepareStatement("""
                select
                    coalesce((
                        select sum(r.qty - r.released_qty)
                        from stock_reservations r
                        where r.demand_id = d.id and r.is_deleted = false
                    ), 0)
                    +
                    coalesce((
                        select sum(p.allocated_qty
                                   - p.consumed_qty - p.released_qty)
                        from production_material_supply_pegs p
                        where p.demand_id = d.id
                          and p.status not in ('RELEASED', 'REVERSED')
                    ), 0)
                from production_material_demands d
                where d.id = ?
                """)) {
            statement.setObject(1, demandId);
            assertEquals(0, decimal(expected).compareTo(scalarDecimal(statement)));
        }
    }

    private static void assertQuantity(
            Connection connection, String sql, UUID id, String expected)
            throws Exception {
        try (PreparedStatement statement = connection.prepareStatement(sql)) {
            statement.setObject(1, id);
            assertEquals(0, decimal(expected).compareTo(scalarDecimal(statement)));
        }
    }

    private static void assertQuantity(
            Connection connection,
            String sql,
            UUID firstId,
            UUID secondId,
            String expected) throws Exception {
        try (PreparedStatement statement = connection.prepareStatement(sql)) {
            statement.setObject(1, firstId);
            statement.setObject(2, secondId);
            assertEquals(0, decimal(expected).compareTo(scalarDecimal(statement)));
        }
    }

    private static BigDecimal scalarDecimal(PreparedStatement statement)
            throws Exception {
        try (ResultSet result = statement.executeQuery()) {
            assertTrue(result.next());
            return result.getBigDecimal(1);
        }
    }

    private static void assertCapacityViolation(SqlAction action) {
        PSQLException error = assertThrows(PSQLException.class, action::run);
        assertEquals(CAPACITY_SQL_STATE, error.getSQLState());
    }

    private static BigDecimal decimal(String value) {
        return new BigDecimal(value);
    }

    private static Connection connection() throws Exception {
        return DriverManager.getConnection(
                POSTGRES.getJdbcUrl(),
                POSTGRES.getUsername(),
                POSTGRES.getPassword());
    }

    @FunctionalInterface
    private interface SqlAction {
        void run() throws Exception;
    }

    private record Inventory(
            UUID warehouseId,
            UUID goodsId,
            UUID unitId,
            UUID balanceId) {
    }

    private record Demand(UUID id, UUID packageId) {
    }
}
