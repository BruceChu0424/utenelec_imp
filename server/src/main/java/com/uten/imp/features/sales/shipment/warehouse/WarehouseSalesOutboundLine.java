package com.uten.imp.features.sales.shipment.warehouse;

import java.math.BigDecimal;
import java.util.UUID;

/** Physical shipment line; contains no price, cost or financial facts. */
public record WarehouseSalesOutboundLine(
        UUID id,
        Integer lineNumber,
        UUID goodsId,
        String goodsCode,
        String goodsName,
        /** Current goods-master placement hint, not a historical shipment snapshot. */
        String currentStockPlaceHint,
        UUID colorId,
        String colorName,
        UUID unitId,
        String unitName,
        BigDecimal quantity,
        BigDecimal weight,
        BigDecimal parcelQuantity,
        BigDecimal cartonCount,
        String clientProductCode,
        String clientModel,
        String sourceDocumentNo) {
}
