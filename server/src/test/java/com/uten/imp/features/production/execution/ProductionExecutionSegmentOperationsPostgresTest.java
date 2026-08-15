package com.uten.imp.features.production.execution;

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

/** PostgreSQL evidence for exact report/inbound ownership and segment close gates. */
@EnabledIfEnvironmentVariable(named = "UTEN_RUN_DB_TESTS", matches = "(?i)true")
class ProductionExecutionSegmentOperationsPostgresTest {

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
    void partialInboundWaitsForMaterialClearanceAndCompletedReverseFailsClosed()
            throws Exception {
        try (Connection connection = connection()) {
            Fixture f = fixture(connection);

            UUID firstInbound = finishedIn(connection, f, "4");
            update(connection,
                    "update stock_documents set status=1 where id=?",
                    firstInbound);
            assertStatus(connection, f.segmentId(), "IN_PROGRESS");

            UUID secondInbound = finishedIn(connection, f, "6");
            update(connection,
                    "update stock_documents set status=1 where id=?",
                    secondInbound);
            assertStatus(connection, f.segmentId(), "IN_PROGRESS");

            UUID excessiveInbound = finishedIn(connection, f, "1");
            PSQLException over = assertThrows(
                    PSQLException.class,
                    () -> update(connection,
                            "update stock_documents set status=1 where id=?",
                            excessiveInbound));
            assertEquals("23514", over.getSQLState());

            UUID stockEvent = UUID.randomUUID();
            insert(connection, """
                    insert into production_material_stock_events(
                        id,stock_document_id,event_type,idempotency_key,request_hash
                    ) values(?,?,'ISSUE',?,?)
                    """, stockEvent, f.drawId(),
                    "issue-" + UUID.randomUUID(), "c".repeat(64));
            insert(connection, """
                    insert into production_material_stock_postings(
                        id,event_id,stock_document_item_id,demand_id,
                        reservation_id,posting_type,qty_base
                    ) values(?,?,?,?,?,'ISSUE',10)
                    """, UUID.randomUUID(), stockEvent, f.drawItemId(),
                    f.demandId(), f.reservationId());
            assertStatus(connection, f.segmentId(), "IN_PROGRESS");

            UUID settlementEvent = UUID.randomUUID();
            insert(connection, """
                    insert into production_material_settlement_events(
                        id,plan_id,event_type,idempotency_key,request_hash
                    ) values(?,?,'POST',?,?)
                    """, settlementEvent, f.planId(),
                    "settle-" + UUID.randomUUID(), "d".repeat(64));
            insert(connection, """
                    insert into production_material_settlement_postings(
                        id,event_id,demand_id,settlement_type,qty_base
                    ) values(?,?,?,'CONSUMED',10)
                    """, UUID.randomUUID(), settlementEvent, f.demandId());
            assertStatus(connection, f.segmentId(), "COMPLETED");

            PSQLException reverse = assertThrows(
                    PSQLException.class,
                    () -> update(connection,
                            "update stock_documents set status=-1 where id=?",
                            secondInbound));
            assertEquals("23514", reverse.getSQLState());
            assertStatus(connection, f.segmentId(), "COMPLETED");
        }
    }

    @Test
    void dailyReportRejectsAExecutionSegmentFromAnotherPlanItem()
            throws Exception {
        try (Connection connection = connection()) {
            Fixture f = fixture(connection);
            UUID otherPlan = UUID.randomUUID();
            UUID otherPlanItem = UUID.randomUUID();
            LocalDate billDate = LocalDate.of(2026, 7, 31);
            String otherPlanNo = businessIdentifier("SJ", billDate);
            insert(connection, """
                    insert into production_plans(
                        id,bill_no,bill_date,status,is_closed
                    ) values(?,?,?,1,false)
                    """, otherPlan, otherPlanNo, billDate);
            insert(connection, """
                    insert into production_plan_items(
                        id,bill_no,bill_date,plan_id,product_no,
                        goods_id,unit_id,unit_rate,qty,fqty,iqty
                    ) values(?,?,?,?,?,?,?,1,10,0,0)
                    """, otherPlanItem, otherPlanNo,
                    billDate, otherPlan,
                    "PRODUCT-" + otherPlanItem, f.productGoodsId(), f.unitId());

            UUID report = UUID.randomUUID();
            String reportNo = businessIdentifier("SR", billDate);
            insert(connection, """
                    insert into production_daily_reports(
                        id,bill_no,bill_date,status
                    ) values(?,?,?,0)
                    """, report, reportNo, billDate);
            PSQLException mismatch = assertThrows(
                    PSQLException.class,
                    () -> insert(connection, """
                            insert into production_daily_report_items(
                                id,bill_no,bill_date,report_id,line_no,
                                goods_id,unit_id,unit_rate,qty,plan_item_id,
                                execution_segment_id
                            ) values(?,?,?,?,1,?,?,1,1,?,?)
                            """, UUID.randomUUID(), reportNo,
                            billDate, report,
                            f.productGoodsId(), f.unitId(),
                            otherPlanItem, f.segmentId()));
            assertEquals("23514", mismatch.getSQLState());
        }
    }

