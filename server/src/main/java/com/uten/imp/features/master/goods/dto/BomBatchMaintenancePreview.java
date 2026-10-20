package com.uten.imp.features.master.goods.dto;

import java.time.Instant;
import java.util.List;
import java.util.UUID;

public record BomBatchMaintenancePreview(
        UUID previewToken, BomBatchMaintenanceRequest.Action action,
        int selectedTargetCount, int changedTargetCount,
        int added, int updated, int removed, int skipped,
        List<Target> targets, List<Product> affectedProducts,
        int otherUsageCount, int hiddenUsageCount, Instant expiresAt, List<String> warnings) {
    public record Target(UUID goodsId, String goodsCode, String goodsName,
                         int added, int updated, int removed, int skipped) {
        public int changes() { return added + updated + removed; }
    }
    public record Product(UUID goodsId, String goodsCode, String goodsName, boolean selected) { }
}
