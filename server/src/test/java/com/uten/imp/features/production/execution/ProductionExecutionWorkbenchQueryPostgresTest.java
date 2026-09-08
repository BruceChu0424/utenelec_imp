package com.uten.imp.features.production.execution;

import com.uten.imp.application.port.SubcontractDocumentReadAccessPort;
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
import java.util.Optional;
import java.util.Set;
import java.util.UUID;
import static org.assertj.core.api.Assertions.assertThat;
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
    static void startPostgres() {
        POSTGRES.start();
        jdbc = new JdbcTemplate(new DriverManagerDataSource(
                POSTGRES.getJdbcUrl(), POSTGRES.getUsername(), POSTGRES.getPassword()));
        jdbc.execute("""
                CREATE TABLE production_execution_segments(id uuid PRIMARY KEY, status text, auto_promote_when_ready boolean DEFAULT TRUE, is_deleted boolean DEFAULT FALSE);
                CREATE TABLE departments(id uuid PRIMARY KEY, parent_id uuid, manager_id uuid, is_deleted boolean DEFAULT FALSE);
                CREATE TABLE employees(id uuid PRIMARY KEY, department_id uuid, status text DEFAULT 'active', is_deleted boolean DEFAULT FALSE);
                CREATE TABLE employee_secondary_departments(employee_id uuid, department_id uuid);
                CREATE TABLE production_plans(id uuid PRIMARY KEY, bill_no text, status integer, maker_id uuid,
                    material_analysis_id uuid, is_deleted boolean DEFAULT FALSE);
                CREATE TABLE goods(id uuid, code text, name text);
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
                    plan_begin_date date DEFAULT '2026-09-05', plan_end_date date DEFAULT '2026-09-06', lock_version bigint DEFAULT 1, zero_material boolean DEFAULT FALSE);
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
        jdbc.update("INSERT INTO departments(id) VALUES (?), (?)", WORKSHOP, OTHER_WORKSHOP);
        jdbc.update("INSERT INTO employees(id, department_id) VALUES (?, ?)", EMPLOYEE, WORKSHOP);
        jdbc.update("INSERT INTO production_plans(id, bill_no, status, maker_id) VALUES (?, 'PLAN-001', 1, ?)", PLAN, EMPLOYEE);
        jdbc.update("INSERT INTO v_production_execution_workbench_roots(root_id, owner_employee_id) VALUES (?, ?)", PLAN, EMPLOYEE);
        insertSegment(1, "WAITING", "PREPARING", false, WORKSHOP);
        insertSegment(2, "READY", "PREPARING", false, WORKSHOP);
        insertSegment(3, "DISPATCHED", "READY_TO_REPORT", true, WORKSHOP);
        insertSegment(4, "IN_PROGRESS", "READY_TO_REPORT", true, WORKSHOP);
        insertSegment(5, "COMPLETED", "COMPLETE", false, WORKSHOP);
        insertSegment(6, "READY", "PREPARING", false, OTHER_WORKSHOP);
        factory = new Configuration()
                .setProperty("hibernate.connection.driver_class", "org.postgresql.Driver")
                .setProperty("hibernate.connection.url", POSTGRES.getJdbcUrl())
                .setProperty("hibernate.connection.username", POSTGRES.getUsername())
                .setProperty("hibernate.connection.password", POSTGRES.getPassword())
                .setProperty("hibernate.hbm2ddl.auto", "none").buildSessionFactory();
    }
    private static void insertSegment(int number, String status, String preparation, boolean reportable, UUID workshop) {
        jdbc.update("INSERT INTO production_execution_segments(id,status) VALUES (?, ?)", new UUID(0, number), status);
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
        service = new ProductionExecutionWorkbenchService(em, access,
                mock(PurchaseDocumentAccessPolicy.class), mock(SubcontractDocumentReadAccessPort.class), currentUser);
        org.springframework.test.util.ReflectionTestUtils.setField(service,"draftPreparationAccess",
                mock(com.uten.imp.features.production.SubcontractDraftPreparationAccessPolicy.class));
    }

    /** V477 读侧放行回归锁：超管在我的车间任务页看到全部车间的活跃段与角标。 */
    @Test
    void superAdminSeesAllWorkshopsOnReadSide() {
        com.uten.imp.security.AuthUser admin = mock(com.uten.imp.security.AuthUser.class);
        when(admin.isSuperAdmin()).thenReturn(true);
        when(currentUser.get()).thenReturn(Optional.of(admin));
        var page = service.workshopTasks(1, 50, null, null, null);
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
        var first = service.workshopTasks(1, 2, null, null, null);
        var last = service.workshopTasks(99, 2, null, null, null);
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
        var reportable = service.workshopTasks(1, 50, "P001", "READY_TO_REPORT", null);
        assertThat(reportable.getTotal()).isEqualTo(1);
        assertThat(reportable.getItems()).allMatch(item -> item.canReport()
                && "IN_PROGRESS".equals(item.segmentStatus()));
        var startable = service.workshopTasks(1, 50, "P001", "READY_TO_START", null);
        assertThat(startable.getTotal()).isEqualTo(1);
        assertThat(startable.getItems()).allMatch(item -> !item.canReport()
                && !item.canBatchReport());
        when(access.hasAuthority("production_daily_report:create")).thenReturn(false);
        var readonly = service.workshopTasks(1, 50, null, "READY_TO_REPORT", null);
        assertThat(readonly.getTotal()).isEqualTo(1);
        assertThat(readonly.getItems()).allMatch(item -> !item.canReport() && !item.canBatchReport());
    }
    @Test
    void preparingAndInProgressFiltersExecuteWithAndWithoutKeyword() {
        assertThat(service.workshopTasks(1, 50, null, "PREPARING", null).getTotal()).isEqualTo(3);
        assertThat(service.workshopTasks(1, 50, "Assembly", "IN_PROGRESS", null).getTotal()).isEqualTo(1);
        assertThat(service.workshopTasks(1, 50, "missing", null, null).getTotal()).isZero();
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
