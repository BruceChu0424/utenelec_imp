package com.uten.imp.features.production.execution;

import com.uten.imp.application.port.SubcontractDocumentReadAccessPort;
import com.uten.imp.common.web.ApiException;
import com.uten.imp.features.stock.allocation.ProductionMaterialSettlementService;
import com.uten.imp.features.stock.allocation.ProductionMaterialTaskAccessPolicy;
import com.uten.imp.features.stock.valuation.ProductionInventoryValueService;
import com.uten.imp.security.TxSessionVars;
import com.uten.imp.features.production.ProductionDocumentAccessPolicy;
import com.uten.imp.features.purchase.PurchaseDocumentAccessPolicy;
import com.uten.imp.security.DocumentAccessPolicy.NativeReadScope;
import com.uten.imp.security.SecurityContextCurrentUser;
import jakarta.persistence.EntityManager;
import org.hibernate.SessionFactory;
import org.hibernate.cfg.Configuration;
import org.junit.jupiter.api.AfterAll;
import org.junit.jupiter.api.AfterEach;
import org.junit.jupiter.api.BeforeAll;
import org.junit.jupiter.api.BeforeEach;
import org.junit.jupiter.api.Test;
import org.junit.jupiter.api.condition.EnabledIfEnvironmentVariable;
import org.springframework.jdbc.core.JdbcTemplate;
import org.springframework.jdbc.datasource.DriverManagerDataSource;
import org.testcontainers.containers.PostgreSQLContainer;
import java.time.LocalDate;
import java.util.Optional;
import java.util.List;
import java.util.Set;
import java.util.UUID;
import java.nio.file.Files;
import java.nio.file.Path;
import static org.assertj.core.api.Assertions.assertThat;
import static org.assertj.core.api.Assertions.assertThatThrownBy;
import static org.mockito.ArgumentMatchers.anyString;
import static org.mockito.Mockito.mock;
import static org.mockito.Mockito.when;

/** Real Hibernate/PostgreSQL query execution against projection fixtures.
 * Migration tests separately verify the full production view definitions. */
@EnabledIfEnvironmentVariable(named = "UTEN_RUN_DB_TESTS", matches = "(?i)true")
class ProductionExecutionWorkbenchQueryPostgresTest {
    private static final PostgreSQLContainer<?> POSTGRES = new PostgreSQLContainer<>("postgres:16-alpine");
    private static final UUID EMPLOYEE = UUID.randomUUID();
    private static final UUID WORKSHOP = UUID.randomUUID();
    private static final UUID OTHER_WORKSHOP = UUID.randomUUID();
    private static final UUID PLAN = UUID.randomUUID();
    private static JdbcTemplate jdbc;
    private static SessionFactory factory;
    private EntityManager em;
    private SecurityContextCurrentUser currentUser;
    private ProductionDocumentAccessPolicy access;
    private ProductionExecutionWorkbenchService service;

