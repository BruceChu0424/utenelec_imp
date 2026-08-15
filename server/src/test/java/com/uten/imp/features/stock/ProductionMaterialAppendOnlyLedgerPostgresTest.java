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
import java.time.LocalDate;
import java.util.UUID;

import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertThrows;
import static org.junit.jupiter.api.Assertions.assertTrue;

/** PostgreSQL proof that V161 material ledgers only accept appended facts. */
@EnabledIfEnvironmentVariable(named = "UTEN_RUN_DB_TESTS", matches = "(?i)true")
class ProductionMaterialAppendOnlyLedgerPostgresTest {

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
    void sourceFactsCannotBeChangedOrDeletedAndReversalsAppend() throws Exception {
        try (Connection connection = connection()) {
            Fixture f = fixture(connection);

            UUID stockEvent = event(
                    connection, f.drawId(), "ISSUE", "issue-ledger-0001");
            update(connection, """
                    update stock_reservations
                    set consumed_qty = consumed_qty + 10
                    where id = ?
                    """, f.reservationId());
            update(connection, """
                    update stock_balances
                    set qty = qty - 10
                    where id = ?
                    """, f.balanceId());
            UUID stockPosting = stockPosting(
                    connection,
                    stockEvent,
                    f.drawItemId(),
                    f.demandId(),
                    f.reservationId(),
                    null,
                    "ISSUE",
                    "10");

            UUID settlementEvent = UUID.randomUUID();
            insert(connection, """
                    insert into production_material_settlement_events(
                        id, plan_id, event_type, idempotency_key, request_hash
                    ) values (?, ?, 'POST', 'settle-ledger-0001', ?)
                    """, settlementEvent, f.planId(), "d".repeat(64));
            UUID settlementPosting = UUID.randomUUID();
            insert(connection, """
                    insert into production_material_settlement_postings(
                        id, event_id, demand_id, settlement_type, qty_base
                    ) values (?, ?, ?, 'CONSUMED', 5)
                    """, settlementPosting, settlementEvent, f.demandId());

            assertImmutable(
                    connection,
                    "update production_material_stock_events "
                            + "set created_at = created_at where id = ?",
                    stockEvent,
                    "production_material_stock_events_append_only_guard");
            assertImmutable(
                    connection,
                    "delete from production_material_stock_events where id = ?",
                    stockEvent,
                    "production_material_stock_events_append_only_guard");
            assertImmutable(
                    connection,
                    "update production_material_stock_postings "
                            + "set created_at = created_at where id = ?",
                    stockPosting,
                    "production_material_stock_postings_append_only_guard");
            assertImmutable(
                    connection,
                    "delete from production_material_stock_postings where id = ?",
                    stockPosting,
                    "production_material_stock_postings_append_only_guard");
            assertImmutable(
                    connection,
                    "update production_material_settlement_events "
                            + "set created_at = created_at where id = ?",
                    settlementEvent,
                    "production_material_settlement_events_append_only_guard");
            assertImmutable(
                    connection,
                    "delete from production_material_settlement_events "
                            + "where id = ?",
                    settlementEvent,
                    "production_material_settlement_events_append_only_guard");
            assertImmutable(
                    connection,
                    "update production_material_settlement_postings "
                            + "set created_at = created_at where id = ?",
                    settlementPosting,
                    "production_material_settlement_postings_append_only_guard");
            assertImmutable(
                    connection,
                    "delete from production_material_settlement_postings "
                            + "where id = ?",
                    settlementPosting,
                    "production_material_settlement_postings_append_only_guard");

            assertEquals(
                    1,
                    count(connection, """
                            select count(*)
                            from production_material_stock_postings
                            where event_id = ?
                            """, stockEvent),
                    "deleting an event must not cascade-delete its posting");
            assertEquals("r", foreignKeyDeleteAction(
                    connection,
                    "production_material_stock_postings_event_id_fkey"));
            assertEquals("r", foreignKeyDeleteAction(
                    connection,
                    "production_material_settlement_postings_event_id_fkey"));

            UUID settlementReverseEvent = UUID.randomUUID();
            insert(connection, """
                    insert into production_material_settlement_events(
                        id, plan_id, event_type, idempotency_key, request_hash
                    ) values (?, ?, 'REVERSE', 'settle-reverse-0001', ?)
                    """, settlementReverseEvent, f.planId(), "e".repeat(64));
            insert(connection, """
                    insert into production_material_settlement_postings(
                        id, event_id, demand_id, settlement_type,
                        qty_base, source_posting_id
                    ) values (?, ?, ?, 'CONSUMED', 2, ?)
                    """, UUID.randomUUID(), settlementReverseEvent,
                    f.demandId(), settlementPosting);

            UUID stockReverseEvent = event(
                    connection,
                    f.drawId(),
                    "ISSUE_REVERSE",
                    "issue-reverse-0001");
            update(connection, """
                    update stock_balances
                    set qty = qty + 2
                    where id = ?
                    """, f.balanceId());
            update(connection, """
                    update stock_reservations
                    set consumed_qty = consumed_qty - 2
                    where id = ?
                    """, f.reservationId());
            stockPosting(
                    connection,
                    stockReverseEvent,
                    f.drawItemId(),
                    f.demandId(),
                    f.reservationId(),
                    stockPosting,
                    "ISSUE_REVERSE",
                    "2");

            assertEquals(2, count(
                    connection,
                    "select count(*) from production_material_stock_events"));
            assertEquals(2, count(
                    connection,
                    "select count(*) from production_material_stock_postings"));
            assertEquals(2, count(
                    connection,
                    "select count(*) from production_material_settlement_events"));
            assertEquals(2, count(
                    connection,
                    "select count(*) from production_material_settlement_postings"));
            assertDecimal(
                    connection,
                    "select qty_base from production_material_stock_postings "
                            + "where id = ?",
                    stockPosting,
                    "10");
            assertDecimal(
                    connection,
                    "select qty_base "
                            + "from production_material_settlement_postings "
                            + "where id = ?",
                    settlementPosting,
                    "5");
        }
    }

