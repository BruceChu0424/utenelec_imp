package com.uten.imp.features.sales.shipment.warehouse;

import java.math.BigDecimal;
import java.util.List;
import java.util.UUID;

/**
 * 仓库视图的出库行：数量、重量、建议库位与实际库位，不含任何商业金额。
 * V631：warehouseId 是已落定的实际发出仓（已出库行/确认过的行），suggestedWarehouseId 是
 * 预填建议仓，warehouseChoices 是本行可选的发出仓及各自可发量（只在待确认出库时给出）。
 */
public record WarehouseSalesOutboundLine(
        UUID id,
        Integer lineNumber,
        UUID goodsId,
        String goodsCode,
        String goodsName,
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
        String sourceDocumentNo,
        String actualStockPlace,
        UUID warehouseId,
        String warehouseName,
        UUID suggestedWarehouseId,
        List<WarehouseSalesOutboundWarehouseChoice> warehouseChoices) {
    public WarehouseSalesOutboundLine {
        warehouseChoices = warehouseChoices == null ? List.of() : List.copyOf(warehouseChoices);
    }
}
