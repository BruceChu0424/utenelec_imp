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
        String parentGoodsName,
        /**
         * 父件颜色：行上的 parent_color_id 优先，空则回落父件货品主档色。
         * 父件也是货品，身份同样要「名称+编号+颜色」才认得出是哪一条。
         * 新字段追加在末尾，不打乱既有位置构造。
         */
        String parentColorName) {
}