    @BeforeAll
    static void startPostgres() throws Exception {
        POSTGRES.start();
        jdbc = new JdbcTemplate(new DriverManagerDataSource(
                POSTGRES.getJdbcUrl(), POSTGRES.getUsername(), POSTGRES.getPassword()));
        jdbc.execute("""
                CREATE TABLE production_execution_segments(id uuid PRIMARY KEY, status text, auto_promote_when_ready boolean DEFAULT TRUE, is_deleted boolean DEFAULT FALSE,source_segment_id uuid,
                    product_goods_id uuid,plan_id uuid,package_id uuid,workshop_department_id uuid,responsible_employee_id uuid,
                    continuous_supply boolean DEFAULT FALSE, start_route text DEFAULT 'FULL_KIT', route_confirmed_at timestamptz);
                CREATE TABLE production_execution_segment_splits(source_segment_id uuid);
                CREATE FUNCTION fn_split_batch_empty_issued(uuid) RETURNS boolean LANGUAGE sql AS 'SELECT FALSE';
                CREATE FUNCTION fn_can_split_execution_batch(uuid) RETURNS boolean LANGUAGE sql AS 'SELECT FALSE';
                CREATE FUNCTION fn_production_material_usage_source_segments(uuid) RETURNS TABLE(segment_id uuid) LANGUAGE sql AS 'SELECT NULL::uuid WHERE FALSE';
                CREATE FUNCTION fn_execution_start_material_ready(uuid) RETURNS boolean LANGUAGE sql AS 'SELECT FALSE';
                CREATE FUNCTION fn_execution_material_custody_valid(uuid) RETURNS boolean LANGUAGE sql AS 'SELECT TRUE';
                CREATE FUNCTION fn_can_change_execution_route(uuid) RETURNS boolean LANGUAGE sql AS 'SELECT FALSE';
                CREATE FUNCTION fn_execution_segment_material_summary(uuid) RETURNS TABLE(kind_count integer, issued_count integer,
                    partial_issued_count integer, awaiting_warehouse_count integer, drawable_count integer,
                    line_side_pending_count integer, preparing_count integer, short_count integer, short_make_count integer,
                    supported_output_qty numeric, prepared_output_qty numeric)
                    LANGUAGE sql AS 'SELECT 2, 1, 0, 0, 1, 0, 0, 0, 0, 0::numeric, 10::numeric';
                CREATE FUNCTION fn_demand_direct_supply_eligible(uuid) RETURNS boolean LANGUAGE sql AS 'SELECT FALSE';
                CREATE TABLE warehouses(id uuid PRIMARY KEY, is_line_side boolean DEFAULT FALSE);
                CREATE TABLE departments(id uuid PRIMARY KEY, parent_id uuid, manager_id uuid, is_deleted boolean DEFAULT FALSE);
                CREATE TABLE employees(id uuid PRIMARY KEY, department_id uuid, status text DEFAULT 'active', is_deleted boolean DEFAULT FALSE);
                CREATE TABLE employee_secondary_departments(employee_id uuid, department_id uuid);
                CREATE TABLE production_plans(id uuid PRIMARY KEY, bill_no text, status integer, maker_id uuid,
                    material_analysis_id uuid, is_deleted boolean DEFAULT FALSE,is_closed boolean DEFAULT FALSE,is_canceled boolean DEFAULT FALSE,is_stopped boolean DEFAULT FALSE);
                CREATE TABLE production_planning_packages(id uuid PRIMARY KEY,status text DEFAULT 'CONFIRMED',is_deleted boolean DEFAULT FALSE, cancel_idempotency_key text, created_at timestamp with time zone DEFAULT now(), created_by uuid, deleted_at timestamp with time zone, execution_model_version smallint DEFAULT 0, idempotency_key text, lifecycle_reason text, lock_version bigint DEFAULT 0, plan_id uuid, preview_fingerprint text, purchase_request_id uuid, request_hash text, reverse_idempotency_key text, updated_at timestamp with time zone DEFAULT now(), updated_by uuid, warehouse_id uuid);
                CREATE TABLE goods(id uuid, code text, name text, default_purchase_price_color_id uuid, default_purchase_price_currency_id uuid, default_purchase_price_supplier_id uuid, default_purchase_price_tax_rate numeric(18,4), default_purchase_price_unit_id uuid, default_subcontract_price_color_id uuid, default_subcontract_price_currency_id uuid, default_subcontract_price_supplier_id uuid, default_subcontract_price_tax_rate numeric(18,4), default_subcontract_price_unit_id uuid);
                CREATE TABLE production_material_analysis_items(analysis_id uuid, goods_id uuid,
                    sales_order_item_id uuid, is_deleted boolean, source_ref text);
                CREATE TABLE sales_order_items(id uuid, order_id uuid, is_deleted boolean);
                CREATE TABLE sales_orders(id uuid, client_id uuid, bill_no text, is_deleted boolean);
                CREATE TABLE clients(id uuid, name text);
                CREATE TABLE execution_segment_sales_allocations(execution_segment_id uuid, sales_order_item_id uuid);
                CREATE TABLE v_production_execution_workbench_segments(
                    segment_id uuid PRIMARY KEY, plan_id uuid, root_type text DEFAULT 'PLAN', root_id uuid,
                    plan_no text DEFAULT 'PLAN-001', segment_code text, segment_no integer,
                    sales_order_nos text DEFAULT 'SO-001', workshop_department_id uuid,
                    workshop_name text DEFAULT 'Assembly', responsible_employee_id uuid,
                    responsible_employee_name text DEFAULT 'Worker', product_code text DEFAULT 'P001',
                    product_name text DEFAULT 'Product', product_color_name text, product_unit_name text DEFAULT 'piece',
                    planned_qty numeric DEFAULT 10, reported_qty numeric DEFAULT 0, remaining_qty numeric DEFAULT 10,
                    fqc_pending_qty numeric DEFAULT 0, fqc_passed_qty numeric DEFAULT 0, fqc_failed_qty numeric DEFAULT 0,
                    finished_inbound_pending_qty numeric DEFAULT 0, inbound_qty numeric DEFAULT 0,
                    segment_status text, material_status text DEFAULT 'KIT_SHORT', preparation_status text,
                    warehouse_ready boolean DEFAULT FALSE, issued boolean DEFAULT FALSE, reportable boolean DEFAULT FALSE,
                    report_source_count integer DEFAULT 1, blocked_reason text DEFAULT 'Waiting for materials',
                    plan_begin_date date DEFAULT '2026-09-05', plan_end_date date DEFAULT '2026-09-06', lock_version bigint DEFAULT 1, zero_material boolean DEFAULT FALSE,
                    product_goods_id uuid);
                CREATE TABLE v_production_execution_workbench_roots(
                    root_type text DEFAULT 'PLAN', root_id uuid, owner_employee_id uuid,
                    root_label text DEFAULT 'PLAN-001', status text DEFAULT 'WAITING',
                    sales_order_preview text, sales_order_count integer DEFAULT 1, sales_order_has_more boolean DEFAULT FALSE,
                    work_order_preview text, work_order_count integer DEFAULT 4, work_order_has_more boolean DEFAULT FALSE,
                    workshop_preview text, workshop_count integer DEFAULT 1, workshop_has_more boolean DEFAULT FALSE,
                    product_code_preview text, product_name_preview text, product_color_preview text,
                    product_count integer DEFAULT 1, product_has_more boolean DEFAULT FALSE,
                    quantity_summary text DEFAULT '40 piece', mixed_units boolean DEFAULT FALSE,
                    execution_unit_count integer DEFAULT 4, execution_unit_has_more boolean DEFAULT FALSE,
                    plan_count integer DEFAULT 1, segment_count integer DEFAULT 4,
                    waiting_count integer DEFAULT 1, ready_count integer DEFAULT 1, dispatched_count integer DEFAULT 1,
                    in_progress_count integer DEFAULT 1, completed_count integer DEFAULT 0,
                    material_ready_count integer DEFAULT 2, warehouse_ready_count integer DEFAULT 2,
                    issued_count integer DEFAULT 2, reportable_count integer DEFAULT 2,
                    fqc_pending_count integer DEFAULT 0, finished_inbound_pending_count integer DEFAULT 0,
                    earliest_begin_date date DEFAULT '2026-09-05', latest_end_date date DEFAULT '2026-09-06', owner_employee_name text, analyzed_at timestamp,
                    root_planned_qty numeric DEFAULT 0, root_inbound_qty numeric DEFAULT 0, root_progress_ratio numeric DEFAULT 0);
                """);
        jdbc.execute("""
                CREATE TABLE production_material_demands(id uuid PRIMARY KEY, plan_id uuid,
                    execution_segment_id uuid, goods_id uuid, color_id uuid, required_qty numeric,
                    status text DEFAULT 'ACTIVE', is_deleted boolean DEFAULT FALSE,split_root_demand_id uuid, consumption_snapshot jsonb);
                CREATE TABLE production_material_stock_postings(id uuid PRIMARY KEY, demand_id uuid,
                    posting_type text, qty_base numeric, stock_document_item_id uuid, recorded_tx_id xid8);
                CREATE TABLE production_planning_package_documents(document_id uuid, document_type text, execution_segment_id uuid);
                CREATE TABLE stock_documents(id uuid, doc_type text, status integer, warehouse_id uuid, is_deleted boolean DEFAULT FALSE);
                CREATE TABLE stock_document_items(id uuid, doc_id uuid,qty numeric DEFAULT 1,issued_qty numeric DEFAULT 0,is_deleted boolean DEFAULT false);
                CREATE TABLE production_execution_segment_events(action text, draw_document_ids uuid[],draw_item_quantities jsonb,receiving_confirmation_id uuid, counter_event_id uuid, receiving_direction smallint,
                    execution_segment_id uuid, created_by uuid, created_at timestamp with time zone DEFAULT now());
                CREATE TABLE production_material_return_requests(id uuid,execution_segment_id uuid, created_at timestamp with time zone DEFAULT now(), created_by uuid, idempotency_key character varying(128), plan_id uuid, reason text, request_hash character(64), source_department_id uuid, warehouse_id uuid);
                CREATE TABLE v_workshop_direct_supply_lots(to_demand_id uuid,received_qty numeric, available_qty numeric, color_id uuid, created_at timestamp with time zone, goods_id uuid, id uuid, line_side_warehouse_id uuid, producing_segment_id uuid, to_execution_segment_id uuid);
                CREATE FUNCTION fn_execution_material_return_allowed(uuid) RETURNS boolean LANGUAGE sql AS 'SELECT FALSE';
                CREATE TABLE production_material_return_request_items(issue_posting_id uuid,request_id uuid,qty_base numeric, direct_transfer_item_id uuid);
                CREATE TABLE production_material_return_request_cancellations(request_id uuid);
                CREATE TABLE production_material_settlement_events(id uuid PRIMARY KEY, event_type text);
                CREATE TABLE production_material_settlement_postings(id uuid PRIMARY KEY, demand_id uuid,
                    event_id uuid, settlement_type text, qty_base numeric);
                """);
        String requestMigration = Files.readString(Path.of("src/main/resources/db/migration/V559__production_workshop_draw_request.sql"));
        int functionStart = requestMigration.indexOf("CREATE OR REPLACE FUNCTION fn_production_draw_requested(");
        jdbc.execute(requestMigration.substring(functionStart, requestMigration.indexOf("$$;", functionStart) + 3));
        String quantitiesMigration = Files.readString(Path.of("src/main/resources/db/migration/V564__production_draw_requested_quantities.sql"));
        jdbc.execute(quantitiesMigration.substring(quantitiesMigration.indexOf("CREATE FUNCTION fn_production_draw_item_requested_qty("),
                quantitiesMigration.indexOf("CREATE FUNCTION fn_guard_production_draw_quantities(")));
        String receiving=Files.readString(Path.of("src/main/resources/db/migration/V618__production_material_return_receiving_warehouse.sql"));
        int effective=receiving.indexOf("CREATE FUNCTION fn_production_draw_item_effective_qty(");
        jdbc.execute(receiving.substring(effective,receiving.indexOf("$$;",effective)+3));
        String returnMigration = Files.readString(Path.of("src/main/resources/db/migration/V560__production_material_return_requests.sql"));
        int pendingStart = returnMigration.indexOf("CREATE FUNCTION fn_material_issue_pending_return(");
        jdbc.execute(returnMigration.substring(pendingStart,returnMigration.indexOf("$$;",pendingStart)+3));
        // Execute the formal authoritative clearance view, not a test copy of its arithmetic.
        String migration = Files.readString(Path.of("src/main/resources/db/migration/V152__production_material_issue_return_ledger.sql"));
        int start = migration.lastIndexOf("CREATE OR REPLACE VIEW v_production_material_clearance AS");
        assertThat(start).isGreaterThanOrEqualTo(0);
        jdbc.execute(migration.substring(start, migration.indexOf(';', start) + 1));
        jdbc.update("INSERT INTO departments(id) VALUES (?), (?)", WORKSHOP, OTHER_WORKSHOP);
        jdbc.update("INSERT INTO employees(id, department_id) VALUES (?, ?)", EMPLOYEE, WORKSHOP);
        jdbc.update("INSERT INTO production_plans(id, bill_no, status, maker_id) VALUES (?, 'PLAN-001', 1, ?)", PLAN, EMPLOYEE);
        jdbc.update("INSERT INTO production_planning_packages(id) VALUES (?)",PLAN);
        jdbc.update("INSERT INTO v_production_execution_workbench_roots(root_id, owner_employee_id) VALUES (?, ?)", PLAN, EMPLOYEE);
        insertSegment(1, "WAITING", "PREPARING", false, WORKSHOP);
        insertSegment(2, "READY", "PREPARING", false, WORKSHOP);
        insertSegment(3, "DISPATCHED", "READY_TO_REPORT", true, WORKSHOP);
        insertSegment(4, "IN_PROGRESS", "READY_TO_REPORT", true, WORKSHOP);
        insertSegment(5, "COMPLETED", "COMPLETE", false, WORKSHOP);
        insertSegment(6, "READY", "PREPARING", false, OTHER_WORKSHOP);
        insertSegment(7, "CANCELLED", "COMPLETE", false, WORKSHOP);
        insertSegment(8, "REVERSED", "COMPLETE", false, WORKSHOP);
        for (int number : new int[]{2, 3, 4, 6}) {
            UUID demand = new UUID(1, number);
            jdbc.update("INSERT INTO production_material_demands(id,plan_id,execution_segment_id,goods_id,required_qty) VALUES (?,?,?,?,10)",
                    demand, PLAN, new UUID(0, number), UUID.randomUUID());
            jdbc.update("INSERT INTO production_material_stock_postings(id,demand_id,posting_type,qty_base) VALUES (?,?, 'ISSUE',?)",
                    UUID.randomUUID(), demand, number == 2 ? 4 : 10);
        }
        UUID settlementEvent = UUID.randomUUID();
        jdbc.update("INSERT INTO production_material_settlement_events VALUES (?,'POST')", settlementEvent);
        jdbc.update("INSERT INTO production_material_settlement_postings VALUES (?,?,?,'CONSUMED',10)",
                UUID.randomUUID(), new UUID(1, 3), settlementEvent);
        jdbc.update("INSERT INTO production_material_stock_postings(id,demand_id,posting_type,qty_base) VALUES (?,?,'ISSUE_REVERSE',10)",
                UUID.randomUUID(), new UUID(1, 4));
        factory = new Configuration()
                .setProperty("hibernate.connection.driver_class", "org.postgresql.Driver")
                .setProperty("hibernate.connection.url", POSTGRES.getJdbcUrl())
                .setProperty("hibernate.connection.username", POSTGRES.getUsername())
                .setProperty("hibernate.connection.password", POSTGRES.getPassword())
                .setProperty("hibernate.hbm2ddl.auto", "none").buildSessionFactory();
    }
    private static void insertSegment(int number, String status, String preparation, boolean reportable, UUID workshop) {
        jdbc.update("INSERT INTO production_execution_segments(id,status,plan_id,package_id,workshop_department_id,responsible_employee_id) VALUES (?, ?,?,?,?,?)", new UUID(0, number), status,PLAN,PLAN,workshop,EMPLOYEE);
        jdbc.update("""
                INSERT INTO v_production_execution_workbench_segments(
                    segment_id, plan_id, root_id, segment_code, segment_no, workshop_department_id,
                    segment_status, preparation_status, reportable, issued) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                """, new UUID(0, number), PLAN, PLAN, "WORK-" + number, number, workshop, status, preparation, reportable, reportable);
    }
    @BeforeEach
    void createService() {
        em = factory.createEntityManager();
        access = mock(ProductionDocumentAccessPolicy.class);
        when(access.nativeReadScope(anyString(), anyString())).thenAnswer(invocation ->
                new NativeReadScope(invocation.getArgument(0) + " IN (:" + invocation.getArgument(1) + ")",
                        invocation.getArgument(1), Set.of(EMPLOYEE)));
        when(access.hasAuthority(anyString())).thenAnswer(invocation -> Set.of(
                "production_plan:view", "production_execution:view", "production_daily_report:view",
                "production_daily_report:create").contains(invocation.getArgument(0)));
        currentUser = mock(SecurityContextCurrentUser.class);
        when(currentUser.employeeId()).thenReturn(Optional.of(EMPLOYEE));
        when(currentUser.get()).thenReturn(Optional.empty());
        var membership = mock(com.uten.imp.features.production.ProductionWorkshopMembership.class);
        when(membership.isActiveOperator()).thenReturn(true);
        service = new ProductionExecutionWorkbenchService(em, access,
                mock(PurchaseDocumentAccessPolicy.class), mock(SubcontractDocumentReadAccessPort.class), currentUser,
                new ProductionMaterialSettlementService(em, mock(TxSessionVars.class),
                        mock(ProductionMaterialTaskAccessPolicy.class), mock(ProductionInventoryValueService.class)), membership);
        org.springframework.test.util.ReflectionTestUtils.setField(service,"draftPreparationAccess",
                mock(com.uten.imp.features.production.SubcontractDraftPreparationAccessPolicy.class));
    }

