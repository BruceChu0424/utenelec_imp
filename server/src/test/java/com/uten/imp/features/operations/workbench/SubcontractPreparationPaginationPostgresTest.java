package com.uten.imp.features.operations.workbench;

import com.uten.imp.features.production.ProductionDocumentAccessPolicy;
import com.uten.imp.features.production.analysis.MaterialAnalysisService;
import com.uten.imp.features.production.analysis.SubcontractMakeTaskService;
import com.uten.imp.security.AuthUser;
import com.uten.imp.security.OwnerVisibility;
import com.uten.imp.security.ProductionStockTaskAccessPolicy;
import com.uten.imp.security.SecurityContextCurrentUser;
import jakarta.persistence.EntityManager;
import jakarta.persistence.EntityManagerFactory;
import org.junit.jupiter.api.*;
import org.junit.jupiter.api.condition.EnabledIfEnvironmentVariable;
import org.springframework.jdbc.core.JdbcTemplate;
import org.springframework.jdbc.datasource.DriverManagerDataSource;
import org.springframework.orm.jpa.JpaTransactionManager;
import org.springframework.orm.jpa.LocalContainerEntityManagerFactoryBean;
import org.springframework.orm.jpa.SharedEntityManagerCreator;
import org.springframework.orm.jpa.vendor.HibernateJpaVendorAdapter;
import org.springframework.transaction.support.TransactionTemplate;
import org.testcontainers.containers.PostgreSQLContainer;

import java.nio.charset.StandardCharsets;
import java.util.*;

import static org.assertj.core.api.Assertions.assertThat;
import static org.assertj.core.api.Assertions.assertThatThrownBy;
import static org.mockito.ArgumentMatchers.anyString;
import static org.mockito.Mockito.*;

/** Real paginated read SQL with a large completed history and a bounded active set. */
@EnabledIfEnvironmentVariable(named = "UTEN_RUN_DB_TESTS", matches = "(?i)true")
class SubcontractPreparationPaginationPostgresTest {
    private static final PostgreSQLContainer<?> DB = new PostgreSQLContainer<>("postgres:16-alpine");
    private static EntityManagerFactory emf;
    private static EntityManager em;
    private static JdbcTemplate jdbc;
    private static TransactionTemplate transactions;
    private static String planBeforeIndex;
    private FulfillmentWorkbenchQueryService service;
    private SecurityContextCurrentUser current;
    private final List<String> executedSql = new ArrayList<>();
    private final UUID employeeId = UUID.randomUUID();

