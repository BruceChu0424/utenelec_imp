package com.uten.imp.application.port;

import java.math.BigDecimal;
import java.util.List;
import java.util.UUID;

/** Read-only qualified and public material availability used by workshop notifications. */
public interface WorkshopMaterialAvailabilityReadPort {
    List<Availability> batchAvailability(UUID warehouseId, List<UUID> demandIds,
                                        UUID analysisId, UUID analysisItemId);

    record Availability(UUID demandId, UUID warehouseId, BigDecimal publicQty,
                        BigDecimal safetyQty, BigDecimal qualifiedQty) {}
}