    @Test
    void cancelledReversedAndOtherTasksNeverProvideTheCurrentTasksRoute() {
        UUID task = new UUID(0, 1), goods = UUID.randomUUID();
        List<UUID> history = List.of(UUID.randomUUID(), UUID.randomUUID(), UUID.randomUUID());
        when(access.hasAuthority("production_execution:start")).thenReturn(true);
        jdbc.update("UPDATE production_execution_segments SET product_goods_id=?,start_route=NULL WHERE id=?", goods, task);
        jdbc.update("UPDATE v_production_execution_workbench_segments SET product_goods_id=? WHERE segment_id=?", goods, task);
        try {
            var original = service.workshopTasks(1, 50, null, "PREPARING", null, null, null)
                    .getItems().stream().filter(row -> row.segmentId().equals(task)).findFirst().orElseThrow();
            assertThat(original.startRoute()).isNull();
            assertThat(original.canConfirmRoute()).isTrue();
            String[] statuses = {"CANCELLED", "REVERSED", "WAITING"};
            String[] routes = {"BATCH", "CONTINUOUS", "BATCH"};
            // 路线记忆(V602 恢复，2026-09-20)只是未确认行的预填展示：终态(已取消/已红冲)
            // 任务不算历史；另一车间同产品的有效确认才成为记忆。任务自己的路线事实
            // (startRoute/canConfirmRoute)在任何历史下都不变。
            String[] expectedMemory = {null, null, "BATCH"};
            for (int index = 0; index < history.size(); index++) {
                // Actual PostgreSQL history includes terminal tasks and another
                // workshop's current task, all sharing this exact product UUID.
                jdbc.update("""
                        INSERT INTO production_execution_segments(id,status,plan_id,package_id,workshop_department_id,
                            product_goods_id,start_route,route_confirmed_at)
                        VALUES (?,?,?,?,?,?,?,now()+interval '1 day')
                        """, history.get(index), statuses[index], UUID.randomUUID(), UUID.randomUUID(),
                        OTHER_WORKSHOP, goods, routes[index]);
                var current = service.workshopTasks(1, 50, null, "PREPARING", null, null, null)
                        .getItems().stream().filter(row -> row.segmentId().equals(task)).findFirst().orElseThrow();
                assertThat(current.startRoute()).as("route history from %s must not change this task", statuses[index]).isNull();
                assertThat(current.canConfirmRoute()).isTrue();
                assertThat(current.suggestedStartRoute())
                        .as("only a live confirmed task of the same product feeds the prefill memory (%s)", statuses[index])
                        .isEqualTo(expectedMemory[index]);
            }
            jdbc.update("UPDATE production_execution_segments SET start_route='FULL_KIT' WHERE id=?", task);
            var confirmed = service.workshopTasks(1, 50, null, "PREPARING", null, null, null)
                    .getItems().stream().filter(row -> row.segmentId().equals(task)).findFirst().orElseThrow();
            assertThat(confirmed.startRoute()).isEqualTo("FULL_KIT");
            assertThat(confirmed.canConfirmRoute()).isFalse();
        } finally {
            history.forEach(id -> jdbc.update("DELETE FROM production_execution_segments WHERE id=?", id));
            jdbc.update("UPDATE production_execution_segments SET product_goods_id=NULL,start_route='FULL_KIT' WHERE id=?", task);
            jdbc.update("UPDATE v_production_execution_workbench_segments SET product_goods_id=NULL WHERE segment_id=?", task);
        }
    }

