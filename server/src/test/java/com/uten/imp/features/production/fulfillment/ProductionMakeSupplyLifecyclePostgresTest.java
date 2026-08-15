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
import java.util.concurrent.CountDownLatch;
import java.util.concurrent.ExecutorService;
import java.util.concurrent.Executors;
import java.util.concurrent.Future;
import java.util.concurrent.TimeUnit;

import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertFalse;
import static org.junit.jupiter.api.Assertions.assertTrue;
import static org.junit.jupiter.api.Assertions.fail;

/**
 * PostgreSQL acceptance evidence for V194's direct MAKE supply lifecycle.
 */
@EnabledIfEnvironmentVariable(named = "UTEN_RUN_DB_TESTS", matches = "(?i)true")
class ProductionMakeSupplyLifecyclePostgresTest {

    private static final LocalDate BILL_DATE = LocalDate.of(2026, 8, 2);
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
    void validMakeReceiptCommitsWithExactPegAndReservationConservation()
            throws Exception {
        try (Connection connection = connection()) {
            FullFixture fixture = createFullFixture(connection);

            assertEquals(
                    "READY",
                    scalarString(
                            connection,
                            "select status from production_execution_segments where id = ?",
                            fixture.core().segmentId()));
            assertEquals(
                    "DONE",
                    scalarString(
                            connection,
                            "select status from production_material_supply_pegs where id = ?",
                            fixture.core().pegId()));
            assertDecimalEquals(
                    "10",
                    scalarDecimal(
                            connection,
                            """
                            select sum(allocated_qty)
                            from production_material_make_receipt_allocations
                            where supply_peg_id = ? and status = 'EFFECTIVE'
                            """,
                            fixture.core().pegId()));
            assertDecimalEquals(
                    "10",
                    scalarDecimal(
                            connection,
                            """
                            select sum(allocated_qty)
                            from production_material_make_receipt_allocations
                            where reservation_id = ? and status = 'EFFECTIVE'
                            """,
                            fixture.reservationId()));
        }
    }

    @Test
    void rekitCanReuseStillApprovedReceiptAfterAtomicUnwind()
            throws Exception {
        try (Connection connection = connection()) {
            FullFixture fixture = createFullFixture(connection);
            String oldReservationKey = scalarString(
                    connection,
                    "select idempotency_key from stock_reservations where id = ?",
                    fixture.reservationId());
            String oldAllocationKey = scalarString(
                    connection,
                    """
                    select idempotency_key
                    from production_material_make_receipt_allocations
                    where id = ?
                    """,
                    fixture.allocationId());

            unwindFullFixture(connection, fixture);

            UUID triggeringReceiptId = UUID.randomUUID();
            UUID triggeringReceiptItemId = UUID.randomUUID();
            UUID reservationId = UUID.randomUUID();
            UUID drawId = UUID.randomUUID();
            UUID drawItemId = UUID.randomUUID();
            UUID allocationId = UUID.randomUUID();
            connection.setAutoCommit(false);
            try {
                insertFinishedIn(
                        connection,
                        fixture.core(),
                        triggeringReceiptId,
                        triggeringReceiptItemId,
                        businessIdentifier("CR", BILL_DATE),
                        decimal("1"));
                execute(
                        connection,
                        "update stock_balances set qty = qty + 1 where id = ?",
                        fixture.core().balanceId());
                execute(
                        connection,
                        """
                        update production_material_supply_pegs
                        set consumed_qty = 10, status = 'DONE'
                        where id = ?
                        """,
                        fixture.core().pegId());
                insertReservation(
                        connection,
                        fixture.core(),
                        reservationId,
                        decimal("10"),
                        triggeringReceiptId);
                insertDraw(
                        connection,
                        fixture.core(),
                        drawId,
                        drawItemId,
                        businessIdentifier("SL", BILL_DATE),
                        decimal("10"));
                insertMakeAllocation(
                        connection,
                        allocationId,
                        fixture.receiptId(),
                        fixture.receiptItemId(),
                        fixture.core().packageId(),
                        fixture.core().demandId(),
                        fixture.core().pegId(),
                        reservationId,
                        drawId,
                        drawItemId,
                        decimal("10"));
                execute(
                        connection,
                        "update production_material_demands set status = 'ALLOCATED' where id = ?",
                        fixture.core().demandId());
                execute(
                        connection,
                        "update production_execution_segments set status = 'READY' where id = ?",
                        fixture.core().segmentId());
                connection.commit();
            } catch (Exception error) {
                connection.rollback();
                throw error;
            } finally {
                connection.setAutoCommit(true);
            }

            String newReservationKey = scalarString(
                    connection,
                    "select idempotency_key from stock_reservations where id = ?",
                    reservationId);
            String newAllocationKey = scalarString(
                    connection,
                    """
                    select idempotency_key
                    from production_material_make_receipt_allocations
                    where id = ?
                    """,
                    allocationId);

            assertFalse(oldReservationKey.equals(newReservationKey));
            assertFalse(oldAllocationKey.equals(newAllocationKey));
            assertTrue(newReservationKey.length() <= 128);
            assertTrue(newAllocationKey.length() <= 128);
            assertEquals(
                    2,
                    scalarInt(
                            connection,
                            "select count(*) from stock_reservations where demand_id = ?",
                            fixture.core().demandId()));
            assertEquals(
                    2,
                    scalarInt(
                            connection,
                            """
                            select count(*)
                            from production_material_make_receipt_allocations
                            where receipt_item_id = ?
                            """,
                            fixture.receiptItemId()));
        }
    }

