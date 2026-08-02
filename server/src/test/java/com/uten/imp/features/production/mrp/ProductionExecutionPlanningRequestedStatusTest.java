package com.uten.imp.features.production.mrp;

import com.uten.imp.features.production.fulfillment.ProductionExecutionSegment;
import com.uten.imp.features.production.fulfillment.ProductionMaterialDemand;
import jakarta.persistence.EntityManager;
import org.junit.jupiter.api.Test;

import java.math.BigDecimal;
import java.time.LocalDate;
import java.util.List;
import java.util.Map;
import java.util.UUID;

import static org.assertj.core.api.Assertions.assertThat;
import static org.assertj.core.api.Assertions.assertThatThrownBy;
import static org.mockito.Mockito.mock;

class ProductionExecutionPlanningRequestedStatusTest {

    @Test
    void waitingUsesExplicitDeferIntentInsteadOfInferringFromStatus() {
        UUID planId = UUID.randomUUID();
        UUID warehouseId = UUID.randomUUID();
        UUID planItemId = UUID.randomUUID();
        UUID productId = UUID.randomUUID();
        UUID productUnitId = UUID.randomUUID();
        UUID materialId = UUID.randomUUID();
        UUID materialUnitId = UUID.randomUUID();
        String bomFingerprint = "b".repeat(64);
        CompleteKitAllocator.MaterialKey materialKey =
                new CompleteKitAllocator.MaterialKey(materialId, null);
        CompleteKitAllocator.ProductLine line =
                new CompleteKitAllocator.ProductLine(
                        planItemId,
                        1,
                        productId,
                        null,
                        productUnitId,
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
                                materialUnitId,
                                BigDecimal.ONE,
                                ProductionMaterialDemand.ROUTE_BUY)),
                        bomFingerprint);
        ProductionExecutionPlanningService.Snapshot snapshot =
                new ProductionExecutionPlanningService.Snapshot(
                        planId,
                        warehouseId,
                        "a".repeat(64),
                        List.of(line),
                        Map.of(materialKey, new BigDecimal("4.0000")),
                        List.of());
        GeneratePlanningPackageRequest.ExecutionSegment requested =
                new GeneratePlanningPackageRequest.ExecutionSegment();
        requested.setClientSegmentKey("manual-waiting");
        requested.setSourcePlanItemId(planItemId);
        requested.setRequestedStatus(
                ProductionExecutionSegment.STATUS_WAITING);
        requested.setDeferUntilManualRelease(true);
        requested.setPlannedQty(new BigDecimal("4.0000"));
        requested.setBomFingerprint(bomFingerprint);

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
                        "Only WAITING segments may be explicitly deferred");
    }
}
