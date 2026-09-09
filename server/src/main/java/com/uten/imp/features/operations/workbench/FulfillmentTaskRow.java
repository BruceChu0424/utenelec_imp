package com.uten.imp.features.operations.workbench;

import java.math.BigDecimal;
import java.time.LocalDate;
import java.time.OffsetDateTime;
import java.util.List;
import java.util.UUID;

public record FulfillmentTaskRow(
        String department,
        UUID taskId,
        UUID packageId,
        UUID planId,
        String planNo,
        UUID warehouseId,
        String warehouseName,
        UUID goodsId,
        String goodsCode,
        String goodsName,
        String spec,
        UUID colorId,
        String colorName,
        UUID unitId,
        String unitName,
        String supplyRoute,
        BigDecimal requiredQty,
        BigDecimal allocatedQty,
        BigDecimal fulfilledQty,
        BigDecimal supplyPeggedQty,
        BigDecimal openQty,
        String taskStatus,
        LocalDate needDate,
        LocalDate expectedDate,
        String exceptionCode,
        OffsetDateTime updatedAt,
        String actionDocType,
        UUID actionDocId,
        String actionDocNo,
        UUID actionDocItemId,
        String actionDocStatus,
        boolean actionDocCanView,
        boolean actionDocCanEdit,
        boolean actionDocRestricted,
        long goodsCount,
        long openLineCount,
        List<String> actionItemIds,
        OffsetDateTime issuedAt,
        boolean canCreateOrder) {

    /** 按单据归组的行（采购/委外）：一行代表一张申请或订货单的整批明细。 */
    public boolean isDocumentGrouped() {
        return goodsCount > 1 || openLineCount > 1 || actionItemIds.size() > 1;
    }
}