    @Test
    void makeDemandRejectsAProcurementPegType() throws Exception {
        try (Connection connection = connection()) {
            CoreFixture fixture = createSupplyFixture(connection, false);

            assertConstraint(
                    connection,
                    "production_material_supply_peg_route_guard",
                    null,
                    () -> insertPeg(
                            connection,
                            fixture,
                            UUID.randomUUID(),
                            "PURCHASE_ORDER_ITEM",
                            fixture.childItemId(),
                            decimal("10"),
                            BigDecimal.ZERO,
                            "EFFECTIVE"));
        }
    }

    @Test
    void activeMakePegProtectsChildPlanAndExactPackageLinkBeforeReceipt()
            throws Exception {
        try (Connection connection = connection()) {
            CoreFixture fixture = createSupplyFixture(connection, true);

            assertConstraint(
                    connection,
                    "production_make_supply_source_link_guard",
                    "trg_guard_active_make_source_plan",
                    () -> execute(
                            connection,
                            "update production_plans set status = -1 where id = ?",
                            fixture.childPlanId()));

            assertConstraint(
                    connection,
                    "production_make_supply_source_link_guard",
                    "trg_guard_active_make_subplan_link",
                    () -> execute(
                            connection,
                            "update subplan_links set is_deleted = true where id = ?",
                            fixture.subplanLinkId()));
        }
    }

    @Test
    void effectiveAllocationRejectsReleasedPegAndClosedPackage()
            throws Exception {
        try (Connection connection = connection()) {
            FullFixture fixture = createFullFixture(connection);

            assertConstraint(
                    connection,
                    "production_make_receipt_provenance_guard",
                    "trg_make_receipt_peg_source",
                    () -> execute(
                            connection,
                            """
                            update production_material_supply_pegs
                            set status = 'RELEASED'
                            where id = ?
                            """,
                            fixture.core().pegId()));

            assertConstraint(
                    connection,
                    "production_make_receipt_provenance_guard",
                    "trg_make_receipt_package_source",
                    () -> execute(
                            connection,
                            """
                            update production_planning_packages
                            set status = 'CANCELLED'
                            where id = ?
                            """,
                            fixture.core().packageId()));
        }
    }

    @Test
    void receiptAndReservationCapacityAreEnforcedByPostgres()
            throws Exception {
        try (Connection connection = connection()) {
            assertInvalidAllocationFixture(
                    connection,
                    decimal("9"),
                    decimal("10"),
                    "production_make_receipt_capacity_guard");
            assertInvalidAllocationFixture(
                    connection,
                    decimal("10"),
                    decimal("9"),
                    "production_make_receipt_reservation_capacity_guard");
        }
    }

