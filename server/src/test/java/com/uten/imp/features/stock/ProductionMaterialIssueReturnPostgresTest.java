package com.uten.imp.features.stock;

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

/** Real PostgreSQL evidence for V152 issue/return/settlement invariants. */
@EnabledIfEnvironmentVariable(named = "UTEN_RUN_DB_TESTS", matches = "(?i)true")
class ProductionMaterialIssueReturnPostgresTest {

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
    static void stop() {
        POSTGRES.stop();
    }

    @Test
    void issueReverseReturnAndSettlementRoundTripKeepsAvailabilityStable()
            throws Exception {
        try (Connection connection = connection()) {
            Fixture f = fixture(connection, "100", "40");
            assertDecimal(connection, """
                    select available_qty from v_stock_available
                    where warehouse_id = ? and goods_id = ?
                    """, f.warehouseId(), f.goodsId(), "60");

            UUID issue = event(
                    connection, f.drawId(), "ISSUE", "issue-key-0001");
            update(connection, """
                    update stock_reservations
                    set consumed_qty = consumed_qty + 20
                    where id = ?
                    """, f.reservationId());
            updateAmount(connection, """
                    update stock_balances set qty = qty - ? where id = ?
                    """, "20", f.balanceId());
            UUID issuePosting = stockPosting(
                    connection, issue, f.drawItemId(), f.demandId(),
                    f.reservationId(), null, "ISSUE", "20");
            assertDecimal(connection, """
                    select available_qty from v_stock_available
                    where warehouse_id = ? and goods_id = ?
                    """, f.warehouseId(), f.goodsId(), "60");

            PSQLException duplicate = assertThrows(
                    PSQLException.class,
                    () -> event(
                            connection, f.drawId(), "ISSUE", "issue-key-0001"));
            assertEquals("23505", duplicate.getSQLState());

            UUID reverse = event(
                    connection, f.drawId(), "ISSUE_REVERSE",
                    "reverse-key-0001");
            // Reverse order is intentional: physical stock first, allocation second.
            updateAmount(connection, """
                    update stock_balances set qty = qty + ? where id = ?
                    """, "5", f.balanceId());
            update(connection, """
                    update stock_reservations
                    set consumed_qty = consumed_qty - 5
                    where id = ?
                    """, f.reservationId());
            stockPosting(
                    connection, reverse, f.drawItemId(), f.demandId(),
                    f.reservationId(), issuePosting, "ISSUE_REVERSE", "5");
            assertDecimal(connection, """
                    select available_qty from v_stock_available
                    where warehouse_id = ? and goods_id = ?
                    """, f.warehouseId(), f.goodsId(), "60");

            UUID returnDoc = stockDocument(
                    connection, f.warehouseId(), "WDRAW");
            UUID returnItem = stockItem(
                    connection, returnDoc, f.goodsId(), f.unitId(),
                    f.drawItemId(), "5", "WDRAW");
            UUID returned = event(
                    connection, returnDoc, "GOOD_RETURN",
                    "return-key-0001");
            // Good return order is also physical stock first.
            updateAmount(connection, """
                    update stock_balances set qty = qty + ? where id = ?
                    """, "5", f.balanceId());
            update(connection, """
                    update stock_reservations
                    set consumed_qty = consumed_qty - 5
                    where id = ?
                    """, f.reservationId());
            stockPosting(
                    connection, returned, returnItem, f.demandId(),
                    f.reservationId(), issuePosting, "GOOD_RETURN", "5");
            assertDecimal(connection, """
                    select available_qty from v_stock_available
                    where warehouse_id = ? and goods_id = ?
                    """, f.warehouseId(), f.goodsId(), "60");
            assertDecimal(connection, """
                    select uncleared_qty from v_production_material_clearance
                    where demand_id = ?
                    """, f.demandId(), "10");

            UUID settlementEvent = UUID.randomUUID();
            insert(connection, """
                    insert into production_material_settlement_events(
                        id, plan_id, event_type, idempotency_key, request_hash
                    ) values (?, ?, 'POST', 'settle-key-0001', ?)
                    """, settlementEvent, f.planId(), "a".repeat(64));
            insert(connection, """
                    insert into production_material_settlement_postings(
                        id, event_id, demand_id, settlement_type, qty_base
                    ) values (?, ?, ?, 'CONSUMED', 10)
                    """, UUID.randomUUID(), settlementEvent, f.demandId());
            assertTrue(booleanValue(connection, """
                    select can_close from v_production_material_clearance
                    where demand_id = ?
                    """, f.demandId()));

            PSQLException returnAfterSettlement = assertThrows(
                    PSQLException.class,
                    () -> stockPosting(
                            connection, returned, returnItem, f.demandId(),
                            f.reservationId(), issuePosting,
                            "GOOD_RETURN", "1"));
            assertEquals("23514", returnAfterSettlement.getSQLState());
            assertDecimal(connection, """
                    select greatest(uncleared_qty, 0)
                    from v_production_material_clearance where demand_id = ?
                    """, f.demandId(), "0");

            update(connection, """
                    update production_plan_items set iqty = 0 where id = ?
                    """, f.planItemId());
            update(connection, """
                    update production_plans set is_closed = true where id = ?
                    """, f.planId());
            assertFalse(booleanValue(connection, """
                    select is_closed from production_plans where id = ?
                    """, f.planId()));
            update(connection, """
                    update production_plan_items set iqty = qty where id = ?
                    """, f.planItemId());

            update(connection, """
                    update production_plans set is_closed = true where id = ?
                    """, f.planId());
            assertTrue(booleanValue(connection, """
                    select is_closed from production_plans where id = ?
                    """, f.planId()));

            PSQLException overSettlement = assertThrows(
                    PSQLException.class,
                    () -> insert(connection, """
                            insert into production_material_settlement_postings(
                                id, event_id, demand_id, settlement_type, qty_base
                            ) values (?, ?, ?, 'APPROVED_LOSS', 1)
                            """, UUID.randomUUID(), settlementEvent, f.demandId()));
            assertEquals("23514", overSettlement.getSQLState());

            UUID orderItemId = UUID.randomUUID();
            PSQLException quantityOrder = assertThrows(
                    PSQLException.class,
                    () -> insert(connection, """
                            insert into plan_order_item_links(
                                id, plan_item_id, order_item_id,
                                allocated_qty, produced_qty, inbound_qty
                            ) values (?, ?, ?, 10, 5, 6)
                            """, UUID.randomUUID(), f.planItemId(), orderItemId));
            assertEquals("23514", quantityOrder.getSQLState());

            UUID lateIssue = event(
                    connection, f.drawId(), "ISSUE", "issue-key-0002");
            update(connection, """
                    update stock_reservations
                    set consumed_qty = consumed_qty + 1 where id = ?
                    """, f.reservationId());
            updateAmount(connection, """
                    update stock_balances set qty = qty - ? where id = ?
                    """, "1", f.balanceId());
            stockPosting(
                    connection, lateIssue, f.drawItemId(), f.demandId(),
                    f.reservationId(), null, "ISSUE", "1");
            assertFalse(booleanValue(connection, """
                    select is_closed from production_plans where id = ?
                    """, f.planId()));
            assertDecimal(connection, """
                    select uncleared_qty from v_production_material_clearance
                    where demand_id = ?
                    """, f.demandId(), "1");
        }
    }

