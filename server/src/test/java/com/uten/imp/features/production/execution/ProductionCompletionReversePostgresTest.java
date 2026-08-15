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
import java.util.ArrayList;
import java.util.List;
import java.util.UUID;

import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertThrows;

/**
 * PostgreSQL evidence for the explicit completed-segment correction workflow.
 */
@EnabledIfEnvironmentVariable(named = "UTEN_RUN_DB_TESTS", matches = "(?i)true")
class ProductionCompletionReversePostgresTest {

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
    void explicitReopenThenInboundReverseAllowsReportReverse()
            throws Exception {
        try (Connection connection = connection()) {
            Fixture fixture = completedFixture(connection, 1);
            UUID segmentId = fixture.segments().getFirst().segmentId();

            // V156 still blocks every direct bypass.
            PSQLException direct = assertThrows(
                    PSQLException.class,
                    () -> update(connection, """
                            UPDATE production_execution_segments
                            SET status = 'IN_PROGRESS',
                                completion_reopened = TRUE
                            WHERE id = ?
                            """, segmentId));
            assertEquals("23514", direct.getSQLState());

            explicitReverseCompletion(
                    connection, fixture.finishedInboundId(),
                    fixture.segments(), true);

            assertSegment(
                    connection, segmentId, "IN_PROGRESS", true);
            assertShort(connection, """
                    SELECT status FROM stock_documents WHERE id = ?
                    """, fixture.finishedInboundId(), (short) -1);
            assertCount(connection, """
                    SELECT COUNT(*)
                    FROM production_execution_segment_events
                    WHERE execution_segment_id = ?
                      AND action = 'REOPEN_COMPLETION'
                    """, segmentId, 1);

            // This is the strict second step. The application guard now sees
            // IN_PROGRESS and can reverse the exact report fact.
            update(connection, """
                    UPDATE production_daily_reports
                    SET status = -1
                    WHERE id = ?
                    """, fixture.reportId());
            assertShort(connection, """
                    SELECT status
                    FROM production_daily_reports
                    WHERE id = ?
                    """, fixture.reportId(), (short) -1);

            // The stock-document state machine makes retries a no-op before
            // the semantic event path can run again.
            assertEquals(0, update(connection, """
                    UPDATE stock_documents
                    SET status = -1
                    WHERE id = ? AND status = 1
                    """, fixture.finishedInboundId()));
            assertCount(connection, """
                    SELECT COUNT(*)
                    FROM production_execution_segment_events
                    WHERE execution_segment_id = ?
                      AND action = 'REOPEN_COMPLETION'
                    """, segmentId, 1);
        }
    }

    @Test
    void downstreamFailureRollsBackReopenDocumentAndEvent()
            throws Exception {
        try (Connection connection = connection()) {
            Fixture fixture = completedFixture(connection, 1);
            SegmentFixture segment = fixture.segments().getFirst();

            connection.setAutoCommit(false);
            try {
                authorize(connection, fixture.finishedInboundId());
                reopen(connection, fixture.finishedInboundId(), segment);
                update(connection, """
                        UPDATE stock_documents SET status = -1 WHERE id = ?
                        """, fixture.finishedInboundId());

                // Represents any later sales-reservation/inventory/downstream
                // guard failure in StockDocService.reverse.
                assertThrows(PSQLException.class, () -> insert(connection, """
                        INSERT INTO production_execution_segment_events(
                            id, execution_segment_id, action,
                            idempotency_key, request_hash,
                            expected_version, resulting_version
                        ) VALUES (
                            ?,?,'REOPEN_COMPLETION',?,?,?,?
                        )
                        """, UUID.randomUUID(), segment.segmentId(),
                        eventKey(fixture.finishedInboundId()),
                        "f".repeat(64), segment.lockVersion(),
                        segment.lockVersion() + 1));
                connection.rollback();
            } finally {
                connection.setAutoCommit(true);
            }

            assertSegment(
                    connection, segment.segmentId(), "COMPLETED", false);
            assertShort(connection, """
                    SELECT status FROM stock_documents WHERE id = ?
                    """, fixture.finishedInboundId(), (short) 1);
            assertCount(connection, """
                    SELECT COUNT(*)
                    FROM production_execution_segment_events
                    WHERE execution_segment_id = ?
                      AND action = 'REOPEN_COMPLETION'
                    """, segment.segmentId(), 0);
        }
    }