    @Test
    void concurrentAllocationsCannotOverAllocateOneFinishedInItem()
            throws Exception {
        ConcurrentFixture fixture;
        try (Connection setup = connection()) {
            fixture = createConcurrentFixture(setup);
        }

        CountDownLatch start = new CountDownLatch(1);
        ExecutorService executor = Executors.newFixedThreadPool(2);
        try {
            Future<CommitOutcome> first = executor.submit(
                    () -> allocateConcurrently(fixture, 0, start));
            Future<CommitOutcome> second = executor.submit(
                    () -> allocateConcurrently(fixture, 1, start));
            start.countDown();

            CommitOutcome firstOutcome = first.get(30, TimeUnit.SECONDS);
            CommitOutcome secondOutcome = second.get(30, TimeUnit.SECONDS);
            long committed = java.util.stream.Stream
                    .of(firstOutcome, secondOutcome)
                    .filter(CommitOutcome::committed)
                    .count();
            CommitOutcome rejected = firstOutcome.committed()
                    ? secondOutcome
                    : firstOutcome;

            assertEquals(1, committed);
            assertFalse(rejected.committed());
            assertEquals(
                    "production_make_receipt_capacity_guard",
                    rejected.constraint());
        } finally {
            executor.shutdownNow();
        }

        try (Connection verification = connection()) {
            assertEquals(
                    1,
                    scalarInt(
                            verification,
                            """
                            select count(*)
                            from production_material_make_receipt_allocations
                            where receipt_item_id = ? and status = 'EFFECTIVE'
                            """,
                            fixture.receiptItemId()));
            assertDecimalEquals(
                    "6",
                    scalarDecimal(
                            verification,
                            """
                            select sum(allocated_qty)
                            from production_material_make_receipt_allocations
                            where receipt_item_id = ? and status = 'EFFECTIVE'
                            """,
                            fixture.receiptItemId()));
        }
    }

    private static CoreFixture createSupplyFixture(
            Connection connection, boolean withPeg) throws Exception {
        connection.setAutoCommit(false);
        try {
            CoreFixture fixture = insertCore(
                    connection,
                    decimal("10"),
                    decimal("10"),
                    1,
                    decimal("10"));
            if (withPeg) {
                insertPeg(
                        connection,
                        fixture,
                        fixture.pegId(),
                        "PRODUCTION_PLAN_ITEM",
                        fixture.childItemId(),
                        decimal("10"),
                        BigDecimal.ZERO,
                        "EFFECTIVE");
            }
            connection.commit();
            return fixture;
        } catch (Exception error) {
            connection.rollback();
            throw error;
        } finally {
            connection.setAutoCommit(true);
        }
    }

    private static FullFixture createFullFixture(Connection connection)
            throws Exception {
        connection.setAutoCommit(false);
        try {
            FullFixture fixture = insertFullFixture(
                    connection,
                    decimal("10"),
                    decimal("10"),
                    true);
            connection.commit();
            return fixture;
        } catch (Exception error) {
            connection.rollback();
            throw error;
        } finally {
            connection.setAutoCommit(true);
        }
    }

    private static void assertInvalidAllocationFixture(
            Connection connection,
            BigDecimal receiptCapacity,
            BigDecimal reservationCapacity,
            String expectedConstraint) throws Exception {
        connection.setAutoCommit(false);
        try {
            insertFullFixture(
                    connection,
                    receiptCapacity,
                    reservationCapacity,
                    false);
            execute(
                    connection,
                    "set constraints trg_check_make_receipt_allocation immediate");
            connection.commit();
            fail("expected PostgreSQL constraint " + expectedConstraint);
        } catch (PSQLException error) {
            connection.rollback();
            assertEquals(
                    expectedConstraint,
                    error.getServerErrorMessage().getConstraint());
        } catch (Exception error) {
            connection.rollback();
            throw error;
        } finally {
            connection.setAutoCommit(true);
        }
    }

