package com.uten.imp.features.stock.allocation.dto;

import java.math.BigDecimal;
import java.util.UUID;

/** One demand row of the issue/use/return/loss/WIP reconciliation equation. */
public record ProductionMaterialClearanceRow(
        UUID planId,
        UUID demandId,
        UUID executionSegmentId,
        String executionSegmentCode,
        UUID goodsId,
        String goodsCode,
        String goodsName,
        UUID colorId,
        String colorName,
        BigDecimal requiredQty,
        BigDecimal issuedQty,
        BigDecimal returnedQty,
        BigDecimal consumedQty,
        BigDecimal approvedLossQty,
        BigDecimal legalWipQty,
        BigDecimal maxReturnQty,
        BigDecimal unclearedQty,
        boolean canClose,
        String unitName) {
}
