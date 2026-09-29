package com.uten.imp.features.production.mrp;

import com.uten.imp.features.production.fulfillment.ProductionExecutionSegment;
import com.uten.imp.features.production.fulfillment.ProductionMaterialDemand;
import jakarta.persistence.EntityManager;
import jakarta.persistence.Query;
import org.junit.jupiter.api.Test;

import java.math.BigDecimal;
import java.time.LocalDate;
import java.util.List;
import java.util.Map;
import java.util.UUID;

import static org.assertj.core.api.Assertions.assertThat;
import static org.assertj.core.api.Assertions.assertThatThrownBy;
import static org.mockito.ArgumentMatchers.any;
import static org.mockito.ArgumentMatchers.anyString;
import static org.mockito.ArgumentMatchers.argThat;
import static org.mockito.Mockito.mock;
import static org.mockito.Mockito.when;

class ProductionExecutionPlanningRequestedStatusTest {

    private static final String BOM_FINGERPRINT = "b".repeat(64);

    @Test
    void waitingUsesExplicitDeferIntentInsteadOfInferringFromStatus() {
        UUID materialId = UUID.randomUUID();
        CompleteKitAllocator.MaterialKey materialKey =
                new CompleteKitAllocator.MaterialKey(materialId, null);
        ProductionExecutionPlanningService.Snapshot snapshot = snapshot(materialId);
        GeneratePlanningPackageRequest.ExecutionSegment requested = waiting(snapshot);

        ProductionExecutionPlanningService service =
                new ProductionExecutionPlanningService(
                        mock(EntityManager.class));
        CompleteKitAllocator.Allocation result =
                service.applyRequested(snapshot, List.of(requested));

        CompleteKitAllocator.SegmentAllocation segment =
                result.segments().getFirst();
        assertThat(segment.status())
                .isEqualTo(ProductionExecutionSegment.STATUS_WAITING);
        assertThat(segment.autoPromoteWhenReady()).isFalse();

        assertThat(segment.materials().getFirst().candidateAllocatedQty())
                .isZero();
        assertThat(result.remainingAvailability().get(materialKey))
                .isEqualByComparingTo("4.0000");
        requested.setDeferUntilManualRelease(false);
        CompleteKitAllocator.Allocation automatic =
                service.applyRequested(snapshot, List.of(requested));
        assertThat(automatic.segments().getFirst().autoPromoteWhenReady())
                .isTrue();

        requested.setRequestedStatus(
                ProductionExecutionSegment.STATUS_READY);
        requested.setDeferUntilManualRelease(true);
        assertThatThrownBy(() ->
                service.applyRequested(snapshot, List.of(requested)))
                .isInstanceOf(
                        com.uten.imp.common.web.ApiException.class)
                .hasMessageContaining(
                        "只有「等待」状态的执行分段才能设置为暂缓放行");
    }

    @Test
    void staleSegmentBomTellsManualPlansThatUsageMayHaveBeenRelearned() {
        ProductionExecutionPlanningService.Snapshot snapshot = snapshot(UUID.randomUUID());
        GeneratePlanningPackageRequest.ExecutionSegment requested = waiting(snapshot);
        requested.setBomFingerprint("c".repeat(64));
        EntityManager em = mock(EntityManager.class);
        Query origin = mock(Query.class);
        when(origin.setParameter(anyString(), any())).thenReturn(origin);
        when(origin.getSingleResult()).thenReturn(0L, 1L);
        when(em.createNativeQuery(argThat((String sql) -> sql.contains("material_analysis_id IS NOT NULL"))))
                .thenReturn(origin);
        ProductionExecutionPlanningService service = new ProductionExecutionPlanningService(em);

        // ADR-129 §2.6：手工计划的用量随真实数据更新，分析计划沿用锁定值。
        assertThatThrownBy(() -> service.applyRequested(snapshot, List.of(requested)))
                .hasMessage("执行分段 BOM 已变化，或用量已按真实数据更新，请重新预览");
        assertThatThrownBy(() -> service.applyRequested(snapshot, List.of(requested)))
                .hasMessage("执行分段 BOM 已变化，请重新预览");
    }

    private static ProductionExecutionPlanningService.Snapshot snapshot(UUID materialId) {
        UUID planItemId = UUID.randomUUID();
        CompleteKitAllocator.ProductLine line =
                new CompleteKitAllocator.ProductLine(
                        planItemId,
                        1,
                        UUID.randomUUID(),
                        null,
                        UUID.randomUUID(),
                        BigDecimal.ONE,
                        new BigDecimal("4.0000"),
                        LocalDate.now(),
                        LocalDate.now().plusDays(1),
                        null,
                        null,
                        null,
                        "P-1",
                        "Product",
                        new CompleteKitAllocator.Priority(
                                LocalDate.now(), 1, planItemId),
                        List.of(new CompleteKitAllocator.MaterialUsage(
                                materialId,
                                null,
                                UUID.randomUUID(),
                                BigDecimal.ONE,
                                ProductionMaterialDemand.ROUTE_BUY)),
                        BOM_FINGERPRINT);
        return new ProductionExecutionPlanningService.Snapshot(
                UUID.randomUUID(),
                UUID.randomUUID(),
                "a".repeat(64),
                List.of(line),
                Map.of(new CompleteKitAllocator.MaterialKey(materialId, null),
                        new BigDecimal("4.0000")),
                List.of());
    }

    private static GeneratePlanningPackageRequest.ExecutionSegment waiting(
            ProductionExecutionPlanningService.Snapshot snapshot) {
        GeneratePlanningPackageRequest.ExecutionSegment requested =
                new GeneratePlanningPackageRequest.ExecutionSegment();
        requested.setClientSegmentKey("manual-waiting");
        requested.setSourcePlanItemId(
                snapshot.productLines().getFirst().sourcePlanItemId());
        requested.setRequestedStatus(
                ProductionExecutionSegment.STATUS_WAITING);
        requested.setDeferUntilManualRelease(true);
        requested.setPlannedQty(new BigDecimal("4.0000"));
        requested.setBomFingerprint(BOM_FINGERPRINT);
        return requested;
    }
}
