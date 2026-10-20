package com.uten.imp.features.master.goods.dto;

import java.time.Instant;
import java.util.List;
import java.util.UUID;

public record BomEditPreview(String previewToken, int operationCount,
                             List<AffectedParent> affectedParents, int otherUsageCount,
                             Instant expiresAt, List<String> warnings) {
    public record AffectedParent(UUID goodsId, String goodsCode, String goodsName, int otherUsageCount) { }
}
