package com.uten.imp.features.production.analysis;

import com.uten.imp.features.production.ProductionDocumentAccessPolicy;
import com.uten.imp.security.SecurityContextCurrentUser;
import com.uten.imp.security.TxSessionVars;
import jakarta.persistence.EntityManager;
import jakarta.persistence.EntityManagerFactory;
import org.flywaydb.core.Flyway;
import org.junit.jupiter.api.AfterAll;
import org.junit.jupiter.api.BeforeAll;
import org.junit.jupiter.api.Test;
import org.junit.jupiter.api.condition.EnabledIfEnvironmentVariable;
import org.springframework.jdbc.core.JdbcTemplate;
import org.springframework.jdbc.datasource.DriverManagerDataSource;
import org.springframework.jdbc.datasource.DataSourceTransactionManager;
import org.springframework.orm.jpa.LocalContainerEntityManagerFactoryBean;
import org.springframework.orm.jpa.vendor.HibernateJpaVendorAdapter;
import org.springframework.transaction.support.TransactionTemplate;
import org.testcontainers.containers.PostgreSQLContainer;

import java.math.BigDecimal;
import java.util.Properties;
import java.util.UUID;
import java.util.concurrent.atomic.AtomicInteger;

import static org.assertj.core.api.Assertions.assertThat;
import static org.junit.jupiter.api.Assertions.assertNotNull;
import static org.mockito.Mockito.mock;

/** PostgreSQL projection evidence for the product-level child-material flag. */
@EnabledIfEnvironmentVariable(named = "UTEN_RUN_DB_TESTS", matches = "(?i)true")
class MaterialAnalysisProductChildrenProjectionPostgresTest {

    private static final AtomicInteger PLAN_NO_SEQUENCE = new AtomicInteger();

    private static final PostgreSQLContainer<?> POSTGRES =
            new PostgreSQLContainer<>("postgres:16-alpine")
                    .withDatabaseName("uten_imp")
                    .withUsername("uten")
                    .withPassword("uten");

    private static JdbcTemplate jdbc;
    private static TransactionTemplate transaction;
    private static EntityManagerFactory entityManagerFactory;
    private static EntityManager entityManager;

    @BeforeAll
    static void migrateAndCreateHibernateHarness() {
        POSTGRES.start();
        Flyway.configure()
                .dataSource(
                        POSTGRES.getJdbcUrl(),
                        POSTGRES.getUsername(),
                        POSTGRES.getPassword())
                .locations("classpath:db/migration")
                .load()
                .migrate();

        DriverManagerDataSource dataSource = new DriverManagerDataSource(
                POSTGRES.getJdbcUrl(),
                POSTGRES.getUsername(),
                POSTGRES.getPassword());
        jdbc = new JdbcTemplate(dataSource);
        transaction = new TransactionTemplate(
                new DataSourceTransactionManager(dataSource));

        LocalContainerEntityManagerFactoryBean factory =
                new LocalContainerEntityManagerFactoryBean();
        factory.setDataSource(dataSource);
        factory.setJpaVendorAdapter(new HibernateJpaVendorAdapter());
        factory.setPackagesToScan("com.uten.imp.features.production.fulfillment");
        Properties properties = new Properties();
        properties.setProperty("hibernate.hbm2ddl.auto", "none");
        properties.setProperty("hibernate.show_sql", "false");
        properties.setProperty("hibernate.jdbc.time_zone", "UTC");
        factory.setJpaProperties(properties);
        factory.afterPropertiesSet();

        entityManagerFactory = factory.getObject();
        assertNotNull(entityManagerFactory);
        entityManager = entityManagerFactory.createEntityManager();
    }

    @AfterAll
    static void stopPostgres() {
        if (entityManager != null) {
            entityManager.close();
        }
        if (entityManagerFactory != null) {
            entityManagerFactory.close();
        }
        POSTGRES.stop();
    }