    private static Fixture fixture(Connection c) throws Exception {
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
        insert(c, "insert into warehouses(id,code,name) "
                        + "values(?,?,'warehouse')",
                warehouse, "W-" + warehouse);
        insert(c, """
                insert into stock_balances(id,warehouse_id,goods_id,qty)
                values(?,?,?,100)
                """, balance, warehouse, goods);
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
                ) values(?,?,?,?,?,?,10,'BUY','ALLOCATED',?)
                """, demand, pkg, plan, warehouse, goods, unit,
                "demand-" + demand);
        insert(c, """
                insert into stock_reservations(
                    id,goods_id,warehouse_id,qty,consumed_qty,released_qty,
                    status,source,source_doc_type,source_doc_id,
                    owner_type,owner_id,purpose,demand_id,
                    supply_type,supply_id,idempotency_key
                ) values(?,?,?,10,0,0,0,2,
                    'PRODUCTION_PLANNING_PACKAGE',?,
                    'PRODUCTION_MATERIAL_DEMAND',?,
                    'PRODUCTION_MATERIAL',?,
                    'STOCK_BALANCE',?,?)
                """, reservation, goods, warehouse, pkg, demand, demand,
                balance, "allocation-" + reservation);

        UUID draw = stockDocument(c, warehouse);
        UUID drawItem = stockItem(c, draw, goods, unit);
        insert(c, "insert into plan_draw_links(plan_id,draw_id) values(?,?)",
                plan, draw);
        return new Fixture(
                balance,
                plan,
                demand,
                reservation,
                draw,
                drawItem);
    }

    private static UUID stockDocument(Connection c, UUID warehouse)
            throws Exception {
        UUID id = UUID.randomUUID();
        LocalDate billDate = LocalDate.of(2026, 7, 31);
        insert(c, """
                insert into stock_documents(
                    id,doc_type,bill_no,bill_date,warehouse_id,status
                ) values(?,'DRAW',?,?,?,1)
                """, id, businessIdentifier("SL", billDate), billDate, warehouse);
        return id;
    }

    private static UUID stockItem(
            Connection c, UUID doc, UUID goods, UUID unit) throws Exception {
        UUID id = UUID.randomUUID();
        insert(c, """
                insert into stock_document_items(
                    id,doc_id,bill_type,bill_no,bill_date,line_no,
                    goods_id,unit_id,unit_rate,qty,base_qty,
                    goods_snapshot_source
                ) values(?,?,'DRAW','LINE',?,1,?,?,1,10,10,'MASTER_AT_SAVE')
                """, id, doc, LocalDate.of(2026, 7, 31), goods, unit);
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
            Connection c,
            UUID event,
            UUID item,
            UUID demand,
            UUID reservation,
            UUID source,
            String type,
            String qty) throws Exception {
        UUID id = UUID.randomUUID();
        insert(c, """
                insert into production_material_stock_postings(
                    id,event_id,stock_document_item_id,demand_id,reservation_id,
                    source_posting_id,posting_type,qty_base
                ) values(?,?,?,?,?,?,?,?)
                """, id, event, item, demand, reservation,
                source, type, decimal(qty));
        return id;
    }

    private static void assertImmutable(
            Connection c, String sql, UUID id, String constraint) {
        PSQLException error = assertThrows(
                PSQLException.class,
                () -> update(c, sql, id));
        assertEquals("55000", error.getSQLState());
        assertEquals(
                constraint,
                error.getServerErrorMessage().getConstraint());
        assertTrue(error.getServerErrorMessage().getHint().contains("reversal"));
    }

    private static int count(Connection c, String sql, Object... values)
            throws Exception {
        try (PreparedStatement statement = c.prepareStatement(sql)) {
            bind(statement, values);
            try (ResultSet result = statement.executeQuery()) {
                assertTrue(result.next());
                return result.getInt(1);
            }
        }
    }

    private static String foreignKeyDeleteAction(
            Connection c, String constraint) throws Exception {
        try (PreparedStatement statement = c.prepareStatement("""
                select confdeltype::text
                from pg_constraint
                where conname = ?
                """)) {
            statement.setString(1, constraint);
            try (ResultSet result = statement.executeQuery()) {
                assertTrue(result.next());
                return result.getString(1);
            }
        }
    }

    private static void assertDecimal(
            Connection c, String sql, UUID id, String expected) throws Exception {
        try (PreparedStatement statement = c.prepareStatement(sql)) {
            statement.setObject(1, id);
            try (ResultSet result = statement.executeQuery()) {
                assertTrue(result.next());
                assertEquals(
                        0,
                        decimal(expected).compareTo(result.getBigDecimal(1)));
            }
        }
    }

    private static int update(
            Connection c, String sql, Object... values) throws Exception {
        try (PreparedStatement statement = c.prepareStatement(sql)) {
            bind(statement, values);
            return statement.executeUpdate();
        }
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
            UUID balanceId,
            UUID planId,
            UUID demandId,
            UUID reservationId,
            UUID drawId,
            UUID drawItemId) {
    }
}