    /**
     * ADR-096 路线记忆两档：本产品有有效确认记忆时按产品预填(PRODUCT)；没有时退到
     * 当前登录人最近一次路线确认(OPERATOR，V629 部分索引点查)；两者都没有则不预填。
     * 记忆只是预填，任务自己的 startRoute/canConfirmRoute 不受影响。
     */
    @Test
    void operatorRouteMemoryPrefillsOnlyWhenProductHasNoHistory() {
        UUID task = new UUID(0, 1), goods = UUID.randomUUID(), userId = UUID.randomUUID();
        UUID operatorHistory = UUID.randomUUID(), productHistory = UUID.randomUUID();
        com.uten.imp.security.AuthUser me = mock(com.uten.imp.security.AuthUser.class);
        when(me.getId()).thenReturn(userId);
        when(currentUser.get()).thenReturn(Optional.of(me));
        when(access.hasAuthority("production_execution:start")).thenReturn(true);
        jdbc.update("UPDATE production_execution_segments SET product_goods_id=?,start_route=NULL WHERE id=?", goods, task);
        jdbc.update("UPDATE v_production_execution_workbench_segments SET product_goods_id=? WHERE segment_id=?", goods, task);
        try {
            var none = row(task);
            assertThat(none.suggestedStartRoute()).isNull();
            assertThat(none.suggestedStartRouteSource()).isNull();
            // 本人在另一产品的另一工单上确认过持续生产 → 操作者记忆。
            jdbc.update("""
                    INSERT INTO production_execution_segments(id,status,plan_id,package_id,workshop_department_id,
                        product_goods_id,start_route,route_confirmed_at)
                    VALUES (?,'IN_PROGRESS',?,?,?,?,'CONTINUOUS',now())
                    """, operatorHistory, UUID.randomUUID(), UUID.randomUUID(), OTHER_WORKSHOP, UUID.randomUUID());
            jdbc.update("INSERT INTO production_execution_segment_events(action,execution_segment_id,created_by,created_at) VALUES ('ROUTE_CONFIRMED',?,?,now()-interval '1 hour')",
                    operatorHistory, userId);
            // 别人的确认不算我的记忆(更新的事件但 created_by 不同)。
            jdbc.update("INSERT INTO production_execution_segment_events(action,execution_segment_id,created_by,created_at) VALUES ('ROUTE_CONFIRMED',?,?,now())",
                    operatorHistory, UUID.randomUUID());
            var operator = row(task);
            assertThat(operator.startRoute()).isNull();
            assertThat(operator.canConfirmRoute()).isTrue();
            assertThat(operator.suggestedStartRoute()).isEqualTo("CONTINUOUS");
            assertThat(operator.suggestedStartRouteSource()).isEqualTo("OPERATOR");
            // 同产品出现有效确认后，产品记忆优先于操作者记忆。
            jdbc.update("""
                    INSERT INTO production_execution_segments(id,status,plan_id,package_id,workshop_department_id,
                        product_goods_id,start_route,route_confirmed_at)
                    VALUES (?,'WAITING',?,?,?,?,'BATCH',now()+interval '1 day')
                    """, productHistory, UUID.randomUUID(), UUID.randomUUID(), OTHER_WORKSHOP, goods);
            var product = row(task);
            assertThat(product.suggestedStartRoute()).isEqualTo("BATCH");
            assertThat(product.suggestedStartRouteSource()).isEqualTo("PRODUCT");
            // 未登录身份(定时任务/系统调用)没有操作者记忆，产品记忆照常。
            when(currentUser.get()).thenReturn(Optional.empty());
            assertThat(row(task).suggestedStartRouteSource()).isEqualTo("PRODUCT");
            jdbc.update("DELETE FROM production_execution_segments WHERE id=?", productHistory);
            assertThat(row(task).suggestedStartRoute()).isNull();
        } finally {
            when(currentUser.get()).thenReturn(Optional.empty());
            jdbc.update("DELETE FROM production_execution_segment_events WHERE execution_segment_id=?", operatorHistory);
            jdbc.update("DELETE FROM production_execution_segments WHERE id IN (?,?)", operatorHistory, productHistory);
            jdbc.update("UPDATE production_execution_segments SET product_goods_id=NULL,start_route='FULL_KIT' WHERE id=?", task);
            jdbc.update("UPDATE v_production_execution_workbench_segments SET product_goods_id=NULL WHERE segment_id=?", task);
        }
    }

