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
import java.time.Duration;
import java.time.LocalDate;
import java.util.UUID;

import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertFalse;
import static org.junit.jupiter.api.Assertions.assertThrows;
import static org.junit.jupiter.api.Assertions.assertTimeoutPreemptively;
import static org.junit.jupiter.api.Assertions.assertTrue;

/**
 * Real PostgreSQL acceptance evidence for V154's request -> order -> receipt
 * -> production reservation/DRAW transition and exact reversal.
 */
@EnabledIfEnvironmentVariable(named = "UTEN_RUN_DB_TESTS", matches = "(?i)true")
class ProductionPurchaseSupplyTransitionPostgresTest {

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
    void partialReceiptsAndReplayPreserveOneForOneDemandCoverage() {
        assertTimeoutPreemptively(Duration.ofSeconds(20), () -> {
            try (Connection connection = connection()) {
                Fixture fixture = createFixture(connection, "10");

                ReceiptConversion first =
                        convertReceipt(connection, fixture, "4");
                assertFalse(first.replayed());
                ReceiptConversion replay =
                        convertReceipt(connection, fixture, "4", first);
                assertTrue(replay.replayed());
                ReceiptConversion second =
                        convertReceipt(connection, fixture, "6");

                assertQuantity(
                        connection,
                        """
                        select allocated_qty - consumed_qty - released_qty
                        from production_material_supply_pegs where id = ?
                        """,
                        fixture.orderPegId(),
                        "0");
                assertQuantity(
                        connection,
                        """
                        select consumed_qty
                        from production_material_supply_pegs where id = ?
                        """,
                        fixture.orderPegId(),
                        "10");
                assertQuantity(
                        connection,
                        """
                        select qty - released_qty
                        from stock_reservations where id = ?
                        """,
                        first.reservationId(),
                        "10");
                assertQuantity(
                        connection,
                        """
                        select coalesce(sum(allocated_qty), 0)
                        from production_material_receipt_allocations
                        where order_peg_id = ? and status = 'EFFECTIVE'
                        """,
                        fixture.orderPegId(),
                        "10");
                assertDemandCoverage(connection, fixture.demandId(), "10");
                assertEquals(
                        2,
                        count(
                                connection,
                                """
                                select count(*)
                                from production_material_receipt_allocations
                                where order_peg_id = ?
                                  and status = 'EFFECTIVE'
                                """,
                                fixture.orderPegId()));
                assertEquals(
                        "COVERED",
                        scalarString(
                                connection,
                                """
                                select task_status
                                from v_fulfillment_workbench
                                where department = 'PURCHASE'
                                  and task_id = ?
                                """,
                                fixture.demandId()));
                assertEquals(
                        "READY_TO_PICK",
                        scalarString(
                                connection,
                                """
                                select task_status
                                from v_fulfillment_workbench
                                where department = 'WAREHOUSE'
                                  and task_id = ?
                                """,
                                fixture.demandId()));
                assertEquals(
                        first.reservationId(),
                        second.reservationId(),
                        "partial receipts into one balance extend one reservation");

                PSQLException duplicate = assertThrows(
                        PSQLException.class,
                        () -> duplicateReceiptMapping(
                                connection, fixture, first));
                assertEquals(
                        "uq_production_material_receipt_allocation_key",
                        duplicate.getServerErrorMessage().getConstraint());
                assertDemandCoverage(connection, fixture.demandId(), "10");
            }
        });
    }

