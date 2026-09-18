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
        String unitName,
        BigDecimal pendingReturnQty,
        BigDecimal availableToSettleQty,
        /** 单耗(每 1 个产品用多少，需求单位口径)；报工页按完工申报量自动折算本次实际用料(V595)。 */
        BigDecimal perProductQty,
        /** 本条需求对应的产品数量(分批子段为本批量)；requiredQty / requiredForProductQty 即平均单耗。 */
        BigDecimal requiredForProductQty,
        /** 同车间直送供给(V595)：持续生产工单上允许分次到料的需求。 */
        boolean directSupply) {
}