    @Test
    void detailProjectsFalseForLeafAndTrueForPersistedRecursiveTree() {
        UUID employeeId = jdbc.queryForObject(
                "SELECT id FROM employees ORDER BY id LIMIT 1", UUID.class);
        UUID unitId = UUID.randomUUID();
        UUID warehouseId = UUID.randomUUID();
        UUID leafGoodsId = UUID.randomUUID();
        UUID treeGoodsId = UUID.randomUUID();
        UUID childGoodsId = UUID.randomUUID();
        UUID grandchildGoodsId = UUID.randomUUID();

        jdbc.update("INSERT INTO units(id,code,name) VALUES(?,?,?)",
                unitId, "CHILD-FLAG-U-" + unitId, "piece");
        insertGoods(leafGoodsId, unitId, "CHILD-FLAG-LEAF-");
        insertGoods(treeGoodsId, unitId, "CHILD-FLAG-TREE-");
        insertGoods(childGoodsId, unitId, "CHILD-FLAG-CHILD-");
        insertGoods(grandchildGoodsId, unitId, "CHILD-FLAG-GRANDCHILD-");
        jdbc.update("INSERT INTO warehouses(id,code,name,status) VALUES(?,?,?,'使用')",
                warehouseId, "CHILD-FLAG-W-" + warehouseId,
                "child flag warehouse");

        AnalysisFixture leaf = insertAnalysis(
                employeeId, warehouseId, leafGoodsId, unitId, "leaf");
        AnalysisFixture tree = insertAnalysis(
                employeeId, warehouseId, treeGoodsId, unitId, "tree");
        insertMaterial(
                tree, childGoodsId, unitId, 1,
                "tree-child", null, "tree-child");
        insertMaterial(
                tree, grandchildGoodsId, unitId, 2,
                "tree-grandchild", "tree-child", "tree-child/tree-grandchild");

        MaterialAnalysisService service = new MaterialAnalysisService(
                entityManager,
                mock(SecurityContextCurrentUser.class),
                mock(TxSessionVars.class),
                mock(ProductionDocumentAccessPolicy.class),
                mock(com.uten.imp.application.port.SubcontractPreparationPort.class));

        MaterialAnalysisContracts.AnalysisView leafView =
                service.detailInternal(leaf.analysisId(), false);
        MaterialAnalysisContracts.AnalysisView treeView =
                service.detailInternal(tree.analysisId(), false);

        assertThat(leafView.flatMaterials()).isEmpty();
        assertThat(leafView.products()).singleElement().satisfies(product ->
                assertThat(product.hasProductionMaterialChildren()).isFalse());
        assertThat(treeView.flatMaterials()).hasSize(2);
        assertThat(treeView.products()).singleElement().satisfies(product ->
                assertThat(product.hasProductionMaterialChildren()).isTrue());
    }