    private static FullFixture insertFullFixture(
            Connection connection,
            BigDecimal receiptCapacity,
            BigDecimal reservationCapacity,
            boolean finalizeReady) throws Exception {
        CoreFixture core = insertCore(
                connection,
                decimal("10"),
                decimal("10"),
                1,
                decimal("10"));
        insertPeg(
                connection,
                core,
                core.pegId(),
                "PRODUCTION_PLAN_ITEM",
                core.childItemId(),
                decimal("10"),
                BigDecimal.ZERO,
                "EFFECTIVE");

        UUID receiptId = UUID.randomUUID();
        UUID receiptItemId = UUID.randomUUID();
        UUID reservationId = UUID.randomUUID();
        UUID drawId = UUID.randomUUID();
        UUID drawItemId = UUID.randomUUID();
        UUID allocationId = UUID.randomUUID();
        String receiptNo = businessIdentifier("CR", BILL_DATE);
        String drawNo = businessIdentifier("SL", BILL_DATE);

        insertFinishedIn(
                connection,
                core,
                receiptId,
                receiptItemId,
                receiptNo,
                receiptCapacity);
        execute(
                connection,
                """
                update production_material_supply_pegs
                set consumed_qty = 10, status = 'DONE'
                where id = ?
                """,
                core.pegId());
        insertReservation(
                connection,
                core,
                reservationId,
                reservationCapacity,
                receiptId);
        insertDraw(
                connection,
                core,
                drawId,
                drawItemId,
                drawNo,
                decimal("10"));

        insertMakeAllocation(
                connection,
                allocationId,
                receiptId,
                receiptItemId,
                core.packageId(),
                core.demandId(),
                core.pegId(),
                reservationId,
                drawId,
                drawItemId,
                decimal("10"));

        if (finalizeReady) {
            execute(
                    connection,
                    "update production_material_demands set status = 'ALLOCATED' where id = ?",
                    core.demandId());
            execute(
                    connection,
                    "update production_execution_segments set status = 'READY' where id = ?",
                    core.segmentId());
        }
        return new FullFixture(
                core,
                receiptId,
                receiptItemId,
                reservationId,
                drawId,
                drawItemId,
                allocationId);
    }