    private ProductionExecutionWorkbenchSegment row(UUID task) {
        return service.workshopTasks(1, 50, null, "PREPARING", null, null, null)
                .getItems().stream().filter(row -> row.segmentId().equals(task)).findFirst().orElseThrow();
    }

    @Test
    void materialEntryFlagsUseActualLedgerBalancesInOneScopedBatch() {
        factory.getStatistics().setStatisticsEnabled(true);
        factory.getStatistics().clear();
        var page = service.workshopTasks(1, 50, null, null, null, null, null);
        assertThat(page.getItems()).extracting(ProductionExecutionWorkbenchSegment::segmentId)
                .containsExactly(new UUID(0, 1), new UUID(0, 2), new UUID(0, 3), new UUID(0, 4));
        var empty = page.getItems().get(0);
        assertThat(empty.hasMaterialActivity()).isFalse();
        assertThat(empty.hasUnregisteredMaterial()).isFalse();
        var partiallyIssued = page.getItems().get(1);
        assertThat(partiallyIssued.issued()).isFalse();
        assertThat(partiallyIssued.hasMaterialActivity()).isTrue();
        assertThat(partiallyIssued.hasUnregisteredMaterial()).isTrue();
        var consumed = page.getItems().get(2);
        assertThat(consumed.hasMaterialActivity()).isTrue();
        assertThat(consumed.hasUnregisteredMaterial()).isFalse();
        var reversedIssue = page.getItems().get(3);
        assertThat(reversedIssue.hasMaterialActivity()).isTrue();
        assertThat(reversedIssue.hasUnregisteredMaterial()).isFalse();
        assertThat(factory.getStatistics().getPrepareStatementCount()).isEqualTo(3);
    }

