package com.uten.imp.features.production.mrp;

import java.util.UUID;

public record PlanningPackageLifecycleResult(
        UUID packageId,
        String status,
        boolean replayed) {
}