    @Test
    void concurrentIssueCannotConsumeOneReservationTwice() {
        assertTimeoutPreemptively(Duration.ofSeconds(20), () -> {
            Fixture f;
            try (Connection setup = connection()) {
                f = fixture(setup, "100", "40");
            }
            CountDownLatch firstUpdated = new CountDownLatch(1);
            CountDownLatch releaseFirst = new CountDownLatch(1);
            try (ExecutorService executor = Executors.newFixedThreadPool(2)) {
                Future<Integer> first = executor.submit(() -> {
                    try (Connection c = connection()) {
                        c.setAutoCommit(false);
                        try {
                            int changed = update(c, """
                                    update stock_reservations
                                    set consumed_qty = consumed_qty + 30
                                    where id = ?
                                      and consumed_qty + released_qty + 30 <= qty
                                    """, f.reservationId());
                            firstUpdated.countDown();
                            assertTrue(releaseFirst.await(5, TimeUnit.SECONDS));
                            c.commit();
                            return changed;
                        } catch (Throwable error) {
                            c.rollback();
                            firstUpdated.countDown();
                            throw error;
                        }
                    }
                });
                assertTrue(firstUpdated.await(5, TimeUnit.SECONDS));
                Future<Integer> second = executor.submit(() -> {
                    try (Connection c = connection()) {
                        c.setAutoCommit(false);
                        int changed = update(c, """
                                update stock_reservations
                                set consumed_qty = consumed_qty + 20
                                where id = ?
                                  and consumed_qty + released_qty + 20 <= qty
                                """, f.reservationId());
                        c.commit();
                        return changed;
                    }
                });
                assertFalse(second.isDone());
                releaseFirst.countDown();
                assertEquals(1, first.get(5, TimeUnit.SECONDS));
                assertEquals(0, second.get(5, TimeUnit.SECONDS));
            } finally {
                releaseFirst.countDown();
            }
        });
    }