    @Test
    void preparationFilterRunsBeforePaginationAndPartialWarehouseRequestStaysSelectable() {
        UUID segment = new UUID(0, 2), firstDraw = UUID.randomUUID(), secondDraw = UUID.randomUUID();
        UUID warehouse=UUID.randomUUID();
        when(access.hasAuthority("production_execution:start")).thenReturn(true);
        jdbc.update("INSERT INTO warehouses(id) VALUES (?)",warehouse);
        jdbc.update("INSERT INTO stock_documents(id,doc_type,status,warehouse_id) VALUES (?,'DRAW',0,?),(?,'DRAW',0,?)", firstDraw,warehouse,secondDraw,warehouse);
        jdbc.update("INSERT INTO stock_document_items(id,doc_id,qty) VALUES (?,?,1),(?,?,1)",UUID.randomUUID(),firstDraw,UUID.randomUUID(),secondDraw);
        jdbc.update("INSERT INTO production_planning_package_documents VALUES (?,'DRAW',?),(?,'DRAW',?)",
                firstDraw, segment, secondDraw, segment);
        jdbc.update("INSERT INTO production_execution_segment_events(action,draw_document_ids) VALUES ('DRAW_REQUEST',ARRAY[CAST(? AS uuid)])", firstDraw);
        try {
            var unrequested = service.workshopTasks(1, 1, null, "PREPARING", null, null, null, "DRAW_NOT_REQUESTED");
            assertThat(unrequested.getTotal()).isEqualTo(1);
            assertThat(unrequested.getItems().getFirst().segmentId()).isEqualTo(segment);
            assertThat(unrequested.getItems().getFirst().drawRequested()).isFalse();
            assertThat(unrequested.getItems().getFirst().canRequestDraw()).isTrue();
            assertThat(service.workshopTasks(1, 1, null, "PREPARING", null, null, null, "DRAW_REQUESTED").getTotal()).isZero();
            jdbc.update("INSERT INTO production_execution_segment_events(action,draw_document_ids) VALUES ('DRAW_REQUEST',ARRAY[CAST(? AS uuid)])", secondDraw);
            var requested = service.workshopTasks(1, 1, null, "PREPARING", null, null, null, "DRAW_REQUESTED");
            assertThat(requested.getTotal()).isEqualTo(1);
            assertThat(requested.getItems().getFirst().drawRequested()).isTrue();
            assertThat(requested.getItems().getFirst().canRequestDraw()).isFalse();
            assertThat(service.workshopTasks(1, 1, null, "PREPARING", null, null, null, "WAITING_MATERIAL").getTotal()).isEqualTo(1);
            assertThat(service.workshopTasks(1, 1, null, "PREPARING", null, null, null, "READY_TO_START").getTotal()).isEqualTo(1);
        } finally {
            jdbc.update("DELETE FROM production_execution_segment_events");
            jdbc.update("DELETE FROM production_planning_package_documents");
            jdbc.update("DELETE FROM stock_document_items");
            jdbc.update("DELETE FROM stock_documents");
            jdbc.update("DELETE FROM warehouses WHERE id=?",warehouse);
        }
    }

