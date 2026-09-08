package com.uten.imp.features.sales.shipment.dto;

import jakarta.validation.constraints.Size;
import java.util.UUID;

/** Finance reviews a particular sales-confirmed revision while retaining the same live lease. */
public record ShipmentFinanceDecisionRequest(Long expectedRevision,
        @Size(max=64) String expectedContentHash, UUID expectedClaimId,
        @Size(max=500) String reason) { }
