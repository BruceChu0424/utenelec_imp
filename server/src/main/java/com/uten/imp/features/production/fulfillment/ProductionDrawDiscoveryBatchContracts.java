package com.uten.imp.features.production.fulfillment;

import java.util.List;
import java.util.UUID;

import static com.uten.imp.features.production.fulfillment.ProductionMaterialDiscoveryContracts.Material;

public final class ProductionDrawDiscoveryBatchContracts {
    private ProductionDrawDiscoveryBatchContracts() {}
    public record Discovery(UUID requestId, Long expectedVersion, List<Material> items) {}
    public record Request(String idempotencyKey, List<UUID> docIds,
                          List<Discovery> discoveries, String reason) {}
}
