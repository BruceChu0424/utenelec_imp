package com.uten.imp.features.operations.workbench;

import com.uten.imp.common.util.NativeQueryResults;
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
        // Match the application pool: OLTP views should not spend seconds JIT-compiling each read.
        var dataSource = new DriverManagerDataSource(DB.getJdbcUrl()
                + "&options=-c%20jit%3Doff", DB.getUsername(), DB.getPassword());
        jdbc = new JdbcTemplate(dataSource);
        jdbc.execute("CREATE TABLE goods(id uuid PRIMARY KEY, code text, name text, is_deleted boolean NOT NULL DEFAULT false, auto_created boolean NOT NULL DEFAULT false, default_purchase_price_color_id uuid, default_purchase_price_currency_id uuid, default_purchase_price_supplier_id uuid, default_purchase_price_tax_rate numeric(18,4), default_purchase_price_unit_id uuid, default_subcontract_price_color_id uuid, default_subcontract_price_currency_id uuid, default_subcontract_price_supplier_id uuid, default_subcontract_price_tax_rate numeric(18,4), default_subcontract_price_unit_id uuid)");
        jdbc.execute("CREATE TABLE colors(id uuid PRIMARY KEY, name text)");
        jdbc.execute("CREATE TABLE units(id uuid PRIMARY KEY, name text)");
        jdbc.execute("CREATE TABLE warehouses(id uuid PRIMARY KEY, name text, parent_id uuid, is_deleted boolean NOT NULL DEFAULT false, is_defective boolean NOT NULL DEFAULT false, is_line_side boolean NOT NULL DEFAULT false)");
        // ADR-103 路线 B 锁判据要读的最小集: 申请明细、BOM 边、可动用库存视图、发料计划两表,
        // 以及 V581 / V613 的两个判据函数 (桩的函数体与迁移原文逐字一致, 判据不在测试里另写一遍).
        jdbc.execute("CREATE TABLE subcontract_application_items(id uuid PRIMARY KEY, application_id uuid, goods_id uuid, color_id uuid, qty numeric, ordered_qty numeric DEFAULT 0, is_deleted boolean NOT NULL DEFAULT false)");
        jdbc.execute("CREATE TABLE goods_bom_items(id uuid PRIMARY KEY, goods_id uuid, component_goods_id uuid, color_id uuid, qty numeric NOT NULL DEFAULT 1, consumption_basis text NOT NULL DEFAULT 'PER_UNIT', control_stage text NOT NULL DEFAULT 'START', is_deleted boolean NOT NULL DEFAULT false)");
        jdbc.execute("CREATE TABLE stock_balances(id uuid PRIMARY KEY, warehouse_id uuid, goods_id uuid, color_id uuid, qty numeric)");
        jdbc.execute("CREATE VIEW v_stock_available AS SELECT warehouse_id, goods_id, color_id, qty AS available_qty FROM stock_balances");
        jdbc.execute("CREATE TABLE subcontract_material_plans(id uuid PRIMARY KEY, order_id uuid, status text, is_deleted boolean NOT NULL DEFAULT false)");
        jdbc.execute("CREATE TABLE subcontract_material_plan_items(id uuid PRIMARY KEY, plan_id uuid, order_item_id uuid, goods_id uuid, color_id uuid, flow_mode text, planned_qty numeric, prepared_qty numeric, issued_qty numeric DEFAULT 0, is_deleted boolean NOT NULL DEFAULT false)");
        jdbc.execute("""
                CREATE FUNCTION fn_warehouse_is_operational_leaf(p_warehouse UUID)
                RETURNS BOOLEAN LANGUAGE sql STABLE AS $$
                    SELECT EXISTS (
                        SELECT 1 FROM warehouses warehouse
                        WHERE warehouse.id = p_warehouse AND NOT warehouse.is_deleted
                          AND NOT EXISTS (
                              SELECT 1 FROM warehouses child
                              WHERE child.parent_id = warehouse.id AND NOT child.is_deleted
                                AND (warehouse.is_line_side OR NOT child.is_line_side)));
                $$
                """);
        jdbc.execute("""
                CREATE FUNCTION fn_subcontract_sole_component_goods(p_goods_id UUID)
                RETURNS BOOLEAN LANGUAGE sql STABLE AS $$
                    SELECT EXISTS (
                        SELECT 1
                        FROM goods_bom_items edge
                        JOIN goods child ON child.id = edge.component_goods_id
                         AND child.is_deleted = FALSE
                         AND COALESCE(child.auto_created, FALSE) = FALSE
                        WHERE edge.goods_id = p_goods_id
                          AND edge.is_deleted = FALSE
                          AND edge.consumption_basis = 'PER_UNIT'
                          AND edge.control_stage IN ('START', 'ASSEMBLY', 'FINISH')
                          AND edge.qty > 0
                          AND (SELECT COUNT(*)
                                 FROM goods_bom_items only_edge
                                 JOIN goods only_child
                                   ON only_child.id = only_edge.component_goods_id
                                  AND only_child.is_deleted = FALSE
                                  AND COALESCE(only_child.auto_created, FALSE) = FALSE
                                WHERE only_edge.goods_id = p_goods_id
                                  AND only_edge.is_deleted = FALSE) = 1
                          AND NOT EXISTS (
                                SELECT 1
                                  FROM goods_bom_items grand
                                  JOIN goods grand_child
                                    ON grand_child.id = grand.component_goods_id
                                   AND grand_child.is_deleted = FALSE
                                   AND COALESCE(grand_child.auto_created, FALSE) = FALSE
                                 WHERE grand.goods_id = edge.component_goods_id
                                   AND grand.is_deleted = FALSE)
                    );
                $$
                """);
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
        // ADR-098：委外「进行中」display_stage 的 LATERAL progress 子查询要读这四张表(最小列集)。
        jdbc.execute("CREATE TABLE subcontract_short_delivery_cases(id uuid PRIMARY KEY, order_id uuid, order_item_id uuid, status text, severity text, expected_complete_by date)");
        jdbc.execute("CREATE TABLE subcontract_order_items(id uuid PRIMARY KEY, order_id uuid, qty numeric, received_qty numeric, returned_qty numeric, is_deleted boolean DEFAULT false)");
        // This pagination fixture has public inventory only. Exact entitlement handoff is
        // exercised against all real migrations by the component outbound integration tests.
        jdbc.execute("""
                CREATE FUNCTION fn_subcontract_component_available_stock(p_application uuid, p_order_item uuid)
                RETURNS TABLE(warehouse_id uuid, goods_id uuid, color_id uuid, available_qty numeric)
                LANGUAGE sql STABLE AS $$
                  SELECT sa.warehouse_id, sa.goods_id, sa.color_id, sa.available_qty
                  FROM v_stock_available sa JOIN warehouses w ON w.id=sa.warehouse_id
                  WHERE sa.available_qty > 0
                    AND NOT w.is_deleted AND NOT w.is_defective AND NOT w.is_line_side
                    AND fn_warehouse_is_operational_leaf(w.id)
                    AND (EXISTS (SELECT 1 FROM subcontract_application_items ai
                                 JOIN goods_bom_items edge ON edge.goods_id=ai.goods_id
                                 WHERE ai.id=p_application AND NOT ai.is_deleted AND NOT edge.is_deleted
                                   AND edge.component_goods_id=sa.goods_id
                                   AND edge.color_id IS NOT DISTINCT FROM sa.color_id)
                         OR EXISTS (SELECT 1 FROM subcontract_material_plan_items pi
                                    WHERE pi.order_item_id=p_order_item AND NOT pi.is_deleted
                                      AND pi.goods_id=sa.goods_id
                                      AND pi.color_id IS NOT DISTINCT FROM sa.color_id))
                $$
                """);
        jdbc.execute("CREATE TABLE subcontract_material_issues(id uuid PRIMARY KEY, status smallint, is_deleted boolean DEFAULT false)");
        jdbc.execute("CREATE TABLE subcontract_material_issue_items(id uuid PRIMARY KEY, issue_id uuid, order_item_id uuid, plan_item_id uuid, qty numeric, is_deleted boolean DEFAULT false)");
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
        jdbc.execute("ALTER TABLE preplan_subcontract_make_tasks ADD COLUMN analysis_material_id uuid");
        jdbc.execute("""
                ALTER TABLE production_material_analysis_items ADD COLUMN analysis_id uuid,
                    ADD COLUMN goods_id uuid, ADD COLUMN source_type text,
                    ADD COLUMN sales_order_item_id uuid, ADD COLUMN requested_qty numeric;
                CREATE TABLE production_material_analysis_materials(
                    id uuid PRIMARY KEY, analysis_id uuid, analysis_item_id uuid);
                CREATE TABLE sales_order_items(id uuid PRIMARY KEY, bill_no text, line_no integer);
                ALTER TABLE preplan_supply_actions ADD COLUMN status text DEFAULT 'CREATED',
                    ADD COLUMN goods_id uuid, ADD COLUMN unit_id uuid,
                    ADD COLUMN public_surplus_qty numeric DEFAULT 0,
                    ADD COLUMN public_surplus_external_item_id uuid;
                ALTER TABLE preplan_supply_action_allocations ADD COLUMN analysis_id uuid,
                    ADD COLUMN analysis_material_id uuid, ADD COLUMN allocated_qty numeric;
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

    @Test void originalProductsAndSalesLinesRemainSeparateWithinOneApplication() {
        transactions.executeWithoutResult(tx -> {
            seedOriginalProductSources();
            var page = service.query("SUBCONTRACT", "WAITING_ORDER", "APP-1", "", null, null, 1, 50);
            assertThat(page.items()).hasSize(1);
            var sources = page.items().getFirst().sources();
            assertThat(sources).hasSize(3);
            assertThat(sources).filteredOn(source -> "SKU-1".equals(source.productCode()))
                    .singleElement().satisfies(source -> {
                        assertThat(source.sourceNo()).isEqualTo("SO-SOURCE-A");
                        assertThat(source.sourceLineNo()).isEqualTo(2);
                        assertThat(source.quantity()).isEqualByComparingTo("3");
                    });
            assertThat(sources).filteredOn(source -> "SKU-2".equals(source.productCode()))
                    .singleElement().satisfies(source -> {
                        assertThat(source.sourceNo()).isEqualTo("SO-SOURCE-B");
                        assertThat(source.quantity()).isEqualByComparingTo("5");
                    });
            assertThat(sources).filteredOn(source -> "PUBLIC_STOCK".equals(source.sourceType()))
                    .singleElement().satisfies(source -> assertThat(source.quantity()).isEqualByComparingTo("2"));
            assertThat(executedSql.stream().filter(sql -> sql.startsWith("WITH visible_items"))).hasSize(1);

            var visibility = mock(OwnerVisibility.class);
            when(visibility.evaluate(anyString(), anyString()))
                    .thenReturn(new OwnerVisibility.OwnerScope(false, Set.of(employeeId)));
            var tasks = new SubcontractMakeTaskService(em, mock(MaterialAnalysisService.class),
                    new ProductionDocumentAccessPolicy(visibility, current), null, null, current);
            var preparation = tasks.task(id("task-125"));
            assertThat(preparation.itemSourceRef()).isEqualTo("PREP-125");
            assertThat(preparation.sources()).hasSize(2);
            assertThat(preparation.sources().getFirst().productCode()).isEqualTo("SKU-1");
            assertThat(preparation.sources().getFirst().sourceNo()).isEqualTo("SO-SOURCE-A");
            assertThat(preparation.sources().getFirst().quantity()).isEqualByComparingTo("4");
            assertThat(preparation.sources().get(1).sourceType()).isEqualTo("PUBLIC_STOCK");
            assertThat(preparation.sources().get(1).quantity()).isEqualByComparingTo("6");

            when(current.get()).thenReturn(Optional.of(new AuthUser(UUID.randomUUID(), employeeId,
                    "order-reader", Set.of(), Set.of("subcontract_order:view"), false, true, false)));
            executedSql.clear();
            var hidden = service.query("SUBCONTRACT", "WAITING_ORDER", "APP-1", "", null, null, 1, 50);
            assertThat(hidden.items()).allSatisfy(row -> assertThat(row.sources()).isEmpty());
            assertThat(executedSql).noneMatch(sql -> sql.startsWith("WITH visible_items"));
            tx.setRollbackOnly();
        });
    }

    private static void seedOriginalProductSources() {
        jdbc.update("INSERT INTO sales_order_items VALUES (?,'SO-SOURCE-A',2),(?,'SO-SOURCE-B',3)",
                id("sale-a"), id("sale-b"));
        jdbc.update("""
                INSERT INTO production_material_analysis_items
                    (id,analysis_id,goods_id,source_type,sales_order_item_id,requested_qty)
                VALUES (?, ?, ?, 'SALES_ORDER_ITEM', ?, 100), (?, ?, ?, 'SALES_ORDER_ITEM', ?, 200)
                """, id("origin-a"), id("analysis"), id("goods-1"), id("sale-a"),
                id("origin-b"), id("analysis"), id("goods-2"), id("sale-b"));
        jdbc.update("INSERT INTO production_material_analysis_materials VALUES (?,?,?),(?,?,?)",
                id("origin-material-a"), id("analysis"), id("origin-a"),
                id("origin-material-b"), id("analysis"), id("origin-b"));
        jdbc.update("UPDATE preplan_subcontract_make_tasks SET analysis_material_id=? WHERE id=?",
                id("origin-material-a"), id("task-125"));
        jdbc.update("UPDATE production_material_analysis_items SET requested_qty=4 WHERE id=?", id("item-125"));
        jdbc.update("""
                INSERT INTO subcontract_application_items(id,application_id,goods_id,qty)
                VALUES (?,?,?,10)
                """, id("doc-item-1"), id("document-1"), id("goods-125"));
        jdbc.update("""
                INSERT INTO preplan_supply_actions
                    (id,route,goods_id,public_surplus_qty,public_surplus_external_item_id)
                VALUES (?,'SUBCONTRACT',?,2,?)
                """, id("source-action"), id("goods-125"), id("doc-item-1"));
        jdbc.update("""
                INSERT INTO preplan_supply_action_allocations
                    (id,external_item_id,action_id,analysis_id,analysis_material_id,allocated_qty)
                VALUES (?,?,?,?,?,3),(?,?,?,?,?,5)
                """, id("source-alloc-a"), id("doc-item-1"), id("source-action"), id("analysis"), id("origin-material-a"),
                id("source-alloc-b"), id("doc-item-1"), id("source-action"), id("analysis"), id("origin-material-b"));
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
            return String.join("\n", NativeQueryResults.typedRows(query,String.class));
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
            jdbc.update("INSERT INTO preplan_supply_actions(id,created_at,external_document_type,route) VALUES (?,TIMESTAMPTZ '2026-09-01 16:30:00+00','SUBCONTRACT_MAKE_TASK','SUBCONTRACT'),(?,TIMESTAMPTZ '2026-09-06 00:00:00+00','SUBCONTRACT_APPLICATION','SUBCONTRACT'),(?,TIMESTAMPTZ '2026-09-03 08:00:00+00','SUBCONTRACT_APPLICATION','SUBCONTRACT')",
                    id("issue-original"), id("issue-after-production"), id("issue-direct"));
            jdbc.update("UPDATE preplan_subcontract_make_tasks SET supply_action_id=? WHERE id=?",id("issue-original"),id("task-1"));
            jdbc.update("INSERT INTO preplan_subcontract_make_task_batches VALUES(?,?,?)",UUID.randomUUID(),id("doc-item-1"),id("task-1"));
            jdbc.update("INSERT INTO preplan_supply_action_allocations(id,external_item_id,action_id) VALUES(?,?,?),(?,?,?)",UUID.randomUUID(),id("doc-item-1"),id("issue-after-production"),UUID.randomUUID(),id("doc-item-2"),id("issue-direct"));
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

    /**
     * ADR-103 路线 B: 只有一个子层物料的委外件, 子件仓里一件都没有时申请行锁住 (不能生成委外订货单,
     * 阶段 WAITING_COMPONENT_STOCK, 留在待处理段照计红数); 子件在作业叶仓有货 (数量不限) 即解锁
     * (阶段 COMPONENT_STOCK_READY, 行带子件可动用量); 线边仓的货不算; 普通委外件 (无 BOM) 不受影响.
     * 红黄徽章、分段计数与列表行数用同一片段 SQL, 这里逐个对账.
     */
    @Test void soleComponentApplicationIsLockedUntilTheComponentReachesAnOperationalWarehouse() {
        when(current.get()).thenReturn(Optional.of(new AuthUser(UUID.randomUUID(), employeeId, "decomposer",
                Set.of(), Set.of("subcontract_application:view", "subcontract_order:create", "subcontract_order:decompose"), false, true, false)));
        transactions.executeWithoutResult(tx -> {
            // 委外件 sole-parent 的活动 BOM 只有一条边 → 叶子子件 sole-child; 申请 APP-1 的明细就是这个委外件.
            jdbc.update("INSERT INTO goods(id, code, name) VALUES (?,?,?),(?,?,?)",
                    id("sole-parent"), "SOLE-P", "Sole parent", id("sole-child"), "SOLE-C", "Sole child");
            jdbc.update("INSERT INTO goods_bom_items(id, goods_id, component_goods_id, color_id, qty) VALUES (?,?,?,NULL,2)",
                    UUID.randomUUID(), id("sole-parent"), id("sole-child"));
            jdbc.update("INSERT INTO subcontract_application_items(id, application_id, goods_id, color_id, qty) VALUES (?,?,?,NULL,10),(?,?,?,NULL,10),(?,?,?,NULL,10)",
                    id("doc-item-1"), id("document-1"), id("sole-parent"),
                    id("doc-item-2"), id("document-2"), id("goods-1"),
                    id("doc-item-3"), id("document-3"), id("goods-1"));
            jdbc.update("INSERT INTO warehouses(id, name, is_line_side) VALUES (?,?,false),(?,?,true)",
                    id("wh-main"), "Main", id("wh-line-side"), "Line side");

            // 1) 子件一件都没有 → 锁: 不能下单, 阶段 WAITING_COMPONENT_STOCK; 但它**留在待处理段、照计红数**
            //    (2026-09-22 用户实机纠偏「刚下单的都是待处理」, 与路线 A 前置自制合成行同款), 不进「进行中」.
            var locked = applicationRow("APP-1");
            assertThat(locked.canCreateOrder()).isFalse();
            assertThat(locked.displayStage()).isEqualTo("WAITING_COMPONENT_STOCK");
            assertThat(locked.componentAvailableQty()).isNotNull().isEqualByComparingTo("0");
            var waitingOrder = service.query("SUBCONTRACT", "WAITING_ORDER", "", "", null, null, 1, 100);
            assertThat(waitingOrder.total()).isEqualTo(128);
            assertThat(waitingOrder.items()).extracting(FulfillmentTaskRow::actionDocNo).contains("APP-1");
            assertThat(waitingOrder.summary().statusCounts())
                    .containsEntry("WAITING_ORDER", 128L)
                    .containsEntry("WAITING_COMPONENT_STOCK", 1L)
                    .containsEntry("IN_PROGRESS", 0L);
            assertThat(service.query("SUBCONTRACT", "IN_PROGRESS", "", "", null, null, 1, 100).items())
                    .extracting(FulfillmentTaskRow::actionDocNo).doesNotContain("APP-1");
            assertThat(service.countPending("SUBCONTRACT")).isEqualTo(128L);
            assertThat(service.countInProgress("SUBCONTRACT")).isEqualTo(0L);

            // 2) 线边仓里的子件不算「仓里有货」(与出仓草稿选仓同口径), 仍然锁.
            jdbc.update("INSERT INTO stock_balances(id, warehouse_id, goods_id, color_id, qty) VALUES (?,?,?,NULL,50)",
                    UUID.randomUUID(), id("wh-line-side"), id("sole-child"));
            assertThat(applicationRow("APP-1").displayStage()).isEqualTo("WAITING_COMPONENT_STOCK");
            assertThat(service.countPending("SUBCONTRACT")).isEqualTo(128L);

            // 3) 作业叶仓入库了 (不管多少) → 解锁: 可下单, 阶段 COMPONENT_STOCK_READY, 行带子件可动用量.
            jdbc.update("INSERT INTO stock_balances(id, warehouse_id, goods_id, color_id, qty) VALUES (?,?,?,NULL,5)",
                    UUID.randomUUID(), id("wh-main"), id("sole-child"));
            var ready = applicationRow("APP-1");
            assertThat(ready.canCreateOrder()).isTrue();
            assertThat(ready.displayStage()).isEqualTo("COMPONENT_STOCK_READY");
            assertThat(ready.componentAvailableQty()).isEqualByComparingTo("5");
            var unlocked = service.query("SUBCONTRACT", "WAITING_ORDER", "", "", null, null, 1, 100);
            assertThat(unlocked.total()).isEqualTo(128);
            assertThat(unlocked.summary().statusCounts())
                    .containsEntry("WAITING_ORDER", 128L)
                    .containsEntry("WAITING_COMPONENT_STOCK", 0L)
                    .containsEntry("IN_PROGRESS", 0L);
            assertThat(service.countPending("SUBCONTRACT")).isEqualTo(128L);
            assertThat(service.countInProgress("SUBCONTRACT")).isEqualTo(0L);

            // 4) 普通委外件 (无 BOM) 的申请行全程不受影响: 阶段仍是 WAITING_ORDER, 没有子件可动用量.
            var plain = applicationRow("APP-2");
            assertThat(plain.canCreateOrder()).isTrue();
            assertThat(plain.displayStage()).isEqualTo("WAITING_ORDER");
            assertThat(plain.componentAvailableQty()).isNull();
            tx.setRollbackOnly();
        });
    }

    @Test void overdueBatchWithinToleranceIsNeutralAndNoLongerCountsAsPendingDecision() {
        when(current.get()).thenReturn(Optional.of(new AuthUser(UUID.randomUUID(), employeeId, "orders",
                Set.of(), Set.of("subcontract_application:view", "subcontract_order:view"), false, true, false)));
        transactions.executeWithoutResult(tx -> {
            jdbc.update("""
                    UPDATE workbench_documents SET action_doc_type='SUBCONTRACT_ORDER',
                        task_status='FINANCE_APPROVED', action_doc_status='1'
                    WHERE action_doc_id=?
                    """, id("document-1"));
            jdbc.update("""
                    INSERT INTO subcontract_short_delivery_cases
                        (id,order_id,order_item_id,status,severity,expected_complete_by)
                    VALUES (?,?,?,'WAITING_MORE','BELOW_FLOOR',CURRENT_DATE-1)
                    """, id("overdue-case"), id("document-1"), id("doc-item-1"));
            assertThat(applicationRow("APP-1").displayStage()).isEqualTo("SHORT_DELIVERY");
            assertThat(service.countPending("SUBCONTRACT")).isEqualTo(128L);

            jdbc.update("UPDATE subcontract_short_delivery_cases SET severity='WITHIN_TOLERANCE' WHERE id=?",
                    id("overdue-case"));
            assertThat(applicationRow("APP-1").displayStage()).isEqualTo("TOLERANT_SHORT");
            assertThat(service.countPending("SUBCONTRACT")).isEqualTo(127L);
            assertThat(jdbc.queryForObject("SELECT status FROM subcontract_short_delivery_cases WHERE id=?",
                    String.class, id("overdue-case"))).isEqualTo("WAITING_MORE");
            tx.setRollbackOnly();
        });
    }

    private FulfillmentTaskRow applicationRow(String docNo) {
        var page = service.query("SUBCONTRACT", "", "", "", null, null, 1, 10,
                new FulfillmentWorkbenchTableQuery("docNo", "asc", Map.of("docNo", docNo), null, null, null, null));
        assertThat(page.items()).hasSize(1);
        return page.items().getFirst();
    }

    private static UUID id(String key) {
        return jdbc.queryForObject("SELECT md5(?)::uuid",UUID.class,key);
    }

    private static String countPlan() {
        return String.join("\n", jdbc.queryForList("EXPLAIN SELECT count(*) FROM preplan_subcontract_make_tasks "
                + "WHERE status='ACTIVE' AND notified_qty<required_qty", String.class));
    }
}
