package com.uten.imp.features.production.mrp;

import com.uten.imp.features.production.fulfillment.ProductionExecutionSegment;
import jakarta.persistence.EntityManager;
import jakarta.persistence.Query;
import org.junit.jupiter.api.Test;

import java.math.BigDecimal;
import java.time.LocalDate;
import java.util.Collections;
import java.util.List;
import java.util.UUID;

import static org.assertj.core.api.Assertions.assertThat;
import static org.assertj.core.api.Assertions.assertThatThrownBy;
import static org.mockito.ArgumentMatchers.any;
import static org.mockito.ArgumentMatchers.anyString;
import static org.mockito.ArgumentMatchers.argThat;
import static org.mockito.Mockito.mock;
import static org.mockito.Mockito.verify;
import static org.mockito.Mockito.when;

class ProductionExecutionPlanningServiceBomControlStageTest {

    @Test
    void onlyShippingPackagingStillCreatesAReadyZeroMaterialProductLine() {
        ProductIds product = ProductIds.create();
        UUID shippingPackaging = UUID.randomUUID();
        Harness harness = harness(
                Collections.singletonList(executionRow(
                        product, UUID.randomUUID(), shippingPackaging,
                        UUID.randomUUID(), "SHIP", true,
                        "PER_PACKAGE", new BigDecimal("12"))),
                List.of());

        ProductionExecutionPlanningService.Snapshot snapshot =
                harness.service().preview(UUID.randomUUID(), UUID.randomUUID());

        assertThat(snapshot.unresolvedZeroMaterialLineageIds()).isEmpty();
        assertThat(snapshot.productLines()).singleElement()
                .satisfies(line -> {
                    assertThat(line.materials()).isEmpty();
                    assertThat(line.zeroMaterialReason()).isEqualTo(
                            ProductionExecutionSegment
                                    .ZERO_MATERIAL_REASON_NO_PRODUCTION_HARD_GATE);
                });
        CompleteKitAllocator.Allocation allocation =
                harness.service().propose(snapshot);
        assertThat(allocation.segments()).singleElement().satisfies(segment -> {
            assertThat(segment.status())
                    .isEqualTo(ProductionExecutionSegment.STATUS_READY);
            assertThat(segment.plannedQty()).isEqualByComparingTo("10");
            assertThat(segment.materials()).isEmpty();
        });
        assertThat(snapshot.availability()).isEmpty();
        verify(harness.em()).createNativeQuery(argThat(sql ->
                sql.contains("b.control_stage")
                        && sql.contains("b.hard_gate")
                        && sql.contains("b.consumption_basis")
                        && sql.contains("b.basis_output_qty")
                        && sql.contains("b.allow_partial_package")));
    }

    @Test
    void missingShippingPackagingDoesNotBlockProductionReadiness() {
        ProductIds product = ProductIds.create();
        UUID productionMaterial = UUID.randomUUID();
        UUID shippingPackaging = UUID.randomUUID();
        Harness harness = harness(
                List.of(
                        executionRow(
                                product, UUID.randomUUID(), productionMaterial,
                                UUID.randomUUID(), "START", true,
                                "PER_UNIT", BigDecimal.ONE),
                        executionRow(
                                product, UUID.randomUUID(), shippingPackaging,
                                UUID.randomUUID(), "SHIP", true,
                                "PER_PACKAGE", new BigDecimal("12"))),
                Collections.singletonList(new Object[]{
                        productionMaterial, null, BigDecimal.TEN
                }));

        ProductionExecutionPlanningService.Snapshot snapshot =
                harness.service().preview(UUID.randomUUID(), UUID.randomUUID());

        assertThat(snapshot.productLines()).singleElement().satisfies(line ->
                assertThat(line.materials()).singleElement()
                        .extracting(CompleteKitAllocator.MaterialUsage::goodsId)
                        .isEqualTo(productionMaterial));
        assertThat(snapshot.availability().keySet())
                .extracting(CompleteKitAllocator.MaterialKey::goodsId)
                .containsExactly(productionMaterial)
                .doesNotContain(shippingPackaging);
        assertThat(harness.service().propose(snapshot).segments())
                .singleElement()
                .satisfies(segment -> assertThat(segment.status())
                        .isEqualTo(ProductionExecutionSegment.STATUS_READY));
    }