    @BeforeAll
    static void start() throws Exception {
        DB.start();
        var dataSource = new DriverManagerDataSource(DB.getJdbcUrl(), DB.getUsername(), DB.getPassword());
        jdbc = new JdbcTemplate(dataSource);
        jdbc.execute("CREATE TABLE goods(id uuid PRIMARY KEY, code text, name text)");
        jdbc.execute("CREATE TABLE colors(id uuid PRIMARY KEY, name text)");
        jdbc.execute("CREATE TABLE units(id uuid PRIMARY KEY, name text)");
        jdbc.execute("CREATE TABLE warehouses(id uuid PRIMARY KEY, name text)");
        jdbc.execute("CREATE TABLE production_material_analyses(id uuid PRIMARY KEY, status text, maker_id uuid)");
        jdbc.execute("CREATE TABLE production_material_analysis_items(id uuid PRIMARY KEY, source_ref text, delivery_date date)");
        jdbc.execute("""
                CREATE TABLE preplan_subcontract_make_tasks(id uuid PRIMARY KEY, analysis_id uuid,
                    preparation_item_id uuid, goods_id uuid, color_id uuid, unit_id uuid, warehouse_id uuid,
                    required_qty numeric(18,4), produced_qty numeric(18,4), notified_qty numeric(18,4),
                    status text, updated_at timestamptz)
                """);
        jdbc.execute("CREATE TABLE production_plans(id uuid PRIMARY KEY, material_analysis_item_id uuid, is_deleted boolean, is_canceled boolean)");
        jdbc.execute("CREATE TABLE production_execution_segments(id uuid PRIMARY KEY, plan_id uuid, status text, is_deleted boolean)");
        jdbc.execute("CREATE TABLE production_material_analysis_plan_links(analysis_id uuid, analysis_item_id uuid, submitted_qty numeric, allocation_status text)");
        jdbc.execute("""
                CREATE TABLE workbench_documents(department text, action_doc_id uuid, plan_no text,
                    warehouse_id uuid, warehouse_name text, goods_id uuid, goods_code text, goods_name text,
                    spec text, color_id uuid, color_name text, unit_id uuid, unit_name text, supply_route text,
                    required_qty numeric, allocated_qty numeric, fulfilled_qty numeric, supply_pegged_qty numeric,
                    open_qty numeric, task_status text, need_date date, expected_date date, exception_code text,
                    updated_at timestamptz, action_doc_type text, action_doc_no text, action_item_id uuid, action_doc_status text)
                """);
        jdbc.execute("CREATE VIEW v_procurement_decomposition_tasks AS SELECT * FROM workbench_documents");
        jdbc.execute("""
                INSERT INTO goods SELECT md5('goods-'||n)::uuid, 'SKU-'||n, 'Product '||n FROM generate_series(1,125) n;
                INSERT INTO production_material_analyses VALUES (md5('analysis')::uuid, 'ACTIVE', md5('maker')::uuid);
                INSERT INTO production_material_analysis_items SELECT md5('item-'||n)::uuid, 'PREP-'||n, CURRENT_DATE FROM generate_series(1,125) n;
                INSERT INTO preplan_subcontract_make_tasks
                SELECT md5('task-'||n)::uuid, md5('analysis')::uuid, md5('item-'||n)::uuid, md5('goods-'||n)::uuid,
                       NULL,NULL,NULL,10,0,0,'ACTIVE',now() FROM generate_series(1,125) n;
                INSERT INTO preplan_subcontract_make_tasks
                SELECT md5('done-'||n)::uuid, md5('analysis')::uuid, md5('item-1')::uuid, md5('goods-1')::uuid,
                       NULL,NULL,NULL,10,10,10,'ACTIVE',now() FROM generate_series(1,20000) n;
                INSERT INTO preplan_subcontract_make_tasks
                SELECT md5('cancelled-'||n)::uuid, md5('analysis')::uuid, md5('item-1')::uuid, md5('goods-1')::uuid,
                       NULL,NULL,NULL,10,0,0,'CANCELLED',now() FROM generate_series(1,50) n;
                INSERT INTO workbench_documents(department, action_doc_id, plan_no, goods_id, goods_code, goods_name,
                    supply_route, required_qty, allocated_qty, fulfilled_qty, supply_pegged_qty, open_qty,
                    task_status, need_date, updated_at, action_doc_type, action_doc_no, action_item_id, action_doc_status)
                SELECT 'SUBCONTRACT',md5('document-'||n)::uuid,'DOC-'||n,md5('goods-1')::uuid,'DOC-SKU','Document goods',
                    'SUBCONTRACT',10,0,0,0,10,'WAITING_ORDER',CURRENT_DATE,now(),'SUBCONTRACT_APPLICATION',
                    'APP-'||n,md5('doc-item-'||n)::uuid,'1' FROM generate_series(1,3) n;
                CREATE INDEX idx_preplan_subcontract_make_tasks_open
                    ON preplan_subcontract_make_tasks(status,updated_at,id) WHERE status='ACTIVE';
                """);
        jdbc.execute("VACUUM ANALYZE preplan_subcontract_make_tasks");
        planBeforeIndex = countPlan();
        try (var migration = Objects.requireNonNull(SubcontractPreparationPaginationPostgresTest.class
                .getResourceAsStream("/db/migration/V497__subcontract_pending_preparation_index.sql"))) {
            jdbc.execute(new String(migration.readAllBytes(), StandardCharsets.UTF_8));
        }
        jdbc.execute("VACUUM ANALYZE preplan_subcontract_make_tasks");
        var factory = new LocalContainerEntityManagerFactoryBean();
        factory.setDataSource(dataSource);
        factory.setJpaVendorAdapter(new HibernateJpaVendorAdapter());
        factory.setPackagesToScan("com.uten.imp.features.common.taskclaim");
        var properties = new Properties(); properties.setProperty("hibernate.hbm2ddl.auto", "none");
        factory.setJpaProperties(properties); factory.afterPropertiesSet();
        emf = factory.getObject(); em = SharedEntityManagerCreator.createSharedEntityManager(emf);
        transactions = new TransactionTemplate(new JpaTransactionManager(emf));
    }

    @AfterAll static void stop() { if (emf != null) emf.close(); DB.stop(); }

    @BeforeEach void setUp() {
        current = mock(SecurityContextCurrentUser.class);
        when(current.get()).thenReturn(Optional.of(new AuthUser(UUID.randomUUID(), employeeId, "reader",
                Set.of(), Set.of("subcontract_application:view"), false, true, false)));
        EntityManager recording = mock(EntityManager.class);
        when(recording.createNativeQuery(anyString())).thenAnswer(call -> {
            String sql = call.getArgument(0); executedSql.add(sql); return em.createNativeQuery(sql);
        });
        service = new FulfillmentWorkbenchQueryService(recording, new FulfillmentWorkbenchAccessPolicy(current,
                mock(ProductionStockTaskAccessPolicy.class)));
    }