    /** V477 读侧放行回归锁：超管在我的车间任务页看到全部车间的活跃段与角标。 */
    @Test
    void superAdminSeesAllWorkshopsOnReadSide() {
        com.uten.imp.security.AuthUser admin = mock(com.uten.imp.security.AuthUser.class);
        when(admin.isSuperAdmin()).thenReturn(true);
        when(currentUser.get()).thenReturn(Optional.of(admin));
        var page = service.workshopTasks(1, 50, null, null, null, null, null);
        // 常规员工口径是 4（OTHER_WORKSHOP 的段被排除）；超管=全部 5 个活跃段。
        assertThat(page.getTotal()).isEqualTo(5);
        assertThat(service.workshopTaskCount()).isEqualTo(5);
    }
    @AfterEach
    void closeEntityManager() {
        if (em != null) em.close();
    }
    @AfterAll
    static void stopPostgres() {
        if (factory != null) factory.close();
        POSTGRES.stop();
    }

    @Test
    void defaultListAndBadgeIncludeWaitingWithTheSameAssignmentAndPaginationScope() {
        var first = service.workshopTasks(1, 2, null, null, null, null, null);
        var last = service.workshopTasks(99, 2, null, null, null, null, null);
        assertThat(first.getTotal()).isEqualTo(4);
        assertThat(first.getItems()).extracting(ProductionExecutionWorkbenchSegment::segmentStatus)
                .containsExactly("WAITING", "READY");
        assertThat(first.getItems()).allMatch(item -> !item.canReport());
        assertThat(last.getPage()).isEqualTo(2);
        assertThat(last.getItems()).extracting(ProductionExecutionWorkbenchSegment::segmentStatus)
                .containsExactly("DISPATCHED", "IN_PROGRESS");
        assertThat(service.workshopTaskCount()).isEqualTo(first.getTotal());
    }
    @Test
    void readyFiltersExecuteWithoutTrueOrderConcatenationAndPreserveReportPermissions() {
        // 2026-09-10：READY_TO_REPORT 参数删除（与 breakdown 第三列口径矛盾且无调用方），
        // 「生产中」= IN_PROGRESS 承担可报工口径。
        var reportable = service.workshopTasks(1, 50, "P001", "IN_PROGRESS", null, null, null);
        assertThat(reportable.getTotal()).isEqualTo(1);
        assertThat(reportable.getItems()).allMatch(item -> item.canReport()
                && "IN_PROGRESS".equals(item.segmentStatus()));
        assertThatThrownBy(() -> service.workshopTasks(1, 50, null, "READY_TO_REPORT", null, null, null))
                .isInstanceOf(ApiException.class);
        var startable = service.workshopTasks(1, 50, "P001", "READY_TO_START", null, null, null);
        assertThat(startable.getTotal()).isEqualTo(1);
        assertThat(startable.getItems()).allMatch(item -> !item.canReport()
                && !item.canBatchReport());
        when(access.hasAuthority("production_daily_report:create")).thenReturn(false);
        var readonly = service.workshopTasks(1, 50, null, "IN_PROGRESS", null, null, null);
        assertThat(readonly.getTotal()).isEqualTo(1);
        assertThat(readonly.getItems()).allMatch(item -> !item.canReport() && !item.canBatchReport());
    }

