package com.uten.imp.features.sales.order.dto;

import com.fasterxml.jackson.databind.annotation.JsonSerialize;
import com.fasterxml.jackson.databind.ser.std.ToStringSerializer;

import java.math.BigDecimal;
import java.time.LocalDate;
import java.time.OffsetDateTime;
import java.util.UUID;

/**
 * 财务确认任务列表行（已审未确认的销售订货单）。
 *
 * <p>financeRejected 族（V300）：财务已驳回待修正的订单仍留在待确认池并带驳回标记，
 * 驳回原因随列表下发，便于财务与销售两端直接看到待办与驳回历史。
 */
public record SalesOrderFinancePendingDto(
        @JsonSerialize(using = ToStringSerializer.class) UUID orderId,
        String billNo,
        LocalDate billDate,
        String clientName,
        String sellerName,
        LocalDate deliverDate,
        long itemCount,
        BigDecimal totalOriginal,
        String currencyCode,
        /** 币种显示名（主档 name 人民币/美金…，前端展示优先于 code 编号）。 */
        String currencyName,
        String shipmentPolicy,
        BigDecimal clientOutstanding,
        boolean financeRejected,
        String financeRejectedReason,
        OffsetDateTime financeRejectedAt,
        /** 上次财务确认之后的改量处数（>0 = 「改后待确认」，审核页有修改清单）。 */
        long changeCount,
        long financeReviewRevision,
        /**
         * ADR-134 来源报价(由财务核价确认过的报价转入才有, 否则为 null): 单号、核价人与时间;
         * allLinesMatch = 每行单价与折扣都与报价核定一致(列表显示「报价已核价 · 一致」), 与审核页同一配对规则。
         */
        SalesOrderFinanceReviewDto.SourceQuote sourceQuote,
        /** 与审核页同口径: 报价转入的订单每行都与报价核定一致为 true、有不一致为 false; 不是报价转入为 null。 */
        Boolean matchesQuote) {
}