    @Test
    void oneInboundWithMultipleSegmentsIsAllOrNothing()
            throws Exception {
        try (Connection connection = connection()) {
            Fixture fixture = completedFixture(connection, 2);
            SegmentFixture first = fixture.segments().get(0);
            SegmentFixture second = fixture.segments().get(1);

            connection.setAutoCommit(false);
            try {
                authorize(connection, fixture.finishedInboundId());
                reopen(connection, fixture.finishedInboundId(), first);

                // The second segment has no semantic event. Its DB row guard
                // aborts the transaction, including the already reopened row.
                PSQLException rejected = assertThrows(
                        PSQLException.class,
                        () -> update(connection, """
                                UPDATE production_execution_segments
                                SET status = 'IN_PROGRESS',
                                    completion_reopened = TRUE
                                WHERE id = ?
                                """, second.segmentId()));
                assertEquals("23514", rejected.getSQLState());
                connection.rollback();
            } finally {
                connection.setAutoCommit(true);
            }

            assertSegment(
                    connection, first.segmentId(), "COMPLETED", false);
            assertSegment(
                    connection, second.segmentId(), "COMPLETED", false);
            assertCount(connection, """
                    SELECT COUNT(*)
                    FROM production_execution_segment_events
                    WHERE action = 'REOPEN_COMPLETION'
                      AND execution_segment_id IN (?,?)
                    """, first.segmentId(), second.segmentId(), 0);
            assertShort(connection, """
                    SELECT status FROM stock_documents WHERE id = ?
                    """, fixture.finishedInboundId(), (short) 1);

            explicitReverseCompletion(
                    connection, fixture.finishedInboundId(),
                    fixture.segments(), true);
            assertSegment(
                    connection, first.segmentId(), "IN_PROGRESS", true);
            assertSegment(
                    connection, second.segmentId(), "IN_PROGRESS", true);
            assertCount(connection, """
                    SELECT COUNT(*)
                    FROM production_execution_segment_events
                    WHERE action = 'REOPEN_COMPLETION'
                      AND execution_segment_id IN (?,?)
                    """, first.segmentId(), second.segmentId(), 2);
        }
    }

