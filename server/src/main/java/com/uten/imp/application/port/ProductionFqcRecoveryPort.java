package com.uten.imp.application.port;

import java.math.BigDecimal;
import java.util.UUID;

/** Neutral integration port for append-only FQC failed-quantity recovery. */
public interface ProductionFqcRecoveryPort {

    void applyFailureAdjustment(
            UUID inspectionId,
            UUID decisionEventId,
            BigDecimal failQty,
            String dispositionCode);

    void allocateApprovedRecoveryReportItem(
            UUID reportItemId,
            UUID authorizationId,
            BigDecimal quantity);

    BigDecimal effectiveContribution(
            UUID reportItemId,
            BigDecimal declaredQuantity);

    void reverseReportEffects(UUID reportId);
    default void requireReportEffectsReversible(UUID reportId) {
        throw new com.uten.imp.common.web.ApiException(com.uten.imp.common.web.ErrorCode.CONFLICT,"当前无法核对FQC补产的反审条件");
    }

    void requireLegacyExemption(UUID reportItemId);
}
