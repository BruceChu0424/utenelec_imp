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

    private static final java.util.concurrent.atomic.AtomicInteger BUSINESS_IDENTIFIER_SEQUENCE =
            new java.util.concurrent.atomic.AtomicInteger();

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
                null, null, null, null, em, null, null, null, null,
                mock(com.uten.imp.features.common.taskclaim.TaskClaimService.class),
                mock(SalesOrderRevisionService.class),
                org.mockito.Mockito.mock(com.uten.imp.features.sales.SalesMutationFootprintService.class));
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
        UUID client = UUID.randomUUID();
        UUID material = UUID.randomUUID();
        UUID balance = UUID.randomUUID();
        LocalDate billDate = LocalDate.of(2026, 7, 31);
        String planNo = businessIdentifier("SJ", billDate);

        insert(connection, """
                INSERT INTO goods(id, code, name, code_sequence)
                VALUES(?, ?, 'V157 test product',
                       (SELECT COALESCE(MAX(code_sequence), 0) + 1 FROM goods))
                """, goods, "V157-G-" + goods);
        insert(connection, """
                INSERT INTO units(id, code, name)
                VALUES(?, ?, 'V157 test unit')
                """, unit, "V157-U-" + unit);
        insert(connection, """
                INSERT INTO warehouses(id, code, name)
                VALUES(?, ?, 'V157 test warehouse')
                """, warehouse, "V157-W-" + warehouse);
        insert(connection,"""
                INSERT INTO clients(id,code,name,status,code_sequence,sales_payment_type)
                VALUES(?,?,'Execution allocation customer','使用',
                    (SELECT COALESCE(MAX(code_sequence),0)+1 FROM clients),'MONTHLY')
                """,client,"V157-C-"+client);
        insert(connection,"""
                INSERT INTO goods(id,code,name,min_qty,code_sequence)
                VALUES(?,?,'Execution allocation material',0,(SELECT COALESCE(MAX(code_sequence),0)+1 FROM goods))
                """,material,"V157-M-"+material);
        insert(connection,"INSERT INTO stock_balances(id,warehouse_id,goods_id,qty) VALUES(?,?,?,10)",balance,warehouse,material);
        insert(connection, """
                INSERT INTO production_plans(
                    id,bill_no,bill_date,status
                ) VALUES(?,?,?,1)
                """, plan, planNo, billDate);
        insert(connection, """
                INSERT INTO production_plan_items(
                    id,bill_no,bill_date,plan_id,product_no,
                    goods_id,unit_id,unit_rate,qty,fqty,iqty
                ) VALUES(?,?,?,?,?,?,?,1,10,0,0)
                """, planItem, planNo,
                billDate, plan,
                "PRODUCT-" + planItem, goods, unit);
        insertOrder(
                connection, orderOne, orderItemOne, client,goods, unit,
                businessIdentifier("XD", billDate));
        insertOrder(
                connection, orderTwo, orderItemTwo, client,goods, unit,
                businessIdentifier("XD", billDate));
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
        connection.setAutoCommit(false);
        try { insert(connection, """
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
        addMaterials(connection,packageId,plan,planItem,segmentOne,warehouse,material,unit,balance,"6",billDate);
        addMaterials(connection,packageId,plan,planItem,segmentTwo,warehouse,material,unit,balance,"4",billDate);
        // The package, material backing and complete sales partition form one transaction.
        // persistValidAllocations commits only after every segment has its exact ownership.
        } catch(Exception failure){connection.rollback();connection.setAutoCommit(true);throw failure;}
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
        startSegments(connection,fixture);
        return new Allocations(
                segmentOneOrderOne,
                segmentTwoOrderOne,
                segmentTwoOrderTwo);
    }

    private static void insertOrder(
            Connection connection,
            UUID orderId,
            UUID orderItemId,
            UUID client,
            UUID goods,
            UUID unit,
            String billNo) throws Exception {
        insert(connection, """
                INSERT INTO sales_orders(
                    id,bill_no,bill_date,client_id,status
                ) VALUES(?,?,?,?,1)
                """, orderId, billNo, LocalDate.of(2026, 7, 31),
                client);
        insert(connection, """
                INSERT INTO sales_order_items(
                    id,bill_no,bill_date,order_id,goods_id,
                    goods_code_snapshot,goods_name_snapshot,
                    goods_snapshot_source,goods_snapshot_locked_at,
                    unit_id,unit_rate,qty,chain_status
                ) SELECT ?,?,?,?,?,goods.code,goods.name,'MASTER_AT_APPROVAL',now(),
                         ?,1,10,4 FROM goods WHERE goods.id=?
                """, orderItemId, billNo,
                LocalDate.of(2026, 7, 31), orderId, goods, unit,goods);
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
                ) VALUES(?,?,?,?,?,?,?,?,?,1,?,'READY',?,?)
                """, segment, packageId, plan, planItem, number,
                canonicalSegmentCode(segment),
                "client-" + segment,
                goods, unit, new BigDecimal(quantity),
                "c".repeat(64), "segment-" + segment);
    }

    private static void addMaterials(Connection connection,UUID pkg,UUID plan,UUID planItem,UUID segment,
            UUID warehouse,UUID material,UUID unit,UUID balance,String quantity,LocalDate date)throws Exception {
        UUID demand=UUID.randomUUID(),reservation=UUID.randomUUID(),draw=UUID.randomUUID(),item=UUID.randomUUID();
        BigDecimal qty=new BigDecimal(quantity);String drawNo=businessIdentifier("SL",date);
        insert(connection,"""
                INSERT INTO production_material_demands(id,package_id,plan_id,warehouse_id,goods_id,unit_id,
                    required_qty,supply_route,status,idempotency_key,execution_segment_id,source_plan_item_id,per_product_qty)
                VALUES(?,?,?,?,?,?,?,'BUY','ALLOCATED',?,?,?,1)
                """,demand,pkg,plan,warehouse,material,unit,qty,"demand-"+demand,segment,planItem);
        insert(connection,"""
                INSERT INTO stock_reservations(id,goods_id,warehouse_id,qty,consumed_qty,released_qty,status,source,
                    source_doc_type,source_doc_id,owner_type,owner_id,purpose,demand_id,supply_type,supply_id,idempotency_key)
                VALUES(?,?,?,?,0,0,0,2,'PRODUCTION_PLANNING_PACKAGE',?,'PRODUCTION_MATERIAL_DEMAND',?,
                    'PRODUCTION_MATERIAL',?,'STOCK_BALANCE',?,?)
                """,reservation,material,warehouse,qty,pkg,demand,demand,balance,"reserve-"+reservation);
        insert(connection,"INSERT INTO stock_documents(id,doc_type,bill_no,bill_date,warehouse_id,status) VALUES(?,'DRAW',?,?,?,0)",draw,drawNo,date,warehouse);
        insert(connection,"""
                INSERT INTO stock_document_items(id,doc_id,bill_type,bill_no,bill_date,line_no,goods_id,unit_id,unit_rate,qty,base_qty,goods_snapshot_source)
                VALUES(?,?,'DRAW',?,?,1,?,?,1,?,?,'MASTER_AT_SAVE')
                """,item,draw,drawNo,date,material,unit,qty,qty);
        insert(connection,"INSERT INTO plan_draw_links(plan_id,draw_id) VALUES(?,?)",plan,draw);
        insert(connection,"""
                INSERT INTO production_planning_package_documents(id,package_id,document_type,document_id,document_no,execution_segment_id)
                VALUES(?,?,'DRAW',?,?,?)
                """,UUID.randomUUID(),pkg,draw,drawNo,segment);
        insert(connection,"""
                INSERT INTO production_planning_package_document_items(id,package_id,demand_id,document_type,document_id,document_item_id)
                VALUES(?,?,?,'DRAW',?,?)
                """,UUID.randomUUID(),pkg,demand,draw,item);
    }

    private static void startSegments(Connection connection,Fixture fixture)throws Exception {
        UUID department;
        try(var statement=connection.prepareStatement("SELECT id FROM departments WHERE code='WS_ZHUSU' AND NOT is_deleted");var rows=statement.executeQuery()){
            assertTrue(rows.next());department=rows.getObject(1,UUID.class);
        }
        UUID employee=UUID.randomUUID(),actor=UUID.randomUUID();
        insert(connection,"""
                INSERT INTO employees(id,code,full_name,id_type,department_id,hire_date,status,employment_type)
                VALUES(?,?,?,'其他',?,DATE '2026-01-01','active','regular')
                """,employee,"E-"+employee,"Allocation workshop owner",department);
        insert(connection,"""
                INSERT INTO users(id,employee_id,login_account,password_hash,must_change_password,is_super_admin,status)
                VALUES(?,?,?,'fixture-password-not-used',false,false,'active')
                """,actor,employee,"V157-"+actor);
        insert(connection,"""
                INSERT INTO user_permission_overrides(user_id,permission_id,effect)
                SELECT ?,id,'grant' FROM permissions WHERE code IN ('production_execution:assign','production_execution:start','production_daily_report:create','production_daily_report:approve')
                """,actor);
        assertQuantity(connection,"""
                SELECT COUNT(*) FROM user_permission_overrides grant_row JOIN permissions permission ON permission.id=grant_row.permission_id
                WHERE grant_row.user_id=? AND grant_row.effect='grant' AND permission.code='production_execution:start'
                """,actor,"1");
        for(UUID segment:List.of(fixture.segmentOne(),fixture.segmentTwo())){
            UUID draw,item,demand,reservation;BigDecimal qty;
            try(var statement=connection.prepareStatement("""
                    SELECT link.document_id,link.document_item_id,demand.id,reservation.id,demand.required_qty
                    FROM production_material_demands demand JOIN production_planning_package_document_items link ON link.demand_id=demand.id
                    JOIN stock_reservations reservation ON reservation.demand_id=demand.id
                    WHERE demand.execution_segment_id=? AND link.document_type='DRAW'
                    """)){
                statement.setObject(1,segment);try(var rows=statement.executeQuery()){
                    assertTrue(rows.next());draw=rows.getObject(1,UUID.class);item=rows.getObject(2,UUID.class);demand=rows.getObject(3,UUID.class);
                    reservation=rows.getObject(4,UUID.class);qty=rows.getBigDecimal(5);assertTrue(!rows.next());
                }
            }
            update(connection,"UPDATE stock_documents SET status=1 WHERE id=?",draw);
            UUID event=com.uten.imp.support.ProductionMaterialMovementTestSupport.beginEvent(connection,draw,"ISSUE","issue-"+segment);
            try {
                update(connection,"UPDATE stock_reservations SET consumed_qty=consumed_qty+? WHERE id=?",qty,reservation);
                update(connection,"""
                        UPDATE stock_balances balance SET qty=balance.qty-?
                        FROM production_material_demands demand WHERE demand.id=? AND balance.warehouse_id=demand.warehouse_id
                            AND balance.goods_id=demand.goods_id AND balance.color_id IS NOT DISTINCT FROM demand.color_id
                        """,qty,demand);
                insert(connection,"""
                        INSERT INTO production_material_stock_postings(id,event_id,stock_document_item_id,demand_id,reservation_id,posting_type,qty_base)
                        VALUES(?,?,?,?,?,'ISSUE',?)
                        """,UUID.randomUUID(),event,item,demand,reservation,qty);
                com.uten.imp.support.ProductionMaterialMovementTestSupport.bindAndCommit(connection,event,item);
            }catch(Exception failure){com.uten.imp.support.ProductionMaterialMovementTestSupport.abort(connection);throw failure;}
            connection.setAutoCommit(false);
            try {
                long beforeAssignment=segmentVersion(connection,segment);
                update(connection,"""
                        UPDATE production_execution_segments SET workshop_department_id=?,responsible_employee_id=?,
                            plan_begin_date=DATE '2026-07-31',plan_end_date=DATE '2026-08-02' WHERE id=? AND lock_version=?
                        """,department,employee,segment,beforeAssignment);
                long beforeStart=segmentVersion(connection,segment);
                assertEquals(beforeAssignment+1,beforeStart);
                insert(connection,"""
                        INSERT INTO production_execution_segment_events(id,execution_segment_id,action,idempotency_key,request_hash,expected_version,resulting_version,created_by)
                        VALUES(?,?,'ASSIGNMENT',?,?,?,?,?)
                        """,UUID.randomUUID(),segment,"assignment-"+segment,"e".repeat(64),beforeAssignment,beforeStart,actor);
                try(var statement=connection.prepareStatement("""
                        SELECT set_config('app.production_execution_start_segment_id',?,true),
                            set_config('app.production_execution_start_expected_version',?,true)
                        """)){statement.setString(1,segment.toString());statement.setString(2,Long.toString(beforeStart));statement.executeQuery().close();}
                update(connection,"UPDATE production_execution_segments SET status='IN_PROGRESS' WHERE id=? AND lock_version=?",segment,beforeStart);
                assertEquals(beforeStart+1,segmentVersion(connection,segment));
                insert(connection,"""
                        INSERT INTO production_execution_segment_events(id,execution_segment_id,action,idempotency_key,request_hash,expected_version,resulting_version,created_by)
                        VALUES(?,?,'START',?,?,?,?,?)
                        """,UUID.randomUUID(),segment,"start-"+segment,"d".repeat(64),beforeStart,beforeStart+1,actor);
                connection.commit();
            }catch(Exception failure){connection.rollback();throw failure;}
            finally{connection.setAutoCommit(true);}
            assertQuantity(connection,"""
                    SELECT COUNT(*) FROM production_execution_segment_events event JOIN production_execution_segments segment ON segment.id=event.execution_segment_id
                    WHERE segment.id=? AND event.action='START' AND event.resulting_version=segment.lock_version
                        AND event.resulting_version=event.expected_version+1 AND segment.status='IN_PROGRESS'
                    """,segment,"1");
        }
    }

    private static long segmentVersion(Connection connection,UUID segment)throws Exception{
        try(var statement=connection.prepareStatement("SELECT lock_version FROM production_execution_segments WHERE id=?")){
            statement.setObject(1,segment);try(var rows=statement.executeQuery()){assertTrue(rows.next());return rows.getLong(1);}
        }
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
        LocalDate billDate = LocalDate.of(2026, 7, 31);
        String reportNo = businessIdentifier("SR", billDate);
        insert(connection, """
                INSERT INTO production_daily_reports(
                    id,bill_no,bill_date,status
                ) VALUES(?,?,?,?)
                """, report, reportNo, billDate, status);
        insert(connection, """
                INSERT INTO production_daily_report_items(
                    id,bill_no,bill_date,report_id,line_no,
                    goods_id,unit_id,unit_rate,qty,
                    sales_order_item_id,plan_item_id,
                    execution_segment_id,
                    execution_segment_sales_allocation_id
                ) VALUES(?,?,?,?,1,?,?,1,?,?,?,?,?)
                """, UUID.randomUUID(), reportNo,
                billDate, report,
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
        LocalDate billDate = LocalDate.of(2026, 7, 31);
        String documentNo = businessIdentifier("CR", billDate);
        insert(connection, """
                INSERT INTO stock_documents(
                    id,doc_type,bill_no,bill_date,warehouse_id,status
                ) VALUES(?,'FINISHED_IN',?,?,?,1)
                """, document, documentNo, billDate, fixture.warehouse());
        insert(connection, """
                INSERT INTO stock_document_items(
                    id,doc_id,bill_type,bill_no,bill_date,line_no,
                    goods_id,unit_id,unit_rate,qty,base_qty,
                    upstream_item_id,execution_segment_id,
                    execution_segment_sales_allocation_id,
                    goods_snapshot_source
                ) VALUES(?,?,'FINISHED_IN',?,?,1,?,?,1,?,?,?, ?,?,'MASTER_AT_SAVE')
                """, UUID.randomUUID(), document, documentNo,
                billDate,
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
