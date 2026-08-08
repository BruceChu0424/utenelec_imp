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

import java.lang.reflect.InvocationTargetException;
import java.lang.reflect.Method;
import java.math.BigDecimal;
import java.time.LocalDate;
import java.util.List;
import java.util.Properties;
import java.util.UUID;

import static org.assertj.core.api.Assertions.assertThat;
import static org.junit.jupiter.api.Assertions.assertNotNull;
import static org.mockito.Mockito.mock;

/**
 * Real Hibernate/PostgreSQL coverage for the recursive BOM preview query.
 *
 * <p>A JDBC-only test cannot catch Hibernate interpreting PostgreSQL's array
 * slice colon as the start of a named parameter. Keep this test on the real
 * EntityManager path and include a grandchild so parent-node derivation is
 * executed, not merely parsed.</p>
 */
@EnabledIfEnvironmentVariable(named = "UTEN_RUN_DB_TESTS", matches = "(?i)true")
class MaterialAnalysisBomTreeHibernatePostgresTest {

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
    void twoLevelBomPreviewDerivesParentPathThroughHibernate() {
        UUID unitId = UUID.randomUUID();
        UUID finishedGoodsId = UUID.randomUUID();
        UUID assemblyId = UUID.randomUUID();
        UUID rawMaterialId = UUID.randomUUID();
        UUID assemblyBomItemId = UUID.randomUUID();
        UUID rawMaterialBomItemId = UUID.randomUUID();
        UUID analysisItemId = UUID.randomUUID();

        jdbc.update("INSERT INTO units(id,code,name) VALUES(?,?,?)",
                unitId, "BOM-U-" + unitId, "piece");
        insertGoods(finishedGoodsId, unitId, "BOM-FG-");
        insertGoods(assemblyId, unitId, "BOM-SA-");
        insertGoods(rawMaterialId, unitId, "BOM-RM-");
        jdbc.update("""
                        INSERT INTO goods_bom_items(
                            id,goods_id,component_goods_id,qty,sort_order
                        ) VALUES(?,?,?,?,?)
                        """,
                assemblyBomItemId, finishedGoodsId, assemblyId,
                new BigDecimal("2"), 1);
        jdbc.update("""
                        INSERT INTO goods_bom_items(
                            id,goods_id,component_goods_id,qty,sort_order
                        ) VALUES(?,?,?,?,?)
                        """,
                rawMaterialBomItemId, assemblyId, rawMaterialId,
                new BigDecimal("3"), 1);

        MaterialAnalysisService service = new MaterialAnalysisService(
                entityManager,
                mock(SecurityContextCurrentUser.class),
                mock(TxSessionVars.class),
                mock(ProductionDocumentAccessPolicy.class));
        MaterialAnalysisService.SourceLine source = sourceLine(
                analysisItemId, finishedGoodsId, unitId);

        List<MaterialAnalysisService.BomNode> nodes = loadBomTree(service, source);

        assertThat(nodes).hasSize(2);
        MaterialAnalysisService.BomNode direct = nodes.stream()
                .filter(node -> node.depth() == 1)
                .findFirst().orElseThrow();
        MaterialAnalysisService.BomNode grandchild = nodes.stream()
                .filter(node -> node.depth() == 2)
                .findFirst().orElseThrow();
        assertThat(direct.bomItemId()).isEqualTo(assemblyBomItemId);
        assertThat(grandchild.bomItemId()).isEqualTo(rawMaterialBomItemId);
        assertThat(grandchild.parentNodeKey()).isEqualTo(direct.nodeKey());
        assertThat(grandchild.perProductQty()).isEqualByComparingTo("6");
    }

    private static void insertGoods(UUID goodsId, UUID unitId, String codePrefix) {
        jdbc.update("INSERT INTO goods(id,code,name,unit_id) VALUES(?,?,?,?)",
                goodsId, codePrefix + goodsId, codePrefix + "test", unitId);
    }

    private static MaterialAnalysisService.SourceLine sourceLine(
            UUID analysisItemId, UUID goodsId, UUID unitId) {
        return MaterialAnalysisService.SourceLine.from(new Object[]{
                analysisItemId, "OTHER", null, null, null, null,
                LocalDate.of(2026, 8, 20), null,
                goodsId, "FG-01", "Finished good", null, null, null,
                unitId, "piece", BigDecimal.ONE, BigDecimal.ONE, BigDecimal.ZERO,
                BigDecimal.ZERO, "BOM_REQUIRED", true, BigDecimal.ONE,
                BigDecimal.ZERO, BigDecimal.ZERO, BigDecimal.ZERO, BigDecimal.ZERO,
                BigDecimal.ZERO, BigDecimal.ZERO, BigDecimal.ZERO, null, false,
                false, false, false, "REQ-BOM-HIBERNATE-001",
                "Hibernate recursive BOM regression", 1, BigDecimal.ZERO,
                BigDecimal.ZERO
        });
    }

    @SuppressWarnings("unchecked")
    private static List<MaterialAnalysisService.BomNode> loadBomTree(
            MaterialAnalysisService service,
            MaterialAnalysisService.SourceLine source) {
        try {
            Method method = MaterialAnalysisService.class.getDeclaredMethod(
                    "loadBomTree", MaterialAnalysisService.SourceLine.class);
            method.setAccessible(true);
            return (List<MaterialAnalysisService.BomNode>) method.invoke(service, source);
        } catch (InvocationTargetException error) {
            if (error.getCause() instanceof RuntimeException runtime) {
                throw runtime;
            }
            throw new AssertionError(error.getCause());
        } catch (ReflectiveOperationException error) {
            throw new AssertionError(error);
        }
    }
}