    private static Fixture fixture(Connection c) throws Exception {
        UUID warehouse = UUID.randomUUID();
        UUID material = UUID.randomUUID();
        UUID product = UUID.randomUUID();
        UUID unit = UUID.randomUUID();
        UUID balance = UUID.randomUUID();
        UUID plan = UUID.randomUUID();
        UUID planItem = UUID.randomUUID();
        UUID pkg = UUID.randomUUID();
        UUID segment = UUID.randomUUID();
        UUID demand = UUID.randomUUID();
        UUID reservation = UUID.randomUUID();
        UUID draw = UUID.randomUUID();
        UUID drawItem = UUID.randomUUID();
        LocalDate billDate = LocalDate.of(2026, 7, 31);
        String planNo = businessIdentifier("SJ", billDate);
        String drawNo = businessIdentifier("SL", billDate);

        insert(c, "insert into units(id,code,name) values(?,?,'piece')",
                unit, "U-" + unit);
        insert(c, "insert into goods(id,code,name,min_qty,code_sequence) "
                        + "values(?,?,'material',0,(select coalesce(max(code_sequence),0)+1 from goods))",
                material, "M-" + material);
        insert(c, "insert into goods(id,code,name,min_qty,code_sequence) "
                        + "values(?,?,'product',0,(select coalesce(max(code_sequence),0)+1 from goods))",
                product, "P-" + product);
        insert(c, "insert into warehouses(id,code,name) values(?,?,'warehouse')",
                warehouse, "W-" + warehouse);
        insert(c, """
                insert into stock_balances(id,warehouse_id,goods_id,qty)
                values(?,?,?,10)
                """, balance, warehouse, material);
        insert(c, """
                insert into production_plans(
                    id,bill_no,bill_date,status,is_closed
                ) values(?,?,?,1,false)
                """, plan, planNo, billDate);
        insert(c, """
                insert into production_plan_items(
                    id,bill_no,bill_date,plan_id,product_no,
                    goods_id,unit_id,unit_rate,qty,fqty,iqty
                ) values(?,?,?,?,?,?,?,1,10,0,0)
                """, planItem, planNo, billDate,
                plan, "PRODUCT-" + planItem, product, unit);

        c.setAutoCommit(false);
        try {
            insert(c, """
                    insert into production_planning_packages(
                        id,plan_id,warehouse_id,idempotency_key,
                        request_hash,preview_fingerprint,status,
                        execution_model_version
                    ) values(?,?,?,?,?,?,'CONFIRMED',1)
                    """, pkg, plan, warehouse, "package-" + pkg,
                    "a".repeat(64), "b".repeat(64));
            insert(c, """
                    insert into production_execution_segments(
                        id,package_id,plan_id,source_plan_item_id,
                        segment_no,segment_code,client_segment_key,
                        product_goods_id,product_unit_id,product_unit_rate,
                        planned_qty,status,bom_fingerprint,idempotency_key
                    ) values(?,?,?,?,1,?,?,?, ?,1,10,'READY',?,?)
                    """, segment, pkg, plan, planItem,
                    canonicalSegmentCode(segment), "client-" + segment, product, unit,
                    "e".repeat(64), "segment-" + segment);
            insert(c, """
                    insert into production_material_demands(
                        id,package_id,plan_id,warehouse_id,goods_id,unit_id,
                        required_qty,supply_route,status,idempotency_key,
                        execution_segment_id,source_plan_item_id,per_product_qty
                    ) values(?,?,?,?,?,?,10,'BUY','ALLOCATED',?,?,?,1)
                    """, demand, pkg, plan, warehouse, material, unit,
                    "demand-" + demand, segment, planItem);
            insert(c, """
                    insert into stock_reservations(
                        id,goods_id,warehouse_id,qty,consumed_qty,released_qty,
                        status,source,source_doc_type,source_doc_id,
                        owner_type,owner_id,purpose,demand_id,
                        supply_type,supply_id,idempotency_key
                    ) values(?,?,?,10,0,0,0,2,'PRODUCTION_PLANNING_PACKAGE',?,
                        'PRODUCTION_MATERIAL_DEMAND',?,'PRODUCTION_MATERIAL',?,
                        'STOCK_BALANCE',?,?)
                    """, reservation, material, warehouse, pkg, demand,
                    demand, balance, "reservation-" + reservation);
            insert(c, """
                    insert into stock_documents(
                        id,doc_type,bill_no,bill_date,warehouse_id,status
                    ) values(?,'DRAW',?,?,?,0)
                    """, draw, drawNo, billDate, warehouse);
            insert(c, """
                    insert into stock_document_items(
                        id,doc_id,bill_type,bill_no,bill_date,line_no,
                        goods_id,unit_id,unit_rate,qty,base_qty,
                        goods_snapshot_source
                    ) values(?,?,'DRAW','LINE',?,1,?,?,1,10,10,'MASTER_AT_SAVE')
                    """, drawItem, draw, LocalDate.of(2026, 7, 31),
                    material, unit);
            insert(c, """
                    insert into plan_draw_links(plan_id,draw_id)
                    values(?,?)
                    """, plan, draw);
            insert(c, """
                    insert into production_planning_package_documents(
                        id,package_id,document_type,document_id,document_no,
                        execution_segment_id
                    ) values(?,?,'DRAW',?,?,?)
                    """, UUID.randomUUID(), pkg, draw, drawNo, segment);
            insert(c, """
                    insert into production_planning_package_document_items(
                        id,package_id,demand_id,document_type,
                        document_id,document_item_id
                    ) values(?,?,?,'DRAW',?,?)
                    """, UUID.randomUUID(), pkg, demand, draw, drawItem);
            c.commit();
        } catch (Throwable error) {
            c.rollback();
            throw error;
        } finally {
            c.setAutoCommit(true);
        }

        UUID department = departmentId(c, "WS_ZHUSU");
        UUID employee = UUID.randomUUID();
        insert(c, """
                insert into employees(
                    id,code,full_name,id_type,department_id,hire_date,
                    status,employment_type
                ) values(?,?,?,'其他',?,?,'active','regular')
                """, employee, "E-" + employee, "owner", department,
                LocalDate.of(2026, 1, 1));
        update(c, """
                update production_execution_segments
                set workshop_department_id=?,responsible_employee_id=?,
                    plan_begin_date=?,plan_end_date=?,status='DISPATCHED'
                where id=?
                """, department, employee, LocalDate.of(2026, 8, 1),
                LocalDate.of(2026, 8, 2), segment);
        update(c, """
                update production_execution_segments
                set status='IN_PROGRESS' where id=?
                """, segment);
        return new Fixture(
                warehouse, product, unit, plan, planItem, segment,
                demand, reservation, draw, drawItem);
    }