    @Test
    void receiptAndOrderReversalAreBlockedUntilExactDownstreamUnwind() {
        assertTimeoutPreemptively(Duration.ofSeconds(25), () -> {
            try (Connection connection = connection()) {
                Fixture fixture = createFixture(connection, "10");
                assertConstraint(
                        "production_purchase_transfer_provenance_guard",
                        () -> execute(
                                connection,
                                """
                                update production_material_peg_transfers
                                set status = 'REVERSED' where id = ?
                                """,
                                fixture.transferId()));
                assertConstraint(
                        "production_peg_transfer_immutable_guard",
                        () -> execute(
                                connection,
                                """
                                update production_material_peg_transfers
                                set transferred_qty = transferred_qty + 1
                                where id = ?
                                """,
                                fixture.transferId()));
                ReceiptConversion first =
                        convertReceipt(connection, fixture, "4");
                ReceiptConversion second =
                        convertReceipt(connection, fixture, "6");

                assertConstraint(
                        "production_receipt_allocation_provenance_guard",
                        () -> execute(
                                connection,
                                """
                                update plan_draw_links
                                set is_deleted = true where draw_id = ?
                                """,
                                second.drawId()));
                assertConstraint(
                        "production_receipt_allocation_immutable_guard",
                        () -> execute(
                                connection,
                                """
                                update production_material_receipt_allocations
                                set allocated_qty = allocated_qty + 1
                                where receipt_item_id = ?
                                """,
                                second.receiptItemId()));

                assertConstraint(
                        "production_purchase_receipt_reversal_guard",
                        () -> updateStatus(
                                connection,
                                "purchase_receipts",
                                first.receiptId(),
                                -1));

                reverseReceipt(connection, fixture, first);
                assertDemandCoverage(connection, fixture.demandId(), "10");
                assertQuantity(
                        connection,
                        """
                        select allocated_qty - consumed_qty - released_qty
                        from production_material_supply_pegs where id = ?
                        """,
                        fixture.orderPegId(),
                        "4");
                assertQuantity(
                        connection,
                        """
                        select qty - released_qty
                        from stock_reservations where id = ?
                        """,
                        first.reservationId(),
                        "6");

                setIssuedQty(connection, second.drawItemId(), "1");
                assertConstraint(
                        "production_receipt_issued_draw_guard",
                        () -> reverseReceipt(connection, fixture, second));
                setIssuedQty(connection, second.drawItemId(), "0");

                reverseReceipt(connection, fixture, second);
                assertDemandCoverage(connection, fixture.demandId(), "10");
                assertQuantity(
                        connection,
                        """
                        select allocated_qty - consumed_qty - released_qty
                        from production_material_supply_pegs where id = ?
                        """,
                        fixture.orderPegId(),
                        "10");
                assertEquals(
                        0,
                        count(
                                connection,
                                """
                                select count(*)
                                from stock_reservations
                                where id = ? and is_deleted = false
                                """,
                                first.reservationId()));

                assertConstraint(
                        "production_purchase_order_reversal_guard",
                        () -> updateStatus(
                                connection,
                                "purchase_orders",
                                fixture.orderId(),
                                -1));
                reverseOrderSupply(connection, fixture);
                assertQuantity(
                        connection,
                        """
                        select allocated_qty - consumed_qty - released_qty
                        from production_material_supply_pegs where id = ?
                        """,
                        fixture.requestPegId(),
                        "10");
                assertQuantity(
                        connection,
                        """
                        select allocated_qty - consumed_qty - released_qty
                        from production_material_supply_pegs where id = ?
                        """,
                        fixture.orderPegId(),
                        "0");
                assertEquals(
                        -1,
                        scalarInt(
                                connection,
                                "select status from purchase_orders where id = ?",
                                fixture.orderId()));
                assertTrue(
                        count(
                                connection,
                                """
                                select count(*) from audit_log
                                where target_type in (
                                    'production_material_peg_transfers',
                                    'production_material_receipt_allocations'
                                )
                                """,
                                (Object[]) null) > 0);
            }
        });
    }

    @Test
    void purchaseWorkbenchActionFollowsLatestValidDownstreamDocument()
            throws Exception {
        try (Connection connection = connection()) {
            Fixture fixture = createFixture(connection, "10");
            assertPurchaseAction(
                    connection,
                    fixture.demandId(),
                    "PURCHASE_ORDER",
                    fixture.orderId(),
                    fixture.orderItemId(),
                    "PO-" + fixture.orderId(),
                    "1");

            ReceiptConversion receipt =
                    convertReceipt(connection, fixture, "10");
            assertPurchaseAction(
                    connection,
                    fixture.demandId(),
                    "PURCHASE_RECEIPT",
                    receipt.receiptId(),
                    receipt.receiptItemId(),
                    "RC-" + receipt.receiptId(),
                    "1");

            reverseReceipt(connection, fixture, receipt);
            assertPurchaseAction(
                    connection,
                    fixture.demandId(),
                    "PURCHASE_ORDER",
                    fixture.orderId(),
                    fixture.orderItemId(),
                    "PO-" + fixture.orderId(),
                    "1");

            reverseOrderSupply(connection, fixture);
            assertPurchaseAction(
                    connection,
                    fixture.demandId(),
                    "PURCHASE_REQUEST",
                    fixture.requestId(),
                    fixture.requestItemId(),
                    "PR-" + fixture.requestId(),
                    "1");
        }
    }

