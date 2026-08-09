package com.uten.imp.features.production.mrp;

import com.uten.imp.features.production.fulfillment.ProductionMaterialDemand;

import java.math.BigDecimal;
import java.time.LocalDate;
import java.util.List;
import java.util.UUID;

/** Editable server proposal shown in the planning drawer before confirmation. */
public record ExecutionSegmentPreview(
        String clientSegmentKey,
        UUID sourcePlanItemId,
        Integer sourceLineNo,
        UUID productGoodsId,
        String productCode,
        String productName,
        String productSpec,
        UUID productColorId,
        UUID productUnitId,
        BigDecimal plannedQty,
        String suggestedStatus,
        UUID workshopDepartmentId,
        UUID teamDepartmentId,
        UUID responsibleEmployeeId,
        LocalDate planBeginDate,
        LocalDate planEndDate,
        String bomFingerprint,
        String materialRequirementMode,
        String zeroMaterialReason,
        List<Material> materials) {

    public record Material(
            UUID goodsId,
            UUID colorId,
            UUID unitId,
            BigDecimal perProductQty,
            BigDecimal requiredQty,
            BigDecimal availableBeforeQty,
            BigDecimal candidateAllocatedQty,
            BigDecimal shortageQty,
            String supplyRoute,
            String requirementMode) {

        public Material(
                UUID goodsId,
                UUID colorId,
                UUID unitId,
                BigDecimal perProductQty,
                BigDecimal requiredQty,
                BigDecimal availableBeforeQty,
                BigDecimal candidateAllocatedQty,
                BigDecimal shortageQty,
                String supplyRoute) {
            this(
                    goodsId,
                    colorId,
                    unitId,
                    perProductQty,
                    requiredQty,
                    availableBeforeQty,
                    candidateAllocatedQty,
                    shortageQty,
                    supplyRoute,
                    ProductionMaterialDemand.REQUIREMENT_MODE_LINEAR);
        }
    }
}
