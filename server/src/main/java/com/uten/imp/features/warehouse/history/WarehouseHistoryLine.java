package com.uten.imp.features.warehouse.history;

import java.math.BigDecimal;
import java.util.UUID;

/** Physical and quality facts visible to warehouse staff; deliberately no commercial fields. */
public record WarehouseHistoryLine(
        UUID id,
        Integer lineNumber,
        UUID goodsId,
        String goodsCode,
        String goodsName,
        /** Current goods-master placement hint; not a historical document snapshot. */
        String stockPlace,
        String colorName,
        String unitName,
        BigDecimal quantity,
        BigDecimal weight,
        BigDecimal returnedQuantity,
        BigDecimal wastedQuantity,
        BigDecimal atSupplierQuantity,
        BigDecimal consumedQuantity,
        BigDecimal supplierEndingQuantity,
        BigDecimal iqcPassedBaseQuantity,
        BigDecimal iqcStockedBaseQuantity,
        BigDecimal iqcPendingStockInBaseQuantity,
        BigDecimal iqcFailedBaseQuantity,
        String iqcStatus,
        String referenceDocumentNo,
        BigDecimal endingQuantity,
        BigDecimal standardQuantity,
        BigDecimal wasteRate,
        String reason,
        BigDecimal boxQuantity,
        String parentGoodsCode,
        String parentGoodsName) {
}