    private static Fixture createFixture(
            Connection connection, String quantity) throws Exception {
        UUID unitId = UUID.randomUUID();
        UUID goodsId = UUID.randomUUID();
        UUID warehouseId = UUID.randomUUID();
        UUID balanceId = UUID.randomUUID();
        UUID planId = UUID.randomUUID();
        UUID packageId = UUID.randomUUID();
        UUID demandId = UUID.randomUUID();
        UUID requestId = UUID.randomUUID();
        UUID requestItemId = UUID.randomUUID();
        UUID requestPegId = UUID.randomUUID();
        UUID orderId = UUID.randomUUID();
        UUID orderItemId = UUID.randomUUID();
        UUID orderPegId = UUID.randomUUID();
        UUID transferId = UUID.randomUUID();
        LocalDate date = LocalDate.of(2026, 7, 31);

        try (PreparedStatement unit = connection.prepareStatement("""
                insert into units(id, code, name) values (?, ?, 'unit')
                """);
             PreparedStatement goods = connection.prepareStatement("""
                     insert into goods(id, code, name, min_qty)
                     values (?, ?, 'material', 0)
                     """);
             PreparedStatement warehouse = connection.prepareStatement("""
                     insert into warehouses(id, code, name)
                     values (?, ?, 'target warehouse')
                     """);
             PreparedStatement balance = connection.prepareStatement("""
                     insert into stock_balances(
                         id, warehouse_id, goods_id, qty
                     ) values (?, ?, ?, 0)
                     """)) {
            unit.setObject(1, unitId);
            unit.setString(2, "U-" + unitId);
            unit.executeUpdate();
            goods.setObject(1, goodsId);
            goods.setString(2, "G-" + goodsId);
            goods.executeUpdate();
            warehouse.setObject(1, warehouseId);
            warehouse.setString(2, "W-" + warehouseId);
            warehouse.executeUpdate();
            balance.setObject(1, balanceId);
            balance.setObject(2, warehouseId);
            balance.setObject(3, goodsId);
            balance.executeUpdate();
        }

        try (PreparedStatement plan = connection.prepareStatement("""
                insert into production_plans(
                    id, bill_no, bill_date, status
                ) values (?, ?, ?, 1)
                """);
             PreparedStatement planningPackage = connection.prepareStatement("""
                     insert into production_planning_packages(
                         id, plan_id, warehouse_id, idempotency_key,
                         request_hash, preview_fingerprint, status
                     ) values (?, ?, ?, ?, ?, ?, 'CONFIRMED')
                     """);
             PreparedStatement demand = connection.prepareStatement("""
                     insert into production_material_demands(
                         id, package_id, plan_id, warehouse_id,
                         goods_id, unit_id, required_qty, need_date,
                         supply_route, status, idempotency_key
                     ) values (
                         ?, ?, ?, ?, ?, ?, ?, ?, 'BUY',
                         'WAITING_SUPPLY', ?
                     )
                     """)) {
            plan.setObject(1, planId);
            plan.setString(2, "PP-" + planId);
            plan.setObject(3, date);
            plan.executeUpdate();
            planningPackage.setObject(1, packageId);
            planningPackage.setObject(2, planId);
            planningPackage.setObject(3, warehouseId);
            planningPackage.setString(4, "PACKAGE-" + packageId);
            planningPackage.setString(5, "a".repeat(64));
            planningPackage.setString(6, "b".repeat(64));
            planningPackage.executeUpdate();
            demand.setObject(1, demandId);
            demand.setObject(2, packageId);
            demand.setObject(3, planId);
            demand.setObject(4, warehouseId);
            demand.setObject(5, goodsId);
            demand.setObject(6, unitId);
            demand.setBigDecimal(7, decimal(quantity));
            demand.setObject(8, date.plusDays(7));
            demand.setString(9, "DEMAND-" + demandId);
            demand.executeUpdate();
        }

        try (PreparedStatement request = connection.prepareStatement("""
                insert into purchase_requests(
                    id, bill_no, bill_date, warehouse_id, status
                ) values (?, ?, ?, ?, 1)
                """);
             PreparedStatement requestItem = connection.prepareStatement("""
                     insert into purchase_request_items(
                         id, bill_no, bill_date, request_id, goods_id,
                         unit_id, unit_rate, qty, ordered_qty
                     ) values (?, ?, ?, ?, ?, ?, 1, ?, ?)
                     """);
             PreparedStatement requestPeg = connection.prepareStatement("""
                     insert into production_material_supply_pegs(
                         id, demand_id, supply_type, supply_item_id,
                         allocated_qty, consumed_qty, released_qty,
                         status, idempotency_key
                     ) values (
                         ?, ?, 'PURCHASE_REQUEST_ITEM', ?, ?, 0, ?,
                         'RELEASED', ?
                     )
                      """);
             PreparedStatement packageRequestDocument =
                     connection.prepareStatement("""
                             insert into production_planning_package_documents(
                                 package_id, document_type, document_id,
                                 document_no
                             ) values (?, 'PURCHASE_REQUEST', ?, ?)
                             """)) {
            request.setObject(1, requestId);
            request.setString(2, "PR-" + requestId);
            request.setObject(3, date);
            request.setObject(4, warehouseId);
            request.executeUpdate();
            requestItem.setObject(1, requestItemId);
            requestItem.setString(2, "PR-" + requestId);
            requestItem.setObject(3, date);
            requestItem.setObject(4, requestId);
            requestItem.setObject(5, goodsId);
            requestItem.setObject(6, unitId);
            requestItem.setBigDecimal(7, decimal(quantity));
            requestItem.setBigDecimal(8, decimal(quantity));
            requestItem.executeUpdate();
            requestPeg.setObject(1, requestPegId);
            requestPeg.setObject(2, demandId);
            requestPeg.setObject(3, requestItemId);
            requestPeg.setBigDecimal(4, decimal(quantity));
            requestPeg.setBigDecimal(5, decimal(quantity));
            requestPeg.setString(6, "REQUEST-PEG-" + requestPegId);
            requestPeg.executeUpdate();
            packageRequestDocument.setObject(1, packageId);
            packageRequestDocument.setObject(2, requestId);
            packageRequestDocument.setString(3, "PR-" + requestId);
            packageRequestDocument.executeUpdate();
        }

        try (PreparedStatement order = connection.prepareStatement("""
                insert into purchase_orders(
                    id, bill_no, bill_date, warehouse_id, status
                ) values (?, ?, ?, ?, 1)
                """);
             PreparedStatement orderItem = connection.prepareStatement("""
                     insert into purchase_order_items(
                         id, bill_no, bill_date, order_id, request_item_id,
                         goods_id, unit_id, unit_rate, qty
                     ) values (?, ?, ?, ?, ?, ?, ?, 1, ?)
                     """);
             PreparedStatement orderPeg = connection.prepareStatement("""
                     insert into production_material_supply_pegs(
                         id, demand_id, supply_type, supply_item_id,
                         allocated_qty, consumed_qty, released_qty,
                         expected_date, status, idempotency_key
                     ) values (
                         ?, ?, 'PURCHASE_ORDER_ITEM', ?, ?, 0, 0,
                         ?, 'EFFECTIVE', ?
                     )
                     """);
             PreparedStatement transfer = connection.prepareStatement("""
                     insert into production_material_peg_transfers(
                         id, demand_id, from_peg_id, to_peg_id,
                         request_item_id, order_item_id, transferred_qty,
                         status, idempotency_key
                     ) values (
                         ?, ?, ?, ?, ?, ?, ?, 'EFFECTIVE', ?
                     )
                     """)) {
            order.setObject(1, orderId);
            order.setString(2, "PO-" + orderId);
            order.setObject(3, date);
            order.setObject(4, warehouseId);
            order.executeUpdate();
            orderItem.setObject(1, orderItemId);
            orderItem.setString(2, "PO-" + orderId);
            orderItem.setObject(3, date);
            orderItem.setObject(4, orderId);
            orderItem.setObject(5, requestItemId);
            orderItem.setObject(6, goodsId);
            orderItem.setObject(7, unitId);
            orderItem.setBigDecimal(8, decimal(quantity));
            orderItem.executeUpdate();
            orderPeg.setObject(1, orderPegId);
            orderPeg.setObject(2, demandId);
            orderPeg.setObject(3, orderItemId);
            orderPeg.setBigDecimal(4, decimal(quantity));
            orderPeg.setObject(5, date.plusDays(3));
            orderPeg.setString(6, "ORDER-PEG-" + orderPegId);
            orderPeg.executeUpdate();
            transfer.setObject(1, transferId);
            transfer.setObject(2, demandId);
            transfer.setObject(3, requestPegId);
            transfer.setObject(4, orderPegId);
            transfer.setObject(5, requestItemId);
            transfer.setObject(6, orderItemId);
            transfer.setBigDecimal(7, decimal(quantity));
            transfer.setString(8, "TRANSFER-" + transferId);
            transfer.executeUpdate();
        }
        return new Fixture(
                warehouseId, goodsId, unitId, balanceId,
                planId, packageId, demandId,
                requestId, requestItemId, requestPegId,
                orderId, orderItemId, orderPegId, transferId);
    }