    @Test
    void shippingOrReferenceRowsCannotBypassCanonicalUuidValidation() {
        ProductIds product = ProductIds.create();
        Object[] missingUnit = executionRow(
                product, UUID.randomUUID(), UUID.randomUUID(), null,
                "SHIP", false, "PER_UNIT", BigDecimal.ONE);
        assertThatThrownBy(() -> harness(
                Collections.singletonList(missingUnit), List.of())
                .service().preview(UUID.randomUUID(), UUID.randomUUID()))
                .hasMessage("BOM、颜色或基本单位数据不完整，禁止生成执行分段");

        Object[] legacyOnlyColor = executionRow(
                product, UUID.randomUUID(), UUID.randomUUID(), UUID.randomUUID(),
                "REFERENCE", false, "PER_UNIT", BigDecimal.ONE);
        legacyOnlyColor[18] = true;
        assertThatThrownBy(() -> harness(
                Collections.singletonList(legacyOnlyColor), List.of())
                .service().preview(UUID.randomUUID(), UUID.randomUUID()))
                .hasMessage("BOM、颜色或基本单位数据不完整，禁止生成执行分段");
    }

    @Test
    void productionHardGateUsesExactWholePackageRequirement() {
        ProductIds product = ProductIds.create();
        UUID materialId = UUID.randomUUID();
        Harness harness = harness(
                Collections.singletonList(executionRow(
                        product, UUID.randomUUID(), materialId,
                        UUID.randomUUID(), "FINISH", true,
                        "PER_PACKAGE", new BigDecimal("6"),
                        new BigDecimal("2"), false)),
                Collections.singletonList(new Object[]{
                        materialId, null, new BigDecimal("2")
                }));

        CompleteKitAllocator.Allocation allocation = harness.service().propose(
                harness.service().preview(
                        UUID.randomUUID(), UUID.randomUUID()));

        assertThat(allocation.segments()).hasSize(2);
        assertThat(allocation.segments().getFirst().plannedQty())
                .isEqualByComparingTo("6");
        assertThat(allocation.segments().getFirst().materials().getFirst()
                .requiredQty()).isEqualByComparingTo("2");
        assertThat(allocation.segments().getFirst().materials().getFirst()
                .perProductQty()).isEqualByComparingTo("0.333334");
        assertThat(allocation.segments().get(1).plannedQty())
                .isEqualByComparingTo("4");
        assertThat(allocation.segments().get(1).materials().getFirst()
                .requiredQty()).isEqualByComparingTo("2");
        assertThat(allocation.segments().get(1).materials().getFirst()
                .perProductQty()).isEqualByComparingTo("0.500000");
    }


    @Test
    void repeatedMaterialDimensionKeepsEveryNonLinearRule() {
        ProductIds product = ProductIds.create();
        UUID materialId = UUID.randomUUID();
        UUID materialUnitId = UUID.randomUUID();
        Harness harness = harness(
                List.of(
                        executionRow(
                                product, UUID.randomUUID(), materialId,
                                materialUnitId, "START", true,
                                "PER_PACKAGE", new BigDecimal("6"),
                                new BigDecimal("2"), false),
                        executionRow(
                                product, UUID.randomUUID(), materialId,
                                materialUnitId, "ASSEMBLY", true,
                                "FIXED_BATCH", new BigDecimal("4"),
                                BigDecimal.ONE, true)),
                Collections.singletonList(new Object[]{
                        materialId, null, new BigDecimal("7")
                }));

        ProductionExecutionPlanningService.Snapshot snapshot =
                harness.service().preview(
                        UUID.randomUUID(), UUID.randomUUID());

        assertThat(snapshot.productLines()).singleElement().satisfies(line ->
                assertThat(line.materials()).singleElement().satisfies(material ->
                        assertThat(material.consumptionRules()).hasSize(2)));
        assertThat(harness.service().propose(snapshot).segments())
                .singleElement().satisfies(segment ->
                        assertThat(segment.materials().getFirst().requiredQty())
                                .isEqualByComparingTo("7"));
    }

    @Test
    void changingControlStageChangesBothBomAndSnapshotFingerprints() {
        ProductIds product = ProductIds.create();
        UUID bomItemId = UUID.randomUUID();
        UUID materialId = UUID.randomUUID();
        UUID materialUnitId = UUID.randomUUID();
        ProductionExecutionPlanningService.Snapshot start = harness(
                Collections.singletonList(executionRow(
                        product, bomItemId, materialId, materialUnitId,
                        "START", true, "PER_UNIT", BigDecimal.ONE)),
                Collections.singletonList(new Object[]{
                        materialId, null, BigDecimal.TEN
                })).service().preview(UUID.randomUUID(), UUID.randomUUID());
        ProductionExecutionPlanningService.Snapshot finish = harness(
                Collections.singletonList(executionRow(
                        product, bomItemId, materialId, materialUnitId,
                        "FINISH", true, "PER_UNIT", BigDecimal.ONE)),
                Collections.singletonList(new Object[]{
                        materialId, null, BigDecimal.TEN
                })).service().preview(start.planId(), start.warehouseId());

        assertThat(start.productLines().getFirst().bomFingerprint())
                .isNotEqualTo(finish.productLines().getFirst().bomFingerprint());
        assertThat(start.fingerprint()).isNotEqualTo(finish.fingerprint());
    }

