package com.uten.imp.features.stock.allocation.dto;

import java.math.BigDecimal;
import java.util.UUID;

/** Explicit DRAW line source offered to the WDRAW editor. */
public record ReturnableMaterialSourceRow(
        UUID planId,
        UUID packageId,
        UUID drawId,
        String drawNo,
        UUID drawItemId,
        UUID warehouseId,
        UUID goodsId,
        String goodsCode,
        String goodsName,
        UUID colorId,
        String colorName,
        UUID unitId,
        String unitName,
        BigDecimal unitRate,
        BigDecimal issuedQty,
        BigDecimal returnedQty,
        BigDecimal maxReturnQty) {
}