    private static ReceiptConversion convertReceipt(
            Connection connection, Fixture fixture, String quantity)
            throws Exception {
        return convertReceipt(connection, fixture, quantity, null);
    }

    private static ReceiptConversion convertReceipt(
            Connection connection,
            Fixture fixture,
            String quantity,
            ReceiptConversion replay) throws Exception {
        if (replay != null) {
            assertEquals(
                    1,
                    count(
                            connection,
                            """
                            select count(*)
                            from production_material_receipt_allocations
                            where receipt_item_id = ?
                              and order_peg_id = ?
                              and status = 'EFFECTIVE'
                            """,
                            replay.receiptItemId(),
                            fixture.orderPegId()));
            return replay.asReplay();
        }

        UUID receiptId = UUID.randomUUID();
        UUID receiptItemId = UUID.randomUUID();
        UUID drawId = UUID.randomUUID();
        UUID drawItemId = UUID.randomUUID();
        UUID allocationId = UUID.randomUUID();
        LocalDate date = LocalDate.of(2026, 7, 31);
        connection.setAutoCommit(false);
        try {
            try (PreparedStatement receipt = connection.prepareStatement("""
                    insert into purchase_receipts(
                        id, bill_no, bill_date, warehouse_id, status
                    ) values (?, ?, ?, ?, 1)
                    """);
                 PreparedStatement item = connection.prepareStatement("""
                         insert into purchase_receipt_items(
                             id, bill_no, bill_date, receipt_id,
                             order_item_id, goods_id, unit_id,
                             unit_rate, qty
                         ) values (?, ?, ?, ?, ?, ?, ?, 1, ?)
                         """);
                 PreparedStatement balance = connection.prepareStatement("""
                         update stock_balances
                         set qty = qty + ? where id = ?
                         """)) {
                receipt.setObject(1, receiptId);
                receipt.setString(2, "RC-" + receiptId);
                receipt.setObject(3, date);
                receipt.setObject(4, fixture.warehouseId());
                receipt.executeUpdate();
                item.setObject(1, receiptItemId);
                item.setString(2, "RC-" + receiptId);
                item.setObject(3, date);
                item.setObject(4, receiptId);
                item.setObject(5, fixture.orderItemId());
                item.setObject(6, fixture.goodsId());
                item.setObject(7, fixture.unitId());
                item.setBigDecimal(8, decimal(quantity));
                item.executeUpdate();
                balance.setBigDecimal(1, decimal(quantity));
                balance.setObject(2, fixture.balanceId());
                balance.executeUpdate();
            }

            try (PreparedStatement peg = connection.prepareStatement("""
                    update production_material_supply_pegs
                    set consumed_qty = consumed_qty + ?,
                        status = case
                            when consumed_qty + released_qty + ?
                                 = allocated_qty
                            then 'DONE' else 'EFFECTIVE' end
                    where id = ?
                    """)) {
                peg.setBigDecimal(1, decimal(quantity));
                peg.setBigDecimal(2, decimal(quantity));
                peg.setObject(3, fixture.orderPegId());
                peg.executeUpdate();
            }

            UUID reservationId = activeReservation(
                    connection, fixture.demandId(), fixture.balanceId());
            if (reservationId == null) {
                reservationId = UUID.randomUUID();
                try (PreparedStatement reservation =
                             connection.prepareStatement("""
                        insert into stock_reservations(
                            id, order_item_id, goods_id, warehouse_id,
                            qty, consumed_qty, released_qty, status, source,
                            source_doc_type, source_doc_id,
                            owner_type, owner_id, purpose, demand_id,
                            supply_type, supply_id, idempotency_key
                        ) values (
                            ?, null, ?, ?, ?, 0, 0, 0, 2,
                            'PURCHASE_RECEIPT', ?,
                            'PRODUCTION_MATERIAL_DEMAND', ?,
                            'PRODUCTION_MATERIAL', ?,
                            'STOCK_BALANCE', ?, ?
                        )
                        """)) {
                    reservation.setObject(1, reservationId);
                    reservation.setObject(2, fixture.goodsId());
                    reservation.setObject(3, fixture.warehouseId());
                    reservation.setBigDecimal(4, decimal(quantity));
                    reservation.setObject(5, receiptId);
                    reservation.setObject(6, fixture.demandId());
                    reservation.setObject(7, fixture.demandId());
                    reservation.setObject(8, fixture.balanceId());
                    reservation.setString(
                            9, "RECEIPT-RESERVATION-" + receiptId);
                    reservation.executeUpdate();
                }
            } else {
                try (PreparedStatement reservation =
                             connection.prepareStatement("""
                        update stock_reservations
                        set qty = qty + ?, status = 0
                        where id = ?
                        """)) {
                    reservation.setBigDecimal(1, decimal(quantity));
                    reservation.setObject(2, reservationId);
                    reservation.executeUpdate();
                }
            }

            try (PreparedStatement draw = connection.prepareStatement("""
                    insert into stock_documents(
                        id, doc_type, bill_no, bill_date, warehouse_id,
                        plan_no, status
                    ) values (?, 'DRAW', ?, ?, ?, ?, 0)
                    """);
                 PreparedStatement drawItem = connection.prepareStatement("""
                         insert into stock_document_items(
                             id, doc_id, bill_type, bill_no, bill_date,
                             line_no, goods_id, unit_id, unit_rate,
                             qty, base_qty
                         ) values (
                             ?, ?, 'DRAW', ?, ?, 1, ?, ?, 1, ?, ?
                         )
                         """);
                 PreparedStatement packageDoc = connection.prepareStatement("""
                         insert into production_planning_package_documents(
                             package_id, document_type, document_id,
                             document_no
                         ) values (?, 'DRAW', ?, ?)
                         """);
                 PreparedStatement packageItem = connection.prepareStatement("""
                         insert into production_planning_package_document_items(
                             package_id, demand_id, document_type,
                             document_id, document_item_id
                         ) values (?, ?, 'DRAW', ?, ?)
                         """);
                 PreparedStatement planLink = connection.prepareStatement("""
                         insert into plan_draw_links(plan_id, draw_id)
                         values (?, ?)
                         """)) {
                String drawNo = "DRAW-" + drawId;
                draw.setObject(1, drawId);
                draw.setString(2, drawNo);
                draw.setObject(3, date);
                draw.setObject(4, fixture.warehouseId());
                draw.setString(5, "PP-" + fixture.planId());
                draw.executeUpdate();
                drawItem.setObject(1, drawItemId);
                drawItem.setObject(2, drawId);
                drawItem.setString(3, drawNo);
                drawItem.setObject(4, date);
                drawItem.setObject(5, fixture.goodsId());
                drawItem.setObject(6, fixture.unitId());
                drawItem.setBigDecimal(7, decimal(quantity));
                drawItem.setBigDecimal(8, decimal(quantity));
                drawItem.executeUpdate();
                packageDoc.setObject(1, fixture.packageId());
                packageDoc.setObject(2, drawId);
                packageDoc.setString(3, drawNo);
                packageDoc.executeUpdate();
                packageItem.setObject(1, fixture.packageId());
                packageItem.setObject(2, fixture.demandId());
                packageItem.setObject(3, drawId);
                packageItem.setObject(4, drawItemId);
                packageItem.executeUpdate();
                planLink.setObject(1, fixture.planId());
                planLink.setObject(2, drawId);
                planLink.executeUpdate();
            }

            try (PreparedStatement allocation = connection.prepareStatement("""
                         insert into production_material_receipt_allocations(
                             id, receipt_id, receipt_item_id, package_id,
                             demand_id, order_peg_id, reservation_id,
                             draw_id, draw_item_id, allocated_qty,
                             status, idempotency_key
                         ) values (
                             ?, ?, ?, ?, ?, ?, ?, ?, ?, ?,
                             'EFFECTIVE', ?
                         )
                         """)) {
                allocation.setObject(1, allocationId);
                allocation.setObject(2, receiptId);
                allocation.setObject(3, receiptItemId);
                allocation.setObject(4, fixture.packageId());
                allocation.setObject(5, fixture.demandId());
                allocation.setObject(6, fixture.orderPegId());
                allocation.setObject(7, reservationId);
                allocation.setObject(8, drawId);
                allocation.setObject(9, drawItemId);
                allocation.setBigDecimal(10, decimal(quantity));
                allocation.setString(
                        11,
                        "RECEIPT-STOCK:"
                                + receiptItemId
                                + ":"
                                + fixture.orderPegId());
                allocation.executeUpdate();
            }
            connection.commit();
            return new ReceiptConversion(
                    receiptId,
                    receiptItemId,
                    drawId,
                    drawItemId,
                    reservationId,
                    decimal(quantity),
                    false);
        } catch (Exception error) {
            connection.rollback();
            throw error;
        } finally {
            connection.setAutoCommit(true);
        }
    }