    /** ADR-066 §1.3：历史任务 = 终态段（完工/取消/红冲）按计划完工日期时间门控。 */
    @Test
    void historySegmentIncludesCancelledAndReversedWithinTheDateGate() {
        var all = service.workshopTasks(1, 50, null, "COMPLETED", null, null, null);
        assertThat(all.getTotal()).isEqualTo(3);
        assertThat(all.getItems()).extracting(ProductionExecutionWorkbenchSegment::segmentStatus)
                .containsExactlyInAnyOrder("COMPLETED", "CANCELLED", "REVERSED");
        var gated = service.workshopTasks(1, 50, null, "COMPLETED", null,
                LocalDate.parse("2026-09-06"), LocalDate.parse("2026-09-06"));
        assertThat(gated.getTotal()).isEqualTo(3);
        var outside = service.workshopTasks(1, 50, null, "COMPLETED", null,
                LocalDate.parse("2026-09-07"), null);
        assertThat(outside.getTotal()).isZero();
        var upperOnly = service.workshopTasks(1, 50, null, "COMPLETED", null,
                null, LocalDate.parse("2026-09-05"));
        assertThat(upperOnly.getTotal()).isZero();
        // 活动段忽略日期参数（徽章/列表全量口径不变）。
        assertThat(service.workshopTasks(1, 50, null, "PREPARING", null,
                LocalDate.parse("2030-01-01"), null).getTotal()).isEqualTo(3);
    }
    @Test
    void preparingAndInProgressFiltersExecuteWithAndWithoutKeyword() {
        assertThat(service.workshopTasks(1, 50, null, "PREPARING", null, null, null).getTotal()).isEqualTo(3);
        assertThat(service.workshopTasks(1, 50, "Assembly", "IN_PROGRESS", null, null, null).getTotal()).isEqualTo(1);
        assertThat(service.workshopTasks(1, 50, "missing", null, null, null, null).getTotal()).isZero();
    }
    @Test
    void overviewSeparatesOwnerScopeFromAndAndLoadsRootWorkOrders() {
        assertThat(service.list(1, 50, "P001", WORKSHOP, true, null, null).getTotal()).isEqualTo(1);
        assertThat(service.list(1, 50, null, WORKSHOP, false, null, null).getTotal()).isEqualTo(1);
        assertThat(service.workOrders("PLAN", PLAN, 1, 2).getItems()).hasSize(2);
    }
    @Test
    void relatedPlansHaveStableColumnNamesWhenOnlyProductionPlanViewIsAuthorized() {
        var documents = service.relatedDocuments("PLAN", PLAN, 99, 2);
        assertThat(documents.getPage()).isEqualTo(1);
        assertThat(documents.getTotal()).isEqualTo(1);
        assertThat(documents.getItems()).singleElement().satisfies(document -> {
            assertThat(document.documentType()).isEqualTo("PRODUCTION_PLAN");
            assertThat(document.documentId()).isEqualTo(PLAN);
        });
    }
}