    @Test
    void makeChildCompletesOnlyAfterEveryActivePlanItemIsFullyInbound() {
        UUID employeeId = jdbc.queryForObject(
                "SELECT id FROM employees ORDER BY id LIMIT 1", UUID.class);
        UUID userId = UUID.randomUUID();
        jdbc.update("""
                INSERT INTO users(
                    id, employee_id, login_account, password_hash, status)
                VALUES (?, ?, ?, 'test-only-hash', 'active')
                """, userId, employeeId, "plan-state-" + userId);
        UUID unitId = UUID.randomUUID();
        UUID warehouseId = UUID.randomUUID();
        UUID parentGoodsId = UUID.randomUUID();
        UUID childGoodsId = UUID.randomUUID();

        jdbc.update("INSERT INTO units(id,code,name) VALUES(?,?,?)",
                unitId, "PLAN-STATE-U-" + unitId, "piece");
        insertGoods(parentGoodsId, unitId, "PLAN-STATE-PARENT-");
        insertGoods(childGoodsId, unitId, "PLAN-STATE-CHILD-");
        jdbc.update("INSERT INTO warehouses(id,code,name,status) VALUES(?,?,?,'使用')",
                warehouseId, "PLAN-STATE-W-" + warehouseId,
                "plan state warehouse");

        MakeChildFixture analysis = insertMakeChildAnalysis(
                employeeId, userId, warehouseId,
                parentGoodsId, childGoodsId, unitId);

        PlanFixture cancelled = insertLinkedPlan(
                analysis, employeeId, userId, childGoodsId, unitId, "2");
        jdbc.update("UPDATE production_plans SET is_canceled=TRUE WHERE id=?",
                cancelled.planId());
        PlanFixture deleted = insertLinkedPlan(
                analysis, employeeId, userId, childGoodsId, unitId, "3");
        jdbc.update("UPDATE production_plans SET is_deleted=TRUE WHERE id=?",
                deleted.planId());

        PlanFixture first = insertLinkedPlan(
                analysis, employeeId, userId, childGoodsId, unitId, "4");
        jdbc.update("UPDATE production_plans SET status=1 WHERE id=?", first.planId());
        jdbc.update("UPDATE production_plan_items SET iqty=4 WHERE id=?",
                first.planItemId());

        PlanFixture second = insertLinkedPlan(
                analysis, employeeId, userId, childGoodsId, unitId, "6");
        jdbc.update("UPDATE production_plans SET status=1 WHERE id=?", second.planId());
        jdbc.update("UPDATE production_plan_items SET iqty=2 WHERE id=?",
                second.planItemId());
        insertReadySegment(
                analysis, second, warehouseId, childGoodsId, unitId);

        MaterialAnalysisService service = new MaterialAnalysisService(
                entityManager,
                mock(SecurityContextCurrentUser.class),
                mock(TxSessionVars.class),
                mock(ProductionDocumentAccessPolicy.class),
                mock(com.uten.imp.application.port.SubcontractPreparationPort.class));

        MaterialAnalysisContracts.ProductView partial = service
                .detailInternal(analysis.analysisId(), false)
                .products().stream()
                .filter(product -> product.analysisLineId()
                        .equals(analysis.childAnalysisItemId()))
                .findFirst()
                .orElseThrow();

        assertThat(partial.sourceType()).isEqualTo("MAKE_COMPONENT");
        assertThat(partial.parentAnalysisLineId())
                .isEqualTo(analysis.parentAnalysisItemId());
        assertThat(partial.parentGoodsName())
                .isEqualTo("PLAN-STATE-PARENT-test");
        assertThat(partial.planExecutionStatus()).isEqualTo("READY");
        assertThat(partial.planExecutionPlannedQty()).isEqualByComparingTo("10");
        assertThat(partial.planExecutionInboundQty()).isEqualByComparingTo("6");
        assertThat(partial.planExecutionProgressRatio())
                .isEqualByComparingTo("0.6000");

        jdbc.update("UPDATE production_plan_items SET iqty=6 WHERE id=?",
                second.planItemId());
        entityManager.clear();

        MaterialAnalysisContracts.ProductView completed = service
                .detailInternal(analysis.analysisId(), false)
                .products().stream()
                .filter(product -> product.analysisLineId()
                        .equals(analysis.childAnalysisItemId()))
                .findFirst()
                .orElseThrow();

        assertThat(completed.planExecutionStatus()).isEqualTo("COMPLETED");
        assertThat(completed.planExecutionPlannedQty()).isEqualByComparingTo("10");
        assertThat(completed.planExecutionInboundQty()).isEqualByComparingTo("10");
        assertThat(completed.planExecutionProgressRatio())
                .isEqualByComparingTo("1.0000");
        assertThat(completed.parentAnalysisLineId())
                .isEqualTo(analysis.parentAnalysisItemId());
        assertThat(completed.parentGoodsName())
                .isEqualTo("PLAN-STATE-PARENT-test");
    }

    private static AnalysisFixture insertAnalysis(
            UUID employeeId,
            UUID warehouseId,
            UUID goodsId,
            UUID unitId,
            String label) {
        UUID analysisId = UUID.randomUUID();
        UUID analysisItemId = UUID.randomUUID();
        jdbc.update("""
                INSERT INTO production_material_analyses(
                    id, warehouse_id, status, fingerprint,
                    initial_idempotency_key, maker_id)
                VALUES (?, ?, 'ACTIVE', ?, ?, ?)
                """, analysisId, warehouseId, "a".repeat(64),
                "child-flag-analysis-" + analysisId, employeeId);
        jdbc.update("""
                INSERT INTO production_material_analysis_items(
                    id, analysis_id, source_type, goods_id, unit_id,
                    source_ref, source_reason, requested_qty,
                    ready_now_qty, ready_by_date_qty,
                    ready_start_qty, ready_finish_qty, ready_ship_qty)
                VALUES (?, ?, 'OTHER', ?, ?, ?, ?, 10, 10, 10, 10, 10, 10)
                """, analysisItemId, analysisId, goodsId, unitId,
                "CHILD-FLAG-" + label + "-" + analysisItemId,
                "child material flag projection fixture");
        return new AnalysisFixture(analysisId, analysisItemId);
    }