    private static void duplicateReceiptMapping(
            Connection connection,
            Fixture fixture,
            ReceiptConversion conversion) throws Exception {
        connection.setAutoCommit(false);
        try (PreparedStatement duplicate = connection.prepareStatement("""
                insert into production_material_receipt_allocations(
                    receipt_id, receipt_item_id, package_id, demand_id,
                    order_peg_id, reservation_id, draw_id, draw_item_id,
                    allocated_qty, status, idempotency_key
                )
                select receipt_id, receipt_item_id, package_id, demand_id,
                       order_peg_id, reservation_id, draw_id, draw_item_id,
                       allocated_qty, status, idempotency_key
                from production_material_receipt_allocations
                where receipt_item_id = ? and order_peg_id = ?
                """)) {
            duplicate.setObject(1, conversion.receiptItemId());
            duplicate.setObject(2, fixture.orderPegId());
            duplicate.executeUpdate();
            connection.commit();
        } catch (PSQLException error) {
            connection.rollback();
            throw error;
        } finally {
            connection.setAutoCommit(true);
        }
    }

    private static void reverseReceipt(
            Connection connection,
            Fixture fixture,
            ReceiptConversion conversion) throws Exception {
        connection.setAutoCommit(false);
        try {
            BigDecimal reservationQty = scalarDecimal(
                    connection,
                    "select qty from stock_reservations where id = ?",
                    conversion.reservationId());
            BigDecimal remaining =
                    reservationQty.subtract(conversion.quantity());
            if (remaining.signum() == 0) {
                execute(
                        connection,
                        """
                        update stock_reservations
                        set released_qty = qty, status = -1,
                            is_deleted = true, deleted_at = now()
                        where id = ?
                        """,
                        conversion.reservationId());
            } else {
                execute(
                        connection,
                        """
                        update stock_reservations
                        set qty = qty - ?
                        where id = ?
                        """,
                        conversion.quantity(),
                        conversion.reservationId());
            }
            execute(
                    connection,
                    """
                    update production_material_supply_pegs
                    set consumed_qty = consumed_qty - ?, status = 'EFFECTIVE'
                    where id = ?
                    """,
                    conversion.quantity(),
                    fixture.orderPegId());
            execute(
                    connection,
                    """
                    update production_material_receipt_allocations
                    set status = 'REVERSED'
                    where receipt_item_id = ?
                      and order_peg_id = ?
                      and status = 'EFFECTIVE'
                    """,
                    conversion.receiptItemId(),
                    fixture.orderPegId());
            execute(
                    connection,
                    """
                    delete from production_planning_package_document_items
                    where document_item_id = ?
                    """,
                    conversion.drawItemId());
            authorizeDrawCleanup(connection, conversion.drawId());
            execute(
                    connection,
                    """
                    update stock_document_items
                    set is_deleted = true where id = ?
                    """,
                    conversion.drawItemId());
            execute(
                    connection,
                    """
                    update stock_documents
                    set status = -1, is_deleted = true, deleted_at = now()
                    where id = ?
                    """,
                    conversion.drawId());
            execute(
                    connection,
                    """
                    update plan_draw_links
                    set is_deleted = true, deleted_at = now()
                    where draw_id = ?
                    """,
                    conversion.drawId());
            execute(
                    connection,
                    """
                    delete from production_planning_package_documents
                    where document_type = 'DRAW' and document_id = ?
                    """,
                    conversion.drawId());
            execute(
                    connection,
                    "update stock_balances set qty = qty - ? where id = ?",
                    conversion.quantity(),
                    fixture.balanceId());
            execute(
                    connection,
                    "update purchase_receipts set status = -1 where id = ?",
                    conversion.receiptId());
            connection.commit();
        } catch (Exception error) {
            connection.rollback();
            throw error;
        } finally {
            connection.setAutoCommit(true);
        }
    }

