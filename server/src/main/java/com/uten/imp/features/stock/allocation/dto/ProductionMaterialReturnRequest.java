package com.uten.imp.features.stock.allocation.dto;

import java.math.BigDecimal;
import java.util.List;
import java.util.UUID;

public final class ProductionMaterialReturnRequest {
    private ProductionMaterialReturnRequest() {}
    public record Source(UUID issuePostingId, UUID demandId, UUID drawId, String drawNo, UUID drawItemId,
                         UUID warehouseId, String warehouseName, UUID goodsId, String goodsCode, String goodsName,
                         UUID colorId, String colorName, UUID unitId, String unitName, BigDecimal unitRate,
                         BigDecimal issuedQty, BigDecimal unsettledQty, BigDecimal pendingReturnQty, BigDecimal availableQty,
                         String returnBlockedReason) {}
    public record Item(UUID issuePostingId, BigDecimal qty) {}
    public record Submit(UUID executionSegmentId, String idempotencyKey, String reason, List<Item> items) {}
    public record Cancel(String idempotencyKey, String reason) {}
    public record Line(UUID itemId, UUID issuePostingId, UUID demandId, UUID drawItemId,
                       String goodsCode, String goodsName, String colorName, String unitName,
                       BigDecimal qty, BigDecimal baseQty) {}
    public record Document(UUID documentId, String documentNo, UUID warehouseId, String warehouseName,
                           String status, List<Line> lines) {}
}
