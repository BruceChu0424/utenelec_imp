package com.uten.imp.features.sales.shipment.warehouse;

import java.math.BigDecimal;
import java.util.List;
import java.util.UUID;

/**
 * 仓库视图的出库行：数量、重量、建议库位与实际库位，不含任何商业金额。
 * V631：warehouseId 是已落定的实际发出仓（已出库行/确认过的行），suggestedWarehouseId 是
 * 预填建议仓，warehouseChoices 是本行可选的发出仓及各自可发量（只在待确认出库时给出）。
 * ADR-135: weightKg / weightSource 取自本行销售出库流水的重量(千克)与来历
 * (MEASURED 实称 / EXACT 按数量精确换算 / AVERAGE 按库存均重 / ESTIMATE 按单重估算 ...);
 * 未出库时为空。销售明细上的商业快照重量不在仓库视图里出现。
 * unitRate = 1 个出货单位折多少货品基本单位(空按 1), 页面按 数量 x unitRate 核对实称重量。
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
        BigDecimal unitRate,
        BigDecimal quantity,
        BigDecimal weightKg,
        String weightSource,
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