    private static MakeChildFixture insertMakeChildAnalysis(
            UUID employeeId,
            UUID userId,
            UUID warehouseId,
            UUID parentGoodsId,
            UUID childGoodsId,
            UUID unitId) {
        UUID analysisId = UUID.randomUUID();
        UUID parentAnalysisItemId = UUID.randomUUID();
        UUID parentMaterialId = UUID.randomUUID();
        UUID childAnalysisItemId = UUID.randomUUID();
        jdbc.update("""
                INSERT INTO production_material_analyses(
                    id, warehouse_id, status, fingerprint,
                    initial_idempotency_key, maker_id,
                    created_by, updated_by)
                VALUES (?, ?, 'ACTIVE', ?, ?, ?, ?, ?)
                """, analysisId, warehouseId, "b".repeat(64),
                "plan-state-analysis-" + analysisId, employeeId, userId, userId);
        jdbc.update("""
                INSERT INTO production_material_analysis_items(
                    id, analysis_id, source_type, goods_id, unit_id,
                    source_ref, source_reason, requested_qty,
                    line_priority, created_by, updated_by)
                VALUES (?, ?, 'OTHER', ?, ?, ?, ?, 10, 1, ?, ?)
                """, parentAnalysisItemId, analysisId, parentGoodsId, unitId,
                "PLAN-STATE-PARENT-" + parentAnalysisItemId,
                "parent production demand", userId, userId);
        jdbc.update("""
                INSERT INTO production_material_analysis_materials(
                    id, analysis_id, analysis_item_id, node_key,
                    goods_id, unit_id, depth, path,
                    per_product_qty, required_qty, available_qty,
                    allocated_available_qty, shortage_qty, source_suggestion,
                    confirmed_route, route_reason, route_confirmed_by,
                    route_confirmed_at, created_by, updated_by)
                VALUES (?, ?, ?, ?, ?, ?, 1, ?,
                        1, 10, 0, 0, 10, 'MAKE',
                        'MAKE', NULL, ?, now(), ?, ?)
                """, parentMaterialId, analysisId, parentAnalysisItemId,
                "make-child-" + parentMaterialId, childGoodsId, unitId,
                "make-child-" + parentMaterialId, userId, userId, userId);
        jdbc.update("""
                INSERT INTO production_material_analysis_items(
                    id, analysis_id, source_type, goods_id, unit_id,
                    source_ref, source_reason, requested_qty,
                    line_priority, parent_analysis_material_id,
                    created_by, updated_by)
                VALUES (?, ?, 'MAKE_COMPONENT', ?, ?, ?, ?, 10, 2, ?, ?, ?)
                """, childAnalysisItemId, analysisId, childGoodsId, unitId,
                "PLAN-STATE-MAKE-" + childAnalysisItemId,
                "parent shortage delegated to make child", parentMaterialId,
                userId, userId);
        return new MakeChildFixture(
                analysisId, parentAnalysisItemId, childAnalysisItemId);
    }

    private static PlanFixture insertLinkedPlan(
            MakeChildFixture analysis,
            UUID employeeId,
            UUID userId,
            UUID goodsId,
            UUID unitId,
            String quantity) {
        UUID planId = UUID.randomUUID();
        UUID planItemId = UUID.randomUUID();
        String suffix = planId.toString().replace("-", "").substring(0, 16)
                .toUpperCase(java.util.Locale.ROOT);
        String billNo = "SJ20260830%06d".formatted(
                PLAN_NO_SEQUENCE.incrementAndGet());
        jdbc.update("""
                INSERT INTO production_plans(
                    id, bill_no, bill_date, status, maker_id,
                    created_by, updated_by)
                VALUES (?, ?, DATE '2026-08-30', 0, ?, ?, ?)
                """, planId, billNo, employeeId, userId, userId);
        jdbc.update("""
                INSERT INTO production_plan_items(
                    id, bill_no, bill_date, plan_id, line_no, product_no,
                    goods_id, unit_id, unit_rate, qty, iqty,
                    created_by, updated_by)
                VALUES (?, ?, DATE '2026-08-30', ?, 1, ?,
                        ?, ?, 1, ?, 0, ?, ?)
                """, planItemId, billNo, planId, "P-" + suffix,
                goodsId, unitId, new BigDecimal(quantity), userId, userId);
        jdbc.update("""
                UPDATE production_plans
                SET material_analysis_id=?, material_analysis_item_id=?
                WHERE id=?
                """, analysis.analysisId(), analysis.childAnalysisItemId(), planId);
        jdbc.update("""
                INSERT INTO production_material_analysis_plan_links(
                    id, analysis_id, analysis_item_id, plan_id,
                    submitted_qty, allocation_status, created_by)
                VALUES (?, ?, ?, ?, ?, 'SUBMITTED', ?)
                """, UUID.randomUUID(), analysis.analysisId(),
                analysis.childAnalysisItemId(), planId,
                new BigDecimal(quantity), userId);
        return new PlanFixture(planId, planItemId);
    }

