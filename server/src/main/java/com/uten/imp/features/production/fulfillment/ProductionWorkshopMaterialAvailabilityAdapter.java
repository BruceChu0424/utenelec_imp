package com.uten.imp.features.production.fulfillment;

import com.uten.imp.application.port.WorkshopMaterialAvailabilityReadPort;
import lombok.RequiredArgsConstructor;
import org.springframework.stereotype.Component;

import java.util.List;
import java.util.UUID;

/** Reuses the preparation source policy without exposing production implementation to notices. */
@Component
@RequiredArgsConstructor
public class ProductionWorkshopMaterialAvailabilityAdapter implements WorkshopMaterialAvailabilityReadPort {
    private final ProductionExecutionReadinessService readiness;

    @Override
    public List<Availability> batchAvailability(UUID warehouseId, List<UUID> demandIds,
                                               UUID analysisId, UUID analysisItemId) {
        return readiness.batchAvailability(warehouseId, demandIds, analysisId, analysisItemId).stream()
                .map(row -> new Availability(row.demandId(), row.warehouseId(), row.publicQty(),
                        row.safetyQty(), row.qualifiedQty()))
                .toList();
    }
}
