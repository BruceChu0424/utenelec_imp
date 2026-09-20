package com.uten.imp.features.stock.allocation.dto;

import java.math.BigDecimal;
import java.util.List;
import java.util.UUID;

public final class ProductionMaterialReturnRequest {
    private ProductionMaterialReturnRequest() {}
    /** Every displayed quantity is in the frozen demand base unit; source document packaging is trace metadata. */
    public record Source(UUID issuePostingId, UUID demandId, UUID drawId, String drawNo, UUID drawItemId,
                         UUID sourceWarehouseId, String sourceWarehouseName, UUID goodsId, String goodsCode, String goodsName,
                         UUID colorId, String colorName, UUID unitId, String unitName, BigDecimal unitRate,
                         BigDecimal issuedQty, BigDecimal unsettledQty, BigDecimal pendingReturnQty, BigDecimal availableQty,
                         String returnBlockedReason, UUID sourceDepartmentId,
                         String sourceType, UUID directTransferItemId) {}
    /** qty is an exact base quantity for both ISSUE and DIRECT_LOT. */
    public record Item(UUID issuePostingId, BigDecimal qty, UUID directTransferItemId) {
        public Item(UUID issuePostingId, BigDecimal qty) { this(issuePostingId,qty,null); }
    }
    public record Submit(UUID executionSegmentId, String idempotencyKey, String reason, List<Item> items) {}
    public record Cancel(String idempotencyKey, String reason) {}
    public record Line(UUID itemId, UUID issuePostingId, UUID demandId, UUID drawItemId,
                       String goodsCode, String goodsName, String colorName, String unitName,
                       BigDecimal qty, BigDecimal baseQty, String sourceType, UUID directTransferItemId) {}
    public record Document(UUID documentId, String documentNo, UUID warehouseId, String warehouseName,
                           String status, List<Line> lines, UUID sourceWarehouseId, String sourceWarehouseName, UUID sourceDepartmentId) {}
}