    private static void insertReadySegment(
            MakeChildFixture analysis,
            PlanFixture plan,
            UUID warehouseId,
            UUID goodsId,
            UUID unitId) {
        transaction.executeWithoutResult(ignored -> {
            UUID packageId = UUID.randomUUID();
            UUID segmentId = UUID.randomUUID();
            jdbc.update("""
                    INSERT INTO production_planning_packages(
                        id, plan_id, warehouse_id, idempotency_key,
                        request_hash, preview_fingerprint, status,
                        execution_model_version)
                    VALUES (?, ?, ?, ?, ?, ?, 'CONFIRMED', 1)
                    """, packageId, plan.planId(), warehouseId,
                    "plan-state-package-" + packageId,
                    "c".repeat(64), "d".repeat(64));
            jdbc.update("""
                    INSERT INTO production_execution_segments(
                        id, package_id, plan_id, source_plan_item_id,
                        segment_no, segment_code, client_segment_key,
                        product_goods_id, product_unit_id, product_unit_rate,
                        planned_qty, status, bom_fingerprint, idempotency_key,
                        material_requirement_mode, zero_material_reason,
                        zero_material_analysis_id)
                    VALUES (?, ?, ?, ?, 1, ?, ?, ?, ?, 1,
                            6, 'READY', ?, ?,
                            'ZERO_MATERIAL', 'DIRECT_MAKE', ?)
                    """, segmentId, packageId, plan.planId(), plan.planItemId(),
                    canonicalSegmentCode(segmentId), "CLIENT-" + segmentId,
                    goodsId, unitId, "e".repeat(64),
                    "plan-state-segment-" + segmentId, analysis.analysisId());
        });
    }

    private static String canonicalSegmentCode(UUID segmentId) {
        return "ZX%08d".formatted(
                Math.floorMod(segmentId.hashCode(), 99_999_999) + 1);
    }

    private static void insertMaterial(
            AnalysisFixture analysis,
            UUID goodsId,
            UUID unitId,
            int depth,
            String nodeKey,
            String parentNodeKey,
            String path) {
        UUID materialId = UUID.randomUUID();
        jdbc.update("""
                INSERT INTO production_material_analysis_materials(
                    id, analysis_id, analysis_item_id, node_key,
                    parent_node_key, goods_id, unit_id, depth, path,
                    per_product_qty, required_qty, available_qty,
                    allocated_available_qty, shortage_qty, source_suggestion)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, 1, 10, 10, 10, 0, 'BUY')
                """, materialId, analysis.analysisId(), analysis.analysisItemId(),
                nodeKey, parentNodeKey, goodsId, unitId, depth, path);
    }

    private static void insertGoods(UUID goodsId, UUID unitId, String codePrefix) {
        jdbc.update("INSERT INTO goods(id,code,name,unit_id,code_sequence) "
                        + "VALUES(?,?,?,?,(SELECT COALESCE(MAX(code_sequence),0)+1 FROM goods))",
                goodsId, codePrefix + goodsId, codePrefix + "test", unitId);
    }

    private record AnalysisFixture(UUID analysisId, UUID analysisItemId) {
    }

    private record MakeChildFixture(
            UUID analysisId,
            UUID parentAnalysisItemId,
            UUID childAnalysisItemId) {
    }

    private record PlanFixture(UUID planId, UUID planItemId) {
    }
}