    private static Fixture fixture(
            Connection c, String stockQty, String reservedQty) throws Exception {
        UUID warehouse = UUID.randomUUID();
        UUID goods = UUID.randomUUID();
        UUID unit = UUID.randomUUID();
        UUID balance = UUID.randomUUID();
        UUID plan = UUID.randomUUID();
        UUID planItem = UUID.randomUUID();
        UUID pkg = UUID.randomUUID();
        UUID demand = UUID.randomUUID();
        UUID reservation = UUID.randomUUID();
        LocalDate billDate = LocalDate.of(2026, 7, 31);
        String planNo = businessIdentifier("SJ", billDate);

        insert(c, "insert into units(id,code,name) values(?,?,'piece')",
                unit, "U-" + unit);
        insert(c, "insert into goods(id,code,name,min_qty,code_sequence) "
                        + "values(?,?,'material',0,(select coalesce(max(code_sequence),0)+1 from goods))",
                goods, "G-" + goods);
        insert(c, "insert into warehouses(id,code,name) values(?,?,'warehouse')",
                warehouse, "W-" + warehouse);
        insert(c, """
                insert into stock_balances(id,warehouse_id,goods_id,qty)
                values(?,?,?,?)
                """, balance, warehouse, goods, decimal(stockQty));
        insert(c, """
                insert into production_plans(
                    id,bill_no,bill_date,status,is_closed
                ) values(?,?,?,1,false)
                """, plan, planNo, billDate);
        insert(c, """
                insert into production_plan_items(
                    id,bill_no,bill_date,plan_id,product_no,
                    goods_id,unit_id,unit_rate,qty,fqty,iqty
                ) values(?,?,?,?,?,?,?,1,1,1,1)
                """, planItem, planNo, billDate,
                plan, "PRODUCT-" + planItem, goods, unit);
        insert(c, """
                insert into production_planning_packages(
                    id,plan_id,warehouse_id,idempotency_key,
                    request_hash,preview_fingerprint,status
                ) values(?,?,?,?,?,?,'CONFIRMED')
                """, pkg, plan, warehouse, "package-" + pkg,
                "a".repeat(64), "b".repeat(64));
        insert(c, """
                insert into production_material_demands(
                    id,package_id,plan_id,warehouse_id,goods_id,unit_id,
                    required_qty,supply_route,status,idempotency_key
                ) values(?,?,?,?,?,?,?,'BUY','ALLOCATED',?)
                """, demand, pkg, plan, warehouse, goods, unit,
                decimal(reservedQty), "demand-" + demand);
        insert(c, """
                insert into stock_reservations(
                    id,goods_id,warehouse_id,qty,consumed_qty,released_qty,
                    status,source,source_doc_type,source_doc_id,
                    owner_type,owner_id,purpose,demand_id,
                    supply_type,supply_id,idempotency_key
                ) values(?,?,?, ?,0,0, 0,2,'PRODUCTION_PLANNING_PACKAGE',?,
                    'PRODUCTION_MATERIAL_DEMAND',?,'PRODUCTION_MATERIAL',?,
                    'STOCK_BALANCE',?,?)
                """, reservation, goods, warehouse, decimal(reservedQty), pkg,
                demand, demand, balance, "allocation-" + reservation);
        UUID draw = stockDocument(c, warehouse, "DRAW");
        UUID drawItem = stockItem(
                c, draw, goods, unit, null, reservedQty, "DRAW");
        insert(c, """
                insert into plan_draw_links(plan_id,draw_id)
                values(?,?)
                """, plan, draw);
        return new Fixture(
                warehouse, goods, unit, balance, plan, planItem, pkg,
                demand, reservation, draw, drawItem);
    }