    private static void reverseOrderSupply(
            Connection connection, Fixture fixture) throws Exception {
        connection.setAutoCommit(false);
        try {
            execute(
                    connection,
                    """
                    update production_material_supply_pegs
                    set released_qty = allocated_qty, status = 'REVERSED'
                    where id = ?
                    """,
                    fixture.orderPegId());
            execute(
                    connection,
                    """
                    update production_material_supply_pegs
                    set released_qty = 0, status = 'EFFECTIVE'
                    where id = ?
                    """,
                    fixture.requestPegId());
            execute(
                    connection,
                    """
                    update production_material_peg_transfers
                    set status = 'REVERSED' where id = ?
                    """,
                    fixture.transferId());
            execute(
                    connection,
                    "update purchase_orders set status = -1 where id = ?",
                    fixture.orderId());
            connection.commit();
        } catch (Exception error) {
            connection.rollback();
            throw error;
        } finally {
            connection.setAutoCommit(true);
        }
    }

    private static void assertPurchaseAction(
            Connection connection,
            UUID demandId,
            String documentType,
            UUID documentId,
            UUID actionItemId,
            String documentNo,
            String status) throws Exception {
        try (PreparedStatement statement = connection.prepareStatement("""
                select action_doc_type, action_doc_id, action_item_id,
                       action_doc_no, action_doc_status
                from v_fulfillment_workbench_actions
                where department = 'PURCHASE' and task_id = ?
                """)) {
            statement.setObject(1, demandId);
            try (ResultSet result = statement.executeQuery()) {
                assertTrue(result.next());
                assertEquals(documentType, result.getString(1));
                assertEquals(documentId, result.getObject(2, UUID.class));
                assertEquals(actionItemId, result.getObject(3, UUID.class));
                assertEquals(documentNo, result.getString(4));
                assertEquals(status, result.getString(5));
                assertFalse(result.next());
            }
        }
    }

