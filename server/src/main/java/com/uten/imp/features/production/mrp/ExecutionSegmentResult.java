package com.uten.imp.features.production.mrp;

import com.uten.imp.features.production.fulfillment.ProductionMaterialDemand;

import java.math.BigDecimal;
import java.time.LocalDate;
import java.util.List;
import java.util.UUID;

/** Persisted execution segment and its exact material/document identities. */
public record ExecutionSegmentResult(
        UUID segmentId,
        String segmentCode,
        String clientSegmentKey,
        UUID sourcePlanItemId,
        UUID productGoodsId,
        UUID productColorId,
        BigDecimal plannedQty,
        String status,
        String materialRequirementMode,
        String zeroMaterialReason,
        UUID workshopDepartmentId,
        UUID teamDepartmentId,
        UUID responsibleEmployeeId,
        LocalDate planBeginDate,
        LocalDate planEndDate,
        List<Material> materials,
        MrpGenerateResult drawDocument) {

    public record Material(
            UUID demandId,
            UUID goodsId,
            UUID colorId,
            UUID unitId,
            BigDecimal perProductQty,
            BigDecimal requiredQty,
            BigDecimal stockAllocatedQty,
            BigDecimal shortageQty,
            String supplyRoute,
            String requirementMode) {

        public Material(
                UUID demandId,
                UUID goodsId,
                UUID colorId,
                UUID unitId,
                BigDecimal perProductQty,
                BigDecimal requiredQty,
                BigDecimal stockAllocatedQty,
                BigDecimal shortageQty,
                String supplyRoute) {
            this(
                    demandId,
                    goodsId,
                    colorId,
                    unitId,
                    perProductQty,
                    requiredQty,
                    stockAllocatedQty,
                    shortageQty,
                    supplyRoute,
                    ProductionMaterialDemand.REQUIREMENT_MODE_LINEAR);
        }
    }
}