    private static UUID stockDocument(
            Connection c, UUID warehouse, String type) throws Exception {
        UUID id = UUID.randomUUID();
        LocalDate billDate = LocalDate.of(2026, 7, 31);
        String documentNo = businessIdentifier(
                switch (type) {
                    case "DRAW" -> "SL";
                    case "WDRAW" -> "ST";
                    default -> throw new IllegalArgumentException(
                            "unsupported stock document type: " + type);
                },
                billDate);
        insert(c, """
                insert into stock_documents(
                    id,doc_type,bill_no,bill_date,warehouse_id,status
                ) values(?,?,?,?,?,1)
                """, id, type, documentNo, billDate, warehouse);
        return id;
    }

    private static UUID stockItem(
            Connection c, UUID doc, UUID goods, UUID unit,
            UUID upstream, String qty, String type) throws Exception {
        UUID id = UUID.randomUUID();
        insert(c, """
                insert into stock_document_items(
                    id,doc_id,bill_type,bill_no,bill_date,line_no,
                    goods_id,unit_id,unit_rate,qty,base_qty,upstream_item_id,
                    goods_snapshot_source
                ) values(?,?,?,'LINE',?,1,?,?,1,?,?,?,'MASTER_AT_SAVE')
                """, id, doc, type, LocalDate.of(2026, 7, 31),
                goods, unit, decimal(qty), decimal(qty), upstream);
        return id;
    }

    private static UUID event(
            Connection c, UUID doc, String type, String key) throws Exception {
        UUID id = UUID.randomUUID();
        insert(c, """
                insert into production_material_stock_events(
                    id,stock_document_id,event_type,idempotency_key,request_hash
                ) values(?,?,?,?,?)
                """, id, doc, type, key, "c".repeat(64));
        return id;
    }

    private static UUID stockPosting(
            Connection c, UUID event, UUID item, UUID demand,
            UUID reservation, UUID source, String type, String qty) throws Exception {
        UUID id = UUID.randomUUID();
        insert(c, """
                insert into production_material_stock_postings(
                    id,event_id,stock_document_item_id,demand_id,reservation_id,
                    source_posting_id,posting_type,qty_base
                ) values(?,?,?,?,?,?,?,?)
                """, id, event, item, demand, reservation, source, type, decimal(qty));
        return id;
    }

    private static int update(
            Connection c, String sql, Object... values) throws Exception {
        try (PreparedStatement statement = c.prepareStatement(sql)) {
            bind(statement, values);
            return statement.executeUpdate();
        }
    }

    private static void updateAmount(
            Connection c, String sql, String qty, UUID id) throws Exception {
        update(c, sql, decimal(qty), id);
    }

    private static void insert(
            Connection c, String sql, Object... values) throws Exception {
        update(c, sql, values);
    }

    private static void bind(PreparedStatement statement, Object... values)
            throws Exception {
        for (int i = 0; i < values.length; i++) {
            statement.setObject(i + 1, values[i]);
        }
    }

    private static void assertDecimal(
            Connection c, String sql, UUID first, String expected) throws Exception {
        try (PreparedStatement statement = c.prepareStatement(sql)) {
            statement.setObject(1, first);
            try (ResultSet result = statement.executeQuery()) {
                assertTrue(result.next());
                assertEquals(0, decimal(expected).compareTo(result.getBigDecimal(1)));
            }
        }
    }

    private static void assertDecimal(
            Connection c, String sql, UUID first, UUID second, String expected)
            throws Exception {
        try (PreparedStatement statement = c.prepareStatement(sql)) {
            statement.setObject(1, first);
            statement.setObject(2, second);
            try (ResultSet result = statement.executeQuery()) {
                assertTrue(result.next());
                assertEquals(0, decimal(expected).compareTo(result.getBigDecimal(1)));
            }
        }
    }

    private static boolean booleanValue(
            Connection c, String sql, UUID id) throws Exception {
        try (PreparedStatement statement = c.prepareStatement(sql)) {
            statement.setObject(1, id);
            try (ResultSet result = statement.executeQuery()) {
                assertTrue(result.next());
                return result.getBoolean(1);
            }
        }
    }

    private static BigDecimal decimal(String value) {
        return new BigDecimal(value);
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

    private record Fixture(
            UUID warehouseId,
            UUID goodsId,
            UUID unitId,
            UUID balanceId,
            UUID planId,
            UUID planItemId,
            UUID packageId,
            UUID demandId,
            UUID reservationId,
            UUID drawId,
            UUID drawItemId) {
    }
}
