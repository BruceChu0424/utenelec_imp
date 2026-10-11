package com.uten.imp.features.production.dailyreport.dto;

import com.fasterxml.jackson.annotation.JsonIgnoreProperties;
import java.math.BigDecimal;
import java.util.List;
import java.util.UUID;

/** Server-calculated projection before approval; never a physical count or a stock receipt. */
@JsonIgnoreProperties(ignoreUnknown = true)
public record DailyReportMaterialReview(
        UUID reportId, long reportVersion, String fingerprint, List<Row> rows) {
    @JsonIgnoreProperties(ignoreUnknown = true)
    public record Row(
            UUID demandId, UUID planId, UUID materialExecutionSegmentId,
            String materialExecutionSegmentCode, String goodsCode, String goodsName,
            String colorName, String unitName, BigDecimal availableQty, BigDecimal usageQty,
            BigDecimal remainingIssuedQty, BigDecimal undrawnDirectQty,
            BigDecimal returnableIssuedQty, BigDecimal returnableDirectQty,
            boolean canReturn, String returnBlockedReason) {
        public String getAvailableQtyExact() { return exact(availableQty); }
        public String getUsageQtyExact() { return exact(usageQty); }
        public String getRemainingIssuedQtyExact() { return exact(remainingIssuedQty); }
        public String getUndrawnDirectQtyExact() { return exact(undrawnDirectQty); }
        public String getReturnableIssuedQtyExact() { return exact(returnableIssuedQty); }
        public String getReturnableDirectQtyExact() { return exact(returnableDirectQty); }
        private static String exact(BigDecimal value) { return value.toPlainString(); }
    }
}