    private static Fixture completedFixture(
            Connection connection, int segmentCount) throws Exception {
        UUID warehouse = UUID.randomUUID();
        UUID material = UUID.randomUUID();
        UUID product = UUID.randomUUID();
        UUID unit = UUID.randomUUID();
        UUID balance = UUID.randomUUID();
        UUID plan = UUID.randomUUID();
        UUID pkg = UUID.randomUUID();
        LocalDate billDate = LocalDate.of(2026, 7, 31);
        String planNo = businessIdentifier("SJ", billDate);

        insert(connection,
                "INSERT INTO units(id,code,name) VALUES(?,?,'piece')",
                unit, "U-" + unit);
        insert(connection,
                "INSERT INTO goods(id,code,name,min_qty,code_sequence)"
                        + " VALUES(?,?,'material',0,(SELECT COALESCE(MAX(code_sequence),0)+1 FROM goods))",
                material, "M-" + material);
        insert(connection,
                "INSERT INTO goods(id,code,name,min_qty,code_sequence)"
                        + " VALUES(?,?,'product',0,(SELECT COALESCE(MAX(code_sequence),0)+1 FROM goods))",
                product, "P-" + product);
        insert(connection,
                "INSERT INTO warehouses(id,code,name)"
                        + " VALUES(?,?,'warehouse')",
                warehouse, "W-" + warehouse);
        insert(connection, """
                INSERT INTO stock_balances(
                    id,warehouse_id,goods_id,qty
                ) VALUES(?,?,?,?)
                """, balance, warehouse, material,
                BigDecimal.TEN.multiply(BigDecimal.valueOf(segmentCount)));
        insert(connection, """
                INSERT INTO production_plans(
                    id,bill_no,bill_date,status,is_closed
                ) VALUES(?,?,?,1,false)
                """, plan, planNo, billDate);

        List<SegmentFixture> segments = new ArrayList<>();
        connection.setAutoCommit(false);
        try {
            insert(connection, """
                    INSERT INTO production_planning_packages(
                        id,plan_id,warehouse_id,idempotency_key,
                        request_hash,preview_fingerprint,status,
                        execution_model_version
                    ) VALUES(?,?,?,?,?,?,'CONFIRMED',1)
                    """, pkg, plan, warehouse, "package-" + pkg,
                    "a".repeat(64), "b".repeat(64));
            for (int index = 0; index < segmentCount; index++) {
                UUID planItem = UUID.randomUUID();
                UUID segment = UUID.randomUUID();
                UUID demand = UUID.randomUUID();
                UUID reservation = UUID.randomUUID();
                UUID draw = UUID.randomUUID();
                UUID drawItem = UUID.randomUUID();
                String drawNo = businessIdentifier("SL", billDate);
                insert(connection, """
                        INSERT INTO production_plan_items(
                            id,bill_no,bill_date,plan_id,product_no,
                            goods_id,unit_id,unit_rate,qty,fqty,iqty
                        ) VALUES(?,?,?,?,?,?,?,1,10,0,0)
                        """, planItem, planNo,
                        billDate, plan,
                        "PRODUCT-" + planItem, product, unit);
                insert(connection, """
                        INSERT INTO production_execution_segments(
                            id,package_id,plan_id,source_plan_item_id,
                            segment_no,segment_code,client_segment_key,
                            product_goods_id,product_unit_id,
                            product_unit_rate,planned_qty,status,
                            bom_fingerprint,idempotency_key
                        ) VALUES(?,?,?,?,?,?,?,?,?,1,10,'READY',?,?)
                        """, segment, pkg, plan, planItem, index + 1,
                        canonicalSegmentCode(segment), "client-" + segment,
                        product, unit, "e".repeat(64),
                        "segment-" + segment);
                insert(connection, """
                        INSERT INTO production_material_demands(
                            id,package_id,plan_id,warehouse_id,
                            goods_id,unit_id,required_qty,supply_route,
                            status,idempotency_key,execution_segment_id,
                            source_plan_item_id,per_product_qty
                        ) VALUES(
                            ?,?,?,?,?,?,10,'BUY','ALLOCATED',?,?,?,1
                        )
                        """, demand, pkg, plan, warehouse, material, unit,
                        "demand-" + demand, segment, planItem);
                insert(connection, """
                        INSERT INTO stock_reservations(
                            id,goods_id,warehouse_id,qty,consumed_qty,
                            released_qty,status,source,source_doc_type,
                            source_doc_id,owner_type,owner_id,purpose,
                            demand_id,supply_type,supply_id,idempotency_key
                        ) VALUES(
                            ?,?,?,10,0,0,0,2,
                            'PRODUCTION_PLANNING_PACKAGE',?,
                            'PRODUCTION_MATERIAL_DEMAND',?,
                            'PRODUCTION_MATERIAL',?,
                            'STOCK_BALANCE',?,?
                        )
                        """, reservation, material, warehouse, pkg,
                        demand, demand, balance,
                        "reservation-" + reservation);
                insert(connection, """
                        INSERT INTO stock_documents(
                            id,doc_type,bill_no,bill_date,
                            warehouse_id,status
                        ) VALUES(?,'DRAW',?,?,?,0)
                        """, draw, drawNo,
                        billDate, warehouse);
                insert(connection, """
                        INSERT INTO stock_document_items(
                            id,doc_id,bill_type,bill_no,bill_date,
                            line_no,goods_id,unit_id,unit_rate,
                            qty,base_qty,goods_snapshot_source
                        ) VALUES(?,?,'DRAW','LINE',?,1,?,?,1,10,10,'MASTER_AT_SAVE')
                        """, drawItem, draw,
                        LocalDate.of(2026, 7, 31), material, unit);
                insert(connection, """
                        INSERT INTO plan_draw_links(plan_id,draw_id)
                        VALUES(?,?)
                        """, plan, draw);
                insert(connection, """
                        INSERT INTO production_planning_package_documents(
                            id,package_id,document_type,document_id,
                            document_no,execution_segment_id
                        ) VALUES(?,?,'DRAW',?,?,?)
                        """, UUID.randomUUID(), pkg, draw,
                        drawNo, segment);
                insert(connection, """
                        INSERT INTO production_planning_package_document_items(
                            id,package_id,demand_id,document_type,
                            document_id,document_item_id
                        ) VALUES(?,?,?,'DRAW',?,?)
                        """, UUID.randomUUID(), pkg, demand, draw, drawItem);
                segments.add(new SegmentFixture(
                        segment, planItem, demand, reservation,
                        draw, drawItem, 0));
            }
            connection.commit();
        } catch (Throwable error) {
            connection.rollback();
            throw error;
        } finally {
            connection.setAutoCommit(true);
        }

        UUID department = departmentId(connection, "WS_ZHUSU");
        UUID employee = UUID.randomUUID();
        insert(connection, """
                INSERT INTO employees(
                    id,code,full_name,id_type,department_id,
                    hire_date,status,employment_type
                ) VALUES(?,?,?,'其他',?,?,'active','regular')
                """, employee, "E-" + employee, "owner", department,
                LocalDate.of(2026, 1, 1));
        for (SegmentFixture segment : segments) {
            update(connection, """
                    UPDATE production_execution_segments
                    SET workshop_department_id=?,
                        responsible_employee_id=?,
                        plan_begin_date=?,plan_end_date=?,
                        status='DISPATCHED'
                    WHERE id=?
                    """, department, employee,
                    LocalDate.of(2026, 8, 1),
                    LocalDate.of(2026, 8, 2),
                    segment.segmentId());
            update(connection, """
                    UPDATE production_execution_segments
                    SET status='IN_PROGRESS' WHERE id=?
                    """, segment.segmentId());
        }

        UUID report = UUID.randomUUID();
        String reportNo = businessIdentifier("SR", billDate);
        insert(connection, """
                INSERT INTO production_daily_reports(
                    id,bill_no,bill_date,status
                ) VALUES(?,?,?,1)
                """, report, reportNo, billDate);
        int reportLine = 1;
        for (SegmentFixture segment : segments) {
            insert(connection, """
                    INSERT INTO production_daily_report_items(
                        id,bill_no,bill_date,report_id,line_no,
                        goods_id,unit_id,unit_rate,qty,plan_item_id,
                        execution_segment_id
                    ) VALUES(?,?,?,?,?,?,?,1,10,?,?)
                    """, UUID.randomUUID(), reportNo,
                    billDate, report, reportLine++,
                    product, unit, segment.planItemId(),
                    segment.segmentId());
        }

        for (SegmentFixture segment : segments) {
            UUID stockEvent = UUID.randomUUID();
            insert(connection, """
                    INSERT INTO production_material_stock_events(
                        id,stock_document_id,event_type,
                        idempotency_key,request_hash
                    ) VALUES(?,?,'ISSUE',?,?)
                    """, stockEvent, segment.drawId(),
                    "issue-" + UUID.randomUUID(), "c".repeat(64));
            insert(connection, """
                    INSERT INTO production_material_stock_postings(
                        id,event_id,stock_document_item_id,demand_id,
                        reservation_id,posting_type,qty_base
                    ) VALUES(?,?,?,?,?,'ISSUE',10)
                    """, UUID.randomUUID(), stockEvent,
                    segment.drawItemId(), segment.demandId(),
                    segment.reservationId());
        }
        UUID settlementEvent = UUID.randomUUID();
        insert(connection, """
                INSERT INTO production_material_settlement_events(
                    id,plan_id,event_type,idempotency_key,request_hash
                ) VALUES(?,?,'POST',?,?)
                """, settlementEvent, plan,
                "settle-" + UUID.randomUUID(), "d".repeat(64));
        for (SegmentFixture segment : segments) {
            insert(connection, """
                    INSERT INTO production_material_settlement_postings(
                        id,event_id,demand_id,settlement_type,qty_base
                    ) VALUES(?,?,?,'CONSUMED',10)
                    """, UUID.randomUUID(), settlementEvent,
                    segment.demandId());
        }

        UUID inbound = UUID.randomUUID();
        String inboundNo = businessIdentifier("CR", billDate);
        insert(connection, """
                INSERT INTO stock_documents(
                    id,doc_type,bill_no,bill_date,warehouse_id,status
                ) VALUES(?,'FINISHED_IN',?,?,?,0)
                """, inbound, inboundNo, billDate, warehouse);
        int inboundLine = 1;
        for (SegmentFixture segment : segments) {
            insert(connection, """
                    INSERT INTO stock_document_items(
                        id,doc_id,bill_type,bill_no,bill_date,line_no,
                        goods_id,unit_id,unit_rate,qty,base_qty,
                        upstream_item_id,execution_segment_id,
                        goods_snapshot_source
                    ) VALUES(?,?,'FINISHED_IN','LINE',?,?,?,?,1,10,10,?,?,'MASTER_AT_SAVE')
                    """, UUID.randomUUID(), inbound,
                    LocalDate.of(2026, 7, 31), inboundLine++,
                    product, unit, segment.planItemId(),
                    segment.segmentId());
        }
        insert(connection, """
                INSERT INTO plan_draw_links(plan_id,draw_id)
                VALUES(?,?)
                """, plan, inbound);
        update(connection,
                "UPDATE stock_documents SET status=1 WHERE id=?",
                inbound);

        List<SegmentFixture> completed = new ArrayList<>();
        for (SegmentFixture segment : segments) {
            assertSegment(
                    connection, segment.segmentId(), "COMPLETED", false);
            completed.add(new SegmentFixture(
                    segment.segmentId(), segment.planItemId(),
                    segment.demandId(), segment.reservationId(),
                    segment.drawId(), segment.drawItemId(),
                    lockVersion(connection, segment.segmentId())));
        }
        return new Fixture(
                plan, report, inbound, List.copyOf(completed));
    }