    @Test
    void usedQuantityDrivesDemandWhileDesignQuantityOnlyValidates() {
        ProductIds product = ProductIds.create();
        UUID materialId = UUID.randomUUID();
        Object[] row = executionRow(
                product, UUID.randomUUID(), materialId, UUID.randomUUID(),
                "START", true, "PER_UNIT", BigDecimal.ONE);
        row[21] = "ACTUAL";
        row[29] = new BigDecimal("0.8");
        Harness harness = harness(
                Collections.singletonList(row),
                Collections.singletonList(new Object[]{
                        materialId, null, BigDecimal.TEN
                }));

        ProductionExecutionPlanningService.Snapshot snapshot =
                harness.service().preview(UUID.randomUUID(), UUID.randomUUID());

        assertThat(snapshot.productLines().getFirst().materials())
                .singleElement().satisfies(material -> {
                    assertThat(material.perProductQty())
                            .isEqualByComparingTo("0.8");
                    assertThat(material.consumptionRules().getFirst().bomQty())
                            .isEqualByComparingTo("0.8");
                });
        assertThat(harness.service().propose(snapshot).segments())
                .singleElement().satisfies(segment -> assertThat(
                        segment.materials().getFirst().requiredQty())
                        .isEqualByComparingTo("8"));
        verify(harness.em()).createNativeQuery(argThat(sql ->
                sql.contains("LEFT JOIN v_goods_bom_item_usage usage")
                        && sql.contains("ON usage.bom_item_id = b.id")
                        && sql.contains("MAX(candidate.bom_qty) AS bom_qty")
                        && sql.contains("MAX(candidate.usage_basis) AS usage_basis")
                        && !sql.contains("b.updated_at")));

        Object[] invalidDesign = executionRow(
                product, UUID.randomUUID(), materialId, UUID.randomUUID(),
                "START", true, "PER_UNIT", BigDecimal.ONE,
                BigDecimal.ZERO, true);
        invalidDesign[29] = BigDecimal.ONE;
        assertThatThrownBy(() -> harness(
                Collections.singletonList(invalidDesign), List.of())
                .service().preview(UUID.randomUUID(), UUID.randomUUID()))
                .as("用量不大于零的存量 BOM 行：说清是哪一行、为什么、怎么改")
                .hasMessage("「FG-001 Finished good」→ 组件「C-001 Component」：用量小于或等于 0，不能排产。"
                        + "请在父件的 BOM 里把这一行的用量改成大于 0。");
    }

    @Test
    void fingerprintFollowsUsedQuantityAndBasisButNotBomRowEdits() {
        ProductIds product = ProductIds.create();
        UUID bomItemId = UUID.randomUUID();
        UUID materialId = UUID.randomUUID();
        UUID materialUnitId = UUID.randomUUID();
        UUID planId = UUID.randomUUID();
        UUID warehouseId = UUID.randomUUID();
        java.util.function.BiFunction<String, BigDecimal, String> fingerprint =
                (basis, usedQty) -> {
                    Object[] row = executionRow(
                            product, bomItemId, materialId, materialUnitId,
                            "START", true, "PER_UNIT", BigDecimal.ONE);
                    row[21] = basis;
                    row[29] = usedQty;
                    return harness(Collections.singletonList(row),
                            Collections.singletonList(new Object[]{
                                    materialId, null, BigDecimal.TEN
                            })).service().preview(planId, warehouseId)
                            .productLines().getFirst().bomFingerprint();
                };
        String design = fingerprint.apply("DESIGN", BigDecimal.ONE);

        assertThat(fingerprint.apply("DESIGN", BigDecimal.ONE)).isEqualTo(design);
        assertThat(fingerprint.apply("ACTUAL", BigDecimal.ONE)).isNotEqualTo(design);
        assertThat(fingerprint.apply("DESIGN", new BigDecimal("1.2")))
                .isNotEqualTo(design);

        Object[] redesigned = executionRow(
                product, bomItemId, materialId, materialUnitId,
                "START", true, "PER_UNIT", BigDecimal.ONE,
                new BigDecimal("3"), true);
        redesigned[29] = BigDecimal.ONE;
        assertThat(harness(Collections.singletonList(redesigned),
                Collections.singletonList(new Object[]{
                        materialId, null, BigDecimal.TEN
                })).service().preview(planId, warehouseId)
                .productLines().getFirst().bomFingerprint())
                .as("an analysis-pinned quantity keeps the task valid after a design edit")
                .isEqualTo(design);
    }

