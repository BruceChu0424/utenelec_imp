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
import org.postgresql.util.PSQLException;
import org.springframework.jdbc.core.JdbcTemplate;
import org.springframework.jdbc.datasource.DataSourceTransactionManager;
import org.springframework.jdbc.datasource.DriverManagerDataSource;
import org.springframework.orm.jpa.LocalContainerEntityManagerFactoryBean;
import org.springframework.orm.jpa.vendor.HibernateJpaVendorAdapter;
import org.springframework.transaction.support.TransactionTemplate;
import org.testcontainers.containers.PostgreSQLContainer;

import java.lang.reflect.InvocationTargetException;
import java.lang.reflect.Method;
import java.math.BigDecimal;
import java.time.LocalDate;
import java.util.List;
import java.util.Properties;
import java.util.UUID;

import static org.assertj.core.api.Assertions.assertThat;
import static org.assertj.core.api.Assertions.assertThatThrownBy;
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
                mock(ProductionDocumentAccessPolicy.class),
                mock(com.uten.imp.security.OwnerVisibility.class),
                mock(com.uten.imp.application.port.SubcontractPreparationPort.class),
                mock(com.uten.imp.features.notice.ChainNoticeService.class),
                mock(com.uten.imp.features.production.analysis.PreplanStockEntitlementService.class),
                new MaterialAnalysisFlowStageService(entityManager),
                com.uten.imp.support.FulfillmentMutationLockTestSupport.locks(),
                org.mockito.Mockito.mock(com.uten.imp.application.port.ProductionMutationFootprintPort.class));
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

        // The maximum admitted batch repeats the same goods with independent
        // source UUIDs and different conversion rates. Exercise real Hibernate
        // parameter binding and PostgreSQL recursion, not just SQL text.
        EntityManager observer = mock(EntityManager.class);
        org.mockito.Mockito.when(observer.createNativeQuery(org.mockito.ArgumentMatchers.anyString()))
                .thenAnswer(call -> entityManager.createNativeQuery(call.getArgument(0)));
        List<MaterialAnalysisService.SourceLine> batch = java.util.stream.IntStream.range(0, 500)
                .mapToObj(index -> sourceLine(UUID.randomUUID(), finishedGoodsId, unitId,
                        BigDecimal.valueOf(index + 1), BigDecimal.ONE)).toList();
        var snapshots = new MaterialAnalysisBomSnapshotReader(observer).read(batch);
        org.mockito.Mockito.verify(observer, org.mockito.Mockito.times(2))
                .createNativeQuery(org.mockito.ArgumentMatchers.anyString());
        assertThat(snapshots).hasSize(500);
        for (int index = 0; index < batch.size(); index++) {
            assertThat(snapshots.get(batch.get(index).analysisItemId())).hasSize(2);
            Object[] nested = snapshots.get(batch.get(index).analysisItemId()).get(1);
            assertThat((UUID) nested[24]).isEqualTo(batch.get(index).analysisItemId());
            assertThat((BigDecimal) nested[10]).isEqualByComparingTo(BigDecimal.valueOf(6L * (index + 1)));
        }
        if ("true".equalsIgnoreCase(System.getenv("UTEN_RUN_PRODUCTION_STRESS"))) {
            measureSourceReadModes(batch);
        }
    }

    /** Real PostgreSQL comparison of the previous per-source read mode and the batched mode. */
    private static void measureSourceReadModes(List<MaterialAnalysisService.SourceLine> sources) {
        try {
            var output = java.nio.file.Path.of(System.getProperty("uten.build.directory", "target"),
                    "bom-read-modes.jsonl");
            java.nio.file.Files.createDirectories(output.toAbsolutePath().getParent());
            var json = new com.fasterxml.jackson.databind.ObjectMapper();
            for (int size : List.of(100, 500)) {
                var batch = sources.subList(0, size);
                var expected = new MaterialAnalysisBomSnapshotReader(entityManager).read(batch);
                for (int sample = 0; sample < 5; sample++) {
                    for (String mode : sample % 2 == 0
                            ? List.of("PER_SOURCE", "BATCH") : List.of("BATCH", "PER_SOURCE")) {
                        EntityManager observed = mock(EntityManager.class);
                        var calls = new java.util.concurrent.atomic.AtomicInteger();
                        org.mockito.Mockito.when(observed.createNativeQuery(org.mockito.ArgumentMatchers.anyString()))
                                .thenAnswer(call -> { calls.incrementAndGet(); return entityManager.createNativeQuery(call.getArgument(0)); });
                        long started = System.nanoTime();
                        var reader = new MaterialAnalysisBomSnapshotReader(observed);
                        java.util.Map<UUID, List<Object[]>> actual = new java.util.LinkedHashMap<>();
                        if ("BATCH".equals(mode)) actual.putAll(reader.read(batch));
                        else for (var source : batch) actual.putAll(reader.read(List.of(source)));
                        double elapsed = (System.nanoTime() - started) / 1_000_000.0;
                        assertThat(actual.keySet()).containsExactlyInAnyOrderElementsOf(expected.keySet());
                        for (UUID source : expected.keySet()) {
                            for (int row = 0; row < expected.get(source).size(); row++) {
                                org.junit.jupiter.api.Assertions.assertArrayEquals(
                                        expected.get(source).get(row), actual.get(source).get(row));
                            }
                        }
                        assertThat(calls.get()).isEqualTo("BATCH".equals(mode) ? 2 : 2 * size);
                        java.nio.file.Files.writeString(output, json.writeValueAsString(java.util.Map.of(
                                "sources", size, "mode", mode, "sample", sample, "queryCalls", calls.get(),
                                "elapsedMillis", elapsed, "rows", size * 2)) + System.lineSeparator(),
                                java.nio.file.StandardOpenOption.CREATE, java.nio.file.StandardOpenOption.APPEND);
                    }
                }
            }
        } catch (java.io.IOException error) {
            throw new AssertionError(error);
        }
    }

    @Test
    void directMakeGuardRequiresExactPlanItemAndAnalysisItemLineage() {
        UUID employeeId = jdbc.queryForObject(
                "SELECT id FROM employees ORDER BY id LIMIT 1", UUID.class);
        UUID unitId = UUID.randomUUID();
        UUID productId = UUID.randomUUID();
        UUID otherProductId = UUID.randomUUID();
        UUID warehouseId = UUID.randomUUID();
        UUID analysisId = UUID.randomUUID();
        UUID analysisItemId = UUID.randomUUID();
        UUID planId = UUID.randomUUID();
        UUID planItemId = UUID.randomUUID();
        UUID packageId = UUID.randomUUID();
        String planNo = "SJ20260829000001";
        String productNo = "SJ20260829000001-001";

        jdbc.update("INSERT INTO units(id,code,name) VALUES(?,?,?)",
                unitId, "LINEAGE-U-" + unitId, "piece");
        insertGoods(productId, unitId, "LINEAGE-FG-");
        insertGoods(otherProductId, unitId, "LINEAGE-OTHER-");
        jdbc.update("INSERT INTO warehouses(id,code,name,status) VALUES(?,?,?,'使用')",
                warehouseId, "LINEAGE-W-" + warehouseId, "lineage warehouse");
        jdbc.update("""
                INSERT INTO production_material_analyses(
                    id, warehouse_id, status, fingerprint,
                    initial_idempotency_key, maker_id)
                VALUES (?, ?, 'ACTIVE', ?, ?, ?)
                """, analysisId, warehouseId, "a".repeat(64),
                "lineage-analysis-" + analysisId, employeeId);
        jdbc.update("""
                INSERT INTO production_material_analysis_items(
                    id, analysis_id, source_type, goods_id, unit_id,
                    source_ref, source_reason, requested_qty)
                VALUES (?, ?, 'OTHER', ?, ?, ?, 'V426 lineage fixture', 10)
                """, analysisItemId, analysisId, productId, unitId,
                "LINEAGE-" + analysisItemId);
        jdbc.update("""
                INSERT INTO production_plans(
                    id, bill_no, bill_date, status, maker_id)
                VALUES (?, ?, DATE '2026-08-29', 1, ?)
                """, planId, planNo, employeeId);
        jdbc.update("""
                INSERT INTO production_plan_items(
                    id, bill_no, bill_date, plan_id, product_no,
                    goods_id, unit_id, unit_rate, qty)
                VALUES (?, ?, DATE '2026-08-29', ?, ?, ?, ?, 1, 10)
                """, planItemId, planNo, planId,
                productNo, productId, unitId);
        jdbc.update("""
                UPDATE production_plans
                SET material_analysis_id = ?, material_analysis_item_id = ?
                WHERE id = ?
                """, analysisId, analysisItemId, planId);
        String insertPackage = """
                INSERT INTO production_planning_packages(
                    id, plan_id, warehouse_id, idempotency_key,
                    request_hash, preview_fingerprint, status,
                    execution_model_version)
                VALUES (?, ?, ?, ?, ?, ?, 'CONFIRMED', 1)
                """;

        String insertSegment = """
                INSERT INTO production_execution_segments(
                    id, package_id, plan_id, source_plan_item_id,
                    segment_no, segment_code, client_segment_key,
                    product_goods_id, product_unit_id, product_unit_rate,
                    planned_qty, status, bom_fingerprint, idempotency_key,
                    material_requirement_mode, zero_material_reason,
                    zero_material_analysis_id)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, 1,
                        10, 'READY', ?, ?, 'ZERO_MATERIAL',
                        'DIRECT_MAKE', ?)
                """;
        UUID validSegmentId = UUID.randomUUID();
        transaction.executeWithoutResult(ignored -> {
            jdbc.update(insertPackage,
                    packageId, planId, warehouseId,
                    "lineage-package-" + packageId,
                    "b".repeat(64), "c".repeat(64));
            jdbc.update(insertSegment,
                    validSegmentId, packageId, planId, planItemId, 1,
                    segmentCode(validSegmentId),
                    "lineage-valid-" + validSegmentId,
                    productId, unitId, "d".repeat(64),
                    "lineage-segment-" + validSegmentId, analysisId);
        });

        assertThat(jdbc.queryForObject(
                "SELECT COUNT(*) FROM production_execution_segments WHERE id = ?",
                Long.class, validSegmentId)).isEqualTo(1L);

        UUID mismatchedSegmentId = UUID.randomUUID();
        assertThatThrownBy(() -> jdbc.update(insertSegment,
                mismatchedSegmentId, packageId, planId, planItemId, 2,
                segmentCode(mismatchedSegmentId),
                "lineage-bad-" + mismatchedSegmentId,
                otherProductId, unitId, "e".repeat(64),
                "lineage-segment-" + mismatchedSegmentId, analysisId))
                .hasMessageContaining(
                        "zero-material evidence does not match the plan/BOM facts")
                .satisfies(MaterialAnalysisBomTreeHibernatePostgresTest::assertCheckViolation);

        String insertNullReasonSegment = """
                INSERT INTO production_execution_segments(
                    id, package_id, plan_id, source_plan_item_id,
                    segment_no, segment_code, client_segment_key,
                    product_goods_id, product_unit_id, product_unit_rate,
                    planned_qty, status, bom_fingerprint, idempotency_key,
                    material_requirement_mode, zero_material_reason,
                    zero_material_analysis_id)
                VALUES (?, ?, ?, ?, 3, ?, ?, ?, ?, 1,
                        10, 'READY', ?, ?, 'ZERO_MATERIAL', NULL, NULL)
                """;
        UUID nullReasonSegmentId = UUID.randomUUID();
        assertThatThrownBy(() -> jdbc.update(insertNullReasonSegment,
                nullReasonSegmentId, packageId, planId, planItemId,
                segmentCode(nullReasonSegmentId),
                "lineage-null-reason-" + nullReasonSegmentId,
                productId, unitId, "f".repeat(64),
                "lineage-segment-" + nullReasonSegmentId))
                .hasMessageContaining(
                        "zero-material evidence does not match the plan/BOM facts")
                .satisfies(MaterialAnalysisBomTreeHibernatePostgresTest::assertCheckViolation);
    }

    private static String segmentCode(UUID id) {
        return "ZX%08d".formatted(
                Math.floorMod(id.hashCode(), 99_999_999) + 1);
    }

    private static void assertCheckViolation(Throwable error) {
        Throwable root = error;
        while (root.getCause() != null) {
            root = root.getCause();
        }
        assertThat(root).isInstanceOf(PSQLException.class);
        assertThat(((PSQLException) root).getSQLState()).isEqualTo("23514");
    }

    private static void insertGoods(UUID goodsId, UUID unitId, String codePrefix) {
        jdbc.update("INSERT INTO goods(id,code,name,unit_id,code_sequence) "
                        + "VALUES(?,?,?,?,(SELECT COALESCE(MAX(code_sequence),0)+1 FROM goods))",
                goodsId, codePrefix + goodsId, codePrefix + "test", unitId);
    }

    private static MaterialAnalysisService.SourceLine sourceLine(
            UUID analysisItemId, UUID goodsId, UUID unitId) {
        return sourceLine(analysisItemId, goodsId, unitId, BigDecimal.ONE, BigDecimal.ONE);
    }

    private static MaterialAnalysisService.SourceLine sourceLine(
            UUID analysisItemId, UUID goodsId, UUID unitId,
            BigDecimal rate, BigDecimal requested) {
        return MaterialAnalysisService.SourceLine.from(new Object[]{
                analysisItemId, "OTHER", null, null, null, null,
                LocalDate.of(2026, 8, 20), null,
                goodsId, "FG-01", "Finished good", null, null, null,
                unitId, "piece", rate, requested, BigDecimal.ZERO,
                BigDecimal.ZERO, BigDecimal.ONE,
                BigDecimal.ZERO, BigDecimal.ZERO, BigDecimal.ZERO, BigDecimal.ZERO,
                BigDecimal.ZERO, BigDecimal.ZERO, BigDecimal.ZERO, null, false,
                false, false, false, "REQ-BOM-HIBERNATE-001",
                "Hibernate recursive BOM regression", 1, BigDecimal.ZERO,
                BigDecimal.ZERO, BigDecimal.ZERO, BigDecimal.ZERO,
                BigDecimal.ZERO, null, null,
                // V294：SourceLine 新增 orderFinanceConfirmed（row[43]），
                // 测试夹具默认财务已确认，不改变既有用例语义。
                true
        });
    }

    @SuppressWarnings("unchecked")
    private static List<MaterialAnalysisService.BomNode> loadBomTree(
            MaterialAnalysisService service,
            MaterialAnalysisService.SourceLine source) {
        try {
            Method method = MaterialAnalysisService.class.getDeclaredMethod(
                    "loadBomTrees", List.class);
            method.setAccessible(true);
            return (List<MaterialAnalysisService.BomNode>) method.invoke(service, List.of(source));
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
