package com.uten.imp.features.production.quality;

import java.math.BigDecimal;
import java.time.LocalDate;
import java.time.OffsetDateTime;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.UUID;

/** Read-only production-FQC decision-record contracts. */
public final class ProductionFqcRecordContracts {

    private ProductionFqcRecordContracts() {
    }

    public record InspectionDecisionRecord(
            UUID recordId,
            String domain,
            String sourceType,
            UUID inspectionId,
            UUID sourceId,
            UUID sourceItemId,
            String sourceNo,
            LocalDate sourceDate,
            String referenceNo,
            UUID partnerId,
            String partnerName,
            UUID warehouseId,
            String warehouseName,
            UUID goodsId,
            String goodsCode,
            String goodsName,
            UUID colorId,
            String colorName,
            UUID unitId,
            String unitName,
            BigDecimal inspectedQty,
            BigDecimal currentPassedQty,
            BigDecimal currentFailedQty,
            BigDecimal currentRemainingQty,
            String decision,
            BigDecimal passQty,
            BigDecimal failQty,
            String dispositionCode,
            String reason,
            UUID inspectorEmployeeId,
            String inspectorName,
            OffsetDateTime decidedAt,
            String currentStatus,
            boolean effective,
            String sheetNo) {
    }

    public record InspectionDecisionRecordPage(
            List<InspectionDecisionRecord> items,
            int page,
            int size,
            long total,
            int totalPages,
            Map<String, Long> metrics) {

        public InspectionDecisionRecordPage {
            items = List.copyOf(items);
            metrics = Map.copyOf(new LinkedHashMap<>(metrics));
        }
    }
}
