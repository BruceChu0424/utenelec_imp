package com.uten.imp.features.production.mrp;

import java.math.BigDecimal;
import java.util.List;
import java.util.UUID;

/** Server-authored planning snapshot; the fingerprint must be echoed on confirm. */
public record PlanningPreviewResult(
        UUID planId,
        UUID warehouseId,
        String fingerprint,
        List<MrpRow> materials,
        List<TargetWarehouseMaterial> targetWarehouseMaterials,
        boolean balancedKitCoverage,
        boolean executionSegmentationReady,
        List<ExecutionSegmentPreview> executionSegments,
        List<UUID> unresolvedZeroMaterialLineageIds) {

    public record TargetWarehouseMaterial(
            UUID goodsId,
            UUID colorId,
            BigDecimal requiredQty,
            BigDecimal allocatableQty,
            BigDecimal candidateAllocatedQty,
            BigDecimal candidateShortageQty) {
    }
}
