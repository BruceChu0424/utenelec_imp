package com.uten.imp.features.finance.payables.warehouse;

import java.math.BigDecimal;
import java.time.LocalDate;
import java.time.OffsetDateTime;
import java.util.List;
import java.util.UUID;

/** Physical IQC return facts only; contains no supplier-finance or commercial fields. */
public record WarehouseIqcReturnView(
        UUID id,
        String receiptType,
        UUID receiptId,
        UUID receiptItemId,
        UUID inspectionItemId,
        String receiptBillNo,
        String orderBillNo,
        UUID supplierId,
        String supplierName,
        UUID warehouseId,
        String warehouseName,
        UUID goodsId,
        String goodsCode,
        String goodsName,
        UUID colorId,
        String colorName,
        UUID unitId,
        String unitName,
        String inspectionStatus,
        BigDecimal failedBaseQuantity,
        BigDecimal failedQuantity,
        String physicalReturnStatus,
        long version,
        String returnReference,
        LocalDate returnDate,
        String returnNote,
        String returnRecordedByName,
        OffsetDateTime returnRecordedAt,
        List<String> allowedActions) {

    public WarehouseIqcReturnView {
        allowedActions = allowedActions == null ? List.of() : List.copyOf(allowedActions);
    }
}