    private static UUID finishedIn(
            Connection c, Fixture f, String qty) throws Exception {
        UUID doc = UUID.randomUUID();
        LocalDate billDate = LocalDate.of(2026, 7, 31);
        String documentNo = businessIdentifier("CR", billDate);
        insert(c, """
                insert into stock_documents(
                    id,doc_type,bill_no,bill_date,warehouse_id,status
                ) values(?,'FINISHED_IN',?,?,?,0)
                """, doc, documentNo, billDate,
                f.warehouseId());
        insert(c, """
                insert into stock_document_items(
                    id,doc_id,bill_type,bill_no,bill_date,line_no,
                    goods_id,unit_id,unit_rate,qty,base_qty,
                    upstream_item_id,execution_segment_id,
                    goods_snapshot_source
                ) values(?,?,'FINISHED_IN','LINE',?,1,?,?,1,?,?,?,?,'MASTER_AT_SAVE')
                """, UUID.randomUUID(), doc, LocalDate.of(2026, 7, 31),
                f.productGoodsId(), f.unitId(), decimal(qty), decimal(qty),
                f.planItemId(), f.segmentId());
        return doc;
    }

    private static void assertStatus(
            Connection c, UUID segmentId, String expected) throws Exception {
        try (PreparedStatement statement = c.prepareStatement(
                "select status from production_execution_segments where id=?")) {
            statement.setObject(1, segmentId);
            try (ResultSet result = statement.executeQuery()) {
                result.next();
                assertEquals(expected, result.getString(1));
            }
        }
    }

    private static UUID departmentId(
            Connection connection,
            String code) throws Exception {
        try (PreparedStatement statement = connection.prepareStatement(
                "SELECT id FROM departments WHERE code = ? AND is_deleted = FALSE")) {
            statement.setString(1, code);
            try (ResultSet result = statement.executeQuery()) {
                result.next();
                return result.getObject(1, UUID.class);
            }
        }
    }

    private static void insert(
            Connection c, String sql, Object... values) throws Exception {
        update(c, sql, values);
    }

    private static int update(
            Connection c, String sql, Object... values) throws Exception {
        try (PreparedStatement statement = c.prepareStatement(sql)) {
            for (int index = 0; index < values.length; index++) {
                statement.setObject(index + 1, values[index]);
            }
            return statement.executeUpdate();
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

    private record Fixture(
            UUID warehouseId,
            UUID productGoodsId,
            UUID unitId,
            UUID planId,
            UUID planItemId,
            UUID segmentId,
            UUID demandId,
            UUID reservationId,
            UUID drawId,
            UUID drawItemId) {
    }
}
