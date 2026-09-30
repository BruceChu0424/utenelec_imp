package com.uten.imp.application.port;

import com.fasterxml.jackson.databind.annotation.JsonSerialize;
import com.uten.imp.common.finance.ExactDecimalText;
import java.math.BigDecimal;
import java.time.LocalDate;
import java.time.OffsetDateTime;
import java.util.List;
import java.util.UUID;

/** Current approved workshop progress of one proven execution family, independent of inventory valuation. */
public interface GoodsProductionOutputQueryPort {
    record Query(UUID goodsId, UUID executionSegmentId) {}

    /** Quantities use the family's frozen reporting unit, never the current goods-master conversion. */
    record Summary(UUID goodsId, String state, String selectionBasis, UUID scopeId, String scopeNo,
            LocalDate firstReportDate, LocalDate lastReportDate, OffsetDateTime lastReportUpdatedAt,
            UUID unitId, String unitName,
            @JsonSerialize(using = ExactDecimalText.class) BigDecimal approvedReportedQty,
            @JsonSerialize(using = ExactDecimalText.class) BigDecimal effectiveCompletedQty,
            @JsonSerialize(using = ExactDecimalText.class) BigDecimal fqcDeductedQty,
            @JsonSerialize(using = ExactDecimalText.class) BigDecimal reportedDefectQty,
            int memberCount, long approvedReportCount, boolean hasDraftReports,
            List<String> sourceCodes, List<String> issues) {}

    Summary summary(Query query);
}