    private static void explicitReverseCompletion(
            Connection connection,
            UUID documentId,
            List<SegmentFixture> segments,
            boolean reverseDocument) throws Exception {
        connection.setAutoCommit(false);
        try {
            authorize(connection, documentId);
            for (SegmentFixture segment : segments) {
                reopen(connection, documentId, segment);
            }
            if (reverseDocument) {
                update(connection, """
                        UPDATE stock_documents SET status=-1 WHERE id=?
                        """, documentId);
            }
            connection.commit();
        } catch (Throwable error) {
            connection.rollback();
            throw error;
        } finally {
            connection.setAutoCommit(true);
        }
    }

    private static void authorize(
            Connection connection, UUID documentId) throws Exception {
        try (PreparedStatement statement = connection.prepareStatement("""
                SELECT set_config(
                    'app.production_completion_reopen_doc_id', ?, true)
                """)) {
            statement.setString(1, documentId.toString());
            try (ResultSet ignored = statement.executeQuery()) {
                ignored.next();
            }
        }
    }

    private static void reopen(
            Connection connection,
            UUID documentId,
            SegmentFixture segment) throws Exception {
        insert(connection, """
                INSERT INTO production_execution_segment_events(
                    id,execution_segment_id,action,idempotency_key,
                    request_hash,expected_version,resulting_version
                ) VALUES(?,?,'REOPEN_COMPLETION',?,?,?,?)
                """, UUID.randomUUID(), segment.segmentId(),
                eventKey(documentId), "e".repeat(64),
                segment.lockVersion(), segment.lockVersion() + 1);
        assertEquals(1, update(connection, """
                UPDATE production_execution_segments
                SET status='IN_PROGRESS', completion_reopened=TRUE
                WHERE id=? AND status='COMPLETED' AND lock_version=?
                """, segment.segmentId(), segment.lockVersion()));
    }

