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
import org.springframework.orm.jpa.LocalContainerEntityManagerFactoryBean;
import org.springframework.orm.jpa.vendor.HibernateJpaVendorAdapter;
import org.testcontainers.containers.PostgreSQLContainer;

import java.util.Properties;
import java.util.UUID;

import static org.assertj.core.api.Assertions.assertThat;
import static org.junit.jupiter.api.Assertions.assertNotNull;
import static org.mockito.Mockito.mock;

/** PostgreSQL projection evidence for the product-level child-material flag. */
@EnabledIfEnvironmentVariable(named = "UTEN_RUN_DB_TESTS", matches = "(?i)true")
class MaterialAnalysisProductChildrenProjectionPostgresTest {

    private static final PostgreSQLContainer<?> POSTGRES =
            new PostgreSQLContainer<>("postgres:16-alpine")
                    .withDatabaseName("uten_imp")
                    .withUsername("uten")
                    .withPassword("uten");

    private static JdbcTemplate jdbc;
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
                mock(ProductionDocumentAccessPolicy.class));

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
}