    private static CoreFixture insertCore(
            Connection connection,
            BigDecimal parentQty,
            BigDecimal childQty,
            int segmentNo,
            BigDecimal segmentQty) throws Exception {
        UUID unitId = UUID.randomUUID();
        UUID productId = UUID.randomUUID();
        UUID materialId = UUID.randomUUID();
        UUID warehouseId = UUID.randomUUID();
        UUID balanceId = UUID.randomUUID();
        UUID parentPlanId = UUID.randomUUID();
        UUID parentItemId = UUID.randomUUID();
        UUID packageId = UUID.randomUUID();
        UUID segmentId = UUID.randomUUID();
        UUID demandId = UUID.randomUUID();
        UUID childPlanId = UUID.randomUUID();
        UUID childItemId = UUID.randomUUID();
        UUID subplanLinkId = UUID.randomUUID();
        UUID pegId = UUID.randomUUID();
        String parentNo = businessIdentifier("SJ", BILL_DATE);
        String childNo = businessIdentifier("SZ", BILL_DATE);

        execute(
                connection,
                "insert into units(id, code, name) values (?, ?, 'piece')",
                unitId,
                "UNIT-" + unitId);
        insertGoods(connection, productId);
        insertGoods(connection, materialId);
        insertWarehouse(connection, warehouseId);
        execute(
                connection,
                """
                insert into stock_balances(id, warehouse_id, goods_id, qty)
                values (?, ?, ?, ?)
                """,
                balanceId,
                warehouseId,
                materialId,
                childQty);
        insertPlan(connection, parentPlanId, parentNo);
        insertPlanItem(
                connection,
                parentItemId,
                parentPlanId,
                parentNo,
                productId,
                unitId,
                parentQty,
                1);
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
                parentPlanId,
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
                    ?, ?, ?, ?, ?, ?, ?, ?, ?, 1,
                    ?, 'WAITING', ?, ?
                )
                """,
                segmentId,
                packageId,
                parentPlanId,
                parentItemId,
                segmentNo,
                canonicalSegmentCode(segmentId),
                "CLIENT-" + segmentId,
                productId,
                unitId,
                segmentQty,
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
                    ?, ?, ?, ?, ?, ?, ?, ?,
                    'MAKE', 'WAITING_SUPPLY', ?, ?, ?, 1
                )
                """,
                demandId,
                packageId,
                parentPlanId,
                warehouseId,
                materialId,
                unitId,
                segmentQty,
                BILL_DATE.plusDays(3),
                "demand-" + demandId,
                segmentId,
                parentItemId);
        insertPlan(connection, childPlanId, childNo);
        insertPlanItem(
                connection,
                childItemId,
                childPlanId,
                childNo,
                materialId,
                unitId,
                childQty,
                1);
        execute(
                connection,
                """
                insert into subplan_links(
                    id, plan_id, subplan_id,
                    planning_package_id, source
                ) values (?, ?, ?, ?, 'EXECUTION_V1')
                """,
                subplanLinkId,
                parentPlanId,
                childPlanId,
                packageId);

        return new CoreFixture(
                unitId,
                productId,
                materialId,
                warehouseId,
                balanceId,
                parentPlanId,
                parentItemId,
                parentNo,
                packageId,
                segmentId,
                demandId,
                childPlanId,
                childItemId,
                subplanLinkId,
                pegId);
    }

    private static ConcurrentFixture createConcurrentFixture(
            Connection connection) throws Exception {
        connection.setAutoCommit(false);
        try {
            UUID unitId = UUID.randomUUID();
            UUID productId = UUID.randomUUID();
            UUID materialId = UUID.randomUUID();
            UUID warehouseId = UUID.randomUUID();
            UUID balanceId = UUID.randomUUID();
            UUID parentPlanId = UUID.randomUUID();
            UUID parentItemId = UUID.randomUUID();
            UUID packageId = UUID.randomUUID();
            UUID childPlanId = UUID.randomUUID();
            UUID childItemId = UUID.randomUUID();
            UUID subplanLinkId = UUID.randomUUID();
            UUID receiptId = UUID.randomUUID();
            UUID receiptItemId = UUID.randomUUID();
            String parentNo = businessIdentifier("SJ", BILL_DATE);
            String childNo = businessIdentifier("SZ", BILL_DATE);

            execute(
                    connection,
                    "insert into units(id, code, name) values (?, ?, 'piece')",
                    unitId,
                    "UNIT-" + unitId);
            insertGoods(connection, productId);
            insertGoods(connection, materialId);
            insertWarehouse(connection, warehouseId);
            execute(
                    connection,
                    """
                    insert into stock_balances(id, warehouse_id, goods_id, qty)
                    values (?, ?, ?, 12)
                    """,
                    balanceId,
                    warehouseId,
                    materialId);
            insertPlan(connection, parentPlanId, parentNo);
            insertPlanItem(
                    connection,
                    parentItemId,
                    parentPlanId,
                    parentNo,
                    productId,
                    unitId,
                    decimal("12"),
                    1);
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
                    parentPlanId,
                    warehouseId,
                    "package-" + packageId,
                    "d".repeat(64),
                    "e".repeat(64));
            insertPlan(connection, childPlanId, childNo);
            insertPlanItem(
                    connection,
                    childItemId,
                    childPlanId,
                    childNo,
                    materialId,
                    unitId,
                    decimal("12"),
                    1);
            execute(
                    connection,
                    """
                    insert into subplan_links(
                        id, plan_id, subplan_id,
                        planning_package_id, source
                    ) values (?, ?, ?, ?, 'EXECUTION_V1')
                    """,
                    subplanLinkId,
                    parentPlanId,
                    childPlanId,
                    packageId);

            CoreFixture receiptCore = new CoreFixture(
                    unitId,
                    productId,
                    materialId,
                    warehouseId,
                    balanceId,
                    parentPlanId,
                    parentItemId,
                    parentNo,
                    packageId,
                    null,
                    null,
                    childPlanId,
                    childItemId,
                    subplanLinkId,
                    null);
            insertFinishedIn(
                    connection,
                    receiptCore,
                    receiptId,
                    receiptItemId,
                    businessIdentifier("CR", BILL_DATE),
                    decimal("10"));

            ConcurrentLine[] lines = new ConcurrentLine[2];
            for (int index = 0; index < 2; index++) {
                UUID segmentId = UUID.randomUUID();
                UUID demandId = UUID.randomUUID();
                UUID pegId = UUID.randomUUID();
                UUID reservationId = UUID.randomUUID();
                UUID drawId = UUID.randomUUID();
                UUID drawItemId = UUID.randomUUID();
                UUID allocationId = UUID.randomUUID();
                int segmentNo = index + 1;

                execute(
                        connection,
                        """
                        insert into production_execution_segments(
                            id, package_id, plan_id, source_plan_item_id,
                            segment_no, segment_code, client_segment_key,
                            product_goods_id, product_unit_id,
                            product_unit_rate, planned_qty, status,
                            bom_fingerprint, idempotency_key
                        ) values (
                            ?, ?, ?, ?, ?, ?, ?, ?, ?, 1,
                            6, 'WAITING', ?, ?
                        )
                        """,
                        segmentId,
                        packageId,
                        parentPlanId,
                        parentItemId,
                        segmentNo,
                        canonicalSegmentCode(segmentId),
                        "CLIENT-" + segmentId,
                        productId,
                        unitId,
                        "f".repeat(64),
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
                            ?, ?, ?, ?, ?, ?, 6, ?,
                            'MAKE', 'WAITING_SUPPLY', ?, ?, ?, 1
                        )
                        """,
                        demandId,
                        packageId,
                        parentPlanId,
                        warehouseId,
                        materialId,
                        unitId,
                        BILL_DATE.plusDays(3 + index),
                        "demand-" + demandId,
                        segmentId,
                        parentItemId);
                CoreFixture lineCore = new CoreFixture(
                        unitId,
                        productId,
                        materialId,
                        warehouseId,
                        balanceId,
                        parentPlanId,
                        parentItemId,
                        parentNo,
                        packageId,
                        segmentId,
                        demandId,
                        childPlanId,
                        childItemId,
                        subplanLinkId,
                        pegId);
                insertPeg(
                        connection,
                        lineCore,
                        pegId,
                        "PRODUCTION_PLAN_ITEM",
                        childItemId,
                        decimal("6"),
                        BigDecimal.ZERO,
                        "EFFECTIVE");
                lines[index] = new ConcurrentLine(
                        lineCore,
                        pegId,
                        demandId,
                        reservationId,
                        drawId,
                        drawItemId,
                        allocationId);
            }
            connection.commit();
            return new ConcurrentFixture(
                    packageId,
                    receiptId,
                    receiptItemId,
                    lines);
        } catch (Exception error) {
            connection.rollback();
            throw error;
        } finally {
            connection.setAutoCommit(true);
        }
    }

    private static CommitOutcome allocateConcurrently(
            ConcurrentFixture fixture,
            int lineIndex,
            CountDownLatch start) throws Exception {
        ConcurrentLine line = fixture.lines()[lineIndex];
        try (Connection connection = connection()) {
            connection.setAutoCommit(false);
            try {
                assertTrue(start.await(10, TimeUnit.SECONDS));
                execute(
                        connection,
                        """
                        update production_material_supply_pegs
                        set consumed_qty = 6, status = 'DONE'
                        where id = ?
                        """,
                        line.pegId());
                insertReservation(
                        connection,
                        line.core(),
                        line.reservationId(),
                        decimal("6"),
                        fixture.receiptId());
                insertDraw(
                        connection,
                        line.core(),
                        line.drawId(),
                        line.drawItemId(),
                        businessIdentifier("SL", BILL_DATE),
                        decimal("6"));
                insertMakeAllocation(
                        connection,
                        line.allocationId(),
                        fixture.receiptId(),
                        fixture.receiptItemId(),
                        fixture.packageId(),
                        line.demandId(),
                        line.pegId(),
                        line.reservationId(),
                        line.drawId(),
                        line.drawItemId(),
                        decimal("6"));
                execute(
                        connection,
                        "update production_material_demands set status = 'ALLOCATED' where id = ?",
                        line.demandId());
                execute(
                        connection,
                        "update production_execution_segments set status = 'READY' where id = ?",
                        line.core().segmentId());
                connection.commit();
                return new CommitOutcome(true, null);
            } catch (PSQLException error) {
                connection.rollback();
                return new CommitOutcome(
                        false,
                        error.getServerErrorMessage().getConstraint());
            } catch (Exception error) {
                connection.rollback();
                throw error;
            }
        }
    }


    private static void unwindFullFixture(
            Connection connection, FullFixture fixture) throws Exception {
        connection.setAutoCommit(false);
        try {
            execute(
                    connection,
                    "update production_execution_segments set status = 'WAITING' where id = ?",
                    fixture.core().segmentId());
            execute(
                    connection,
                    "update production_material_demands set status = 'WAITING_SUPPLY' where id = ?",
                    fixture.core().demandId());
            execute(
                    connection,
                    """
                    update production_material_make_receipt_allocations
                    set status = 'REVERSED'
                    where id = ?
                    """,
                    fixture.allocationId());
            execute(
                    connection,
                    """
                    update stock_reservations
                    set released_qty = qty, status = 1,
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
                    fixture.core().pegId());
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
                    "update stock_document_items set is_deleted = true where id = ?",
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
                    fixture.core().packageId(),
                    fixture.drawId());
            connection.commit();
        } catch (Exception error) {
            connection.rollback();
            throw error;
        } finally {
            connection.setAutoCommit(true);
        }
    }
    private static void insertPeg(
            Connection connection,
            CoreFixture fixture,
            UUID pegId,
            String supplyType,
            UUID supplyItemId,
            BigDecimal allocatedQty,
            BigDecimal consumedQty,
            String status) throws Exception {
        execute(
                connection,
                """
                insert into production_material_supply_pegs(
                    id, demand_id, supply_type, supply_item_id,
                    allocated_qty, consumed_qty, released_qty,
                    expected_date, status, idempotency_key
                ) values (?, ?, ?, ?, ?, ?, 0, ?, ?, ?)
                """,
                pegId,
                fixture.demandId(),
                supplyType,
                supplyItemId,
                allocatedQty,
                consumedQty,
                BILL_DATE,
                status,
                "supply-peg-" + pegId);
    }

    private static void insertFinishedIn(
            Connection connection,
            CoreFixture core,
            UUID receiptId,
            UUID receiptItemId,
            String receiptNo,
            BigDecimal capacity) throws Exception {
        execute(
                connection,
                """
                insert into stock_documents(
                    id, doc_type, bill_no, bill_date,
                    warehouse_id, plan_no, status
                ) values (?, 'FINISHED_IN', ?, ?, ?, ?, 1)
                """,
                receiptId,
                receiptNo,
                BILL_DATE,
                core.warehouseId(),
                core.parentNo());
        execute(
                connection,
                """
                insert into stock_document_items(
                    id, doc_id, bill_type, bill_no, bill_date,
                    line_no, goods_id, unit_id, unit_rate,
                    qty, base_qty, upstream_item_id, goods_snapshot_source
                ) values (
                    ?, ?, 'FINISHED_IN', ?, ?, 1, ?, ?, 1,
                    ?, ?, ?, 'MASTER_AT_SAVE'
                )
                """,
                receiptItemId,
                receiptId,
                receiptNo,
                BILL_DATE,
                core.materialId(),
                core.unitId(),
                capacity,
                capacity,
                core.childItemId());
    }

    private static void insertReservation(
            Connection connection,
            CoreFixture core,
            UUID reservationId,
            BigDecimal qty,
            UUID triggeringReceiptId) throws Exception {
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
                    ?, null, ?, ?, ?, 0, 0, 0, 2,
                    'PRODUCTION_PLANNING_PACKAGE', ?,
                    'PRODUCTION_MATERIAL_DEMAND', ?,
                    'PRODUCTION_MATERIAL', ?,
                    'STOCK_BALANCE', ?, ?
                )
                """,
                reservationId,
                core.materialId(),
                core.warehouseId(),
                qty,
                core.packageId(),
                core.demandId(),
                core.demandId(),
                core.balanceId(),
                core.packageId() + ":REKIT:" + core.demandId()
                        + ":" + triggeringReceiptId);
    }

    private static void insertDraw(
            Connection connection,
            CoreFixture core,
            UUID drawId,
            UUID drawItemId,
            String drawNo,
            BigDecimal qty) throws Exception {
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
                core.warehouseId(),
                core.parentNo());
        execute(
                connection,
                """
                insert into stock_document_items(
                    id, doc_id, bill_type, bill_no, bill_date,
                    line_no, goods_id, unit_id, unit_rate,
                    qty, base_qty, goods_snapshot_source
                ) values (?, ?, 'DRAW', ?, ?, 1, ?, ?, 1, ?, ?, 'MASTER_AT_SAVE')
                """,
                drawItemId,
                drawId,
                drawNo,
                BILL_DATE,
                core.materialId(),
                core.unitId(),
                qty,
                qty);
        execute(
                connection,
                """
                insert into production_planning_package_documents(
                    package_id, execution_segment_id,
                    document_type, document_id, document_no
                ) values (?, ?, 'DRAW', ?, ?)
                """,
                core.packageId(),
                core.segmentId(),
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
                core.packageId(),
                core.demandId(),
                drawId,
                drawItemId);
        execute(
                connection,
                "insert into plan_draw_links(plan_id, draw_id) values (?, ?)",
                core.parentPlanId(),
                drawId);
    }

    private static void insertMakeAllocation(
            Connection connection,
            UUID allocationId,
            UUID receiptId,
            UUID receiptItemId,
            UUID packageId,
            UUID demandId,
            UUID pegId,
            UUID reservationId,
            UUID drawId,
            UUID drawItemId,
            BigDecimal qty) throws Exception {
        execute(
                connection,
                """
                insert into production_material_make_receipt_allocations(
                    id, receipt_id, receipt_item_id, package_id,
                    demand_id, supply_peg_id, reservation_id,
                    draw_id, draw_item_id, allocated_qty,
                    status, idempotency_key
                ) values (
                    ?, ?, ?, ?, ?, ?, ?, ?, ?, ?,
                    'EFFECTIVE', ?
                )
                """,
                allocationId,
                receiptId,
                receiptItemId,
                packageId,
                demandId,
                pegId,
                reservationId,
                drawId,
                drawItemId,
                qty,
                "SEG-MAKE-REKIT:" + receiptItemId + ":" + pegId
                        + ":" + reservationId);
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

    private static void insertPlan(
            Connection connection, UUID id, String billNo) throws Exception {
        execute(
                connection,
                """
                insert into production_plans(
                    id, bill_no, bill_date, delivery_date, status
                ) values (?, ?, ?, ?, 1)
                """,
                id,
                billNo,
                BILL_DATE,
                BILL_DATE.plusDays(7));
    }

    private static void insertPlanItem(
            Connection connection,
            UUID id,
            UUID planId,
            String billNo,
            UUID goodsId,
            UUID unitId,
            BigDecimal qty,
            int lineNo) throws Exception {
        execute(
                connection,
                """
                insert into production_plan_items(
                    id, bill_no, bill_date, plan_id, line_no,
                    product_no, goods_id, unit_id, unit_rate, qty
                ) values (?, ?, ?, ?, ?, ?, ?, ?, 1, ?)
                """,
                id,
                billNo,
                BILL_DATE,
                planId,
                lineNo,
                "PRODUCT-" + id,
                goodsId,
                unitId,
                qty);
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

    private static void assertConstraint(
            Connection connection,
            String expectedConstraint,
            String forceConstraint,
            CheckedRunnable mutation) throws Exception {
        connection.setAutoCommit(false);
        try {
            mutation.run();
            if (forceConstraint != null) {
                execute(
                        connection,
                        "set constraints " + forceConstraint + " immediate");
            }
            connection.commit();
            fail("expected PostgreSQL constraint " + expectedConstraint);
        } catch (PSQLException error) {
            connection.rollback();
            assertEquals(
                    expectedConstraint,
                    error.getServerErrorMessage().getConstraint());
        } catch (Exception error) {
            connection.rollback();
            throw error;
        } finally {
            connection.setAutoCommit(true);
        }
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
            Connection connection, String sql, Object parameter)
            throws Exception {
        try (PreparedStatement statement = connection.prepareStatement(sql)) {
            statement.setObject(1, parameter);
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

    private static void assertDecimalEquals(
            String expected, BigDecimal actual) {
        assertEquals(0, decimal(expected).compareTo(actual));
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
    private interface CheckedRunnable {
        void run() throws Exception;
    }

    private record CoreFixture(
            UUID unitId,
            UUID productId,
            UUID materialId,
            UUID warehouseId,
            UUID balanceId,
            UUID parentPlanId,
            UUID parentItemId,
            String parentNo,
            UUID packageId,
            UUID segmentId,
            UUID demandId,
            UUID childPlanId,
            UUID childItemId,
            UUID subplanLinkId,
            UUID pegId) {}

    private record FullFixture(
            CoreFixture core,
            UUID receiptId,
            UUID receiptItemId,
            UUID reservationId,
            UUID drawId,
            UUID drawItemId,
            UUID allocationId) {}

    private record ConcurrentLine(
            CoreFixture core,
            UUID pegId,
            UUID demandId,
            UUID reservationId,
            UUID drawId,
            UUID drawItemId,
            UUID allocationId) {}

    private record ConcurrentFixture(
            UUID packageId,
            UUID receiptId,
            UUID receiptItemId,
            ConcurrentLine[] lines) {}

    private record CommitOutcome(boolean committed, String constraint) {}
}
