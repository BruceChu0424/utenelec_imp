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
        jdbc.execute("CREATE TABLE preplan_supply_actions(id uuid PRIMARY KEY, created_at timestamptz, external_document_type text, route text)");
        jdbc.execute("CREATE TABLE preplan_supply_action_allocations(id uuid PRIMARY KEY, external_item_id uuid, action_id uuid)");
        jdbc.execute("CREATE TABLE preplan_subcontract_make_task_batches(id uuid PRIMARY KEY, application_item_id uuid, task_id uuid)");
        jdbc.execute("CREATE TABLE subcontract_order_item_sources(order_item_id uuid, application_item_id uuid, alloc_qty numeric)");
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
        jdbc.execute("ALTER TABLE preplan_subcontract_make_tasks ADD COLUMN supply_action_id uuid");
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

    @Test void orderableDocumentsPrecedePreparationAcrossPagesAndColumnFacetsUseAllMatchingRows() {
        when(current.get()).thenReturn(Optional.of(new AuthUser(UUID.randomUUID(), employeeId, "decomposer",
                Set.of(), Set.of("subcontract_application:view", "subcontract_order:create", "subcontract_order:decompose"), false, true, false)));
        transactions.executeWithoutResult(tx -> {
            jdbc.update("UPDATE workbench_documents SET need_date=CURRENT_DATE+90");
            var options = new FulfillmentWorkbenchTableQuery("docNo", "desc", Map.of(), null, null, null, null);
            var first = service.query("SUBCONTRACT", "", "", "", null, null, 1, 2, options);
            var second = service.query("SUBCONTRACT", "", "", "", null, null, 2, 2, options);
            assertThat(first.items()).extracting(FulfillmentTaskRow::actionDocNo).containsExactly("APP-3", "APP-2");
            assertThat(first.items()).allMatch(FulfillmentTaskRow::canCreateOrder);
            assertThat(second.items().getFirst().actionDocNo()).isEqualTo("APP-1");
            assertThat(second.items().get(1).canCreateOrder()).isFalse();
            assertThat(first.total()).isEqualTo(128);
            var filtered = service.query("SUBCONTRACT", "", "", "", null, null, 1, 2,
                    new FulfillmentWorkbenchTableQuery("docNo", "asc", Map.of("docNo", "APP-3"), null, null, null, null));
            assertThat(filtered.total()).isEqualTo(1);
            assertThat(filtered.facets().get("docNo")).extracting(FulfillmentWorkbenchPage.Facet::value)
                    .contains("APP-1", "APP-2", "APP-3", "PREP-125");
            var stage = service.query("SUBCONTRACT", "", "", "", null, null, 1, 2,
                    new FulfillmentWorkbenchTableQuery("planNo", "asc", Map.of("status", "NOTIFYING_WORKSHOP"), null, null, null, null));
            assertThat(stage.total()).isEqualTo(125);
            assertThat(stage.facets().get("status")).contains(new FulfillmentWorkbenchPage.Facet("WAITING_ORDER", "WAITING_ORDER", 3));
            var exactGoods = service.query("SUBCONTRACT", "", "", "", null, null, 1, 2,
                    new FulfillmentWorkbenchTableQuery("goods", "desc", Map.of("goods", id("goods-125").toString()), null, null, null, null));
            assertThat(exactGoods.total()).isEqualTo(1);
            assertThat(exactGoods.items().getFirst().goodsCode()).isEqualTo("SKU-125");
            tx.setRollbackOnly();
        });
    }

    @Test void issueDateUsesOriginalPlanningActionThroughPreparationAndOrderSourcesAndKeepsUnknownNull() {
        when(current.get()).thenReturn(Optional.of(new AuthUser(UUID.randomUUID(), employeeId, "decomposer",
                Set.of(), Set.of("subcontract_application:view", "subcontract_order:view", "subcontract_order:create", "subcontract_order:decompose"), false, true, false)));
        transactions.executeWithoutResult(tx -> {
            jdbc.update("INSERT INTO preplan_supply_actions VALUES (?,TIMESTAMPTZ '2026-09-01 16:30:00+00','SUBCONTRACT_MAKE_TASK','SUBCONTRACT'),(?,TIMESTAMPTZ '2026-09-06 00:00:00+00','SUBCONTRACT_APPLICATION','SUBCONTRACT'),(?,TIMESTAMPTZ '2026-09-03 08:00:00+00','SUBCONTRACT_APPLICATION','SUBCONTRACT')",
                    id("issue-original"), id("issue-after-production"), id("issue-direct"));
            jdbc.update("UPDATE preplan_subcontract_make_tasks SET supply_action_id=? WHERE id=?",id("issue-original"),id("task-1"));
            jdbc.update("INSERT INTO preplan_subcontract_make_task_batches VALUES(?,?,?)",UUID.randomUUID(),id("doc-item-1"),id("task-1"));
            jdbc.update("INSERT INTO preplan_supply_action_allocations VALUES(?,?,?),(?,?,?)",UUID.randomUUID(),id("doc-item-1"),id("issue-after-production"),UUID.randomUUID(),id("doc-item-2"),id("issue-direct"));
            jdbc.update("INSERT INTO subcontract_order_item_sources VALUES(?,?,10)",id("ordered-item"),id("doc-item-1"));
            jdbc.update("""
                    INSERT INTO workbench_documents
                    SELECT department,?,plan_no,warehouse_id,warehouse_name,goods_id,goods_code,goods_name,
                        spec,color_id,color_name,unit_id,unit_name,supply_route,required_qty,allocated_qty,
                        fulfilled_qty,supply_pegged_qty,open_qty,'ORDER_PENDING_APPROVAL',need_date,expected_date,
                        exception_code,updated_at,'SUBCONTRACT_ORDER','ORDER-A',?,'0'
                    FROM workbench_documents WHERE action_doc_id=?
                    """,id("ordered-document"),id("ordered-item"),id("document-1"));
            var date = java.time.LocalDate.of(2026,9,2);
            var result = service.query("SUBCONTRACT", "", "", "", null, null, 1, 50,
                    new FulfillmentWorkbenchTableQuery("issuedAt", "desc", Map.of(), date, date, null, null));
            assertThat(result.items()).extracting(FulfillmentTaskRow::taskId)
                    .containsExactlyInAnyOrder(id("task-1"),id("document-1"),id("ordered-document"));
            assertThat(result.items()).allSatisfy(row -> assertThat(row.issuedAt().toInstant())
                    .isEqualTo(java.time.Instant.parse("2026-09-01T16:30:00Z")));
            var applications = service.query("SUBCONTRACT", "", "APP-", "", null, null, 1, 50,
                    new FulfillmentWorkbenchTableQuery("issuedAt", "desc", Map.of(), null, null, null, null));
            assertThat(applications.items()).extracting(FulfillmentTaskRow::actionDocNo).containsExactly("APP-2","APP-1","APP-3");
            assertThat(applications.items().getLast().issuedAt()).isNull();
            assertThat(applications.nullCounts()).containsEntry("issuedAt",1L);
            assertThat(applications.facets().get("issuedAt")).extracting(FulfillmentWorkbenchPage.Facet::value)
                    .containsExactly("2026-09-02","2026-09-03");
            tx.setRollbackOnly();
        });
    }

    @Test void restrictedDocumentNumbersCannotLeakViaNewFacetsOrColumnFiltersAndUnknownKeysFailClosed() {
        when(current.get()).thenReturn(Optional.of(new AuthUser(UUID.randomUUID(), employeeId, "orders-only",
                Set.of(), Set.of("subcontract_order:view"), false, true, false)));
        transactions.executeWithoutResult(tx -> {
            var result=service.query("SUBCONTRACT","","","",null,null,1,50,
                    new FulfillmentWorkbenchTableQuery("docNo","asc",Map.of(),null,null,null,null));
            assertThat(result.items()).allMatch(FulfillmentTaskRow::actionDocRestricted);
            assertThat(result.facets()).doesNotContainKey("docNo");
            assertThat(result.nullCounts()).containsEntry("docNo",3L);
            assertThat(service.query("SUBCONTRACT","","","",null,null,1,50,
                    new FulfillmentWorkbenchTableQuery("docNo","asc",Map.of("docNo","APP-1"),null,null,null,null)).total()).isZero();
        });
        assertThatThrownBy(()->new FulfillmentWorkbenchTableQuery("task_id;DROP TABLE goods","asc",Map.of(),null,null,null,null))
                .isInstanceOf(com.uten.imp.common.web.ApiException.class);
        assertThatThrownBy(()->new FulfillmentWorkbenchTableQuery("planNo","asc",Map.of("unknown","x"),null,null,null,null))
                .isInstanceOf(com.uten.imp.common.web.ApiException.class);
    }

    private static UUID id(String key) {
        return jdbc.queryForObject("SELECT md5(?)::uuid",UUID.class,key);
    }

    private static String countPlan() {
        return String.join("\n", jdbc.queryForList("EXPLAIN SELECT count(*) FROM preplan_subcontract_make_tasks "
                + "WHERE status='ACTIVE' AND notified_qty<required_qty", String.class));
    }
}