    private static void assertDemandCoverage(
            Connection connection, UUID demandId, String expected)
            throws Exception {
        assertQuantity(
                connection,
                """
                select
                    coalesce((
                        select sum(qty - released_qty)
                        from stock_reservations
                        where demand_id = d.id and is_deleted = false
                    ), 0)
                    +
                    coalesce((
                        select sum(
                            allocated_qty - consumed_qty - released_qty
                        )
                        from production_material_supply_pegs
                        where demand_id = d.id and status <> 'REVERSED'
                    ), 0)
                from production_material_demands d where d.id = ?
                """,
                demandId,
                expected);
    }

    private static UUID activeReservation(
            Connection connection, UUID demandId, UUID balanceId)
            throws Exception {
        try (PreparedStatement statement = connection.prepareStatement("""
                select id from stock_reservations
                where demand_id = ? and supply_id = ? and is_deleted = false
                for update
                """)) {
            statement.setObject(1, demandId);
            statement.setObject(2, balanceId);
            try (ResultSet result = statement.executeQuery()) {
                return result.next()
                        ? result.getObject(1, UUID.class)
                        : null;
            }
        }
    }

    private static void setIssuedQty(
            Connection connection, UUID drawItemId, String quantity)
            throws Exception {
        execute(
                connection,
                "update stock_document_items set issued_qty = ? where id = ?",
                decimal(quantity),
                drawItemId);
    }

