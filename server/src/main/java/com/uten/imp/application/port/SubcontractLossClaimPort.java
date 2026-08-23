package com.uten.imp.application.port;

import java.math.BigDecimal;
import java.time.LocalDate;
import java.util.List;
import java.util.UUID;

/** Boundary from the subcontract physical-loss fact to finance responsibility handling. */
public interface SubcontractLossClaimPort {
    void validateApprovedWaste(ApprovedWaste waste);

    void openForApprovedWaste(ApprovedWaste waste);

    /** Reversing the physical waste is allowed only after finance effects are safely reversible. */
    void beforeWasteReverse(UUID wasteId);

    record ApprovedWaste(
            UUID wasteId,
            String wasteBillNo,
            LocalDate wasteDate,
            UUID supplierId,
            BigDecimal suggestedClaimAmountLocal,
            List<LossLine> lines) {
        public ApprovedWaste {
            lines = lines == null ? List.of() : List.copyOf(lines);
        }
    }

    record LossLine(
            UUID wasteItemId,
            UUID materialIssueItemId,
            UUID goodsId,
            UUID colorId,
            UUID unitId,
            BigDecimal actualLossQty,
            BigDecimal allowedLossQty,
            String goodsCode,
            String goodsName) {}
}
