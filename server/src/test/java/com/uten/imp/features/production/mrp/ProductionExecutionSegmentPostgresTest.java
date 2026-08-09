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
import java.util.List;
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
 * Real PostgreSQL acceptance evidence for the first-class execution-segment
 * model. These tests intentionally exercise deferred constraints at commit,
 * because partial kits and orphaned allocations must never become observable.
 */
@EnabledIfEnvironmentVariable(named = "UTEN_RUN_DB_TESTS", matches = "(?i)true")
class ProductionExecutionSegmentPostgresTest {

    private static final LocalDate BILL_DATE = LocalDate.of(2026, 7, 31);
    private static final String CHECK_VIOLATION = "23514";
    private static final String UNIQUE_VIOLATION = "23505";
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
    void a10B6PersistsReadySixAndZeroHoldWaitingFour() {
        assertTimeoutPreemptively(Duration.ofSeconds(15), () -> {
            try (Connection connection = connection()) {
                SegmentFixture fixture =
                        createSegmentFixture(connection, true);

                assertQuantity(
                        connection,
                        """
                        select sum(planned_qty)
                        from production_execution_segments
                        where package_id = ? and status = 'READY'
                        """,
                        fixture.packageId(),
                        "6");
                assertQuantity(
                        connection,
                        """
                        select sum(planned_qty)
                        from production_execution_segments
                        where package_id = ? and status = 'WAITING'
                        """,
                        fixture.packageId(),
                        "4");
                assertQuantity(
                        connection,
                        """
                        select coalesce(sum(r.qty - r.released_qty), 0)
                        from stock_reservations r
                        join production_material_demands d
                          on d.id = r.demand_id
                        where d.execution_segment_id = ?
                          and r.is_deleted = false
                        """,
                        fixture.waitingSegmentId(),
                        "0");
                assertQuantity(
                        connection,
                        """
                        select count(*)
                        from production_planning_package_documents
                        where execution_segment_id = ?
                          and document_type = 'DRAW'
                        """,
                        fixture.waitingSegmentId(),
                        "0");
                assertQuantity(
                        connection,
                        """
                        select sum(r.qty - r.released_qty)
                        from stock_reservations r
                        join production_material_demands d
                          on d.id = r.demand_id
                        where d.execution_segment_id = ?
                          and r.is_deleted = false
                        """,
                        fixture.readySegmentId(),
                        "12");
            }
        });
    }

    @Test
    void exactSnapshotPersists9999Over4000DemandReservationAndDrawAsThree() {
        assertTimeoutPreemptively(Duration.ofSeconds(15), () -> {
            try (Connection connection = connection()) {
                ExactDemandFixture fixture =
                        createExactDemandFixture(connection);

                assertEquals(
                        "EXACT_SNAPSHOT|9999.0000|3.0000",
                        scalarText(
                                connection,
                                """
                                select concat_ws(
                                    '|', requirement_mode,
                                    required_for_product_qty::text,
                                    required_qty::text)
                                from production_material_demands
                                where id = ?
                                """,
                                fixture.demandId()));
                assertQuantity(
                        connection,
                        """
                        select sum(qty - released_qty)
                        from stock_reservations
                        where demand_id = ? and is_deleted = false
                        """,
                        fixture.demandId(),
                        "3");
                assertQuantity(
                        connection,
                        """
                        select sum(i.base_qty)
                        from production_planning_package_document_items m
                        join stock_document_items i
                          on i.id = m.document_item_id
                        where m.demand_id = ? and m.document_type = 'DRAW'
                        """,
                        fixture.demandId(),
                        "3");

                assertConstraint(
                        connection,
                        "production_material_demand_exact_snapshot_guard",
                        """
                        update production_material_demands
                        set required_qty = 2.9997
                        where id = ?
                        """,
                        fixture.demandId());
                assertConstraint(
                        connection,
                        "production_material_demand_exact_snapshot_guard",
                        """
                        update production_material_demands
                        set requirement_fingerprint = ?
                        where id = ?
                        """,
                        "b".repeat(64), fixture.demandId());
                assertConstraint(
                        connection,
                        "production_execution_segment_requirement_immutable_guard",
                        """
                        update production_execution_segments
                        set material_requirement_mode = 'ZERO_MATERIAL',
                            zero_material_reason = 'DIRECT_MAKE'
                        where id = ?
                        """,
                        fixture.segmentId());
            }
        });
    }

    @Test
    void explicitDeferReleaseRequiresEventAndAdvancesVersionExactlyOnce() {
        assertTimeoutPreemptively(Duration.ofSeconds(15), () -> {
            try (Connection connection = connection()) {
                SegmentFixture fixture =
                        createSegmentFixture(connection, false, false);

                assertEquals(
                        "WAITING|false|0",
                        scalarText(
                                connection,
                                """
                                select concat_ws(
                                    '|', status,
                                    auto_promote_when_ready::text,
                                    lock_version::text)
                                from production_execution_segments
                                where id = ?
                                """,
                                fixture.waitingSegmentId()));

                connection.setAutoCommit(false);
                try {
                    execute(
                            connection,
                            """
                            update production_execution_segments
                            set auto_promote_when_ready = true
                            where id = ? and lock_version = 0
                            """,
                            fixture.waitingSegmentId());
                    PSQLException missingEvent = assertThrows(
                            PSQLException.class, connection::commit);
                    assertEquals(CHECK_VIOLATION, missingEvent.getSQLState());
                    assertEquals(
                            "production_execution_segment_defer_release_event_guard",
                            missingEvent.getServerErrorMessage().getConstraint());
                    connection.rollback();
                } finally {
                    connection.setAutoCommit(true);
                }

                connection.setAutoCommit(false);
                try {
                    execute(
                            connection,
                            """
                            update production_execution_segments
                            set auto_promote_when_ready = true
                            where id = ? and lock_version = 0
                            """,
                            fixture.waitingSegmentId());
                    assertEquals(
                            "1",
                            scalarText(
                                    connection,
                                    """
                                    select lock_version::text
                                    from production_execution_segments
                                    where id = ?
                                    """,
                                    fixture.waitingSegmentId()));
                    execute(
                            connection,
                            """
                            insert into production_execution_segment_events(
                                execution_segment_id, action,
                                idempotency_key, request_hash,
                                expected_version, resulting_version)
                            values (?, 'RELEASE_DEFER', ?, ?, 0, 1)
                            """,
                            fixture.waitingSegmentId(),
                            "release-defer-" + fixture.waitingSegmentId(),
                            "f".repeat(64));
                    connection.commit();
                } catch (Exception error) {
                    connection.rollback();
                    throw error;
                } finally {
                    connection.setAutoCommit(true);
                }

                assertEquals(
                        "WAITING|true|1",
                        scalarText(
                                connection,
                                """
                                select concat_ws(
                                    '|', status,
                                    auto_promote_when_ready::text,
                                    lock_version::text)
                                from production_execution_segments
                                where id = ?
                                """,
                                fixture.waitingSegmentId()));
                assertQuantity(
                        connection,
                        """
                        select count(*)
                        from production_execution_segment_events
                        where execution_segment_id = ?
                          and action = 'RELEASE_DEFER'
                          and expected_version = 0
                          and resulting_version = 1
                        """,
                        fixture.waitingSegmentId(),
                        "1");

                PSQLException cannotDeferAgain = assertThrows(
                        PSQLException.class,
                        () -> execute(
                                connection,
                                """
                                update production_execution_segments
                                set auto_promote_when_ready = false
                                where id = ?
                                """,
                                fixture.waitingSegmentId()));
                assertEquals(
                        CHECK_VIOLATION,
                        cannotDeferAgain.getSQLState());
                assertEquals(
                        "production_execution_segment_readiness_policy_guard",
                        cannotDeferAgain.getServerErrorMessage().getConstraint());
            }
        });
    }


