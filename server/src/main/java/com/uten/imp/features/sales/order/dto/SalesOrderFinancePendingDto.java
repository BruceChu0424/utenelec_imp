package com.uten.imp.features.sales.order.dto;

import com.fasterxml.jackson.databind.annotation.JsonSerialize;
import com.fasterxml.jackson.databind.ser.std.ToStringSerializer;

import java.math.BigDecimal;
import java.time.LocalDate;
import java.util.UUID;

/** 财务确认任务列表行（已审未确认的销售订货单）。 */
public record SalesOrderFinancePendingDto(
        @JsonSerialize(using = ToStringSerializer.class) UUID orderId,
        String billNo,
        LocalDate billDate,
        String clientName,
        String sellerName,
        LocalDate deliverDate,
        long itemCount,
        BigDecimal totalOriginal,
        String currencyCode) {
}
