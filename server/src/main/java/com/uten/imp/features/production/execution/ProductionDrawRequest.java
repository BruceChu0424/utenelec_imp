package com.uten.imp.features.production.execution;

import java.math.BigDecimal;
import java.util.List;
import java.util.UUID;

/** Workshop submission identifies exact execution segments and frozen DRAW lines. */
public final class ProductionDrawRequest {
    private ProductionDrawRequest() {}

    public record Item(UUID segmentId, Long expectedVersion) {}
    public record PreviewRequest(List<Item> items) {}
    public record Selection(UUID drawItemId, BigDecimal quantity) {}
    public record SubmitRequest(List<Item> items, String idempotencyKey, String previewFingerprint,
                                List<Selection> lines) {
        public SubmitRequest(List<Item> items, String idempotencyKey, String previewFingerprint) {
            this(items, idempotencyKey, previewFingerprint, null);
        }
    }
    public record Task(UUID segmentId, UUID planId, String planNo, String segmentCode,
                       UUID workshopDepartmentId, String workshopName, String productCode,
                       String productName, BigDecimal plannedQty, long expectedVersion) {}
    public record Line(UUID segmentId, UUID drawId, String drawNo, UUID drawItemId,
                       UUID warehouseId, String warehouseName, UUID goodsId, String goodsCode,
                       String goodsName, UUID colorId, String colorName, UUID unitId,
                       String unitName, BigDecimal qty) {}
    public record Summary(UUID warehouseId, String warehouseName, UUID goodsId, String goodsCode,
                          String goodsName, UUID colorId, String colorName, UUID unitId,
                          String unitName, BigDecimal qty) {}
    public record Preview(String fingerprint, int taskCount, int documentCount, int lineCount,
                          List<Task> tasks, List<Line> lines, List<Summary> summaries) {}
    public record Result(List<UUID> segmentIds, List<UUID> documentIds,
                         int taskCount, int documentCount, boolean replayed) {}
}