    @Test
    void assignmentScopeRejectsNonProductionWorkshopAndNonDirectTeam() {
        assertTimeoutPreemptively(Duration.ofSeconds(15), () -> {
            try (Connection connection = connection()) {
                SegmentFixture fixture =
                        createSegmentFixture(connection, false);
                UUID engineeringGroup = scalarUuid(
                        connection,
                        "select id from departments where code = 'GRP_PE'");
                UUID injectionWorkshop = scalarUuid(
                        connection,
                        "select id from departments where code = 'WS_ZHUSU'");
                UUID metalWorkshop = scalarUuid(
                        connection,
                        "select id from departments where code = 'WS_WJTZ'");

                assertConstraint(
                        connection,
                        "production_execution_segment_production_workshop_guard",
                        """
                        update production_execution_segments
                        set workshop_department_id = ?
                        where id = ?
                        """,
                        engineeringGroup,
                        fixture.waitingSegmentId());

                execute(
                        connection,
                        """
                        update production_execution_segments
                        set workshop_department_id = ?
                        where id = ?
                        """,
                        injectionWorkshop,
                        fixture.waitingSegmentId());
                assertEquals(
                        injectionWorkshop,
                        scalarUuid(
                                connection,
                                """
                                select workshop_department_id
                                from production_execution_segments
                                where id = ?
                                """,
                                fixture.waitingSegmentId()));

                assertConstraint(
                        connection,
                        "production_execution_segment_direct_team_guard",
                        """
                        update production_execution_segments
                        set team_department_id = ?
                        where id = ?
                        """,
                        metalWorkshop,
                        fixture.waitingSegmentId());
            }
        });
    }
    @Test
    void b4InTwoReceiptsPromotesOnlyAfterWholeKitCanBeCommitted() {
        assertTimeoutPreemptively(Duration.ofSeconds(20), () -> {
            try (Connection connection = connection()) {
                SegmentFixture fixture =
                        createSegmentFixture(connection, true);

                Receipt first = createApprovedReceipt(
                        connection, fixture, "2", true);
                assertEquals(
                        "WAITING",
                        scalarText(
                                connection,
                                """
                                select status
                                from production_execution_segments
                                where id = ?
                                """,
                                fixture.waitingSegmentId()));
                assertQuantity(
                        connection,
                        """
                        select count(*)
                        from production_material_receipt_allocations
                        where receipt_id = ?
                        """,
                        first.id(),
                        "0");

                connection.setAutoCommit(false);
                try {
                    insertReservation(
                            connection,
                            fixture.packageId(),
                            fixture.waitingADemandId(),
                            fixture.materialAId(),
                            fixture.warehouseId(),
                            fixture.balanceAId(),
                            "2");
                    PSQLException partial = assertThrows(
                            PSQLException.class, connection::commit);
                    assertEquals(CHECK_VIOLATION, partial.getSQLState());
                    assertEquals(
                            "production_execution_segment_waiting_allocation_guard",
                            partial.getServerErrorMessage().getConstraint());
                    connection.rollback();
                } finally {
                    connection.setAutoCommit(true);
                }
                assertQuantity(
                        connection,
                        """
                        select coalesce(sum(r.qty - r.released_qty), 0)
                        from stock_reservations r
                        where r.demand_id = ? and r.is_deleted = false
                        """,
                        fixture.waitingBDemandId(),
                        "0");

                Receipt second = createApprovedReceipt(
                        connection, fixture, "2", true);
                promoteWaitingSegment(
                        connection, fixture, List.of(first, second));

                assertEquals(
                        "READY",
                        scalarText(
                                connection,
                                """
                                select status
                                from production_execution_segments
                                where id = ?
                                """,
                                fixture.waitingSegmentId()));
                assertQuantity(
                        connection,
                        """
                        select coalesce(sum(r.qty - r.released_qty), 0)
                        from stock_reservations r
                        where r.demand_id = ? and r.is_deleted = false
                        """,
                        fixture.waitingADemandId(),
                        "4");
                assertQuantity(
                        connection,
                        """
                        select coalesce(sum(r.qty - r.released_qty), 0)
                        from stock_reservations r
                        where r.demand_id = ? and r.is_deleted = false
                        """,
                        fixture.waitingBDemandId(),
                        "4");
                assertQuantity(
                        connection,
                        """
                        select coalesce(sum(a.allocated_qty), 0)
                        from production_material_receipt_allocations a
                        where a.order_peg_id = ? and a.status = 'EFFECTIVE'
                        """,
                        fixture.waitingBOrderPegId(),
                        "4");
                assertQuantity(
                        connection,
                        """
                        select coalesce(sum(i.base_qty), 0)
                        from production_planning_package_documents h
                        join production_planning_package_document_items m
                          on m.package_id = h.package_id
                         and m.document_type = h.document_type
                         and m.document_id = h.document_id
                        join stock_document_items i
                          on i.id = m.document_item_id
                        where h.execution_segment_id = ?
                          and h.document_type = 'DRAW'
                        """,
                        fixture.waitingSegmentId(),
                        "8");

                PSQLException reverse = assertThrows(
                        PSQLException.class,
                        () -> execute(
                                connection,
                                """
                                update purchase_receipts
                                set status = -1
                                where id = ?
                                """,
                                first.id()));
                assertEquals(CHECK_VIOLATION, reverse.getSQLState());
                assertEquals(
                        "production_purchase_receipt_reversal_guard",
                        reverse.getServerErrorMessage().getConstraint());

                reverseReceiptByDemotingWholeSegment(
                        connection, fixture, first);
                assertEquals(
                        "WAITING",
                        scalarText(
                                connection,
                                """
                                select status
                                from production_execution_segments
                                where id = ?
                                """,
                                fixture.waitingSegmentId()));
                assertEquals(
                        "-1",
                        scalarText(
                                connection,
                                """
                                select status::text
                                from purchase_receipts
                                where id = ?
                                """,
                                first.id()));
                assertQuantity(
                        connection,
                        """
                        select count(*)
                        from production_material_receipt_allocations
                        where order_peg_id = ?
                          and status = 'EFFECTIVE'
                        """,
                        fixture.waitingBOrderPegId(),
                        "0");
            }
        });
    }

    @Test
    void subcontractReturnPromotesOnlyAfterTheWholeWaitingKitIsAvailable() {
        assertTimeoutPreemptively(Duration.ofSeconds(25), () -> {
            try (Connection connection = connection()) {
                SegmentFixture fixture =
                        createSegmentFixture(connection, false);
                SubcontractSupply supply =
                        attachSubcontractSupply(connection, fixture);

                assertConstraint(
                        connection,
                        "production_subcontract_transfer_append_only_guard",
                        """
                        delete from
                          production_material_subcontract_peg_transfers
                        where id = ?
                        """,
                        supply.transferId());
                assertConstraint(
                        connection,
                        "production_subcontract_transfer_target_guard",
                        """
                        update production_material_supply_pegs
                        set allocated_qty = 3 where id = ?
                        """,
                        supply.orderPegId());
                assertConstraint(
                        connection,
                        "production_subcontract_peg_receipt_coverage_guard",
                        """
                        update production_material_supply_pegs
                        set consumed_qty = 1 where id = ?
                        """,
                        supply.orderPegId());

                assertConstraint(
                        connection,
                        "production_subcontract_order_item_supply_guard",
                        """
                        update subcontract_order_items
                        set qty = 3 where id = ?
                        """,
                        supply.orderItemId());
                assertConstraint(
                        connection,
                        "production_subcontract_application_supply_guard",
                        """
                        update subcontract_applications
                        set status = -1 where id = ?
                        """,
                        supply.applicationId());

                assertQuantity(
                        connection,
                        """
                        select sum(planned_qty)
                        from production_execution_segments
                        where package_id = ? and status = 'READY'
                        """,
                        fixture.packageId(),
                        "6");
                assertQuantity(
                        connection,
                        """
                        select sum(planned_qty)
                        from production_execution_segments
                        where package_id = ? and status = 'WAITING'
                        """,
                        fixture.packageId(),
                        "4");
                assertEquals(
                        "SUBCONTRACT_ORDER|1|WAITING_RETURN",
                        scalarText(
                                connection,
                                """
                                select concat_ws(
                                    '|', action_doc_type,
                                    action_doc_status, task_status)
                                from v_fulfillment_workbench_actions
                                where department = 'SUBCONTRACT'
                                  and task_id = ?
                                """,
                                fixture.waitingBDemandId()));

                PSQLException orderReverse = assertThrows(
                        PSQLException.class,
                        () -> execute(
                                connection,
                                """
                                update subcontract_orders
                                set status = -1 where id = ?
                                """,
                                supply.orderId()));
                assertEquals(CHECK_VIOLATION, orderReverse.getSQLState());
                assertEquals(
                        "production_subcontract_order_reversal_guard",
                        orderReverse.getServerErrorMessage().getConstraint());

                Receipt first = createApprovedSubcontractReceipt(
                        connection, fixture, supply, "2");
                assertFalse(promoteSubcontractWaitingSegment(
                        connection, fixture, supply,
                        List.of(first)));
                assertEquals(
                        "WAITING",
                        scalarText(
                                connection,
                                """
                                select status
                                from production_execution_segments
                                where id = ?
                                """,
                                fixture.waitingSegmentId()));
                assertQuantity(
                        connection,
                        """
                        select count(*)
                        from
                          production_material_subcontract_receipt_allocations
                        where receipt_id = ?
                        """,
                        first.id(),
                        "0");
                assertQuantity(
                        connection,
                        """
                        select coalesce(sum(qty - released_qty), 0)
                        from stock_reservations
                        where demand_id in (?, ?)
                          and is_deleted = false
                        """,
                        fixture.waitingADemandId(),
                        fixture.waitingBDemandId(),
                        "0");

                Receipt second = createApprovedSubcontractReceipt(
                        connection, fixture, supply, "2");
                assertTrue(promoteSubcontractWaitingSegment(
                        connection, fixture, supply,
                        List.of(first, second)));
                assertFalse(promoteSubcontractWaitingSegment(
                        connection, fixture, supply,
                        List.of(first, second)),
                        "replayed receipt callback must not duplicate a kit");

                assertEquals(
                        "READY",
                        scalarText(
                                connection,
                                """
                                select status
                                from production_execution_segments
                                where id = ?
                                """,
                                fixture.waitingSegmentId()));
                assertQuantity(
                        connection,
                        """
                        select coalesce(sum(qty - released_qty), 0)
                        from stock_reservations
                        where demand_id in (?, ?)
                          and is_deleted = false
                        """,
                        fixture.waitingADemandId(),
                        fixture.waitingBDemandId(),
                        "8");
                assertQuantity(
                        connection,
                        """
                        select coalesce(sum(allocated_qty), 0)
                        from
                          production_material_subcontract_receipt_allocations
                        where order_peg_id = ?
                          and status = 'EFFECTIVE'
                        """,
                        supply.orderPegId(),
                        "4");
                assertQuantity(
                        connection,
                        """
                        select consumed_qty
                        from production_material_supply_pegs
                        where id = ?
                        """,
                        supply.orderPegId(),
                        "4");
                assertQuantity(
                        connection,
                        """
                        select coalesce(sum(item.base_qty), 0)
                        from production_planning_package_documents header
                        join stock_document_items item
                          on item.doc_id = header.document_id
                         and item.is_deleted = false
                        where header.execution_segment_id = ?
                          and header.document_type = 'DRAW'
                        """,
                        fixture.waitingSegmentId(),
                        "8");
                assertEquals(
                        "SUBCONTRACT_RECEIPT|1|COVERED",
                        scalarText(
                                connection,
                                """
                                select concat_ws(
                                    '|', action_doc_type,
                                    action_doc_status, task_status)
                                from v_fulfillment_workbench_actions
                                where department = 'SUBCONTRACT'
                                  and task_id = ?
                                """,
                                fixture.waitingBDemandId()));

                PSQLException duplicate = assertThrows(
                        PSQLException.class,
                        () -> execute(
                                connection,
                                """
                                insert into
                                  production_material_subcontract_receipt_allocations(
                                    id, receipt_id, receipt_item_id,
                                    package_id, demand_id, order_peg_id,
                                    reservation_id, draw_id, draw_item_id,
                                    allocated_qty, status, idempotency_key)
                                select ?, receipt_id, receipt_item_id,
                                       package_id, demand_id, order_peg_id,
                                       reservation_id, draw_id, draw_item_id,
                                       allocated_qty, status, ?
                                from
                                  production_material_subcontract_receipt_allocations
                                where order_peg_id = ?
                                  and status = 'EFFECTIVE'
                                limit 1
                                """,
                                UUID.randomUUID(),
                                "duplicate-" + UUID.randomUUID(),
                                supply.orderPegId()));
                assertEquals(UNIQUE_VIOLATION, duplicate.getSQLState());
                assertEquals(
                        "uq_production_material_subcontract_receipt_active",
                        duplicate.getServerErrorMessage().getConstraint());

                assertConstraint(
                        connection,
                        "production_subcontract_receipt_append_only_guard",
                        """
                        delete from
                          production_material_subcontract_receipt_allocations
                        where receipt_id = ?
                        """,
                        first.id());
                assertConstraint(
                        connection,
                        "production_linked_stock_document_update_guard",
                        """
                        update stock_documents
                        set warehouse_id = null
                        where id in (
                            select draw_id
                            from
                              production_material_subcontract_receipt_allocations
                            where receipt_id = ?
                        )
                        """,
                        first.id());
                assertConstraint(
                        connection,
                        "production_subcontract_receipt_item_capacity_guard",
                        """
                        update subcontract_receipt_items
                        set qty = 1
                        where id = ?
                        """,
                        first.itemId());

                PSQLException receiptReverse = assertThrows(
                        PSQLException.class,
                        () -> execute(
                                connection,
                                """
                                update subcontract_receipts
                                set status = -1 where id = ?
                                """,
                                first.id()));
                assertEquals(CHECK_VIOLATION, receiptReverse.getSQLState());
                assertEquals(
                        "production_subcontract_receipt_reversal_guard",
                        receiptReverse.getServerErrorMessage().getConstraint());

                execute(
                        connection,
                        """
                        update stock_document_items
                        set issued_qty = 1
                        where id in (
                            select draw_item_id
                            from
                              production_material_subcontract_receipt_allocations
                            where receipt_id = ?
                        )
                        """,
                        first.id());
                assertConstraint(
                        connection,
                        "production_subcontract_receipt_issued_draw_guard",
                        """
                        update
                          production_material_subcontract_receipt_allocations
                        set status = 'REVERSED'
                        where receipt_id = ?
                        """,
                        first.id());
                execute(
                        connection,
                        """
                        update stock_document_items
                        set issued_qty = 0
                        where id in (
                            select draw_item_id
                            from
                              production_material_subcontract_receipt_allocations
                            where receipt_id = ?
                        )
                        """,
                        first.id());

            }
        });
    }

