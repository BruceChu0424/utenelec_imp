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

        assertThat(snapshot.noBomPlanItemIds()).isEmpty();
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
    void zeroMaterialAuthorizationUsesOnlyConfirmedDirectOrExplicitOverrideFacts() {
        UUID analysisId = UUID.randomUUID();
        UUID actorId = UUID.randomUUID();

        assertThat(ProductionExecutionPlanningService
                .authorizedZeroMaterialReason(
                        analysisId, "DIRECT_MAKE", null, null))
                .isEqualTo(ProductionExecutionSegment
                        .ZERO_MATERIAL_REASON_DIRECT_MAKE);
        assertThat(ProductionExecutionPlanningService
                .authorizedZeroMaterialReason(
                        analysisId, "BOM_REQUIRED", "批准缺 BOM 直制", actorId))
                .isEqualTo(ProductionExecutionSegment
                        .ZERO_MATERIAL_REASON_PLAN_BOM_OVERRIDE);
        assertThatThrownBy(() -> ProductionExecutionPlanningService
                .authorizedZeroMaterialReason(
                        analysisId, "BOM_REQUIRED", " ", actorId))
                .isInstanceOf(RuntimeException.class);
        assertThatThrownBy(() -> ProductionExecutionPlanningService
                .authorizedZeroMaterialReason(
                        null, "DIRECT_MAKE", null, null))
                .isInstanceOf(RuntimeException.class);
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

    private static Harness harness(
            List<Object[]> rows, List<Object[]> availability) {
        EntityManager em = mock(EntityManager.class);
        Query bomRows = resultQuery(rows);
        Query sourceItems = resultQuery(List.of((UUID) rows.getFirst()[0]));
        Query stock = resultQuery(availability);
        when(em.createNativeQuery(anyString()))
                .thenReturn(bomRows, sourceItems, stock);
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
        Object[] row = new Object[29];
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
        row[21] = "bom-item-version-1";
        row[22] = "\u91c7\u8d2d";
        row[23] = null;
        row[24] = controlStage;
        row[25] = hardGate;
        row[26] = consumptionBasis;
        row[27] = basisOutputQty;
        row[28] = allowPartialPackage;
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
