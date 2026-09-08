package com.uten.imp.features.warehouse.inbound.dto;

import java.math.BigDecimal;
import java.util.UUID;

/** 采购/委外收货待检冻结明细投影（IQC）。含货品/颜色快照与来源订货单号（溯源展示）。 */
public record ProcurementInspectionItemDto(
        UUID id,
        UUID receiptItemId,
        UUID goodsId,
        UUID colorId,
        UUID unitId,
        BigDecimal unitRate,
        BigDecimal receivedBaseQty,
        BigDecimal passedBaseQty,
        BigDecimal failedBaseQty,
        BigDecimal remainingBaseQty,
        String status,
        String goodsCode,
        String goodsName,
        String colorName,
        UUID warehouseId,
        String sourceOrderNo,
        BigDecimal receivedWeight,
        UUID baseUnitId,
        String baseUnitName,
        String sourceUnitName) {
}