    @Test
    void productionLinkedSupplySourcesRejectGenericMutation() {
        assertTimeoutPreemptively(Duration.ofSeconds(20), () -> {
            try (Connection connection = connection()) {
                SegmentFixture fixture =
                        createSegmentFixture(connection, false);
                UUID requestId = UUID.randomUUID();
                UUID requestItemId = UUID.randomUUID();
                UUID requestPegId = UUID.randomUUID();
                UUID applicationId = UUID.randomUUID();
                UUID applicationItemId = UUID.randomUUID();
                UUID applicationPegId = UUID.randomUUID();

                execute(
                        connection,
                        """
                        insert into purchase_requests(
                            id, bill_no, bill_date, warehouse_id,
                            need_date, status)
                        values (?, ?, ?, ?, ?, 0)
                        """,
                        requestId, "PR-" + requestId, BILL_DATE,
                        fixture.warehouseId(), BILL_DATE.plusDays(3));
                execute(
                        connection,
                        """
                        insert into purchase_request_items(
                            id, bill_no, bill_date, request_id,
                            goods_id, unit_id, unit_rate, qty)
                        values (?, ?, ?, ?, ?, ?, 1, 4)
                        """,
                        requestItemId, "PR-" + requestId, BILL_DATE,
                        requestId, fixture.materialBId(), fixture.unitId());
                execute(
                        connection,
                        """
                        insert into production_material_supply_pegs(
                            id, demand_id, supply_type, supply_item_id,
                            allocated_qty, consumed_qty, released_qty,
                            status, idempotency_key)
                        values (
                            ?, ?, 'PURCHASE_REQUEST_ITEM', ?,
                            4, 0, 0, 'EFFECTIVE', ?)
                        """,
                        requestPegId, fixture.waitingBDemandId(),
                        requestItemId, "source-request-" + requestPegId);

                execute(
                        connection,
                        """
                        update production_material_demands
                        set supply_route = 'SUBCONTRACT'
                        where id = ?
                        """,
                        fixture.waitingADemandId());
                execute(
                        connection,
                        """
                        insert into subcontract_applications(
                            id, bill_no, bill_date, warehouse_id,
                            need_date, status)
                        values (?, ?, ?, ?, ?, 0)
                        """,
                        applicationId, "SA-" + applicationId, BILL_DATE,
                        fixture.warehouseId(), BILL_DATE.plusDays(3));
                execute(
                        connection,
                        """
                        insert into subcontract_application_items(
                            id, bill_no, bill_date, application_id,
                            goods_id, unit_id, unit_rate, qty)
                        values (?, ?, ?, ?, ?, ?, 1, 4)
                        """,
                        applicationItemId, "SA-" + applicationId, BILL_DATE,
                        applicationId, fixture.materialAId(), fixture.unitId());
                execute(
                        connection,
                        """
                        insert into production_material_supply_pegs(
                            id, demand_id, supply_type, supply_item_id,
                            allocated_qty, consumed_qty, released_qty,
                            status, idempotency_key)
                        values (
                            ?, ?, 'SUBCONTRACT_APPLICATION_ITEM', ?,
                            4, 0, 0, 'EFFECTIVE', ?)
                        """,
                        applicationPegId, fixture.waitingADemandId(),
                        applicationItemId,
                        "source-application-" + applicationPegId);

                assertConstraint(
                        connection,
                        "production_material_supply_peg_append_only_guard",
                        """
                        delete from production_material_supply_pegs
                        where id = ?
                        """,
                        requestPegId);
                assertConstraint(
                        connection,
                        "production_material_demand_identity_guard",
                        """
                        update production_material_demands
                        set execution_segment_id = ?
                        where id = ?
                        """,
                        fixture.readySegmentId(),
                        fixture.waitingBDemandId());

                assertConstraint(
                        connection,
                        "production_purchase_request_item_supply_guard",
                        "update purchase_request_items set qty = 3 where id = ?",
                        requestItemId);
                assertConstraint(
                        connection,
                        "production_subcontract_application_item_supply_guard",
                        """
                        delete from subcontract_application_items
                        where id = ?
                        """,
                        applicationItemId);
                assertConstraint(
                        connection,
                        "production_purchase_request_supply_guard",
                        """
                        update purchase_requests
                        set need_date = need_date + 1 where id = ?
                        """,
                        requestId);
                assertConstraint(
                        connection,
                        "production_subcontract_application_supply_guard",
                        """
                        update subcontract_applications
                        set status = -1 where id = ?
                        """,
                        applicationId);
                assertConstraint(
                        connection,
                        "production_subcontract_application_peg_consumption_guard",
                        """
                        update production_material_supply_pegs
                        set consumed_qty = 1 where id = ?
                        """,
                        applicationPegId);

                execute(
                        connection,
                        """
                        update production_material_supply_pegs
                        set released_qty = allocated_qty,
                            status = 'REVERSED'
                        where id in (?, ?)
                        """,
                        requestPegId, applicationPegId);
                assertConstraint(
                        connection,
                        "production_purchase_request_item_supply_guard",
                        "update purchase_request_items set qty = 3 where id = ?",
                        requestItemId);
                execute(
                        connection,
                        "update purchase_requests set status = -1 where id = ?",
                        requestId);
                assertConstraint(
                        connection,
                        "production_purchase_request_lifecycle_guard",
                        """
                        update purchase_requests
                        set status = 0 where id = ?
                        """,
                        requestId);
                execute(
                        connection,
                        """
                        update subcontract_applications
                        set status = -1 where id = ?
                        """,
                        applicationId);
            }
        });
    }

