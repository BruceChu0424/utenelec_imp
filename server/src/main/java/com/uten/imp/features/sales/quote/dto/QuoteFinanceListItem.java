package com.uten.imp.features.sales.quote.dto;

import com.fasterxml.jackson.databind.annotation.JsonSerialize;
import com.uten.imp.common.finance.ExactDecimalText;

import java.math.BigDecimal;
import java.time.LocalDate;
import java.time.OffsetDateTime;
import java.util.UUID;

/**
 * 财务核价列表行(待核价 / 已核价 / 已退回)。claimedByName 非空表示有人正在核价;
 * pricePendingCount = 还没有单价、需要财务定价的行数。
 */
public record QuoteFinanceListItem(
        UUID id,
        String billNo,
        LocalDate billDate,
        String clientName,
        String sellerName,
        String makerName,
        OffsetDateTime submittedAt,
        long lineCount,
        long pricePendingCount,
        @JsonSerialize(using = ExactDecimalText.class) BigDecimal totalOriginal,
        String clientFileCurrency,
        String statusBucket,
        int reviewRevision,
        boolean resubmitted,
        String financeReturnReason,
        OffsetDateTime financeReturnedAt,
        OffsetDateTime financeConfirmedAt,
        String financeConfirmedByName,
        String convertedOrderNo,
        String claimedByName,
        boolean claimedByMe) {
}
