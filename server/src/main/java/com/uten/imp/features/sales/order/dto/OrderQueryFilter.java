package com.uten.imp.features.sales.order.dto;

import java.time.LocalDate;
import java.util.UUID;

/** 销售订货列表查询条件。chain=订单行链路状态组（工作台统计卡钻取：2/3/4待生产 5/6生产中 1/7/8待发货）。 */
public record OrderQueryFilter(
        String keyword,
        UUID clientId,
        Short status,
        Boolean closed,
        LocalDate dateFrom,
        LocalDate dateTo,
        java.util.List<Short> chain) {
}