    private static String eventKey(UUID documentId) {
        return "FINISHED_IN_REVERSE:" + documentId;
    }

    private static long lockVersion(
            Connection connection, UUID segmentId) throws Exception {
        try (PreparedStatement statement = connection.prepareStatement("""
                SELECT lock_version
                FROM production_execution_segments
                WHERE id=?
                """)) {
            statement.setObject(1, segmentId);
            try (ResultSet result = statement.executeQuery()) {
                result.next();
                return result.getLong(1);
            }
        }
    }

    private static void assertSegment(
            Connection connection,
            UUID segmentId,
            String status,
            boolean reopened) throws Exception {
        try (PreparedStatement statement = connection.prepareStatement("""
                SELECT status, completion_reopened
                FROM production_execution_segments
                WHERE id=?
                """)) {
            statement.setObject(1, segmentId);
            try (ResultSet result = statement.executeQuery()) {
                result.next();
                assertEquals(status, result.getString(1));
                assertEquals(reopened, result.getBoolean(2));
            }
        }
    }

    private static void assertShort(
            Connection connection,
            String sql,
            UUID id,
            short expected) throws Exception {
        try (PreparedStatement statement = connection.prepareStatement(sql)) {
            statement.setObject(1, id);
            try (ResultSet result = statement.executeQuery()) {
                result.next();
                assertEquals(expected, result.getShort(1));
            }
        }
    }