    @Test void allPendingPreparationsAndDocumentsShareOnePagerAndAuthoritativeCount() {
        Set<UUID> ids = new HashSet<>();
        int preparations = 0;
        for (int page = 1; page <= 3; page++) {
            int number = page;
            var response = transactions.execute(tx -> service.query("SUBCONTRACT", "WAITING_ORDER", "", "", null, null, number, 50));
            assertThat(response.total()).isEqualTo(128);
            assertThat(response.totalPages()).isEqualTo(3);
            assertThat(response.items()).hasSize(page == 3 ? 28 : 50);
            assertThat(response.summary().statusCounts()).containsEntry("WAITING_ORDER", 128L);
            for (var item : response.items()) {
                assertThat(ids.add(item.taskId())).isTrue();
                if ("SUBCONTRACT_MAKE_TASK".equals(item.actionDocType())) {
                    preparations++;
                    assertThat(item.actionDocCanView()).isTrue();
                    assertThat(item.actionDocCanEdit()).isFalse();
                }
            }
        }
        assertThat(preparations).isEqualTo(125);
        assertThat(ids).hasSize(128);
        long count = transactions.execute(tx -> service.countPending("SUBCONTRACT"));
        assertThat(count).isEqualTo(128L);
    }

    @Test void keywordFilteringHappensBeforePaginationAndSingleTaskLookupDoesNotScanTheFirstHundred() {
        var response = transactions.execute(tx -> service.query("SUBCONTRACT", "WAITING_ORDER", "SKU-125", "", null, null, 1, 50));
        assertThat(response.items()).hasSize(1);
        assertThat(response.total()).isEqualTo(1);
        UUID taskId = response.items().getFirst().taskId();
        var visibility = mock(OwnerVisibility.class);
        when(visibility.evaluate(anyString(), anyString())).thenReturn(new OwnerVisibility.OwnerScope(false, Set.of(employeeId)));
        var tasks = new SubcontractMakeTaskService(em, mock(MaterialAnalysisService.class),
                new ProductionDocumentAccessPolicy(visibility, current), null, null, current);
        var task = transactions.execute(tx -> tasks.task(taskId));
        assertThat(task.taskId()).isEqualTo(taskId);
        assertThat(task.goodsCode()).isEqualTo("SKU-125");
        assertThat(task.allowedActions()).isEmpty();
        when(current.get()).thenReturn(Optional.of(new AuthUser(UUID.randomUUID(), employeeId, "planning-reader",
                Set.of(), Set.of("production_material_analysis:view"), false, true, false)));
        assertThatThrownBy(() -> transactions.execute(tx -> tasks.task(taskId)))
                .isInstanceOf(com.uten.imp.common.web.ApiException.class)
                .extracting(error -> ((com.uten.imp.common.web.ApiException) error).getCode())
                .isEqualTo(com.uten.imp.common.web.ErrorCode.NOT_FOUND);
    }

    @Test void orderOnlyPermissionDoesNotExposePreparationRowsOrTheirCount() {
        when(current.get()).thenReturn(Optional.of(new AuthUser(UUID.randomUUID(), employeeId, "order-reader",
                Set.of(), Set.of("subcontract_order:view"), false, true, false)));
        var response = transactions.execute(tx -> service.query("SUBCONTRACT", "WAITING_ORDER", "", "", null, null, 1, 50));
        assertThat(response.total()).isEqualTo(3);
        long count = transactions.execute(tx -> service.countPending("SUBCONTRACT"));
        assertThat(count).isEqualTo(3L);
    }

    @Test void pendingCountUsesTheNarrowIndexInsteadOfScanningCompletedActiveHistory() {
        assertThat(planBeforeIndex).contains("Seq Scan");
        assertThat(countPlan()).contains("idx_subcontract_make_pending").doesNotContain("Seq Scan");
        transactions.execute(tx -> service.query("SUBCONTRACT", "WAITING_ORDER", "", "", null, null, 1, 50));
        String actualRowsSql = executedSql.getFirst();
        String plan = transactions.execute(tx -> {
            var query = em.createNativeQuery("EXPLAIN " + actualRowsSql);
            query.setParameter("department", "SUBCONTRACT").setParameter("status", "WAITING_ORDER")
                    .setParameter("exception", "").setParameter("keyword", "").setParameter("keywordLike", "%%")
                    .setParameter("date_from", null).setParameter("date_to", null)
                    .setParameter("offset", 0L).setParameter("limit", 50);
            return String.join("\n", query.getResultList().stream().map(Object::toString).toList());
        });
        assertThat(plan).contains("idx_subcontract_make_pending")
                .doesNotContain("Seq Scan on preplan_subcontract_make_tasks");
    }

    private static String countPlan() {
        return String.join("\n", jdbc.queryForList("EXPLAIN SELECT count(*) FROM preplan_subcontract_make_tasks "
                + "WHERE status='ACTIVE' AND notified_qty<required_qty", String.class));
    }
}
