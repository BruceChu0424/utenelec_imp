package com.uten.imp.features.production.execution;

import java.math.BigDecimal;
import java.time.Instant;
import java.time.LocalDate;
import java.util.List;
import java.util.UUID;

/**
 * Read-only print projection for a confirmed V1 production planning package.
 *
 * <p>The projection is assembled from persisted execution and material facts.
 * Names are resolved from current master data at print time and are therefore
 * explicitly not a historical name snapshot.
 */
public record ProductionWorkCardView(
        UUID planId,
        String planBillNo,
        LocalDate planBillDate,
        LocalDate deliveryDate,
        UUID packageId,
        String packageStatus,
        short executionModelVersion,
        long packageLockVersion,
        Instant confirmedAt,
        String approverName,
        UUID warehouseId,
        String warehouseCode,
        String warehouseName,
        Instant generatedAt,
        String namePolicy,
        List<Card> cards) {

    public static final String CURRENT_MASTER_DATA = "CURRENT_MASTER_DATA";

    public record Card(
            UUID segmentId,
            String segmentCode,
            UUID sourcePlanItemId,
            Integer sourceLineNo,
            String productNo,
            UUID productGoodsId,
            String productCode,
            String productName,
            String productSpec,
            String productModel,
            String productColorName,
            String productUnitName,
            BigDecimal plannedQty,
            String status,
            boolean autoPromoteWhenReady,
            String workshopName,
            String teamName,
            String responsibleEmployeeName,
            LocalDate planBeginDate,
            LocalDate planEndDate,
            String salesOrderNo,
            String requestNote,
            String remark,
            String drawBillNos,
            List<Material> materials) {
    }

    public record Material(
            UUID demandId,
            UUID goodsId,
            String goodsCode,
            String goodsName,
            String spec,
            String colorName,
            String unitName,
            BigDecimal perProductQty,
            BigDecimal requiredQty,
            BigDecimal stockAllocatedQty,
            BigDecimal shortageQty,
            String supplyRoute,
            String demandStatus) {
    }
}