    @Test
    void confirmIdentitySerializesConcurrentWritersAndReplaysOneRow() {
        assertTimeoutPreemptively(Duration.ofSeconds(20), () -> {
            BarePlan plan;
            try (Connection setup = connection()) {
                plan = createBarePlan(setup);
            }

            UUID firstPackageId = UUID.randomUUID();
            String key = "confirm-" + UUID.randomUUID();
            CountDownLatch firstInserted = new CountDownLatch(1);
            CountDownLatch allowFirstCommit = new CountDownLatch(1);
            CountDownLatch secondStarted = new CountDownLatch(1);
            CountDownLatch secondFinished = new CountDownLatch(1);

            try (ExecutorService executor = Executors.newFixedThreadPool(2)) {
                Future<Boolean> first = executor.submit(() -> {
                    try (Connection connection = connection()) {
                        connection.setAutoCommit(false);
                        try {
                            insertLegacyPackage(
                                    connection,
                                    firstPackageId,
                                    plan,
                                    key);
                            firstInserted.countDown();
                            assertTrue(allowFirstCommit.await(
                                    5, TimeUnit.SECONDS));
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
                            insertLegacyPackage(
                                    connection,
                                    UUID.randomUUID(),
                                    plan,
                                    key);
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
                        "the duplicate confirm must serialize on its unique key");
                allowFirstCommit.countDown();
                assertTrue(first.get(5, TimeUnit.SECONDS));
                assertEquals(
                        UNIQUE_VIOLATION,
                        second.get(5, TimeUnit.SECONDS));
            } finally {
                allowFirstCommit.countDown();
            }

            try (Connection verification = connection()) {
                assertQuantity(
                        verification,
                        """
                        select count(*)
                        from production_planning_packages
                        where plan_id = ? and idempotency_key = ?
                          and is_deleted = false
                        """,
                        plan.planId(),
                        key,
                        "1");
                assertEquals(
                        firstPackageId,
                        scalarUuid(
                                verification,
                                """
                                select id
                                from production_planning_packages
                                where plan_id = ? and idempotency_key = ?
                                """,
                                plan.planId(),
                                key));

                PSQLException conflictingKey = assertThrows(
                        PSQLException.class,
                        () -> insertLegacyPackage(
                                verification,
                                UUID.randomUUID(),
                                plan,
                                "different-" + UUID.randomUUID()));
                assertEquals(
                        UNIQUE_VIOLATION,
                        conflictingKey.getSQLState());
                assertEquals(
                        "uq_production_planning_package_active_plan",
                        conflictingKey.getServerErrorMessage().getConstraint());
            }
        });
    }

    @Test
    void wholeUnstartedPackageCanBeCancelledOrReversedAndReleasesStock() {
        assertTimeoutPreemptively(Duration.ofSeconds(20), () -> {
            try (Connection connection = connection()) {
                SegmentFixture cancelled =
                        createSegmentFixture(connection, false);
                applyLifecycle(connection, cancelled, "CANCELLED");
                assertLifecycle(connection, cancelled, "CANCELLED");

                SegmentFixture reversed =
                        createSegmentFixture(connection, false);
                applyLifecycle(connection, reversed, "REVERSED");
                assertLifecycle(connection, reversed, "REVERSED");
            }
        });
    }

    @Test
    void legacyModelZeroPackageRemainsValidWithoutSegments() {
        assertTimeoutPreemptively(Duration.ofSeconds(15), () -> {
            try (Connection connection = connection()) {
                BarePlan plan = createBarePlan(connection);
                UUID packageId = UUID.randomUUID();
                insertLegacyPackage(
                        connection,
                        packageId,
                        plan,
                        "legacy-" + UUID.randomUUID());
                UUID demandId = UUID.randomUUID();
                execute(
                        connection,
                        """
                        insert into production_material_demands(
                            id, package_id, plan_id, warehouse_id,
                            goods_id, unit_id, required_qty, need_date,
                            supply_route, status, idempotency_key
                        ) values (
                            ?, ?, ?, ?, ?, ?, 3, ?,
                            'BUY', 'OPEN', ?
                        )
                        """,
                        demandId,
                        packageId,
                        plan.planId(),
                        plan.warehouseId(),
                        plan.materialId(),
                        plan.unitId(),
                        BILL_DATE.plusDays(3),
                        "legacy-demand-" + demandId);

                assertQuantity(
                        connection,
                        """
                        select execution_model_version
                        from production_planning_packages
                        where id = ?
                        """,
                        packageId,
                        "0");
                assertQuantity(
                        connection,
                        """
                        select count(*)
                        from production_execution_segments
                        where package_id = ?
                        """,
                        packageId,
                        "0");
                assertQuantity(
                        connection,
                        """
                        select count(*)
                        from production_material_demands
                        where id = ?
                          and execution_segment_id is null
                          and source_plan_item_id is null
                          and per_product_qty is null
                        """,
                        demandId,
                        "1");
            }
        });
    }

    private static ExactDemandFixture createExactDemandFixture(
            Connection connection) throws Exception {
        UUID unitId = UUID.randomUUID();
        UUID productId = UUID.randomUUID();
        UUID materialId = UUID.randomUUID();
        UUID warehouseId = UUID.randomUUID();
        UUID balanceId = UUID.randomUUID();
        UUID planId = UUID.randomUUID();
        UUID planItemId = UUID.randomUUID();
        UUID packageId = UUID.randomUUID();
        UUID segmentId = UUID.randomUUID();
        UUID demandId = UUID.randomUUID();
        String planNo = "PP-EXACT-" + planId;

        connection.setAutoCommit(false);
        try {
            execute(
                    connection,
                    "insert into units(id, code, name) values (?, ?, 'piece')",
                    unitId,
                    "UNIT-" + unitId);
            for (UUID goodsId : List.of(productId, materialId)) {
                execute(
                        connection,
                        """
                        insert into goods(id, code, name, min_qty)
                        values (?, ?, 'exact fixture goods', 0)
                        """,
                        goodsId,
                        "GOODS-" + goodsId);
            }
            execute(
                    connection,
                    """
                    insert into warehouses(id, code, name)
                    values (?, ?, 'exact fixture warehouse')
                    """,
                    warehouseId,
                    "WH-" + warehouseId);
            execute(
                    connection,
                    """
                    insert into stock_balances(
                        id, warehouse_id, goods_id, qty
                    ) values (?, ?, ?, 3)
                    """,
                    balanceId, warehouseId, materialId);
            execute(
                    connection,
                    """
                    insert into production_plans(
                        id, bill_no, bill_date, delivery_date, status
                    ) values (?, ?, ?, ?, 1)
                    """,
                    planId, planNo, BILL_DATE, BILL_DATE.plusDays(7));
            execute(
                    connection,
                    """
                    insert into production_plan_items(
                        id, bill_no, bill_date, plan_id, line_no,
                        product_no, goods_id, unit_id, unit_rate, qty
                    ) values (?, ?, ?, ?, 1, ?, ?, ?, 1, 9999)
                    """,
                    planItemId, planNo, BILL_DATE, planId,
                    "PRODUCT-" + planItemId, productId, unitId);
            execute(
                    connection,
                    """
                    insert into production_planning_packages(
                        id, plan_id, warehouse_id, idempotency_key,
                        request_hash, preview_fingerprint, status,
                        execution_model_version
                    ) values (?, ?, ?, ?, ?, ?, 'CONFIRMED', 1)
                    """,
                    packageId, planId, warehouseId,
                    "package-exact-" + packageId,
                    "a".repeat(64), "b".repeat(64));
            insertSegment(
                    connection, segmentId, packageId, planId, planItemId,
                    1, productId, unitId, "9999", "READY");
            execute(
                    connection,
                    """
                    insert into production_material_demands(
                        id, package_id, plan_id, warehouse_id,
                        goods_id, unit_id, required_qty, need_date,
                        supply_route, status, idempotency_key,
                        execution_segment_id, source_plan_item_id,
                        per_product_qty, requirement_mode,
                        required_for_product_qty,
                        requirement_fingerprint
                    ) values (
                        ?, ?, ?, ?, ?, ?, 3, ?,
                        'BUY', 'ALLOCATED', ?, ?, ?,
                        0.000301, 'EXACT_SNAPSHOT', 9999, ?
                    )
                    """,
                    demandId, packageId, planId, warehouseId,
                    materialId, unitId, BILL_DATE.plusDays(3),
                    "demand-exact-" + demandId,
                    segmentId, planItemId, "a".repeat(64));
            insertReservation(
                    connection, packageId, demandId, materialId,
                    warehouseId, balanceId, "3");
            createDraw(
                    connection, packageId, segmentId, planId, planNo,
                    warehouseId,
                    List.of(new DrawLine(
                            demandId, materialId, unitId, decimal("3"))));
            connection.commit();
        } catch (Exception error) {
            connection.rollback();
            throw error;
        } finally {
            connection.setAutoCommit(true);
        }
        return new ExactDemandFixture(segmentId, demandId);
    }

    private static SegmentFixture createSegmentFixture(
            Connection connection,
            boolean withWaitingPurchasePeg) throws Exception {
        return createSegmentFixture(
                connection, withWaitingPurchasePeg, true);
    }

    private static SegmentFixture createSegmentFixture(
            Connection connection,
            boolean withWaitingPurchasePeg,
            boolean waitingAutoPromote) throws Exception {
        UUID unitId = UUID.randomUUID();
        UUID productId = UUID.randomUUID();
        UUID materialAId = UUID.randomUUID();
        UUID materialBId = UUID.randomUUID();
        UUID warehouseId = UUID.randomUUID();
        UUID balanceAId = UUID.randomUUID();
        UUID balanceBId = UUID.randomUUID();
        UUID planId = UUID.randomUUID();
        UUID planItemId = UUID.randomUUID();
        UUID packageId = UUID.randomUUID();
        UUID readySegmentId = UUID.randomUUID();
        UUID waitingSegmentId = UUID.randomUUID();
        UUID readyADemandId = UUID.randomUUID();
        UUID readyBDemandId = UUID.randomUUID();
        UUID waitingADemandId = UUID.randomUUID();
        UUID waitingBDemandId = UUID.randomUUID();
        UUID orderItemId = withWaitingPurchasePeg
                ? UUID.randomUUID() : null;
        UUID orderPegId = withWaitingPurchasePeg
                ? UUID.randomUUID() : null;
        String planNo = "PP-" + planId;

        connection.setAutoCommit(false);
        try {
            execute(
                    connection,
                    "insert into units(id, code, name) values (?, ?, 'piece')",
                    unitId,
                    "UNIT-" + unitId);
            for (UUID goodsId :
                    List.of(productId, materialAId, materialBId)) {
                execute(
                        connection,
                        """
                        insert into goods(id, code, name, min_qty)
                        values (?, ?, 'fixture goods', 0)
                        """,
                        goodsId,
                        "GOODS-" + goodsId);
            }
            execute(
                    connection,
                    """
                    insert into warehouses(id, code, name)
                    values (?, ?, 'fixture warehouse')
                    """,
                    warehouseId,
                    "WH-" + warehouseId);
            execute(
                    connection,
                    """
                    insert into stock_balances(
                        id, warehouse_id, goods_id, qty
                    ) values (?, ?, ?, 10)
                    """,
                    balanceAId,
                    warehouseId,
                    materialAId);
            execute(
                    connection,
                    """
                    insert into stock_balances(
                        id, warehouse_id, goods_id, qty
                    ) values (?, ?, ?, 6)
                    """,
                    balanceBId,
                    warehouseId,
                    materialBId);
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
            insertSegment(
                    connection,
                    readySegmentId,
                    packageId,
                    planId,
                    planItemId,
                    1,
                    productId,
                    unitId,
                    "6",
                    "READY");
            insertSegment(
                    connection,
                    waitingSegmentId,
                    packageId,
                    planId,
                    planItemId,
                    2,
                    productId,
                    unitId,
                    "4",
                    "WAITING",
                    waitingAutoPromote);
            insertDemand(
                    connection,
                    readyADemandId,
                    packageId,
                    planId,
                    warehouseId,
                    readySegmentId,
                    planItemId,
                    materialAId,
                    unitId,
                    "6",
                    "ALLOCATED");
            insertDemand(
                    connection,
                    readyBDemandId,
                    packageId,
                    planId,
                    warehouseId,
                    readySegmentId,
                    planItemId,
                    materialBId,
                    unitId,
                    "6",
                    "ALLOCATED");
            insertDemand(
                    connection,
                    waitingADemandId,
                    packageId,
                    planId,
                    warehouseId,
                    waitingSegmentId,
                    planItemId,
                    materialAId,
                    unitId,
                    "4",
                    "OPEN");
            insertDemand(
                    connection,
                    waitingBDemandId,
                    packageId,
                    planId,
                    warehouseId,
                    waitingSegmentId,
                    planItemId,
                    materialBId,
                    unitId,
                    "4",
                    withWaitingPurchasePeg
                            ? "WAITING_SUPPLY" : "OPEN");
            insertReservation(
                    connection,
                    packageId,
                    readyADemandId,
                    materialAId,
                    warehouseId,
                    balanceAId,
                    "6");
            insertReservation(
                    connection,
                    packageId,
                    readyBDemandId,
                    materialBId,
                    warehouseId,
                    balanceBId,
                    "6");
            createDraw(
                    connection,
                    packageId,
                    readySegmentId,
                    planId,
                    planNo,
                    warehouseId,
                    List.of(
                            new DrawLine(
                                    readyADemandId,
                                    materialAId,
                                    unitId,
                                    decimal("6")),
                            new DrawLine(
                                    readyBDemandId,
                                    materialBId,
                                    unitId,
                                    decimal("6"))));

            if (withWaitingPurchasePeg) {
                UUID orderId = UUID.randomUUID();
                String orderNo = "PO-" + orderId;
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
                            goods_id, unit_id, unit_rate, qty
                        ) values (?, ?, ?, ?, ?, ?, 1, 4)
                        """,
                        orderItemId,
                        orderNo,
                        BILL_DATE,
                        orderId,
                        materialBId,
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
                            4, 0, 0, ?, 'EFFECTIVE', ?
                        )
                        """,
                        orderPegId,
                        waitingBDemandId,
                        orderItemId,
                        BILL_DATE.plusDays(2),
                        "order-peg-" + orderPegId);
            }
            connection.commit();
        } catch (Exception error) {
            connection.rollback();
            throw error;
        } finally {
            connection.setAutoCommit(true);
        }

        return new SegmentFixture(
                unitId,
                materialAId,
                materialBId,
                warehouseId,
                balanceAId,
                balanceBId,
                planId,
                planItemId,
                packageId,
                readySegmentId,
                waitingSegmentId,
                readyADemandId,
                readyBDemandId,
                waitingADemandId,
                waitingBDemandId,
                orderItemId,
                orderPegId,
                planNo);
    }

    private static BarePlan createBarePlan(Connection connection)
            throws Exception {
        UUID unitId = UUID.randomUUID();
        UUID materialId = UUID.randomUUID();
        UUID warehouseId = UUID.randomUUID();
        UUID planId = UUID.randomUUID();
        execute(
                connection,
                "insert into units(id, code, name) values (?, ?, 'piece')",
                unitId,
                "UNIT-" + unitId);
        execute(
                connection,
                """
                insert into goods(id, code, name, min_qty)
                values (?, ?, 'legacy material', 0)
                """,
                materialId,
                "GOODS-" + materialId);
        execute(
                connection,
                """
                insert into warehouses(id, code, name)
                values (?, ?, 'legacy warehouse')
                """,
                warehouseId,
                "WH-" + warehouseId);
        execute(
                connection,
                """
                insert into production_plans(id, bill_no, bill_date, status)
                values (?, ?, ?, 1)
                """,
                planId,
                "PP-" + planId,
                BILL_DATE);
        return new BarePlan(planId, warehouseId, materialId, unitId);
    }

    private static void insertLegacyPackage(
            Connection connection,
            UUID packageId,
            BarePlan plan,
            String idempotencyKey) throws Exception {
        execute(
                connection,
                """
                insert into production_planning_packages(
                    id, plan_id, warehouse_id, idempotency_key,
                    request_hash, preview_fingerprint, status
                ) values (?, ?, ?, ?, ?, ?, 'CONFIRMED')
                """,
                packageId,
                plan.planId(),
                plan.warehouseId(),
                idempotencyKey,
                "c".repeat(64),
                "d".repeat(64));
    }

    private static void insertSegment(
            Connection connection,
            UUID segmentId,
            UUID packageId,
            UUID planId,
            UUID planItemId,
            int segmentNo,
            UUID productId,
            UUID unitId,
            String plannedQty,
            String status) throws Exception {
        insertSegment(
                connection, segmentId, packageId, planId, planItemId,
                segmentNo, productId, unitId, plannedQty, status, true);
    }

    private static void insertSegment(
            Connection connection,
            UUID segmentId,
            UUID packageId,
            UUID planId,
            UUID planItemId,
            int segmentNo,
            UUID productId,
            UUID unitId,
            String plannedQty,
            String status,
            boolean autoPromoteWhenReady) throws Exception {
        execute(
                connection,
                """
                insert into production_execution_segments(
                    id, package_id, plan_id, source_plan_item_id,
                    segment_no, segment_code, client_segment_key,
                    product_goods_id, product_unit_id, product_unit_rate,
                    planned_qty, status, bom_fingerprint, idempotency_key,
                    auto_promote_when_ready
                ) values (
                    ?, ?, ?, ?, ?, ?, ?, ?, ?, 1,
                    ?, ?, ?, ?, ?
                )
                """,
                segmentId,
                packageId,
                planId,
                planItemId,
                segmentNo,
                "SEG-" + segmentId,
                "CLIENT-" + segmentId,
                productId,
                unitId,
                decimal(plannedQty),
                status,
                "e".repeat(64),
                "segment-" + segmentId,
                autoPromoteWhenReady);
    }

    private static void insertDemand(
            Connection connection,
            UUID demandId,
            UUID packageId,
            UUID planId,
            UUID warehouseId,
            UUID segmentId,
            UUID planItemId,
            UUID goodsId,
            UUID unitId,
            String requiredQty,
            String status) throws Exception {
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
                    'BUY', ?, ?, ?, ?, 1
                )
                """,
                demandId,
                packageId,
                planId,
                warehouseId,
                goodsId,
                unitId,
                decimal(requiredQty),
                BILL_DATE.plusDays(3),
                status,
                "demand-" + demandId,
                segmentId,
                planItemId);
    }

    private static UUID insertReservation(
            Connection connection,
            UUID packageId,
            UUID demandId,
            UUID goodsId,
            UUID warehouseId,
            UUID balanceId,
            String qty) throws Exception {
        UUID reservationId = UUID.randomUUID();
        execute(
                connection,
                """
                insert into stock_reservations(
                    id, order_item_id, goods_id, color_id, warehouse_id,
                    qty, consumed_qty, released_qty, status, source,
                    source_doc_type, source_doc_id,
                    owner_type, owner_id, purpose, demand_id,
                    supply_type, supply_id, idempotency_key
                ) values (
                    ?, null, ?, null, ?, ?, 0, 0, 0, 0,
                    'PRODUCTION_PLANNING_PACKAGE', ?,
                    'PRODUCTION_MATERIAL_DEMAND', ?,
                    'PRODUCTION_MATERIAL', ?,
                    'STOCK_BALANCE', ?, ?
                )
                """,
                reservationId,
                goodsId,
                warehouseId,
                decimal(qty),
                packageId,
                demandId,
                demandId,
                balanceId,
                "reservation-" + reservationId);
        return reservationId;
    }

    private static Draw createDraw(
            Connection connection,
            UUID packageId,
            UUID segmentId,
            UUID planId,
            String planNo,
            UUID warehouseId,
            List<DrawLine> lines) throws Exception {
        UUID drawId = UUID.randomUUID();
        String drawNo = "DRAW-" + drawId;
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
                insert into plan_draw_links(plan_id, draw_id)
                values (?, ?)
                """,
                planId,
                drawId);