    private static Harness harness(
            List<Object[]> rows, List<Object[]> availability) {
        EntityManager em = mock(EntityManager.class);
        Query bomRows = resultQuery(rows);
        Query sourceItems = resultQuery(List.of((UUID) rows.getFirst()[0]));
        Query stock = resultQuery(availability.stream().map(row -> new Object[]{
                row[0], row[1], UUID.randomUUID(), row[2], BigDecimal.ZERO,
                BigDecimal.ZERO, BigDecimal.ZERO, true
        }).toList());
        // V298 之后第一个原生查询是 material_analysis_id 预查（typedRows→UUID）：
        // 按 SQL 分流，该测试的计划无分析来源 → 空结果；其余按原顺序消费。
        java.util.Iterator<Query> ordered =
                java.util.List.of(bomRows, sourceItems, stock).iterator();
        when(em.createNativeQuery(anyString())).thenAnswer(invocation -> {
            String sql = invocation.getArgument(0, String.class);
            // 预查 SQL 独有特征是 "material_analysis_id IS NOT NULL"（主查询也选
            // p.material_analysis_id 列，不能按列名分流）。
            if (sql.contains("material_analysis_id IS NOT NULL")) {
                return resultQuery(java.util.List.of());
            }
            return ordered.next();
        });
        return new Harness(new ProductionExecutionPlanningService(em), em);
    }

    private static Query resultQuery(List<?> values) {
        Query query = mock(Query.class);
        when(query.setParameter(anyString(), any())).thenReturn(query);
        when(query.getResultList()).thenReturn(values);
        return query;
    }

    private static Object[] executionRow(
            ProductIds product,
            UUID bomItemId,
            UUID componentGoodsId,
            UUID componentUnitId,
            String controlStage,
            boolean hardGate,
            String consumptionBasis,
            BigDecimal basisOutputQty) {
        return executionRow(
                product, bomItemId, componentGoodsId, componentUnitId,
                controlStage, hardGate, consumptionBasis, basisOutputQty,
                BigDecimal.ONE, true);
    }

    private static Object[] executionRow(
            ProductIds product,
            UUID bomItemId,
            UUID componentGoodsId,
            UUID componentUnitId,
            String controlStage,
            boolean hardGate,
            String consumptionBasis,
            BigDecimal basisOutputQty,
            BigDecimal bomQty,
            boolean allowPartialPackage) {
        Object[] row = new Object[32];
        row[0] = product.sourceItemId();
        row[1] = 1;
        row[2] = product.productGoodsId();
        row[3] = null;
        row[4] = product.productUnitId();
        row[5] = BigDecimal.ONE;
        row[6] = BigDecimal.TEN;
        row[7] = LocalDate.of(2026, 8, 9);
        row[8] = LocalDate.of(2026, 8, 10);
        row[9] = product.workshopId();
        row[10] = product.workerId();
        row[11] = "FG-001";
        row[12] = "Finished good";
        row[13] = bomItemId;
        row[14] = componentGoodsId;
        row[15] = null;
        row[16] = componentUnitId;
        row[17] = bomQty;
        row[18] = null;
        row[19] = false;
        row[20] = "plan-item-version-1";
        row[21] = "DESIGN";
        row[22] = "\u91c7\u8d2d";
        row[23] = null;
        row[24] = controlStage;
        row[25] = hardGate;
        row[26] = consumptionBasis;
        row[27] = basisOutputQty;
        row[28] = allowPartialPackage;
        row[29] = bomQty;
        row[30] = "C-001";
        row[31] = "Component";
        return row;
    }

    private record Harness(
            ProductionExecutionPlanningService service,
            EntityManager em) {
    }

    private record ProductIds(
            UUID sourceItemId,
            UUID productGoodsId,
            UUID productUnitId,
            UUID workshopId,
            UUID workerId) {
        private static ProductIds create() {
            return new ProductIds(
                    UUID.randomUUID(), UUID.randomUUID(), UUID.randomUUID(),
                    UUID.randomUUID(), UUID.randomUUID());
        }
    }
}
