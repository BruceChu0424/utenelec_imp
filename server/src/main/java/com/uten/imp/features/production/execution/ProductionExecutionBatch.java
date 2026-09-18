package com.uten.imp.features.production.execution;

import java.math.BigDecimal;
import java.util.List;
import java.util.UUID;

public final class ProductionExecutionBatch {
    private ProductionExecutionBatch() {}

    public record PreviewRequest(UUID segmentId, Long expectedVersion, BigDecimal quantity) {}
    public record SubmitRequest(UUID segmentId, Long expectedVersion, BigDecimal quantity,
                                String previewFingerprint, String idempotencyKey) {}
    public record Preview(UUID segmentId, long expectedVersion, UUID planId, String planNo,
                          String segmentCode, String productCode, String productName,
                          String productUnitName, BigDecimal originalQty, BigDecimal maxReadyQty,
                          BigDecimal quantity, BigDecimal remainingQty, String fingerprint,
                          List<Line> lines, List<ProductionDrawRequest.Summary> summaries,
                          List<UUID> lineSideWarehouseIds) {}
    public record Line(UUID sourceDemandId, UUID warehouseId, String warehouseName,
                       UUID goodsId, String goodsCode, String goodsName,
                       UUID colorId, String colorName, UUID unitId, String unitName,
                       BigDecimal quantity, boolean lineSide) {}
    public record Result(UUID batchSegmentId, UUID remainingSegmentId,
                         List<UUID> documentIds, boolean replayed) {}
}