        java.util.ArrayList<UUID> itemIds = new java.util.ArrayList<>();
        int lineNo = 0;
        for (DrawLine line : lines) {
            UUID itemId = UUID.randomUUID();
            itemIds.add(itemId);
            lineNo++;
            execute(
                    connection,
                    """
                    insert into stock_document_items(
                        id, doc_id, bill_type, bill_no, bill_date,
                        line_no, goods_id, unit_id, unit_rate,
                        qty, base_qty
                    ) values (
                        ?, ?, 'DRAW', ?, ?, ?, ?, ?, 1, ?, ?
                    )
                    """,
                    itemId,
                    drawId,
                    drawNo,
                    BILL_DATE,
                    lineNo,
                    line.goodsId(),
                    line.unitId(),
                    line.qty(),
                    line.qty());
            execute(
                    connection,
                    """
                    insert into production_planning_package_document_items(
                        package_id, demand_id, document_type,
                        document_id, document_item_id
                    ) values (?, ?, 'DRAW', ?, ?)
                    """,
                    packageId,
                    line.demandId(),
                    drawId,
                    itemId);
        }
        return new Draw(drawId, List.copyOf(itemIds));
    }

    private static Receipt createApprovedReceipt(
            Connection connection,
            SegmentFixture fixture,
            String qty,
            boolean addToStock) throws Exception {
        UUID receiptId = UUID.randomUUID();
        UUID itemId = UUID.randomUUID();
        String billNo = "RC-" + receiptId;
        connection.setAutoCommit(false);
        try {
            execute(
                    connection,
                    """
                    insert into purchase_receipts(
                        id, bill_no, bill_date, warehouse_id, status
                    ) values (?, ?, ?, ?, 1)
                    """,
                    receiptId,
                    billNo,
                    BILL_DATE,
                    fixture.warehouseId());
            execute(
                    connection,
                    """
                    insert into purchase_receipt_items(
                        id, bill_no, bill_date, receipt_id,
                        order_item_id, goods_id, unit_id,
                        unit_rate, qty
                    ) values (?, ?, ?, ?, ?, ?, ?, 1, ?)
                    """,
                    itemId,
                    billNo,
                    BILL_DATE,
                    receiptId,
                    fixture.waitingBOrderItemId(),
                    fixture.materialBId(),
                    fixture.unitId(),
                    decimal(qty));
            if (addToStock) {
                execute(
                        connection,
                        """
                        update stock_balances
                        set qty = qty + ?
                        where id = ?
                        """,
                        decimal(qty),
                        fixture.balanceBId());
            }
            connection.commit();
        } catch (Exception error) {
            connection.rollback();
            throw error;
        } finally {
            connection.setAutoCommit(true);
        }
        return new Receipt(receiptId, itemId, decimal(qty));
    }

    private static void promoteWaitingSegment(
            Connection connection,
            SegmentFixture fixture,
            List<Receipt> receipts) throws Exception {
        connection.setAutoCommit(false);
        try {
            execute(
                    connection,
                    """
                    update production_material_supply_pegs
                    set consumed_qty = 4, status = 'DONE'
                    where id = ?
                    """,
                    fixture.waitingBOrderPegId());
            insertReservation(
                    connection,
                    fixture.packageId(),
                    fixture.waitingADemandId(),
                    fixture.materialAId(),
                    fixture.warehouseId(),
                    fixture.balanceAId(),
                    "4");
            UUID bReservationId = insertReservation(
                    connection,
                    fixture.packageId(),
                    fixture.waitingBDemandId(),
                    fixture.materialBId(),
                    fixture.warehouseId(),
                    fixture.balanceBId(),
                    "4");

            List<DrawLine> lines = new java.util.ArrayList<>();
            lines.add(new DrawLine(
                    fixture.waitingADemandId(),
                    fixture.materialAId(),
                    fixture.unitId(),
                    decimal("4")));
            receipts.forEach(receipt -> lines.add(new DrawLine(
                    fixture.waitingBDemandId(),
                    fixture.materialBId(),
                    fixture.unitId(),
                    receipt.qty())));
            Draw draw = createDraw(
                    connection,
                    fixture.packageId(),
                    fixture.waitingSegmentId(),
                    fixture.planId(),
                    fixture.planNo(),
                    fixture.warehouseId(),
                    lines);

            for (int index = 0; index < receipts.size(); index++) {
                Receipt receipt = receipts.get(index);
                UUID drawItemId = draw.itemIds().get(index + 1);
                UUID allocationId = UUID.randomUUID();
                execute(
                        connection,
                        """
                        insert into production_material_receipt_allocations(
                            id, receipt_id, receipt_item_id, package_id,
                            demand_id, order_peg_id, reservation_id,
                            draw_id, draw_item_id, allocated_qty,
                            status, idempotency_key
                        ) values (
                            ?, ?, ?, ?, ?, ?, ?, ?, ?, ?,
                            'EFFECTIVE', ?
                        )
                        """,
                        allocationId,
                        receipt.id(),
                        receipt.itemId(),
                        fixture.packageId(),
                        fixture.waitingBDemandId(),
                        fixture.waitingBOrderPegId(),
                        bReservationId,
                        draw.id(),
                        drawItemId,
                        receipt.qty(),
                        "receipt-allocation-" + allocationId);
            }
            execute(
                    connection,
                    """
                    update production_material_demands
                    set status = 'ALLOCATED'
                    where id in (?, ?)
                    """,
                    fixture.waitingADemandId(),
                    fixture.waitingBDemandId());
            execute(
                    connection,
                    """
                    update production_execution_segments
                    set status = 'READY'
                    where id = ?
                    """,
                    fixture.waitingSegmentId());
            connection.commit();
        } catch (Exception error) {
            connection.rollback();
            throw error;
        } finally {
            connection.setAutoCommit(true);
        }
    }

    private static void reverseReceiptByDemotingWholeSegment(
            Connection connection,
            SegmentFixture fixture,
            Receipt receipt) throws Exception {
        connection.setAutoCommit(false);
        try {
            java.util.ArrayList<UUID> drawIds =
                    new java.util.ArrayList<>();
            try (PreparedStatement statement = connection.prepareStatement("""
                    select document_id
                    from production_planning_package_documents
                    where package_id = ?
                      and execution_segment_id = ?
                      and document_type = 'DRAW'
                    order by document_id
                    """)) {
                statement.setObject(1, fixture.packageId());
                statement.setObject(2, fixture.waitingSegmentId());
                try (ResultSet result = statement.executeQuery()) {
                    while (result.next()) {
                        drawIds.add(result.getObject(1, UUID.class));
                    }
                }
            }
            assertFalse(drawIds.isEmpty());

            execute(
                    connection,
                    """
                    update production_execution_segments
                    set status = 'WAITING'
                    where id = ? and status = 'READY'
                    """,
                    fixture.waitingSegmentId());
            execute(
                    connection,
                    """
                    update stock_reservations
                    set released_qty = qty, status = -1,
                        is_deleted = true, deleted_at = now(),
                        release_reason = 'RECEIPT_SEGMENT_DEMOTED'
                    where demand_id in (?, ?)
                      and is_deleted = false
                      and consumed_qty = 0
                    """,
                    fixture.waitingADemandId(),
                    fixture.waitingBDemandId());
            execute(
                    connection,
                    """
                    update production_material_supply_pegs
                    set consumed_qty = 0, status = 'EFFECTIVE'
                    where id = ?
                    """,
                    fixture.waitingBOrderPegId());
            execute(
                    connection,
                    """
                    update production_material_receipt_allocations
                    set status = 'REVERSED'
                    where order_peg_id = ?
                      and status = 'EFFECTIVE'
                    """,
                    fixture.waitingBOrderPegId());
            for (UUID drawId : drawIds) {
                execute(
                        connection,
                        """
                        delete from
                            production_planning_package_document_items
                        where package_id = ?
                          and document_type = 'DRAW'
                          and document_id = ?
                        """,
                        fixture.packageId(),
                        drawId);
                authorizeDrawCleanup(connection, drawId);
                execute(
                        connection,
                        """
                        update stock_document_items
                        set is_deleted = true
                        where doc_id = ? and is_deleted = false
                        """,
                        drawId);
                execute(
                        connection,
                        """
                        update stock_documents
                        set status = -1, is_deleted = true,
                            deleted_at = now()
                        where id = ?
                        """,
                        drawId);
                execute(
                        connection,
                        """
                        update plan_draw_links
                        set is_deleted = true, deleted_at = now()
                        where draw_id = ? and is_deleted = false
                        """,
                        drawId);
                execute(
                        connection,
                        """
                        delete from production_planning_package_documents
                        where package_id = ?
                          and execution_segment_id = ?
                          and document_type = 'DRAW'
                          and document_id = ?
                        """,
                        fixture.packageId(),
                        fixture.waitingSegmentId(),
                        drawId);
            }
            execute(
                    connection,
                    """
                    update production_material_demands
                    set status = case
                        when id = ? then 'WAITING_SUPPLY'
                        else 'OPEN'
                    end
                    where id in (?, ?)
                    """,
                    fixture.waitingBDemandId(),
                    fixture.waitingADemandId(),
                    fixture.waitingBDemandId());
            execute(
                    connection,
                    """
                    update purchase_receipts
                    set status = -1
                    where id = ?
                    """,
                    receipt.id());
            execute(
                    connection,
                    """
                    update stock_balances
                    set qty = qty - ?
                    where id = ?
                    """,
                    receipt.qty(),
                    fixture.balanceBId());
            connection.commit();
        } catch (Exception error) {
            connection.rollback();
            throw error;
        } finally {
            connection.setAutoCommit(true);
        }
    }

    private static SubcontractSupply attachSubcontractSupply(
            Connection connection,
            SegmentFixture fixture) throws Exception {
        UUID applicationId = UUID.randomUUID();
        UUID applicationItemId = UUID.randomUUID();
        UUID applicationPegId = UUID.randomUUID();
        UUID orderId = UUID.randomUUID();
        UUID orderItemId = UUID.randomUUID();
        UUID orderPegId = UUID.randomUUID();
        UUID transferId = UUID.randomUUID();
        String applicationNo = "SA-" + applicationId;
        String orderNo = "SO-" + orderId;

        connection.setAutoCommit(false);
        try {
            execute(
                    connection,
                    """
                    update production_material_demands
                    set supply_route = 'SUBCONTRACT',
                        status = 'WAITING_SUPPLY'
                    where id = ?
                    """,
                    fixture.waitingBDemandId());
            execute(
                    connection,
                    """
                    insert into subcontract_applications(
                        id, bill_no, bill_date, warehouse_id,
                        need_date, status, is_closed,
                        source_doc_no)
                    values (?, ?, ?, ?, ?, 1, true, ?)
                    """,
                    applicationId,
                    applicationNo,
                    BILL_DATE,
                    fixture.warehouseId(),
                    BILL_DATE.plusDays(2),
                    fixture.planNo());
            execute(
                    connection,
                    """
                    insert into subcontract_application_items(
                        id, bill_no, bill_date, application_id,
                        line_no, goods_id, unit_id, unit_rate,
                        qty, ordered_qty, source_doc_no)
                    values (?, ?, ?, ?, 1, ?, ?, 1, 4, 4, ?)
                    """,
                    applicationItemId,
                    applicationNo,
                    BILL_DATE,
                    applicationId,
                    fixture.materialBId(),
                    fixture.unitId(),
                    fixture.planNo());
            execute(
                    connection,
                    """
                    insert into production_planning_package_documents(
                        package_id, document_type,
                        document_id, document_no)
                    values (?, 'SUBCONTRACT_APPLICATION', ?, ?)
                    """,
                    fixture.packageId(),
                    applicationId,
                    applicationNo);
            execute(
                    connection,
                    """
                    insert into production_material_supply_pegs(
                        id, demand_id, supply_type, supply_item_id,
                        allocated_qty, consumed_qty, released_qty,
                        expected_date, status, idempotency_key)
                    values (
                        ?, ?, 'SUBCONTRACT_APPLICATION_ITEM', ?,
                        4, 0, 4, ?, 'RELEASED', ?)
                    """,
                    applicationPegId,
                    fixture.waitingBDemandId(),
                    applicationItemId,
                    BILL_DATE.plusDays(2),
                    "sub-application-peg-" + applicationPegId);
            execute(
                    connection,
                    """
                    insert into subcontract_orders(
                        id, bill_no, bill_date, warehouse_id,
                        deliver_date, status, source_doc_no)
                    values (?, ?, ?, ?, ?, 1, ?)
                    """,
                    orderId,
                    orderNo,
                    BILL_DATE,
                    fixture.warehouseId(),
                    BILL_DATE.plusDays(2),
                    applicationNo);
            execute(
                    connection,
                    """
                    insert into subcontract_order_items(
                        id, bill_no, bill_date, order_id,
                        line_no, goods_id, unit_id, unit_rate,
                        qty, received_qty, application_item_id,
                        deliver_date, source_doc_no)
                    values (
                        ?, ?, ?, ?, 1, ?, ?, 1,
                        4, 0, ?, ?, ?)
                    """,
                    orderItemId,
                    orderNo,
                    BILL_DATE,
                    orderId,
                    fixture.materialBId(),
                    fixture.unitId(),
                    applicationItemId,
                    BILL_DATE.plusDays(2),
                    applicationNo);
            execute(
                    connection,
                    """
                    insert into production_material_supply_pegs(
                        id, demand_id, supply_type, supply_item_id,
                        allocated_qty, consumed_qty, released_qty,
                        expected_date, status, idempotency_key)
                    values (
                        ?, ?, 'SUBCONTRACT_ORDER_ITEM', ?,
                        4, 0, 0, ?, 'EFFECTIVE', ?)
                    """,
                    orderPegId,
                    fixture.waitingBDemandId(),
                    orderItemId,
                    BILL_DATE.plusDays(2),
                    "sub-order-peg-" + orderPegId);
            execute(
                    connection,
                    """
                    insert into
                      production_material_subcontract_peg_transfers(
                        id, demand_id, from_peg_id, to_peg_id,
                        application_item_id, order_item_id,
                        transferred_qty, status, idempotency_key)
                    values (
                        ?, ?, ?, ?, ?, ?, 4,
                        'EFFECTIVE', ?)
                    """,
                    transferId,
                    fixture.waitingBDemandId(),
                    applicationPegId,
                    orderPegId,
                    applicationItemId,
                    orderItemId,
                    "sub-transfer-" + transferId);
            connection.commit();
        } catch (Exception error) {
            connection.rollback();
            throw error;
        } finally {
            connection.setAutoCommit(true);
        }
        return new SubcontractSupply(
                applicationId,
                applicationItemId,
                applicationPegId,
                orderId,
                orderItemId,
                orderPegId,
                transferId);
    }

    private static Receipt createApprovedSubcontractReceipt(
            Connection connection,
            SegmentFixture fixture,
            SubcontractSupply supply,
            String qty) throws Exception {
        UUID receiptId = UUID.randomUUID();
        UUID receiptItemId = UUID.randomUUID();
        String receiptNo = "SR-" + receiptId;
        BigDecimal quantity = decimal(qty);
        connection.setAutoCommit(false);
        try {
            execute(
                    connection,
                    """
                    insert into subcontract_receipts(
                        id, bill_no, bill_date,
                        warehouse_id, status, source_doc_no)
                    values (?, ?, ?, ?, 1, ?)
                    """,
                    receiptId,
                    receiptNo,
                    BILL_DATE,
                    fixture.warehouseId(),
                    "SO-" + supply.orderId());
            execute(
                    connection,
                    """
                    insert into subcontract_receipt_items(
                        id, bill_no, bill_date, receipt_id,
                        order_item_id, line_no, goods_id, unit_id,
                        unit_rate, qty, order_qty, source_doc_no)
                    values (
                        ?, ?, ?, ?, ?, 1, ?, ?,
                        1, ?, 4, ?)
                    """,
                    receiptItemId,
                    receiptNo,
                    BILL_DATE,
                    receiptId,
                    supply.orderItemId(),
                    fixture.materialBId(),
                    fixture.unitId(),
                    quantity,
                    "SO-" + supply.orderId());
            execute(
                    connection,
                    """
                    update subcontract_order_items
                    set received_qty = received_qty + ?
                    where id = ?
                    """,
                    quantity,
                    supply.orderItemId());
            execute(
                    connection,
                    """
                    update stock_balances
                    set qty = qty + ?
                    where id = ?
                    """,
                    quantity,
                    fixture.balanceBId());
            connection.commit();
        } catch (Exception error) {
            connection.rollback();
            throw error;
        } finally {
            connection.setAutoCommit(true);
        }
        return new Receipt(receiptId, receiptItemId, quantity);
    }

    private static boolean promoteSubcontractWaitingSegment(
            Connection connection,
            SegmentFixture fixture,
            SubcontractSupply supply,
            List<Receipt> receipts) throws Exception {
        if (!"WAITING".equals(scalarText(
                connection,
                """
                select status from production_execution_segments
                where id = ?
                """,
                fixture.waitingSegmentId()))) {
            return false;
        }
        BigDecimal received = receipts.stream()
                .map(Receipt::qty)
                .reduce(BigDecimal.ZERO, BigDecimal::add);
        if (received.compareTo(decimal("4")) != 0) {
            return false;
        }

        connection.setAutoCommit(false);
        try {
            execute(
                    connection,
                    """
                    update production_material_supply_pegs
                    set consumed_qty = 4, status = 'DONE'
                    where id = ?
                    """,
                    supply.orderPegId());
            insertReservation(
                    connection,
                    fixture.packageId(),
                    fixture.waitingADemandId(),
                    fixture.materialAId(),
                    fixture.warehouseId(),
                    fixture.balanceAId(),
                    "4");
            UUID bReservationId = insertReservation(
                    connection,
                    fixture.packageId(),
                    fixture.waitingBDemandId(),
                    fixture.materialBId(),
                    fixture.warehouseId(),
                    fixture.balanceBId(),
                    "4");

            List<DrawLine> lines = new java.util.ArrayList<>();
            lines.add(new DrawLine(
                    fixture.waitingADemandId(),
                    fixture.materialAId(),
                    fixture.unitId(),
                    decimal("4")));
            receipts.forEach(receipt -> lines.add(new DrawLine(
                    fixture.waitingBDemandId(),
                    fixture.materialBId(),
                    fixture.unitId(),
                    receipt.qty())));
            Draw draw = createDraw(
                    connection,
                    fixture.packageId(),
                    fixture.waitingSegmentId(),
                    fixture.planId(),
                    fixture.planNo(),
                    fixture.warehouseId(),
                    lines);

            for (int index = 0; index < receipts.size(); index++) {
                Receipt receipt = receipts.get(index);
                UUID allocationId = UUID.randomUUID();
                execute(
                        connection,
                        """
                        insert into
                          production_material_subcontract_receipt_allocations(
                            id, receipt_id, receipt_item_id, package_id,
                            demand_id, order_peg_id, reservation_id,
                            draw_id, draw_item_id, allocated_qty,
                            status, idempotency_key)
                        values (
                            ?, ?, ?, ?, ?, ?, ?, ?, ?, ?,
                            'EFFECTIVE', ?)
                        """,
                        allocationId,
                        receipt.id(),
                        receipt.itemId(),
                        fixture.packageId(),
                        fixture.waitingBDemandId(),
                        supply.orderPegId(),
                        bReservationId,
                        draw.id(),
                        draw.itemIds().get(index + 1),
                        receipt.qty(),
                        "sub-receipt-allocation-" + allocationId);
            }
            execute(
                    connection,
                    """
                    update production_material_demands
                    set status = 'ALLOCATED'
                    where id in (?, ?)
                    """,
                    fixture.waitingADemandId(),
                    fixture.waitingBDemandId());
            execute(
                    connection,
                    """
                    update production_execution_segments
                    set status = 'READY'
                    where id = ? and status = 'WAITING'
                    """,
                    fixture.waitingSegmentId());
            connection.commit();
            return true;
        } catch (Exception error) {
            connection.rollback();
            throw error;
        } finally {
            connection.setAutoCommit(true);
        }
    }

    private static void applyLifecycle(
            Connection connection,
            SegmentFixture fixture,
            String target) throws Exception {
        String demandStatus = "CANCELLED".equals(target)
                ? "RELEASED" : "REVERSED";
        connection.setAutoCommit(false);
        try {
            execute(
                    connection,
                    """
                    update production_execution_segments
                    set status = ?
                    where package_id = ?
                      and status in ('READY', 'WAITING')
                    """,
                    target,
                    fixture.packageId());
            java.util.ArrayList<UUID> drawIds =
                    new java.util.ArrayList<>();
            try (PreparedStatement statement = connection.prepareStatement("""
                    select document_id
                    from production_planning_package_documents
                    where package_id = ?
                      and document_type = 'DRAW'
                    order by document_id
                    """)) {
                statement.setObject(1, fixture.packageId());
                try (ResultSet result = statement.executeQuery()) {
                    while (result.next()) {
                        drawIds.add(result.getObject(1, UUID.class));
                    }
                }
            }
            for (UUID drawId : drawIds) {
                if ("CANCELLED".equals(target)) {
                    authorizeDrawCleanup(connection, drawId);
                    execute(
                            connection,
                            """
                            update stock_documents
                            set is_deleted = true, deleted_at = now()
                            where id = ?
                            """,
                            drawId);
                } else {
                    execute(
                            connection,
                            """
                            update stock_documents
                            set status = -1
                            where id = ?
                            """,
                            drawId);
                }
            }
            execute(
                    connection,
                    """
                    update plan_draw_links
                    set is_deleted = true, deleted_at = now()
                    where plan_id = ? and is_deleted = false
                    """,
                    fixture.planId());
            execute(
                    connection,
                    """
                    update stock_reservations
                    set released_qty = qty, status = -1,
                        is_deleted = true, deleted_at = now(),
                        release_reason = ?
                    where demand_id in (
                        select id
                        from production_material_demands
                        where package_id = ?
                    )
                      and is_deleted = false
                    """,
                    "PACKAGE_" + target,
                    fixture.packageId());
            execute(
                    connection,
                    """
                    update production_material_demands
                    set released_qty = required_qty, status = ?
                    where package_id = ? and is_deleted = false
                    """,
                    demandStatus,
                    fixture.packageId());
            if ("CANCELLED".equals(target)) {
                execute(
                        connection,
                        """
                        update production_planning_packages
                        set status = 'CANCELLED',
                            cancel_idempotency_key = ?,
                            lifecycle_reason = 'acceptance cancellation'
                        where id = ?
                        """,
                        "cancel-" + fixture.packageId(),
                        fixture.packageId());
            } else {
                execute(
                        connection,
                        """
                        update production_planning_packages
                        set status = 'REVERSED',
                            reverse_idempotency_key = ?,
                            lifecycle_reason = 'acceptance reversal'
                        where id = ?
                        """,
                        "reverse-" + fixture.packageId(),
                        fixture.packageId());
            }
            connection.commit();
        } catch (Exception error) {
            connection.rollback();
            throw error;
        } finally {
            connection.setAutoCommit(true);
        }
    }

    private static void assertLifecycle(
            Connection connection,
            SegmentFixture fixture,
            String target) throws Exception {
        assertEquals(
                target,
                scalarText(
                        connection,
                        """
                        select status
                        from production_planning_packages
                        where id = ?
                        """,
                        fixture.packageId()));
        assertQuantity(
                connection,
                """
                select count(*)
                from production_execution_segments
                where package_id = ? and status = ?
                """,
                fixture.packageId(),
                target,
                "2");
        assertQuantity(
                connection,
                """
                select coalesce(sum(qty - released_qty), 0)
                from stock_reservations
                where demand_id in (
                    select id
                    from production_material_demands
                    where package_id = ?
                )
                  and is_deleted = false
                """,
                fixture.packageId(),
                "0");
        assertQuantity(
                connection,
                """
                select count(*)
                from production_material_demands
                where package_id = ?
                  and released_qty = required_qty
                  and status = ?
                """,
                fixture.packageId(),
                "CANCELLED".equals(target) ? "RELEASED" : "REVERSED",
                "4");
    }

    private static void assertConstraint(
            Connection connection,
            String expectedConstraint,
            String sql,
            Object... values) {
        PSQLException error = assertThrows(
                PSQLException.class,
                () -> execute(connection, sql, values));
        assertEquals(CHECK_VIOLATION, error.getSQLState());
        assertEquals(
                expectedConstraint,
                error.getServerErrorMessage().getConstraint());
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
            Connection connection,
            String sql,
            Object... values) throws Exception {
        try (PreparedStatement statement = connection.prepareStatement(sql)) {
            bind(statement, values);
            statement.executeUpdate();
        }
    }

    private static void bind(
            PreparedStatement statement,
            Object... values) throws Exception {
        for (int index = 0; index < values.length; index++) {
            statement.setObject(index + 1, values[index]);
        }
    }

    private static void assertQuantity(
            Connection connection,
            String sql,
            Object id,
            String expected) throws Exception {
        assertQuantity(connection, sql, new Object[]{id}, expected);
    }

    private static void assertQuantity(
            Connection connection,
            String sql,
            Object first,
            Object second,
            String expected) throws Exception {
        assertQuantity(
                connection, sql, new Object[]{first, second}, expected);
    }

    private static void assertQuantity(
            Connection connection,
            String sql,
            Object[] values,
            String expected) throws Exception {
        try (PreparedStatement statement = connection.prepareStatement(sql)) {
            bind(statement, values);
            try (ResultSet result = statement.executeQuery()) {
                assertTrue(result.next());
                assertEquals(
                        0,
                        decimal(expected).compareTo(
                                result.getBigDecimal(1)));
            }
        }
    }

    private static String scalarText(
            Connection connection,
            String sql,
            Object... values) throws Exception {
        try (PreparedStatement statement = connection.prepareStatement(sql)) {
            bind(statement, values);
            try (ResultSet result = statement.executeQuery()) {
                assertTrue(result.next());
                return result.getString(1);
            }
        }
    }

    private static UUID scalarUuid(
            Connection connection,
            String sql,
            Object... values) throws Exception {
        try (PreparedStatement statement = connection.prepareStatement(sql)) {
            bind(statement, values);
            try (ResultSet result = statement.executeQuery()) {
                assertTrue(result.next());
                return result.getObject(1, UUID.class);
            }
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

    private record BarePlan(
            UUID planId,
            UUID warehouseId,
            UUID materialId,
            UUID unitId) {
    }

    private record SegmentFixture(
            UUID unitId,
            UUID materialAId,
            UUID materialBId,
            UUID warehouseId,
            UUID balanceAId,
            UUID balanceBId,
            UUID planId,
            UUID planItemId,
            UUID packageId,
            UUID readySegmentId,
            UUID waitingSegmentId,
            UUID readyADemandId,
            UUID readyBDemandId,
            UUID waitingADemandId,
            UUID waitingBDemandId,
            UUID waitingBOrderItemId,
            UUID waitingBOrderPegId,
            String planNo) {
    }

    private record ExactDemandFixture(UUID segmentId, UUID demandId) {
    }

    private record DrawLine(
            UUID demandId,
            UUID goodsId,
            UUID unitId,
            BigDecimal qty) {
    }

    private record Draw(UUID id, List<UUID> itemIds) {
    }

    private record Receipt(UUID id, UUID itemId, BigDecimal qty) {
    }

    private record SubcontractSupply(
            UUID applicationId,
            UUID applicationItemId,
            UUID applicationPegId,
            UUID orderId,
            UUID orderItemId,
            UUID orderPegId,
            UUID transferId) {
    }
}