    private static void updateStatus(
            Connection connection, String table, UUID id, int status)
            throws Exception {
        if (!"purchase_orders".equals(table)
                && !"purchase_receipts".equals(table)) {
            throw new IllegalArgumentException("unsupported table");
        }
        try (PreparedStatement statement = connection.prepareStatement(
                "update " + table + " set status = ? where id = ?")) {
            statement.setInt(1, status);
            statement.setObject(2, id);
            statement.executeUpdate();
        }
    }

    private static void assertConstraint(
            String expectedConstraint, CheckedRunnable action) {
        PSQLException error = assertThrows(PSQLException.class, action::run);
        assertEquals(
                expectedConstraint,
                error.getServerErrorMessage().getConstraint());
    }

    private static void assertQuantity(
            Connection connection, String sql, UUID id, String expected)
            throws Exception {
        assertEquals(
                0,
                decimal(expected).compareTo(
                        scalarDecimal(connection, sql, id)));
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

    private static int count(
            Connection connection, String sql, Object... parameters)
            throws Exception {
        return scalarDecimal(connection, sql, parameters).intValueExact();
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

    private static void bind(
            PreparedStatement statement, Object... parameters)
            throws Exception {
        if (parameters == null) {
            return;
        }
        for (int i = 0; i < parameters.length; i++) {
            statement.setObject(i + 1, parameters[i]);
        }
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

    private record Fixture(
            UUID warehouseId,
            UUID goodsId,
            UUID unitId,
            UUID balanceId,
            UUID planId,
            UUID packageId,
            UUID demandId,
            UUID requestId,
            UUID requestItemId,
            UUID requestPegId,
            UUID orderId,
            UUID orderItemId,
            UUID orderPegId,
            UUID transferId) {}

    private record ReceiptConversion(
            UUID receiptId,
            UUID receiptItemId,
            UUID drawId,
            UUID drawItemId,
            UUID reservationId,
            BigDecimal quantity,
            boolean replayed) {
        private ReceiptConversion asReplay() {
            return new ReceiptConversion(
                    receiptId,
                    receiptItemId,
                    drawId,
                    drawItemId,
                    reservationId,
                    quantity,
                    true);
        }
    }
}
