package com.uten.imp.features.production.mrp;

import java.time.Instant;
import java.util.UUID;

public record ProductionPlanningDraftView(
        UUID draftId,
        UUID planId,
        UUID warehouseId,
        String status,
        String previewFingerprint,
        int segmentCount,
        boolean generatePurchaseRequest,
        UUID plannedBy,
        Instant plannedAt,
        GeneratePlanningPackageRequest request) {
}