    private static void assertCount(
            Connection connection,
            String sql,
            Object first,
            int expected) throws Exception {
        assertCount(connection, sql, new Object[]{first}, expected);
    }

    private static void assertCount(
            Connection connection,
            String sql,
            Object first,
            Object second,
            int expected) throws Exception {
        assertCount(
                connection, sql, new Object[]{first, second}, expected);
    }

    private static void assertCount(
            Connection connection,
            String sql,
            Object[] values,
            int expected) throws Exception {
        try (PreparedStatement statement = connection.prepareStatement(sql)) {
            for (int index = 0; index < values.length; index++) {
                statement.setObject(index + 1, values[index]);
            }
            try (ResultSet result = statement.executeQuery()) {
                result.next();
                assertEquals(expected, result.getInt(1));
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
            Connection connection,
            String sql,
            Object... values) throws Exception {
        update(connection, sql, values);
    }

    private static int update(
            Connection connection,
            String sql,
            Object... values) throws Exception {
        try (PreparedStatement statement = connection.prepareStatement(sql)) {
            for (int index = 0; index < values.length; index++) {
                statement.setObject(index + 1, values[index]);
            }
            return statement.executeUpdate();
        }
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
            UUID planId,
            UUID reportId,
            UUID finishedInboundId,
            List<SegmentFixture> segments) {
    }

    private record SegmentFixture(
            UUID segmentId,
            UUID planItemId,
            UUID demandId,
            UUID reservationId,
            UUID drawId,
            UUID drawItemId,
            long lockVersion) {
    }
}
